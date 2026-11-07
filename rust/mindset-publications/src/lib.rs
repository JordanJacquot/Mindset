//! Mindset en Rust, bloc « publications » : la dernière version de chaque appli (et de Mindset) sur GitHub, le canal
//! d'essai, la vérification des signatures, et le vrai réseau (paquets.ps1, signature.ps1 ; `Update-Publications`,
//! `Get-VersionsEssaiAppli`, `Set-VersionsEssaiAppli` d'installations.ps1 ; `Invoke-Actualiser`,
//! `Update-InfoActualiser` et la minuterie d'une heure d'accueil.ps1 ; le retour depuis l'horloge de zone.ps1).
//!
//! - [`github`] : les questions à GitHub (`Get-Publication` et ce qu'elle appelle), par le port `Reseau` ;
//! - [`telechargement`] : `Test-AdresseTelechargement`, `Get-Octets`, et le téléchargement vérifié d'un zip signé ;
//! - [`bloc`] : le bloc (quand chercher, ce qui est publié dans le tableau commun, les versions d'essai) ;
//! - [`html`], [`version_net`] : `HtmlDecode` et `[version]` de .NET, pour lire exactement comme la version PowerShell ;
//! - `windows` : le vrai réseau (WinHTTP), branché par l'hôte par [`reseau_windows`], jamais dans un test.
//!
//! Juges (exportés de la version PowerShell par `outils\exporter-juges-publications.ps1`) : tests\juges\*.json,
//! rejoués par `src\juges.rs`. Différences voulues : DIVERGENCES.md.

use std::sync::Arc;

use mindset_noyau::reseau::Reseau;

pub mod bloc;
pub mod entites;
pub mod github;
pub mod html;
pub mod port;
pub mod telechargement;
pub mod version_net;
#[cfg(windows)]
mod windows;

#[cfg(test)]
mod juges;

pub use bloc::{BlocPublications, versions_essai_appli};
pub use github::{Publication, Reponse};

/// Le vrai réseau, branché par l'hôte (jamais dans un test) : WinHTTP, seulement vers GitHub
/// (`api.github.com`, `github.com`, et ses serveurs de fichiers), en https.
pub fn reseau_windows() -> Arc<dyn Reseau> {
    #[cfg(windows)]
    {
        Arc::new(windows::ReseauWindows)
    }
    #[cfg(not(windows))]
    {
        Arc::new(mindset_noyau::reseau::SansReseau)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mindset_noyau::Bloc;

    #[test]
    fn nom_du_bloc() {
        assert_eq!(BlocPublications::default().nom(), "publications");
        let b: Box<dyn Bloc> = Box::new(BlocPublications::default());
        assert_eq!(b.nom(), "publications");
    }
}
