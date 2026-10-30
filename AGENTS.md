# AGENTS.md — Dumm

Repo ini berisi aplikasi notch native Windows (Rust + Slint + windows-rs).
Instruksi berikut mengikat setiap agent yang bekerja di sini.

## Bacaan wajib sebelum mengubah kode

1. `.opencode/rules.md` — coding standard, disiplin memori, aturan FFI, pemisahan `src/` dan `ui/`.
2. `docs/ARCHITECTURE.md` — alur data event-driven, strategi anti-polling, batas modul,
   keputusan teknis beserta alasan terukurnya.
3. `docs/ROADMAP.md` — fase kerja dan Definition of Done terukur.

Urutan prioritas bila ada konflik: `.opencode/rules.md` > `docs/ARCHITECTURE.md` >
skill yang dimuat > default agent.

## Aturan singkat yang tidak boleh dilanggar

- Tanpa polling. Tidak ada timer berkala; timer hanya boleh ada dengan jalur berhenti eksplisit.
- Tanpa `unwrap()`/`expect()` pada jalur FFI. API `windows` 0.58 mengembalikan `Result`.
- Tanpa `DwmExtendFrameIntoClientArea`, tanpa feature `Win32_UI_Controls` / `Win32_Graphics_Dwm`.
  Sudah diuji: memunculkan border abu-abu 1 px dan glyph "x". Alasan: `docs/ARCHITECTURE.md`, poin 5.2.
- Tanpa dependency baru tanpa persetujuan arsitek.
- Warna, radius, durasi, ukuran visual hanya di `ui/*.slint`. Panggilan Win32 hanya di `src/`.
- Tanpa commit dan tanpa push kecuali diminta eksplisit.

## Tugas aktif

Tugas per-fase ditulis di `TASK_PROMPT.md` (di-exclude dari git, lokal saja).
Minta agent membacanya secara eksplisit, jangan dijadikan konteks default.
