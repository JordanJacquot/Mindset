//! La fenêtre « principale » de Mindset, créée dans le code (règle 7 de docs\regles-tauri.md). Une seule, jamais
//! recréée.
//!
//! - cachée et sans prendre la main au départ ; montrée ensuite par l'hôte, sauf lancé avec Windows (`-Demarrage`) ;
//! - titre « Mindset », icône du M (build.rs), fond `#06050F` dès l'allumage (pas d'éclair blanc), barre de titre
//!   sombre (interface.ps1:70-78) ;
//! - la taille d'interface.xaml:3 (1340 x 930, au moins 1000 x 640), ramenée à la zone utile de l'écran
//!   (`Get-TailleFenetre`, interface.ps1:24-40) et centrée ;
//! - dossier WebView2 `<données de la suite>\WebView2-Tauri\Mindset` s'il s'écrit, sinon
//!   `<données de Mindset>\ecran-webview`, et options fixes du navigateur : tout par suite-commun ;
//! - outils de développement, zoom, saisie automatique et téléchargements coupés ; navigation fermée aux pages de
//!   l'appli (console.ps1:120-122), aucune nouvelle fenêtre.

use std::path::Path;
use std::sync::Arc;

use suite_commun::webview::{self, DossierEcran};
use tauri::webview::{NewWindowResponse, PageLoadEvent};
use tauri::window::Color;
use tauri::{Manager, Runtime, Theme, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

/// Le nom (label) de la fenêtre : celui de capabilities\principale.json
pub const LABEL: &str = "principale";
/// La taille de la fenêtre (interface.xaml:3), en pixels logiques
pub const TAILLE: (f64, f64) = (1340.0, 930.0);
/// La taille minimale (interface.xaml:3)
pub const TAILLE_MIN: (f64, f64) = (1000.0, 640.0);
/// La couleur du fond (interface.xaml:4, `#06050F`)
pub const FOND: Color = Color(6, 5, 15, 255);
/// L'adresse de la page de l'appli (rangée dans l'exe, sous Windows)
pub const ADRESSE_PAGE: &str = "http://tauri.localhost/index.html";

/// Seules les pages de l'appli s'affichent : `http://tauri.localhost/...`, sans nom, mot de passe ni port.
pub fn adresse_permise(adresse: &Url) -> bool {
    adresse.scheme() == "http"
        && adresse.host_str() == Some("tauri.localhost")
        && adresse.port().is_none()
        && adresse.username().is_empty()
        && adresse.password().is_none()
}

/// La taille de la fenêtre et sa taille minimale, ramenées à la zone utile de l'écran (`Get-TailleFenetre`,
/// interface.ps1:28-31) : `(largeur, hauteur, min_largeur, min_hauteur)`. Une zone inconnue (moins de 100) : la taille
/// d'origine (interface.ps1:35).
pub fn taille_fenetre(zone_largeur: f64, zone_hauteur: f64) -> (f64, f64, f64, f64) {
    if zone_largeur < 100.0 || zone_hauteur < 100.0 {
        return (TAILLE.0, TAILLE.1, TAILLE_MIN.0, TAILLE_MIN.1);
    }
    let l = TAILLE.0.min(zone_largeur).floor();
    let h = TAILLE.1.min(zone_hauteur).floor();
    (l, h, TAILLE_MIN.0.min(l), TAILLE_MIN.1.min(h))
}

/// Le journal de l'appli, vu de la fenêtre
pub type Journal = Arc<dyn Fn(&str) + Send + Sync>;

fn court(adresse: &Url) -> String {
    adresse.as_str().chars().take(120).collect()
}

/// Crée la fenêtre « principale », cachée. `donnees_suite` : le dossier des données de la suite ; `donnees_mindset` :
/// celui de Mindset. `zone` : la zone utile de l'écran en pixels logiques (largeur, hauteur), si elle est connue. Rend
/// aussi le dossier WebView2 choisi, pour le journal.
pub fn creer_principale<R: Runtime, M: Manager<R>>(
    app: &M,
    donnees_suite: &Path,
    donnees_mindset: &Path,
    zone: Option<(f64, f64)>,
    journal: Journal,
) -> tauri::Result<(WebviewWindow<R>, DossierEcran)> {
    let choix = webview::choisir_dossier(donnees_suite, crate::NOM_APPLI, donnees_mindset);
    let (l, h, ml, mh) =
        zone.map_or((TAILLE.0, TAILLE.1, TAILLE_MIN.0, TAILLE_MIN.1), |(zl, zh)| taille_fenetre(zl, zh));
    let pour_navigation = Arc::clone(&journal);
    // (le label écrit en clair, égal à LABEL : verifier-tauri.ps1 le lit ici pour le relier à sa capability)
    let fenetre = WebviewWindowBuilder::new(app, "principale", WebviewUrl::App("index.html".into()))
        .title(crate::NOM_APPLI)
        .inner_size(l, h)
        .min_inner_size(ml, mh)
        .center()
        .visible(false)
        .focused(false)
        .theme(Some(Theme::Dark))
        .background_color(FOND)
        .devtools(false)
        .zoom_hotkeys_enabled(false)
        .general_autofill_enabled(false)
        .data_directory(choix.dossier.clone())
        .additional_browser_args(webview::OPTIONS_NAVIGATEUR)
        .on_navigation(move |a| {
            let permise = adresse_permise(a);
            if !permise {
                pour_navigation(&format!("Écran : navigation refusée ({})", court(a)));
            }
            permise
        })
        .on_page_load(move |_, p| {
            if p.event() == PageLoadEvent::Finished {
                journal(&format!("Écran : page chargée {}", court(p.url())));
            }
        })
        .on_new_window(|_, _| NewWindowResponse::Deny)
        .on_download(|_, _| false)
        .build()?;
    Ok((fenetre, choix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seules_les_pages_de_l_appli_sont_permises() {
        let a = |s: &str| s.parse::<Url>().unwrap();
        for s in [ADRESSE_PAGE, "http://tauri.localhost/", "http://tauri.localhost/console/scene.html?vue=menu"] {
            assert!(adresse_permise(&a(s)), "{s}");
        }
        for s in [
            "https://tauri.localhost/",
            "http://tauri.localhost:8080/",
            "http://pack.localhost/fond.png",
            "http://fichier.localhost/x.png",
            "http://tauri.localhost.exemple.com/",
            "https://github.com/JordanJacquot/Mindset",
            "https://mindset.local/scene.html",
            "http://moi:secret@tauri.localhost/",
            "file:///C:/Windows/win.ini",
            "about:blank",
            "javascript:alert(1)",
        ] {
            assert!(!adresse_permise(&a(s)), "{s}");
        }
    }

    #[test]
    fn taille_ramenee_a_l_ecran() {
        // (interface.ps1 : Get-TailleFenetre, cas de tester-fenetre-console.ps1)
        assert_eq!(taille_fenetre(1920.0, 1040.0), (1340.0, 930.0, 1000.0, 640.0));
        assert_eq!(taille_fenetre(1366.0, 728.0), (1340.0, 728.0, 1000.0, 640.0));
        assert_eq!(taille_fenetre(1280.0 / 1.5, 680.0 / 1.25), (853.0, 544.0, 853.0, 544.0));
        assert_eq!(taille_fenetre(50.0, 900.0), (1340.0, 930.0, 1000.0, 640.0));
    }
}
