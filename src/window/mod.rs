//! Konfigurasi HWND overlay. Satu-satunya pintu masuk: [`init_overlay`].
//!
//! Transparansi ditangani oleh winit (alpha channel + no-frame pada Slint).
//! `DwmExtendFrameIntoClientArea` sengaja tidak dipakai: pada uji Probe 7 panggilan
//! itu memunculkan border abu-abu 1px dan glyph "x" pada area transparan.

mod attach;
mod position;
mod style;

use crate::MainWindow;

/// Memasang perilaku overlay (exstyle + posisi) sekali setelah HWND native tersedia.
pub fn init_overlay(main_window: &MainWindow) {
    attach::on_hwnd_ready(main_window, |hwnd| {
        // SAFETY: hwnd baru saja dikembalikan FindWindowW untuk window milik proses ini.
        unsafe { style::apply(hwnd) };
        // SAFETY: idem.
        if let Err(error) = unsafe { position::apply(hwnd) } {
            eprintln!("[dumm] gagal memasang atribut overlay: {error}");
        }
        #[cfg(debug_assertions)]
        log_state(hwnd);
    });
}

/// Mencetak rect dan exstyle aktual agar DoD 1.4–1.6 dapat diverifikasi dari output.
/// Hanya ada pada build debug.
#[cfg(debug_assertions)]
fn log_state(hwnd: windows::Win32::Foundation::HWND) {
    use windows::Win32::Foundation::RECT;
    use windows::Win32::UI::WindowsAndMessaging::{
        GWL_EXSTYLE, GetSystemMetrics, GetWindowLongPtrW, GetWindowRect, SM_CXSCREEN,
        WINDOW_EX_STYLE, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
    };

    let mut rect = RECT::default();
    // SAFETY: hwnd valid (lihat init_overlay); rect buffer lokal; WINDOW_TITLE literal
    // UTF-16 statis berakhiran nul sehingga display() membaca memori yang sah.
    unsafe {
        if let Err(error) = GetWindowRect(hwnd, &mut rect) {
            eprintln!("[dumm] GetWindowRect gagal: {error}");
        }
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let has = |bit: WINDOW_EX_STYLE| ex & bit.0 as isize != 0;
        eprintln!(
            "[dumm] title={} rect=({},{},{},{}) exstyle=0x{:08x} toolwindow={} appwindow={} topmost={} cxscreen={}",
            crate::WINDOW_TITLE.display(),
            rect.left,
            rect.top,
            rect.right,
            rect.bottom,
            ex,
            has(WS_EX_TOOLWINDOW),
            has(WS_EX_APPWINDOW),
            has(WS_EX_TOPMOST),
            GetSystemMetrics(SM_CXSCREEN),
        );
    }
}
