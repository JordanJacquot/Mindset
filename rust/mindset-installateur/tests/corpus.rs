//! Le corpus cas\installateur (format dans cas\LISEZMOI.md) passé à l'installateur en Rust, sur un faux PC : les
//! mêmes cas que tester-installer.ps1 passe à la version PowerShell, et les mêmes contrôles de l'attendu.
//!
//! Le faux PC est le trait `Systeme` rempli ici : rien ne touche le vrai Windows (ni tâches, ni registre, ni droits,
//! ni programmes) ; chaque action est notée dans un journal, avec les mêmes lignes que le faux PC de la version
//! PowerShell (« ACTION tâche créée : ... », « RESULTAT ... »). Les fichiers sont vrais, dans un dossier de test, et
//! le faux disque « X: » est un dossier de test.
//!
//! Contre-épreuve : un cas faux glissé dans une copie du corpus doit faire échouer le test (`contre_epreuve`).

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

use mindset_installateur::installateur::dossier_mindset;
use mindset_installateur::systeme::{
    ActionTache, CompteTache, Disque, Droits, NouvelleTache, Processus, RegleAcces, Systeme, TacheVue, ValeurRegistre,
};
use serde_json::{Map, Value, json};

// =============================================================================================================
// Le faux PC
// =============================================================================================================

/// L'utilisateur du test, et un autre compte du PC.
const SID: &str = "S-1-5-21-1000000001-2000000002-3000000003-1001";
const SID_AUTRE: &str = "S-1-5-21-1111111111-2222222222-3333333333-1001";
const NOM_COMPTE: &str = r"PCTEST\Utilisateur";
const SESSION: u32 = 1;

/// L'état du faux PC propre à un cas (`entree.contexte`).
#[derive(Default, Clone)]
struct Contexte {
    racine: String,
    aide_ancienne: bool,
    taches_restantes: bool,
    demarrage_ko: bool,
    sid_tache: String,
}

struct FauxPc {
    tmp: String,
    windows: String,
    lettre: char,
    lettre_amovible: char,
    ctx: Contexte,
    journal: RefCell<Vec<String>>,
    recu: RefCell<Option<String>>,
    versions: RefCell<BTreeMap<String, String>>,
    /// Pour dossier-protege.json : le vrai Program Files, et les disques vérifiés
    programmes: Option<String>,
    disques_vus: RefCell<Vec<char>>,
}

impl FauxPc {
    fn noter(&self, ligne: &str) {
        // (comme le journal de la version PowerShell, relu ligne par ligne : un texte de plusieurs lignes en donne
        // plusieurs, les lignes vides sont sautées)
        for l in ligne.split(['\r', '\n']) {
            if !l.is_empty() {
                self.journal.borrow_mut().push(l.to_string());
            }
        }
    }
    fn pm(&self) -> String {
        format!(r"{}\ProgramFiles\Mindset", self.tmp)
    }
}

/// La ligne de création d'une tâche, comme la notait le faux Register-ScheduledTask de la version PowerShell.
fn ligne_tache(t: &NouvelleTache) -> String {
    let principal = match &t.compte {
        CompteTache::Systeme => "Principal -UserId S-1-5-18 -LogonType ServiceAccount -RunLevel Highest".to_string(),
        CompteTache::Utilisateur(s) => format!("Principal -UserId {s} -LogonType Interactive -RunLevel Limited"),
    };
    let declencheur = match &t.ouverture_session {
        Some(u) => format!(" -Trigger (Declencheur -AtLogOn -User {u})"),
        None => String::new(),
    };
    format!(
        r"ACTION tâche créée : -TaskPath \Mindset\ -TaskName {} -Action (Action -Execute {} -Argument {} -WorkingDirectory {}){declencheur} -Principal ({principal}) -Settings (Reglages) -Description {} -Force",
        t.nom, t.execute, t.arguments, t.dossier_travail, t.description
    )
}

impl Systeme for FauxPc {
    fn dossier_windows(&self) -> String {
        self.windows.clone()
    }
    fn dossier_systeme(&self) -> String {
        format!(r"{}\System32", self.windows)
    }
    fn dossier_programmes(&self) -> String {
        self.programmes.clone().unwrap_or_else(|| format!(r"{}\ProgramFiles", self.tmp))
    }
    fn exe_courant(&self) -> String {
        format!(r"{}\Mindset\MindsetInstallateur.exe", self.pm())
    }
    fn reel(&self, chemin: &str) -> PathBuf {
        // Le faux disque fixe : un dossier de test (comme le lecteur PowerShell de la version PowerShell)
        let b = chemin.as_bytes();
        if b.len() >= 3 && (b[0] as char).eq_ignore_ascii_case(&self.lettre) && b[1] == b':' && b[2] == b'\\' {
            return PathBuf::from(format!(r"{}\disque\{}", self.tmp, &chemin[3..]));
        }
        PathBuf::from(chemin)
    }

    fn sid_courant(&self) -> String {
        SID.into()
    }
    fn sid_de_compte(&self, compte: &str) -> Option<String> {
        match compte.to_ascii_uppercase().as_str() {
            "SYSTEM" | r"NT AUTHORITY\SYSTEM" => Some("S-1-5-18".into()),
            c if c == NOM_COMPTE.to_ascii_uppercase() => Some(SID.into()),
            _ => None,
        }
    }
    fn compte_de_sid(&self, sid: &str) -> Option<String> {
        match sid {
            SID => Some(NOM_COMPTE.into()),
            SID_AUTRE => Some(r"PCTEST\Autre".into()),
            "S-1-5-18" => Some(r"NT AUTHORITY\SYSTEM".into()),
            _ => None,
        }
    }
    fn profil_brut(&self, sid: &str) -> Option<String> {
        self.noter(&format!(r"LECTURE registre HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{sid}"));
        let p = format!(r"{}\Profils\{sid}", self.tmp);
        // (noté comme Windows le fait : %SystemDrive% au début quand il est sur le disque de Windows)
        if p.get(..2).is_some_and(|d| d.eq_ignore_ascii_case(&self.windows[..2])) {
            return Some(format!("%SystemDrive%{}", &p[2..]));
        }
        Some(p)
    }

    fn disque(&self, lettre: char) -> Option<Disque> {
        self.noter(&format!("LECTURE disque DeviceID='{lettre}:'"));
        self.disques_vus.borrow_mut().push(lettre);
        if self.programmes.is_some() {
            // (dossier-protege.json : Z: n'est pas un disque fixe NTFS, toutes les autres lettres le sont)
            return (lettre != 'Z').then(|| Disque { genre: 3, systeme_fichiers: "NTFS".into() });
        }
        if lettre.eq_ignore_ascii_case(&self.lettre) {
            return Some(Disque { genre: 3, systeme_fichiers: "NTFS".into() });
        }
        if lettre.eq_ignore_ascii_case(&self.lettre_amovible) {
            return Some(Disque { genre: 2, systeme_fichiers: "FAT32".into() });
        }
        None
    }
    fn droits(&self, dossier: &str) -> Option<Droits> {
        self.noter(&format!("LECTURE droits {dossier}"));
        // Ceux d'un dossier posé par l'installateur (propriétaire Administrateurs, utilisateurs en lecture) ;
        // « ouverte » : les utilisateurs peuvent y écrire ; « proprietaire » : il appartient à l'utilisateur
        let proprietaire = if self.ctx.racine == "proprietaire" { SID } else { "S-1-5-32-544" };
        let utilisateurs = if self.ctx.racine == "ouverte" { 0x0013_01BF } else { 0x0012_00A9 };
        Some(Droits {
            proprietaire: Some(proprietaire.into()),
            regles: vec![
                RegleAcces { sid: "S-1-5-32-544".into(), autorise: true, herite_seulement: false, masque: 0x001F_01FF },
                RegleAcces {
                    sid: "S-1-5-32-545".into(),
                    autorise: true,
                    herite_seulement: false,
                    masque: utilisateurs,
                },
                // (un droit qui ne vaut que pour ce qui sera créé dessous, comme « CREATOR OWNER » : ne compte pas)
                RegleAcces { sid: "S-1-3-0".into(), autorise: true, herite_seulement: true, masque: 0x001F_01FF },
            ],
        })
    }
    fn poser_droits_racine(&mut self, dossier: &str) -> Result<(), String> {
        self.noter(&format!("ACTION droits posés sur {dossier}"));
        Ok(())
    }
    fn reprendre_droits_herites(&mut self, dossier: &str) {
        self.noter(&format!("ACTION droits (icacls) {dossier} /reset /T /C /Q"));
    }
    fn poser_proprietaire_admins(&mut self, dossier: &str) -> Result<(), String> {
        self.noter(&format!("ACTION droits posés sur {dossier}"));
        Ok(())
    }
    fn ajouter_droit_modifier(&mut self, dossier: &str, _sid: &str) -> Result<(), String> {
        self.noter(&format!("ACTION droits posés sur {dossier}"));
        Ok(())
    }

    fn registre_lire(&self, cle: &str, nom: &str) -> Option<String> {
        if cle == r"SOFTWARE\Mindset\Installation" && nom == "Recu" && self.recu.borrow().is_some() {
            return self.recu.borrow().clone();
        }
        if cle == r"SOFTWARE\Mindset\Versions"
            && let Some(v) = self.versions.borrow().get(nom)
        {
            return Some(v.clone());
        }
        self.noter(&format!(r"LECTURE registre HKLM:\{cle} {nom}"));
        None
    }
    fn registre_existe(&self, cle: &str) -> bool {
        self.noter(&format!(r"LECTURE registre HKLM:\{cle}"));
        true
    }
    fn registre_creer(&mut self, cle: &str) -> Result<(), String> {
        if cle == r"SOFTWARE\Mindset\Installation" {
            self.noter(&format!(r"REPONSE clé HKLM:\{cle}"));
        } else {
            self.noter(&format!(r"ACTION registre : création de HKLM:\{cle}"));
        }
        Ok(())
    }
    fn registre_ecrire(&mut self, cle: &str, nom: &str, valeur: &ValeurRegistre) -> Result<(), String> {
        let v = match valeur {
            ValeurRegistre::Texte(t) => t.clone(),
            ValeurRegistre::Nombre(n) => n.to_string(),
        };
        if cle == r"SOFTWARE\Mindset\Versions" {
            self.versions.borrow_mut().insert(nom.to_string(), v.clone());
        }
        if cle == r"SOFTWARE\Mindset\Installation" {
            match nom {
                "Resultat" => {
                    self.noter(&format!("RESULTAT {v}"));
                    return Ok(());
                }
                "Recu" => {
                    self.noter(&format!("RECU {v}"));
                    *self.recu.borrow_mut() = Some(v);
                    return Ok(());
                }
                "Restes" => {
                    self.noter(&format!("RESTES {v}"));
                    return Ok(());
                }
                // (la liste des applis qui a servi : une note, pas une action)
                "Liste" => {
                    self.noter(&format!("LISTE {v}"));
                    return Ok(());
                }
                _ => {}
            }
        }
        self.noter(&format!(r"ACTION registre : HKLM:\{cle}\{nom} = {v}"));
        Ok(())
    }
    fn registre_supprimer(&mut self, cle: &str) -> Result<(), String> {
        self.noter(&format!(r"ACTION registre : suppression de HKLM:\{cle}"));
        Ok(())
    }

    fn taches(&self, dossier: Option<&str>) -> Vec<TacheVue> {
        self.noter(&format!("LECTURE tâches {}", dossier.unwrap_or("")));
        let act = |e: &str| ActionTache { execute: Some(e.to_string()), arguments: String::new() };
        let t = |d: &str, n: &str, c: Option<&str>, a: Vec<ActionTache>| TacheVue {
            dossier: d.into(),
            nom: n.into(),
            compte: c.map(str::to_string),
            actions: a,
        };
        if dossier == Some(r"\Mindset\") {
            if self.ctx.taches_restantes {
                return vec![t(r"\Mindset\", "Mindset (démarrage)", Some(SID), vec![])];
            }
            if self.ctx.aide_ancienne {
                // Des tâches d'aide d'avant (Mindset 2.10.0) : celle de l'utilisateur (à refaire en SYSTEM), celle d'un
                // autre compte, une vers un programme hors du dossier protégé, une déjà en SYSTEM
                let pm = self.pm();
                let aide = format!("\"{pm}\\Appli\\Aide.exe\"");
                return vec![
                    t(r"\Mindset\", "Appli (aide)", Some(NOM_COMPTE), vec![act(&aide)]),
                    t(r"\Mindset\", "Autre (aide)", Some(SID_AUTRE), vec![act(&aide)]),
                    t(
                        r"\Mindset\",
                        "Piege (aide)",
                        Some(SID),
                        vec![act(&format!("\"{}\\victime\\Aide.exe\"", self.tmp))],
                    ),
                    t(r"\Mindset\", "Deja (aide)", Some("SYSTEM"), vec![act(&aide)]),
                ];
            }
            return vec![];
        }
        // Les tâches du PC : celles qui lancent l'ancienne copie d'une appli, de tous les genres
        let anc = format!(r"{}\ancienne\Appli.exe", self.tmp);
        vec![
            t("\\", "Appli (démarrage)", Some(SID), vec![act(&format!("\"{anc}\"")), act(r"C:\Autre\Autre.exe")]),
            t("\\", "Antivirus", Some("S-1-5-18"), vec![act(&anc)]),
            t(r"\Microsoft\Windows\Defrag\", "Windows", Some(SID), vec![act(&anc)]),
            t(r"\Mindset\", "Mindset (aide)", Some(SID), vec![act(&anc)]),
            t("\\", "Autre compte", Some(SID_AUTRE), vec![act(&anc)]),
            t("\\", "Groupe", None, vec![act(&anc)]),
        ]
    }
    fn tache(&self, dossier: &str, nom: &str) -> Option<TacheVue> {
        self.noter(&format!("LECTURE tâches {dossier}{nom}"));
        if dossier == r"\Mindset\" && nom == "Mindset (installation)" && !self.ctx.sid_tache.is_empty() {
            return Some(TacheVue {
                dossier: dossier.into(),
                nom: nom.into(),
                compte: Some(self.ctx.sid_tache.clone()),
                actions: vec![],
            });
        }
        None
    }
    fn enregistrer_tache(&mut self, tache: &NouvelleTache) -> Result<(), String> {
        self.noter(&ligne_tache(tache));
        Ok(())
    }
    fn droits_tache(&mut self, nom: &str, sddl: &str) -> Result<(), String> {
        self.noter(&format!("LECTURE tâche {nom}"));
        self.noter(&format!("ACTION droits de la tâche : {sddl}"));
        Ok(())
    }
    fn retirer_tache(&mut self, dossier: &str, nom: &str) {
        self.noter(&format!(
            "ACTION tâche retirée : -TaskPath {dossier} -TaskName {nom} -Confirm:False -ErrorAction SilentlyContinue"
        ));
    }
    fn retirer_dossier_taches(&mut self, nom: &str) {
        self.noter(&format!("ACTION dossier de tâches retiré : {nom}"));
    }
    fn modifier_actions(&mut self, dossier: &str, nom: &str, actions: &[ActionTache]) -> Result<(), String> {
        let l: Vec<&str> = actions.iter().map(|a| a.execute.as_deref().unwrap_or("")).collect();
        self.noter(&format!("ACTION tâche modifiée : {dossier}{nom} -> {}", l.join(" | ")));
        Ok(())
    }
    fn lancer_tache(&mut self, chemin: &str) -> i32 {
        self.noter(&format!("ACTION lancement schtasks /Run /TN {chemin}"));
        i32::from(self.ctx.demarrage_ko && chemin.contains("(démarrage)"))
    }

    fn pid(&self) -> u32 {
        999
    }
    fn session(&self) -> u32 {
        SESSION
    }
    fn processus(&self) -> Vec<Processus> {
        self.noter("LECTURE programmes ouverts");
        // Mindset lui-même, l'hôte Mindset.exe et l'ancien Appli.exe de l'appli, son aide, une autre appli au nom
        // proche « AppliBis », des copies ailleurs, un processus au chemin illisible, et deux programmes de l'appli
        // ouverts par un autre compte, dans d'autres sessions
        let pm = self.pm();
        let p = |id: u32, c: Option<String>, s: u32| Processus { id, chemin: c, session: s };
        vec![
            p(101, Some(format!(r"{pm}\Mindset\Mindset.exe")), SESSION),
            p(102, Some(format!(r"{pm}\Appli\Mindset.exe")), SESSION),
            p(103, Some(format!(r"{pm}\Appli\Appli.exe")), SESSION),
            p(104, Some(format!(r"{pm}\Appli\Aide.exe")), SESSION),
            p(105, Some(format!(r"{pm}\AppliBis\Appli.exe")), SESSION),
            p(106, Some(format!(r"{}\ailleurs\Appli.exe", self.tmp)), SESSION),
            p(107, Some(format!(r"{}\ailleurs\Mindset.exe", self.tmp)), SESSION),
            p(108, None, SESSION),
            p(109, Some(format!(r"{pm}\Appli\Mindset.exe")), 98),
            p(110, Some(format!(r"{pm}\Appli\Appli.exe")), 99),
        ]
    }
    fn proprietaire_processus(&self, id: u32) -> Option<String> {
        Some(if id == 109 || id == 110 { SID_AUTRE.into() } else { SID.into() })
    }
    fn arreter(&mut self, p: &Processus) {
        self.noter(&format!("ACTION arrêt du programme {}", p.chemin.as_deref().unwrap_or("")));
    }
    fn attendre_fin(&mut self, pid: i32, secondes: u32) {
        self.noter(&format!("LECTURE attente -Id {pid} -Timeout {secondes} -ErrorAction Stop"));
    }
    fn pause(&mut self, _millisecondes: u64) {}
    fn lancer_par_explorateur(&mut self, programme: &str) {
        self.noter(&format!("ACTION lancement {}\\explorer.exe \"{programme}\"", self.windows));
    }
    fn fenetre(&mut self, _texte: &str, _titre: &str) {
        self.noter("ACTION fenêtre");
    }
    fn effacer_au_redemarrage(&mut self, chemin: &str) {
        self.noter(&format!("ACTION effacement au redémarrage de {chemin}"));
    }
}

// =============================================================================================================
// Le dossier de test : zips signés par une clé de TEST, apps.json, état de départ
// =============================================================================================================

/// Le dossier `cas\installateur` du dépôt (le test lit lui-même le corpus)
fn dossier_cas() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(r"..\..\cas\installateur")
}

fn ecrire(chemin: &str, contenu: &[u8]) {
    let p = Path::new(chemin);
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).unwrap();
    }
    std::fs::write(p, contenu).unwrap();
}

/// Un zip en mémoire : (nom, contenu)
fn zip_de(entrees: &[(&str, &str)]) -> Vec<u8> {
    let mut z = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for (nom, contenu) in entrees {
        z.start_file(*nom, o).unwrap();
        z.write_all(contenu.as_bytes()).unwrap();
    }
    z.finish().unwrap().into_inner()
}

/// La signature RSA PKCS#1 v1.5 SHA-256 par la clé de TEST (tests/cle-de-test, au format DER, jamais la clé de la suite)
fn signer(donnees: &[u8]) -> Vec<u8> {
    let pk8 =
        std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join(r"tests\cle-de-test\privee-de-test.der")).unwrap();
    let cle = ring::signature::RsaKeyPair::from_der(&pk8).unwrap();
    let mut sig = vec![0u8; cle.public().modulus_len()];
    cle.sign(&ring::signature::RSA_PKCS1_SHA256, &ring::rand::SystemRandom::new(), donnees, &mut sig).unwrap();
    sig
}

/// Une lettre de disque libre sur ce PC
fn lettres_libres() -> (char, char) {
    let libres: Vec<char> = "QRSTUVWXYPONMLKJIH".chars().filter(|l| !Path::new(&format!(r"{l}:\")).exists()).collect();
    assert!(libres.len() >= 2, "pas assez de lettres de disque libres pour les faux disques");
    (libres[0], libres[1])
}

struct Banc {
    tmp: String,
    valeurs: Vec<(String, String)>,
    lettre: char,
    lettre_amovible: char,
    numero: usize,
}

const APPS_TEST: &str = r#"[
  { "id": "appli", "nom": "Appli", "zip": "Appli.zip", "dossier_zip": "Appli", "ancien_dossier_zip": "AncienAppli", "exe": "Appli.exe", "aide": "Appli (aide)", "aide_exe": "Aide.exe" },
  { "id": "autre", "nom": "Autre", "zip": "Autre.zip", "dossier_zip": "Autre", "exe": "Autre.exe" },
  { "id": "piege", "nom": "..\\Mindset", "zip": "Piege.zip", "dossier_zip": "Piege", "exe": "Piege.exe" }
]"#;

impl Banc {
    fn nouveau() -> Banc {
        let base = std::env::temp_dir().join(format!(
            "mindset-tests-installateur-rust-{}-{}",
            std::process::id(),
            &nouvel_id()[..8]
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        // (en nom long, sans « \\?\ »)
        let tmp = std::fs::canonicalize(&base).unwrap().to_string_lossy().trim_start_matches(r"\\?\").to_string();
        let (lettre, lettre_amovible) = lettres_libres();
        let paquets = format!(r"{tmp}\demandes\telechargements");
        std::fs::create_dir_all(&paquets).unwrap();
        for d in ["journaux", "resultats"] {
            std::fs::create_dir_all(format!(r"{tmp}\{d}")).unwrap();
        }
        let paquet = |nom: &str, entrees: &[(&str, &str)]| -> String {
            let z = zip_de(entrees);
            let f = format!(r"{paquets}\{nom}.zip");
            ecrire(&f, &z);
            ecrire(&format!("{f}.sig"), &signer(&z));
            f
        };
        let zip_appli = paquet(
            "Appli",
            &[
                ("Appli/Appli.exe", "appli 2.0.0"),
                ("Appli/Aide.exe", "aide 2.0.0"),
                ("Appli/fichiers/Appli.ps1", "$AppVersion = '2.0.0'\r\n"),
            ],
        );
        let zip_mindset = paquet(
            "Mindset",
            &[("Mindset/Mindset.exe", "mindset 2.0.0"), ("Mindset/fichiers/Mindset.ps1", "$AppVersion = '2.0.0'\r\n")],
        );
        let sig_fausse = format!(r"{paquets}\fausse.sig");
        ecrire(&sig_fausse, &signer(b"autre chose"));
        // Les dossiers de Mindset fournis par l'installation complète (Action mindset -Source)
        let src_ok = format!(r"{tmp}\sources\Mindset");
        ecrire(&format!(r"{src_ok}\Mindset.exe"), b"mindset nouveau");
        ecrire(&format!(r"{src_ok}\fichiers\Mindset.ps1"), b"$AppVersion = '3.0.0'");
        ecrire(&format!(r"{src_ok}\LISEZMOI.txt"), b"lisez-moi");
        let src_sans_exe = format!(r"{tmp}\sources\SansExe");
        ecrire(&format!(r"{src_sans_exe}\fichiers\Mindset.ps1"), b"$AppVersion = '3.0.0'");
        let src_sans_script = format!(r"{tmp}\sources\SansScript");
        ecrire(&format!(r"{src_sans_script}\Mindset.exe"), b"mindset nouveau");
        // Ce qui est copié dans le dossier de Mindset de test à chaque cas : apps.json et la clé publique de TEST
        let publique =
            std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join(r"tests\cle-de-test\publique-de-test.xml"))
                .unwrap();
        ecrire(&format!(r"{tmp}\copie\cles-publiques\test.xml"), &publique);
        ecrire(&format!(r"{tmp}\copie\apps.json"), APPS_TEST.as_bytes());

        let pf = format!(r"{tmp}\ProgramFiles");
        let pm = format!(r"{pf}\Mindset");
        let windows = windows_du_pc();
        let valeurs = vec![
            ("{tmp}", tmp.clone()),
            ("{pf}", pf.clone()),
            ("{pm}", pm.clone()),
            ("{xa}", lettre_amovible.to_string()),
            ("{x}", lettre.to_string()),
            ("{zip-appli}", zip_appli),
            ("{zip-mindset}", zip_mindset),
            ("{sig-fausse}", sig_fausse),
            ("{src-ok}", src_ok),
            ("{src-sans-exe}", src_sans_exe),
            ("{src-sans-script}", src_sans_script),
            ("{sid}", SID.into()),
            ("{sid-autre}", SID_AUTRE.into()),
            ("{powershell}", format!(r"{windows}\System32\WindowsPowerShell\v1.0\powershell.exe")),
            ("{ancienne}", format!(r"{tmp}\ancienne\Appli.exe")),
            // Ce que lance la tâche d'installation : ici l'exe, à côté de Mindset.exe
            ("{programme-installation}", format!("\"{pm}\\Mindset\\MindsetInstallateur.exe\"")),
            ("{arguments-installation}", "-Argument -Action demande -Sid".to_string()),
        ];
        Banc {
            tmp,
            valeurs: valeurs.into_iter().map(|(k, v)| (k.to_string(), v)).collect(),
            lettre,
            lettre_amovible,
            numero: 0,
        }
    }

    /// Les dossiers que l'installateur pourrait toucher
    fn racines_etat(&self) -> Vec<String> {
        ["ProgramFiles", "disque", "Profils", "victime", "ancienne"]
            .iter()
            .map(|d| format!(r"{}\{d}", self.tmp))
            .collect()
    }

    /// État de départ de chaque cas : Mindset 1.0.0 et une appli 1.0.0 dans Program Files\Mindset (de test), un
    /// dossier « victime » hors de Mindset, un faux disque vide
    fn initialiser_etat(&self) {
        for d in self.racines_etat() {
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
        }
        let pm = format!(r"{}\ProgramFiles\Mindset", self.tmp);
        ecrire(&format!(r"{pm}\Mindset\Mindset.exe"), b"mindset 1.0.0");
        ecrire(&format!(r"{pm}\Mindset\fichiers\Mindset.ps1"), b"$AppVersion = '1.0.0'");
        ecrire(&format!(r"{pm}\Appli\Appli.exe"), b"appli 1.0.0");
        ecrire(&format!(r"{pm}\Appli\Aide.exe"), b"aide 1.0.0");
        ecrire(&format!(r"{pm}\Appli\fichiers\Appli.ps1"), b"$AppVersion = '1.0.0'");
        ecrire(&format!(r"{}\victime\important.txt", self.tmp), "à garder".as_bytes());
        copier_dossier(&format!(r"{}\copie", self.tmp), &format!(r"{pm}\Mindset\fichiers"));
    }

    /// Tous les fichiers (avec leur taille et leur date) et dossiers sous les racines
    fn etat(&self) -> Vec<String> {
        let mut r = Vec::new();
        fn parcourir(d: &Path, r: &mut Vec<String>) {
            let Ok(l) = std::fs::read_dir(d) else { return };
            for e in l.flatten() {
                let p = e.path();
                if e.file_type().is_ok_and(|t| t.is_dir()) {
                    r.push(format!(r"{}\", p.display()));
                    parcourir(&p, r);
                } else if let Ok(m) = e.metadata() {
                    r.push(format!("{}|{}|{:?}", p.display(), m.len(), m.modified().ok()));
                }
            }
        }
        for d in self.racines_etat() {
            parcourir(Path::new(&d), &mut r);
        }
        r.sort();
        r
    }
}

impl Drop for Banc {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.tmp);
    }
}

fn windows_du_pc() -> String {
    std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into())
}

fn copier_dossier(de: &str, vers: &str) {
    std::fs::create_dir_all(vers).unwrap();
    for e in std::fs::read_dir(de).unwrap().flatten() {
        let cible = Path::new(vers).join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copier_dossier(&e.path().to_string_lossy(), &cible.to_string_lossy());
        } else {
            std::fs::copy(e.path(), cible).unwrap();
        }
    }
}

// =============================================================================================================
// Les cas
// =============================================================================================================

/// Remplace les {valeurs} dans un texte ; une {valeur} inconnue fait échouer le test.
fn developper(t: &str, valeurs: &[(String, String)]) -> Result<String, String> {
    let mut r = t.to_string();
    for (k, v) in valeurs {
        r = r.replace(k.as_str(), v);
    }
    // ({a-z...} restant : une valeur inconnue)
    let o = r.as_bytes();
    for (i, c) in o.iter().enumerate() {
        if *c == b'{'
            && let Some(f) = r[i + 1..].find('}')
        {
            let nom = &r[i + 1..i + 1 + f];
            if !nom.is_empty()
                && nom.as_bytes()[0].is_ascii_lowercase()
                && nom.bytes().all(|b| b.is_ascii_lowercase() || b == b'-')
            {
                return Err(format!("valeur inconnue dans le corpus : {{{nom}}}"));
            }
        }
    }
    Ok(r)
}

/// Une valeur du corpus, avec les {valeurs} remplacées partout (textes, noms des champs, listes)
fn developper_json(v: &Value, valeurs: &[(String, String)]) -> Result<Value, String> {
    Ok(match v {
        Value::String(s) => Value::String(developper(s, valeurs)?),
        Value::Array(a) => Value::Array(a.iter().map(|x| developper_json(x, valeurs)).collect::<Result<_, _>>()?),
        Value::Object(o) => {
            let mut m = Map::new();
            for (k, x) in o {
                m.insert(developper(k, valeurs)?, developper_json(x, valeurs)?);
            }
            Value::Object(m)
        }
        autre => autre.clone(),
    })
}

/// La base du fichier complétée par le cas : un champ du cas remplace celui de la base ; un champ à null le retire
/// (`garder_null` : il reste, à null)
fn joindre_base(base: Option<&Value>, cas: Option<&Value>, garder_null: bool) -> Map<String, Value> {
    let mut d = base.and_then(Value::as_object).cloned().unwrap_or_default();
    if let Some(c) = cas.and_then(Value::as_object) {
        for (k, v) in c {
            if v.is_null() && !garder_null {
                d.remove(k);
            } else {
                d.insert(k.clone(), v.clone());
            }
        }
    }
    d
}

/// Ce qu'a donné un cas
struct Resultat {
    lignes: Vec<String>,
    actions: Vec<String>,
    reponse: Option<Value>,
    registre: bool,
    inchange: bool,
    erreur: bool,
    demande: String,
    id: String,
    versions: BTreeMap<String, String>,
}

const CHAMPS_ENTREE: [&str; 8] =
    ["lancement", "demande", "demande_texte", "demande_absente", "taille", "sid", "sans_resultat", "contexte"];
const CHAMPS_CONTEXTE: [&str; 10] = [
    "fichiers",
    "retirer",
    "copier",
    "version_gardee",
    "racine",
    "aide_ancienne",
    "taches_restantes",
    "demarrage_ko",
    "sid_tache",
    "recu",
];
const CHAMPS_ATTENDU: [&str; 26] = [
    "reponse",
    "message",
    "message_exact",
    "message_absent",
    "id_rendu",
    "registre",
    "rien_fait",
    "actions_permises",
    "actions",
    "actions_absentes",
    "actions_absentes_motif",
    "taches_creees",
    "sans_tache",
    "versions",
    "existe",
    "absent",
    "version_gardee",
    "erreur",
    "arrets",
    "nb_arrets",
    "arrets_absents",
    "lignes",
    "lignes_absentes",
    "taches_modifiees",
    "demande_gardee",
    "avant",
];

fn texte(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        autre => autre.to_string(),
    }
}

fn nouvel_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
    let a = h.finish();
    h.write_u64(a);
    format!("{:016x}{:016x}", a, h.finish())
}

impl Banc {
    /// Passe un cas du corpus à l'installateur
    fn lancer(&mut self, corpus: &Value, cas: &Value) -> Result<(Resultat, Map<String, Value>), String> {
        self.numero += 1;
        let id = nouvel_id();
        let mut valeurs = self.valeurs.clone();
        valeurs.push(("{id}".into(), id.clone()));
        let e = developper_json(cas.get("entree").ok_or("cas sans entree")?, &valeurs)?;
        let a = developper_json(cas.get("attendu").ok_or("cas sans attendu")?, &valeurs)?;
        let e = e.as_object().ok_or("entree n'est pas un objet")?.clone();
        let a = a.as_object().ok_or("attendu n'est pas un objet")?.clone();
        if let Some(k) = e.keys().find(|k| !CHAMPS_ENTREE.contains(&k.as_str())) {
            return Err(format!("champ d'entrée inconnu : {k}"));
        }
        let base = match corpus.get("base") {
            Some(b) => Some(developper_json(b, &valeurs)?),
            None => None,
        };
        let donne_id = e.get("demande").and_then(Value::as_object).is_some_and(|d| d.contains_key("Id"));
        let mut demande = joindre_base(base.as_ref().and_then(|b| b.get("demande")), e.get("demande"), false);
        let ctx = joindre_base(base.as_ref().and_then(|b| b.get("contexte")), e.get("contexte"), true);
        if let Some(k) = ctx.keys().find(|k| !CHAMPS_CONTEXTE.contains(&k.as_str())) {
            return Err(format!("champ de contexte inconnu : {k}"));
        }
        let lancement = texte(e.get("lancement").unwrap_or(&Value::Null));
        if lancement != "direct" && !donne_id {
            demande.insert("Id".into(), Value::String(id.clone()));
        }

        // L'état du faux PC propre au cas, posé après l'état de départ
        self.initialiser_etat();
        let mut versions = BTreeMap::new();
        versions.insert("appli".to_string(), "1.0.0".to_string());
        if let Some(f) = ctx.get("fichiers").and_then(Value::as_object) {
            for (k, v) in f {
                ecrire(k, texte(v).as_bytes());
            }
        }
        if let Some(c) = ctx.get("copier").and_then(Value::as_object) {
            for (k, v) in c {
                std::fs::copy(k, texte(v)).map_err(|x| format!("copie {k} : {x}"))?;
            }
        }
        for r in ctx.get("retirer").and_then(Value::as_array).cloned().unwrap_or_default() {
            let r = texte(&r);
            let p = Path::new(&r);
            if p.is_dir() {
                std::fs::remove_dir_all(p).unwrap();
            } else {
                std::fs::remove_file(p).unwrap();
            }
        }
        if let Some(v) = ctx.get("version_gardee") {
            versions.clear();
            if !v.is_null() {
                versions.insert("appli".into(), texte(v));
            }
        }
        let faux_ctx = Contexte {
            racine: texte(ctx.get("racine").unwrap_or(&Value::Null)),
            aide_ancienne: ctx.get("aide_ancienne").and_then(Value::as_bool).unwrap_or(false),
            taches_restantes: ctx.get("taches_restantes").and_then(Value::as_bool).unwrap_or(false),
            demarrage_ko: ctx.get("demarrage_ko").and_then(Value::as_bool).unwrap_or(false),
            sid_tache: texte(ctx.get("sid_tache").unwrap_or(&Value::Null)),
        };
        let recu = ctx.get("recu").map(texte).filter(|r| !r.is_empty());

        // Les paramètres, comme la tâche ou la demande de Windows les donnent
        let fichier_reponse = format!(r"{}\resultats\{}.json", self.tmp, self.numero);
        let mut args: Vec<String> = Vec::new();
        let mut fichier_demande = String::new();
        match lancement.as_str() {
            "direct" => {
                for (k, v) in &demande {
                    args.push(format!("-{k}"));
                    args.push(texte(v));
                }
            }
            "tache" | "ancienne-tache" => {
                fichier_demande = if e.get("demande_absente").and_then(Value::as_bool).unwrap_or(false) {
                    format!(r"{}\demandes\absente.demande", self.tmp)
                } else {
                    let mut t = match e.get("demande_texte") {
                        Some(x) => texte(x),
                        None => Value::Object(demande.clone()).to_string(),
                    };
                    if let Some(n) = e.get("taille").and_then(Value::as_u64) {
                        let manque = (n as usize).saturating_sub(t.len());
                        t.push_str(&" ".repeat(manque));
                    }
                    let f = format!(r"{}\demandes\{}.demande", self.tmp, nouvel_id());
                    ecrire(&f, t.as_bytes());
                    f
                };
                args.extend([
                    "-Action".to_string(),
                    "demande".to_string(),
                    "-Demande".to_string(),
                    fichier_demande.clone(),
                ]);
                if lancement == "tache" {
                    match e.get("sid") {
                        None => args.extend(["-Sid".to_string(), SID.to_string()]),
                        Some(Value::Null) => {}
                        Some(s) => args.extend(["-Sid".to_string(), texte(s)]),
                    }
                }
            }
            autre => return Err(format!("lancement inconnu : {autre}")),
        }
        let sans_resultat = e.get("sans_resultat").and_then(Value::as_bool).unwrap_or(false);
        if !sans_resultat && !args.iter().any(|x| x.eq_ignore_ascii_case("-Resultat")) {
            args.extend(["-Resultat".to_string(), fichier_reponse.clone()]);
        }

        let avant = self.etat();
        let mut pc = FauxPc {
            tmp: self.tmp.clone(),
            windows: windows_du_pc(),
            lettre: self.lettre,
            lettre_amovible: self.lettre_amovible,
            ctx: faux_ctx,
            journal: RefCell::new(Vec::new()),
            recu: RefCell::new(recu),
            versions: RefCell::new(versions),
            programmes: None,
            disques_vus: RefCell::new(Vec::new()),
        };
        let r = mindset_installateur::executer(&args, &mut pc);
        match &r {
            Ok(()) => pc.noter("FIN"),
            Err(m) => pc.noter(&format!("ERREUR {m}")),
        }
        let mut lignes = pc.journal.borrow().clone();
        let apres = self.etat();
        let mut changes = Vec::new();
        for x in &avant {
            if !apres.contains(x) {
                changes.push(format!("FICHIER avant : {x}"));
            }
        }
        for x in &apres {
            if !avant.contains(x) {
                changes.push(format!("FICHIER après : {x}"));
            }
        }
        let rr: Vec<&String> = lignes.iter().filter(|l| l.starts_with("RESULTAT ")).collect();
        let reponse = match rr.last() {
            Some(l) => serde_json::from_str(&l["RESULTAT ".len()..]).ok(),
            None => std::fs::read_to_string(&fichier_reponse).ok().and_then(|t| serde_json::from_str(&t).ok()),
        };
        let registre = !rr.is_empty();
        let actions =
            lignes.iter().filter(|l| l.starts_with("ACTION ") || l.starts_with("INTERDIT ")).cloned().collect();
        let inchange = changes.is_empty();
        lignes.extend(changes);
        let versions = pc.versions.borrow().clone();
        Ok((
            Resultat {
                lignes,
                actions,
                reponse,
                registre,
                inchange,
                erreur: r.is_err(),
                demande: fichier_demande,
                id,
                versions,
            },
            a,
        ))
    }
}

// =============================================================================================================
// Les contrôles de l'attendu (comme Test-AttenduCas de tester-installer.ps1)
// =============================================================================================================

/// `-like` de PowerShell (sans tenir compte des majuscules) : « * » et « ? »
fn comme(texte: &str, motif: &str) -> bool {
    fn m(t: &[char], p: &[char]) -> bool {
        match p.first() {
            None => t.is_empty(),
            Some('*') => (0..=t.len()).any(|i| m(&t[i..], &p[1..])),
            Some('?') => !t.is_empty() && m(&t[1..], &p[1..]),
            Some(c) => !t.is_empty() && egal_car(t[0], *c) && m(&t[1..], &p[1..]),
        }
    }
    let t: Vec<char> = texte.chars().collect();
    let p: Vec<char> = motif.chars().collect();
    m(&t, &p)
}

fn egal_car(a: char, b: char) -> bool {
    a == b || a.to_lowercase().eq(b.to_lowercase())
}

/// Une petite expression régulière (comme `-match` : sans tenir compte des majuscules) : littéraux, « . », « \x »,
/// groupes « (a|b) », « (?!...) », quantificateurs « * + ? », ancres « ^ $ ». Assez pour les motifs du corpus.
mod expr {
    #[derive(Debug, Clone)]
    enum Noeud {
        Car(char),
        Point,
        Debut,
        Fin,
        Groupe(Vec<Vec<Noeud>>),
        PasSuivi(Vec<Vec<Noeud>>),
        Repete(Box<Noeud>, usize, usize),
    }

    fn lire_alternatives(p: &[char], i: &mut usize) -> Vec<Vec<Noeud>> {
        let mut alts = vec![Vec::new()];
        while *i < p.len() {
            let c = p[*i];
            match c {
                ')' => break,
                '|' => {
                    *i += 1;
                    alts.push(Vec::new());
                    continue;
                }
                _ => {}
            }
            let atome = match c {
                '(' => {
                    *i += 1;
                    let pas = p.get(*i) == Some(&'?') && p.get(*i + 1) == Some(&'!');
                    if pas {
                        *i += 2;
                    }
                    let g = lire_alternatives(p, i);
                    *i += 1; // ')'
                    if pas { Noeud::PasSuivi(g) } else { Noeud::Groupe(g) }
                }
                '\\' => {
                    *i += 2;
                    Noeud::Car(p[*i - 1])
                }
                '.' => {
                    *i += 1;
                    Noeud::Point
                }
                '^' => {
                    *i += 1;
                    Noeud::Debut
                }
                '$' => {
                    *i += 1;
                    Noeud::Fin
                }
                autre => {
                    *i += 1;
                    Noeud::Car(autre)
                }
            };
            let atome = match p.get(*i) {
                Some('*') => {
                    *i += 1;
                    Noeud::Repete(Box::new(atome), 0, usize::MAX)
                }
                Some('+') => {
                    *i += 1;
                    Noeud::Repete(Box::new(atome), 1, usize::MAX)
                }
                Some('?') => {
                    *i += 1;
                    Noeud::Repete(Box::new(atome), 0, 1)
                }
                _ => atome,
            };
            alts.last_mut().unwrap().push(atome);
        }
        alts
    }

    /// Les positions où peut finir la suite `n` commencée en `pos`
    fn suite(n: &[Noeud], t: &[char], pos: usize, k: &mut dyn FnMut(usize) -> bool) -> bool {
        let Some((premier, reste)) = n.split_first() else { return k(pos) };
        noeud(premier, t, pos, &mut |p| suite(reste, t, p, k))
    }

    fn noeud(n: &Noeud, t: &[char], pos: usize, k: &mut dyn FnMut(usize) -> bool) -> bool {
        match n {
            Noeud::Car(c) => pos < t.len() && super::egal_car(t[pos], *c) && k(pos + 1),
            Noeud::Point => pos < t.len() && t[pos] != '\n' && k(pos + 1),
            Noeud::Debut => pos == 0 && k(pos),
            Noeud::Fin => pos == t.len() && k(pos),
            Noeud::Groupe(alts) => alts.iter().any(|a| suite(a, t, pos, k)),
            Noeud::PasSuivi(alts) => !alts.iter().any(|a| suite(a, t, pos, &mut |_| true)) && k(pos),
            Noeud::Repete(x, min, max) => repete(x, *min, *max, t, pos, 0, k),
        }
    }

    fn repete(
        x: &Noeud,
        min: usize,
        max: usize,
        t: &[char],
        pos: usize,
        n: usize,
        k: &mut dyn FnMut(usize) -> bool,
    ) -> bool {
        // (gourmand : le plus de répétitions d'abord)
        if n < max && noeud(x, t, pos, &mut |p| p != pos && repete(x, min, max, t, p, n + 1, k)) {
            return true;
        }
        n >= min && k(pos)
    }

    pub fn trouve(texte: &str, motif: &str) -> bool {
        let p: Vec<char> = motif.chars().collect();
        let mut i = 0;
        let alts = lire_alternatives(&p, &mut i);
        let n = vec![Noeud::Groupe(alts)];
        let t: Vec<char> = texte.chars().collect();
        (0..=t.len()).any(|debut| suite(&n, &t, debut, &mut |_| true))
    }
}

fn liste(v: Option<&Value>) -> Vec<String> {
    match v {
        None | Some(Value::Null) => vec![],
        Some(Value::Array(a)) => a.iter().filter(|x| !x.is_null()).map(texte).collect(),
        Some(x) => vec![texte(x)],
    }
}

/// La version installée dans un dossier (lue dans fichiers\<Nom>.ps1)
fn version_installee(dossier: &str) -> String {
    let nom = dossier.rsplit('\\').next().unwrap_or("");
    let f = format!(r"{dossier}\fichiers\{nom}.ps1");
    let Ok(t) = std::fs::read_to_string(f) else { return String::new() };
    let Some(i) = t.find('\'') else { return String::new() };
    let r = &t[i + 1..];
    r.find('\'').map(|j| r[..j].to_string()).unwrap_or_default()
}

fn verifier(r: &Resultat, a: &Map<String, Value>) -> Vec<String> {
    let mut manques = Vec::new();
    for k in a.keys() {
        if !CHAMPS_ATTENDU.contains(&k.as_str()) {
            manques.push(format!("champ attendu inconnu : {k}"));
        }
    }
    let msg = r.reponse.as_ref().and_then(|x| x.get("message")).map(texte).unwrap_or_default();
    let ok = r.reponse.as_ref().and_then(|x| x.get("ok")).and_then(Value::as_bool);
    let action = |t: &str| r.actions.iter().any(|x| x.contains(t));
    if let Some(attendue) = a.get("reponse") {
        let bon = match texte(attendue).as_str() {
            "ok" => ok == Some(true),
            "refus" => ok == Some(false),
            "aucune" => r.reponse.is_none() && !r.registre,
            _ => false,
        };
        if !bon {
            manques.push(format!("réponse attendue : {}", texte(attendue)));
        }
    }
    for m in liste(a.get("message")) {
        if !msg.contains(&m) {
            manques.push(format!("message sans « {m} »"));
        }
    }
    if let Some(m) = a.get("message_exact")
        && msg != texte(m)
    {
        manques.push(format!("message différent de « {} »", texte(m)));
    }
    if let Some(m) = a.get("message_absent")
        && msg.contains(&texte(m))
    {
        manques.push(format!("message avec « {} »", texte(m)));
    }
    if a.get("id_rendu").and_then(Value::as_bool) == Some(true)
        && r.reponse.as_ref().and_then(|x| x.get("id")).map(texte) != Some(r.id.clone())
    {
        manques.push("numéro de la demande pas rendu".into());
    }
    if let Some(x) = a.get("registre").and_then(Value::as_bool)
        && x != r.registre
    {
        manques.push(format!("réponse dans le registre : {x} attendu"));
    }
    if a.get("rien_fait").and_then(Value::as_bool) == Some(true) {
        let permis = liste(a.get("actions_permises"));
        let autres = r.actions.iter().filter(|x| !permis.iter().any(|p| comme(x, p))).count();
        if !r.inchange || autres > 0 {
            manques.push("quelque chose a été fait".into());
        }
    }
    for t in liste(a.get("actions")) {
        if !action(&t) {
            manques.push(format!("action absente : {t}"));
        }
    }
    for t in liste(a.get("actions_absentes")) {
        if action(&t) {
            manques.push(format!("action en trop : {t}"));
        }
    }
    for t in liste(a.get("actions_absentes_motif")) {
        if r.actions.iter().any(|x| expr::trouve(x, &t)) {
            manques.push(format!("action en trop (motif) : {t}"));
        }
    }
    for t in liste(a.get("taches_creees")) {
        let sddl = format!("ACTION droits de la tâche : D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;{SID})");
        let creee = |extra: &dyn Fn(&str) -> bool| {
            r.actions
                .iter()
                .any(|x| x.contains("ACTION tâche créée") && x.contains(&format!("-TaskName {t} -")) && extra(x))
        };
        let bon = if t == "Mindset (installation)" {
            creee(&|x| {
                x.contains("-UserId S-1-5-18 -LogonType ServiceAccount")
                    && x.contains(&format!("-Action demande -Sid {SID} -Demande"))
            }) && action(&sddl)
        } else if t.ends_with(" (aide)") {
            creee(&|x| {
                x.contains("-UserId S-1-5-18 -LogonType ServiceAccount")
                    && x.contains(&format!(" -Argument -Sid {SID} "))
            }) && action(&sddl)
        } else {
            creee(&|x| x.contains(&format!("-UserId {SID} ")))
        };
        if !bon {
            manques.push(format!("tâche pas créée comme attendu : {t}"));
        }
    }
    if a.get("sans_tache").and_then(Value::as_bool) == Some(true) && r.actions.iter().any(|x| comme(x, "ACTION tâche*"))
    {
        manques.push("une tâche a été touchée".into());
    }
    if let Some(v) = a.get("versions").and_then(Value::as_object) {
        for (k, x) in v {
            if version_installee(k) != texte(x) {
                manques.push(format!("version de {k} : {} attendue", texte(x)));
            }
        }
    }
    for t in liste(a.get("existe")) {
        if !Path::new(&t).exists() {
            manques.push(format!("absent : {t}"));
        }
    }
    for t in liste(a.get("absent")) {
        if Path::new(&t).exists() {
            manques.push(format!("présent : {t}"));
        }
    }
    if let Some(v) = a.get("version_gardee") {
        let vu = r.versions.get("appli").cloned();
        let attendu = (!v.is_null()).then(|| texte(v));
        if vu != attendu {
            manques.push(format!("version gardée : {attendu:?} attendue, {vu:?} vue"));
        }
    }
    if let Some(x) = a.get("erreur").and_then(Value::as_bool)
        && x != r.erreur
    {
        manques.push(format!("erreur : {x} attendu"));
    }
    let arrets: Vec<String> = {
        let mut l: Vec<String> =
            r.actions.iter().filter_map(|x| x.strip_prefix("ACTION arrêt du programme ").map(str::to_string)).collect();
        l.sort();
        l
    };
    if let Some(x) = a.get("arrets") {
        let mut attendus = liste(Some(x));
        attendus.sort();
        if arrets != attendus {
            manques.push(format!("programmes fermés : {attendus:?} attendus, {arrets:?} vus"));
        }
    }
    if let Some(n) = a.get("nb_arrets").and_then(Value::as_u64)
        && r.lignes.iter().filter(|l| comme(l, "ACTION arrêt*")).count() as u64 != n
    {
        manques.push(format!("{n} programme(s) fermé(s) attendu(s)"));
    }
    if let Some(x) = a.get("arrets_absents") {
        let interdits = liste(Some(x));
        for p in &arrets {
            if p.is_empty() || interdits.iter().any(|i| p.contains(i.as_str())) {
                manques.push(format!("programme fermé à tort : {p}"));
            }
        }
    }
    for t in liste(a.get("lignes")) {
        if !r.lignes.iter().any(|l| comme(l, &t)) {
            manques.push(format!("ligne absente : {t}"));
        }
    }
    for t in liste(a.get("lignes_absentes")) {
        if r.lignes.iter().any(|l| comme(l, &t)) {
            manques.push(format!("ligne en trop : {t}"));
        }
    }
    if let Some(x) = a.get("taches_modifiees") {
        let vues: Vec<&String> = r.actions.iter().filter(|l| comme(l, "ACTION tâche modifiée*")).collect();
        let vues: Vec<String> = vues.into_iter().cloned().collect();
        if vues != liste(Some(x)) {
            manques.push(format!("tâches modifiées différentes : {vues:?}"));
        }
    }
    if a.get("demande_gardee").and_then(Value::as_bool) == Some(true)
        && (r.demande.is_empty() || !Path::new(&r.demande).exists())
    {
        manques.push("demande effacée".into());
    }
    if let Some(x) = a.get("avant").and_then(Value::as_array) {
        let premier = x.first().map(texte).unwrap_or_default();
        let second = x.get(1).map(texte).unwrap_or_default();
        let i = r.lignes.iter().position(|l| *l == premier);
        let j = r.lignes.iter().position(|l| comme(l, &second));
        if !matches!((i, j), (Some(i), Some(j)) if j > i) {
            manques.push(format!("« {premier} » pas avant « {second} »"));
        }
    }
    manques
}

// =============================================================================================================
// Les tests
// =============================================================================================================

/// Le nombre de cas attendu au moins dans chaque fichier (un cas retiré ou un fichier vidé fait échouer le test)
const MINIMUM_CAS: [(&str, usize); 10] = [
    ("demande.json", 31),
    ("appli.json", 66),
    ("mindset.json", 16),
    ("mindset-maj.json", 9),
    ("taches.json", 11),
    ("supprimer.json", 11),
    ("systeme.json", 12),
    ("ancienne-tache.json", 5),
    ("prise-en-charge.json", 9),
    ("programmes.json", 6),
];

fn lire_corpus(nom: &str) -> Value {
    let t = std::fs::read_to_string(dossier_cas().join(nom)).unwrap_or_else(|e| panic!("{nom} illisible : {e}"));
    serde_json::from_str(t.trim_start_matches('\u{FEFF}')).unwrap_or_else(|e| panic!("{nom} : JSON illisible : {e}"))
}

/// Passe tous les cas d'un corpus ; rend les échecs (nom du cas et ce qui manque, avec le journal)
fn passer(banc: &mut Banc, nom_fichier: &str, corpus: &Value, minimum: usize) -> (usize, Vec<String>) {
    let mut echecs = Vec::new();
    let cas = corpus.get("cas").and_then(Value::as_array).cloned().unwrap_or_default();
    if corpus.get("format") != Some(&json!(1)) || cas.len() < minimum {
        echecs.push(format!("{nom_fichier} : format 1 et au moins {minimum} cas attendus (trouvés : {})", cas.len()));
    }
    let mut noms = HashMap::new();
    for c in &cas {
        let nom = texte(c.get("nom").unwrap_or(&Value::Null));
        if noms.insert(nom.clone(), ()).is_some() {
            echecs.push(format!("{nom_fichier} : nom de cas en double : {nom}"));
        }
        match banc.lancer(corpus, c) {
            Ok((r, a)) => {
                let m = verifier(&r, &a);
                if !m.is_empty() {
                    echecs.push(format!(
                        "{nom_fichier} : {nom}\n    - {}\n    | {}",
                        m.join("\n    - "),
                        r.lignes.join("\n    | ")
                    ));
                }
            }
            Err(e) => echecs.push(format!("{nom_fichier} : {nom} : {e}")),
        }
    }
    (cas.len(), echecs)
}

#[test]
fn corpus_installateur() {
    // Chaque fichier de cas\installateur est lu par un test (ici, ou côté Mindset : cote-mindset-*.json)
    let fichiers: Vec<String> = std::fs::read_dir(dossier_cas())
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".json") && !n.starts_with("cote-mindset-") && n != "dossier-protege.json")
        .collect();
    let connus: Vec<&str> = MINIMUM_CAS.iter().map(|(n, _)| *n).collect();
    let inconnus: Vec<&String> = fichiers.iter().filter(|f| !connus.contains(&f.as_str())).collect();
    assert!(inconnus.is_empty() && fichiers.len() == MINIMUM_CAS.len(), "fichiers de cas non lus : {inconnus:?}");

    let mut banc = Banc::nouveau();
    let mut total = 0;
    let mut echecs = Vec::new();
    for (nom, minimum) in MINIMUM_CAS {
        let corpus = lire_corpus(nom);
        let (n, e) = passer(&mut banc, nom, &corpus, minimum);
        total += n;
        echecs.extend(e);
    }
    println!("corpus cas\\installateur : {} cas sur {total} réussis", total - echecs.len());
    assert!(echecs.is_empty(), "{} échec(s) sur {total} cas :\n{}", echecs.len(), echecs.join("\n\n"));
}

/// Contre-épreuve : un cas faux glissé (une réponse attendue à l'envers) fait échouer le contrôle.
#[test]
fn contre_epreuve() {
    let mut banc = Banc::nouveau();
    let mut corpus = lire_corpus("taches.json");
    let cas = corpus["cas"].as_array_mut().unwrap();
    let premier = cas[0].clone();
    let mut faux = premier.clone();
    faux["nom"] = json!("faux : refus attendu");
    faux["attendu"]["reponse"] = json!("refus");
    let mut faux2 = premier.clone();
    faux2["nom"] = json!("faux : une tâche d'aide attendue");
    faux2["attendu"]["taches_creees"] = json!(["Autre (aide)"]);
    *cas = vec![premier, faux, faux2];
    let (n, echecs) = passer(&mut banc, "taches.json (contre-épreuve)", &corpus, 3);
    assert_eq!(n, 3);
    assert_eq!(echecs.len(), 2, "les deux cas faux doivent échouer, et eux seuls : {echecs:#?}");
}

/// dossier-protege.json : les dossiers acceptés (Test-DossierMindset), avec le vrai Program Files du PC
#[test]
fn corpus_dossier_protege() {
    let corpus = lire_corpus("dossier-protege.json");
    let cas = corpus["cas"].as_array().unwrap();
    assert!(corpus["format"] == json!(1) && cas.len() >= 20, "dossier-protege.json : au moins 20 cas");
    let programmes = std::env::var("ProgramW6432").or_else(|_| std::env::var("ProgramFiles")).unwrap();
    let valeurs = vec![
        ("{programmes-mindset}".to_string(), format!(r"{programmes}\Mindset")),
        ("{windows}".to_string(), windows_du_pc()),
    ];
    let mut echecs = Vec::new();
    for c in cas {
        let pc = FauxPc {
            tmp: String::new(),
            windows: windows_du_pc(),
            lettre: '?',
            lettre_amovible: '?',
            ctx: Contexte::default(),
            journal: RefCell::new(Vec::new()),
            recu: RefCell::new(None),
            versions: RefCell::new(BTreeMap::new()),
            programmes: Some(programmes.clone()),
            disques_vus: RefCell::new(Vec::new()),
        };
        let nom = texte(&c["nom"]);
        let d = developper(&texte(&c["entree"]["dossier"]), &valeurs).unwrap();
        let a = &c["attendu"];
        if let Some(k) = a
            .as_object()
            .unwrap()
            .keys()
            .find(|k| !["accepte", "dossier", "message", "disque_verifie"].contains(&k.as_str()))
        {
            echecs.push(format!("{nom} : champ attendu inconnu {k}"));
        }
        let r = dossier_mindset(&pc, &d);
        let bon = if a["accepte"] == json!(true) {
            let attendu = developper(&texte(&a["dossier"]), &valeurs).unwrap();
            let disque = a.get("disque_verifie").map(texte);
            r.as_deref() == Ok(attendu.as_str())
                && disque.is_none_or(|l| pc.disques_vus.borrow().iter().any(|v| v.to_string() == l))
        } else {
            match &r {
                Err(m) => a.get("message").is_none_or(|x| m.contains(&texte(x))),
                Ok(_) => false,
            }
        };
        if !bon {
            echecs.push(format!("{nom} : {r:?}"));
        }
    }
    assert!(echecs.is_empty(), "{} échec(s) :\n{}", echecs.len(), echecs.join("\n"));
}

// =============================================================================================================
// La liste des applis en ligne (-Liste, Mindset 2.16) : écrite dans le test et non dans cas\installateur, car sa
// signature est faite ici (clé de TEST) et la version PowerShell d'avant (tester-installer.ps1) ne la connaît pas
// =============================================================================================================

/// Une appli qui n'est que dans la liste en ligne
const NOUVELLE: &str = r#"{ "id": "nouvelle", "nom": "Nouvelle", "zip": "Nouvelle.zip", "dossier_zip": "Nouvelle", "exe": "Nouvelle.exe" }"#;

/// Une liste en ligne (Mindset de test : 1.0.0)
fn liste_en_ligne(numero: &str, min: &str, applis: &[&str]) -> Vec<u8> {
    format!(r#"{{ "liste": {numero}, "mindset_min": "{min}", "applis": [ {} ] }}"#, applis.join(", ")).into_bytes()
}

/// Comment la liste est posée pour un cas
enum Pose {
    /// Signée, posée à côté de la demande (le fichier gardé par Mindset)
    Signee(Vec<u8>),
    /// Signée, puis le fichier changé après la signature
    Modifiee(Vec<u8>, Vec<u8>),
    /// Sans son .sig
    SansSignature(Vec<u8>),
    /// Signée, mais posée ailleurs (dans ce dossier de {tmp})
    Ailleurs(Vec<u8>, &'static str),
}

struct CasListe {
    nom: &'static str,
    lancement: &'static str,
    /// L'appli demandée (« nouvelle » ou une de apps.json)
    appli: &'static str,
    pose: Pose,
    /// Le numéro de la liste livrée (fichiers\apps-liste.txt) ; None : fichier absent
    livree: Option<&'static str>,
    /// Passer -Liste (le chemin où la liste est posée)
    donner_liste: bool,
    attendu: Value,
}

fn cas_liste_en_ligne() -> Vec<CasListe> {
    let appli = r#"{ "id": "appli", "nom": "Appli", "zip": "Appli.zip", "dossier_zip": "Appli", "ancien_dossier_zip": "AncienAppli", "exe": "Appli.exe", "aide": "Appli (aide)", "aide_exe": "Aide.exe" }"#;
    let bonne = liste_en_ligne("4", "1.0.0", &[appli, NOUVELLE]);
    let refus = |raison: &str| json!({ "reponse": "refus", "message_exact": "Appli inconnue.", "lignes": [format!("LISTE livrée (liste en ligne refusée : {raison}*")], "absent": ["{pm}\\Nouvelle"] });
    let installee = json!({ "reponse": "ok", "message_exact": "{pm}\\Nouvelle", "lignes": ["LISTE en ligne 4"], "existe": ["{pm}\\Nouvelle\\Nouvelle.exe"], "versions": { "{pm}\\Nouvelle": "1.0.0" } });
    let c = |nom, appli, pose, livree, donner_liste, attendu| CasListe {
        nom,
        lancement: "tache",
        appli,
        pose,
        livree,
        donner_liste,
        attendu,
    };
    let mut gros = liste_en_ligne("4", "1.0.0", &[NOUVELLE]);
    gros.extend(std::iter::repeat_n(b' ', 256 * 1024 + 1 - gros.len()));
    vec![
        c(
            "liste bonne : une appli seulement en ligne est installée",
            "nouvelle",
            Pose::Signee(bonne.clone()),
            Some("3"),
            true,
            installee.clone(),
        ),
        CasListe {
            lancement: "direct",
            ..c(
                "liste bonne en lancement direct (-Liste ailleurs permis) : installée",
                "nouvelle",
                Pose::Ailleurs(bonne.clone(), "listes"),
                Some("3"),
                true,
                json!({ "reponse": "ok", "message_exact": "{pm}\\Nouvelle", "registre": false, "lignes": ["LISTE en ligne 4"] }),
            )
        },
        c(
            "appli seulement en ligne, sans -Liste : « Appli inconnue. », rien fait",
            "nouvelle",
            Pose::Signee(bonne.clone()),
            Some("3"),
            false,
            json!({ "reponse": "refus", "message_exact": "Appli inconnue.", "lignes_absentes": ["LISTE *"], "rien_fait": true }),
        ),
        c(
            "mauvaise signature (liste changée après signature) : apps.json seul",
            "nouvelle",
            Pose::Modifiee(
                bonne.clone(),
                liste_en_ligne(
                    "4",
                    "1.0.0",
                    &[
                        appli,
                        NOUVELLE,
                        r#"{ "id": "piege2", "nom": "Piege2", "zip": "P.zip", "dossier_zip": "P", "exe": "P.exe" }"#,
                    ],
                ),
            ),
            Some("3"),
            true,
            refus("signature invalide"),
        ),
        c(
            "liste changée après signature : une appli de apps.json s'installe quand même",
            "appli",
            Pose::Modifiee(bonne.clone(), liste_en_ligne("4", "1.0.0", &[NOUVELLE])),
            Some("3"),
            true,
            json!({ "reponse": "ok", "message_exact": "{pm}\\Appli", "lignes": ["LISTE livrée (liste en ligne refusée : signature invalide)"] }),
        ),
        c(
            ".sig absent : apps.json seul",
            "nouvelle",
            Pose::SansSignature(bonne.clone()),
            Some("3"),
            true,
            refus("signature absente"),
        ),
        c(
            "numéro égal à celui de la liste livrée : apps.json seul",
            "nouvelle",
            Pose::Signee(bonne.clone()),
            Some("4"),
            true,
            refus("liste 4 pas plus récente que la liste livrée (4)"),
        ),
        c(
            "numéro plus petit que celui de la liste livrée : apps.json seul",
            "nouvelle",
            Pose::Signee(bonne.clone()),
            Some("7"),
            true,
            refus("liste 4 pas plus récente"),
        ),
        c(
            "apps-liste.txt absent : apps.json seul",
            "nouvelle",
            Pose::Signee(bonne.clone()),
            None,
            true,
            refus("numéro de la liste livrée"),
        ),
        c(
            "mindset_min plus haut que ce Mindset (1.0.0) : apps.json seul",
            "nouvelle",
            Pose::Signee(liste_en_ligne("4", "1.0.1", &[NOUVELLE])),
            Some("3"),
            true,
            refus("liste pour Mindset 1.0.1"),
        ),
        c(
            "JSON abîmé (signé) : apps.json seul",
            "nouvelle",
            Pose::Signee(b"{ \"liste\": 4, \"applis\": [".to_vec()),
            Some("3"),
            true,
            refus("liste mal formée"),
        ),
        c(
            "trop gros (signé) : apps.json seul",
            "nouvelle",
            Pose::Signee(gros),
            Some("3"),
            true,
            refus("fichier trop gros"),
        ),
        c(
            "par la tâche, liste hors du dossier de la demande : apps.json seul",
            "nouvelle",
            Pose::Ailleurs(bonne.clone(), "victime"),
            Some("3"),
            true,
            refus("fichier refusé"),
        ),
        c(
            "liste acceptée sans « appli » : elle remplace apps.json, « appli » est inconnue",
            "appli",
            Pose::Signee(liste_en_ligne("4", "1.0.0", &[NOUVELLE])),
            Some("3"),
            true,
            json!({ "reponse": "refus", "message_exact": "Appli inconnue.", "lignes": ["LISTE en ligne 4"] }),
        ),
        c(
            "entrée mal formée ignorée, le reste pris : l'appli valable s'installe",
            "nouvelle",
            Pose::Signee(liste_en_ligne(
                "4",
                "1.0.0",
                &[
                    r#"{ "id": "piege", "nom": "..\\Mindset", "zip": "P.zip", "dossier_zip": "P", "exe": "P.exe" }"#,
                    NOUVELLE,
                ],
            )),
            Some("3"),
            true,
            installee,
        ),
        c(
            "entrée mal formée ignorée : elle est inconnue",
            "piege",
            Pose::Signee(liste_en_ligne(
                "4",
                "1.0.0",
                &[
                    r#"{ "id": "piege", "nom": "..\\Mindset", "zip": "P.zip", "dossier_zip": "P", "exe": "P.exe" }"#,
                    NOUVELLE,
                ],
            )),
            Some("3"),
            true,
            json!({ "reponse": "refus", "message_exact": "Appli inconnue.", "lignes": ["LISTE en ligne 4"] }),
        ),
        c(
            "deux entrées avec le même id : apps.json seul",
            "nouvelle",
            Pose::Signee(liste_en_ligne("4", "1.0.0", &[NOUVELLE, NOUVELLE])),
            Some("3"),
            true,
            refus("appli « nouvelle » en double"),
        ),
    ]
}

/// Passe un cas de la liste en ligne : pose la liste, lance l'installateur, contrôle l'attendu
fn passer_liste(banc: &mut Banc, zip_nouvelle: &str, c: &CasListe) -> Vec<String> {
    let demandes = format!(r"{}\demandes", banc.tmp);
    for d in ["listes", "victime"] {
        let _ = std::fs::remove_dir_all(format!(r"{}\{d}", banc.tmp));
    }
    let gardee = format!(r"{demandes}\apps-en-ligne.json");
    for f in [gardee.clone(), format!("{gardee}.sig")] {
        let _ = std::fs::remove_file(f);
    }
    let mut chemin = gardee.clone();
    let mut ailleurs = None;
    match &c.pose {
        Pose::Signee(o) => {
            ecrire(&gardee, o);
            ecrire(&format!("{gardee}.sig"), &signer(o));
        }
        Pose::Modifiee(o, apres) => {
            ecrire(&format!("{gardee}.sig"), &signer(o));
            ecrire(&gardee, apres);
        }
        Pose::SansSignature(o) => ecrire(&gardee, o),
        Pose::Ailleurs(o, dossier) => {
            chemin = format!(r"{}\{dossier}\apps-en-ligne.json", banc.tmp);
            ailleurs = Some((chemin.clone(), o.clone()));
        }
    }
    let mut demande = json!({ "Appli": c.appli });
    if c.appli == "nouvelle" {
        demande = json!({ "Appli": "nouvelle", "Zip": zip_nouvelle, "Signature": format!("{zip_nouvelle}.sig"),
            "Destination": "{pm}\\Nouvelle", "DossierZip": "Nouvelle", "Exe": "Nouvelle.exe" });
    }
    if c.donner_liste {
        demande["Liste"] = json!(chemin);
    }
    let mut fichiers = Map::new();
    if let Some(n) = c.livree {
        fichiers.insert(r"{pm}\Mindset\fichiers\apps-liste.txt".into(), json!(n));
    }
    let corpus = json!({ "format": 1, "base": { "demande": { "Action": "appli", "Appli": "appli", "Zip": "{zip-appli}",
        "Signature": "{zip-appli}.sig", "Destination": "{pm}\\Appli", "DossierZip": "Appli", "Exe": "Appli.exe" } } });
    let mut cas = json!({ "nom": c.nom, "entree": { "lancement": c.lancement, "demande": demande, "contexte": { "fichiers": fichiers } },
        "attendu": c.attendu });
    // Posée ailleurs : copiée par le contexte « copier », après la remise à zéro du faux PC (qui recrée « victime »
    // vide ; « listes » est créé ici)
    if let Some((f, o)) = &ailleurs {
        let source = format!(r"{}\sources-listes\apps-en-ligne.json", banc.tmp);
        ecrire(&source, o);
        ecrire(&format!("{source}.sig"), &signer(o));
        std::fs::create_dir_all(Path::new(f).parent().unwrap()).unwrap();
        cas["entree"]["contexte"]["copier"] =
            json!({ source.clone(): f.clone(), format!("{source}.sig"): format!("{f}.sig") });
    }
    match banc.lancer(&corpus, &cas) {
        Ok((r, a)) => {
            let m = verifier(&r, &a);
            if m.is_empty() {
                Vec::new()
            } else {
                vec![format!("{}\n    - {}\n    | {}", c.nom, m.join("\n    - "), r.lignes.join("\n    | "))]
            }
        }
        Err(e) => vec![format!("{} : {e}", c.nom)],
    }
}

/// Le zip signé de l'appli « nouvelle » (1.0.0), dans le dossier telechargements de l'utilisateur
fn zip_nouvelle(banc: &Banc) -> String {
    let z = zip_de(&[
        ("Nouvelle/Nouvelle.exe", "nouvelle 1.0.0"),
        ("Nouvelle/fichiers/Nouvelle.ps1", "$AppVersion = '1.0.0'\r\n"),
    ]);
    let f = format!(r"{}\demandes\telechargements\Nouvelle.zip", banc.tmp);
    ecrire(&f, &z);
    ecrire(&format!("{f}.sig"), &signer(&z));
    f
}

#[test]
fn liste_en_ligne_installateur() {
    let mut banc = Banc::nouveau();
    let zip = zip_nouvelle(&banc);
    let cas = cas_liste_en_ligne();
    let mut echecs = Vec::new();
    for c in &cas {
        echecs.extend(passer_liste(&mut banc, &zip, c));
    }
    println!("liste en ligne : {} cas sur {} réussis", cas.len() - echecs.len(), cas.len());
    assert!(echecs.is_empty(), "{} échec(s) sur {} cas :\n{}", echecs.len(), cas.len(), echecs.join("\n\n"));
}

/// Contre-épreuve : un attendu à l'envers fait échouer le contrôle (la liste acceptée, puis la liste refusée).
#[test]
fn liste_en_ligne_contre_epreuve() {
    let mut banc = Banc::nouveau();
    let zip = zip_nouvelle(&banc);
    let mut cas = cas_liste_en_ligne();
    let mut faux_ok = cas.remove(0);
    faux_ok.attendu["reponse"] = json!("refus");
    let mut faux_refus = cas.remove(2);
    faux_refus.attendu["reponse"] = json!("ok");
    assert_eq!(passer_liste(&mut banc, &zip, &faux_ok).len(), 1);
    assert_eq!(passer_liste(&mut banc, &zip, &faux_refus).len(), 1);
}
