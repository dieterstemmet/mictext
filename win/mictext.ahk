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
; lines to RMS (audio unchanged). A 70ms timer tails that file and drives 14
; rolling vertical bars in a small always-on-top pill — same look and feel as
; the mac client. Purely cosmetic: failures here must never break recording.
meterGui := 0
meterBars := []
meterLevels := []
latest := 0.0      ; newest normalized level (the tick samples this)
env := 0.0         ; attack/release envelope of latest
recent := []       ; rolling window of raw dB, ~1.3s at ~100 RMS lines/s
rmsSeen := 0       ; RMS-file lines already consumed
seen := 0          ; frames seen this recording (for warmup skip)
hiSeen := ""       ; session memory of the voice's ceiling (across recordings)

ShowMeter() {
    global meterGui, meterBars, meterLevels, latest, env, recent, rmsSeen, seen
    try {
        latest := 0.0, env := 0.0, recent := [], rmsSeen := 0, seen := 0
        meterGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000") ; WS_EX_NOACTIVATE: never steal focus
        meterGui.BackColor := "0A0A0A"
        meterBars := [], meterLevels := []
        loop 14 {
            meterLevels.Push(0.0)
            meterBars.Push(meterGui.AddProgress(
                "x" (10 + (A_Index - 1) * 11) " y3 w3 h20 Vertical cFFFFFF Background0A0A0A Range0-100", 10))
        }
        w := 17 + 14 * 11
        ; bottom-center, clearing the taskbar — matches the mac pill
        meterGui.Show("x" ((A_ScreenWidth - w) // 2) " y" (A_ScreenHeight - 26 - 90) " w" w " h26 NoActivate")
        SetTimer(UpdateMeter, 70)
    }
}

; Adaptive level range: a fixed dB window doesn't transfer across machines
; (mic gain / input volume shift absolute RMS by 20+ dB). Normalize against
; the min/max of the last ~1.3s of raw dB: the window min tracks the ambient
; floor via inter-word dips, the max tracks syllable peaks, outliers
; self-expire. Young windows assume a full speech range (else every early
; syllable is its own maximum and pegs the meter), and the voice's real
; ceiling is remembered across recordings.
PushLevel(db) {
    global latest, recent, seen, hiSeen
    seen++
    if (!IsNumber(db) || seen <= 30) { ; skip astats' first ~0.3s of ramp junk
        latest := 0.0
        return
    }
    db := db + 0.0
    recent.Push(db)
    if (recent.Length > 130)
        recent.RemoveAt(1)
    lo := 999.0, hi := -999.0
    for v in recent
        lo := Min(lo, v), hi := Max(hi, v)
    if (recent.Length = 130)
        hiSeen := Max(hi, ((hiSeen = "") ? hi : hiSeen) - 0.002)
    hi := Max(hi, (hiSeen = "") ? lo + 40 : hiSeen)
    ; 6dB gate above the floor keeps ambient wiggle flat; 12dB min span stops
    ; quiet rooms amplifying noise; ^0.8 lift keeps waves big without pegging.
    latest := Max(0, Min(1, (db - lo - 6) / Max(hi - lo - 6, 12))) ** 0.8
}

UpdateMeter() {
    global meterBars, meterLevels, latest, env, rmsSeen
    ; consume every new RMS line (not just the last: the adaptive window
    ; needs each frame), then advance the display on this fixed clock
    try {
        lines := StrSplit(FileRead(RMS), "`n", "`r")
        while (rmsSeen < lines.Length) {
            rmsSeen++
            if (p := InStr(lines[rmsSeen], "RMS_level="))
                PushLevel(Trim(SubStr(lines[rmsSeen], p + 10)))
        }
    }
    ; attack/release envelope: syllables register in ~70ms, silence falls off
    ; over ~280ms — kills raw RMS jitter without feeling laggy
    env := env + (latest - env) * (latest > env ? 0.7 : 0.4)
    meterLevels.RemoveAt(1)
    meterLevels.Push(env)
    for i, bar in meterBars {
        ; 1-2-1 blur across neighbors rounds the wave into an organic curve;
        ; 10% floor so silence reads as a dot line
        c := meterLevels[i]
        l := (i > 1) ? meterLevels[i - 1] : c
        r := (i < meterLevels.Length) ? meterLevels[i + 1] : c
        bar.Value := Round(10 + ((l + 2 * c + r) / 4) * 90)
    }
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
    af := "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:direct=1:file=" rmsEsc
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
