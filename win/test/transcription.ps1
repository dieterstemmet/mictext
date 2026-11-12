# Full local speech -> PCM -> Whisper -> textbox check, using synthesized speech.
param([string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
$ahk = "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
if (-not (Test-Path $ahk)) { $ahk = "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" }
if ($PackageDirectory) { $ahk = Join-Path $PackageDirectory 'MicText.exe' }
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('mictext-transcription-' + [guid]::NewGuid())
New-Item -ItemType Directory $tempDir | Out-Null
try {
    Add-Type -AssemblyName System.Speech
    $voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $voice.SetOutputToWaveFile((Join-Path $tempDir 'speech.wav'))
        $voice.Speak('The quick brown fox jumps over the lazy dog.')
    } finally { $voice.Dispose() }
    $source = Get-Content -Raw -Encoding UTF8 "$PSScriptRoot\..\mictext.ahk"
    $start = $source.IndexOf('ResolveIcons()')
    $end = $source.IndexOf('; =============================================================================', $start)
    $source = $source.Remove($start, $end - $start).Insert($start, "RunTest()`nExitApp()`n")
    # Exercise the production capture command with a file input instead of hardware.
    if (-not $source.Contains('CaptureInput(mic) {')) {
        throw 'Capture adapter changed; update the synthetic input before running this test.'
    }
    $source = $source.Replace('CaptureInput(mic) {', 'OriginalCaptureInput(mic) {')
    # Inference can take seconds; re-establish the test target immediately before
    # the real SendText call so unrelated foreground activity cannot race the check.
    $source = $source.Replace('    lastWin := WinExist("A")', "    FocusTestTextbox()`n    lastWin := WinExist(`"A`")")
    $tests = @'
CaptureInput(mic) {
    return '-stream_loop -1 -re -i "' A_ScriptDir '\speech.wav"'
}
RunTest() {
    global
    if A_Args.Length {
        APP_DIR := A_Args[1]
        BIN_DIR := APP_DIR "\bin"
        MODEL_DIR := APP_DIR "\models"
        WHISPER := BIN_DIR "\whisper-cli.exe"
        FFMPEG := BIN_DIR "\ffmpeg.exe"
    }
    RAW := A_ScriptDir "\audio.pcm"
    WAV := A_ScriptDir "\audio.wav"
    OUT := A_ScriptDir "\out.txt"
    RMS := A_ScriptDir "\rms.txt"
    TERMS_FILE := A_ScriptDir "\terms.json"
    cfgMic := "Synthetic speech"
    boundHotkey := "F13"
    failed := false
    try {
        ; StartRecording uses the real command, with just its input replaced.
        SendEvent("{F13 down}")
        StartRecording()
        Sleep(2000)
        Check(FileExist(RAW) && FileGetSize(RAW) > 16000,
            "Short recording must reach disk before ffmpeg is terminated")
        ; Finish the phrase, then exercise release, the speech gate and SendText.
        Sleep(1500)
        g := Gui(, "MicText transcription test")
        textbox := g.AddEdit("w500 h80")
        g.Show()
        WinActivate(g.Hwnd)
        Check(WinWaitActive(g.Hwnd, , 2), "Test textbox must be active before transcription")
        textbox.Focus()
        SendEvent("{F13 up}")
        StopRecording()
        ; Let this script's own GUI process the input messages from SendText.
        Sleep(100)
        Check(InStr(StrLower(textbox.Value), "quick brown fox"),
            "Whisper must transcribe and insert speech into the textbox; speech frames: " speechFrames
            "; transcript: " lastText "; textbox: " textbox.Value)
        g.Destroy()
        FileAppend("PASS: short capture, release, speech gate, Whisper transcription, textbox insertion`n", "*")
    } catch as e {
        CancelCapture()
        FileAppend("FAIL: " e.Message " at " e.Line "`n", "*")
        failed := true
    } finally {
        SendEvent("{F13 up}")
    }
    Gdip_Shutdown()
    if failed
        ExitApp(1)
}
FocusTestTextbox() {
    global g, textbox
    WinActivate(g.Hwnd)
    Check(WinWaitActive(g.Hwnd, , 2), "Test textbox must be active at insertion")
    textbox.Focus()
}
Check(ok, message) {
    if !ok
        throw Error(message)
}
'@
    $path = Join-Path $tempDir 'transcription.ahk'
    [IO.File]::WriteAllText($path, $source + "`n" + $tests, [Text.UTF8Encoding]::new($true))
    if ($PackageDirectory) {
        & $ahk /script /ErrorStdOut $path $PackageDirectory | Out-Host
    } else {
        & $ahk /ErrorStdOut $path | Out-Host
    }
    if ($LASTEXITCODE -ne 0) { throw "Transcription checks failed ($LASTEXITCODE)" }
} finally {
    if ((Split-Path $tempDir -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected test directory' }
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
