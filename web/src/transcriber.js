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
