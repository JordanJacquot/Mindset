//! Ce que ce bloc seul demande à Windows (le reste passe par les ports du noyau) : les raccourcis (.lnk, leur cible,
//! leur icône et leur identité), les dossiers connus (Bureau, menu Démarrer, Téléchargements...), les entrées « Run »
//! de l'utilisateur, les tâches de démarrage d'une appli, les variables d'environnement, le compte de l'utilisateur,
//! et la copie d'un dossier d'un disque à l'autre (robocopy).
//!
//! Le vrai poste est dans [`crate::windows`] ; les tests ont [`FauxPoste`] (un faux PC sous le dossier d'essai), et
//! la construction d'essai de Mindset [`SansPoste`] (rien n'est lu, rien n'est écrit).

use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

fn verrou<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Un raccourci lu : sa cible, son icône (« chemin,index ») et son identité (System.AppUserModel.ID).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Raccourci {
    pub cible: String,
    pub icone: String,
    pub identite: String,
}

/// Un raccourci à écrire (`MSRaccourci.Ecrire`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NouveauRaccourci {
    pub cible: String,
    pub dossier: String,
    pub icone: String,
    pub description: String,
    pub identite: String,
}

/// Ce que le bloc demande à Windows.
pub trait Poste: Send + Sync {
    /// Les dossiers où chercher les raccourcis d'une appli (`Get-LieuxRaccourcis`) : Bureau, Bureau commun, menu
    /// Démarrer (les deux), Démarrage ; seulement ceux qui existent.
    fn lieux_raccourcis(&self) -> Vec<String>;
    /// Les dossiers où chercher une copie téléchargée : Téléchargements, Bureau, Documents (`Find-InstallationExistante`).
    fn lieux_copies(&self) -> Vec<String>;
    /// La cible d'un raccourci (`TargetPath` de WScript.Shell), `None` s'il ne se lit pas.
    fn cible_raccourci(&self, lnk: &Path) -> Option<String>;
    /// Un raccourci lu en entier (`MSRaccourci.Lire`), `None` s'il ne se lit pas.
    fn lire_raccourci(&self, lnk: &Path) -> Option<Raccourci>;
    /// Écrit un raccourci (`MSRaccourci.Ecrire`).
    fn ecrire_raccourci(&self, lnk: &Path, r: &NouveauRaccourci) -> Result<(), String>;
    /// Le dossier Mindset du menu Démarrer (`$MenuApplis`), `None` : aucun (essai sans dossier de test).
    fn menu_applis(&self) -> Option<String>;
    /// Les entrées « Run » de l'utilisateur (`HKCU\...\CurrentVersion\Run`) : (nom, valeur si c'est un texte). `Err` :
    /// la clé ne se lit pas.
    fn entrees_run(&self) -> Result<Vec<(String, Option<String>)>, String>;
    /// Retire une entrée « Run » de l'utilisateur.
    fn retirer_run(&self, nom: &str) -> Result<(), String>;
    /// La tâche planifiée existe-t-elle (`schtasks /Query /TN <chemin>`, code 0) ?
    fn tache_existe(&self, chemin: &str) -> bool;
    /// Retire une tâche planifiée (`schtasks /Delete /TN <chemin> /F`) : `true` si c'est fait (code 0).
    fn retirer_tache(&self, chemin: &str) -> bool;
    /// Les noms des variables d'environnement de Mindset.
    fn variables_processus(&self) -> Vec<String>;
    /// Les noms des variables d'environnement du compte (`HKCU\Environment`).
    fn variables_compte(&self) -> Vec<String>;
    /// Le SID de l'utilisateur (`WindowsIdentity.GetCurrent().User.Value`).
    fn sid(&self) -> String;
    /// Les dossiers que Mindset ne vide jamais (`Test-DossierSur`) : Windows, Program Files (les deux),
    /// ProgramData.
    fn dossiers_interdits(&self) -> Vec<String>;
    /// `$env:ProgramFiles`
    fn program_files(&self) -> String;
    /// `$env:LOCALAPPDATA`
    fn localappdata(&self) -> String;
    /// Copie un dossier entier vers un nouveau dossier (`robocopy /E /COPY:DAT /DCOPY:DAT /R:1 /W:1`) : `Err` si la
    /// copie a échoué (code 8 ou plus).
    fn copier_dossier(&self, de: &Path, vers: &Path) -> Result<(), String>;
    /// Permet à l'appli réveillée de passer devant (`AllowSetForegroundWindow(-1)`).
    fn autoriser_premier_plan(&self) {}
}

/// Aucun poste (la construction d'essai de Mindset) : rien n'est trouvé, rien n'est écrit ni retiré.
#[derive(Debug, Default)]
pub struct SansPoste;

impl Poste for SansPoste {
    fn lieux_raccourcis(&self) -> Vec<String> {
        Vec::new()
    }
    fn lieux_copies(&self) -> Vec<String> {
        Vec::new()
    }
    fn cible_raccourci(&self, _: &Path) -> Option<String> {
        None
    }
    fn lire_raccourci(&self, _: &Path) -> Option<Raccourci> {
        None
    }
    fn ecrire_raccourci(&self, _: &Path, _: &NouveauRaccourci) -> Result<(), String> {
        Err("essai : aucun raccourci n'est écrit".into())
    }
    fn menu_applis(&self) -> Option<String> {
        None
    }
    fn entrees_run(&self) -> Result<Vec<(String, Option<String>)>, String> {
        Ok(Vec::new())
    }
    fn retirer_run(&self, _: &str) -> Result<(), String> {
        Err("essai".into())
    }
    fn tache_existe(&self, _: &str) -> bool {
        false
    }
    fn retirer_tache(&self, _: &str) -> bool {
        false
    }
    fn variables_processus(&self) -> Vec<String> {
        Vec::new()
    }
    fn variables_compte(&self) -> Vec<String> {
        Vec::new()
    }
    fn sid(&self) -> String {
        "S-1-5-21-0-0-0-1001".into()
    }
    fn dossiers_interdits(&self) -> Vec<String> {
        Vec::new()
    }
    fn program_files(&self) -> String {
        String::new()
    }
    fn localappdata(&self) -> String {
        String::new()
    }
    fn copier_dossier(&self, _: &Path, _: &Path) -> Result<(), String> {
        Err("essai : rien n'est copié".into())
    }
}

/// Le faux poste des tests : un faux PC sous un dossier d'essai.
///
/// - un raccourci est un vrai fichier `.lnk` dont le contenu est un petit JSON `{cible, icone, identite}` (écrit par
///   [`FauxPoste::poser_raccourci`] ou par le bloc) ; un `.lnk` qui n'est pas ce JSON ne se lit pas ;
/// - les entrées « Run », les tâches et les variables sont en mémoire ;
/// - la copie d'un dossier est faite en Rust (fichiers et sous-dossiers).
#[derive(Debug, Default)]
pub struct FauxPoste {
    pub racine: PathBuf,
    run: Mutex<Option<BTreeMap<String, Option<String>>>>,
    run_retirees: Mutex<Vec<String>>,
    taches: Mutex<BTreeSet<String>>,
    taches_retirees: Mutex<Vec<String>>,
    variables: Mutex<(Vec<String>, Vec<String>)>,
    pub sid: Mutex<String>,
    pub interdits: Mutex<Vec<String>>,
    pub sans_menu: Mutex<bool>,
    copie_refusee: Mutex<bool>,
    ecrits: Mutex<Vec<PathBuf>>,
}

impl FauxPoste {
    /// Un faux PC sous `racine` (ses dossiers : `Bureau`, `BureauCommun`, `Menu`, `MenuCommun`, `Demarrage`,
    /// `Telechargements`, `Documents`, `Menu\Mindset` pour le menu des applis, `ProgramFiles`, `Windows`, `Local`).
    pub fn nouveau(racine: &Path) -> FauxPoste {
        for d in ["Bureau", "BureauCommun", "Menu", "MenuCommun", "Demarrage", "Telechargements", "Documents"] {
            let _ = std::fs::create_dir_all(racine.join("pc").join(d));
        }
        FauxPoste {
            racine: racine.join("pc"),
            run: Mutex::new(Some(BTreeMap::new())),
            sid: Mutex::new("S-1-5-21-1111-2222-3333-1001".into()),
            interdits: Mutex::new(vec![
                racine.join("pc").join("Windows").to_string_lossy().into_owned(),
                racine.join("pc").join("ProgramFiles").to_string_lossy().into_owned(),
            ]),
            ..Default::default()
        }
    }

    fn d(&self, nom: &str) -> String {
        self.racine.join(nom).to_string_lossy().into_owned()
    }

    /// Le dossier d'un lieu du faux PC (`Bureau`, `Telechargements`...).
    pub fn lieu(&self, nom: &str) -> PathBuf {
        self.racine.join(nom)
    }

    /// Un raccourci posé dans le faux PC.
    pub fn poser_raccourci(&self, lnk: &Path, cible: &str, icone: &str, identite: &str) {
        if let Some(p) = lnk.parent() {
            let _ = std::fs::create_dir_all(p);
        }
        let _ = std::fs::write(lnk, json!({ "cible": cible, "icone": icone, "identite": identite }).to_string());
    }

    /// Une entrée « Run » de l'utilisateur (`None` : une valeur qui n'est pas un texte).
    pub fn poser_run(&self, nom: &str, valeur: Option<&str>) {
        if let Some(r) = verrou(&self.run).as_mut() {
            r.insert(nom.into(), valeur.map(str::to_string));
        }
    }
    /// La clé « Run » ne se lit pas.
    pub fn run_illisible(&self) {
        *verrou(&self.run) = None;
    }
    /// Les entrées « Run » restantes.
    pub fn run(&self) -> Vec<(String, Option<String>)> {
        verrou(&self.run).clone().unwrap_or_default().into_iter().collect()
    }
    /// Les entrées « Run » retirées.
    pub fn run_retirees(&self) -> Vec<String> {
        verrou(&self.run_retirees).clone()
    }
    /// Une tâche planifiée qui existe.
    pub fn poser_tache(&self, chemin: &str) {
        verrou(&self.taches).insert(chemin.into());
    }
    /// Les tâches retirées.
    pub fn taches_retirees(&self) -> Vec<String> {
        verrou(&self.taches_retirees).clone()
    }
    /// Les variables d'environnement de Mindset et du compte.
    pub fn poser_variables(&self, processus: &[&str], compte: &[&str]) {
        *verrou(&self.variables) =
            (processus.iter().map(|s| s.to_string()).collect(), compte.iter().map(|s| s.to_string()).collect());
    }
    /// La prochaine copie de dossier échoue.
    pub fn refuser_copie(&self) {
        *verrou(&self.copie_refusee) = true;
    }
    /// Les raccourcis écrits par le bloc.
    pub fn ecrits(&self) -> Vec<PathBuf> {
        verrou(&self.ecrits).clone()
    }
}

fn lire_faux_lnk(lnk: &Path) -> Option<Raccourci> {
    let o = std::fs::read(lnk).ok()?;
    let v: Value = serde_json::from_slice(&o).ok()?;
    let t = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    Some(Raccourci { cible: t("cible"), icone: t("icone"), identite: t("identite") })
}

/// La copie d'un dossier, en Rust (fichiers, sous-dossiers, dates de modification).
pub fn copier_en_rust(de: &Path, vers: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(vers)?;
    for e in std::fs::read_dir(de)? {
        let e = e?;
        let t = e.file_type()?;
        let cible = vers.join(e.file_name());
        if t.is_dir() {
            copier_en_rust(&e.path(), &cible)?;
        } else if t.is_file() {
            std::fs::copy(e.path(), &cible)?;
            if let Ok(m) = e.metadata().and_then(|m| m.modified()) {
                let _ = std::fs::File::options().write(true).open(&cible).and_then(|f| f.set_modified(m));
            }
        }
    }
    Ok(())
}

impl Poste for FauxPoste {
    fn lieux_raccourcis(&self) -> Vec<String> {
        ["Bureau", "BureauCommun", "Menu", "MenuCommun", "Demarrage"]
            .iter()
            .map(|n| self.d(n))
            .filter(|d| Path::new(d).is_dir())
            .collect()
    }
    fn lieux_copies(&self) -> Vec<String> {
        ["Telechargements", "Bureau", "Documents"].iter().map(|n| self.d(n)).collect()
    }
    fn cible_raccourci(&self, lnk: &Path) -> Option<String> {
        lire_faux_lnk(lnk).map(|r| r.cible)
    }
    fn lire_raccourci(&self, lnk: &Path) -> Option<Raccourci> {
        lire_faux_lnk(lnk)
    }
    fn ecrire_raccourci(&self, lnk: &Path, r: &NouveauRaccourci) -> Result<(), String> {
        verrou(&self.ecrits).push(lnk.to_path_buf());
        let icone = format!("{},0", r.icone);
        std::fs::write(
            lnk,
            json!({ "cible": r.cible, "icone": icone, "identite": r.identite, "dossier": r.dossier,
            "description": r.description })
            .to_string(),
        )
        .map_err(|e| e.to_string())
    }
    fn menu_applis(&self) -> Option<String> {
        if *verrou(&self.sans_menu) { None } else { Some(self.d(r"Menu\Mindset")) }
    }
    fn entrees_run(&self) -> Result<Vec<(String, Option<String>)>, String> {
        verrou(&self.run).clone().map(|r| r.into_iter().collect()).ok_or_else(|| "clé illisible".into())
    }
    fn retirer_run(&self, nom: &str) -> Result<(), String> {
        let mut r = verrou(&self.run);
        match r.as_mut().and_then(|m| m.remove(nom)) {
            Some(_) => {
                verrou(&self.run_retirees).push(nom.into());
                Ok(())
            }
            None => Err("absente".into()),
        }
    }
    fn tache_existe(&self, chemin: &str) -> bool {
        verrou(&self.taches).contains(chemin)
    }
    fn retirer_tache(&self, chemin: &str) -> bool {
        let ok = verrou(&self.taches).remove(chemin);
        if ok {
            verrou(&self.taches_retirees).push(chemin.into());
        }
        ok
    }
    fn variables_processus(&self) -> Vec<String> {
        verrou(&self.variables).0.clone()
    }
    fn variables_compte(&self) -> Vec<String> {
        verrou(&self.variables).1.clone()
    }
    fn sid(&self) -> String {
        verrou(&self.sid).clone()
    }
    fn dossiers_interdits(&self) -> Vec<String> {
        verrou(&self.interdits).clone()
    }
    fn program_files(&self) -> String {
        self.d("ProgramFiles")
    }
    fn localappdata(&self) -> String {
        self.d("Local")
    }
    fn copier_dossier(&self, de: &Path, vers: &Path) -> Result<(), String> {
        if std::mem::take(&mut *verrou(&self.copie_refusee)) {
            return Err("copie refusée (essai)".into());
        }
        copier_en_rust(de, vers).map_err(|e| e.to_string())
    }
}
