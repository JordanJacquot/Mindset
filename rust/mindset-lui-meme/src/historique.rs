//! L'historique des mises à jour (mises-a-jour.json, dans les données de Mindset) : les 20 dernières, de Mindset et de
//! ses applis, la plus récente d'abord (mindset.ps1:557-654).
//!
//! Écrit à côté puis remplacé d'un coup (`Save-JsonSur`, par le port du disque). Un fichier abîmé est mis de côté par
//! le port et l'historique repart de sa copie ou de zéro ; pris par un autre programme, il n'est pas réécrit
//! (`Illisible`). La version PowerShell le gardait en mémoire après la première lecture ; ici il est relu à chaque
//! fois (le bloc « installations » peut y ajouter une entrée de son côté) : même contenu, sans risque d'écraser une
//! entrée écrite entre-temps.

use mindset_noyau::Contexte;
use std::path::PathBuf;

use crate::regles::{self, Entree, HISTORIQUE_MAX};

/// L'historique lu.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Historique {
    pub liste: Vec<Entree>,
    /// La mise à jour de Mindset notée avant qu'il ne se ferme pour se mettre à jour
    pub attendue: Option<Entree>,
    /// Pris par un autre programme : rien n'est écrit (pour ne pas le remplacer par une liste vide)
    pub illisible: bool,
}

/// `$FichierHistoriqueMaj`
pub fn fichier(ctx: &Contexte) -> PathBuf {
    ctx.dossiers.donnees.join("mises-a-jour.json")
}

/// `Read-HistoriqueMaj`
pub fn lire(ctx: &Contexte) -> Historique {
    match ctx.donnees().lire_json(&fichier(ctx)) {
        Err(e) => {
            ctx.journal(&format!("Historique des mises à jour : {e}"));
            Historique { illisible: true, ..Default::default() }
        }
        Ok(Some(serde_json::Value::Object(j))) => {
            let (liste, attendue) = regles::historique_depuis(&j);
            Historique { liste, attendue, illisible: false }
        }
        Ok(_) => Historique::default(),
    }
}

/// L'historique lu pour le tableau commun (rien au journal : relu à chaque publication).
pub fn lire_sans_journal(ctx: &Contexte) -> Historique {
    match ctx.donnees().lire_json(&fichier(ctx)) {
        Ok(Some(serde_json::Value::Object(j))) => {
            let (liste, attendue) = regles::historique_depuis(&j);
            Historique { liste, attendue, illisible: false }
        }
        Ok(_) => Historique::default(),
        Err(_) => Historique { illisible: true, ..Default::default() },
    }
}

/// `Save-HistoriqueMaj`
pub fn enregistrer(ctx: &Contexte, h: &Historique) {
    if h.illisible {
        ctx.journal("Historique des mises à jour non enregistré : il n'a pas pu être lu");
        return;
    }
    let v = regles::historique_en_json(&h.liste, h.attendue.as_ref());
    if let Err(e) = ctx.donnees().ecrire_json(&fichier(ctx), &v) {
        ctx.journal(&format!("Historique des mises à jour non enregistré : {e}"));
    }
}

fn entree(ctx: &Contexte, id: &str, nom: &str, version: &str, auto: bool, notes: &str) -> Option<Entree> {
    regles::entree_maj(&serde_json::json!({ "id": id, "nom": nom, "version": version, "quand": ctx.heure_iso(),
        "auto": auto, "notes": notes }))
}

/// `Add-HistoriqueMaj`, sur un historique déjà lu (il est enregistré).
pub fn ajouter_dans(ctx: &Contexte, h: &mut Historique, id: &str, nom: &str, version: &str, auto: bool, notes: &str) {
    let Some(e) = entree(ctx, id, nom, version, auto, notes) else {
        ctx.journal(&format!("Historique des mises à jour : {nom} {version} pas noté (valeurs inattendues)"));
        return;
    };
    h.liste.insert(0, e);
    h.liste.truncate(HISTORIQUE_MAX);
    enregistrer(ctx, h);
    ctx.journal(&format!(
        "Historique des mises à jour : {nom} {version} ({})",
        if auto { "automatique" } else { "faite par l'utilisateur" }
    ));
}

/// `Add-HistoriqueMaj`
pub fn ajouter(ctx: &Contexte, id: &str, nom: &str, version: &str, auto: bool, notes: &str) {
    if entree(ctx, id, nom, version, auto, notes).is_none() {
        ctx.journal(&format!("Historique des mises à jour : {nom} {version} pas noté (valeurs inattendues)"));
        return;
    }
    let mut h = lire(ctx);
    ajouter_dans(ctx, &mut h, id, nom, version, auto, notes);
}

/// `Set-MajMindsetAttendue` : la mise à jour de Mindset notée avant qu'il ne se ferme.
pub fn attendre_mindset(ctx: &Contexte, version: &str, auto: bool, notes: &str) {
    let mut h = lire(ctx);
    h.attendue = entree(ctx, "mindset", "Mindset", version, auto, notes);
    enregistrer(ctx, &h);
}

/// `Resolve-MajMindsetAttendue` : au démarrage, la mise à jour attendue est faite si c'est cette version qui tourne ;
/// sinon elle est oubliée.
pub fn resoudre_mindset(ctx: &Contexte) {
    let mut h = lire(ctx);
    let Some(a) = h.attendue.take() else { return };
    if suite_commun::chemins::egal(&a.version, &ctx.version) {
        ajouter_dans(ctx, &mut h, "mindset", "Mindset", &a.version, a.auto, &a.notes);
    } else {
        enregistrer(ctx, &h);
    }
}
