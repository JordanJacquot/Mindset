//! Les tests des blocs : un contexte d'essai tout fait, avec les faux ports (disque d'essai, faux GitHub, faux
//! mini-installateur, faux Windows) et un dossier d'essai neuf sous le dossier temporaire. Rien ne touche le vrai PC.
//!
//! ```
//! let (ctx, faux) = mindset_noyau::essai::contexte("mon-bloc");
//! faux.reseau.repondre("https://github.com/...", Ok(mindset_noyau::reseau::ReponseHttp::ok(b"{}".to_vec())));
//! assert!(ctx.essai);
//! ```

use std::path::PathBuf;
use std::sync::Arc;

use crate::contexte::{Contexte, Lancement, Ports};
use crate::donnees::{DonneesMemoire, Dossiers};
use crate::installateur::FauxInstallateur;
use crate::moment;
use crate::reseau::FauxReseau;
use crate::systeme::FauxSysteme;

/// Les faux ports d'un contexte d'essai, pour préparer un cas et regarder ce qui a été fait.
#[derive(Clone)]
pub struct Faux {
    /// Le dossier d'essai (effacé au début ; à effacer à la fin par le test s'il le veut)
    pub racine: PathBuf,
    pub donnees: Arc<DonneesMemoire>,
    pub reseau: Arc<FauxReseau>,
    pub installateur: Arc<FauxInstallateur>,
    pub systeme: Arc<FauxSysteme>,
}

/// L'heure de départ des contextes d'essai : le 07/11/2026 à 20 h.
pub const HEURE_ESSAI: &str = "2026-11-07T20:00:00";

/// Un contexte d'essai : version « 3.0.0 », lancé normalement, sans les droits, heure figée à [`HEURE_ESSAI`], tous
/// les dossiers sous `<temp>\mindset-essai-<nom>-<pid>` (voir `Dossiers::sous`).
pub fn contexte(nom: &str) -> (Contexte, Faux) {
    contexte_avec(nom, Lancement::default())
}

/// Pareil, avec ce lancement (`-Demarrage`, administrateur...).
pub fn contexte_avec(nom: &str, lancement: Lancement) -> (Contexte, Faux) {
    let racine = crate::dossier_essai(nom);
    let _ = std::fs::remove_dir_all(&racine);
    let dossiers = Dossiers::sous(&racine);
    let _ = std::fs::create_dir_all(&dossiers.donnees);
    let faux = Faux {
        racine,
        donnees: Arc::new(DonneesMemoire::nouvelle(dossiers.clone())),
        reseau: Arc::new(FauxReseau::default()),
        installateur: Arc::new(FauxInstallateur::default()),
        systeme: Arc::new(FauxSysteme::default()),
    };
    *faux.systeme.admin.lock().unwrap_or_else(|e| e.into_inner()) = lancement.admin;
    let ports = Ports {
        donnees: faux.donnees.clone(),
        reseau: faux.reseau.clone(),
        installateur: faux.installateur.clone(),
        systeme: faux.systeme.clone(),
    };
    let ctx = Contexte::nouveau(dossiers, "3.0.0", lancement, true, ports, 4242);
    if let Some(h) = moment::lire_iso(HEURE_ESSAI) {
        ctx.figer_heure(h);
    }
    (ctx, faux)
}

#[cfg(test)]
mod tests {
    #[test]
    fn contexte_d_essai() {
        let (ctx, f) = super::contexte("essai");
        assert!(ctx.essai);
        assert_eq!(ctx.heure_iso(), super::HEURE_ESSAI);
        assert!(ctx.dossiers.donnees.starts_with(&f.racine));
        assert!(ctx.dossiers.donnees.is_dir());
        assert!(!ctx.systeme().est_admin());
        let _ = std::fs::remove_dir_all(&f.racine);
    }
}
