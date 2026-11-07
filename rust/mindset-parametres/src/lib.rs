//! Mindset en Rust, bloc « paramètres » : les panneaux des Paramètres, les thèmes de la suite et les packs (parametres.ps1, themes.ps1, packs.ps1).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md` (ce que le bloc porte, reçoit, envoie, et ne touche pas).
//! Le contrat (`Bloc`, `Effet`, `Contexte`, les ports, le tableau commun, les signaux) est dans `mindset-noyau`
//! et ne change pas.

use mindset_noyau::Bloc;

/// Le bloc « paramètres ».
#[derive(Debug, Default)]
pub struct BlocParametres;

impl Bloc for BlocParametres {
    fn nom(&self) -> &'static str {
        "parametres"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocParametres.nom(), "parametres");
    }
}
