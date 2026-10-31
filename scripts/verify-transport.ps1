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
    # Bila diisi, identitas target memakai SourceAppUserModelId (lebih stabil daripada judul
    # karena trek bisa berganti). Contoh: -TargetApp Spotify.exe
    [string]$TargetApp = "",
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

# Skala antarmuka, aturan sama dengan main.rs.
$screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$scale = if ($screenW -le 1600) { 1.0 } elseif ($screenW -le 2000) { 1.3 } elseif ($screenW -le 2600) { 1.5 } else { 1.7 }
$expandedExpect = [int][math]::Round(380 * $scale)
$expandedTol = [int][math]::Round(10 * $scale)
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
        AppId  = $s.SourceAppUserModelId
        Status = [int]$s.GetPlaybackInfo().PlaybackStatus
    }
}

function Test-Target($m) {
    if (-not $m) { return $false }
    if ($TargetApp -ne "") { return ($m.AppId -like "*$TargetApp*") }
    return ($m.Title -eq $targetTitle)
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
    # Tinggi pita harus menutup kartu yang membesar (122 px * skala) sampai baris tombol.
    $bmp = New-Object System.Drawing.Bitmap $StripW, 200
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
        # Batas kiri/kanan = kartu terlebar yang mungkin; noise dari jendela lain di belakang
        # tidak boleh memperpanjang run.
        $limitL = [math]::Max(0, $center - $expandedExpect / 2 - 12)
        $limitR = [math]::Min($StripW - 1, $center + $expandedExpect / 2 + 12)
        $l = $center; $r = $center
        while ($l -gt $limitL -and $diff[$l - 1]) { $l-- }
        while ($r -lt $limitR -and $diff[$r + 1]) { $r++ }
        $w = $r - $l + 1
        if ($w -gt $best) { $best = $w }
    }
    return $best
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

# Latar putih terkontrol: kalau warna desktop kebetulan sama dengan pill (#09090b), tepi pill
# tidak bisa diukur dari diff dan lebar terbaca salah (pernah 306 px untuk pill 380 px).
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
    if ($TargetApp -ne "") {
        if (Test-Target $m) { $targetTitle = if ($m.Title) { $m.Title } else { $TargetApp }; break }
    } elseif ($m -and $m.Title -eq $ExpectedTitle) { $targetTitle = $ExpectedTitle; break }
}

if (-not $targetTitle) {
    $m = Get-CurrentMedia
    if (-not $m) {
        "SKIP: tidak ada sesi media aktif"
        if (-not $tone.HasExited) { $tone.Kill() }
        $backdrop.Close(); $backdrop.Dispose()
        $baseline.Dispose(); exit 0
    }
    # Windows mempertahankan sesi lama sebagai "current" meski tone sedang berbunyi.
    $targetTitle = $m.Title
    "CATATAN: sesi tone bukan sesi aktif; target alternatif='{0}' app='{1}'" -f $m.Title, $m.AppId
    if (-not $tone.HasExited) { $tone.Kill() }
    Start-Sleep -Milliseconds 400
}
"target_uji='{0}' mode='{1}'" -f $targetTitle, $(if ($TargetApp -ne "") { "app:$TargetApp" } else { "judul" })

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
"lebar_expanded={0}px (harapan {1}, skala {2})" -f $wExpanded, $expandedExpect, $scale

# Deteksi posisi tombol dari tangkapan yang sama (kartu sedang terbuka).
# Koordinat tombol dari rumus geometri kartu (sumber sama dengan ui/notch.slint):
# tombol 34 px, spacing 20 px, konten padding 12 px, artwork 56 px.
# Pusat kartu = lebar window / 2; jarak antar-pusat = 54 px * skala; baris tombol = 91 px * skala.
$winW = 420 * $scale
$cardCenter = [int]($winW / 2)
$off = [int](54 * $scale)
$PrevX = $cardCenter - $off
$PlayX = $cardCenter
$NextX = $cardCenter + $off
$RowY = [int](91 * $scale)
"koordinat_tombol: prev={0} play={1} next={2} y={3} (skala {4})" -f $PrevX, $PlayX, $NextX, $RowY, $scale

$statusAwal = (Get-CurrentMedia).Status
$lulus = 0
$skipIdentitas = 0
for ($i = 1; $i -le $Cycles; $i++) {
    $m = Get-CurrentMedia
    if (-not (Test-Target $m)) {
        "iterasi {0}: SKIP, target berubah ('{1}')" -f $i, $(if ($m) { $m.Title } else { "(tidak ada)" })
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

    $ok = ($null -ne $delta) -and ($delta -le 700) -and ($wNow -ge ($expandedExpect - $expandedTol) -and $wNow -le ($expandedExpect + $expandedTol))
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

# Uji zona klik "di mana saja": sepertiga kiri = previous, sepertiga kanan = next.
# Klik dilakukan di koordinat klien, bukan di ikon, untuk membuktikan zona bukan cuma ikon.
$judulSebelum = (Get-CurrentMedia).Title
Click-Client $hwnd ([int](420 * $scale * 0.20)) ([int](50 * $scale))
Start-Sleep -Milliseconds 900
$judulKanan = (Get-CurrentMedia).Title
Click-Client $hwnd ([int](420 * $scale * 0.80)) ([int](50 * $scale))
Start-Sleep -Milliseconds 900
$judulKiri = (Get-CurrentMedia).Title
"zona_klik: awal='{0}' setelah_klik_kanan='{1}' setelah_klik_kiri='{2}'" -f $judulSebelum, $judulKanan, $judulKiri

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
$backdrop.Close()
$backdrop.Dispose()
$errBytes = if (Test-Path $err) { (Get-Item $err).Length } else { -1 }
"proses_hidup_selama_uji={0} stderr_bytes={1}" -f $hidup, $errBytes
"HASIL: {0}/{1} iterasi lulus" -f $lulus, $Cycles
