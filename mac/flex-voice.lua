-- flex-voice: hold right-option, speak, release -> text typed at the cursor.
-- Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves the Mac.
local M = {}

local HOME = os.getenv("HOME")
local MODEL = HOME .. "/.flex-voice/models/ggml-base.en.bin"
local WAV = "/tmp/flex-voice.wav"
local RIGHT_OPT = 61 -- keycode for right option
local MIN_MS = 300   -- taps shorter than this are cancels

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

local function transcribe()
  local task = hs.task.new(bin("whisper-cli"), function(code, stdout, stderr)
    os.remove(WAV)
    if code ~= 0 then
      hs.alert.show("flex-voice: transcription failed")
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
      if cancelled then os.remove(WAV); return end
      transcribe()
    end,
    -- Device by name, not index: index :0 may be a virtual/silent device
    -- (e.g. "Microsoft Teams Audio"). Change MIC to another listed name if needed:
    --   ffmpeg -f avfoundation -list_devices true -i ""
    { "-y", "-f", "avfoundation", "-i", ":MacBook Pro Microphone", "-ar", "16000", "-ac", "1", WAV })
  recTask:start()
  setIcon(true)
end

local function stopRecording()
  if not recTask then return end
  cancelled = (hs.timer.secondsSinceEpoch() - downAt) * 1000 < MIN_MS
  recTask:terminate()
  setIcon(false)
end

M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  if e:getKeyCode() ~= RIGHT_OPT then return false end
  if e:getFlags().alt then startRecording() else stopRecording() end
  return false
end)
M.tap:start()

return M
