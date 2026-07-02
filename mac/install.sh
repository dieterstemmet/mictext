#!/usr/bin/env bash
set -euo pipefail
brew list hammerspoon &>/dev/null || brew install --cask hammerspoon
brew install ffmpeg whisper-cpp
command -v whisper-cli >/dev/null || [ -x /opt/homebrew/bin/whisper-cli ] || [ -x /usr/local/bin/whisper-cli ] || {
  echo "whisper-cli not found -- check brew whisper-cpp formula (binary may be named differently)"
  exit 1
}
mkdir -p ~/.flex-voice/models ~/.hammerspoon
MODEL=~/.flex-voice/models/ggml-base.en.bin
[ -f "$MODEL" ] || {
  curl -fL -o "$MODEL.tmp" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
  mv "$MODEL.tmp" "$MODEL"
}
cp "$(dirname "$0")/flex-voice.lua" ~/.hammerspoon/flex-voice.lua
grep -qF 'require("flex-voice")' ~/.hammerspoon/init.lua 2>/dev/null || \
  echo 'require("flex-voice")' >> ~/.hammerspoon/init.lua
echo "Done. Start Hammerspoon, grant Accessibility + Microphone permissions, reload config."
