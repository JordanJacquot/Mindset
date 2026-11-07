//! Mindset en Rust, bloc « données » : les dossiers de la suite, le journal, les réglages, les fichiers JSON sûrs et
//! suite.json (modules\donnees.ps1 et modules\suite.ps1 de Mindset 2.18, portés à l'identique).
//!
//! [`ouvrir`] est appelé par l'hôte au lancement, avant tout le reste (SA SIGNATURE NE CHANGE PAS) :
//! 1. les racines : déduites de l'emplacement du programme, ou du Mindset inscrit dans « Applications installées »
//!    (HKLM, en LECTURE seulement, jamais dans la construction d'essai) ;
//! 2. les fichiers des anciennes versions repris (premières versions, journal de Mindset.exe jusqu'à la 2.8.0) ;
//! 3. l'ancien dossier `console-webview` supprimé s'il n'a pas servi depuis 14 jours ;
//! 4. les réglages lus (repris d'un fichier abîmé si besoin, « Chercher les nouvelles versions » et les mises à jour
//!    automatiques jamais rallumés en silence).
//!
//! Le disque rendu ([`disque::DisqueMindset`]) écrit le JSON comme `ConvertTo-Json` de PowerShell 5.1 ([`json_ps`]) :
//! la version 2.18 et Evermind (PowerShell) le relisent tel quel. Les différences voulues sont dans DIVERGENCES.md.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use mindset_noyau::Bloc;
use mindset_noyau::donnees::{Donnees, Dossiers, Environnement, Ouverture};
use suite_commun::json_sur::Horloge;

pub mod anciens;
pub mod disque;
pub mod json_ps;
pub mod racines;
pub mod reglages;
pub mod suite;
#[cfg(windows)]
mod windows;

pub use disque::DisqueMindset;
pub use racines::{Racines, racines_depuis};

/// Les dossiers et le disque de Mindset, au lancement (donnees.ps1:10-58 et 155-186).
pub fn ouvrir(env: &Environnement) -> Ouverture {
    let (dossiers, disque) = ouvrir_disque(env, &inscrit_windows, Arc::new(moment_du_pc));
    Ouverture { dossiers, donnees: disque, notes: Vec::new() }
}

fn moment_du_pc() -> mindset_noyau::moment::HeureLocale {
    mindset_noyau::moment::heure_du_pc()
}

/// `InstallLocation` de Mindset (HKLM, lecture seule).
fn inscrit_windows() -> Option<String> {
    #[cfg(windows)]
    {
        windows::emplacement_inscrit()
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// Le texte d'un chemin.
fn texte(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// Les dossiers de Mindset (donnees.ps1:10-38). `inscrit` : la lecture de InstallLocation (jamais appelée pour un
/// Mindset installé). Rend aussi vrai si le registre a été lu.
pub fn dossiers(env: &Environnement, inscrit: &dyn Fn() -> Option<String>) -> (Dossiers, bool) {
    if let Some(racine) = &env.essai {
        // (construction d'essai : tout sous son dossier, et le registre n'est jamais lu)
        return (Dossiers::sous(racine), false);
    }
    let suite_file_dir = env.localappdata.join("Mindset");
    let mon_dossier = env.exe.parent().map(Path::to_path_buf).unwrap_or_default();
    let (r, lu) =
        racines::racines_de(&texte(&mon_dossier), &texte(&env.program_files), &texte(&suite_file_dir), inscrit, |p| {
            Path::new(p).exists()
        });
    let donnees_suite = PathBuf::from(&r.donnees);
    let d = Dossiers {
        fichiers: mon_dossier.join("fichiers"),
        mindset: mon_dossier,
        exe: env.exe.clone(),
        programmes: PathBuf::from(&r.programmes),
        donnees: donnees_suite.join("Mindset"),
        donnees_suite,
        local_mindset: suite_file_dir,
        disque: r.disque,
    };
    (d, lu)
}

/// [`ouvrir`], avec la lecture du registre et l'horloge données (les tests). Rend le disque lui-même.
pub fn ouvrir_disque(
    env: &Environnement,
    inscrit: &dyn Fn() -> Option<String>,
    horloge: Horloge,
) -> (Dossiers, Arc<DisqueMindset>) {
    let (d, _) = dossiers(env, inscrit);
    // %LOCALAPPDATA% : celui de Windows, ou celui du dossier d'essai (le parent de <racine>\Local\Mindset)
    let localappdata = match &env.essai {
        Some(_) => d.local_mindset.parent().map(Path::to_path_buf).unwrap_or_default(),
        None => env.localappdata.clone(),
    };
    let _ = std::fs::create_dir_all(&d.donnees);
    let disque = Arc::new(DisqueMindset::nouveau(d.clone(), localappdata, env.essai.clone(), horloge));
    anciens::reprendre_anciens_fichiers(&d.local_mindset, &d.donnees);
    anciens::reprendre_ancien_journal(&d.local_mindset, &d.donnees, &disque.heure());
    anciens::nettoyer_restes(&d.donnees, 14, &disque.heure(), &|t| disque.journal(t));
    disque.lire_reglages_au_demarrage();
    (d, disque)
}

/// `Get-LancerAvecWindows` : Mindset se lance-t-il avec Windows ? (oui tant que l'utilisateur ne l'a pas coupé dans
/// les Paramètres ; `[bool]` de PowerShell).
pub fn lancer_avec_windows(d: &dyn Donnees) -> bool {
    d.reglage("LancerAvecWindows").is_none_or(|v| suite_commun::protocole_installateur::vrai_ps(&v))
}

/// `Set-LancerAvecWindows`
pub fn ecrire_lancer_avec_windows(d: &dyn Donnees, oui: bool) {
    d.ecrire_reglage("LancerAvecWindows", serde_json::Value::Bool(oui));
}

/// Le bloc « données » : il ne reçoit ni n'envoie rien (le disque est donné à tous les blocs par le contexte).
#[derive(Debug, Default)]
pub struct BlocDonnees;

impl Bloc for BlocDonnees {
    fn nom(&self) -> &'static str {
        "donnees"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        assert_eq!(BlocDonnees.nom(), "donnees");
    }

    #[test]
    fn ouverture_d_essai_sous_son_dossier() {
        let racine = mindset_noyau::dossier_essai("donnees-ouvrir");
        let _ = std::fs::remove_dir_all(&racine);
        let o = ouvrir(&Environnement { essai: Some(racine.clone()), ..Default::default() });
        assert!(o.dossiers.donnees.starts_with(&racine));
        assert!(o.dossiers.suite().starts_with(&racine));
        o.donnees.journal("essai");
        assert!(std::fs::read_to_string(o.dossiers.journal()).unwrap().ends_with(" essai\r\n"));
        o.donnees.ecrire_reglage("MajAuto", serde_json::Value::Bool(false));
        assert!(std::fs::read_to_string(o.dossiers.reglages()).unwrap().contains("\"MajAuto\":  false"));
        // (hors du dossier d'essai : refusé)
        let dehors = std::env::temp_dir().join("mindset-donnees-jamais.json");
        assert!(o.donnees.ecrire_json(&dehors, &serde_json::json!({})).is_err() && !dehors.exists());
        assert!(o.donnees.lire_json(&dehors).is_err());
        let _ = std::fs::remove_dir_all(&racine);
    }
}
