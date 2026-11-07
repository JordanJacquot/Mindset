//! Ce que Mindset décide avant tout le reste (Mindset.ps1:40-72) : Mindset ouvert en administrateur se rouvre sans
//! les droits, une fois en 2 minutes au plus.
//!
//! Mindset installé, ouvert en administrateur (Explorateur administrateur, par exemple) : il refait ses tâches
//! planifiées (`MindsetInstallateur.exe -Action taches`, à la place de `installer-admin.ps1 -Action taches`), puis se
//! relance par l'Explorateur, qui le rouvre sans les droits. Si l'Explorateur a lui-même les droits (contrôle de compte
//! coupé, compte Administrateur intégré), le Mindset relancé est encore administrateur : la marque
//! `%TEMP%\mindset-bascule-admin.marque` (moins de 2 minutes) l'empêche de recommencer sans fin.
//! Lancé avec `-Demarrage`, il pose `%TEMP%\mindset-rouvrir-cache.marque` : l'Explorateur ne passe pas `-Demarrage`,
//! et le Mindset rouvert dans les 2 minutes se comporte comme lancé avec Windows (caché).

use mindset_noyau::Lancement;
use mindset_noyau::donnees::Dossiers;
use mindset_noyau::systeme::{Lancer, Systeme};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// La marque de la bascule (Mindset.ps1:55).
pub const MARQUE_ADMIN: &str = "mindset-bascule-admin.marque";
/// La marque « rouvert caché » (Mindset.ps1:47).
pub const MARQUE_CACHE: &str = "mindset-rouvrir-cache.marque";
/// Le mini-installateur, à côté de Mindset.exe.
pub const INSTALLATEUR: &str = "MindsetInstallateur.exe";

/// Ce que la bascule lit de Windows (le vrai : `crate::windows::BasculeWindows`).
pub trait PcBascule {
    /// `InstallLocation` de `HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset`, « » si absent.
    fn inscrit(&self) -> String;
    /// `%TEMP%`
    fn temp(&self) -> PathBuf;
    /// Le compte de l'utilisateur (SID).
    fn sid(&self) -> String;
    /// Le dossier de Windows (`GetFolderPath('Windows')`).
    fn windows(&self) -> PathBuf;
}

/// Ce que la bascule a décidé.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Decision {
    /// Mindset s'arrête tout de suite (il s'est relancé par l'Explorateur)
    pub quitter: bool,
    /// Rouvert dans les 2 minutes après une bascule lancée avec Windows : il se comporte comme `-Demarrage`
    pub demarrage_force: bool,
}

/// L'âge d'un fichier en secondes (`(Get-Date) - LastWriteTime`), `None` s'il n'existe pas.
pub fn age(f: &Path, maintenant: SystemTime) -> Option<f64> {
    let m = std::fs::metadata(f).ok()?.modified().ok()?;
    Some(match maintenant.duration_since(m) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => -e.duration().as_secs_f64(),
    })
}

/// La bascule (Mindset.ps1:47-72), sans le mode test (la version Rust n'a pas de variables de test : la construction
/// d'essai est un autre programme).
pub fn decider(
    dossiers: &Dossiers,
    lancement: &Lancement,
    systeme: &dyn Systeme,
    pc: &dyn PcBascule,
    maintenant: SystemTime,
) -> Decision {
    let mut d = Decision::default();
    let temp = pc.temp();
    let marque_cache = temp.join(MARQUE_CACHE);
    let mut demarrage = lancement.demarrage;
    if !demarrage && marque_cache.exists() {
        if age(&marque_cache, maintenant).is_some_and(|a| a < 120.0) {
            demarrage = true;
            d.demarrage_force = true;
        }
        let _ = std::fs::remove_file(&marque_cache);
    }
    if !lancement.admin || lancement.desinstaller {
        return d;
    }
    let marque_admin = temp.join(MARQUE_ADMIN);
    let recente = age(&marque_admin, maintenant).is_some_and(|a| a < 120.0);
    let inscrit = pc.inscrit();
    let copie = dossiers.mindset.to_string_lossy();
    if recente || inscrit.is_empty() || !suite_commun::chemins::egal(&inscrit, &copie) {
        return d;
    }
    let _ = std::fs::write(&marque_admin, "1");
    let windows = pc.windows();
    let rep = temp.join(format!("mindset-taches-{}.json", std::process::id()));
    let taches = Lancer {
        exe: dossiers.mindset.join(INSTALLATEUR),
        arguments: vec![
            "-Action".into(),
            "taches".into(),
            "-Destination".into(),
            inscrit.clone(),
            "-Sid".into(),
            pc.sid(),
            "-Resultat".into(),
            rep.to_string_lossy().into_owned(),
        ],
        dossier: windows.clone(),
        sans_droits: false,
    };
    if let Ok(pid) = systeme.lancer(&taches) {
        let _ = systeme.attendre_fin(pid, 60_000);
    }
    let _ = std::fs::remove_file(&rep);
    if demarrage {
        let _ = std::fs::write(&marque_cache, "1");
    }
    let explorateur = Lancer {
        exe: windows.join("explorer.exe"),
        arguments: vec![dossiers.exe.to_string_lossy().into_owned()],
        dossier: windows,
        sans_droits: false,
    };
    let _ = systeme.lancer(&explorateur);
    d.quitter = true;
    d
}
