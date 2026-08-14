-- MicText: hold right-option, speak, release -> text typed at the cursor.
-- Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves the Mac.
local M = {}

local HOME = os.getenv("HOME")
local MODEL = HOME .. "/.mictext/models/ggml-base.en.bin"
local WAV = "/tmp/mictext.wav"
local RIGHT_OPT = 61 -- keycode for right option
local MIN_MS = 300   -- taps shorter than this are cancels
-- Silence gate (keep in sync with win/mictext.ahk and web/src/silence.js):
-- dB above the rolling-window floor that counts as speech, and how many such
-- frames a real utterance needs (~100ms at astats' ~100 lines/s). Relative,
-- never absolute — mic gain shifts absolute RMS 20+ dB across machines. The
-- web reference derives the frame count from its variable rAF rate; astats is
-- fixed-rate, so the desktop clients pass SPEECH_FRAMES directly (see the
-- framesForRate note in silence.js).
local SPEECH_DB = 12
local SPEECH_FRAMES = 10
-- avfoundation input device by name (index :0 may be a virtual/silent device).
-- List devices: ffmpeg -f avfoundation -list_devices true -i ""
local MIC = "MacBook Pro Microphone"

local function bin(name)
  for _, p in ipairs({ "/opt/homebrew/bin/", "/usr/local/bin/" }) do
    if hs.fs.attributes(p .. name) then return p .. name end
  end
  return name
end

local recTask, downAt, cancelled = nil, nil, false
local capturing = false -- true once ffmpeg has actually opened the device
local menubar = hs.menubar.new()
-- Three states, because two of them lied: "warming" is the ~0.5-2s the capture
-- device takes to open on the first press of a session, during which nothing
-- is recorded. Showing 🔴 for it costs the user their first words.
local function setIcon(state)
  menubar:setTitle(state == "rec" and "🔴" or state == "warm" and "🎙…" or "🎙")
end
setIcon("idle")

-- Live waveform HUD (tuning constants: keep in sync with win/mictext.ahk): rolling RMS bars (matches the web mic's look). Levels
-- come free from the SAME recording ffmpeg via the pass-through astats
-- filter — the captured audio is untouched, ffmpeg just also prints RMS.
local BARS = 14
local TICK = 0.07 -- bar shift period: BARS * TICK ~= 1s of visible history
local hud, levels, latest, env, meterTimer = nil, {}, 0, 0, nil

-- Adaptive level range: a fixed dB window doesn't transfer across machines
-- (mic gain / input volume shift absolute RMS by 20+ dB). Normalize against
-- the min/max of the last ~1.3s of raw dB instead: the window min tracks the
-- ambient floor via inter-word dips, the max tracks syllable peaks, and any
-- outlier self-expires when it scrolls out. No decay constants to tune.
local recent, RECENT = {}, 130 -- ~1.3s at ~100 RMS lines/s
local speechFrames = 0 -- frames this recording that cleared the window floor by SPEECH_DB
local seen, SKIP = 0, 30 -- astats' first ~0.3s ramps to digital-zero junk
local hiSeen -- session memory of the voice's ceiling (persists across recordings)

local function drawBars()
  if not hud then return end
  for i = 1, BARS do
    -- Reference proportions: thin bars (3px), wide gaps, rounded ends,
    -- centered vertically. Min 2px so silence reads as a dot line.
    -- 1-2-1 blur across neighbors rounds the wave into an organic curve.
    local c = levels[i] or 0
    local v = ((levels[i-1] or c) + 2 * c + (levels[i+1] or c)) / 4
    local bh = 2 + v * 18
    hud[i + 1] = {
      type = "rectangle", action = "fill",
      fillColor = { red = 1, green = 1, blue = 1, alpha = 1 },
      frame = { x = 10 + (i - 1) * 11, y = (26 - bh) / 2, w = 3, h = bh },
      roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
    }
  end
end

local function hideHud()
  if meterTimer then meterTimer:stop(); meterTimer = nil end
  if hud then hud:delete(); hud = nil end
end

local function showHud()
  hideHud() -- never orphan a shown canvas by overwriting the reference
  local f = hs.screen.mainScreen():frame()
  -- Notch-sized lozenge (~200x32) bottom-center: thin bars, wide gaps,
  -- fully rounded ends — exact reference proportions.
  local w = 17 + BARS * 11
  hud = hs.canvas.new({ x = f.x + (f.w - w) / 2, y = f.y + f.h - 26 - 24, w = w, h = 26 })
  hud[1] = {
    type = "rectangle", action = "fill",
    -- Dim while warming: the pill is visible (the press registered) but the
    -- bars are absent, because there is no audio to draw yet.
    fillColor = { red = 0.02, green = 0.02, blue = 0.02, alpha = 0.45 },
    roundedRectRadii = { xRadius = 13, yRadius = 13 },
  }
  levels = {}
  for i = 1, BARS do levels[i] = 0 end
  latest, env, recent, seen, speechFrames = 0, 0, {}, 0, 0
  hud:show()
end

-- First real audio frame: the pill goes solid and the bars start moving. Called
-- from the astats stream callback the moment ffmpeg's first RMS line arrives.
local function hudLive()
  if not hud then return end
  hud[1].fillColor = { red = 0.02, green = 0.02, blue = 0.02, alpha = 0.95 }
  drawBars()
  meterTimer = hs.timer.doEvery(TICK, function()
    -- Attack/release envelope follower: rise fast on syllables (70ms), fall
    -- smoothly on silence (~280ms). Kills raw RMS jitter without lag, and
    -- silence drop-off comes free from the release side.
    env = env + (latest - env) * (latest > env and 0.7 or 0.4)
    table.remove(levels, 1)
    levels[#levels + 1] = env
    drawBars()
  end)
end

local function pushLevel(db)
  -- Only remember the newest level: ffmpeg's stdout arrives in buffered
  -- bursts of near-identical adjacent frames, so shifting the window per
  -- line made all bars show the same instant (the meter pulsed in unison).
  -- The meter timer samples this on a fixed clock instead.
  seen = seen + 1
  if not db or seen <= SKIP then latest = 0; return end
  recent[#recent + 1] = db
  if #recent > RECENT then table.remove(recent, 1) end
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(recent) do
    lo = math.min(lo, v); hi = math.max(hi, v)
  end
  -- Silence gate: count frames well above the clip's own rolling floor.
  -- Cheap, and it reuses the window the meter already maintains. `db` is
  -- never nil here — astats' -inf digital-silence frames arrive as nil and
  -- return early above (`if not db`), so they never reach this count.
  if db - lo > SPEECH_DB then speechFrames = speechFrames + 1 end
  -- While the window is young every syllable IS its own maximum, which
  -- pegged the first second of wave at full height. Assume a full speech
  -- range until the window matures, and remember the voice's real ceiling
  -- (slow decay) so later recordings are calibrated from the first word.
  if #recent == RECENT then hiSeen = math.max(hi, (hiSeen or hi) - 0.002) end
  hi = math.max(hi, hiSeen or (lo + 40))
  -- 6dB gate above the window floor keeps ambient wiggle flat; 12dB min
  -- span stops quiet rooms from amplifying noise to full height; ^0.8 lift
  -- keeps waves big without slamming every syllable to the ceiling.
  latest = math.max(0, math.min(1, (db - lo - 6) / math.max(hi - lo - 6, 12))) ^ 0.8
end

-- Whisper fed near-silence hallucinates rather than returning "". Matched on
-- the WHOLE trimmed transcript, so "thank you for the ride" survives.
-- (Keep in sync with win/mictext.ahk and web/src/silence.js. The empty-string
-- case in silence.js's set is handled here by the #text == 0 check below.)
local ARTIFACTS = {
  ["."] = true, [".."] = true, ["..."] = true,
  ["[blank_audio]"] = true, ["(blank_audio)"] = true,
  ["[silence]"] = true, ["(silence)"] = true, ["[ silence ]"] = true,
  ["you"] = true, ["thank you"] = true, ["thank you."] = true,
  ["thanks for watching!"] = true, ["thanks for watching."] = true,
  ["bye"] = true, ["bye."] = true,
}
local function isArtifact(text) return ARTIFACTS[text:lower()] == true end

-- Learned vocabulary (hand-port of web/src/terms.js — see its PORTABILITY
-- notes; keep this and win/mictext.ahk in sync with it). Local file only,
-- never uploaded.
local TERMS = HOME .. "/.mictext/terms.json"
local PROMPT_MAX_CHARS = 200 -- whisper's prompt window is 224 tokens and
                             -- truncates from the FRONT; cap it newest-first
local MAX_PAIR_WORDS = 6     -- longer corrections bias only, never replace
local SENTINEL = "\31"       -- \x1F Unit Separator; NEVER \0 (NUL is safe in
                             -- Lua but the AHK port must match, and AHK strings
                             -- are null-terminated — see the terms.js note)

local function trim(s) return (tostring(s):gsub("^%s*(.-)%s*$", "%1")) end

local function words(s)
  local out = {}
  for w in tostring(s):gmatch("%S+") do out[#out + 1] = w end
  return out
end

-- One normalization boundary (mirror of normalizeTerms in terms.js): drop
-- non-tables and anything missing a usable heard/said; coerce heard/said to
-- strings and n to a number ALWAYS. Lua-specific: 0 and "" are truthy here, so
-- they must be tested explicitly (terms.js leans on JS falsiness).
local function normalizeTerms(arr)
  local out = {}
  if type(arr) ~= "table" then return out end
  for _, t in ipairs(arr) do
    if type(t) == "table"
       and t.heard ~= nil and t.heard ~= "" and t.heard ~= 0
       and t.said ~= nil and t.said ~= "" and t.said ~= 0 then
      out[#out + 1] = { heard = tostring(t.heard), said = tostring(t.said),
                        n = tonumber(t.n) or 0, at = t.at }
    end
  end
  return out
end

local function loadTerms()
  local ok, t = pcall(hs.json.read, TERMS)
  if ok and type(t) == "table" then return normalizeTerms(t) end
  return {} -- missing/corrupt file = no vocabulary, never a crash
end

local function saveTerms(terms)
  hs.json.write(terms, TERMS, true, true) -- prettyprint, replace
end

-- Newest first, de-duplicated, capped on a word boundary. A word that doesn't
-- fit is skipped (not aborted), so one oversized word can't zero the prompt.
local function promptFrom(terms)
  local list = normalizeTerms(terms)
  local seen, out, len = {}, {}, 0
  for i = #list, 1, -1 do
    for _, w in ipairs(words(list[i].said)) do
      local k = w:lower()
      if not seen[k] then
        seen[k] = true
        local add = (#out > 0) and (#w + 2) or #w
        if len + add <= PROMPT_MAX_CHARS then
          out[#out + 1] = w
          len = len + add
        end
      end
    end
  end
  return table.concat(out, ", ")
end

-- Eligible to rewrite output: short enough to be a term (<= MAX_PAIR_WORDS) and
-- specific enough (>= 4 chars or multi-word). Derived, never stored.
local function replaceable(t)
  local w = words(t.heard)
  return #w > 0 and #w <= MAX_PAIR_WORDS and (#trim(t.heard) >= 4 or #w > 1)
end

-- Escape Lua-pattern magic chars, THEN fold each letter into a two-case class
-- (Lua has no case-insensitive flag). Order matters: escaping introduces % (not
-- a letter), folding introduces [ ] — fold AFTER so escaping doesn't touch the
-- classes. (terms.js does this with \b + the 'i' flag.)
local function luaPattern(s)
  local esc = s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
  return (esc:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

-- Two-pass replacement (mirror of applyTerms): pass 1 swaps each match for a
-- numbered sentinel, pass 2 swaps sentinels for the real text, so a shorter
-- pair can't re-match a longer pair's output. \b becomes %f frontier patterns;
-- the pass-2 replacer is a FUNCTION so % in `said` stays literal.
local function applyTerms(text, terms)
  local out = tostring(text):gsub(SENTINEL, "") -- strip any sentinel in input
  local usable = {}
  for _, t in ipairs(normalizeTerms(terms)) do
    if replaceable(t) then usable[#usable + 1] = t end
  end
  table.sort(usable, function(a, b) return #trim(a.heard) > #trim(b.heard) end)
  for i, t in ipairs(usable) do
    local heard = trim(t.heard)
    local lead = heard:match("^%w") and "%f[%w]" or ""
    local tail = heard:match("%w$") and "%f[%W]" or ""
    out = out:gsub(lead .. luaPattern(heard) .. tail, SENTINEL .. i .. SENTINEL)
  end
  out = out:gsub(SENTINEL .. "(%d+)" .. SENTINEL, function(i) return usable[tonumber(i)].said end)
  return out
end

local function learn(terms, heard, said)
  local h, s = trim(heard or ""), trim(said or "")
  local list = normalizeTerms(terms)
  if h == "" or s == "" or h:lower() == s:lower() then return list end
  local rest, prevN = {}, 0
  for _, t in ipairs(list) do
    if t.heard:lower() == h:lower() then prevN = t.n
    else rest[#rest + 1] = t end
  end
  -- newest last: promptFrom reads from the end
  rest[#rest + 1] = { heard = h, said = s, n = prevN + 1, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  return rest
end

local lastText, lastApp, typedSince = nil, nil, 0
local sinceTap = nil

-- Arm a keystroke COUNTER (never a reader — it sees only that a key went down)
-- for 60s after we type. The only honest way to know whether backspacing our
-- own text would eat the user's later typing instead.
local function armSince()
  typedSince = 0
  if sinceTap then sinceTap:stop() end
  local tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function()
    typedSince = typedSince + 1
    return false
  end)
  sinceTap = tap
  tap:start()
  -- Compare identity, not just non-nil: a second dictation inside the window
  -- installs a new tap, and this timer must not stop THAT one.
  hs.timer.doAfter(60, function()
    tap:stop()
    if sinceTap == tap then sinceTap = nil end
  end)
end

local function transcribe()
  local prompt = promptFrom(loadTerms())
  local args = { "-m", MODEL, "-f", WAV, "-nt", "-np" }
  if #prompt > 0 then
    args[#args + 1] = "--prompt"
    args[#args + 1] = prompt
  end
  local task = hs.task.new(bin("whisper-cli"), function(code, stdout, stderr)
    os.remove(WAV)
    if code ~= 0 then
      hs.alert.show("MicText: transcription failed")
      return
    end
    local text = stdout:gsub("^%s+", ""):gsub("%s+$", "")
    if #text == 0 or isArtifact(text) then return end -- silent no-op
    -- lastText is what was actually TYPED (post-replacement): it is both the
    -- backspace count and the "heard" side of any correction — you correct
    -- what you can see.
    local fixed = applyTerms(text, loadTerms())
    lastApp = hs.application.frontmostApplication()
    hs.eventtap.keyStrokes(fixed)
    lastText = fixed
    armSince()
  end, args)
  task:start()
end

local function startRecording()
  if recTask then return end
  downAt = hs.timer.secondsSinceEpoch()
  cancelled = false
  os.remove(WAV)
  -- Exit callback fires only once ffmpeg has actually exited (graceful SIGTERM
  -- from terminate() finalizes the wav header first) -- no guessed sleep.
  recTask = hs.task.new(bin("ffmpeg"),
    function(code, stdout, stderr)
      recTask = nil
      hideHud() -- safety net if ffmpeg dies while the key is still held
      -- Gate here, not in stopRecording: RMS lines keep arriving between
      -- terminate() and exit, and they count toward speechFrames.
      if cancelled or speechFrames < SPEECH_FRAMES then os.remove(WAV); return end
      transcribe()
    end,
    function(_, so, se)
      for db in ((so or "") .. (se or "")):gmatch("RMS_level=([%-%w%.]+)") do
        -- ffmpeg writes nothing before the device opens, so the FIRST astats
        -- line is the first captured sample: warming ends exactly here.
        if not capturing then capturing = true; hudLive(); setIcon("rec") end
        pushLevel(tonumber(db))
      end
      return true -- keep streaming
    end,
    { "-y", "-f", "avfoundation", "-i", ":" .. MIC, "-ar", "16000", "-ac", "1",
      "-af", "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:direct=1:file=-",
      WAV })
  capturing = false
  recTask:start()
  setIcon("warm")
  showHud()
end

local function stopRecording()
  if not recTask then return end
  cancelled = (hs.timer.secondsSinceEpoch() - downAt) * 1000 < MIN_MS
  recTask:terminate()
  setIcon("idle")
  hideHud()
end

-- "Fix that": correct the last transcript in place and remember the pair.
-- Deliberately explicit — nothing reads your screen or diffs your document.
local function fixLast()
  if not lastText then hs.alert.show("MicText: nothing to fix"); return end
  local heard = lastText
  -- Snapshot the count NOW, before the modal dialog: the counter keeps ticking
  -- while you type the correction INTO the dialog, and that typing must not
  -- read as "you edited the document". typedBefore = document keys since dictation.
  local typedBefore = typedSince
  local btn, corrected = hs.dialog.textPrompt(
    "MicText: fix that", "What did you actually say?", heard, "Save", "Cancel")
  if btn ~= "Save" or not corrected then return end
  corrected = trim(corrected)
  if #corrected == 0 or corrected == heard then return end
  -- In-place rewrite ONLY when provably safe: same app, nothing typed since.
  -- Anything else and the correction goes to the clipboard — never guess at
  -- the contents of someone's document.
  local nowApp = hs.application.frontmostApplication()
  local sameApp = lastApp and nowApp and lastApp:pid() == nowApp:pid()
  if sameApp and typedBefore == 0 then
    for _ = 1, (utf8.len(heard) or #heard) do
      hs.eventtap.keyStroke({}, "delete", 0)
    end
    hs.eventtap.keyStrokes(corrected)
  else
    hs.pasteboard.setContents(corrected)
    hs.alert.show("MicText: correction copied to clipboard")
  end
  saveTerms(learn(loadTerms(), heard, corrected))
  lastText = nil
end
M.fixHotkey = hs.hotkey.bind({ "alt", "shift" }, "f", fixLast)

M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  if e:getKeyCode() ~= RIGHT_OPT then return false end
  -- getFlags().alt is true for EITHER option key: releasing right-opt while
  -- left-opt is held used to read as another "start", so stop never fired
  -- and the recording + HUD wedged. Test the device-specific right-alt bit.
  local rightAlt = (e:getRawEventData().CGEventData.flags & 0x40) ~= 0
  if rightAlt then startRecording() else stopRecording() end
  return false
end)
M.tap:start()

-- A shown canvas whose reference is dropped stays on screen forever, and a
-- config reload drops every reference -- delete the HUD on reload/exit; also
-- stop the fix-that keystroke counter so it doesn't outlive a reload.
hs.shutdownCallback = function()
  hideHud()
  if sinceTap then sinceTap:stop(); sinceTap = nil end
end

return M
