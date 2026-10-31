//! Layanan latar. Modul di sini tidak mengimpor tipe Slint; data keluar lewat pesan biasa
//! dan `main.rs` yang memetakannya ke properti UI.

pub mod media;
pub mod volume;

#[derive(Clone, Copy)]
pub enum ServiceCommand {
    TogglePlayPause,
    Next,
    Previous,
}

/// Status volume endpoint default. `level` adalah scalar [0,1].
#[derive(Clone, Copy)]
pub struct VolumeUpdate {
    pub level: f32,
    pub muted: bool,
}

#[derive(Clone)]
pub struct Artwork {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Status media sesi aktif. `has_session == false` berarti tidak ada sesi atau layanan mati.
#[derive(Default)]
pub struct MediaUpdate {
    pub title: String,
    pub artist: String,
    pub has_session: bool,
    pub is_playing: bool,
    pub artwork: Option<Artwork>,
    pub artwork_changed: bool,
}
