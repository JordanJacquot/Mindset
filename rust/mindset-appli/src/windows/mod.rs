//! Le seul module de l'appli qui parle directement à Windows, et le seul où le code « unsafe » est permis (chaque
//! bloc a son commentaire SAFETY) :
//!
//! - [`synchro`] : un seul Mindset à la fois (`Local\Mindset-Instance`, `Local\Mindset-Afficher`) ;
//! - [`fenetre`] : la taille minimale gardée quand un autre programme change la taille ;
//! - [`webview2`] : les réglages de WebView2 que Tauri ne transmet pas, la veille de la page ;
//! - [`identite`] : l'identité de la barre des tâches (`JordanJacquot.Mindset`) ;
//! - [`message`] : les boîtes de message de Windows (écran impossible) ;
//! - `capture` (construction d'essai seulement) : l'image de la fenêtre (`PrintWindow`).
//!
//! Rien ici n'écrit dans le registre, ne touche aux fenêtres d'un autre programme ni ne lance quoi que ce soit.
//! (L'accrochage des applis, qui touche à leurs fenêtres, est le bloc « accrochage ».)

#![allow(unsafe_code)]

#[cfg(feature = "essai")]
pub mod capture;
pub mod fenetre;
pub mod identite;
pub mod message;
pub mod synchro;
pub mod webview2;

use windows::Win32::Foundation::{HANDLE, HWND};

/// Un handle de Windows gardé comme un nombre.
pub(crate) fn handle(h: usize) -> HANDLE {
    HANDLE(h as *mut core::ffi::c_void)
}

/// Une fenêtre gardée comme un nombre (le `HWND` de Tauri).
pub(crate) fn hwnd(h: usize) -> HWND {
    HWND(h as *mut core::ffi::c_void)
}
