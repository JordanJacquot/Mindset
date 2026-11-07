//! Mindset en Rust, bloc « Mindset lui-même » : son installation sur le PC (bienvenue, choix du disque), ses
//! raccourcis, sa mise à jour, les mises à jour automatiques, l'historique des mises à jour, sa désinstallation, le
//! démarrage des applis avec Mindset (mindset.ps1, et le début de Mindset.ps1 : bascule administrateur,
//! « Mindset se lance avec Windows » coupé, `-Desinstaller`).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md`. Le contrat est dans `mindset-noyau` et ne change pas.
//!
//! [`avant_tout`] est appelé par l'hôte au lancement, après les dossiers et AVANT le verrou d'instance unique (comme
//! Mindset.ps1:52-75) : SA SIGNATURE NE CHANGE PAS. Aujourd'hui elle ne fait rien.

use mindset_noyau::donnees::Dossiers;
use mindset_noyau::{Bloc, Lancement, Ports};

/// Ce qui se décide avant tout le reste (Mindset.ps1:41-75) : `Some(code)` pour quitter tout de suite (Mindset
/// ouvert en administrateur qui se rouvre sans les droits), `None` pour continuer.
pub fn avant_tout(_dossiers: &Dossiers, _lancement: &Lancement, _ports: &Ports) -> Option<i32> {
    None
}

/// Le bloc « Mindset lui-même ».
#[derive(Debug, Default)]
pub struct BlocLuiMeme;

impl Bloc for BlocLuiMeme {
    fn nom(&self) -> &'static str {
        "lui-meme"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        assert_eq!(BlocLuiMeme.nom(), "lui-meme");
    }
}
