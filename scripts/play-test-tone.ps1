# Memutar tone uji 10 detik sebagai sesi GSMTC asli bernama "Dumm Test Tone", lalu berhenti.
# Memberi sesi media yang bisa diprediksi tanpa Spotify atau browser.
# Pakai: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\play-test-tone.ps1
param(
    [int]$Seconds = 10,
    [string]$Title = "Dumm Test Tone",
    [string]$Artist = "Dumm Harness"
)

$ErrorActionPreference = 'Stop'

# WAV PCM 16-bit mono 44,1 kHz, sinus 440 Hz dengan amplitudo rendah.
$wav = Join-Path $env:TEMP 'dumm-test-tone.wav'
$rate = 44100
$n = $rate * $Seconds
$fs = [System.IO.File]::Create($wav)
$w = New-Object System.IO.BinaryWriter $fs
$w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $n * 2))
$w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([int]16)
$w.Write([int16]1); $w.Write([int16]1); $w.Write([int]$rate); $w.Write([int]($rate * 2))
$w.Write([int16]2); $w.Write([int16]16)
$w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]($n * 2))
$k = 2 * [math]::PI * 440 / $rate
for ($i = 0; $i -lt $n; $i++) { $w.Write([int16](1500 * [math]::Sin($k * $i))) }
$w.Close()

$null = [Windows.Media.Playback.MediaPlayer, Windows.Media, ContentType = WindowsRuntime]
$null = [Windows.Media.Playback.MediaPlaybackItem, Windows.Media, ContentType = WindowsRuntime]
$null = [Windows.Media.Core.MediaSource, Windows.Media.Core, ContentType = WindowsRuntime]

# Metadata dipasang pada MediaPlaybackItem, bukan DisplayUpdater: MediaPlayer dengan
# CommandManager aktif menimpa DisplayUpdater dengan properti item saat media dibuka
# (terukur: MediaPropertiesChanged berisi judul kosong ~190 ms setelah Play).
$item = New-Object Windows.Media.Playback.MediaPlaybackItem ([Windows.Media.Core.MediaSource]::CreateFromUri([Uri]$wav))
$props = $item.GetDisplayProperties()
$props.Type = [Windows.Media.MediaPlaybackType]::Music
$props.MusicProperties.Title = $Title
$props.MusicProperties.Artist = $Artist
$item.ApplyDisplayProperties($props)

$player = New-Object Windows.Media.Playback.MediaPlayer
$player.Source = $item

$t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$player.Play()
"TONE_MULAI epoch_ms={0} title=""{1}"" artist=""{2}"" durasi_s={3}" -f $t0, $Title, $Artist, $Seconds
Start-Sleep -Seconds $Seconds

$player.Pause()
$player.Dispose()
$t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
"TONE_SELESAI epoch_ms={0}" -f $t1
Remove-Item $wav -ErrorAction SilentlyContinue
