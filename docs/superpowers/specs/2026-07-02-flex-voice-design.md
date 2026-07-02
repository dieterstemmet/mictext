# flex-voice — on-device speech-to-text, embeddable everywhere

**Date**: 2026-07-02 (rev 2 — on-device pivot)
**Status**: Awaiting Dieter's review
**Scope**: v1 = (W) an embeddable browser library that runs Whisper fully on-device, wired into agent-platform first, and (C) a Mac push-to-talk dictation client running whisper.cpp on-device. TTS ("talk back") is a designed-for later sibling.

## The hard constraint

**Voice audio never leaves the device it was spoken on.** Transcription runs locally wherever the mic is: in the browser for web apps, on the Mac for desktop dictation. There is no transcription server, no cloud STT, no fallback that uploads audio. The one-time *inbound* model download (cached forever after) is allowed — nothing outbound.

Corollary: the transcribed *text* belongs to the host app — in agent-platform it is sent to chat exactly like typed text. The privacy boundary is the audio.

## What this replaces

- agent-platform's shipped push-to-talk currently uploads audio to `POST /api/v1/chat/transcribe` → **Grok cloud STT** (`voice_service.py`). That path violates the constraint and gets retired once the web library is proven.
- The rev-1 idea of a server-side `stt.flexsolutions.ph` service is dead — deliberately, per the constraint.
- agent-platform's `whisper_worker.py` (server-side faster-whisper for *uploaded audio file attachments*) is out of scope: those files were already deliberately uploaded by the user; transcribing them server-side doesn't leak anything new.

## Repo layout

One repo, `~/Personal/flex-voice`:

```
flex-voice/
  web/              # embeddable JS library — on-device Whisper in the browser
  mac/              # Mac push-to-talk client — whisper.cpp on-device
  docs/superpowers/specs/
```

## Part W — browser library (`flex-voice/web`)

**Engine**: Whisper via `@huggingface/transformers` (transformers.js) in a **Web Worker** — WebGPU when available, WASM fallback. Battle-tested (this is what whisper-web is built on), no server component.

**Model**: `whisper-base.en` quantized (~40 MB) as the default — the interactive sweet spot. `tiny.en` (~20 MB) selectable for weak devices, `small.en` for accuracy. Downloaded once, cached by the browser (Cache API), so it's a one-time cost per device. Model files fetched from HF CDN by default; each app *may* self-host the model files as static assets for full CDN independence — supported via a `modelBaseUrl` option, not required for v1.

**Public API** — two layers so apps with existing UI aren't forced into ours:

1. **Headless core** (what agent-platform uses):
   ```js
   const t = await createTranscriber({ model?, language?, modelBaseUrl?, onProgress? })
   t.start()                    // begins mic capture (getUserMedia)
   const { text } = await t.stop()   // ends capture, resolves transcript
   t.state                      // 'loading-model' | 'idle' | 'recording' | 'transcribing'
   ```
2. **Drop-in element** `<flex-voice-mic>` (framework-agnostic web component wrapping the core): hold-to-record button, fires a `transcript` CustomEvent. This is the "embed in any future app" one-liner — Buhaton, customer-to-kitchen, etc.

**Packaging**: plain npm package in the repo, consumed via a local file/git dependency by his apps (no public npm publish needed for v1). `ponytail:` no bundler gymnastics — ship ESM only; every consumer is a modern Vite app.

**Honest limits (accepted, price of the constraint)**:
- First use per device downloads the model (~40 MB) and shows a progress state — the API's `loading-model` state and `onProgress` exist for exactly this.
- Low-end Android (Buhaton crew phones) on WASM will transcribe slower than real-time-ish for long clips; short push-to-talk utterances stay tolerable on `tiny.en`. If it's ever too slow in the field, the escape hatch is a smaller/distilled model — never a server.
- English models default; multilingual = config, not UI, for now.

## Part W.2 — agent-platform integration (first consumer)

- `useVoiceInput.js` swaps its internals: instead of POSTing the blob to `/chat/transcribe`, it calls the headless `createTranscriber()` from `flex-voice/web`. `VoiceRecorder.vue` (button, states, gestures) is unchanged; its `transcribing` state maps onto model-loading + inference.
- Transcript still lands in the composer as editable text, never auto-sends — behavior identical, provider now on-device.
- Backend: `POST /chat/transcribe`, `voice_service.py`, and the `VOICE_*` Grok config are retired in a follow-up PR once the browser path is live-verified (kept during transition as an env-gated fallback, then deleted — no dead code left).
- No cost `Run` rows anymore — on-device costs $0 and touches no provider. Voice disappears from the spend ledger by design.

## Part C — Mac dictation client (`flex-voice/mac`)

**v1 = Hammerspoon + whisper.cpp**, fully on-device (`brew install hammerspoon whisper-cpp ffmpeg`), ~100 lines of Lua:

- Hold a global hotkey (default right-⌥, configurable at the top of the file) → `ffmpeg -f avfoundation` mic capture to a temp wav; menu-bar icon turns red.
- Release → run `whisper-cli` (Metal-accelerated on Apple Silicon, `base.en` model, ~real-time or faster) → `hs.eventtap.keyStrokes(text)` types the transcript into whatever app has focus. Temp wav deleted immediately after.
- Taps <300 ms cancel. Errors show a brief `hs.alert`, never type anything. No network access at all.
- Model file lives at `~/.flex-voice/models/` (one-time `whisper-cli` download or curl in the install script).
- `ponytail:` Hammerspoon is the v1 ceiling — upgrade path is a small Swift menu-bar app (nicer UX, waveform, streaming) against the same whisper.cpp, only if daily use earns it.

**Failure mode is benign**: worst case nothing is typed and an alert shows; no auto-send anywhere.

## TTS / talk-back (out of scope, designed for)

Same constraint applies later: on-device synthesis — Piper (WASM build exists) in the browser, `say`/Piper on the Mac. The web library reserves a `createSpeaker()` sibling; nothing in v1 blocks it.

## Testing

- **web**: vitest with the worker + transformers mocked — state machine, start/stop produces audio → transcript, error paths. One real browser check (per browser-testing convention): Playwright/Chrome against a demo page in `web/` — hold, speak, release, assert text appears; verify the network tab shows **zero uploads** (model download only).
- **agent-platform**: existing `useVoiceInput` specs rewired to mock the library; manual live check on ai.flexsolutions.ph with the playwright-bot account — dictate "Dahican", confirm composer fills, confirm no `/transcribe` request fires.
- **mac**: manual — dictate into Notes and into the browser; verify cancel-tap, error alert, and (with Wi-Fi off) that dictation still works — the on-device proof.

## Out of scope (v1)

- TTS / talk-back; wake word / always-listening; streaming partial transcripts.
- Windows/Linux desktop clients.
- Retiring `whisper_worker.py` (attachment transcription) — separate concern, unaffected.
- AI reformatting of transcripts (Wispr-Flow-style tone matching).
- Public npm publish, versioning ceremony, CI for the lib — add when a second app consumes it.

## Build order

1. `web/` library + demo page → browser-verified (including the zero-upload check).
2. agent-platform PR: swap `useVoiceInput` internals; backend voice path env-gated off.
3. Mac client + manual verify (Wi-Fi-off test).
4. Follow-up agent-platform PR: delete the Grok voice path.
