# flex-voice — self-hosted speech-to-text service + Mac dictation client

**Date**: 2026-07-02
**Status**: Awaiting Dieter's review
**Scope**: v1 = (A) standalone Whisper STT service on the prod server + agent-platform switched to it, and (C) a thin Mac push-to-talk dictation client. TTS ("talk back") is a designed-for but out-of-scope sibling.

## Goal

One self-owned, local (self-hosted, no third-party cloud) transcription service that every Flex app can call, plus a Wispr-Flow-style desktop client so Dieter can dictate into *any* Mac app. Agent-platform is the first consumer — its existing push-to-talk UI stays, only the STT provider changes from Grok cloud to this service.

## What already exists (reused, not rebuilt)

- **agent-platform push-to-talk** is fully shipped: `VoiceRecorder.vue` + `useVoiceInput.js` → `POST /api/v1/chat/transcribe` → `voice_service.py` (currently Grok STT). The frontend is untouched by this project.
- **faster-whisper already runs on the prod server** inside agent-platform's `whisper_worker.py` (attachment transcription, `medium.en`, CPU int8, serial queue). This proves the engine on the box; flex-voice lifts the same engine into a standalone service.

## Assumptions (flag if wrong)

1. "Local" = self-hosted on the prod server (5.223.51.1), not offline-on-laptop. The Mac client needs internet.
2. Mac client v1 is a thin client of the service (no on-device model). On-device whisper.cpp is a possible v2 if offline dictation is ever needed.
3. No Wispr-Flow-style AI reformatting/tone-matching in v1 — raw Whisper transcripts. Add a post-processing LLM pass later only if raw quality annoys in practice.

## Repo layout

One repo, `~/Personal/flex-voice`:

```
flex-voice/
  service/          # FastAPI + faster-whisper (Docker, prod server)
  mac/              # Hammerspoon-based push-to-talk client (v1)
  docs/superpowers/specs/
```

## Part A — the service

**Stack**: FastAPI + faster-whisper, single container, Docker Compose on the prod server behind Traefik at `stt.flexsolutions.ph` (standard Route53 A-record recipe → 5.223.51.1).

**Endpoints**:
- `POST /transcribe` — multipart `audio` file (+ optional `language` form field, default `en`) → `{ "text": str, "duration_ms": int }`. Auth: `X-API-Key` header checked against `API_KEYS` env (comma-separated, one key per consuming app so a leaked key is revocable alone).
- `GET /health` — model loaded + version; no auth (Traefik-internal for smoke checks).
- `/tts` — **not built in v1.** Reserved path; Piper TTS slots in later without reshaping anything.

**Engine config** (env, mirrors agent-platform's proven knobs):
- `WHISPER_MODEL=small.en` — interactive latency matters; a 10 s clip ≈ 1–2 s on this CPU. `medium.en` stays available by env for accuracy-first consumers.
- `int8` compute, CPU, model cached in a named volume (downloaded on first run).
- **Serial transcription** via a global asyncio semaphore(1) — same hard requirement as the existing worker: two concurrent jobs OOM the box. Requests queue briefly rather than fork memory. `ponytail:` global lock; per-model worker pool only if real contention shows up.

**Guards**: 25 MB upload cap (413), empty upload (400), bad/missing key (401), busy-timeout returns 503 with Retry-After rather than piling up.

**Ops**: joins the existing compose/Traefik pattern on the server; logs to stdout; no DB, no state beyond the model cache — nothing to back up.

## Part A.2 — agent-platform integration (first consumer)

- New config: `VOICE_STT_PROVIDER` (`grok` | `local`, default `grok` until verified), `LOCAL_STT_URL`, `LOCAL_STT_API_KEY`.
- `voice_service.transcribe()` branches on provider: `local` → httpx multipart POST to the service, same `TranscriptionResult` shape. Grok path untouched = instant rollback via env.
- Cost `Run` row still written for `local` with `cost_usd=0.0`, `provider="flex-voice"` — keeps voice usage visible on the ledger.
- Frontend: zero changes.
- Later (separate, optional): point `whisper_worker.py` at the service too and drop the in-container model (~saves image size + RAM). Not v1.

## Part C — Mac dictation client

**v1 = Hammerspoon script + ffmpeg** (`brew install hammerspoon ffmpeg`), ~100 lines of Lua in `mac/`:

- Hold a global hotkey (default `F13`/right-⌥ — configurable at the top of the file) → start `ffmpeg -f avfoundation` mic capture to a temp file; menu-bar icon turns red.
- Release → stop capture, `hs.http` POST to `https://stt.flexsolutions.ph/transcribe`, then `hs.eventtap.keyStrokes(text)` types the transcript into whatever app has focus.
- Taps <300 ms are cancels (no accidental empty clips). Errors show a brief `hs.alert`, never type anything.
- API key + URL live in `~/.flex-voice` (chmod 600) — never in the script or repo, per the secrets rule.
- `ponytail:` Hammerspoon is the ceiling for v1 — if daily use sticks and wants a nicer UX (waveform, history, on-device model), the upgrade path is a small Swift menu-bar app against the same endpoint.

**Failure mode is benign**: worst case nothing is typed and an alert shows; there is no auto-send anywhere.

## Testing

- **Service**: pytest — auth (401), size cap (413), empty (400), happy path with the model call stubbed; plus one real end-to-end `curl` with a short wav on the server before flipping agent-platform's provider.
- **agent-platform**: existing `voice_service` tests extended with the `local` provider branch (httpx mocked). Eval gate untouched (no routing change).
- **Mac client**: manual — dictate a sentence with local vocabulary ("Dahican", "Mati") into Notes and into ai.flexsolutions.ph via the browser; verify hold/release, cancel-tap, and the error alert with the service stopped.
- **Live verification** uses a dedicated `mac-client` API key, not agent-platform's.

## Out of scope (v1)

- TTS / talk-back (Piper sibling endpoint, next iteration).
- On-device Mac whisper.cpp; Linux/Windows clients.
- Shared frontend mic component — extract from agent-platform's Vue recorder only when a second web app needs a mic.
- Wake word / always-listening; real-time streaming transcription; AI reformatting of transcripts.

## Build order

1. Service skeleton + tests → deploy to server → DNS + Traefik → real-curl verify.
2. agent-platform provider switch (PR against master, normal CI + manual deploy).
3. Mac client script → manual verify.
