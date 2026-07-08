# MicText

On-device speech-to-text — audio never leaves the machine. Embeddable STT library for the web (`npm i mictext`: Whisper in a Web Worker, WebGPU → WASM) plus reference push-to-talk dictation clients for macOS and Windows running whisper.cpp locally. Integration target: agent-platform (PR #240 was the first integration, via a vendored copy; the npm publish root-causes that). Open-source release (MIT) and the Windows client landed 2026-07-08; "push-to-type" is the planned UX direction, growing toward voice-assistant frontends (specs in `docs/superpowers/`).

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

# desktop clients (install = the whole build)
mac/install.sh                                          # Hammerspoon + ffmpeg + whisper-cpp
powershell -ExecutionPolicy Bypass -File win\install.ps1  # AutoHotkey v2 + ffmpeg + whisper.cpp
```

## Layout

- `web/` — the npm library (`mictext`). Headless `createTranscriber()` core (`src/transcriber.js` + `src/worker.js`) and `<mictext-mic>` element (`src/mic-element.js`); dep: `@huggingface/transformers`.
- `mac/` — macOS client: hold right-⌥, speak, text typed at cursor. One Hammerspoon module (`mictext.lua`) + `install.sh`.
- `win/` — Windows client: hold Right Ctrl. `mictext.ahk` (AutoHotkey v2) + `install.ps1`.
- `server/` — optional self-hosted fallback (FastAPI + faster-whisper) for the explicit `slowDevice: 'server'` opt-in only. Audio transcribed in memory, never persisted.
- `docs/superpowers/{specs,plans}/` — dated per-feature design docs.

## Gotchas

- **Dieter also commits from his Mac** — always `git pull` before starting work here, and expect the local branch to sometimes be ahead/behind.
- **No server deploy pipeline** — this ships as a library + client installs. `server/DEPLOY.md` is a one-time manual runbook (stt.flexsolutions.ph) that Dieter runs; nothing here auto-deploys.
- `navigator.gpu` presence != working WebGPU: a failed webgpu model load retries once on a fresh worker with wasm before degrading to `unsupported`/`server` (see `web/README.md`).
- The demo and tests aren't in the npm tarball (`files: ["src", "README.md"]`) — the demo needs a repo clone.
- No CI — run web + server tests locally before merge.

## Conventions

Single-line commit messages, no Co-Authored-By trailers, no AI attribution in PRs. Run `/code-review` at high effort before merging any PR.
