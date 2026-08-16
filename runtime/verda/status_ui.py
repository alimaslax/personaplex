"""Small Gradio landing page for the PersonaPlex deployment."""

from __future__ import annotations

import os
from pathlib import Path

import gradio as gr


MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/data/models/personaplex"))


def cache_status() -> str:
    marker = MODEL_DIR / ".personaplex-ready"
    return "✅ Model cache is ready" if marker.is_file() else "⏳ Model cache is still loading"


with gr.Blocks(title="PersonaPlex on Verda") as demo:
    gr.Markdown("# PersonaPlex on Verda\n\nThe full-duplex microphone client is available at the deployment root. This page confirms the model cache and explains the WebSocket service.")
    status = gr.Markdown(cache_status())
    refresh = gr.Button("Refresh cache status")
    refresh.click(cache_status, outputs=status)
    gr.Markdown("The live client uses a WebSocket at `/api/chat`; keep one conversation active per replica.")


if __name__ == "__main__":
    demo.launch(server_name="127.0.0.1", server_port=int(os.environ.get("GRADIO_PORT", "7861")), root_path="/gradio")
