//! Mindset en Rust, bloc « écrans » : les écrans WPF refaits en HTML à l'identique (interface.xaml, interface.ps1, accueil.ps1, chargement.ps1, logo.ps1). Le HTML vit dans `mindset-appli/ui/` (index.html, coquille.*, ecrans/), ce bloc donne leur état et reçoit leurs gestes.
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md` (ce que le bloc porte, reçoit, envoie, et ne touche pas).
//! Le contrat (`Bloc`, `Effet`, `Contexte`, les ports, le tableau commun, les signaux) est dans `mindset-noyau`
//! et ne change pas.

use mindset_noyau::Bloc;

/// Le bloc « écrans ».
#[derive(Debug, Default)]
pub struct BlocEcrans;

impl Bloc for BlocEcrans {
    fn nom(&self) -> &'static str {
        "ecrans"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocEcrans.nom(), "ecrans");
    }
}
