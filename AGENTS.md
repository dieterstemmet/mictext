# MicText

On-device speech-to-text — audio never leaves the machine. Embeddable STT library for the web (`npm i mictext`: Whisper in a Web Worker, WebGPU → WASM) plus reference push-to-talk dictation clients for macOS and Windows running whisper.cpp locally. Open-source release (MIT) and the Windows client landed 2026-07-08; "push-to-type" is the planned UX direction, growing toward voice-assistant frontends.

**Privacy is the product.** With defaults, no code path here POSTs audio or transcripts anywhere — only GETs model files (verified with full network logging, see `web/README.md`). Any change that sends audio or transcripts off-device is a design violation — flag it. Sole exception: the web library's explicit `slowDevice: 'server'` opt-in to a fallback URL the user configures.

## Commands

```bash
# web/ — the only package.json in the repo
cd web && npm test                  # vitest run (3 spec files in test/)
cd web && npx vite --port 5199      # demo at /demo/index.html (vite required; plain static server can't resolve bare imports)
npm pack --dry-run                  # tarball must list only src/, README.md, package.json

# server/ — no venv checked in, create one first
cd server && python -m venv .venv && .venv/bin/pip install -r requirements.txt pytest httpx
cd server && .venv/bin/python -m pytest test_app.py -q

# desktop clients
mac/install.sh                                          # Hammerspoon + ffmpeg + whisper-cpp
powershell -ExecutionPolicy Bypass -File win\install.ps1  # AutoHotkey v2 + ffmpeg + whisper.cpp
powershell -ExecutionPolicy Bypass -File win\config.ps1   # mic / hotkey / model CLI (tray Settings is the GUI)
powershell -NoProfile -ExecutionPolicy Bypass -File win\build.ps1  # portable offline Windows ZIP
powershell -NoProfile -ExecutionPolicy Bypass -File win\test\settings.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File win\test\capture.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File win\test\transcription.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File win\test\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File win\test\package.ps1
```

## Layout

- `web/` — the npm library (`mictext`). Headless `createTranscriber()` core (`src/transcriber.js` + `src/worker.js`) and `<mictext-mic>` element (`src/mic-element.js`); dep: `@huggingface/transformers`.
- `mac/` — macOS client: hold right-⌥, speak, text typed at cursor. One Hammerspoon module (`mictext.lua`) + `install.sh`.
- `win/` — Windows client: hold Right Ctrl. `mictext.ahk` (AutoHotkey v2) + `install.ps1` + `config.ps1` + `icons/`. Tray Settings writes `%USERPROFILE%\.mictext\config.ini`.
- `server/` — optional self-hosted fallback (FastAPI + faster-whisper) for the explicit `slowDevice: 'server'` opt-in only. Audio transcribed in memory, never persisted.

## Gotchas

- **Dieter also commits from his Mac** — always `git pull` before starting work here, and expect the local branch to sometimes be ahead/behind.
- **No server deploy pipeline** — this ships as a library + client installs. `server/DEPLOY.md` is a one-time manual runbook; nothing here auto-deploys.
- `navigator.gpu` presence != working WebGPU: a failed webgpu model load retries once on a fresh worker with wasm before degrading to `unsupported`/`server` (see `web/README.md`).
- The demo and tests aren't in the npm tarball (`files: ["src", "README.md"]`) — the demo needs a repo clone.
- No CI — run web + server tests locally before merge.
- **The silence-gate and vocabulary logic is triplicated on purpose** — `web/src/silence.js` and `web/src/terms.js` are the tested reference; `mac/mictext.lua` and `win/mictext.ahk` are hand-ports of them. There is no shared runtime. Windows has PowerShell-driven AHK tests with synthetic audio; Lua has no harness. Keep behavior changes in sync across all three ports. The web-only bits (`framesForRate`, the suspended-`AudioContext` handling) do NOT apply to the desktop clients — astats is fixed-rate; each `silence.js` note says which.

## Conventions

Follow the standing commit/PR rules. Run built-in code review before merging any PR.

## Windows capture and packaging

- The compiled EXE resolves tools/icons/models beside itself; personal settings and vocabulary stay in `%USERPROFILE%\.mictext`. Extra personal models remain available.
- `win/package-manifest.json` pins every downloaded build input by SHA-256. Outputs and cached archives are ignored under `dist/windows` and `.build/windows`. Package only curated public files; never copy the installed config, vocabulary or recorded audio.
- Keep `CaptureInput(mic)` shared by dictation and mic preview. Its DirectShow input requests a 50 ms buffer. `win/test/latency.ps1 -MicName "Device name"` measures startup using level metadata only.
- Capture process creation and meter initialization must complete before a release callback can run. Keep that setup critical, and keep capture/inference outside the critical section.
- `processing` owns audio until stop/transcription cleanup finishes. Neither a new hold, mic preview nor a cancel/settings callback may overwrite or delete its input.
- Recovery tests inject delayed startup, omit key-up callbacks, crash capture, advance the inactivity deadline, and exercise cancellation with modifiers held and repeat key-downs. They control the key-state and audio-input adapters; process/UI cleanup runs normally. Do not make them depend on a background process retaining injected Windows key state. Update the adapters when changing their interfaces.
- `test/package.ps1` runs the built EXE with an empty profile, paths containing spaces, and a Windows-only PATH. It includes the capture lifecycle and full synthetic transcription checks. No physical audio is saved by these automatic checks.
