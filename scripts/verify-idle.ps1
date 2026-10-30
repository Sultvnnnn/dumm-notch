# Sampler CPU idle dengan pemisahan bucket: input-free vs ada input.
#
# Latar belakang: TotalProcessorTime di Windows bertambah per kuantum 15,6 ms, dan proses
# overlay ikut bangun saat ada event mouse di area window. Karena itu CPU hanya sah disebut
# "idle 0%" pada bucket yang benar-benar tanpa input. Skrip ini memisahkan keduanya memakai
# GetLastInputInfo sebelum dan sesudah tiap bucket 0,5 detik.
#
# Pakai: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-idle.ps1
# Kriteria lulus DoD 1.8: cpu_input_free_ms == 0 pada semua run.
param(
    [string]$Exe = "D:\codingan\dumm-notch\target\release\dum-notch.exe",
    [int]$Runs = 3,
    [int]$Buckets = 60,
    [int]$IdleThresholdSec = 2
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
public class DummInputProbe {
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
}
"@

if (-not (Test-Path $Exe)) { Write-Output "EXE_TIDAK_ADA: $Exe"; exit 2 }

function IdleSeconds {
    $lii = New-Object LASTINPUTINFO
    $lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
    [DummInputProbe]::GetLastInputInfo([ref]$lii) | Out-Null
    $now = [double][DummInputProbe]::GetTickCount64()
    return (($now - [double]$lii.dwTime) / 1000.0)
}

$semuaLulus = $true
for ($r = 1; $r -le $Runs; $r++) {
    # Parkir kursor jauh dari window 420x160 (window: x 750..1170, y 0..160).
    [DummInputProbe]::SetCursorPos(5, 1000) | Out-Null
    Start-Sleep -Milliseconds 600

    $p = Start-Process -FilePath $Exe -PassThru
    Start-Sleep -Seconds 4

    $prev = $p.TotalProcessorTime.TotalMilliseconds
    $freeMs = 0.0; $freeN = 0
    $inputMs = 0.0; $inputN = 0
    $inputRows = @()

    for ($i = 0; $i -lt $Buckets; $i++) {
        $idleA = IdleSeconds
        Start-Sleep -Milliseconds 500
        $p.Refresh()
        $now = $p.TotalProcessorTime.TotalMilliseconds
        $d = $now - $prev
        $idleB = IdleSeconds
        $prev = $now

        if ($idleA -ge $IdleThresholdSec -and $idleB -ge ($IdleThresholdSec + 0.5)) {
            $freeN++; $freeMs += $d
        } else {
            $inputN++; $inputMs += $d
            if ($d -gt 0) { $inputRows += ("t={0:N1}s d={1:N0}ms" -f ($i * 0.5), $d) }
        }
    }

    $p.Refresh()
    $verdict = if ($freeMs -eq 0) { "LULUS" } else { $semuaLulus = $false; "GAGAL" }
    "RUN {0}: {1}" -f $r, $verdict
    "  bucket_tanpa_input={0} cpu_ms_tanpa_input={1:N0}" -f $freeN, $freeMs
    "  bucket_ada_input={0}  cpu_ms_ada_input={1:N0}" -f $inputN, $inputMs
    if ($inputRows.Count -gt 0) { "  tick_saat_ada_input: " + ($inputRows -join " ; ") }
    "  private_mb={0} workingset_mb={1} threads={2}" -f `
        [math]::Round($p.PrivateMemorySize64 / 1MB, 2), [math]::Round($p.WorkingSet64 / 1MB, 2), $p.Threads.Count
    $p.Kill()
    Start-Sleep -Milliseconds 400
}

if ($semuaLulus) { "HASIL: LULUS semua run (0 ms CPU pada bucket tanpa input)" } else { "HASIL: GAGAL" }
