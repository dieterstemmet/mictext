import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createTranscriber } from '../src/transcriber.js'

// Minimal fake worker implementing the load/transcribe protocol.
// failDevice: fail the load message only when msg.device matches (used to
// simulate WebGPU present-but-broken while WASM still works).
function fakeWorker({ elapsedMs = 100, failLoad = false, failDevice = null } = {}) {
  const w = {
    onmessage: null,
    terminated: false,
    postMessage(msg) {
      queueMicrotask(() => {
        if (msg.type === 'load') {
          const fail = failLoad || msg.device === failDevice
          w.onmessage({ data: fail ? { type: 'error', message: 'no backend' } : { type: 'ready' } })
        } else if (msg.type === 'transcribe') {
          w.onmessage({ data: { type: 'result', text: 'hello world', elapsedMs } })
        }
      })
    },
    terminate() { w.terminated = true },
  }
  return w
}

function withGpu(fn) {
  return async () => {
    globalThis.navigator.gpu = {}
    try {
      await fn()
    } finally {
      delete globalThis.navigator.gpu
    }
  }
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
    expect(text).toBe('hello world')
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

  it('webgpu present but broken -> retries wasm and succeeds', withGpu(async () => {
    const workers = []
    const t = createTranscriber({
      createWorker: () => { const w = fakeWorker({ failDevice: 'webgpu' }); workers.push(w); return w },
    })
    const { text } = await t.transcribeBlob(new Blob([new Uint8Array([1])]))
    expect(text).toBe('hello world')
    expect(t.mode).toBe('device')
    expect(workers.length).toBe(2)
    expect(workers[0].terminated).toBe(true)
  }))

  it('webgpu present, both webgpu and wasm loads fail -> unsupported', withGpu(async () => {
    const t = createTranscriber({ createWorker: () => fakeWorker({ failLoad: true }) })
    await t.load()
    expect(t.mode).toBe('unsupported')
    expect(t.state).toBe('unsupported')
  }))

  it('dispose terminates the worker', async () => {
    const w = fakeWorker()
    const t = createTranscriber({ createWorker: () => w })
    await t.load()
    t.dispose()
    expect(w.terminated).toBe(true)
  })

  it('two concurrent transcribeBlob calls both resolve with text', async () => {
    const t = createTranscriber({ createWorker: () => fakeWorker() })
    const [a, b] = await Promise.all([
      t.transcribeBlob(new Blob([new Uint8Array([1])])),
      t.transcribeBlob(new Blob([new Uint8Array([2])])),
    ])
    expect(a.text).toBe('hello world')
    expect(b.text).toBe('hello world')
  })
})

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
      fallbackUrl: 'https://stt.example.com',
      fallbackApiKey: 'k1',
    })
    const { text } = await t.transcribeBlob(new Blob([new Uint8Array([1])]))
    expect(text).toBe('from server')
    const [url, init] = globalThis.fetch.mock.calls[0]
    expect(url).toBe('https://stt.example.com/transcribe')
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

  it('omits X-API-Key header when fallbackApiKey is not provided', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ text: 'x' }) })
    const t = createTranscriber({
      createWorker: () => fakeWorker({ elapsedMs: 9999 }),
      slowDevice: 'server',
      fallbackUrl: 'https://x',
    })
    await t.transcribeBlob(new Blob([new Uint8Array([1])]))
    const [, init] = globalThis.fetch.mock.calls[0]
    expect(init.headers).not.toHaveProperty('X-API-Key')
  })

  it('a crashed worker rejects the request instead of hanging forever', async () => {
    // Worker that never posts a message — only fires the error event (OOM/crash).
    const w = {
      onmessage: null,
      onerror: null,
      postMessage() {
        queueMicrotask(() => w.onerror && w.onerror(new Error('worker crashed')))
      },
      terminate() {},
    }
    const t = createTranscriber({ createWorker: () => w })
    await expect(t.transcribeBlob(new Blob([new Uint8Array([1])]))).rejects.toThrow()
  })

  it('dispose() SETTLES the in-flight request so caller finally blocks run', async () => {
    // Worker answers load+benchmark then wedges on the real transcribe.
    let transcribes = 0
    const w = {
      onmessage: null, onerror: null,
      postMessage(msg) {
        queueMicrotask(() => {
          if (msg.type === 'load') w.onmessage({ data: { type: 'ready' } })
          else if (++transcribes === 1) w.onmessage({ data: { type: 'result', text: 'bench', elapsedMs: 100 } })
        })
      },
      terminate() {},
    }
    const t = createTranscriber({ createWorker: () => w })
    let settled = false
    const hung = t.transcribeBlob(new Blob([new Uint8Array([1])])).catch(() => {}).finally(() => { settled = true })
    await new Promise((r) => setTimeout(r, 10))
    t.dispose()
    await hung
    expect(settled).toBe(true)
  })

  it('a request queued behind a worker crash rejects cleanly instead of throwing on null', async () => {
    let transcribes = 0
    const w = {
      onmessage: null, onerror: null,
      postMessage(msg) {
        queueMicrotask(() => {
          if (msg.type === 'load') w.onmessage({ data: { type: 'ready' } })
          else if (++transcribes === 1) w.onmessage({ data: { type: 'result', text: 'bench', elapsedMs: 100 } })
          else if (transcribes === 2) w.onerror && w.onerror(new Error('boom')) // crash on first real clip
        })
      },
      terminate() {},
    }
    const t = createTranscriber({ createWorker: () => w })
    const a = t.transcribeBlob(new Blob([new Uint8Array([1])]))
    const b = t.transcribeBlob(new Blob([new Uint8Array([2])]))
    await expect(a).rejects.toThrow()
    await expect(b).rejects.toThrow(/disposed|crashed/) // clean rejection, not a null TypeError
  })

  it('dispose() unwedges the queue: next transcribe runs on a fresh worker', async () => {
    // First worker answers load + the benchmark, then wedges on the real
    // transcribe. dispose() must reset the queue so worker #2 can serve.
    const mkWedged = () => {
      let transcribes = 0
      const w = {
        onmessage: null,
        onerror: null,
        postMessage(msg) {
          queueMicrotask(() => {
            if (msg.type === 'load') w.onmessage({ data: { type: 'ready' } })
            else if (++transcribes === 1) w.onmessage({ data: { type: 'result', text: 'bench', elapsedMs: 100 } })
            // 2nd transcribe: no reply, ever (wedged worker)
          })
        },
        terminate() {},
      }
      return w
    }
    let made = 0
    const t = createTranscriber({ createWorker: () => { made += 1; return made === 1 ? mkWedged() : fakeWorker() } })
    const hung = t.transcribeBlob(new Blob([new Uint8Array([1])]))
    await new Promise((r) => setTimeout(r, 10)) // let the wedged transcribe get posted
    t.dispose()
    const { text } = await t.transcribeBlob(new Blob([new Uint8Array([1])]))
    expect(text).toBe('hello world')
    expect(made).toBe(2)
    hung.catch(() => {}) // wedged promise never settles; silence any late rejection
  })

  // --- stall handling (WebGPU adapters that hang instead of failing) -------

  // A worker that accepts the load message and then never posts anything.
  function silentWorker() {
    const w = {
      onmessage: null, terminated: false,
      postMessage() { /* never replies */ },
      terminate() { w.terminated = true },
    }
    return w
  }

  it('webgpu load that never responds stalls out and retries wasm', withGpu(async () => {
    vi.useFakeTimers()
    try {
      const workers = []
      const t = createTranscriber({ createWorker: () => {
        const w = workers.length === 0 ? silentWorker() : fakeWorker()
        workers.push(w); return w
      } })
      const p = t.load()
      await vi.advanceTimersByTimeAsync(31000)
      await p
      expect(workers.length).toBe(2)
      expect(workers[0].terminated).toBe(true)
      expect(t.state).toBe('idle')
      expect(t.mode).toBe('device')
    } finally { vi.useRealTimers() }
  }))

  it('webgpu benchmark that never responds stalls out and retries wasm', withGpu(async () => {
    vi.useFakeTimers()
    try {
      // load succeeds, benchmark (first transcribe) never replies
      function loadOkBenchSilent() {
        const w = {
          onmessage: null, terminated: false,
          postMessage(msg) {
            if (msg.type === 'load') queueMicrotask(() => w.onmessage({ data: { type: 'ready' } }))
            // transcribe: never replies
          },
          terminate() { w.terminated = true },
        }
        return w
      }
      const workers = []
      const t = createTranscriber({ createWorker: () => {
        const w = workers.length === 0 ? loadOkBenchSilent() : fakeWorker()
        workers.push(w); return w
      } })
      const p = t.load()
      await vi.advanceTimersByTimeAsync(62000) // load span + benchmark span
      await p
      expect(workers.length).toBe(2)
      expect(t.state).toBe('idle')
    } finally { vi.useRealTimers() }
  }))

  it('webgpu benchmark error retries wasm instead of rejecting load()', withGpu(async () => {
    function loadOkBenchError() {
      const w = {
        onmessage: null,
        postMessage(msg) {
          queueMicrotask(() => {
            if (msg.type === 'load') w.onmessage({ data: { type: 'ready' } })
            else w.onmessage({ data: { type: 'error', message: 'device lost' } })
          })
        },
        terminate() {},
      }
      return w
    }
    const workers = []
    const t = createTranscriber({ createWorker: () => {
      const w = workers.length === 0 ? loadOkBenchError() : fakeWorker()
      workers.push(w); return w
    } })
    await t.load() // must NOT reject
    expect(workers.length).toBe(2)
    expect(t.state).toBe('idle')
    const { text } = await t.transcribeBlob(new Blob([new Uint8Array([1])]))
    expect(text).toBe('hello world')
  }))

  it('long transcriptions are NOT stall-killed', async () => {
    vi.useFakeTimers()
    try {
      let transcribes = 0
      function slowTranscribe() {
        const w = {
          onmessage: null,
          postMessage(msg) {
            if (msg.type === 'load') queueMicrotask(() => w.onmessage({ data: { type: 'ready' } }))
            else if (++transcribes === 1) queueMicrotask(() => w.onmessage({ data: { type: 'result', text: 'bench', elapsedMs: 100 } }))
            else setTimeout(() => w.onmessage({ data: { type: 'result', text: 'slow but real', elapsedMs: 90000 } }), 90000)
          },
          terminate() {},
        }
        return w
      }
      const t = createTranscriber({ createWorker: slowTranscribe })
      const p = t.transcribeBlob(new Blob([new Uint8Array([1])]))
      await vi.advanceTimersByTimeAsync(91000)
      const { text } = await p
      expect(text).toBe('slow but real')
    } finally { vi.useRealTimers() }
  })

  it('dispose during a stall-armed load does not kill the retried worker later', withGpu(async () => {
    vi.useFakeTimers()
    try {
      const workers = []
      const t = createTranscriber({ createWorker: () => {
        const w = workers.length === 0 ? silentWorker() : fakeWorker()
        workers.push(w); return w
      } })
      const p = t.load()
      await vi.advanceTimersByTimeAsync(5000)
      t.dispose() // rejects the stalled load request; its 30s timer must die too
      await vi.advanceTimersByTimeAsync(40000) // past the original stall deadline
      await p // load() settles one way or another; must not throw unhandled
      // the retried wasm worker (if any) must NOT have been torn down by the
      // leaked timer of the disposed request
      if (workers.length > 1) expect(workers[1].terminated).toBe(false)
    } finally { vi.useRealTimers() }
  }))
})
