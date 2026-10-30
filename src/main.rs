//! Dumm — floating dynamic notch native untuk Windows 10/11.
//!
//! Phase 1: window shell. Tanggung jawab file ini hanya tiga:
//! 1. Memilih backend Slint yang hemat memori (renderer software).
//! 2. Menyerahkan konfigurasi HWND ke modul `window`.
//! 3. Menjalankan event loop Slint tanpa polling.

slint::include_modules!();

mod window;

use slint::winit_030::winit;
use windows::core::{PCWSTR, w};

/// Harus sama dengan `title` pada `MainWindow` di `ui/notch.slint`.
const WINDOW_TITLE: PCWSTR = w!("DummNotchOverlay");

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Renderer software dipilih dari feature Cargo, bukan saat runtime.
    // with_skip_taskbar menahan window keluar dari taskbar sejak awal.
    slint::BackendSelector::new()
        .with_winit_window_attributes_hook(|attributes| {
            use winit::platform::windows::WindowAttributesExtWindows;
            attributes.with_skip_taskbar(true)
        })
        .select()?;

    let main_window = MainWindow::new()?;
    main_window.show()?;
    window::init_overlay(&main_window);

    slint::run_event_loop()?;
    Ok(())
}
