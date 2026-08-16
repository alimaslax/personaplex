#!/usr/bin/env bash
set -euo pipefail

export HF_HOME="${HF_HOME:-/data/.cache/huggingface}"
export MODEL_DIR="${MODEL_DIR:-/data/models/personaplex}"
export PORT="${PORT:-7860}"
export NO_TORCH_COMPILE="${NO_TORCH_COMPILE:-1}"
export TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-/data/tailscale}"
mkdir -p "$HF_HOME" "$MODEL_DIR"

nginx -c /app/runtime/verda/nginx.conf -g 'daemon off;' &
NGINX_PID=$!

start_tailscale() {
  [[ "${TAILSCALE_ENABLE:-0}" == "1" ]] || return 0

  echo "[personaplex-tailscale] waiting for daemon"

  # `tailscale status` is non-zero while the daemon is logged out, which is
  # exactly when we need to run `tailscale up`. Wait for its control socket
  # instead of waiting for an already-authenticated status.
  until [[ -S /tmp/tailscaled.sock ]]; do
    sleep 1
  done

  # With no auth key, `tailscale up` reuses the identity persisted on the
  # /data disk. On a first-ever boot it prints a one-time login URL; on a
  # resumed replica it reconnects without asking the owner to approve again.
  # This keeps tailnet authorization in the account owner's browser instead of
  # embedding a reusable tailnet credential in the deployment.
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    tailscale --socket=/tmp/tailscaled.sock up \
      --auth-key="$TAILSCALE_AUTHKEY" \
      --hostname=personaplex-live \
      --accept-dns=false
  else
    echo "[personaplex-tailscale] login link follows; approve it in your Tailscale account"
    tailscale --socket=/tmp/tailscaled.sock up \
      --hostname=personaplex-live \
      --accept-dns=false
  fi

  until TAILSCALE_IP="$(tailscale --socket=/tmp/tailscaled.sock ip -4 2>/dev/null)"; [[ -n "$TAILSCALE_IP" ]]; do
    sleep 2
  done
  echo "[personaplex-tailscale] connected at ${TAILSCALE_IP}:7860"
  tailscale --socket=/tmp/tailscaled.sock serve --http=7860 http://127.0.0.1:7860
}

if [[ "${TAILSCALE_ENABLE:-0}" == "1" ]]; then
  mkdir -p "$TAILSCALE_STATE_DIR"
  tailscaled \
    --state="$TAILSCALE_STATE_DIR/tailscaled.state" \
    --socket=/tmp/tailscaled.sock \
    --tun=userspace-networking &
  TAILSCALED_PID=$!
  start_tailscale &
  TAILSCALE_CONFIG_PID=$!
fi

cleanup() {
  for pid in "${MOSHI_PID:-}" "${TAILSCALED_PID:-}" "${TAILSCALE_CONFIG_PID:-}" "$NGINX_PID"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  wait || true
}
trap cleanup TERM INT EXIT

# Nginx is intentionally up before the (large) gated model download.  Its
# /health endpoint answers the platform startup probe while bootstrap runs.
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

# The PersonaPlex browser client is served by Moshi through Nginx.  The
# optional Gradio status page is intentionally not started: Gradio's bundled
# web stack is independent of the duplex service and must never take the
# whole GPU worker down if it fails to initialize.
wait -n "$MOSHI_PID" "$NGINX_PID"
STATUS=$?
trap - EXIT
cleanup
exit "$STATUS"
