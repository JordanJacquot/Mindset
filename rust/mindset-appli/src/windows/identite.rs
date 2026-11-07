//! L'identité de Mindset pour la barre des tâches : `JordanJacquot.Mindset` (`[MSNative]::SetAppId`, Mindset.ps1:118),
//! la même que ses raccourcis : épinglé depuis le menu Démarrer, il garde un seul bouton.

use windows::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID;
use windows::core::HSTRING;

/// Pose l'identité du processus (avant toute fenêtre).
pub fn poser() -> windows::core::Result<()> {
    let id = HSTRING::from(crate::ID_APPLI);
    // SAFETY : texte valide pendant l'appel ; seulement un réglage de ce processus
    unsafe { SetCurrentProcessExplicitAppUserModelID(&id) }
}
