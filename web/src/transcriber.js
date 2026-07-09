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

  // Serialize requests: concurrent callers would otherwise clobber onmessage.
  // ponytail: single promise queue, fine for a serial worker.
  let queue = Promise.resolve()
  function request(msg, transfer) {
    const p = queue.then(() => new Promise((resolve, reject) => {
      worker.onmessage = ({ data }) => {
        if (data.type === 'progress') { if (onProgress) onProgress(data.progress); return }
        if (data.type === 'error') reject(new Error(data.message))
        else resolve(data)
      }
      // A worker that CRASHES (mobile OOM, runtime fault) never posts a
      // message — without these the request promise hangs forever and the
      // caller spins on "Transcribing…" indefinitely.
      worker.onerror = (e) => reject(new Error((e && e.message) || 'worker crashed'))
      worker.onmessageerror = () => reject(new Error('worker message deserialization failed'))
      worker.postMessage(msg, transfer)
    }))
    queue = p.catch(() => {})
    return p
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

  async function attemptLoad(device) {
    worker = createWorker()
    await request({ type: 'load', model, modelBaseUrl, device })
  }

  t.load = function load() {
    if (loadPromise) return loadPromise
    loadPromise = (async () => {
      t.state = 'loading-model'
      const device = typeof navigator !== 'undefined' && navigator.gpu ? 'webgpu' : 'wasm'
      try {
        await attemptLoad(device)
      } catch (e) {
        // WebGPU can be present but broken (requestAdapter always fails on some
        // hardware/browsers) - retry on WASM before giving up. A wasm-first
        // attempt that fails has nowhere left to retry.
        if (device !== 'webgpu') return degrade()
        if (worker) { worker.terminate(); worker = null }
        try {
          await attemptLoad('wasm')
        } catch (e2) {
          return degrade()
        }
      }
      if ((await benchmark()) > slowThresholdMs) degrade()
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

  t.dispose = function dispose() {
    if (worker) { worker.terminate(); worker = null }
    loadPromise = null
  }

  return t
}
