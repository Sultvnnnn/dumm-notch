# Uji HUD volume: muncul saat volume berubah, hilang setelah 1500 ms, plus tiga pemeriksaan
# cacat V1/V2/V3:
#   1. Label persen terisi benar (bukan teks mentah `$(Math.roi...`).
#   2. Tidak ada kedip saat start (baseline volume tidak memunculkan HUD).
#   3. Bar tidak menyentuh tepi membulat pill (margin horizontal 12 px).
#
# Semua memakai latar putih layar penuh dan baseline-diff. Volume dipulihkan dengan satu
# VK_VOLUME_DOWN per VK_VOLUME_UP.
#
# Pakai: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-volume.ps1
param([string]$Exe = "D:\codingan\dumm-notch\target\release\dum-notch.exe")

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class VolCursor {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out System.Drawing.Point p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(IntPtr cls, string title);
}
public class VolKey {
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@ -ReferencedAssemblies System.Drawing

$VK_VOLUME_UP = 0xAF
$VK_VOLUME_DOWN = 0xAE
$KEYUP = 0x0002

# Geometri layar (1920x1080, window di tengah atas).
# Pill expanded: x 770, lebar 380, tinggi 90; bar HUD y 84..88 (V3: x 782..1138).
$BandX = 770; $BandY = 76; $BandW = 380; $BandH = 15
# Kotak label persen (x 1094..1144, y 72..86).
$LabelX = 1094; $LabelY = 72; $LabelW = 50; $LabelH = 14
# Tepi kiri/kanan pita bar untuk cek radius (6 px paling luar).
$EdgeW = 6; $EdgeY = 84; $EdgeH = 4

function Move-To([int]$tx, [int]$ty) {
    $pt = New-Object System.Drawing.Point
    [VolCursor]::GetCursorPos([ref]$pt) | Out-Null
    $sx = $pt.X; $sy = $pt.Y
    for ($s = 1; $s -le 12; $s++) {
        $nx = [int]($sx + ($tx - $sx) * $s / 12)
        $ny = [int]($sy + ($ty - $sy) * $s / 12)
        [VolCursor]::SetCursorPos($nx, $ny) | Out-Null
        Start-Sleep -Milliseconds 15
    }
}

function Send-VolKey([byte]$vk) {
    [VolKey]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 10
    [VolKey]::keybd_event($vk, 0, [uint32]$KEYUP, [UIntPtr]::Zero)
}

function Capture-Region([int]$x, [int]$y, [int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $g.Dispose()
    return $bmp
}

# Hitung piksel terang (R,G,B semua > 150) — teks label #f4f4f5 pada latar gelap.
# Ambang 150 (bukan 200) menangkap glyph anti-aliasing 10 px dengan andal (terukur 28-33).
function Count-Bright($bmp) {
    $count = 0
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if ($c.R -gt 150 -and $c.G -gt 150 -and $c.B -gt 150) { $count++ }
        }
    }
    return $count
}

# Hitung piksel berwarna bar terang #f4f4f5 (244,244,245) — cek tepi radius.
function Count-BarColor($bmp) {
    $count = 0
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if ([math]::Abs($c.R - 244) -le 8 -and [math]::Abs($c.G - 244) -le 8 -and [math]::Abs($c.B - 245) -le 8) { $count++ }
        }
    }
    return $count
}

# Jumlah piksel berbeda dari baseline (>24 per kanal RGB).
function Measure-DiffCount($baseline, $frame) {
    $count = 0
    for ($y = 0; $y -lt $baseline.Height; $y++) {
        for ($x = 0; $x -lt $baseline.Width; $x++) {
            $a = $baseline.GetPixel($x, $y)
            $b = $frame.GetPixel($x, $y)
            $d = [math]::Abs($a.R - $b.R) + [math]::Abs($a.G - $b.G) + [math]::Abs($a.B - $b.B)
            if ($d -gt 24) { $count++ }
        }
    }
    return $count
}

$backdrop = New-Object System.Windows.Forms.Form
$backdrop.FormBorderStyle = 'None'
$backdrop.WindowState = 'Maximized'
$backdrop.BackColor = [System.Drawing.Color]::White
$backdrop.ShowInTaskbar = $false
$backdrop.TopMost = $false
$backdrop.Show()
$backdrop.SendToBack()
Start-Sleep -Milliseconds 500

Get-Process dum-notch -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 500

$app = Start-Process -FilePath $Exe -PassThru

# ===== Cek 2: tidak ada kedip saat start =====
# Tunggu window muncul, lalu tanpa hover/volume, tangkap pita bawah pill collapsed pada t=1,0 s.
# Pill collapsed: x 870, lebar 180, tinggi 32 -> bar HUD (bila rusak) di y 26..30.
# Pakai pita tengah (x 895..1025) untuk menghindari latar putih di sudut membulat.
$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) {
    $hwnd = [VolCursor]::FindWindowW([IntPtr]::Zero, "DummNotchOverlay")
    if ($hwnd -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 100
}
Start-Sleep -Milliseconds 1000   # t=1,0 s setelah window tampil
$blinkBmp = Capture-Region 895 24 130 8
$blinkBright = Count-Bright $blinkBmp
$blinkBmp.Dispose()
$noBlink = ($blinkBright -lt 20)
"Cek2_blink: piksel_terang=$blinkBright (<20) -> $(if ($noBlink) { 'LULUS' } else { 'GAGAL' })"

# Expand pill lewat hover, tunggu animasi (250 ms) selesai.
Move-To 960 16
Start-Sleep -Milliseconds 900

$baseline = Capture-Region $BandX $BandY $BandW $BandH

$lulus = 0
$labelOk = $true
$edgeOk = $true
for ($i = 1; $i -le 5; $i++) {
    Send-VolKey $VK_VOLUME_UP
    Start-Sleep -Milliseconds 300
    $f1 = Capture-Region $BandX $BandY $BandW $BandH
    $d1 = Measure-DiffCount $baseline $f1
    $f1.Dispose()
    $muncul = ($d1 -gt 200)

    # ===== Cek 1: label persen terisi =====
    $labelBmp = Capture-Region $LabelX $LabelY $LabelW $LabelH
    $labelBright = Count-Bright $labelBmp
    $labelBmp.Dispose()
    $labelOk = $labelOk -and ($labelBright -ge 8 -and $labelBright -le 45)

    # ===== Cek 3: tepi bar tidak menyentuh radius =====
    # Periksa warna bar terang #f4f4f5 spesifik (bukan kecerahan umum — sudut membulat
    # memperlihatkan latar putih di belakang pill). Margin V3 = 12 px, jadi tepi 6 px
    # paling luar tidak boleh memuat bar.
    $leftEdge = Capture-Region $BandX $EdgeY $EdgeW $EdgeH
    $rightEdge = Capture-Region ($BandX + $BandW - $EdgeW) $EdgeY $EdgeW $EdgeH
    $leftBright = Count-BarColor $leftEdge
    $rightBright = Count-BarColor $rightEdge
    $leftEdge.Dispose(); $rightEdge.Dispose()
    $edgeThis = ($leftBright -eq 0 -and $rightBright -eq 0)
    $edgeOk = $edgeOk -and $edgeThis

    $privateBytes = $app.PrivateMemorySize64

    Start-Sleep -Milliseconds 1900   # total 2200 ms sejak tombol
    $f2 = Capture-Region $BandX $BandY $BandW $BandH
    $d2 = Measure-DiffCount $baseline $f2
    $f2.Dispose()
    $hilang = ($d2 -le 50)

    if ($muncul -and $hilang) { $lulus++ }
    "iterasi $i`: muncul=$muncul hilang=$hilang diff300=$d1 diff2200=$d2 label_bright=$labelBright tepi_kiri=$leftBright tepi_kanan=$rightBright private=$privateBytes"
}

# Pulihkan volume kira-kira: satu kali turun.
Send-VolKey $VK_VOLUME_DOWN

Move-To 5 1000
Start-Sleep -Milliseconds 300
$app.Kill()
$backdrop.Close(); $backdrop.Dispose()
$baseline.Dispose()

"Cek1_label: $(if ($labelOk) { 'LULUS' } else { 'GAGAL' }) (butuh 8-45 piksel terang)"
"Cek3_tepi: $(if ($edgeOk) { 'LULUS' } else { 'GAGAL' }) (tepi kiri/kanan tak boleh terang)"
"HASIL: $lulus/5 iterasi muncul-hilang | label=$labelOk noblink=$noBlink tepi=$edgeOk"
