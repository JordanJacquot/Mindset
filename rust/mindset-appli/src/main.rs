//! Mindset en Rust : le programme Mindset.exe. Tout est dans la bibliothèque (src\programme.rs).

// Pas de console : c'est une appli à fenêtre (même en construction de mise au point, aucune console ne s'ouvre).
#![windows_subsystem = "windows"]

fn main() {
    mindset_appli::programme::lancer()
}
