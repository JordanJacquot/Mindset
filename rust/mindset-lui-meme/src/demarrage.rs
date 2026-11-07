//! Mindset lancé avec Windows (Mindset.ps1:111-120, mindset.ps1:156-179) : relancé après une mise à jour demandée à
//! l'écran, il revient avec sa fenêtre ; « Mindset se lance avec Windows » coupé, il s'arrête avant d'ouvrir quoi que
//! ce soit (sauf juste après une mise à jour faite caché) ; puis les applis « S'ouvre avec Mindset » démarrent en
//! arrière-plan.

use mindset_noyau::{Contexte, Effet, Effets, Fenetre, partage, signaux};
use serde_json::{Value, json};
use std::time::SystemTime;

use crate::LuiMeme;

impl LuiMeme {
    /// Mindset.ps1:117-120 : rend faux si Mindset s'arrête là (rien n'est ouvert).
    pub fn demarrer_lancement(&mut self, ctx: &Contexte, effets: &mut Effets) -> bool {
        let force = crate::demarrage_force() && !ctx.lancement.demarrage;
        self.demarrage = ctx.lancement.demarrage || force;
        // Relancé après une mise à jour demandée à l'écran : le mini-installateur passe toujours par la tâche de
        // démarrage (-Demarrage), mais Mindset revient avec sa fenêtre
        if self.demarrage && ctx.reglage_bool("MajMindsetVisible", false) {
            ctx.ecrire_reglage("MajMindsetVisible", Value::Bool(false));
            self.demarrage = false;
            effets.ajouter(Effet::Fenetre(Fenetre::Montrer));
        }
        if self.demarrage
            && !ctx.reglage_bool("LancerAvecWindows", true)
            && !ctx.reglage_bool("MajMindsetDemande", false)
        {
            ctx.journal("Lancé avec Windows, mais « Mindset se lance avec Windows » est coupé : rien n'est ouvert");
            effets.ajouter(Effet::Quitter { avec_applis: false });
            return false;
        }
        if force && self.demarrage {
            // (rouvert par l'Explorateur après la bascule, qui ne passe pas -Demarrage : caché près de l'horloge)
            effets.ajouter(Effet::Fenetre(Fenetre::Cacher));
        }
        true
    }

    /// `Start-Demarrage` : les applis « S'ouvre avec Mindset » démarrent en arrière-plan. Pas après une relance pour
    /// un nouveau thème (`relance.marque` de moins de 2 minutes). Une appli administrateur seulement si Mindset l'est
    /// aussi.
    pub fn lancer_demarrage(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if ctx.essai && !self.en_essai.lancements {
            return;
        }
        self.mettre_a_jour_raccourcis(ctx);
        let marque = ctx.dossiers.donnees.join("relance.marque");
        if marque.exists() {
            let recente = crate::bascule::age(&marque, SystemTime::now()).is_some_and(|a| a < 120.0);
            let _ = std::fs::remove_file(&marque);
            if recente {
                return;
            }
        }
        let demarrages = ctx.lu(partage::DEMARRAGES);
        let reglage = ctx.reglage_ou("Demarrage", json!([]));
        for a in ctx.applis().iter() {
            if Self::appli_admin(ctx, a) && !ctx.lancement.admin {
                continue;
            }
            // Get-DemarrageAppli : le relevé du bloc « installations », sinon le réglage « Demarrage »
            let oui = match demarrages.as_ref().and_then(|d| d.get(&a.id)).and_then(Value::as_bool) {
                Some(b) => b,
                None => match &reglage {
                    Value::Array(l) => {
                        l.iter().any(|x| x.as_str().is_some_and(|s| suite_commun::chemins::egal(s, &a.id)))
                    }
                    Value::String(s) => suite_commun::chemins::egal(s, &a.id),
                    _ => false,
                },
            };
            if !oui {
                continue;
            }
            if partage::installation(ctx, &a.id).is_some_and(|i| i.gere) {
                effets.signal(signaux::LANCER_APPLI, json!({ "id": a.id, "demarrage": true }));
            }
        }
    }
}
