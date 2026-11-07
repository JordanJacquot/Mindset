//! Les visuels d'un thème personnalisé (pack) pour la page : fond, mascotte, dessin du bas, logo, icônes des onglets,
//! personnage de la jauge, police (`Initialize-PackVisuels`, `New-IconeOnglet`, `Add-PackLogo`, packs.ps1:382-445 ;
//! `Get-JaugePack`, chargement.ps1:61-75 ; `Add-PackFontXaml`, themes.ps1:52-60).
//!
//! Le pack lui-même est lu par `suite_commun::themes` (le même contrôle que le bloc « paramètres ») ; ce que cette
//! lecture ne garde pas (les icônes des onglets `TabIcons`, le personnage de la jauge `Loader` en entier) est relu ici
//! dans pack.json, avec les mêmes règles que `Get-ThemePack` (packs.ps1:59-119) : seulement de simples noms de fichiers
//! du dossier du pack. Les images sont servies à la page par `http://pack.localhost/<fichier>` (le dossier du pack est
//! donné à l'hôte par le bloc « paramètres », `Effet::DossierPack`) ; un personnage de jauge trouvé seulement dans le
//! pack de Nevermind est servi par `Effet::Exposer` sous le nom [`NOM_JAUGE`].

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};
use suite_commun::protocole_installateur::{champ, entier_ps, texte_ps, vrai_ps};
use suite_commun::themes::{Alignement, Pack, Planche};

/// Le nom sous lequel l'image de la jauge d'un pack est servie quand elle n'est que dans le pack de Nevermind.
pub const NOM_JAUGE: &str = "jauge-pack";

/// `Test-NomFichierPack` : un simple nom de fichier (`^[\w .()-]{1,80}$`, sans « .. »).
pub fn nom_fichier(n: &str) -> bool {
    let c = n.chars().count();
    (1..=80).contains(&c)
        && !n.contains("..")
        && n.chars().all(|x| x == '_' || x.is_alphanumeric() || " .()-".contains(x))
        && !n.contains(['/', '\\', ':'])
}

fn planche(p: &Planche) -> Value {
    json!({ "fichier": p.image.fichier, "images": p.images.max(1), "delai": p.delai })
}

fn alignement(a: Alignement, debut: &str, fin: &str) -> &'static str {
    match a {
        Alignement::Debut if debut == "gauche" => "gauche",
        Alignement::Debut => "haut",
        Alignement::Fin if fin == "droite" => "droite",
        Alignement::Fin => "bas",
        Alignement::Centre => "centre",
    }
}

fn lire_json(f: &Path) -> Option<Map<String, Value>> {
    let md = std::fs::metadata(f).ok().filter(|m| m.is_file() && m.len() <= 1024 * 1024)?;
    let _ = md;
    let t = String::from_utf8_lossy(&std::fs::read(f).ok()?).to_string();
    match suite_commun::protocole_installateur::lire_json(&t)? {
        Value::Object(o) => Some(o),
        _ => None,
    }
}

fn entier(v: Option<&Value>) -> i64 {
    v.and_then(entier_ps).map(i64::from).unwrap_or(0)
}

/// Ce que le pack donne à la page, et le fichier de jauge à servir à part (s'il y en a un).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VisuelsPack {
    pub page: Value,
    pub exposer: Option<PathBuf>,
}

/// Les visuels du pack, lus dans `dossier` (celui de Mindset) ; `nevermind` : le dossier du même pack pour Nevermind
/// (où les packs de la suite déclarent le personnage de la jauge).
pub fn visuels(p: &Pack, nevermind: Option<&Path>) -> VisuelsPack {
    let dossier = &p.dossier;
    let fichier = |n: &str| nom_fichier(n) && dossier.join(n).is_file();
    let j = lire_json(&dossier.join("pack.json")).unwrap_or_default();
    let mut o = Map::new();
    o.insert("id".into(), json!(p.id));
    if let Some(f) = &p.fond {
        o.insert(
            "fond".into(),
            json!({ "fichier": f.image.fichier, "opacite": f.opacite,
                "x": alignement(f.x, "gauche", "droite"), "y": alignement(f.y, "haut", "bas") }),
        );
    }
    if let Some(m) = &p.mascotte {
        let mut v = planche(&m.planche);
        v["miroir"] = json!(m.miroir);
        o.insert("mascotte".into(), v);
    }
    if let Some(b) = &p.bas {
        let mut v = planche(&b.planche);
        v["hauteur"] = json!(b.hauteur);
        o.insert("bas".into(), v);
    }
    if let Some(l) = &p.logo {
        let mut v = planche(l);
        v["lueur"] = json!(p.logo_lueur);
        o.insert("logo".into(), v);
    }
    // Les icônes des onglets (TabIcons) : { accueil, <id d'appli>, parametres = { File, Frames, Delay } }
    let mut onglets = Map::new();
    if let Some(Value::Object(t)) = champ(&j, "TabIcons") {
        for (id, v) in t {
            let Some(v) = v.as_object() else { continue };
            let f = champ(v, "File").map(texte_ps).unwrap_or_default();
            if id.chars().all(|c| c.is_ascii_lowercase()) && !id.is_empty() && fichier(&f) {
                onglets.insert(
                    id.clone(),
                    json!({ "fichier": f, "images": entier(champ(v, "Frames")).max(1), "delai": entier(champ(v, "Delay")).max(40) }),
                );
            }
        }
    }
    if !onglets.is_empty() {
        o.insert("onglets".into(), Value::Object(onglets));
    }
    // Le personnage de la jauge (Loader) : dans le réglage de Mindset du pack, sinon dans celui de Nevermind
    let mut exposer = None;
    let mut sources = vec![(dossier.clone(), j.clone())];
    if let Some((n, jn)) = nevermind.and_then(|n| Some((n, lire_json(&n.join("pack.json"))?))) {
        sources.push((n.to_path_buf(), jn));
    }
    for (src, js) in &sources {
        let Some(Value::Object(l)) = champ(js, "Loader") else { continue };
        let f = champ(l, "File").map(texte_ps).unwrap_or_default();
        if !nom_fichier(&f) {
            continue;
        }
        let (nom, chemin) = if dossier.join(&f).is_file() {
            (f.clone(), None)
        } else if src.join(&f).is_file() {
            (NOM_JAUGE.to_string(), Some(src.join(&f)))
        } else {
            continue;
        };
        let hauteur =
            champ(l, "Height").and_then(|v| v.as_f64().or_else(|| texte_ps(v).trim().parse().ok())).unwrap_or(0.0);
        let mut v = json!({ "fichier": nom, "images": entier(champ(l, "Frames")).max(1), "delai": entier(champ(l, "Delay")).max(30),
            "miroir": champ(l, "Flip").is_some_and(vrai_ps), "fixe": champ(l, "Static").is_some_and(vrai_ps),
            "hauteur": hauteur, "ecart": entier(champ(l, "Gap")).max(0) });
        if chemin.is_some() {
            v["expose"] = json!(true);
        }
        exposer = chemin;
        o.insert("jauge".into(), v);
        break;
    }
    if let Some(pol) = &p.police {
        o.insert("police".into(), json!({ "fichier": pol.fichier.fichier, "partout": pol.partout, "pixel": p.pixel }));
    }
    o.insert("bonjour".into(), json!(p.bonjour));
    VisuelsPack { page: Value::Object(o), exposer }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noms_de_fichiers() {
        assert!(nom_fichier("mascotte (1).png") && nom_fichier("é.webp"));
        assert!(!nom_fichier("..\\x.png") && !nom_fichier("a/b.png") && !nom_fichier("") && !nom_fichier("x..png"));
        assert!(!nom_fichier(&"a".repeat(81)));
    }

    #[test]
    fn un_pack_d_essai() {
        let racine = mindset_noyau::dossier_essai("ecrans-pack");
        let _ = std::fs::remove_dir_all(&racine);
        let d = racine.join("Mindset").join("packs").join("foret");
        let n = racine.join("Nevermind").join("packs").join("foret");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::create_dir_all(&n).unwrap();
        // (le début d'une image PNG : seuls les noms et la présence des fichiers comptent ici)
        let png = [0x89u8, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];
        for f in ["onglet.png", "masc.png"] {
            std::fs::write(d.join(f), png).unwrap();
        }
        std::fs::write(n.join("coureur.png"), png).unwrap();
        std::fs::write(
            d.join("pack.json"),
            r#"{"Name":"Forêt","Base":"neon","Hello":"{0}, la forêt t'attend","Mascotte":{"File":"masc.png","Frames":2,"Delay":10},
                "TabIcons":{"accueil":{"File":"onglet.png","Frames":3,"Delay":90},"evermind":{"File":"absente.png"},"Mal":{"File":"onglet.png"}}}"#,
        )
        .unwrap();
        std::fs::write(
            n.join("pack.json"),
            r#"{"Loader":{"File":"coureur.png","Frames":4,"Delay":20,"Flip":true,"Gap":-5}}"#,
        )
        .unwrap();
        let th = suite_commun::themes::charger(Some("pack:foret"), &[racine.join("Mindset").join("packs")]);
        let p = th.pack.clone().expect("le pack d'essai se lit");
        let v = visuels(&p, Some(&n));
        assert_eq!(v.page["onglets"], json!({ "accueil": { "fichier": "onglet.png", "images": 3, "delai": 90 } }));
        assert_eq!(v.page["jauge"]["fichier"], NOM_JAUGE);
        assert_eq!(v.page["jauge"]["delai"], 30);
        assert_eq!(v.page["jauge"]["ecart"], 0);
        assert_eq!(v.exposer, Some(n.join("coureur.png")));
        assert_eq!(v.page["mascotte"]["fichier"], "masc.png");
        let _ = std::fs::remove_dir_all(&racine);
    }
}
