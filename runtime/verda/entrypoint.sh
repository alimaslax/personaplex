#!/usr/bin/env bash
set -euo pipefail

export HF_HOME="${HF_HOME:-/data/.cache/huggingface}"
export MODEL_DIR="${MODEL_DIR:-/data/models/personaplex}"
export PORT="${PORT:-7860}"
export NO_TORCH_COMPILE="${NO_TORCH_COMPILE:-1}"
mkdir -p "$HF_HOME" "$MODEL_DIR"

python3 /app/runtime/verda/bootstrap_model.py

python3 -m moshi.server \
  --host 127.0.0.1 \
  --port 8998 \
  --moshi-weight "$MODEL_DIR/model.safetensors" \
  --mimi-weight "$MODEL_DIR/tokenizer-e351c8d8-checkpoint125.safetensors" \
  --tokenizer "$MODEL_DIR/tokenizer_spm_32k_3.model" \
  --voice-prompt-dir "$MODEL_DIR/voices" \
  --static "$MODEL_DIR/dist" &
MOSHI_PID=$!

python3 /app/runtime/verda/gradio_client.py &
GRADIO_PID=$!

trap 'kill "$MOSHI_PID" "$GRADIO_PID" 2>/dev/null || true; wait' TERM INT
nginx -c /app/runtime/verda/nginx.conf -g 'daemon off;' &
NGINX_PID=$!

wait -n "$MOSHI_PID" "$GRADIO_PID" "$NGINX_PID"
STATUS=$?
kill "$MOSHI_PID" "$GRADIO_PID" "$NGINX_PID" 2>/dev/null || true
wait || true
exit "$STATUS"
