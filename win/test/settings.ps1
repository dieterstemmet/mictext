# Regression checks with isolated config and synthetic level metadata (no mic access).
$ErrorActionPreference = 'Stop'
$ahk = "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
if (-not (Test-Path $ahk)) { $ahk = "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" }
$source = Get-Content -Raw -Encoding UTF8 "$PSScriptRoot\..\mictext.ahk"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('mictext-test-' + [guid]::NewGuid())
New-Item -ItemType Directory $tempDir | Out-Null
try {
    # Omit application startup; instrument only dictation callbacks to avoid typing/capture.
    $start = $source.IndexOf('ResolveIcons()')
    $end = $source.IndexOf('; =============================================================================', $start)
    $source = $source.Remove($start, $end - $start).Insert($start, "RunTests()`nExitApp()`n")
    $source = $source.Replace('StartRecording() {', 'OriginalStartRecording() {').Replace('StopRecording() {', 'OriginalStopRecording() {')
    $tests = @'
StartRecording() {
    global presses
    presses++
}
StopRecording() {
    global releases
    releases++
}
Check(ok, message) {
    if !ok
        throw Error(message)
}
RunTests() {
    global
    BASE := A_ScriptDir
    CFG_FILE := BASE "\config.ini"
    MIC_FILE := BASE "\mic.txt"
    RAW := BASE "\test.pcm"
    RMS := BASE "\test-rms.txt"
    presses := 0, releases := 0
    try {
        code := RunWait('ffmpeg -hide_banner -f lavfi -i "sine=frequency=440:duration=0.2" -af "' CaptureLevelFilter() '" -f null -', , "Hide")
        Check(code = 0 && FileExist(RMS), "Capture filter must accept Windows drive paths")
        Check(InStr(FileRead(RMS), "RMS_level="), "Capture filter must produce real level metadata")
        StrReplace(FileRead(RMS), "RMS_level=", "", , &frames)
        Check(frames >= 19 && frames <= 21, "Speech gate requires 100 level frames per second")
        FileDelete(RMS)
        cfgHotkey := "F13"
        loop 3 {
            ApplyHotkey()
            SendLevel(1)
            SendEvent("{F13 down}{F13 up}")
            Sleep(100)
        }
        Check(presses = 3 && releases = 3, "Repeated apply disables hotkeys")
        cfgHotkey := "F14"
        ApplyHotkey()
        SendEvent("{F13 down}{F13 up}{F14 down}{F14 up}")
        Sleep(100)
        Check(presses = 4 && releases = 4, "Changing hotkey leaves wrong bindings")
        cfgHotkey := "F13"
        ApplyHotkey()
        SendEvent("{F13 down}{F13 up}")
        Sleep(100)
        Check(presses = 5 && releases = 5, "Returning to previous key disables it")
        g := Gui()
        settingsGui := g
        testLevel := g.AddProgress("Range0-100")
        testStatus := g.AddText()
        testButton := g.AddButton()
        mic := g.AddDropDownList(, ["Synthetic mic"])
        mic.Choose(1)
        hot := g.AddDropDownList(, ["F13"])
        hot.Choose(1)
        model := g.AddDropDownList(, ["test.bin"])
        model.Choose(1)
        minHold := g.AddEdit(, "300")
        testingMic := true
        recPid := DllCall("GetCurrentProcessId")
        testStarted := A_TickCount
        FileAppend("lavfi.astats.Overall.RMS_level=-30`n", RMS)
        UpdateMicTest()
        Check(testLevel.Value = 50, "Level must use absolute dBFS")
        FileAppend("lavfi.astats.Overall.RMS_level=-inf`n", RMS)
        UpdateMicTest()
        Check(testLevel.Value = 0, "Digital silence must clear the level")
        FileAppend("lavfi.astats.Overall.RMS_level=-", RMS)
        UpdateMicTest()
        FileAppend("12`n", RMS)
        UpdateMicTest()
        Check(testLevel.Value = 80, "Partial metadata lines must be retained")
        recPid := 0  ; Never terminate this test process.
        SaveSettingsFromGui(mic, hot, model, minHold)
        Check(!testingMic && !settingsGui && !FileExist(RMS), "Save must close preview and clean metadata")
        Check(IniRead(CFG_FILE, "MicText", "mic") = "Synthetic mic", "Save must persist selected mic")
        SendEvent("{F13 down}{F13 up}")
        Sleep(100)
        Check(presses = 6 && releases = 6, "Save must keep dictation enabled")
        ReloadAll()
        SendEvent("{F13 down}{F13 up}")
        Sleep(100)
        Check(presses = 7 && releases = 7, "Reload must keep dictation enabled")
        FileAppend("PASS: hotkey apply/change/save/reload, preview levels/silence/partial writes, cleanup`n", "*")
    } catch as e {
        FileAppend("FAIL: " e.Message " at " e.Line "`n", "*")
        ExitApp(1)
    }
}
'@
    $path = Join-Path $tempDir 'settings.ahk'
    [IO.File]::WriteAllText($path, $source + "`n" + $tests, [Text.UTF8Encoding]::new($true))
    & $ahk /ErrorStdOut $path | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Settings regression checks failed ($LASTEXITCODE)" }
} finally {
    # The generated directory is a direct child of the system temporary directory.
    if ((Split-Path $tempDir -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected test directory' }
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
