#Requires -Version 5.1
# A bad cached compiler/runtime must be rejected before anything is executed.
$ErrorActionPreference = 'Stop'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('mictext build test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $manifest = Get-Content -LiteralPath "$PSScriptRoot\..\package-manifest.json" -Raw | ConvertFrom-Json
    $asset = $manifest.autohotkey
    $cachedName = $asset.sha256.Substring(0, 12) + '-' + ([uri]$asset.url).Segments[-1]
    Set-Content -LiteralPath (Join-Path $tempDir $cachedName) -Value 'untrusted bytes'
    # Windows PowerShell turns native stderr into error records under Stop.
    $ErrorActionPreference = 'Continue'
    $message = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\build.ps1" -CacheDirectory $tempDir -OutputDirectory "$tempDir\output" 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -eq 0 -or $message -notmatch 'failed SHA-256 verification') {
        throw "Untrusted cached input was not rejected: $message"
    }
    if (Test-Path -LiteralPath "$tempDir\output\MicText-Windows-x64.zip") {
        throw 'Invalid dependencies must not produce a package'
    }
    Write-Host 'PASS: tampered cached dependency rejected before compilation'
} finally {
    if ((Split-Path $tempDir -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected test directory' }
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
