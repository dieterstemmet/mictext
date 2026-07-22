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

export function loadTerms() {
  try {
    const v = JSON.parse(localStorage.getItem(KEY))
    return Array.isArray(v) ? v.filter((t) => t && t.heard && t.said) : []
  } catch { return [] } // corrupt or unavailable storage = no vocabulary, never a crash
}

export function saveTerms(terms) {
  try { localStorage.setItem(KEY, JSON.stringify(terms)) } catch { /* private mode: learn nothing, break nothing */ }
}

// Newest first, de-duplicated, capped on a word boundary.
export function promptFrom(terms) {
  const seen = new Set()
  const out = []
  let len = 0
  for (let i = terms.length - 1; i >= 0; i--) {
    for (const w of words(terms[i].said)) {
      const k = w.toLowerCase()
      if (seen.has(k)) continue
      seen.add(k)
      const add = out.length ? w.length + 2 : w.length
      if (len + add > PROMPT_MAX_CHARS) return out.join(', ')
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

export function applyTerms(text, terms) {
  let out = String(text == null ? '' : text)
  // Longest first, so "da he can bay" wins over "bay".
  const pairs = terms.filter(replaceable).sort((a, b) => b.heard.length - a.heard.length)
  for (const t of pairs) {
    // ponytail: \b is fine here — the heard side is dictated words. Phrases
    // that start or end in punctuation fall back to a bare match, which is
    // what you want for "c++ (plus)".
    const body = escapeRe(t.heard.trim())
    const lead = /^\w/.test(t.heard.trim()) ? '\\b' : ''
    const tail = /\w$/.test(t.heard.trim()) ? '\\b' : ''
    out = out.replace(new RegExp(`${lead}${body}${tail}`, 'gi'), () => t.said)
  }
  return out
}

// Returns a NEW array. Persisting is the caller's job (saveTerms).
export function learn(terms, heard, said) {
  const h = String(heard || '').trim()
  const s = String(said || '').trim()
  if (!h || !s || h.toLowerCase() === s.toLowerCase()) return terms.slice()
  const rest = terms.filter((t) => t.heard.toLowerCase() !== h.toLowerCase())
  const prev = terms.find((t) => t.heard.toLowerCase() === h.toLowerCase())
  // Newest last: promptFrom reads from the end, so a re-learned pair stays
  // at the front of the bias list.
  return [...rest, { heard: h, said: s, n: (prev ? prev.n : 0) + 1, at: new Date().toISOString() }]
}
