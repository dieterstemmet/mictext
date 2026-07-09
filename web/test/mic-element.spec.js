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
    localStorage.clear()
    customElements.get('mictext-mic').resetProbe()
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

  describe('crash probe (WebKit OOM tab-kill detection)', () => {
    it('a fresh marker at boot blocks the device and hides the mic', async () => {
      localStorage.setItem('mictext-probe', String(Date.now() - 1000))
      const errors = []
      document.body.addEventListener('voice-error', (e) => errors.push(e.detail.message))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      expect(el.hidden).toBe(true)
      expect(localStorage.getItem('mictext-probe')).toBe('blocked')
      expect(transcriber.load).not.toHaveBeenCalled()
      expect(errors.length).toBe(1)
    })

    it('a stale marker (tab closed mid-work, not a crash) is cleared and the mic works', async () => {
      localStorage.setItem('mictext-probe', String(Date.now() - 10 * 60 * 1000))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      expect(el.hidden).toBe(false)
      expect(transcriber.load).toHaveBeenCalled()
    })

    it('a blocked device stays blocked on later boots', async () => {
      localStorage.setItem('mictext-probe', 'blocked')
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      expect(el.hidden).toBe(true)
      expect(transcriber.load).not.toHaveBeenCalled()
    })

    it('a clean load + transcribe leaves no marker behind', async () => {
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await new Promise((r) => setTimeout(r, 0)) // load() settles, guard released
      const got = new Promise((res) => el.addEventListener('transcript', (e) => res(e.detail.text)))
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 350))
      el.dispatchEvent(new Event('pointerup'))
      await got
      expect(localStorage.getItem('mictext-probe')).toBe(null)
    })

    it('the marker is SET during the risky inference span', async () => {
      let resolveTranscribe
      transcriber.transcribeBlob.mockReturnValue(new Promise((res) => { resolveTranscribe = res }))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await new Promise((r) => setTimeout(r, 0))
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 350))
      el.dispatchEvent(new Event('pointerup'))
      await new Promise((r) => setTimeout(r, 0))
      expect(Number(localStorage.getItem('mictext-probe'))).toBeGreaterThan(0) // armed mid-inference
      resolveTranscribe({ text: 'done' })
      await new Promise((r) => setTimeout(r, 0))
      expect(localStorage.getItem('mictext-probe')).toBe(null)
    })
  })
})
