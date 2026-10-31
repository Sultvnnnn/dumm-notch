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
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
};
use windows::Win32::System::WinRT::{RO_INIT_MULTITHREADED, RoInitialize, RoUninitialize};

use super::{Artwork, MediaUpdate, ServiceCommand};
use windows::Storage::Streams::DataReader;
use windows::Win32::Graphics::Imaging::*;
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};

pub enum Signal {
    SessionChanged,
    PropertiesChanged,
    PlaybackChanged,
    Command(ServiceCommand),
}

/// Menyalakan thread layanan media. `sink` dipanggil dari thread layanan setiap ada perubahan.
/// Bila layanan gagal atau berhenti, `sink` menerima `has_session: false` sebagai pesan terakhir.
pub fn spawn(sink: impl Fn(MediaUpdate) + Send + 'static) -> mpsc::Sender<Signal> {
    let (tx, rx) = mpsc::channel();
    let worker_tx = tx.clone();
    let spawned = thread::Builder::new()
        .name("dumm-media".into())
        .spawn(move || {
            if let Err(error) = run(&sink, worker_tx, rx) {
                eprintln!("[dumm] layanan media berhenti: {error}");
            }
            sink(MediaUpdate::default());
        });
    if let Err(error) = spawned {
        eprintln!("[dumm] thread layanan media gagal dibuat: {error}");
    }
    tx
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

fn run(sink: &impl Fn(MediaUpdate), tx: mpsc::Sender<Signal>, rx: mpsc::Receiver<Signal>) -> windows::core::Result<()> {
    // SAFETY: dipanggil sekali di awal thread baru, sebelum objek WinRT apa pun dibuat.
    unsafe { RoInitialize(RO_INIT_MULTITHREADED)? };
    let _apartment = Apartment;

    let manager = Manager::RequestAsync()?.get()?;

    let session_tx = tx.clone();
    let session_token = manager.CurrentSessionChanged(&TypedEventHandler::new(move |_, _| {
        // Gagal kirim hanya terjadi bila thread layanan sudah selesai; tidak ada yang perlu diberi tahu.
        let _ = session_tx.send(Signal::SessionChanged);
        Ok(())
    }))?;

    let mut watched = watch_current(&manager, &tx, None);
    let mut state = MediaState::default();
    send_snapshot(&sink, watched.as_ref(), &mut state);

    // Blocking: thread tidur sampai WinRT mengirim sinyal. `tx` tetap hidup di sini,
    // jadi loop hanya berakhir bersama proses.
    for signal in &rx {
        if let Signal::Command(command) = signal {
            if let Some((session, _, _)) = watched.as_ref() {
                // Jangan kendalikan sesi lama setelah sesi aktif berubah.
                if manager.GetCurrentSession().is_ok_and(|current| current == *session) {
                    let result = match command {
                        ServiceCommand::TogglePlayPause => session.TryTogglePlayPauseAsync(),
                        ServiceCommand::Next => session.TrySkipNextAsync(),
                        ServiceCommand::Previous => session.TrySkipPreviousAsync(),
                    }.and_then(|op| op.get());
                    match result {
                        Ok(true) => {},
                        Ok(false) => send_snapshot(&sink, watched.as_ref(), &mut state),
                        Err(error) => eprintln!("[dumm] perintah media gagal: {error}"),
                    }
                }
            }
            continue;
        }
        if matches!(signal, Signal::SessionChanged) {
            watched = watch_current(&manager, &tx, watched);
        }
        send_snapshot(&sink, watched.as_ref(), &mut state);
    }

    manager.RemoveCurrentSessionChanged(session_token)
}

/// Melepas langganan sesi lama dan berlangganan `MediaPropertiesChanged` pada sesi aktif.
/// Tidak ada sesi aktif (`GetCurrentSession` gagal) berarti `None`, bukan error.
fn watch_current(
    manager: &Manager,
    tx: &mpsc::Sender<Signal>,
    previous: Option<(Session, EventRegistrationToken, EventRegistrationToken)>,
) -> Option<(Session, EventRegistrationToken, EventRegistrationToken)> {
    if let Some((session, token, playback_token)) = previous {
        // Sesi lama bisa sudah hilang bersama pemutarnya; gagal melepas tidak mengubah apa pun.
        let _ = session.RemoveMediaPropertiesChanged(token);
        let _ = session.RemovePlaybackInfoChanged(playback_token);
    }

    let session = manager.GetCurrentSession().ok()?;
    let playback_tx = tx.clone();
    let tx = tx.clone();
    let handler = TypedEventHandler::new(move |_, _| {
        let _ = tx.send(Signal::PropertiesChanged);
        Ok(())
    });
    match session.MediaPropertiesChanged(&handler) {
        Ok(token) => match session.PlaybackInfoChanged(&TypedEventHandler::new(move |_, _| {
            let _ = playback_tx.send(Signal::PlaybackChanged);
            Ok(())
        })) {
            Ok(playback_token) => Some((session, token, playback_token)),
            Err(error) => {
                let _ = session.RemoveMediaPropertiesChanged(token);
                eprintln!("[dumm] langganan PlaybackInfoChanged gagal: {error}");
                None
            }
        },
        Err(error) => {
            eprintln!("[dumm] langganan MediaPropertiesChanged gagal: {error}");
            None
        }
    }
}

/// State decode artwork yang dipakai lintas event (F1: kunci pada identitas trek).
#[derive(Default)]
struct MediaState {
    /// (judul, artis) trek yang sedang ditampilkan.
    last_key: Option<(String, String)>,
    /// Artwork valid terakhir; None bila belum pernah sukses.
    last_artwork: Option<Artwork>,
    /// Sudah disimpulkan untuk `last_key` (sukses atau menyerah) — mencegah re-decode
    /// pada event berikutnya untuk trek yang sama (F3: retry hanya sekali per trek).
    settled: bool,
}

fn snapshot(watched: Option<&(Session, EventRegistrationToken, EventRegistrationToken)>, state: &mut MediaState) -> MediaUpdate {
    let Some((session, _, _)) = watched else {
        // Sesi hilang: kosongkan artwork dan tandai berubah agar UI membersihkan gambar.
        state.last_key = None;
        state.last_artwork = None;
        state.settled = false;
        let mut update = debug_log(MediaUpdate::default());
        update.artwork_changed = true;
        return update;
    };

    let update = match session.TryGetMediaPropertiesAsync().and_then(|op| op.get()) {
        Ok(props) => {
            let title = props.Title().unwrap_or_default().to_string_lossy();
            let artist = props.Artist().unwrap_or_default().to_string_lossy();
            let key = (title.clone(), artist.clone());
            let key_same = state.last_key.as_ref() == Some(&key);
            let is_playing = session.GetPlaybackInfo()
                .and_then(|info| info.PlaybackStatus())
                .is_ok_and(|status| status == PlaybackStatus::Playing);

            // F1: decode hanya bila key berubah atau artwork belum pernah ada / belum
            // disimpulkan untuk trek ini. Event lain (PlaybackChanged, penolakan perintah,
            // PlaybackInfoChanged) tidak memicu decode.
            let need_decode = !key_same || !state.settled;

            let (artwork, artwork_changed) = if !need_decode {
                (state.last_artwork.clone(), false)
            } else {
                match fetch_artwork(&props) {
                    Some(art) => {
                        state.last_key = Some(key.clone());
                        state.last_artwork = Some(art.clone());
                        state.settled = true;
                        (Some(art), true)
                    }
                    None => {
                        if key_same {
                            // F2: key sama, decode gagal → pertahankan artwork terakhir,
                            // tanpa tanda berubah. Simpulkan agar tidak mencoba lagi.
                            state.settled = true;
                            (state.last_artwork.clone(), false)
                        } else {
                            // F2: key berubah, decode gagal → trek baru memang tidak punya artwork.
                            state.last_key = Some(key.clone());
                            state.last_artwork = None;
                            state.settled = true;
                            (None, true)
                        }
                    }
                }
            };

            MediaUpdate {
                title,
                artist,
                has_session: true,
                is_playing,
                artwork,
                artwork_changed,
            }
        }
        Err(error) => {
            eprintln!("[dumm] properti media gagal dibaca: {error}");
            // Properti tidak terbaca: jangan mengubah artwork yang sedang tampil.
            MediaUpdate { has_session: true, ..MediaUpdate::default() }
        }
    };
    debug_log(update)
}

fn send_snapshot(sink: &impl Fn(MediaUpdate), watched: Option<&(Session, EventRegistrationToken, EventRegistrationToken)>, state: &mut MediaState) {
    sink(snapshot(watched, state));
}

/// Hasil decode artwork.
enum ArtworkDecode {
    Ok(Artwork),
    /// Belum tersedia (thumbnail null / ukuran 0) — sah dicoba ulang.
    Pending,
    /// Kegagalan permanen.
    Failed(windows::core::Error),
}

/// Mencoba mengambil artwork, dengan retry terbatas untuk kasus "belum tersedia"
/// (F3/F4). Retry memakai `std::thread::sleep` (bounded, 3×200 ms, sekali per trek),
/// bukan timer maupun loop tak terbatas.
fn fetch_artwork(props: &windows::Media::Control::GlobalSystemMediaTransportControlsSessionMediaProperties) -> Option<Artwork> {
    let mut retries = 0;
    loop {
        match decode_artwork(props) {
            ArtworkDecode::Ok(art) => return Some(art),
            ArtworkDecode::Failed(_error) => {
                #[cfg(debug_assertions)]
                eprintln!("[dumm] artwork gagal permanen: {_error}");
                return None;
            }
            ArtworkDecode::Pending => {
                if retries >= 3 {
                    #[cfg(debug_assertions)]
                    eprintln!("[dumm] artwork belum tersedia, menyerah setelah {retries} retry");
                    return None;
                }
                retries += 1;
                #[cfg(debug_assertions)]
                eprintln!("[dumm] artwork belum tersedia, retry {retries}/3");
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        }
    }
}

/// F3: `Error::empty()` (HRESULT 0) dipetakan windows saat properti COM bernilai null
/// (Thumbnail null, OpenReadAsync null). Perlakukan itu sebagai "belum tersedia" (Pending);
/// error lain adalah kegagalan nyata.
fn classify_artwork_error(error: &windows::core::Error) -> ArtworkDecode {
    if error.code() == windows::core::HRESULT(0) {
        ArtworkDecode::Pending
    } else {
        ArtworkDecode::Failed(error.clone())
    }
}

fn decode_artwork(props: &windows::Media::Control::GlobalSystemMediaTransportControlsSessionMediaProperties) -> ArtworkDecode {
    match props.Thumbnail() {
        Ok(thumb) => {
            match thumb.OpenReadAsync().and_then(|op| op.get()) {
                Ok(stream) => {
                    let size = match stream.Size() {
                        Ok(size) => size,
                        Err(error) => return classify_artwork_error(&error),
                    };
                    if size == 0 {
                        return ArtworkDecode::Pending;
                    }
                    if size > 20_000_000 {
                        return ArtworkDecode::Failed(windows::core::Error::from(windows::core::HRESULT(0x80070057u32 as i32)));
                    }
                    let reader = match DataReader::CreateDataReader(&stream) {
                        Ok(reader) => reader,
                        Err(error) => return ArtworkDecode::Failed(error),
                    };
                    let loaded = match reader.LoadAsync(size as u32).and_then(|op| op.get()) {
                        Ok(loaded) => loaded,
                        Err(error) => return ArtworkDecode::Failed(error),
                    };
                    let mut bytes = vec![0; loaded as usize];
                    if let Err(error) = reader.ReadBytes(&mut bytes) {
                        return ArtworkDecode::Failed(error);
                    }
                    let decoded = (|| -> windows::core::Result<Artwork> {
                        // SAFETY: WinRT MTA aktif pada thread layanan, dan bytes tetap hidup selama WIC membaca stream.
                        unsafe {
                            let factory: IWICImagingFactory = CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
                            let input = factory.CreateStream()?;
                            input.InitializeFromMemory(&bytes)?;
                            let decoder = factory.CreateDecoderFromStream(&input, std::ptr::null(), WICDecodeMetadataCacheOnLoad)?;
                            let frame = decoder.GetFrame(0)?;
                            let converter = factory.CreateFormatConverter()?;
                            converter.Initialize(&frame, &GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, None, 0.0, WICBitmapPaletteTypeCustom)?;
                            let scaler = factory.CreateBitmapScaler()?;
                            scaler.Initialize(&converter, 40, 40, WICBitmapInterpolationModeFant)?;
                            // Scaler tidak menjamin format keluaran: di pipeline ini ia
                            // mengembalikan BGRA (terukur lewat artwork kontrol, R dan B
                            // tertukar). Konversi sekali lagi tepat sebelum CopyPixels supaya
                            // byte yang dibaca benar-benar RGBA.
                            let out = factory.CreateFormatConverter()?;
                            out.Initialize(&scaler, &GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, None, 0.0, WICBitmapPaletteTypeCustom)?;
                            let mut rgba = vec![0; 40 * 40 * 4];
                            out.CopyPixels(std::ptr::null(), 160, &mut rgba)?;
                            Ok(Artwork { width: 40, height: 40, rgba })
                        }
                    })();
                    match decoded {
                        Ok(art) => ArtworkDecode::Ok(art),
                        Err(error) => ArtworkDecode::Failed(error),
                    }
                }
                Err(error) => classify_artwork_error(&error),
            }
        }
        Err(error) => classify_artwork_error(&error),
    }
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
            "[dumm] media epoch_ms={ms} has_session={} title=\"{}\" artist=\"{}\" is_playing={}",
            update.has_session, update.title, update.artist, update.is_playing
        );
    }
    update
}
