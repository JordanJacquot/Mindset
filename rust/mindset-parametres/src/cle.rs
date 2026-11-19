//! « Applis privées » (Mindset 3.1), dans l'onglet Mises à jour des Paramètres : la clé GitHub qui ouvre le dépôt
//! privé d'une appli (un jeton à grain fin de GitHub, en lecture seule). Un guide pas à pas pour la créer sur GitHub,
//! un champ pour la coller, « Essayer » (la clé est essayée sur le dépôt de chaque appli privée de la liste, et gardée
//! chiffrée seulement si elle en ouvre au moins un), « Retirer la clé », et un rappel quand elle va expirer.
//!
//! La clé ne va JAMAIS dans l'état envoyé à la page, ni au journal : elle passe seulement du champ de la page au
//! travail de fond qui l'essaie, puis au coffre chiffré (`mindset_noyau::cle_github`).

use serde_json::{Value, json};

use mindset_noyau::cle_github;
use mindset_noyau::moment;
use mindset_noyau::reseau::Jeton;
use mindset_noyau::{Contexte, partage};
use suite_commun::json_sur::HeureLocale;

/// Le travail de fond de « Essayer ».
pub const TACHE: &str = "cle-essai";
/// Le rappel vient 14 jours avant que la clé expire.
const RAPPEL_JOURS: i64 = 14;

/// Le guide, une étape par ligne (les mots entre guillemets sont ceux de la page de GitHub, en anglais).
pub const ETAPES: [&str; 6] = [
    "Clique sur « Ouvrir la page de GitHub » (connecte-toi à GitHub si on te le demande).",
    "Donne un nom à la clé (par exemple Mindset) et choisis une durée dans « Expiration » (90 jours, par exemple).",
    "Dans « Repository access », choisis « Only select repositories », puis le dépôt de l'appli privée.",
    "Dans « Permissions », ouvre « Repository permissions » et mets « Contents » sur « Read-only ». Ne change rien d'autre.",
    "Clique sur « Generate token » en bas de la page, puis copie la clé (elle commence par github_pat_).",
    "Colle-la ci-dessous, puis clique sur « Essayer ». Mindset la garde chiffrée sur ce PC, rien que pour toi.",
];

/// Ce que la section dit en ce moment (rien de secret).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct EtatCle {
    pub info: String,
    /// « ok », « attention », « urgent » ou vide
    pub ton: String,
    /// « Essayer » est en route
    pub en_cours: bool,
    /// Proposer « Relancer Mindset » (une appli privée apparaît ou disparaît au prochain démarrage)
    pub relancer: bool,
    /// Une clé est-elle gardée ? (lue au démarrage du bloc, puis tenue à jour : pas de déchiffrement à chaque état)
    pub presente: bool,
}

/// Les applis privées de la liste (`liste.privees`, du bloc « liste ») : (id, nom, dépôt).
pub fn privees(ctx: &Contexte) -> Vec<(String, String, String)> {
    let l = ctx.lu(partage::LISTE).unwrap_or(Value::Null);
    let t = |v: &Value, n: &str| v.get(n).and_then(Value::as_str).unwrap_or("").to_string();
    l.get("privees")
        .and_then(Value::as_array)
        .map(|a| a.iter().map(|p| (t(p, "id"), t(p, "nom"), t(p, "depot"))).filter(|p| !p.2.is_empty()).collect())
        .unwrap_or_default()
}

/// La date d'expiration donnée par GitHub (« 2027-02-01 10:00:00 UTC », ou avec un fuseau « +0100 »).
pub fn lire_expiration(t: &str) -> Option<HeureLocale> {
    let t = t.trim();
    let debut = t.get(..19)?;
    moment::lire_iso(&debut.replacen(' ', "T", 1))
}

/// « 01/02/2027 »
fn date(h: &HeureLocale) -> String {
    format!("{:02}/{:02}/{}", h.jour, h.mois, h.annee)
}

/// Le rappel : la clé expire bientôt (14 jours au plus), ou a expiré. Vide sinon.
pub fn rappel(expire: Option<&HeureLocale>, maintenant: &HeureLocale) -> String {
    let Some(e) = expire else { return String::new() };
    let reste = moment::ecart(maintenant, e);
    let jours = reste.div_euclid(86400);
    if reste <= 0 {
        return format!("Ta clé GitHub a expiré le {} : refais-en une (le guide est juste en dessous).", date(e));
    }
    if jours >= RAPPEL_JOURS {
        return String::new();
    }
    let quand = match jours {
        0 => "aujourd'hui".to_string(),
        1 => "demain".to_string(),
        n => format!("dans {n} jours"),
    };
    format!("Ta clé GitHub expire {quand} (le {}) : refais-en une avant, avec le guide juste en dessous.", date(e))
}

/// L'état de la section, pour la page.
pub fn etat(ctx: &Contexte, e: &EtatCle) -> Value {
    let liste = privees(ctx);
    let cle = e.presente;
    let expire = ctx.reglage("CleGithubExpire").and_then(|v| v.as_str().and_then(lire_expiration)).filter(|_| cle);
    // (les noms seulement quand la clé les ouvre : sans clé, la section ne nomme aucune appli privée)
    let applis: Vec<String> =
        if cle { ctx.applis().iter().filter(|a| a.prive).map(|a| a.nom.clone()).collect() } else { Vec::new() };
    json!({
        "visible": !liste.is_empty() || cle,
        "cle": cle,
        "applis": applis,
        "expire": expire.as_ref().map(date).unwrap_or_default(),
        "rappel": rappel(expire.as_ref(), &ctx.heure()),
        "info": e.info,
        "ton": e.ton,
        "en_cours": e.en_cours,
        "relancer": e.relancer,
        "etapes": ETAPES,
    })
}

/// Le travail de fond de « Essayer » : la clé essayée sur chaque appli privée de la liste. Le résultat ne contient
/// jamais la clé.
pub fn travail(
    ctx: &Contexte,
    jeton: Jeton,
    liste: Vec<(String, String, String)>,
) -> impl FnOnce() -> Result<Value, String> + Send + 'static {
    let reseau = ctx.reseau();
    move || {
        let e = cle_github::essayer(&*reseau, &jeton, &liste);
        let ouvertes: Vec<Value> =
            e.ouvertes.iter().map(|(id, nom, v)| json!({ "id": id, "nom": nom, "version": v })).collect();
        Ok(json!({ "ouvertes": ouvertes, "expire": e.expire, "injoignable": e.injoignable }))
    }
}

/// La fin de « Essayer » : la clé gardée (chiffrée) seulement si elle ouvre au moins une appli privée.
pub fn fin_essai(ctx: &Contexte, e: &mut EtatCle, jeton: Option<Jeton>, r: Result<Value, String>) {
    e.en_cours = false;
    let r = r.unwrap_or(Value::Null);
    let ouvertes: Vec<(String, String, String)> = r
        .get("ouvertes")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .map(|x| {
                    let t = |n: &str| x.get(n).and_then(Value::as_str).unwrap_or("").to_string();
                    (t("id"), t("nom"), t("version"))
                })
                .collect()
        })
        .unwrap_or_default();
    let Some(jeton) = jeton else { return };
    if ouvertes.is_empty() {
        let injoignable = r.get("injoignable").and_then(Value::as_bool).unwrap_or(r.is_null());
        e.ton = "urgent".into();
        e.info = if injoignable {
            "GitHub ne répond pas : vérifie ta connexion à Internet, puis réessaie. La clé n'a pas été gardée.".into()
        } else {
            "Cette clé n'ouvre aucune appli privée : vérifie le dépôt choisi et « Contents » sur « Read-only », puis réessaie. Elle n'a pas été gardée.".into()
        };
        ctx.journal("Applis privées : clé GitHub essayée, refusée (pas gardée)");
        return;
    }
    if let Err(x) = cle_github::enregistrer(&ctx.dossiers, &jeton) {
        e.ton = "urgent".into();
        e.info = format!("La clé marche, mais Mindset n'a pas pu la garder sur ce PC ({x}).");
        ctx.journal(&format!("Applis privées : clé GitHub pas gardée ({x})"));
        return;
    }
    e.presente = true;
    match r.get("expire").and_then(Value::as_str) {
        Some(x) => ctx.ecrire_reglage("CleGithubExpire", json!(x)),
        None => ctx.ecrire_reglage("CleGithubExpire", Value::Null),
    }
    let noms: Vec<String> =
        ouvertes.iter().map(|(_, n, v)| if v.is_empty() { n.clone() } else { format!("{n} (version {v})") }).collect();
    e.ton = "ok".into();
    e.info = format!("Ta clé marche : elle ouvre {}. Elle est gardée chiffrée sur ce PC.", noms.join(" et "));
    let deja: Vec<String> = ctx.applis().iter().filter(|a| a.prive).map(|a| a.id.clone()).collect();
    if ouvertes.iter().any(|(id, _, _)| !deja.contains(id)) {
        e.relancer = true;
        e.info.push_str(" Relance Mindset pour la voir dans l'accueil.");
    }
    ctx.journal(&format!("Applis privées : clé GitHub gardée ({} appli(s) ouverte(s))", ouvertes.len()));
}

/// « Retirer la clé ».
pub fn retirer(ctx: &Contexte, e: &mut EtatCle) {
    match cle_github::retirer(&ctx.dossiers) {
        Ok(()) => {
            e.presente = false;
            ctx.ecrire_reglage("CleGithubExpire", Value::Null);
            e.ton = String::new();
            e.info = "Clé retirée de ce PC.".into();
            if ctx.applis().iter().any(|a| a.prive) {
                e.relancer = true;
                e.info.push_str(" Les applis privées partiront de l'accueil au prochain démarrage de Mindset.");
            }
            ctx.journal("Applis privées : clé GitHub retirée");
        }
        Err(x) => {
            e.ton = "urgent".into();
            e.info = format!("La clé n'a pas pu être retirée ({x}).");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(t: &str) -> HeureLocale {
        moment::lire_iso(t).unwrap()
    }

    #[test]
    fn expiration_et_rappel() {
        let e = lire_expiration("2027-02-01 10:00:00 UTC").unwrap();
        assert_eq!(date(&e), "01/02/2027");
        assert!(lire_expiration("2027-02-01 10:00:00 +0100").is_some());
        assert!(lire_expiration("demain").is_none());
        assert_eq!(rappel(Some(&e), &h("2027-01-01T10:00:00")), "");
        assert_eq!(
            rappel(Some(&e), &h("2027-01-27T09:00:00")),
            "Ta clé GitHub expire dans 5 jours (le 01/02/2027) : refais-en une avant, avec le guide juste en dessous."
        );
        assert!(rappel(Some(&e), &h("2027-01-31T11:00:00")).contains("expire aujourd'hui"));
        assert!(rappel(Some(&e), &h("2027-01-30T11:00:00")).contains("expire demain"));
        assert!(rappel(Some(&e), &h("2027-02-02T10:00:00")).starts_with("Ta clé GitHub a expiré le 01/02/2027"));
        assert_eq!(rappel(None, &h("2027-02-02T10:00:00")), "");
    }

    #[test]
    fn aucun_tiret_long_dans_les_textes() {
        for t in ETAPES {
            assert!(!t.contains(['\u{2013}', '\u{2014}']), "{t}");
        }
    }
}
