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
    # 0 = hitung otomatis dari lebar layar memakai aturan yang sama dengan main.rs.
    [int]$IdleWidth = 0,
    [int]$ExpandedWidth = 0,
    [int]$Tolerance = 8,
    [int]$ScanRow = 8,
    [int]$StripX = 600,
    [int]$StripW = 720
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Skala antarmuka: main.rs memakai 1.0 (<=1600), 1.3 (<=2000), 1.5 (<=2600), 1.7 (>2600).
$screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$scale = if ($screenW -le 1600) { 1.0 } elseif ($screenW -le 2000) { 1.3 } elseif ($screenW -le 2600) { 1.5 } else { 1.7 }
if ($IdleWidth -eq 0) { $IdleWidth = [int][math]::Round(180 * $scale) }
if ($ExpandedWidth -eq 0) { $ExpandedWidth = [int][math]::Round(380 * $scale) }
"skala={0} lebar_harapan idle={1} expanded={2}" -f $scale, $IdleWidth, $ExpandedWidth
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

# Lebar pill = panjang run diff gelap yang memuat titik tengah layar (x=960). Syarat "gelap"
# penting: jendela lain di belakang pill bisa ikut berubah (video yang diputar) sehingga run
# diff merembet keluar pill dan lebar terbaca 550 px untuk pill 380 px.
function Measure-DiffWidth($baseline, $frame) {
    $center = 960 - $StripX
    $best = 0
    foreach ($row in 3, 5, 80, 84, 86) {
        $diff = New-Object 'bool[]' $StripW
        for ($x = 0; $x -lt $StripW; $x++) {
            $a = $baseline.GetPixel($x, $row)
            $b = $frame.GetPixel($x, $row)
            $d = [math]::Abs($a.R - $b.R) + [math]::Abs($a.G - $b.G) + [math]::Abs($a.B - $b.B)
            $gelap = ($b.R -lt 40 -and $b.G -lt 40 -and $b.B -lt 40)
            $diff[$x] = ($d -gt 24 -and $gelap)
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
