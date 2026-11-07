//! Paramètres, Consommation : ce que consomme toute la suite (`Measure-ConsoSuite`, parametres.ps1:227-258). Les
//! parties mesurées : Mindset (ce processus et son dossier), chaque appli (son dossier des programmes ET son dossier
//! de données : ses programmes d'aide y tournent), le WebView2 de la suite, et les programmes d'aide lancés depuis les
//! dossiers de la suite. La mesure elle-même est à Windows ([`crate::plateforme::Plateforme::mesurer`]).

use serde_json::{Value, json};

use mindset_noyau::{Contexte, partage};

use crate::plateforme::{DemandeMesure, Partie};
use crate::textes;

pub const NOM_AIDE: &str = "Programmes d'aide";
pub const NOM_WEBVIEW: &str = "WebView2 de la suite";

fn sans_barre(d: &str) -> &str {
    d.trim_end_matches('\\')
}

/// `Get-DossierDonnees` : celui de la suite si l'appli est gérée et l'a déjà adopté, sinon l'ancien.
pub fn dossier_donnees(ctx: &Contexte, a: &mindset_noyau::Appli) -> String {
    let suite = ctx.dossiers.donnees_suite.join(&a.nom);
    match partage::installation(ctx, &a.id) {
        Some(i) if i.gere && suite.exists() => suite.to_string_lossy().into_owned(),
        _ => a.donnees.clone(),
    }
}

/// Ce que `Measure-ConsoSuite` demande à `MSProcessus.Mesurer`.
pub fn demande(ctx: &Contexte) -> DemandeMesure {
    let suite = ctx.dossiers.donnees_suite.to_string_lossy().into_owned();
    let mut noms = Vec::new();
    let mut dossiers = Vec::new();
    // Les dossiers WebView2 de la suite : celui des applis Tauri (Mindset 3.0 compris), et l'ancien profil commun
    let mut marqueurs = vec![
        format!("{}\\", ctx.dossiers.donnees_suite.join("WebView2-Tauri").to_string_lossy()),
        format!("{}\\", ctx.dossiers.donnees_suite.join("WebView2").to_string_lossy()),
    ];
    for a in ctx.applis().iter() {
        let i = partage::installation(ctx, &a.id);
        if let Some(i) = &i
            && !i.dossier.is_empty()
        {
            noms.push(a.nom.clone());
            dossiers.push(i.dossier.clone());
        }
        let mut vus: Vec<String> = Vec::new();
        for d in [dossier_donnees(ctx, a), a.donnees.clone()] {
            if vus.contains(&d) {
                continue;
            }
            vus.push(d.clone());
            if d.is_empty() || sans_barre(&d).eq_ignore_ascii_case(sans_barre(&suite)) {
                continue;
            }
            noms.push(if i.is_some() { a.nom.clone() } else { NOM_AIDE.to_string() });
            marqueurs.push(format!("{}\\", std::path::Path::new(&d).join("ecran-webview").to_string_lossy()));
            dossiers.push(d);
        }
    }
    for d in [suite.clone(), ctx.dossiers.programmes.to_string_lossy().into_owned()] {
        if !d.is_empty() {
            noms.push(NOM_AIDE.to_string());
            dossiers.push(d);
        }
    }
    DemandeMesure {
        moi: ctx.pid(),
        nom_moi: "Mindset".into(),
        dossier_moi: ctx.dossiers.mindset.to_string_lossy().into_owned(),
        noms,
        dossiers,
        nom_webview: NOM_WEBVIEW.into(),
        marqueurs,
    }
}

/// `$script:ConsoEtat` : le total et une ligne par partie qui a au moins un programme (`premiere` : le processeur
/// arrive à la mesure suivante).
pub fn etat(parties: &[Partie], premiere: bool) -> Value {
    let mut memoire = 0i64;
    let mut cpu = 0.0f64;
    let mut lignes = Vec::new();
    for p in parties.iter().filter(|p| p.nombre > 0) {
        memoire += p.memoire;
        cpu += p.processeur;
        let mut detail = match p.nom.as_str() {
            "Mindset" => "le portail".to_string(),
            NOM_WEBVIEW => "l'affichage de la console et des écrans".to_string(),
            NOM_AIDE => "lancés depuis les dossiers de la suite".to_string(),
            _ => "ouvert".to_string(),
        };
        if p.nombre > 1 {
            detail = format!("{detail}, {} programmes", p.nombre);
        }
        lignes.push(json!({
            "nom": p.nom, "detail": detail, "memoire": textes::memoire(p.memoire),
            "processeur": if premiere { "...".to_string() } else { textes::processeur(p.processeur) },
        }));
    }
    json!({
        "memoire": textes::memoire(memoire),
        "processeur": if premiere { "...".to_string() } else { textes::processeur(cpu) },
        "lignes": lignes,
    })
}

/// `Test-ConsoVisible` : l'onglet Consommation est-il à l'écran (la page des Paramètres, ou les Paramètres dans
/// l'écran de la console) ?
pub fn visible(ctx: &Contexte, onglet: &str) -> bool {
    let v = ctx.vue();
    let console = ctx.lu(partage::CONSOLE).and_then(|c| c.get("parametres").and_then(Value::as_bool)).unwrap_or(false);
    v.visible && !v.reduite && onglet == "conso" && (v.page == "parametres" || (console && v.page == "accueil"))
}
