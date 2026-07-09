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
// The marker is a timestamp: a STALE marker means the tab was closed mid-work
// (download on a slow link, user gave up) — that's not a crash, so it's
// cleared and the device gets another chance.
const PROBE_KEY = 'mictext-probe'
const PROBE_FRESH_MS = 120000
let probeGuards = 0

function probeRead() {
  try { return localStorage.getItem(PROBE_KEY) } catch { return null }
}
function probeWrite(v) {
  try {
    if (v === null) localStorage.removeItem(PROBE_KEY)
    else localStorage.setItem(PROBE_KEY, v)
  } catch { /* no storage = no probe, attempt anyway */ }
}
// load() and transcribeBlob() overlap (transcribe awaits load), so the marker
// is refcounted: it clears only when the LAST risky span finishes.
function guardStart() {
  probeGuards += 1
  probeWrite(String(Date.now()))
}
function guardEnd() {
  probeGuards = Math.max(0, probeGuards - 1)
  if (probeGuards === 0) probeWrite(null)
}
// Returns true when this device is (now) blocked from on-device attempts.
function probeBlocked() {
  const marker = probeRead()
  if (marker === 'blocked') return true
  if (marker) {
    if (Date.now() - (Number(marker) || 0) < PROBE_FRESH_MS) {
      probeWrite('blocked') // fresh marker at boot = last attempt crashed the tab
      return true
    }
    probeWrite(null) // stale = closed mid-work, not a crash
  }
  return false
}

class MicTextMic extends HTMLElement {
  connectedCallback() {
    this._disconnected = false
    if (this.shadowRoot) return // reconnect: shadow root + listeners already set up

    this.attachShadow({ mode: 'open' }).innerHTML = `
      <style>
        button { border: none; border-radius: 50%; width: 2.5rem; height: 2.5rem;
                 cursor: pointer; background: #eee; font-size: 1.1rem; }
        button.recording { background: #e33; }
        button:disabled { opacity: .5; cursor: default; }
      </style>
      <button type="button" title="Hold to talk">🎤</button>`
    this._btn = this.shadowRoot.querySelector('button')

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
      this._emitError('On-device transcription previously crashed this device — mic disabled')
      return
    }

    this._t = createTranscriber(opts)
    // Kick off the (cached) model load early, hide if the device can't run it.
    // The load includes a benchmark inference — crash-guard the whole span.
    guardStart()
    this._t.load()
      .then(() => { if (this._t.mode === 'unsupported') this.hidden = true })
      .finally(guardEnd)

    this.addEventListener('pointerdown', () => this._start())
    this.addEventListener('pointerup', () => this._stop())
    this.addEventListener('pointerleave', () => this._stop())
    this.addEventListener('pointercancel', () => this._stop())
  }

  disconnectedCallback() {
    this._disconnected = true
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
    if (this._session) return // already recording / awaiting permission
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
  }

  async _stop() {
    const session = this._session
    if (!session) return
    this._session = null
    session.released = true
    if (!session.rec) return // getUserMedia still pending; _runStart will tear it down
    const { rec, stream } = session
    this._btn.classList.remove('recording')
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
    probeWrite(null)
  }

  _emitError(message) {
    this.dispatchEvent(new CustomEvent('voice-error', { detail: { message }, bubbles: true }))
  }
}

if (!customElements.get('mictext-mic')) customElements.define('mictext-mic', MicTextMic)
