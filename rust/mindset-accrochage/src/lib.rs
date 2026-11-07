//! Mindset en Rust, bloc « accrochage » : la vraie fenêtre d'une appli affichée dans Mindset (integration.ps1, `MSIntegration` de natif.cs).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md` (ce que le bloc porte, reçoit, envoie, et ne touche pas).
//! Le contrat (`Bloc`, `Effet`, `Contexte`, les ports, le tableau commun, les signaux) est dans `mindset-noyau`
//! et ne change pas.

use mindset_noyau::Bloc;

/// Le bloc « accrochage ».
#[derive(Debug, Default)]
pub struct BlocAccrochage;

impl Bloc for BlocAccrochage {
    fn nom(&self) -> &'static str {
        "accrochage"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocAccrochage.nom(), "accrochage");
    }
}
