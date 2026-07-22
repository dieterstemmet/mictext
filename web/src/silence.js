// Silence handling. Whisper fed near-silence does NOT return an empty string —
// it hallucinates ("[BLANK_AUDIO]", "you", "Thank you."). Two cheap layers:
// never transcribe a clip that carried no speech, and drop the known artifacts
// if one slips through anyway.

// dB above the clip's own noise floor that counts as speech, and how many such
// frames a real utterance needs. Physical-world knobs, not magic numbers: mic
// gain and input volume shift absolute RMS by 20+ dB across machines, so the
// threshold is relative to the floor, never an absolute dB value.
// (Keep in sync with mac/mictext.lua and win/mictext.ahk.)
export const SPEECH_DB = 12
export const SPEECH_FRAMES = 10

// levels: raw per-frame loudness in dB, any consistent scale. Callers pass
// their own `frames` when they sample at a different rate — desktop ffmpeg
// astats emits ~100 lines/s, the web analyser runs at ~60fps.
export function hasSpeech(levels, { db = SPEECH_DB, frames = SPEECH_FRAMES } = {}) {
  if (!levels || levels.length < frames) return false
  let floor = Infinity
  for (const v of levels) {
    // ffmpeg astats emits -inf for RMS_level on digitally silent frames; ignore non-finite
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
