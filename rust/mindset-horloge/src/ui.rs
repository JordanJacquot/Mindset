//! La question de la croix rouge en HTML (`ui/fermeture.js`, `ui/fermeture.css`), au rendu de la grille
//! « Fermeture » d'interface.xaml. Le bloc horloge ne dessine rien lui-même (le bloc écrans est le seul à écrire le
//! HTML) : ces deux fichiers sont à joindre aux scripts et styles des écrans, qui appellent
//! `horlogeFermeture.installer(coquille, couleur)`. Les tests contrôlent qu'ils restent fidèles à interface.xaml.

/// Le script de la question.
pub const FERMETURE_JS: &str = include_str!("../ui/fermeture.js");
/// Ses styles.
pub const FERMETURE_CSS: &str = include_str!("../ui/fermeture.css");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn les_textes_de_la_question_sont_ceux_de_wpf() {
        for t in [
            "Fermer Mindset ?",
            "Réduit près de l\\'horloge, Mindset et tes applis restent prêts : un clic sur son icône le rouvre. Quitter ferme aussi toutes tes applis (les rappels d\\'Evermind, par exemple, ne sonneront plus jusqu\\'à la réouverture).",
            "Ne plus me demander (modifiable dans Paramètres)",
            ">Annuler<",
            ">Tout quitter<",
            ">Réduire près de l\\'horloge<",
            "horloge:fermeture",
        ] {
            assert!(FERMETURE_JS.contains(t), "manque : {t}");
        }
        // (l'ordre des boutons : Annuler, Tout quitter, Réduire)
        let a = FERMETURE_JS.find(">Annuler<").unwrap();
        let q = FERMETURE_JS.find(">Tout quitter<").unwrap();
        let r = FERMETURE_JS.find(">Réduire près").unwrap();
        assert!(a < q && q < r);
    }

    #[test]
    fn regles_de_la_page() {
        for (nom, t) in [("fermeture.js", FERMETURE_JS), ("fermeture.css", FERMETURE_CSS)] {
            assert!(!t.contains('\u{2014}') && !t.contains('\u{2013}'), "{nom} : tiret long");
            for interdit in ["__TAURI", "invoke", "ipc.localhost", "chrome.webview", "http://", "https://", "eval("] {
                assert!(!t.contains(interdit), "{nom} : {interdit}");
            }
        }
    }
}
