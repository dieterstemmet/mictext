# MicText: On-Device Push-to-Talk for Windows

Hold Right Ctrl anywhere, speak, then release — your words appear typed at the cursor. Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves your PC.

## Installation

One line, no clone needed — open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/dieterstemmet/mictext/master/win/install.ps1 | iex
```

Or from a clone of the repo: `powershell -ExecutionPolicy Bypass -File win\install.ps1`.

This will:
- Install AutoHotkey v2 and ffmpeg via winget
- Download whisper.cpp release binaries (`whisper-cli.exe` and its DLLs)
- Download the base English whisper model (~141 MB)
- Auto-detect your microphone and write it to `mic.txt`
- Create a shortcut in the Startup folder so MicText runs at login

Double-click `%USERPROFILE%\.mictext\mictext.ahk` to start it now (it also auto-starts at your next login via the Startup shortcut)

## First-Run Permissions

After installation, Windows will prompt for microphone access the first time you record:

- **Microphone**: allow it when prompted. If you miss the prompt, grant it manually from Settings > Privacy & security > Microphone.

Unlike macOS, no accessibility permission is needed — AutoHotkey can send keystrokes without it.

## Hotkey

**Hold Right Ctrl** anywhere on your PC:
- A small waveform pill appears bottom-center. On the first press of a session the mic takes up to a second to open — the pill starts **grey with a "warming up" tray tooltip**; wait until it darkens and the bars move before speaking, so your first words aren't lost
- Speak clearly into your microphone
- Release Right Ctrl
- Your speech is transcribed on-device and typed into the focused app

Right Ctrl is passed through while held, so it still works as a normal modifier key too (e.g. Ctrl+C still works during a hold).

**Quick tap** (< 300 ms) is ignored — no text will be typed.

**Silence is silence.** If you hold the key and say nothing, nothing is typed — no blank text to clean up. Whisper's silence hallucinations (`[BLANK_AUDIO]`, `Thank you.`) are dropped too.

## Fixing what it mishears

Press **Alt+Shift+F** right after a dictation to correct it. A box shows what it heard; type the correction and OK. The wrong text is replaced in place — but only if you haven't typed anything since and are still in the same window; otherwise the correction lands on your clipboard (MicText never guesses at your document). The pair is remembered in `%USERPROFILE%\.mictext\terms.json`.

Remembered corrections do two things: they're fed to Whisper as decoding context so the word is more likely to come out right first time, and short ones (six words or fewer) are also applied as literal replacements. The file is plain JSON — edit or delete it freely, and it never leaves your PC. It shares its format with the macOS client, so the same file works on both.

## Manual Verification Checklist

These tests confirm the setup works end-to-end. Perform them on a Windows 10/11 PC.

- [ ] **Test 0: One-line install**
  - On a Windows box without the repo cloned, run the one-liner above in PowerShell
  - It reaches "Mic: ..." (or the no-device warning) and "Done. ..."; `%USERPROFILE%\.mictext\mictext.ahk` exists

- [ ] **Test 1: Installer**
  - Run `powershell -ExecutionPolicy Bypass -File win\install.ps1` on a stock Windows 10/11 box (non-elevated is fine)
  - It completes with a `Mic: <device>` line (or a "No dshow audio device found" warning if none is present) followed by `Done.` — not an error after the model download

- [ ] **Test 2: Notepad**
  - Open Notepad or any text app
  - Hold Right Ctrl, say "testing one two three", release — a small waveform strip appears bottom-center while recording
  - "testing one two three" appears typed in the editor

- [ ] **Test 3: Web form in a browser**
  - Open a browser and navigate to any page with a text input (e.g. a search engine)
  - Click into a text input field
  - Hold Right Ctrl, say "hello from MicText", release
  - Text appears in the input field

- [ ] **Test 4: Quick tap rejection**
  - Click into any text field
  - Quickly tap Right Ctrl (< 300 ms)
  - Nothing is typed (the hold-and-speak pattern is required)

- [ ] **Test 5: Wi-Fi off**
  - Turn off Wi-Fi on the PC
  - Open a text app and hold Right Ctrl, say a few words, release
  - Transcription works (proving it's fully on-device, no network call)
  - Turn Wi-Fi back on when done

- [ ] **Test 6: Error handling**
  - Rename or delete `%USERPROFILE%\.mictext\models\ggml-base.en.bin`
  - Try to dictate by holding Right Ctrl and speaking
  - A Windows notification appears, titled **MicText** with the message **transcription failed**
  - Nothing is typed
  - (Restore the model by running `win\install.ps1` again)

## Troubleshooting

- **No tooltip / hotkey does nothing**: the script isn't running — check the system tray for the AutoHotkey icon (double-click `%USERPROFILE%\.mictext\mictext.ahk` to start it)
- **Wrong or no microphone**: edit `%USERPROFILE%\.mictext\mic.txt`; list available devices with `ffmpeg -list_devices true -f dshow -i dummy`
- **"No mic configured" tray notification**: `mic.txt` is empty or missing — set it as above, or re-run `install.ps1` to auto-detect
- **Model download failed**: re-run `win\install.ps1`
- **Ran the installer non-elevated**: that's fine — AutoHotkey may install per-user instead of machine-wide; the installer checks both locations

## Known Limitations

- **Right Ctrl passes through**: since the hotkey is pass-through, apps with their own Ctrl-hold behaviors may see brief side effects while a recording is active.
- **Cancel window under load**: the <300ms cancel window is measured at the moment the release event's callback runs, not at physical key-up. Under heavy system load, a genuine quick tap could occasionally be misjudged as a real recording (or vice versa).
- **Tooltip indicator, not a tray icon**: recording is shown by a "🔴 MicText recording" tooltip near the cursor rather than a tray-icon swap (unlike the mac client's menubar icon).

## Architecture

- **ffmpeg** captures audio from the PC's microphone (DirectShow/dshow)
- **whisper.cpp** (offline binary) transcribes the audio using a local model
- **AutoHotkey** handles the Right Ctrl hotkey and types the result
- All processing happens locally; no data leaves your PC
