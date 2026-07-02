import { createTranscriber } from './transcriber.js'

const CANCEL_MS = 300

class FlexVoiceMic extends HTMLElement {
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
    this._t = createTranscriber(opts)
    // Kick off the (cached) model load early, hide if the device can't run it.
    this._t.load().then(() => { if (this._t.mode === 'unsupported') this.hidden = true })

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
      const { text } = await this._t.transcribeBlob(new Blob(session.chunks, { type: 'audio/webm' }))
      if (text) this.dispatchEvent(new CustomEvent('transcript', { detail: { text }, bubbles: true }))
    } catch (e) {
      this._emitError(e.message)
    } finally {
      this._btn.disabled = false
    }
  }

  _emitError(message) {
    this.dispatchEvent(new CustomEvent('voice-error', { detail: { message }, bubbles: true }))
  }
}

if (!customElements.get('flex-voice-mic')) customElements.define('flex-voice-mic', FlexVoiceMic)
