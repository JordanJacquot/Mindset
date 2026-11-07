//! Les dessins des écrans, en tracés SVG : la lettre de chaque appli (`Get-LettreAppli`, `Get-LettreTexte`,
//! chargement.ps1:15-57), le M de Mindset (`Get-MindsetM`, logo.ps1:101-110), les icônes des onglets des thèmes de base
//! (`New-IconeBase`, accueil.ps1:20-60) et le bonjour (`Update-Greeting`, `Get-ThemeHello`).
//!
//! Les tracés sont donnés sur une grille de 100 (les formes de PowerShell sont toutes proportionnelles à leur taille) :
//! la page les met à l'échelle (`viewBox="0 0 100 100"`). WPF « élargit » le trait (`GetWidenedPathGeometry`) ; en
//! SVG, c'est le même trait (`stroke-width`, bouts et coins arrondis).

use mindset_noyau::appli::Appli;
use serde_json::{Value, json};

fn n(x: f64) -> String {
    // (au plus 3 décimales, sans zéros inutiles)
    let s = format!("{:.3}", (x * 1000.0).round() / 1000.0);
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s == "-0" { "0".into() } else { s.to_string() }
}

/// Le M de Mindset, sur 100 : `{ d, epaisseur }`.
pub fn m_mindset() -> Value {
    let (x, y, w, h) = (22.0, 22.0, 56.0, 56.0);
    let d = format!(
        "M {},{} L {},{} L {},{} L {},{} L {},{}",
        n(x),
        n(y + h),
        n(x),
        n(y),
        n(x + w / 2.0),
        n(y + h * 0.6),
        n(x + w),
        n(y),
        n(x + w),
        n(y + h)
    );
    json!({ "d": d, "epaisseur": 15 })
}

/// Un tracé du champ « logo » de apps.json (sur une grille de 100) : seulement des lettres de commandes et des
/// nombres, sinon rien (la liste des applis l'a déjà vérifié ; ici il va dans un attribut de la page).
fn trace_sur(t: &str) -> bool {
    !t.is_empty() && t.len() <= 2000 && t.chars().all(|c| c.is_ascii_digit() || " ,.-MLHVCSQTAZmlhvcsqtaz".contains(c))
}

/// La lettre d'une appli, sur 100 : `{ d, epaisseur }` (un trait), ou `{ texte }` (la première lettre de son nom en
/// très gras), ou le M de Mindset.
pub fn lettre(a: Option<&Appli>) -> Value {
    match a.map(|a| a.id.as_str()) {
        Some("nevermind") => {
            let (x, y, w, h) = (22.0, 20.0, 56.0, 60.0);
            json!({ "d": format!("M {},{} L {},{} L {},{} L {},{}", n(x), n(y + h), n(x), n(y), n(x + w), n(y + h), n(x + w), n(y)), "epaisseur": 19 })
        }
        Some("evermind") => {
            let (x, y, w, h) = (27.0, 20.0, 46.0, 60.0);
            json!({ "d": format!("M {},{} L {},{} L {},{} L {},{} M {},{} L {},{}",
                n(x + w), n(y), n(x), n(y), n(x), n(y + h), n(x + w), n(y + h), n(x), n(y + h / 2.0), n(x + w * 0.82), n(y + h / 2.0)),
                "epaisseur": 17 })
        }
        _ => match a {
            Some(a) if trace_sur(&a.logo) => json!({ "d": a.logo, "epaisseur": a.logo_epaisseur * 100.0 }),
            Some(a) if !a.nom.is_empty() => {
                json!({ "texte": a.nom.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default() })
            }
            _ => m_mindset(),
        },
    }
}

/// L'icône de l'onglet de l'accueil (une petite maison au trait), sur 20.
pub const MAISON: &str =
    "M 2.5,10 L 10,3 L 17.5,10 M 4.8,8.2 L 4.8,17 L 15.2,17 L 15.2,8.2 M 8.3,17 L 8.3,12.3 L 11.7,12.3 L 11.7,17";

/// La maison du bouton « Menu » (interface.xaml, `MaisonMenu`), sur 24.
pub const MAISON_MENU: &str = "M3,10.5 L12,3 L21,10.5 M5,9 L5,20 L10,20 L10,14 L14,14 L14,20 L19,20 L19,9";

/// `[math]::Round(x, 2)` de .NET (au pair le plus proche).
fn arrondi2(x: f64) -> f64 {
    (x * 100.0).round_ties_even() / 100.0
}

/// La roue crantée de l'onglet des Paramètres, sur 20 : 8 dents autour d'un anneau, trou au centre (règle evenodd).
pub fn roue() -> String {
    let mut pts = Vec::new();
    for k in 0..8 {
        for (a, r) in [(-15.0, 6.6), (-8.0, 9.4), (8.0, 9.4), (15.0, 6.6)] {
            let ang = (f64::from(k) * 45.0 + a) * std::f64::consts::PI / 180.0;
            pts.push(format!("{},{}", n(arrondi2(10.0 + r * ang.cos())), n(arrondi2(10.0 + r * ang.sin()))));
        }
    }
    // (le trou : un cercle de 2,8 au centre, en deux arcs)
    format!("M {} L {} Z M 12.8,10 A 2.8,2.8 0 1 0 7.2,10 A 2.8,2.8 0 1 0 12.8,10 Z", pts[0], pts[1..].join(" "))
}

/// Le bonjour de l'accueil : « Bonjour » ou « Bonsoir » (de 18 h à 5 h), dans la phrase du thème personnalisé si elle
/// contient « {0} » (`Get-ThemeHello`), sinon « {0} ! ».
pub fn bonjour(heure: u32, phrase: Option<&suite_commun::themes::Pack>) -> String {
    let soir = !(5..18).contains(&heure);
    let mot = if soir { "Bonsoir" } else { "Bonjour" };
    match phrase.filter(|p| p.bonjour.contains("{0}")) {
        Some(p) => p.phrase_accueil(soir).unwrap_or_else(|| format!("{mot} !")),
        None => format!("{mot} !"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn traces() {
        assert_eq!(m_mindset()["d"], "M 22,78 L 22,22 L 50,55.6 L 78,22 L 78,78");
        let r = roue();
        assert!(r.starts_with("M 16.38,8.29 L 19.31,8.69 19.31,11.31 16.38,11.71"), "{r}");
        assert_eq!(r.split(" Z").next().unwrap().matches(',').count(), 32, "8 dents de 4 points");
        let z = Appli { id: "zephyr".into(), nom: "zéphyr".into(), ..Default::default() };
        assert_eq!(lettre(Some(&z))["texte"], "Z");
        let mal = Appli { logo: "M 0,0 \" onload=x".into(), ..z.clone() };
        assert_eq!(lettre(Some(&mal))["texte"], "Z", "un tracé douteux n'est jamais mis dans la page");
        assert_eq!(lettre(None), m_mindset());
    }
}
