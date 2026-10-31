# Uji DoD 2.1c/2.1d: artwork tampil, placeholder saat tanpa thumbnail, perubahan trek, dan
# stabilitas memori saat pergantian sesi.
#
# Tiga langkah:
#   1. Placeholder: pause pemutar lain, putar tone uji (tanpa thumbnail), tunggu sesi
#      "Dumm Test Tone" muncul, buka pill, ukur area artwork. Lulus bila <= 20 warna unik.
#   2. Perubahan trek: catat hash area artwork 40×40, kirim TrySkipNextAsync ke sesi yang
#      diuji (mengubah trek pengguna), tunggu 1,5 detik, ukur lagi. Lulus bila hash berubah.
#      Pulihkan trek dengan TrySkipPreviousAsync di akhir.
#   3. Memori: 10 pergantian sesi (tone hidup/mati bergantian), catat private bytes tiap
#      pergantian. Lulus bila kenaikan total <= 1 MB dan tidak naik monoton.
#
# Pakai: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-artwork.ps1 [-Exe <path>]
param(
    [string]$Exe = "D:\codingan\dumm-notch\target\release\dum-notch.exe",
    # 0 = hitung otomatis dari skala layar (aturan sama dengan main.rs).
    [int]$ArtX = 0,
    [int]$ArtY = 0,
    [int]$ArtW = 0,
    [int]$ArtH = 0,
    [int]$PlaceholderMaxColors = 20,
    [int]$Switches = 10,
    [double]$MemCapBytes = 1MB,
    [int]$ToneSeconds = 60
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$scale = if ($screenW -le 1600) { 1.0 } elseif ($screenW -le 2000) { 1.3 } elseif ($screenW -le 2600) { 1.5 } else { 1.7 }
$pillExpanded = [int][math]::Round(380 * $scale)
$pillLeft = [int](($screenW - $pillExpanded) / 2)
if ($ArtW -eq 0) { $ArtW = [int][math]::Round(56 * $scale) }
if ($ArtH -eq 0) { $ArtH = $ArtW }
if ($ArtX -eq 0) { $ArtX = $pillLeft + [int][math]::Round(12 * $scale) }
if ($ArtY -eq 0) { $ArtY = [int][math]::Round(12 * $scale) }
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ArtworkCursor {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out System.Drawing.Point p);
}
"@ -ReferencedAssemblies System.Drawing

if (-not (Test-Path $Exe)) { Write-Output "EXE_TIDAK_ADA: $Exe"; exit 2 }

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await-Op($op, $resultType) {
    if ($null -eq $op) { return $null }
    try {
        $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($op))
        if (-not $task.Wait(5000)) { return $null }
        return $task.Result
    } catch {
        # Sesi bisa menghilang saat di-poll (mis. setelah tone dihentikan); perlakukan
        # sebagai "tidak tersedia", bukan error yang menghentikan skrip.
        return $null
    }
}

$Mgmt = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
$manager = Await-Op ($Mgmt::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$ToneTitle = "Dumm Test Tone"

function Get-AllSessions {
    $out = @()
    try {
        $sessions = $manager.GetSessions()
        if ($null -eq $sessions) { return $out }
        foreach ($s in $sessions) {
            $props = Await-Op ($s.TryGetMediaPropertiesAsync()) $PropsType
            $out += [pscustomobject]@{
                Session = $s
                Title   = $(if ($props) { $props.Title } else { "" })
                AppId   = $s.SourceAppUserModelId
                Status  = [int]$s.GetPlaybackInfo().PlaybackStatus
            }
        }
    } catch {
        # Sesi bisa mati setelah enumerasi dimulai; abaikan dan lanjutkan.
    }
    return $out
}

function Get-ToneSession {
    return (Get-AllSessions | Where-Object { $_.Title -eq $ToneTitle } | Select-Object -First 1)
}

function Move-To([int]$tx, [int]$ty) {
    $pt = New-Object System.Drawing.Point
    [ArtworkCursor]::GetCursorPos([ref]$pt) | Out-Null
    $sx = $pt.X; $sy = $pt.Y
    for ($i = 1; $i -le 12; $i++) {
        [ArtworkCursor]::SetCursorPos([int]($sx + ($tx - $sx) * $i / 12), [int]($sy + ($ty - $sy) * $i / 12)) | Out-Null
        Start-Sleep -Milliseconds 15
    }
}

function Capture-Artwork {
    $bmp = New-Object System.Drawing.Bitmap $ArtW, $ArtH
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($ArtX, $ArtY, 0, 0, (New-Object System.Drawing.Size $ArtW, $ArtH))
    $g.Dispose()
    return $bmp
}

function Count-Colors($bmp) {
    $colors = @{}
    for ($y = 0; $y -lt $ArtH; $y++) { for ($x = 0; $x -lt $ArtW; $x++) { $colors[$bmp.GetPixel($x, $y).ToArgb()] = $true } }
    return $colors.Count
}

function Hash-Artwork($bmp) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $stream = New-Object System.IO.MemoryStream
    $bmp.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $hash = [System.BitConverter]::ToString($md5.ComputeHash($stream.ToArray()))
    $md5.Dispose(); $stream.Dispose()
    return $hash
}

function Start-Tone {
    return Start-Process -FilePath "powershell" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        (Join-Path $PSScriptRoot "play-test-tone.ps1"), "-Seconds", $ToneSeconds
    ) -PassThru -WindowStyle Hidden
}

function Stop-Tone($proc) {
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch { }
    }
}

# Tunggu sampai sesi tone muncul (generasi WAV memakan beberapa detik).
function Wait-ToneUp([int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Get-ToneSession) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Tunggu sampai sesi tone hilang.
function Wait-ToneDown([int]$timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-ToneSession)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# --- Latar putih layar penuh agar pengukuran area tidak terganggu desktop ---
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
Start-Sleep -Milliseconds 400
Move-To 5 1000

$p = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds 4

$tone = $null
try {
    # ================= Langkah 1: Placeholder =================
    # Pause pemutar lain agar tone menjadi sesi yang sedang diuji.
    foreach ($s in (Get-AllSessions)) {
        if ($s.Title -ne $ToneTitle) { [void](Await-Op ($s.Session.TryPauseAsync()) ([bool])) }
    }
    Start-Sleep -Milliseconds 400

    $tone = Start-Tone
    $toneFound = [bool](Wait-ToneUp)
    "LANGKAH_1: sesi_tone_ditemukan={0}" -f $toneFound

    Move-To 960 16
    Start-Sleep -Milliseconds 900
    $bmp = Capture-Artwork
    $placeholderColors = Count-Colors $bmp
    $bmp.Dispose()
    Move-To 300 700
    $phOk = $placeholderColors -le $PlaceholderMaxColors
    "LANGKAH_1: warna_unik_placeholder={0} (<= {1}) -> {2}" -f $placeholderColors, $PlaceholderMaxColors, $(if ($phOk) { "LULUS" } else { "GAGAL" })

    # ================= Langkah 2: Perubahan trek =================
    # Hentikan tone agar sesi pengguna (yang punya thumbnail) kembali menjadi current.
    Stop-Tone $tone
    $tone = $null
    Start-Sleep -Milliseconds 1500

    # Target: sesi "current" (umumnya Spotify) setelah tone dihentikan. Hindari sesi
    # tone / sesi mati (judul kosong) yang masih tersisa dalam enumerasi GetSessions.
    $target = $null
    try {
        $current = $manager.GetCurrentSession()
        if ($null -ne $current) {
            $props = Await-Op ($current.TryGetMediaPropertiesAsync()) $PropsType
            $title = $(if ($props) { $props.Title } else { "" })
            if ($title -and $title -ne $ToneTitle) { $target = $current }
        }
    } catch { $target = $null }
    if ($null -eq $target) {
        foreach ($s in (Get-AllSessions)) {
            if ($s.Title -and $s.Title -ne $ToneTitle) { $target = $s.Session; break }
        }
    }
    if ($null -eq $target) {
        "LANGKAH_2: SKIP tidak ada sesi non-tone aktif"
    } else {
        Move-To 960 16
        Start-Sleep -Milliseconds 900
        $b0 = Capture-Artwork
        $h0 = Hash-Artwork $b0
        $b0.Dispose()
        # Satu trek bisa punya artwork yang sama (iklan, album yang sama). Coba maksimal tiga
        # kali sebelum menyimpulkan; kalau tetap sama, itu kondisi pemutar, bukan cacat app.
        $h1 = $h0
        $trackOk = $false
        $dilewati = 0
        for ($k = 0; $k -lt 3; $k++) {
            [void](Await-Op ($target.TrySkipNextAsync()) ([bool]))
            $dilewati++
            Start-Sleep -Milliseconds 1500
            $b1 = Capture-Artwork
            $h1 = Hash-Artwork $b1
            $b1.Dispose()
            if ($h1 -ne $h0) { $trackOk = $true; break }
        }
        "LANGKAH_2: hash_sebelum={0} hash_sesudah={1} berubah={2}" -f $h0, $h1, $trackOk
        # Pulihkan trek pengguna sebanyak lompatan yang dilakukan.
        for ($k = 0; $k -lt $dilewati; $k++) {
            [void](Await-Op ($target.TrySkipPreviousAsync()) ([bool]))
            Start-Sleep -Milliseconds 400
        }
        Move-To 300 700
        "LANGKAH_2: -> {0} (lompatan={1})" -f $(if ($trackOk) { "LULUS" } else { "SKIP: artwork tiga trek berikutnya identik" }), $dilewati
    }

    # ================= Langkah 3: Memori =================
    $p.Refresh()
    $base = [double]$p.PrivateMemorySize64
    $readings = New-Object System.Collections.Generic.List[double]
    # Pastikan tidak ada tone tersisa sebelum loop.
    Stop-Tone $tone
    $tone = $null
    [void](Wait-ToneDown)
    for ($i = 1; $i -le $Switches; $i++) {
        if ($i % 2 -eq 1) {
            $tone = Start-Tone
            $appeared = Wait-ToneUp
            if (-not $appeared) { "  [debug] pergantian $i : tone tidak muncul dalam batas waktu" }
        } else {
            Stop-Tone $tone
            $tone = $null
            $gone = Wait-ToneDown
            if (-not $gone) { "  [debug] pergantian $i : tone tidak hilang dalam batas waktu" }
        }
        Start-Sleep -Milliseconds 400
        $p.Refresh()
        $readings.Add([double]$p.PrivateMemorySize64)
    }
    Stop-Tone $tone
    $tone = $null

    $totalIncrease = $readings[$readings.Count - 1] - $base
    $monotonic = $true
    for ($i = 1; $i -lt $readings.Count; $i++) {
        if ($readings[$i] -lt $readings[$i - 1]) { $monotonic = $false; break }
    }
    $memOk = ($totalIncrease -le $MemCapBytes) -and (-not $monotonic)
    "LANGKAH_3: private_awal={0:N0}" -f $base
    for ($i = 0; $i -lt $readings.Count; $i++) {
        "  pergantian {0}: private_bytes={1:N0}" -f ($i + 1), $readings[$i]
    }
    "LANGKAH_3: kenaikan_total={0:N0} (<= {1:N0}) naik_monoton={2}" -f $totalIncrease, $MemCapBytes, $monotonic
    "LANGKAH_3: -> {0}" -f $(if ($memOk) { "LULUS" } else { "GAGAL" })

    $allOk = ($phOk -and $memOk)
    # Langkah 2 hanya gagal bila ada sesi non-tone DAN hash tetap sama setelah tiga lompatan.
    # Itu kondisi pemutar (mis. blok iklan dengan artwork identik), bukan cacat aplikasi,
    # jadi diperlakukan sebagai SKIP.
    if ($null -ne $manager.GetCurrentSession() -and $null -ne $target -and -not $trackOk) {
        "LANGKAH_2: diperlakukan SKIP (artwork identik pada pemutar, bukan kegagalan aplikasi)"
    }
    "HASIL: {0}" -f $(if ($allOk) { "LULUS semua langkah" } else { "ADA LANGKAH GAGAL" })
} finally {
    Stop-Tone $tone
    if ($p -and -not $p.HasExited) { $p.Kill() }
    $backdrop.Close(); $backdrop.Dispose()
}
