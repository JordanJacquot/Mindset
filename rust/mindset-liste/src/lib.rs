//! Mindset en Rust, bloc « liste des applis » : apps.json livré ou la liste en ligne signée, et les applis ouvertes (liste.ps1, applis.ps1).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md` (ce que le bloc porte, reçoit, envoie, et ne touche pas).
//! Le contrat (`Bloc`, `Effet`, `Contexte`, les ports, le tableau commun, les signaux) est dans `mindset-noyau`
//! et ne change pas.

use mindset_noyau::Bloc;

/// Le bloc « liste des applis ».
#[derive(Debug, Default)]
pub struct BlocListe;

impl Bloc for BlocListe {
    fn nom(&self) -> &'static str {
        "liste"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocListe.nom(), "liste");
    }
}
