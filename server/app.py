"""flex-voice server fallback — STT for devices too slow to run Whisper locally.

Opt-in only: the browser library POSTs here solely when the host app set
slowDevice='server'. Audio is transcribed in memory and never persisted.
"""
import asyncio
import json
import os
import tempfile

from fastapi import FastAPI, Form, Header, HTTPException, UploadFile
from starlette.middleware.cors import CORSMiddleware

MODEL_NAME = os.environ.get("WHISPER_MODEL", "small.en")
MODELS_DIR = os.environ.get("WHISPER_MODELS_DIR", "/models")
MAX_BYTES = int(os.environ.get("MAX_BYTES", 25 * 1024 * 1024))
API_KEYS = {k for k in os.environ.get("API_KEYS", "").split(",") if k}
# ponytail: empty ALLOWED_ORIGINS -> allow_origins=[] -> CORSMiddleware allows
# no browser origin (fail closed), same posture as an unset API_KEYS locking
# out /transcribe entirely.
ALLOWED_ORIGINS = [o for o in os.environ.get("ALLOWED_ORIGINS", "").split(",") if o]

fastapi_app = FastAPI()
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


@fastapi_app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_NAME}


@fastapi_app.post("/transcribe")
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
        text, duration = await asyncio.to_thread(_run, data, language)
    return {"text": text, "duration_ms": int(duration * 1000)}


def _run(data: bytes, language: str) -> tuple[str, float]:
    with tempfile.NamedTemporaryFile(suffix=".webm") as f:
        f.write(data)
        f.flush()
        segments, info = _get_model().transcribe(f.name, language=language)
        return " ".join(s.text.strip() for s in segments).strip(), info.duration


class _PayloadTooLarge(Exception):
    """Raised from a wrapped ASGI `receive` to abort a body read mid-stream."""


async def _respond(send, status: int, message: str) -> None:
    await send({
        "type": "http.response.start",
        "status": status,
        "headers": [(b"content-type", b"application/json")],
    })
    await send({"type": "http.response.body", "body": json.dumps({"detail": message}).encode()})


class UploadGuardMiddleware:
    """Pure-ASGI guard in front of POST /transcribe.

    FastAPI/Starlette fully receive+parse the multipart body before the
    endpoint function runs, so in-function auth/size checks don't stop an
    unauthenticated or oversized upload from being buffered off the socket
    first. This middleware runs ahead of body parsing: it rejects a bad key
    or an over-cap Content-Length immediately from the ASGI scope, and wraps
    `receive` to keep counting bytes so a lying/chunked client that omits or
    understates Content-Length still gets cut off mid-stream. The in-endpoint
    checks stay in place as defense-in-depth.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST" or scope["path"] != "/transcribe":
            await self.app(scope, receive, send)
            return

        headers = dict(scope["headers"])
        api_key = headers.get(b"x-api-key")
        if (api_key.decode("latin-1") if api_key else None) not in API_KEYS:
            await _respond(send, 401, "invalid API key")
            return

        content_length = headers.get(b"content-length")
        if content_length is None:
            await _respond(send, 411, "Content-Length required")
            return
        if int(content_length) > MAX_BYTES:
            await _respond(send, 413, "upload too large")
            return

        received = 0
        aborted = False

        async def guarded_receive():
            nonlocal received, aborted
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > MAX_BYTES:
                    aborted = True
                    raise _PayloadTooLarge()
            return message

        async def guarded_send(message):
            if aborted:
                return
            await send(message)

        try:
            await self.app(scope, guarded_receive, guarded_send)
        except _PayloadTooLarge:
            pass

        if aborted:
            await _respond(send, 413, "upload too large")


_guarded_app = UploadGuardMiddleware(fastapi_app)
# CORSMiddleware wraps outside the guard so it runs first: an OPTIONS
# preflight (browsers never send X-API-Key on preflight) is answered by CORS
# directly and never reaches the guard — which only matches POST anyway.
app = CORSMiddleware(
    _guarded_app,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["POST"],
    allow_headers=["X-API-Key"],
    max_age=3600,
)
