//! Ce que les anciennes versions ont laissé sur le disque (donnees.ps1:40-56 et 65-84) :
//! - les fichiers des premières versions, à la racine de `%LOCALAPPDATA%\Mindset` ou dans `%LOCALAPPDATA%\Mindset\Mindset`
//!   alors que Mindset est installé sur un autre disque : déplacés dans le vrai dossier de données, s'il n'en a pas
//!   déjà un ;
//! - le journal des plantages de Mindset.exe (jusqu'à la 2.8.0), toujours dans `%LOCALAPPDATA%\Mindset\Mindset` : ses
//!   lignes rejoignent le vrai journal, puis il est supprimé ;
//! - l'ancien dossier WebView2 de la console (`console-webview`, environ 75 Mo) : supprimé quand il n'a pas servi
//!   depuis 14 jours (renommé d'abord d'un bloc : un WebView2 encore ouvert dessus fait échouer le renommage sans rien
//!   toucher).

use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use mindset_noyau::moment::{self, HeureLocale};
use suite_commun::chemins::egal;

/// Les fichiers repris des premières versions.
pub const ANCIENS_FICHIERS: [&str; 3] = ["journal.txt", "reglages.json", "installations.json"];

fn texte(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// `Move-Item -LiteralPath $a -Destination $dossier` : renommé, ou copié puis effacé s'il change de disque.
pub fn deplacer(a: &Path, b: &Path) -> std::io::Result<()> {
    match std::fs::rename(a, b) {
        Ok(()) => Ok(()),
        Err(e) if a.is_file() => {
            // (ERROR_NOT_SAME_DEVICE, 17 : un autre disque)
            if e.raw_os_error() != Some(17) {
                return Err(e);
            }
            std::fs::copy(a, b)?;
            if let Err(e) = std::fs::remove_file(a) {
                // (jamais deux copies : le prochain démarrage réessaiera)
                let _ = std::fs::remove_file(b);
                return Err(e);
            }
            Ok(())
        }
        Err(e) => Err(e),
    }
}

/// Les fichiers des premières versions (donnees.ps1:40-46), déplacés dans `donnees` s'il ne les a pas déjà.
pub fn reprendre_anciens_fichiers(local_mindset: &Path, donnees: &Path) {
    for n in ANCIENS_FICHIERS {
        for a in [local_mindset.join(n), local_mindset.join("Mindset").join(n)] {
            let b = donnees.join(n);
            if !egal(&texte(&a), &texte(&b)) && a.exists() && !b.exists() {
                let _ = deplacer(&a, &b);
            }
        }
    }
}

/// Le journal de Mindset.exe jusqu'à la 2.8.0 (donnees.ps1:47-56) : ses lignes rejoignent le vrai journal (à la fin,
/// telles quelles, après une ligne datée), puis l'ancien fichier est supprimé.
pub fn reprendre_ancien_journal(local_mindset: &Path, donnees: &Path, maintenant: &HeureLocale) {
    let ancien = local_mindset.join("Mindset").join("journal.txt");
    let journal = donnees.join("journal.txt");
    if egal(&texte(&ancien), &texte(&journal)) || !ancien.exists() || !journal.exists() {
        return;
    }
    let Ok(octets) = std::fs::read(&ancien) else { return };
    let t = suite_commun::json_sur::texte_du_fichier(&octets);
    if !t.trim().is_empty() {
        use std::io::Write;
        let ligne = format!(
            "{} Lignes reprises de l'ancien journal de Mindset.exe ({}) :\r\n{}\r\n",
            moment::iso(maintenant),
            ancien.display(),
            t.trim_end()
        );
        let ecrit =
            std::fs::OpenOptions::new().append(true).open(&journal).and_then(|mut f| f.write_all(ligne.as_bytes()));
        if ecrit.is_err() {
            return;
        }
    }
    let _ = std::fs::remove_file(&ancien);
}

/// La date la plus récente d'un dossier et de tous ses fichiers (sans suivre les liens).
fn derniere_date(dossier: &Path) -> std::io::Result<SystemTime> {
    let mut dernier = std::fs::metadata(dossier)?.modified()?;
    let mut a_voir = vec![dossier.to_path_buf()];
    while let Some(d) = a_voir.pop() {
        for e in std::fs::read_dir(&d)? {
            let e = e?;
            let m = e.metadata()?;
            if m.is_dir() {
                a_voir.push(e.path());
            } else if m.is_file() {
                let t = m.modified()?;
                if t > dernier {
                    dernier = t;
                }
            }
        }
    }
    Ok(dernier)
}

/// Les secondes depuis 1970 d'un moment du PC.
fn secondes_unix(t: SystemTime) -> i64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64,
        Err(e) => -(e.duration().as_secs() as i64),
    }
}

/// La date locale d'un moment du PC au format court français (`ToString('d')` : « 18/10/2026 »).
pub fn date_courte(t: SystemTime, maintenant_local: &HeureLocale, maintenant: SystemTime) -> String {
    let decalage = moment::secondes(maintenant_local) - secondes_unix(maintenant);
    let h = moment::depuis_secondes(secondes_unix(t) + decalage);
    format!("{:02}/{:02}/{:04}", h.jour, h.mois, h.annee)
}

/// `Clear-RestesDisque` (donnees.ps1:69-83) : l'ancien `console-webview`, s'il n'a pas servi depuis `jours` jours.
pub fn nettoyer_restes(dossier: &Path, jours: u64, maintenant_local: &HeureLocale, journal: &dyn Fn(&str)) {
    let vieux = dossier.join("console-webview.a-supprimer");
    let cw = dossier.join("console-webview");
    let maintenant = SystemTime::now();
    if cw.is_dir()
        && let Ok(dernier) = derniere_date(&cw)
        && maintenant.checked_sub(Duration::from_secs(jours * 86_400)).is_some_and(|limite| dernier < limite)
        && !vieux.is_dir()
        && std::fs::rename(&cw, &vieux).is_ok()
    {
        journal(&format!(
            "Ancien dossier console-webview (pas servi depuis le {}) supprimé",
            date_courte(dernier, maintenant_local, maintenant)
        ));
    }
    if vieux.is_dir() {
        let _ = std::fs::remove_dir_all(&vieux);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn date_au_format_court() {
        let local = moment::lire_iso("2026-11-07T20:00:00").unwrap();
        let maintenant = UNIX_EPOCH + Duration::from_secs(1_794_078_000); // (07/11/2026 19:00 UTC)
        let il_y_a_20_jours = maintenant - Duration::from_secs(20 * 86_400);
        assert_eq!(date_courte(il_y_a_20_jours, &local, maintenant), "18/10/2026");
    }
}
