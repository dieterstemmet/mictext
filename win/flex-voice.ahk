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
