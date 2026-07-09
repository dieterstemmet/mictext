<p align="center">
  <img src="https://raw.githubusercontent.com/dieterstemmet/mictext/master/assets/logo-badge.svg" width="140" alt="MicText: a microphone whose grille is lines of text, ending in a red caret">
</p>

# MicText (web)

On-device speech-to-text for the browser: audio never leaves the machine
unless you explicitly opt into a server fallback for slow devices. Runs
Whisper (`onnx-community/whisper-tiny.en` by default, quantized) via
`@huggingface/transformers`, in a Web Worker, over WebGPU or WASM.

## Layer 1: headless core (`createTranscriber`)

```js
import { createTranscriber } from 'mictext'

const t = createTranscriber({
  model = 'onnx-community/whisper-tiny.en',   // base.en fits desktop Chrome; exceeds WebKit's tab memory
  modelBaseUrl = null,          // self-hosted model files (sets localModelPath)
  onProgress = null,            // (fractionOrFileProgress) => void during model download
  slowDevice = 'disable',       // 'disable' | 'server'
  fallbackUrl = null,           // required when slowDevice === 'server'
  fallbackApiKey = null,
  slowThresholdMs = 5000,
  createWorker = () => new Worker(new URL('./worker.js', import.meta.url), { type: 'module' }),
})

t.state          // 'idle' | 'loading-model' | 'transcribing' | 'unsupported'
t.mode           // 'device' | 'server' | 'unsupported'  (settles after first load)
await t.load()   // idempotent; downloads/initializes model, runs a benchmark
await t.transcribeBlob(blob)  // -> { text }  (lazy-loads on first call)
t.dispose()      // terminates the worker
```

Use this layer directly if you're building your own UI/hold-to-talk logic.

## Layer 2: `<mictext-mic>` web component

```html
<script type="module">
  import 'mictext/mic'
  addEventListener('transcript', (e) => console.log(e.detail.text))
  addEventListener('voice-error', (e) => alert(e.detail.message))
</script>
<mictext-mic model="onnx-community/whisper-base.en" slow-device="disable"></mictext-mic>
```

Hold the button (pointerdown), speak, release (pointerup) — a `transcript`
CustomEvent fires with `{ detail: { text } }`. Releasing before ~300ms
cancels the recording without transcribing (accidental-tap guard). Errors
(mic permission denied, transcription failure) fire a `voice-error` event
with `{ detail: { message } }` instead of throwing.

Attributes: `model`, `slow-device`, `fallback-url`, `fallback-api-key`. For
anything not expressible as an attribute (e.g. `slowThresholdMs`,
`onProgress`), set the `transcriberOptions` property to a full options
object *before* the element is inserted into the DOM — it's read once in
`connectedCallback`.

The element hides itself (`hidden = true`) if the device is degraded to
`unsupported` (see policy table below).

## Demo

From a clone of [the repo](https://github.com/dieterstemmet/mictext) (the
demo isn't shipped in the npm package):

```bash
cd web && npx vite --port 5199
```

Open `/demo/index.html`. Vite is required (not a plain static file server)
to resolve the bare `@huggingface/transformers` import — it's a direct
dependency of this library (see `dependencies` in `package.json`).

## Slow-device policy (`slowDevice`)

After the model loads, `createTranscriber` runs a 1-second benchmark
transcription. If it exceeds `slowThresholdMs` (default 5000ms), the device
is judged too slow to run Whisper locally and the policy below applies:

| `slowDevice` | Behavior on a slow/unsupported device |
| --- | --- |
| `'disable'` (default) | `t.mode = 'unsupported'`, `t.state = 'unsupported'`. `transcribeBlob()` rejects. `<mictext-mic>` hides itself. No audio ever leaves the device — appropriate when you have no fallback endpoint. |
| `'server'` | `t.mode = 'server'`. `transcribeBlob()` uploads the audio blob to `${fallbackUrl}/transcribe` (`multipart/form-data`, `X-API-Key: fallbackApiKey`) instead of running it locally. Requires `fallbackUrl`; throws at construction time otherwise. This is the only path in this library that ever sends audio over the network. |

Device selection (`'webgpu'` vs `'wasm'`) is a simple `navigator.gpu`
presence check, not a real capability probe — see "Known limitation" below
for how a broken-but-present WebGPU is handled.

## Model download

The Whisper model (`onnx-community/whisper-tiny.en` by default, `dtype: 'q8'`) is
fetched from huggingface.co on first use and cached by the browser (Cache
Storage API), not re-downloaded on subsequent page loads on the same
device/browser profile. Pass `onProgress` (headless) — or watch network
activity — to show download progress on first run.

### Observed numbers (this verification run, real Chromium, real network, no GPU)

- Model payload: ~77 MB (`encoder_model_quantized.onnx` 23.2 MB +
  `decoder_model_merged_quantized.onnx` 53.7 MB, plus small tokenizer/config
  JSON) — bigger than the ~40 MB ballpark estimate; budget for ~75-80 MB.
- Cold load (worker spin-up + full model download + benchmark, CPU-only
  WASM path, no WebGPU): **~10-11 seconds** on this box's network.
- Warm reload (model served from Cache Storage, no re-download): **~7.7
  seconds** settle time, with the huggingface.co GETs gone entirely from
  the network log (13 requests total vs. 31 cold) — the remaining time is
  worker/WASM-runtime init and the benchmark, not download.
- 1-second-silence benchmark stayed under the default 5000ms
  `slowThresholdMs` on this (otherwise unremarkable, no-GPU) box, so the
  device path was used, not `unsupported`/`server`.
- A real hold → speak → release cycle (fake mic device, 440Hz tone as the
  "speech") completed end-to-end: `transcribeBlob` returned text (a
  non-speech-audio hallucination like `"(beep)"`/`"(chiming)"` — expected
  and fine for a synthetic tone, not a real defect) and fired the
  `transcript` event, in ~3.2 seconds on-device transcription time.

If your `slowThresholdMs` is too tight for a given CPU, raise it via
`transcriberOptions` (component) or the `createTranscriber` option
(headless) rather than lowering expectations of the WASM path — the
threshold exists to protect users of *actually* slow hardware, not to be a
strict SLA.

### Known limitation: `navigator.gpu` presence != working WebGPU

Device selection is `navigator.gpu ? 'webgpu' : 'wasm'`, a presence check
rather than a real capability probe. On some environments (observed here:
headless Chromium, software rendering, no real/virtual GPU) `navigator.gpu`
exists as an object but `requestAdapter()` unconditionally fails at
model-load time (`no available backend found ... Failed to get GPU
adapter`). `transcriber.js` handles this: a failed `'webgpu'` load
terminates that worker and retries once on a fresh worker with `'wasm'`,
running the normal benchmark on success. Only when the WASM retry also
fails does the device degrade to `unsupported`/`server`. A `'wasm'`-first
attempt (no `navigator.gpu`) that fails still degrades immediately, since
there's nothing left to retry.

## Zero-upload guarantee

With `slowDevice: 'disable'` (the default), no network request this
library makes is ever a POST/PUT of your audio — only GETs (model files
from huggingface.co, WASM runtime from jsdelivr). Verified end-to-end in a
real browser with full network-request logging during a complete
load → record → transcribe cycle: 31 requests, all GET, zero POST/PUT.
The only path that uploads audio is the explicit `slowDevice: 'server'`
opt-in.
