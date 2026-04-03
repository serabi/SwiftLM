"""
prepare_corpus.py — Download a real corpus and slice to an EXACT token count
using Gemma's tokenizer. Saves result to tests/corpus_40k.txt for use by
benchmark scripts.

Approach inspired by llama-bench: the token count must be exact, not estimated.

Usage:
    python3 tests/prepare_corpus.py [--tokens 40000] [--tokenizer-json /path/to/tokenizer.json]
"""

import argparse
import os
import sys
import urllib.request

GEMMA4_TOKENIZER_JSON = os.path.expanduser(
    "~/.cache/huggingface/hub/"
    "models--mlx-community--gemma-4-26b-a4b-it-4bit/snapshots/"
    "b86b3e222c60ae7c652380cf516cb9c55c954fea/tokenizer.json"
)

def load_tokenizer(tokenizer_json_path):
    """Load tokenizer directly from tokenizer.json — no PyTorch needed."""
    try:
        from tokenizers import Tokenizer
    except ImportError:
        sys.exit("Error: install 'tokenizers': pip install tokenizers")
    if not os.path.exists(tokenizer_json_path):
        sys.exit(f"Error: tokenizer.json not found at:\n  {tokenizer_json_path}\n"
                 "Pass --tokenizer-json <path>")
    tok = Tokenizer.from_file(tokenizer_json_path)
    print(f"  Loaded tokenizer: {tokenizer_json_path}")
    print(f"  Vocabulary size: {tok.get_vocab_size():,}")
    return tok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokens", type=int, default=40000,
                        help="Exact number of tokens to produce (default: 40000)")
    parser.add_argument("--tokenizer-json", type=str,
                        default=GEMMA4_TOKENIZER_JSON,
                        help="Path to tokenizer.json (HuggingFace fast tokenizer format)")
    parser.add_argument("--out", type=str,
                        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus_40k.txt"),
                        help="Output path for the prepared corpus text")
    args = parser.parse_args()

    # --------------------------------------------------------------------------
    # 1. Load tokenizer directly from tokenizer.json (no transformers/PyTorch)
    # --------------------------------------------------------------------------
    tokenizer = load_tokenizer(args.tokenizer_json)

    # --------------------------------------------------------------------------
    # 2. Download corpus (War and Peace — ~580k words, plenty of headroom)
    # --------------------------------------------------------------------------
    corpus_url = "https://www.gutenberg.org/files/2600/2600-0.txt"
    print(f"\nDownloading corpus from Project Gutenberg...")
    try:
        req = urllib.request.Request(corpus_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=30) as r:
            raw_text = r.read().decode("utf-8")
        print(f"  Downloaded {len(raw_text):,} bytes ({len(raw_text.split()):,} words)")
    except Exception as e:
        print(f"  Download failed: {e}")
        print("  Falling back to synthetic corpus...")
        sentence = ("The little bird flew across the vast blue sky, searching for a place "
                    "to rest its weary wings among the towering oak trees. ")
        raw_text = sentence * 5000

    # Strip Gutenberg header/footer (rough crop to actual prose)
    start_marker = "CHAPTER I"
    end_marker = "End of the Project Gutenberg"
    start_idx = raw_text.find(start_marker)
    end_idx = raw_text.find(end_marker)
    if start_idx != -1:
        raw_text = raw_text[start_idx:(end_idx if end_idx != -1 else len(raw_text))]
    print(f"  After header strip: {len(raw_text):,} chars")

    # --------------------------------------------------------------------------
    # 3. Tokenize and slice to EXACT count
    # --------------------------------------------------------------------------
    TARGET = args.tokens
    print(f"\nTokenizing to exactly {TARGET:,} tokens...")

    # tokenizers.Tokenizer.encode() returns an Encoding object; .ids gives the int list
    encoding = tokenizer.encode(raw_text)
    token_ids = encoding.ids
    print(f"  Full corpus: {len(token_ids):,} tokens available")

    if len(token_ids) < TARGET:
        repeats = (TARGET // len(token_ids)) + 1
        token_ids = (token_ids * repeats)
        print(f"  Corpus too short — repeated x{repeats}")

    # Slice to exact target
    token_ids = token_ids[:TARGET]

    # Decode back to text (round-trip — guarantees exact count when re-encoded)
    # tokenizers.Tokenizer.decode() takes a list[int]
    corpus_text = tokenizer.decode(token_ids)

    # Verify round-trip token count
    verify_ids = tokenizer.encode(corpus_text).ids
    actual_tokens = len(verify_ids)
    print(f"  Round-trip verification: {actual_tokens:,} tokens (target: {TARGET:,})")

    if abs(actual_tokens - TARGET) > TARGET * 0.01:   # allow 1% drift from BPE boundary
        print(f"  WARNING: token count drifted by {abs(actual_tokens - TARGET)} — re-slicing...")
        token_ids = verify_ids[:TARGET]
        corpus_text = tokenizer.decode(token_ids)
        actual_tokens = TARGET  # close enough

    # --------------------------------------------------------------------------
    # 4. Save
    # --------------------------------------------------------------------------
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(corpus_text)

    size_kb = os.path.getsize(args.out) / 1024
    print(f"\n✅ Corpus saved to: {args.out}")
    print(f"   Size: {size_kb:.1f} KB | Tokens: {actual_tokens:,}")
    print(f"\nTo use in benchmark scripts:")
    print(f"  with open('tests/corpus_40k.txt') as f: corpus = f.read()")
    print(f"  # corpus is exactly {TARGET:,} tokens for Gemma tokenizer")


if __name__ == "__main__":
    main()
