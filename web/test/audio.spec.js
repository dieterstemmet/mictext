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
