//! La reprise d'une installation 2.18 existante, sur des cas que les juges ne couvrent pas :
//! - les données sur un AUTRE disque que le profil (C: -> D:), où un déplacement n'est plus un simple renommage ;
//! - toutes les coupures possibles d'un vrai reglages.json de 2.18 (jamais un réglage coupé rallumé, toujours la même
//!   chose au lancement suivant) ;
//! - des écritures en même temps depuis plusieurs fils (journal et réglages jamais abîmés).
//!
//! Tout se passe sous le dossier temporaire et sous `D:\Outils\Rust\essais\donnees` (jamais les vraies données).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use mindset_donnees::{DisqueMindset, ouvrir_disque};
use mindset_noyau::donnees::{Donnees, Environnement};
use serde_json::{Value, json};

fn horloge() -> suite_commun::json_sur::Horloge {
    Arc::new(mindset_noyau::moment::heure_du_pc)
}

fn ouvrir(exe: &Path, local: &Path, pf: &Path) -> (mindset_noyau::donnees::Dossiers, Arc<DisqueMindset>) {
    let env = Environnement { exe: exe.into(), localappdata: local.into(), program_files: pf.into(), essai: None };
    ouvrir_disque(&env, &|| None, horloge())
}

const REGLAGES_218: &str = "{\r\n    \"VerifVersions\":  false,\r\n    \"MajAuto\":  false,\r\n    \"LancerAvecWindows\":  false,\r\n    \"Demarrage\":  [\r\n                      \"evermind\",\r\n                      \"mindcare\"\r\n                  ],\r\n    \"Fermeture\":  \"reduire\",\r\n    \"Animations\":  \"reduites\",\r\n    \"ReduireHorloge\":  false,\r\n    \"Ouverture-nevermind\":  3.2,\r\n    \"Theme\":  \"pack:cafe-creme\"\r\n}";

/// Mindset installé sur D:, ses anciens fichiers restés dans le profil (C:) : déplacés d'un disque à l'autre, rien de
/// perdu, rien en double.
#[test]
fn anciens_fichiers_d_un_disque_a_l_autre() {
    let d = PathBuf::from(r"D:\Outils\Rust\essais");
    if !d.is_dir() {
        eprintln!("pas de disque D: d'essai, cas sauté");
        return;
    }
    let racine_d = d.join(format!("donnees\\disques-{}", std::process::id()));
    let racine_c = std::env::temp_dir().join(format!("mindset-donnees-disques-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&racine_d);
    let _ = std::fs::remove_dir_all(&racine_c);
    let local = racine_c.join(r"Users\Élodie\AppData\Local");
    let ancien = local.join(r"Mindset\Mindset");
    std::fs::create_dir_all(&ancien).unwrap();
    std::fs::write(ancien.join("reglages.json"), REGLAGES_218).unwrap();
    std::fs::write(
        ancien.join("installations.json"),
        r#"{"nevermind":{"dossier":"D:\\Mindset\\Programmes\\Nevermind","gere":true}}"#,
    )
    .unwrap();
    std::fs::write(ancien.join("journal.txt"), "2026-10-01T10:00:00 vieux\r\n").unwrap();
    let exe = racine_d.join(r"Mindset\Programmes\Mindset\Mindset.exe");
    std::fs::create_dir_all(exe.parent().unwrap()).unwrap();

    let (dos, disque) = ouvrir(&exe, &local, &racine_c.join("PF"));
    assert_eq!(dos.donnees, racine_d.join(r"Mindset\Donnees\Mindset"));
    assert_eq!(dos.disque, "D");
    assert_eq!(dos.local_mindset, local.join("Mindset"), "suite.json reste toujours dans le profil");
    for n in ["reglages.json", "installations.json", "journal.txt"] {
        assert!(dos.donnees.join(n).is_file(), "{n} déplacé sur D:");
        assert!(!ancien.join(n).exists(), "{n} plus dans le profil (jamais deux copies)");
    }
    assert_eq!(std::fs::read_to_string(dos.donnees.join("reglages.json")).unwrap(), REGLAGES_218, "copié tel quel");
    assert_eq!(disque.reglage("VerifVersions"), Some(json!(false)));
    assert_eq!(disque.reglage("Demarrage"), Some(json!(["evermind", "mindcare"])));
    assert!(!mindset_donnees::lancer_avec_windows(&*disque));
    drop(disque);

    // L'ancien journal de Mindset.exe (jusqu'à la 2.8.0) réapparu dans le profil : ajouté au vrai journal, sur D:
    std::fs::write(ancien.join("journal.txt"), "plantage\r\n").unwrap();
    let (dos, _d) = ouvrir(&exe, &local, &racine_c.join("PF"));
    let j = std::fs::read_to_string(dos.journal()).unwrap();
    assert!(j.starts_with("2026-10-01T10:00:00 vieux\r\n"), "{j}");
    assert!(
        j.contains("Lignes reprises de l'ancien journal de Mindset.exe (") && j.ends_with(" :\r\nplantage\r\n"),
        "{j}"
    );
    assert!(!ancien.join("journal.txt").exists());
    let _ = std::fs::remove_dir_all(&racine_d);
    let _ = std::fs::remove_dir_all(&racine_c);
}

/// Toutes les coupures possibles d'un reglages.json de 2.18 sans copie : « Chercher les nouvelles versions » et les
/// mises à jour automatiques ne se rallument jamais, ce qui est repris l'est avec sa vraie valeur, et le lancement
/// suivant donne exactement la même chose (la reprise est enregistrée tout de suite).
#[test]
fn chaque_coupure_d_un_reglages_json() {
    let racine = std::env::temp_dir().join(format!("mindset-donnees-coupures-{}", std::process::id()));
    let vrais: serde_json::Map<String, Value> = serde_json::from_str(REGLAGES_218).unwrap();
    let mut coupures = 0;
    for (n, _) in REGLAGES_218.char_indices().step_by(3) {
        let _ = std::fs::remove_dir_all(&racine);
        let donnees = racine.join(r"Local\Mindset\Mindset");
        std::fs::create_dir_all(&donnees).unwrap();
        std::fs::write(donnees.join("reglages.json"), &REGLAGES_218[..n]).unwrap();
        let exe = racine.join(r"PF\Mindset\Mindset\Mindset.exe");
        let (_, disque) = ouvrir(&exe, &racine.join("Local"), &racine.join("PF"));
        let lus = disque.reglages();
        for prudent in ["VerifVersions", "MajAuto"] {
            assert_eq!(lus.get(prudent), Some(&json!(false)), "coupé à {n} : {prudent} rallumé ? {lus:?}");
        }
        for (k, v) in &lus {
            if k != "VerifVersions" && k != "MajAuto" {
                assert_eq!(vrais.get(k), Some(v), "coupé à {n} : {k} repris avec une autre valeur");
            }
        }
        drop(disque);
        let (_, encore) = ouvrir(&exe, &racine.join("Local"), &racine.join("PF"));
        assert_eq!(encore.reglages(), lus, "coupé à {n} : le lancement suivant ne donne pas la même chose");
        coupures += 1;
    }
    assert!(coupures > 100);
    let _ = std::fs::remove_dir_all(&racine);
}

/// Des blocs et des travaux de fond qui écrivent en même temps : chaque ligne du journal est entière, et
/// reglages.json garde tous les réglages écrits.
#[test]
fn ecritures_en_meme_temps() {
    let racine = std::env::temp_dir().join(format!("mindset-donnees-fils-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&racine);
    let exe = racine.join(r"PF\Mindset\Mindset\Mindset.exe");
    let (dos, disque) = ouvrir(&exe, &racine.join("Local"), &racine.join("PF"));
    let fils: Vec<_> = (0..8)
        .map(|f| {
            let d = disque.clone();
            std::thread::spawn(move || {
                for i in 0..25 {
                    d.journal(&format!("fil {f} ligne {i} : café crème"));
                    d.ecrire_reglage(&format!("Essai-{f}"), json!(i));
                }
            })
        })
        .collect();
    for f in fils {
        f.join().unwrap();
    }
    let j = std::fs::read_to_string(dos.journal()).unwrap();
    assert_eq!(j.lines().filter(|l| l.contains(" : café crème")).count(), 200);
    assert!(j.lines().all(|l| l.len() > 20 && l.as_bytes()[19] == b' '), "une ligne mélangée");
    let r: serde_json::Map<String, Value> =
        serde_json::from_str(&std::fs::read_to_string(dos.reglages()).unwrap()).unwrap();
    for f in 0..8 {
        assert_eq!(r.get(&format!("Essai-{f}")), Some(&json!(24)));
    }
    drop(disque);
    let _ = std::fs::remove_dir_all(&racine);
}

/// Le JSON écrit par Rust est relu tel quel par Rust (et la forme est celle de PowerShell : voir les juges).
#[test]
fn aller_retour_du_json() {
    let racine = std::env::temp_dir().join(format!("mindset-donnees-aller-retour-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&racine);
    let exe = racine.join(r"PF\Mindset\Mindset\Mindset.exe");
    let (dos, disque) = ouvrir(&exe, &racine.join("Local"), &racine.join("PF"));
    let v =
        json!({ "a": "<é> & 'x' \"y\" \\ \u{2028}\u{1}😀", "b": [1, 2.5, -3, [], {}], "c": { "d": null, "e": true } });
    let f = dos.donnees.join("essai.json");
    disque.ecrire_json(&f, &v).unwrap();
    assert_eq!(disque.lire_json(&f).unwrap(), Some(v));
    let _ = std::fs::remove_dir_all(&racine);
}
