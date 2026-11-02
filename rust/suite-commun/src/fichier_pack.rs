//! La lecture d'une image ou d'une police d'un thème (pack) pour l'écran d'une appli Tauri : le protocole maison
//! `pack` (docs\regles-tauri.md, règle 6). Rien ici ne dépend de Tauri : l'appli appelle [`lire`] avec le dossier du
//! pack (celui que donne [`crate::themes`]) et le nom demandé par la page ([`nom_depuis_adresse`]), et répond
//! « introuvable » à toute erreur.
//!
//! Chaque règle, dans l'ordre :
//! 1. un nom de fichier simple, comme `Test-NomFichierPack` (modules\packs.ps1:39) : ni `\`, ni `/`, ni `..`, ni `:`,
//!    80 caractères au plus, ni nom réservé de Windows ni point ou espace à la fin ([`Refus::Nom`]) ;
//! 2. une extension d'image ou de police du thème, les mêmes qu'à l'import (packs.ps1:164) ([`Refus::Extension`]) ;
//! 3. le dossier du pack est un chemin complet, `<...>\packs\<id>` avec un id du thème (packs.ps1:275-283)
//!    ([`Refus::Dossier`]) ;
//! 4. ni le dossier du pack, ni son dossier `packs`, ni le fichier ne sont un lien ou une jonction (aucun « point
//!    d'analyse » de Windows) ([`Refus::Lien`]) ;
//! 5. le chemin canonique du fichier est **directement** dans le chemin canonique du dossier du pack
//!    ([`Refus::HorsDuDossier`]) ;
//! 6. les limites de taille de l'import (packs.ps1:165) : 15 Mo pour une image, 10 Mo pour une police
//!    ([`Refus::TropLourd`]) ;
//! 7. le type est reconnu à ses premiers octets ([`Refus::Type`]) : pour une image, PNG, JPEG, GIF ou WebP, quelle
//!    que soit son extension parmi celles des images (`Get-FormatImagePack`, packs.ps1:128-136) ; pour une police,
//!    TrueType ou OpenType. Le type rendu à la page vient de ces octets, jamais de l'extension.
//!
//! Le fichier est lu en lecture seule, ouvert sans suivre un lien (et refusé si c'en est un), et sans laisser un autre
//! programme l'écrire, le remplacer ou l'effacer pendant la lecture : ce qui est vérifié est ce qui est lu.
//!
//! Plus strict que PowerShell : `Get-ReponseThemeConsole` (console.ps1:199-208) sert une police d'après son seul nom ;
//! ici, ses premiers octets doivent être ceux d'une police. Non vérifié : un lien « dur » (un second nom du même
//! fichier, sur le même disque), que la bibliothèque standard ne sait pas reconnaître ; un zip importé ne peut pas en
//! créer.

use std::fs::{File, Metadata, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::themes::{EXT_IMAGES, EXT_POLICES, nom_fichier_valable};

/// La taille maximale d'une image (comme l'import d'un thème, packs.ps1:165).
pub const TAILLE_MAX_IMAGE: u64 = 15 * 1024 * 1024;
/// La taille maximale d'une police (packs.ps1:165).
pub const TAILLE_MAX_POLICE: u64 = 10 * 1024 * 1024;

/// Un fichier du pack, prêt à servir.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FichierPack {
    pub octets: Vec<u8>,
    /// Le type à donner à la page (`Content-Type`), d'après les premiers octets.
    pub type_contenu: &'static str,
}

/// Pourquoi un fichier n'est pas servi (pour le journal ; la page reçoit toujours « introuvable »).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refus {
    Nom,
    Extension,
    Dossier,
    Introuvable,
    Lien,
    HorsDuDossier,
    TropLourd,
    Type,
    Illisible,
}

impl Refus {
    /// La raison en mots simples.
    pub fn raison(self) -> &'static str {
        match self {
            Refus::Nom => "nom de fichier refusé",
            Refus::Extension => "ce n'est ni une image ni une police du thème",
            Refus::Dossier => "dossier du thème refusé",
            Refus::Introuvable => "fichier introuvable",
            Refus::Lien => "lien ou jonction refusé",
            Refus::HorsDuDossier => "fichier hors du dossier du thème",
            Refus::TropLourd => "fichier trop lourd",
            Refus::Type => "le contenu ne correspond pas à une image ou une police",
            Refus::Illisible => "fichier illisible",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Sorte {
    Image,
    Police,
}

/// Le type d'une image d'après ses premiers octets (`Get-FormatImagePack` : 12 octets au moins).
pub fn type_image(debut: &[u8]) -> Option<&'static str> {
    if debut.len() < 12 {
        return None;
    }
    if debut.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        return Some("image/png");
    }
    if debut.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some("image/jpeg");
    }
    if debut.starts_with(b"GIF8") {
        return Some("image/gif");
    }
    if debut.starts_with(b"RIFF") && &debut[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    None
}

/// Le type d'une police d'après ses premiers octets : TrueType (`00 01 00 00` ou `true`) ou OpenType (`OTTO`).
pub fn type_police(debut: &[u8]) -> Option<&'static str> {
    if debut.len() < 12 {
        return None;
    }
    if debut.starts_with(&[0, 1, 0, 0]) || debut.starts_with(b"true") {
        return Some("font/ttf");
    }
    if debut.starts_with(b"OTTO") {
        return Some("font/otf");
    }
    None
}

/// Un id de thème (`^[a-z0-9-]{1,40}$`, packs.ps1:275).
fn id_valable(id: &str) -> bool {
    (1..=40).contains(&id.len()) && id.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

/// Un lien symbolique, une jonction, ou tout autre « point d'analyse » de Windows.
fn est_lien(m: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // FILE_ATTRIBUTE_REPARSE_POINT
        if m.file_attributes() & 0x400 != 0 {
            return true;
        }
    }
    m.file_type().is_symlink()
}

/// L'entrée elle-même (sans suivre un lien) : `Introuvable` si elle n'existe pas, `Lien` si c'en est un.
fn sans_lien(chemin: &Path) -> Result<Metadata, Refus> {
    let m = std::fs::symlink_metadata(chemin).map_err(|_| Refus::Introuvable)?;
    if est_lien(&m) { Err(Refus::Lien) } else { Ok(m) }
}

/// Le fichier canonique est-il directement dans le dossier canonique ?
fn directement_dans(dossier: &Path, fichier: &Path) -> bool {
    fichier.parent() == Some(dossier)
}

/// Ouvre le fichier en lecture seule, sans suivre un lien, sans partage d'écriture ni d'effacement.
fn ouvrir(chemin: &Path) -> std::io::Result<File> {
    let mut o = OpenOptions::new();
    o.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // FILE_FLAG_OPEN_REPARSE_POINT : le lien lui-même est ouvert (puis refusé), jamais ce vers quoi il mène
        o.custom_flags(0x0020_0000);
        // FILE_SHARE_READ seulement : personne ne l'écrit, ne le renomme ni ne l'efface pendant la lecture
        o.share_mode(0x0000_0001);
    }
    o.open(chemin)
}

/// `nom` de la page, depuis le dossier du pack `dossier_pack`, suivant les règles du module.
pub fn lire(dossier_pack: &Path, nom: &str) -> Result<FichierPack, Refus> {
    // 1. Le nom
    if !nom_fichier_valable(nom) {
        return Err(Refus::Nom);
    }
    // 2. L'extension
    let ext = nom.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).ok_or(Refus::Extension)?;
    let sorte = if EXT_IMAGES.contains(&ext.as_str()) {
        Sorte::Image
    } else if EXT_POLICES.contains(&ext.as_str()) {
        Sorte::Police
    } else {
        return Err(Refus::Extension);
    };
    // 3. Le dossier du pack : <...>\packs\<id>
    let id = dossier_pack.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let packs = dossier_pack.parent().ok_or(Refus::Dossier)?;
    let nom_packs = packs.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if !dossier_pack.is_absolute() || !id_valable(id) || !nom_packs.eq_ignore_ascii_case("packs") {
        return Err(Refus::Dossier);
    }
    // 4. Ni lien ni jonction : le dossier packs, le dossier du pack, le fichier
    if !sans_lien(packs)?.is_dir() || !sans_lien(dossier_pack)?.is_dir() {
        return Err(Refus::Dossier);
    }
    let canon_dossier = std::fs::canonicalize(dossier_pack).map_err(|_| Refus::Introuvable)?;
    let chemin: PathBuf = canon_dossier.join(nom);
    if !sans_lien(&chemin)?.is_file() {
        return Err(Refus::Introuvable);
    }
    let f = ouvrir(&chemin).map_err(|_| Refus::Illisible)?;
    let m = f.metadata().map_err(|_| Refus::Illisible)?;
    if est_lien(&m) {
        return Err(Refus::Lien);
    }
    if !m.is_file() {
        return Err(Refus::Introuvable);
    }
    // 5. Directement dans le dossier du pack (vérifié fichier ouvert : il ne peut plus être remplacé)
    let canon_fichier = std::fs::canonicalize(&chemin).map_err(|_| Refus::Introuvable)?;
    if !directement_dans(&canon_dossier, &canon_fichier) {
        return Err(Refus::HorsDuDossier);
    }
    // 6. La taille (annoncée, puis lue : jamais plus que la limite)
    let max = if sorte == Sorte::Image { TAILLE_MAX_IMAGE } else { TAILLE_MAX_POLICE };
    if m.len() > max {
        return Err(Refus::TropLourd);
    }
    let mut octets = Vec::new();
    f.take(max + 1).read_to_end(&mut octets).map_err(|_| Refus::Illisible)?;
    if octets.len() as u64 > max {
        return Err(Refus::TropLourd);
    }
    // 7. Le type, d'après les premiers octets
    let type_contenu = match sorte {
        Sorte::Image => type_image(&octets),
        Sorte::Police => type_police(&octets),
    }
    .ok_or(Refus::Type)?;
    Ok(FichierPack { octets, type_contenu })
}

/// Le nom de fichier demandé par la page, d'après le chemin de l'adresse (`/logo%20bleu.png` donne `logo bleu.png`) :
/// décodé une seule fois (`%XX` en UTF-8). `None` si le décodage échoue, ou s'il y a une requête (`?`) ou un fragment
/// (`#`). Le nom obtenu passe ensuite par toutes les règles de [`lire`].
pub fn nom_depuis_adresse(chemin: &str) -> Option<String> {
    let c = chemin.strip_prefix('/').unwrap_or(chemin);
    if c.contains(['?', '#']) {
        return None;
    }
    let o = c.as_bytes();
    let mut sortie = Vec::with_capacity(o.len());
    let mut i = 0;
    while i < o.len() {
        if o[i] == b'%' {
            let h = o.get(i + 1..i + 3).filter(|h| h.iter().all(u8::is_ascii_hexdigit))?;
            let h = std::str::from_utf8(h).ok()?;
            sortie.push(u8::from_str_radix(h, 16).ok()?);
            i += 3;
        } else {
            sortie.push(o[i]);
            i += 1;
        }
    }
    String::from_utf8(sortie).ok()
}

#[cfg(test)]
mod tests;
