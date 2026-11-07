//! Les travaux de fond (taches.ps1, `Start-Tache`) : un téléchargement, une vérification, une question à GitHub, qui
//! ne doivent jamais figer Mindset.
//!
//! Un bloc demande `Effet::Tache(Tache::nouvelle("id", move || { ... }))` : l'hôte lance le travail sur un autre fil,
//! puis rend son résultat au même bloc par `Bloc::tache_finie(ctx, "id", resultat, effets)`, sur le fil des blocs.
//! Le travail ne reçoit pas le contexte : il emporte ce dont il a besoin (une copie des ports, `ctx.reseau()`, des
//! chemins, un [`Progres`] partagé). Une panique du travail devient une erreur, comme une exception de PowerShell.
//!
//! Plus besoin de `New-Action` (taches.ps1:330-344) : les valeurs voyagent dans la fermeture ou dans l'id, jamais
//! recopiées dans du code.

use serde_json::Value;
use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};

/// Le travail d'une tâche.
pub type Travail = Box<dyn FnOnce() -> Result<Value, String> + Send + 'static>;

/// Un travail de fond et son id (choisi par le bloc, rendu tel quel à la fin).
pub struct Tache {
    pub id: String,
    travail: Travail,
}

impl Tache {
    pub fn nouvelle(id: &str, travail: impl FnOnce() -> Result<Value, String> + Send + 'static) -> Tache {
        Tache { id: id.to_string(), travail: Box::new(travail) }
    }

    /// Fait le travail (sur le fil où on l'appelle) ; une panique devient une erreur.
    pub fn lancer(self) -> Result<Value, String> {
        match catch_unwind(AssertUnwindSafe(self.travail)) {
            Ok(r) => r,
            Err(p) => Err(texte_panique(p.as_ref())),
        }
    }
}

/// Le texte d'une panique (pour le journal), comme le message d'une exception.
pub fn texte_panique(p: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        format!("erreur imprévue ({s})")
    } else if let Some(s) = p.downcast_ref::<String>() {
        format!("erreur imprévue ({s})")
    } else {
        "erreur imprévue".into()
    }
}

impl fmt::Debug for Tache {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Tache").field("id", &self.id).finish_non_exhaustive()
    }
}

/// Deux tâches sont égales si elles ont le même id (le travail ne se compare pas) : pour les tests des effets.
impl PartialEq for Tache {
    fn eq(&self, autre: &Tache) -> bool {
        self.id == autre.id
    }
}

/// L'avancée d'un téléchargement, partagée entre le travail et le bloc (`$script:Progres[id]`,
/// `[hashtable]::Synchronized(@{ Recu; Total })`, installations.ps1:493). À mettre dans un `Arc`.
#[derive(Debug, Default)]
pub struct Progres {
    recu: AtomicU64,
    total: AtomicU64,
}

impl Progres {
    /// Octets reçus jusqu'ici, et le total attendu (0 : inconnu).
    pub fn noter(&self, recu: u64, total: u64) {
        self.recu.store(recu, Ordering::Relaxed);
        self.total.store(total, Ordering::Relaxed);
    }

    pub fn recu(&self) -> u64 {
        self.recu.load(Ordering::Relaxed)
    }

    pub fn total(&self) -> u64 {
        self.total.load(Ordering::Relaxed)
    }

    /// La part reçue, de 0 à 1 (`Recu / Total`, 0 si le total est inconnu).
    pub fn part(&self) -> f64 {
        let t = self.total();
        if t == 0 { 0.0 } else { (self.recu() as f64 / t as f64).min(1.0) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn une_panique_devient_une_erreur() {
        let t = Tache::nouvelle("x", || panic!("boum"));
        assert_eq!(t.lancer(), Err("erreur imprévue (boum)".into()));
        let t = Tache::nouvelle("y", || Err("refusé".into()));
        assert_eq!(t.lancer(), Err("refusé".into()));
    }

    #[test]
    fn progres() {
        let p = Progres::default();
        assert_eq!(p.part(), 0.0);
        p.noter(50, 200);
        assert_eq!(p.part(), 0.25);
        p.noter(300, 200);
        assert_eq!(p.part(), 1.0);
    }
}
