//! La fenêtre principale vue par Windows : la taille minimale gardée quand un AUTRE programme change la taille
//! (`SetWindowPos`) : tao répond lui-même à `WM_WINDOWPOSCHANGING` sans `DefWindowProc`, qui seul borne la taille
//! (vu pour Mindcare et Nevermind en Rust). Repris de nevermind-appli\src\windows\fenetre.rs.

use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::Shell::{DefSubclassProc, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::{
    GWL_STYLE, GetWindowLongPtrW, IsWindow, MINMAXINFO, SWP_NOSIZE, SendMessageW, WINDOWPOS, WM_GETMINMAXINFO,
    WM_WINDOWPOSCHANGING, WS_CHILD, WS_MINIMIZE,
};

use super::hwnd;

/// Le numéro de la sous-classe de [`garder_taille_minimale`] (« MSMI »).
const SOUS_CLASSE_TAILLE: usize = 0x4D53_4D49;

/// La fenêtre existe encore (`IsWindow`).
pub fn existe(h: usize) -> bool {
    // SAFETY : IsWindow accepte n'importe quelle valeur
    h != 0 && unsafe { IsWindow(Some(hwnd(h))) }.as_bool()
}

/// Garde la taille minimale quand un autre programme change la taille. À appeler une fois, sur le fil de la fenêtre.
pub fn garder_taille_minimale(h: usize) -> bool {
    // SAFETY : une fenêtre de ce programme, sur ce fil ; la procédure ne garde aucune donnée
    existe(h) && unsafe { SetWindowSubclass(hwnd(h), Some(taille_minimale), SOUS_CLASSE_TAILLE, 0) }.as_bool()
}

unsafe extern "system" fn taille_minimale(
    h: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _sous_classe: usize,
    _donnees: usize,
) -> LRESULT {
    if message == WM_WINDOWPOSCHANGING && lparam.0 != 0 {
        // SAFETY : pour WM_WINDOWPOSCHANGING, lparam est un WINDOWPOS modifiable pendant l'appel
        let (pos, style) = unsafe { (&mut *(lparam.0 as *mut WINDOWPOS), GetWindowLongPtrW(h, GWL_STYLE) as u32) };
        if !pos.flags.contains(SWP_NOSIZE) && style & (WS_CHILD.0 | WS_MINIMIZE.0) == 0 {
            let mut mm = MINMAXINFO::default();
            // SAFETY : la fenêtre de ce fil (appel direct) ; mm vit pendant l'appel
            unsafe { SendMessageW(h, WM_GETMINMAXINFO, None, Some(LPARAM(&mut mm as *mut MINMAXINFO as isize))) };
            pos.cx = pos.cx.max(mm.ptMinTrackSize.x);
            pos.cy = pos.cy.max(mm.ptMinTrackSize.y);
        }
    }
    // SAFETY : le message tel que reçu, au suivant de la chaîne
    unsafe { DefSubclassProc(h, message, wparam, lparam) }
}

/// La couleur de la barre de titre (`DWMWA_CAPTION_COLOR`, Windows 11), écrite « 0x00BBGGRR » comme le faisait
/// `[MSNative]::SetDarkTitleBar` (interface.ps1:70-74). Sans effet sur Windows 10 (la barre reste sombre).
pub fn couleur_barre(h: usize, (r, g, b): (u8, u8, u8)) -> bool {
    use windows::Win32::Graphics::Dwm::{DWMWA_CAPTION_COLOR, DwmSetWindowAttribute};
    if !existe(h) {
        return false;
    }
    let couleur: u32 = u32::from(r) | (u32::from(g) << 8) | (u32::from(b) << 16);
    // SAFETY : une fenêtre de ce programme ; la valeur est une variable locale de 4 octets, lue pendant l'appel
    unsafe {
        DwmSetWindowAttribute(
            hwnd(h),
            DWMWA_CAPTION_COLOR,
            &couleur as *const u32 as *const core::ffi::c_void,
            std::mem::size_of::<u32>() as u32,
        )
        .is_ok()
    }
}
