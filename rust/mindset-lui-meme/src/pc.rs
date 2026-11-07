//! Ce que le bloc demande à Windows et que le noyau n'a pas : les raccourcis de Mindset (avec son identité dans la
//! barre des tâches), le lancement avec Windows par le registre (`HKCU\...\Run`), les disques, le compte (SID),
//! l'activité (plein écran, manette, clavier et souris), le nom lisible d'un programme, la marque « téléchargé depuis
//! Internet ».
//!
//! Le vrai port est [`crate::windows::PcWindows`] ; les tests (et la construction d'essai) prennent [`FauxPc`], qui ne
//! touche à rien et note ce qui aurait été fait.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::regles::Volume;

/// Ce que contient un raccourci (`MSRaccourci.Lire`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Raccourci {
    /// Le programme
    pub cible: String,
    /// « icône,index »
    pub icone: String,
    /// L'identité dans la barre des tâches (« » s'il n'en a pas)
    pub app_id: String,
    /// Le dossier de travail (pour les tests)
    pub dossier: String,
    /// Le commentaire (pour les tests)
    pub description: String,
}

/// La description et le nom de produit d'un programme.
pub type InfosProgramme = (Option<String>, Option<String>);

/// Les gestes du bloc vers Windows.
pub trait PcLuiMeme: Send + Sync {
    /// Les raccourcis de Mindset : sur le Bureau, puis dans le menu Démarrer (`$RaccourcisMindset`).
    fn raccourcis_mindset(&self) -> Vec<PathBuf>;
    /// Le fichier existe-t-il (`Test-Path -LiteralPath`) ?
    fn existe(&self, chemin: &Path) -> bool;
    /// `MSRaccourci.Lire`
    fn lire_raccourci(&self, lien: &Path) -> Result<Raccourci, String>;
    /// `MSRaccourci.Ecrire` : programme, dossier de travail, icône (index 0), commentaire, identité.
    fn ecrire_raccourci(&self, lien: &Path, r: &Raccourci) -> Result<(), String>;
    /// Retire un raccourci (`Remove-Item -Force`).
    fn retirer_fichier(&self, chemin: &Path) -> Result<(), String>;
    /// La valeur « Mindset » de `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`, `None` si absente.
    fn run(&self) -> Option<String>;
    /// L'écrit (`Set-ItemProperty`).
    fn ecrire_run(&self, valeur: &str) -> Result<(), String>;
    /// La retire (`Remove-ItemProperty`).
    fn retirer_run(&self) -> Result<(), String>;
    /// Les disques fixes (`Win32_LogicalDisk`, `DriveType=3`).
    fn volumes(&self) -> Vec<Volume>;
    /// La lettre du disque de Windows (`$env:SystemDrive`, « C »).
    fn disque_systeme(&self) -> String;
    /// Le compte de l'utilisateur (`WindowsIdentity.GetCurrent().User.Value`), « » s'il n'est pas lisible.
    fn sid(&self) -> String;
    /// Une fenêtre en plein écran sur n'importe quel écran (`MSActivite.PleinEcranQuelquePart`).
    fn plein_ecran(&self) -> bool;
    /// Relève les manettes (`MSActivite.ReleverManette`).
    fn relever_manette(&self);
    /// Depuis combien de secondes une manette a servi (très grand : jamais vue).
    fn secondes_manette(&self) -> f64;
    /// Depuis combien de secondes personne ne touche au clavier ni à la souris.
    fn secondes_inactif(&self) -> Result<f64, String>;
    /// La description et le nom de produit d'un programme (`FileVersionInfo`), `None` s'ils ne sont pas lisibles.
    fn infos_programme(&self, chemin: &str) -> (Option<String>, Option<String>);
    /// Retire la marque « téléchargé depuis Internet » des fichiers de ce dossier (`Unblock-File`).
    fn debloquer(&self, dossier: &Path);
    /// La forme longue d'un chemin (`GetLongPathNameW`) : un Mindset lancé par son nom court (`MINDSE~1`) doit
    /// reconnaître ses raccourcis écrits avec le nom long, et inversement.
    fn forme_longue(&self, chemin: &str) -> String {
        chemin.to_string()
    }
}

/// Le faux Windows du bloc : des raccourcis, une valeur Run et des disques posés à la main, l'activité réglée par le
/// test ; il note ce qui aurait été écrit ou retiré.
#[derive(Debug, Default)]
pub struct FauxPc {
    pub raccourcis: Mutex<BTreeMap<PathBuf, Raccourci>>,
    pub refus: Mutex<Vec<PathBuf>>,
    pub run: Mutex<Option<String>>,
    pub run_refuse: Mutex<bool>,
    pub volumes: Mutex<Vec<Volume>>,
    pub sid: Mutex<String>,
    pub plein_ecran: Mutex<bool>,
    pub manette: Mutex<f64>,
    pub inactif: Mutex<Option<f64>>,
    pub programmes: Mutex<BTreeMap<String, InfosProgramme>>,
    pub debloques: Mutex<Vec<PathBuf>>,
    pub releves: Mutex<u32>,
    pub lieux: Mutex<Vec<PathBuf>>,
    /// Les noms courts de Windows (8.3) : `forme_longue` remplace le début court par le long.
    pub courts: Mutex<BTreeMap<String, String>>,
}

fn v<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl FauxPc {
    /// Un faux PC : Bureau et menu Démarrer sous `racine`, aucune manette, personne au clavier depuis 0 s.
    pub fn sous(racine: &Path) -> FauxPc {
        let f = FauxPc::default();
        *v(&f.lieux) = vec![racine.join(r"Bureau\Mindset.lnk"), racine.join(r"Programmes\Mindset.lnk")];
        *v(&f.manette) = f64::MAX;
        *v(&f.inactif) = Some(0.0);
        *v(&f.sid) = "S-1-5-21-1000-2000-3000-1001".into();
        f
    }
    /// Un raccourci présent.
    pub fn poser_raccourci(&self, lien: &Path, r: Raccourci) {
        v(&self.raccourcis).insert(lien.to_path_buf(), r);
    }
    /// L'écriture ou le retrait de ce fichier sera refusé.
    pub fn refuser(&self, lien: &Path) {
        v(&self.refus).push(lien.to_path_buf());
    }
    /// Le raccourci, s'il existe.
    pub fn raccourci(&self, lien: &Path) -> Option<Raccourci> {
        v(&self.raccourcis).get(lien).cloned()
    }
    pub fn poser_inactif(&self, s: Result<f64, String>) {
        *v(&self.inactif) = s.ok();
    }
    pub fn poser_manette(&self, s: f64) {
        *v(&self.manette) = s;
    }
    pub fn poser_plein_ecran(&self, oui: bool) {
        *v(&self.plein_ecran) = oui;
    }
    pub fn poser_run(&self, valeur: Option<&str>) {
        *v(&self.run) = valeur.map(str::to_string);
    }
    pub fn valeur_run(&self) -> Option<String> {
        v(&self.run).clone()
    }
}

impl PcLuiMeme for FauxPc {
    fn raccourcis_mindset(&self) -> Vec<PathBuf> {
        v(&self.lieux).clone()
    }
    fn existe(&self, chemin: &Path) -> bool {
        v(&self.raccourcis).contains_key(chemin)
    }
    fn lire_raccourci(&self, lien: &Path) -> Result<Raccourci, String> {
        v(&self.raccourcis).get(lien).cloned().ok_or_else(|| "raccourci illisible".to_string())
    }
    fn ecrire_raccourci(&self, lien: &Path, r: &Raccourci) -> Result<(), String> {
        if v(&self.refus).iter().any(|x| x == lien) {
            return Err("Accès refusé.".into());
        }
        v(&self.raccourcis).insert(lien.to_path_buf(), r.clone());
        Ok(())
    }
    fn retirer_fichier(&self, chemin: &Path) -> Result<(), String> {
        if v(&self.refus).iter().any(|x| x == chemin) {
            return Err("Accès refusé.".into());
        }
        v(&self.raccourcis).remove(chemin);
        Ok(())
    }
    fn run(&self) -> Option<String> {
        v(&self.run).clone()
    }
    fn ecrire_run(&self, valeur: &str) -> Result<(), String> {
        *v(&self.run) = Some(valeur.to_string());
        Ok(())
    }
    fn retirer_run(&self) -> Result<(), String> {
        if *v(&self.run_refuse) {
            return Err("Accès refusé.".into());
        }
        *v(&self.run) = None;
        Ok(())
    }
    fn volumes(&self) -> Vec<Volume> {
        v(&self.volumes).clone()
    }
    fn disque_systeme(&self) -> String {
        "C".into()
    }
    fn sid(&self) -> String {
        v(&self.sid).clone()
    }
    fn plein_ecran(&self) -> bool {
        *v(&self.plein_ecran)
    }
    fn relever_manette(&self) {
        *v(&self.releves) += 1;
    }
    fn secondes_manette(&self) -> f64 {
        *v(&self.manette)
    }
    fn secondes_inactif(&self) -> Result<f64, String> {
        v(&self.inactif).ok_or_else(|| "relevé impossible".to_string())
    }
    fn infos_programme(&self, chemin: &str) -> (Option<String>, Option<String>) {
        v(&self.programmes).get(chemin).cloned().unwrap_or((None, None))
    }
    fn debloquer(&self, dossier: &Path) {
        v(&self.debloques).push(dossier.to_path_buf());
    }
    fn forme_longue(&self, chemin: &str) -> String {
        for (court, long) in v(&self.courts).iter() {
            if let Some(reste) = suite_commun::chemins::apres_debut(chemin, court) {
                return format!("{long}{reste}");
            }
        }
        chemin.to_string()
    }
}
