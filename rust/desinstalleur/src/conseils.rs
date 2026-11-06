//! Les conseils laissés par le désinstalleur d'une appli (docs\contrat-appli.md, partie 9) : lancé avec une option, il
//! ne montre pas sa fenêtre de fin ; ce qu'il aurait dit d'important (« Redémarre le PC... ») est écrit, juste avant
//! qu'il rende la main, dans `<dossier des données de la suite>\<Nom>.conseils-desinstallation.txt`, et ce désinstalleur
//! le reprend dans son bilan.
//!
//! Le fichier vient d'un dossier modifiable par l'utilisateur : il n'est jamais lu au travers d'un lien (lien
//! symbolique, point de jonction), jamais au-delà de 8 Ko, et il doit être en UTF-8. Au plus 10 lignes de 300
//! caractères ; sans lignes vides ni caractères de contrôle. Tout ce qui ne va pas : rien n'est pris, sans erreur.

use std::io::Read;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// La fin du nom du fichier, après le nom de l'appli
pub const SUFFIXE: &str = ".conseils-desinstallation.txt";
/// La taille la plus grande acceptée (au-delà : fichier ignoré)
pub const TAILLE_MAX: u64 = 8 * 1024;
/// Le nombre de lignes et de caractères par ligne gardés (au-delà : coupé)
pub const LIGNES_MAX: usize = 10;
pub const CARACTERES_MAX: usize = 300;

const LIEN: u32 = 0x400; // FILE_ATTRIBUTE_REPARSE_POINT
const DOSSIER: u32 = 0x10;
const OUVRIR_LE_LIEN: u32 = 0x0020_0000; // FILE_FLAG_OPEN_REPARSE_POINT : ouvre le lien lui-même, sans le suivre

/// Le fichier des conseils d'une appli dans un dossier des données de la suite
pub fn fichier(racine_donnees: &Path, appli: &str) -> PathBuf {
    racine_donnees.join(format!("{appli}{SUFFIXE}"))
}

/// Retire le fichier (ou le lien lui-même, jamais ce vers quoi il pointe) ; false s'il est resté
pub fn effacer(f: &Path) -> bool {
    let Ok(m) = std::fs::symlink_metadata(f) else { return true };
    let a = m.file_attributes();
    if a & DOSSIER != 0 {
        // (un dossier ordinaire de ce nom n'est pas à nous : seulement un lien vers un dossier est retiré)
        return a & LIEN == 0 || std::fs::remove_dir(f).is_ok();
    }
    if m.permissions().readonly() && a & LIEN == 0 {
        let mut p = m.permissions();
        #[allow(clippy::permissions_set_readonly_false)] // (Windows : seulement l'attribut « lecture seule »)
        p.set_readonly(false);
        let _ = std::fs::set_permissions(f, p);
    }
    std::fs::remove_file(f).is_ok()
}

/// Lit le fichier des conseils : ses lignes gardées, ou None (absent, lien, trop gros, illisible, pas en UTF-8)
pub fn lire(f: &Path) -> Option<Vec<String>> {
    let m = std::fs::symlink_metadata(f).ok()?;
    if m.file_attributes() & (LIEN | DOSSIER) != 0 || m.len() > TAILLE_MAX {
        return None;
    }
    // Ouvert sans suivre un lien (il a pu être remplacé entre-temps), et vérifié une fois ouvert
    let mut fic = std::fs::OpenOptions::new().read(true).custom_flags(OUVRIR_LE_LIEN).open(f).ok()?;
    let m = fic.metadata().ok()?;
    if m.file_attributes() & (LIEN | DOSSIER) != 0 || m.len() > TAILLE_MAX {
        return None;
    }
    let mut octets = Vec::new();
    (&mut fic).take(TAILLE_MAX + 1).read_to_end(&mut octets).ok()?;
    if octets.len() as u64 > TAILLE_MAX {
        return None;
    }
    let texte = std::str::from_utf8(octets.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&octets)).ok()?;
    Some(lignes(texte))
}

/// Un caractère qui ne s'affiche pas (contrôle, sens d'écriture, espace sans largeur) : retiré
fn invisible(c: char) -> bool {
    c.is_control()
        || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{206F}' | '\u{FEFF}')
}

/// Les lignes gardées d'un texte : nettoyées, sans lignes vides ni doublons, coupées à 300 caractères, 10 au plus
pub fn lignes(texte: &str) -> Vec<String> {
    let mut r: Vec<String> = Vec::new();
    for l in texte.split('\n') {
        let propre: String = l.chars().map(|c| if c == '\t' { ' ' } else { c }).filter(|c| !invisible(*c)).collect();
        let propre: String = propre.trim().chars().take(CARACTERES_MAX).collect();
        let propre = propre.trim_end().to_string();
        if propre.is_empty() || r.contains(&propre) {
            continue;
        }
        r.push(propre);
        if r.len() == LIGNES_MAX {
            break;
        }
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lignes_nettoyees() {
        let t = "\u{feff}  Un\r\n\r\n\tDeux\u{7}\u{202E} \r\nUn\n   \n";
        assert_eq!(lignes(t), vec!["Un", "Deux"]);
        let longue = "é".repeat(400);
        assert_eq!(lignes(&longue)[0].chars().count(), CARACTERES_MAX);
        let beaucoup: String = (0..20).map(|i| format!("Ligne {i}\n")).collect();
        let l = lignes(&beaucoup);
        assert_eq!(l.len(), LIGNES_MAX);
        assert_eq!(l[9], "Ligne 9");
        assert!(lignes("").is_empty() && lignes("\r\n \u{0}\r\n").is_empty());
    }
}
