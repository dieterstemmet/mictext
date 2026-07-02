# flex-voice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On-device speech-to-text everywhere: a browser library (Whisper via transformers.js in a web worker) embedded into agent-platform first, a Mac push-to-talk client (whisper.cpp), and an opt-in self-hosted server fallback for slow devices.

**Architecture:** `web/` is a dependency-light ESM package: a web worker runs the Whisper pipeline; a headless `createTranscriber()` exposes `transcribeBlob()` plus a slow-device policy (`disable` default, `server` = POST to our own prod service); a `<flex-voice-mic>` web component wraps it for one-line embeds. agent-platform keeps its existing `VoiceRecorder.vue`/`useVoiceInput.js` mic capture and swaps only the transcription step. `mac/` is ~100 lines of Hammerspoon Lua shelling to ffmpeg + whisper-cli. `server/` is a single-file FastAPI + faster-whisper service behind Traefik.

**Tech Stack:** `@huggingface/transformers` (transformers.js v3), Web Workers, WebGPU/WASM, vitest; Hammerspoon + ffmpeg + whisper.cpp; FastAPI + faster-whisper + Docker/Traefik.

## Global Constraints

- **Audio never leaves the device** except in explicitly configured `slowDevice: 'server'` mode, and then only to Dieter's own server. No third-party STT anywhere. Model downloads (inbound) are allowed and cached.
- Default browser model: `onnx-community/whisper-base.en` (q8). Slow-device benchmark threshold: 5000 ms for 1 s of audio.
- Mac model: `ggml-base.en.bin`. Mac client makes zero network calls.
- Server fallback: `X-API-Key` auth, 25 MB cap, serial semaphore(1), `POST /transcribe` → `{"text": str, "duration_ms": int}`, deployed at `stt.flexsolutions.ph`.
- Commits: **single-line messages, no Co-Authored-By, no AI attribution** (Dieter's standing rule — overrides any tool default).
- agent-platform changes go on a branch → PR against master (CI builds + tests); never push master directly.
- Secrets (fallback API keys) never in code or chat; Dieter drops them into prod `.env` himself.
- Plain JS (no TypeScript) in `web/`, matching agent-platform's frontend. ESM only.

---

## Phase 1 — `web/` library (repo: `~/Personal/flex-voice`)

### Task 1: Package scaffold + audio decode util

**Files:**
- Create: `web/package.json`, `web/vitest.config.js`, `web/src/audio.js`
- Test: `web/test/audio.spec.js`

**Interfaces:**
- Produces: `blobToPcm(blob) -> Promise<Float32Array>` — 16 kHz mono PCM, used by Task 2's `transcribeBlob` and Task 3's benchmark.

- [ ] **Step 1: Scaffold the package**

`web/package.json`:
```json
{
  "name": "flex-voice",
  "version": "0.1.0",
  "type": "module",
  "exports": {
    ".": "./src/index.js",
    "./mic": "./src/mic-element.js"
  },
  "scripts": { "test": "vitest run" },
  "dependencies": { "@huggingface/transformers": "^3.5.0" },
  "devDependencies": { "vitest": "^3.0.0", "happy-dom": "^17.0.0" }
}
```

`web/vitest.config.js`:
```js
export default { test: { environment: 'happy-dom' } }
```

Run: `cd ~/Personal/flex-voice/web && npm install`
Expected: lockfile created, no errors.

- [ ] **Step 2: Write the failing test**

`web/test/audio.spec.js`:
```js
import { describe, it, expect, vi } from 'vitest'
import { blobToPcm } from '../src/audio.js'

describe('blobToPcm', () => {
  it('decodes a blob to 16kHz mono Float32Array and closes the context', async () => {
    const pcm = new Float32Array(16000)
    const close = vi.fn().mockResolvedValue()
    globalThis.AudioContext = vi.fn(function ({ sampleRate }) {
      expect(sampleRate).toBe(16000)
      this.decodeAudioData = vi.fn().mockResolvedValue({ getChannelData: () => pcm })
      this.close = close
    })
    const blob = new Blob([new Uint8Array([1, 2, 3])])
    const out = await blobToPcm(blob)
    expect(out).toBe(pcm)
    expect(close).toHaveBeenCalled()
  })

  it('closes the context even when decode fails', async () => {
    const close = vi.fn().mockResolvedValue()
    globalThis.AudioContext = vi.fn(function () {
      this.decodeAudioData = vi.fn().mockRejectedValue(new Error('bad audio'))
      this.close = close
    })
    await expect(blobToPcm(new Blob([new Uint8Array([1])]))).rejects.toThrow('bad audio')
    expect(close).toHaveBeenCalled()
  })
})
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npm test`
Expected: FAIL — cannot resolve `../src/audio.js`.

- [ ] **Step 4: Implement**

`web/src/audio.js`:
```js
// Decode any browser-recorded blob (webm/opus etc.) to the 16 kHz mono
// Float32Array Whisper expects. AudioContext resamples during decode.
export async function blobToPcm(blob) {
  const ctx = new AudioContext({ sampleRate: 16000 })
  try {
    const buf = await ctx.decodeAudioData(await blob.arrayBuffer())
    return buf.getChannelData(0)
  } finally {
    await ctx.close()
  }
}
```

- [ ] **Step 5: Run tests — expect PASS, then commit**

```bash
git add web && git commit -m "web: package scaffold + blobToPcm audio decode"
```

### Task 2: Worker + headless createTranscriber core

**Files:**
- Create: `web/src/worker.js`, `web/src/transcriber.js`, `web/src/index.js`
- Test: `web/test/transcriber.spec.js`

**Interfaces:**
- Consumes: `blobToPcm` (Task 1).
- Produces (used by Tasks 3–6):
  ```js
  const t = createTranscriber({
    model = 'onnx-community/whisper-base.en',
    modelBaseUrl = null,          // self-hosted model files (sets localModelPath)
    onProgress = null,            // (fractionOrFileProgress) => void during model download
    slowDevice = 'disable',       // 'disable' | 'server'   (Task 3)
    fallbackUrl = null,           // required when slowDevice === 'server'
    fallbackApiKey = null,
    slowThresholdMs = 5000,
    createWorker = () => new Worker(new URL('./worker.js', import.meta.url), { type: 'module' }),
  })
  t.state          // 'idle' | 'loading-model' | 'transcribing' | 'unsupported'
  t.mode           // 'device' | 'server' | 'unsupported'  (settles after first load)
  await t.load()   // idempotent; downloads/initializes model, runs benchmark
  await t.transcribeBlob(blob)  // -> { text }  (lazy-loads on first call)
  t.dispose()      // terminates the worker
  ```

- [ ] **Step 1: Write the worker (no unit test — exercised via Task 5's real-browser check; its protocol is tested through the core with a fake worker)**

`web/src/worker.js`:
```js
import { pipeline, env } from '@huggingface/transformers'

let asr = null

self.onmessage = async ({ data }) => {
  try {
    if (data.type === 'load') {
      if (data.modelBaseUrl) {
        env.allowRemoteModels = false
        env.localModelPath = data.modelBaseUrl
      }
      asr = await pipeline('automatic-speech-recognition', data.model, {
        dtype: 'q8',
        device: data.device, // 'webgpu' | 'wasm'
        progress_callback: (p) => self.postMessage({ type: 'progress', progress: p }),
      })
      self.postMessage({ type: 'ready' })
    } else if (data.type === 'transcribe') {
      const t0 = performance.now()
      const out = await asr(data.audio)
      self.postMessage({
        type: 'result',
        text: (out.text || '').trim(),
        elapsedMs: performance.now() - t0,
      })
    }
  } catch (e) {
    self.postMessage({ type: 'error', message: String((e && e.message) || e) })
  }
}
```

- [ ] **Step 2: Write the failing tests**

`web/test/transcriber.spec.js`:
```js
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createTranscriber } from '../src/transcriber.js'

// Minimal fake worker implementing the load/transcribe protocol.
function fakeWorker({ elapsedMs = 100, failLoad = false } = {}) {
  const w = {
    onmessage: null,
    terminated: false,
    postMessage(msg) {
      queueMicrotask(() => {
        if (msg.type === 'load') {
          w.onmessage({ data: failLoad ? { type: 'error', message: 'no backend' } : { type: 'ready' } })
        } else if (msg.type === 'transcribe') {
          w.onmessage({ data: { type: 'result', text: 'hello dahican', elapsedMs } })
        }
      })
    },
    terminate() { w.terminated = true },
  }
  return w
}

beforeEach(() => {
  globalThis.AudioContext = vi.fn(function () {
    this.decodeAudioData = vi.fn().mockResolvedValue({ getChannelData: () => new Float32Array(16000) })
    this.close = vi.fn().mockResolvedValue()
  })
})

describe('createTranscriber', () => {
  it('lazy-loads on first transcribeBlob and returns text', async () => {
    const t = createTranscriber({ createWorker: () => fakeWorker() })
    expect(t.state).toBe('idle')
    const { text } = await t.transcribeBlob(new Blob([new Uint8Array([1])]))
    expect(text).toBe('hello dahican')
    expect(t.mode).toBe('device')
    expect(t.state).toBe('idle')
  })

  it('load() is idempotent (one worker, one load message)', async () => {
    const workers = []
    const t = createTranscriber({ createWorker: () => { const w = fakeWorker(); workers.push(w); return w } })
    await Promise.all([t.load(), t.load()])
    await t.load()
    expect(workers.length).toBe(1)
  })

  it('worker load error -> mode unsupported when slowDevice=disable', async () => {
    const t = createTranscriber({ createWorker: () => fakeWorker({ failLoad: true }) })
    await t.load()
    expect(t.mode).toBe('unsupported')
    expect(t.state).toBe('unsupported')
    await expect(t.transcribeBlob(new Blob([new Uint8Array([1])]))).rejects.toThrow(/unsupported/)
  })

  it('dispose terminates the worker', async () => {
    const w = fakeWorker()
    const t = createTranscriber({ createWorker: () => w })
    await t.load()
    t.dispose()
    expect(w.terminated).toBe(true)
  })
})
```

- [ ] **Step 3: Run tests — expect FAIL** (`createTranscriber` not defined).

- [ ] **Step 4: Implement**

`web/src/transcriber.js`:
```js
import { blobToPcm } from './audio.js'

const BENCH_SECONDS = 1

export function createTranscriber(opts = {}) {
  const {
    model = 'onnx-community/whisper-base.en',
    modelBaseUrl = null,
    onProgress = null,
    slowDevice = 'disable',
    fallbackUrl = null,
    fallbackApiKey = null,
    slowThresholdMs = 5000,
    createWorker = () => new Worker(new URL('./worker.js', import.meta.url), { type: 'module' }),
  } = opts

  if (slowDevice === 'server' && !fallbackUrl) {
    throw new Error("slowDevice: 'server' requires fallbackUrl")
  }

  let worker = null
  let loadPromise = null
  const t = { state: 'idle', mode: 'device' }

  // One in-flight request at a time; the worker is serial anyway.
  function request(msg, transfer) {
    return new Promise((resolve, reject) => {
      worker.onmessage = ({ data }) => {
        if (data.type === 'progress') { if (onProgress) onProgress(data.progress); return }
        if (data.type === 'error') reject(new Error(data.message))
        else resolve(data)
      }
      worker.postMessage(msg, transfer)
    })
  }

  async function benchmark() {
    const silence = new Float32Array(16000 * BENCH_SECONDS)
    const { elapsedMs } = await request(
      { type: 'transcribe', audio: silence }, [silence.buffer],
    )
    return elapsedMs
  }

  function degrade() {
    // Device can't run the model (or is too slow): apply the policy.
    if (worker) { worker.terminate(); worker = null }
    t.mode = slowDevice === 'server' ? 'server' : 'unsupported'
    t.state = t.mode === 'unsupported' ? 'unsupported' : 'idle'
  }

  t.load = function load() {
    if (loadPromise) return loadPromise
    loadPromise = (async () => {
      t.state = 'loading-model'
      try {
        worker = createWorker()
        const device = typeof navigator !== 'undefined' && navigator.gpu ? 'webgpu' : 'wasm'
        await request({ type: 'load', model, modelBaseUrl, device })
        if ((await benchmark()) > slowThresholdMs) degrade()
        else t.state = 'idle'
      } catch (e) {
        degrade()
      }
    })()
    return loadPromise
  }

  async function serverTranscribe(blob) {
    const form = new FormData()
    form.append('audio', blob, 'clip.webm')
    const r = await fetch(`${fallbackUrl}/transcribe`, {
      method: 'POST',
      headers: { 'X-API-Key': fallbackApiKey },
      body: form,
    })
    if (!r.ok) throw new Error(`fallback transcription failed (${r.status})`)
    return { text: (await r.json()).text || '' }
  }

  t.transcribeBlob = async function transcribeBlob(blob) {
    await t.load()
    if (t.mode === 'unsupported') throw new Error('transcription unsupported on this device')
    if (t.mode === 'server') return serverTranscribe(blob)
    t.state = 'transcribing'
    try {
      const audio = await blobToPcm(blob)
      const { text } = await request({ type: 'transcribe', audio }, [audio.buffer])
      return { text }
    } finally {
      if (t.state === 'transcribing') t.state = 'idle'
    }
  }

  t.dispose = function dispose() {
    if (worker) { worker.terminate(); worker = null }
    loadPromise = null
  }

  return t
}
```

`web/src/index.js`:
```js
export { createTranscriber } from './transcriber.js'
export { blobToPcm } from './audio.js'
```

- [ ] **Step 5: Run tests — expect PASS, then commit**

```bash
git add web && git commit -m "web: worker + headless createTranscriber core"
```

### Task 3: Slow-device policy tests (benchmark → disable / server fallback)

**Files:**
- Modify: `web/test/transcriber.spec.js` (append tests; implementation from Task 2 should already satisfy them — this task pins the policy behavior)

**Interfaces:**
- Consumes: `createTranscriber` (Task 2), including its `fakeWorker`.

- [ ] **Step 1: Write the tests**

Append to `web/test/transcriber.spec.js`:
```js
describe('slow-device policy', () => {
  it("slow benchmark + slowDevice 'disable' -> unsupported", async () => {
    const t = createTranscriber({ createWorker: () => fakeWorker({ elapsedMs: 9999 }) })
    await t.load()
    expect(t.mode).toBe('unsupported')
  })

  it("slow benchmark + slowDevice 'server' -> POSTs blob to fallbackUrl", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ text: 'from server', duration_ms: 1200 }),
    })
    const t = createTranscriber({
      createWorker: () => fakeWorker({ elapsedMs: 9999 }),
      slowDevice: 'server',
      fallbackUrl: 'https://stt.flexsolutions.ph',
      fallbackApiKey: 'k1',
    })
    const { text } = await t.transcribeBlob(new Blob([new Uint8Array([1])]))
    expect(text).toBe('from server')
    const [url, init] = globalThis.fetch.mock.calls[0]
    expect(url).toBe('https://stt.flexsolutions.ph/transcribe')
    expect(init.headers['X-API-Key']).toBe('k1')
    expect(init.body).toBeInstanceOf(FormData)
  })

  it("slowDevice 'server' without fallbackUrl throws at creation", () => {
    expect(() => createTranscriber({ slowDevice: 'server' })).toThrow(/fallbackUrl/)
  })

  it('fast benchmark stays on-device and never calls fetch', async () => {
    globalThis.fetch = vi.fn()
    const t = createTranscriber({ createWorker: () => fakeWorker({ elapsedMs: 100 }), slowDevice: 'server', fallbackUrl: 'https://x', fallbackApiKey: 'k' })
    await t.transcribeBlob(new Blob([new Uint8Array([1])]))
    expect(globalThis.fetch).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run tests** — expect PASS (Task 2 implemented the policy). If any fail, fix `transcriber.js` until green.

- [ ] **Step 3: Commit**

```bash
git add web && git commit -m "web: pin slow-device policy behavior with tests"
```

### Task 4: `<flex-voice-mic>` web component

**Files:**
- Create: `web/src/mic-element.js`
- Test: `web/test/mic-element.spec.js`

**Interfaces:**
- Consumes: `createTranscriber` (Task 2).
- Produces: custom element `<flex-voice-mic>`; attributes `model`, `fallback-url`, `fallback-api-key`, `slow-device`; property `transcriberOptions` (object, overrides attributes); fires `transcript` CustomEvent with `detail: { text }`, and `voice-error` with `detail: { message }`. Hides itself (`hidden = true`) when the device is unsupported.

- [ ] **Step 1: Write the failing tests**

`web/test/mic-element.spec.js`:
```js
import { describe, it, expect, vi, beforeEach } from 'vitest'

const transcriber = {
  state: 'idle',
  mode: 'device',
  load: vi.fn().mockResolvedValue(),
  transcribeBlob: vi.fn().mockResolvedValue({ text: 'hi' }),
  dispose: vi.fn(),
}
vi.mock('../src/transcriber.js', () => ({ createTranscriber: vi.fn(() => transcriber) }))

// Import AFTER the mock so the element sees the mocked factory.
await import('../src/mic-element.js')

function fakeMedia() {
  const track = { stop: vi.fn() }
  globalThis.navigator.mediaDevices = {
    getUserMedia: vi.fn().mockResolvedValue({ getTracks: () => [track] }),
  }
  globalThis.MediaRecorder = vi.fn(function () {
    this.start = vi.fn()
    this.stop = vi.fn(() => {
      this.ondataavailable({ data: new Blob([new Uint8Array([1])]) })
      this.onstop()
    })
  })
}

describe('<flex-voice-mic>', () => {
  beforeEach(() => {
    document.body.innerHTML = ''
    transcriber.mode = 'device'
    fakeMedia()
  })

  it('hold -> release emits a transcript event', async () => {
    const el = document.createElement('flex-voice-mic')
    document.body.appendChild(el)
    const got = new Promise((res) => el.addEventListener('transcript', (e) => res(e.detail.text)))
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 350)) // past the 300ms cancel window
    el.dispatchEvent(new Event('pointerup'))
    expect(await got).toBe('hi')
  })

  it('short tap (<300ms) cancels without transcribing', async () => {
    const el = document.createElement('flex-voice-mic')
    document.body.appendChild(el)
    el.dispatchEvent(new Event('pointerdown'))
    el.dispatchEvent(new Event('pointerup'))
    await new Promise((r) => setTimeout(r, 10))
    expect(transcriber.transcribeBlob).not.toHaveBeenCalled()
  })

  it('hides itself when transcriber mode is unsupported', async () => {
    transcriber.mode = 'unsupported'
    const el = document.createElement('flex-voice-mic')
    document.body.appendChild(el)
    await new Promise((r) => setTimeout(r, 10))
    expect(el.hidden).toBe(true)
  })
})
```

- [ ] **Step 2: Run tests — expect FAIL** (element not registered).

- [ ] **Step 3: Implement**

`web/src/mic-element.js`:
```js
import { createTranscriber } from './transcriber.js'

const CANCEL_MS = 300

class FlexVoiceMic extends HTMLElement {
  connectedCallback() {
    this.attachShadow({ mode: 'open' }).innerHTML = `
      <style>
        button { border: none; border-radius: 50%; width: 2.5rem; height: 2.5rem;
                 cursor: pointer; background: #eee; font-size: 1.1rem; }
        button.recording { background: #e33; }
        button:disabled { opacity: .5; cursor: default; }
      </style>
      <button type="button" title="Hold to talk">🎤</button>`
    this._btn = this.shadowRoot.querySelector('button')

    const opts = this.transcriberOptions || {
      model: this.getAttribute('model') || undefined,
      slowDevice: this.getAttribute('slow-device') || undefined,
      fallbackUrl: this.getAttribute('fallback-url') || undefined,
      fallbackApiKey: this.getAttribute('fallback-api-key') || undefined,
    }
    this._t = createTranscriber(opts)
    // Kick off the (cached) model load early, hide if the device can't run it.
    this._t.load().then(() => { if (this._t.mode === 'unsupported') this.hidden = true })

    this.addEventListener('pointerdown', () => this._start())
    this.addEventListener('pointerup', () => this._stop())
    this.addEventListener('pointerleave', () => this._stop())
  }

  disconnectedCallback() { if (this._t) this._t.dispose() }

  async _start() {
    this._downAt = Date.now()
    this._chunks = []
    try {
      this._stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      this._emitError('Microphone unavailable')
      return
    }
    this._rec = new MediaRecorder(this._stream)
    this._rec.ondataavailable = (ev) => { if (ev.data && ev.data.size) this._chunks.push(ev.data) }
    this._rec.start()
    this._btn.classList.add('recording')
  }

  async _stop() {
    if (!this._rec) return
    const rec = this._rec
    this._rec = null
    this._btn.classList.remove('recording')
    const stopped = new Promise((res) => { rec.onstop = res; setTimeout(res, 5000) })
    rec.stop()
    await stopped
    if (this._stream) { this._stream.getTracks().forEach((t) => t.stop()); this._stream = null }
    if (Date.now() - this._downAt < CANCEL_MS) return // cancel tap
    try {
      this._btn.disabled = true
      const { text } = await this._t.transcribeBlob(new Blob(this._chunks, { type: 'audio/webm' }))
      if (text) this.dispatchEvent(new CustomEvent('transcript', { detail: { text }, bubbles: true }))
    } catch (e) {
      this._emitError(e.message)
    } finally {
      this._btn.disabled = false
    }
  }

  _emitError(message) {
    this.dispatchEvent(new CustomEvent('voice-error', { detail: { message }, bubbles: true }))
  }
}

if (!customElements.get('flex-voice-mic')) customElements.define('flex-voice-mic', FlexVoiceMic)
```

- [ ] **Step 4: Run tests — expect PASS, then commit**

```bash
git add web && git commit -m "web: flex-voice-mic hold-to-talk web component"
```

### Task 5: Demo page + real-browser verification

**Files:**
- Create: `web/demo/index.html`, `web/README.md`

**Interfaces:**
- Consumes: `<flex-voice-mic>` (Task 4).

- [ ] **Step 1: Demo page**

`web/demo/index.html`:
```html
<!doctype html>
<meta charset="utf-8">
<title>flex-voice demo</title>
<script type="module">
  import '../src/mic-element.js'
  const out = () => document.querySelector('#out')
  addEventListener('transcript', (e) => { out().value += (out().value ? ' ' : '') + e.detail.text })
  addEventListener('voice-error', (e) => alert(e.detail.message))
</script>
<h1>flex-voice</h1>
<p>Hold the mic, speak, release. Audio never leaves this device.</p>
<flex-voice-mic></flex-voice-mic>
<textarea id="out" rows="6" cols="60"></textarea>
```

- [ ] **Step 2: Serve and verify in a real browser (per browser-testing convention: Playwright/Chrome DevTools MCP)**

```bash
cd ~/Personal/flex-voice/web && npx vite --port 5199
```
Vite is needed (not a plain static server) to resolve the bare `@huggingface/transformers` import; it's already a transitive dev tool — do not add it to `dependencies`.

Checklist (fake mic input is fine: launch Chrome with `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream`, or use a real mic if available):
- Model download progress happens once; reload → served from cache.
- Hold → button red; release → text lands in the textarea.
- **Zero-upload check**: DevTools Network tab shows only model-file GETs (huggingface.co / cache) — no POST anywhere.
- Short tap does nothing.

- [ ] **Step 3: Write `web/README.md`** — usage for both layers (copy the Interfaces block from Task 2 + a `<flex-voice-mic>` snippet from the demo), the slow-device policy table (`disable`/`server`), and the model-download note (~40 MB once per device).

- [ ] **Step 4: Commit**

```bash
git add web && git commit -m "web: demo page + README, browser-verified"
```

---

## Phase 2 — agent-platform integration (repo: `~/Personal/agent-platform`, branch + PR)

### Task 6: Swap useVoiceInput internals to on-device

**Files:**
- Create: `frontend/src/lib/flexvoice/` — vendored copy of `web/src/{audio.js,transcriber.js,worker.js,index.js}`
- Modify: `frontend/src/composables/useVoiceInput.js`, `frontend/src/components/VoiceRecorder.vue`, `frontend/package.json`
- Delete: `frontend/src/api/voice.js`
- Test: `frontend/src/composables/__tests__/useVoiceInput.spec.js` (rewire), `frontend/src/components/__tests__/VoiceRecorder.spec.js` (extend)

**Interfaces:**
- Consumes: `createTranscriber` from the vendored lib (exact API in Task 2).
- Produces: `useVoiceInput()` keeps its exact public shape `{ isRecording, isTranscribing, permissionDenied, error, start, stop }` **plus a new `unsupported` ref**; `VoiceRecorder.vue` hides when `unsupported` is true.

> `ponytail:` vendored copy, not an npm dependency — the prod Docker build context is `./frontend` only, so a `file:` dep outside it can't build. Canonical source stays in flex-voice; publish properly when a second app consumes it.

- [ ] **Step 1: Branch + vendor**

```bash
cd ~/Personal/agent-platform && git checkout master && git pull && git checkout -b feat/on-device-voice
mkdir -p frontend/src/lib/flexvoice
cp ~/Personal/flex-voice/web/src/{audio.js,transcriber.js,worker.js,index.js} frontend/src/lib/flexvoice/
cd frontend && npm install @huggingface/transformers
```
Add a one-line header comment to `frontend/src/lib/flexvoice/index.js`: `// Vendored from ~/Personal/flex-voice web/src — edit there, copy here.`

- [ ] **Step 2: Rewire the composable test**

Rewrite `frontend/src/composables/__tests__/useVoiceInput.spec.js`: keep the existing MediaRecorder/getUserMedia mocks and recording-lifecycle tests unchanged, but replace the `../api/voice` mock with:
```js
const transcriber = {
  mode: 'device',
  load: vi.fn().mockResolvedValue(),
  transcribeBlob: vi.fn().mockResolvedValue({ text: 'hello world' }),
}
vi.mock('../../lib/flexvoice/index.js', () => ({ createTranscriber: vi.fn(() => transcriber) }))
```
Assert: `stop()` resolves to `'hello world'` via `transcriber.transcribeBlob` (called with a Blob); `transcribeBlob` rejection → `error.value === 'Could not transcribe'` and `stop()` returns `''`; and a new test: when `transcriber.mode === 'unsupported'` after `load()`, the composable's `unsupported` ref becomes true.

- [ ] **Step 3: Run — expect FAIL**, then modify `frontend/src/composables/useVoiceInput.js`:

```js
import { ref } from 'vue'
import { createTranscriber } from '../lib/flexvoice/index.js'

// Module-level singleton: one model in memory no matter how many composable
// instances mount. Lazy — nothing downloads until the first mic press.
let transcriber = null
function getTranscriber() {
  if (!transcriber) transcriber = createTranscriber()
  return transcriber
}

export function useVoiceInput() {
  const isRecording = ref(false)
  const isTranscribing = ref(false)
  const permissionDenied = ref(false)
  const unsupported = ref(false)
  const error = ref(null)
  // ... start() and _releaseStream() unchanged from current file ...

  async function stop() {
    // ... recorder stop + blob assembly unchanged down to `if (blob.size === 0) return ''` ...
    isTranscribing.value = true
    try {
      const t = getTranscriber()
      const { text } = await t.transcribeBlob(blob)
      if (t.mode === 'unsupported') unsupported.value = true
      return text || ''
    } catch (e) {
      const t = getTranscriber()
      if (t.mode === 'unsupported') { unsupported.value = true; return '' }
      error.value = 'Could not transcribe'
      return ''
    } finally {
      isTranscribing.value = false
    }
  }

  return { isRecording, isTranscribing, permissionDenied, unsupported, error, start, stop }
}
```
(The `sessionIdRef` parameter is dropped — it existed only for backend cost attribution. Check its call site in `VoiceRecorder.vue`/`ChatView.vue` and remove the argument.)

Delete `frontend/src/api/voice.js`. In `VoiceRecorder.vue`: destructure `unsupported` and add `v-if="!unsupported"` (or `v-show`) on the root button; extend `VoiceRecorder.spec.js` with one test that the button is absent when `unsupported` is true.

- [ ] **Step 4: Run full frontend suite**

Run: `cd frontend && npm test` — expect PASS (fix fallout: anything else importing `api/voice.js`).

- [ ] **Step 5: Live browser check** (dev server or ai.flexsolutions.ph after deploy, playwright-bot account): dictate "Dahican" → composer fills; Network tab shows **no `/chat/transcribe` POST**.

- [ ] **Step 6: Commit + PR**

```bash
git add -A && git commit -m "feat: on-device voice transcription via vendored flex-voice (no audio upload)"
git push -u origin feat/on-device-voice
gh pr create --title "On-device voice transcription (flex-voice)" --body "Swaps push-to-talk STT from Grok cloud to on-device Whisper (transformers.js). Audio never leaves the browser. Backend /chat/transcribe path unused by the UI as of this PR; deletion follows in a separate PR once live-verified."
```
No AI attribution in the PR body. Backend `VOICE_*`/Grok deletion is deliberately NOT in this PR (spec build-order step 5).

---

## Phase 3 — Mac client (repo: `~/Personal/flex-voice`)

### Task 7: Hammerspoon push-to-talk client

**Files:**
- Create: `mac/flex-voice.lua`, `mac/install.sh`, `mac/README.md`

**Interfaces:**
- Consumes: nothing from other tasks (fully standalone, zero network).
- Produces: hold right-⌥ anywhere on macOS → transcript typed into the focused app.

- [ ] **Step 1: Write the Hammerspoon module**

`mac/flex-voice.lua`:
```lua
-- flex-voice: hold right-option, speak, release -> text typed at the cursor.
-- Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves the Mac.
local M = {}

local HOME = os.getenv("HOME")
local MODEL = HOME .. "/.flex-voice/models/ggml-base.en.bin"
local WAV = "/tmp/flex-voice.wav"
local RIGHT_OPT = 61 -- keycode for right option
local MIN_MS = 300   -- taps shorter than this are cancels

local function bin(name)
  for _, p in ipairs({ "/opt/homebrew/bin/", "/usr/local/bin/" }) do
    if hs.fs.attributes(p .. name) then return p .. name end
  end
  return name
end

local recTask, downAt = nil, nil
local menubar = hs.menubar.new()
local function setIcon(rec) menubar:setTitle(rec and "🔴" or "🎙") end
setIcon(false)

local function startRecording()
  downAt = hs.timer.secondsSinceEpoch()
  os.remove(WAV)
  recTask = hs.task.new(bin("ffmpeg"),
    nil,
    { "-y", "-f", "avfoundation", "-i", ":0", "-ar", "16000", "-ac", "1", WAV })
  recTask:start()
  setIcon(true)
end

local function transcribe()
  local out, ok = hs.execute(
    bin("whisper-cli") .. " -m " .. MODEL .. " -f " .. WAV .. " -nt -np 2>/dev/null")
  os.remove(WAV)
  if not ok then
    hs.alert.show("flex-voice: transcription failed")
    return
  end
  local text = out:gsub("^%s+", ""):gsub("%s+$", "")
  if #text > 0 then hs.eventtap.keyStrokes(text) end
end

local function stopRecording()
  if not recTask then return end
  local cancelled = (hs.timer.secondsSinceEpoch() - downAt) * 1000 < MIN_MS
  -- SIGTERM = ffmpeg graceful quit: it finalizes the wav header before exiting.
  recTask:terminate()
  recTask = nil
  setIcon(false)
  if cancelled then os.remove(WAV); return end
  -- Give ffmpeg a beat to flush, then transcribe off the hotkey path.
  hs.timer.doAfter(0.3, transcribe)
end

M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  if e:getKeyCode() ~= RIGHT_OPT then return false end
  if e:getFlags().alt then startRecording() else stopRecording() end
  return false
end)
M.tap:start()

return M
```

- [ ] **Step 2: Install script**

`mac/install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
brew list hammerspoon &>/dev/null || brew install --cask hammerspoon
brew install ffmpeg whisper-cpp
mkdir -p ~/.flex-voice/models ~/.hammerspoon
MODEL=~/.flex-voice/models/ggml-base.en.bin
[ -f "$MODEL" ] || curl -L -o "$MODEL" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
cp "$(dirname "$0")/flex-voice.lua" ~/.hammerspoon/flex-voice.lua
grep -q 'flex%-voice' ~/.hammerspoon/init.lua 2>/dev/null || \
  echo 'require("flex-voice")' >> ~/.hammerspoon/init.lua
echo "Done. Start Hammerspoon, grant Accessibility + Microphone permissions, reload config."
```
`chmod +x mac/install.sh`.

- [ ] **Step 3: `mac/README.md`** — install steps (`./install.sh`), first-run permissions (Accessibility for keyStrokes, Microphone for ffmpeg), the hotkey (hold right-⌥), and the manual verification checklist below.

- [ ] **Step 4: Manual verification (on the Mac — Dieter or a driven session there)**

- Hold right-⌥, say "testing one two three from Dahican", release → text appears in Notes.
- Same into the browser at ai.flexsolutions.ph.
- Quick tap → nothing typed.
- **Wi-Fi off** → dictation still works (the on-device proof).
- Stop whisper-cli mid-run (rename model file) → alert shows, nothing typed.

- [ ] **Step 5: Commit**

```bash
cd ~/Personal/flex-voice && git add mac && git commit -m "mac: Hammerspoon push-to-talk client (ffmpeg + whisper.cpp, on-device)"
```

---

## Phase 4 — server fallback (repo: `~/Personal/flex-voice`)

### Task 8: Fallback service (FastAPI + faster-whisper)

**Files:**
- Create: `server/app.py`, `server/requirements.txt`
- Test: `server/test_app.py`

**Interfaces:**
- Produces: `POST /transcribe` (multipart `audio`, optional `language` form field, `X-API-Key` header) → `{"text": str, "duration_ms": int}`; `GET /health` → `{"status": "ok", "model": str}`. Matches exactly what `transcriber.js` `serverTranscribe()` (Task 2) calls.

- [ ] **Step 1: Write the failing tests**

`server/test_app.py`:
```python
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
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd ~/Personal/flex-voice/server && python -m venv .venv && .venv/bin/pip install fastapi uvicorn faster-whisper python-multipart httpx pytest
.venv/bin/python -m pytest test_app.py -q
```

- [ ] **Step 3: Implement**

`server/requirements.txt`:
```
fastapi
uvicorn
faster-whisper
python-multipart
```

`server/app.py`:
```python
"""flex-voice server fallback — STT for devices too slow to run Whisper locally.

Opt-in only: the browser library POSTs here solely when the host app set
slowDevice='server'. Audio is transcribed in memory and never persisted.
"""
import asyncio
import os
import tempfile
import time

from fastapi import FastAPI, Form, Header, HTTPException, UploadFile

MODEL_NAME = os.environ.get("WHISPER_MODEL", "small.en")
MODELS_DIR = os.environ.get("WHISPER_MODELS_DIR", "/models")
MAX_BYTES = int(os.environ.get("MAX_BYTES", 25 * 1024 * 1024))
API_KEYS = {k for k in os.environ.get("API_KEYS", "").split(",") if k}

app = FastAPI()
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


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/transcribe")
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
        t0 = time.monotonic()
        text, duration = await asyncio.to_thread(_run, data, language)
    return {"text": text, "duration_ms": int(duration * 1000)}


def _run(data: bytes, language: str) -> tuple[str, float]:
    with tempfile.NamedTemporaryFile(suffix=".webm") as f:
        f.write(data)
        f.flush()
        segments, info = _get_model().transcribe(f.name, language=language)
        return " ".join(s.text.strip() for s in segments).strip(), info.duration
```

- [ ] **Step 4: Run tests — expect PASS, then commit**

```bash
git add server && git commit -m "server: opt-in slow-device fallback (FastAPI + faster-whisper)"
```

### Task 9: Deploy fallback to prod + wire into agent-platform

**Files:**
- Create: `server/Dockerfile`, `server/docker-compose.yml`
- Modify (agent-platform repo, follow-up PR): `frontend/src/composables/useVoiceInput.js` (transcriber options from env)

**Interfaces:**
- Consumes: Task 8's service; Task 2's `slowDevice: 'server'` options.

- [ ] **Step 1: Dockerfile + compose**

`server/Dockerfile`:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```

`server/docker-compose.yml` (mirror the Traefik labels of an existing service on the box — check `/root/projects/agent-platform/docker-compose.yml` for the live pattern):
```yaml
services:
  flex-voice:
    build: .
    container_name: flex-voice
    environment:
      - WHISPER_MODEL=${WHISPER_MODEL:-small.en}
      - API_KEYS=${API_KEYS}
    volumes:
      - whisper-models:/models
    networks: [traefik-public]
    labels:
      - traefik.enable=true
      - traefik.http.routers.flexvoice.rule=Host(`stt.flexsolutions.ph`)
      - traefik.http.routers.flexvoice.entrypoints=websecure
      - traefik.http.routers.flexvoice.tls.certresolver=letsencrypt
      - traefik.http.services.flexvoice.loadbalancer.server.port=8000
volumes:
  whisper-models:
networks:
  traefik-public:
    external: true
```
Verify the certresolver name against a live service's labels before deploying; adjust if the box uses a different resolver id.

- [ ] **Step 2: DNS** — Route53 recipe from memory: A record `stt.flexsolutions.ph → 5.223.51.1` (zone `Z0828140M9CUSR7YWTSG`, `aws --profile flex`, SSO login first if needed).

- [ ] **Step 3: Deploy**

```bash
# on the server (root@5.223.51.1): clone/pull flex-voice to /root/projects/flex-voice
cd /root/projects/flex-voice/server && docker compose up -d --build
```
`API_KEYS` goes into `/root/projects/flex-voice/server/.env` — **Dieter drops the keys in himself** (generate with `openssl rand -hex 24`; one key per consuming app: `agent-platform`, `mac-client`, …). Never paste keys in chat.

- [ ] **Step 4: Real-curl verify**

```bash
curl -s https://stt.flexsolutions.ph/health          # {"status":"ok",...}
curl -s -X POST https://stt.flexsolutions.ph/transcribe \
  -H "X-API-Key: $KEY" -F audio=@sample.wav          # {"text":"...","duration_ms":...}
curl -s -o /dev/null -w '%{http_code}' -X POST https://stt.flexsolutions.ph/transcribe -F audio=@sample.wav  # 401
```
(Generate `sample.wav` with `ffmpeg -f lavfi -i "sine=frequency=440:duration=2" sample.wav`, or use any short speech clip.)

- [ ] **Step 5: Wire into agent-platform (small follow-up PR)**

In `useVoiceInput.js`'s `getTranscriber()`:
```js
transcriber = createTranscriber({
  slowDevice: import.meta.env.VITE_STT_FALLBACK_URL ? 'server' : 'disable',
  fallbackUrl: import.meta.env.VITE_STT_FALLBACK_URL || null,
  fallbackApiKey: import.meta.env.VITE_STT_FALLBACK_KEY || null,
})
```
Note in the PR body: `VITE_*` vars are baked at build time and visible in the served bundle — the fallback key is deliberately a low-privilege, revocable, STT-only key, acceptable to expose to logged-in users of our own app. Unset vars = policy stays `disable` (pure on-device). Prod values go in via Dieter + the normal deploy.

- [ ] **Step 6: Commit flex-voice, push both**

```bash
cd ~/Personal/flex-voice && git add server && git commit -m "server: Dockerfile + compose + prod deploy notes"
```

---

## Post-plan follow-ups (tracked, not tasks here)

- Delete agent-platform's Grok voice path (`/chat/transcribe`, `voice_service.py`, `VOICE_*` config) after 1–2 weeks of live on-device use — spec build-order step 5, its own small PR.
- Create the flex-voice GitHub repo + push (needed before the server can `git pull`; `gh repo create` when Dieter says where it lives).
- TTS (`createSpeaker()` / Piper) — next iteration.
