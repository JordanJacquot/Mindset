//! Les essais de json_sur, chacun dans son dossier temporaire (jamais un vrai fichier de la suite).

use super::*;
use std::time::Instant;

/// Un dossier d'essai neuf sous le dossier temporaire, effacé à la fin.
struct Dossier(PathBuf);
impl Dossier {
    fn nouveau(nom: &str) -> Dossier {
        let d = std::env::temp_dir().join(format!("suite-commun-json-{nom}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        Dossier(d)
    }

    /// Les noms des fichiers du dossier qui commencent par `debut`, triés.
    fn noms(&self, debut: &str) -> Vec<String> {
        let mut n: Vec<String> = std::fs::read_dir(&self.0)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with(debut))
            .collect();
        n.sort();
        n
    }
}
impl Drop for Dossier {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Le 31 octobre 2026 à 9 h 05 min 07 s, toujours.
const FIGEE: HeureLocale = HeureLocale { annee: 2026, mois: 10, jour: 31, heure: 9, minute: 5, seconde: 7 };

/// Les options par défaut, avec une horloge figée.
fn figees() -> Options {
    Options { horloge: Arc::new(|| FIGEE), ..Options::default() }
}

/// Les options de Mindcare (5 essais à 300 ms, seulement un fichier pris), en plus court, et une horloge figée.
fn partage() -> Options {
    Options { essais: 3, attente: Duration::from_millis(100), seulement_partage: true, horloge: Arc::new(|| FIGEE) }
}

fn lu(f: &Path) -> String {
    std::fs::read_to_string(f).unwrap()
}

#[test]
fn ecriture_avec_copie_bak() {
    let d = Dossier::nouveau("ecriture");
    let f = d.0.join("reglages.json");
    ecrire(&f, r#"{"a":1}"#).unwrap();
    assert!(!a_cote(&f, ".bak").exists());
    ecrire(&f, r#"{"a":2}"#).unwrap();
    assert_eq!(lu(&f), r#"{"a":2}"#);
    assert_eq!(lu(&a_cote(&f, ".bak")), r#"{"a":1}"#);
    assert!(!a_cote(&f, ".tmp").exists());
    let l = lire(&f, true).unwrap();
    assert_eq!(l.valeur.unwrap()["a"], 2);
}

/// Constat 23 de Mindcare : un fichier en place vide (rien, espaces, « null ») n'est jamais poussé dans « .bak » ;
/// il est remplacé, sans rien mettre de côté (il ne contient rien).
#[test]
fn ecriture_par_dessus_un_fichier_vide_garde_la_copie() {
    for (i, vide) in ["", "   \r\n\t ", "null", " null \n", "\u{FEFF}"].iter().enumerate() {
        let d = Dossier::nouveau(&format!("ecrire-vide-{i}"));
        let f = d.0.join("diagnostics.json");
        ecrire_avec(&f, r#"{"n":1}"#, &figees()).unwrap();
        ecrire_avec(&f, r#"{"n":2}"#, &figees()).unwrap();
        std::fs::write(&f, vide).unwrap();
        ecrire_avec(&f, r#"{"n":3}"#, &figees()).unwrap();
        assert_eq!(lu(&f), r#"{"n":3}"#);
        assert_eq!(lu(&a_cote(&f, ".bak")), r#"{"n":1}"#, "{vide:?} a remplacé la bonne copie");
        assert!(d.noms("diagnostics.json.abime").is_empty(), "{vide:?} : rien à mettre de côté");
    }
}

/// Un fichier en place abîmé (tableau, coupé) : jamais dans « .bak », mais gardé à côté (jamais effacé).
#[test]
fn ecriture_par_dessus_un_fichier_abime_le_met_de_cote() {
    for (i, abime) in ["[1,2]", r#"{"n":"#, "42"].iter().enumerate() {
        let d = Dossier::nouveau(&format!("ecrire-abime-{i}"));
        let f = d.0.join("etat.json");
        ecrire_avec(&f, r#"{"n":1}"#, &figees()).unwrap();
        ecrire_avec(&f, r#"{"n":2}"#, &figees()).unwrap();
        std::fs::write(&f, abime).unwrap();
        ecrire_avec(&f, r#"{"n":3}"#, &figees()).unwrap();
        assert_eq!(lu(&f), r#"{"n":3}"#);
        assert_eq!(lu(&a_cote(&f, ".bak")), r#"{"n":1}"#, "{abime:?} a remplacé la bonne copie");
        assert_eq!(d.noms("etat.json.abime"), ["etat.json.abime-20261031-090507"]);
        assert_eq!(lu(&a_cote(&f, ".abime-20261031-090507")), *abime);
    }
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
    let abimes = d.noms("suite.json.abime-");
    assert_eq!(abimes.len(), 1);
    assert_eq!(lu(&d.0.join(&abimes[0])), r#"{"theme":"nu"#);
    assert_eq!(lu(&f), r#"{"theme":"neon"}"#);
}

/// Vide, espaces, « null », tableau, coupé : abîmés, mis de côté, et la bonne copie « .bak » est reprise.
#[test]
fn chaque_sorte_de_fichier_abime_reprend_sa_copie() {
    for (i, abime) in ["", "  \r\n ", "null", "[1,2]", r#"{"a":"#].iter().enumerate() {
        let d = Dossier::nouveau(&format!("sortes-{i}"));
        let f = d.0.join("reglages.json");
        std::fs::write(a_cote(&f, ".bak"), r#"{"a":"copie"}"#).unwrap();
        std::fs::write(&f, abime).unwrap();
        let l = lire_avec(&f, true, &partage()).unwrap();
        assert_eq!(l.valeur.unwrap()["a"], "copie", "{abime:?}");
        assert_eq!(d.noms("reglages.json.abime"), ["reglages.json.abime-20261031-090507"], "{abime:?}");
        assert_eq!(lu(&a_cote(&f, ".abime-20261031-090507")), *abime);
        assert_eq!(lu(&f), r#"{"a":"copie"}"#, "{abime:?} : la copie est remise en place");
    }
}

/// Le fichier et sa copie sont abîmés : les deux sont mis de côté, rien n'est lu, le texte abîmé est rendu.
#[test]
fn copie_abimee_mise_de_cote_aussi() {
    let d = Dossier::nouveau("bak-abime");
    let f = d.0.join("etat.json");
    std::fs::write(&f, r#"{"x":"#).unwrap();
    std::fs::write(a_cote(&f, ".bak"), "[3]").unwrap();
    let l = lire_avec(&f, true, &partage()).unwrap();
    assert!(l.valeur.is_none());
    assert_eq!(l.abime.as_deref(), Some(r#"{"x":"#));
    assert_eq!(d.noms("etat.json"), ["etat.json.abime-20261031-090507", "etat.json.bak.abime-20261031-090507"]);
    assert_eq!(lu(&a_cote(&f, ".bak.abime-20261031-090507")), "[3]");
    assert!(l.journal.iter().any(|j| j.contains("illisible aussi")), "{:?}", l.journal);
    assert!(l.journal.iter().any(|j| j.contains("repart de zéro")), "{:?}", l.journal);
}

/// Une simple lecture (mettre_de_cote faux) ne déplace pas non plus une copie abîmée.
#[test]
fn copie_abimee_sans_mise_de_cote() {
    let d = Dossier::nouveau("bak-abime-lecture");
    let f = d.0.join("etat.json");
    std::fs::write(a_cote(&f, ".bak"), "").unwrap();
    let l = lire_avec(&f, false, &partage()).unwrap();
    assert!(l.valeur.is_none() && l.abime.is_none());
    assert_eq!(d.noms("etat.json"), ["etat.json.bak"]);
}

/// Le fichier est absent, sa copie est bonne : elle est reprise et remise en place.
#[test]
fn absent_repris_de_sa_copie() {
    let d = Dossier::nouveau("absent-bak");
    let f = d.0.join("suite.json");
    std::fs::write(a_cote(&f, ".bak"), "\u{FEFF}{\"ok\":1}").unwrap();
    let l = lire(&f, true).unwrap();
    assert_eq!(l.valeur.unwrap()["ok"], 1);
    assert!(f.exists());
}

/// Deux mises de côté dans la même seconde ne s'écrasent pas : la seconde prend le nom suivant.
#[test]
fn deux_mises_de_cote_dans_la_meme_seconde() {
    let d = Dossier::nouveau("meme-seconde");
    let f = d.0.join("etat.json");
    std::fs::write(&f, "premier abîmé").unwrap();
    lire_avec(&f, true, &partage()).unwrap();
    std::fs::write(&f, "second abîmé").unwrap();
    lire_avec(&f, true, &partage()).unwrap();
    std::fs::write(&f, "troisième abîmé").unwrap();
    ecrire_avec(&f, r#"{"n":1}"#, &partage()).unwrap();
    assert_eq!(
        d.noms("etat.json.abime"),
        ["etat.json.abime-20261031-090507", "etat.json.abime-20261031-090507-2", "etat.json.abime-20261031-090507-3"]
    );
    assert_eq!(lu(&a_cote(&f, ".abime-20261031-090507")), "premier abîmé");
    assert_eq!(lu(&a_cote(&f, ".abime-20261031-090507-2")), "second abîmé");
    assert_eq!(lu(&a_cote(&f, ".abime-20261031-090507-3")), "troisième abîmé");
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

/// Seulement un fichier pris est réessayé : un texte abîmé est mis de côté tout de suite, sans attendre.
#[test]
fn seulement_partage_ne_relit_pas_un_texte_abime() {
    let d = Dossier::nouveau("partage-abime");
    let f = d.0.join("etat.json");
    std::fs::write(&f, "coupé").unwrap();
    let o = Options { essais: 5, attente: Duration::from_millis(400), ..partage() };
    let debut = Instant::now();
    lire_avec(&f, true, &o).unwrap();
    assert!(debut.elapsed() < Duration::from_millis(400), "{:?}", debut.elapsed());
}

/// Seulement un fichier pris est réessayé : une autre erreur (ici un dossier à la place du fichier) est rendue tout
/// de suite, sans « pris ».
#[test]
fn seulement_partage_ne_reessaie_pas_une_autre_erreur() {
    let d = Dossier::nouveau("partage-autre");
    let f = d.0.join("etat.json");
    std::fs::create_dir(&f).unwrap();
    let o = Options { essais: 5, attente: Duration::from_millis(400), ..partage() };
    let debut = Instant::now();
    let e = lire_avec(&f, true, &o).unwrap_err();
    assert!(debut.elapsed() < Duration::from_millis(400), "{:?}", debut.elapsed());
    assert!(!e.pris);
    assert!(f.is_dir(), "rien n'est déplacé");
}

#[test]
fn texte_d_un_fichier() {
    assert_eq!(texte_du_fichier(b"\xEF\xBB\xBF{}"), "{}");
    assert_eq!(texte_du_fichier(b"\xFF\xFE{\x00}\x00"), "{}");
    assert_eq!(texte_du_fichier("é".as_bytes()), "é");
    assert!(texte_vide(" null ") && texte_vide("") && texte_vide("\u{FEFF} ") && !texte_vide("{}"));
    assert_eq!(analyser("[1]").unwrap_err(), "ce n'est pas un objet JSON");
    assert_eq!(analyser(" ").unwrap_err(), "fichier vide");
    assert!(analyser("{\"a\":").is_err());
    assert_eq!(analyser("\u{FEFF}{\"a\":1}").unwrap()["a"], 1);
}

#[test]
fn heure_du_nom() {
    assert_eq!(FIGEE.compacte(), "20261031-090507");
    // L'heure du PC : la forme de Get-Date -Format 'yyyyMMdd-HHmmss'
    let h = heure_du_pc().compacte();
    assert_eq!(h.len(), 15);
    assert!(h.starts_with("20") && h.as_bytes()[8] == b'-' && h.bytes().filter(u8::is_ascii_digit).count() == 14);
}

/// L'heure locale : à moins de 14 h de l'heure UTC, et décalée d'un nombre entier de quarts d'heure (les fuseaux).
#[cfg(all(windows, feature = "heure-locale"))]
#[test]
fn heure_locale_et_non_utc() {
    fn secondes(h: HeureLocale) -> i64 {
        // Jours depuis le 1er janvier 1970 (algorithme de H. Hinnant, domaine public)
        let (a, m) = (i64::from(h.annee) - i64::from(h.mois <= 2), i64::from(h.mois));
        let ere = a.div_euclid(400);
        let ade = a - ere * 400;
        let jda = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(h.jour) - 1;
        let jde = ade * 365 + ade / 4 - ade / 100 + jda;
        let jours = ere * 146_097 + jde - 719_468;
        jours * 86_400 + i64::from(h.heure) * 3600 + i64::from(h.minute) * 60 + i64::from(h.seconde)
    }
    let (utc, locale) = (heure_utc(), heure_du_pc());
    let ecart = secondes(locale) - secondes(utc);
    assert!(ecart.abs() <= 14 * 3600, "écart {ecart}");
    let quart = (ecart as f64 / 900.0).round() as i64 * 900;
    assert!((ecart - quart).abs() <= 2, "écart {ecart}");
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

/// Pris pendant tous les essais (comme Mindcare 0.15.1) : un résultat « pris », distinct d'une erreur, après le
/// nombre d'essais voulu ; rien n'est déplacé ; sa copie se lit à part ; libéré, il se relit.
#[cfg(windows)]
#[test]
fn fichier_pris_resultat_pris_et_copie_lue() {
    use std::os::windows::fs::OpenOptionsExt;
    let d = Dossier::nouveau("pris-long");
    let f = d.0.join("diagnostics.json");
    ecrire_avec(&f, r#"{"n":1}"#, &partage()).unwrap();
    ecrire_avec(&f, r#"{"n":2}"#, &partage()).unwrap();
    let verrou = std::fs::OpenOptions::new().read(true).share_mode(0).open(&f).unwrap();
    let debut = Instant::now();
    let e = lire_avec(&f, true, &partage()).unwrap_err();
    let duree = debut.elapsed();
    assert!(e.pris, "{e}");
    assert_eq!(e.fichier, f);
    assert!(erreur_fichier_pris(&e.erreur));
    // 3 essais à 100 ms : deux attentes
    assert!(duree >= Duration::from_millis(200) && duree < Duration::from_millis(2000), "{duree:?}");
    assert_eq!(d.noms("diagnostics.json"), ["diagnostics.json", "diagnostics.json.bak"], "rien n'est déplacé");
    // L'appelant lit la copie pour montrer quelque chose, sans rien remettre en place
    let c = lire_copie(&f, true, &partage()).unwrap();
    assert_eq!(c.valeur.unwrap()["n"], 1);
    // L'écriture aussi : une erreur reconnue comme « pris », et l'ancien fichier reste entier
    let e = ecrire_avec(&f, r#"{"n":3}"#, &partage()).unwrap_err();
    assert!(erreur_fichier_pris(&e), "{e}");
    assert!(!a_cote(&f, ".tmp").exists());
    drop(verrou);
    assert_eq!(lu(&f), r#"{"n":2}"#);
    assert_eq!(lire_avec(&f, true, &partage()).unwrap().valeur.unwrap()["n"], 2);
}

/// La copie « .bak » prise pendant tous les essais, le fichier absent : « pris » aussi (sinon l'appelant
/// repartirait de zéro).
#[cfg(windows)]
#[test]
fn copie_prise_resultat_pris() {
    use std::os::windows::fs::OpenOptionsExt;
    let d = Dossier::nouveau("bak-pris");
    let f = d.0.join("etat.json");
    let bak = a_cote(&f, ".bak");
    std::fs::write(&bak, r#"{"n":1}"#).unwrap();
    let verrou = std::fs::OpenOptions::new().read(true).share_mode(0).open(&bak).unwrap();
    let e = lire_avec(&f, true, &partage()).unwrap_err();
    assert!(e.pris);
    assert_eq!(e.fichier, bak);
    drop(verrou);
    assert_eq!(lire_avec(&f, true, &partage()).unwrap().valeur.unwrap()["n"], 1);
}
