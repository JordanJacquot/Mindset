//! Les cas du travail, sur un faux Windows (processus, registre, tâches en mémoire) et de vrais fichiers dans un dossier
//! de test. Les mêmes situations que outils\tester-desinstallation.ps1, plus celles qu'un essai réel ne peut pas
//! provoquer (Planificateur qui ne répond pas, registre qui refuse...).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use super::*;
use crate::fin::texte_bilan;
use crate::systeme::{DossierTaches, ErreurTache, Fin, LectureTaches, Ruche, Systeme};

/// Un faux désinstalleur d'appli : ce qu'il fait quand on le lance
#[derive(Clone, Copy, PartialEq, Eq)]
enum Comportement {
    /// Efface les .exe de son dossier (sauf lui), et ses données avec -SupprimerDonnees
    Normal,
    /// Ancienne version : efface aussi ses données avec -GarderDonnees
    Ancien,
    /// Échoue (code 3) sans rien effacer
    Echec,
    /// Ne se lance pas
    Introuvable,
}

#[derive(Default)]
struct Faux {
    /// (numéro, chemin, ligne de commande)
    processus: Mutex<Vec<(u32, String, String)>>,
    fermes: Mutex<Vec<u32>>,
    /// clé (ruche:chemin en minuscules) -> valeurs
    registre: Mutex<BTreeMap<String, BTreeMap<String, String>>>,
    registre_refuse: Mutex<bool>,
    /// dossiers de tâches (chemin) et tâches (chemin complet)
    dossiers: Mutex<BTreeSet<String>>,
    taches: Mutex<BTreeSet<String>>,
    taches_bloquees: Mutex<BTreeSet<String>>,
    planificateur_absent: Mutex<bool>,
    /// lancés : (exe, argument)
    lances: Mutex<Vec<(String, String)>>,
    comportements: Mutex<BTreeMap<String, Comportement>>,
    donnees: Mutex<Option<PathBuf>>,
}

fn cle(r: Ruche, c: &str) -> String {
    format!("{:?}:{}", r, c.to_lowercase())
}

impl Systeme for Faux {
    fn mon_pid(&self) -> u32 {
        1
    }
    fn processus(&self) -> Vec<(u32, String)> {
        self.processus.lock().unwrap().iter().map(|(p, c, _)| (*p, c.clone())).collect()
    }
    fn ligne_commande(&self, pid: u32) -> Option<String> {
        self.processus.lock().unwrap().iter().find(|x| x.0 == pid).map(|x| x.2.clone())
    }
    fn fermer(&self, pid: u32, _attente: Duration) -> Result<(), String> {
        self.processus.lock().unwrap().retain(|x| x.0 != pid);
        self.fermes.lock().unwrap().push(pid);
        Ok(())
    }
    fn tourne_nomme(&self, _nom: &str) -> bool {
        false
    }
    fn lancer_et_attendre(&self, exe: &Path, argument: &str, dossier: &Path, _l: Duration) -> Result<Fin, String> {
        let nom_exe = t(exe);
        self.lances.lock().unwrap().push((nom_exe.clone(), argument.to_string()));
        let c = self.comportements.lock().unwrap().get(&nom(&nom_exe)).copied().unwrap_or(Comportement::Normal);
        match c {
            Comportement::Introuvable => return Err("Le fichier spécifié est introuvable.".into()),
            Comportement::Echec => return Ok(Fin::Code(3)),
            _ => {}
        }
        let appli = nom(&t(dossier));
        if (argument == "-SupprimerDonnees" || c == Comportement::Ancien)
            && let Some(d) = self.donnees.lock().unwrap().clone()
        {
            let _ = std::fs::remove_dir_all(d.join(&appli));
        }
        for f in std::fs::read_dir(dossier).unwrap().flatten() {
            let p = f.path();
            if p.extension().is_some_and(|e| e == "exe") && !egal(&t(&p), &nom_exe) {
                std::fs::remove_file(p).unwrap();
            }
        }
        Ok(Fin::Code(0))
    }
    fn nom_ruche(&self, r: Ruche) -> String {
        match r {
            Ruche::Machine => "HKEY_LOCAL_MACHINE".into(),
            Ruche::Utilisateur => "HKEY_CURRENT_USER".into(),
        }
    }
    fn cle_existe(&self, r: Ruche, c: &str) -> Result<bool, String> {
        if *self.registre_refuse.lock().unwrap() {
            return Err("Accès refusé.".into());
        }
        let k = cle(r, c);
        Ok(self.registre.lock().unwrap().keys().any(|x| *x == k || x.starts_with(&format!("{k}\\"))))
    }
    fn supprimer_cle(&self, r: Ruche, c: &str) -> Result<(), String> {
        let k = cle(r, c);
        self.registre.lock().unwrap().retain(|x, _| *x != k && !x.starts_with(&format!("{k}\\")));
        Ok(())
    }
    fn valeur_existe(&self, r: Ruche, c: &str, n: &str) -> Result<bool, String> {
        if *self.registre_refuse.lock().unwrap() {
            return Err("Accès refusé.".into());
        }
        Ok(self.registre.lock().unwrap().get(&cle(r, c)).is_some_and(|v| v.contains_key(n)))
    }
    fn supprimer_valeur(&self, r: Ruche, c: &str, n: &str) -> Result<(), String> {
        if let Some(v) = self.registre.lock().unwrap().get_mut(&cle(r, c)) {
            v.remove(n);
        }
        Ok(())
    }
    fn ecrire_texte_si_cle(&self, r: Ruche, c: &str, n: &str, valeur: &str) -> Result<(), String> {
        if let Some(v) = self.registre.lock().unwrap().get_mut(&cle(r, c)) {
            v.insert(n.into(), valeur.into());
        }
        Ok(())
    }
    fn dossier_taches(&self, chemin: &str) -> Result<Option<DossierTaches>, LectureTaches> {
        if *self.planificateur_absent.lock().unwrap() {
            return Err(LectureTaches::Connexion("Le service n'est pas disponible.".into()));
        }
        if !self.dossiers.lock().unwrap().contains(chemin) {
            return Ok(None);
        }
        let enfant = |x: &String| x.rsplit_once('\\').map(|(p, n)| (p.to_string(), n.to_string()));
        let mut d = DossierTaches::default();
        for x in self.dossiers.lock().unwrap().iter() {
            if let Some((p, n)) = enfant(x)
                && p == chemin
            {
                d.sous_dossiers.push((n, x.clone()));
            }
        }
        for x in self.taches.lock().unwrap().iter() {
            if let Some((p, n)) = enfant(x)
                && p == chemin
            {
                d.taches.push((n, x.clone()));
            }
        }
        Ok(Some(d))
    }
    fn arreter_tache(&self, _chemin: &str) {}
    fn supprimer_tache(&self, dossier: &str, n: &str) -> Result<(), ErreurTache> {
        let c = format!("{dossier}\\{n}");
        if self.taches_bloquees.lock().unwrap().contains(&c) {
            return Err(ErreurTache { absent: false, message: "Accès refusé.".into() });
        }
        if !self.taches.lock().unwrap().remove(&c) {
            return Err(ErreurTache { absent: true, message: "introuvable".into() });
        }
        Ok(())
    }
    fn supprimer_dossier_taches(&self, parent: &str, n: &str) -> Result<(), ErreurTache> {
        let c = if parent == "\\" { format!("\\{n}") } else { format!("{parent}\\{n}") };
        if self.taches.lock().unwrap().iter().any(|x| x.starts_with(&format!("{c}\\"))) {
            return Err(ErreurTache { absent: false, message: "Le dossier n'est pas vide.".into() });
        }
        if !self.dossiers.lock().unwrap().remove(&c) {
            return Err(ErreurTache { absent: true, message: "introuvable".into() });
        }
        Ok(())
    }
}

/// Un faux environnement complet, comme New-Environnement de tester-desinstallation.ps1
struct Env {
    dossier: PathBuf,
    racine_c: PathBuf,
    mindset: PathBuf,
    exe: PathBuf,
    racine_x: PathBuf,
    donnees: PathBuf,
    bureau: PathBuf,
    menu: PathBuf,
    precieux: PathBuf,
    lieux: Lieux,
    sys: Faux,
}

fn ecrire(p: &Path, contenu: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, contenu).unwrap();
}

fn jonction(lien: &Path, vers: &Path) {
    std::fs::create_dir_all(lien.parent().unwrap()).unwrap();
    let ok = std::process::Command::new("cmd.exe")
        .args(["/c", "mklink", "/J", &t(lien), &t(vers)])
        .output()
        .unwrap()
        .status
        .success();
    assert!(ok, "jonction impossible");
}

const APPS: &str = r#"[{"id":"appli","nom":"Appli","exe":"Appli.exe","desinstalleur":"Désinstaller Appli.exe"},
{"id":"autre","nom":"Autre","exe":"Autre.exe","desinstalleur":"Désinstaller Autre.exe"},
{"id":"evermind","nom":"Evermind","exe":"Evermind.exe"}]"#;

impl Env {
    fn nouveau(nom_env: &str, sans_programme_c: bool, apps_abime: bool) -> Env {
        let dossier = std::env::temp_dir().join(format!(
            "desinst-cargo-{}-{}-{}",
            std::process::id(),
            nom_env,
            crate::os::hasard()
        ));
        let sous = |n: &str| {
            let p = dossier.join(n);
            std::fs::create_dir_all(&p).unwrap();
            p
        };
        let (pf, lad, bureau, menu, temp, disque) =
            (sous("ProgramFiles"), sous("LocalAppData"), sous("Bureau"), sous("Menu"), sous("Temp"), sous("DisqueX"));
        let racine_c = pf.join("Mindset");
        let mindset = racine_c.join("Mindset");
        let exe = mindset.join("Desinstaller Mindset.exe");
        let racine_x = disque.join("Mindset");
        let apps = if apps_abime { r#"[{"id": "appli", "nom": "# } else { APPS };
        if !sans_programme_c {
            ecrire(&mindset.join("Mindset.exe"), "programme");
            ecrire(&exe, "désinstalleur");
            ecrire(&mindset.join("fichiers").join("apps.json"), apps);
            for a in ["Appli", "Autre"] {
                ecrire(&racine_c.join(a).join(format!("{a}.exe")), "programme");
                ecrire(&racine_c.join(a).join(format!("Désinstaller {a}.exe")), "désinstalleur");
                ecrire(&racine_c.join(a).join("fichiers").join(format!("{a}.ps1")), "$AppVersion = '1.0.0'");
            }
            ecrire(&racine_c.join("Evermind").join("Evermind.exe"), "programme");
            // Un fichier en lecture seule (Windows refuse de le supprimer tel quel)
            let lisez = mindset.join("LISEZMOI.txt");
            ecrire(&lisez, "Lis-moi");
            let mut p = std::fs::metadata(&lisez).unwrap().permissions();
            p.set_readonly(true);
            std::fs::set_permissions(&lisez, p).unwrap();
        }
        ecrire(&racine_x.join("Programmes").join("Mindset").join("fichiers").join("apps.json"), apps);
        ecrire(&racine_x.join("Programmes").join("Mindset").join("Mindset.exe"), "programme");
        ecrire(&racine_x.join("Donnees").join("Mindset").join("reglages.json"), "{}");
        ecrire(&racine_x.join("Donnees").join("Evermind").join("rendez-vous.json"), "[]");
        let donnees = lad.join("Mindset");
        ecrire(&donnees.join("suite.json"), "{}");
        ecrire(&donnees.join("Mindset").join("reglages.json"), "{}");
        ecrire(&donnees.join("Mindset").join("installation.demande"), "{}");
        ecrire(&donnees.join("Mindset").join("telechargements").join("appli.zip"), "zip");
        ecrire(&donnees.join("Evermind").join("rendez-vous.json"), "[]");
        ecrire(&donnees.join("Appli").join("parametres.json"), "{}");
        let precieux = dossier.join("precieux");
        ecrire(&precieux.join("important.txt"), "à garder");
        jonction(&donnees.join("Mindset").join("lien"), &precieux);
        for d in [&bureau, &menu] {
            ecrire(&d.join("Mindset.lnk"), "raccourci");
        }
        for a in ["Nevermind", "Evermind"] {
            ecrire(&menu.join("Mindset").join(format!("{a}.lnk")), "raccourci");
        }
        ecrire(&bureau.join("Autre programme.lnk"), "raccourci");
        let lieux = Lieux {
            test: true,
            program_files: pf,
            local_app_data: Some(lad),
            bureau: Some(bureau.clone()),
            menu: Some(menu.clone()),
            temp,
            disques: vec![disque],
            cle_desinstall: "Software\\Test\\Uninstall\\Mindset".into(),
            cle_mindset: "Software\\Test\\Mindset".into(),
            cle_run: "Software\\Test\\Run".into(),
            dossier_taches: "\\MindsetTest".into(),
        };
        let sys = Faux::default();
        {
            let mut r = sys.registre.lock().unwrap();
            r.insert(cle(Ruche::Machine, "Software\\Test\\Uninstall\\Mindset"), BTreeMap::new());
            r.insert(cle(Ruche::Machine, "Software\\Test\\Mindset\\Installation"), BTreeMap::new());
            let mut run = BTreeMap::new();
            run.insert("Mindset".to_string(), "\"Mindset.exe\" -Demarrage".to_string());
            run.insert("Autre programme".to_string(), "autre.exe".to_string());
            r.insert(cle(Ruche::Utilisateur, "Software\\Test\\Run"), run);
        }
        sys.dossiers.lock().unwrap().insert("\\MindsetTest".into());
        for n in ["Mindset (démarrage)", "Mindset (installation)", "Appli (aide)"] {
            sys.taches.lock().unwrap().insert(format!("\\MindsetTest\\{n}"));
        }
        *sys.donnees.lock().unwrap() = Some(donnees.clone());
        sys.comportements.lock().unwrap().insert("Désinstaller Autre.exe".into(), Comportement::Echec);
        Env { dossier, racine_c, mindset, exe, racine_x, donnees, bureau, menu, precieux, lieux, sys }
    }

    fn lancer(&self, original: Option<&Path>, supprimer: bool) -> (Bilan, String, Vec<String>, Vec<String>) {
        let o = original.map(t);
        let mut tr = Travail::nouveau(&self.sys, self.lieux.clone(), Bilan::default(), o.as_deref());
        tr.executer(supprimer);
        let texte = texte_bilan(&tr);
        (tr.bilan, texte, tr.donnees_supprimees_par, tr.donnees_gardees)
    }

    fn tout_retire(&self) -> bool {
        let r = self.sys.registre.lock().unwrap();
        !self.racine_c.exists()
            && !self.racine_x.join("Programmes").exists()
            && self.sys.dossiers.lock().unwrap().is_empty()
            && self.sys.taches.lock().unwrap().is_empty()
            && !r.keys().any(|k| k.contains("uninstall") || k.contains("test\\mindset"))
            && !r.get(&cle(Ruche::Utilisateur, "Software\\Test\\Run")).is_some_and(|v| v.contains_key("Mindset"))
            && !self.bureau.join("Mindset.lnk").exists()
            && !self.menu.join("Mindset.lnk").exists()
            && !self.menu.join("Mindset").exists()
    }

    fn lances(&self, exe: &str) -> Vec<String> {
        self.sys.lances.lock().unwrap().iter().filter(|(e, _)| nom(e) == exe).map(|(_, a)| a.clone()).collect()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        // (rd ne suit pas les jonctions)
        let _ = std::process::Command::new("cmd.exe").args(["/c", "rd", "/s", "/q", &t(&self.dossier)]).output();
    }
}

#[test]
fn case_decochee_tout_retire_donnees_gardees() {
    let e = Env::nouveau("decochee", false, false);
    // Mindset qui tourne (Mindset.exe de son dossier), l'hôte d'une appli et un programme ailleurs du même nom
    e.sys.processus.lock().unwrap().extend([
        (10, t(&e.mindset.join("Mindset.exe")), String::new()),
        (11, t(&e.racine_c.join("Evermind").join("Mindset.exe")), String::new()),
        (12, t(&e.dossier.join("ailleurs").join("Mindset.exe")), String::new()),
    ]);
    let (b, texte, par, gardees) = e.lancer(Some(&e.exe), false);
    assert!(b.restes.is_empty(), "restes : {:?}", b.restes);
    assert!(e.tout_retire());
    assert_eq!(e.sys.fermes.lock().unwrap()[0], 10, "Mindset est fermé en premier");
    assert!(e.sys.fermes.lock().unwrap().contains(&11), "l'hôte de l'appli est fermé avec les programmes");
    assert!(!e.sys.fermes.lock().unwrap().contains(&12), "un Mindset.exe ailleurs n'est jamais touché");
    assert!(
        e.sys.registre.lock().unwrap()[&cle(Ruche::Utilisateur, "Software\\Test\\Run")].contains_key("Autre programme")
    );
    assert!(e.bureau.join("Autre programme.lnk").exists());
    assert!(e.donnees.join("suite.json").exists() && e.donnees.join("Mindset").join("reglages.json").exists());
    assert!(e.racine_x.join("Donnees").join("Evermind").join("rendez-vous.json").exists());
    assert!(!e.donnees.join("Mindset").join("telechargements").exists());
    assert!(!e.donnees.join("Mindset").join("installation.demande").exists());
    assert_eq!(e.lances("Désinstaller Appli.exe"), vec!["-GarderDonnees"]);
    assert!(e.donnees.join("Appli").join("parametres.json").exists() && par.is_empty());
    assert_eq!(b.alertes.len(), 1);
    assert!(b.alertes[0].starts_with("Le désinstalleur de Autre n'a pas fini (annulé, ou en erreur : code 3)"));
    assert!(!e.racine_c.join("Autre").exists(), "la désinstallation a continué après l'échec");
    assert!(texte.starts_with("Mindset est désinstallé.\r\n\r\nTes données sont gardées ("));
    assert!(texte.contains("tu retrouveras tout") && !texte.contains("sauf") && texte.contains("À savoir :"));
    assert!(!e.exe.exists(), "le désinstalleur lui-même est parti");
    let reste_x: Vec<String> = std::fs::read_dir(&e.racine_x).unwrap().flatten().map(|x| nom(&t(&x.path()))).collect();
    assert_eq!(reste_x, vec!["Donnees"]);
    assert_eq!(gardees.len(), 2);
    assert!(e.precieux.join("important.txt").exists());
}

#[test]
fn case_cochee_donnees_supprimees_sans_suivre_les_liens() {
    let e = Env::nouveau("cochee", false, false);
    // Un WebView2 de la suite (données) et un d'un autre programme ; un programme d'aide lancé depuis les données
    e.sys.processus.lock().unwrap().extend([
        (
            20,
            "C:\\edge\\msedgewebview2.exe".to_string(),
            format!("--user-data-dir={}\\WebView2\\EBWebView", t(&e.donnees)),
        ),
        (21, "C:\\edge\\msedgewebview2.exe".to_string(), "--user-data-dir=C:\\autre\\EBWebView".to_string()),
        (22, t(&e.donnees.join("Evermind").join("voix").join("Mindset.exe")), String::new()),
    ]);
    let (b, texte, par, _) = e.lancer(Some(&e.exe), true);
    assert!(b.restes.is_empty(), "restes : {:?}", b.restes);
    assert!(e.tout_retire());
    assert_eq!(e.lances("Désinstaller Appli.exe"), vec!["-SupprimerDonnees"]);
    assert!(!e.donnees.exists() && !e.racine_x.exists(), "plus aucun dossier Mindset");
    assert!(e.precieux.join("important.txt").exists(), "le lien dans les données n'a pas été suivi");
    let fermes = e.sys.fermes.lock().unwrap().clone();
    assert!(fermes.contains(&20) && fermes.contains(&22) && !fermes.contains(&21));
    assert!(par.is_empty());
    assert!(!texte.contains("données sont gardées"));
}

#[test]
fn ancienne_version_qui_supprime_ses_donnees() {
    let e = Env::nouveau("ancien", false, false);
    e.sys.comportements.lock().unwrap().insert("Désinstaller Appli.exe".into(), Comportement::Ancien);
    let (_, texte, par, _) = e.lancer(Some(&e.exe), false);
    assert!(!e.donnees.join("Appli").exists());
    assert_eq!(par, vec!["Appli"]);
    assert!(texte.contains("sauf celles de Appli, que son désinstalleur a supprimées"));
    assert!(!texte.contains("tu retrouveras tout"));
    assert!(e.donnees.join("Evermind").join("rendez-vous.json").exists());
}

#[test]
fn fichier_bloque_puis_relance() {
    let e = Env::nouveau("bloque", false, false);
    let bloque = e.racine_c.join("Evermind").join("Evermind.exe");
    let f = {
        use std::os::windows::fs::OpenOptionsExt;
        std::fs::OpenOptions::new().read(true).share_mode(0).open(&bloque).unwrap()
    };
    let (b, texte, _, _) = e.lancer(Some(&e.exe), true);
    assert!(!b.restes.is_empty());
    assert!(texte.starts_with("Ces éléments n'ont pas pu être retirés :\r\n"));
    assert!(texte.contains(&t(&e.racine_c)) && texte.contains("Evermind.exe") && texte.contains("relance"));
    assert!(e.sys.taches.lock().unwrap().is_empty() && !e.bureau.join("Mindset.lnk").exists());
    assert!(!e.racine_x.join("Programmes").exists());
    assert!(e.exe.exists(), "le désinstalleur reste, pour relancer");
    let r = e.sys.registre.lock().unwrap();
    let u = &r[&cle(Ruche::Machine, "Software\\Test\\Uninstall\\Mindset")];
    assert_eq!(u.get("UninstallString"), Some(&format!("\"{}\"", t(&e.exe))));
    drop(r);
    drop(f);
    let (b, _, _, _) = e.lancer(Some(&e.exe), true);
    assert!(b.restes.is_empty(), "restes : {:?}", b.restes);
    assert!(e.tout_retire() && !e.exe.exists() && !e.racine_x.exists());
}

#[test]
fn nettoyage_de_secours_idempotent() {
    // Rien dans Program Files, apps.json abîmé, pas d'entrée « Applications installées » ; lancé d'ailleurs
    let e = Env::nouveau("secours", true, true);
    e.sys.registre.lock().unwrap().remove(&cle(Ruche::Machine, "Software\\Test\\Uninstall\\Mindset"));
    let ailleurs = e.dossier.join("outils").join("Desinstaller Mindset.exe");
    ecrire(&ailleurs, "x");
    let (b, _, _, _) = e.lancer(Some(&ailleurs), false);
    assert!(b.restes.is_empty() && e.tout_retire());
    assert!(e.donnees.join("Mindset").join("reglages.json").exists());
    let (b, texte, _, _) = e.lancer(Some(&ailleurs), false);
    assert!(b.restes.is_empty() && b.faits.is_empty(), "relancé : rien à faire ({:?})", b.faits);
    assert!(texte.starts_with("Il ne restait plus rien de Mindset sur ce PC."));
    let (b, _, _, _) = e.lancer(Some(&ailleurs), true);
    assert!(b.restes.is_empty() && !e.donnees.exists() && !e.racine_x.exists());
    assert!(ailleurs.exists(), "le désinstalleur lancé hors des programmes est gardé");
}

#[test]
fn sans_apps_json_le_desinstalleur_d_une_appli_est_trouve_par_son_nom() {
    let e = Env::nouveau("sansapps", false, true);
    let mut tr = Travail::nouveau(&e.sys, e.lieux.clone(), Bilan::default(), None);
    let racines = e.lieux.racines_programmes();
    let a = tr.applis_avec_desinstalleur(&racines);
    let noms: Vec<(String, String)> = a.iter().map(|x| (x.nom.clone(), x.desinstalleur.clone())).collect();
    assert_eq!(
        noms,
        vec![("Appli".into(), "Désinstaller Appli.exe".into()), ("Autre".into(), "Désinstaller Autre.exe".into())]
    );
    assert!(a.iter().all(|x| x.exe.is_none()));
    // apps.json bon : les applis de apps.json, avec leur programme
    let e = Env::nouveau("avecapps", false, false);
    let mut tr = Travail::nouveau(&e.sys, e.lieux.clone(), Bilan::default(), None);
    let a = tr.applis_avec_desinstalleur(&e.lieux.racines_programmes());
    assert_eq!(a.len(), 2);
    assert_eq!(a[0].exe.as_deref(), Some("Appli.exe"));
}

#[test]
fn apps_json_refuse_les_noms_dangereux() {
    let d = std::env::temp_dir().join(format!("desinst-apps-{}-{}", std::process::id(), crate::os::hasard()));
    let f = d.join("apps.json");
    ecrire(
        &f,
        "\u{feff}[{\"nom\":\"..\",\"exe\":\"a.exe\",\"desinstalleur\":\"d.exe\"},\
         {\"nom\":\"A\\\\B\",\"exe\":\"a.exe\",\"desinstalleur\":\"d.exe\"},\
         {\"nom\":\"Bon\",\"exe\":\"a.exe\",\"desinstalleur\":\"d.bat\"},\
         {\"nom\":\"Bon\",\"exe\":\"..\\\\a.exe\",\"desinstalleur\":\"d.exe\"},\
         {\"nom\":\"Bon\",\"exe\":\"a.exe\",\"desinstalleur\":\"D.EXE\"}]",
    );
    let r = lire_apps(&f).unwrap();
    assert_eq!(r, vec![("Bon".to_string(), "a.exe".to_string(), "D.EXE".to_string())]);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn desinstalleur_d_appli_qui_ne_se_lance_pas() {
    let e = Env::nouveau("introuvable", false, false);
    e.sys.comportements.lock().unwrap().insert("Désinstaller Appli.exe".into(), Comportement::Introuvable);
    let (b, texte, _, _) = e.lancer(Some(&e.exe), false);
    assert!(b.restes.is_empty(), "les fichiers partent quand même");
    assert!(b.alertes.iter().any(|a| a.starts_with("Le désinstalleur de Appli n'a pas pu se lancer (")));
    assert!(texte.contains("À savoir :\r\n  - Le désinstalleur de Appli"));
}

#[test]
fn taches_planifiees() {
    // Sous-dossier et tâche cachée : tout part, le dossier aussi
    let e = Env::nouveau("taches", false, false);
    e.sys.dossiers.lock().unwrap().insert("\\MindsetTest\\Sous".into());
    e.sys.taches.lock().unwrap().insert("\\MindsetTest\\Sous\\Cachee".into());
    let (b, _, _, _) = e.lancer(Some(&e.exe), false);
    assert!(b.faits.iter().any(|f| f == "Tâche planifiée retirée : \\MindsetTest\\Sous\\Cachee"));
    assert!(b.faits.iter().any(|f| f == "Dossier de tâches planifiées retiré : \\MindsetTest"));
    assert!(e.sys.dossiers.lock().unwrap().is_empty());
    // Une tâche qui refuse : elle reste, le dossier aussi, et c'est dit
    let e = Env::nouveau("tachebloquee", false, false);
    e.sys.taches_bloquees.lock().unwrap().insert("\\MindsetTest\\Appli (aide)".into());
    let (b, _, _, _) = e.lancer(Some(&e.exe), false);
    assert_eq!(b.restes, vec!["La tâche planifiée « \\MindsetTest\\Appli (aide) » (Accès refusé.)"]);
    assert!(e.sys.dossiers.lock().unwrap().contains("\\MindsetTest"));
    assert!(e.exe.exists(), "il reste quelque chose : le désinstalleur est gardé");
    // Le Planificateur ne répond pas
    let e = Env::nouveau("sansplanificateur", false, false);
    *e.sys.planificateur_absent.lock().unwrap() = true;
    let (b, _, _, _) = e.lancer(Some(&e.exe), false);
    assert_eq!(
        b.restes,
        vec![
            "Les tâches planifiées de Mindset (dossier « \\MindsetTest » du Planificateur de tâches : Le service n'est pas disponible.)"
        ]
    );
}

#[test]
fn registre_qui_refuse() {
    let e = Env::nouveau("registre", false, false);
    *e.sys.registre_refuse.lock().unwrap() = true;
    let (b, texte, _, _) = e.lancer(Some(&e.exe), false);
    assert!(
        b.restes
            .contains(&"La clé du registre HKEY_LOCAL_MACHINE\\Software\\Test\\Mindset (Accès refusé.)".to_string())
    );
    assert!(b.restes.contains(&"Le lancement de Mindset avec Windows (registre : Accès refusé.)".to_string()));
    assert!(texte.contains("Redémarre l'ordinateur, puis relance la désinstallation de Mindset"));
}

/// Contre-épreuve du juge : un environnement où un fichier reste fait bien échouer « tout retiré »
#[test]
fn contre_epreuve() {
    let e = Env::nouveau("contre", false, false);
    let _ = e.lancer(Some(&e.exe), false);
    assert!(e.tout_retire());
    ecrire(&e.racine_c.join("intrus.txt"), "x");
    assert!(!e.tout_retire());
}

// ---------------------------------------------------------------------------------------------------------------
// La liste des applis en ligne gardée par Mindset (Mindset 2.16)
// ---------------------------------------------------------------------------------------------------------------

/// La clé de TEST de l'installateur (jamais la clé de la suite)
fn cle_de_test() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(r"..\mindset-installateur\tests\cle-de-test")
}

fn signer(donnees: &[u8]) -> Vec<u8> {
    let pk8 = std::fs::read(cle_de_test().join("privee-de-test.der")).unwrap();
    let cle = ring::signature::RsaKeyPair::from_der(&pk8).unwrap();
    let mut sig = vec![0u8; cle.public().modulus_len()];
    cle.sign(&ring::signature::RSA_PKCS1_SHA256, &ring::rand::SystemRandom::new(), donnees, &mut sig).unwrap();
    sig
}

/// Une appli seulement dans la liste en ligne, avec un désinstalleur que la recherche par le nom ne trouve pas
const NOUVELLE: &str =
    r#"{"id":"nouvelle","nom":"Nouvelle","exe":"Nouvelle.exe","desinstalleur":"Retirer Nouvelle.exe"}"#;

fn liste(numero: &str, min: &str, applis: &[&str]) -> Vec<u8> {
    format!(r#"{{"liste":{numero},"mindset_min":"{min}","applis":[{}]}}"#, applis.join(",")).into_bytes()
}

/// Comment la liste gardée est posée
enum Pose {
    Signee(Vec<u8>),
    Modifiee(Vec<u8>, Vec<u8>),
    SansSignature(Vec<u8>),
}

/// Le Mindset de la racine (2.16.0, liste livrée n° `livree`, clé de test), l'appli « Nouvelle » installée, et la
/// liste gardée dans `donnees` (le dossier des données de ce Mindset)
fn poser_liste(racine: &Path, donnees: &Path, livree: &str, pose: &Pose) {
    let fichiers = racine.join("Mindset").join("fichiers");
    ecrire(&fichiers.join("Mindset.ps1"), "$AppVersion = '2.16.0'\r\n");
    ecrire(&fichiers.join("apps-liste.txt"), livree);
    std::fs::create_dir_all(fichiers.join("cles-publiques")).unwrap();
    std::fs::copy(cle_de_test().join("publique-de-test.xml"), fichiers.join("cles-publiques").join("test.xml"))
        .unwrap();
    ecrire(&racine.join("Nouvelle").join("Nouvelle.exe"), "programme");
    ecrire(&racine.join("Nouvelle").join("Retirer Nouvelle.exe"), "désinstalleur");
    let f = donnees.join("apps-en-ligne.json");
    std::fs::create_dir_all(donnees).unwrap();
    let (contenu, signe) = match pose {
        Pose::Signee(o) => (o.clone(), Some(o.clone())),
        Pose::Modifiee(o, apres) => (apres.clone(), Some(o.clone())),
        Pose::SansSignature(o) => (o.clone(), None),
    };
    std::fs::write(&f, contenu).unwrap();
    if let Some(s) = signe {
        std::fs::write(donnees.join("apps-en-ligne.json.sig"), signer(&s)).unwrap();
    }
}

/// Les applis trouvées (nom, programme) et le journal
fn trouvees(e: &Env) -> (Vec<(String, Option<String>)>, Vec<String>) {
    let journal = std::sync::Arc::new(Mutex::new(Vec::<String>::new()));
    let j = journal.clone();
    let bilan =
        Bilan { journal: Some(Box::new(move |t: &str| j.lock().unwrap().push(t.to_string()))), ..Bilan::default() };
    let mut tr = Travail::nouveau(&e.sys, e.lieux.clone(), bilan, None);
    let a = tr.applis_avec_desinstalleur(&e.lieux.racines_programmes());
    let noms = a.iter().map(|x| (x.nom.clone(), x.exe.clone())).collect();
    let lignes = journal.lock().unwrap().clone();
    (noms, lignes)
}

#[test]
fn liste_en_ligne_valable_trouve_ses_applis() {
    let bonne = liste("4", "2.16.0", &[NOUVELLE]);
    // Program Files : la liste dans %LOCALAPPDATA%\Mindset\Mindset
    let e = Env::nouveau("enligne-c", false, false);
    poser_liste(&e.racine_c, &e.donnees.join("Mindset"), "3", &Pose::Signee(bonne.clone()));
    let (a, journal) = trouvees(&e);
    assert!(a.contains(&("Nouvelle".into(), Some("Nouvelle.exe".into()))), "{a:?}");
    // (en plus de apps.json, pas à sa place)
    assert!(a.contains(&("Appli".into(), Some("Appli.exe".into()))), "{a:?}");
    assert!(journal.iter().any(|l| l.starts_with("Liste des applis en ligne 4 prise")), "{journal:?}");
    // X:\Mindset\Programmes : la liste dans X:\Mindset\Donnees\Mindset
    let e = Env::nouveau("enligne-x", true, false);
    let racine = e.racine_x.join("Programmes");
    poser_liste(&racine, &e.racine_x.join("Donnees").join("Mindset"), "3", &Pose::Signee(bonne));
    let (a, _) = trouvees(&e);
    assert!(a.contains(&("Nouvelle".into(), Some("Nouvelle.exe".into()))), "{a:?}");
}

#[test]
fn liste_en_ligne_refusee_ignoree() {
    let bonne = liste("4", "2.16.0", &[NOUVELLE]);
    let autre = liste("4", "2.16.0", &[NOUVELLE, r#"{"id":"x","nom":"X","exe":"X.exe","desinstalleur":"X.exe"}"#]);
    for (nom, livree, pose, raison) in [
        ("modifiee", "3", Pose::Modifiee(bonne.clone(), autre), "signature invalide"),
        ("sans-sig", "3", Pose::SansSignature(bonne.clone()), "signature absente"),
        ("numero-egal", "4", Pose::Signee(bonne.clone()), "pas plus récente"),
        ("numero-petit", "9", Pose::Signee(bonne.clone()), "pas plus récente"),
        ("trop-recente", "3", Pose::Signee(liste("4", "2.17.0", &[NOUVELLE])), "plus récent"),
        ("abimee", "3", Pose::Signee(b"{\"liste\":4,".to_vec()), "mal formée"),
    ] {
        let e = Env::nouveau(&format!("refus-{nom}"), false, false);
        poser_liste(&e.racine_c, &e.donnees.join("Mindset"), livree, &pose);
        let (a, journal) = trouvees(&e);
        assert!(!a.iter().any(|(n, _)| n == "Nouvelle"), "{nom} : {a:?}");
        // apps.json livré reste pris
        assert!(a.contains(&("Appli".into(), Some("Appli.exe".into()))), "{nom} : {a:?}");
        assert!(journal.iter().any(|l| l.contains("ignorée") && l.contains(raison)), "{nom} : {journal:?}");
    }
}

#[test]
fn liste_en_ligne_entree_mal_formee_ignoree() {
    let piege = r#"{"id":"piege","nom":"..","exe":"P.exe","desinstalleur":"Retirer Nouvelle.exe"}"#;
    let e = Env::nouveau("enligne-entree", false, false);
    poser_liste(&e.racine_c, &e.donnees.join("Mindset"), "3", &Pose::Signee(liste("4", "2.16.0", &[piege, NOUVELLE])));
    let (a, _) = trouvees(&e);
    assert!(a.contains(&("Nouvelle".into(), Some("Nouvelle.exe".into()))), "{a:?}");
    assert!(!a.iter().any(|(n, _)| n == ".."), "{a:?}");
}
