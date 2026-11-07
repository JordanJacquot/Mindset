//! Les couleurs des écrans dans le thème de la suite (`Get-Brush`, `Get-Couleur`, `Convert-ThemeXaml` : toute la
//! fenêtre est dessinée en Néon, le thème « traduit » chaque couleur).
//!
//! La table vient du bloc « paramètres » (`theme.couleurs` du tableau commun, `partage::couleur`) ; une couleur qu'elle
//! n'a pas (ou le tableau encore vide, au tout début) est traduite ici par la même règle (`suite_commun::themes`,
//! `ConvertTo-ThemeHex`), à partir du thème choisi : les deux donnent toujours la même chose.
//!
//! La page reçoit [`PALETTE`] traduite (les variables CSS de ecrans.css, une par couleur Néon), et les couleurs des
//! cartes déjà traduites.

use serde_json::{Map, Value};
use suite_commun::themes::Theme;

/// Toutes les couleurs Néon (« RRGGBB ») écrites dans ecrans.css et coquille.css : interface.xaml, accueil.ps1,
/// chargement.ps1, logo.ps1, packs.ps1. La page pose une variable `--c-RRGGBB` (« r g b ») pour chacune.
pub const PALETTE: &[&str] = &[
    // Fond et panneaux, textes
    "06050F", "0C0920", "141030", "2A2450", "ECEAF7", "A9A3C9", "6F6894", "A6A1BC", "100C28", "060510", "08060F",
    "F2EFFA", "EEEBF7", "FFFFFF", "000000", // La marque et ses variantes
    "00E5FF", "B04BFF", "FF2EB5", "7A3CFF", "7A7BFF", "7FF4FF", "00D9F5", // L'interrupteur, les états
    "3A4355", "3DDC84", "FFB020", "FF5C7A",
];

/// Le traducteur des couleurs du thème de la suite.
#[derive(Debug, Clone)]
pub struct Traducteur {
    theme: Theme,
    table: Map<String, Value>,
}

impl Default for Traducteur {
    fn default() -> Self {
        Traducteur { theme: Theme::neon(), table: Map::new() }
    }
}

impl Traducteur {
    /// `table` : `theme.couleurs` du tableau commun (« #00E5FF » -> « #FF8A3D »), vide s'il n'y est pas encore.
    pub fn nouveau(theme: Theme, table: Map<String, Value>) -> Traducteur {
        Traducteur { theme, table }
    }

    /// Le thème (couleurs, police, pack).
    pub fn theme(&self) -> &Theme {
        &self.theme
    }

    /// La table du bloc « paramètres ».
    pub fn table(&self) -> &Map<String, Value> {
        &self.table
    }

    /// Une couleur Néon (« #RRGGBB » ou « #AARRGGBB ») dans le thème, en majuscules, comme la relit WPF
    /// (`Color.ToString()` sans l'opacité pleine).
    pub fn tr(&self, hex: &str) -> String {
        let haut = hex.to_ascii_uppercase();
        let brut = match self.table.get(&haut).and_then(Value::as_str) {
            Some(c) => c.to_ascii_uppercase(),
            None => self.theme.traduire(&haut).to_ascii_uppercase(),
        };
        // (« #FFRRGGBB » : opacité pleine, écrite comme « #RRGGBB »)
        match brut.strip_prefix("#FF") {
            Some(rgb) if brut.len() == 9 => format!("#{rgb}"),
            _ => brut,
        }
    }

    /// La palette de la page : « RRGGBB » -> « #RRGGBB » traduite.
    pub fn palette(&self) -> Map<String, Value> {
        PALETTE.iter().map(|c| ((*c).to_string(), Value::String(self.tr(&format!("#{c}"))))).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn neon_ne_change_rien() {
        let t = Traducteur::default();
        assert_eq!(t.tr("#00e5ff"), "#00E5FF");
        assert_eq!(t.tr("#8000E5FF"), "#8000E5FF");
        assert_eq!(t.tr("#FF00E5FF"), "#00E5FF");
        assert_eq!(t.palette().len(), PALETTE.len());
    }

    #[test]
    fn la_table_du_bloc_parametres_passe_avant() {
        let theme = suite_commun::themes::charger(Some("crepuscule"), &[]);
        let t = Traducteur::nouveau(theme.clone(), Map::new());
        assert_eq!(t.tr("#00E5FF"), "#FF8A3D");
        assert_eq!(t.tr("#0C0920"), "#1A0B12");
        let avec = Traducteur::nouveau(theme, json!({ "#00E5FF": "#123456" }).as_object().cloned().unwrap());
        assert_eq!(avec.tr("#00E5FF"), "#123456");
        assert_eq!(avec.tr("#0C0920"), "#1A0B12", "une couleur absente de la table est traduite ici");
    }
}
