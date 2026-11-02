// Projet d'essai de outils\verifier-tauri.ps1 : jamais construit, seulement lu.
fn main() {
    // Le manifeste des commandes : sans lui, toute page appellerait toutes les commandes
    let attributs = tauri_build::Attributes::new()
        .app_manifest(tauri_build::AppManifest::new().commands(&["etat_appli", "quitter_appli"]));
    tauri_build::try_build(attributs).expect("construction de l'appli");
}
