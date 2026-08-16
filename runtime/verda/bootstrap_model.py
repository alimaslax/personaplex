"""Populate Verda's persistent disk with PersonaPlex assets exactly once."""

from __future__ import annotations

import os
import shutil
import tarfile
import time
import traceback
import uuid
from pathlib import Path

from huggingface_hub import snapshot_download


MODEL_REPO = os.environ.get("HF_MODEL_REPO", "nvidia/personaplex-7b-v1")
MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/data/models/personaplex"))
MARKER = ".personaplex-ready"
LOCK_DIR = MODEL_DIR.parent / ".personaplex-download.lock"
REQUIRED_FILES = (
    "model.safetensors",
    "tokenizer-e351c8d8-checkpoint125.safetensors",
    "tokenizer_spm_32k_3.model",
    "voices/NATF0.pt",
    "dist/index.html",
)
DOWNLOAD_PATTERNS = (
    "model.safetensors",
    "tokenizer-e351c8d8-checkpoint125.safetensors",
    "tokenizer_spm_32k_3.model",
    "voices.tgz",
    "dist.tgz",
)


def log(message: str) -> None:
    print(f"[personaplex-bootstrap {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {message}", flush=True)


def is_ready(path: Path) -> bool:
    return (path / MARKER).is_file() and all((path / item).is_file() for item in REQUIRED_FILES)


def safe_extract(archive: Path, target: Path) -> None:
    with tarfile.open(archive, "r:gz") as tar:
        target_root = target.resolve()
        for member in tar.getmembers():
            destination = (target / member.name).resolve()
            if destination != target_root and target_root not in destination.parents:
                raise RuntimeError(f"archive member escapes model cache: {member.name}")
        # `filter="data"` is only available on newer Python releases.  The
        # destination validation above gives this Python 3.10 image the same
        # path-traversal protection.
        tar.extractall(target)


def acquire_lock() -> None:
    while True:
        try:
            LOCK_DIR.mkdir()
            return
        except FileExistsError:
            if is_ready(MODEL_DIR):
                return
            log("another replica is downloading the model; waiting for its /data cache")
            time.sleep(5)


def main() -> None:
    MODEL_DIR.parent.mkdir(parents=True, exist_ok=True)
    if is_ready(MODEL_DIR):
        log(f"cache ready at {MODEL_DIR}; skipping Hugging Face download")
        return
    if not os.environ.get("HF_TOKEN"):
        raise RuntimeError("HF_TOKEN must be configured as a Verda secret before first startup")

    acquire_lock()
    if is_ready(MODEL_DIR):
        log("cache became ready while waiting; skipping Hugging Face download")
        return

    staging = MODEL_DIR.parent / f".personaplex-staging-{uuid.uuid4().hex}"
    try:
        log(f"downloading gated model assets from {MODEL_REPO}")
        snapshot_download(
            repo_id=MODEL_REPO,
            local_dir=staging,
            allow_patterns=list(DOWNLOAD_PATTERNS),
            token=os.environ["HF_TOKEN"],
        )
        log("extracting bundled web client and voice prompts")
        safe_extract(staging / "voices.tgz", staging)
        safe_extract(staging / "dist.tgz", staging)
        if not all((staging / item).is_file() for item in REQUIRED_FILES):
            missing = [item for item in REQUIRED_FILES if not (staging / item).is_file()]
            raise RuntimeError(f"incomplete PersonaPlex cache: {missing}")
        (staging / MARKER).write_text("ready\n", encoding="utf-8")
        if MODEL_DIR.exists():
            shutil.rmtree(MODEL_DIR)
        staging.replace(MODEL_DIR)
        log(f"cache committed atomically at {MODEL_DIR}")
    except Exception:
        log(f"bootstrap failed:\n{traceback.format_exc()}")
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        shutil.rmtree(LOCK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
