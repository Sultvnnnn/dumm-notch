# Uji hover N siklus dengan deteksi baseline-diff.
#
# Cara kerja: tangkap pita layar SEBELUM aplikasi jalan (baseline), lalu bandingkan frame
# berikutnya dengan baseline. Hanya piksel yang berubah karena window Dumm yang dihitung,
# sehingga wallpaper atau jendela lain di belakang area transparan tidak mengacaukan ukuran.
# Deteksi warna absolut tidak dipakai: background gelap membuat background ikut terhitung.
#
# Kriteria lulus: lebar idle ~180 px dan expanded ~380 px pada setiap siklus.
# Pakai: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-hover.ps1
param(
    [string]$Exe = "D:\codingan\dumm-notch\target\release\dum-notch.exe",
    [int]$Cycles = 10,
    [int]$IdleWidth = 180,
    [int]$ExpandedWidth = 380,
    [int]$Tolerance = 8,
    [int]$ScanRow = 8,
    [int]$StripX = 600,
    [int]$StripW = 720
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DummCursor2 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out System.Drawing.Point p);
}
"@ -ReferencedAssemblies System.Drawing

if (-not (Test-Path $Exe)) { Write-Output "EXE_TIDAK_ADA: $Exe"; exit 2 }

function Capture-Strip {
    $bmp = New-Object System.Drawing.Bitmap $StripW, 110
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($StripX, 0, 0, 0, (New-Object System.Drawing.Size $StripW, 110))
    $g.Dispose()
    return $bmp
}

# Lebar pill = panjang run diff yang memuat titik tengah layar (x=960). Run lain di luar pill
# diabaikan, karena jendela lain di belakang bisa berubah dan memperlebar bentang diff
# (pernah terbaca 550 px untuk pill 380 px).
function Measure-DiffWidth($baseline, $frame) {
    $center = 960 - $StripX
    $best = 0
    foreach ($row in 4, 12, 20, 28, 36, 44, 52, 60, 68, 76) {
        $diff = New-Object 'bool[]' $StripW
        for ($x = 0; $x -lt $StripW; $x++) {
            $a = $baseline.GetPixel($x, $row)
            $b = $frame.GetPixel($x, $row)
            $d = [math]::Abs($a.R - $b.R) + [math]::Abs($a.G - $b.G) + [math]::Abs($a.B - $b.B)
            $diff[$x] = ($d -gt 24)
        }
        if (-not $diff[$center]) { continue }
        $l = $center; $r = $center
        while ($l -gt 0 -and $diff[$l - 1]) { $l-- }
        while ($r -lt ($StripW - 1) -and $diff[$r + 1]) { $r++ }
        $w = $r - $l + 1
        if ($w -gt $best) { $best = $w }
    }
    return $best
}

function Move-To([int]$tx, [int]$ty) {
    $pt = New-Object System.Drawing.Point
    [DummCursor2]::GetCursorPos([ref]$pt) | Out-Null
    $sx = $pt.X; $sy = $pt.Y
    for ($s = 1; $s -le 12; $s++) {
        $nx = [int]($sx + ($tx - $sx) * $s / 12)
        $ny = [int]($sy + ($ty - $sy) * $s / 12)
        [DummCursor2]::SetCursorPos($nx, $ny) | Out-Null
        Start-Sleep -Milliseconds 15
    }
}

# Latar putih terkontrol: bila warna desktop sama dengan pill (#09090b), tepi pill tidak
# terukur dari diff dan lebar terbaca salah.
$backdrop = New-Object System.Windows.Forms.Form
$backdrop.FormBorderStyle = 'None'
$backdrop.WindowState = 'Maximized'
$backdrop.BackColor = [System.Drawing.Color]::White
$backdrop.ShowInTaskbar = $false
$backdrop.TopMost = $false
$backdrop.Show()
$backdrop.SendToBack()
Start-Sleep -Milliseconds 500

# Baseline harus diambil tanpa window Dumm di layar.
Get-Process dum-notch -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 500
Move-To 5 1000
Start-Sleep -Milliseconds 500
$baseline = Capture-Strip

$p = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds 4

$lulus = 0
for ($i = 1; $i -le $Cycles; $i++) {
    Move-To 5 1000
    Start-Sleep -Milliseconds 800
    $fIdle = Capture-Strip
    $wIdle = Measure-DiffWidth $baseline $fIdle
    $fIdle.Dispose()

    Move-To 960 16
    Start-Sleep -Milliseconds 900
    $fHover = Capture-Strip
    $wHover = Measure-DiffWidth $baseline $fHover
    $fHover.Dispose()

    $okIdle = [math]::Abs($wIdle - $IdleWidth) -le $Tolerance
    $okHover = [math]::Abs($wHover - $ExpandedWidth) -le $Tolerance
    if ($okIdle -and $okHover) { $lulus++ }
    "siklus {0}: idle={1}px expanded={2}px -> {3}" -f $i, $wIdle, $wHover, $(if ($okIdle -and $okHover) { "OK" } else { "GAGAL" })
}

Move-To 5 1000
Start-Sleep -Milliseconds 800
$p.Kill()
$backdrop.Close()
$backdrop.Dispose()
$baseline.Dispose()
"HASIL: {0}/{1} siklus lulus" -f $lulus, $Cycles
