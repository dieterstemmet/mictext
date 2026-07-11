#Requires AutoHotkey v2.0
#SingleInstance Force
; MicText: hold Right Ctrl, speak, release -> text typed at the cursor.
; Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves the PC.

; -- config ------------------------------------------------------------------
HOLD_KEY := "RCtrl"                     ; hold-to-talk key (RCtrl, not RAlt: RAlt = AltGr on intl layouts)
BASE     := EnvGet("USERPROFILE") "\.mictext"
MODEL    := BASE "\models\ggml-base.en.bin"
WHISPER  := BASE "\bin\whisper-cli.exe"
MIC_FILE := BASE "\mic.txt"             ; dshow device name, written by install.ps1
MIN_MS   := 300                         ; holds shorter than this are cancels
; -----------------------------------------------------------------------------

RAW := A_Temp "\mictext.pcm"
WAV := A_Temp "\mictext.wav"
OUT := A_Temp "\mictext-out.txt"
RMS := A_Temp "\mictext-rms.txt"

A_IconTip := "MicText (hold " HOLD_KEY " to dictate)"
recPid := 0
downAt := 0

; -- live waveform meter ------------------------------------------------------
; The recording ffmpeg also runs the pass-through astats filter, appending RMS
; lines to RMS (audio unchanged). A 100ms timer tails that file and drives 14
; rolling vertical bars in a small always-on-top strip — same look as the web
; mic. Purely cosmetic: any failure here must never break the recording.
meterGui := 0
meterBars := []
meterLevels := []

ShowMeter() {
    global meterGui, meterBars, meterLevels
    try {
        meterGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000") ; WS_EX_NOACTIVATE: never steal focus
        meterGui.BackColor := "1E1E1E"
        meterBars := [], meterLevels := []
        loop 14 {
            meterLevels.Push(0)
            meterBars.Push(meterGui.AddProgress(
                "x" (10 + (A_Index - 1) * 11) " y6 w4 h24 Vertical cD44950 Background303030 Range0-100", 2))
        }
        w := 20 + 14 * 11
        meterGui.Show("x" ((A_ScreenWidth - w) // 2) " y40 w" w " h36 NoActivate")
        SetTimer(UpdateMeter, 100)
    }
}

UpdateMeter() {
    global meterBars, meterLevels
    db := ""
    try {
        lines := StrSplit(FileRead(RMS), "`n", "`r")
        idx := lines.Length
        while idx >= 1 {
            if (p := InStr(lines[idx], "RMS_level=")) {
                db := Trim(SubStr(lines[idx], p + 10))
                break
            }
            idx--
        }
    }
    lv := 2 ; floor so idle bars stay visible
    if IsNumber(db)
        lv := Max(2, Min(100, Round((db + 50) * 2))) ; -50 dB floor -> 0-100
    meterLevels.RemoveAt(1)
    meterLevels.Push(lv)
    for i, bar in meterBars
        bar.Value := meterLevels[i]
}

HideMeter() {
    global meterGui
    SetTimer(UpdateMeter, 0)
    if meterGui {
        try meterGui.Destroy()
        meterGui := 0
    }
    try FileDelete(RMS)
}

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
        TrayTip("No mic configured - run install.ps1", "MicText")
        return
    }
    downAt := A_TickCount
    try FileDelete(RAW)
    try FileDelete(RMS)
    ; filtergraph paths need ':' and '\' escaped (filter option syntax)
    rmsEsc := StrReplace(StrReplace(RMS, "\", "/"), ":", "\:")
    af := "astats=metadata=1:reset=0.15,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:direct=1:file=" rmsEsc
    Run('ffmpeg -y -f dshow -i audio="' mic '" -ar 16000 -ac 1 -af "' af '" -f s16le "' RAW '"', , "Hide", &recPid)
    ShowMeter()
}

StopRecording() {
    global recPid
    if !recPid
        return
    pid := recPid
    recPid := 0
    cancelled := (A_TickCount - downAt) < MIN_MS
    ProcessClose(pid)
    HideMeter()
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
        TrayTip("transcription failed", "MicText")
        return
    }
    code := RunWait(A_ComSpec ' /c ""' WHISPER '" -m "' MODEL '" -f "' WAV '" -nt -np > "' OUT '""', , "Hide")
    text := ""
    if (code = 0)
        try text := Trim(FileRead(OUT, "UTF-8"), " `t`r`n")
    Cleanup()
    if (code != 0) {
        TrayTip("transcription failed", "MicText")
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
