import { createTranscriber } from './transcriber.js'

const CANCEL_MS = 300

// Crash probe. WebKit (iPhone AND macOS Safari) can OOM-kill the whole tab
// mid-inference — nothing catchable fires in JS, the page just reloads with
// "A problem repeatedly occurred". Detection is only possible after the fact:
// a marker written before risky work that is still present (and fresh) at the
// next boot means the last attempt took the page down. That device is then
// blocked from on-device transcription permanently (MicTextMic.resetProbe()
// to retry, e.g. after switching to a smaller model).
//
// Each tab owns its own marker key (`mictext-probe:<tabId>`, tabId from
// sessionStorage — survives a crash-reload in the same tab, differs across
// tabs), so concurrent tabs never clobber or misread each other's markers.
// The device-wide block flag is a separate shared key. The timestamp is
// re-stamped every 30s while work is in flight, so even a crash minutes into
// a long inference still reads as fresh at the next boot; a genuinely STALE
// own marker means the tab was closed mid-work (not a crash) and is cleared.
const BLOCK_KEY = 'mictext-blocked'
const PROBE_FRESH_MS = 120000
const PROBE_RESTAMP_MS = 30000
let probeGuards = 0
let probeTimer = 0

function tabId() {
  try {
    let id = sessionStorage.getItem('mictext-tab')
    if (!id) {
      id = Math.random().toString(36).slice(2, 10)
      sessionStorage.setItem('mictext-tab', id)
    }
    return id
  } catch { return 'notab' }
}
function probeKey() { return `mictext-probe:${tabId()}` }
function lsGet(k) {
  try { return localStorage.getItem(k) } catch { return null }
}
function lsSet(k, v) {
  try {
    if (v === null) localStorage.removeItem(k)
    else localStorage.setItem(k, v)
  } catch { /* no storage = no probe, attempt anyway */ }
}
function stamp() { lsSet(probeKey(), String(Date.now())) }
// load() and transcribeBlob() overlap (transcribe awaits load), so the marker
// is refcounted: it clears only when the LAST risky span finishes.
function guardStart() {
  probeGuards += 1
  stamp()
  if (!probeTimer) probeTimer = setInterval(stamp, PROBE_RESTAMP_MS)
}
function guardEnd() {
  probeGuards = Math.max(0, probeGuards - 1)
  if (probeGuards === 0) {
    clearInterval(probeTimer)
    probeTimer = 0
    lsSet(probeKey(), null)
  }
}
// Returns true when this device is (now) blocked from on-device attempts.
function probeBlocked() {
  if (lsGet(BLOCK_KEY)) return true
  const ts = lsGet(probeKey()) // only OUR tab's marker is ours to judge
  if (ts) {
    lsSet(probeKey(), null)
    if (Date.now() - (Number(ts) || 0) < PROBE_FRESH_MS) {
      lsSet(BLOCK_KEY, '1') // our fresh marker at boot = last attempt crashed this tab
      return true
    }
    // stale = closed mid-work, not a crash
  }
  return false
}

class MicTextMic extends HTMLElement {
  connectedCallback() {
    this._disconnected = false
    if (this.shadowRoot) return // reconnect: shadow root + listeners already set up

    this.attachShadow({ mode: 'open' }).innerHTML = `
      <style>
        :host { display: inline-flex; align-items: center; }
        button { border: none; border-radius: 50%; width: 2.5rem; height: 2.5rem;
                 cursor: pointer; background: #eee; font-size: 1.1rem; }
        button.recording { background: #e33; }
        button:disabled { opacity: .5; cursor: default; }
        .wave { display: inline-flex; align-items: center; gap: 2px; height: 18px;
                margin-left: .5rem; }
        .wave[hidden] { display: none; }
        .wave i { width: 2px; min-height: 2px; height: 2px; background: #e33;
                  border-radius: 1px; transition: height 90ms linear; }
      </style>
      <button type="button" title="Hold to talk">🎤</button>
      <span class="wave" hidden aria-hidden="true">${'<i></i>'.repeat(14)}</span>`
    this._btn = this.shadowRoot.querySelector('button')
    this._waveEl = this.shadowRoot.querySelector('.wave')

    const opts = this.transcriberOptions || {
      model: this.getAttribute('model') || undefined,
      slowDevice: this.getAttribute('slow-device') || undefined,
      fallbackUrl: this.getAttribute('fallback-url') || undefined,
      fallbackApiKey: this.getAttribute('fallback-api-key') || undefined,
    }
    // ponytail: a blocked device hides the mic even when a server fallback is
    // configured; wire blocked→server mode if a real deployment needs it.
    if (probeBlocked()) {
      this.hidden = true
      // Async: for parser-created elements connectedCallback runs before any
      // script attaches listeners — a sync dispatch would go unheard.
      queueMicrotask(() =>
        this._emitError('On-device transcription previously crashed this device — mic disabled'))
      return
    }

    this._t = createTranscriber(opts)
    // Kick off the (cached) model load early, hide if the device can't run it.
    // The load includes a benchmark inference — crash-guard the whole span.
    // Until it settles the button is disabled: recording against a transcriber
    // that may never answer reads as "broken", not "loading".
    this._ready = false
    this._btn.disabled = true
    this._btn.title = 'Loading model…'
    guardStart()
    this._t.load()
      .then(() => {
        if (this._t.mode === 'unsupported') { this.hidden = true; return }
        this._ready = true
        this._btn.disabled = false
        this._btn.title = 'Hold to talk'
      })
      .finally(guardEnd)

    this.addEventListener('pointerdown', () => this._start())
    this.addEventListener('pointerup', () => this._stop())
    this.addEventListener('pointerleave', () => this._stop())
    this.addEventListener('pointercancel', () => this._stop())
  }

  // Live input waveform: rolling bars driven by mic RMS while recording, so
  // "listening" is visible at a glance (newest bar on the right, WhatsApp-style).
  _startWave(stream) {
    // Cosmetic — any failure (no AudioContext, autoplay policy) means flat
    // bars, never a broken recording.
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext
      const ctx = new Ctx()
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 512
      ctx.createMediaStreamSource(stream).connect(analyser)
      const buf = new Uint8Array(analyser.fftSize)
      const bars = [...this._waveEl.children]
      this._waveEl.hidden = false
      const wave = { ctx, raf: 0, last: 0 }
      this._wave = wave
      const tick = (t) => {
        analyser.getByteTimeDomainData(buf)
        let sum = 0
        for (let i = 0; i < buf.length; i++) {
          const d = (buf[i] - 128) / 128
          sum += d * d
        }
        // ~3x boost: normal speech RMS is quiet; full bar ≈ loud voice.
        const level = Math.min(1, Math.sqrt(sum / buf.length) * 3)
        if (t - wave.last > 90) { // roll left every ~90ms, newest on the right
          wave.last = t
          for (let i = 0; i < bars.length - 1; i++) bars[i].style.height = bars[i + 1].style.height
          bars[bars.length - 1].style.height = `${2 + level * 16}px`
        }
        wave.raf = requestAnimationFrame(tick)
      }
      wave.raf = requestAnimationFrame(tick)
    } catch { /* see above */ }
  }

  _stopWave() {
    if (this._wave) {
      cancelAnimationFrame(this._wave.raf)
      try { this._wave.ctx.close() } catch { /* already closed */ }
      this._wave = null
    }
    if (this._waveEl) {
      this._waveEl.hidden = true
      for (const b of this._waveEl.children) b.style.height = '2px'
    }
  }

  disconnectedCallback() {
    this._disconnected = true
    this._stopWave()
    if (this._t) this._t.dispose()

    const session = this._session
    this._session = null
    if (!session) return
    session.released = true
    if (session.rec) { try { session.rec.stop() } catch { /* already stopped */ } }
    if (session.stream) session.stream.getTracks().forEach((t) => t.stop())
    // else: getUserMedia still pending — _runStart cleans up the stream when it resolves.
  }

  _start() {
    if (!this._ready || this._session) return // still loading / already recording
    const session = { released: false, stream: null, rec: null, chunks: [], downAt: Date.now() }
    this._session = session
    this._runStart(session)
  }

  async _runStart(session) {
    let stream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      if (this._session === session) this._session = null
      this._emitError('Microphone unavailable')
      return
    }
    if (session.released || this._disconnected) {
      // Hold was released (or element removed) while permission was pending.
      stream.getTracks().forEach((t) => t.stop())
      return
    }
    session.stream = stream
    session.rec = new MediaRecorder(stream)
    session.rec.ondataavailable = (ev) => { if (ev.data && ev.data.size) session.chunks.push(ev.data) }
    session.rec.start()
    this._btn.classList.add('recording')
    this._startWave(stream)
  }

  async _stop() {
    const session = this._session
    if (!session) return
    this._session = null
    session.released = true
    if (!session.rec) return // getUserMedia still pending; _runStart will tear it down
    const { rec, stream } = session
    this._btn.classList.remove('recording')
    this._stopWave()
    const stopped = new Promise((res) => { rec.onstop = res; setTimeout(res, 5000) })
    rec.stop()
    await stopped
    stream.getTracks().forEach((t) => t.stop())
    if (Date.now() - session.downAt < CANCEL_MS) return // cancel tap
    try {
      this._btn.disabled = true
      guardStart() // inference is the crash-prone span on WebKit
      const { text } = await this._t.transcribeBlob(new Blob(session.chunks, { type: 'audio/webm' }))
      if (text) this.dispatchEvent(new CustomEvent('transcript', { detail: { text }, bubbles: true }))
      else this._emitError('No speech detected') // silence in = silence out, but say so
    } catch (e) {
      this._emitError(e.message)
    } finally {
      guardEnd() // a JS error is NOT a crash — only an unreachable finally is
      this._btn.disabled = false
    }
  }

  // Clear the crash block (e.g. to retry after switching to a smaller model).
  static resetProbe() {
    probeGuards = 0
    clearInterval(probeTimer)
    probeTimer = 0
    lsSet(BLOCK_KEY, null)
    lsSet(probeKey(), null)
  }

  _emitError(message) {
    this.dispatchEvent(new CustomEvent('voice-error', { detail: { message }, bubbles: true }))
  }
}

if (!customElements.get('mictext-mic')) customElements.define('mictext-mic', MicTextMic)
