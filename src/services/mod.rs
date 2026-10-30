//! Layanan latar. Modul di sini tidak mengimpor tipe Slint; data keluar lewat pesan biasa
//! dan `main.rs` yang memetakannya ke properti UI.

pub mod media;

/// Status media sesi aktif. `has_session == false` berarti tidak ada sesi atau layanan mati.
#[derive(Default)]
pub struct MediaUpdate {
    pub title: String,
    pub artist: String,
    pub has_session: bool,
}
