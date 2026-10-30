# Uji DoD 2.1a/2.1b: putar tone uji, hover pill, simpan tangkapan layar, lalu cek pill
# kembali idle setelah sesi tone hilang, proses tetap hidup, dan isi stderr.
# Build debug mencetak baris "[dumm] media epoch_ms=..." ke stderr untuk mengukur jeda
# dari TONE_MULAI; build release harus menghasilkan stderr kosong.
# Pakai: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-media.ps1 [-Exe <path>]
param(
    [string]$Exe = "D:\codingan\dumm-notch\target\release\dum-notch.exe",
    [string]$Tone = "D:\codingan\dumm-notch\scripts\play-test-tone.ps1"
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DummMediaCursor { [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y); }
"@

if (-not (Test-Path $Exe)) { Write-Output "EXE_TIDAK_ADA: $Exe"; exit 2 }

function Move-To([int]$tx, [int]$ty) {
    $pos = [System.Windows.Forms.Cursor]::Position
    for ($s = 1; $s -le 12; $s++) {
        [DummMediaCursor]::SetCursorPos([int]($pos.X + ($tx - $pos.X) * $s / 12), [int]($pos.Y + ($ty - $pos.Y) * $s / 12)) | Out-Null
        Start-Sleep -Milliseconds 15
    }
}

# Simpan area window 420x160 dan ukur lebar pill gelap pada baris y=8.
function Capture([string]$name) {
    $bmp = New-Object System.Drawing.Bitmap 420, 160
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(750, 0, 0, 0, (New-Object System.Drawing.Size 420, 160))
    $g.Dispose()
    $min = -1; $max = -1
    for ($x = 0; $x -lt 420; $x++) {
        $c = $bmp.GetPixel($x, 8)
        # Cocokkan warna pill #09090b secara ketat; latar desktop hitam (#000) tidak ikut terhitung.
        if ([math]::Abs($c.R - 9) -le 2 -and [math]::Abs($c.G - 9) -le 2 -and [math]::Abs($c.B - 11) -le 2) { if ($min -lt 0) { $min = $x }; $max = $x }
    }
    $png = Join-Path $env:TEMP "dumm-media-$name.png"
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $w = if ($min -lt 0) { 0 } else { $max - $min + 1 }
    "{0}: lebar_pill={1}px png={2}" -f $name, $w, $png
}

$err = Join-Path $env:TEMP 'dumm-media.err'
$toneOut = Join-Path $env:TEMP 'dumm-media-tone.out'
[DummMediaCursor]::SetCursorPos(300, 700) | Out-Null

$p = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $err
Start-Sleep -Seconds 4

$toneProc = Start-Process -FilePath powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Tone `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $toneOut
Start-Sleep -Milliseconds 1500

Move-To 960 16
Start-Sleep -Milliseconds 900
Capture 'saat-tone-expanded'
Move-To 300 700
Start-Sleep -Milliseconds 800
Capture 'saat-tone-idle'

$toneProc.WaitForExit()
Start-Sleep -Milliseconds 1500
Capture 'setelah-tone-idle'
Move-To 960 16
Start-Sleep -Milliseconds 900
Capture 'setelah-tone-expanded'
Move-To 300 700
Start-Sleep -Milliseconds 800

$p.Refresh()
"proses_hidup={0}" -f (-not $p.HasExited)
if (-not $p.HasExited) { $p.Kill() }
Start-Sleep -Milliseconds 300

"--- tone ---"
Get-Content $toneOut
"--- stderr ({0} byte) ---" -f (Get-Item $err).Length
Get-Content $err
