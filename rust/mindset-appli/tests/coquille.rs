//! Le contrat de la page (architecture-mindset-rust.md) : les zones et les scripts de la coquille, que le bloc
//! « écrans » peut remplir mais pas retirer, et les règles Tauri lisibles dans les fichiers (règles 1, 2, 7, 8 de
//! docs\regles-tauri.md ; outils\verifier-tauri.ps1 les revérifie toutes).

use std::path::{Path, PathBuf};

fn racine() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn lire(p: &Path) -> String {
    std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{} : {e}", p.display()))
}

/// Les zones de la coquille (les id d'interface.xaml qu'elles remplacent entre parenthèses).
const ZONES: &[&str] = &[
    "fenetre",
    "fond",    // BackdropDeco
    "en-tete", // EnTete
    "corps",
    "colonne-onglets", // ColonneOnglets, BarreOnglets
    "centre",
    "bandeaux", // Bandeaux : Bienvenue, AdminBandeau, MajBandeau
    "page-centrale",
    "page-console",       // PageConsole
    "page-accueil",       // PageAccueil
    "page-appli",         // PageAppli
    "zone-appli",         // PageAppliHotes : la place de l'appli accrochée
    "page-parametres",    // PageParametres
    "pied",               // FooterArt
    "voile-fermeture",    // Fermeture
    "voile-confirmation", // Confirmation
];

/// Les scripts, dans cet ordre.
const SCRIPTS: &[&str] = &["ipc.js", "coquille.js", "ecrans/ecrans.js", "console/console.js"];

#[test]
fn les_zones_et_les_scripts_de_la_coquille() {
    let html = lire(&racine().join("ui").join("index.html"));
    for z in ZONES {
        assert!(html.contains(&format!("id=\"{z}\"")), "zone manquante : {z}");
    }
    let mut avant = 0;
    for s in SCRIPTS {
        let i = html.find(&format!("<script src=\"{s}\"></script>")).unwrap_or_else(|| panic!("script manquant : {s}"));
        assert!(i >= avant, "{s} n'est pas dans l'ordre");
        avant = i;
        assert!(racine().join("ui").join(s).is_file(), "{s} absent du dossier ui");
    }
}

fn fichiers(d: &Path, r: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(d).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            fichiers(&p, r);
        } else {
            r.push(p);
        }
    }
}

#[test]
fn seul_ipc_js_parle_a_tauri() {
    let mut l = Vec::new();
    fichiers(&racine().join("ui"), &mut l);
    for f in l {
        let ext = f.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        if !["js", "html", "css", "mjs"].contains(&ext.as_str()) || f.file_name().is_some_and(|n| n == "ipc.js") {
            continue;
        }
        let t = lire(&f);
        for interdit in ["__TAURI", "ipc.localhost", "chrome.webview", ".invoke("] {
            assert!(!t.contains(interdit), "{} contient {interdit} (règle 1 : seulement ipc.js)", f.display());
        }
    }
}

#[test]
fn les_trois_commandes_et_leur_permission() {
    let build = lire(&racine().join("build.rs"));
    let cap = lire(&racine().join("capabilities").join("principale.json"));
    let lib = lire(&racine().join("src").join("lib.rs"));
    for c in ["suivre_page", "noter_visibilite", "action"] {
        assert!(build.contains(&format!("\"{c}\"")), "{c} absent du manifeste de build.rs");
        assert!(cap.contains(&format!("allow-{}", c.replace('_', "-"))), "{c} sans permission");
        assert!(lib.contains(&format!("commandes::{c}")), "{c} absent de generate_handler");
    }
    assert!(cap.contains("\"windows\": [\"principale\"]"));
}

#[test]
fn configuration_tauri() {
    let conf: serde_json::Value = serde_json::from_str(&lire(&racine().join("tauri.conf.json"))).unwrap();
    assert_eq!(conf["productName"], "Mindset", "règle 8 : le Gestionnaire des tâches montre « Mindset »");
    assert_eq!(conf["bundle"]["active"], false);
    assert_eq!(conf["app"]["withGlobalTauri"], false);
    assert_eq!(conf["app"]["windows"], serde_json::json!([]), "règle 7 : fenêtre créée dans le code");
    let csp = conf["app"]["security"]["csp"].as_str().unwrap();
    assert_eq!(Some(csp), conf["app"]["security"]["devCsp"].as_str());
    assert!(csp.starts_with("default-src 'none'"));
    assert!(!csp.contains("unsafe-eval"));
    assert!(csp.contains("frame-src 'self'"), "la console 3D est un cadre de la page");
    for autre in ["tauri.conf.json5", "Tauri.toml", "tauri.windows.conf.json"] {
        assert!(!racine().join(autre).exists(), "{autre} : un seul fichier de configuration");
    }
}
