//! Construction de Mindset.exe par tauri-build : rien d'autre que des fichiers lus.
//!
//! - le manifeste des commandes de l'appli (docs\regles-tauri.md, règle 2) : chaque commande demande sa permission
//!   `allow-<commande>`, donnée à la seule fenêtre « principale » dans capabilities\ ;
//! - l'icône de Mindset (icons\Mindset.ico, copie de Mindset\fichiers\Mindset.ico) ;
//! - la fiche de version : productName (« Mindset », tauri.conf.json) comme description de l'exe, ce qu'affiche le
//!   Gestionnaire des tâches, et la version du Cargo.toml ;
//! - le runtime C rangé dans l'exe (réglage par défaut de tauri-build) : aucune VCRUNTIME140.dll à installer.

fn main() {
    println!("cargo:rerun-if-changed=icons/Mindset.ico");
    let windows = tauri_build::WindowsAttributes::new().window_icon_path("icons/Mindset.ico");
    let attributs = tauri_build::Attributes::new()
        .windows_attributes(windows)
        .app_manifest(tauri_build::AppManifest::new().commands(&["suivre_page", "noter_visibilite", "action"]));
    tauri_build::try_build(attributs).expect("construction de Mindset (tauri-build)");
    // Les exe des tests : sans les contrôles modernes de Windows (comctl32 version 6), ils ne démarrent pas
    // (STATUS_ENTRYPOINT_NOT_FOUND), comme pour Nevermind et Mindcare.
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        println!("cargo:rustc-link-arg-tests=/MANIFEST:EMBED");
        println!(
            "cargo:rustc-link-arg-tests=/MANIFESTDEPENDENCY:type='win32' name='Microsoft.Windows.Common-Controls' \
             version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'"
        );
    }
}
