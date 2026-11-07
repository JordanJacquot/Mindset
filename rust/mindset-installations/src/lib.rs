//! Mindset en Rust, bloc « installations » : installer, mettre à jour, prendre en charge, ouvrir et désinstaller une
//! appli, ses raccourcis, son démarrage avec Mindset, la file des demandes au mini-installateur (installations.ps1,
//! taches.ps1 ; `Write-DemandeQuitter` et `Request-FermetureApplis` d'integration.ps1).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md`. Le contrat est dans `mindset-noyau` et ne change pas.
//!
//! [`installateur_windows`] est appelé par l'hôte au lancement : SA SIGNATURE NE CHANGE PAS. Aujourd'hui : aucun
//! mini-installateur ; le bloc la remplace par le vrai (installation.demande, schtasks.exe sans fenêtre, HKLM en
//! lecture, MindsetInstallateur.exe en « runas »).

use std::sync::Arc;

use mindset_noyau::Bloc;
use mindset_noyau::donnees::Dossiers;
use mindset_noyau::installateur::{Installateur, SansInstallateur};

/// Le vrai mini-installateur, branché par l'hôte (jamais dans un test).
pub fn installateur_windows(_dossiers: &Dossiers) -> Arc<dyn Installateur> {
    Arc::new(SansInstallateur)
}

/// Le bloc « installations ».
#[derive(Debug, Default)]
pub struct BlocInstallations;

impl Bloc for BlocInstallations {
    fn nom(&self) -> &'static str {
        "installations"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        assert_eq!(BlocInstallations.nom(), "installations");
    }
}
