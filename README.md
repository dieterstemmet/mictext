<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" width="180" alt="MicText: a microphone whose grille is lines of text, ending in a red caret">
  </picture>
</p>

<h1 align="center">MicText</h1>

<p align="center">
  <em>Hold a key. Speak. Text appears — and your audio never leaves your machine.</em>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/mictext"><img src="https://img.shields.io/npm/v/mictext?style=flat-square&color=1A1D24&label=npm" alt="npm"></a>
  <img src="https://img.shields.io/badge/audio-never%20leaves%20your%20machine-FF4D3D?style=flat-square" alt="On-device">
  <img src="https://img.shields.io/badge/license-MIT-1A1D24?style=flat-square" alt="MIT license">
</p>

MicText is an embeddable STT library for the web plus reference
push-to-talk dictation clients for macOS and Windows, all running
[Whisper](https://github.com/ggml-org/whisper.cpp) locally. An optional
self-hosted fallback server covers devices too slow to run the model.

| Component | What it is |
| --- | --- |
| [`web/`](web/) | Browser library: Whisper in a Web Worker (WebGPU → WASM). Headless `createTranscriber()` core + `<mictext-mic>` element. `npm i mictext` |
| [`mac/`](mac/) | macOS dictation client: hold right-⌥, speak, release — text typed at the cursor (Hammerspoon + ffmpeg + whisper.cpp) |
| [`win/`](win/) | Windows dictation client: hold Right Ctrl (AutoHotkey v2 + ffmpeg + whisper.cpp) |
| [`server/`](server/) | Optional self-hosted fallback (FastAPI + faster-whisper) for the web library's explicit `slowDevice: 'server'` opt-in |

## Zero-upload guarantee

With the default configuration, no code path in this repo POSTs your audio
anywhere. The web library only GETs model files (verified end-to-end with
full network logging — see [`web/README.md`](web/README.md)); the desktop
clients work with Wi-Fi off. The single exception is the web library's
`slowDevice: 'server'` opt-in, which sends audio to a fallback URL **you**
configure — typically your own `server/` deployment.

## Quick start

**Browser** — `npm i mictext`, then:

```js
import { createTranscriber } from 'mictext'
const t = createTranscriber()
const { text } = await t.transcribeBlob(audioBlob)
```

**macOS** — `mac/install.sh`, then hold right-⌥ and speak. ([mac/README.md](mac/README.md))

**Windows** — `powershell -ExecutionPolicy Bypass -File win\install.ps1`, then hold Right Ctrl and speak. ([win/README.md](win/README.md))

## Design: headless core, swappable frontends

The durable interface is the headless transcriber
(`createTranscriber().transcribeBlob(blob)` on the web; `whisper-cli` behind
a hotkey on desktop). Dictation — "type what I said at the cursor" — is just
the first frontend. The same ears can feed a voice assistant: that's the
direction this project grows in, and why no client logic lives in the core.

## License

MIT
