#Requires -Version 5.1
# Build a portable x64 Windows package. No installed MicText, winget or admin needed.
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$CacheDirectory
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '..\dist\windows' }
if (-not $CacheDirectory) { $CacheDirectory = Join-Path $PSScriptRoot '..\.build\windows' }
$manifest = Get-Content -Raw "$PSScriptRoot\package-manifest.json" | ConvertFrom-Json
$cache = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CacheDirectory).TrimEnd('\')
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $cache, $output | Out-Null

function Get-VerifiedAsset($asset) {
    $name = ([uri]$asset.url).Segments[-1]
    $path = Join-Path $cache ($asset.sha256.Substring(0, 12) + '-' + $name)
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Downloading $name"
        Invoke-WebRequest -UseBasicParsing -Uri $asset.url -OutFile "$path.partial"
        if ((Get-FileHash -LiteralPath "$path.partial" -Algorithm SHA256).Hash -ne $asset.sha256) {
            throw "SHA-256 mismatch for $name; refusing to use this download."
        }
        Move-Item -LiteralPath "$path.partial" -Destination $path -Force
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $asset.sha256) {
        throw "Cached $name failed SHA-256 verification. Remove it and rebuild."
    }
    return $path
}

function Expand-Asset([string]$name, [string]$destination) {
    $archive = Get-VerifiedAsset $manifest.$name
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $destination)
}

# Use a fresh staging directory so previous builds cannot leak files into a package.
$stage = Join-Path $cache ('stage-' + [guid]::NewGuid())
$package = Join-Path $stage 'MicText-Windows-x64'
New-Item -ItemType Directory -Path "$package\bin", "$package\models", "$package\icons", "$package\licenses", "$package\source\win" -Force | Out-Null
try {
    foreach ($name in 'autohotkey', 'compiler', 'ffmpeg', 'whisper', 'vclibs') {
        Expand-Asset $name (Join-Path $stage $name)
    }
    $compiler = Join-Path $stage 'compiler\Ahk2Exe.exe'
    $runtime = Join-Path $stage 'autohotkey\AutoHotkey64.exe'
    $exe = Join-Path $package 'MicText.exe'
    & $compiler /in "$PSScriptRoot\mictext.ahk" /out $exe /base $runtime /icon "$PSScriptRoot\icons\mictext.ico" /compress 0 /silent verbose | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
        throw "Ahk2Exe failed ($LASTEXITCODE)."
    }

    $ffmpeg = Get-ChildItem -LiteralPath "$stage\ffmpeg" -Filter ffmpeg.exe -File -Recurse | Select-Object -First 1
    Copy-Item -LiteralPath $ffmpeg.FullName -Destination "$package\bin\ffmpeg.exe"
    $whisper = Get-ChildItem -LiteralPath "$stage\whisper" -Filter whisper-cli.exe -File -Recurse | Select-Object -First 1
    Copy-Item -LiteralPath $whisper.FullName -Destination "$package\bin\whisper-cli.exe"
    Get-ChildItem -LiteralPath $whisper.DirectoryName -Filter '*.dll' -File | Where-Object {
        $_.Name -eq 'whisper.dll' -or $_.Name -like 'ggml*.dll'
    } | Copy-Item -Destination "$package\bin"
    foreach ($dll in 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'vcomp140.dll', 'concrt140.dll') {
        Copy-Item -LiteralPath "$stage\vclibs\$dll" -Destination "$package\bin"
    }
    Copy-Item -LiteralPath (Get-VerifiedAsset $manifest.model) -Destination "$package\models\ggml-base.en.bin"
    Copy-Item -LiteralPath "$PSScriptRoot\icons\mictext.ico", "$PSScriptRoot\icons\mictext-rec.ico" -Destination "$package\icons"
    Copy-Item -LiteralPath "$PSScriptRoot\..\LICENSE" -Destination "$package\LICENSE.txt"
    Copy-Item -LiteralPath "$PSScriptRoot\portable\README.txt", "$PSScriptRoot\portable\THIRD-PARTY-NOTICES.txt" -Destination $package
    Copy-Item -LiteralPath "$stage\autohotkey\license.txt" -Destination "$package\licenses\AutoHotkey.txt"
    Get-ChildItem -LiteralPath "$PSScriptRoot\portable\licenses" -File | Copy-Item -Destination "$package\licenses"
    $ffmpegLicense = Get-ChildItem -LiteralPath "$stage\ffmpeg" -Filter LICENSE -File -Recurse | Select-Object -First 1
    Copy-Item -LiteralPath $ffmpegLicense.FullName -Destination "$package\licenses\FFmpeg.txt"
    Copy-Item -LiteralPath (Join-Path $ffmpegLicense.DirectoryName 'README.txt') -Destination "$package\licenses\FFmpeg-build.txt"
    Copy-Item -LiteralPath (Get-VerifiedAsset $manifest.autohotkeySource) -Destination "$package\source\AutoHotkey-v2.0.26.zip"
    Copy-Item -LiteralPath "$PSScriptRoot\mictext.ahk", "$PSScriptRoot\build.ps1", "$PSScriptRoot\package-manifest.json", "$PSScriptRoot\README.md" -Destination "$package\source\win"
    Copy-Item -LiteralPath "$PSScriptRoot\portable" -Destination "$package\source\win" -Recurse
    Copy-Item -LiteralPath "$PSScriptRoot\test" -Destination "$package\source\win" -Recurse
    Copy-Item -LiteralPath "$PSScriptRoot\icons" -Destination "$package\source\win" -Recurse
    Copy-Item -LiteralPath "$PSScriptRoot\..\LICENSE" -Destination "$package\source\LICENSE"
    Copy-Item -LiteralPath "$PSScriptRoot\package-manifest.json" -Destination "$package\dependencies.json"

    # Hash the payload as well as downloads, for auditing an extracted package.
    Get-ChildItem -LiteralPath $package -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($package.Length + 1).Replace('\', '/')
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
    } | Set-Content -LiteralPath "$package\SHA256SUMS.txt" -Encoding ASCII

    $zip = Join-Path $stage 'MicText-Windows-x64.zip'
    # .NET Framework's CreateFromDirectory writes backslashes. Use standard ZIP
    # separators so the same archive can be inspected/extracted by other tools.
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $package -Recurse -File | Sort-Object FullName | ForEach-Object {
            $entry = 'MicText-Windows-x64/' + $_.FullName.Substring($package.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $archive.Dispose() }
    $destination = Join-Path $output 'MicText-Windows-x64.zip'
    Move-Item -LiteralPath $zip -Destination $destination -Force
    (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() + '  MicText-Windows-x64.zip' |
        Set-Content -LiteralPath "$destination.sha256" -Encoding ASCII
    Write-Host "Built $destination"
} finally {
    # Only our unique staging directory, a direct child of the selected cache.
    if ((Split-Path $stage -Parent) -ne $cache) { throw 'Unexpected staging directory' }
    Remove-Item -LiteralPath $stage -Recurse -Force
}
