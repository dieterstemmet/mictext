// Silence handling. Whisper fed near-silence does NOT return an empty string —
// it hallucinates ("[BLANK_AUDIO]", "you", "Thank you."). Two cheap layers:
// never transcribe a clip that carried no speech, and drop the known artifacts
// if one slips through anyway.

// dB above the clip's own noise floor that counts as speech, and how many such
// frames a real utterance needs. Physical-world knobs, not magic numbers: mic
// gain and input volume shift absolute RMS by 20+ dB across machines, so the
// threshold is relative to the floor, never an absolute dB value.
// Keep in sync with mac/mictext.lua and win/mictext.ahk — SAME gate (db,
// frames), but NOT the same floor. hasSpeech() below takes the floor as the
// MINIMUM OVER THE WHOLE CLIP, because the web has no rolling window to
// borrow one from. The planned desktop ports instead take the floor as the
// minimum of their existing ~1.3s ROLLING WINDOW (already maintained for the
// waveform meter) — free there, since the window already exists. On a long
// hold with drifting ambient noise the two floors can genuinely differ. This
// is intended divergence, not drift: do not "fix" one to match the other.
export const SPEECH_DB = 12
export const SPEECH_FRAMES = 10

// Speech is a DURATION, not a frame count. Frame rate varies — the desktop
// clients read ffmpeg astats at a fixed ~10ms/frame, but the web analyser is
// rAF-driven and throttles from ~60fps to 30fps (or lower) on background tabs
// and weak devices — so a fixed frame count is a moving duration: 10 frames is
// 100ms at the desktop rate but 167ms at 60fps and 333ms at 30fps, each
// silently dropping a real word shorter than that. framesForRate() converts a
// measured per-frame interval into the frame count that spans SPEECH_SPAN_MS,
// so the threshold is the same amount of speech regardless of rate. Floored at
// 3 (a fluke can't trip it) and capped at SPEECH_FRAMES (never stricter than
// the desktop default). Desktop's fixed ~10ms/frame yields SPEECH_FRAMES here,
// so the ports can keep passing the constant directly.
export const SPEECH_SPAN_MS = 100
export function framesForRate(frameMs) {
  if (!Number.isFinite(frameMs) || frameMs <= 0) frameMs = 1000 / 60
  return Math.min(SPEECH_FRAMES, Math.max(3, Math.round(SPEECH_SPAN_MS / frameMs)))
}

// levels: raw per-frame loudness in dB, any consistent scale. Callers pass
// their own `frames` when they sample at a different rate — desktop ffmpeg
// astats emits ~100 lines/s, the web analyser runs at ~60fps.
export function hasSpeech(levels, { db = SPEECH_DB, frames = SPEECH_FRAMES } = {}) {
  if (!levels || levels.length < frames) return false
  let floor = Infinity
  for (const v of levels) {
    // ffmpeg astats emits -inf for RMS_level on digitally silent frames; ignore non-finite.
    // PORTABILITY: this guard cannot be copied literally — both desktop
    // clients tail exactly the astats stream that produces -inf, and it
    // fires on the FIRST digitally-silent frame, precisely the case this
    // gate exists to handle:
    //   Lua: tonumber("-inf") returns nil, and comparing/arithmetic on that
    //     nil is a hard "attempt to perform arithmetic on a nil value" error
    //     — guard with `if not db then return end` (skip the nil, don't
    //     crash) before using it.
    //   AutoHotkey v2: arithmetic on a non-numeric string throws a TypeError
    //     — guard with an `IsNumber()` check before using it.
    if (Number.isFinite(v) && v < floor) floor = v
  }
  let n = 0
  for (const v of levels) {
    if (Number.isFinite(v) && v - floor > db) n += 1
    if (n >= frames) return true
  }
  return false
}

// ponytail: a flat literal set, not a regex — the match is on the ENTIRE
// trimmed transcript, so "thank you for the ride" can never be swallowed.
const ARTIFACTS = new Set([
  '', '.', '..', '...',
  '[blank_audio]', '(blank_audio)', '[silence]', '(silence)', '[ silence ]',
  'you', 'thank you', 'thank you.', 'thanks for watching!', 'thanks for watching.',
  'bye.', 'bye',
])

export function isSilenceArtifact(text) {
  return ARTIFACTS.has(String(text == null ? '' : text).trim().toLowerCase())
}
