//! Mindset en Rust : l'appli. Elle remplace l'hôte PowerShell et WPF (Mindset.ps1, le lanceur C# Mindset.exe, et ce
//! qui sert à la fenêtre dans interface.ps1) : une fenêtre Tauri qui montre la page de Mindset (ui\), assemble l'état
//! de tous les blocs, leur passe les gestes, exécute leurs effets et fait tourner leurs travaux de fond.
//!
//! - [`blocs`] : la liste des blocs, dans l'ordre où Mindset.ps1 charge ses modules ;
//! - [`hote`] : l'état assemblé, les gestes, les signaux, les tics, les travaux de fond (sans Tauri : testé à part) ;
//! - [`commandes`], [`pont`] : les trois commandes de la page et la lecture de ses messages ;
//! - [`fenetre`] : la fenêtre « principale » ;
//! - [`protocoles`] : `pack` (les images et polices du thème perso) et `fichier` (les fichiers déclarés par les blocs) ;
//! - [`depart`] : les arguments (`-Demarrage`, `-Desinstaller`) ;
//! - `programme` : le programme Mindset.exe tout branché ; `windows` : le seul module où « unsafe » est permis ;
//! - `essai` et `png` : la construction d'essai seulement (option cargo `essai`, jamais livrée).

use mindset_noyau::Bloc;

pub mod commandes;
pub mod depart;
#[cfg(feature = "essai")]
pub mod essai;
pub mod fenetre;
pub mod hote;
#[cfg(any(feature = "essai", test))]
pub mod png;
pub mod pont;
#[cfg(windows)]
pub mod programme;
pub mod protocoles;
#[cfg(windows)]
pub mod windows;

pub use commandes::Page;

/// Le nom de l'appli : titre de sa fenêtre, nom de son dossier WebView2 (`WebView2-Tauri\Mindset`).
pub const NOM_APPLI: &str = "Mindset";
/// La version de Mindset (celle de son Cargo.toml, la même que version.json).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// L'identité de Mindset dans la barre des tâches (`$AppId`, Mindset.ps1:118).
pub const ID_APPLI: &str = "JordanJacquot.Mindset";

/// Tous les blocs de Mindset, dans l'ordre où Mindset.ps1 charge ses modules (donnees, suite, packs, themes, ...,
/// applis, installations, mindset, interface, accueil, integration, parametres, zone, console). C'est l'ordre de
/// `demarrer`, des actions (le premier qui prend une action la garde) et de `fermer`. Cette liste reste le point
/// d'entrée des blocs.
pub fn blocs() -> Vec<Box<dyn Bloc>> {
    vec![
        Box::new(mindset_donnees::BlocDonnees),
        Box::new(mindset_liste::BlocListe::default()),
        Box::new(mindset_parametres::BlocParametres::default()),
        Box::new(mindset_publications::BlocPublications::default()),
        Box::new(mindset_installations::BlocInstallations::default()),
        Box::new(mindset_lui_meme::BlocLuiMeme::default()),
        Box::new(mindset_ecrans::BlocEcrans::default()),
        Box::new(mindset_accrochage::BlocAccrochage::default()),
        Box::new(mindset_horloge::BlocHorloge::default()),
        Box::new(mindset_console::BlocConsole::default()),
    ]
}

/// Ajoute à Tauri la page partagée et les commandes de l'appli (les seules que la page peut appeler, chacune avec sa
/// permission dans capabilities\principale.json).
pub fn preparer<R: tauri::Runtime>(constructeur: tauri::Builder<R>, page: Page) -> tauri::Builder<R> {
    constructeur.manage(page).invoke_handler(tauri::generate_handler![
        commandes::suivre_page,
        commandes::noter_visibilite,
        commandes::action
    ])
}

/// La configuration de Tauri lue à la construction (tauri.conf.json, capabilities\, les pages de ui\ rangées dans
/// l'exe, avec les empreintes de leurs scripts ajoutées à la CSP).
pub fn contexte<R: tauri::Runtime>() -> tauri::Context<R> {
    tauri::generate_context!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chaque_bloc_a_son_nom_du_tableau_commun() {
        let noms: Vec<&str> = blocs().iter().map(|b| b.nom()).collect();
        assert_eq!(
            noms,
            [
                "donnees",
                "liste",
                "parametres",
                "publications",
                "installations",
                "lui-meme",
                "ecrans",
                "accrochage",
                "horloge",
                "console"
            ]
        );
        for (_, bloc) in mindset_noyau::partage::PROPRIETAIRES {
            assert!(noms.contains(bloc), "le bloc {bloc} du tableau commun n'est pas dans blocs()");
        }
    }
}
