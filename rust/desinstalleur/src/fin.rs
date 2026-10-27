//! Les textes montrés à l'utilisateur (accueil de la fenêtre, bilan de fin) et le bilan en JSON (-Rapport), mot pour mot
//! ceux de la version C#.

use std::path::Path;

use serde_json::{Value, json};

use crate::travail::Travail;

/// Le texte d'accueil suit la case : il ne promet de garder les données que si elle est décochée
pub fn texte_accueil(supprimer_donnees: bool) -> String {
    let fin = if supprimer_donnees {
        "Tes données seront effacées aussi : si tu réinstalles Mindset plus tard, tu repartiras de zéro."
    } else {
        "Tes données sont gardées : si tu réinstalles Mindset plus tard, tu retrouveras tout."
    };
    format!(
        "Mindset va être retiré de ce PC, avec les applis qu'il a installées (Nevermind, Evermind...) : les programmes, les raccourcis et le lancement avec Windows.\r\n\r\n{fin}"
    )
}

/// Le texte du bilan, tel qu'il est affiché à la fin
pub fn texte_bilan(t: &Travail<'_>) -> String {
    let b = &t.bilan;
    let mut s = String::new();
    if b.restes.is_empty() {
        s.push_str(if b.faits.is_empty() {
            "Il ne restait plus rien de Mindset sur ce PC."
        } else {
            "Mindset est désinstallé."
        });
        if !t.donnees_gardees.is_empty() {
            let ou = t.donnees_gardees.join(", ");
            if t.donnees_supprimees_par.is_empty() {
                s.push_str(&format!(
                    "\r\n\r\nTes données sont gardées ({ou}) : si tu réinstalles Mindset, tu retrouveras tout."
                ));
            } else {
                // (une ancienne version d'une appli a supprimé ses données malgré le choix : on le dit)
                let une = t.donnees_supprimees_par.len() == 1;
                s.push_str(&format!(
                    "\r\n\r\nTes données sont gardées ({ou}), sauf celles de {}{}. Si tu réinstalles Mindset, tu retrouveras le reste.",
                    t.donnees_supprimees_par.join(" et de "),
                    if une { ", que son désinstalleur a supprimées" } else { ", que leurs désinstalleurs ont supprimées" }
                ));
            }
        }
    } else {
        s.push_str("Ces éléments n'ont pas pu être retirés :\r\n");
        for r in &b.restes {
            s.push_str(&format!("  - {r}\r\n"));
        }
        s.push_str("\r\n");
        s.push_str(&t.conseil_relance);
    }
    if !b.alertes.is_empty() {
        s.push_str("\r\n\r\nÀ savoir :\r\n");
        for a in &b.alertes {
            s.push_str(&format!("  - {a}\r\n"));
        }
    }
    s.trim_end().to_string()
}

/// Ce que la fenêtre a vu (pour le bilan en JSON) ; None en mode sans fenêtre
#[derive(Debug, Clone, Default)]
pub struct VuFenetre {
    pub case_au_depart: bool,
    pub accueil_au_depart: String,
    pub accueil_au_lancement: String,
}

/// Le bilan en JSON (même forme que la version C#)
pub fn rapport(t: &Travail<'_>, fenetre: Option<&VuFenetre>, donnees: bool, texte: &str) -> Value {
    json!({
        "ok": t.bilan.restes.is_empty(),
        "faits": t.bilan.faits,
        "restes": t.bilan.restes,
        "alertes": t.bilan.alertes,
        "caseDonneesAuDepart": fenetre.map(|f| f.case_au_depart),
        "donneesSupprimees": donnees,
        "donneesSupprimeesPar": t.donnees_supprimees_par,
        "texteAffiche": texte,
        "accueilAuDepart": fenetre.map(|f| f.accueil_au_depart.clone()),
        "accueilAuLancement": fenetre.map(|f| f.accueil_au_lancement.clone()),
    })
}

/// Écrit le bilan : à côté d'abord, puis renommé (le fichier n'apparaît qu'une fois complet)
pub fn ecrire_rapport(fichier: &str, valeur: &Value) {
    if fichier.is_empty() {
        return;
    }
    let tmp = format!("{fichier}.tmp");
    if std::fs::write(&tmp, valeur.to_string()).is_err() {
        return;
    }
    let _ = std::fs::remove_file(fichier);
    let _ = std::fs::rename(&tmp, Path::new(fichier));
}
