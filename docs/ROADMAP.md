# ROADMAP DUMM

Status per dokumen ini: **Phase 1 dalam proses** (build lulus, atribut window terpasang;
animasi dan pemisahan modul belum selesai).

Aturan umum tiap fase:

- Tidak menambah dependency baru tanpa persetujuan arsitek.
- Tidak ada polling. Fitur yang menuntut polling ditunda, bukan dipaksa.
- Setiap fase ditutup dengan bukti: output `cargo build --release`, `cargo clippy`, dan
  tangkapan layar atau angka pengukuran. Klaim tanpa bukti dianggap belum selesai.

---

## Phase 1 — Native Window Shell

**Tujuan:** pill notched muncul melayang di tengah atas layar, transparan, tanpa frame,
tidak ada di taskbar/Alt-Tab, dan proses idle benar-benar diam.

### Scope

1. `Cargo.toml`: `slint` dengan `default-features = false` + `renderer-software`; feature
   `windows` minimal (`Win32_Foundation`, `Win32_UI_WindowsAndMessaging`); profil release
   size-oriented.
2. `src/main.rs`: bootstrap, `with_skip_taskbar`, pemasangan atribut sekali jalan lewat event
   winit pertama, `FindWindowW` sebagai `Result`.
3. `ui/notch.slint`: pill 180×32 idle, expand 380×90, radius bawah 18 px, animasi 250 ms.
4. Pemecahan `src/main.rs` menjadi `src/window/{mod,attach,style,position}.rs` sesuai §4
   ARCHITECTURE.md.
5. Hover keluar menutup pill kembali (sekarang hanya membuka).

### Definition of Done (terukur)

| # | Kriteria | Cara verifikasi | Ambang |
| --- | --- | --- | --- |
| 1.1 | Build bersih | `cargo build --release` | exit 0, 0 warning baru |
| 1.2 | Lint bersih | `cargo clippy -- -D warnings` | exit 0 |
| 1.3 | Tanpa `unwrap`/`expect` di jalur FFI | `rg -n "unwrap\(|expect\(" src/` | 0 hasil di `src/window/` |
| 1.4 | Muncul di tengah atas | `GetWindowRect` dicetak saat startup | `x + width/2 == 960 ± 2` pada layar 1920; `y == 0` |
| 1.5 | Tidak di taskbar & Alt-Tab | `GetWindowLongPtrW(GWL_EXSTYLE)` | bit `WS_EX_TOOLWINDOW` = 1, bit `WS_EX_APPWINDOW` = 0 |
| 1.6 | Selalu di atas | exstyle | bit `WS_EX_TOPMOST` = 1 |
| 1.7 | Transparan, tanpa artefak | tangkapan layar area 420×160 | tidak ada border/glyph; piksel luar pill = warna desktop |
| 1.8 | Idle CPU 0 ms tanpa input | `powershell -File scripts\verify-idle.ps1` | `cpu_ms_tanpa_input == 0` di semua run (3 run × 30 detik). Tick saat ada input tidak dihitung, karena overlay memang bereaksi terhadap event mouse. |
| 1.9 | Memori idle | `PrivateUsage` via `GetProcessMemoryInfo` | ≤ 15 MB private (informasi tambahan: working set ≤ 20 MB) |
| 1.10 | Hover membuka, keluar menutup | `powershell -File scripts\verify-hover.ps1` (kursor digeser bertahap, lebar pill diukur dari piksel) | 10/10 siklus: idle 180 px, expanded 380 px |
| 1.11 | Tidak ada `target/` ter-commit | `git status --short` | hanya file sumber + docs |

---

## Phase 2 — GSMTC Media & Volume HUD

**Tujuan:** notch menampilkan judul/artis/artwork dan mengendalikan play-pause/next/prev
tanpa polling, plus HUD volume saat berubah.

**Status:** potongan pertama selesai — metadata read-only (judul, artis, pergantian sesi) lewat
`src/services/media.rs`, terverifikasi pada 2.1 dan 2.8. Potongan kedua selesai — kontrol
transport prev / play-pause / next, terverifikasi pada 2.2, 2.3, dan 2.7. Artwork dan volume
belum dikerjakan.

### Scope

1. `src/services/media.rs`: `GlobalSystemMediaTransportControlsSessionManager` di thread
   service; langganan `CurrentSessionChanged`, `MediaPropertiesChanged`,
   `TimelinePropertiesChanged`, `PlaybackInfoChanged`.
2. Kontrol transport: `TryPlayAsync`, `TryPauseAsync`, `TrySkipNextAsync`,
   `TrySkipPreviousAsync` lewat `ServiceCommand`.
3. `src/services/volume.rs`: `IAudioEndpointVolume` + `RegisterControlChangeNotify` untuk HUD.
4. `ui/notch.slint`: kartu media (artwork 40×40, teks 1 baris dengan ellipsis) dan bar HUD.
5. Feature `windows` bertambah sesuai kebutuhan (`Win32_Media_Audio`, `Media_*`).

### Definition of Done

| # | Kriteria | Ambang |
| --- | --- | --- |
| 2.1 | Memutar lagu di Spotify/browser memunculkan judul di pill | ≤ 500 ms setelah perubahan terdeteksi |
| 2.2 | Pause dari aplikasi lain tercermin di notch | ≤ 500 ms, tanpa polling |
| 2.3 | Tombol play/pause di notch mengubah state pemutar asli | 10/10 percobaan |
| 2.4 | Ganti sesi media (Spotify → browser) | judul ikut berganti tanpa restart |
| 2.5 | Tidak ada timer periodik saat idle | grep `Timer::start` di `src/services/` = 0, atau hanya timer yang dijeda |
| 2.6 | Memori idle setelah media aktif | private ≤ 15 MB |
| 2.7 | CPU saat musik berjalan tapi UI tertutup | ≤ 0,2% rata-rata |
| 2.8 | Media session hilang (pemutar ditutup) | notch kembali ke pill idle, tidak panic |

---

## Phase 3 — Productivity Shelf & Focus Timer

**Tujuan:** notch berubah menjadi shelf ringkas (clipboard, baterai, jam, cuaca opsional)
dan Pomodoro dengan timer yang hanya hidup selama sesi.

### Scope

1. `src/services/system_hud.rs`: baterai via `PowerSettingRegisterNotification`, jam hanya
   saat shelf terbuka, clipboard-history terbatas (≤ 10 entri, in-memory).
2. `src/timer/focus.rs`: sesi 25/5 menit, start/stop/pause lewat `ServiceCommand`,
   notifikasi saat sesi selesai.
3. `ui/components/shelf.slint`: layout shelf, tanpa mengubah `ui/notch.slint` sebagai root.
4. Persistensi ringan (opsional): file JSON di `%LOCALAPPDATA%/Dumm/` untuk pengaturan.

### Definition of Done

| # | Kriteria | Ambang |
| --- | --- | --- |
| 3.1 | Timer tidak berjalan saat tidak dipakai | `Timer::stop` terverifikasi lewat log start/stop |
| 3.2 | Drift timer | ≤ 1 detik per 25 menit |
| 3.3 | Baterai berubah | HUD ter-update ≤ 1 detik, tanpa polling |
| 3.4 | Clipboard shelf | ≤ 10 entri, tidak menulis ke disk |
| 3.5 | Memori idle setelah semua fitur aktif | private ≤ 18 MB |
| 3.6 | Cold start | ≤ 300 ms sampai pill tampil |
| 3.7 | Crash-free | 1 jam pemakaian tanpa panic; `panic = "abort"` berarti tidak ada unwind diam-diam |

---

## Urutan Kerja yang Disarankan

1. **Phase 1 selesai dulu sampai DoD 1.1–1.11 lulus.** Menambah fitur di atas shell yang
   belum stabil akan menggandakan biaya debug.
2. Refactor modul (1.4) sebelum Phase 2, karena `services/media.rs` butuh `window::` yang
   sudah punya batas jelas.
3. Phase 2 media dulu, volume HUD kemudian — volume menyentuh COM callback yang lebih rumit.
4. Phase 3 terakhir; shelf adalah fitur produk, bukan fondasi teknis.
