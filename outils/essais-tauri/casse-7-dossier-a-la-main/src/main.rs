// Projet d'essai de outils\verifier-tauri.ps1 : jamais construit, seulement lu.
use std::path::PathBuf;

use suite_commun::webview;

#[tauri::command]
fn etat_appli() -> String {
    "prête".to_string()
}

#[tauri::command]
async fn quitter_appli() {
    std::process::exit(0);
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![etat_appli, quitter_appli])
        .setup(|app| {
            let suite = PathBuf::from(r"C:\essai\Mindset");
            tauri::WebviewWindowBuilder::new(app, "principale", tauri::WebviewUrl::App("index.html".into()))
                .title("Essai")
                .data_directory(suite.join("WebView2"))
                .additional_browser_args(webview::OPTIONS_NAVIGATEUR)
                .devtools(false)
                .visible(false)
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("lancement de l'appli");
}
