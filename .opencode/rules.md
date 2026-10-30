# Aturan Engineering Dumm (untuk OpenCode)

Dokumen ini mengikat setiap perubahan kode di repo `D:\codingan\dumm-notch`.
Urutan prioritas bila ada konflik: aturan ini > `docs/ARCHITECTURE.md` > skill yang dimuat > default agent.
Rencana kerja dan kriteria selesai ada di `docs/ROADMAP.md`; kerjakan hanya item fase yang ditugaskan.

## 1. Aturan kerja

- Kerjakan hanya scope tugas. Tanpa refactor di luar scope, tanpa fitur tambahan.
- Tanpa dependency baru kecuali tugas menyebutnya secara eksplisit.
- Jangan commit dan jangan push. Laporkan `git status --short` di akhir.
- Setiap klaim "lolos" wajib disertai output asli `cargo build` / `cargo run` / `cargo clippy`.
  Hal yang tidak bisa diverifikasi masuk daftar "belum terverifikasi". Jangan mengarang output.
- Versi terkunci: Rust edition 2024, `slint` 1.x (lock saat ini 1.18.1), `windows` 0.58.
  Jangan menaikkan versi `windows` tanpa instruksi; API `HWND`/`Result` berubah antar versi.

## 2. Pemisahan `src/` dan `ui/`

- `ui/*.slint` hanya berisi tampilan: layout, warna, animasi, state visual, `callback`, dan `property`.
  Tanpa logika bisnis, tanpa timer polling, tanpa string data hardcode selain label statis.
- `src/` berisi semua logika: Win32, WinRT, audio, state aplikasi, timer Pomodoro.
- Kontrak UI dan Rust hanya lewat `in property`, `out property`, `in-out property`, dan `callback`
  yang dideklarasikan di komponen root `MainWindow`. Rust tidak menyentuh elemen internal.
- Penamaan property Slint: kebab-case (`is-expanded`, `media-title`). Rust mengaksesnya sebagai
  `set_is_expanded` / `get_media_title` (generated).
- Satu komponen per tanggung jawab visual. File boleh dipecah per fitur (`ui/media.slint`,
  `ui/hud.slint`) dan di-`import` dari `ui/notch.slint`.

## 3. Struktur modul Rust

```
src/main.rs              entry point: buat window, pasang service, jalankan event loop
src/window/mod.rs        konfigurasi HWND: style, posisi, DWM
src/services/mod.rs      trait/enum event bersama
src/services/media.rs    GSMTC (Phase 2)
src/services/system_hud.rs volume + power (Phase 2)
```

- `main.rs` tidak berisi panggilan `unsafe` Win32 langsung. Semua `unsafe` berada di `src/window/`
  atau `src/services/`.
- Modul service tidak meng-import tipe generated Slint. Service mengirim `AppEvent` (enum biasa)
  dan `main.rs` yang memetakan event ke property UI.

## 4. Win32 FFI yang aman

- Dilarang `unwrap()`, `expect()`, `panic!`, dan indexing yang bisa panic pada jalur runtime.
  Pengecualian satu-satunya: `build.rs` (gagal compile UI memang harus menghentikan build).
- Di `windows` 0.58, `FindWindowW` mengembalikan `windows::core::Result<HWND>`. Pola wajib:

  ```rust
  let Ok(hwnd) = (unsafe { FindWindowW(None, w!("DummNotchOverlay")) }) else {
      eprintln!("dumm: HWND overlay tidak ditemukan");
      return;
  };
  ```

- Setiap blok `unsafe` sesempit mungkin dan diawali komentar `// SAFETY:` yang menjelaskan
  kenapa pointer/handle valid.
- Fungsi yang mengembalikan `Result` diteruskan dengan `?` atau dilog lalu diabaikan secara
  sadar (`if let Err(e) = ... { eprintln!(...) }`). Jangan `let _ =` pada panggilan yang
  kegagalannya mengubah perilaku (style window, posisi, DWM).
- Fungsi yang mengembalikan nilai lama (`SetWindowLongPtrW`) boleh diabaikan, tapi baca dulu
  style lama dengan `GetWindowLongPtrW` lalu OR/AND-kan. Jangan menimpa seluruh extended style.
- HWND baru ada setelah event loop berjalan. `FindWindowW` tepat setelah `show()` maupun di
  `Timer` 0 ms gagal (terukur). Konfigurasi HWND dijalankan sekali di event winit pertama
  (`on_winit_window_event` + guard `Cell<bool>`).
- Jangan pakai `WS_EX_LAYERED` tanpa `SetLayeredWindowAttributes`/`UpdateLayeredWindow`;
  window layered tanpa atribut tidak tergambar. Transparansi sudah ditangani winit
  (`DwmEnableBlurBehindWindow`) bersama `background: transparent` di Slint.
- Jangan panggil `DwmExtendFrameIntoClientArea` dengan margin `-1`. Terukur: DWM lalu menggambar
  border abu-abu 1 px dan glyph "×" di sekeliling window. Bila dipakai, margin wajib `0`.
- Ukuran dari Slint adalah logical px; Win32 memakai physical px. Jangan menulis ukuran
  hardcode ke `SetWindowPos`; pakai `SWP_NOSIZE` dan baca lebar asli dengan `GetWindowRect`.
- Handle COM/WinRT dibungkus tipe pemilik yang melepas resource di `Drop`
  (`CoUninitialize`, `UnregisterPowerSettingNotification`, revoke event token).

## 5. Disiplin memori dan CPU

- Dilarang loop polling: `loop { sleep(..) }`, `Timer` berulang untuk mengecek state, atau
  `thread::spawn` yang busy-wait. Semua sumber data memakai callback OS.
- Update dari thread lain masuk ke UI hanya lewat `slint::invoke_from_event_loop` atau
  `Weak::upgrade_in_event_loop`. Jangan menyimpan `MainWindow` (strong) di closure thread.
- `slint::Timer` hanya untuk durasi yang memang dibutuhkan user (auto-collapse HUD, Pomodoro).
  Timer dihentikan saat tidak aktif.
- Animasi di Slint hanya pada perubahan state. Jangan `animate` property yang di-bind ke nilai
  yang berubah terus.
- Hindari alokasi di jalur event panas: pakai `SharedString`, jangan `format!` per frame.
- Thread latar maksimal satu per sumber event OS yang membutuhkan message pump sendiri.
- Gambar album art di-resize ke ukuran tampil sebelum dijadikan `slint::Image`; jangan simpan
  bitmap ukuran asli.

## 6. Kualitas

- `cargo build` dan `cargo clippy -- -D warnings` bersih sebelum laporan selesai.
- Komentar dan pesan log memakai bahasa Indonesia yang baku. Nama identifier bahasa Inggris.
- Tanpa kode mati, tanpa `#[allow(...)]` untuk menutupi warning kecuali disertai alasan.
