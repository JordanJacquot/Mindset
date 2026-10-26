//! Écriture et lecture sûres des fichiers JSON de la suite, comme `Save-JsonSur` et `Read-JsonSur`
//! (Mindset\fichiers\modules\donnees.ps1).
//!
//! - Écriture : le texte va dans un fichier à côté (`.tmp`), qui remplace l'ancien d'un coup ; l'ancien reste dans
//!   `.bak`. Une coupure en pleine écriture laisse toujours un fichier entier : l'ancien ou le nouveau.
//! - Lecture : un fichier pris un instant par une autre appli est relu (3 essais) ; un fichier abîmé est mis de côté
//!   (`.abime-<date>`, jamais effacé) et remplacé par sa copie `.bak` si elle est bonne. Un fichier qu'on ne peut
//!   pas lire du tout n'est pas « abîmé » : c'est une erreur, pour que l'appelant ne reparte pas de zéro (il
//!   écraserait tout à la sauvegarde suivante).

use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};

use crate::texte::{SansMarque, decoder_fichier};

/// `<fichier><fin>` (« reglages.json » donne « reglages.json.bak »).
fn a_cote(fichier: &Path, fin: &str) -> PathBuf {
    let mut s = fichier.as_os_str().to_owned();
    s.push(fin);
    PathBuf::from(s)
}

/// Écrit `texte` dans `fichier` sans jamais laisser un fichier à moitié écrit ; l'ancien contenu reste dans
/// `<fichier>.bak`. Le remplacement est réessayé 3 fois (une appli qui lit au même moment peut le bloquer un
/// court instant). En cas d'échec, le fichier à côté est effacé et l'ancien fichier reste intact.
pub fn ecrire(fichier: &Path, texte: &str) -> io::Result<()> {
    let tmp = a_cote(fichier, ".tmp");
    let resultat = (|| {
        std::fs::write(&tmp, texte.as_bytes())?;
        let mut essai = 1;
        loop {
            match remplacer(&tmp, fichier) {
                Ok(()) => return Ok(()),
                Err(e) if essai >= 3 => return Err(e),
                Err(_) => {
                    essai += 1;
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        }
    })();
    if resultat.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    resultat
}

/// Met `tmp` à la place de `fichier`, l'ancien `fichier` devenant `fichier.bak` (comme `[IO.File]::Replace`).
/// Chaque étape est un remplacement d'un seul coup : `fichier` est toujours entier.
fn remplacer(tmp: &Path, fichier: &Path) -> io::Result<()> {
    if fichier.exists() {
        // L'ancien est d'abord copié à côté puis renommé en .bak (d'un coup), puis le nouveau prend sa place
        let bak = a_cote(fichier, ".bak");
        let bak_tmp = a_cote(fichier, ".bak.tmp");
        std::fs::copy(fichier, &bak_tmp)?;
        std::fs::rename(&bak_tmp, &bak)?;
    }
    std::fs::rename(tmp, fichier)
}

/// Le contenu d'un fichier JSON, s'il contient bien un objet ; `None` sinon (abîmé, vide, coupé en plein milieu).
fn objet(texte: &str) -> Option<Map<String, Value>> {
    match serde_json::from_str::<Value>(texte.trim_start_matches('\u{FEFF}')) {
        Ok(Value::Object(o)) => Some(o),
        _ => None,
    }
}

/// Ce qu'a donné la lecture d'un fichier.
#[derive(Debug, Default)]
pub struct Lecture {
    /// Le contenu lu (du fichier, ou de sa copie .bak) ; `None` s'il n'y a rien de bon à lire
    pub valeur: Option<Map<String, Value>>,
    /// Le texte du fichier abîmé quand rien de bon n'a pu être lu (`None` : il n'existait pas)
    pub abime: Option<String>,
    /// Ce qui s'est passé, pour le journal de l'appli
    pub journal: Vec<String>,
}

/// La date et l'heure (UTC) pour le nom d'un fichier mis de côté : « 20261026-193000 ».
fn horodatage() -> String {
    let s = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let (jours, reste) = ((s / 86_400) as i64, s % 86_400);
    // Jour julien vers date (algorithme de H. Hinnant, domaine public)
    let z = jours + 719_468;
    let ere = z.div_euclid(146_097);
    let jde = z - ere * 146_097;
    let ade = (jde - jde / 1460 + jde / 36_524 - jde / 146_096) / 365;
    let jda = jde - (365 * ade + ade / 4 - ade / 100);
    let mp = (5 * jda + 2) / 153;
    let jour = jda - (153 * mp + 2) / 5 + 1;
    let mois = if mp < 10 { mp + 3 } else { mp - 9 };
    let annee = ade + ere * 400 + i64::from(mois <= 2);
    format!("{annee:04}{mois:02}{jour:02}-{:02}{:02}{:02}", reste / 3600, reste % 3600 / 60, reste % 60)
}

/// Lit un fichier écrit par [`ecrire`]. `mettre_de_cote` : faux pour une simple lecture (un test, un aperçu) qui ne
/// doit toucher à aucun fichier.
pub fn lire(fichier: &Path, mettre_de_cote: bool) -> Result<Lecture, String> {
    let nom = fichier.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut l = Lecture::default();
    let mut texte: Option<String> = None;
    for essai in 1..=3 {
        if !fichier.exists() {
            texte = None;
            break;
        }
        match std::fs::read(fichier) {
            Err(e) => {
                if essai == 3 {
                    return Err(format!("{nom} ne peut pas être lu ({e})"));
                }
                std::thread::sleep(Duration::from_millis(50));
                continue;
            }
            Ok(o) => {
                let t = decoder_fichier(&o, SansMarque::Utf8);
                if let Some(v) = objet(&t) {
                    l.valeur = Some(v);
                    return Ok(l);
                }
                texte = Some(t);
            }
        }
        if essai < 3 {
            // (peut-être en train d'être écrit par une autre appli : on relit)
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    if let Some(t) = &texte {
        l.abime = Some(t.clone());
        let de = a_cote(fichier, &format!(".abime-{}", horodatage()));
        if !mettre_de_cote {
            l.journal.push(format!("{nom} abîmé (illisible)"));
        } else {
            match std::fs::rename(fichier, &de) {
                Ok(()) => l.journal.push(format!(
                    "{nom} abîmé (illisible) : mis de côté dans {}",
                    de.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
                )),
                Err(e) => l.journal.push(format!("{nom} abîmé (illisible), pas pu être mis de côté : {e}")),
            }
        }
    }
    let bak = a_cote(fichier, ".bak");
    if bak.exists() {
        let copie = std::fs::read(&bak).ok().and_then(|o| objet(&decoder_fichier(&o, SansMarque::Utf8)));
        if let Some(v) = copie {
            let etat = if texte.is_some() { "abîmé" } else { "absent" };
            l.journal.push(format!("{nom} {etat} : repris de sa copie ({nom}.bak)"));
            if mettre_de_cote && !fichier.exists() {
                let tmp = a_cote(fichier, ".tmp");
                if let Err(e) = std::fs::copy(&bak, &tmp).and_then(|_| std::fs::rename(&tmp, fichier)) {
                    l.journal.push(format!("{nom} non remis en place depuis sa copie : {e}"));
                }
            }
            l.abime = None;
            l.valeur = Some(v);
            return Ok(l);
        }
        l.journal.push(format!("{nom} : sa copie ({nom}.bak) est illisible aussi"));
    }
    if texte.is_some() {
        l.journal.push(format!("{nom} : aucune copie lisible, il repart de zéro"));
    }
    Ok(l)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Un dossier d'essai neuf sous le dossier temporaire, effacé à la fin.
    struct Dossier(PathBuf);
    impl Dossier {
        fn nouveau(nom: &str) -> Dossier {
            let d = std::env::temp_dir().join(format!("suite-commun-json-{nom}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            Dossier(d)
        }
    }
    impl Drop for Dossier {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn ecriture_avec_copie_bak() {
        let d = Dossier::nouveau("ecriture");
        let f = d.0.join("reglages.json");
        ecrire(&f, r#"{"a":1}"#).unwrap();
        assert!(!a_cote(&f, ".bak").exists());
        ecrire(&f, r#"{"a":2}"#).unwrap();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), r#"{"a":2}"#);
        assert_eq!(std::fs::read_to_string(a_cote(&f, ".bak")).unwrap(), r#"{"a":1}"#);
        assert!(!a_cote(&f, ".tmp").exists());
        let l = lire(&f, true).unwrap();
        assert_eq!(l.valeur.unwrap()["a"], 2);
    }

    #[test]
    fn fichier_abime_mis_de_cote_et_copie_reprise() {
        let d = Dossier::nouveau("abime");
        let f = d.0.join("suite.json");
        ecrire(&f, r#"{"theme":"neon"}"#).unwrap();
        ecrire(&f, r#"{"theme":"nuit"}"#).unwrap();
        std::fs::write(&f, r#"{"theme":"nu"#).unwrap(); // coupé en plein milieu
        let l = lire(&f, true).unwrap();
        assert_eq!(l.valeur.unwrap()["theme"], "neon");
        assert!(l.abime.is_none());
        // Le fichier abîmé est gardé à côté, jamais effacé ; la copie est remise en place
        let abimes: Vec<_> = std::fs::read_dir(&d.0)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with("suite.json.abime-"))
            .collect();
        assert_eq!(abimes.len(), 1);
        assert_eq!(std::fs::read_to_string(abimes[0].path()).unwrap(), r#"{"theme":"nu"#);
        assert_eq!(std::fs::read_to_string(&f).unwrap(), r#"{"theme":"neon"}"#);
    }

    #[test]
    fn abime_sans_copie_ni_mise_de_cote() {
        let d = Dossier::nouveau("sanscopie");
        let f = d.0.join("x.json");
        std::fs::write(&f, "[1,2]").unwrap(); // du JSON, mais pas un objet
        let l = lire(&f, false).unwrap();
        assert!(l.valeur.is_none());
        assert_eq!(l.abime.as_deref(), Some("[1,2]"));
        assert!(f.exists(), "une simple lecture ne touche à rien");
    }

    #[test]
    fn absent_sans_copie() {
        let d = Dossier::nouveau("absent");
        let l = lire(&d.0.join("rien.json"), true).unwrap();
        assert!(l.valeur.is_none() && l.abime.is_none());
    }

    #[test]
    fn fichier_pris_un_instant_relu() {
        let d = Dossier::nouveau("pris");
        let f = d.0.join("etat.json");
        std::fs::write(&f, r#"{"pas":"fini"#).unwrap();
        // Une autre appli finit son écriture pendant que la lecture attend
        let f2 = f.clone();
        let fil = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            std::fs::write(&f2, r#"{"pas":"fini"}"#).unwrap();
        });
        let l = lire(&f, true).unwrap();
        fil.join().unwrap();
        assert_eq!(l.valeur.unwrap()["pas"], "fini");
    }

    /// Un fichier ouvert sans partage par une autre appli (le temps d'un enregistrement) : relu, pas « abîmé ».
    #[cfg(windows)]
    #[test]
    fn fichier_verrouille_un_instant_relu() {
        use std::os::windows::fs::OpenOptionsExt;
        let d = Dossier::nouveau("verrou");
        let f = d.0.join("etat.json");
        std::fs::write(&f, r#"{"ok":true}"#).unwrap();
        let verrou = std::fs::OpenOptions::new().read(true).share_mode(0).open(&f).unwrap();
        let fil = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            drop(verrou);
        });
        let l = lire(&f, true).unwrap();
        fil.join().unwrap();
        assert_eq!(l.valeur.unwrap()["ok"], true);
    }

    /// Verrouillé tout du long : une erreur (l'appelant ne doit pas repartir de zéro), et rien n'est déplacé.
    #[cfg(windows)]
    #[test]
    fn fichier_verrouille_longtemps_erreur() {
        use std::os::windows::fs::OpenOptionsExt;
        let d = Dossier::nouveau("verrou-long");
        let f = d.0.join("etat.json");
        std::fs::write(&f, r#"{"ok":true}"#).unwrap();
        let verrou = std::fs::OpenOptions::new().read(true).share_mode(0).open(&f).unwrap();
        assert!(lire(&f, true).is_err());
        drop(verrou);
        assert!(f.exists());
    }

    #[test]
    fn date_du_nom() {
        let h = horodatage();
        assert_eq!(h.len(), 15);
        assert!(h.starts_with("20"));
    }
}
