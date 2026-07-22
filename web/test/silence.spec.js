import { describe, it, expect } from 'vitest'
import { hasSpeech, isSilenceArtifact, SPEECH_DB, SPEECH_FRAMES } from '../src/silence.js'

// Levels are raw per-frame loudness in dB. Absolute values are meaningless
// across machines (mic gain shifts them 20+ dB), so every case here is built
// as "a floor, plus something above it".
const flat = (n, v) => Array(n).fill(v)

describe('hasSpeech', () => {
  it('is false for a flat room tone at any absolute level', () => {
    expect(hasSpeech(flat(200, -60))).toBe(false)
    expect(hasSpeech(flat(200, -20))).toBe(false)
  })

  it('is false for ambient wiggle below the threshold', () => {
    const levels = Array.from({ length: 200 }, (_, i) => -60 + (i % 5))
    expect(hasSpeech(levels)).toBe(false)
  })

  it('is false for a single loud transient (a door slam is not a sentence)', () => {
    const levels = flat(200, -60)
    for (let i = 100; i < 104; i++) levels[i] = -20 // 4 frames, under SPEECH_FRAMES
    expect(hasSpeech(levels)).toBe(false)
  })

  it('is true once enough frames clear the floor by SPEECH_DB', () => {
    const levels = flat(200, -60)
    for (let i = 100; i < 100 + SPEECH_FRAMES; i++) levels[i] = -60 + SPEECH_DB + 1
    expect(hasSpeech(levels)).toBe(true)
  })

  it('is false when frames clear the floor by less than SPEECH_DB', () => {
    const levels = flat(200, -60)
    for (let i = 100; i < 150; i++) levels[i] = -60 + SPEECH_DB - 1
    expect(hasSpeech(levels)).toBe(false)
  })

  it('is false for a clip shorter than the frame requirement', () => {
    expect(hasSpeech([-60, -10, -10])).toBe(false)
  })

  it('is false for no data at all', () => {
    expect(hasSpeech([])).toBe(false)
  })

  it('honours per-client frame counts (desktop and web sample at different rates)', () => {
    const levels = flat(50, -60)
    for (let i = 10; i < 15; i++) levels[i] = -30
    expect(hasSpeech(levels, { frames: 5 })).toBe(true)
    expect(hasSpeech(levels, { frames: 20 })).toBe(false)
  })

  it('ignores non-finite frames (astats emits -inf on digital silence)', () => {
    const levels = flat(50, -60)
    levels[25] = -Infinity
    expect(hasSpeech(levels)).toBe(false)
  })

  it('honours custom db threshold override', () => {
    const levels = flat(50, -60)
    for (let i = 10; i < 20; i++) levels[i] = -60 + 12 + 1 // strictly > 12 dB above floor
    expect(hasSpeech(levels, { db: 12 })).toBe(true)
    expect(hasSpeech(levels, { db: 13 })).toBe(false)
  })
})

describe('isSilenceArtifact', () => {
  it('catches whisper silence hallucinations', () => {
    for (const t of ['[BLANK_AUDIO]', '(silence)', 'you', 'Thank you.', 'Thanks for watching!', '.']) {
      expect(isSilenceArtifact(t)).toBe(true)
    }
  })

  it('is case- and whitespace-insensitive', () => {
    expect(isSilenceArtifact('  [blank_audio]  ')).toBe(true)
    expect(isSilenceArtifact('THANK YOU.')).toBe(true)
  })

  it('treats empty and whitespace-only output as an artifact', () => {
    expect(isSilenceArtifact('')).toBe(true)
    expect(isSilenceArtifact('   ')).toBe(true)
  })

  it('matches the WHOLE transcript only — a real sentence containing "you" survives', () => {
    expect(isSilenceArtifact('can you hear me')).toBe(false)
    expect(isSilenceArtifact('thank you for the ride')).toBe(false)
    expect(isSilenceArtifact('you know what I mean')).toBe(false)
  })
})
