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
    // n is normalized to a number even when the stored entry omits it, so
    // learn()'s count arithmetic can never see undefined.
    expect(terms).toEqual([{ heard: '123', said: 'abc', n: 0 }])
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

  // Round 2, Finding 4: the oversized-word skip (Finding 1 above) is only
  // pinned for a term whose ENTIRE said is one oversized word. This pins the
  // skip path within a single term: an oversized word mid-said must be
  // skipped without discarding the other, in-budget words of that SAME term.
  it('skips an oversized word within a term but keeps that term\'s other in-budget words', () => {
    const huge = 'x'.repeat(PROMPT_MAX_CHARS + 1)
    const terms = [term('h', `foo ${huge} bar`)]
    expect(promptFrom(terms)).toBe('foo, bar')
  })

  // Round 4, Finding 1: a null/undefined ELEMENT in the array (not a
  // malformed field) must not crash promptFrom. Well-formed entries
  // alongside it still contribute their words.
  it('ignores null and undefined elements instead of throwing', () => {
    const terms = [null, term('a', 'Alpha'), undefined, term('b', 'Bravo')]
    expect(() => promptFrom(terms)).not.toThrow()
    expect(promptFrom(terms)).toBe('Bravo, Alpha')
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

  // Round 2, Finding 1: applyTerms is exported/general-purpose, so its input
  // is not guaranteed to be free of the internal sentinel (\x1F) pass 1/2
  // use to avoid cross-pair chaining. Pass 2 must not trust a sentinel it
  // didn't write itself: an out-of-range index must not crash, and an
  // in-range index must not splice in an unrelated term's `said` text.
  it('does not crash on sentinel-shaped input with an out-of-range index', () => {
    const terms = [term('new york', 'New York City'), term('foo bar', 'nope')]
    expect(() => applyTerms('weird \x1F5\x1F text', terms)).not.toThrow()
  })

  it('does not let sentinel-shaped input splice in an unrelated term (in-range index)', () => {
    const terms = [term('new york', 'New York City'), term('foo bar', 'nope')]
    const result = applyTerms('weird \x1F0\x1F text', terms)
    expect(result).not.toContain('New York City')
    expect(result).toBe('weird 0 text')
  })

  // Round 3, Finding 1: applyTerms is exported/general-purpose, so its input
  // is not guaranteed to be free of non-string heard/said. A caller-supplied
  // array may have non-string values (e.g. a bare number) that would crash
  // downstream in replaceable() or in the regex-building loop without coercion.
  it('coerces non-string heard when it would otherwise crash', () => {
    expect(() => applyTerms('12345 test', [{ heard: 12345, said: 'abc', n: 1, at: 'x' }])).not.toThrow()
  })

  // Round 4, Finding 1: a null/undefined ELEMENT in the array must not
  // crash applyTerms; the well-formed entry alongside it still replaces.
  it('ignores null and undefined elements in the terms array instead of throwing', () => {
    const terms = [null, term('oak en field', 'Oakenfield'), undefined]
    expect(() => applyTerms('we went to oak en field', terms)).not.toThrow()
    expect(applyTerms('we went to oak en field', terms)).toBe('we went to Oakenfield')
  })

  // Round 4, Finding 1 (related bug): applyTerms' own coercion used to write
  // `String(t.said || '')`, unlike loadTerms' bare `String(t.said)` — a
  // falsy-but-real `said: 0` silently became '' there, blanking the
  // replacement instead of being treated consistently as unusable input.
  // The consolidated helper drops it like loadTerms always would, so the
  // heard text is left alone rather than corrupted.
  it('treats a said:0 entry as unusable rather than blanking the replacement', () => {
    const terms = [{ heard: 'mati', said: 0, n: 1, at: 'x' }]
    expect(applyTerms('we went to mati today', terms)).toBe('we went to mati today')
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

  // Round 2, Finding 3: learn() is handed a caller-supplied array, not
  // necessarily one that came through loadTerms()'s coercion. A raw
  // non-string heard on an existing entry must not crash learn().
  it('coerces a non-string heard on an existing entry instead of crashing', () => {
    const terms = [{ heard: 123, said: 'abc', n: 1, at: '2026-01-01T00:00:00.000Z' }]
    expect(() => learn(terms, 'foo', 'bar')).not.toThrow()
  })

  // Round 4, Finding 1: a null/undefined ELEMENT in the existing terms array
  // must not crash learn(); the well-formed entry alongside it is preserved.
  it('ignores null and undefined elements in the existing terms array instead of throwing', () => {
    const terms = [null, term('a', 'Alpha'), undefined]
    expect(() => learn(terms, 'b', 'Bravo')).not.toThrow()
    const t = learn(terms, 'b', 'Bravo')
    expect(t.map((x) => x.heard)).toEqual(['a', 'b'])
  })

  // Round 4, Finding 1 (related bug): `(prev ? prev.n : 0) + 1` assumed
  // prev.n was numeric; a string n from a hand-edited file used to
  // string-concatenate ("5" + 1 -> "51") instead of incrementing.
  it('coerces a numeric-string n instead of string-concatenating on re-learn', () => {
    const terms = [{ heard: 'oak en field', said: 'Oakenfield', n: '5', at: 'x' }]
    const t = learn(terms, 'oak en field', 'Oakenfield')
    expect(t[0].n).toBe(6)
  })

  // Round 5, Finding 1: an entry with no `n` key at all passes through
  // normalizeTerms untouched, so `(prev ? prev.n : 0) + 1` evaluates
  // `undefined + 1` = NaN. learn() must coerce n unconditionally.
  it('produces numeric n even when the existing entry has no n key', () => {
    const terms = [{ heard: 'oak en field', said: 'Oakenfield', at: 'x' }]
    const t = learn(terms, 'oak en field', 'Oakenfield')
    expect(typeof t[0].n).toBe('number')
    expect(t[0].n).toBe(1)
  })

  // Round 5, Finding 2: learn() returns early on the no-op path before
  // calling normalizeTerms(), so a null or malformed input is handed straight
  // back. If the caller saves this unfiltered, it re-persists junk. learn()
  // must normalize before the early return.
  it('normalizes a no-op input instead of handing back junk', () => {
    expect(learn(null, 'a', 'a')).toEqual([])
  })

  it('normalizes a malformed array before the no-op return', () => {
    const result = learn([null, 3, { heard: 1, said: 2 }], 'hello', 'hello')
    // null and 3 are filtered; { heard: 1, said: 2 } survives (both truthy)
    // and is normalized to { heard: '1', said: '2', n: 0 }
    expect(result.length).toBe(1)
    expect(result[0].heard).toBe('1')
    expect(result[0].said).toBe('2')
  })
})

describe('applyTerms (round 5 Finding 4)', () => {
  // Round 5, Finding 4: longest-match-first sorts on untrimmed heard length,
  // but patterns are built from trimmed heard. A whitespace-padded entry
  // breaks the order: a "          bayside          " (28 chars) sorts before
  // "bayside bay" (11 chars) even though the pattern for "bayside" is only
  // 8 chars and should match last.
  it('sorts longest-match-first on the trimmed length, not the padded length', () => {
    const terms = [
      { heard: '          bayside          ', said: 'BAYSIDE', n: 1, at: 'x' },
      { heard: 'bayside bay', said: 'Bayside Bay', n: 1, at: 'x' },
    ]
    const result = applyTerms('at bayside bay', terms)
    expect(result).toBe('at Bayside Bay')
  })
})
