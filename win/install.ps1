#Requires -Version 5.1
# MicText Windows installer: AutoHotkey v2 + ffmpeg + whisper.cpp + model.
# Idempotent - safe to re-run.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false  # PS 7.3+: winget/ffmpeg exit non-zero by design; don't trap native exit codes

$base = "$env:USERPROFILE\.mictext"
New-Item -ItemType Directory -Force -Path "$base\models", "$base\bin" | Out-Null

# --- AutoHotkey v2 + ffmpeg via winget -----------------------------------
winget install --id AutoHotkey.AutoHotkey -e --accept-source-agreements --accept-package-agreements
winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements

# AutoHotkey isn't on PATH; verify the standard install locations (machine + per-user)
$ahkExe = @("$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
            "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ahkExe) { throw "AutoHotkey v2 not found after winget install" }

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
$ErrorActionPreference = 'Continue'  # PS 5.1: 2>&1 from native commands throws under 'Stop'
$devices = & $ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
$ErrorActionPreference = 'Stop'
$mic = [regex]::Match($devices, '"([^"]+)"\s+\(audio\)').Groups[1].Value
if ($mic) {
    Set-Content -Path "$base\mic.txt" -Value $mic -NoNewline -Encoding utf8
    Write-Host "Mic: $mic"
} else {
    Write-Warning "No dshow audio device found. Write your mic name to $base\mic.txt (list devices: ffmpeg -list_devices true -f dshow -i dummy)"
}

# --- install script + run at startup --------------------------------------
Copy-Item "$PSScriptRoot\mictext.ahk" "$base\mictext.ahk" -Force
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut(
    "$([Environment]::GetFolderPath('Startup'))\mictext.lnk")
$lnk.TargetPath = "$base\mictext.ahk"
$lnk.Save()

Write-Host "Done. Double-click $base\mictext.ahk to start now (auto-starts at next login)."
Write-Host "Windows will prompt for microphone access on first recording - allow it."
