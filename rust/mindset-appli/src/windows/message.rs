//! La boîte de message de Windows : quand l'écran ne peut pas s'afficher, ou quand des fichiers de Mindset manquent
//! (Mindset.ps1:106-109, interface.ps1:14). Une fenêtre voulue, pour l'utilisateur ; jamais dans la construction d'essai.

use windows::Win32::UI::WindowsAndMessaging::{
    IDYES, MB_ICONINFORMATION, MB_OK, MB_SETFOREGROUND, MB_YESNO, MESSAGEBOX_STYLE, MessageBoxW,
};
use windows::core::HSTRING;

fn boite(texte: &str, titre: &str, style: MESSAGEBOX_STYLE) -> bool {
    let texte = HSTRING::from(texte);
    let titre = HSTRING::from(titre);
    // SAFETY : textes valides pendant l'appel ; aucune fenêtre parente
    unsafe { MessageBoxW(None, &texte, &titre, style | MB_ICONINFORMATION | MB_SETFOREGROUND) == IDYES }
}

/// Un message avec « Oui » et « Non » : `true` pour « Oui ».
pub fn demander(texte: &str, titre: &str) -> bool {
    boite(texte, titre, MB_YESNO)
}

/// Un message avec « OK ».
pub fn informer(texte: &str, titre: &str) {
    let _ = boite(texte, titre, MB_OK);
}
