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
            text = " hello dahican"
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
    assert r.json() == {"text": "hello dahican", "duration_ms": 2500}


def test_health():
    r = client.get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok"
