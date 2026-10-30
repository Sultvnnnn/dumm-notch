use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, GetWindowRect, HWND_TOPMOST, SM_CXSCREEN, SWP_FRAMECHANGED,
    SWP_NOACTIVATE, SWP_NOSIZE, SetWindowPos,
};

/// Menempelkan window di tengah atas monitor utama dan menjadikannya topmost.
///
/// Lebar dibaca dari `GetWindowRect`, bukan dari payload event winit maupun konstanta,
/// karena event pertama melaporkan ukuran monitor dan DPI scaling mengubah lebar fisik.
///
/// # Safety
/// `hwnd` harus window valid milik proses ini.
pub unsafe fn apply(hwnd: HWND) -> windows::core::Result<()> {
    let mut rect = RECT::default();
    // SAFETY: pemanggil menjamin hwnd valid; rect adalah buffer lokal yang dapat ditulis.
    unsafe { GetWindowRect(hwnd, &mut rect)? };

    let width = rect.right - rect.left;
    // SAFETY: GetSystemMetrics tidak menyentuh memori pemanggil.
    let x = (unsafe { GetSystemMetrics(SM_CXSCREEN) } - width) / 2;

    // SAFETY: pemanggil menjamin hwnd valid; SWP_NOSIZE membuat cx/cy diabaikan.
    unsafe {
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            x,
            0,
            0,
            0,
            SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        )
    }
}
