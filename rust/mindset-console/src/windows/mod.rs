//! Le seul module du bloc console qui parle à Windows, et le seul où le code « unsafe » est permis : trouver la
//! fenêtre principale d'une appli qui démarre (`[MSIntegration]::Trouver`, natif.cs:61-74), pour savoir quand la
//! console peut plonger dans l'écran (`Find-FenetreAppli`, integration.ps1:35). Rien n'est changé : les fenêtres sont
//! seulement lues.

#![allow(unsafe_code)]

use windows::Win32::Foundation::{HWND, LPARAM};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GW_OWNER, GetClassNameW, GetWindow, GetWindowTextW, GetWindowThreadProcessId,
};
use windows::core::BOOL;

struct Recherche {
    pid: u32,
    titre: String,
    trouvee: bool,
}

fn texte(t: &[u16], n: i32) -> String {
    String::from_utf16_lossy(&t[..n.clamp(0, t.len() as i32) as usize])
}

unsafe extern "system" fn chaque(h: HWND, l: LPARAM) -> BOOL {
    // SAFETY : `l` est l'adresse de la `Recherche` donnée à EnumWindows ci-dessous, vivante pendant tout l'appel.
    let r = unsafe { &mut *(l.0 as *mut Recherche) };
    let mut p = 0u32;
    // SAFETY : `h` vient d'EnumWindows ; `p` est un entier local.
    unsafe { GetWindowThreadProcessId(h, Some(&mut p)) };
    // SAFETY : simple lecture du propriétaire de la fenêtre.
    let proprietaire = unsafe { GetWindow(h, GW_OWNER) }.unwrap_or_default();
    if p != r.pid || !proprietaire.is_invalid() {
        return BOOL(1);
    }
    let mut t = [0u16; 256];
    let mut c = [0u16; 256];
    // SAFETY : les tampons sont locaux, de la taille donnée.
    let nt = unsafe { GetWindowTextW(h, &mut t) };
    // SAFETY : idem.
    let nc = unsafe { GetClassNameW(h, &mut c) };
    let classe = texte(&c, nc);
    if texte(&t, nt) == r.titre && (classe.starts_with("HwndWrapper") || classe == "Tauri Window") {
        r.trouvee = true;
        return BOOL(0);
    }
    BOOL(1)
}

/// Le programme `pid` a-t-il une fenêtre principale (sans propriétaire) de ce titre, faite par WPF ou par Tauri ?
pub fn fenetre_trouvee(pid: u32, titre: &str) -> bool {
    let mut r = Recherche { pid, titre: titre.to_string(), trouvee: false };
    // SAFETY : `chaque` ne garde pas le pointeur après l'appel ; `r` vit jusqu'à la fin de cette fonction.
    let _ = unsafe { EnumWindows(Some(chaque), LPARAM(&mut r as *mut Recherche as isize)) };
    r.trouvee
}

#[cfg(test)]
mod tests {
    #[test]
    fn aucun_programme_n_a_de_fenetre_au_pid_zero() {
        // (lecture seule des fenêtres ouvertes : rien n'est touché)
        assert!(!super::fenetre_trouvee(0, "Aucune fenêtre de ce nom"));
    }
}
