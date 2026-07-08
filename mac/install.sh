#!/usr/bin/env bash
set -euo pipefail
brew list hammerspoon &>/dev/null || brew install --cask hammerspoon
brew install ffmpeg whisper-cpp
command -v whisper-cli >/dev/null || [ -x /opt/homebrew/bin/whisper-cli ] || [ -x /usr/local/bin/whisper-cli ] || {
  echo "whisper-cli not found -- check brew whisper-cpp formula (binary may be named differently)"
  exit 1
}
mkdir -p ~/.mictext/models ~/.hammerspoon
MODEL=~/.mictext/models/ggml-base.en.bin
[ -f "$MODEL" ] || {
  curl -fL -o "$MODEL.tmp" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
  mv "$MODEL.tmp" "$MODEL"
}
cp "$(dirname "$0")/mictext.lua" ~/.hammerspoon/mictext.lua
grep -qF 'require("mictext")' ~/.hammerspoon/init.lua 2>/dev/null || \
  echo 'require("mictext")' >> ~/.hammerspoon/init.lua
echo "Done. Start Hammerspoon, grant Accessibility + Microphone permissions, reload config."
