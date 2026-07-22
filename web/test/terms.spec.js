import { describe, it, expect, beforeEach } from 'vitest'
import {
  loadTerms, saveTerms, promptFrom, applyTerms, learn,
  PROMPT_MAX_CHARS, MAX_PAIR_WORDS,
} from '../src/terms.js'

const term = (heard, said) => ({ heard, said, n: 1, at: '2026-07-22T00:00:00.000Z' })

describe('storage', () => {
  beforeEach(() => localStorage.clear())

  it('returns an empty list when nothing is stored', () => {
    expect(loadTerms()).toEqual([])
  })

  it('round-trips through localStorage', () => {
    const t = [term('oak en field', 'Oakenfield')]
    saveTerms(t)
    expect(loadTerms()).toEqual(t)
  })

  it('survives corrupt storage rather than throwing', () => {
    localStorage.setItem('mictext-terms', 'not json')
    expect(loadTerms()).toEqual([])
  })

  it('ignores stored values of the wrong shape', () => {
    localStorage.setItem('mictext-terms', '{"heard":"x"}')
    expect(loadTerms()).toEqual([])
  })

  // Finding 4: the shape filter is truthiness-only, so a hand-edited or
  // cross-platform-pasted file with non-string heard/said survives the
  // filter and would crash downstream in replaceable()/applyTerms() at
  // `t.heard.trim()`. Coerce to strings at load time instead.
  it('coerces non-string heard/said instead of letting them crash a consumer', () => {
    localStorage.setItem('mictext-terms', JSON.stringify([{ heard: 123, said: 'abc' }]))
    const terms = loadTerms()
    expect(terms).toEqual([{ heard: '123', said: 'abc' }])
    expect(() => applyTerms('123 test', terms)).not.toThrow()
  })
})

describe('promptFrom', () => {
  it('is empty for no terms', () => {
    expect(promptFrom([])).toBe('')
  })

  it('lists the words of the corrections, most recent first', () => {
    const terms = [term('wim ble ton', 'Wimbleton'), term('oak en field', 'Oakenfield')]
    expect(promptFrom(terms)).toBe('Oakenfield, Wimbleton')
  })

  it('de-duplicates words across entries', () => {
    const terms = [term('a', 'Oakenfield beach'), term('b', 'Oakenfield')]
    expect(promptFrom(terms)).toBe('Oakenfield, beach')
  })

  it('caps at PROMPT_MAX_CHARS without cutting a word in half', () => {
    const terms = Array.from({ length: 100 }, (_, i) => term(`h${i}`, `Word${i}`))
    const p = promptFrom(terms)
    expect(p.length).toBeLessThanOrEqual(PROMPT_MAX_CHARS)
    expect(p.endsWith(',')).toBe(false)
    expect(p).not.toMatch(/Wor$/)
  })

  it('keeps the NEWEST terms when it has to cut (whisper truncates from the front)', () => {
    const terms = Array.from({ length: 100 }, (_, i) => term(`h${i}`, `Word${i}`))
    expect(promptFrom(terms).startsWith('Word99')).toBe(true)
  })

  // Finding 1: one oversized (unbroken) word must not zero out the whole
  // prompt. The oversized word itself is skipped; everything else that
  // fits should still make it in.
  it('skips a single oversized word instead of discarding every other term', () => {
    const huge = 'x'.repeat(PROMPT_MAX_CHARS + 1)
    const terms = [term('a', 'Ordinary'), term('b', huge)]
    expect(promptFrom(terms)).toBe('Ordinary')
  })

  // Finding 5: pin the exact-boundary case (0 + 200 > 200 is false, so a
  // first word of exactly PROMPT_MAX_CHARS chars is included whole).
  it('includes a first word of exactly PROMPT_MAX_CHARS characters', () => {
    const word = 'w'.repeat(PROMPT_MAX_CHARS)
    const terms = [term('h', word)]
    expect(promptFrom(terms)).toBe(word)
  })
})

describe('applyTerms', () => {
  it('replaces a learned phrase, case-insensitively', () => {
    const terms = [term('oak en field', 'Oakenfield')]
    expect(applyTerms('we surfed at oak en field today', terms)).toBe('we surfed at Oakenfield today')
    expect(applyTerms('Oak En Field is windy', terms)).toBe('Oakenfield is windy')
  })

  it('respects word boundaries', () => {
    const terms = [term('mati', 'Mati')]
    expect(applyTerms('automatic', terms)).toBe('automatic')
  })

  it('never learns a replacement for a short single word (guards common words)', () => {
    const terms = [term('you', 'Yu')]
    expect(applyTerms('can you hear me', terms)).toBe('can you hear me')
  })

  it('allows a short MULTI-word pair', () => {
    const terms = [term('a b', 'AB')]
    expect(applyTerms('say a b now', terms)).toBe('say AB now')
  })

  it('ignores entries longer than MAX_PAIR_WORDS (bias only, never replace)', () => {
    const long = Array.from({ length: MAX_PAIR_WORDS + 1 }, (_, i) => `w${i}`).join(' ')
    const terms = [term(long, 'short')]
    expect(applyTerms(`x ${long} y`, terms)).toBe(`x ${long} y`)
  })

  it('applies the longest match first', () => {
    const terms = [term('bay', 'Bay'), term('oak en field bay', 'Oakenfield Bay')]
    expect(applyTerms('at oak en field bay', terms)).toBe('at Oakenfield Bay')
  })

  it('is safe with regex metacharacters in the heard text', () => {
    const terms = [term('c++ (plus)', 'C++')]
    expect(applyTerms('I write c++ (plus) code', terms)).toBe('I write C++ code')
  })

  it('leaves text untouched when there are no terms', () => {
    expect(applyTerms('hello there', [])).toBe('hello there')
  })

  // Finding 2: a shorter pair must not re-match text a longer pair just
  // produced. Longest-first ordering correctly protects the ORIGINAL text
  // (see "applies the longest match first" above) but a naive sequential
  // apply lets "york" re-match the "York" inside the replacement text that
  // "new york" -> "New York City" just inserted.
  it('does not let a shorter pair re-match text a longer pair just inserted', () => {
    const terms = [term('new york', 'New York City'), term('york', 'Yorkshire')]
    expect(applyTerms('I love new york', terms)).toBe('I love New York City')
  })

  // Finding 3: regression guard for the function-replacer form. A string
  // replacement would reinterpret $& / $1 inside `said`; the function form
  // must not.
  it('inserts $ sequences in the replacement text literally', () => {
    const terms = [term('foo bar', '$& and $1')]
    expect(applyTerms('say foo bar now', terms)).toBe('say $& and $1 now')
  })
})

describe('learn', () => {
  it('appends a new pair', () => {
    const t = learn([], 'oak en field', 'Oakenfield')
    expect(t.length).toBe(1)
    expect(t[0].heard).toBe('oak en field')
    expect(t[0].said).toBe('Oakenfield')
    expect(t[0].n).toBe(1)
    expect(typeof t[0].at).toBe('string')
  })

  it('bumps n and freshens an existing pair instead of duplicating', () => {
    const first = learn([], 'oak en field', 'Oakenfield')
    const second = learn(first, 'Oak En Field', 'Oakenfield')
    expect(second.length).toBe(1)
    expect(second[0].n).toBe(2)
  })

  it('moves a re-learned pair to the end so it stays newest', () => {
    let t = learn([], 'a', 'Alpha')
    t = learn(t, 'b', 'Bravo')
    t = learn(t, 'a', 'Alpha')
    expect(t.map((x) => x.said)).toEqual(['Bravo', 'Alpha'])
  })

  it('stores a long correction too — it contributes bias words even with no replacement', () => {
    const long = 'one two three four five six seven'
    const t = learn([], long, 'a much better sentence entirely here')
    expect(t.length).toBe(1)
    expect(applyTerms(long, t)).toBe(long)          // too long to replace
    expect(promptFrom(t)).toContain('sentence')     // but it still biases
  })

  it('does not mutate the array it was given', () => {
    const orig = []
    learn(orig, 'a', 'Alpha')
    expect(orig).toEqual([])
  })

  it('ignores a correction identical to what was heard', () => {
    expect(learn([], 'hello', 'hello')).toEqual([])
    expect(learn([], 'hello', '  Hello  ')).toEqual([])
  })

  it('ignores empty input on either side', () => {
    expect(learn([], '', 'Oakenfield')).toEqual([])
    expect(learn([], 'oak en field', '   ')).toEqual([])
  })
})
