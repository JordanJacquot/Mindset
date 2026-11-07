//! Mindset en Rust, bloc « publications » : la dernière version de chaque appli (et de Mindset) sur GitHub, le canal
//! d'essai, la vérification des signatures, et le vrai réseau (paquets.ps1, signature.ps1 ; `Update-Publications`,
//! `Get-VersionsEssaiAppli`, `Set-VersionsEssaiAppli` d'installations.ps1 ; `Invoke-Actualiser` d'accueil.ps1).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md`. Le contrat est dans `mindset-noyau` et ne change pas.
//!
//! [`reseau_windows`] est appelé par l'hôte au lancement : SA SIGNATURE NE CHANGE PAS. Aujourd'hui : aucun réseau ;
//! le bloc la remplace par le vrai (WinHTTP, comme `Get-Octets`).

use std::sync::Arc;

use mindset_noyau::Bloc;
use mindset_noyau::reseau::{Reseau, SansReseau};

/// Le vrai réseau, branché par l'hôte (jamais dans un test).
pub fn reseau_windows() -> Arc<dyn Reseau> {
    Arc::new(SansReseau)
}

/// Le bloc « publications ».
#[derive(Debug, Default)]
pub struct BlocPublications;

impl Bloc for BlocPublications {
    fn nom(&self) -> &'static str {
        "publications"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        assert_eq!(BlocPublications.nom(), "publications");
    }
}
