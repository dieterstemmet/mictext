-- MicText: hold right-option, speak, release -> text typed at the cursor.
-- Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves the Mac.
local M = {}

local HOME = os.getenv("HOME")
local MODEL = HOME .. "/.mictext/models/ggml-base.en.bin"
local WAV = "/tmp/mictext.wav"
local RIGHT_OPT = 61 -- keycode for right option
local MIN_MS = 300   -- taps shorter than this are cancels
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
local menubar = hs.menubar.new()
local function setIcon(rec) menubar:setTitle(rec and "🔴" or "🎙") end
setIcon(false)

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
    fillColor = { red = 0.02, green = 0.02, blue = 0.02, alpha = 0.95 },
    roundedRectRadii = { xRadius = 13, yRadius = 13 },
  }
  levels = {}
  for i = 1, BARS do levels[i] = 0 end
  latest, env, recent, seen = 0, 0, {}, 0
  drawBars()
  hud:show()
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

local function transcribe()
  local task = hs.task.new(bin("whisper-cli"), function(code, stdout, stderr)
    os.remove(WAV)
    if code ~= 0 then
      hs.alert.show("MicText: transcription failed")
      return
    end
    local text = stdout:gsub("^%s+", ""):gsub("%s+$", "")
    if #text > 0 then hs.eventtap.keyStrokes(text) end
  end, { "-m", MODEL, "-f", WAV, "-nt", "-np" })
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
      if cancelled then os.remove(WAV); return end
      transcribe()
    end,
    function(_, so, se)
      for db in ((so or "") .. (se or "")):gmatch("RMS_level=([%-%w%.]+)") do
        pushLevel(tonumber(db))
      end
      return true -- keep streaming
    end,
    { "-y", "-f", "avfoundation", "-i", ":" .. MIC, "-ar", "16000", "-ac", "1",
      "-af", "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:direct=1:file=-",
      WAV })
  recTask:start()
  setIcon(true)
  showHud()
end

local function stopRecording()
  if not recTask then return end
  cancelled = (hs.timer.secondsSinceEpoch() - downAt) * 1000 < MIN_MS
  recTask:terminate()
  setIcon(false)
  hideHud()
end

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
-- config reload drops every reference -- delete the HUD on reload/exit.
hs.shutdownCallback = hideHud

return M
