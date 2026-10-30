# Uji transport otomatis: 10 klik play/pause pada sesi media aktif.
#
# Pelajaran yang sudah dibayar mahal dan dikodekan di sini:
#   1. `mouse_event` TIDAK sampai ke window overlay yang tidak pernah aktif. Klik dikirim
#      sebagai WM_LBUTTONDOWN/UP lewat PostMessage ke HWND `DummNotchOverlay`.
#   2. TouchArea bersarang di dalam layout tidak menerima hit-test; yang menangkap klik
#      adalah satu TouchArea milik pill. Koordinat tombol karenanya tetap:
#      previous = 182, play-pause = 210, next = 238 (klien), baris y = 60.
#   3. Identitas sesi diperiksa sebelum setiap klik. Insiden "Earth Song" tidak boleh terulang.
#   4. Lebar pill diukur dari piksel (baseline-diff), bukan dari state.
#
# Pakai: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-transport.ps1
param(
    [string]$Exe = "D:\codingan\dumm-notch\target\release\dum-notch.exe",
    [int]$Cycles = 10,
    [string]$ExpectedTitle = "Dumm Test Tone",
    [int]$ToneSeconds = 120,
    [int]$PrevX = 182,
    [int]$PlayX = 210,
    [int]$NextX = 238,
    [int]$RowY = 60,
    [int]$StripX = 600,
    [int]$StripW = 720,
    [int]$ScanRow = 8
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TransportCtl {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(IntPtr cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out System.Drawing.Point p);
}
"@ -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await-Op($op, $resultType) {
    if ($null -eq $op) { return $null }
    $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($op))
    if (-not $task.Wait(5000)) { return $null }
    return $task.Result
}

$Mgmt = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
$manager = Await-Op ($Mgmt::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]

function Get-CurrentMedia {
    $s = $manager.GetCurrentSession()
    if (-not $s) { return $null }
    $props = Await-Op ($s.TryGetMediaPropertiesAsync()) $PropsType
    return [pscustomobject]@{
        Title  = $(if ($props) { $props.Title } else { "" })
        Status = [int]$s.GetPlaybackInfo().PlaybackStatus
    }
}

function Move-To([int]$tx, [int]$ty) {
    $pt = New-Object System.Drawing.Point
    [TransportCtl]::GetCursorPos([ref]$pt) | Out-Null
    $sx = $pt.X; $sy = $pt.Y
    for ($i = 1; $i -le 12; $i++) {
        [TransportCtl]::SetCursorPos([int]($sx + ($tx - $sx) * $i / 12), [int]($sy + ($ty - $sy) * $i / 12)) | Out-Null
        Start-Sleep -Milliseconds 15
    }
}

function Capture-Strip {
    $bmp = New-Object System.Drawing.Bitmap $StripW, 110
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($StripX, 0, 0, 0, (New-Object System.Drawing.Size $StripW, 110))
    $g.Dispose()
    return $bmp
}

function Measure-DiffWidth($baseline, $frame) {
    $min = -1; $max = -1
    for ($x = 0; $x -lt $StripW; $x++) {
        $a = $baseline.GetPixel($x, $ScanRow)
        $b = $frame.GetPixel($x, $ScanRow)
        $d = [math]::Abs($a.R - $b.R) + [math]::Abs($a.G - $b.G) + [math]::Abs($a.B - $b.B)
        if ($d -gt 24) { if ($min -lt 0) { $min = $x }; $max = $x }
    }
    if ($min -lt 0) { return 0 }
    return ($max - $min + 1)
}

function Click-Client([IntPtr]$hwnd, [int]$cx, [int]$cy) {
    $lp = [IntPtr]($cx -bor ($cy -shl 16))
    [TransportCtl]::PostMessageW($hwnd, 0x0200, [IntPtr]0, $lp) | Out-Null
    Start-Sleep -Milliseconds 40
    [TransportCtl]::PostMessageW($hwnd, 0x0201, [IntPtr]1, $lp) | Out-Null
    Start-Sleep -Milliseconds 40
    [TransportCtl]::PostMessageW($hwnd, 0x0202, [IntPtr]0, $lp) | Out-Null
}

if (-not (Test-Path $Exe)) { "EXE_TIDAK_ADA: $Exe"; exit 2 }

Get-Process dum-notch -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 400
Move-To 5 1000
Start-Sleep -Milliseconds 400
$baseline = Capture-Strip

$tone = Start-Process -FilePath "powershell" -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
    (Join-Path $PSScriptRoot "play-test-tone.ps1"), "-Seconds", $ToneSeconds
) -PassThru -WindowStyle Hidden

$targetTitle = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $m = Get-CurrentMedia
    if ($m -and $m.Title -eq $ExpectedTitle) { $targetTitle = $ExpectedTitle; break }
}

if (-not $targetTitle) {
    $m = Get-CurrentMedia
    if (-not $m) {
        "SKIP: tidak ada sesi media aktif"
        if (-not $tone.HasExited) { $tone.Kill() }
        $baseline.Dispose(); exit 0
    }
    # Windows mempertahankan sesi lama sebagai "current" meski tone sedang berbunyi.
    $targetTitle = $m.Title
    "CATATAN: sesi tone bukan sesi aktif; target alternatif='{0}'" -f $m.Title
    if (-not $tone.HasExited) { $tone.Kill() }
    Start-Sleep -Milliseconds 400
}
"target_uji='{0}'" -f $targetTitle

$err = "$env:TEMP\dumm-transport.err"
if (Test-Path $err) { Remove-Item $err }
$p = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $err
Start-Sleep -Seconds 4
$hwnd = [TransportCtl]::FindWindowW([IntPtr]::Zero, "DummNotchOverlay")
if ($hwnd -eq [IntPtr]::Zero) {
    "GAGAL: window DummNotchOverlay tidak ditemukan"
    $p.Kill(); $baseline.Dispose(); exit 1
}

Move-To 960 16
Start-Sleep -Milliseconds 1200
$f = Capture-Strip
$wExpanded = Measure-DiffWidth $baseline $f
$f.Dispose()
"lebar_expanded={0}px (harapan 380)" -f $wExpanded

$statusAwal = (Get-CurrentMedia).Status
$lulus = 0
$skipIdentitas = 0
for ($i = 1; $i -le $Cycles; $i++) {
    $m = Get-CurrentMedia
    if (-not $m -or $m.Title -ne $targetTitle) {
        "iterasi {0}: SKIP, sesi aktif berubah ('{1}')" -f $i, $(if ($m) { $m.Title } else { "(tidak ada)" })
        $skipIdentitas++
        continue
    }

    $sebelum = $m.Status
    $t0 = [DateTime]::UtcNow
    Click-Client $hwnd $PlayX $RowY
    $sesudah = $sebelum
    $delta = $null
    for ($w = 0; $w -lt 80; $w++) {
        Start-Sleep -Milliseconds 25
        $m2 = Get-CurrentMedia
        if (-not $m2) { break }
        if ($m2.Status -ne $sebelum) {
            $sesudah = $m2.Status
            $delta = [int]([DateTime]::UtcNow - $t0).TotalMilliseconds
            break
        }
    }

    Move-To 960 16
    Start-Sleep -Milliseconds 150
    $f = Capture-Strip
    $wNow = Measure-DiffWidth $baseline $f
    $f.Dispose()

    $ok = ($null -ne $delta) -and ($delta -le 500) -and ($wNow -ge 372 -and $wNow -le 388)
    if ($ok) { $lulus++ }
    "iterasi {0}: sebelum={1} sesudah={2} berubah={3} delta_ms={4} lebar={5}px -> {6}" -f `
        $i, $sebelum, $sesudah, ($null -ne $delta), $(if ($null -ne $delta) { $delta } else { "-" }), $wNow, $(if ($ok) { "OK" } else { "GAGAL" })
}

# Uji next dan previous: tidak wajib mengubah status pada sesi satu trek, tapi tidak boleh
# membuat proses mati atau mengubah sesi aktif.
Click-Client $hwnd $NextX $RowY
Start-Sleep -Milliseconds 600
$mNext = Get-CurrentMedia
Click-Client $hwnd $PrevX $RowY
Start-Sleep -Milliseconds 600
$mPrev = Get-CurrentMedia
"uji_next: sesi='{0}' status={1} hidup={2}" -f $(if ($mNext) { $mNext.Title } else { "-" }), $(if ($mNext) { $mNext.Status } else { "-" }), (-not $p.HasExited)
"uji_previous: sesi='{0}' status={1} hidup={2}" -f $(if ($mPrev) { $mPrev.Title } else { "-" }), $(if ($mPrev) { $mPrev.Status } else { "-" }), (-not $p.HasExited)

$akhir = (Get-CurrentMedia).Status
"status_awal_uji={0} status_akhir={1} skip_identitas={2}" -f $statusAwal, $akhir, $skipIdentitas
if ($akhir -ne $statusAwal) {
    Click-Client $hwnd $PlayX $RowY
    Start-Sleep -Milliseconds 900
    "pemulihan: status_sekarang={0}" -f (Get-CurrentMedia).Status
}

Move-To 5 1000
Start-Sleep -Milliseconds 300
$hidup = -not $p.HasExited
$p.Kill()
if (-not $tone.HasExited) { $tone.Kill() }
$baseline.Dispose()
$errBytes = if (Test-Path $err) { (Get-Item $err).Length } else { -1 }
"proses_hidup_selama_uji={0} stderr_bytes={1}" -f $hidup, $errBytes
"HASIL: {0}/{1} iterasi lulus" -f $lulus, $Cycles
