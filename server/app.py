"""flex-voice server fallback — STT for devices too slow to run Whisper locally.

Opt-in only: the browser library POSTs here solely when the host app set
slowDevice='server'. Audio is transcribed in memory and never persisted.
"""
import asyncio
import os
import tempfile
import time

from fastapi import FastAPI, Form, Header, HTTPException, UploadFile

MODEL_NAME = os.environ.get("WHISPER_MODEL", "small.en")
MODELS_DIR = os.environ.get("WHISPER_MODELS_DIR", "/models")
MAX_BYTES = int(os.environ.get("MAX_BYTES", 25 * 1024 * 1024))
API_KEYS = {k for k in os.environ.get("API_KEYS", "").split(",") if k}

app = FastAPI()
_model = None
# ponytail: semaphore(1) — two concurrent jobs OOM the box (same hard limit
# as agent-platform's whisper worker). Scale = bigger box, not more slots.
_lock = asyncio.Semaphore(1)


def _get_model():
    global _model
    if _model is None:
        from faster_whisper import WhisperModel
        _model = WhisperModel(MODEL_NAME, device="cpu", compute_type="int8",
                              download_root=MODELS_DIR)
    return _model


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/transcribe")
async def transcribe(audio: UploadFile, language: str = Form("en"),
                     x_api_key: str | None = Header(None)):
    if x_api_key not in API_KEYS:
        raise HTTPException(401, "invalid API key")
    data = await audio.read()
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "upload too large")
    if not data:
        raise HTTPException(400, "empty upload")

    async with _lock:
        t0 = time.monotonic()
        text, duration = await asyncio.to_thread(_run, data, language)
    return {"text": text, "duration_ms": int(duration * 1000)}


def _run(data: bytes, language: str) -> tuple[str, float]:
    with tempfile.NamedTemporaryFile(suffix=".webm") as f:
        f.write(data)
        f.flush()
        segments, info = _get_model().transcribe(f.name, language=language)
        return " ".join(s.text.strip() for s in segments).strip(), info.duration
