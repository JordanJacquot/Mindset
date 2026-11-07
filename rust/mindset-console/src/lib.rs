//! Mindset en Rust, bloc « console 3D » : l'hôte de la scène 3D, rangée dans `mindset-appli/ui/console/` (console.ps1, console\scene.html).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md` (ce que le bloc porte, reçoit, envoie, et ne touche pas).
//! Le contrat (`Bloc`, `Effet`, `Contexte`, les ports, le tableau commun, les signaux) est dans `mindset-noyau`
//! et ne change pas.

use mindset_noyau::Bloc;

/// Le bloc « console 3D ».
#[derive(Debug, Default)]
pub struct BlocConsole;

impl Bloc for BlocConsole {
    fn nom(&self) -> &'static str {
        "console"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocConsole.nom(), "console");
    }
}
