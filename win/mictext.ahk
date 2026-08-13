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
; Silence gate (keep in sync with mac/mictext.lua and web/src/silence.js):
; dB above the rolling-window floor that counts as speech, and how many such
; frames a real utterance needs (~100ms at astats' ~100 lines/s). Relative,
; never absolute. astats is fixed-rate, so we pass SPEECH_FRAMES directly (the
; web reference rate-derives it; see the framesForRate note in silence.js).
SPEECH_DB     := 12
SPEECH_FRAMES := 10
; -----------------------------------------------------------------------------

RAW := A_Temp "\mictext.pcm"
WAV := A_Temp "\mictext.wav"
OUT := A_Temp "\mictext-out.txt"
RMS := A_Temp "\mictext-rms.txt"

A_IconTip := "MicText (hold " HOLD_KEY " to dictate)"
recPid := 0
downAt := 0

; -- live waveform meter (tuning constants: keep in sync with mac/mictext.lua) ------------------------------------------------------
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
speechFrames := 0  ; frames this recording that cleared the window floor by SPEECH_DB
capturing := false ; true once ffmpeg has actually opened the device (warming ends)

; --- learned vocabulary state (hand-port of web/src/terms.js; keep in sync) ---
TERMS := BASE "\terms.json"
PROMPT_MAX_CHARS := 200   ; whisper truncates its prompt from the FRONT
MAX_PAIR_WORDS   := 6     ; longer corrections bias only, never replace
SENTINEL := Chr(0x1F)     ; \x1F Unit Separator; NEVER Chr(0) — AHK strings are
                          ; null-terminated, an embedded NUL would truncate them
lastText := "", lastWin := 0, sinceHook := 0

ShowMeter() {
    global meterGui, meterBars, meterLevels, latest, env, recent, rmsSeen, seen, speechFrames
    try {
        latest := 0.0, env := 0.0, recent := [], rmsSeen := 0, seen := 0, speechFrames := 0
        meterGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000") ; WS_EX_NOACTIVATE: never steal focus
        ; Dim while warming: the pill is visible (the press registered) but the
        ; bars stay flat until audio arrives. UpdateMeter darkens it to 0A0A0A
        ; on the first RMS line.
        meterGui.BackColor := "3A3A3A"
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
    global latest, recent, seen, hiSeen, speechFrames, SPEECH_DB
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
    ; Silence gate: count frames well above the clip's own rolling floor.
    ; db is numeric here — astats' -inf digital-silence frames fail IsNumber()
    ; above and return early, so they never reach this count.
    if (db - lo > SPEECH_DB)
        speechFrames++
    if (recent.Length = 130)
        hiSeen := Max(hi, ((hiSeen = "") ? hi : hiSeen) - 0.002)
    hi := Max(hi, (hiSeen = "") ? lo + 40 : hiSeen)
    ; 6dB gate above the floor keeps ambient wiggle flat; 12dB min span stops
    ; quiet rooms amplifying noise; ^0.8 lift keeps waves big without pegging.
    latest := Max(0, Min(1, (db - lo - 6) / Max(hi - lo - 6, 12))) ** 0.8
}

UpdateMeter() {
    global meterBars, meterLevels, latest, env, rmsSeen, capturing, meterGui
    ; consume every new RMS line (not just the last: the adaptive window
    ; needs each frame), then advance the display on this fixed clock
    try {
        lines := StrSplit(FileRead(RMS), "`n", "`r")
        while (rmsSeen < lines.Length) {
            rmsSeen++
            if (p := InStr(lines[rmsSeen], "RMS_level=")) {
                ; ffmpeg writes nothing before the device opens, so the FIRST
                ; RMS line is the first captured sample: warming ends here.
                if (!capturing) {
                    capturing := true
                    A_IconTip := "MicText (recording)"
                    try meterGui.BackColor := "0A0A0A"
                }
                PushLevel(Trim(SubStr(lines[rmsSeen], p + 10)))
            }
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
    global meterGui, HOLD_KEY
    SetTimer(UpdateMeter, 0)
    if meterGui {
        try meterGui.Destroy()
        meterGui := 0
    }
    try FileDelete(RMS)
    A_IconTip := "MicText (hold " HOLD_KEY " to dictate)"
}

; ponytail: record headerless raw PCM so a hard ProcessClose can't corrupt the
; file (wav headers are finalized on close); a second instant ffmpeg pass wraps
; it into a wav. Avoids graceful-shutdown plumbing for console apps on Windows.
StartRecording() {
    global recPid, downAt, capturing
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
    capturing := false
    A_IconTip := "MicText (warming up...)"
    ShowMeter()
}

StopRecording() {
    global recPid, speechFrames, SPEECH_FRAMES
    if !recPid
        return
    pid := recPid
    recPid := 0
    cancelled := (A_TickCount - downAt) < MIN_MS
    ProcessClose(pid)
    ; One last tail before the meter tears down: the 70ms timer may not have
    ; consumed the final RMS lines, and they count toward the gate.
    UpdateMeter()
    quiet := speechFrames < SPEECH_FRAMES
    HideMeter()
    if (cancelled || quiet) {   ; held but said nothing = silent no-op
        try FileDelete(RAW)
        return
    }
    Transcribe()
}

; --- learned vocabulary functions (hand-port of web/src/terms.js) -------------
; AHK v2 ships no JSON parser, so JSON is hand-rolled. RegExReplace is real
; PCRE, so \b and the i) flag work directly (unlike the Lua port's %f frontier
; patterns + manual case-folding), and pass-2 uses StrReplace (literal), so the
; $-escaping the terms.js note warns about is a non-issue here.
NowIso() => FormatTime(A_NowUTC, "yyyy-MM-dd") "T" FormatTime(A_NowUTC, "HH:mm:ss") "Z"
JsonEsc(s) => StrReplace(StrReplace(StrReplace(s, "\", "\\"), '"', '\"'), "`n", " ")
JsonUnesc(s) => StrReplace(StrReplace(s, '\"', '"'), "\\", "\")

Words(s) {
    t := Trim(RegExReplace(s "", "\s+", " "))
    return (t = "") ? [] : StrSplit(t, " ")
}

; Normalization boundary: fields are extracted individually so field ORDER in
; the file doesn't matter (hs.json.write on the Mac doesn't guarantee it), and
; records missing a usable heard/said are dropped.
LoadTerms() {
    global TERMS
    out := []
    try
        raw := FileRead(TERMS, "UTF-8")
    catch
        return out
    pos := 1
    while (RegExMatch(raw, "s)\{[^{}]*\}", &rec, pos)) {
        pos := rec.Pos + rec.Len
        block := rec[0]
        if (!RegExMatch(block, '"heard"\s*:\s*"((?:\\.|[^"\\])*)"', &mh)
         || !RegExMatch(block, '"said"\s*:\s*"((?:\\.|[^"\\])*)"', &ms))
            continue
        heard := JsonUnesc(mh[1]), said := JsonUnesc(ms[1])
        if (heard = "" || said = "")
            continue
        n  := RegExMatch(block, '"n"\s*:\s*(\d+)', &mn) ? mn[1] + 0 : 0
        at := RegExMatch(block, '"at"\s*:\s*"([^"]*)"', &ma) ? ma[1] : ""
        out.Push({ heard: heard, said: said, n: n, at: at })
    }
    return out
}

SaveTerms(terms) {
    global TERMS
    parts := []
    for t in terms {
        at := (t.HasOwnProp("at") && t.at != "") ? t.at : NowIso()
        parts.Push('  {"heard": "' JsonEsc(t.heard) '", "said": "' JsonEsc(t.said) '", "n": ' t.n ', "at": "' at '"}')
    }
    body := "[`n"
    for i, p in parts
        body .= p (i < parts.Length ? ",`n" : "`n")
    body .= "]`n"
    try DirCreate(RegExReplace(TERMS, "\\[^\\]+$"))  ; ensure the .mictext dir exists
    try FileDelete(TERMS)
    try FileAppend(body, TERMS, "UTF-8-RAW")         ; no BOM, so hs.json on the Mac reads it
}

; Newest first, de-duplicated, capped on a word boundary. A word that doesn't
; fit is skipped (not aborted), so one oversized word can't zero the prompt.
PromptFrom(terms) {
    global PROMPT_MAX_CHARS
    seen := Map(), out := [], len := 0
    i := terms.Length
    while (i >= 1) {
        for w in Words(terms[i].said) {
            key := StrLower(w)
            if (seen.Has(key)) {
                continue
            }
            seen[key] := 1
            add := (out.Length ? StrLen(w) + 2 : StrLen(w))
            if (len + add <= PROMPT_MAX_CHARS) {
                out.Push(w)
                len += add
            }
        }
        i--
    }
    result := ""
    for j, w in out
        result .= (j > 1 ? ", " : "") w
    return result
}

; Eligible to rewrite output: <= MAX_PAIR_WORDS words, and (>= 4 chars or multi-word).
Replaceable(t) {
    global MAX_PAIR_WORDS
    w := Words(t.heard)
    return w.Length > 0 && w.Length <= MAX_PAIR_WORDS && (StrLen(Trim(t.heard)) >= 4 || w.Length > 1)
}

EscapeRe(s) => RegExReplace(s, "[\\.\*\+\?\(\)\[\]\{\}\^\$\|]", "\$0")

; Two-pass replacement (mirror of applyTerms): pass 1 swaps each match for a
; numbered sentinel via PCRE (longest-first); pass 2 swaps sentinels for the
; real text with StrReplace, which is LITERAL — so $/% in `said` need no guard.
ApplyTerms(text, terms) {
    global SENTINEL
    out := StrReplace(text "", SENTINEL, "")   ; strip any sentinel already in input
    usable := []
    for t in terms
        if (Replaceable(t))
            usable.Push(t)
    ; longest trimmed-heard first (insertion sort; the list is a handful)
    loop usable.Length {
        i := A_Index
        while (i > 1 && StrLen(Trim(usable[i-1].heard)) < StrLen(Trim(usable[i].heard))) {
            tmp := usable[i-1], usable[i-1] := usable[i], usable[i] := tmp
            i--
        }
    }
    for i, t in usable {
        heard := Trim(t.heard)
        lead := RegExMatch(heard, "^\w") ? "\b" : ""
        tail := RegExMatch(heard, "\w$") ? "\b" : ""
        out := RegExReplace(out, "i)" lead EscapeRe(heard) tail, SENTINEL i SENTINEL)
    }
    for i, t in usable
        out := StrReplace(out, SENTINEL i SENTINEL, t.said)
    return out
}

Learn(terms, heard, said) {
    h := Trim(heard ""), s := Trim(said "")
    if (h = "" || s = "" || StrLower(h) = StrLower(s))
        return terms
    rest := [], prevN := 0
    for t in terms {
        if (StrLower(t.heard) = StrLower(h))
            prevN := t.n
        else
            rest.Push(t)
    }
    rest.Push({ heard: h, said: s, n: prevN + 1, at: NowIso() })
    return rest
}

; Whisper fed near-silence hallucinates rather than returning "". Matched on
; the WHOLE trimmed transcript, so "thank you for the ride" survives.
; (Keep in sync with mac/mictext.lua and web/src/silence.js. StrLower keeps
; the lookup robust regardless of Map default case sensitivity.)
IsArtifact(text) {
    static ARTIFACTS := Map(
        ".", 1, "..", 1, "...", 1,
        "[blank_audio]", 1, "(blank_audio)", 1,
        "[silence]", 1, "(silence)", 1, "[ silence ]", 1,
        "you", 1, "thank you", 1, "thank you.", 1,
        "thanks for watching!", 1, "thanks for watching.", 1,
        "bye", 1, "bye.", 1)
    return ARTIFACTS.Has(StrLower(text))
}

Transcribe() {
    global lastText, lastWin, sinceHook   ; assigned below, so must be declared
    ; wrap raw pcm into a wav whisper-cli can read
    if RunWait('ffmpeg -y -f s16le -ar 16000 -ac 1 -i "' RAW '" "' WAV '"', , "Hide") != 0 {
        Cleanup()
        TrayTip("transcription failed", "MicText")
        return
    }
    ; strip quotes from the prompt rather than escape them through cmd.exe
    prompt := StrReplace(PromptFrom(LoadTerms()), '"', "")
    promptArg := (prompt = "") ? "" : ' --prompt "' prompt '"'
    code := RunWait(A_ComSpec ' /c ""' WHISPER '" -m "' MODEL '" -f "' WAV '" -nt -np' promptArg ' > "' OUT '""', , "Hide")
    text := ""
    if (code = 0)
        try text := Trim(FileRead(OUT, "UTF-8"), " `t`r`n")
    Cleanup()
    if (code != 0) {
        TrayTip("transcription failed", "MicText")
        return
    }
    if (text = "" || IsArtifact(text))
        return
    ; lastText is what was actually TYPED (post-replacement): both the backspace
    ; count and the "heard" side of any correction — you correct what you see.
    fixed := ApplyTerms(text, LoadTerms())
    lastWin := WinExist("A")
    SendText(fixed)
    lastText := fixed
    ; Arm a typed-since detector: an InputHook in visible mode passes keys
    ; through untouched and only records what arrived. Read its length BEFORE
    ; the fix dialog (below) so the correction you type there never counts.
    try sinceHook.Stop()
    sinceHook := InputHook("V")
    sinceHook.Start()
}

Cleanup() {
    for f in [RAW, WAV, OUT]
        try FileDelete(f)
}

; "Fix that": correct the last transcript in place and remember the pair.
; Deliberately explicit — nothing reads your screen or diffs your document.
FixLast() {
    global lastText, lastWin, sinceHook
    if (lastText = "") {
        TrayTip("nothing to fix", "MicText")
        return
    }
    heard := lastText
    ; Snapshot BEFORE the dialog: sinceHook keeps collecting while you type the
    ; correction, and that typing must not read as "you edited the document".
    typedSince := 0
    try typedSince := StrLen(sinceHook.Input)
    ib := InputBox("What did you actually say?", "MicText: fix that", "w420 h130", heard)
    if (ib.Result != "OK")
        return
    corrected := Trim(ib.Value)
    if (corrected = "" || corrected = heard)
        return
    ; In-place rewrite ONLY when provably safe: same window, nothing typed
    ; since. Otherwise the correction goes to the clipboard — never guess at
    ; the contents of someone's document.
    if (WinExist("A") = lastWin && typedSince = 0) {
        Send("{BS " StrLen(heard) "}")
        SendText(corrected)
    } else {
        A_Clipboard := corrected
        TrayTip("correction copied to clipboard", "MicText")
    }
    SaveTerms(Learn(LoadTerms(), heard, corrected))
    lastText := ""
    try sinceHook.Stop()
}

Hotkey("!+f", (*) => FixLast())
Hotkey("~*" HOLD_KEY, (*) => StartRecording())
Hotkey("~*" HOLD_KEY " up", (*) => StopRecording())
