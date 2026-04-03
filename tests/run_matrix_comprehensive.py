import subprocess
import time
import urllib.request
import json
import os

models_dense = [
    "mlx-community/gemma-4-e2b-it-4bit",
    "mlx-community/gemma-4-e4b-it-8bit"
]
models_moe = [
    "mlx-community/gemma-4-26b-a4b-it-4bit",
    "mlx-community/gemma-4-31b-it-4bit"
]

port = 5443
TARGET_TOKENS = 40000  # exact token count, prepared by tests/prepare_corpus.py

# Load pre-tokenized corpus (exact token count) if available, else fall back to approximation.
# Run:  python3 tests/prepare_corpus.py --tokens 40000
_corpus_path = os.path.join(os.path.dirname(__file__), "corpus_40k.txt")
if os.path.exists(_corpus_path):
    with open(_corpus_path, encoding="utf-8") as _f:
        _corpus = _f.read()
    prompt_text = "Please write a story about a little bird.\n\n" + _corpus
    print(f"✅ Loaded exact corpus: {_corpus_path} ({TARGET_TOKENS:,} tokens)")
else:
    # Fallback: ~40K tokens via word repetition (not exact, but avoids OOM)
    prompt_text = "Please write a story about a little bird. " + ("test " * 32000)
    print(f"⚠️  corpus_40k.txt not found — using word-repetition approximation.")
    print(f"   For exact token counts run: python3 tests/prepare_corpus.py")


results = []

def run_benchmark(model, use_turbo, use_ssd):
    print(f"\n======================================")
    print(f"Benchmarking: {model}")
    print(f"TurboQuant: {'ON' if use_turbo else 'OFF'} | SSD Stream: {'ON' if use_ssd else 'OFF'}")
    print(f"======================================")
    
    server_cmd = [".build/release/SwiftLM", "--model", model, "--port", str(port)]
    if use_turbo:
        server_cmd.append("--turbo-kv")
    if use_ssd:
        server_cmd.append("--stream-experts")
        
    with open("benchmark_matrix_server.log", "w") as log_file:
        server_proc = subprocess.Popen(server_cmd, stdout=log_file, stderr=subprocess.STDOUT)
    
    loaded = False
    for i in range(1200):
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/health", method="GET")
            with urllib.request.urlopen(req) as response:
                if response.status == 200:
                    loaded = True
                    break
        except:
            time.sleep(1.0)
            
    if not loaded:
        print(f"Error: Server failed to start.")
        server_proc.terminate()
        server_proc.wait()
        return
        
    print(f"Server loaded. Submitting 40K context...")
    time.sleep(2)
    
    payload = {
        "model": model,
        "stream": True,
        "max_tokens": 10,
        "messages": [{"role": "user", "content": prompt_text}]
    }
    
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
        method="POST"
    )
    
    start_time = time.time()
    ttft = None
    tokens = 0
    peak_gb = 0
    
    try:
        with urllib.request.urlopen(req, timeout=1200) as response:
            for line in response:
                line = line.decode('utf-8').strip()
                if not line or line == "data: [DONE]":
                    continue
                if line.startswith("data: "):
                    data_str = line[6:]
                    try:
                        data = json.loads(data_str)
                        if data.get('choices') and data['choices'][0]['delta'].get('content'):
                            if ttft is None:
                                ttft = time.time() - start_time
                                print(f"  -> First Token received in {ttft:.2f}s!")
                                
                                # Immediately poll memory after prefill
                                try:
                                    hreq = urllib.request.Request(f"http://127.0.0.1:{port}/health", method="GET")
                                    with urllib.request.urlopen(hreq) as hres:
                                        hdata = json.loads(hres.read().decode('utf-8'))
                                        peak_mb = hdata.get("memory", {}).get("peak_mb", 0)
                                        peak_gb = peak_mb / 1024.0
                                except Exception:
                                    pass
                                    
                            tokens += 1
                    except json.JSONDecodeError:
                        continue
    except Exception as e:
        print(f"Generation failed: {e}")
        
    duration = time.time() - start_time
    if ttft is None:
        ttft = duration
        
    # Teardown
    server_proc.terminate()
    try:
        server_proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server_proc.kill()
        
    tps = tokens / (duration - ttft) if (duration - ttft) > 0 and tokens > 1 else 0
    print(f"--- Results ---")
    print(f"TTFT: {ttft:.2f}s | TPS: {tps:.2f} | Peak RAM: {peak_gb:.2f} GB\n")
    
    results.append({
        "Model": model.split("/")[-1],
        "TurboKV": "ON" if use_turbo else "OFF",
        "SSD": "ON" if use_ssd else "OFF",
        "TTFT (s)": round(ttft, 2),
        "TPS": round(tps, 2),
        "Peak Mem (GB)": round(peak_gb, 2)
    })

print("\nStarting comprehensive matrix...")

# Dense Model Matrix
for m in models_dense:
    run_benchmark(m, use_turbo=False, use_ssd=False)
    run_benchmark(m, use_turbo=True, use_ssd=False)

# MoE Model Matrix
for m in models_moe:
    run_benchmark(m, use_turbo=False, use_ssd=False)
    run_benchmark(m, use_turbo=True, use_ssd=False)
    run_benchmark(m, use_turbo=False, use_ssd=True)
    run_benchmark(m, use_turbo=True, use_ssd=True)

print("\n\n=== FINAL 40K COMPREHENSIVE MATRIX ===")
print("| Model | TurboKV | SSD Stream | Time To First Token | Generation Speed | Peak GPU Memory |")
print("|---|---|---|---|---|---|")
for r in results:
    print(f"| `{r['Model']}` | {r['TurboKV']} | {r['SSD']} | {r['TTFT (s)']}s | {r['TPS']} tok/s | {r['Peak Mem (GB)']} GB |")

with open("comprehensive_matrix_results.json", "w") as f:
    json.dump(results, f, indent=2)
