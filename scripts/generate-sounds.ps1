param()

$ErrorActionPreference = "Stop"
$soundsDir = Join-Path $PSScriptRoot "..\plugins\claude-codex-windows-notify\sounds"
if (-not (Test-Path -LiteralPath $soundsDir)) {
    New-Item -ItemType Directory -Path $soundsDir -Force | Out-Null
}

function Write-WavFile {
    param(
        [string]$Path,
        [double[]]$Frequencies,
        [double[]]$Durations,
        [double[]]$Amplitudes,
        [string]$WaveType = "Sine",
        [int]$SampleRate = 44100
    )

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms

    $totalDuration = 0.0
    foreach ($d in $Durations) { $totalDuration += $d }
    $totalSamples = [int]($SampleRate * $totalDuration)

    # RIFF header
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
    $bw.Write([int](36 + $totalSamples * 2))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("WAVE"))

    # fmt subchunk
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("fmt "))
    $bw.Write([int]16)
    $bw.Write([Int16]1) # AudioFormat
    $bw.Write([Int16]1) # NumChannels
    $bw.Write([int]$SampleRate)
    $bw.Write([int]($SampleRate * 2))
    $bw.Write([Int16]2) # BlockAlign
    $bw.Write([Int16]16) # BitsPerSample

    # data subchunk
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("data"))
    $bw.Write([int]($totalSamples * 2))

    $noteCount = $Frequencies.Count

    for ($n = 0; $n -lt $noteCount; $n++) {
        $freq = $Frequencies[$n]
        $dur = $Durations[$n]
        $amp = $Amplitudes[$n]
        $noteSamples = [int]($SampleRate * $dur)

        for ($i = 0; $i -lt $noteSamples; $i++) {
            $t = $i / $SampleRate
            $attackSamples = [int]($SampleRate * 0.005)
            $envelope = 1.0
            if ($i -lt $attackSamples) {
                $envelope = $i / $attackSamples
            } else {
                $decayProgress = ($i - $attackSamples) / ($noteSamples - $attackSamples)
                $envelope = [Math]::Max(0.0, [Math]::Exp(-3.5 * $decayProgress))
            }

            $val = 0.0
            $phase = 2.0 * [Math]::PI * $freq * $t
            if ($WaveType -eq "Sine") {
                $val = [Math]::Sin($phase) + 0.3 * [Math]::Sin(2.0 * $phase) + 0.15 * [Math]::Sin(3.0 * $phase)
            } elseif ($WaveType -eq "Square") {
                $rawSq = if ([Math]::Sin($phase) -ge 0) { 0.7 } else { -0.7 }
                $val = $rawSq + 0.2 * [Math]::Sin($phase)
            } elseif ($WaveType -eq "Triangle") {
                $val = 2.0 * [Math]::Abs(2.0 * ($t * $freq - [Math]::Floor($t * $freq + 0.5))) - 1.0
            }

            $sampleValue = [Int16]([Math]::Max(-32767, [Math]::Min(32767, ($val * $amp * $envelope * 24000))))
            $bw.Write([Int16]$sampleValue)
        }
    }

    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose()
    $ms.Dispose()
}

# 1. Complete Sound: "Level Up!" (Gamified Rising Major Chord Arpeggio: C5 -> E5 -> G5 -> C6)
Write-WavFile -Path (Join-Path $soundsDir "complete.wav") `
    -Frequencies @(523.25, 659.25, 783.99, 1046.50) `
    -Durations @(0.09, 0.09, 0.09, 0.35) `
    -Amplitudes @(0.7, 0.75, 0.8, 0.9) `
    -WaveType "Sine"

# 2. Approval Sound: "Item / Prompt Chime" (Bouncy 2-note chime: E5 -> B5)
Write-WavFile -Path (Join-Path $soundsDir "approval.wav") `
    -Frequencies @(659.25, 987.77) `
    -Durations @(0.08, 0.28) `
    -Amplitudes @(0.75, 0.9) `
    -WaveType "Square"

# 3. Failure Sound: "Game Over / Defeat" (Soft retro 3-note descending: G4 -> E4 -> C4)
Write-WavFile -Path (Join-Path $soundsDir "failure.wav") `
    -Frequencies @(392.00, 329.63, 261.63) `
    -Durations @(0.12, 0.12, 0.35) `
    -Amplitudes @(0.7, 0.65, 0.6) `
    -WaveType "Triangle"

Write-Host "Generated 3 gamified sounds in $soundsDir successfully."
