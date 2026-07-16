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
  globalThis.AudioContext = vi.fn(function () {
    this.createAnalyser = () => ({ fftSize: 0, getByteTimeDomainData: vi.fn() })
    this.createMediaStreamSource = () => ({ connect: vi.fn() })
    this.close = vi.fn()
  })
  globalThis.MediaRecorder = vi.fn(function () {
    this.start = vi.fn()
    this.stop = vi.fn(() => {
      this.ondataavailable({ data: new Blob([new Uint8Array([1])]) })
      this.onstop()
    })
  })
}

// The element now gates recording behind load() settling (ready-gate);
// tests that record must let the connect-time load resolve first.
const settled = () => new Promise((r) => setTimeout(r, 0))

describe('<mictext-mic>', () => {
  beforeEach(() => {
    document.body.innerHTML = ''
    transcriber.mode = 'device'
    vi.clearAllMocks()
    fakeMedia()
    localStorage.clear()
    sessionStorage.setItem('mictext-tab', 'testtab')
    customElements.get('mictext-mic').resetProbe()
  })

  it('hold -> release emits a transcript event', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await settled()
    const got = new Promise((res) => el.addEventListener('transcript', (e) => res(e.detail.text)))
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 350)) // past the 300ms cancel window
    el.dispatchEvent(new Event('pointerup'))
    expect(await got).toBe('hi')
  })

  it('short tap (<300ms) cancels without transcribing', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await settled()
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
    await settled()
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 10))
    el.dispatchEvent(new Event('pointerup'))
    await new Promise((r) => setTimeout(r, 10))
    expect(track.stop).toHaveBeenCalled()
  })

  it('stops mic tracks when disconnected mid-recording', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await settled()
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 10))
    el.remove()
    expect(track.stop).toHaveBeenCalled()
  })

  it('shows the live waveform while recording and hides it after', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await settled()
    const wave = el.shadowRoot.querySelector('.wave')
    expect(wave.hidden).toBe(true)
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 0)) // getUserMedia resolves
    expect(wave.hidden).toBe(false)
    expect(wave.children.length).toBeGreaterThan(0)
    await new Promise((r) => setTimeout(r, 350))
    el.dispatchEvent(new Event('pointerup'))
    await new Promise((r) => setTimeout(r, 0))
    expect(wave.hidden).toBe(true)
  })

  describe('crash probe (WebKit OOM tab-kill detection)', () => {
    it('a fresh marker at boot blocks the device and hides the mic', async () => {
      localStorage.setItem('mictext-probe:testtab', String(Date.now() - 1000))
      const errors = []
      document.body.addEventListener('voice-error', (e) => errors.push(e.detail.message))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      expect(el.hidden).toBe(true)
      expect(localStorage.getItem('mictext-blocked')).toBe('1')
      expect(transcriber.load).not.toHaveBeenCalled()
      await new Promise((r) => setTimeout(r, 0)) // error dispatch is async by design
      expect(errors.length).toBe(1)
    })

    it('a stale marker (tab closed mid-work, not a crash) is cleared and the mic works', async () => {
      localStorage.setItem('mictext-probe:testtab', String(Date.now() - 10 * 60 * 1000))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      expect(el.hidden).toBe(false)
      expect(transcriber.load).toHaveBeenCalled()
    })

    it("another tab's fresh marker is ignored — no false block from two-tab use", async () => {
      localStorage.setItem('mictext-probe:othertab', String(Date.now() - 1000))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      expect(el.hidden).toBe(false)
      expect(transcriber.load).toHaveBeenCalled()
      // and we must NOT have clobbered the other tab's live marker
      expect(localStorage.getItem('mictext-probe:othertab')).not.toBe(null)
    })

    it('a blocked device stays blocked on later boots', async () => {
      localStorage.setItem('mictext-blocked', '1')
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
      expect(localStorage.getItem('mictext-probe:testtab')).toBe(null)
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
      expect(localStorage.getItem('mictext-probe:testtab')).toMatch(/^\d+$/) // armed mid-inference
      resolveTranscribe({ text: 'done' })
      await new Promise((r) => setTimeout(r, 0))
      expect(localStorage.getItem('mictext-probe:testtab')).toBe(null)
    })
  })

  it('button is disabled until load resolves, then enabled', async () => {
    let resolveLoad
    transcriber.load.mockReturnValueOnce(new Promise((r) => { resolveLoad = r }))
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    const btn = el.shadowRoot.querySelector('button')
    expect(btn.disabled).toBe(true)
    resolveLoad()
    await Promise.resolve(); await Promise.resolve(); await Promise.resolve()
    expect(btn.disabled).toBe(false)
  })

  it('does not start recording before load resolves', async () => {
    transcriber.load.mockReturnValueOnce(new Promise(() => {})) // never resolves
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await settled()
    el.dispatchEvent(new Event('pointerdown'))
    await Promise.resolve()
    expect(navigator.mediaDevices.getUserMedia).not.toHaveBeenCalled()
  })

  it('empty transcription emits voice-error "No speech detected"', async () => {
    transcriber.transcribeBlob.mockResolvedValue({ text: '' })
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await settled() // let load() settle -> button enabled
    const err = new Promise((res) => el.addEventListener('voice-error', (e) => res(e.detail.message)))
    el.dispatchEvent(new Event('pointerdown'))
    await settled() // getUserMedia + recorder start
    const realNow = Date.now()
    const dateSpy = vi.spyOn(Date, 'now').mockReturnValue(realNow + 1000) // past the cancel window
    el.dispatchEvent(new Event('pointerup'))
    expect(await err).toBe('No speech detected')
    dateSpy.mockRestore()
  })
})
