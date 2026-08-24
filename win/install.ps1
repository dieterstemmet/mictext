#Requires -Version 5.1
# MicText Windows installer: AutoHotkey v2 + ffmpeg + whisper.cpp + model.
# Idempotent - safe to re-run. Does not overwrite an existing mic preference.
# Clone: powershell -ExecutionPolicy Bypass -File win\install.ps1
# No clone: irm https://raw.githubusercontent.com/dieterstemmet/mictext/master/win/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false  # PS 7.3+: winget/ffmpeg exit non-zero by design; don't trap native exit codes

$base = "$env:USERPROFILE\.mictext"
$cfg  = "$base\config.ini"
$raw  = "https://raw.githubusercontent.com/dieterstemmet/mictext/master/win"
New-Item -ItemType Directory -Force -Path "$base\models", "$base\bin", "$base\icons" | Out-Null

function Install-WinFile([string]$rel, [string]$dest) {
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot $rel } else { $null }
    if ($local -and (Test-Path $local)) {
        Copy-Item $local $dest -Force
        return
    }
    Invoke-WebRequest -Uri "$raw/$($rel.Replace('\', '/'))" -OutFile "$dest.tmp"
    Move-Item "$dest.tmp" $dest -Force
}

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

# --- config.ini + mic (preserve existing preference) ----------------------
function Read-IniValue([string]$path, [string]$key, [string]$default = '') {
    if (-not (Test-Path $path)) { return $default }
    $rawIni = Get-Content -Raw $path
    if ($rawIni -match "(?m)^\s*$([regex]::Escape($key))\s*=\s*(.*)\s*$") {
        return $Matches[1].Trim()
    }
    return $default
}

function Write-MicTextConfig([string]$mic, [string]$hotkey = 'RCtrl', [string]$modelName = 'ggml-base.en.bin', [string]$minMs = '300') {
    $body = @"
[MicText]
mic=$mic
hotkey=$hotkey
model=$modelName
min_ms=$minMs
"@
    [System.IO.File]::WriteAllText($cfg, $body.TrimEnd() + [Environment]::NewLine)
    [System.IO.File]::WriteAllText("$base\mic.txt", $mic)
}

$existingMic = Read-IniValue $cfg 'mic'
if (-not $existingMic -and (Test-Path "$base\mic.txt")) {
    $existingMic = (Get-Content -Raw "$base\mic.txt").Trim()
}

if ($existingMic) {
    $hotkey = Read-IniValue $cfg 'hotkey' 'RCtrl'
    $modelName = Read-IniValue $cfg 'model' 'ggml-base.en.bin'
    $minMs = Read-IniValue $cfg 'min_ms' '300'
    Write-MicTextConfig -mic $existingMic -hotkey $hotkey -modelName $modelName -minMs $minMs
    Write-Host "Mic (kept): $existingMic"
} else {
    $ErrorActionPreference = 'Continue'  # PS 5.1: 2>&1 from native commands throws under 'Stop'
    $devices = & $ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    $mic = [regex]::Match($devices, '"([^"]+)"\s+\(audio\)').Groups[1].Value
    if ($mic) {
        Write-MicTextConfig -mic $mic
        Write-Host "Mic: $mic"
        Write-Host "  (change later: tray Settings, or win\config.ps1)"
    } else {
        Write-MicTextConfig -mic ''
        Write-Warning "No dshow audio device found. Set a mic via tray Settings or: powershell -File win\config.ps1"
    }
}

# --- script + icons + config helper + run at startup ----------------------
Install-WinFile "mictext.ahk" "$base\mictext.ahk"
Install-WinFile "config.ps1" "$base\config.ps1"
try {
    Install-WinFile "icons\mictext.ico" "$base\icons\mictext.ico"
    Install-WinFile "icons\mictext-rec.ico" "$base\icons\mictext-rec.ico"
} catch {
    Write-Warning "Tray icons missing - tray will use the AutoHotkey default. $($_.Exception.Message)"
}

# Point at AutoHotkey64.exe, not the .ahk file: a bare .ahk shortcut is not
# registered in StartupApproved, so Windows 11 silently skips it at login.
$startupDir = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startupDir 'mictext.lnk'
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
$lnk.TargetPath = $ahkExe
$lnk.Arguments = "`"$base\mictext.ahk`""
$lnk.WorkingDirectory = $base
$ico = "$base\icons\mictext.ico"
if (Test-Path $ico) { $lnk.IconLocation = $ico }
$lnk.Save()

$approved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
if (-not (Test-Path $approved)) {
    New-Item -Path $approved -Force | Out-Null
}
# 02 = enabled (03 = disabled in Task Manager > Startup apps)
$enabled = [byte[]](0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
New-ItemProperty -Path $approved -Name 'mictext.lnk' -PropertyType Binary -Value $enabled -Force | Out-Null

$running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*mictext.ahk*' }
if (-not $running) {
    Start-Process -FilePath $ahkExe -ArgumentList "`"$base\mictext.ahk`""
    Write-Host "Started MicText."
}

Write-Host "Done. Look for the MicText mic logo in the system tray (hold Right Ctrl to dictate)."
Write-Host "It will also start at next login."
Write-Host "Configure: right-click tray icon -> Settings...  or  powershell -File $base\config.ps1"
Write-Host "Windows will prompt for microphone access on first recording - allow it."
