//! Mindset en Rust, bloc « près de l'horloge » : l'icône près de l'horloge, son menu, les bulles, la croix rouge (zone.ps1).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md` (ce que le bloc porte, reçoit, envoie, et ne touche pas).
//! Le contrat (`Bloc`, `Effet`, `Contexte`, les ports, le tableau commun, les signaux) est dans `mindset-noyau`
//! et ne change pas.

use mindset_noyau::Bloc;

/// Le bloc « près de l'horloge ».
#[derive(Debug, Default)]
pub struct BlocHorloge;

impl Bloc for BlocHorloge {
    fn nom(&self) -> &'static str {
        "horloge"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocHorloge.nom(), "horloge");
    }
}
