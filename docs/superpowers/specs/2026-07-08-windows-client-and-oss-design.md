# Windows Client + Open-Source Release — Design

**Date**: 2026-07-08
**Status**: Approved
**Scope**: (1) a Windows push-to-talk dictation client mirroring `mac/`; (2) open-sourcing this repo. Explicitly **not** in scope: the voice-assistant conversation loop (wake-word, TTS, barge-in) — future spec.

## Context & Vision

flex-voice is the STT ("ears") layer of a longer-term voice-assistant direction
(agent-platform = brain, Kokoro = voice). The durable asset is the headless core
(`createTranscriber().transcribeBlob()`); dictation clients are swappable frontends
on top of it. This work adds the Windows frontend and makes the layer public —
it must not leak dictation logic into the core.

Naming: the OSS project keeps the **flex-voice** name (infrastructural,
already what agent-platform imports; npm name confirmed free). The brandable
name ("Susurra") is reserved for the future assistant, not this library.
Descriptive names (push-to-type, murmur, talktype, …) were checked and are all
taken by near-identical tools — the hold-key local-Whisper dictation niche is
saturated; the emptier niche this repo targets is the **embeddable web STT
library**, with the desktop clients as reference implementations.

## Section 1: Windows client (`win/`)

Direct mirror of `mac/` — three files, no build step, no compiled app.

### `win/flex-voice.ahk` (AutoHotkey v2, ~70 lines)

- Hold **Right Ctrl** → record; release → transcribe → type at cursor.
  - Right Ctrl, not Right Alt: Right Alt is AltGr on international layouts.
  - Hotkey + mic device are config vars at the top of the script.
- Record: `ffmpeg -f dshow -i audio="<MIC>" -ar 16000 -ac 1 <wav>` to `%TEMP%\flex-voice.wav`.
- Transcribe: `whisper-cli -m %USERPROFILE%\.flex-voice\models\ggml-base.en.bin -f <wav> -nt -np`.
- Type result with `SendText` (analog of `hs.eventtap.keyStrokes`).
- `<300ms` hold = cancel (accidental-tap guard, same threshold as mac).
- Tray icon state: 🎙 idle / 🔴 recording; transcription failure → tray tip/alert, nothing typed.
- Graceful stop: terminate ffmpeg so the wav header is finalized before transcribing
  (mac client relies on SIGTERM + exit callback; Windows needs the equivalent —
  ffmpeg `q` on stdin or a graceful-close, NOT a hard process kill).

### `win/install.ps1`

- `winget install` AutoHotkey + ffmpeg.
- whisper.cpp: download the Windows release zip from the ggerganov/whisper.cpp
  GitHub releases (not reliably on winget); place `whisper-cli.exe` on a known path.
- Model: download `ggml-base.en.bin` (~141 MB) from HuggingFace to
  `%USERPROFILE%\.flex-voice\models\` (same layout as mac).
- Startup: shortcut to the .ahk in the user's Startup folder.
- Idempotent, like `mac/install.sh`.

### `win/README.md`

Install steps, hotkey, permissions notes (mic prompt), troubleshooting, and the
same 5-test manual verification checklist as `mac/README.md`:
text app, web form at ai.flexsolutions.ph, quick-tap rejection, Wi-Fi off
(on-device proof), missing-model error handling.

### Verification constraint

No Windows machine in the dev environment. The client ships review-verified;
Dieter runs the README checklist on a real Windows box (same pending status as
the mac client's manual verify).

## Section 2: Open-source release

### Repo

- Flip `github.com/dieterstemmet/flex-voice` **public in place**. No mirror repo
  (coach-dieter-oss two-repo upkeep not worth repeating for 21 clean commits,
  single author).
- **Gate before flipping**: audit full git history and the committed
  `docs/superpowers/` specs for secrets/credentials. Server hostnames are
  acceptable; keys/tokens/credentials are not (none expected — tree is clean).

### Files added

- `LICENSE` — MIT, Dieter Stemmet.
- Top-level `README.md` — positions the project as:
  *embeddable on-device STT for the web (`web/`) + reference push-to-talk
  clients (`mac/`, `win/`) + optional self-hosted fallback server (`server/`)*.
  Includes: quick-start per component, the zero-upload guarantee, the
  headless-core/client boundary as a documented contract, and a one-paragraph
  roadmap note that this is the STT layer of a larger voice-assistant direction.
  That paragraph is the only vision footprint in this release.
- No CONTRIBUTING / CODE_OF_CONDUCT yet — add when a first contributor shows up.

### npm publish

- Publish `web/` as `flex-voice@0.1.0` (name free; package.json already
  publish-shaped: ESM exports, no build step). Add the minimal publish fields
  (license, repository, description, files).
- This root-causes the vendored-copy hack in agent-platform PR #240 — consumers
  `npm i flex-voice`. Swapping agent-platform to the npm dep is a separate
  follow-up PR, out of scope here.

### Non-goals

- No changes to `web/` or `server/` runtime code.
- No CI/release pipeline, no code signing, no compiled Windows app.
- No assistant-loop features.

## Error handling

- Windows client mirrors mac's: transcription failure alerts and types nothing;
  cancel path deletes the wav; missing model → clear error (checklist test 5).
- install.ps1 fails loudly (`$ErrorActionPreference = 'Stop'`), verifies
  whisper-cli exists before finishing.

## Testing

- `win/`: manual checklist (README) on a real Windows machine — the same bar
  the mac client is held to. No mock-Windows automation theater.
- OSS gate: history secret-scan performed and recorded in the plan execution.
- npm: `npm publish --dry-run` inspected before real publish.
