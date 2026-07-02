#!/usr/bin/env bash
set -euo pipefail
brew list hammerspoon &>/dev/null || brew install --cask hammerspoon
brew install ffmpeg whisper-cpp
mkdir -p ~/.flex-voice/models ~/.hammerspoon
MODEL=~/.flex-voice/models/ggml-base.en.bin
[ -f "$MODEL" ] || curl -L -o "$MODEL" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
cp "$(dirname "$0")/flex-voice.lua" ~/.hammerspoon/flex-voice.lua
grep -q 'flex%-voice' ~/.hammerspoon/init.lua 2>/dev/null || \
  echo 'require("flex-voice")' >> ~/.hammerspoon/init.lua
echo "Done. Start Hammerspoon, grant Accessibility + Microphone permissions, reload config."
