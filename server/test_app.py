import os
os.environ.setdefault("ALLOWED_ORIGINS", "https://app.example.com")

import asyncio
import io
import pytest
from fastapi.testclient import TestClient

import app as appmod
from app import app


class StubModel:
    def transcribe(self, path, language="en"):
        class Info:
            duration = 2.5
        class Seg:
            text = " hello world"
        return iter([Seg()]), Info()


@pytest.fixture(autouse=True)
def stub(monkeypatch):
    monkeypatch.setattr(appmod, "_get_model", lambda: StubModel())
    monkeypatch.setattr(appmod, "API_KEYS", {"k1"})


client = TestClient(app)
AUDIO = {"audio": ("clip.webm", io.BytesIO(b"\x1a" * 100), "audio/webm")}


def test_no_key_401():
    assert client.post("/transcribe", files=AUDIO).status_code == 401


def test_bad_key_401():
    assert client.post("/transcribe", files=AUDIO, headers={"X-API-Key": "nope"}).status_code == 401


def test_empty_upload_400():
    r = client.post("/transcribe", files={"audio": ("c.webm", io.BytesIO(b""), "audio/webm")},
                    headers={"X-API-Key": "k1"})
    assert r.status_code == 400


def test_oversize_413(monkeypatch):
    monkeypatch.setattr(appmod, "MAX_BYTES", 10)
    r = client.post("/transcribe", files=AUDIO, headers={"X-API-Key": "k1"})
    assert r.status_code == 413


def test_happy_path():
    r = client.post("/transcribe", files=AUDIO, headers={"X-API-Key": "k1"})
    assert r.status_code == 200
    assert r.json() == {"text": "hello world", "duration_ms": 2500}


def test_health():
    r = client.get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok"


def test_bad_key_with_large_declared_upload_never_reaches_model(monkeypatch):
    def boom():
        raise AssertionError("model should never be constructed for an unauthenticated request")
    monkeypatch.setattr(appmod, "_get_model", boom)
    big_audio = {"audio": ("clip.webm", io.BytesIO(b"\x1a" * (2 * 1024 * 1024)), "audio/webm")}
    r = client.post("/transcribe", files=big_audio, headers={"X-API-Key": "nope"})
    assert r.status_code == 401


def test_content_length_over_cap_rejected_before_body_read():
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "method": "POST", "path": "/transcribe",
        "headers": [(b"x-api-key", b"k1"), (b"content-length", str(appmod.MAX_BYTES + 1).encode())],
    }
    asyncio.run(appmod.app(scope, receive, send))
    assert sent[0]["status"] == 413


def test_preflight_allowed_origin_gets_cors_headers():
    r = client.options("/transcribe", headers={
        "Origin": "https://app.example.com",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "X-API-Key",
    })
    assert r.status_code == 200
    assert r.headers["access-control-allow-origin"] == "https://app.example.com"
    assert "x-api-key" in r.headers["access-control-allow-headers"].lower()


def test_preflight_disallowed_origin_gets_no_cors_headers():
    r = client.options("/transcribe", headers={
        "Origin": "https://evil.example",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "X-API-Key",
    })
    assert "access-control-allow-origin" not in r.headers


def test_missing_content_length_411():
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "method": "POST", "path": "/transcribe",
        "headers": [(b"x-api-key", b"k1")],
    }
    asyncio.run(appmod.app(scope, receive, send))
    assert sent[0]["status"] == 411


def test_receive_time_cap_enforced_for_lying_content_length(monkeypatch):
    # A chunked/lying client can understate Content-Length; the middleware
    # must still cut it off once the *actual* bytes received exceed the cap,
    # regardless of what the downstream app does with them. Use a trivial
    # downstream app (not the real FastAPI multipart parser) so this test
    # isolates the middleware's receive-wrapping behavior.
    monkeypatch.setattr(appmod, "MAX_BYTES", 10)
    sent = []
    chunks = iter([b"x" * 6, b"x" * 6])

    async def receive():
        chunk = next(chunks, None)
        if chunk is None:
            return {"type": "http.request", "body": b"", "more_body": False}
        return {"type": "http.request", "body": chunk, "more_body": True}

    async def send(message):
        sent.append(message)

    async def drain_body_app(scope, receive, send):
        more_body = True
        while more_body:
            message = await receive()
            more_body = message.get("more_body", False)

    guarded = appmod.UploadGuardMiddleware(drain_body_app)
    scope = {
        "type": "http", "method": "POST", "path": "/transcribe",
        "headers": [(b"x-api-key", b"k1"), (b"content-length", b"6")],
    }
    asyncio.run(guarded(scope, receive, send))
    assert sent[0]["status"] == 413
