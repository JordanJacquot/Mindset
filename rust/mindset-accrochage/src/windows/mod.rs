//! Le seul module du bloc qui parle à Windows, et le seul où le code « unsafe » est permis (chaque bloc a son
//! commentaire SAFETY) : le vrai port [`crate::Fenetres`], c'est-à-dire `MSIntegration` (natif.cs:36-137) plus le
//! panneau de chaque appli.
//!
//! **Le panneau.** La version PowerShell accrochait l'appli dans un `Panel` Windows Forms (une vraie fenêtre de
//! Mindset). Ici, un panneau noir (classe « MindsetAccrochage ») est créé dans la fenêtre Tauri de Mindset, par un fil
//! à nous qui ne fait que tourner sa boucle de messages : le fil des blocs n'en a pas, et une fenêtre sans boucle
//! bloquerait le clavier de Mindset et de l'appli (Windows relie leurs files de saisie). L'appli devient l'enfant du
//! panneau ; cacher l'appli, c'est cacher le panneau (son drapeau `WS_VISIBLE` à elle ne change pas, comme avant).
//!
//! **Le piège du 26/10** (plan-rust-2026-10-26.md, essai 2) : sans rien de plus, l'appli accrochée est dessinée SOUS
//! la page (WebView2, fenêtre enfant `WRY_WEBVIEW` qui couvre tout). À chaque fois que le panneau est montré : la
//! fenêtre de Mindset prend `WS_CLIPCHILDREN`, chacun de ses enfants directs (la page, les panneaux) `WS_CLIPSIBLINGS`,
//! le panneau passe devant (`HWND_TOP`), puis tout est redessiné (`RedrawWindow` avec `RDW_ALLCHILDREN`).
//!
//! **Ne jamais rester bloqué par une appli** : ce qui touche la fenêtre d'une appli (un autre programme) se fait depuis
//! le fil des blocs, avec `SWP_ASYNCWINDOWPOS` pour les tailles, `PostMessage` pour `WM_CLOSE`, et une appli qui ne
//! répond pas (`SendMessageTimeout`, 1 s) n'est pas accrochée tant qu'elle ne répond pas.

#![allow(unsafe_code)]

use std::sync::Mutex;
use std::sync::mpsc;

use windows::Win32::Foundation::{FILETIME, HWND, LPARAM, LRESULT, WIN32_ERROR, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BLACK_BRUSH, GetStockObject, HBRUSH, RDW_ALLCHILDREN, RDW_ERASE, RDW_FRAME, RDW_INVALIDATE, RedrawWindow,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::StationsAndDesktops::{GetThreadDesktop, HDESK, SetThreadDesktop};
use windows::Win32::System::SystemInformation::GetSystemTimeAsFileTime;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, EnumWindows, GW_CHILD, GW_HWNDNEXT, GW_OWNER,
    GWL_EXSTYLE, GWL_STYLE, GetClassNameW, GetMessageW, GetParent, GetPropW, GetWindow, GetWindowLongPtrW,
    GetWindowTextW, GetWindowThreadProcessId, HWND_MESSAGE, HWND_TOP, IsIconic, IsWindow, IsZoomed, MSG, PostMessageW,
    PostQuitMessage, RegisterClassW, SMTO_ABORTIFHUNG, SMTO_BLOCK, SMTO_NORMAL, SW_HIDE, SW_RESTORE,
    SWP_ASYNCWINDOWPOS, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SWP_SHOWWINDOW,
    SendMessageTimeoutW, SetParent, SetWindowLongPtrW, SetWindowPos, ShowWindow, TranslateMessage, WINDOW_EX_STYLE,
    WM_APP, WM_CLOSE, WM_NULL, WM_SETFOCUS, WNDCLASSW, WS_CHILD, WS_CLIPCHILDREN, WS_CLIPSIBLINGS,
    WS_EX_NOPARENTNOTIFY,
};
use windows::core::{BOOL, w};

use crate::fenetres::{Fenetres, Styles, Zone};

fn hwnd(h: isize) -> HWND {
    HWND(h as *mut core::ffi::c_void)
}

// Les styles retirés et ajoutés par `Accrocher` (natif.cs:54-56)
const WS_POPUP: i64 = 0x8000_0000;
const WS_CAPTION: i64 = 0x00C0_0000;
const WS_THICKFRAME: i64 = 0x0004_0000;
const WS_SYSMENU: i64 = 0x0008_0000;
const WS_MINIMIZEBOX: i64 = 0x0002_0000;
const WS_MAXIMIZEBOX: i64 = 0x0001_0000;
const WS_VISIBLE: i64 = 0x1000_0000;
const WS_CHILD_L: i64 = 0x4000_0000;
const WS_EX_APPWINDOW: i64 = 0x0004_0000;
const WS_EX_WINDOWEDGE: i64 = 0x100;
const WS_EX_DLGMODALFRAME: i64 = 0x1;
const WS_EX_CLIENTEDGE: i64 = 0x200;
const WS_EX_STATICEDGE: i64 = 0x2_0000;

/// Les messages du fil des panneaux.
const CREER: u32 = WM_APP + 1;
const FOCUS: u32 = WM_APP + 2;
const FIN: u32 = WM_APP + 3;

/// Le fil des panneaux : sa fenêtre à messages (`HWND_MESSAGE`).
#[derive(Debug, Default)]
struct Fil {
    boite: isize,
}

/// Le vrai Windows de l'accrochage.
#[derive(Debug, Default)]
pub struct FenetresWindows {
    fil: Mutex<Fil>,
}

impl FenetresWindows {
    pub fn nouveau() -> FenetresWindows {
        FenetresWindows::default()
    }

    /// La fenêtre à messages du fil des panneaux, le fil démarré la première fois (sur le même bureau Windows que le
    /// fil qui le demande).
    fn boite(&self) -> Option<isize> {
        let mut f = self.fil.lock().unwrap_or_else(|e| e.into_inner());
        if f.boite != 0 && existe(f.boite) {
            return Some(f.boite);
        }
        // SAFETY : lecture du bureau de ce fil (handle non possédé, rien à fermer)
        let bureau = unsafe { GetThreadDesktop(GetCurrentThreadId()) }.ok().map(|d| d.0 as isize);
        let (envoi, recu) = mpsc::channel();
        let fil = std::thread::Builder::new().name("accrochage-panneaux".into()).spawn(move || boucle(bureau, envoi));
        if fil.is_err() {
            return None;
        }
        let b = recu.recv_timeout(std::time::Duration::from_secs(5)).ok().filter(|b| *b != 0)?;
        f.boite = b;
        Some(b)
    }
}

/// Le fil des panneaux : ses classes, sa fenêtre à messages, puis sa boucle jusqu'à `FIN`.
fn boucle(bureau: Option<isize>, envoi: mpsc::Sender<isize>) {
    // SAFETY : ce fil neuf n'a encore aucune fenêtre ; le bureau est celui du fil demandeur
    unsafe {
        if let Some(b) = bureau {
            let _ = SetThreadDesktop(HDESK(b as *mut core::ffi::c_void));
        }
    }
    // SAFETY : classes de ce programme, textes constants, procédures de ce module
    let boite = unsafe {
        let instance = GetModuleHandleW(None).map(|m| m.into()).unwrap_or_default();
        let panneau = WNDCLASSW {
            lpfnWndProc: Some(proc_panneau),
            hInstance: instance,
            hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
            lpszClassName: w!("MindsetAccrochage"),
            ..Default::default()
        };
        let boite = WNDCLASSW {
            lpfnWndProc: Some(proc_boite),
            hInstance: instance,
            lpszClassName: w!("MindsetAccrochageBoite"),
            ..Default::default()
        };
        // (déjà enregistrées par un fil d'avant : RegisterClassW refuse, les classes restent bonnes)
        RegisterClassW(&panneau);
        RegisterClassW(&boite);
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("MindsetAccrochageBoite"),
            w!(""),
            Default::default(),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            Some(instance),
            None,
        )
    };
    let Ok(boite) = boite else {
        let _ = envoi.send(0);
        return;
    };
    let _ = envoi.send(boite.0 as isize);
    let mut m = MSG::default();
    // SAFETY : la boucle de messages de ce fil
    unsafe {
        while GetMessageW(&mut m, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }
}

/// La fenêtre à messages : crée un panneau (dans la fenêtre donnée), donne le focus, finit le fil.
unsafe extern "system" fn proc_boite(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        CREER => {
            // SAFETY : la fenêtre parente est celle de Mindset (vérifiée par l'appelant) ; classe de ce module
            let p = unsafe {
                CreateWindowExW(
                    WS_EX_NOPARENTNOTIFY,
                    w!("MindsetAccrochage"),
                    w!(""),
                    WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                    0,
                    0,
                    0,
                    0,
                    Some(hwnd(wp.0 as isize)),
                    None,
                    GetModuleHandleW(None).ok().map(|m| m.into()),
                    None,
                )
            };
            LRESULT(p.map_or(0, |p| p.0 as isize))
        }
        FOCUS => {
            // (ce fil est relié à celui de l'appli, dont la fenêtre est l'enfant d'un de ses panneaux : SetFocus marche)
            // SAFETY : une fenêtre vérifiée juste avant ; un refus ne fait rien
            unsafe {
                if IsWindow(Some(hwnd(wp.0 as isize))).as_bool() {
                    let _ = SetFocus(Some(hwnd(wp.0 as isize)));
                }
            }
            LRESULT(0)
        }
        FIN => {
            // SAFETY : la fenêtre à messages de ce fil ; ses panneaux s'en vont avec le fil
            unsafe {
                let _ = DestroyWindow(h);
                PostQuitMessage(0);
            }
            LRESULT(0)
        }
        // SAFETY : traitement par défaut
        _ => unsafe { DefWindowProcW(h, msg, wp, lp) },
    }
}

/// Le panneau : noir ; le focus qu'il reçoit va à l'appli qu'il tient.
unsafe extern "system" fn proc_panneau(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_SETFOCUS {
        // SAFETY : l'enfant du panneau, s'il y en a un
        unsafe {
            if let Ok(enfant) = GetWindow(h, GW_CHILD) {
                let _ = SetFocus(Some(enfant));
            }
        }
        return LRESULT(0);
    }
    // SAFETY : traitement par défaut
    unsafe { DefWindowProcW(h, msg, wp, lp) }
}

fn existe(h: isize) -> bool {
    // SAFETY : lecture seule
    h != 0 && unsafe { IsWindow(Some(hwnd(h))) }.as_bool()
}

fn style(h: isize) -> i64 {
    // SAFETY : lecture seule
    unsafe { GetWindowLongPtrW(hwnd(h), GWL_STYLE) as i64 }
}

fn ex(h: isize) -> i64 {
    // SAFETY : lecture seule
    unsafe { GetWindowLongPtrW(hwnd(h), GWL_EXSTYLE) as i64 }
}

fn texte(n: u16, f: impl FnOnce(&mut [u16]) -> i32) -> String {
    let mut b = vec![0u16; usize::from(n)];
    let l = f(&mut b).clamp(0, i32::from(n)) as usize;
    String::from_utf16_lossy(&b[..l])
}

/// Ajoute un style s'il manque (`WS_CLIPCHILDREN`, `WS_CLIPSIBLINGS`).
fn ajouter_style(h: isize, s: i64) {
    let a = style(h);
    if a & s != s {
        // SAFETY : une fenêtre de Mindset (la principale ou un de ses enfants directs)
        unsafe {
            SetWindowLongPtrW(hwnd(h), GWL_STYLE, (a | s) as isize);
        }
    }
}

struct Releve {
    pid: u32,
    fenetres: Vec<isize>,
}

unsafe extern "system" fn chaque_fenetre(h: HWND, l: LPARAM) -> BOOL {
    // SAFETY : l est l'adresse du `Releve` de `trouver`, vivant pendant EnumWindows
    let r = unsafe { &mut *(l.0 as *mut Releve) };
    let mut pid = 0u32;
    // SAFETY : lecture seule
    unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
    if pid == r.pid {
        r.fenetres.push(h.0 as isize);
    }
    BOOL(1)
}

impl Fenetres for FenetresWindows {
    fn maintenant(&self) -> u64 {
        // SAFETY : lecture de l'heure
        let FILETIME { dwLowDateTime: b, dwHighDateTime: h } = unsafe { GetSystemTimeAsFileTime() };
        (u64::from(h) << 32) | u64::from(b)
    }

    fn trouver(&self, pid: u32, titre: &str) -> Option<isize> {
        let mut r = Releve { pid, fenetres: Vec::new() };
        // SAFETY : la procédure ne garde rien ; r vit pendant l'appel
        let _ = unsafe { EnumWindows(Some(chaque_fenetre), LPARAM(&mut r as *mut Releve as isize)) };
        r.fenetres.into_iter().find(|&h| {
            // SAFETY : lectures seules (titre et classe sans message envoyé à l'appli)
            let possedee = unsafe { GetWindow(hwnd(h), GW_OWNER) }.is_ok_and(|o| !o.is_invalid());
            // SAFETY : idem, tampons de 256
            let t = texte(256, |b| unsafe { GetWindowTextW(hwnd(h), b) });
            // SAFETY : idem
            let c = texte(256, |b| unsafe { GetClassNameW(hwnd(h), b) });
            crate::fenetres::convient(pid, titre, pid, possedee, &t, &c)
        })
    }

    fn existe(&self, h: isize) -> bool {
        existe(h)
    }

    fn processus(&self, h: isize) -> u32 {
        let mut pid = 0u32;
        // SAFETY : lecture seule
        unsafe { GetWindowThreadProcessId(hwnd(h), Some(&mut pid)) };
        pid
    }

    fn repond(&self, h: isize) -> bool {
        let mut r = 0usize;
        // SAFETY : un message vide, rendu en moins d'une seconde ou abandonné
        let ok = unsafe {
            SendMessageTimeoutW(
                hwnd(h),
                WM_NULL,
                WPARAM(0),
                LPARAM(0),
                SMTO_ABORTIFHUNG | SMTO_BLOCK,
                1000,
                Some(&mut r),
            )
        };
        ok.0 != 0
    }

    fn hote(&self, _id: &str, parent: isize) -> Option<isize> {
        if !existe(parent) {
            return None;
        }
        let b = self.boite()?;
        let mut r = 0usize;
        // SAFETY : la fenêtre à messages de notre fil, qui tourne sa boucle ; 3 s au plus
        let ok = unsafe {
            SendMessageTimeoutW(hwnd(b), CREER, WPARAM(parent as usize), LPARAM(0), SMTO_NORMAL, 3000, Some(&mut r))
        };
        (ok.0 != 0 && r != 0).then_some(r as isize)
    }

    fn placer_hote(&self, hote: isize, zone: Zone, visible: bool) {
        if !existe(hote) {
            return;
        }
        if !visible || !zone.utilisable() {
            // SAFETY : notre panneau
            unsafe {
                let _ = ShowWindow(hwnd(hote), SW_HIDE);
            }
            return;
        }
        // SAFETY : la fenêtre de Mindset, parent du panneau
        let Ok(parent) = (unsafe { GetParent(hwnd(hote)) }) else { return };
        let parent = parent.0 as isize;
        ajouter_style(parent, i64::from(WS_CLIPCHILDREN.0));
        // SAFETY : les enfants directs de la fenêtre de Mindset, un par un
        let mut enfant = unsafe { GetWindow(hwnd(parent), GW_CHILD) }.map_or(0, |e| e.0 as isize);
        let mut n = 0;
        while enfant != 0 && n < 64 {
            ajouter_style(enfant, i64::from(WS_CLIPSIBLINGS.0));
            // SAFETY : idem
            enfant = unsafe { GetWindow(hwnd(enfant), GW_HWNDNEXT) }.map_or(0, |e| e.0 as isize);
            n += 1;
        }
        // SAFETY : notre panneau, devant la page, à la place de la zone ; puis la fenêtre de Mindset redessinée
        unsafe {
            let _ = SetWindowPos(
                hwnd(hote),
                Some(HWND_TOP),
                zone.x,
                zone.y,
                zone.largeur,
                zone.hauteur,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
            let _ =
                RedrawWindow(Some(hwnd(parent)), None, None, RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN);
        }
    }

    fn accrocher(&self, h: isize, hote: isize, largeur: i32, hauteur: i32) -> Option<Styles> {
        let style = style(h);
        let ex = ex(h);
        let nouveau = (style & !(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX))
            | WS_CHILD_L
            | WS_VISIBLE;
        let nouveau_ex =
            ex & !(WS_EX_APPWINDOW | WS_EX_WINDOWEDGE | WS_EX_DLGMODALFRAME | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE);
        // SAFETY : la fenêtre principale de l'appli (trouvée par son processus, son titre et sa classe) et notre panneau
        unsafe {
            // (ni réduite, ni agrandie ; une fenêtre cachée en taille normale n'est pas montrée hors de Mindset : voir
            // DIVERGENCES.md)
            if IsIconic(hwnd(h)).as_bool() || IsZoomed(hwnd(h)).as_bool() {
                let _ = ShowWindow(hwnd(h), SW_RESTORE);
            }
            SetWindowLongPtrW(hwnd(h), GWL_STYLE, nouveau as isize);
            SetWindowLongPtrW(hwnd(h), GWL_EXSTYLE, nouveau_ex as isize);
            windows::Win32::Foundation::SetLastError(WIN32_ERROR(0));
            if let Err(e) = SetParent(hwnd(h), Some(hwnd(hote)))
                && e.code().is_err()
            {
                SetWindowLongPtrW(hwnd(h), GWL_STYLE, style as isize);
                SetWindowLongPtrW(hwnd(h), GWL_EXSTYLE, ex as isize);
                return None;
            }
            let _ = SetWindowPos(
                hwnd(h),
                None,
                0,
                0,
                largeur,
                hauteur,
                SWP_NOZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW | SWP_ASYNCWINDOWPOS,
            );
        }
        Some(Styles { style, ex })
    }

    fn redimensionner(&self, h: isize, largeur: i32, hauteur: i32) {
        // SAFETY : la fenêtre accrochée ; sans attendre l'appli
        unsafe {
            let _ =
                SetWindowPos(hwnd(h), None, 0, 0, largeur, hauteur, SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
        }
    }

    fn est_montree(&self, h: isize) -> bool {
        style(h) & WS_VISIBLE != 0
    }

    fn barre_propre(&self, h: isize) -> bool {
        // SAFETY : lecture d'une propriété (aucune mémoire derrière)
        h != 0 && !unsafe { GetPropW(hwnd(h), w!("Mindset.BarrePropre")) }.0.is_null()
    }

    fn fermer(&self, h: isize) {
        // SAFETY : un message posté, sans attendre
        unsafe {
            let _ = PostMessageW(Some(hwnd(h)), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
    }

    fn liberer(&self, h: isize, styles: Styles) {
        if !existe(h) {
            return;
        }
        // SAFETY : la fenêtre accrochée, rendue telle qu'elle était, cachée
        unsafe {
            let _ = ShowWindow(hwnd(h), SW_HIDE);
            let _ = SetParent(hwnd(h), None);
            SetWindowLongPtrW(hwnd(h), GWL_STYLE, (styles.style & !WS_VISIBLE) as isize);
            SetWindowLongPtrW(hwnd(h), GWL_EXSTYLE, styles.ex as isize);
            let _ = SetWindowPos(
                hwnd(h),
                None,
                0,
                0,
                0,
                0,
                SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS,
            );
        }
    }

    fn focus(&self, h: isize) {
        let b = self.fil.lock().unwrap_or_else(|e| e.into_inner()).boite;
        if b != 0 {
            // SAFETY : un message posté à notre fil
            unsafe {
                let _ = PostMessageW(Some(hwnd(b)), FOCUS, WPARAM(h as usize), LPARAM(0));
            }
        }
    }

    fn fin(&self) {
        let mut f = self.fil.lock().unwrap_or_else(|e| e.into_inner());
        if f.boite != 0 {
            // SAFETY : un message posté à notre fil, qui s'arrête
            unsafe {
                let _ = PostMessageW(Some(hwnd(f.boite)), FIN, WPARAM(0), LPARAM(0));
            }
            f.boite = 0;
        }
    }
}

impl Drop for FenetresWindows {
    fn drop(&mut self) {
        self.fin();
    }
}

#[cfg(test)]
mod tests;
