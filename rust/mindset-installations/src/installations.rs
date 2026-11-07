//! installations.json et l'installation connue d'une appli (installations.ps1:21-104) : `Get-DossierGere`,
//! `Get-DossierDonnees`, `Read-Installations`, `Save-Installation`, `Get-Installation`.

use mindset_noyau::{Appli, Contexte, Installation};
use serde_json::{Map, Value, json};
use suite_commun::chemins;
use suite_commun::protocole_installateur::{texte_ps, vrai_ps};

use crate::regles::{dossier_appli, existe, joindre, version_dans};

/// Une entrée d'installations.json.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entree {
    pub dossier: String,
    pub gere: bool,
}

/// `Get-DossierGere` : `<programmes>\<Nom>`.
pub fn dossier_gere(ctx: &Contexte, appli: &Appli) -> String {
    joindre(&ctx.dossiers.programmes.to_string_lossy(), &appli.nom)
}

/// `$SuiteDir`
pub fn suite_dir(ctx: &Contexte) -> String {
    ctx.dossiers.donnees_suite.to_string_lossy().into_owned()
}

/// `Read-Installations` : les entrées dans l'ordre du fichier (abîmé ou absent : aucune). `pour_ecrire` : une erreur
/// s'il ne peut pas être lu (pris par un autre programme).
pub fn lire(ctx: &Contexte, pour_ecrire: bool) -> Result<Vec<(String, Entree)>, String> {
    match ctx.donnees().lire_json(&ctx.dossiers.installations()) {
        Ok(Some(Value::Object(m))) => Ok(m
            .iter()
            .map(|(k, v)| {
                let dossier = v.get("dossier").map(texte_ps).unwrap_or_default();
                let gere = v.get("gere").is_some_and(vrai_ps);
                (k.clone(), Entree { dossier, gere })
            })
            .collect()),
        Ok(_) => Ok(Vec::new()),
        Err(e) => {
            if pour_ecrire {
                return Err(e);
            }
            ctx.journal(&format!("installations.json illisible : {e}"));
            Ok(Vec::new())
        }
    }
}

/// Une entrée (les clés d'une table de PowerShell ne tiennent pas compte des majuscules).
pub fn entree(ctx: &Contexte, id: &str) -> Option<Entree> {
    lire(ctx, false).ok()?.into_iter().find(|(k, _)| k.eq_ignore_ascii_case(id)).map(|(_, e)| e)
}

/// `Save-Installation` : l'entrée est écrite (ou retirée si `dossier` est `None`). Illisible : rien n'est écrit.
pub fn enregistrer(ctx: &Contexte, id: &str, dossier: Option<&str>, gere: bool) {
    let mut r = match lire(ctx, true) {
        Ok(r) => r,
        Err(e) => {
            ctx.journal(&format!("installations.json pas modifié ({id}) : {e}"));
            return;
        }
    };
    let place = r.iter().position(|(k, _)| k.eq_ignore_ascii_case(id));
    match (dossier.filter(|d| !d.is_empty()), place) {
        (Some(d), Some(i)) => r[i].1 = Entree { dossier: d.into(), gere },
        (Some(d), None) => r.push((id.into(), Entree { dossier: d.into(), gere })),
        (None, Some(i)) => {
            r.remove(i);
        }
        (None, None) => {}
    }
    let mut o = Map::new();
    for (k, e) in r {
        o.insert(k, json!({ "dossier": e.dossier, "gere": e.gere }));
    }
    if let Err(e) = ctx.donnees().ecrire_json(&ctx.dossiers.installations(), &Value::Object(o)) {
        ctx.journal(&format!("installations.json pas modifié ({id}) : {e}"));
    }
}

/// `Get-Installation` : l'installation connue d'une appli. `occupee` : une opération est en cours sur elle (son
/// dossier peut manquer quelques secondes, elle reste notée).
pub fn installation(ctx: &Contexte, appli: &Appli, occupee: bool) -> Option<Installation> {
    let mut r = entree(ctx, &appli.id);
    let gere = dossier_gere(ctx, appli);
    // installations.json est modifiable par n'importe quel programme : une installation « gérée » n'est crue que dans
    // le dossier protégé des programmes
    if let Some(e) = &r
        && e.gere
        && !chemins::egal(&e.dossier, &gere)
    {
        ctx.journal(&format!("installations.json : {} « géré » hors de {gere}, ignoré", appli.nom));
        r = None;
    }
    if let Some(e) = &r
        && dossier_appli(&e.dossier, appli)
    {
        return Some(Installation {
            dossier: e.dossier.clone(),
            gere: e.gere,
            version: version_dans(&e.dossier, appli),
        });
    }
    if let Some(e) = &r {
        if occupee {
            return Some(Installation { dossier: e.dossier.clone(), gere: e.gere, version: None });
        }
        enregistrer(ctx, &appli.id, None, false);
        if e.gere {
            ctx.donnees().ecrire_suite_appli(&appli.id, None);
        }
    }
    // Copie gérée présente mais oubliée (installations.json effacé)
    if dossier_appli(&gere, appli) {
        enregistrer(ctx, &appli.id, Some(&gere), true);
        ctx.donnees().ecrire_suite_appli(&appli.id, Some(&gere));
        return Some(Installation { version: version_dans(&gere, appli), dossier: gere, gere: true });
    }
    None
}

/// `Get-DossierDonnees` : celui de la suite si elle est gérée et l'a déjà adopté, sinon son ancien dossier.
pub fn dossier_donnees(ctx: &Contexte, appli: &Appli) -> String {
    let suite = joindre(&suite_dir(ctx), &appli.nom);
    if entree(ctx, &appli.id).is_some_and(|e| e.gere) && existe(&suite) { suite } else { appli.donnees.clone() }
}
