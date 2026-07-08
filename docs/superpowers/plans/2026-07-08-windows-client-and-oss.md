# Windows Client + Open-Source Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Windows push-to-talk dictation client mirroring `mac/`, then open-source the repo (MIT, public GitHub, npm publish).

**Architecture:** `win/` is a three-file mirror of `mac/` (AutoHotkey v2 script + PowerShell installer + README) with no build step. OSS prep adds LICENSE + top-level README, publish fields to `web/package.json`, and flips the existing repo public after a secret-audit gate.

**Tech Stack:** AutoHotkey v2, PowerShell 5.1+, ffmpeg (dshow), whisper.cpp v1.9.1 Windows release, gitleaks (audit), npm.

**Spec:** `docs/superpowers/specs/2026-07-08-windows-client-and-oss-design.md`

## Global Constraints

- Hotkey is **Right Ctrl** (pass-through `~*RCtrl`), NOT Right Alt (AltGr on international layouts).
- Cancel threshold: holds **< 300 ms** are cancels — same as `mac/flex-voice.lua` `MIN_MS`.
- Model: `ggml-base.en.bin` from `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin`, stored at `%USERPROFILE%\.flex-voice\models\` (mirrors mac's `~/.flex-voice/models/`).
- whisper.cpp Windows binaries: release `v1.9.1` asset `whisper-bin-x64.zip` from `ggml-org/whisper.cpp`; `whisper-cli.exe` lives in `Release/` inside the zip **and requires the DLLs next to it** — copy the whole `Release/*` into `%USERPROFILE%\.flex-voice\bin\`.
- No Windows machine in this environment: AHK/PowerShell cannot be executed here. Their verification = line-by-line review against this plan + the README manual checklist run by Dieter on a real Windows box. Do NOT claim runtime verification.
- License: MIT, copyright Dieter Stemmet.
- Commits: single-line messages, no Co-Authored-By/attribution trailers.
- Secrets policy: the history audit must use `--redact`; never print a candidate secret value into the session.
- Tasks 1–6 are local-only. **Task 7 (push + public flip + npm publish) is gated on Task 1 passing AND explicit go-ahead from Dieter in-session.**

---

### Task 1: Secret-audit gate (history + docs)

**Files:**
- No repo changes. Produces a pass/fail verdict recorded in the final report.

**Interfaces:**
- Produces: audit verdict consumed by Task 7 (hard gate).

- [ ] **Step 1: Download gitleaks release binary to scratchpad**

```bash
cd /tmp/claude-1000/-home-dev-Personal/94111d61-6545-4a50-82b8-c3a870cdab32/scratchpad
VER=$(gh api repos/gitleaks/gitleaks/releases/latest --jq .tag_name)
curl -sL -o gitleaks.tar.gz "https://github.com/gitleaks/gitleaks/releases/download/${VER}/gitleaks_${VER#v}_linux_x64.tar.gz"
tar xzf gitleaks.tar.gz gitleaks
./gitleaks version
```

Expected: prints the version number.

- [ ] **Step 2: Scan the full git history, redacted**

```bash
cd /home/dev/Personal/flex-voice
/tmp/claude-1000/-home-dev-Personal/94111d61-6545-4a50-82b8-c3a870cdab32/scratchpad/gitleaks git --redact --no-banner .
```

Expected: `no leaks found`, exit 0. If findings: STOP — report each finding's file/commit (redacted) to Dieter; Task 7 is blocked until resolved (history rewrite or accepted false positive).

- [ ] **Step 3: Manually review committed internal docs**

Read and check for credentials, internal-only operational detail beyond hostnames, or personal data:
- `docs/superpowers/specs/2026-07-02-flex-voice-design.md`
- `docs/superpowers/plans/2026-07-02-flex-voice.md`
- `git log --format='%s%n%b'` (all 22+ commit messages)

Server hostnames (`stt.flexsolutions.ph`, `ai.flexsolutions.ph`) are acceptable. Keys/tokens/passwords/IPs-with-credentials are not. Expected: nothing beyond hostnames.

- [ ] **Step 4: Record verdict**

State PASS or FAIL with evidence (gitleaks exit code + doc review notes). No commit.

---

### Task 2: `win/flex-voice.ahk`

**Files:**
- Create: `win/flex-voice.ahk`

**Interfaces:**
- Consumes: `%USERPROFILE%\.flex-voice\{models\ggml-base.en.bin, bin\whisper-cli.exe, mic.txt}` — all provisioned by Task 3's installer.
- Produces: the script Task 3 copies to `%USERPROFILE%\.flex-voice\flex-voice.ahk` and Task 4 documents.

- [ ] **Step 1: Write the script**

```ahk
#Requires AutoHotkey v2.0
#SingleInstance Force
; flex-voice: hold Right Ctrl, speak, release -> text typed at the cursor.
; Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves the PC.

; -- config ------------------------------------------------------------------
HOLD_KEY := "RCtrl"                     ; hold-to-talk key (RCtrl, not RAlt: RAlt = AltGr on intl layouts)
BASE     := EnvGet("USERPROFILE") "\.flex-voice"
MODEL    := BASE "\models\ggml-base.en.bin"
WHISPER  := BASE "\bin\whisper-cli.exe"
MIC_FILE := BASE "\mic.txt"             ; dshow device name, written by install.ps1
MIN_MS   := 300                         ; holds shorter than this are cancels
; -----------------------------------------------------------------------------

RAW := A_Temp "\flex-voice.pcm"
WAV := A_Temp "\flex-voice.wav"
OUT := A_Temp "\flex-voice-out.txt"

A_IconTip := "flex-voice (hold " HOLD_KEY " to dictate)"
recPid := 0
downAt := 0

; ponytail: record headerless raw PCM so a hard ProcessClose can't corrupt the
; file (wav headers are finalized on close); a second instant ffmpeg pass wraps
; it into a wav. Avoids graceful-shutdown plumbing for console apps on Windows.
StartRecording() {
    global recPid, downAt
    if recPid                            ; key auto-repeat fires this repeatedly
        return
    mic := ""
    try mic := Trim(FileRead(MIC_FILE), " `t`r`n")
    if (mic = "") {
        TrayTip("flex-voice", "No mic configured - run install.ps1")
        return
    }
    downAt := A_TickCount
    try FileDelete(RAW)
    Run('ffmpeg -y -f dshow -i audio="' mic '" -ar 16000 -ac 1 -f s16le "' RAW '"', , "Hide", &recPid)
    ToolTip("🔴 flex-voice recording")
}

StopRecording() {
    global recPid
    if !recPid
        return
    pid := recPid
    recPid := 0
    cancelled := (A_TickCount - downAt) < MIN_MS
    ProcessClose(pid)
    ToolTip()
    if cancelled {
        try FileDelete(RAW)
        return
    }
    Transcribe()
}

Transcribe() {
    ; wrap raw pcm into a wav whisper-cli can read
    if RunWait('ffmpeg -y -f s16le -ar 16000 -ac 1 -i "' RAW '" "' WAV '"', , "Hide") != 0 {
        Cleanup()
        TrayTip("flex-voice", "transcription failed")
        return
    }
    code := RunWait(A_ComSpec ' /c ""' WHISPER '" -m "' MODEL '" -f "' WAV '" -nt -np > "' OUT '""', , "Hide")
    text := ""
    if (code = 0)
        try text := Trim(FileRead(OUT, "UTF-8"), " `t`r`n")
    Cleanup()
    if (code != 0) {
        TrayTip("flex-voice", "transcription failed")
        return
    }
    if (text != "")
        SendText(text)
}

Cleanup() {
    for f in [RAW, WAV, OUT]
        try FileDelete(f)
}

Hotkey("~*" HOLD_KEY, (*) => StartRecording())
Hotkey("~*" HOLD_KEY " up", (*) => StopRecording())
```

- [ ] **Step 2: Review against the mac client (no runtime available)**

Line-by-line check versus `mac/flex-voice.lua` semantics:
- pass-through hotkey (`~` = mac's `return false`),
- repeat-guard (`if recPid return` = mac's `if recTask then return`),
- <300ms cancel measured from key-down,
- exit-code != 0 → alert + nothing typed,
- empty text → nothing typed, no alert,
- temp files deleted on every path.

Expected: all six behaviors present.

- [ ] **Step 3: Commit**

```bash
git add win/flex-voice.ahk
git commit -m "Add Windows push-to-talk client (AutoHotkey v2)"
```

---

### Task 3: `win/install.ps1`

**Files:**
- Create: `win/install.ps1`

**Interfaces:**
- Consumes: `win/flex-voice.ahk` from Task 2 (copied via `$PSScriptRoot`).
- Produces: `%USERPROFILE%\.flex-voice\{bin\whisper-cli.exe + DLLs, models\ggml-base.en.bin, mic.txt, flex-voice.ahk}` + Startup shortcut — the exact paths Task 2's config block reads.

- [ ] **Step 1: Write the installer**

```powershell
#Requires -Version 5.1
# flex-voice Windows installer: AutoHotkey v2 + ffmpeg + whisper.cpp + model.
# Idempotent - safe to re-run.
$ErrorActionPreference = 'Stop'

$base = "$env:USERPROFILE\.flex-voice"
New-Item -ItemType Directory -Force -Path "$base\models", "$base\bin" | Out-Null

# --- AutoHotkey v2 + ffmpeg via winget -----------------------------------
winget install --id AutoHotkey.AutoHotkey -e --accept-source-agreements --accept-package-agreements
winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements

# winget PATH updates don't reach this session; resolve ffmpeg directly
$ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ffmpeg) { $ffmpeg = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe" }
if (-not (Test-Path $ffmpeg)) { throw "ffmpeg not found after winget install" }

# --- whisper.cpp release binaries (whisper-cli.exe needs its DLLs) -------
if (-not (Test-Path "$base\bin\whisper-cli.exe")) {
    $zip = "$env:TEMP\whisper-bin-x64.zip"
    Invoke-WebRequest -Uri "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-bin-x64.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath "$env:TEMP\whisper-bin" -Force
    Copy-Item "$env:TEMP\whisper-bin\Release\*" "$base\bin\" -Force
    Remove-Item $zip, "$env:TEMP\whisper-bin" -Recurse -Force
}
if (-not (Test-Path "$base\bin\whisper-cli.exe")) { throw "whisper-cli.exe missing after extract" }

# --- model ----------------------------------------------------------------
$model = "$base\models\ggml-base.en.bin"
if (-not (Test-Path $model)) {
    Invoke-WebRequest -Uri "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" -OutFile "$model.tmp"
    Move-Item "$model.tmp" $model
}

# --- detect mic (first dshow audio device) --------------------------------
$devices = & $ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
$mic = [regex]::Match($devices, '"([^"]+)"\s+\(audio\)').Groups[1].Value
if ($mic) {
    Set-Content -Path "$base\mic.txt" -Value $mic -NoNewline
    Write-Host "Mic: $mic"
} else {
    Write-Warning "No dshow audio device found. Write your mic name to $base\mic.txt (list devices: ffmpeg -list_devices true -f dshow -i dummy)"
}

# --- install script + run at startup --------------------------------------
Copy-Item "$PSScriptRoot\flex-voice.ahk" "$base\flex-voice.ahk" -Force
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut(
    "$([Environment]::GetFolderPath('Startup'))\flex-voice.lnk")
$lnk.TargetPath = "$base\flex-voice.ahk"
$lnk.Save()

Write-Host "Done. Double-click $base\flex-voice.ahk to start now (auto-starts at next login)."
Write-Host "Windows will prompt for microphone access on first recording - allow it."
```

- [ ] **Step 2: Review (no pwsh in this environment)**

Check: every step idempotent (`Test-Path` guards), fails loudly (`$ErrorActionPreference='Stop'` + explicit `throw`s), paths exactly match Task 2's config block (`bin\whisper-cli.exe`, `models\ggml-base.en.bin`, `mic.txt`), model URL identical to `mac/install.sh`.

- [ ] **Step 3: Commit**

```bash
git add win/install.ps1
git commit -m "Add Windows installer for the push-to-talk client"
```

---

### Task 4: `win/README.md`

**Files:**
- Create: `win/README.md`

**Interfaces:**
- Consumes: hotkey/paths/behaviors from Tasks 2–3.
- Produces: the manual verification checklist Dieter runs on a Windows box.

- [ ] **Step 1: Write the README**

Mirror `mac/README.md`'s structure exactly (read it first), with Windows substitutions:

- Title: `# flex-voice: On-Device Push-to-Talk for Windows`
- Install: clone repo → run `powershell -ExecutionPolicy Bypass -File win\install.ps1` → double-click `%USERPROFILE%\.flex-voice\flex-voice.ahk`.
- Hotkey: **hold Right Ctrl**, speak, release; quick tap (<300 ms) is ignored. Recording shown by a small "🔴 flex-voice recording" tooltip at the cursor.
- Permissions: Windows mic-privacy prompt on first recording (Settings > Privacy & security > Microphone if missed). No accessibility permission needed (unlike macOS).
- Manual Verification Checklist — the same 5 tests as mac's:
  1. Notepad: hold Right Ctrl, say "testing one two three from Dahican", release → text typed.
  2. Web form at ai.flexsolutions.ph → text appears in the input.
  3. Quick tap (<300 ms) → nothing typed.
  4. Wi-Fi off → dictation still works (on-device proof).
  5. Rename `%USERPROFILE%\.flex-voice\models\ggml-base.en.bin` → tray notification "transcription failed", nothing typed; restore by re-running `install.ps1`.
- Troubleshooting: no tooltip/hotkey → script not running (check tray for AHK icon); wrong/no mic → edit `%USERPROFILE%\.flex-voice\mic.txt` (list devices: `ffmpeg -list_devices true -f dshow -i dummy`); model download failed → re-run installer.
- Known limitations: Right Ctrl passes through to apps (`~` pass-through — brief Ctrl-modifier side effects possible in apps with Ctrl-hold behaviors); cancel window measured at callback time under load (same caveat as mac); tooltip indicator instead of a tray-icon swap.
- Architecture: ffmpeg (dshow) records → whisper.cpp transcribes locally → AutoHotkey types the result. Nothing leaves the PC.

- [ ] **Step 2: Cross-check consistency**

Every path, hotkey, threshold, and filename in the README must match Tasks 2–3 exactly. Expected: no mismatches.

- [ ] **Step 3: Commit**

```bash
git add win/README.md
git commit -m "Add Windows client README with manual verification checklist"
```

---

### Task 5: LICENSE + top-level README

**Files:**
- Create: `LICENSE`
- Create: `README.md`

**Interfaces:**
- Consumes: component READMEs (`web/`, `mac/`, `win/`, `server/DEPLOY.md`) for links.
- Produces: the public front page; `LICENSE` referenced by Task 6's package.json.

- [ ] **Step 1: Write LICENSE (standard MIT text)**

```
MIT License

Copyright (c) 2026 Dieter Stemmet

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Write top-level README.md**

Content (positioning per spec — embeddable web STT lib first, clients as reference implementations):

```markdown
# flex-voice

On-device speech-to-text. Your audio never leaves your machine.

flex-voice is an embeddable STT library for the web plus reference
push-to-talk dictation clients for macOS and Windows, all running
[Whisper](https://github.com/ggml-org/whisper.cpp) locally. An optional
self-hosted fallback server covers devices too slow to run the model.

| Component | What it is |
| --- | --- |
| [`web/`](web/) | Browser library: Whisper in a Web Worker (WebGPU → WASM). Headless `createTranscriber()` core + `<flex-voice-mic>` element. `npm i flex-voice` |
| [`mac/`](mac/) | macOS dictation client: hold right-⌥, speak, release — text typed at the cursor (Hammerspoon + ffmpeg + whisper.cpp) |
| [`win/`](win/) | Windows dictation client: hold Right Ctrl (AutoHotkey v2 + ffmpeg + whisper.cpp) |
| [`server/`](server/) | Optional self-hosted fallback (FastAPI + faster-whisper) for the web library's explicit `slowDevice: 'server'` opt-in |

## Zero-upload guarantee

With the default configuration, no code path in this repo POSTs your audio
anywhere. The web library only GETs model files (verified end-to-end with
full network logging — see [`web/README.md`](web/README.md)); the desktop
clients work with Wi-Fi off. The single exception is the web library's
`slowDevice: 'server'` opt-in, which sends audio to a fallback URL **you**
configure — typically your own `server/` deployment.

## Quick start

**Browser** — `npm i flex-voice`, then:

```js
import { createTranscriber } from 'flex-voice'
const t = createTranscriber()
const { text } = await t.transcribeBlob(audioBlob)
```

**macOS** — `mac/install.sh`, then hold right-⌥ and speak. ([mac/README.md](mac/README.md))

**Windows** — `powershell -ExecutionPolicy Bypass -File win\install.ps1`, then hold Right Ctrl and speak. ([win/README.md](win/README.md))

## Design: headless core, swappable frontends

The durable interface is the headless transcriber
(`createTranscriber().transcribeBlob(blob)` on the web; `whisper-cli` behind
a hotkey on desktop). Dictation — "type what I said at the cursor" — is just
the first frontend. The same ears can feed a voice assistant: that's the
direction this project grows in, and why no client logic lives in the core.

## License

MIT
```

- [ ] **Step 3: Verify links resolve**

```bash
cd /home/dev/Personal/flex-voice
for f in web mac win server web/README.md mac/README.md win/README.md; do [ -e "$f" ] || echo "MISSING: $f"; done
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add LICENSE README.md
git commit -m "Add MIT license and top-level README for open-source release"
```

---

### Task 6: npm publish fields on `web/package.json`

**Files:**
- Modify: `web/package.json`

**Interfaces:**
- Consumes: `LICENSE` from Task 5.
- Produces: a publishable `flex-voice@0.1.0`; Task 7 runs the actual publish.

- [ ] **Step 1: Add publish fields**

Final `web/package.json`:

```json
{
  "name": "flex-voice",
  "version": "0.1.0",
  "description": "On-device speech-to-text for the browser: Whisper in a Web Worker over WebGPU/WASM, zero audio upload",
  "type": "module",
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "git+https://github.com/dieterstemmet/flex-voice.git",
    "directory": "web"
  },
  "keywords": ["speech-to-text", "stt", "whisper", "on-device", "webgpu", "wasm", "dictation", "transcription"],
  "files": ["src", "README.md"],
  "exports": {
    ".": "./src/index.js",
    "./mic": "./src/mic-element.js"
  },
  "scripts": { "test": "vitest run" },
  "dependencies": { "@huggingface/transformers": "^3.5.0" },
  "devDependencies": { "vitest": "^3.0.0", "happy-dom": "^17.0.0" }
}
```

- [ ] **Step 2: Regression + dry-run**

```bash
cd /home/dev/Personal/flex-voice/web
npm test
npm publish --dry-run
```

Expected: all vitest suites pass (3 spec files); dry-run tarball lists `src/*.js`, `README.md`, `package.json` and nothing else (no `demo/`, no `test/`, no `node_modules`). Note: npm auto-includes LICENSE only if inside `web/` — it isn't; acceptable (license field + repo root LICENSE). If the tarball looks wrong, fix `files` before committing.

- [ ] **Step 3: Commit**

```bash
git add web/package.json
git commit -m "Add npm publish metadata to web package"
```

---

### Task 7: Ship — push, flip public, publish (GATED)

**Files:**
- No file changes. Remote-state changes only.

**Interfaces:**
- Consumes: Task 1 PASS verdict + all prior tasks committed + **explicit go-ahead from Dieter in-session** (publishing is outward-facing and irreversible).

- [ ] **Step 1: Confirm gates**

Task 1 verdict = PASS; working tree clean (`git status`); Dieter has said "go" for the public flip + npm publish in this session. If any gate fails: STOP.

- [ ] **Step 2: Push master**

```bash
cd /home/dev/Personal/flex-voice
git push origin master
```

Expected: up-to-date remote, no errors.

- [ ] **Step 3: Flip repo public + set description**

```bash
gh repo edit dieterstemmet/flex-voice --visibility public --accept-visibility-change-consequences
gh repo edit dieterstemmet/flex-voice --description "On-device speech-to-text: embeddable web library (Whisper/WebGPU/WASM) + push-to-talk dictation clients for macOS and Windows"
gh repo view dieterstemmet/flex-voice --json visibility --jq .visibility
```

Expected: final command prints `PUBLIC`.

- [ ] **Step 4: npm publish**

```bash
cd /home/dev/Personal/flex-voice/web
npm whoami || echo "NOT AUTHENTICATED"
```

If not authenticated: hand to Dieter — suggest he runs `! npm login` in this session, then continue.

```bash
npm publish
npm view flex-voice version
```

Expected: `npm view` prints `0.1.0`.

- [ ] **Step 5: Report**

Summarize: audit verdict, commits made, repo URL (public), npm package URL, and the outstanding manual step — Dieter runs `win/README.md`'s checklist on a Windows machine (and mac's still-pending checklist).

---

## Self-Review Notes

- Spec coverage: Windows client (Tasks 2–4), audit gate (Task 1), LICENSE/README (Task 5), npm (Tasks 6–7), public flip (Task 7), vision footprint = one README section (Task 5). Assistant loop: correctly absent.
- No TDD cycle for AHK/PS: no Windows runtime exists here; the spec's stated bar is review + Dieter's manual checklist. Web package change carries a real test run (Task 6 Step 2).
- Type/path consistency: `%USERPROFILE%\.flex-voice\{bin,models,mic.txt}` identical across Tasks 2, 3, 4.
