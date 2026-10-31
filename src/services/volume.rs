//! Volume endpoint audio default (read-only + notifikasi perubahan).
//!
//! Satu thread layanan `dumm-volume`. COM diinisialisasi MTA di thread ini. Callback
//! `IAudioEndpointVolumeCallback` datang dari thread milik COM dan hanya mengirim `VolumeUpdate`
//! lewat `mpsc`; thread layanan yang meneruskan ke UI. Tidak ada polling, tidak ada timer.

use std::sync::mpsc;
use std::thread;

use windows::core::{implement, Result};
use windows::Win32::Media::Audio::Endpoints::{
    IAudioEndpointVolume, IAudioEndpointVolumeCallback, IAudioEndpointVolumeCallback_Impl,
};
use windows::Win32::Media::Audio::{
    AUDIO_VOLUME_NOTIFICATION_DATA, IMMDeviceEnumerator, MMDeviceEnumerator, eMultimedia, eRender,
};
use windows::Win32::System::Com::{
    COINIT_MULTITHREADED, CLSCTX_ALL, CoCreateInstance, CoInitializeEx, CoUninitialize,
};

use super::VolumeUpdate;

/// Menyalakan thread layanan volume. `sink` dipanggil dari thread layanan setiap ada perubahan
/// volume (termasuk sekali saat start untuk nilai awal).
pub fn spawn(sink: impl Fn(VolumeUpdate) + Send + 'static) {
    let spawned = thread::Builder::new()
        .name("dumm-volume".into())
        .spawn(move || {
            if let Err(error) = run(&sink) {
                eprintln!("[dumm] layanan volume berhenti: {error}");
            }
        });
    if let Err(error) = spawned {
        eprintln!("[dumm] thread layanan volume gagal dibuat: {error}");
    }
}

/// Melepas apartemen COM saat thread layanan selesai. Dideklarasikan sebelum objek COM lain agar
/// di-drop paling akhir (setelah `endpoint` dan `callback`).
struct Apartment;

impl Drop for Apartment {
    fn drop(&mut self) {
        // SAFETY: hanya dibuat setelah CoInitializeEx sukses di thread yang sama, dan semua objek
        // COM di thread ini sudah di-drop lebih dulu (urutan deklarasi di `run`).
        unsafe { CoUninitialize() };
    }
}

#[implement(IAudioEndpointVolumeCallback)]
struct VolumeCallback {
    tx: mpsc::Sender<VolumeUpdate>,
}

impl IAudioEndpointVolumeCallback_Impl for VolumeCallback_Impl {
    fn OnNotify(&self, pnotify: *mut AUDIO_VOLUME_NOTIFICATION_DATA) -> Result<()> {
        // SAFETY: COM menjamin pnotify berlaku selama callback; null diperiksa.
        if let Some(data) = unsafe { pnotify.as_ref() } {
            let _ = self.tx.send(VolumeUpdate {
                level: data.fMasterVolume,
                muted: data.bMuted.as_bool(),
            });
        }
        Ok(())
    }
}

fn run(sink: &impl Fn(VolumeUpdate)) -> Result<()> {
    // SAFETY: dipanggil sekali di awal thread baru, sebelum objek COM apa pun dibuat. S_FALSE
    // berarti MTA sudah aktif di thread ini, bukan error, maka .ok() diabaikan.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED).ok();
    }
    let _apartment = Apartment;

    // SAFETY: COM MTA aktif; MMDeviceEnumerator adalah CLSID dan antarmuka yang valid di Windows.
    let enumerator: IMMDeviceEnumerator = unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)? };
    // SAFETY: enumerator valid; endpoint render default diminta secara read-only.
    let device = unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia)? };
    // SAFETY: device valid; tipe antarmuka yang diminta benar.
    let endpoint: IAudioEndpointVolume = unsafe { device.Activate(CLSCTX_ALL, None)? };

    // SAFETY: endpoint valid; nilai scalar dan mute dibaca untuk laporan awal.
    let (level, muted) = unsafe { (endpoint.GetMasterVolumeLevelScalar()?, endpoint.GetMute()?.as_bool()) };
    sink(VolumeUpdate { level, muted });

    // Callback berlangganan; hidup selama endpoint masih terdaftar.
    let (tx, rx) = mpsc::channel();
    let callback: IAudioEndpointVolumeCallback = VolumeCallback { tx }.into();
    // SAFETY: callback hidup selama langganan aktif.
    unsafe { endpoint.RegisterControlChangeNotify(&callback)? };

    // Blocking: thread tidur sampai COM memanggil OnNotify. Tidak ada polling.
    for update in &rx {
        sink(update);
    }

    // SAFETY: callback yang terdaftar dilepas dari endpoint yang sama sebelum drop.
    unsafe { endpoint.UnregisterControlChangeNotify(&callback) }
}
