//! Tests des thèmes : d'abord les juges exportés de PowerShell (outils\exporter-juges-themes.ps1 : les vraies fonctions
//! de Mindcare et de Mindset sur les mêmes fichiers), puis ce que PowerShell ne vérifie pas (lisibilité, liens,
//! extensions, noms réservés) et les cas où la bibliothèque est volontairement plus stricte.
//! Les packs d'essai sont inventés (« essai-bleu »...).

use super::*;

/// Un dossier d'essai neuf sous le dossier temporaire, effacé à la fin.
struct Dossier(PathBuf);
impl Dossier {
    fn nouveau(nom: &str) -> Dossier {
        let d = std::env::temp_dir().join(format!("suite-commun-themes-{nom}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        Dossier(d)
    }
    /// Écrit un fichier (texte), dossiers compris.
    fn ecrire(&self, chemin: &str, contenu: &str) -> PathBuf {
        let f = self.0.join(chemin);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(&f, contenu.as_bytes()).unwrap();
        f
    }
    /// Les dossiers de packs d'une appli gérée : le sien, puis celui de Mindset.
    fn racines(&self) -> Vec<PathBuf> {
        vec![self.0.join(r"donnees\Mindcare\packs"), self.0.join(r"donnees\Mindset\packs")]
    }
    fn suite(&self) -> PathBuf {
        self.0.join("suite.json")
    }
}
impl Drop for Dossier {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Les juges de PowerShell
// ---------------------------------------------------------------------------------------------------------------

const JUGES: &str = include_str!("../../juges/themes.json");

fn txt(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

/// Compare un nom d'image attendu (ou null) à ce que la bibliothèque a trouvé.
fn meme_image(cas: &str, quoi: &str, attendu: &Value, trouve: Option<&Image>, dossier: &Path) {
    let a = txt(attendu);
    assert_eq!(a, trouve.map(|i| i.fichier.clone()), "{cas} : {quoi}");
    if let Some(i) = trouve {
        assert_eq!(i.chemin, dossier.join(&i.fichier), "{cas} : {quoi} hors du dossier du pack");
    }
}

fn meme_planche(cas: &str, quoi: &str, attendu: &Value, trouve: Option<&Planche>, dossier: &Path) {
    if attendu.is_null() {
        assert!(trouve.is_none(), "{cas} : {quoi} inattendu ({trouve:?})");
        return;
    }
    let p = trouve.unwrap_or_else(|| panic!("{cas} : {quoi} manquant"));
    meme_image(cas, quoi, &attendu["fichier"], Some(&p.image), dossier);
    assert_eq!(Some(u64::from(p.images)), attendu["images"].as_u64(), "{cas} : {quoi}, images");
    assert_eq!(Some(u64::from(p.delai)), attendu["delai"].as_u64(), "{cas} : {quoi}, délai");
}

fn alignement(a: Alignement, x: bool) -> &'static str {
    match (a, x) {
        (Alignement::Debut, true) => "Left",
        (Alignement::Fin, true) => "Right",
        (Alignement::Debut, false) => "Top",
        (Alignement::Fin, false) => "Bottom",
        (Alignement::Centre, _) => "Center",
    }
}

fn comparer_pack(cas: &str, a: &Value, p: &Pack, racine: &Path) {
    let dossier = racine.join(a["dossier"].as_str().unwrap());
    assert_eq!(p.dossier, dossier, "{cas} : dossier du pack");
    assert_eq!(Some(p.id.as_str()), a["id"].as_str(), "{cas} : id");
    assert_eq!(Some(p.nom.as_str()), a["nom"].as_str(), "{cas} : nom");
    assert_eq!(Some(p.description.as_str()), a["description"].as_str(), "{cas} : description");
    assert_eq!(Some(p.bonjour.as_str()), a["bonjour"].as_str(), "{cas} : phrase d'accueil");
    meme_planche(cas, "logo", &a["logo"], p.logo.as_ref(), &dossier);
    assert_eq!(p.logo_lueur.as_deref().unwrap_or(""), a["logo_lueur"].as_str().unwrap(), "{cas} : lueur");
    meme_planche(cas, "mascotte", &a["mascotte"], p.mascotte.as_ref().map(|m| &m.planche), &dossier);
    if let Some(m) = &p.mascotte {
        assert_eq!(Some(m.miroir), a["mascotte"]["miroir"].as_bool(), "{cas} : mascotte, miroir");
        assert_eq!(Some(m.vignette), a["mascotte_vignette"].as_bool(), "{cas} : mascotte, vignette");
    }
    meme_planche(cas, "chargement", &a["chargement"], p.chargement.as_ref(), &dossier);
    meme_planche(cas, "bas", &a["bas"], p.bas.as_ref().map(|b| &b.planche), &dossier);
    if let Some(b) = &p.bas {
        assert_eq!(Some(u64::from(b.hauteur)), a["bas"]["hauteur"].as_u64(), "{cas} : bas, hauteur");
    }
    if a["fond"].is_null() {
        assert!(p.fond.is_none(), "{cas} : fond inattendu");
    } else {
        let f = p.fond.as_ref().unwrap_or_else(|| panic!("{cas} : fond manquant"));
        meme_image(cas, "fond", &a["fond"]["fichier"], Some(&f.image), &dossier);
        assert!((f.opacite - a["fond"]["opacite"].as_f64().unwrap()).abs() < 1e-9, "{cas} : opacité du fond");
        assert_eq!(alignement(f.x, true), a["fond"]["x"].as_str().unwrap(), "{cas} : fond, x");
        assert_eq!(alignement(f.y, false), a["fond"]["y"].as_str().unwrap(), "{cas} : fond, y");
    }
    if a["police"].is_null() {
        assert!(p.police.is_none(), "{cas} : police inattendue");
    } else {
        let po = p.police.as_ref().unwrap_or_else(|| panic!("{cas} : police manquante"));
        meme_image(cas, "police", &a["police"]["fichier"], Some(&po.fichier), &dossier);
        assert_eq!(Some(po.partout), a["police"]["partout"].as_bool(), "{cas} : police partout");
    }
    assert_eq!(Some(p.pixel), a["pixel"].as_bool(), "{cas} : pixel");
    let c = &a["console"];
    if c.is_null() {
        assert!(p.console.is_none(), "{cas} : console inattendue");
        return;
    }
    let pc = p.console.as_ref().unwrap_or_else(|| panic!("{cas} : console manquante"));
    let tuiles: BTreeMap<String, String> =
        c["tuiles"].as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string())).collect();
    let trouvees: BTreeMap<String, String> = pc.tuiles.iter().map(|(k, v)| (k.clone(), v.fichier.clone())).collect();
    assert_eq!(trouvees, tuiles, "{cas} : tuiles");
    meme_image(cas, "console, mascotte", &c["mascotte"], pc.mascotte.as_ref(), &dossier);
    meme_image(cas, "console, fond", &c["fond"], pc.fond.as_ref(), &dossier);
    meme_image(cas, "console, logo", &c["logo"], pc.logo.as_ref(), &dossier);
    assert!((pc.fond_opacite - c["fond_opacite"].as_f64().unwrap()).abs() < 1e-9, "{cas} : console, opacité");
    if c["chargement"].is_null() {
        assert!(pc.chargement.is_none(), "{cas} : console, chargement inattendu");
    } else {
        let ch = pc.chargement.as_ref().unwrap_or_else(|| panic!("{cas} : console, chargement manquant"));
        meme_image(cas, "console, chargement", &c["chargement"]["fichier"], Some(&ch.image), &dossier);
        assert_eq!(ch.tourne, c["chargement"]["effet"] == "tourne", "{cas} : console, effet");
    }
}

#[test]
fn juges_powershell() {
    let j: Value = serde_json::from_str(JUGES.trim_start_matches('\u{FEFF}')).unwrap();
    let essayees: Vec<String> =
        j["couleurs_essayees"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
    let cas = j["cas"].as_array().unwrap();
    assert!(cas.len() >= 30, "trop peu de juges ({})", cas.len());
    for (n, c) in cas.iter().enumerate() {
        let nom = c["nom"].as_str().unwrap();
        let d = Dossier::nouveau(&format!("juge{n}"));
        for (chemin, contenu) in c["fichiers"].as_object().unwrap() {
            d.ecrire(chemin, contenu.as_str().unwrap());
        }
        let t = theme_de_la_suite(&d.suite(), &d.racines());
        let a = &c["attendu"];
        assert_eq!(t.choix, txt(&a["choix"]), "{nom} : choix lu dans suite.json");
        assert!(
            t.id.eq_ignore_ascii_case(a["theme"].as_str().unwrap()),
            "{nom} : thème {} au lieu de {}",
            t.id,
            a["theme"]
        );
        assert_eq!(Some(t.couleurs.p.as_str()), a["P"].as_str(), "{nom} : P");
        assert_eq!(Some(t.couleurs.s.as_str()), a["S"].as_str(), "{nom} : S");
        assert_eq!(Some(t.couleurs.t.as_str()), a["T"].as_str(), "{nom} : T");
        let traductions: Vec<String> = essayees.iter().map(|h| t.traduire(h)).collect();
        let attendues: Vec<String> =
            a["traductions"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
        assert_eq!(traductions, attendues, "{nom} : traductions des couleurs");
        match (&a["pack"], &t.pack) {
            (Value::Null, None) => {}
            (Value::Null, Some(p)) => panic!("{nom} : pack inattendu ({})", p.dossier.display()),
            (_, None) => panic!("{nom} : pack manquant ({:?})", t.raisons),
            (ap, Some(p)) => comparer_pack(nom, ap, p, &d.0),
        }
        // Un repli a toujours sa raison
        if t.choix.is_none() || (t.choix.as_deref().is_some_and(|c| c.starts_with("pack:")) && t.pack.is_none()) {
            assert!(!t.raisons.is_empty(), "{nom} : repli sans raison");
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Thèmes intégrés et traduction
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn themes_integres_et_kit() {
    // Les variables du kit (kit.css) pour chaque thème intégré
    let kit = [
        ("neon", ["#00E5FF", "#B04BFF", "#FF2EB5", "#06050F", "#0C0920"]),
        ("crepuscule", ["#FF8A3D", "#FF3D7F", "#FFC83D", "#0B0508", "#1A0B12"]),
        ("terminal", ["#33FF77", "#B6FF3B", "#00E0A0", "#000302", "#030B06"]),
        ("arcade", ["#FBD000", "#E52521", "#1E88E5", "#050A20", "#0B1640"]),
        ("rubis", ["#FF3B3B", "#FFDE00", "#3B6FFF", "#0A0A0D", "#17171D"]),
    ];
    for (id, attendu) in kit {
        let t = charger(Some(id), &[]);
        assert_eq!(t.id, id);
        assert!(t.raisons.is_empty());
        assert_eq!(t.theme_ecran(), id);
        assert_eq!(t.couleurs_ecran(), None);
        let v: Vec<String> = t.variables_css().into_iter().map(|(_, c)| c).collect();
        assert_eq!(v, attendu, "{id}");
        // Les thèmes intégrés passent la règle de lisibilité
        assert_eq!(verifier_lisibilite(&t.couleurs), Ok(()), "{id}");
    }
    assert_eq!(charger(Some("TERMINAL"), &[]).police, Some("Cascadia Code, Consolas"));
    assert_eq!(charger(None, &[]).id, NEON);
}

#[test]
fn traduction_couleurs() {
    let t = charger(Some("crepuscule"), &[]);
    assert_eq!(t.traduire("#00E5FF"), "#FF8A3D");
    assert_eq!(t.traduire("#8000E5FF"), "#80FF8A3D");
    assert_eq!(t.traduire("#0c0920"), "#1A0B12");
    // Ce qui n'est pas une couleur est rendu tel quel
    for x in ["", "rouge", "#12345", "#1234567", "#GG0000", "#é0000"] {
        assert_eq!(t.traduire(x), x);
    }
    // Néon ne change rien, pas même la casse
    assert_eq!(charger(Some("neon"), &[]).traduire("#00b8d4"), "#00b8d4");
    // Arrondi au pair le plus proche (comme [math]::Round de .NET) : 255 × 0,5 = 127,5 donne 128
    assert_eq!(depuis_hsl(0.0, 0.0, 0.5), "808080");
    assert_eq!(depuis_hsl(0.0, 0.0, 0.5 / 255.0 * 1.0), "000000");
}

// ---------------------------------------------------------------------------------------------------------------
// suite.json
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn choix_dans_suite() {
    assert_eq!(choix_valable("Crepuscule").as_deref(), Some("crepuscule"));
    assert_eq!(choix_valable("pack:essai-bleu").as_deref(), Some("pack:essai-bleu"));
    for x in ["pack:Essai", "pack:", "pack:a/b", "pack:..", "PACK:essai", "pack:essai\n", "pack:essai bleu", "sombre"] {
        assert_eq!(choix_valable(x), None, "{x:?}");
    }
    assert_eq!(choix_valable(&format!("pack:{}", "a".repeat(40))).map(|c| c.len()), Some(45));
    assert_eq!(choix_valable(&format!("pack:{}", "a".repeat(41))), None);
}

#[test]
fn suite_absente_vide_abimee_et_copie() {
    let d = Dossier::nouveau("suite");
    let t = theme_de_la_suite(&d.suite(), &d.racines());
    assert_eq!((t.id.as_str(), t.raisons.clone()), ("neon", vec!["suite.json absent : Néon".to_string()]));
    d.ecrire("suite.json", "");
    assert_eq!(theme_de_la_suite(&d.suite(), &[]).raisons, vec!["suite.json vide : Néon".to_string()]);
    d.ecrire("suite.json", "{\"theme\": \"arc");
    let t = theme_de_la_suite(&d.suite(), &[]);
    assert!(t.raisons.iter().any(|r| r == "suite.json abîmé : Néon"), "{:?}", t.raisons);
    // Rien n'est modifié : suite.json appartient à Mindset
    assert_eq!(std::fs::read_to_string(d.suite()).unwrap(), "{\"theme\": \"arc");
    assert_eq!(std::fs::read_dir(&d.0).unwrap().count(), 1);
    // Abîmé avec une bonne copie .bak : le thème de la copie
    d.ecrire("suite.json.bak", r#"{"theme":"arcade"}"#);
    let t = theme_de_la_suite(&d.suite(), &[]);
    assert_eq!(t.id, "arcade");
    assert!(t.raisons.iter().any(|r| r.contains("repris de sa copie")), "{:?}", t.raisons);
    // Deux fois « theme » à la casse près : abîmé pour PowerShell, pareil ici
    d.ecrire("suite.json.bak", "{}");
    d.ecrire("suite.json", r#"{"theme":"arcade","Theme":"rubis"}"#);
    assert_eq!(theme_de_la_suite(&d.suite(), &[]).raisons, vec!["suite.json abîmé : Néon".to_string()]);
    d.ecrire("suite.json", "{\"theme\": \"arc");
    assert_eq!(std::fs::read_to_string(d.suite()).unwrap(), "{\"theme\": \"arc");
    d.ecrire("suite.json", r#"{"theme": 3}"#);
    assert_eq!(theme_de_la_suite(&d.suite(), &[]).raisons, vec!["thème mal écrit dans suite.json : Néon".to_string()]);
    d.ecrire("suite.json", r#"{"applis":{}}"#);
    assert_eq!(
        theme_de_la_suite(&d.suite(), &[]).raisons,
        vec!["aucun thème choisi dans suite.json : Néon".to_string()]
    );
    d.ecrire("suite.json", r#"{"theme":"pack:essai-absent"}"#);
    let t = theme_de_la_suite(&d.suite(), &d.racines());
    assert_eq!(t.id, "neon");
    assert_eq!(t.choix.as_deref(), Some("pack:essai-absent"));
    assert!(t.raisons[0].contains("introuvable"), "{:?}", t.raisons);
}

// ---------------------------------------------------------------------------------------------------------------
// Les packs : couleurs
// ---------------------------------------------------------------------------------------------------------------

/// Écrit `donnees\Mindcare\packs\<id>\pack.json` et rend le thème « pack:<id> ».
fn pack(d: &Dossier, id: &str, json: &str) -> Theme {
    d.ecrire(&format!(r"donnees\Mindcare\packs\{id}\pack.json"), json);
    charger(Some(&format!("pack:{id}")), &d.racines())
}

#[test]
fn couleurs_valables() {
    let d = Dossier::nouveau("couleurs");
    let t = pack(
        &d,
        "essai-bleu",
        r##"{"Name":"Essai bleu","Colors":{"P":"#4fc3f7","S":"#7C4DFF","T":"#FF4081","NH":"210","NS":0,"Map":{"#0c0920":"0A1A2B"}}}"##,
    );
    assert_eq!(t.id, "pack-essai-bleu");
    assert_eq!(t.nom, "Essai bleu");
    assert!(t.raisons.is_empty(), "{:?}", t.raisons);
    assert_eq!((t.couleurs.nh, t.couleurs.ns), (Some(210.0), 1.0));
    assert_eq!(t.theme_ecran(), "neon");
    let ecran = t.couleurs_ecran().unwrap();
    // (P telle qu'écrite dans le pack, comme PowerShell)
    assert_eq!(ecran[0], ("P", "#4fc3f7".to_string()));
    assert_eq!(ecran[4], ("fond2", "#0A1A2B".to_string()));
}

#[test]
fn couleurs_refusees_gardent_les_images_et_la_base() {
    let d = Dossier::nouveau("refus");
    d.ecrire(r"donnees\Mindcare\packs\essai-x\logo.png", "image");
    let refus = [
        (r##"{"P":"red","S":"#7C4DFF","T":"#FF4081"}"##, "P n'est pas"),
        (r##"{"P":"#0F0","S":"#7C4DFF","T":"#FF4081"}"##, "P n'est pas"),
        (r##"{"P":"#00E5FF\" Foo=\"<Bar/>","S":"#7C4DFF","T":"#FF4081"}"##, "P n'est pas"),
        (r##"{"P":"#00E5FF\n","S":"#7C4DFF","T":"#FF4081"}"##, "P n'est pas"),
        (r##"{"P":null,"S":"#7C4DFF","T":"#FF4081"}"##, "P n'est pas"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":{"0C0920":"<x>"}}"##, "Map contient"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":{"#0C092G":"000000"}}"##, "Map contient"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":["0C0920"]}"##, "Map n'est pas"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":{"#0C0920":"000000","0c0920":"111111"}}"##, "deux fois"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","NH":"teinte"}"##, "NH n'est pas"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","NH":true}"##, "NH n'est pas"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","NS":-1}"##, "NS est négatif"),
        // Lisibles au format, mais pas à l'écran
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":{"06050F":"F0F0F0"}}"##, "le texte"),
        (r##"{"P":"#0A0A20","S":"#7C4DFF","T":"#FF4081"}"##, "la couleur P"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":{"0C0920":"5A5A5A"}}"##, "le texte secondaire"),
        (r##"{"P":"#4FC3F7","S":"#7C4DFF","T":"#101010"}"##, "la couleur T"),
    ];
    for (colors, raison) in refus {
        let t = pack(&d, "essai-x", &format!(r#"{{"Base":"rubis","Logo":"logo.png","Colors":{colors}}}"#));
        assert_eq!(t.id, "rubis", "{colors}");
        assert!(t.pack.as_ref().unwrap().logo.is_some(), "{colors}");
        assert!(
            t.raisons.iter().any(|r| r.contains("couleurs refusées") && r.contains(raison)),
            "{colors} : {:?}",
            t.raisons
        );
        // Sans base connue : Néon
        let t = pack(&d, "essai-x", &format!(r#"{{"Base":"sombre","Colors":{colors}}}"#));
        assert_eq!(t.id, "neon", "{colors}");
    }
    // Colors pas un objet
    let t = pack(&d, "essai-x", r#"{"Colors":"bleu"}"#);
    assert_eq!(t.id, "neon");
    assert!(t.raisons[0].contains("Colors n'est pas"));
    // Sans P, S et T : pas de couleurs propres, sans erreur ; Colors faux : ignoré
    for colors in [r##"{"P":"#4FC3F7"}"##, "{}", "false", "0", "\"\""] {
        let t = pack(&d, "essai-x", &format!(r#"{{"Base":"Arcade","Colors":{colors}}}"#));
        assert_eq!((t.id.as_str(), t.raisons.len()), ("arcade", 0), "{colors}");
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Les packs : fichiers et chemins
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn images_jamais_hors_du_dossier() {
    let d = Dossier::nouveau("chemins");
    let p = r"donnees\Mindcare\packs\essai-x";
    d.ecrire(r"donnees\Mindcare\packs\secret.png", "image");
    d.ecrire(&format!(r"{p}\sous\logo.png"), "image");
    d.ecrire(&format!(r"{p}\logo.png"), "image");
    d.ecrire(&format!(r"{p}\note.txt"), "texte");
    d.ecrire(&format!(r"{p}\police.png"), "image");
    std::fs::create_dir_all(d.0.join(format!(r"{p}\dossier.png"))).unwrap();
    let refuses = [
        r"..\secret.png",
        "../secret.png",
        r"sous\logo.png",
        "sous/logo.png",
        r"C:\Windows\win.ini",
        r"\\serveur\partage\a.png",
        "logo.png:flux",
        "note.txt",
        "dossier.png",
        "absent.png",
        "NUL.png",
        "com1.png",
        "logo.png.",
        "logo.png ",
        "",
        "pack.json",
    ];
    for nom in refuses {
        let json = serde_json::json!({ "Logo": nom, "Background": nom, "Font": nom, "Mascotte": { "File": nom } });
        let t = pack(&d, "essai-x", &json.to_string());
        let pk = t.pack.unwrap();
        assert!(pk.logo.is_none() && pk.fond.is_none() && pk.police.is_none() && pk.mascotte.is_none(), "{nom:?}");
    }
    // Une image comme police, ou un nombre à la place d'un nom : refusés
    let t = pack(&d, "essai-x", r#"{"Logo":5,"Font":"police.png","Mascotte":"logo.png"}"#);
    let pk = t.pack.unwrap();
    assert!(pk.logo.is_none() && pk.police.is_none() && pk.mascotte.is_none());
    // Le bon nom passe, avec son chemin dans le dossier du pack
    let pk = pack(&d, "essai-x", r#"{"Logo":"logo.png"}"#).pack.unwrap();
    assert_eq!(pk.logo.unwrap().image.chemin, d.0.join(format!(r"{p}\logo.png")));
}

/// Un lien (jonction de dossier) dans un pack, ou un pack qui est lui-même une jonction : refusés. Les jonctions se
/// créent sans droit d'administrateur ; si Windows refuse quand même, le test le dit et s'arrête là.
#[cfg(windows)]
#[test]
fn liens_refuses() {
    let d = Dossier::nouveau("liens");
    let ailleurs = d.0.join("ailleurs");
    d.ecrire(r"ailleurs\logo.png", "image");
    d.ecrire(r"ailleurs\pack.json", r#"{"Name":"Ailleurs","Logo":"logo.png"}"#);
    use std::os::windows::process::CommandExt;
    let jonction = |lien: &Path, cible: &Path| {
        std::process::Command::new("cmd")
            // (CREATE_NO_WINDOW : jamais de fenêtre à l'écran)
            .creation_flags(0x0800_0000)
            .args(["/C", "mklink", "/J"])
            .arg(lien)
            .arg(cible)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    };
    std::fs::create_dir_all(d.0.join(r"donnees\Mindcare\packs")).unwrap();
    if !jonction(&d.0.join(r"donnees\Mindcare\packs\essai-lien"), &ailleurs) {
        eprintln!("jonction impossible ici : test des liens sauté");
        return;
    }
    let t = charger(Some("pack:essai-lien"), &d.racines());
    assert!(t.pack.is_none());
    assert!(t.raisons.iter().any(|r| r.contains("son dossier est un lien")), "{:?}", t.raisons);
    // Un sous-dossier lien dans un vrai pack : son contenu n'est jamais pris
    d.ecrire(r"donnees\Mindcare\packs\essai-x\pack.json", r#"{"Logo":"logo.png"}"#);
    if jonction(&d.0.join(r"donnees\Mindcare\packs\essai-x\logo.png"), &ailleurs) {
        let t = charger(Some("pack:essai-x"), &d.racines());
        assert!(t.pack.unwrap().logo.is_none());
    }
}

#[test]
fn pack_abime_trop_gros_ou_ailleurs() {
    let d = Dossier::nouveau("abime");
    d.ecrire(r"donnees\Mindcare\packs\essai-x\pack.json", "{ pas du json");
    let t = charger(Some("pack:essai-x"), &d.racines());
    assert_eq!(t.id, "neon");
    assert!(t.raisons.iter().any(|r| r.contains("abîmé")) && t.raisons.iter().any(|r| r.contains("introuvable")));
    // Le réglage de Mindset prend le relais
    d.ecrire(r"donnees\Mindset\packs\essai-x\pack.json", r#"{"Name":"De Mindset","Base":"terminal"}"#);
    let t = charger(Some("pack:essai-x"), &d.racines());
    assert_eq!((t.id.as_str(), t.nom.as_str()), ("terminal", "De Mindset"));
    // Un tableau n'est pas un réglage ; un fichier énorme n'est pas lu
    d.ecrire(r"donnees\Mindcare\packs\essai-x\pack.json", "[]");
    assert_eq!(charger(Some("pack:essai-x"), &d.racines()).nom, "De Mindset");
    d.ecrire(r"donnees\Mindcare\packs\essai-x\pack.json", &format!(r#"{{"Name":"{}"}}"#, "a".repeat(1_100_000)));
    let t = charger(Some("pack:essai-x"), &d.racines());
    assert_eq!(t.nom, "De Mindset");
    assert!(t.raisons.iter().any(|r| r.contains("trop gros")));
    // pack.json est un dossier : on passe au suivant
    std::fs::remove_file(d.0.join(r"donnees\Mindcare\packs\essai-x\pack.json")).unwrap();
    std::fs::create_dir_all(d.0.join(r"donnees\Mindcare\packs\essai-x\pack.json")).unwrap();
    assert_eq!(charger(Some("pack:essai-x"), &d.racines()).nom, "De Mindset");
}

#[test]
fn lueur_et_phrase_accueil() {
    let d = Dossier::nouveau("phrase");
    let lu = |glow: &str| pack(&d, "essai-x", &format!(r#"{{"LogoGlow":{glow}}}"#)).pack.unwrap().logo_lueur;
    assert_eq!(lu(r##""#FF00FF""##).as_deref(), Some("#FF00FF"));
    assert_eq!(lu(r##""#80FF00FF""##).as_deref(), Some("#80FF00FF"));
    for glow in [r#""red""#, r##""#FF00FF\" x=\"y""##, "5", r##""#FFF""##] {
        assert_eq!(lu(glow), None, "{glow}");
    }
    let phrase = |hello: &str, soir| {
        let mut p = pack(&d, "essai-x", "{}").pack.unwrap();
        p.bonjour = hello.to_string();
        p.phrase_accueil(soir)
    };
    assert_eq!(phrase("{0}, voyageur !", false).as_deref(), Some("Bonjour, voyageur !"));
    assert_eq!(phrase("{0} {{ok}} {0}", true).as_deref(), Some("Bonsoir {ok} Bonsoir"));
    assert_eq!(phrase("Salut {1}", true).as_deref(), Some("Salut {1}"));
    assert_eq!(phrase("Sans rien", true).as_deref(), Some("Sans rien"));
    assert_eq!(phrase("", true), None);
}
