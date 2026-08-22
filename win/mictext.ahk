#Requires AutoHotkey v2.0
#SingleInstance Force
; MicText: hold hotkey, speak, release -> text typed at the cursor.
; Fully on-device: ffmpeg records, whisper.cpp transcribes, nothing leaves the PC.
; Config: %USERPROFILE%\.mictext\config.ini  (tray icon -> Settings...)
; Tray: brand icons (idle / recording). Waveform: iOS-style rounded pill (GDI+).

; -- paths -------------------------------------------------------------------
BASE      := EnvGet("USERPROFILE") "\.mictext"
CFG_FILE  := BASE "\config.ini"
MIC_FILE  := BASE "\mic.txt"             ; legacy one-liner; migrated into config.ini
BIN_DIR   := BASE "\bin"
MODEL_DIR := BASE "\models"
ICON_DIR  := BASE "\icons"
WHISPER   := BIN_DIR "\whisper-cli.exe"
ICON_IDLE := ICON_DIR "\mictext.ico"
ICON_REC  := ICON_DIR "\mictext-rec.ico"

RAW := A_Temp "\mictext.pcm"
WAV := A_Temp "\mictext.wav"
OUT := A_Temp "\mictext-out.txt"
RMS := A_Temp "\mictext-rms.txt"

; -- runtime config (filled by LoadConfig) -----------------------------------
cfgMic    := ""
cfgHotkey := "RCtrl"
cfgModel  := "ggml-base.en.bin"
cfgMinMs  := 300

recPid := 0
downAt := 0
settingsGui := 0
boundHotkey := ""
recordingUi := false

; -- live waveform meter (tuning: keep in sync with mac/mictext.lua) ---------
; GDI+ layered pill — rounded ends, white bars, dark translucent capsule.
; Matches mac canvas HUD proportions (14 bars × 11px pitch, 26px tall).
BARS := 14
METER_H := 26
METER_W := 17 + BARS * 11   ; 171
gdipToken := 0
meterGui := 0
meterHwnd := 0
meterLevels := []
latest := 0.0
env := 0.0
recent := []
rmsSeen := 0
seen := 0
hiSeen := ""

; -- startup -----------------------------------------------------------------
ResolveIcons()
Gdip_Startup()
LoadConfig()
BuildTray()
SetTrayRecording(false)
ApplyHotkey()
UpdateIconTip()
OnExit(MicTextExit)

; =============================================================================
; Icons / tray chrome
; =============================================================================

ResolveIcons() {
    ; Prefer installed icons under ~/.mictext/icons; fall back to script-adjacent
    ; (repo win/ or win/icons/) so running from source still brands the tray.
    global ICON_IDLE, ICON_REC, ICON_DIR, BASE
    candidates := [
        BASE "\icons",
        A_ScriptDir "\icons",
        A_ScriptDir
    ]
    for dir in candidates {
        idle := dir "\mictext.ico"
        rec  := dir "\mictext-rec.ico"
        if FileExist(idle) {
            ICON_DIR := dir
            ICON_IDLE := idle
            ICON_REC := FileExist(rec) ? rec : idle
            return
        }
    }
}

SetTrayRecording(on) {
    global recordingUi, ICON_IDLE, ICON_REC
    recordingUi := !!on
    path := recordingUi ? ICON_REC : ICON_IDLE
    if FileExist(path)
        TraySetIcon(path)
}

; =============================================================================
; Config
; =============================================================================

LoadConfig() {
    global cfgMic, cfgHotkey, cfgModel, cfgMinMs, CFG_FILE, MIC_FILE, MODEL_DIR
    EnsureConfigFile()
    cfgMic    := IniRead(CFG_FILE, "MicText", "mic", "")
    cfgHotkey := IniRead(CFG_FILE, "MicText", "hotkey", "RCtrl")
    cfgModel  := IniRead(CFG_FILE, "MicText", "model", "ggml-base.en.bin")
    cfgMinMs  := Integer(IniRead(CFG_FILE, "MicText", "min_ms", "300"))
    if (cfgHotkey = "")
        cfgHotkey := "RCtrl"
    if (cfgMinMs < 50)
        cfgMinMs := 50
    if (cfgMic = "" && FileExist(MIC_FILE)) {
        try cfgMic := Trim(FileRead(MIC_FILE), " `t`r`n")
        if (cfgMic != "")
            SaveConfig()
    }
    modelPath := MODEL_DIR "\" cfgModel
    if !FileExist(modelPath) {
        for f in ListModels() {
            cfgModel := f
            break
        }
    }
}

EnsureConfigFile() {
    global CFG_FILE, BASE, cfgMic, cfgHotkey, cfgModel, cfgMinMs
    if FileExist(CFG_FILE)
        return
    DirCreate(BASE)
    cfgMic := ""
    if FileExist(BASE "\mic.txt")
        try cfgMic := Trim(FileRead(BASE "\mic.txt"), " `t`r`n")
    cfgHotkey := "RCtrl"
    cfgModel := "ggml-base.en.bin"
    cfgMinMs := 300
    SaveConfig()
}

SaveConfig() {
    global cfgMic, cfgHotkey, cfgModel, cfgMinMs, CFG_FILE, MIC_FILE
    body := "[MicText]`r`n"
        . "mic=" cfgMic "`r`n"
        . "hotkey=" cfgHotkey "`r`n"
        . "model=" cfgModel "`r`n"
        . "min_ms=" cfgMinMs "`r`n"
    try FileDelete(CFG_FILE)
    FileAppend(body, CFG_FILE, "UTF-8")
    try FileDelete(MIC_FILE)
    try FileAppend(cfgMic, MIC_FILE, "UTF-8-RAW")
}

ListModels() {
    global MODEL_DIR
    out := []
    loop files MODEL_DIR "\*.bin"
        out.Push(A_LoopFileName)
    return out
}

ListMics() {
    out := []
    tmp := A_Temp "\mictext-devices.txt"
    try FileDelete(tmp)
    RunWait(A_ComSpec ' /c ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2> "' tmp '"', , "Hide")
    text := ""
    try text := FileRead(tmp)
    try FileDelete(tmp)
    for line in StrSplit(text, "`n", "`r") {
        if RegExMatch(line, '"([^"]+)"\s+\(audio\)', &m)
            out.Push(m[1])
    }
    return out
}

ModelPath() {
    global MODEL_DIR, cfgModel
    return MODEL_DIR "\" cfgModel
}

UpdateIconTip() {
    global cfgHotkey, cfgMic, cfgModel
    micShort := cfgMic != "" ? cfgMic : "(no mic)"
    if (StrLen(micShort) > 40)
        micShort := SubStr(micShort, 1, 37) "..."
    A_IconTip := "MicText — hold " cfgHotkey "`nMic: " micShort "`nModel: " cfgModel
}

; =============================================================================
; Tray
; =============================================================================

BuildTray() {
    global BASE
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Settings...", (*) => OpenSettings())
    A_TrayMenu.Add("Reload config", (*) => ReloadAll())
    A_TrayMenu.Add("Open config folder", (*) => Run('explorer.exe "' BASE '"'))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Default := "Settings..."
}

ReloadAll() {
    LoadConfig()
    ApplyHotkey()
    UpdateIconTip()
    SetTrayRecording(false)
    TrayTip("Config reloaded", "MicText")
}

ApplyHotkey() {
    global cfgHotkey, boundHotkey
    if (boundHotkey != "") {
        try Hotkey("~*" boundHotkey, "Off")
        try Hotkey("~*" boundHotkey " up", "Off")
    }
    boundHotkey := cfgHotkey
    try {
        Hotkey("~*" boundHotkey, (*) => StartRecording())
        Hotkey("~*" boundHotkey " up", (*) => StopRecording())
    } catch as e {
        TrayTip("Invalid hotkey: " cfgHotkey "`n" e.Message, "MicText")
        if (cfgHotkey != "RCtrl") {
            cfgHotkey := "RCtrl"
            SaveConfig()
            boundHotkey := "RCtrl"
            Hotkey("~*RCtrl", (*) => StartRecording())
            Hotkey("~*RCtrl up", (*) => StopRecording())
        }
    }
}

; =============================================================================
; Settings GUI
; =============================================================================

OpenSettings() {
    global settingsGui, cfgMic, cfgHotkey, cfgModel, cfgMinMs, CFG_FILE
    if settingsGui {
        settingsGui.Show()
        return
    }

    mics := ListMics()
    models := ListModels()
    if (models.Length = 0)
        models.Push(cfgModel != "" ? cfgModel : "ggml-base.en.bin")

    g := Gui("+AlwaysOnTop", "MicText Settings")
    settingsGui := g
    g.SetFont("s10", "Segoe UI")
    g.OnEvent("Close", CloseSettings)
    g.OnEvent("Escape", CloseSettings)

    g.AddText("xm w420", "Microphone (DirectShow)")
    ddMic := g.AddDropDownList("xm w420 r8", mics)
    SelectOrInsert(ddMic, cfgMic, mics)

    g.AddText("xm w420 Section", "Hold-to-talk hotkey")
    hotkeys := ["RCtrl", "RShift", "RAlt", "F8", "F9", "F10", "F13", "CapsLock", "XButton1", "XButton2"]
    ddHot := g.AddDropDownList("xm w200 r10", hotkeys)
    SelectOrInsert(ddHot, cfgHotkey, hotkeys)
    g.AddText("x+10 yp+4 c666666", "AHK key name (e.g. RCtrl)")

    g.AddText("xm w420", "Whisper model (from ~/.mictext/models)")
    ddModel := g.AddDropDownList("xm w420 r6", models)
    SelectOrInsert(ddModel, cfgModel, models)

    g.AddText("xm", "Ignore holds shorter than (ms)")
    edMin := g.AddEdit("xm w100 Number", String(cfgMinMs))

    g.AddText("xm w420 c666666",
        "RAlt is AltGr on many international layouts — prefer RCtrl or a function key.`n"
        . "Changes apply immediately. Config: " CFG_FILE)

    g.AddButton("xm w100 Default", "Save").OnEvent("Click", (*) => SaveSettingsFromGui(ddMic, ddHot, ddModel, edMin))
    g.AddButton("x+10 w100", "Refresh mics").OnEvent("Click", (*) => RefreshMicList(ddMic))
    g.AddButton("x+10 w100", "Cancel").OnEvent("Click", CloseSettings)

    g.Show()
}

CloseSettings(*) {
    global settingsGui
    if settingsGui {
        try settingsGui.Destroy()
        settingsGui := 0
    }
}

SelectOrInsert(dd, value, list) {
    if (value = "") {
        if list.Length
            dd.Choose(1)
        return
    }
    for i, v in list {
        if (v = value) {
            dd.Choose(i)
            return
        }
    }
    dd.Add([value])
    dd.Choose(list.Length + 1)
}

RefreshMicList(ddMic) {
    global cfgMic
    mics := ListMics()
    ddMic.Delete()
    if mics.Length
        ddMic.Add(mics)
    SelectOrInsert(ddMic, cfgMic, mics)
    if !mics.Length
        TrayTip("No dshow audio devices found", "MicText")
}

SaveSettingsFromGui(ddMic, ddHot, ddModel, edMin) {
    global cfgMic, cfgHotkey, cfgModel, cfgMinMs
    mic := ddMic.Text
    hot := ddHot.Text
    model := ddModel.Text
    minMs := Integer(edMin.Value)
    if (hot = "") {
        MsgBox("Hotkey cannot be empty.", "MicText", "Icon!")
        return
    }
    if (minMs < 50)
        minMs := 50
    cfgMic := mic
    cfgHotkey := hot
    cfgModel := model
    cfgMinMs := minMs
    SaveConfig()
    ApplyHotkey()
    UpdateIconTip()
    CloseSettings()
    TrayTip("Saved — hold " cfgHotkey " to dictate", "MicText")
}

; =============================================================================
; GDI+ helpers (minimal subset for layered waveform pill)
; =============================================================================

Gdip_Startup() {
    global gdipToken
    if gdipToken
        return
    if !DllCall("GetModuleHandle", "str", "gdiplus", "ptr")
        DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("uint", 1, si)  ; GdiplusVersion
    if DllCall("gdiplus\GdiplusStartup", "ptr*", &t := 0, "ptr", si, "ptr", 0)
        return
    gdipToken := t
}

Gdip_Shutdown() {
    global gdipToken
    if gdipToken {
        DllCall("gdiplus\GdiplusShutdown", "ptr", gdipToken)
        gdipToken := 0
    }
}

MicTextExit(*) {
    HideMeter()
    Gdip_Shutdown()
}

; Fill a rounded rectangle via GraphicsPath (GdipFillRoundedRectangle is not
; in every GDI+ export set; path arcs are universal).
Gdip_FillRoundRect(pGraphics, pBrush, x, y, w, h, r) {
    if (w <= 0 || h <= 0)
        return
    r := Min(r, w / 2, h / 2)
    if (r < 0.5) {
        DllCall("gdiplus\GdipFillRectangle", "ptr", pGraphics, "ptr", pBrush, "float", x, "float", y, "float", w, "float", h)
        return
    }
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &pPath := 0)
    d := r * 2
    ; clockwise: top-left, top-right, bottom-right, bottom-left
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x, "float", y, "float", d, "float", d, "float", 180, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x + w - d, "float", y, "float", d, "float", d, "float", 270, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x + w - d, "float", y + h - d, "float", d, "float", d, "float", 0, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x, "float", y + h - d, "float", d, "float", d, "float", 90, "float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", pPath)
    DllCall("gdiplus\GdipFillPath", "ptr", pGraphics, "ptr", pBrush, "ptr", pPath)
    DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
}

; =============================================================================
; Waveform meter — iOS-style dark pill, white rounded bars
; =============================================================================

ShowMeter() {
    global meterGui, meterHwnd, meterLevels, latest, env, recent, rmsSeen, seen
    global BARS, METER_W, METER_H, gdipToken
    try {
        if !gdipToken
            Gdip_Startup()
        latest := 0.0, env := 0.0, recent := [], rmsSeen := 0, seen := 0
        meterLevels := []
        loop BARS
            meterLevels.Push(0.0)

        ; WS_EX_LAYERED | WS_EX_TRANSPARENT(click-through) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
        meterGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20 +E0x08000000")
        meterGui.Show("Hide")
        meterHwnd := meterGui.Hwnd

        x := (A_ScreenWidth - METER_W) // 2
        y := A_ScreenHeight - METER_H - 90
        DllCall("SetWindowPos", "ptr", meterHwnd, "ptr", -1, "int", x, "int", y, "int", METER_W, "int", METER_H
            , "uint", 0x0010)  ; SWP_NOACTIVATE

        PaintMeter()
        DllCall("ShowWindow", "ptr", meterHwnd, "int", 8)  ; SW_SHOWNA
        SetTimer(UpdateMeter, 70)
    }
}

PaintMeter() {
    global meterHwnd, meterLevels, BARS, METER_W, METER_H, gdipToken
    if !meterHwnd || !gdipToken
        return

    ; Create 32bpp ARGB bitmap (GdipCreateBitmapFromScan0 with null scan0 allocates)
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", METER_W, "int", METER_H, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &pBitmap := 0)
    if !pBitmap
        return
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", pBitmap, "ptr*", &pGraphics := 0)
    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", pGraphics, "int", 4)  ; AntiAlias
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", pGraphics, "int", 2) ; HighQuality
    DllCall("gdiplus\GdipGraphicsClear", "ptr", pGraphics, "uint", 0x00000000)

    ; Pill background — near-black ~95% opacity (mac: 0.02 rgb, 0.95 a)
    DllCall("gdiplus\GdipCreateSolidFill", "uint", 0xF20A0A0A, "ptr*", &pBg := 0)
    Gdip_FillRoundRect(pGraphics, pBg, 0, 0, METER_W, METER_H, METER_H / 2)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", pBg)

    ; Subtle inner edge (iOS material hint)
    DllCall("gdiplus\GdipCreatePen1", "uint", 0x33FFFFFF, "float", 1, "int", 2, "ptr*", &pEdge := 0)
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &pEdgePath := 0)
    r := METER_H / 2 - 0.5
    d := r * 2
    x := 0.5, y := 0.5, w := METER_W - 1, h := METER_H - 1
    DllCall("gdiplus\GdipAddPathArc", "ptr", pEdgePath, "float", x, "float", y, "float", d, "float", d, "float", 180, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pEdgePath, "float", x + w - d, "float", y, "float", d, "float", d, "float", 270, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pEdgePath, "float", x + w - d, "float", y + h - d, "float", d, "float", d, "float", 0, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", pEdgePath, "float", x, "float", y + h - d, "float", d, "float", d, "float", 90, "float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", pEdgePath)
    DllCall("gdiplus\GdipDrawPath", "ptr", pGraphics, "ptr", pEdge, "ptr", pEdgePath)
    DllCall("gdiplus\GdipDeletePath", "ptr", pEdgePath)
    DllCall("gdiplus\GdipDeletePen", "ptr", pEdge)

    ; White bars — 3px wide, 11px pitch, rounded, min ~2px so silence is a dot line
    DllCall("gdiplus\GdipCreateSolidFill", "uint", 0xFFFFFFFF, "ptr*", &pBar := 0)
    loop BARS {
        i := A_Index
        c := meterLevels.Has(i) ? meterLevels[i] : 0.0
        l := (i > 1) ? meterLevels[i - 1] : c
        rN := (i < meterLevels.Length) ? meterLevels[i + 1] : c
        v := (l + 2 * c + rN) / 4
        bh := 2 + v * 18
        bx := 10 + (i - 1) * 11
        by := (METER_H - bh) / 2
        Gdip_FillRoundRect(pGraphics, pBar, bx, by, 3, bh, 1.5)
    }
    DllCall("gdiplus\GdipDeleteBrush", "ptr", pBar)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGraphics)

    ; HBITMAP -> memory DC -> UpdateLayeredWindow
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", pBitmap, "ptr*", &hBitmap := 0, "uint", 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    if !hBitmap
        return

    hdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
    hdcMem := DllCall("CreateCompatibleDC", "ptr", hdcScreen, "ptr")
    old := DllCall("SelectObject", "ptr", hdcMem, "ptr", hBitmap, "ptr")

    size := Buffer(8)
    NumPut("int", METER_W, size, 0)
    NumPut("int", METER_H, size, 4)
    ptSrc := Buffer(8, 0)
    blend := Buffer(4)
    NumPut("uchar", 0, blend, 0)    ; AC_SRC_OVER
    NumPut("uchar", 0, blend, 1)
    NumPut("uchar", 255, blend, 2)  ; alpha
    NumPut("uchar", 1, blend, 3)    ; AC_SRC_ALPHA

    DllCall("UpdateLayeredWindow"
        , "ptr", meterHwnd
        , "ptr", hdcScreen
        , "ptr", 0
        , "ptr", size
        , "ptr", hdcMem
        , "ptr", ptSrc
        , "uint", 0
        , "ptr", blend
        , "uint", 2)  ; ULW_ALPHA

    DllCall("SelectObject", "ptr", hdcMem, "ptr", old)
    DllCall("DeleteObject", "ptr", hBitmap)
    DllCall("DeleteDC", "ptr", hdcMem)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScreen)
}

PushLevel(db) {
    global latest, recent, seen, hiSeen
    seen++
    if (!IsNumber(db) || seen <= 30) {
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
    latest := Max(0, Min(1, (db - lo - 6) / Max(hi - lo - 6, 12))) ** 0.8
}

UpdateMeter() {
    global meterLevels, latest, env, rmsSeen, RMS
    try {
        lines := StrSplit(FileRead(RMS), "`n", "`r")
        while (rmsSeen < lines.Length) {
            rmsSeen++
            if (p := InStr(lines[rmsSeen], "RMS_level="))
                PushLevel(Trim(SubStr(lines[rmsSeen], p + 10)))
        }
    }
    env := env + (latest - env) * (latest > env ? 0.7 : 0.4)
    meterLevels.RemoveAt(1)
    meterLevels.Push(env)
    PaintMeter()
}

HideMeter() {
    global meterGui, meterHwnd, RMS
    SetTimer(UpdateMeter, 0)
    if meterGui {
        try meterGui.Destroy()
        meterGui := 0
        meterHwnd := 0
    }
    try FileDelete(RMS)
}

; =============================================================================
; Record / transcribe
; =============================================================================

StartRecording() {
    global recPid, downAt, cfgMic, RAW, RMS
    if recPid
        return
    if (cfgMic = "") {
        TrayTip("No mic configured — open Settings from the tray icon", "MicText")
        return
    }
    if !FileExist(ModelPath()) {
        TrayTip("Model missing: " ModelPath(), "MicText")
        return
    }
    downAt := A_TickCount
    try FileDelete(RAW)
    try FileDelete(RMS)
    rmsEsc := StrReplace(StrReplace(RMS, "\", "/"), ":", "\:")
    af := "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:direct=1:file=" rmsEsc
    Run('ffmpeg -y -f dshow -i audio="' cfgMic '" -ar 16000 -ac 1 -af "' af '" -f s16le "' RAW '"', , "Hide", &recPid)
    SetTrayRecording(true)
    ShowMeter()
}

StopRecording() {
    global recPid, downAt, cfgMinMs, RAW
    if !recPid
        return
    pid := recPid
    recPid := 0
    cancelled := (A_TickCount - downAt) < cfgMinMs
    ProcessClose(pid)
    HideMeter()
    SetTrayRecording(false)
    if cancelled {
        try FileDelete(RAW)
        return
    }
    Transcribe()
}

Transcribe() {
    global RAW, WAV, OUT, WHISPER
    if RunWait('ffmpeg -y -f s16le -ar 16000 -ac 1 -i "' RAW '" "' WAV '"', , "Hide") != 0 {
        Cleanup()
        TrayTip("transcription failed", "MicText")
        return
    }
    code := RunWait(A_ComSpec ' /c ""' WHISPER '" -m "' ModelPath() '" -f "' WAV '" -nt -np > "' OUT '""', , "Hide")
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
    global RAW, WAV, OUT
    for f in [RAW, WAV, OUT]
        try FileDelete(f)
}
