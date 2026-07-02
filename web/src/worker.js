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
