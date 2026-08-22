#Requires -Version 5.1
# MicText Windows config helper: list/set microphone, hotkey, model, min hold.
# Usage:
#   powershell -ExecutionPolicy Bypass -File win\config.ps1              # interactive
#   powershell -ExecutionPolicy Bypass -File win\config.ps1 -ListMics
#   powershell -ExecutionPolicy Bypass -File win\config.ps1 -SetMic "Microphone Array (Realtek(R) Audio)"
#   powershell -ExecutionPolicy Bypass -File win\config.ps1 -SetHotkey RCtrl
#   powershell -ExecutionPolicy Bypass -File win\config.ps1 -SetModel ggml-base.en.bin
#   powershell -ExecutionPolicy Bypass -File win\config.ps1 -SetMinMs 300
#   powershell -ExecutionPolicy Bypass -File win\config.ps1 -Show

[CmdletBinding()]
param(
    [switch]$ListMics,
    [string]$SetMic,
    [string]$SetHotkey,
    [string]$SetModel,
    [int]$SetMinMs = -1,
    [switch]$Show,
    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$base = "$env:USERPROFILE\.mictext"
$cfg  = Join-Path $base 'config.ini'
$micFile = Join-Path $base 'mic.txt'

function Get-Ffmpeg {
    $ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
    if (-not $ffmpeg) { $ffmpeg = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe" }
    if (-not (Test-Path $ffmpeg)) {
        throw "ffmpeg not found. Run win\install.ps1 first."
    }
    return $ffmpeg
}

function Get-AudioDevices {
    $ffmpeg = Get-Ffmpeg
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $devices = & $ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
    $ErrorActionPreference = $prev
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($devices, '"([^"]+)"\s+\(audio\)')) {
        [void]$list.Add($m.Groups[1].Value)
    }
    return $list
}

function Ensure-Config {
    if (-not (Test-Path $base)) {
        New-Item -ItemType Directory -Force -Path $base | Out-Null
    }
    if (-not (Test-Path $cfg)) {
        $mic = ''
        if (Test-Path $micFile) {
            $mic = (Get-Content -Raw $micFile).Trim()
        }
        @"
[MicText]
mic=$mic
hotkey=RCtrl
model=ggml-base.en.bin
min_ms=300
"@ | Set-Content -Path $cfg -Encoding utf8
    }
}

function Read-Config {
    Ensure-Config
    $ini = Get-Content -Raw $cfg
    $get = {
        param($key, $default)
        if ($ini -match "(?m)^\s*$key\s*=\s*(.*)\s*$") { return $Matches[1].Trim() }
        return $default
    }
    return [pscustomobject]@{
        mic    = & $get 'mic' ''
        hotkey = & $get 'hotkey' 'RCtrl'
        model  = & $get 'model' 'ggml-base.en.bin'
        min_ms = [int](& $get 'min_ms' '300')
    }
}

function Write-Config {
    param(
        [string]$Mic,
        [string]$Hotkey,
        [string]$Model,
        [int]$MinMs
    )
    Ensure-Config
    $c = Read-Config
    if ($PSBoundParameters.ContainsKey('Mic'))    { $c.mic = $Mic }
    if ($PSBoundParameters.ContainsKey('Hotkey')) { $c.hotkey = $Hotkey }
    if ($PSBoundParameters.ContainsKey('Model'))  { $c.model = $Model }
    if ($PSBoundParameters.ContainsKey('MinMs'))  { $c.min_ms = $MinMs }

    $body = @"
[MicText]
mic=$($c.mic)
hotkey=$($c.hotkey)
model=$($c.model)
min_ms=$($c.min_ms)
"@
    # Full rewrite with trailing newline (avoids stacking sections if a reader re-saves)
    [System.IO.File]::WriteAllText($cfg, $body.TrimEnd() + [Environment]::NewLine)

    # Keep legacy mic.txt in sync
    [System.IO.File]::WriteAllText($micFile, $c.mic)
    Write-Host "Wrote $cfg"
    Write-Host "  mic     = $($c.mic)"
    Write-Host "  hotkey  = $($c.hotkey)"
    Write-Host "  model   = $($c.model)"
    Write-Host "  min_ms  = $($c.min_ms)"
    Write-Host "Reload MicText (tray -> Reload config) or restart the tray app for hotkey changes to apply if Settings GUI wasn't used."
}

function Show-Config {
    $c = Read-Config
    Write-Host "Config: $cfg"
    Write-Host "  mic     = $($c.mic)"
    Write-Host "  hotkey  = $($c.hotkey)"
    Write-Host "  model   = $($c.model)"
    Write-Host "  min_ms  = $($c.min_ms)"
    $modelsDir = Join-Path $base 'models'
    if (Test-Path $modelsDir) {
        Write-Host "Models in $modelsDir`:"
        Get-ChildItem $modelsDir -Filter *.bin | ForEach-Object { Write-Host "  - $($_.Name)" }
    }
}

function Invoke-Interactive {
    $devices = @(Get-AudioDevices)
    if ($devices.Count -eq 0) {
        Write-Warning "No dshow audio devices found."
        return
    }
    Write-Host "Available microphones:"
    for ($i = 0; $i -lt $devices.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $devices[$i])
    }
    $c = Read-Config
    if ($c.mic) { Write-Host "Current: $($c.mic)" }
    $choice = Read-Host "Pick mic number (Enter to keep current)"
    if ($choice -match '^\d+$') {
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge $devices.Count) {
            throw "Invalid choice: $choice"
        }
        Write-Config -Mic $devices[$idx]
    } else {
        Write-Host "Mic unchanged."
        Show-Config
    }
}

# --- dispatch ---------------------------------------------------------------
$did = $false

if ($ListMics) {
    $devices = @(Get-AudioDevices)
    if ($devices.Count -eq 0) {
        Write-Warning "No dshow audio devices found."
    } else {
        $devices | ForEach-Object { Write-Output $_ }
    }
    $did = $true
}

if ($PSBoundParameters.ContainsKey('SetMic') -and $null -ne $SetMic) {
    if ($SetMic -eq '') { throw "-SetMic cannot be empty" }
    Write-Config -Mic $SetMic
    $did = $true
}

if ($PSBoundParameters.ContainsKey('SetHotkey') -and $SetHotkey) {
    Write-Config -Hotkey $SetHotkey
    $did = $true
}

if ($PSBoundParameters.ContainsKey('SetModel') -and $SetModel) {
    $path = Join-Path $base "models\$SetModel"
    if (-not (Test-Path $path)) {
        Write-Warning "Model file not found: $path (saving anyway)"
    }
    Write-Config -Model $SetModel
    $did = $true
}

if ($SetMinMs -ge 0) {
    if ($SetMinMs -lt 50) { throw "-SetMinMs must be >= 50" }
    Write-Config -MinMs $SetMinMs
    $did = $true
}

if ($Show) {
    Show-Config
    $did = $true
}

if ($Interactive -or -not $did) {
    Invoke-Interactive
}
