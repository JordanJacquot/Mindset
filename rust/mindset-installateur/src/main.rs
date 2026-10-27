//! MindsetInstallateur.exe : le mini-installateur de Mindset, sans fenêtre (voir la bibliothèque,
//! mindset_installateur). Lancé par la tâche SYSTEM « \Mindset\Mindset (installation) », ou par installer-admin.ps1
//! (le relais) après la demande de Windows.
//!
//! Ici, seulement la préparation du processus et le vrai Windows (src/windows, le seul module « unsafe »).

#![windows_subsystem = "windows"]
#![deny(unsafe_op_in_unsafe_fn)]

mod windows;

use std::process::ExitCode;

fn main() -> ExitCode {
    // DLL cherchées dans System32 seulement, COM prêt pour tout le processus
    let _processus = windows::preparer_processus();
    let args: Vec<String> = std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned()).collect();
    let mut systeme = windows::Windows::new();
    match mindset_installateur::executer(&args, &mut systeme) {
        Ok(()) => ExitCode::SUCCESS,
        // Paramètres refusés : rien n'a été fait (comme PowerShell, qui ne lançait pas le script)
        Err(_) => ExitCode::from(2),
    }
}
