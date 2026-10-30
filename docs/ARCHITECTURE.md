# ARSITEKTUR DUMM

Dokumen ini menjelaskan arsitektur sistem **Dumm**, floating dynamic notch native untuk
Windows 10/11. Semua angka memori di dokumen ini berasal dari pengukuran langsung
(lihat §6), bukan perkiraan.

**Stack terkunci:** Rust edition 2024 · Slint 1.x (`renderer-software`) · `windows` 0.58.
Tidak ada Electron, Tauri, WebView2, maupun runtime terkelola.

---

## 1. Prinsip Arsitektur

| Prinsip | Konsekuensi teknis |
| --- | --- |
| Nol polling | Tidak ada `loop { sleep }` dan tidak ada timer berkala. Semua reaksi berasal dari event handler Slint/winit atau callback Win32/WinRT. |
| Satu proses, satu thread UI | Slint, winit, dan seluruh pemanggilan Win32 UI berjalan di thread main. Tanpa `Send/Sync` lintas thread untuk `MainWindow`. |
| FFI sebagai lapisan tipis | Semua `unsafe` dibatasi di `src/window/style.rs` dan `src/window/position.rs`, masing-masing dengan blok `// SAFETY:` dan signature `-> windows::core::Result<()>`. |
| UI deklaratif | `ui/*.slint` hanya berisi tampilan dan properti; tidak ada logika sistem. |
| Gagal lunak | Kegagalan satu fitur (mis. media session tidak tersedia) menonaktifkan fitur itu, bukan menghentikan aplikasi. |

---

## 2. Alur Data (Event-Driven)

```
                     ┌──────────────────────────── thread main ────────────────────────────┐
                     │                                                                     │
 Win32 / OS event ──▶│  winit event loop  ──▶  Slint event loop  ──▶  ui/notch.slint        │
 (hover, klik,       │        │                     │                                    │
  tray, hotkey)      │        │                     └──▶ property binding ──▶ render      │
                     │        │                                                             │
                     │        └──▶ src/window/attach.rs (sekali: HWND, exstyle, posisi)    │
                     │                                                                     │
 service thread ────▶│  Sender<ServiceEvent> ──▶ invoke_from_event_loop ──▶ Slint property │
 (Phase 2/3)         │                                                                     │
                     └─────────────────────────────────────────────────────────────────────┘
```

Aturan aliran data:

1. **Arah masuk:** event OS masuk lewat winit/Slint atau lewat channel dari thread service.
2. **Marshalling:** thread service TIDAK menyentuh `MainWindow` secara langsung. Setiap update
   dibungkus `slint::Weak<MainWindow>` + `slint::invoke_from_event_loop(...)`.
3. **Arah keluar:** aksi pengguna (klik pill, tombol media) menulis ke state Slint atau
   mengirim perintah ke service lewat `Sender<ServiceCommand>`.
4. **Kebenaran tunggal:** sumber data ada di service (`src/services/`). Slint hanya cermin
   dari state itu, jadi tidak ada duplikasi logika.

### 2.1 Urutan startup (Phase 1, terverifikasi)

1. `BackendSelector` dipilih dengan hook `with_winit_window_attributes_hook` →
   `with_skip_taskbar(true)`.
2. `MainWindow::new()` lalu `show()` — pada titik ini HWND native **belum** ada.
3. Event winit pertama tiba; handler memanggil `FindWindowW(None, w!("DummNotchOverlay"))`.
   `FindWindowW` di `windows` 0.58 mengembalikan `Result<HWND>`, sehingga dipakai
   `if let Ok(hwnd) = ...`; tidak ada `unwrap`.
4. `apply_overlay_behavior(hwnd)` dipasang sekali: `WS_EX_TOOLWINDOW` ditambah,
   `WS_EX_APPWINDOW` dihapus, `SetWindowPos` menempelkan window di `y = 0` tengah layar.
5. `run_event_loop()` — setelah itu proses idle tanpa satu pun timer aktif.

> HWND tidak tersedia saat `show()` maupun pada timer 0 ms. Timer 100 ms berfungsi, tetapi
> event hook lebih deterministik dan tidak menambah timer sama sekali.

---

## 3. Strategi Zero-Polling

| Kebutuhan | Mekanisme yang dipakai | Yang dilarang |
| --- | --- | --- |
| Perubahan visual (hover, expand/shrink) | `TouchArea` di Slint + `animate` deklaratif | Timer `repeat` untuk animasi manual |
| Sinkronisasi media (Phase 2) | GSMTC `SessionManager` + `CurrentSessionChanged` / `MediaPropertiesChanged` / `TimelinePropertiesChanged` | Polling `GetCurrentSession` setiap N ms |
| Volume HUD (Phase 2) | `IAudioEndpointVolume` callback (COM) atau `Win32_System_Power`/notifikasi perangkat | Polling mixer setiap frame |
| Battery / jam (Phase 3) | `PowerSettingRegisterNotification` untuk baterai; jam hanya hidup saat shelf terbuka | Refresh tiap detik walau shelf tertutup |
| Focus timer (Phase 3) | Satu `slint::Timer` yang hanya dibuat saat sesi berjalan lalu dihentikan saat selesai | Timer yang selalu aktif |
| Tray / show-hide | Register hotkey + window message | Loop pengecekan |

Kaidah: **timer adalah resource yang harus dibebaskan.** Setiap timer wajib punya jalur
berhenti yang eksplisit. Bila sebuah fitur tidak bisa dibuat event-driven, fitur itu ditunda,
bukan dipaksakan dengan polling.

### 3.1 Hasil pengukuran idle

`TotalProcessorTime` bertambah per kuantum 15,6 ms, jadi angka "0 ms" dan "600 ms" untuk satu
proses bisa muncul dari kondisi yang sama sekali berbeda. Pengukuran awal yang hanya menjumlah
60 detik memberi tiga hasil berbeda (641 ms, 578 ms, 0 ms) tanpa penjelasan.

Setelah bucket 0,5 detik dipisahkan memakai `GetLastInputInfo` (bucket tanpa input vs bucket
yang berisi input), polanya jelas: **CPU hanya bertambah saat ada event input.** Tiga run
pengukuran lanjutan memberi 114 bucket tanpa input dengan total **0 ms** CPU, sementara bucket
yang berisi input memakai 0–438 ms.

Kesimpulan: tidak ada polling di aplikasi. Wakeup berasal dari `WM_MOUSEMOVE` yang ditangani
backend winit/Slint, termasuk saat kursor berada di area transparan window 420×160. Karena itu
DoD idle CPU diukur dengan `scripts/verify-idle.ps1` yang hanya menghitung bucket tanpa input.

---

## 4. Struktur Modul

```
src/
├── main.rs                 Bootstrap: backend selector, show(), pasang hook, run event loop.
├── window/
│   ├── mod.rs              API tingkat tinggi: `init_overlay(&MainWindow)`.
│   ├── attach.rs           Penentuan waktu pemasangan HWND, guard "sekali jalan".
│   ├── style.rs            WS_EX_TOOLWINDOW / WS_EX_APPWINDOW, // SAFETY per panggilan.
│   └── position.rs         SetWindowPos: tengah atas, HWND_TOPMOST, SWP_NOACTIVATE.
├── services/
│   ├── mod.rs              Enum `ServiceEvent` / `ServiceCommand`, channel helper.
│   ├── media.rs            Phase 2 — GSMTC: judul, artis, artwork, transport control.
│   └── system_hud.rs       Phase 3 — baterai, volume, jam, clipboard shelf.
└── timer/
    └── focus.rs            Phase 3 — Pomodoro, timer aktif hanya selama sesi.
ui/
├── notch.slint             Root `MainWindow`, kontrak properti publik.
└── components/             Phase 2+: pill, media card, shelf.
```

Kontrak modul (interface, bukan implementasi):

| Modul | Masukan | Keluaran | Boleh menyentuh UI? |
| --- | --- | --- | --- |
| `window::attach` | `&MainWindow` | — | Hanya membaca `window()`, tidak menulis properti |
| `services::media` | `ServiceCommand` | `ServiceEvent::MediaChanged` | Tidak |
| `services::system_hud` | `ServiceCommand` | `ServiceEvent::HudChanged` | Tidak |
| `timer::focus` | `ServiceCommand::StartFocus` | `ServiceEvent::FocusTick` | Tidak |

**Pemisahan tegas:** `src/` tidak boleh berisi warna, radius, durasi animasi, atau ukuran
piksel visual. `ui/` tidak boleh berisi panggilan FFI, nama window, atau konstanta Win32.
Satu-satunya nilai yang dipakai bersama adalah nama window (`DummNotchOverlay`) yang harus
identik di `ui/notch.slint` (`title`) dan `src/main.rs` (`WINDOW_TITLE`).

---

## 5. Keputusan Teknis Penting (Decision Log)

### 5.1 Renderer software, bukan femtovg

`slint` dipasang dengan `default-features = false` dan `features = ["std", "compat-1-2",
"backend-winit", "renderer-software", "unstable-winit-030"]`.

Alasan: backend default (femtovg, OpenGL) membawa driver + konteks GL. Pengukuran probe pada
window yang sama menunjukkan working set 70 MB / private 32 MB, sedangkan renderer software
17,8 MB / private 3,1 MB. Notch hanya menggambar beberapa rounded rectangle dan teks, sehingga
akselerasi GPU tidak memberi manfaat sebanding.

### 5.2 Tanpa `DwmExtendFrameIntoClientArea`

PRD Phase 1 menyebut "transparan via DWM glass". Hasil uji: memanggil
`DwmExtendFrameIntoClientArea` dengan `MARGINS { -1, -1, -1, -1 }` pada window winit yang sudah
transparan justru memunculkan **border abu-abu 1 px** di seluruh tepi window dan glyph **"x"**
dekat tombol tutup. Setelah panggilan itu dihapus (Probe 7), tangkapan layar bersih dan
transparansi tetap bekerja penuh karena winit sudah memakai alpha channel composited.

Keputusan: DWM glass **tidak dipakai**. Feature `Win32_Graphics_Dwm` dan `Win32_UI_Controls`
(MARGINS) dihapus dari `Cargo.toml` agar tidak mengundang pemakaian ulang. Ini penyimpangan
sadar dari PRD dan sudah dicatat di sini.

### 5.3 `with_skip_taskbar` + `WS_EX_TOOLWINDOW`

Dua mekanisme dipakai bersama: atribut winit (efektif sejak window dibuat) dan bit exstyle
(menutup kasus window di-restore). `WS_EX_APPWINDOW` harus dihapus eksplisit; tanpa itu window
tetap muncul di Alt-Tab pada sebagian konfigurasi taskbar.

### 5.4 Posisi dihitung dari `GetWindowRect`, bukan dari konstanta

Lebar window diambil dari rect nyata, bukan angka `420`. Alasannya: lebar Slint dan DPI scaling
bisa berbeda dari asumsi. `x = (SM_CXSCREEN - width) / 2` sehingga window tetap di tengah pada
skala 100% maupun 125%. Catatan: `SM_CXSCREEN` mengembalikan pixel fisik monitor utama; pada
konfigurasi multi-monitor, Phase 2 harus menggantinya dengan `MonitorFromWindow` +
`GetMonitorInfo` agar notch mengikuti monitor yang aktif.

---

## 6. Analisis Memori: Rust + Slint vs Managed Runtime

Pengukuran pada build release, window idle, tanpa animasi berjalan:

| Konfigurasi | Working Set | Private Bytes | Catatan |
| --- | --- | --- | --- |
| Slint, backend default (femtovg/GL), debug | ~70 MB | ~32 MB | Baseline "cara gampang" |
| Slint, winit-software, debug | ~25 MB | ~3,8 MB | Sebelum optimasi build |
| Slint, winit-software, release | **~17,8 MB** | **~3,1 MB** | Konfigurasi yang dipakai |
| .NET/WPF hello-world (referensi umum) | ~80–120 MB | ~40–60 MB | Runtime + JIT + GC heap |

Penyebab selisih:

1. **Tanpa runtime terkelola.** Tidak ada GC heap, tidak ada JIT, tidak ada assembly loading.
   Kode Rust dikompilasi statis; yang dimuat saat runtime hanya crate yang benar-benar dipanggil.
2. **Renderer software.** Tidak ada konteks OpenGL, texture atlas GPU, atau driver state yang
   dialokasikan sejak awal. Menggambar notch adalah beberapa operasi raster kecil.
3. **Working set ≠ biaya nyata.** Working set mencakup halaman kode yang dipetakan bersama
   (`comctl32`, `user32`, `gdi32`, DLL CRT) yang juga dipakai proses lain. Private bytes
   (≈3 MB) adalah memori yang benar-benar eksklusif milik Dumm.
4. **`[profile.release]`** memakai `opt-level = "z"`, `lto = true`, `codegen-units = 1`,
   `panic = "abort"`, `strip = true` sehingga biner kecil dan tidak membawa jalur panic
   yang tidak perlu.

Catatan terhadap constraint PRD (< 15 MB RAM idle): angka 17,8 MB adalah working set. Target
15 MB realistis bila diukur sebagai private bytes, dan bisa turun lagi dengan (a) mengecilkan
ukuran window idle menjadi 180×32 (pixel buffer lebih kecil), (b) menghindari teks berukuran
besar/font fallback, (c) menunda inisialisasi service Phase 2 sampai benar-benar dipakai.
Keputusan metrik resmi yang dipakai untuk DoD: **private bytes**, dengan working set dilaporkan
sebagai informasi pendamping. Perlu persetujuan pemilik produk bila PRD ingin tetap memakai
working set.

---

## 7. Risiko dan Batasan yang Diketahui

| Risiko | Dampak | Mitigasi |
| --- | --- | --- |
| Event winit pertama melaporkan `Resized(1440×759)` | Ukuran pada event pertama tidak sama dengan rect akhir | Jangan memakai ukuran dari event; baca `GetWindowRect` |
| Transparansi bergantung pada DWM compositor | Bila compositor dimatikan, window bisa tampak hitam | Terima sebagai batasan Windows 10/11 modern; dokumentasikan |
| `FindWindowW` berbasis judul | Judul duplikat dari proses lain bisa tertukar | Judul unik `DummNotchOverlay`, dan Phase 2 sebaiknya pindah ke handle dari winit |
| Multi-monitor | `SM_CXSCREEN` hanya monitor utama | Ganti ke `MonitorFromWindow` pada Phase 2 |
| Auto-hide taskbar | Notch di `y = 0` bisa tertutup taskbar | Uji dan geser ke `y = work_area.top` bila perlu |
| Kursor di area transparan tetap membangunkan proses | CPU terpakai saat kursor lewat, bukan saat diam | Phase 2: perkecil window ke ukuran maksimum pill (380×90) atau bentuk ulang dengan `SetWindowRgn` agar area tembus kursor tidak menerima event |
