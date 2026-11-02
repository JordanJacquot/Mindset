//! Le dossier de données WebView2 d'une appli Tauri de la suite, et les options fixes de son navigateur
//! (docs\regles-tauri.md, règle 7). Rien ici ne dépend de Tauri : l'appli donne ce qui est calculé ici à sa fenêtre
//! (`data_directory` et `additional_browser_args` de `WebviewWindowBuilder`).
//!
//! - Les applis en PowerShell (Mindset, Nevermind) partagent `<données de la suite>\WebView2` (Mindset :
//!   `$ConsoleWebviewCommun`, modules\console.ps1:19), sans aucune option. Tauri (wry) crée son navigateur avec des
//!   options à lui (arguments, langue, barres de défilement) : WebView2 refuserait de partager ce dossier. Les applis
//!   Tauri ont donc le leur, juste à côté : `<données de la suite>\WebView2-Tauri` ([`DOSSIER_APPLIS_TAURI`]).
//! - Tauri 2.12.5 ne permet pas de choisir un profil WebView2 (wry le sait, Tauri ne le transmet pas), et toutes les
//!   applis Tauri ont la même adresse (`http://tauri.localhost`) : un profil commun mélangerait leurs stockages. Chaque
//!   appli a donc son sous-dossier, `WebView2-Tauri\<Nom>` ([`dossier_profil`]) : Mindset l'efface quand l'appli est
//!   désinstallée sans ses données.
//! - Les options du navigateur sont fixées par la suite ([`OPTIONS_NAVIGATEUR`]), les mêmes pour toutes les applis :
//!   ce sont celles que wry 0.57 met de lui-même quand on ne lui en donne pas, écrites ici pour qu'aucune version de
//!   wry ni aucun réglage (lecture automatique, proxy) ne les change en douce.
//! - Avant de s'en servir, le dossier doit pouvoir s'écrire ([`tester_ecriture`], comme `Test-DossierWebviewEcrivable`,
//!   console.ps1:51-64) : sinon WebView2 afficherait lui-même une boîte d'erreur. Repli : `<données de l'appli>\
//!   ecran-webview` ([`choisir_dossier`]). L'écran ne reste jamais vide.

use std::path::{Path, PathBuf};

use crate::themes::nom_fichier_valable;

/// Le dossier WebView2 des applis Tauri, dans les données de la suite (à côté de `WebView2`, celui de Mindset).
pub const DOSSIER_APPLIS_TAURI: &str = "WebView2-Tauri";
/// Le dossier de repli, dans les données de l'appli, quand celui de la suite ne s'écrit pas.
pub const DOSSIER_REPLI: &str = "ecran-webview";
/// Les options du navigateur, les mêmes pour toutes les applis Tauri de la suite (`additional_browser_args`). Ce sont
/// celles que wry 0.57.1 ajoute par défaut (webview2\mod.rs:311) : ni mini-menu sur le texte choisi, ni lecteur PDF à
/// part, ni SmartScreen (les pages viennent toutes de l'exe).
pub const OPTIONS_NAVIGATEUR: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection";

/// `<données de la suite>\WebView2-Tauri`.
pub fn dossier_applis_tauri(donnees_suite: &Path) -> PathBuf {
    donnees_suite.join(DOSSIER_APPLIS_TAURI)
}

/// Un nom d'appli valable pour un dossier : des lettres et chiffres simples et des tirets (40 au plus), qui commence
/// par une lettre, et pas un nom réservé de Windows.
fn nom_appli_valable(appli: &str) -> bool {
    (1..=40).contains(&appli.len())
        && appli.starts_with(|c: char| c.is_ascii_alphabetic())
        && appli.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        && nom_fichier_valable(appli)
}

/// Le dossier de l'appli `appli` (son nom, « Mindcare ») : `<données de la suite>\WebView2-Tauri\<appli>`. Refusé
/// si les données de la suite ne sont pas un chemin complet ou si le nom n'est pas un simple nom de dossier.
pub fn dossier_profil(donnees_suite: &Path, appli: &str) -> Result<PathBuf, String> {
    if !nom_appli_valable(appli) {
        return Err(format!("nom d'appli refusé pour le dossier WebView2 : {appli:?}"));
    }
    if !donnees_suite.is_absolute() {
        return Err(format!("dossier des données de la suite incomplet : {}", donnees_suite.display()));
    }
    Ok(dossier_applis_tauri(donnees_suite).join(appli))
}

/// Le dossier peut-il s'écrire ? Créé s'il manque, puis un petit fichier témoin écrit et effacé dans le dossier et
/// dans son `EBWebView` s'il existe (là où WebView2 écrit), comme `Test-DossierWebviewEcrivable`. `Err` : la raison.
pub fn tester_ecriture(dossier: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dossier).map_err(|e| format!("{} ne peut pas être créé ({e})", dossier.display()))?;
    for d in [dossier.to_path_buf(), dossier.join("EBWebView")] {
        if !d.is_dir() {
            continue;
        }
        let t = d.join(format!("ecriture-{}.tmp", std::process::id()));
        std::fs::write(&t, b"1").map_err(|e| format!("{} ne s'écrit pas ({e})", d.display()))?;
        std::fs::remove_file(&t).map_err(|e| format!("{} ne s'efface pas ({e})", t.display()))?;
    }
    Ok(())
}

/// Le dossier choisi pour WebView2.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DossierEcran {
    /// Le dossier à donner à WebView2 (`data_directory`).
    pub dossier: PathBuf,
    /// Vrai si c'est le repli `<données de l'appli>\ecran-webview`.
    pub repli: bool,
    /// Pourquoi le dossier de la suite n'a pas été pris (pour le journal), et si le repli ne s'écrit pas non plus.
    pub raison: Option<String>,
}

/// Le dossier WebView2 de l'appli : `WebView2-Tauri\<appli>` dans les données de la suite s'il s'écrit, sinon
/// `<données de l'appli>\ecran-webview`. Le repli est rendu même s'il ne s'écrit pas non plus (la raison le dit) :
/// l'appli l'essaie quand même, et le journal dit pourquoi.
pub fn choisir_dossier(donnees_suite: &Path, appli: &str, donnees_appli: &Path) -> DossierEcran {
    let raison = match dossier_profil(donnees_suite, appli) {
        Ok(d) => match tester_ecriture(&d) {
            Ok(()) => return DossierEcran { dossier: d, repli: false, raison: None },
            Err(r) => r,
        },
        Err(r) => r,
    };
    let repli = donnees_appli.join(DOSSIER_REPLI);
    let raison = match tester_ecriture(&repli) {
        Ok(()) => raison,
        Err(r2) => format!("{raison} ; repli : {r2}"),
    };
    DossierEcran { dossier: repli, repli: true, raison: Some(raison) }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Un dossier d'essai neuf sous le dossier temporaire, effacé à la fin.
    struct Dossier(PathBuf);
    impl Dossier {
        fn nouveau(nom: &str) -> Dossier {
            let d = std::env::temp_dir().join(format!("suite-commun-webview-{nom}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            Dossier(d)
        }
    }
    impl Drop for Dossier {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn chemins_des_applis_tauri() {
        let suite = Path::new(r"C:\Users\essai\AppData\Local\Mindset");
        assert_eq!(dossier_applis_tauri(suite), Path::new(r"C:\Users\essai\AppData\Local\Mindset\WebView2-Tauri"));
        assert_eq!(
            dossier_profil(Path::new(r"X:\Mindset\Donnees"), "Mindcare").unwrap(),
            Path::new(r"X:\Mindset\Donnees\WebView2-Tauri\Mindcare")
        );
        // Jamais le dossier WebView2 de Mindset (options différentes : WebView2 refuserait de le partager)
        assert_ne!(DOSSIER_APPLIS_TAURI, "WebView2");
    }

    /// Chaque règle du nom : un cas refusé (contre-épreuve : sans la règle, le cas passerait).
    #[test]
    fn noms_d_applis_refuses() {
        let suite = Path::new(r"C:\essai");
        for nom in [
            "",
            "..",
            r"..\Mindset",
            "a/b",
            r"a\b",
            "C:",
            "Mind care",
            "Mindcare.",
            "-Mindcare",
            "1appli",
            "Évermind",
            "CON",
            "nul",
            "COM1",
            &"a".repeat(41),
        ] {
            assert!(dossier_profil(suite, nom).is_err(), "{nom:?} accepté");
        }
        assert!(dossier_profil(suite, "Mind-care2").is_ok());
        // Les données de la suite doivent être un chemin complet
        assert!(dossier_profil(Path::new(r"Mindset\Donnees"), "Mindcare").is_err());
    }

    #[test]
    fn options_fixes() {
        // Exactement les options par défaut de wry 0.57.1 (sinon deux applis aux options différentes ne partageraient
        // plus le navigateur), sans lecture automatique ni proxy
        assert_eq!(OPTIONS_NAVIGATEUR, "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection");
        assert!(!OPTIONS_NAVIGATEUR.contains("proxy") && !OPTIONS_NAVIGATEUR.contains("autoplay"));
        assert!(!OPTIONS_NAVIGATEUR.contains("remote-debugging"));
    }

    #[test]
    fn dossier_de_la_suite_quand_il_s_ecrit() {
        let d = Dossier::nouveau("ecrit");
        let suite = d.0.join("suite");
        let c = choisir_dossier(&suite, "Mindcare", &d.0.join(r"suite\Mindcare"));
        assert_eq!(c, DossierEcran { dossier: suite.join(r"WebView2-Tauri\Mindcare"), repli: false, raison: None });
        assert!(c.dossier.is_dir());
        // Le témoin est effacé, aussi dans EBWebView
        std::fs::create_dir_all(c.dossier.join("EBWebView")).unwrap();
        tester_ecriture(&c.dossier).unwrap();
        assert_eq!(std::fs::read_dir(&c.dossier).unwrap().count(), 1);
        assert_eq!(std::fs::read_dir(c.dossier.join("EBWebView")).unwrap().count(), 0);
    }

    /// Le dossier de la suite ne peut pas être créé (un fichier porte déjà son nom) : repli.
    #[test]
    fn repli_si_le_dossier_ne_se_cree_pas() {
        let d = Dossier::nouveau("fichier");
        let suite = d.0.join("suite");
        std::fs::create_dir_all(&suite).unwrap();
        std::fs::write(suite.join("WebView2-Tauri"), b"pas un dossier").unwrap();
        let appli = d.0.join(r"suite\Mindcare");
        let c = choisir_dossier(&suite, "Mindcare", &appli);
        assert_eq!((c.dossier.as_path(), c.repli), (appli.join("ecran-webview").as_path(), true));
        assert!(c.raison.unwrap().contains("ne peut pas être créé"));
        assert!(appli.join("ecran-webview").is_dir());
    }

    /// Son EBWebView ne s'écrit pas (ici : un fichier en lecture seule porte le nom du témoin) : repli.
    #[test]
    fn repli_si_ebwebview_ne_s_ecrit_pas() {
        let d = Dossier::nouveau("lecture-seule");
        let suite = d.0.join("suite");
        let eb = suite.join(r"WebView2-Tauri\Mindcare\EBWebView");
        std::fs::create_dir_all(&eb).unwrap();
        let temoin = eb.join(format!("ecriture-{}.tmp", std::process::id()));
        std::fs::write(&temoin, b"").unwrap();
        let mut p = std::fs::metadata(&temoin).unwrap().permissions();
        p.set_readonly(true);
        std::fs::set_permissions(&temoin, p.clone()).unwrap();
        let c = choisir_dossier(&suite, "Mindcare", &d.0.join(r"suite\Mindcare"));
        #[allow(clippy::permissions_set_readonly_false)]
        p.set_readonly(false);
        std::fs::set_permissions(&temoin, p).unwrap();
        assert!(c.repli, "{c:?}");
        assert!(c.raison.unwrap().contains("ne s'écrit pas"));
    }

    /// Un nom d'appli refusé ne crée rien dans les données de la suite : repli aussi.
    #[test]
    fn repli_si_le_nom_est_refuse() {
        let d = Dossier::nouveau("nom");
        let suite = d.0.join("suite");
        let c = choisir_dossier(&suite, r"..\Mindset", &d.0.join(r"suite\Mindcare"));
        assert!(c.repli && c.raison.unwrap().contains("nom d'appli refusé"));
        assert!(!suite.join("WebView2-Tauri").exists());
    }

    /// Ni le dossier de la suite ni le repli ne s'écrivent : le repli est rendu, avec les deux raisons.
    #[test]
    fn rien_ne_s_ecrit() {
        let d = Dossier::nouveau("rien");
        let suite = d.0.join("suite");
        std::fs::create_dir_all(&suite).unwrap();
        std::fs::write(suite.join("WebView2-Tauri"), b"").unwrap();
        std::fs::write(suite.join("Mindcare"), b"").unwrap();
        let c = choisir_dossier(&suite, "Mindcare", &suite.join("Mindcare"));
        assert!(c.repli);
        assert!(c.raison.unwrap().contains("; repli :"));
    }
}
