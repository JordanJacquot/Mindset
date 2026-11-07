//! Les juges du bloc « écrans » : les cartes, les questions, le bonjour, les dates des rendez-vous et les phrases
//! réseau, exportés depuis la VRAIE version PowerShell (outils\exporter-juges-ecrans.ps1 : la carte relue dans la
//! fenêtre WPF), rejoués ici avec les mêmes entrées. Chaque élément de chaque carte doit être le même (textes, tailles,
//! couleurs dans le thème, marges, boutons et leur style).

use std::path::Path;

use mindset_ecrans::{BlocEcrans, Ecrans, dessins, etat_appli, rdv};
use mindset_noyau::appli::Appli;
use mindset_noyau::moment;
use mindset_noyau::{Bloc, Effet, Effets, Lancement};
use serde_json::{Value, json};

fn juge(nom: &str) -> Value {
    let f = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(nom);
    let t = std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{} : {e}", f.display()));
    serde_json::from_str(t.trim_start_matches('\u{feff}')).unwrap()
}

/// Deux valeurs JSON pareilles (les nombres comparés comme des nombres : 20 et 20.0 sont égaux).
pub fn pareil(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(p, q)| pareil(p, q)),
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| pareil(v, w)))
        }
        _ => a == b,
    }
}

/// « {RACINE} » des juges remplacé par la racine d'essai.
fn sans_marque(v: &Value, racine: &str) -> Value {
    match v {
        Value::String(s) => Value::String(s.replace("{RACINE}", racine)),
        Value::Array(a) => Value::Array(a.iter().map(|x| sans_marque(x, racine)).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), sans_marque(x, racine))).collect()),
        x => x.clone(),
    }
}

/// Les applis d'essai : les mêmes que l'export.
fn applis(donnees: &str) -> Vec<Appli> {
    let a = |id: &str, nom: &str, couleur: &str, desc: &str, exe: &str| Appli {
        id: id.into(),
        nom: nom.into(),
        couleur: couleur.into(),
        description: desc.into(),
        exe: exe.into(),
        donnees: donnees.into(),
        logo_epaisseur: 0.12,
        ..Default::default()
    };
    vec![
        Appli {
            script: r"fichiers\Nevermind.ps1".into(),
            desinstalleur: "Désinstaller Nevermind.exe".into(),
            admin: true,
            sans_droits_depuis: "1.0.115".into(),
            confidentialite: "https://github.com/JordanJacquot/Nevermind/blob/main/CODE_SIGNING.md".into(),
            ..a("nevermind", "Nevermind", "#00E5FF", "Analyse et optimisation gaming", "Nevermind.exe")
        },
        Appli {
            script: r"fichiers\Evermind.ps1".into(),
            rappels: true,
            confidentialite: "https://github.com/JordanJacquot/Evermind/blob/main/CODE_SIGNING.md".into(),
            ..a("evermind", "Evermind", "#B04BFF", "L'agenda qui se souvient de tout pour toi", "Evermind.exe")
        },
        Appli {
            script: r"fichiers\Mindcare.ps1".into(),
            confidentialite: "https://github.com/JordanJacquot/Mindcare/blob/main/CODE_SIGNING.md".into(),
            ..a(
                "mindcare",
                "Mindcare",
                "#FF8A00",
                "Trouve pourquoi ton PC est en panne, en répondant à quelques questions simples.",
                "Mindcare.exe",
            )
        },
        a("zephyr", "Zéphyr", "#3DDC84", "Une appli inventée pour les essais", "Zephyr.exe"),
    ]
}

fn txt(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).map(str::to_string)
}

/// Un cas de l'export : le contexte d'essai rempli comme le faux PC de PowerShell, et le bloc démarré.
fn preparer(nom: &str, theme: &str, e: &Value) -> (mindset_noyau::Contexte, mindset_noyau::essai::Faux, Ecrans, Appli) {
    let admin = e.get("admin").and_then(Value::as_bool).unwrap_or(false);
    let (ctx, faux) = mindset_noyau::essai::contexte_avec(nom, Lancement { admin, ..Default::default() });
    let racine = faux.racine.to_string_lossy().to_string();
    let anciennes = faux.racine.join("cas").join("anciennes-donnees");
    if e.get("donnees_existe").and_then(Value::as_bool) == Some(true) {
        std::fs::create_dir_all(&anciennes).unwrap();
    }
    ctx.definir_applis(applis(&anciennes.to_string_lossy()));
    let id = txt(e, "appli").unwrap();
    let a = ctx.appli(&id).unwrap();
    let inst = e.get("inst").filter(|v| v.is_object());
    let gere = inst.and_then(|i| i.get("gere")).and_then(Value::as_bool).unwrap_or(false);
    if let Some(i) = inst {
        let dossier = if gere {
            ctx.dossiers.programmes.join(&a.nom).to_string_lossy().to_string()
        } else {
            txt(i, "dossier").unwrap().replace("{RACINE}", &racine)
        };
        ctx.au_nom_de("installations", || {
            ctx.publier(
                "installations",
                json!({ id.clone(): { "dossier": dossier, "gere": gere, "version": i.get("version") } }),
            )
        });
    }
    if let Some(t) = e.get("etat").filter(|v| !v.is_null()) {
        let d = if gere { ctx.dossiers.donnees_suite.join(&a.nom) } else { anciennes.clone() };
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("etat.json"), t.as_str().unwrap_or("")).unwrap();
    }
    if let Some(p) = e.get("pub").filter(|v| v.is_object()) {
        ctx.au_nom_de("publications", || {
            ctx.publier(
                "publications",
                json!({ id.clone(): { "version": p.get("version"), "erreur": p.get("erreur") } }),
            )
        });
    }
    if e.get("ouverte").and_then(Value::as_bool) == Some(true) {
        ctx.au_nom_de("liste", || ctx.publier("ouvertes", json!({ id.clone(): true })));
    }
    if let Some(t) = txt(e, "trouvee") {
        let t = t.replace("{RACINE}", &racine);
        if e.get("travail").and_then(Value::as_bool) == Some(true) {
            std::fs::create_dir_all(Path::new(&t).join(".git")).unwrap();
        }
        ctx.au_nom_de("installations", || ctx.publier("trouvees", json!({ id.clone(): t })));
    }
    ctx.au_nom_de("installations", || {
        if let Some(o) = txt(e, "occupe") {
            ctx.publier("occupations", json!({ id.clone(): { "texte": o } }));
        }
        if let Some(m) = txt(e, "message") {
            ctx.publier("messages", json!({ id.clone(): m }));
        }
        ctx.publier("demarrages", json!({ id.clone(): e.get("demarrage").and_then(Value::as_bool).unwrap_or(false) }));
    });
    ctx.au_nom_de("parametres", || ctx.publier("theme", json!({ "id": theme })));
    let mut b = BlocEcrans;
    let mut fx = Effets::default();
    ctx.au_nom_de("ecrans", || b.demarrer(&ctx, &mut fx));
    (ctx, faux, b, a)
}

/// La question posée par un bouton de la carte, et ce que fait son « Oui » (`{ titre, texte, bouton, valeur }` comme
/// l'export), ou `null` si le bouton agit tout de suite.
fn question(ctx: &mindset_noyau::Contexte, b: &mut Ecrans, id: &str, quoi: &str) -> Value {
    let mut fx = Effets::default();
    ctx.au_nom_de("ecrans", || b.action(ctx, "ecrans:carte", &json!({ "id": id, "quoi": quoi }), &mut fx));
    let Some(q) = b.question().cloned() else { return Value::Null };
    let mut fx2 = Effets::default();
    ctx.au_nom_de("ecrans", || b.action(ctx, "ecrans:confirmation", &json!({ "oui": true }), &mut fx2));
    let suite = fx2.0.iter().find_map(|e| match e {
        Effet::Signal { nom, donnees } if nom == "installer" || nom == "desinstaller" => Some(donnees.clone()),
        _ => None,
    });
    let mut valeur = json!({ "Id": id });
    if let Some(d) = suite.as_ref().and_then(|s| s.get("ancien")).and_then(Value::as_str) {
        valeur["Dossier"] = json!(d);
    }
    json!({ "titre": q.titre, "texte": q.texte, "bouton": q.bouton, "valeur": valeur })
}

fn rejouer(fichier: &str) -> usize {
    let cas = juge(fichier);
    let cas = cas.as_array().unwrap();
    assert!(!cas.is_empty());
    let mut ecarts = Vec::new();
    for (n, c) in cas.iter().enumerate() {
        let e = &c["entree"];
        let theme = c["theme"].as_str().unwrap();
        let (ctx, faux, mut b, a) = preparer(&format!("ecrans-{}-{n}", fichier.trim_end_matches(".json")), theme, e);
        let racine = faux.racine.to_string_lossy().to_string();
        let attendu = sans_marque(&c["carte"], &racine);
        let carte = b.carte(&ctx, &a);
        if !pareil(&carte["elements"], &attendu) {
            ecarts.push(format!(
                "{} ({theme}) :\n  attendu {}\n  obtenu  {}",
                c["nom"],
                serde_json::to_string(&attendu).unwrap(),
                serde_json::to_string(&carte["elements"]).unwrap()
            ));
        }
        let q = sans_marque(&c["questions"], &racine);
        for (k, quoi) in [("maj", "maj"), ("prendre", "prendre"), ("desinstaller", "desinstaller")] {
            let Some(att) = q.get(k) else { continue };
            let obtenu = question(&ctx, &mut b, &a.id, quoi);
            if !pareil(&obtenu, att) {
                ecarts.push(format!("{} : question « {k} »\n  attendu {att}\n  obtenu  {obtenu}", c["nom"]));
            }
        }
        drop(ctx);
        let _ = std::fs::remove_dir_all(&faux.racine);
    }
    assert!(ecarts.is_empty(), "{} écart(s) sur {} cas de {fichier} :\n{}", ecarts.len(), cas.len(), ecarts.join("\n"));
    cas.len()
}

#[test]
fn cartes_neon() {
    assert!(rejouer("cartes.json") >= 50);
}

#[test]
fn cartes_crepuscule() {
    assert!(rejouer("cartes-crepuscule.json") >= 30);
}

#[test]
fn cartes_terminal() {
    assert!(rejouer("cartes-terminal.json") >= 20);
}

#[test]
fn cartes_au_hasard() {
    assert!(rejouer("cartes-hasard.json") >= 60);
}

#[test]
fn bonjour() {
    for c in juge("bonjour.json").as_array().unwrap() {
        let heure = c["heure"].as_u64().unwrap() as u32;
        let pack = c["hello"].as_str().map(|h| suite_commun::themes::Pack {
            id: "foret".into(),
            dossier: Default::default(),
            nom: "Forêt".into(),
            description: String::new(),
            bonjour: h.into(),
            logo: None,
            logo_lueur: None,
            mascotte: None,
            chargement: None,
            bas: None,
            fond: None,
            police: None,
            pixel: true,
            console: None,
        });
        assert_eq!(dessins::bonjour(heure, pack.as_ref()), c["texte"].as_str().unwrap(), "{c}");
    }
}

#[test]
fn dates_des_rendez_vous() {
    let l = juge("quand-rdv.json");
    for c in l.as_array().unwrap() {
        let m = moment::lire_iso(c["maintenant"].as_str().unwrap()).unwrap();
        let r = etat_appli::Rdv {
            id: String::new(),
            titre: String::new(),
            quand: moment::lire_iso(c["quand"].as_str().unwrap()).unwrap(),
            journee: c["journee"].as_bool().unwrap(),
        };
        assert_eq!(rdv::quand(&r, &m), c["texte"].as_str().unwrap(), "{c}");
    }
    assert!(l.as_array().unwrap().len() >= 90);
}

#[test]
fn phrases_reseau() {
    let tous = applis("");
    for c in juge("reseau.json").as_array().unwrap() {
        let a = tous.iter().find(|a| a.id == c["id"].as_str().unwrap()).unwrap();
        assert_eq!(mindset_ecrans::cartes::phrase_reseau(a), c["phrase"].as_str().unwrap());
        assert_eq!(mindset_ecrans::cartes::lien_reseau(a), c["lien"].as_str().unwrap());
    }
}

/// La contre-épreuve : un octet changé dans un juge fait échouer la comparaison (les juges comptent vraiment).
#[test]
fn contre_epreuve() {
    let cas = juge("cartes.json");
    let c = &cas[27];
    let (ctx, faux, b, a) = preparer("ecrans-contre-epreuve", "neon", &c["entree"]);
    let racine = faux.racine.to_string_lossy().to_string();
    let attendu = sans_marque(&c["carte"], &racine);
    let obtenu = b.carte(&ctx, &a)["elements"].clone();
    assert!(pareil(&obtenu, &attendu), "le cas lui-même passe");
    let texte = serde_json::to_string(&attendu).unwrap();
    // (chaque changement d'un seul caractère dans les textes, les couleurs ou les nombres est vu)
    for (de, vers) in
        [("Nevermind", "Nevermynd"), ("#A9A3C9", "#A9A3C8"), ("\"taille\":20", "\"taille\":21"), ("82", "83")]
    {
        let faux_juge: Value = serde_json::from_str(&texte.replacen(de, vers, 1)).unwrap();
        assert!(!pareil(&obtenu, &faux_juge), "le changement {de} -> {vers} n'est pas vu");
    }
    let _ = std::fs::remove_dir_all(&faux.racine);
}
