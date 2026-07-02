import { createTranscriber } from './transcriber.js'

const CANCEL_MS = 300

class FlexVoiceMic extends HTMLElement {
  connectedCallback() {
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
  }

  disconnectedCallback() { if (this._t) this._t.dispose() }

  async _start() {
    this._downAt = Date.now()
    this._chunks = []
    try {
      this._stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      this._emitError('Microphone unavailable')
      return
    }
    this._rec = new MediaRecorder(this._stream)
    this._rec.ondataavailable = (ev) => { if (ev.data && ev.data.size) this._chunks.push(ev.data) }
    this._rec.start()
    this._btn.classList.add('recording')
  }

  async _stop() {
    if (!this._rec) return
    const rec = this._rec
    this._rec = null
    this._btn.classList.remove('recording')
    const stopped = new Promise((res) => { rec.onstop = res; setTimeout(res, 5000) })
    rec.stop()
    await stopped
    if (this._stream) { this._stream.getTracks().forEach((t) => t.stop()); this._stream = null }
    if (Date.now() - this._downAt < CANCEL_MS) return // cancel tap
    try {
      this._btn.disabled = true
      const { text } = await this._t.transcribeBlob(new Blob(this._chunks, { type: 'audio/webm' }))
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
