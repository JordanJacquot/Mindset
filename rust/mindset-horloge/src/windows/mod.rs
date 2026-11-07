//! La vraie icône près de l'horloge (le seul module du bloc qui parle à Windows, et le seul où le code « unsafe »
//! est permis, chaque appel avec son commentaire SAFETY).
//!
//! Comme le `NotifyIcon` de Windows Forms (zone.ps1:33-46) : `Shell_NotifyIconW` sur son propre fil, avec une
//! fenêtre de messages jamais montrée (pas `HWND_MESSAGE` : elle ne recevrait pas « TaskbarCreated », envoyé à
//! toutes les fenêtres quand l'Explorateur redémarre, et l'icône serait perdue). Le texte au survol « Mindset »,
//! l'icône de `fichiers\Mindset.ico` (sinon celle des applications de Windows). Un clic gauche (relâché, pas le
//! second d'un double clic) : `Clic` ; un clic droit : le menu (natif, le choix en gras par `SetMenuDefaultItem`) ;
//! un clic sur la bulle : `BulleCliquee` ; la bulle fermée ou partie toute seule : `BulleFermee`.
//!
//! Le bloc parle au fil par une file et `PostMessageW` ; le fil lui rend les gestes par une autre file, lue dans
//! `tic`. Rien ici ne touche une fenêtre d'un autre programme.

#![allow(unsafe_code)]

use std::cell::RefCell;
use std::collections::VecDeque;
use std::path::Path;
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use windows::Win32::Foundation::{HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::StationsAndDesktops::{GetThreadDesktop, GetUserObjectInformationW, UOI_NAME};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_INFO, NIIF_NONE, NIIF_WARNING, NIM_ADD, NIM_DELETE, NIM_MODIFY,
    NIN_BALLOONHIDE, NIN_BALLOONTIMEOUT, NIN_BALLOONUSERCLICK, NOTIFYICONDATAW, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, ChangeWindowMessageFilterEx, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyIcon,
    DestroyMenu, DestroyWindow, DispatchMessageW, EndMenu, GetCursorPos, GetMessageW, GetSystemMetrics, HICON,
    IDI_APPLICATION, IMAGE_ICON, IsWindow, IsWindowVisible, LR_LOADFROMFILE, LoadIconW, LoadImageW, MF_SEPARATOR,
    MF_STRING, MSG, MSGFLT_ALLOW, PostMessageW, PostQuitMessage, RegisterClassW, RegisterWindowMessageW, SM_CXSCREEN,
    SM_CXSMICON, SM_CYSCREEN, SM_CYSMICON, SetForegroundWindow, SetMenuDefaultItem, TPM_BOTTOMALIGN, TPM_LEFTALIGN,
    TPM_NONOTIFY, TPM_RETURNCMD, TPM_RIGHTALIGN, TPM_RIGHTBUTTON, TPM_TOPALIGN, TrackPopupMenu, TranslateMessage,
    WINDOW_EX_STYLE, WM_APP, WM_DESTROY, WM_LBUTTONDBLCLK, WM_LBUTTONUP, WM_NULL, WM_RBUTTONUP, WNDCLASSW,
    WS_EX_TOOLWINDOW, WS_POPUP,
};
use windows::core::{HSTRING, PCWSTR, w};

use crate::icone::{Dessin, Geste, Icone, Ligne};

/// Le message de l'icône vers sa fenêtre (celui de Windows Forms : WM_USER + 1024 ; ici une valeur de WM_APP).
const RAPPEL: u32 = WM_APP + 1;
/// Le bloc a déposé une demande dans la file.
const DEMANDE: u32 = WM_APP + 2;
/// Le numéro de l'icône (une seule par fenêtre).
const NUMERO: u32 = 1;

enum Demande {
    Bulle { duree_ms: u32, titre: String, texte: String, dessin: Dessin },
    Retirer,
}

#[derive(Default)]
struct Partage {
    demandes: VecDeque<Demande>,
    gestes: Vec<Geste>,
    menu: Vec<Ligne>,
    ajoutee: bool,
}

fn verrou<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// La vraie icône près de l'horloge.
pub struct IconeWindows {
    partage: Arc<Mutex<Partage>>,
    fenetre: isize,
    fini: Mutex<Option<mpsc::Receiver<()>>>,
}

impl IconeWindows {
    /// Crée l'icône (son fil, sa fenêtre de messages, `NIM_ADD`). Une icône que l'Explorateur n'a pas encore pu
    /// prendre (Mindset lancé avec Windows avant la barre des tâches) est ajoutée à « TaskbarCreated ».
    pub fn creer(ico: &Path) -> Result<IconeWindows, String> {
        let partage = Arc::new(Mutex::new(Partage::default()));
        let p = Arc::clone(&partage);
        let ico = ico.to_path_buf();
        let (pret, attendre) = mpsc::channel::<Result<isize, String>>();
        let (fin, fini) = mpsc::channel::<()>();
        std::thread::Builder::new()
            .name("horloge-icone".into())
            .spawn(move || {
                fil(&ico, p, pret);
                let _ = fin.send(());
            })
            .map_err(|e| e.to_string())?;
        let fenetre = attendre
            .recv_timeout(Duration::from_secs(5))
            .map_err(|_| "le fil de l'icône ne répond pas".to_string())??;
        Ok(IconeWindows { partage, fenetre, fini: Mutex::new(Some(fini)) })
    }

    fn deposer(&self, d: Demande) {
        verrou(&self.partage).demandes.push_back(d);
        // SAFETY : la fenêtre appartient au fil de l'icône ; PostMessageW se contente de déposer un message (sans
        // effet si la fenêtre n'existe plus).
        let _ = unsafe { PostMessageW(Some(hwnd(self.fenetre)), DEMANDE, WPARAM(0), LPARAM(0)) };
    }

    /// L'Explorateur a-t-il pris l'icône (`NIM_ADD` réussi) ? Faux sur un bureau à part (pas de barre des tâches).
    pub fn ajoutee(&self) -> bool {
        verrou(&self.partage).ajoutee
    }

    /// La fenêtre de messages existe-t-elle encore ?
    pub fn fenetre_existe(&self) -> bool {
        // SAFETY : simple question sur une fenêtre (un numéro périmé rend faux).
        unsafe { IsWindow(Some(hwnd(self.fenetre))).as_bool() }
    }

    /// La fenêtre de messages est-elle montrée ? (Jamais : c'est vérifié par l'essai.)
    pub fn fenetre_montree(&self) -> bool {
        // SAFETY : simple question sur une fenêtre.
        unsafe { IsWindowVisible(hwnd(self.fenetre)).as_bool() }
    }

    /// Essai seulement : un message de l'icône (`WM_LBUTTONUP`, `NIN_BALLOONUSERCLICK`...) comme s'il venait de
    /// l'Explorateur.
    #[doc(hidden)]
    pub fn simuler(&self, souris: u32) {
        // SAFETY : un message déposé à notre propre fenêtre.
        let _ =
            unsafe { PostMessageW(Some(hwnd(self.fenetre)), RAPPEL, WPARAM(NUMERO as usize), LPARAM(souris as isize)) };
    }
}

impl Icone for IconeWindows {
    fn bulle(&self, duree_ms: u32, titre: &str, texte: &str, dessin: Dessin) {
        self.deposer(Demande::Bulle { duree_ms, titre: titre.into(), texte: texte.into(), dessin });
    }
    fn menu(&self, lignes: &[Ligne]) {
        verrou(&self.partage).menu = lignes.to_vec();
    }
    fn gestes(&self) -> Vec<Geste> {
        std::mem::take(&mut verrou(&self.partage).gestes)
    }
    fn retirer(&self) {
        let Some(fini) = verrou(&self.fini).take() else { return };
        self.deposer(Demande::Retirer);
        let _ = fini.recv_timeout(Duration::from_secs(3));
    }
}

impl Drop for IconeWindows {
    fn drop(&mut self) {
        self.retirer();
    }
}

fn hwnd(h: isize) -> HWND {
    HWND(h as *mut core::ffi::c_void)
}

/// Mindset tourne-t-il sur un bureau Windows à part (pas « Default », celui de l'écran) ? La construction d'essai ne
/// crée l'icône que là (sur un bureau à part, il n'y a pas de barre des tâches : rien n'apparaît).
pub fn bureau_a_part() -> bool {
    let mut nom = [0u16; 256];
    let mut taille = 0u32;
    // SAFETY : GetThreadDesktop rend le bureau du fil courant (pas à fermer) ; le tampon fait 512 octets, sa taille
    // est donnée à GetUserObjectInformationW, qui n'écrit pas au-delà.
    let lu = unsafe {
        GetThreadDesktop(GetCurrentThreadId()).and_then(|b| {
            GetUserObjectInformationW(
                HANDLE(b.0),
                UOI_NAME,
                Some(nom.as_mut_ptr().cast()),
                (nom.len() * 2) as u32,
                Some(&mut taille),
            )
        })
    };
    if lu.is_err() {
        return false;
    }
    let n = nom.iter().position(|&c| c == 0).unwrap_or(nom.len());
    let nom = String::from_utf16_lossy(&nom[..n]);
    !nom.is_empty() && !nom.eq_ignore_ascii_case("Default")
}

// -------------------------------------------------------------------------------------------------------------------
// Le fil de l'icône
// -------------------------------------------------------------------------------------------------------------------

struct Fil {
    partage: Arc<Mutex<Partage>>,
    icone: HICON,
    icone_chargee: bool,
    barre_creee: u32,
    double_clic: bool,
}

thread_local! {
    static FIL: RefCell<Option<Fil>> = const { RefCell::new(None) };
}

fn copier(dans: &mut [u16], texte: &str) {
    // (au plus la place moins le zéro final, sans couper une paire de demi-caractères)
    let mut u: Vec<u16> = texte.encode_utf16().collect();
    let max = dans.len() - 1;
    if u.len() > max {
        u.truncate(max);
        if u.last().is_some_and(|&c| (0xD800..0xDC00).contains(&c)) {
            u.pop();
        }
    }
    dans[..u.len()].copy_from_slice(&u);
    dans[u.len()] = 0;
}

fn donnees(fenetre: HWND) -> NOTIFYICONDATAW {
    NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: fenetre,
        uID: NUMERO,
        ..Default::default()
    }
}

fn ajouter(fenetre: HWND, icone: HICON) -> bool {
    let mut d = donnees(fenetre);
    d.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    d.uCallbackMessage = RAPPEL;
    d.hIcon = icone;
    copier(&mut d.szTip, "Mindset");
    // SAFETY : la structure est complète (cbSize posé) et vit pendant l'appel.
    unsafe { Shell_NotifyIconW(NIM_ADD, &d).as_bool() }
}

fn fil(ico: &Path, partage: Arc<Mutex<Partage>>, pret: mpsc::Sender<Result<isize, String>>) {
    // SAFETY : appels de création classiques sur ce fil ; les chaînes passées vivent pendant les appels ; la fenêtre
    // est une fenêtre surgissante JAMAIS montrée (ni WS_VISIBLE, ni ShowWindow), absente de la barre des tâches.
    let fenetre = unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None).map(|m| HINSTANCE(m.0)).unwrap_or_default();
        let classe = WNDCLASSW {
            lpfnWndProc: Some(procedure),
            hInstance: instance,
            lpszClassName: w!("MindsetHorloge"),
            ..Default::default()
        };
        // (déjà inscrite par une icône précédente du même programme : sans importance)
        let _ = RegisterClassW(&classe);
        CreateWindowExW(
            WINDOW_EX_STYLE(WS_EX_TOOLWINDOW.0),
            w!("MindsetHorloge"),
            w!("Mindset près de l'horloge"),
            WS_POPUP,
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance),
            None,
        )
    };
    let fenetre = match fenetre {
        Ok(f) => f,
        Err(e) => {
            let _ = pret.send(Err(format!("fenêtre de l'icône impossible ({e})")));
            return;
        }
    };
    // L'icône : Mindset.ico à la taille des petites icônes, sinon celle des applications (SystemIcons.Application)
    // SAFETY : chargement d'une image depuis un fichier (chemin en HSTRING, vivant pendant l'appel) ou d'une icône
    // de Windows ; la première est rendue à la fin (DestroyIcon), la seconde est partagée (jamais rendue).
    let (icone, chargee) = unsafe {
        let cx = GetSystemMetrics(SM_CXSMICON);
        let cy = GetSystemMetrics(SM_CYSMICON);
        match LoadImageW(None, &HSTRING::from(ico.as_os_str()), IMAGE_ICON, cx, cy, LR_LOADFROMFILE) {
            Ok(h) if !h.is_invalid() => (HICON(h.0), true),
            _ => (LoadIconW(None, IDI_APPLICATION).unwrap_or_default(), false),
        }
    };
    // « TaskbarCreated » : l'Explorateur a redémarré (ou vient de démarrer), l'icône est remise. Permis aussi quand
    // Mindset a les droits administrateur (sinon Windows filtre ce message venu de l'Explorateur).
    // SAFETY : inscription d'un nom de message, filtre posé sur notre propre fenêtre.
    let barre_creee = unsafe {
        let m = RegisterWindowMessageW(w!("TaskbarCreated"));
        if m != 0 {
            let _ = ChangeWindowMessageFilterEx(fenetre, m, MSGFLT_ALLOW, None);
        }
        m
    };
    FIL.with(|f| {
        *f.borrow_mut() = Some(Fil { partage, icone, icone_chargee: chargee, barre_creee, double_clic: false });
    });
    let pris = ajouter(fenetre, icone);
    if let Some(p) = avec(|f| Arc::clone(&f.partage)) {
        verrou(&p).ajoutee = pris;
    }
    let _ = pret.send(Ok(fenetre.0 as isize));
    let mut msg = MSG::default();
    // SAFETY : la boucle de messages du fil ; GetMessageW rend 0 à WM_QUIT, -1 en cas d'erreur.
    unsafe {
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    FIL.with(|f| {
        if let Some(e) = f.borrow_mut().take()
            && e.icone_chargee
        {
            // SAFETY : l'icône chargée depuis le fichier, plus utilisée (l'icône près de l'horloge est retirée).
            let _ = unsafe { DestroyIcon(e.icone) };
        }
    });
}

extern "system" fn procedure(fenetre: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        RAPPEL => {
            let quoi = (lp.0 as u32) & 0xFFFF;
            match quoi {
                WM_LBUTTONDBLCLK => {
                    avec(|f| f.double_clic = true);
                }
                WM_LBUTTONUP => {
                    // (Windows Forms : le relâchement qui suit un double clic n'est pas un clic)
                    let double = avec(|f| std::mem::replace(&mut f.double_clic, false)).unwrap_or(false);
                    if !double {
                        geste(Geste::Clic);
                    }
                }
                WM_RBUTTONUP => montrer_menu(fenetre),
                NIN_BALLOONUSERCLICK => geste(Geste::BulleCliquee),
                NIN_BALLOONTIMEOUT | NIN_BALLOONHIDE => geste(Geste::BulleFermee),
                _ => {}
            }
            LRESULT(0)
        }
        DEMANDE => {
            demandes(fenetre);
            LRESULT(0)
        }
        WM_DESTROY => {
            // SAFETY : fin de la boucle de messages de ce fil.
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        _ => {
            let barre = avec(|f| f.barre_creee).unwrap_or(0);
            if barre != 0 && msg == barre {
                if let Some((i, p)) = avec(|f| (f.icone, Arc::clone(&f.partage))) {
                    let pris = ajouter(fenetre, i);
                    verrou(&p).ajoutee = pris;
                }
                return LRESULT(0);
            }
            // SAFETY : le traitement par défaut de Windows.
            unsafe { DefWindowProcW(fenetre, msg, wp, lp) }
        }
    }
}

/// Un accès court à l'état du fil (jamais gardé pendant un appel qui fait tourner les messages, comme le menu).
fn avec<R>(f: impl FnOnce(&mut Fil) -> R) -> Option<R> {
    FIL.with(|x| x.try_borrow_mut().ok().and_then(|mut b| b.as_mut().map(f)))
}

fn geste(g: Geste) {
    if let Some(p) = avec(|f| Arc::clone(&f.partage)) {
        verrou(&p).gestes.push(g);
    }
}

fn demandes(fenetre: HWND) {
    let Some(p) = avec(|f| Arc::clone(&f.partage)) else { return };
    let liste: Vec<Demande> = verrou(&p).demandes.drain(..).collect();
    for d in liste {
        match d {
            Demande::Bulle { duree_ms, titre, texte, dessin } => {
                let mut n = donnees(fenetre);
                n.uFlags = NIF_INFO;
                n.Anonymous.uTimeout = duree_ms;
                copier(&mut n.szInfoTitle, &titre);
                copier(&mut n.szInfo, &texte);
                n.dwInfoFlags = match dessin {
                    Dessin::Info => NIIF_INFO,
                    Dessin::Attention => NIIF_WARNING,
                    Dessin::Aucun => NIIF_NONE,
                };
                // SAFETY : la structure est complète et vit pendant l'appel.
                let _ = unsafe { Shell_NotifyIconW(NIM_MODIFY, &n) };
            }
            Demande::Retirer => {
                let n = donnees(fenetre);
                // SAFETY : retrait de notre icône, puis destruction de notre propre fenêtre (fin du fil) ; un menu
                // encore ouvert est refermé d'abord.
                unsafe {
                    let _ = EndMenu();
                    let _ = Shell_NotifyIconW(NIM_DELETE, &n);
                    let _ = DestroyWindow(fenetre);
                }
                return;
            }
        }
    }
}

/// Le menu du clic droit, refait à chaque ouverture depuis les lignes données par le bloc (`Update-MenuHorloge`).
fn montrer_menu(fenetre: HWND) {
    let Some(p) = avec(|f| Arc::clone(&f.partage)) else { return };
    let lignes = verrou(&p).menu.clone();
    if lignes.is_empty() {
        return;
    }
    let mut textes: Vec<HSTRING> = Vec::new();
    // SAFETY : un menu surgissant créé, rempli (les textes en HSTRING vivent jusqu'à sa destruction), montré à la
    // souris et détruit ici ; SetForegroundWindow sur notre propre fenêtre (sans elle, le menu ne se referme pas
    // quand on clique ailleurs), puis WM_NULL comme le recommande Windows.
    let choisi = unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        for (k, l) in lignes.iter().enumerate() {
            match l {
                Ligne::Separateur => {
                    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
                }
                Ligne::Choix { texte, gras, .. } => {
                    textes.push(HSTRING::from(texte.as_str()));
                    let t = textes.last().map(|h| PCWSTR(h.as_ptr())).unwrap_or(PCWSTR::null());
                    let _ = AppendMenuW(menu, MF_STRING, k + 1, t);
                    if *gras {
                        let _ = SetMenuDefaultItem(menu, (k + 1) as u32, 0);
                    }
                }
            }
        }
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        // (vers le haut et la gauche près d'une barre des tâches en bas à droite, comme ContextMenuStrip.ShowInTaskbar)
        let h = if pt.y > GetSystemMetrics(SM_CYSCREEN) / 2 { TPM_BOTTOMALIGN } else { TPM_TOPALIGN };
        let l = if pt.x > GetSystemMetrics(SM_CXSCREEN) / 2 { TPM_RIGHTALIGN } else { TPM_LEFTALIGN };
        let _ = SetForegroundWindow(fenetre);
        let r = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY | h | l,
            pt.x,
            pt.y,
            None,
            fenetre,
            None,
        );
        let _ = PostMessageW(Some(fenetre), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);
        r.0
    };
    drop(textes);
    if choisi <= 0 {
        return;
    }
    if let Some(Ligne::Choix { choix, .. }) = lignes.get(choisi as usize - 1) {
        geste(Geste::Menu(choix.clone()));
    }
}
