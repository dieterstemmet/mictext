#Requires -Version 5.1
# Exercise real capture processes with synthetic audio and deliberately missing key-up callbacks.
param([string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
$ahk = "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
if (-not (Test-Path $ahk)) { $ahk = "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" }
if ($PackageDirectory) { $ahk = Join-Path $PackageDirectory 'MicText.exe' }
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('mictext capture test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $source = Get-Content -LiteralPath "$PSScriptRoot\..\mictext.ahk" -Raw -Encoding UTF8
    $start = $source.IndexOf('ResolveIcons()')
    $end = $source.IndexOf('; =============================================================================', $start)
    $source = $source.Remove($start, $end - $start).Insert($start, "RunTests()`nExitApp()`n")
    if (-not $source.Contains('CaptureInput(mic) {')) { throw 'Update synthetic capture input for the production adapter' }
    $source = $source.Replace('CaptureInput(mic) {', 'OriginalCaptureInput(mic) {')
    $source = $source.Replace("`nTalkKeyHeld() {", "`nOriginalTalkKeyHeld() {")
    $source = $source.Replace('Transcribe() {', 'OriginalTranscribe() {')
    $source = $source.Replace('ShowMeter() {', 'OriginalShowMeter() {')
    $tests = @'
CaptureInput(mic) {
    return '-re -f lavfi -i "sine=frequency=440:sample_rate=16000"'
}
TalkKeyHeld() {
    global talkDown
    return talkDown
}
PressTalk(key) {
    global talkDown
    talkDown := true
    SendEvent("{Blind}{" key " down}")
}
ReleaseTalk(key) {
    global talkDown
    talkDown := false
    SendEvent("{Blind}{" key " up}")
}
Check(ok, message) {
    if !ok
        throw Error(message)
}
WaitIdle(context) {
    global recPid
    deadline := A_TickCount + 1500
    while recPid && A_TickCount < deadline
        Sleep(10)
    Check(!recPid, "Recording must recover: " context)
}
Transcribe() {
    global recPid, transcribeChecks, failTranscribe, RAW, testingMic, testStatus
    CancelCapture() ; Settings/reload may arrive while the transcriber owns its input.
    Check(FileExist(RAW), "Cancel/settings callbacks must not delete audio during transcription")
    panel := Gui()
    mic := panel.AddDropDownList(, ["Synthetic tone"])
    mic.Choose(1)
    testStatus := panel.AddText()
    try {
        ToggleMicTest(mic)
        Check(!recPid && !testingMic, "Mic preview must not take the capture slot during transcription")
    } finally {
        panel.Destroy()
    }
    StartRecording()
    Check(!recPid, "A new recording must not overwrite audio during transcription")
    transcribeChecks++
    if failTranscribe
        throw Error("Synthetic transcription error")
}
ShowMeter() {
    global slowStart
    if slowStart
        Sleep(150)
    OriginalShowMeter()
}
CaptureTestError(error, mode) {
    global errors
    errors.Push(error.Message)
    return 1
}
RunTests() {
    global
    BASE := A_ScriptDir
    CFG_FILE := BASE "\config.ini"
    MIC_FILE := BASE "\mic.txt"
    MODEL_DIR := BASE "\models"
    RAW := BASE "\audio.pcm"
    WAV := BASE "\audio.wav"
    OUT := BASE "\out.txt"
    RMS := BASE "\levels.txt"
    if A_Args.Length {
        BIN_DIR := A_Args[1] "\bin"
        FFMPEG := BIN_DIR "\ffmpeg.exe"
    }
    DirCreate(MODEL_DIR)
    FileAppend("unused test model", MODEL_DIR "\test.bin")
    cfgMic := "Synthetic tone"
    cfgModel := "test.bin"
    cfgMinMs := 50
    SPEECH_FRAMES := 999999 ; These recovery checks must never insert text.
    transcribeChecks := 0
    failTranscribe := false
    failed := false
    slowStart := false
    talkDown := false
    errors := []
    OnError(CaptureTestError)
    BindCancelHotkey()
    SendLevel(1)
    try {
        ; A key-up/timer can arrive after process creation but before the UI exists.
        boundHotkey := "F13", cfgHotkey := "F13"
        PressTalk("F13")
        slowStart := true
        SetTimer(StopRecording, -20)
        StartRecording()
        Sleep(200)
        slowStart := false
        ReleaseTalk("F13")
        Check(!errors.Length, "Release during microphone startup must not access an uninitialized meter")
        Check(!recPid && !recordingUi && !meterGui, "Release during startup must not leave a recording indicator")
        ; No ApplyHotkey call: release is visible to Windows, but has no callback.
        for key in ["F13", "RCtrl", "RAlt"] {
            boundHotkey := key
            cfgHotkey := key
            PressTalk(key)
            StartRecording()
            pid := recPid
            Check(pid, "A held key must start capture")
            Sleep(400)
            Check(recPid = pid && ProcessExist(pid), "Capture must remain active with " key
                . " held; pid=" pid "; capture=" recPid "; key state=" DllCall("GetAsyncKeyState", "int", GetKeyVK(key), "short"))
            ReleaseTalk(key)
            WaitIdle("missing " key " release")
            Check(!ProcessExist(pid) && !recordingUi && !meterGui, "Recovery must close capture and recording UI")
        }
        boundHotkey := "F13", cfgHotkey := "F13"
        PressTalk("F13")
        StartRecording()
        pid := recPid
        ProcessClose(pid)
        WaitIdle("capture crash")
        Check(!recordingUi && !meterGui, "A crashed capture process must clear the recording UI")
        ReleaseTalk("F13")
        StopRecording()

        for key in ["F13", "RCtrl", "RAlt"] {
            boundHotkey := key, cfgHotkey := key
            PressTalk(key)
            StartRecording()
            pid := recPid
            SendEvent("{Blind}{" key " down}{Esc}")
            WaitIdle("Escape with " key " held")
            Check(!ProcessExist(pid) && !recordingUi && !meterGui, "Escape must cancel while the talk modifier is held")
            StartRecording() ; A repeating key produces another key-down while held.
            Check(!recPid, "Cancellation must suppress repeat key-downs until release")
            ReleaseTalk(key)
            Sleep(100) ; No key-up callback: the independent watcher must reset cancellation.
            PressTalk(key)
            StartRecording()
            Check(recPid, "A fresh hold must work after cancellation and release")
            CancelCapture()
            ReleaseTalk(key)
            StopRecording()
        }
        boundHotkey := "F13", cfgHotkey := "F13"

        PressTalk("F13")
        StartRecording()
        pid := recPid
        ; Advance the inactivity deadline instead of waiting ten seconds.
        SetTimer(UpdateMeter, 0)
        lastAudioAt := A_TickCount - 10001
        WaitIdle("stalled audio")
        Check(!ProcessExist(pid) && !recordingUi && !meterGui, "Stalled audio must release the mic and UI")
        ReleaseTalk("F13")
        StopRecording()

        ; Re-enter through the actual stop/transcribe path, including an exception.
        for failTranscribe in [false, true] {
            PressTalk("F13")
            StartRecording()
            Sleep(400)
            SPEECH_FRAMES := 0
            try StopRecording()
            catch as e {
                Check(e.Message = "Synthetic transcription error", e.Message)
            }
            ReleaseTalk("F13")
            SPEECH_FRAMES := 999999
            Check(!recPid && !recordingUi && !meterGui, "Finishing must always clear capture state")
            Check(!FileExist(RAW), "Finished or failed transcription must clean its audio")
        }
        Check(transcribeChecks = 2, "Both transcription paths must run and permit the next recording")
        Check(!errors.Length, "Capture lifecycle must not raise timer or hotkey errors")
        FileAppend("PASS: startup/release races (F13/RCtrl/RAlt), crash, Escape, stalled audio, re-entry, exception cleanup`n", "*")
    } catch as e {
        FileAppend("FAIL: " e.Message " at " e.Line "`n", "*")
        failed := true
    } finally {
        talkDown := false
        SendEvent("{F13 up}{RCtrl up}{RAlt up}")
        CancelCapture()
        Gdip_Shutdown()
    }
    ExitApp(failed ? 1 : 0)
}
'@
    $path = Join-Path $tempDir 'capture.ahk'
    [IO.File]::WriteAllText($path, $source + "`n" + $tests, [Text.UTF8Encoding]::new($true))
    if ($PackageDirectory) { & $ahk /script /ErrorStdOut $path $PackageDirectory | Out-Host }
    else { & $ahk /ErrorStdOut $path | Out-Host }
    if ($LASTEXITCODE -ne 0) { throw "Capture recovery checks failed ($LASTEXITCODE)" }
} finally {
    if ((Split-Path $tempDir -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected test directory' }
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
