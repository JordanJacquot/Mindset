//! Les arguments de Mindset.exe (lanceur.cs:28-41 et 66-72, Mindset.ps1:13) : `-Demarrage` (lancé avec Windows, ou
//! relancé par le mini-installateur par la tâche de démarrage) et `-Desinstaller` (ancienne entrée d'« Applications
//! installées »). Sans tenir compte des majuscules ; `/Demarrage` aussi (contrat-appli, partie 6). Tout autre argument
//! est ignoré.

/// Ce que disent les arguments.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Arguments {
    pub demarrage: bool,
    pub desinstaller: bool,
}

/// Lit les arguments (sans le nom du programme).
pub fn lire_arguments<I: IntoIterator<Item = String>>(args: I) -> Arguments {
    let mut a = Arguments::default();
    for x in args {
        let n = x.strip_prefix('-').or_else(|| x.strip_prefix('/')).unwrap_or("");
        if n.eq_ignore_ascii_case("Demarrage") {
            a.demarrage = true;
        } else if n.eq_ignore_ascii_case("Desinstaller") {
            a.desinstaller = true;
        }
    }
    a
}

/// Le désinstalleur autonome, à côté de Mindset.exe (lanceur.cs:30).
pub const DESINSTALLEUR: &str = "Desinstaller Mindset.exe";

#[cfg(test)]
mod tests {
    use super::*;

    fn lire(l: &[&str]) -> Arguments {
        lire_arguments(l.iter().map(|s| s.to_string()))
    }

    #[test]
    fn arguments() {
        assert_eq!(lire(&[]), Arguments::default());
        assert!(lire(&["-Demarrage"]).demarrage);
        assert!(lire(&["/demarrage"]).demarrage);
        assert!(lire(&["-DEMARRAGE"]).demarrage);
        assert!(!lire(&["Demarrage"]).demarrage, "sans tiret ni barre : ignoré");
        assert!(lire(&["-Desinstaller"]).desinstaller);
        assert_eq!(lire(&["-Autre", "--demarrage"]), Arguments::default());
    }
}
