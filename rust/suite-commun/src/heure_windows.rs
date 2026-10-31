//! L'heure locale du PC, comme `Get-Date` (le nom d'un fichier mis de côté par [`crate::json_sur`]).
//!
//! Le seul endroit de suite-commun qui appelle Windows, et donc le seul où le code « unsafe » est permis : un appel
//! sans argument ni pointeur. Seulement avec l'option « heure-locale » (activée par défaut) : une appli qui ne doit
//! pas appeler Windows ici (Mindcare) s'en passe et donne sa propre horloge à `json_sur::Options`.

#![allow(unsafe_code)]

use windows::Win32::System::SystemInformation::GetLocalTime;

use crate::json_sur::HeureLocale;

/// L'heure locale du PC, à la seconde (`GetLocalTime`, ce que lit `Get-Date`).
pub fn heure_locale() -> HeureLocale {
    // SAFETY : GetLocalTime ne prend rien et rend une structure par valeur ; il ne peut pas échouer.
    let t = unsafe { GetLocalTime() };
    HeureLocale {
        annee: i32::from(t.wYear),
        mois: u32::from(t.wMonth),
        jour: u32::from(t.wDay),
        heure: u32::from(t.wHour),
        minute: u32::from(t.wMinute),
        seconde: u32::from(t.wSecond),
    }
}
