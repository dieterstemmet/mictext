#Requires -Version 5.1
# Regenerates tray icons (idle + recording) matching assets/logo.svg brand.
# Run from repo: powershell -ExecutionPolicy Bypass -File win\icons\generate-icons.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Draw-MicTextLogo([System.Drawing.Graphics]$g, [int]$size, [bool]$recording) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = $size / 240.0
    $dark  = [System.Drawing.Color]::FromArgb(255, 0x1A, 0x1D, 0x24)
    $cream = [System.Drawing.Color]::FromArgb(255, 0xF2, 0xEF, 0xE7)
    $red   = [System.Drawing.Color]::FromArgb(255, 0xFF, 0x4D, 0x3D)
    $white = [System.Drawing.Color]::White

    if ($recording) {
        $capsule = $red; $grille = $white; $caret = $white; $frame = $red
    } else {
        $capsule = $dark; $grille = $cream; $caret = $red; $frame = $dark
    }

    $cx = 66 * $s; $cy = 24 * $s; $cw = 108 * $s; $ch = 132 * $s
    $radius = 54 * $s
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($cx, $cy, $radius * 2, $radius * 2, 180, 90)
    $path.AddArc($cx + $cw - $radius * 2, $cy, $radius * 2, $radius * 2, 270, 90)
    $path.AddArc($cx + $cw - $radius * 2, $cy + $ch - $radius * 2, $radius * 2, $radius * 2, 0, 90)
    $path.AddArc($cx, $cy + $ch - $radius * 2, $radius * 2, $radius * 2, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.SolidBrush $capsule
    $g.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()

    $penW = [Math]::Max(1.5, 9 * $s)
    $pen = New-Object System.Drawing.Pen $grille, $penW
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, 90 * $s, 58 * $s, 150 * $s, 58 * $s)
    $g.DrawLine($pen, 90 * $s, 80 * $s, 138 * $s, 80 * $s)
    $g.DrawLine($pen, 90 * $s, 102 * $s, 146 * $s, 102 * $s)
    $g.DrawLine($pen, 90 * $s, 124 * $s, 116 * $s, 124 * $s)
    $pen.Dispose()

    $cb = New-Object System.Drawing.SolidBrush $caret
    $g.FillRectangle($cb, 126 * $s, 117 * $s, [Math]::Max(2, 8 * $s), [Math]::Max(3, 15 * $s))
    $cb.Dispose()

    $framePen = New-Object System.Drawing.Pen $frame, ([Math]::Max(1.5, 11 * $s))
    $framePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $framePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arcRect = New-Object System.Drawing.RectangleF (50 * $s), (42 * $s), (140 * $s), (140 * $s)
    $g.DrawArc($framePen, $arcRect, 0, 180)
    $g.DrawLine($framePen, 120 * $s, 182 * $s, 120 * $s, 206 * $s)
    $g.DrawLine($framePen, 90 * $s, 212 * $s, 150 * $s, 212 * $s)
    $framePen.Dispose()

    if ($recording) {
        $ring = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(180, 0xFF, 0x4D, 0x3D)), ([Math]::Max(1, 2 * $s))
        $inset = 3 * $s
        $g.DrawEllipse($ring, $inset, $inset, $size - 2 * $inset, $size - 2 * $inset)
        $ring.Dispose()
    }
}

function New-IcoFile([string]$path, [bool]$recording) {
    $sizes = @(16, 32, 48)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$sizes.Count)

    $imageStreams = @()
    $offset = 6 + (16 * $sizes.Count)

    foreach ($sz in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $sz, $sz, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        Draw-MicTextLogo $g $sz $recording
        $g.Dispose()
        $png = New-Object System.IO.MemoryStream
        $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $bytes = $png.ToArray()
        $png.Dispose()
        $imageStreams += , $bytes

        $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))
        $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $bytes.Length
    }
    foreach ($img in $imageStreams) { $bw.Write($img) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
    Write-Host "Wrote $path"
}

$outDir = $PSScriptRoot
New-IcoFile (Join-Path $outDir 'mictext.ico') $false
New-IcoFile (Join-Path $outDir 'mictext-rec.ico') $true
foreach ($pair in @(@('mictext-32.png', $false), @('mictext-rec-32.png', $true))) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    Draw-MicTextLogo $g 32 $pair[1]
    $g.Dispose()
    $bmp.Save((Join-Path $outDir $pair[0]), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
