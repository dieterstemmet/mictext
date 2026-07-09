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
      // Without chunk_length_s Whisper's feature extractor silently TRUNCATES
      // input to the first 30 s — long dictations lost everything after the
      // first sentence. Chunk long clips; leave short ones on the fast path.
      const opts = data.audio.length > 30 * 16000
        ? { chunk_length_s: 30, stride_length_s: 5 }
        : {}
      const out = await asr(data.audio, opts)
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
