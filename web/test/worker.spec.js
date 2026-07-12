import { describe, it, expect, vi, beforeEach } from 'vitest'

// worker.js drives everything through self.onmessage/postMessage and the
// transformers pipeline — mock both and exercise the message protocol.
const asr = vi.fn(async () => ({ text: '  hello world  ' }))
vi.mock('@huggingface/transformers', () => ({
  pipeline: vi.fn(async () => asr),
  env: {},
}))

let posted
beforeEach(async () => {
  vi.clearAllMocks()
  posted = []
  globalThis.self = { postMessage: (m) => posted.push(m) }
  vi.resetModules()
  await import('../src/worker.js')
  await self.onmessage({ data: { type: 'load', model: 'm', device: 'wasm' } })
  posted.length = 0
})

describe('worker transcribe', () => {
  it('short clips stay on the fast path (no chunking opts)', async () => {
    await self.onmessage({ data: { type: 'transcribe', audio: new Float32Array(10 * 16000) } })
    expect(asr).toHaveBeenCalledWith(expect.anything(), {})
    expect(posted[0]).toMatchObject({ type: 'result', text: 'hello world' })
  })

  it('long clips chunk WITH timestamps — the merge drops seam sentences without them', async () => {
    await self.onmessage({ data: { type: 'transcribe', audio: new Float32Array(31 * 16000) } })
    expect(asr).toHaveBeenCalledWith(expect.anything(), {
      chunk_length_s: 30,
      stride_length_s: 5,
      return_timestamps: true,
    })
    expect(posted[0]).toMatchObject({ type: 'result', text: 'hello world' })
  })

  it('pipeline errors post an error message instead of hanging', async () => {
    asr.mockRejectedValueOnce(new Error('boom'))
    await self.onmessage({ data: { type: 'transcribe', audio: new Float32Array(16000) } })
    expect(posted[0]).toMatchObject({ type: 'error', message: 'boom' })
  })
})
