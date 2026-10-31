//! Les thèmes de la suite : le thème choisi dans Mindset (suite.json), les 5 thèmes intégrés et les thèmes
//! personnalisés (packs), comme les applis PowerShell les lisent aujourd'hui :
//! - le choix dans suite.json : `Read-Suite` de Mindcare (modules\mindset.ps1) ;
//! - le pack : `Get-ThemePack` de Mindcare (modules\themes.ps1), qui cherche le réglage de l'appli puis celui de
//!   Mindset, avec le contrôle des couleurs de Mindset (`Test-CouleursPack`, modules\packs.ps1) et d'Evermind
//!   (NH et NS des nombres) : constat 7 de l'audit du 25/10 ;
//! - la traduction des couleurs : `ConvertTo-ThemeHex` (toute l'appli est dessinée en Néon, le thème « traduit »
//!   chaque couleur) ;
//! - ce que l'écran (le kit de la suite) attend : `Get-ThemeVue`, `Get-CouleursVue` et `Get-PackVue` (vue.ps1).
//!
//! Pas d'écran, pas d'appel à Windows : seulement des fichiers, aux chemins donnés par l'appelant (suite.json et les
//! dossiers « packs » où chercher, dans l'ordre).
//!
//! Sécurité : n'importe quel programme de l'utilisateur peut modifier suite.json et les packs. On n'y accepte qu'un
//! nom de thème connu ou « pack:<id> » (lettres minuscules, chiffres, tirets), des couleurs « #RRGGBB » (rien qui
//! puisse changer le texte d'une page ou d'une fenêtre), et des images qui sont de simples noms de fichiers du
//! dossier du pack (ni dossier, ni « .. », ni lien qui mène ailleurs). Un thème absent, abîmé ou refusé retombe sur
//! Néon (ou, pour un pack aux couleurs refusées, sur son thème de base, comme PowerShell), avec la raison.
//!
//! En plus du PowerShell : les couleurs d'un pack doivent laisser le texte lisible sur le fond (contraste mesuré
//! comme le W3C, voir [`verifier_lisibilite`]).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::json_sur;
use crate::texte::{SansMarque, decoder_fichier};

/// Le thème par défaut, et celui des replis.
pub const NEON: &str = "neon";

/// Un pack.json plus gros n'est pas lu (l'import de Mindset refuse déjà un réglage de plus de 1 Mo).
const TAILLE_MAX_PACK: u64 = 1024 * 1024;

/// Les extensions acceptées pour une image ou une police d'un pack (les mêmes qu'à l'import dans Mindset).
const EXT_IMAGES: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];
const EXT_POLICES: &[&str] = &["ttf", "otf"];

/// Contraste minimal (W3C) du texte de l'écran sur les fonds du thème, puis des couleurs de la marque.
pub const CONTRASTE_TEXTE: f64 = 4.5;
pub const CONTRASTE_TEXTE_DOUX: f64 = 3.0;
pub const CONTRASTE_P: f64 = 3.0;
pub const CONTRASTE_S_T: f64 = 2.0;

/// Les couleurs Néon du kit (kit.css) : fonds, textes, et les trois couleurs de la marque.
const FOND: &str = "#06050F";
const FOND2: &str = "#0C0920";
const TEXTE: &str = "#ECEAF7";
const TEXTE_DOUX: &str = "#A9A3C9";
const MARQUE: [&str; 3] = ["#00E5FF", "#B04BFF", "#FF2EB5"];

// ---------------------------------------------------------------------------------------------------------------
// Les thèmes intégrés
// ---------------------------------------------------------------------------------------------------------------

/// Un des 5 thèmes intégrés (le tableau `$AppThemes` des applis PowerShell).
#[derive(Debug)]
pub struct ThemeIntegre {
    pub id: &'static str,
    pub nom: &'static str,
    pub description: &'static str,
    pub p: &'static str,
    pub s: &'static str,
    pub t: &'static str,
    /// Teinte des gris et des fonds (`None` : ils ne changent pas)
    pub nh: Option<f64>,
    /// Facteur de saturation des gris et des fonds
    pub ns: f64,
    /// Couleurs remplacées telles quelles (« RRGGBB » vers « RRGGBB »)
    pub map: &'static [(&'static str, &'static str)],
    /// Police de tout l'écran (Terminal), sinon celle de l'appli
    pub police: Option<&'static str>,
    /// Décor propre au thème (les lignes d'un vieil écran pour Terminal)
    pub decor: Option<&'static str>,
}

pub static THEMES_INTEGRES: [ThemeIntegre; 5] = [
    ThemeIntegre {
        id: "neon",
        nom: "Néon",
        description: "Cyan, violet et magenta sur fond de nuit.",
        p: "#00E5FF",
        s: "#B04BFF",
        t: "#FF2EB5",
        nh: None,
        ns: 1.0,
        map: &[],
        police: None,
        decor: None,
    },
    ThemeIntegre {
        id: "crepuscule",
        nom: "Crépuscule",
        description: "Orange, rose et or, comme un coucher de soleil.",
        p: "#FF8A3D",
        s: "#FF3D7F",
        t: "#FFC83D",
        nh: Some(345.0),
        ns: 0.75,
        map: &[("0C0920", "1A0B12"), ("06050F", "0B0508"), ("0B0820", "170910"), ("08060F", "160806")],
        police: None,
        decor: None,
    },
    ThemeIntegre {
        id: "terminal",
        nom: "Terminal",
        description: "Vert phosphore sur fond noir, tout en police de code.",
        p: "#33FF77",
        s: "#B6FF3B",
        t: "#00E0A0",
        nh: Some(140.0),
        ns: 0.55,
        map: &[("0C0920", "030B06"), ("06050F", "000302"), ("0B0820", "020A05"), ("08060F", "001A08")],
        police: Some("Cascadia Code, Consolas"),
        decor: Some("terminal"),
    },
    ThemeIntegre {
        id: "arcade",
        nom: "Arcade",
        description: "Jaune, rouge et bleu vifs sur fond bleu nuit, comme une vieille borne.",
        p: "#FBD000",
        s: "#E52521",
        t: "#1E88E5",
        nh: Some(228.0),
        ns: 0.9,
        map: &[("0C0920", "0B1640"), ("06050F", "050A20"), ("0B0820", "0A1338"), ("08060F", "1A1000")],
        police: None,
        decor: None,
    },
    ThemeIntegre {
        id: "rubis",
        nom: "Rubis",
        description: "Rouge vif, jaune et bleu sur un gris anthracite sobre.",
        p: "#FF3B3B",
        s: "#FFDE00",
        t: "#3B6FFF",
        nh: Some(0.0),
        ns: 0.15,
        map: &[("0C0920", "17171D"), ("06050F", "0A0A0D"), ("0B0820", "141419"), ("08060F", "1A0606")],
        police: None,
        decor: None,
    },
];

/// Le thème intégré de ce nom, sans tenir compte des majuscules (comme `$AppThemes.Contains` en PowerShell).
pub fn theme_integre(id: &str) -> Option<&'static ThemeIntegre> {
    THEMES_INTEGRES.iter().find(|t| t.id.eq_ignore_ascii_case(id))
}

// ---------------------------------------------------------------------------------------------------------------
// Les couleurs et leur traduction
// ---------------------------------------------------------------------------------------------------------------

/// Les couleurs d'un thème : celles d'un thème intégré, ou celles d'un pack (vérifiées).
#[derive(Debug, Clone, PartialEq)]
pub struct Couleurs {
    /// « #RRGGBB » : les couleurs de la marque (à la place du cyan, du violet et du magenta de Néon)
    pub p: String,
    pub s: String,
    pub t: String,
    pub nh: Option<f64>,
    pub ns: f64,
    /// « RRGGBB » (majuscules) vers « RRGGBB » (majuscules)
    pub map: BTreeMap<String, String>,
}

impl Couleurs {
    fn depuis_integre(t: &ThemeIntegre) -> Couleurs {
        Couleurs {
            p: t.p.to_string(),
            s: t.s.to_string(),
            t: t.t.to_string(),
            nh: t.nh,
            ns: t.ns,
            map: t.map.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect(),
        }
    }

    /// Une couleur Néon (« #RRGGBB » ou « #AARRGGBB ») traduite dans ces couleurs, comme `ConvertTo-ThemeHex` (sans
    /// le raccourci de Néon, voir [`Theme::traduire`]). Ce qui n'est pas une couleur est rendu tel quel.
    fn traduire(&self, hex: &str) -> String {
        if !hex.is_ascii() || !hex.starts_with('#') || (hex.len() != 7 && hex.len() != 9) {
            return hex.to_string();
        }
        let alpha = if hex.len() == 9 { &hex[1..3] } else { "" };
        let rgb = hex[hex.len() - 6..].to_ascii_uppercase();
        if !rgb.bytes().all(|o| o.is_ascii_hexdigit()) {
            return hex.to_string();
        }
        let sortie = if let Some(m) = self.map.get(&rgb) {
            m.clone()
        } else if rgb == "00E5FF" {
            self.p[1..].to_string()
        } else if rgb == "B04BFF" {
            self.s[1..].to_string()
        } else if rgb == "FF2EB5" {
            self.t[1..].to_string()
        } else {
            let (r, g, b) = composantes(&rgb);
            let (h, s, l) = vers_hsl(r, g, b);
            let mut marque = None;
            if s > 0.5 && l > 0.2 && l < 0.92 {
                if (170.0..200.0).contains(&h) {
                    marque = Some(&self.p);
                } else if (228.0..292.0).contains(&h) {
                    marque = Some(&self.s);
                } else if (292.0..336.0).contains(&h) {
                    marque = Some(&self.t);
                }
            }
            if let Some(m) = marque {
                // Même clarté que la couleur d'origine (une variante claire reste claire), teinte et saturation du thème
                let (mr, mg, mb) = composantes(&m[1..]);
                let (bh, bs, bl) = vers_hsl(mr, mg, mb);
                let dl = l - 0.5;
                if dl.abs() < 0.06 {
                    m[1..].to_ascii_uppercase()
                } else {
                    depuis_hsl(bh, bs, (bl + dl).clamp(0.05, 0.95))
                }
            } else if let Some(nh) = self.nh.filter(|_| (s < 0.35 || l < 0.16) && l > 0.015 && l < 0.97) {
                // Gris et fonds : la teinte du thème, même clarté
                depuis_hsl(nh, (s * self.ns).min(1.0), l)
            } else {
                rgb
            }
        };
        format!("#{alpha}{sortie}")
    }
}

/// Les trois composantes d'une couleur « RRGGBB » (vérifiée avant).
fn composantes(rgb: &str) -> (i32, i32, i32) {
    let c = |i: usize| i32::from_str_radix(&rgb[i..i + 2], 16).unwrap_or(0);
    (c(0), c(2), c(4))
}

/// Teinte (0 à 360), saturation et clarté (0 à 1), exactement comme `ConvertTo-Hsl` (mêmes opérations, dans le
/// même ordre, pour des résultats identiques au bit près).
fn vers_hsl(rouge: i32, vert: i32, bleu: i32) -> (f64, f64, f64) {
    let (r, g, b) = (f64::from(rouge) / 255.0, f64::from(vert) / 255.0, f64::from(bleu) / 255.0);
    let max = r.max(g.max(b));
    let min = r.min(g.min(b));
    let l = (max + min) / 2.0;
    if max == min {
        return (0.0, 0.0, l);
    }
    let d = max - min;
    let s = if l > 0.5 { d / (2.0 - max - min) } else { d / (max + min) };
    let h = if max == r {
        ((g - b) / d) + if g < b { 6.0 } else { 0.0 }
    } else if max == g {
        ((b - r) / d) + 2.0
    } else {
        ((r - g) / d) + 4.0
    };
    (h * 60.0, s, l)
}

/// « RRGGBB » d'une teinte, saturation et clarté, comme `ConvertFrom-Hsl` (arrondi au pair le plus proche, comme
/// `[math]::Round` de .NET).
fn depuis_hsl(h: f64, s: f64, l: f64) -> String {
    let h = ((h % 360.0) + 360.0) % 360.0;
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let x = c * (1.0 - (((h / 60.0) % 2.0) - 1.0).abs());
    let m = l - c / 2.0;
    let (r, g, b) = match (h / 60.0).floor() as i64 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let octet = |v: f64| (255.0 * (v + m)).round_ties_even().clamp(0.0, 255.0) as u8;
    format!("{:02X}{:02X}{:02X}", octet(r), octet(g), octet(b))
}

/// « #RRGGBB » exactement (`^#[0-9A-Fa-f]{6}\z`).
fn est_couleur(v: &str) -> bool {
    v.len() == 7 && v.starts_with('#') && v[1..].bytes().all(|o| o.is_ascii_hexdigit())
}

/// « RRGGBB » ou « #RRGGBB » (`^#?[0-9A-Fa-f]{6}\z`), pour Map.
fn est_couleur_map(v: &str) -> bool {
    let v = v.strip_prefix('#').unwrap_or(v);
    v.len() == 6 && v.bytes().all(|o| o.is_ascii_hexdigit())
}

/// Une lueur (LogoGlow) : « #RRGGBB » ou « #AARRGGBB », sinon aucune (comme `Get-CouleurGlow` d'Evermind).
fn lueur(v: Option<&Value>) -> Option<String> {
    let s = v?.as_str()?;
    let ok = s.starts_with('#') && (s.len() == 7 || s.len() == 9) && s[1..].bytes().all(|o| o.is_ascii_hexdigit());
    ok.then(|| s.to_string())
}

/// Le contraste entre deux couleurs « #RRGGBB » selon le W3C (WCAG 2), de 1 à 21.
pub fn contraste(a: &str, b: &str) -> f64 {
    fn luminance(c: &str) -> f64 {
        let c = c.trim_start_matches('#');
        if c.len() != 6 || !c.bytes().all(|o| o.is_ascii_hexdigit()) {
            return 0.0;
        }
        let (r, g, b) = composantes(c);
        let lin = |v: i32| {
            let v = f64::from(v) / 255.0;
            if v <= 0.040_45 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
        };
        0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    let (la, lb) = (luminance(a), luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

/// Les couleurs d'un pack laissent-elles l'écran lisible ? Le texte du kit (et le texte doux) sur les deux fonds
/// traduits, puis les couleurs de la marque sur ces fonds. `Err` dit ce qui ne va pas.
pub fn verifier_lisibilite(c: &Couleurs) -> Result<(), String> {
    let fonds = [c.traduire(FOND), c.traduire(FOND2)];
    let regles = [
        (TEXTE.to_string(), CONTRASTE_TEXTE, "le texte"),
        (TEXTE_DOUX.to_string(), CONTRASTE_TEXTE_DOUX, "le texte secondaire"),
        (c.traduire(MARQUE[0]), CONTRASTE_P, "la couleur P"),
        (c.traduire(MARQUE[1]), CONTRASTE_S_T, "la couleur S"),
        (c.traduire(MARQUE[2]), CONTRASTE_S_T, "la couleur T"),
    ];
    for fond in &fonds {
        for (couleur, minimum, quoi) in &regles {
            let k = contraste(couleur, fond);
            if k < *minimum {
                return Err(format!(
                    "{quoi} ({couleur}) se lit mal sur le fond {fond} (contraste {k:.1}, il faut {minimum})"
                ));
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------------------------
// Lecture des valeurs JSON comme PowerShell
// ---------------------------------------------------------------------------------------------------------------

/// Une propriété d'un objet JSON, sans tenir compte des majuscules (comme `$j.Logo` en PowerShell).
fn champ<'a>(o: &'a Map<String, Value>, nom: &str) -> Option<&'a Value> {
    o.get(nom).or_else(|| o.iter().find(|(k, _)| k.eq_ignore_ascii_case(nom)).map(|(_, v)| v))
}

/// Deux propriétés d'un même objet qui ne diffèrent que par les majuscules (« pc » et « PC ») : `ConvertFrom-Json` de
/// Windows PowerShell refuse alors tout le fichier, comme s'il était abîmé. Pareil ici.
fn cles_en_double(o: &Map<String, Value>) -> bool {
    let mut vues = std::collections::BTreeSet::new();
    for (k, v) in o {
        if !vues.insert(k.to_lowercase()) {
            return true;
        }
        let double = match v {
            Value::Object(s) => cles_en_double(s),
            Value::Array(a) => a.iter().any(|x| x.as_object().is_some_and(cles_en_double)),
            _ => false,
        };
        if double {
            return true;
        }
    }
    false
}

/// Une propriété d'une valeur qui est peut-être un objet (`$j.Mascotte.File`).
fn sous<'a>(v: Option<&'a Value>, nom: &str) -> Option<&'a Value> {
    champ(v?.as_object()?, nom)
}

/// Vrai ou faux comme `if ($x)` en PowerShell : rien, faux, 0 et "" sont faux.
fn vrai(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|x| x != 0.0),
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(_)) => true,
    }
}

/// Un nombre comme `[double]` en PowerShell (un nombre, ou un texte qui en est un) ; `None` sinon.
fn nombre(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok().filter(|x| x.is_finite()),
        Value::Bool(b) => Some(f64::from(u8::from(*b))),
        Value::Null => Some(0.0),
        _ => None,
    }
}

/// Un entier comme `[int]` en PowerShell (arrondi au pair le plus proche) ; 0 pour ce qui n'en est pas un (PowerShell
/// s'arrêterait sur une erreur).
fn entier(v: Option<&Value>) -> i64 {
    nombre(v).map(|x| x.round_ties_even().clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i64).unwrap_or(0)
}

/// Un texte (`[string]$x`) : seulement une vraie chaîne, sinon "".
fn texte(v: Option<&Value>) -> String {
    v.and_then(Value::as_str).unwrap_or_default().to_string()
}

// ---------------------------------------------------------------------------------------------------------------
// suite.json
// ---------------------------------------------------------------------------------------------------------------

/// Un thème de la suite valable (comme `Read-Suite` de Mindcare) : un thème intégré (sans tenir compte des
/// majuscules, rendu en minuscules), ou « pack:<id> » exactement (`^pack:[a-z0-9-]{1,40}$`). `None` sinon.
pub fn choix_valable(valeur: &str) -> Option<String> {
    if let Some(t) = theme_integre(valeur) {
        return Some(t.id.to_string());
    }
    let id = valeur.strip_prefix("pack:")?;
    id_pack_valable(id).then(|| valeur.to_string())
}

/// `^[a-z0-9-]{1,40}$` : l'id d'un pack, qui est aussi le nom de son dossier (rien ne peut en sortir).
fn id_pack_valable(id: &str) -> bool {
    (1..=40).contains(&id.len()) && id.bytes().all(|o| o.is_ascii_lowercase() || o.is_ascii_digit() || o == b'-')
}

/// Ce qu'on garde de suite.json pour le thème.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct LectureSuite {
    /// Le thème choisi (« neon », « pack:<id> »...), s'il est valable
    pub choix: Option<String>,
    /// Pourquoi il n'y a pas de choix (fichier absent, vide, abîmé, pris, thème inconnu)
    pub raison: Option<String>,
    /// Ce qui s'est passé à la lecture (copie .bak reprise...), pour le journal de l'appli
    pub journal: Vec<String>,
}

/// Lit le thème choisi dans suite.json. Simple lecture : rien n'est jamais modifié (suite.json appartient à
/// Mindset). Un fichier abîmé est remplacé par sa copie `.bak` si elle est bonne (lecture sûre de [`json_sur`]).
pub fn lire_suite(fichier: &Path) -> LectureSuite {
    let mut l = LectureSuite::default();
    let lu = match json_sur::lire(fichier, false) {
        Ok(lu) => lu,
        Err(e) => {
            l.raison = Some(format!("suite.json illisible pour l'instant ({e})"));
            return l;
        }
    };
    // (le journal de la lecture sûre ne sert que si la copie .bak a pris le relais : sinon la raison dit tout)
    if lu.valeur.is_some() {
        l.journal = lu.journal;
    }
    let double = lu.valeur.as_ref().is_some_and(cles_en_double);
    let Some(o) = lu.valeur.filter(|_| !double) else {
        l.journal.clear();
        l.raison = Some(match lu.abime {
            _ if double => "suite.json abîmé".to_string(),
            None => "suite.json absent".to_string(),
            Some(t) if t.trim_start_matches('\u{FEFF}').trim().is_empty() => "suite.json vide".to_string(),
            Some(_) => "suite.json abîmé".to_string(),
        });
        return l;
    };
    // (« theme » écrit en minuscules par Mindset ; comme PowerShell, la casse du nom de la propriété ne compte pas)
    match champ(&o, "theme") {
        None | Some(Value::Null) => l.raison = Some("aucun thème choisi dans suite.json".to_string()),
        Some(Value::String(s)) => match choix_valable(s) {
            Some(c) => l.choix = Some(c),
            None => l.raison = Some("thème inconnu dans suite.json".to_string()),
        },
        Some(_) => l.raison = Some("thème mal écrit dans suite.json".to_string()),
    }
    l
}

// ---------------------------------------------------------------------------------------------------------------
// Les packs
// ---------------------------------------------------------------------------------------------------------------

/// Une image (ou la police) d'un pack : un simple nom de fichier, et son chemin dans le dossier du pack.
#[derive(Debug, Clone, PartialEq)]
pub struct Image {
    /// Le nom du fichier (pour une adresse comme « https://theme.local/<nom> »)
    pub fichier: String,
    /// Son chemin complet : toujours `<dossier du pack>\<fichier>`
    pub chemin: PathBuf,
}

/// Une image animée : une planche d'images côte à côte (ou une seule image).
#[derive(Debug, Clone, PartialEq)]
pub struct Planche {
    pub image: Image,
    pub images: u32,
    /// En millisecondes
    pub delai: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Mascotte {
    pub planche: Planche,
    /// Retournée de gauche à droite
    pub miroir: bool,
    /// Image opaque (une scène) : montrée en vignette arrondie
    pub vignette: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Bas {
    pub planche: Planche,
    /// De 16 à 48 pixels
    pub hauteur: u32,
}

/// Où l'image de fond reste collée quand l'écran la recadre.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Alignement {
    /// Gauche (x) ou haut (y)
    Debut,
    Centre,
    /// Droite (x) ou bas (y)
    Fin,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Fond {
    pub image: Image,
    /// De 0,05 à 1 (0,35 par défaut)
    pub opacite: f64,
    pub x: Alignement,
    pub y: Alignement,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Police {
    pub fichier: Image,
    /// Partout (« tout »), sinon sur les titres
    pub partout: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChargementConsole {
    pub image: Image,
    /// « tourne » : l'image tourne ; sinon elle reste fixe
    pub tourne: bool,
}

/// Le bloc « Console » d'un pack (la nouvelle interface), comme Mindset le lit : seulement des images du dossier du
/// pack, aux extensions attendues (le reste est ignoré).
#[derive(Debug, Clone, PartialEq)]
pub struct Console {
    /// Les images des tuiles, par id de tuile (PNG ou WebP)
    pub tuiles: BTreeMap<String, Image>,
    pub mascotte: Option<Image>,
    pub chargement: Option<ChargementConsole>,
    /// Le fond (sans lui : l'image de fond du pack)
    pub fond: Option<Image>,
    pub fond_opacite: f64,
    pub logo: Option<Image>,
}

/// Un thème personnalisé de la suite, lu dans son dossier.
#[derive(Debug, Clone, PartialEq)]
pub struct Pack {
    pub id: String,
    /// Le dossier du pack (le seul d'où viennent ses images)
    pub dossier: PathBuf,
    pub nom: String,
    pub description: String,
    /// La phrase d'accueil brute (« {0} » = Bonjour ou Bonsoir), voir [`Pack::phrase_accueil`]
    pub bonjour: String,
    pub logo: Option<Planche>,
    /// La lueur du logo (« #RRGGBB » ou « #AARRGGBB »)
    pub logo_lueur: Option<String>,
    pub mascotte: Option<Mascotte>,
    /// L'image de chargement (« Loader »)
    pub chargement: Option<Planche>,
    /// Le dessin animé du bas (« Footer »)
    pub bas: Option<Bas>,
    pub fond: Option<Fond>,
    pub police: Option<Police>,
    /// Police pixel (tailles exactes, sans lissage) ; vrai par défaut
    pub pixel: bool,
    pub console: Option<Console>,
}

impl Pack {
    /// La phrase d'accueil, « {0} » remplacé par Bonjour (ou Bonsoir le soir), comme `$Hello -f ...` ; mal écrite
    /// pour .NET (une autre accolade), elle est rendue telle quelle, comme PowerShell. `None` sans phrase.
    pub fn phrase_accueil(&self, soir: bool) -> Option<String> {
        if self.bonjour.is_empty() {
            return None;
        }
        let mot = if soir { "Bonsoir" } else { "Bonjour" };
        let mut sortie = String::new();
        let mut reste = self.bonjour.as_str();
        while let Some(i) = reste.find(['{', '}']) {
            sortie.push_str(&reste[..i]);
            let apres = &reste[i..];
            if apres.starts_with("{{") || apres.starts_with("}}") {
                sortie.push(apres.as_bytes()[0] as char);
                reste = &apres[2..];
            } else if let Some(r) = apres.strip_prefix("{0}") {
                sortie.push_str(mot);
                reste = r;
            } else {
                return Some(self.bonjour.clone());
            }
        }
        sortie.push_str(reste);
        Some(sortie)
    }
}

/// Un nom de fichier du pack : simple, sans dossier (comme `Test-NomFichierPack` : `^[\w .()-]{1,80}$` sans « .. »),
/// et en plus ni nom réservé de Windows (CON, NUL...) ni point ou espace à la fin (Windows les retire).
fn nom_fichier_valable(nom: &str) -> bool {
    let n = nom.chars().count();
    if !(1..=80).contains(&n) || nom.contains("..") || nom.ends_with(['.', ' ']) {
        return false;
    }
    if !nom.chars().all(|c| c == '_' || c.is_alphabetic() || c.is_ascii_digit() || " .()-".contains(c)) {
        return false;
    }
    let base = nom.split('.').next().unwrap_or("").trim_end().to_ascii_uppercase();
    let reserve = matches!(base.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ((base.starts_with("COM") || base.starts_with("LPT"))
            && base.len() == 4
            && base.as_bytes()[3].is_ascii_digit()
            && base.as_bytes()[3] != b'0');
    !reserve
}

/// Une vraie entrée du disque, pas un lien (lien symbolique ou jonction : il pourrait mener hors du dossier).
fn sans_lien(chemin: &Path) -> Option<std::fs::Metadata> {
    std::fs::symlink_metadata(chemin).ok().filter(|m| !m.file_type().is_symlink())
}

/// L'image (ou la police) `v` du pack, si c'est un nom de fichier valable, d'une extension attendue, et un vrai
/// fichier du dossier du pack.
fn image(dossier: &Path, v: Option<&Value>, extensions: &[&str]) -> Option<Image> {
    let nom = v?.as_str()?;
    if !nom_fichier_valable(nom) {
        return None;
    }
    let ext = nom.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase())?;
    if !extensions.contains(&ext.as_str()) {
        return None;
    }
    let chemin = dossier.join(nom);
    sans_lien(&chemin).filter(|m| m.is_file())?;
    Some(Image { fichier: nom.to_string(), chemin })
}

fn planche(dossier: &Path, v: Option<&Value>, delai_min: i64) -> Option<Planche> {
    let image = image(dossier, sous(v, "File"), EXT_IMAGES)?;
    Some(Planche {
        image,
        images: borne(entier(sous(v, "Frames")), 1),
        delai: borne(entier(sous(v, "Delay")), delai_min),
    })
}

/// `[math]::Max(min, n)`, en nombre positif.
fn borne(n: i64, min: i64) -> u32 {
    u32::try_from(n.max(min)).unwrap_or(u32::MAX)
}

/// Les couleurs d'un pack (`Colors`), vérifiées comme `Test-CouleursPack` (Mindset) et `Get-CouleursPack`
/// (Evermind) : P, S et T « #RRGGBB », les clés et valeurs de Map « RRGGBB » (le « # » est permis), NH et NS des
/// nombres. `Ok(None)` : pas de couleurs propres (P, S ou T manque) ; `Err` : ce qui est mal écrit.
fn couleurs_pack(c: &Value) -> Result<Option<Couleurs>, String> {
    let Value::Object(o) = c else { return Err("Colors n'est pas un groupe de couleurs".to_string()) };
    let mut pst = Vec::new();
    for n in ["P", "S", "T"] {
        match champ(o, n) {
            None => pst.push(None),
            Some(Value::String(v)) if est_couleur(v) => pst.push(Some(v.clone())),
            Some(_) => return Err(format!("{n} n'est pas une couleur #RRGGBB")),
        }
    }
    let mut map = BTreeMap::new();
    match champ(o, "Map") {
        None | Some(Value::Null) => {}
        Some(Value::Object(m)) => {
            for (k, v) in m {
                let Some(v) = v.as_str().filter(|v| est_couleur_map(v)) else {
                    return Err("Map contient autre chose que des couleurs".to_string());
                };
                if !est_couleur_map(k) {
                    return Err("Map contient autre chose que des couleurs".to_string());
                }
                let (k, v) =
                    (k.trim_start_matches('#').to_ascii_uppercase(), v.trim_start_matches('#').to_ascii_uppercase());
                // (PowerShell garderait la dernière écrite ; l'ordre du fichier n'est pas connu ici : refusé)
                if map.get(&k).is_some_and(|ancienne| *ancienne != v) {
                    return Err(format!("Map remplace deux fois la couleur {k}"));
                }
                map.insert(k, v);
            }
        }
        Some(_) => return Err("Map n'est pas un groupe de couleurs".to_string()),
    }
    let mut nh = None;
    let mut ns = 1.0;
    for n in ["NH", "NS"] {
        let v = match champ(o, n) {
            None | Some(Value::Null) => continue,
            Some(v @ (Value::Number(_) | Value::String(_))) => nombre(Some(v)),
            Some(_) => None,
        };
        let Some(x) = v else { return Err(format!("{n} n'est pas un nombre")) };
        if n == "NH" {
            nh = Some(x);
        } else if x < 0.0 {
            return Err("NS est négatif".to_string());
        } else if x != 0.0 {
            ns = x; // (NS à 0 : 1, comme PowerShell)
        }
    }
    match (pst[0].take(), pst[1].take(), pst[2].take()) {
        (Some(p), Some(s), Some(t)) => Ok(Some(Couleurs { p, s, t, nh, ns, map })),
        _ => Ok(None),
    }
}

/// Un pack lu : ses images, et ce que disent ses couleurs.
struct PackLu {
    pack: Pack,
    couleurs: Option<Couleurs>,
    base: String,
}

/// Lit le pack `id` dans le premier dossier qui l'a, comme `Get-ThemePack` de Mindcare : le réglage de l'appli
/// d'abord, puis celui de Mindset (l'ordre de `dossiers_packs`). Un pack.json absent, illisible ou abîmé fait passer
/// au dossier suivant.
fn lire_pack(id: &str, dossiers_packs: &[PathBuf], raisons: &mut Vec<String>) -> Option<PackLu> {
    if !id_pack_valable(id) {
        raisons.push(format!("nom de thème refusé ({id})"));
        return None;
    }
    for racine in dossiers_packs {
        let dossier = racine.join(id);
        let f = dossier.join("pack.json");
        let Some(md) = sans_lien(&dossier) else {
            if std::fs::symlink_metadata(&dossier).is_ok() {
                raisons.push(format!("thème {id} refusé dans {} : son dossier est un lien", racine.display()));
            }
            continue;
        };
        if !md.is_dir() {
            continue;
        }
        let Some(mf) = sans_lien(&f).filter(|m| m.is_file()) else {
            if std::fs::symlink_metadata(&f).is_ok() {
                raisons
                    .push(format!("thème {id} refusé dans {} : pack.json n'est pas un vrai fichier", racine.display()));
            }
            continue;
        };
        if mf.len() > TAILLE_MAX_PACK {
            raisons.push(format!("thème {id} refusé dans {} : pack.json trop gros", racine.display()));
            continue;
        }
        let j = match std::fs::read(&f) {
            Err(e) => {
                raisons.push(format!("thème {id} illisible dans {} ({e})", racine.display()));
                continue;
            }
            Ok(o) => {
                serde_json::from_str::<Value>(decoder_fichier(&o, SansMarque::Utf8).trim_start_matches('\u{FEFF}'))
            }
        };
        let Ok(Value::Object(j)) = j else {
            raisons.push(format!("thème {id} abîmé dans {}", racine.display()));
            continue;
        };
        if cles_en_double(&j) {
            raisons.push(format!("thème {id} abîmé dans {} (deux fois le même réglage)", racine.display()));
            continue;
        }
        return Some(construire_pack(id, dossier, &j, raisons));
    }
    None
}

fn construire_pack(id: &str, dossier: PathBuf, j: &Map<String, Value>, raisons: &mut Vec<String>) -> PackLu {
    let d = dossier.as_path();
    let mut nom = texte(champ(j, "Name"));
    if nom.is_empty() {
        nom = id.to_string();
    }
    let logo = image(d, champ(j, "Logo"), EXT_IMAGES).map(|image| Planche {
        image,
        images: borne(entier(champ(j, "LogoFrames")), 1),
        delai: borne(entier(champ(j, "LogoDelay")), 30),
    });
    let m = champ(j, "Mascotte");
    let mascotte = planche(d, m, 40).map(|planche| Mascotte {
        planche,
        miroir: vrai(sous(m, "Flip")),
        vignette: vrai(sous(m, "Vignette")),
    });
    let chargement = planche(d, champ(j, "Loader"), 30);
    let f = champ(j, "Footer");
    let bas = planche(d, f, 40).map(|planche| Bas { planche, hauteur: borne(entier(sous(f, "Height")).min(48), 16) });
    let opacite_fond = if vrai(champ(j, "BackgroundOpacity")) {
        nombre(champ(j, "BackgroundOpacity")).unwrap_or(0.35).clamp(0.05, 1.0)
    } else {
        0.35
    };
    let al = texte(champ(j, "BackgroundAlign")).to_lowercase();
    let fond = image(d, champ(j, "Background"), EXT_IMAGES).map(|image| Fond {
        image,
        opacite: opacite_fond,
        x: if al.contains("droite") {
            Alignement::Fin
        } else if al.contains("gauche") {
            Alignement::Debut
        } else {
            Alignement::Centre
        },
        y: if al.contains("bas") {
            Alignement::Fin
        } else if al.contains("haut") {
            Alignement::Debut
        } else {
            Alignement::Centre
        },
    });
    let police = image(d, champ(j, "Font"), EXT_POLICES)
        .map(|fichier| Police { fichier, partout: texte(champ(j, "FontScope")).eq_ignore_ascii_case("tout") });
    let pixel = match champ(j, "FontPixel") {
        None | Some(Value::Null) => true,
        v => vrai(v),
    };
    let console = match champ(j, "Console") {
        Some(Value::Object(c)) => Some(console(d, c, fond.as_ref())),
        _ => None,
    };

    // Les couleurs : les siennes (un thème « pack-<id> »), sinon son thème de base, sinon Néon
    let mut couleurs = None;
    let colors = champ(j, "Colors");
    if vrai(colors) {
        match colors.map(couleurs_pack) {
            Some(Err(e)) => raisons.push(format!("thème {id} : couleurs refusées ({e}), thème de base gardé")),
            Some(Ok(Some(c))) => match verifier_lisibilite(&c) {
                Ok(()) => couleurs = Some(c),
                Err(e) => raisons.push(format!("thème {id} : couleurs refusées ({e}), thème de base gardé")),
            },
            _ => {}
        }
    }
    let base = theme_integre(&texte(champ(j, "Base"))).map_or(NEON, |t| t.id).to_string();
    let pack = Pack {
        id: id.to_string(),
        dossier: dossier.clone(),
        nom,
        description: texte(champ(j, "Desc")),
        bonjour: texte(champ(j, "Hello")),
        logo,
        logo_lueur: lueur(champ(j, "LogoGlow")),
        mascotte,
        chargement,
        bas,
        fond,
        police,
        pixel,
        console,
    };
    PackLu { pack, couleurs, base }
}

/// Le bloc « Console », comme Mindset le lit (packs.ps1).
fn console(d: &Path, c: &Map<String, Value>, fond_pack: Option<&Fond>) -> Console {
    const TUILES: &[&str] = &["png", "webp"];
    const IMAGES: &[&str] = &["png", "webp", "gif", "jpg", "jpeg"];
    const LOGO: &[&str] = &["png", "webp", "gif"];
    let mut tuiles = BTreeMap::new();
    if let Some(Value::Object(t)) = champ(c, "Tuiles") {
        for (k, v) in t {
            let nom_ok = (1..=20).contains(&k.len()) && k.bytes().all(|o| o.is_ascii_alphabetic());
            if let Some(i) = image(d, Some(v), TUILES).filter(|_| nom_ok) {
                tuiles.insert(k.clone(), i);
            }
        }
    }
    let ch = champ(c, "Chargement");
    let (fichier, effet) = match ch {
        Some(Value::String(_)) => (ch, None),
        _ => (sous(ch, "File"), sous(ch, "Effet")),
    };
    let chargement = image(d, fichier, IMAGES)
        .map(|image| ChargementConsole { image, tourne: texte(effet).eq_ignore_ascii_case("tourne") });
    let mut fond = image(d, champ(c, "Fond"), IMAGES);
    let mut opacite = None;
    if fond.is_some() && !matches!(champ(c, "FondOpacite"), None | Some(Value::Null)) {
        opacite = nombre(champ(c, "FondOpacite")).map(|x| x.clamp(0.05, 1.0));
    }
    if fond.is_none()
        && let Some(f) = fond_pack
    {
        fond = Some(f.image.clone());
        opacite = Some(f.opacite);
    }
    Console {
        tuiles,
        mascotte: image(d, champ(c, "Mascotte"), IMAGES),
        chargement,
        fond,
        fond_opacite: opacite.unwrap_or(0.35),
        logo: image(d, champ(c, "Logo"), LOGO),
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Le thème prêt à l'emploi
// ---------------------------------------------------------------------------------------------------------------

/// Le thème à appliquer.
#[derive(Debug, Clone, PartialEq)]
pub struct Theme {
    /// Le thème demandé (« neon », « pack:<id> »...), `None` s'il n'y en avait pas de valable
    pub choix: Option<String>,
    /// Le thème de couleurs appliqué : un thème intégré (« neon »...), ou « pack-<id> » (les couleurs du pack)
    pub id: String,
    /// Le nom à montrer (celui du pack pour un thème personnalisé)
    pub nom: String,
    pub couleurs: Couleurs,
    /// Police de tout l'écran du thème intégré (Terminal)
    pub police: Option<&'static str>,
    pub decor: Option<&'static str>,
    /// Les images, la police et la phrase d'un thème personnalisé
    pub pack: Option<Pack>,
    /// Pourquoi le thème appliqué n'est pas tout à fait celui demandé (vide si tout va bien), pour le journal
    pub raisons: Vec<String>,
}

impl Theme {
    fn integre(t: &'static ThemeIntegre, choix: Option<String>, raisons: Vec<String>) -> Theme {
        Theme {
            choix,
            id: t.id.to_string(),
            nom: t.nom.to_string(),
            couleurs: Couleurs::depuis_integre(t),
            police: t.police,
            decor: t.decor,
            pack: None,
            raisons,
        }
    }

    /// Néon, le thème des replis.
    pub fn neon() -> Theme {
        Theme::integre(&THEMES_INTEGRES[0], None, Vec::new())
    }

    /// Une couleur Néon (« #RRGGBB » ou « #AARRGGBB », l'alpha devant comme en XAML) traduite dans ce thème, comme
    /// `ConvertTo-ThemeHex` : rien ne change en Néon.
    pub fn traduire(&self, hex: &str) -> String {
        if self.id == NEON { hex.to_string() } else { self.couleurs.traduire(hex) }
    }

    /// Le thème pour l'écran (`data-theme` du kit), comme `Get-ThemeVue` : un des 5 thèmes intégrés ; un pack à
    /// couleurs propres donne « neon », ses couleurs passant par [`Theme::couleurs_ecran`].
    pub fn theme_ecran(&self) -> &'static str {
        theme_integre(&self.id).map_or(NEON, |t| t.id)
    }

    /// Les couleurs propres d'un pack pour l'écran (les variables `--P`, `--S`, `--T`, `--fond`, `--fond2` du kit),
    /// comme `Get-CouleursVue` ; `None` pour un thème intégré (le kit a déjà ses couleurs).
    pub fn couleurs_ecran(&self) -> Option<Vec<(&'static str, String)>> {
        if theme_integre(&self.id).is_some() {
            return None;
        }
        Some(self.variables_css())
    }

    /// Les variables CSS du kit pour ce thème (`--P`, `--S`, `--T`, `--fond`, `--fond2`), quel qu'il soit : pour un
    /// thème intégré, ce sont celles de kit.css.
    pub fn variables_css(&self) -> Vec<(&'static str, String)> {
        vec![
            ("P", self.traduire(MARQUE[0])),
            ("S", self.traduire(MARQUE[1])),
            ("T", self.traduire(MARQUE[2])),
            ("fond", self.traduire(FOND)),
            ("fond2", self.traduire(FOND2)),
        ]
    }
}

/// Le thème `choix` (« neon », « pack:<id> »... ou `None`), prêt à l'emploi. Les packs sont cherchés dans
/// `dossiers_packs`, dans l'ordre (pour une appli gérée : `<données>\<Appli>\packs`, puis `<données>\Mindset\packs`).
/// Ne rate jamais : un choix absent ou inconnu, un pack absent ou abîmé donnent Néon ; un pack aux couleurs refusées
/// garde ses images avec son thème de base (Néon s'il n'en a pas). La raison est dans [`Theme::raisons`].
pub fn charger(choix: Option<&str>, dossiers_packs: &[PathBuf]) -> Theme {
    let Some(c) = choix else { return Theme::neon() };
    let mut raisons = Vec::new();
    let Some(valable) = choix_valable(c) else {
        raisons.push(format!("thème inconnu ({c}) : Néon"));
        return Theme::integre(&THEMES_INTEGRES[0], None, raisons);
    };
    if let Some(t) = theme_integre(&valable) {
        return Theme::integre(t, Some(valable), raisons);
    }
    let id = valable["pack:".len()..].to_string();
    let Some(lu) = lire_pack(&id, dossiers_packs, &mut raisons) else {
        raisons.push(format!("thème personnalisé introuvable ({valable}) : Néon en attendant"));
        return Theme::integre(&THEMES_INTEGRES[0], Some(valable), raisons);
    };
    let mut t = match lu.couleurs {
        Some(couleurs) => Theme {
            choix: Some(valable),
            id: format!("pack-{id}"),
            nom: lu.pack.nom.clone(),
            couleurs,
            police: None,
            decor: None,
            pack: None,
            raisons,
        },
        None => {
            let base = theme_integre(&lu.base).unwrap_or(&THEMES_INTEGRES[0]);
            let mut t = Theme::integre(base, Some(valable), raisons);
            t.nom = lu.pack.nom.clone();
            t
        }
    };
    t.pack = Some(lu.pack);
    t
}

/// Le thème de la suite : celui choisi dans Mindset (suite.json), prêt à l'emploi. Sans choix valable (suite.json
/// absent, vide, abîmé, pris, thème inconnu) : Néon, avec la raison.
pub fn theme_de_la_suite(fichier_suite: &Path, dossiers_packs: &[PathBuf]) -> Theme {
    let l = lire_suite(fichier_suite);
    let mut t = charger(l.choix.as_deref(), dossiers_packs);
    let mut raisons = l.journal;
    raisons.extend(l.raison.map(|r| format!("{r} : Néon")));
    raisons.append(&mut t.raisons);
    t.raisons = raisons;
    t
}

#[cfg(test)]
mod tests;
