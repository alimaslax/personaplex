# PersonaPlex on Verda

`Dockerfile.verda` builds a CUDA image for a Verda **Continuous** container.
It exposes port `7860`: `/` is PersonaPlex's real-time microphone/WebSocket
client and `/gradio/` is a small Gradio status client. The WebSocket endpoint
is `/api/chat`.

On its first boot, the entrypoint downloads the gated
`nvidia/personaplex-7b-v1` assets to `/data/models/personaplex`, validates and
atomically marks the cache, then starts the service. A later cold boot sees
the marker and skips the download.

Deploy with one GPU, one concurrent request, `min_replicas=1`,
`max_replicas=1`, port `7860`, and health check path `/health`. Configure
`HF_TOKEN` as a Verda secret and accept the model's Hugging Face license before
the first start. Use an immutable image tag from the GitHub Actions workflow.
