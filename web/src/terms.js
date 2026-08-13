// Learned vocabulary. Two uses for one list: the corrections bias Whisper's
// decoding up front (--prompt / initial prompt), and short pairs additionally
// rewrite the output when it still gets them wrong.
//
// Storage is local and stays local — localStorage here, ~/.mictext/terms.json
// on the desktop clients. Same JSON shape, so a file can be pasted between
// them. Nothing about this is ever uploaded.

const KEY = 'mictext-terms'

// Whisper's prompt window is 224 tokens and overflow is truncated FROM THE
// FRONT — an uncapped list would silently drop the newest terms, the exact
// opposite of what is wanted. Hence a cap, applied newest-first.
export const PROMPT_MAX_CHARS = 200

// Corrections longer than this are stored (they still bias) but are never
// used as literal replacements: rewriting a whole sentence off one past
// correction is far more likely to be wrong than right.
export const MAX_PAIR_WORDS = 6

const words = (s) => String(s || '').trim().split(/\s+/).filter(Boolean)

// The one normalization boundary in this file: loadTerms, promptFrom,
// applyTerms and learn all run their (caller-supplied, possibly malformed)
// terms array through this first, so "well-formed term" is defined once.
// Drops non-objects (null/undefined/primitives) and anything missing a
// usable heard/said; coerces heard/said to strings and n to a number —
// ALWAYS, even when the key is absent. Coercing it only when present is what
// produced `undefined + 1` -> NaN in learn(); in Lua the same gap is a hard
// runtime error on `prev.n + 1`, not a silent NaN.
// Plain loop, not a filter/map chain — must port as-is.
function normalizeTerms(arr) {
  const out = []
  if (!Array.isArray(arr)) return out
  for (const t of arr) {
    if (!t || typeof t !== 'object') continue // null, undefined, primitives
    // said: 0 or '' is unusable as replacement text, same as heard.
    // PORTABILITY (Lua): do NOT translate this literally. `not t.said` drops
    // nothing in Lua — only false and nil are falsy there, so 0 and "" both
    // survive and a said of 0 goes on to blank the matched text with "0".
    // Lua needs the tests spelled out:
    //   if t.heard == nil or t.heard == "" or t.heard == 0
    //      or t.said == nil or t.said == "" or t.said == 0 then goto continue end
    // AutoHotkey v2 agrees with JavaScript here, so checking only AHK misleads.
    if (!t.heard || !t.said) continue
    // Lua: copy with `for k, v in pairs(t) do term[k] = v end`; AHK v2: `.Clone()`
    const term = { ...t, heard: String(t.heard), said: String(t.said) }
    term.n = Number(t.n) || 0
    out.push(term)
  }
  return out
}

export function loadTerms() {
  try {
    return normalizeTerms(JSON.parse(localStorage.getItem(KEY)))
  } catch { return [] } // corrupt or unavailable storage = no vocabulary, never a crash
}

export function saveTerms(terms) {
  try { localStorage.setItem(KEY, JSON.stringify(terms)) } catch { /* private mode: learn nothing, break nothing */ }
}

// Newest first, de-duplicated, capped on a word boundary.
export function promptFrom(terms) {
  const list = normalizeTerms(terms)
  const seen = new Set()
  const out = []
  let len = 0
  for (let i = list.length - 1; i >= 0; i--) {
    for (const w of words(list[i].said)) {
      const k = w.toLowerCase()
      if (seen.has(k)) continue
      seen.add(k)
      const add = out.length ? w.length + 2 : w.length
      // Skip (don't abort) a word that doesn't fit: one oversized word
      // (e.g. a pasted correction with no spaces) must not zero out every
      // other term's bias words, which is worse than the truncation this
      // cap exists to prevent. Later, smaller words may still fit.
      if (len + add > PROMPT_MAX_CHARS) continue
      out.push(w)
      len += add
    }
  }
  return out.join(', ')
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// A pair is eligible to rewrite output only if it is short enough to be a
// term rather than a sentence, and specific enough not to hit common words:
// >=4 characters OR more than one word. Derived, never stored.
function replaceable(t) {
  const w = words(t.heard)
  return w.length > 0 && w.length <= MAX_PAIR_WORDS && (t.heard.trim().length >= 4 || w.length > 1)
}

// Sentinel used internally between pass 1 and pass 2 of applyTerms below.
// \x1F (ASCII Unit Separator) was chosen for CROSS-LANGUAGE safety, not just
// JS safety: it is a control character that never appears in a transcript,
// and it is not a \w character, so it can never satisfy a \b word-boundary —
// the SENTINEL CHARACTER itself is unmatchable by any heard pattern here.
// (The index digits sandwiched between the two sentinel characters ARE \w
// and so ARE \b-anchorable in principle — that part of the old claim was
// wrong. Reaching them needs an all-digit `heard` term AND more replaceable
// terms than that digit string's value, e.g. a heard of "7" with 8+
// replaceable terms loaded; unreachable in any realistic vocabulary, but
// that's a numbers argument, not "no pattern can ever match a sentinel".) Do
// NOT substitute \x00 (NUL) here when porting: AutoHotkey
// strings are null-terminated internally, so an embedded NUL silently
// truncates the string in win/mictext.ahk. \x1F has no such landmine in
// JavaScript, Lua, or AutoHotkey.
const SENTINEL = '\x1F'

export function applyTerms(text, terms) {
  let out = String(text == null ? '' : text)
  // Strip any sentinel already present in the input before pass 1 runs.
  // applyTerms is exported and general-purpose — its input is not
  // guaranteed to have come from Whisper. Without this strip, pass 2 below
  // would blindly index pairs[Number(i)] for ANY sentinel-shaped substring
  // it finds, trusting it was written by pass 1: an out-of-range index
  // crashes, an in-range index silently splices in an unrelated term's
  // `said` text. Stripping the sentinel here means every sentinel pass 2
  // ever sees was written by pass 1 moments ago — both failure modes become
  // unreachable from the INPUT side, not merely guarded. (A term whose own
  // `heard` contains a sentinel can still produce stray output; that needs a
  // control character in your own vocabulary file to reach.)
  // A porter must keep this strip.
  out = out.split(SENTINEL).join('')
  // Longest first, so "da he can bay" wins over "bay". Sort on the trimmed
  // heard length, not the padded length, to keep ordering consistent with
  // the pattern-building logic below.
  const pairs = normalizeTerms(terms).filter(replaceable).sort((a, b) => b.heard.trim().length - a.heard.trim().length)

  // Two passes, not one. Applying replacements longest-first stops a short
  // pattern from pre-empting a longer match in the ORIGINAL text (that part
  // is fine as a single pass), but nothing stops a short pattern from then
  // re-matching text a longer pattern already inserted — e.g. "york" would
  // match the "York" inside the "new york" -> "New York City" replacement,
  // yielding "New Yorkshire City". So pass 1 swaps every match for a numbered
  // sentinel (not the real text), and pass 2 swaps sentinels for the real
  // replacement text, so nothing chains. (See the SENTINEL comment above for
  // exactly how strong that guarantee is — the character is unmatchable, the
  // index digits between are unreachable rather than unmatchable.)
  pairs.forEach((t, i) => {
    // ponytail: \b is fine here — the heard side is dictated words. Phrases
    // that start or end in punctuation fall back to a bare match, which is
    // what you want for "c++ (plus)".
    //
    // PORTABILITY (Lua): the \b anchors, the 'i' flag, and \-escaping below
    // are PCRE/JS syntax. They port cleanly to AutoHotkey v2 (real PCRE —
    // see the function-replacer comment below) but NOT to Lua: Lua patterns
    // have no \b, no case-insensitive flag, and escape with % rather than \.
    // A Lua port needs %f[%w] / %f[%W] frontier patterns for word
    // boundaries, and, since there's no i flag, must fold each letter into a
    // two-case class itself (a -> [aA]). Escape metacharacters BEFORE
    // case-folding, not after: escaping introduces literal % characters and
    // folding only touches letters, so escape-then-fold leaves those %'s
    // alone — fold-then-escape would instead re-escape the [ and ] the
    // folding just introduced, corrupting the pattern.
    const heard = t.heard.trim()
    const body = escapeRe(heard)
    const lead = /^\w/.test(heard) ? '\\b' : ''
    const tail = /\w$/.test(heard) ? '\\b' : ''
    out = out.replace(new RegExp(`${lead}${body}${tail}`, 'gi'), () => `${SENTINEL}${i}${SENTINEL}`)
  })
  // Pass 2: swap sentinels for the real replacement text. The function form
  // is essential: a string form would reinterpret $& or $1 inside `said` as
  // regex backreferences instead of literal text. A porter to a language
  // without callback replacement must escape $ in the replacement text
  // instead — AutoHotkey v2's RegExReplace accepts only a string replacement
  // (no callback form), and $0-$9 / ${…} inside that string are still
  // interpreted, so $ must be escaped as $$ there.
  // Lua's string.gsub DOES take a function replacer — use it. If you reach
  // for the string form instead, note that % is the special character there,
  // so a `said` of "50%" raises "invalid use of '%' in replacement string".
  out = out.replace(new RegExp(`${SENTINEL}(\\d+)${SENTINEL}`, 'g'), (_, i) => pairs[Number(i)].said)
  return out
}

// ponytail: the list has no size cap, and applyTerms compiles one RegExp per
// replaceable term on every transcription — fine at realistic vocabulary
// sizes (tens to low hundreds of corrections). If it ever grows large enough
// for that per-call compile cost (or prompt-window pressure in promptFrom)
// to matter, cap it here — e.g. drop the least-recently-learned by `at`/`n`
// once over a ceiling — rather than reaching for a smarter data structure.
// Returns a NEW array. Persisting is the caller's job (saveTerms).
export function learn(terms, heard, said) {
  const h = String(heard || '').trim()
  const s = String(said || '').trim()
  const list = normalizeTerms(terms)
  if (!h || !s || h.toLowerCase() === s.toLowerCase()) return list
  const rest = list.filter((t) => t.heard.toLowerCase() !== h.toLowerCase())
  const prev = list.find((t) => t.heard.toLowerCase() === h.toLowerCase())
  // Newest last: promptFrom reads from the end, so a re-learned pair stays
  // at the front of the bias list.
  return [...rest, { heard: h, said: s, n: (prev ? prev.n : 0) + 1, at: new Date().toISOString() }]
}
