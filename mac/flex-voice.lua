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

local recTask, downAt = nil, nil
local menubar = hs.menubar.new()
local function setIcon(rec) menubar:setTitle(rec and "🔴" or "🎙") end
setIcon(false)

local function startRecording()
  downAt = hs.timer.secondsSinceEpoch()
  os.remove(WAV)
  recTask = hs.task.new(bin("ffmpeg"),
    nil,
    { "-y", "-f", "avfoundation", "-i", ":0", "-ar", "16000", "-ac", "1", WAV })
  recTask:start()
  setIcon(true)
end

local function transcribe()
  local out, ok = hs.execute(
    bin("whisper-cli") .. " -m " .. MODEL .. " -f " .. WAV .. " -nt -np 2>/dev/null")
  os.remove(WAV)
  if not ok then
    hs.alert.show("flex-voice: transcription failed")
    return
  end
  local text = out:gsub("^%s+", ""):gsub("%s+$", "")
  if #text > 0 then hs.eventtap.keyStrokes(text) end
end

local function stopRecording()
  if not recTask then return end
  local cancelled = (hs.timer.secondsSinceEpoch() - downAt) * 1000 < MIN_MS
  -- SIGTERM = ffmpeg graceful quit: it finalizes the wav header before exiting.
  recTask:terminate()
  recTask = nil
  setIcon(false)
  if cancelled then os.remove(WAV); return end
  -- Give ffmpeg a beat to flush, then transcribe off the hotkey path.
  hs.timer.doAfter(0.3, transcribe)
end

M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  if e:getKeyCode() ~= RIGHT_OPT then return false end
  if e:getFlags().alt then startRecording() else stopRecording() end
  return false
end)
M.tap:start()

return M
