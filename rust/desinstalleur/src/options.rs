//! Les options de la ligne de commande (les mêmes que la version C#, sauf celles des essais, absentes de l'exe livré).
//!
//!   Desinstaller Mindset.exe              la fenêtre « Désinstaller Mindset » (case « Supprimer aussi mes données »,
//!                                         décochée au départ)
//!   Desinstaller Mindset.exe -Nettoyer    nettoyage de secours, sans question : retire tout ce qui reste de Mindset,
//!                                         même d'une installation à moitié cassée. Les données sont gardées, sauf avec
//!                                         -SupprimerDonnees.
//!
//! Options internes (relances) :
//!   -Sid <S-1-5-21-...>                       l'utilisateur qui a lancé la désinstallation (son registre, son Bureau...)
//!   -Copie -Original <exe> -AttendrePid <n>   la copie temporaire : attend la fin du premier, puis travaille
//!   -Silencieux                               aucune fenêtre ni message
//!   -Rapport <fichier>                        le bilan en JSON (ok, faits, restes, alertes, texte affiché...), pour un
//!                                             programme qui attend la fin (essais réels sur la machine de GitHub)
//! Seulement dans la construction d'essai (option « essai » de cargo, jamais dans l'exe livré) :
//!   -Test <fichier.json>                      faux environnement (outils\tester-desinstallation.ps1)
//!   -EssaiFenetre <0|1>                       la fenêtre hors de l'écran, qui se clique seule (case laissée ou cochée)

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Options {
    pub nettoyer: bool,
    pub supprimer_donnees: bool,
    pub silencieux: bool,
    pub copie: bool,
    pub sid: Option<String>,
    pub original: Option<String>,
    pub rapport: Option<String>,
    pub attendre_pid: u32,
    /// Faux environnement (construction d'essai seulement)
    pub test: Option<String>,
    /// -1 : pas d'essai ; 0 ou 1 : la fenêtre se clique seule, case laissée ou cochée (construction d'essai seulement)
    pub essai_fenetre: i32,
}

/// Un SID d'utilisateur local ou du domaine : `^S-1-5-21-\d+-\d+-\d+-\d+$`
pub fn sid_valide(s: &str) -> bool {
    let Some(reste) = s.strip_prefix("S-1-5-21-") else { return false };
    let morceaux: Vec<&str> = reste.split('-').collect();
    morceaux.len() == 4 && morceaux.iter().all(|m| !m.is_empty() && m.bytes().all(|o| o.is_ascii_digit()))
}

impl Options {
    /// Lit les arguments (sans le nom du programme). Une option inconnue est ignorée, comme dans la version C#.
    pub fn lire(args: &[String]) -> Options {
        let mut o = Options { essai_fenetre: -1, ..Options::default() };
        let mut i = 0;
        while i < args.len() {
            let suivant = args.get(i + 1).cloned();
            match args[i].to_lowercase().as_str() {
                "-nettoyer" => o.nettoyer = true,
                "-supprimerdonnees" => o.supprimer_donnees = true,
                "-silencieux" => o.silencieux = true,
                "-copie" => o.copie = true,
                "-sid" => {
                    o.sid = suivant;
                    i += 1;
                }
                "-original" => {
                    o.original = suivant;
                    i += 1;
                }
                "-rapport" => {
                    o.rapport = suivant;
                    i += 1;
                }
                "-attendrepid" => {
                    o.attendre_pid = suivant.and_then(|s| s.parse().ok()).unwrap_or(0);
                    i += 1;
                }
                #[cfg(feature = "essai")]
                "-test" => {
                    o.test = suivant;
                    i += 1;
                }
                #[cfg(feature = "essai")]
                "-essaifenetre" => {
                    o.essai_fenetre = if suivant.as_deref() == Some("1") { 1 } else { 0 };
                    i += 1;
                }
                _ => {}
            }
            i += 1;
        }
        if o.sid.as_deref().is_some_and(|s| !sid_valide(s)) {
            o.sid = None;
        }
        o
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lire(a: &[&str]) -> Options {
        Options::lire(&a.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn options_de_la_relance() {
        let o = lire(&["-Nettoyer", "-SupprimerDonnees", "-Silencieux", "-Sid", "S-1-5-21-1-2-3-1001"]);
        assert!(o.nettoyer && o.supprimer_donnees && o.silencieux && !o.copie);
        assert_eq!(o.sid.as_deref(), Some("S-1-5-21-1-2-3-1001"));
        let o = lire(&["-COPIE", "-Original", "C:\\x\\Desinstaller Mindset.exe", "-AttendrePid", "1234"]);
        assert!(o.copie);
        assert_eq!(o.original.as_deref(), Some("C:\\x\\Desinstaller Mindset.exe"));
        assert_eq!(o.attendre_pid, 1234);
        assert_eq!(o.essai_fenetre, -1);
    }

    #[test]
    fn sid_refuse() {
        assert_eq!(lire(&["-Sid", "S-1-5-18"]).sid, None);
        assert_eq!(lire(&["-Sid", "S-1-5-21-1-2-3"]).sid, None);
        assert_eq!(lire(&["-Sid", "S-1-5-21-1-2-3-x"]).sid, None);
        assert_eq!(lire(&["-Sid"]).sid, None);
        assert!(sid_valide("S-1-5-21-3623811015-3361044348-30300820-1013"));
    }

    #[test]
    fn options_inconnues_ignorees() {
        let o = lire(&["-Inconnue", "-AttendrePid", "pas un nombre", "-Nettoyer"]);
        assert!(o.nettoyer);
        assert_eq!(o.attendre_pid, 0);
    }

    /// L'exe livré (sans l'option « essai ») ne connaît ni -Test ni -EssaiFenetre
    #[cfg(not(feature = "essai"))]
    #[test]
    fn pas_d_options_d_essai_dans_l_exe_livre() {
        let o = lire(&["-Test", "C:\\faux.json", "-EssaiFenetre", "1"]);
        assert_eq!(o.test, None);
        assert_eq!(o.essai_fenetre, -1);
    }

    #[cfg(feature = "essai")]
    #[test]
    fn options_d_essai() {
        let o = lire(&["-Test", "C:\\faux.json", "-EssaiFenetre", "1"]);
        assert_eq!(o.test.as_deref(), Some("C:\\faux.json"));
        assert_eq!(o.essai_fenetre, 1);
    }
}
