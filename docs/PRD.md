# Product Requirement Document (PRD) — Dumm (Windows Dynamic Notch)

## 1. Executive Summary

Dumm adalah lightweight dynamic notch overlay untuk Windows 11/10 yang dibangun di atas Rust dan Slint UI. Aplikasi ini dirancang sebagai micro-utility hub non-intrusif di area bezel atas layar monitor dengan jejak memori sangat rendah (< 15 MB RAM idle) dan responsivitas instan tanpa webview runtime.

## 2. Technical Stack & Architecture

- **Language:** Rust (Edition 2024, Toolchain MSVC)
- **UI Framework:** Slint UI (v1.9+)
- **OS Interop:** Windows API (`windows` crate v0.58)
- **Target OS:** Windows 10 / 11 (x86_64)

## 3. Core Capabilities & Milestones

### Phase 1: Native Window Shell (Current Focus)

- Window melayang (_frameless_, tanpa border & title bar, `always-on-top`).
- Komposisi transparansi sesungguhnya via DWM (`DwmExtendFrameIntoClientArea`).
- Tersembunyi dari Taskbar dan Alt+Tab (`WS_EX_TOOLWINDOW`).
- Posisi menempel presisi di bagian horizontal center, vertical top (y = 0).
- Animasi transisi fluid saat pill di-hover (expand: 380x90px) dan idle (shrink: 180x32px).

### Phase 2: Media Hub & Hardware HUD

- Integrasi GSMTC (`Windows::Media::Control`) untuk membaca Now Playing Spotify/Browser.
- Metadata display (Title, Artist, Playback control).
- Overlay HUD reaktif saat volume bergeser atau status baterai/charger berubah.
- Mouse wheel scroll gesture di area pill untuk mengatur master volume Windows.

### Phase 3: Productivity & Micro-Utilities

- Temporary Drag & Drop shelf untuk holding file antar folder/aplikasi.
- Minimalist countdown Pomodoro timer.
- Dynamic dual-pill state saat audio dan timer aktif bersamaan.

## 4. Non-Functional Constraints

- **Idle Memory:** Maksimal 15 MB RAM.
- **CPU:** 0% ketika tidak ada animasi atau event.
- **Robustness:** Hindari unwrap panic pada panggilan Windows API.
