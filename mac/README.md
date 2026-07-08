# MicText: On-Device Push-to-Talk for macOS

Hold right-⌥ (right Option key) anywhere, speak, then release — your words appear typed at the cursor. Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves your Mac.

## Installation

1. Clone or navigate to the MicText repo:
   ```bash
   cd ~/Personal/mictext
   ```

2. Run the installer:
   ```bash
   mac/install.sh
   ```
   This will:
   - Install Hammerspoon (macOS automation framework) via Homebrew
   - Install ffmpeg (audio recording) and whisper-cpp (speech-to-text)
   - Download the base English whisper model (~141 MB)
   - Copy the MicText module into Hammerspoon's config
   - Update your Hammerspoon init script to load it

3. Open Hammerspoon (or reload if it's already running)
   - First launch: Hammerspoon will ask for Accessibility permission → grant it
   - You may also see a prompt for Microphone access → grant it

## First-Run Permissions

After installation, you'll see two permission prompts in macOS:

1. **Accessibility**: Hammerspoon needs this to intercept the right-⌥ key and simulate keystrokes (typing the transcription). Grant it from System Settings > Privacy & Security > Accessibility, add Hammerspoon.

2. **Microphone**: ffmpeg uses this to record your speech. Grant it from System Settings > Privacy & Security > Microphone, add ffmpeg (or terminal app if ffmpeg runs via shell).

Once granted, Hammerspoon will reload and the 🎙 icon will appear in the menubar.

## Hotkey

**Hold right-⌥ (right Option key)** anywhere on your Mac:
- The menubar shows 🎙 (idle) or 🔴 (recording)
- Speak clearly into your Mac's microphone
- Release right-⌥
- Your speech is transcribed on-device and typed into the focused app

**Quick tap** (< 300 ms) is ignored — no text will be typed.

## Manual Verification Checklist

These tests confirm the setup works end-to-end. Perform them on a Mac with the Hammerspoon client installed:

- [ ] **Test 1: Notes app**
  - Open Apple Notes or any text app
  - Hold right-⌥, say "testing one two three from Dahican", release
  - "testing one two three from Dahican" appears typed in the editor

- [ ] **Test 2: Web form at ai.flexsolutions.ph**
  - Open a browser and navigate to ai.flexsolutions.ph
  - Click into a text input field
  - Hold right-⌥, say "hello from MicText", release
  - Text appears in the input field

- [ ] **Test 3: Quick tap rejection**
  - Click into any text field
  - Quickly tap right-⌥ (< 300 ms)
  - Nothing is typed (the hold-and-speak pattern is required)

- [ ] **Test 4: Wi-Fi off**
  - Turn off Wi-Fi on the Mac
  - Open a text app and hold right-⌥, say a few words, release
  - Transcription works (proving it's fully on-device, no network call)
  - Turn Wi-Fi back on when done

- [ ] **Test 5: Error handling**
  - Rename or delete `~/.mictext/models/ggml-base.en.bin`
  - Try to dictate by holding right-⌥ and speaking
  - An alert appears: "MicText: transcription failed"
  - Nothing is typed
  - (You can restore the model by running `mac/install.sh` again)

## Troubleshooting

- **No menubar icon**: Hammerspoon may not have started. Open Hammerspoon.app from Applications.
- **Accessibility prompt keeps appearing**: Make sure Hammerspoon is listed in System Settings > Privacy & Security > Accessibility.
- **Microphone access denied**: Check System Settings > Privacy & Security > Microphone; add the app running ffmpeg (usually Terminal or your shell).
- **Model download failed**: Ensure you have internet, then run `mac/install.sh` again. The HuggingFace URL redirects; curl should handle it with `-L`.
- **Transcription says "failed"**: Ensure ffmpeg recorded audio (check `/tmp/mictext.wav` exists during recording). Check model file at `~/.mictext/models/ggml-base.en.bin`.

## Known Limitations

- **Holding both option keys**: pressing left and right ⌥ together can confuse the start/stop detection (the flagsChanged event only reports the combined modifier state). If dictation gets stuck, release both option keys and retry.
- **Cancel window under load**: the <300ms cancel window is measured at the moment the release event's callback runs, not at physical key-up. Under heavy system load, a genuine quick tap could occasionally be misjudged as a real recording (or vice versa).
- **Menubar icon**: the module assumes `hs.menubar.new()` succeeds. On some macOS configurations (e.g. menubar full/hidden) the icon may not be visible even though the hotkey still works.

## Architecture

- **ffmpeg** captures audio from the Mac's microphone
- **whisper.cpp** (offline binary) transcribes the audio using a local model
- **Hammerspoon** handles the right-⌥ hotkey and types the result
- All processing happens locally; no data leaves your Mac
