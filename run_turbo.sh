#!/bin/bash
model="mlx-community/gemma-4-e4b-it-8bit"
echo "Starting TurboKV Server..."
.build/debug/SwiftLM --model $model --port 5420 --turbo-kv > server_turbo.log 2>&1 &
SERVER_PID=$!
sleep 15
echo "Running Python Benchmark..."
python3 tests/run_benchmarks.py --port 5420 --model $model --concurrency 1 --max-tokens 5 --input-multiplier 2500 > bench_turbo.log 2>&1
kill $SERVER_PID
echo "(Done)"
cat bench_turbo.log
