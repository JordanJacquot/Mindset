//! Les captures « après » : l'état complet de la page pour chaque scène de outils\vitrine.ps1 (les mêmes données que
//! les captures de la version PowerShell), calculé par le bloc « écrans » ; les clés des autres blocs (bandeaux, page
//! d'une appli, question de la croix) sont posées dans la forme fixée par l'architecture.
//!
//! Écrit seulement si `MINDSET_VITRINE_SORTIE` donne un dossier (outils\captures-apres.ps1) ; sinon, le test vérifie
//! juste que chaque scène se calcule.

use mindset_ecrans::BlocEcrans;
use mindset_noyau::appli::Appli;
use mindset_noyau::{Bloc, Effets, moment};
use serde_json::{Map, Value, json};

fn applis() -> Vec<Appli> {
    vec![
        Appli {
            id: "nevermind".into(),
            nom: "Nevermind".into(),
            couleur: "#00E5FF".into(),
            description: "Analyse et optimisation gaming".into(),
            exe: "Nevermind.exe".into(),
            script: r"fichiers\Nevermind.ps1".into(),
            desinstalleur: "Désinstaller Nevermind.exe".into(),
            admin: true,
            sans_droits_depuis: "1.0.115".into(),
            confidentialite: "https://github.com/JordanJacquot/Nevermind/blob/main/CODE_SIGNING.md".into(),
            logo_epaisseur: 0.12,
            ..Default::default()
        },
        Appli {
            id: "evermind".into(),
            nom: "Evermind".into(),
            couleur: "#B04BFF".into(),
            description: "L'agenda qui se souvient de tout pour toi".into(),
            exe: "Evermind.exe".into(),
            script: r"fichiers\Evermind.ps1".into(),
            rappels: true,
            confidentialite: "https://github.com/JordanJacquot/Evermind/blob/main/CODE_SIGNING.md".into(),
            logo_epaisseur: 0.12,
            ..Default::default()
        },
        Appli {
            id: "mindcare".into(),
            nom: "Mindcare".into(),
            couleur: "#FF8A00".into(),
            description: "Trouve pourquoi ton PC est en panne, en répondant à quelques questions simples.".into(),
            exe: "Mindcare.exe".into(),
            script: r"fichiers\Mindcare.ps1".into(),
            confidentialite: "https://github.com/JordanJacquot/Mindcare/blob/main/CODE_SIGNING.md".into(),
            logo: "M14,52 L31,52 L38,31 L47,73 L57,20 L66,66 L71,52 L86,52".into(),
            logo_epaisseur: 0.12,
            ..Default::default()
        },
    ]
}

const SCENES: &[&str] = &[
    "accueil-neon",
    "accueil-crepuscule",
    "accueil-terminal",
    "bienvenue",
    "bandeaux",
    "confirmation",
    "fermeture",
    "jauge",
    "ecran-ouvrir",
    "non-installe",
    "parametres",
];

fn scene(nom: &str, maintenant: &moment::HeureLocale) -> Value {
    let (ctx, faux) = mindset_noyau::essai::contexte(&format!("ecrans-vitrine-{nom}"));
    ctx.figer_heure(*maintenant);
    // (l'ancien dossier de données des applis : un dossier d'essai qui n'existe pas)
    let mut l = applis();
    for a in &mut l {
        a.donnees = faux.racine.join(format!("ancien-{}", a.id)).to_string_lossy().to_string();
    }
    ctx.definir_applis(l);
    let p = &ctx.dossiers.programmes;
    ctx.au_nom_de("installations", || {
        ctx.publier(
            "installations",
            json!({
                "nevermind": { "dossier": p.join("Nevermind").to_string_lossy(), "gere": true, "version": "2.0.1" },
                "evermind": { "dossier": p.join("Evermind").to_string_lossy(), "gere": true, "version": "1.4.0" },
            }),
        );
        ctx.publier("demarrages", json!({ "nevermind": true, "evermind": false }));
    });
    ctx.au_nom_de("liste", || ctx.publier("ouvertes", json!({ "nevermind": true })));
    ctx.au_nom_de("publications", || ctx.publier("publications", json!({ "evermind": { "version": "1.5.0" } })));
    let theme = match nom {
        "accueil-crepuscule" => "crepuscule",
        "accueil-terminal" => "terminal",
        _ => "neon",
    };
    ctx.au_nom_de("parametres", || ctx.publier("theme", json!({ "id": theme })));
    // Les résumés, les mêmes que vitrine.ps1
    let dn = ctx.dossiers.donnees_suite.join("Nevermind");
    std::fs::create_dir_all(&dn).unwrap();
    std::fs::write(
        dn.join("etat.json"),
        r#"{"Score":82,"Protection":64,"AFaire":"Mettre à jour le pilote graphique","Urgent":false,"NbAFaire":1}"#,
    )
    .unwrap();
    let de = ctx.dossiers.donnees_suite.join("Evermind");
    std::fs::create_dir_all(&de).unwrap();
    let jour = moment::HeureLocale { heure: 0, minute: 0, seconde: 0, ..*maintenant };
    let a = |s: i64| moment::iso(&moment::ajouter(&jour, s));
    let rdv = json!({ "Prochains": [
        { "Id": format!("{}1", "a".repeat(31)), "Titre": "Appeler maman", "Quand": a(i64::from(maintenant.heure + 1) * 3600 + 15 * 60), "Journee": false },
        { "Id": format!("{}2", "a".repeat(31)), "Titre": "Dentiste", "Quand": a(86_400 + 9 * 3600), "Journee": false },
        { "Id": format!("{}3", "a".repeat(31)), "Titre": "Anniversaire de Léa", "Quand": a(3 * 86_400), "Journee": true },
    ] });
    std::fs::write(de.join("etat.json"), rdv.to_string()).unwrap();

    let page = match nom {
        "jauge" => "nevermind",
        "ecran-ouvrir" => "evermind",
        "non-installe" => "mindcare",
        "parametres" => "parametres",
        _ => "accueil",
    };
    ctx.definir_vue(mindset_noyau::Vue { visible: true, reduite: false, page: page.into() });
    let mut b = BlocEcrans;
    let mut fx = Effets::default();
    ctx.au_nom_de("ecrans", || b.demarrer(&ctx, &mut fx));
    if nom == "confirmation" {
        ctx.au_nom_de("ecrans", || {
            b.action(&ctx, "ecrans:carte", &json!({ "id": "evermind", "quoi": "desinstaller" }), &mut fx)
        });
    }
    let mut etat: Map<String, Value> = ctx.au_nom_de("ecrans", || b.etat(&ctx));
    etat.insert("_vue".into(), json!({ "page": page, "visible": true, "reduite": false, "version": "3.0.0" }));
    // Les clés des autres blocs (formes de l'architecture, partie 5)
    match nom {
        "bienvenue" => {
            etat.insert(
                "bienvenue".into(),
                json!({ "visible": true, "verif": true, "en_cours": false, "disques": [
                    { "lettre": "", "texte": "C: (dans Program Files, comme les autres programmes)", "libre": "120 Go libres" },
                    { "lettre": "D", "texte": r"D:\Mindset", "libre": "900 Go libres" } ] }),
            );
        }
        "bandeaux" => {
            etat.insert("admin_bandeau".into(), json!({ "visible": true, "bouton_actif": true }));
            etat.insert(
                "maj_mindset".into(),
                json!({ "visible": true, "titre": "Mindset 3.0.1 est prêt",
                    "texte": "La nouvelle version est téléchargée et sa signature vérifiée. Mindset va se fermer, se mettre à jour et se rouvrir tout seul.",
                    "bouton_maj": true, "bouton_fermer": "Plus tard" }),
            );
        }
        "fermeture" => {
            etat.insert("fermeture".into(), json!({ "visible": true }));
        }
        "jauge" => {
            etat.insert(
                "pages_applis".into(),
                json!({ "nevermind": { "etat": "lancement", "titre": "Nevermind", "texte": "Ouverture...", "bouton_ici": false,
                    "jauge": { "texte": "Ouverture...", "depuis_ms": 10100, "duree_s": 20 }, "ecran_ouvrir": false, "montree": false } }),
            );
        }
        "ecran-ouvrir" => {
            etat.insert(
                "pages_applis".into(),
                json!({ "evermind": { "etat": "vide", "titre": "Evermind", "texte": "Evermind est fermé.", "bouton_ici": true,
                    "bouton_texte": "Ouvrir Evermind", "jauge": null, "ecran_ouvrir": true, "montree": false } }),
            );
        }
        _ => {}
    }
    drop(ctx);
    let _ = std::fs::remove_dir_all(&faux.racine);
    Value::Object(etat)
}

#[test]
fn scenes_de_la_vitrine() {
    let sortie = std::env::var("MINDSET_VITRINE_SORTIE").ok().filter(|s| !s.is_empty());
    let maintenant = sortie
        .as_ref()
        .and_then(|d| std::fs::read_to_string(std::path::Path::new(d).join("maintenant.txt")).ok())
        .and_then(|t| moment::lire_iso(t.trim()))
        .unwrap_or_else(|| moment::lire_iso("2026-11-07T20:00:00").unwrap());
    for n in SCENES {
        let e = scene(n, &maintenant);
        assert!(e["ecrans"]["cartes"].as_array().is_some_and(|c| c.len() == 3), "{n}");
        if let Some(d) = &sortie {
            let dossier = std::path::Path::new(d).join("etats");
            std::fs::create_dir_all(&dossier).unwrap();
            std::fs::write(dossier.join(format!("{n}.json")), serde_json::to_string(&e).unwrap()).unwrap();
        }
    }
}
