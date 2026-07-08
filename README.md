# flex-voice

On-device speech-to-text. Your audio never leaves your machine.

flex-voice is an embeddable STT library for the web plus reference
push-to-talk dictation clients for macOS and Windows, all running
[Whisper](https://github.com/ggml-org/whisper.cpp) locally. An optional
self-hosted fallback server covers devices too slow to run the model.

| Component | What it is |
| --- | --- |
| [`web/`](web/) | Browser library: Whisper in a Web Worker (WebGPU → WASM). Headless `createTranscriber()` core + `<flex-voice-mic>` element. `npm i flex-voice` |
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

**Browser** — `npm i flex-voice`, then:

```js
import { createTranscriber } from 'flex-voice'
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
