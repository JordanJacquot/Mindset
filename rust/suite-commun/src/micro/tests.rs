use std::path::PathBuf;

use super::*;
use crate::base64;

/// Un dossier d'essai neuf sous le dossier temporaire, effacé à la fin.
struct Dossier(PathBuf);
impl Dossier {
    fn nouveau(nom: &str) -> Dossier {
        let d = std::env::temp_dir().join(format!("suite-commun-micro-{nom}-{}", std::process::id()));
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

/// Des appareils inventés, pour les tests.
struct FauxPc {
    micros: Vec<String>,
    sorties: Vec<String>,
}
impl AppareilsAudio for FauxPc {
    fn micros(&self) -> Vec<String> {
        self.micros.clone()
    }
    fn sorties(&self) -> Vec<String> {
        self.sorties.clone()
    }
}

fn appareil(nom: &str) -> Choix {
    Choix::Appareil(nom.to_string())
}

// ---------------------------------------------------------------------------------------------------------------
// Les juges : les réponses des vraies fonctions PowerShell (outils\exporter-juges-micro.ps1)
// ---------------------------------------------------------------------------------------------------------------

/// Les cas où ce module répond autrement qu'une des applis PowerShell, exprès. Chacun doit vraiment différer (sinon il
/// n'a plus rien à faire ici).
const ECARTS: &[(&str, &str, &str)] = &[
    // (appli, cas, pourquoi)
    ("mindset", "abîmé, copie .bak bonne", "Mindset reprend sa copie .bak ; les applis ne lisent que suite.json"),
    ("mindset", "guillemets simples", "ConvertFrom-Json accepte 'micro' entre guillemets simples, pas le JSON"),
    ("mindcare", "guillemets simples", "ConvertFrom-Json accepte 'micro' entre guillemets simples, pas le JSON"),
    ("evermind", "guillemets simples", "ConvertFrom-Json accepte 'micro' entre guillemets simples, pas le JSON"),
    ("mindcare", "un tableau d'un objet", "Mindcare lit $j.micro sur un tableau (PowerShell l'étend à ses éléments)"),
    ("evermind", "micro : un tableau d'un nom", "Evermind déballe un tableau d'un seul nom ($v = if ...)"),
    ("evermind", "caractère DEL (0x7F)", "Evermind refuse tout \\p{Cc}, Mindset et Mindcare 0x00 à 0x1F"),
    ("evermind", "caractère de contrôle C1 (0x85)", "Evermind refuse tout \\p{Cc}, Mindset et Mindcare 0x00 à 0x1F"),
];

fn ecart(appli: &str, cas: &str) -> bool {
    ECARTS.iter().any(|(a, c, _)| *a == appli && *c == cas)
}

/// Un choix tel que PowerShell le rend : `null` (rien), `""` (celui de Windows) ou un nom.
fn choix_juge(v: &Value) -> Choix {
    match v {
        Value::Null => Choix::Absent,
        Value::String(s) if s.is_empty() => Choix::Windows,
        Value::String(s) => appareil(s),
        _ => panic!("juge illisible : {v}"),
    }
}

fn noms(v: &Value) -> Vec<String> {
    v.as_array().unwrap().iter().map(|n| n.as_str().unwrap().to_string()).collect()
}

#[test]
fn juges_powershell() {
    let juges: Value = serde_json::from_str(include_str!("juges.json")).unwrap();
    let cas = juges["cas"].as_array().unwrap();
    assert!(cas.len() >= 50, "juges.json incomplet");
    let d = Dossier::nouveau("juges");
    let mut echecs = Vec::new();
    let mut ecarts_vus = Vec::new();
    for (n, c) in cas.iter().enumerate() {
        let nom = c["nom"].as_str().unwrap();
        let dossier = d.0.join(n.to_string());
        std::fs::create_dir_all(&dossier).unwrap();
        let f = dossier.join("suite.json");
        if let Some(o) = c["fichier"].as_str() {
            std::fs::write(&f, base64::decoder(o).unwrap()).unwrap();
        }
        if let Some(o) = c["bak"].as_str() {
            std::fs::write(dossier.join("suite.json.bak"), base64::decoder(o).unwrap()).unwrap();
        }
        let pc = FauxPc { micros: noms(&c["micros"]), sorties: noms(&c["sorties"]) };
        let l = lire(&f, 1);
        assert_ne!(l.etat, EtatSuite::Pris, "{nom}");
        let son = &l.son;

        // Chaque appli : ce que dit PowerShell, ce que dit ce module
        let mut verifier = |appli: &str, juge: String, rust: String| {
            let different = juge != rust;
            if ecart(appli, nom) {
                ecarts_vus.push((appli.to_string(), nom.to_string(), different));
            } else if different {
                echecs.push(format!("{appli} / {nom} : PowerShell {juge}, Rust {rust}"));
            }
        };

        let ms = &c["mindset"];
        verifier(
            "mindset",
            format!("{:?} {:?}", choix_juge(&ms["micro"]), choix_juge(&ms["casque"])),
            format!("{:?} {:?}", son.micro, son.casque),
        );

        // Mindcare : le micro gardé ("" sans choix) et le numéro donné à la dictée
        let mc = &c["mindcare"];
        verifier(
            "mindcare",
            format!("{:?} {}", mc["micro"].as_str().unwrap(), mc["numero"].as_u64().unwrap()),
            format!("{:?} {}", son.micro.nom(), son.micro_sur(&pc).numero()),
        );

        // Evermind : sans choix, il garde son réglage (ici celui de Windows)
        let ev = &c["evermind"];
        let micro = son.micro.clone().ou(Choix::Windows);
        let casque = son.casque.clone().ou(Choix::Windows);
        verifier(
            "evermind",
            format!(
                "{:?} {:?} {} {}",
                choix_juge(&ev["micro"]),
                choix_juge(&ev["casque"]),
                ev["numero_micro"].as_u64().unwrap(),
                ev["numero_casque"].as_u64().unwrap()
            ),
            format!(
                "{:?} {:?} {} {}",
                son.micro,
                son.casque,
                trouver(&micro, &pc.micros).numero(),
                trouver(&casque, &pc.sorties).numero()
            ),
        );
    }
    assert!(echecs.is_empty(), "{} écart(s) avec PowerShell :\n{}", echecs.len(), echecs.join("\n"));
    for (a, c, _) in ECARTS {
        let vu = ecarts_vus.iter().find(|(va, vc, _)| va == a && vc == c);
        assert!(vu.is_some(), "écart connu {a} / {c} : ce cas n'est plus dans juges.json");
        assert!(vu.unwrap().2, "écart connu {a} / {c} : Rust et PowerShell répondent pareil, à retirer de ECARTS");
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Les règles, une par une
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn valeurs_du_micro() {
    let son = |t: &str| depuis_texte(t).map(|s| s.micro);
    assert_eq!(son(r#"{"theme":"neon"}"#), Some(Choix::Absent));
    assert_eq!(son(r#"{"micro":""}"#), Some(Choix::Windows));
    assert_eq!(son(r#"{"micro":"Micro USB"}"#), Some(appareil("Micro USB")));
    assert_eq!(son(r#"{"Micro":"Micro USB"}"#), Some(appareil("Micro USB")));
    assert_eq!(son(r#"{"micro":null}"#), Some(Choix::Absent));
    assert_eq!(son(r#"{"micro":12}"#), Some(Choix::Absent));
    assert_eq!(son(r#"{"micro":["Micro USB"]}"#), Some(Choix::Absent));
    assert_eq!(son(r#"{"micro":"a\tb"}"#), Some(Choix::Absent));
    assert_eq!(son(r#"{"micro":"a\u007fb"}"#), Some(appareil("a\u{7f}b")));
    // Rien n'est retouché : ni espaces, ni majuscules
    assert_eq!(son(r#"{"micro":" Micro "}"#), Some(appareil(" Micro ")));
    // La dernière valeur d'une clé en double
    assert_eq!(son(r#"{"micro":"A","micro":"B"}"#), Some(appareil("B")));
}

#[test]
fn longueur_en_unites_utf16() {
    let son = |nom: String| depuis_texte(&serde_json::json!({ "micro": nom }).to_string()).unwrap().micro;
    assert_eq!(son("é".repeat(64)), appareil(&"é".repeat(64)));
    assert_eq!(son("é".repeat(65)), Choix::Absent);
    // Un emoji compte pour deux, comme en .NET
    assert_eq!(son(format!("{}🎤", "a".repeat(62))), appareil(&format!("{}🎤", "a".repeat(62))));
    assert_eq!(son(format!("{}🎤", "a".repeat(63))), Choix::Absent);
}

#[test]
fn fichiers_illisibles() {
    for t in ["", "  ", "null", "[]", "\"micro\"", r#"{"micro":"A""#, r#"{"micro":"A",}"#, r#"{"micro":"A"} x"#] {
        assert_eq!(depuis_texte(t), None, "{t:?}");
    }
    // Deux clés qui ne diffèrent que par les majuscules, où que ce soit : PowerShell refuse tout le fichier
    assert_eq!(depuis_texte(r#"{"micro":"A","Micro":"B"}"#), None);
    assert_eq!(depuis_texte(r#"{"micro":"A","x":[{"b":1,"B":2}]}"#), None);
    assert_eq!(depuis_texte(r#"{"micro":"A","x":{"b":1,"c":{"b":2}}}"#).unwrap().micro, appareil("A"));
    // Un nombre trop grand, un caractère seul d'une paire UTF-16 : illisibles en Rust (PowerShell lit le second,
    // mais ce nom ne peut être celui d'aucun appareil : celui de Windows dans les deux cas pour Mindcare)
    assert_eq!(depuis_texte(r#"{"micro":"A","n":1e400}"#), None);
    assert_eq!(depuis_texte(r#"{"micro":"\ud800"}"#), None);
}

#[test]
fn profondeur_comme_powershell() {
    let tableaux = |n: usize| format!(r#"{{"micro":"A","x":{}{}}}"#, "[".repeat(n), "]".repeat(n));
    assert!(depuis_texte(&tableaux(101)).is_some());
    assert!(depuis_texte(&tableaux(102)).is_none());
    assert!(depuis_texte(&tableaux(500)).is_none());
}

#[test]
fn trouver_parmi_les_appareils() {
    let noms = ["Microphone (Realtek(R) Audio)", "Micro USB", "Micro USB", ""];
    assert_eq!(trouver(&Choix::Absent, &noms), Trouve::Windows);
    assert_eq!(trouver(&Choix::Windows, &noms), Trouve::Windows);
    assert_eq!(trouver(&appareil("Microphone (Realtek(R) Audio)"), &noms), Trouve::Present(0));
    // Deux appareils au même nom : le premier
    assert_eq!(trouver(&appareil("Micro USB"), &noms), Trouve::Present(1));
    // Mêmes majuscules, mêmes espaces
    assert_eq!(trouver(&appareil("micro usb"), &noms), Trouve::Debranche);
    assert_eq!(trouver(&appareil("Micro USB "), &noms), Trouve::Debranche);
    assert_eq!(trouver(&appareil("Micro Blue Yeti"), &noms), Trouve::Debranche);
    assert_eq!(trouver(&appareil("Micro USB"), &[] as &[&str]), Trouve::Debranche);
    assert_eq!(Trouve::Present(2).numero(), 2);
    assert_eq!(Trouve::Debranche.numero(), APPAREIL_DE_WINDOWS);
    assert_eq!(Trouve::Windows.numero(), 0xFFFF_FFFF);
}

#[test]
fn choix_absent_et_reglage_de_l_appli() {
    assert_eq!(Choix::Absent.ou(appareil("Le mien")), appareil("Le mien"));
    assert_eq!(Choix::Windows.ou(appareil("Le mien")), Choix::Windows);
    assert_eq!(appareil("A").ou(appareil("Le mien")), appareil("A"));
    assert_eq!(Choix::Absent.nom(), "");
    assert_eq!(Choix::Windows.nom(), "");
    assert_eq!(appareil("A").nom(), "A");
}

#[test]
fn par_le_trait() {
    let pc = FauxPc {
        micros: vec!["Microphone (Realtek(R) Audio)".into(), "Casque (Logitech G435)".into()],
        sorties: vec!["Casque (Logitech G435)".into()],
    };
    let son = depuis_texte(r#"{"micro":"Casque (Logitech G435)","casque":"Haut-parleurs"}"#).unwrap();
    assert_eq!(son.micro_sur(&pc), Trouve::Present(1));
    assert_eq!(son.casque_sur(&pc), Trouve::Debranche);
    let dyn_pc: &dyn AppareilsAudio = &pc;
    assert_eq!(son.micro_sur(dyn_pc).numero(), 1);
}

#[test]
fn lecture_du_fichier() {
    let d = Dossier::nouveau("lecture");
    let f = d.0.join("suite.json");
    assert_eq!(lire(&f, 3).etat, EtatSuite::Absent);
    std::fs::write(&f, b"\xEF\xBB\xBF{\"micro\":\"Micro \xC3\xA9t\xC3\xA9\"}").unwrap();
    let l = lire(&f, 3);
    assert_eq!((l.etat, l.son.micro), (EtatSuite::Lu, appareil("Micro été")));
    std::fs::write(&f, b"{\"micro\":\"Mi").unwrap();
    assert_eq!(lire(&f, 3), LectureSuite { etat: EtatSuite::Illisible, son: SonSuite::default() });
    assert!(f.exists(), "un fichier abîmé n'est jamais déplacé");
    // Un dossier qui porte ce nom : comme s'il n'y avait rien ([IO.File]::Exists)
    let d2 = d.0.join("dossier");
    std::fs::create_dir_all(d2.join("suite.json")).unwrap();
    assert_eq!(lire(&d2.join("suite.json"), 3).etat, EtatSuite::Absent);
}

/// Tenu par un autre programme tout du long : « Pris », sans choix (Mindcare prend celui de Windows cette fois).
#[cfg(windows)]
#[test]
fn fichier_pris() {
    use std::os::windows::fs::OpenOptionsExt;
    let d = Dossier::nouveau("pris");
    let f = d.0.join("suite.json");
    std::fs::write(&f, r#"{"micro":"Micro USB"}"#).unwrap();
    let verrou = std::fs::OpenOptions::new().read(true).share_mode(0).open(&f).unwrap();
    let debut = std::time::Instant::now();
    let l = lire(&f, 2);
    assert_eq!((l.etat, l.son.micro), (EtatSuite::Pris, Choix::Absent));
    assert!(debut.elapsed() >= Duration::from_millis(300), "un second essai, 300 ms plus tard");
    // Libéré pendant l'attente : relu
    let fil = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        drop(verrou);
    });
    let l = lire(&f, 3);
    fil.join().unwrap();
    assert_eq!((l.etat, l.son.micro), (EtatSuite::Lu, appareil("Micro USB")));
}
