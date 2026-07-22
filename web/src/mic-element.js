import { createTranscriber } from './transcriber.js'
import { hasSpeech, isSilenceArtifact, SPEECH_FRAMES } from './silence.js'

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
// v2: the original key was set by a flow that couldn't tell a mid-work
// RELOAD from a crash (any reload during model load false-blocked the
// device forever). Old flags are untrustworthy — ignored and removed.
const BLOCK_KEY = 'mictext-blocked2'
const LEGACY_BLOCK_KEY = 'mictext-blocked'
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
// A graceful reload/navigation fires pagehide; an OOM tab-kill does not.
// Clearing the marker here means only GENUINE crashes leave one behind.
// (bfcache restore: the 30s re-stamp interval survives and re-marks work
// that is still in flight — the guard degrades safely.)
if (typeof addEventListener === 'function') {
  addEventListener('pagehide', () => lsSet(probeKey(), null))
}

// Returns true when this device is (now) blocked from on-device attempts.
function probeBlocked() {
  lsSet(LEGACY_BLOCK_KEY, null) // pre-fix flags: void, see BLOCK_KEY note
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
        :host { display: inline-flex; align-items: center; --mictext-mic-size: 2.5rem; }
        .wrap { position: relative; display: inline-flex; }
        button { border: none; border-radius: 50%; box-sizing: border-box;
                 width: var(--mictext-mic-size); height: var(--mictext-mic-size);
                 cursor: pointer; background: #eee; font-size: 1.1rem; padding: 0;
                 display: inline-flex; align-items: center; justify-content: center;
                 overflow: hidden; }
        button ::slotted(*) { width: 100%; height: 100%; object-fit: contain;
                              pointer-events: none; }
        /* a slotted face hides a background swap — use a halo ring instead */
        button.recording { box-shadow: 0 0 0 3px #e33; }
        /* warming = the device is opening, we are NOT capturing yet. Paper
           halo, not the recording red — the two must never look alike. */
        button.warming { box-shadow: 0 0 0 3px #F2EFE7;
                         animation: mictext-warm 1.1s ease-in-out infinite; }
        @keyframes mictext-warm { 50% { box-shadow: 0 0 0 3px #cfcabd; } }
        @media (prefers-reduced-motion: reduce) {
          button.warming { animation: none; }
        }
        button:disabled { opacity: .5; cursor: default; }
        /* loading ring: the logo's grille palette (paper + caret red) orbiting
           the button while the model loads or a clip transcribes */
        .ring { position: absolute; inset: -7px; border-radius: 50%; pointer-events: none;
                background: conic-gradient(#FF4D3D 0 25%, #F2EFE7 25% 50%,
                                           #FF4D3D 50% 75%, #F2EFE7 75% 100%);
                -webkit-mask: radial-gradient(farthest-side, transparent calc(100% - 4px), #000 calc(100% - 3px));
                mask: radial-gradient(farthest-side, transparent calc(100% - 4px), #000 calc(100% - 3px));
                animation: mictext-spin 1s linear infinite; }
        .ring[hidden] { display: none; }
        @keyframes mictext-spin { to { transform: rotate(1turn); } }
        @media (prefers-reduced-motion: reduce) {
          .ring { animation: mictext-pulse 1.6s ease-in-out infinite; }
        }
        @keyframes mictext-pulse { 50% { opacity: .35; } }
        .wave { display: inline-flex; align-items: center; gap: 2px; height: 18px;
                margin-left: .5rem; }
        .wave[hidden] { display: none; }
        .wave i { width: 2px; min-height: 2px; height: 2px; background: #e33;
                  border-radius: 1px; transition: height 90ms linear; }
      </style>
      <span class="wrap">
        <span class="ring" part="ring" hidden aria-hidden="true"></span>
        <button type="button" title="Hold to talk"><slot>🎤</slot></button>
      </span>
      <span class="wave" hidden aria-hidden="true">${'<i></i>'.repeat(14)}</span>`
    this._btn = this.shadowRoot.querySelector('button')
    this._ring = this.shadowRoot.querySelector('.ring')
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
    this._setBusy(true)
    guardStart()
    this._t.load()
      .then(() => {
        if (this._t.mode === 'unsupported') { this.hidden = true; return }
        this._ready = true
        this._btn.disabled = false
        this._btn.title = 'Hold to talk'
      })
      .finally(() => { this._setBusy(false); guardEnd() })

    this.addEventListener('pointerdown', () => this._start())
    this.addEventListener('pointerup', () => this._stop())
    this.addEventListener('pointerleave', () => this._stop())
    this.addEventListener('pointercancel', () => this._stop())
  }

  // Live input waveform: rolling bars driven by mic RMS while recording, so
  // "listening" is visible at a glance (newest bar on the right, WhatsApp-style).
  _startWave(stream, session) {
    // Cosmetic — construction failure (no AudioContext) means flat bars,
    // never a broken recording. Autoplay-policy suspension is NOT such a
    // failure to swallow silently: it's exactly what fed real speech into the
    // gate as measured silence before, which is why `metered` is proven live,
    // per-frame, from an actually-running context (see tick) rather than
    // assumed the moment the graph is built.
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext
      const ctx = new Ctx()
      // Off-gesture (post-await) construction starts suspended on WebKit;
      // give it a chance to come up. No-op if already running; a rejection
      // (or a mock with no resume at all) is cosmetic-path noise, not ours to
      // surface — this call must never be able to break recording.
      try { ctx.resume().catch(() => {}) } catch { /* unsupported, ignore */ }
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
        const rms = Math.sqrt(sum / buf.length)
        // A suspended context returns a constant fake buffer forever — reads
        // identically to true silence — so a frame only proves metering once
        // it's actually sampled off a running context. _stop() can't check
        // this itself: by the time the gate runs, _stopWave() has already
        // closed the context, so the flag has to be earned here, live.
        if (ctx.state !== 'suspended') session.metered = true
        // dB for the gate, floor-relative; clamp rms to a plausible ~-100dB
        // floor instead of true digital-silence's ~-180dB — unclamped, that
        // floor reads as 100+dB of "signal" above it for ordinary ambient
        // noise, which only happens to be harmless because it errs open, not
        // because it's a meaningful measurement.
        session.levels.push(20 * Math.log10(Math.max(rms, 1e-5)))
        // ~3x boost: normal speech RMS is quiet; full bar ≈ loud voice.
        const level = Math.min(1, rms * 3)
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
    if (this._btn) this._setWarming(false)
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
    const session = {
      released: false, stream: null, rec: null, chunks: [], downAt: Date.now(),
      // levels: per-frame dB from the analyser; metered stays false unless a
      // frame is actually sampled off a running context, which makes the
      // gate fail OPEN (no AudioContext, autoplay-suspended, or too short).
      levels: [], metered: false,
    }
    this._session = session
    this._setWarming(true) // the device is opening — say so, don't imply capture
    this._runStart(session)
  }

  async _runStart(session) {
    let stream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      if (this._session === session) this._session = null
      this._setWarming(false)
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
    // Capture has actually begun: warming -> recording.
    this._setWarming(false)
    this._btn.classList.add('recording')
    this._startWave(stream, session)
  }

  async _stop() {
    const session = this._session
    if (!session) return
    this._session = null
    session.released = true
    if (!session.rec) { this._setWarming(false); return } // still warming; _runStart tears the stream down
    const { rec, stream } = session
    this._btn.classList.remove('recording')
    this._stopWave()
    const stopped = new Promise((res) => { rec.onstop = res; setTimeout(res, 5000) })
    rec.stop()
    await stopped
    stream.getTracks().forEach((t) => t.stop())
    if (Date.now() - session.downAt < CANCEL_MS) return // cancel tap
    // Held, but said nothing: the most common case is "still gathering my
    // thoughts". Silent no-op — no transcription, nothing typed, no alert.
    // Fails open with no level data at all (see _startWave) AND with too
    // little of it to judge (a short hold, or a throttled/low-power device
    // that never reaches SPEECH_FRAMES) — "not enough data" is the same
    // epistemic state as "no data", and only an unambiguous verdict of
    // silence gets to suppress a real transcription.
    if (session.metered
        && session.levels.length >= SPEECH_FRAMES
        && !hasSpeech(session.levels)) {
      this._emitNoSpeech('silence')
      return
    }
    try {
      this._btn.disabled = true
      this._setBusy(true) // "words on the way" — same signal as model load
      guardStart() // inference is the crash-prone span on WebKit
      const { text } = await this._t.transcribeBlob(new Blob(session.chunks, { type: 'audio/webm' }))
      // Whisper on near-silence hallucinates rather than returning "".
      if (isSilenceArtifact(text)) this._emitNoSpeech('artifact')
      else this.dispatchEvent(new CustomEvent('transcript', { detail: { text }, bubbles: true }))
    } catch (e) {
      this._emitError(e.message)
    } finally {
      guardEnd() // a JS error is NOT a crash — only an unreachable finally is
      this._setBusy(false)
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

  // Busy = model loading or a clip transcribing. Shows the shadow ring and
  // reflects a host `busy` attribute so consumers can drive their own
  // loading treatment (e.g. animating a slotted logo) from plain CSS.
  _setBusy(on) {
    this._ring.hidden = !on
    this.toggleAttribute('busy', on)
  }

  // Warming = the capture device is opening; audio is NOT being captured yet.
  // Deliberately separate from `busy` (model load / inference): a consumer's
  // loading treatment must not fire for two unrelated states.
  _setWarming(on) {
    this._btn.classList.toggle('warming', on)
    this.toggleAttribute('warming', on)
  }

  _emitError(message) {
    this.dispatchEvent(new CustomEvent('voice-error', { detail: { message }, bubbles: true }))
  }

  // Not an error: the user held the key and said nothing. Hosts decide
  // whether that deserves any UI at all — the bundled demo ignores it.
  _emitNoSpeech(reason) {
    this.dispatchEvent(new CustomEvent('no-speech', { detail: { reason }, bubbles: true }))
  }
}

if (!customElements.get('mictext-mic')) customElements.define('mictext-mic', MicTextMic)
