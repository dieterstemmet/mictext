import { blobToPcm } from './audio.js'

const BENCH_SECONDS = 1
// Load/benchmark deadline: some WebGPU adapters HANG instead of failing
// (session compiles forever, no error, no message). 30s without any worker
// message during load/benchmark = treat as crashed and let the wasm retry
// take over. Progress messages re-arm the timer, so slow model downloads
// never false-trip. Transcription requests are exempt: long clips post
// nothing for minutes, legitimately.
const STALL_MS = 30000

export function createTranscriber(opts = {}) {
  const {
    // tiny.en by default: whisper-base's inference footprint exceeds WebKit's
    // per-tab memory ceiling (iPhone AND macOS Safari OOM-kill the page).
    // Pass model: 'onnx-community/whisper-base.en' where you know the device.
    model = 'onnx-community/whisper-tiny.en',
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

  // Serialize requests: concurrent callers would otherwise clobber onmessage.
  // ponytail: single promise queue, fine for a serial worker.
  let queue = Promise.resolve()
  // Reject hook for the in-flight request: dispose()/worker teardown must
  // SETTLE it — an abandoned pending promise leaks callers' finally blocks
  // (e.g. the mic element's crash-probe marker never clears).
  let pendingReject = null
  function request(msg, transfer, stallMs = 0) {
    const p = queue.then(() => new Promise((resolve, reject) => {
      // The worker may have been torn down while this request sat queued
      // behind the one that crashed — fail cleanly, don't deref null.
      if (!worker) { reject(new Error('transcriber disposed')); return }
      pendingReject = reject
      let stallTimer = 0
      const settle = (fn) => (v) => { pendingReject = null; clearTimeout(stallTimer); fn(v) }
      const done = settle(resolve)
      const fail = settle(reject)
      // Stalled worker = crashed worker: same teardown, same recovery path.
      const arm = () => {
        if (!stallMs) return
        clearTimeout(stallTimer)
        stallTimer = setTimeout(() => { _workerReset(); fail(new Error('worker stalled')) }, stallMs)
      }
      worker.onmessage = ({ data }) => {
        arm() // any message proves the worker is alive
        if (data.type === 'progress') { if (onProgress) onProgress(data.progress); return }
        if (data.type === 'error') fail(new Error(data.message))
        else done(data)
      }
      // A worker that CRASHES (mobile OOM, runtime fault) never posts a
      // message — without these the request promise hangs forever and the
      // caller spins on "Transcribing…" indefinitely. The crashed worker is
      // torn down so the NEXT attempt starts from a clean load instead of
      // posting into a corpse.
      worker.onerror = (e) => { _workerReset(); fail(new Error((e && e.message) || 'worker crashed')) }
      worker.onmessageerror = () => { _workerReset(); fail(new Error('worker message deserialization failed')) }
      arm()
      worker.postMessage(msg, transfer)
    }))
    queue = p.catch(() => {})
    return p
  }

  async function benchmark() {
    const silence = new Float32Array(16000 * BENCH_SECONDS)
    const { elapsedMs } = await request(
      { type: 'transcribe', audio: silence }, [silence.buffer], STALL_MS,
    )
    return elapsedMs
  }

  function degrade() {
    // Device can't run the model (or is too slow): apply the policy.
    if (worker) { worker.terminate(); worker = null }
    t.mode = slowDevice === 'server' ? 'server' : 'unsupported'
    t.state = t.mode === 'unsupported' ? 'unsupported' : 'idle'
  }

  // Load AND benchmark: both are webgpu-hang-prone, so both live inside the
  // per-device attempt — a benchmark failure on webgpu gets the wasm retry
  // too (and can no longer reject the cached loadPromise permanently).
  async function attemptLoad(device) {
    worker = createWorker()
    await request({ type: 'load', model, modelBaseUrl, device }, undefined, STALL_MS)
    return benchmark()
  }

  t.load = function load() {
    if (loadPromise) return loadPromise
    loadPromise = (async () => {
      t.state = 'loading-model'
      const device = typeof navigator !== 'undefined' && navigator.gpu ? 'webgpu' : 'wasm'
      let elapsedMs
      try {
        elapsedMs = await attemptLoad(device)
      } catch (e) {
        // WebGPU can be present but broken (requestAdapter always fails) or
        // HUNG (adapter exists, session never completes — stall timeout) —
        // retry on WASM before giving up. A wasm-first attempt that fails
        // has nowhere left to retry.
        if (device !== 'webgpu') return degrade()
        if (worker) { worker.terminate(); worker = null }
        try {
          elapsedMs = await attemptLoad('wasm')
        } catch (e2) {
          return degrade()
        }
      }
      if (elapsedMs > slowThresholdMs) degrade()
      else t.state = 'idle'
    })()
    return loadPromise
  }

  async function serverTranscribe(blob) {
    const form = new FormData()
    form.append('audio', blob, 'clip.webm')
    const r = await fetch(`${fallbackUrl}/transcribe`, {
      method: 'POST',
      headers: fallbackApiKey ? { 'X-API-Key': fallbackApiKey } : {},
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

  // Tear down the worker + queue so the next request() starts clean, and
  // SETTLE any in-flight request (callers' finally blocks must run). Resetting
  // `queue` is essential: a wedged in-flight request would otherwise chain every
  // future request onto a promise that never settles (permanent on-device hang).
  // Deliberately does NOT touch loadPromise: during load()'s webgpu→wasm retry
  // the fault path runs mid-load, and nulling loadPromise there would let a
  // second load() race in later, orphaning a fully-loaded worker (doubled
  // model memory on exactly the weak devices this serves).
  function _workerReset() {
    if (worker) { worker.terminate(); worker = null }
    queue = Promise.resolve()
    // Crash AFTER a completed load → clear loadPromise so the next attempt
    // reloads fresh. Crash DURING load → leave it: load() is still running
    // its own webgpu→wasm retry/degrade logic on that very promise.
    if (t.state !== 'loading-model') loadPromise = null
    if (pendingReject) {
      const r = pendingReject
      pendingReject = null
      r(new Error('transcriber disposed'))
    }
  }

  t.dispose = function dispose() {
    _workerReset()
    loadPromise = null
  }

  return t
}
