//! Dumm — floating dynamic notch native untuk Windows 10/11.
//!
//! Tanggung jawab file ini:
//! 1. Memilih backend Slint yang hemat memori (renderer software).
//! 2. Menyerahkan konfigurasi HWND ke modul `window`.
//! 3. Menyalakan layanan dan meneruskan pesannya ke properti UI.
//! 4. Menjalankan event loop Slint tanpa polling.

slint::include_modules!();

mod services;
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

    // Pesan dari thread layanan masuk ke UI hanya lewat event loop Slint.
    let ui = main_window.as_weak();
    services::media::spawn(move |update| {
        let forwarded = ui.upgrade_in_event_loop(move |main_window| {
            let (title, artist) = if update.has_session {
                (update.title, update.artist)
            } else {
                Default::default()
            };
            main_window.set_media_title(title.into());
            main_window.set_media_artist(artist.into());
        });
        if let Err(error) = forwarded {
            eprintln!("[dumm] pembaruan media tidak terkirim ke UI: {error}");
        }
    });

    slint::run_event_loop()?;
    Ok(())
}
