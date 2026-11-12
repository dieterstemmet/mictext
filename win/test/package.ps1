#Requires -Version 5.1
# Test the shipped EXE from a fresh profile and a path with spaces, without tools on PATH.
[CmdletBinding()]
param([string]$PackageZip)
$ErrorActionPreference = 'Stop'
if (-not $PackageZip) { $PackageZip = Join-Path $PSScriptRoot '..\..\dist\windows\MicText-Windows-x64.zip' }
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('mictext package test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    Expand-Archive -LiteralPath $PackageZip -DestinationPath $tempDir
    $package = Join-Path $tempDir 'MicText-Windows-x64'
    $exe = Join-Path $package 'MicText.exe'
    foreach ($line in Get-Content -LiteralPath "$package\SHA256SUMS.txt") {
        $hash, $relative = $line -split '  ', 2
        if ((Get-FileHash -LiteralPath (Join-Path $package $relative) -Algorithm SHA256).Hash -ne $hash) {
            throw "Payload checksum mismatch: $relative"
        }
    }
    $privateFiles = Get-ChildItem -LiteralPath $package -Recurse -File | Where-Object {
        $_.Name -in 'config.ini', 'mic.txt', 'terms.json' -or $_.Extension -in '.wav', '.pcm'
    }
    if ($privateFiles) { throw 'Package must not contain personal settings, learned words or recordings' }
    # A compiled AutoHotkey EXE can also run a test controller with /script.
    # The production EXE is launched normally by that controller; no installed AHK is used.
    $controller = @'
#Requires AutoHotkey v2.0
Check(ok, message) {
    if !ok
        throw Error(message)
}
appPid := 0
failed := false
exe := A_Args[1]
profile := EnvGet("USERPROFILE")
cfg := profile "\.mictext\config.ini"
try {
    Check(!FileExist(cfg), "Test profile must start empty")
    Run('"' exe '"', A_Temp, , &appPid)
    settings := "MicText Settings ahk_pid " appPid
    Check(WinWait(settings, , 10), "First launch must open microphone setup")
    models := ControlGetItems("ComboBox3", settings)
    mics := ControlGetItems("ComboBox1", settings)
    Check(models.Length = 1 && models[1] = "ggml-base.en.bin", "Setup must find the bundled model")
    ; No microphones is valid on a test PC; the complete pipeline uses synthetic audio below.
    Check(FileExist(cfg), "Settings must be created in the user profile")
    ControlChooseString("F13", "ComboBox2", settings)
    ControlClick("Button2", settings) ; Save; Button1 is Test mic.
    Check(WinWaitClose(settings, , 3), "Saving must close setup")
    Check(IniRead(cfg, "MicText", "hotkey") = "F13", "Saving setup must persist the hotkey")
    Check(IniRead(cfg, "MicText", "model") = "ggml-base.en.bin", "Saving setup must persist the bundled model")
    ProcessClose(appPid)
    ProcessWaitClose(appPid, 3)
    appPid := 0

    ; An incomplete extraction must give instructions rather than fail on the first recording.
    SplitPath(exe, , &appDir)
    FileMove(appDir "\bin\ffmpeg.exe", appDir "\bin\ffmpeg.exe.disabled")
    Run('"' exe '"', A_Temp, , &appPid)
    errorWindow := "MicText ahk_class #32770 ahk_pid " appPid
    Check(WinWait(errorWindow, , 5), "Missing bundled tools must show an extraction error")
    Check(InStr(WinGetText(errorWindow), "Extract"), "Error must explain how to extract the package")
    ControlClick("Button1", errorWindow)
    ProcessWaitClose(appPid, 3)
    Check(!ProcessExist(appPid), "Incomplete package must exit after the error")
    appPid := 0
    FileMove(appDir "\bin\ffmpeg.exe.disabled", appDir "\bin\ffmpeg.exe")
    FileAppend("PASS: package checksums, first-run setup, bundled model, save, incomplete extraction; microphones: " mics.Length "`n", "*")
} catch as e {
    FileAppend("FAIL: " e.Message " at " e.Line "`n", "*")
    failed := true
} finally {
    if appPid && ProcessExist(appPid)
        ProcessClose(appPid)
}
ExitApp(failed ? 1 : 0)
'@
    $controllerPath = Join-Path $tempDir 'controller.ahk'
    [IO.File]::WriteAllText($controllerPath, $controller, [Text.UTF8Encoding]::new($true))

    function Invoke-Isolated([string]$file, [string]$arguments) {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $file
        $start.Arguments = $arguments
        $start.WorkingDirectory = $tempDir
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['USERPROFILE'] = $tempDir
        $start.EnvironmentVariables['TEMP'] = $tempDir
        $start.EnvironmentVariables['TMP'] = $tempDir
        $start.EnvironmentVariables['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot"
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        try {
            if (-not $process.WaitForExit(120000)) {
                $process.Kill()
                throw 'Package check timed out'
            }
            Write-Host $stdout.Result.TrimEnd()
            if ($stderr.Result) { Write-Host $stderr.Result.TrimEnd() }
            if ($process.ExitCode -ne 0) { throw "Package check failed ($($process.ExitCode))" }
        } finally { $process.Dispose() }
    }

    Invoke-Isolated $exe "/script /ErrorStdOut `"$controllerPath`" `"$exe`""
    Invoke-Isolated "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\capture.ps1`" -PackageDirectory `"$package`""
    Invoke-Isolated "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\transcription.ps1`" -PackageDirectory `"$package`""
} finally {
    if ((Split-Path $tempDir -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected test directory' }
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
