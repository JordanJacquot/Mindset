//! Le thème de Mindset, comme `modules\themes.ps1` : le thème choisi pour la suite (`$ThemeSetting`), son pack
//! (`$ThemePack`), ses couleurs (`$ThemeId`, `ConvertTo-ThemeHex`), la phrase de l'en-tête (`Get-ThemeHello`), la
//! police (`Add-PackFontXaml`, `Convert-ThemeXaml`) ; et pour les Paramètres, les cartes des thèmes
//! (`New-ChoixTheme`, `Update-ChoixThemes`, `Get-ThemesConsole`, `Get-ImageThemeConsole`).
//!
//! Toute la page est dessinée en Néon (comme interface.xaml) : le bloc publie dans le tableau commun la traduction de
//! chaque couleur Néon de la page et de la console (`theme.couleurs`), comme `Convert-ThemeXaml` traduisait le texte de
//! la fenêtre avant de la charger. Les thèmes eux-mêmes (les 5 thèmes intégrés, la lecture des packs, la traduction)
//! sont ceux de `suite_commun::themes`, déjà vérifiés contre la version PowerShell.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};
use suite_commun::themes::{self, Alignement, Pack, Theme};

use crate::packs;

/// Toutes les couleurs Néon écrites dans interface.xaml, les modules PowerShell et la scène de la console (relevées le
/// 07/11/2026), en majuscules : ce que la page et la scène traduisent par `theme.couleurs`.
pub const COULEURS_NEON: &[&str] = &[
    "#0000E5FF",
    "#007A3CFF",
    "#00D9F5",
    "#00E0A0",
    "#00E5FF",
    "#00FF2EB5",
    "#00FFFFFF",
    "#05040C",
    "#06050F",
    "#07060D",
    "#08060F",
    "#08FFFFFF",
    "#0A0812",
    "#0AFFFFFF",
    "#0B0820",
    "#0C0920",
    "#0DFFFFFF",
    "#0FFFFFFF",
    "#100C28",
    "#100D26",
    "#120E28",
    "#14102A",
    "#141030",
    "#141126",
    "#16FFFFFF",
    "#17FFFFFF",
    "#1A0610",
    "#1A1206",
    "#1A1738",
    "#1AFF2EB5",
    "#1AFFFFFF",
    "#1B1830",
    "#1CFFFFFF",
    "#1E1A3E",
    "#1E88E5",
    "#1EFFFFFF",
    "#22FF2EB5",
    "#2600E5FF",
    "#267A3CFF",
    "#26FFFFFF",
    "#2A2450",
    "#2A2548",
    "#2EFFFFFF",
    "#33000000",
    "#33FF77",
    "#38FFFFFF",
    "#3A3466",
    "#3A355A",
    "#3A4355",
    "#3B6FFF",
    "#3DDC84",
    "#40000000",
    "#4000E5FF",
    "#40FFFFFF",
    "#4400E5FF",
    "#44FF2EB5",
    "#55000000",
    "#5500E5FF",
    "#55060510",
    "#6F6894",
    "#7A7BFF",
    "#7FF4FF",
    "#8000E5FF",
    "#80B04BFF",
    "#8F88B8",
    "#99000000",
    "#9900E5FF",
    "#A6A1BC",
    "#A9A3C9",
    "#AA000000",
    "#B04BFF",
    "#B6FF3B",
    "#C006050F",
    "#C9C4DD",
    "#CFCDE0",
    "#D8D4EC",
    "#E52521",
    "#ECEAF7",
    "#EEEBF7",
    "#F2EFFA",
    "#FBD000",
    "#FF2EB5",
    "#FF3B3B",
    "#FF3D7F",
    "#FF5C7A",
    "#FF7A9C",
    "#FF8A3D",
    "#FFB020",
    "#FFC83D",
    "#FFDE00",
    "#FFFFFF",
];

/// Le fond de la fenêtre (la barre de titre prend sa traduction : `SetDarkTitleBar`).
pub const FOND_FENETRE: &str = "#06050F";

/// Ce que `Get-ThemePack` de Mindset notait au journal en lisant un pack : ses couleurs mal écrites, ou son
/// pack.json illisible.
pub fn noter_raisons(id: &str, t: &Theme, journal: &dyn Fn(&str)) {
    for r in &t.raisons {
        if r.starts_with(&format!("thème {id} : couleurs refusées")) {
            journal(&format!("Thème {id} : couleurs mal écrites, ignorées (thème de base)"));
        } else if r.starts_with(&format!("thème {id} abîmé dans"))
            || r.starts_with(&format!("thème {id} illisible dans"))
        {
            journal(&format!("Pack {id} illisible : {r}"));
        }
    }
}

/// `Get-ThemePack <id>` : le pack lu dans `<données de Mindset>\packs`, avec ses couleurs (`None` s'il est absent
/// ou illisible).
pub fn pack(id: &str, dossier_packs: &Path, journal: &dyn Fn(&str)) -> Option<Theme> {
    let t = themes::charger(Some(&format!("pack:{id}")), &[dossier_packs.to_path_buf()]);
    noter_raisons(id, &t, journal);
    t.pack.is_some().then_some(t)
}

/// `Get-ThemePacks` : les packs installés pour Mindset (dans l'ordre de leurs dossiers), sans ceux qui attendent
/// d'être retirés.
pub fn packs_installes(dossier_packs: &Path, a_retirer: &[String], journal: &dyn Fn(&str)) -> Vec<Theme> {
    let Ok(l) = std::fs::read_dir(dossier_packs) else { return Vec::new() };
    let mut noms: Vec<String> = l
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    noms.sort_by_key(|n| n.to_uppercase());
    noms.into_iter()
        .filter(|n| !a_retirer.iter().any(|x| packs::egal(x, n)))
        .filter_map(|n| pack(&n, dossier_packs, journal))
        .collect()
}

/// Le thème de Mindset au lancement (le haut de themes.ps1).
pub struct ThemeCourant {
    /// `$ThemeSetting` : « neon », « pack:<id> »...
    pub reglage: String,
    /// Le thème appliqué (couleurs, pack)
    pub theme: Theme,
}

impl ThemeCourant {
    pub fn charger(reglage: &str, dossier_packs: &Path) -> ThemeCourant {
        let theme = themes::charger(Some(reglage), &[dossier_packs.to_path_buf()]);
        ThemeCourant { reglage: reglage.to_string(), theme }
    }

    /// `ConvertTo-ThemeHex` dans le thème appliqué.
    pub fn traduire(&self, hex: &str) -> String {
        self.theme.traduire(hex)
    }

    /// Le pack du thème (`$ThemePack`).
    pub fn pack(&self) -> Option<&Pack> {
        self.theme.pack.as_ref()
    }

    /// `Get-ThemeHello` : la phrase du pack si elle a « {0} », sinon « {0} ! ».
    pub fn bonjour(&self) -> String {
        match self.pack() {
            Some(p) if p.bonjour.contains("{0}") => p.bonjour.clone(),
            _ => "{0} !".to_string(),
        }
    }

    /// La table `theme.couleurs` : chaque couleur Néon (en majuscules) et sa traduction.
    pub fn table(&self, en_plus: &[String]) -> Map<String, Value> {
        let mut m = Map::new();
        for c in COULEURS_NEON.iter().map(|c| c.to_string()).chain(en_plus.iter().map(|c| c.to_uppercase())) {
            if m.contains_key(&c) || !est_hex(&c) {
                continue;
            }
            let t = self.traduire(&c);
            m.insert(c, Value::String(t));
        }
        m
    }

    /// Ce qui est publié dans le tableau commun (`theme`).
    pub fn publication(&self, en_plus: &[String]) -> Value {
        json!({
            "id": self.reglage,
            "couleurs": self.table(en_plus),
            "police": self.theme.police,
            "pack": self.pack().map(|p| pack_json(p, &self.bonjour())),
            "theme": self.theme.id,
            "nom": self.theme.nom,
            "decor": self.theme.decor,
            "bonjour": self.bonjour(),
        })
    }
}

/// « #RRGGBB » ou « #AARRGGBB »
fn est_hex(c: &str) -> bool {
    (c.len() == 7 || c.len() == 9) && c.starts_with('#') && c[1..].bytes().all(|o| o.is_ascii_hexdigit())
}

fn planche(p: &themes::Planche) -> Value {
    json!({ "fichier": p.image.fichier, "images": p.images, "delai": p.delai })
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

/// Le pack pour les écrans (`theme.pack`) : chaque image est un nom de fichier servi par `http://pack.localhost/`.
pub fn pack_json(p: &Pack, bonjour: &str) -> Value {
    let mut o = Map::new();
    o.insert("id".into(), json!(p.id));
    o.insert("nom".into(), json!(p.nom));
    o.insert("description".into(), json!(p.description));
    o.insert("dossier".into(), json!(p.dossier.to_string_lossy()));
    o.insert("bonjour".into(), json!(bonjour));
    o.insert(
        "logo".into(),
        p.logo.as_ref().map_or(Value::Null, |l| {
            let mut v = planche(l);
            v["lueur"] = json!(p.logo_lueur);
            v
        }),
    );
    o.insert(
        "mascotte".into(),
        p.mascotte.as_ref().map_or(Value::Null, |m| {
            let mut v = planche(&m.planche);
            v["miroir"] = json!(m.miroir);
            v
        }),
    );
    o.insert(
        "bas".into(),
        p.bas.as_ref().map_or(Value::Null, |b| {
            let mut v = planche(&b.planche);
            v["hauteur"] = json!(b.hauteur);
            v
        }),
    );
    o.insert("onglets".into(), Value::Object(icones_onglets(&p.dossier)));
    o.insert(
        "fond".into(),
        p.fond.as_ref().map_or(Value::Null, |f| {
            json!({ "fichier": f.image.fichier, "opacite": f.opacite,
                "x": alignement(f.x, "gauche", "droite"), "y": alignement(f.y, "haut", "bas") })
        }),
    );
    o.insert(
        "police".into(),
        p.police
            .as_ref()
            .map_or(Value::Null, |f| json!({ "fichier": f.fichier.fichier, "partout": f.partout, "pixel": p.pixel })),
    );
    o.insert(
        "console".into(),
        p.console.as_ref().map_or(Value::Null, |c| {
            let tuiles: Map<String, Value> =
                c.tuiles.iter().map(|(k, i)| (k.clone(), json!(i.fichier))).collect();
            json!({
                "tuiles": tuiles,
                "mascotte": c.mascotte.as_ref().map(|i| i.fichier.clone()),
                "chargement": c.chargement.as_ref().map(|ch| json!({ "fichier": ch.image.fichier, "tourne": ch.tourne })),
                "fond": c.fond.as_ref().map(|i| i.fichier.clone()),
                "fond_opacite": c.fond_opacite,
                "logo": c.logo.as_ref().map(|i| i.fichier.clone()),
            })
        }),
    );
    Value::Object(o)
}

/// `TabIcons` du pack (les icônes des onglets de gauche), comme `Get-ThemePack` de Mindset : un nom d'onglet en
/// lettres, une image qui est un simple nom de fichier du pack.
pub fn icones_onglets(dossier: &Path) -> Map<String, Value> {
    let mut m = Map::new();
    let Ok(o) = std::fs::read(dossier.join("pack.json")) else { return m };
    let t = suite_commun::json_sur::texte_du_fichier(&o);
    let Ok(Value::Object(j)) = serde_json::from_str::<Value>(t.trim_start_matches('\u{FEFF}')) else { return m };
    let Some(Value::Object(icones)) = j.iter().find(|(k, _)| k.eq_ignore_ascii_case("TabIcons")).map(|(_, v)| v) else {
        return m;
    };
    for (nom, v) in icones {
        let Some(v) = v.as_object() else { continue };
        if nom.is_empty() || !nom.bytes().all(|o| o.is_ascii_alphabetic()) {
            continue;
        }
        let champ = |n: &str| v.iter().find(|(k, _)| k.eq_ignore_ascii_case(n)).map(|(_, x)| x);
        let Some(fichier) = champ("File").and_then(Value::as_str).filter(|f| fichier_du_pack(dossier, f)) else {
            continue;
        };
        m.insert(
            nom.clone(),
            json!({
                "fichier": fichier,
                "images": entier(champ("Frames")).max(1),
                "delai": entier(champ("Delay")).max(40),
                "lueur": champ("Glow").map(suite_commun::protocole_installateur::texte_ps).unwrap_or_default(),
            }),
        );
    }
    m
}

/// `[int]` de PowerShell (arrondi au pair) ; 0 pour ce qui n'est pas un nombre.
fn entier(v: Option<&Value>) -> i64 {
    let x = match v {
        Some(Value::Number(n)) => n.as_f64(),
        Some(Value::String(s)) => s.trim().parse::<f64>().ok(),
        Some(Value::Bool(b)) => Some(f64::from(u8::from(*b))),
        _ => None,
    };
    x.filter(|x| x.is_finite()).map(|x| x.round_ties_even().clamp(-1e9, 1e9) as i64).unwrap_or(0)
}

/// Un simple nom de fichier du pack, qui est un vrai fichier (pas un lien).
fn fichier_du_pack(dossier: &Path, nom: &str) -> bool {
    packs::nom_fichier_valable(nom)
        && std::fs::symlink_metadata(dossier.join(nom)).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
}

// ---------------------------------------------------------------------------------------------------------------
// Les cartes des thèmes (Paramètres, Apparence)
// ---------------------------------------------------------------------------------------------------------------

/// L'image d'un thème perso sur sa carte : sa mascotte (ou son logo), la première image de la planche.
#[derive(Debug, Clone, PartialEq)]
pub struct Vignette {
    pub chemin: PathBuf,
    /// Le nom sous lequel elle est servie (`http://fichier.localhost/<nom>`)
    pub nom: String,
    pub images: u32,
    pub largeur: u32,
    pub hauteur: u32,
}

/// Une carte de thème (`Get-ThemesConsole` et `New-ChoixTheme`).
#[derive(Debug, Clone, PartialEq)]
pub struct Carte {
    /// Ce qui va dans suite.json : « neon », « pack:<id> »
    pub cle: String,
    pub nom: String,
    pub desc: String,
    /// Le fond de la carte : `#0C0920` dans ses propres couleurs
    pub fond: String,
    pub couleurs: [String; 3],
    /// Son bord quand ce n'est pas le thème actuel : `#2A2450` dans ses propres couleurs
    pub bord: String,
    /// La police de son nom (Terminal)
    pub police: Option<String>,
    pub vignette: Option<Vignette>,
}

impl Carte {
    pub fn json(&self) -> Value {
        json!({
            "cle": self.cle, "nom": self.nom, "desc": self.desc, "fond": self.fond,
            "couleurs": self.couleurs, "image": self.vignette.is_some(),
            "bord": self.bord, "police": self.police,
            "vignette": self.vignette.as_ref().map(|v| json!({
                "adresse": format!("http://fichier.localhost/{}", v.nom),
                "images": v.images, "largeur": v.largeur, "hauteur": v.hauteur,
            })),
        })
    }
}

/// Les cartes : les 5 thèmes de base, puis les thèmes perso installés.
pub fn cartes(dossier_packs: &Path, a_retirer: &[String], journal: &dyn Fn(&str)) -> Vec<Carte> {
    let mut l = Vec::new();
    for t in &themes::THEMES_INTEGRES {
        let th = themes::charger(Some(t.id), &[]);
        l.push(Carte {
            cle: t.id.to_string(),
            nom: t.nom.to_string(),
            desc: t.description.to_string(),
            fond: th.traduire("#0C0920"),
            couleurs: [t.p.to_string(), t.s.to_string(), t.t.to_string()],
            bord: th.traduire("#2A2450"),
            police: t.police.map(str::to_string),
            vignette: None,
        });
    }
    for th in packs_installes(dossier_packs, a_retirer, journal) {
        let Some(p) = th.pack.as_ref() else { continue };
        l.push(Carte {
            cle: format!("pack:{}", p.id),
            nom: p.nom.clone(),
            desc: p.description.clone(),
            fond: th.traduire("#0C0920"),
            couleurs: [th.couleurs.p.clone(), th.couleurs.s.clone(), th.couleurs.t.clone()],
            bord: th.traduire("#2A2450"),
            police: th.police.map(str::to_string),
            vignette: vignette(p),
        });
    }
    l
}

/// `Get-ImageThemeConsole` : la mascotte, sinon le logo ; une « mascotte » très large (une bande, plus de deux fois
/// plus large que haute pour une image) laisse la place au logo.
pub fn vignette(p: &Pack) -> Option<Vignette> {
    let depuis = |pl: &themes::Planche| -> Option<Vignette> {
        let (l, h) = dimensions(&pl.image.chemin)?;
        let ext = pl.image.fichier.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
        Some(Vignette {
            chemin: pl.image.chemin.clone(),
            nom: format!("theme-{}.{ext}", p.id),
            images: pl.images.max(1),
            largeur: l,
            hauteur: h,
        })
    };
    let logo = p.logo.as_ref();
    match (&p.mascotte, logo) {
        (Some(m), Some(lg)) => {
            let v = depuis(&m.planche)?;
            let largeur_image = v.largeur / v.images.max(1);
            if largeur_image > 2 * v.hauteur { depuis(lg) } else { Some(v) }
        }
        (Some(m), None) => depuis(&m.planche),
        (None, Some(lg)) => depuis(lg),
        (None, None) => None,
    }
}

/// La largeur et la hauteur d'une image (PNG, GIF, JPEG, WebP) lues dans son en-tête.
pub fn dimensions(chemin: &Path) -> Option<(u32, u32)> {
    use std::io::Read;
    let mut b = Vec::new();
    std::fs::File::open(chemin).ok()?.take(256 * 1024).read_to_end(&mut b).ok()?;
    dimensions_octets(&b)
}

pub fn dimensions_octets(b: &[u8]) -> Option<(u32, u32)> {
    let be32 = |i: usize| b.get(i..i + 4).map(|x| u32::from_be_bytes([x[0], x[1], x[2], x[3]]));
    let le16 = |i: usize| b.get(i..i + 2).map(|x| u32::from(u16::from_le_bytes([x[0], x[1]])));
    let be16 = |i: usize| b.get(i..i + 2).map(|x| u32::from(u16::from_be_bytes([x[0], x[1]])));
    let le24 = |i: usize| b.get(i..i + 3).map(|x| u32::from(x[0]) | (u32::from(x[1]) << 8) | (u32::from(x[2]) << 16));
    let d = match packs::format_image(b)? {
        "png" => (be32(16)?, be32(20)?),
        "gif" => (le16(6)?, le16(8)?),
        "webp" => match b.get(12..16)? {
            b"VP8X" => (le24(24)? + 1, le24(27)? + 1),
            b"VP8L" => {
                let x = b.get(21..25)?;
                let v = u32::from_le_bytes([x[0], x[1], x[2], x[3]]);
                ((v & 0x3FFF) + 1, ((v >> 14) & 0x3FFF) + 1)
            }
            b"VP8 " => (le16(26)? & 0x3FFF, le16(28)? & 0x3FFF),
            _ => return None,
        },
        _ => {
            // JPEG : le premier segment SOF donne la taille
            let mut i = 2;
            loop {
                if *b.get(i)? != 0xFF {
                    return None;
                }
                let m = *b.get(i + 1)?;
                if (0xC0..=0xCF).contains(&m) && m != 0xC4 && m != 0xC8 && m != 0xCC {
                    break (be16(i + 7)?, be16(i + 5)?);
                }
                i += 2 + be16(i + 2)? as usize;
            }
        }
    };
    (d.0 > 0 && d.1 > 0).then_some(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn couleurs_et_bonjour() {
        let t = ThemeCourant::charger("crepuscule", Path::new("Z:\\absent"));
        assert_eq!(t.traduire("#00E5FF"), "#FF8A3D");
        assert_eq!(t.traduire(FOND_FENETRE), "#0B0508");
        assert_eq!(t.bonjour(), "{0} !");
        let table = t.table(&["#3dDC84".to_string()]);
        assert_eq!(table["#0C0920"], "#1A0B12");
        assert!(table.contains_key("#3DDC84"));
        let n = ThemeCourant::charger("neon", Path::new("Z:\\absent"));
        assert_eq!(n.traduire("#2600E5FF"), "#2600E5FF");
    }

    #[test]
    fn tailles_d_images() {
        let mut png = vec![0x89, b'P', b'N', b'G', 13, 10, 26, 10, 0, 0, 0, 13, b'I', b'H', b'D', b'R'];
        png.extend_from_slice(&320u32.to_be_bytes());
        png.extend_from_slice(&64u32.to_be_bytes());
        assert_eq!(dimensions_octets(&png), Some((320, 64)));
        let gif = b"GIF89a\x40\x01\x20\x00......";
        assert_eq!(dimensions_octets(gif), Some((320, 32)));
        assert_eq!(dimensions_octets(b"pas une image du tout"), None);
    }
}
