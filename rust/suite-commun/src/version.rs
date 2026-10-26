//! Numéros de version, comparés comme `[version]` de .NET, et lus comme Mindset les lit aujourd'hui
//! (la ligne `$AppVersion = 'x.y.z'` d'un script de fichiers\), ou dans `version.json` (plan, section 3.4).

use std::cmp::Ordering;
use std::path::Path;

use crate::texte::{SansMarque, decoder_fichier, lignes};

/// Une version au sens de .NET (`System.Version`) : 2 à 4 nombres ; un nombre absent vaut -1, donc
/// « 2.1 » est plus ancienne que « 2.1.0 ».
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version([i64; 4]);

impl Version {
    /// Lit « 2.1.0 » ; `None` si ce n'est pas 2 à 4 nombres de 0 à 2147483647 séparés par des points.
    pub fn lire(texte: &str) -> Option<Version> {
        let morceaux: Vec<&str> = texte.split('.').collect();
        if !(2..=4).contains(&morceaux.len()) {
            return None;
        }
        let mut v = [-1i64; 4];
        for (i, m) in morceaux.iter().enumerate() {
            if m.is_empty() || !m.bytes().all(|o| o.is_ascii_digit()) {
                return None;
            }
            v[i] = i64::from(m.parse::<i32>().ok()?);
        }
        Some(Version(v))
    }
}

/// Comme `Test-VersionPlusRecente` : vrai si `a` est strictement plus récente que `b` ; faux si l'une des deux
/// est illisible (comme le `catch` de la version PowerShell).
pub fn plus_recente(a: &str, b: &str) -> bool {
    match (Version::lire(a), Version::lire(b)) {
        (Some(a), Some(b)) => a.cmp(&b) == Ordering::Greater,
        _ => false,
    }
}

/// Vrai pour « 1.2 », « 1.2.3 », « 1.2.3.4 » (chiffres ASCII seulement) : la forme `\d+(\.\d+){1,3}`.
pub fn forme_valide(texte: &str) -> bool {
    let morceaux: Vec<&str> = texte.split('.').collect();
    (2..=4).contains(&morceaux.len()) && morceaux.iter().all(|m| !m.is_empty() && m.bytes().all(|o| o.is_ascii_digit()))
}

/// La version écrite sur une ligne `$AppVersion = 'x.y.z'` (majuscules indifférentes, espaces permis autour
/// du « = »), comme l'expression `^\$AppVersion\s*=\s*'(\d+(\.\d+){1,3})'` de Mindset.
pub fn version_de_ligne(ligne: &str) -> Option<&str> {
    let reste = ligne.strip_prefix('$')?;
    let nom = "AppVersion";
    if reste.len() < nom.len() || !reste.is_char_boundary(nom.len()) || !reste[..nom.len()].eq_ignore_ascii_case(nom) {
        return None;
    }
    let reste = reste[nom.len()..].trim_start();
    let reste = reste.strip_prefix('=')?.trim_start();
    let reste = reste.strip_prefix('\'')?;
    let fin = reste.find(|c: char| !(c.is_ascii_digit() || c == '.')).unwrap_or(reste.len());
    let version = &reste[..fin];
    (reste[fin..].starts_with('\'') && forme_valide(version)).then_some(version)
}

/// Comme `Get-VersionDossier` : la version d'une appli installée dans `dossier`, lue sur la ligne `$AppVersion`
/// des 40 premières lignes de ses scripts `fichiers\*.ps1` (dans l'ordre du disque). Vide si introuvable.
pub fn version_scripts(dossier: &Path) -> String {
    let Ok(entrees) = std::fs::read_dir(dossier.join("fichiers")) else {
        return String::new();
    };
    for entree in entrees.flatten() {
        let nom = entree.file_name().to_string_lossy().into_owned();
        let Ok(meta) = entree.metadata() else { continue };
        if !meta.is_file() || cache_ou_systeme(&meta) || !nom.to_ascii_lowercase().ends_with(".ps1") {
            continue;
        }
        let Ok(octets) = std::fs::read(entree.path()) else { continue };
        let texte = decoder_fichier(&octets, SansMarque::Ansi);
        for ligne in lignes(&texte).take(40) {
            if let Some(v) = version_de_ligne(ligne) {
                return v.to_string();
            }
        }
    }
    String::new()
}

/// `Get-ChildItem` (sans -Force) ne montre pas les fichiers cachés ni les fichiers système.
#[cfg(windows)]
fn cache_ou_systeme(meta: &std::fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    meta.file_attributes() & (0x2 | 0x4) != 0
}

#[cfg(not(windows))]
fn cache_ou_systeme(_meta: &std::fs::Metadata) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comparaison_comme_dotnet() {
        assert!(plus_recente("2.1.0", "2.0.9"));
        assert!(plus_recente("2.1.0", "2.1"));
        assert!(!plus_recente("2.1", "2.1.0"));
        assert!(!plus_recente("2.1.0", "2.1.0"));
        assert!(plus_recente("10.0", "9.9.9.9"));
        // Illisible (trop grand pour .NET) : jamais « plus récente »
        assert!(!plus_recente("99999999999.0", "1.0"));
        assert!(!plus_recente("1.0", "99999999999.0"));
    }

    #[test]
    fn ligne_appversion() {
        assert_eq!(version_de_ligne("$AppVersion = '2.14.0'"), Some("2.14.0"));
        assert_eq!(version_de_ligne("$appversion='1.2' # commentaire"), Some("1.2"));
        assert_eq!(version_de_ligne("$AppVersion\u{A0}=\t'1.2.3.4'"), Some("1.2.3.4"));
        assert_eq!(version_de_ligne(" $AppVersion = '1.2'"), None);
        assert_eq!(version_de_ligne("$AppVersion = '1'"), None);
        assert_eq!(version_de_ligne("$AppVersion = '1.2.3.4.5'"), None);
        assert_eq!(version_de_ligne("$AppVersion = 'deux'"), None);
        assert_eq!(version_de_ligne("$AppVersion = \"1.2\""), None);
        assert_eq!(version_de_ligne("$AppVersionX = '1.2'"), None);
    }
}
