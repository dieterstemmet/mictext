import { describe, it, expect, vi, beforeEach } from 'vitest'

const transcriber = {
  state: 'idle',
  mode: 'device',
  load: vi.fn().mockResolvedValue(),
  transcribeBlob: vi.fn().mockResolvedValue({ text: 'hi' }),
  dispose: vi.fn(),
}
vi.mock('../src/transcriber.js', () => ({ createTranscriber: vi.fn(() => transcriber) }))

// Import AFTER the mock so the element sees the mocked factory.
await import('../src/mic-element.js')

let track
function fakeMedia() {
  track = { stop: vi.fn() }
  globalThis.navigator.mediaDevices = {
    getUserMedia: vi.fn().mockResolvedValue({ getTracks: () => [track] }),
  }
  globalThis.MediaRecorder = vi.fn(function () {
    this.start = vi.fn()
    this.stop = vi.fn(() => {
      this.ondataavailable({ data: new Blob([new Uint8Array([1])]) })
      this.onstop()
    })
  })
}

describe('<mictext-mic>', () => {
  beforeEach(() => {
    document.body.innerHTML = ''
    transcriber.mode = 'device'
    vi.clearAllMocks()
    fakeMedia()
  })

  it('hold -> release emits a transcript event', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    const got = new Promise((res) => el.addEventListener('transcript', (e) => res(e.detail.text)))
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 350)) // past the 300ms cancel window
    el.dispatchEvent(new Event('pointerup'))
    expect(await got).toBe('hi')
  })

  it('short tap (<300ms) cancels without transcribing', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    el.dispatchEvent(new Event('pointerdown'))
    el.dispatchEvent(new Event('pointerup'))
    await new Promise((r) => setTimeout(r, 10))
    expect(transcriber.transcribeBlob).not.toHaveBeenCalled()
  })

  it('hides itself when transcriber mode is unsupported', async () => {
    transcriber.mode = 'unsupported'
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await new Promise((r) => setTimeout(r, 10))
    expect(el.hidden).toBe(true)
  })

  it('stops mic tracks on release', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 10))
    el.dispatchEvent(new Event('pointerup'))
    await new Promise((r) => setTimeout(r, 10))
    expect(track.stop).toHaveBeenCalled()
  })

  it('stops mic tracks when disconnected mid-recording', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 10))
    el.remove()
    expect(track.stop).toHaveBeenCalled()
  })
})
