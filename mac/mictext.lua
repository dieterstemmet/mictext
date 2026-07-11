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

-- Live waveform HUD: rolling RMS bars (matches the web mic's look). Levels
-- come free from the SAME recording ffmpeg via the pass-through astats
-- filter — the captured audio is untouched, ffmpeg just also prints RMS.
local BARS = 14
local hud, levels = nil, {}

local function drawBars()
  if not hud then return end
  for i = 1, BARS do
    local bh = 2 + (levels[i] or 0) * 22
    hud[i + 1] = {
      type = "rectangle", action = "fill",
      fillColor = { red = 0.90, green = 0.28, blue = 0.30, alpha = 1 },
      frame = { x = 10 + (i - 1) * 11, y = (36 - bh) / 2, w = 4, h = bh },
      roundedRectRadii = { xRadius = 2, yRadius = 2 },
    }
  end
end

local function showHud()
  local f = hs.screen.mainScreen():frame()
  local w = 20 + BARS * 11
  hud = hs.canvas.new({ x = f.x + (f.w - w) / 2, y = f.y + 24, w = w, h = 36 })
  hud[1] = {
    type = "rectangle", action = "fill",
    fillColor = { red = 0.10, green = 0.10, blue = 0.10, alpha = 0.85 },
    roundedRectRadii = { xRadius = 9, yRadius = 9 },
  }
  levels = {}
  for i = 1, BARS do levels[i] = 0 end
  drawBars()
  hud:show()
end

local function hideHud()
  if hud then hud:delete(); hud = nil end
end

local function pushLevel(db)
  -- -50 dB floor -> 0..1; silence prints "-inf" (tonumber = nil).
  local lv = db and math.max(0, math.min(1, (db + 50) / 50)) or 0
  table.remove(levels, 1)
  levels[#levels + 1] = lv
  drawBars()
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
      "-af", "astats=metadata=1:reset=0.15,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:direct=1:file=-",
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
  if e:getFlags().alt then startRecording() else stopRecording() end
  return false
end)
M.tap:start()

return M
