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
  // Alternates quiet/loud bytes across frames so the analyser simulates real
  // speech (varying RMS) by default — the silence gate needs frames that
  // actually clear the floor, unlike a truly flat/constant buffer. Tests that
  // want genuine silence (the silence-gate suite) override this locally.
  let frame = 0
  globalThis.AudioContext = vi.fn(function () {
    this.createAnalyser = () => ({
      fftSize: 0,
      getByteTimeDomainData: (buf) => { frame += 1; buf.fill(frame % 2 === 0 ? 200 : 128) },
    })
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
      expect(localStorage.getItem('mictext-blocked2')).toBe('1')
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
      localStorage.setItem('mictext-blocked2', '1')
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
      transcriber.transcribeBlob.mockReturnValueOnce(new Promise((res) => { resolveTranscribe = res }))
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

  it('empty transcription emits no-speech "artifact" (whisper artifact, not an error)', async () => {
    transcriber.transcribeBlob.mockResolvedValueOnce({ text: '' })
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await settled() // let load() settle -> button enabled
    const quiet = new Promise((res) => el.addEventListener('no-speech', (e) => res(e.detail.reason)))
    el.dispatchEvent(new Event('pointerdown'))
    await new Promise((r) => setTimeout(r, 350)) // past the cancel window, gives the analyser frames to gather
    el.dispatchEvent(new Event('pointerup'))
    expect(await quiet).toBe('artifact')
  })

  it('slot with 🎤 fallback lets consumers provide a custom button face', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    const slot = el.shadowRoot.querySelector('button slot')
    expect(slot).toBeTruthy()
    expect(slot.textContent).toBe('🎤')
  })

  it('loading ring shows while the model loads and hides once ready', async () => {
    let resolveLoad
    transcriber.load.mockReturnValueOnce(new Promise((r) => { resolveLoad = r }))
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    const ring = el.shadowRoot.querySelector('.ring')
    expect(ring.hidden).toBe(false)
    resolveLoad()
    await settled()
    expect(ring.hidden).toBe(true)
  })

  it('loading ring shows during transcription and hides after', async () => {
    let resolveText
    transcriber.transcribeBlob.mockReturnValueOnce(new Promise((r) => { resolveText = r }))
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    await settled()
    const ring = el.shadowRoot.querySelector('.ring')
    expect(ring.hidden).toBe(true)
    el.dispatchEvent(new Event('pointerdown'))
    // Real wait, not a Date.now() spoof: the silence gate needs actual
    // analyser frames to accumulate, past the cancel window.
    await new Promise((r) => setTimeout(r, 350))
    el.dispatchEvent(new Event('pointerup'))
    await settled()
    expect(ring.hidden).toBe(false) // transcribing
    resolveText({ text: 'hi' })
    await settled()
    expect(ring.hidden).toBe(true)
  })

  describe('crash-probe false-positive fixes', () => {
    it('pagehide clears the in-flight marker (reload is not a crash)', async () => {
      let resolveLoad
      transcriber.load.mockReturnValueOnce(new Promise((r) => { resolveLoad = r }))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el) // load starts -> marker stamped
      expect(localStorage.getItem('mictext-probe:testtab')).toBeTruthy()
      window.dispatchEvent(new Event('pagehide')) // graceful reload/navigation
      expect(localStorage.getItem('mictext-probe:testtab')).toBe(null)
      resolveLoad()
    })

    it('a legacy (pre-fix) block flag is ignored and cleaned up', async () => {
      localStorage.setItem('mictext-blocked', '1') // old key: unreliable, void
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      expect(el.hidden).toBe(false)
      expect(localStorage.getItem('mictext-blocked')).toBe(null)
    })
  })

  it('reflects a busy attribute while loading and while transcribing', async () => {
    let resolveLoad
    transcriber.load.mockReturnValueOnce(new Promise((r) => { resolveLoad = r }))
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    expect(el.hasAttribute('busy')).toBe(true) // loading
    resolveLoad()
    await settled()
    expect(el.hasAttribute('busy')).toBe(false) // idle

    let resolveText
    transcriber.transcribeBlob.mockReturnValueOnce(new Promise((r) => { resolveText = r }))
    el.dispatchEvent(new Event('pointerdown'))
    // Real wait, not a Date.now() spoof: the silence gate needs actual
    // analyser frames to accumulate, past the cancel window.
    await new Promise((r) => setTimeout(r, 350))
    el.dispatchEvent(new Event('pointerup'))
    await settled()
    expect(el.hasAttribute('busy')).toBe(true) // transcribing
    resolveText({ text: 'hi' })
    await settled()
    expect(el.hasAttribute('busy')).toBe(false)
  })

  it('exposes the ring as a part for consumer styling', async () => {
    const el = document.createElement('mictext-mic')
    document.body.appendChild(el)
    expect(el.shadowRoot.querySelector('.ring').getAttribute('part')).toBe('ring')
  })

  describe('silence gate', () => {
    // The default analyser now simulates speech (varying levels) so the
    // other ~20 tests above get a normal transcript. Genuine silence needs
    // its own override: a constant 128 (digital silence) into the buffer,
    // so this recording produces a flat level series.
    it('does not transcribe a hold that carried no speech', async () => {
      globalThis.AudioContext = vi.fn(function () {
        this.createAnalyser = () => ({ fftSize: 0, getByteTimeDomainData: (buf) => buf.fill(128) })
        this.createMediaStreamSource = () => ({ connect: vi.fn() })
        this.close = vi.fn()
      })
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      const quiet = new Promise((res) => el.addEventListener('no-speech', (e) => res(e.detail.reason)))
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 350))
      el.dispatchEvent(new Event('pointerup'))
      expect(await quiet).toBe('silence')
      expect(transcriber.transcribeBlob).not.toHaveBeenCalled()
    })

    it('emits no-speech (not transcript) when whisper returns a silence artifact', async () => {
      transcriber.transcribeBlob.mockResolvedValueOnce({ text: '[BLANK_AUDIO]' })
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      const transcripts = []
      el.addEventListener('transcript', (e) => transcripts.push(e.detail.text))
      const quiet = new Promise((res) => el.addEventListener('no-speech', (e) => res(e.detail.reason)))
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 350))
      el.dispatchEvent(new Event('pointerup'))
      expect(await quiet).toBe('artifact')
      expect(transcripts).toEqual([])
    })

    it('fails OPEN when no level data exists (no AudioContext = never swallow speech)', async () => {
      const RealCtx = globalThis.AudioContext
      globalThis.AudioContext = undefined
      globalThis.webkitAudioContext = undefined
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      const got = new Promise((res) => el.addEventListener('transcript', (e) => res(e.detail.text)))
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 350))
      el.dispatchEvent(new Event('pointerup'))
      expect(await got).toBe('hi')
      globalThis.AudioContext = RealCtx
    })

    it('fails OPEN on a suspended AudioContext (WebKit autoplay policy off-gesture)', async () => {
      // A context built after an `await` (getUserMedia) starts life suspended
      // on WebKit. A suspended analyser reads back a constant flat buffer
      // forever — indistinguishable from true silence — so metering must be
      // proven by an actual running-context sample, never assumed at construction.
      globalThis.AudioContext = vi.fn(function () {
        this.state = 'suspended'
        this.resume = vi.fn().mockResolvedValue()
        this.createAnalyser = () => ({ fftSize: 0, getByteTimeDomainData: (buf) => buf.fill(128) })
        this.createMediaStreamSource = () => ({ connect: vi.fn() })
        this.close = vi.fn()
      })
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      const got = new Promise((res) => el.addEventListener('transcript', (e) => res(e.detail.text)))
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 350))
      el.dispatchEvent(new Event('pointerup'))
      expect(await got).toBe('hi')
    })

    it('fails OPEN when a hold ends with too few frames to judge (short hold / throttled device)', async () => {
      // A slow/throttled device (or a very short hold) can end with fewer
      // frames than hasSpeech() needs to render any verdict at all. "Not
      // enough data to judge" is the same epistemic state as "no data" and
      // must transcribe, not silently read as measured silence.
      let frames = 0
      const realRAF = globalThis.requestAnimationFrame
      globalThis.requestAnimationFrame = (cb) => {
        frames += 1
        if (frames > 3) return 0 // simulate a device that stalls after 3 frames
        return realRAF(cb)
      }
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      const got = new Promise((res) => el.addEventListener('transcript', (e) => res(e.detail.text)))
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 350))
      el.dispatchEvent(new Event('pointerup'))
      expect(await got).toBe('hi')
      globalThis.requestAnimationFrame = realRAF
    })

    it('discriminates a realistic mic signal (quiet floor, modest speech peaks) from silence', async () => {
      // The default fakeMedia() double swings between ~-5dB and a ~-180dB
      // digital-silence floor — a 175dB ratio against a 12dB threshold, so
      // any implementation that pushes SOME monotonic function of RMS passes
      // it. Real mic noise floors sit far higher than digital silence, so
      // this double keeps both floor and peaks in a plausible range.
      let frame = 0
      globalThis.AudioContext = vi.fn(function () {
        this.createAnalyser = () => ({
          fftSize: 0,
          getByteTimeDomainData: (buf) => {
            frame += 1
            if (frame % 2 === 0) {
              // "peak" frame: ~-36dB, modest speech-level swing
              for (let i = 0; i < buf.length; i++) buf[i] = i % 2 === 0 ? 126 : 130
            } else {
              // "floor" frame: ~-55dB, quiet room noise, not digital silence
              buf.fill(128)
              for (let i = 0; i < buf.length; i += 20) buf[i] = 129
            }
          },
        })
        this.createMediaStreamSource = () => ({ connect: vi.fn() })
        this.close = vi.fn()
      })
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      const got = new Promise((res) => el.addEventListener('transcript', (e) => res(e.detail.text)))
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 350))
      el.dispatchEvent(new Event('pointerup'))
      expect(await got).toBe('hi')
    })
  })

  describe('warming state', () => {
    it('is warming from press until the recorder starts, then recording', async () => {
      let openMic
      globalThis.navigator.mediaDevices.getUserMedia =
        vi.fn(() => new Promise((res) => { openMic = () => res({ getTracks: () => [track] }) }))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      const btn = el.shadowRoot.querySelector('button')

      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 0))
      expect(el.hasAttribute('warming')).toBe(true)
      expect(btn.classList.contains('recording')).toBe(false)
      expect(el.shadowRoot.querySelector('.wave').hidden).toBe(true)

      openMic()
      await new Promise((r) => setTimeout(r, 0))
      expect(el.hasAttribute('warming')).toBe(false)
      expect(btn.classList.contains('recording')).toBe(true)
    })

    it('clears warming when released before the mic ever opens', async () => {
      globalThis.navigator.mediaDevices.getUserMedia = vi.fn(() => new Promise(() => {}))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      el.dispatchEvent(new Event('pointerdown'))
      await new Promise((r) => setTimeout(r, 0))
      expect(el.hasAttribute('warming')).toBe(true)
      el.dispatchEvent(new Event('pointerup'))
      expect(el.hasAttribute('warming')).toBe(false)
    })

    it('clears warming when the microphone is unavailable', async () => {
      globalThis.navigator.mediaDevices.getUserMedia = vi.fn().mockRejectedValue(new Error('denied'))
      const el = document.createElement('mictext-mic')
      document.body.appendChild(el)
      await settled()
      const failed = new Promise((res) => el.addEventListener('voice-error', (e) => res(e.detail.message)))
      el.dispatchEvent(new Event('pointerdown'))
      expect(await failed).toBe('Microphone unavailable')
      expect(el.hasAttribute('warming')).toBe(false)
    })
  })
})
