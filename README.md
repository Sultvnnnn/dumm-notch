# Dumm

A native, ultra-light dynamic notch overlay for Windows 10/11. It sits at the top center of the
screen as a small pill, expands on hover, and costs what a native window should cost — no
Electron, no Tauri, no WebView2.

**Measured on the current build** (release, 1920×1080, Windows 11):

| Metric | Value |
| --- | --- |
| Private memory | **2.95 – 3.07 MB** |
| Working set | ~16.9 MB |
| Idle CPU (no input) | **0 ms** across 114 sampled buckets |
| Binary size | 6.3 MB (stripped, LTO, `opt-level = "z"`) |
| Threads / handles | 7 / ~210 |

> "Idle CPU" here means CPU used while no input arrives. The overlay is event-driven and does
> wake on `WM_MOUSEMOVE`, including over the transparent part of its window — that is behaviour,
> not polling. See `docs/ARCHITECTURE.md` chapter 3.1.

## Status

Phase 1 (native window shell) is complete and verified. Phase 2 is under way: the media slice
reads the active GSMTC session, shows title and artist in the expanded pill, and drives
play/pause, next and previous through the same service thread — all event-driven, no polling.
Artwork, the volume HUD and Phase 3 remain, as specified in `docs/ROADMAP.md`.

## Stack

| Layer | Choice | Why |
| --- | --- | --- |
| Language | Rust 2024 (MSVC toolchain) | No runtime, no GC |
| UI | Slint 1.18, **software renderer** | femtovg backend costs ~70 MB working set; software costs ~17 MB |
| Win32 | `windows` crate 0.58 | Minimal feature set: `Win32_Foundation`, `Win32_UI_WindowsAndMessaging` |
| Event loop | winit 0.30 (via Slint's `backend-winit`) | One loop, no extra message pump |

`slint` is pinned with `default-features = false`. Enabling its default features pulls the
femtovg renderer and multiplies memory usage.

## Requirements

- Windows 10/11 x86_64
- Rust stable with edition 2024 support (`rustup default stable`)
- MSVC build tools (the `x86_64-pc-windows-msvc` target)

## Build and run

```powershell
cargo build --release
.\target\release\dum-notch.exe
```

The window is frameless, topmost, and skipped from the taskbar and Alt-Tab. It closes with
`Ctrl+C` in the terminal that launched it, or by terminating the process.

## How it is verified

The DoD in `docs/ROADMAP.md` is checked by two scripts that drive the real binary and read the
real screen, so no claim rests on eyeballing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-hover.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-idle.ps1
```

- `verify-hover.ps1` moves the cursor in interpolated steps (a teleporting `SetCursorPos` does
  not reliably deliver hover), captures a baseline strip with the app stopped, and measures the
  pill's width by pixel diff. It expects 180 px idle and 380 px expanded, 10 cycles.
- `verify-idle.ps1` samples `TotalProcessorTime` in 0.5 s buckets and splits them by
  `GetLastInputInfo`, so input-driven wakeups are not counted as idle CPU. It passes only when
  every input-free bucket shows 0 ms.

Both assume a 1920 px wide primary monitor with the overlay at the top center.

## Project layout

```
src/main.rs              bootstrap: backend selection, window, event loop
src/window/mod.rs        single entry point: init_overlay -> attach -> style -> position
src/window/attach.rs     locate the HWND on the first winit event
src/window/style.rs      WS_EX_TOOLWINDOW in, WS_EX_APPWINDOW out
src/window/position.rs   center horizontally, pin to y = 0, keep topmost
src/services/media.rs    GSMTC session service thread: title/artist, event-driven, no polling
src/services/mod.rs      message types shared with the UI (no Slint types)
ui/notch.slint           declarative UI: pill, expansion animation, hover state
scripts/verify-*.ps1     DoD harnesses (hover geometry, idle CPU)
docs/PRD.md              product requirements
docs/ARCHITECTURE.md     data flow, zero-polling policy, memory analysis, decision log
docs/ROADMAP.md          phases and measurable definition of done
.opencode/rules.md       engineering rules for the delegated coding agent
```

Rust holds every Win32 call and every piece of state. `.slint` files describe appearance only —
no FFI, no logic beyond view state.

## Known limitations

- Single-monitor centering: uses `SM_CXSCREEN`, so multi-monitor setups need Phase 2 work.
- The window is 420×160 while the pill is 180×32 (expanded: 380×90), so the cursor is tracked
  over a larger area than the visible pill. Shrinking the native window or shaping it with
  `SetWindowRgn` is scheduled for Phase 2.
- `DwmExtendFrameIntoClientArea` is deliberately **not** used: it produced a 1 px gray border
  and an "×" glyph on this stack. Transparency comes from the software renderer instead.
- No installer, no autostart entry, no tray icon yet.

## Documentation

- [`docs/PRD.md`](docs/PRD.md) — what the product is and its constraints
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — module contracts, zero-polling rules, measurements
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — phases, definition of done, known risks
