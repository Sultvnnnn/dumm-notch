use std::cell::Cell;

use slint::ComponentHandle;
use slint::winit_030::{EventResult, WinitWindowAccessor};
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::FindWindowW;

use crate::{MainWindow, WINDOW_TITLE};

/// Memanggil `on_ready` tepat sekali, pada event winit pertama setelah HWND native ada.
///
/// HWND belum ada setelah `show()` maupun pada timer 0 ms, jadi pemasangan ditunda ke
/// hook event winit, bukan ke timer/polling.
pub fn on_hwnd_ready(main_window: &MainWindow, on_ready: impl Fn(HWND) + 'static) {
    let applied = Cell::new(false);
    main_window
        .window()
        .on_winit_window_event(move |winit_window, _event| {
            if applied.get() || !winit_window.has_winit_window() {
                return EventResult::Propagate;
            }

            // SAFETY: WINDOW_TITLE adalah literal UTF-16 statis berakhiran nul dari `w!`.
            // FindWindowW hanya membaca; hasilnya Result, jadi tidak ada unwrap.
            if let Ok(hwnd) = unsafe { FindWindowW(None, WINDOW_TITLE) } {
                applied.set(true);
                on_ready(hwnd);
            }

            // Bila window belum terdaftar, event berikutnya akan mencoba lagi.
            EventResult::Propagate
        });
}
