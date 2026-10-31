# Uji kesetiaan warna artwork dengan gambar kontrol 4 kuadran.
#
# Kenapa ada skrip ini: pemeriksaan "ada gambar / tidak ada gambar" tidak bisa menangkap
# kanal warna yang tertukar. Thumbnail asli pernah tampil dengan R dan B tertukar (merah jadi
# biru) karena IWICBitmapScaler mengembalikan format BGRA meski sumbernya diminta RGBA.
# Skrip ini memakai gambar dengan warna yang sudah diketahui pasti, jadi kesalahan kanal
# langsung terlihat sebagai nilai piksel yang salah.
#
# Pakai: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-artwork-color.ps1
param(
    [string]$Exe = "D:\codingan\dumm-notch\target\release\dum-notch.exe",
    [int]$Seconds = 25
)

Add-Type -AssemblyName System.Drawing, System.Runtime.WindowsRuntime
# Skala antarmuka (aturan sama dengan main.rs) dan geometri turunannya.
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
$screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$scale = if ($screenW -le 1600) { 1.0 } elseif ($screenW -le 2000) { 1.3 } elseif ($screenW -le 2600) { 1.5 } else { 1.7 }
$pillExpanded = [int][math]::Round(380 * $scale)
$pillLeft = [int](($screenW - $pillExpanded) / 2)
$pad = [int][math]::Round(12 * $scale)
$artSize = [int][math]::Round(56 * $scale)
$artX = $pillLeft + $pad
$artY = $pad

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ArtColorCtl {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out System.Drawing.Point p);
}
"@ -ReferencedAssemblies System.Drawing

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await-Op($op, $t) {
    if ($null -eq $op) { return $null }
    $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op))
    if (-not $task.Wait(8000)) { return $null }
    return $task.Result
}

# Gambar kontrol 64x64: merah (kiri atas), hijau (kanan atas), biru (kiri bawah), putih.
$png = Join-Path $env:TEMP 'dumm-control-artwork.png'
$bmp = New-Object System.Drawing.Bitmap 64, 64
for ($y = 0; $y -lt 64; $y++) {
    for ($x = 0; $x -lt 64; $x++) {
        $c = if ($x -lt 32 -and $y -lt 32) { [System.Drawing.Color]::FromArgb(255, 255, 0, 0) }
             elseif ($x -ge 32 -and $y -lt 32) { [System.Drawing.Color]::FromArgb(255, 0, 255, 0) }
             elseif ($x -lt 32) { [System.Drawing.Color]::FromArgb(255, 0, 0, 255) }
             else { [System.Drawing.Color]::FromArgb(255, 255, 255, 255) }
        $bmp.SetPixel($x, $y, $c)
    }
}
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$wav = Join-Path $env:TEMP 'dumm-control-tone.wav'
$rate = 44100; $n = $rate * $Seconds
$fs = [System.IO.File]::Create($wav); $w = New-Object System.IO.BinaryWriter $fs
$w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $n * 2))
$w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([int]16)
$w.Write([int16]1); $w.Write([int16]1); $w.Write([int]$rate); $w.Write([int]($rate * 2))
$w.Write([int16]2); $w.Write([int16]16)
$w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]($n * 2))
$k = 2 * [math]::PI * 440 / $rate
for ($i = 0; $i -lt $n; $i++) { $w.Write([int16](1200 * [math]::Sin($k * $i))) }
$w.Close()

$null = [Windows.Media.Playback.MediaPlayer, Windows.Media, ContentType = WindowsRuntime]
$null = [Windows.Media.Playback.MediaPlaybackItem, Windows.Media, ContentType = WindowsRuntime]
$null = [Windows.Media.Core.MediaSource, Windows.Media.Core, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.RandomAccessStreamReference, Windows.Storage.Streams, ContentType = WindowsRuntime]

$file = Await-Op ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
$thumbRef = [Windows.Storage.Streams.RandomAccessStreamReference]::CreateFromFile($file)

# Pause pemutar lain agar sesi kontrol menjadi current session.
$Mgmt = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
$PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$mgr = Await-Op ($Mgmt::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$dipausekan = @()
foreach ($s2 in $mgr.GetSessions()) {
    if ([int]$s2.GetPlaybackInfo().PlaybackStatus -eq 4) {
        $ok = Await-Op ($s2.TryPauseAsync()) ([bool])
        $dipausekan += [pscustomobject]@{ Session = $s2; Berhasil = $ok }
    }
}
Start-Sleep -Milliseconds 600

$item = New-Object Windows.Media.Playback.MediaPlaybackItem ([Windows.Media.Core.MediaSource]::CreateFromUri([Uri]$wav))
$props = $item.GetDisplayProperties()
$props.Type = [Windows.Media.MediaPlaybackType]::Music
$props.MusicProperties.Title = "Dumm Color Probe"
$props.MusicProperties.Artist = "Dumm Harness"
$props.Thumbnail = $thumbRef
$item.ApplyDisplayProperties($props)

$player = New-Object Windows.Media.Playback.MediaPlayer
$player.Source = $item
$player.Play()

$current = ""
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $cs = $mgr.GetCurrentSession()
    if ($cs) {
        $cp = Await-Op ($cs.TryGetMediaPropertiesAsync()) $PropsType
        if ($cp) { $current = $cp.Title }
    }
    if ($current -eq "Dumm Color Probe") { break }
}
if ($current -ne "Dumm Color Probe") {
    "SKIP: sesi kontrol bukan sesi aktif (current='{0}')" -f $current
    foreach ($d in $dipausekan) { if ($d.Berhasil) { $null = Await-Op ($d.Session.TryPlayAsync()) ([bool]) } }
    $player.Pause(); $player.Dispose(); $player = $null
    Remove-Item $wav, $png -ErrorAction SilentlyContinue
    exit 0
}

function Move-To([int]$tx, [int]$ty) {
    $pt = New-Object System.Drawing.Point
    [ArtColorCtl]::GetCursorPos([ref]$pt) | Out-Null
    for ($i = 1; $i -le 12; $i++) {
        [ArtColorCtl]::SetCursorPos([int]($pt.X + ($tx - $pt.X) * $i / 12), [int]($pt.Y + ($ty - $pt.Y) * $i / 12)) | Out-Null
        Start-Sleep -Milliseconds 15
    }
}

Get-Process dum-notch -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 400
$app = Start-Process $Exe -PassThru
Start-Sleep -Seconds 4
Move-To 960 16
Start-Sleep -Milliseconds 1300

"geometri_artwork: x={0} y={1} size={2} skala={3}" -f $artX, $artY, $artSize, $scale
$card = New-Object System.Drawing.Bitmap $artSize, $artSize
$g = [System.Drawing.Graphics]::FromImage($card)
$g.CopyFromScreen($artX, $artY, 0, 0, (New-Object System.Drawing.Size $artSize, $artSize))
$g.Dispose()
$saved = Join-Path $env:TEMP 'dumm-artwork-kontrol-kartu.png'
$card.Save($saved, [System.Drawing.Imaging.ImageFormat]::Png)

$q1 = [int]($artSize * 0.25); $q3 = [int]($artSize * 0.75)
$ujian = @(
    @{ nama = 'merah (kiri atas)'; x = $q1; y = $q1; r = 255; g = 0; b = 0 },
    @{ nama = 'hijau (kanan atas)'; x = $q3; y = $q1; r = 0; g = 255; b = 0 },
    @{ nama = 'biru  (kiri bawah)'; x = $q1; y = $q3; r = 0; g = 0; b = 255 },
    @{ nama = 'putih (kanan bawah)'; x = $q3; y = $q3; r = 255; g = 255; b = 255 }
)
$lulus = 0
foreach ($u in $ujian) {
    $c = $card.GetPixel($u.x, $u.y)
    $selisih = [math]::Abs($c.R - $u.r) + [math]::Abs($c.G - $u.g) + [math]::Abs($c.B - $u.b)
    $ok = $selisih -le 24
    if ($ok) { $lulus++ }
    "{0}: R{1} G{2} B{3} (harus R{4} G{5} B{6}) selisih={7} -> {8}" -f `
        $u.nama, $c.R, $c.G, $c.B, $u.r, $u.g, $u.b, $selisih, $(if ($ok) { "OK" } else { "GAGAL" })
}
$card.Dispose()

Move-To 5 1000
Start-Sleep -Milliseconds 300
$app.Kill()
$player.Pause(); $player.Dispose()
foreach ($d in $dipausekan) { if ($d.Berhasil) { $null = Await-Op ($d.Session.TryPlayAsync()) ([bool]) } }
Remove-Item $wav, $png -ErrorAction SilentlyContinue
"png=$saved"
"HASIL: {0}/4 kuadran cocok -> {1}" -f $lulus, $(if ($lulus -eq 4) { "LULUS" } else { "GAGAL (kanal warna atau konversi format bermasalah)" })
