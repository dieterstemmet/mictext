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
