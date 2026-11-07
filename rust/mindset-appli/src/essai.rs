//! La construction d'essai (option cargo `essai`), jamais livrée : elle tourne seulement sur un dossier d'essai et sur
//! un bureau Windows à part (D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1). L'exe livré ne contient
//! pas ce module.
//!
//! Deux variables, obligatoires (sinon le programme s'arrête aussitôt, sans rien faire) :
//! - `MINDSET_ESSAI_DONNEES` : la racine d'essai ; tout y est (programmes, données, faux %LOCALAPPDATA%), comme
//!   `Dossiers::sous` ;
//! - `MINDSET_ESSAI_NOM` : le nom des verrous d'essai, `Local\MindsetEssai-<nom>-Instance` et `-Afficher`.
//!
//! En plus, dans cette construction : HKLM n'est jamais lu, aucun réseau, aucun mini-installateur, et Windows est
//! gardé ([`SystemeEssai`]) : les programmes qui tournent se lisent, mais rien n'est lancé, arrêté, ouvert ni
//! signalé. `capture.demande` dans le dossier des données fait écrire l'image de la fenêtre dans `capture.png` ;
//! `actions.demande` y fait jouer des messages de la page (un JSON par ligne) ; l'état envoyé est écrit dans
//! `etat.json`.

use std::path::PathBuf;

use mindset_noyau::systeme::{Lancer, Processus, Systeme};

pub const CAPTURE_DEMANDE: &str = "capture.demande";
pub const CAPTURE: &str = "capture.png";
pub const ACTIONS_DEMANDE: &str = "actions.demande";
pub const ETAT: &str = "etat.json";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Essai {
    pub racine: PathBuf,
    pub nom: String,
}

impl Essai {
    /// Les noms du verrou et du signal d'essai (jamais ceux de Mindset).
    pub fn noms(&self) -> (String, String) {
        (format!(r"Local\MindsetEssai-{}-Instance", self.nom), format!(r"Local\MindsetEssai-{}-Afficher", self.nom))
    }
}

fn nom_valable(n: &str) -> bool {
    (1..=40).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

pub fn depuis(racine: Option<String>, nom: Option<String>) -> Result<Essai, String> {
    let racine = racine.filter(|d| std::path::Path::new(d).is_absolute()).ok_or("MINDSET_ESSAI_DONNEES manque")?;
    let nom = nom.filter(|n| nom_valable(n)).ok_or("MINDSET_ESSAI_NOM manque ou mal écrit")?;
    Ok(Essai { racine: PathBuf::from(racine), nom })
}

pub fn lire() -> Result<Essai, String> {
    let v = |n: &str| std::env::var(n).ok();
    depuis(v("MINDSET_ESSAI_DONNEES"), v("MINDSET_ESSAI_NOM"))
}

/// Windows gardé : on lit, on ne fait rien.
pub struct SystemeEssai<S: Systeme>(pub S);

impl<S: Systeme> Systeme for SystemeEssai<S> {
    fn processus(&self) -> Vec<Processus> {
        self.0.processus()
    }
    fn verrou_existe(&self, nom: &str) -> bool {
        self.0.verrou_existe(nom)
    }
    fn lever_signal(&self, _: &str) -> bool {
        false
    }
    fn lancer(&self, _: &Lancer) -> Result<u32, String> {
        Err("essai : rien n'est lancé".into())
    }
    fn arreter(&self, _: u32) -> Result<(), String> {
        Err("essai : rien n'est arrêté".into())
    }
    fn attendre_fin(&self, _: u32, _: u32) -> bool {
        true
    }
    fn ouvrir(&self, _: &str) -> Result<(), String> {
        Err("essai : rien n'est ouvert".into())
    }
    fn est_admin(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reglages_d_essai() {
        let s = |t: &str| Some(t.to_string());
        let e = depuis(s(r"C:\T\Essai"), s("essai-42")).unwrap();
        let (v, sig) = e.noms();
        assert_eq!(v, r"Local\MindsetEssai-essai-42-Instance");
        assert!(!v.starts_with(r"Local\Mindset-") && !sig.starts_with(r"Local\Mindset-"));
        assert!(depuis(s("relatif"), s("a")).is_err());
        assert!(depuis(s(r"C:\D"), None).is_err());
        assert!(depuis(s(r"C:\D"), s("a b")).is_err());
    }
}
