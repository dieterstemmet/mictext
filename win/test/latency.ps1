#Requires -Version 5.1
# Manual hardware check: time until the first level sample; no audio is saved.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MicName,
    [string]$FFmpegPath = 'ffmpeg.exe',
    [ValidateRange(1, 10)][int]$Samples = 3
)
$ErrorActionPreference = 'Stop'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('mictext latency test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    for ($sample = 1; $sample -le $Samples; $sample++) {
        foreach ($mode in @(
            @{ Name = 'default'; Options = '' },
            @{ Name = '50ms'; Options = '-audio_buffer_size 50 ' }
        )) {
            $levels = Join-Path $tempDir "levels-$sample-$($mode.Name).txt"
            $escaped = $levels.Replace('\', '/').Replace(':', '\:')
            $filter = "aresample=16000,asetnsamples=n=160:p=0,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:direct=1:file='$escaped'"
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $FFmpegPath
            $start.Arguments = "-hide_banner -f dshow $($mode.Options)-i audio=`"$MicName`" -ar 16000 -ac 1 -t 0.5 -af `"$filter`" -f null -"
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardError = $true
            $start.RedirectStandardOutput = $true
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $process = [Diagnostics.Process]::Start($start)
            $stderr = $process.StandardError.ReadToEndAsync()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            try {
                while ($clock.ElapsedMilliseconds -lt 15000 -and -not $process.HasExited) {
                    if ((Test-Path -LiteralPath $levels) -and (Get-Item -LiteralPath $levels).Length) { break }
                    Start-Sleep -Milliseconds 5
                }
                $firstAudioMs = $clock.ElapsedMilliseconds
                if (-not $process.WaitForExit(5000)) { $process.Kill(); throw 'Microphone probe timed out' }
                if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $levels)) {
                    throw "Microphone probe failed: $($stderr.Result)"
                }
                $frames = ([regex]::Matches((Get-Content -LiteralPath $levels -Raw), 'RMS_level=')).Count
                if ($frames -lt 40) { throw "Too few level frames: $frames" }
                [pscustomobject]@{ Sample = $sample; Mode = $mode.Name; FirstAudioMs = $firstAudioMs; Frames = $frames }
            } finally {
                if (-not $process.HasExited) { $process.Kill() }
                $process.Dispose()
            }
        }
    }
} finally {
    if ((Split-Path $tempDir -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected test directory' }
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
