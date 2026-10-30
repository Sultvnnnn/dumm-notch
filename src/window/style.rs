use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::{
    GWL_EXSTYLE, GetWindowLongPtrW, SetWindowLongPtrW, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW,
};

/// Menyembunyikan window dari taskbar/Alt-Tab: `WS_EX_TOOLWINDOW` masuk,
/// `WS_EX_APPWINDOW` keluar. Bit exstyle lain dipertahankan.
///
/// # Safety
/// `hwnd` harus window valid milik proses ini.
pub unsafe fn apply(hwnd: HWND) {
    // SAFETY: pemanggil menjamin hwnd valid; style lama dibaca dulu agar bit lain
    // (mis. WS_EX_TOPMOST) tidak tertimpa. Nilai balik SetWindowLongPtrW adalah style
    // lama, bukan status galat.
    unsafe {
        let current = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let desired = (current | WS_EX_TOOLWINDOW.0 as isize) & !(WS_EX_APPWINDOW.0 as isize);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, desired);
    }
}
