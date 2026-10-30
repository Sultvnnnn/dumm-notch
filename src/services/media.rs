//! Metadata media GSMTC (read-only): judul dan artis sesi aktif.
//!
//! Satu thread layanan. Handler WinRT (`CurrentSessionChanged`, `MediaPropertiesChanged`)
//! berjalan di thread milik WinRT dan hanya mengirim sinyal lewat `mpsc`; pembacaan properti
//! dan pengiriman ke UI terjadi di thread layanan. Thread menunggu sinyal secara blocking,
//! tanpa timer dan tanpa polling.

use std::sync::mpsc;
use std::thread;

use windows::Foundation::{EventRegistrationToken, TypedEventHandler};
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session,
    GlobalSystemMediaTransportControlsSessionManager as Manager,
};
use windows::Win32::System::WinRT::{RO_INIT_MULTITHREADED, RoInitialize, RoUninitialize};

use super::MediaUpdate;

enum Signal {
    SessionChanged,
    PropertiesChanged,
}

/// Menyalakan thread layanan media. `sink` dipanggil dari thread layanan setiap ada perubahan.
/// Bila layanan gagal atau berhenti, `sink` menerima `has_session: false` sebagai pesan terakhir.
pub fn spawn(sink: impl Fn(MediaUpdate) + Send + 'static) {
    let spawned = thread::Builder::new()
        .name("dumm-media".into())
        .spawn(move || {
            if let Err(error) = run(&sink) {
                eprintln!("[dumm] layanan media berhenti: {error}");
            }
            sink(MediaUpdate::default());
        });
    if let Err(error) = spawned {
        eprintln!("[dumm] thread layanan media gagal dibuat: {error}");
    }
}

/// Melepas apartemen WinRT saat thread layanan selesai. Dideklarasikan sebelum objek WinRT
/// lain agar di-drop paling akhir.
struct Apartment;

impl Drop for Apartment {
    fn drop(&mut self) {
        // SAFETY: hanya dibuat setelah RoInitialize sukses di thread yang sama, dan semua
        // objek WinRT di thread ini sudah di-drop lebih dulu (urutan deklarasi di `run`).
        unsafe { RoUninitialize() };
    }
}

fn run(sink: &impl Fn(MediaUpdate)) -> windows::core::Result<()> {
    // SAFETY: dipanggil sekali di awal thread baru, sebelum objek WinRT apa pun dibuat.
    unsafe { RoInitialize(RO_INIT_MULTITHREADED)? };
    let _apartment = Apartment;

    let manager = Manager::RequestAsync()?.get()?;
    let (tx, rx) = mpsc::channel();

    let session_tx = tx.clone();
    let session_token = manager.CurrentSessionChanged(&TypedEventHandler::new(move |_, _| {
        // Gagal kirim hanya terjadi bila thread layanan sudah selesai; tidak ada yang perlu diberi tahu.
        let _ = session_tx.send(Signal::SessionChanged);
        Ok(())
    }))?;

    let mut watched = watch_current(&manager, &tx, None);
    sink(snapshot(watched.as_ref()));

    // Blocking: thread tidur sampai WinRT mengirim sinyal. `tx` tetap hidup di sini,
    // jadi loop hanya berakhir bersama proses.
    for signal in &rx {
        if matches!(signal, Signal::SessionChanged) {
            watched = watch_current(&manager, &tx, watched);
        }
        sink(snapshot(watched.as_ref()));
    }

    manager.RemoveCurrentSessionChanged(session_token)
}

/// Melepas langganan sesi lama dan berlangganan `MediaPropertiesChanged` pada sesi aktif.
/// Tidak ada sesi aktif (`GetCurrentSession` gagal) berarti `None`, bukan error.
fn watch_current(
    manager: &Manager,
    tx: &mpsc::Sender<Signal>,
    previous: Option<(Session, EventRegistrationToken)>,
) -> Option<(Session, EventRegistrationToken)> {
    if let Some((session, token)) = previous {
        // Sesi lama bisa sudah hilang bersama pemutarnya; gagal melepas tidak mengubah apa pun.
        let _ = session.RemoveMediaPropertiesChanged(token);
    }

    let session = manager.GetCurrentSession().ok()?;
    let tx = tx.clone();
    let handler = TypedEventHandler::new(move |_, _| {
        let _ = tx.send(Signal::PropertiesChanged);
        Ok(())
    });
    match session.MediaPropertiesChanged(&handler) {
        Ok(token) => Some((session, token)),
        Err(error) => {
            eprintln!("[dumm] langganan MediaPropertiesChanged gagal: {error}");
            None
        }
    }
}

fn snapshot(watched: Option<&(Session, EventRegistrationToken)>) -> MediaUpdate {
    let Some((session, _)) = watched else {
        return debug_log(MediaUpdate::default());
    };
    let update = match session.TryGetMediaPropertiesAsync().and_then(|op| op.get()) {
        Ok(props) => MediaUpdate {
            title: props.Title().unwrap_or_default().to_string_lossy(),
            artist: props.Artist().unwrap_or_default().to_string_lossy(),
            has_session: true,
        },
        Err(error) => {
            eprintln!("[dumm] properti media gagal dibaca: {error}");
            MediaUpdate { has_session: true, ..MediaUpdate::default() }
        }
    };
    debug_log(update)
}

/// Build debug: cetak waktu dan isi pesan agar jeda callback bisa diverifikasi dari output.
fn debug_log(update: MediaUpdate) -> MediaUpdate {
    #[cfg(debug_assertions)]
    {
        let ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or_default();
        eprintln!(
            "[dumm] media epoch_ms={ms} has_session={} title=\"{}\" artist=\"{}\"",
            update.has_session, update.title, update.artist
        );
    }
    update
}
