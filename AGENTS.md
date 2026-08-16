# PersonaPlex Verda Deployment Runbook

This repository runs PersonaPlex on Verda as a GPU-backed **Continuous**
container. Treat the container image, persistent disk, private network access,
and local browser client as one deployment system.

## Source control and image publishing

- Canonical remote: `https://github.com/alimaslax/personaplex.git`.
- Deployable changes go to `main`. Before handing off work, run `git status
  -sb`, commit intentional changes, and push them to `origin/main`.
- The deployable image is built by GitHub Actions, never by pushing a locally
  built image. The workflow is
  `.github/workflows/publish-verda-image.yml`.
- A push to `main` that changes `Dockerfile.verda`, `moshi/**`,
  `runtime/verda/**`, or that workflow publishes:

  ```text
  ghcr.io/alimaslax/personaplex-verda:<git-sha>
  ```

  The SHA tag is immutable and is the image tag to select in Verda. A
  `workflow_dispatch` run may instead use an explicit immutable tag.
- Do not put credentials in the image, Dockerfile, workflow, repository, or
  logs. GitHub Actions uses its built-in `GITHUB_TOKEN` to publish to GHCR.

## Image and GPU compatibility

- `Dockerfile.verda` is the only image definition for this deployment.
- It uses `nvidia/cuda:12.8.1-runtime-ubuntu22.04` and PyTorch `2.8.0` from
  the CUDA 12.8 wheel index. This is required for Blackwell / RTX PRO 6000
  GPUs; older CUDA 12.4 Torch wheels can fail with `no kernel image`.
- The image includes PersonaPlex's `moshi` package, Nginx, and the Tailscale
  client. It exposes port `7860` and starts
  `runtime/verda/entrypoint.sh`.
- Rebuild through GitHub Actions after changing the Dockerfile, `moshi`, or
  anything under `runtime/verda`; then update the Verda container to the new
  immutable image tag.

## Verda continuous container

- Use a **Continuous** container with one GPU, one concurrent request,
  `min_replicas=1`, `max_replicas=1`, port `7860`, and health-check path
  `/health`.
- Prefer a spot Blackwell GPU only when it is available and acceptable for the
  session. It can be reclaimed, so do not assume uninterrupted availability.
- Nginx starts before model bootstrap. `/health` deliberately returns HTTP 200
  with `{"status":"starting"}` so Verda keeps the replica alive while the
  large model is first downloaded. It is a platform liveness endpoint, not a
  statement that Moshi has finished loading.
- Nginx forwards normal HTTP and WebSocket traffic on port `7860` to Moshi on
  `127.0.0.1:8998`. PersonaPlex's real-time WebSocket endpoint is `/api/chat`.
  Keep the WebSocket upgrade headers and the long proxy timeouts in
  `runtime/verda/nginx.conf`.
- Inspect **replica logs** for the actual startup error. Nginx access logs are
  emitted to stdout so a missing ingress request can be distinguished from an
  application failure.

## Hugging Face model cache and persistent disk

- The gated source model is `nvidia/personaplex-7b-v1`. The model license must
  be accepted by the account supplying the token.
- Set `HF_TOKEN` as a Verda secret before the first startup; never commit or
  print it. A token is not needed after a valid cache exists unless the cache
  is removed or the model source changes.
- The persistent Verda disk is mounted at `/data`. It holds:

  ```text
  /data/.cache/huggingface             Hugging Face download cache
  /data/models/personaplex             validated PersonaPlex model + client assets
  /data/tailscale/tailscaled.state     persisted Tailscale node state
  ```

- `runtime/verda/bootstrap_model.py` downloads only the inference assets:
  `model.safetensors`, Mimi/tokenizer weights, `voices.tgz`, and `dist.tgz`.
  It extracts the voice prompts and web client, verifies required files, then
  atomically replaces the model directory and writes `.personaplex-ready`.
- Never treat a partially downloaded directory as usable. The ready marker and
  required-file validation are what make later cold starts safely skip the
  download. Keep the disk attached when recreating or rolling the container;
  using a new disk requires the first download again.

## Private Tailscale access

- Set `TAILSCALE_ENABLE=1` in Verda to enable the private access path.
  `entrypoint.sh` starts `tailscaled` with userspace networking and persists
  its node state at `/data/tailscale/tailscaled.state`.
- With no `TAILSCALE_AUTHKEY`, startup prints a one-time Tailscale approval URL
  in the replica logs. Open it while signed into the intended tailnet. This is
  intentional: it avoids storing a reusable tailnet credential in Verda.
- If using `TAILSCALE_AUTHKEY`, configure it as a **Verda secret**, never as a
  GitHub secret, Docker build argument, or checked-in environment variable.
- After approval, the logs report the assigned tailnet IP. Tailscale Serve
  maps the MagicDNS hostname `personaplex-live` on port `7860` to local Nginx.
  Use the hostname because Serve is host-sensitive:

  ```text
  http://personaplex-live:7860/
  ```

  Accessing only the tailnet IP can produce an unexpected 404 even though the
  node is connected.
- Tailscale state survives replica restarts as long as the `/data` disk is
  reused. A replacement disk or deleted state requires a new login/approval.
- Never paste a one-time login URL, auth key, or tailnet IP into repository
  files, commits, issues, or public logs.

## Local browser client

- Run the Vite client from `client/`. For the private Tailscale path:

  ```bash
  VITE_QUEUE_API_URL='http://personaplex-live:7860' \
  VITE_PROXY_DEBUG='true' \
  npm run dev -- --port 5174
  ```

- Open `http://127.0.0.1:5174/` and allow microphone permission. Keep
  `VITE_QUEUE_API_STRIP_PREFIX` unset/false for normal PersonaPlex use because
  the server must receive `/api/chat` unchanged.
- A successful socket handshake begins with a one-byte handshake frame; use a
  real microphone conversation to assess voice quality and feasibility.

## Cost and shutdown

- Continuous replicas do not automatically stop after a fixed interaction
  period. If the session is meant to last roughly 45 minutes, set an explicit
  reminder and manually scale the deployment to zero or stop/delete it in
  Verda when finished.
- Do not claim that scale-to-zero has happened without checking the Verda
  replica status. A healthy, minimum-one continuous deployment continues to
  consume the selected GPU capacity.
