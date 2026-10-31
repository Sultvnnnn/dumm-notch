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
    // Skala antarmuka mengikuti lebar layar utama: kartu 380x100 terlalu kecil untuk monitor
    // 1920 ke atas, dan ukuran tetap membuat tata letak terasa rapat.
    // SAFETY: GetSystemMetrics hanya membaca metrik sistem, tidak menyentuh pointer.
    let screen_width = unsafe { windows::Win32::UI::WindowsAndMessaging::GetSystemMetrics(
        windows::Win32::UI::WindowsAndMessaging::SM_CXSCREEN,
    ) };
    let scale = match screen_width {
        w if w <= 1600 => 1.0,
        w if w <= 2000 => 1.3,
        w if w <= 2600 => 1.5,
        _ => 1.7,
    };
    main_window.set_scale(scale);

    main_window.show()?;
    window::init_overlay(&main_window);

    // Pesan dari thread layanan masuk ke UI hanya lewat event loop Slint.
    let ui = main_window.as_weak();
    let commands = services::media::spawn(move |update| {
        let forwarded = ui.upgrade_in_event_loop(move |main_window| {
            let (title, artist) = if update.has_session {
                (update.title, update.artist)
            } else {
                Default::default()
            };
            main_window.set_media_title(title.into());
            main_window.set_media_artist(artist.into());
            main_window.set_is_playing(update.is_playing);
            main_window.set_position_frac(update.position_frac);
            main_window.set_position_label(update.position_label.into());
            main_window.set_duration_label(update.duration_label.into());
            if update.artwork_changed {
                let artwork = update.artwork.map(|art| {
                    let pixels = slint::SharedPixelBuffer::<slint::Rgba8Pixel>::clone_from_slice(&art.rgba, art.width, art.height);
                    slint::Image::from_rgba8(pixels)
                }).unwrap_or_default();
                main_window.set_media_artwork(artwork);
            }
        });
        if let Err(error) = forwarded {
            eprintln!("[dumm] pembaruan media tidak terkirim ke UI: {error}");
        }
    });

    let ui_volume = main_window.as_weak();
    // V2: pembaruan volume pertama adalah baseline (nilai awal endpoint) dan tidak boleh
    // memunculkan HUD. `volume-ready` baru dinaikkan pada pembaruan kedua, sehingga hanya
    // perubahan volume nyata dari pengguna yang memicu HUD. Tanpa timer.
    let volume_updates = std::cell::Cell::new(0u32);
    services::volume::spawn(move |update| {
        let count = volume_updates.get() + 1;
        volume_updates.set(count);
        let forwarded = ui_volume.upgrade_in_event_loop(move |main_window| {
            let ready = count > 1;
            main_window.set_volume_level(update.level);
            main_window.set_volume_muted(update.muted);
            main_window.set_volume_ready(ready);
        });
        if let Err(error) = forwarded {
            eprintln!("[dumm] pembaruan volume tidak terkirim ke UI: {error}");
        }
    });

    let tx = commands.clone();
    main_window.on_play_pause(move || {
        #[cfg(debug_assertions)]
        eprintln!("[dumm] klik play-pause");
        let _ = tx.send(services::media::Signal::Command(services::ServiceCommand::TogglePlayPause));
    });
    let tx = commands.clone();
    main_window.on_next(move || {
        #[cfg(debug_assertions)]
        eprintln!("[dumm] klik next");
        let _ = tx.send(services::media::Signal::Command(services::ServiceCommand::Next));
    });
    main_window.on_previous(move || {
        #[cfg(debug_assertions)]
        eprintln!("[dumm] klik previous");
        let _ = commands.send(services::media::Signal::Command(services::ServiceCommand::Previous));
    });

    slint::run_event_loop()?;
    Ok(())
}
