//! La fenêtre « Désinstaller Mindset » : une question, une case (décochée), puis le bilan. Mêmes textes, même ordre et
//! mêmes boutons que la version C# (Windows Forms), faits ici avec les contrôles de Windows.
//!
//! Le travail tourne sur un fil à part ; il prévient la fenêtre par des messages (étape en cours, fin).

use std::sync::{Arc, Mutex};

use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, CreateFontW, CreateSolidBrush, DEFAULT_CHARSET, DT_CALCRECT,
    DT_EDITCONTROL, DT_NOPREFIX, DT_WORDBREAK, DeleteObject, DrawTextW, FF_DONTCARE, FW_BOLD, FW_NORMAL, GetDC,
    GetDeviceCaps, HBRUSH, HDC, HFONT, HGDIOBJ, InvalidateRect, LOGPIXELSY, OUT_DEFAULT_PRECIS, ReleaseDC,
    SelectObject, SetBkColor, SetTextColor,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{
    ICC_PROGRESS_CLASS, ICC_STANDARD_CLASSES, INITCOMMONCONTROLSEX, InitCommonControlsEx,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetFocus, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::{
    AdjustWindowRectEx, BM_GETCHECK, BM_SETCHECK, BN_CLICKED, BS_AUTOCHECKBOX, BS_PUSHBUTTON, CS_HREDRAW, CS_VREDRAW,
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, ES_AUTOVSCROLL, ES_MULTILINE, ES_READONLY,
    GWLP_USERDATA, GetMessageW, GetSystemMetrics, GetWindowLongPtrW, HICON, HMENU, IDC_ARROW, IMAGE_ICON,
    IsDialogMessageW, KillTimer, LR_DEFAULTCOLOR, LoadCursorW, LoadImageW, MSG, MoveWindow, PostMessageW,
    PostQuitMessage, RegisterClassExW, SM_CXICON, SM_CXSMICON, SPI_GETWORKAREA, SW_HIDE, SW_SHOW, SW_SHOWNOACTIVATE,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SendMessageW, SetForegroundWindow, SetTimer, SetWindowLongPtrW,
    SetWindowTextW, ShowWindow, SystemParametersInfoW, TranslateMessage, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP,
    WM_CLOSE, WM_COMMAND, WM_CTLCOLORSTATIC, WM_DESTROY, WM_SETFONT, WM_SETICON, WM_TIMER, WNDCLASSEXW, WS_CAPTION,
    WS_CHILD, WS_CLIPCHILDREN, WS_EX_CONTROLPARENT, WS_EX_DLGMODALFRAME, WS_EX_TOOLWINDOW, WS_OVERLAPPED, WS_SYSMENU,
    WS_TABSTOP, WS_VISIBLE, WS_VSCROLL,
};
use windows::core::{HSTRING, PCWSTR, w};

use crate::fin::{VuFenetre, texte_accueil, texte_bilan};
use crate::travail::Travail;

/// Ce que la fenêtre rend à la fin
pub struct ResultatFenetre {
    pub annule: bool,
    pub donnees_demandees: bool,
    pub texte_affiche: String,
    pub vu: VuFenetre,
}

const ID_OUI: i32 = 101;
const ID_NON: i32 = 102;
const ID_FERMER: i32 = 103;
const ID_CASE: i32 = 104;
const IDOK: i32 = 1;
const IDCANCEL: i32 = 2;
const MSG_ETAPE: u32 = WM_APP + 1;
const MSG_FINI: u32 = WM_APP + 2;
const MSG_DEMARRER: u32 = WM_APP + 3;
const MINUTERIE_FERMER: usize = 1;
const PBM_SETMARQUEE: u32 = 0x0400 + 10;
const PBS_MARQUEE: u32 = 0x08;
const SS_LEFT: u32 = 0x0;
const SS_NOPREFIX: u32 = 0x80;

struct Etat {
    fenetre: HWND,
    titre: HWND,
    texte: HWND,
    case: HWND,
    attention: HWND,
    etape: HWND,
    barre: HWND,
    bilan: HWND,
    oui: HWND,
    non: HWND,
    fermer: HWND,
    police: HFONT,
    police_titre: HFONT,
    blanc: HBRUSH,
    dpi: i32,
    essai: i32,
    travail: Arc<Mutex<Travail<'static>>>,
    etape_texte: Arc<Mutex<String>>,
    fil: Option<std::thread::JoinHandle<()>>,
    en_cours: bool,
    annule: bool,
    donnees: bool,
    bilan_grand: bool,
    texte_affiche: String,
    vu: VuFenetre,
}

impl Etat {
    /// Une taille donnée pour un écran à 100 %, à l'échelle de cet écran
    fn s(&self, v: i32) -> i32 {
        v * self.dpi / 96
    }
}

fn texte_de(h: HWND) -> String {
    let mut b = vec![0u16; 8192];
    // SAFETY : tampon et taille cohérents
    let n = unsafe { windows::Win32::UI::WindowsAndMessaging::GetWindowTextW(h, &mut b) } as usize;
    String::from_utf16_lossy(&b[..n.min(b.len())])
}

fn ecrire(h: HWND, t: &str) {
    // SAFETY : texte terminé par un zéro
    unsafe {
        let _ = SetWindowTextW(h, &HSTRING::from(t));
    }
}

fn montrer(h: HWND, oui: bool) {
    // SAFETY : simple changement de visibilité
    unsafe {
        let _ = ShowWindow(h, if oui { SW_SHOW } else { SW_HIDE });
    }
}

fn visible(h: HWND) -> bool {
    // SAFETY : simple lecture
    unsafe { windows::Win32::UI::WindowsAndMessaging::IsWindowVisible(h).as_bool() }
}

fn cochee(h: HWND) -> bool {
    // SAFETY : message d'une case à cocher
    unsafe { SendMessageW(h, BM_GETCHECK, None, None).0 == 1 }
}

/// La taille d'un texte dans une police : (largeur, hauteur), coupé à `largeur_max` (0 : sur une ligne)
fn mesurer(police: HFONT, texte: &str, largeur_max: i32) -> (i32, i32) {
    let mut t: Vec<u16> = texte.encode_utf16().collect();
    if t.is_empty() {
        t.push(u16::from(b' '));
    }
    // SAFETY : contexte d'affichage de l'écran, rendu à la fin ; police remise comme avant
    unsafe {
        let dc: HDC = GetDC(None);
        let avant = SelectObject(dc, HGDIOBJ(police.0));
        let mut r = RECT { left: 0, top: 0, right: if largeur_max > 0 { largeur_max } else { 10_000 }, bottom: 0 };
        let drapeaux = DT_CALCRECT
            | DT_NOPREFIX
            | if largeur_max > 0 { DT_WORDBREAK | DT_EDITCONTROL } else { Default::default() };
        DrawTextW(dc, &mut t, &mut r, drapeaux);
        SelectObject(dc, avant);
        ReleaseDC(None, dc);
        (r.right - r.left, r.bottom - r.top)
    }
}

/// Place les contrôles visibles les uns sous les autres (comme le FlowLayoutPanel de la version C#)
fn disposer(e: &Etat) {
    let x0 = e.s(22);
    let largeur = e.s(510);
    let mut y = e.s(18);
    let place = |h: HWND, x: i32, y: i32, w: i32, hh: i32| {
        // SAFETY : déplacement d'un contrôle de cette fenêtre
        unsafe {
            let _ = MoveWindow(h, x, y, w, hh, true);
        }
    };
    let (w, h) = mesurer(e.police_titre, &texte_de(e.titre), 0);
    place(e.titre, x0, y, w + e.s(4), h);
    y += h + e.s(10);
    let (_, h) = mesurer(e.police, &texte_de(e.texte), largeur);
    place(e.texte, x0, y, largeur, h);
    y += h + e.s(14);
    if visible(e.case) {
        let (w, h) = mesurer(e.police, &texte_de(e.case), 0);
        let hh = h.max(e.s(17)) + e.s(4);
        place(e.case, x0, y, (w + e.s(24)).min(largeur), hh);
        y += hh + e.s(4);
    }
    if visible(e.attention) {
        let (w, h) = mesurer(e.police, &texte_de(e.attention), 0);
        place(e.attention, x0 + e.s(18), y, w + e.s(4), h);
        y += h;
    }
    if visible(e.etape) {
        y += e.s(6);
        let (_, h) = mesurer(e.police, &texte_de(e.etape), largeur);
        place(e.etape, x0, y, largeur, h);
        y += h + e.s(8);
    }
    if visible(e.barre) {
        y += e.s(3);
        place(e.barre, x0, y, largeur, e.s(14));
        y += e.s(14) + e.s(3);
    }
    if visible(e.bilan) {
        y += e.s(3);
        let h = e.s(if e.bilan_grand { 250 } else { 170 });
        place(e.bilan, x0, y, largeur, h);
        y += h + e.s(3);
    }
    // Les boutons, de droite à gauche : Fermer (à la fin), Annuler, Désinstaller
    y += e.s(18) + e.s(3);
    let mut droite = x0 + largeur;
    for b in [e.fermer, e.non, e.oui] {
        if !visible(b) {
            continue;
        }
        let (w, _) = mesurer(e.police, &texte_de(b), 0);
        let bw = (w + e.s(24)).max(e.s(110));
        droite -= e.s(3);
        place(b, droite - bw, y, bw, e.s(32));
        droite -= bw + e.s(3);
    }
    // SAFETY : redessin de cette fenêtre
    unsafe {
        let _ = InvalidateRect(Some(e.fenetre), None, true);
    }
}

/// Le texte d'accueil suit la case
fn case_changee(e: &mut Etat) {
    let c = cochee(e.case);
    montrer(e.attention, c);
    ecrire(e.texte, &texte_accueil(c));
    disposer(e);
}

/// « Désinstaller » : le travail commence, sur un fil à part
fn lancer(e: &mut Etat) {
    if e.en_cours || e.fil.is_some() {
        return;
    }
    e.annule = false;
    e.en_cours = true;
    e.donnees = cochee(e.case);
    e.vu.accueil_au_lancement = texte_de(e.texte);
    for h in [e.case, e.attention, e.oui, e.non] {
        montrer(h, false);
    }
    ecrire(
        e.texte,
        "Mindset est en train d'être retiré. Si une appli ouvre son propre désinstalleur, suis ses étapes.",
    );
    montrer(e.etape, true);
    montrer(e.barre, true);
    // SAFETY : message d'une barre de progression de cette fenêtre
    unsafe {
        SendMessageW(e.barre, PBM_SETMARQUEE, Some(WPARAM(1)), Some(LPARAM(30)));
    }
    disposer(e);
    let fenetre = e.fenetre.0 as isize;
    let etape = Arc::clone(&e.etape_texte);
    let travail = Arc::clone(&e.travail);
    let donnees = e.donnees;
    {
        let mut t = travail.lock().unwrap_or_else(|p| p.into_inner());
        t.bilan.sur_etape = Some(Box::new(move |texte: &str| {
            *etape.lock().unwrap_or_else(|p| p.into_inner()) = texte.to_string();
            // SAFETY : simple message posté à la fenêtre (elle vit tant que le travail n'est pas fini)
            unsafe {
                let _ = PostMessageW(Some(HWND(fenetre as *mut _)), MSG_ETAPE, WPARAM(0), LPARAM(0));
            }
        }));
    }
    e.fil = Some(std::thread::spawn(move || {
        let mut t = travail.lock().unwrap_or_else(|p| p.into_inner());
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| t.executer(donnees)));
        if let Err(p) = r {
            let m = p
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| p.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "erreur inconnue".into());
            t.bilan.reste(format!("La désinstallation s'est arrêtée à cause d'une erreur : {m}"));
        }
        t.bilan.sur_etape = None;
        drop(t);
        // SAFETY : simple message posté à la fenêtre
        unsafe {
            let _ = PostMessageW(Some(HWND(fenetre as *mut _)), MSG_FINI, WPARAM(0), LPARAM(0));
        }
    }));
}

/// Le travail est fini : le bilan à la place de la question
fn fini(e: &mut Etat) {
    if let Some(f) = e.fil.take() {
        let _ = f.join();
    }
    e.en_cours = false;
    let (ok, alertes, texte) = {
        let t = e.travail.lock().unwrap_or_else(|p| p.into_inner());
        (t.bilan.restes.is_empty(), !t.bilan.alertes.is_empty(), texte_bilan(&t))
    };
    ecrire(e.titre, if ok { "Mindset est désinstallé" } else { "Désinstallation pas tout à fait finie" });
    montrer(e.etape, false);
    montrer(e.barre, false);
    e.texte_affiche = texte.clone();
    ecrire(
        e.texte,
        if ok {
            "C'est fini. Merci d'avoir utilisé Mindset !"
        } else {
            "Presque tout est retiré, mais il reste quelques éléments :"
        },
    );
    ecrire(e.bilan, &texte);
    montrer(e.bilan, true);
    // Des restes ou des choses à savoir : la fenêtre s'agrandit pour tout montrer
    if !ok || alertes {
        e.bilan_grand = true;
        taille_client(e.fenetre, e.s(560), e.s(450), e.essai >= 0);
    }
    montrer(e.fermer, true);
    disposer(e);
    // SAFETY : focus sur un bouton de cette fenêtre ; minuterie de cette fenêtre
    unsafe {
        let _ = SetFocus(Some(e.fermer));
        if e.essai >= 0 {
            SetTimer(Some(e.fenetre), MINUTERIE_FERMER, 300, None);
        }
    }
}

fn fermer(e: &Etat) {
    if e.en_cours {
        return; // (pas de fermeture au milieu)
    }
    // SAFETY : destruction de cette fenêtre (la boucle des messages s'arrête ensuite)
    unsafe {
        let _ = DestroyWindow(e.fenetre);
    }
}

const STYLE: WINDOW_STYLE = WINDOW_STYLE(WS_OVERLAPPED.0 | WS_CAPTION.0 | WS_SYSMENU.0 | WS_CLIPCHILDREN.0);

fn style_etendu(essai: bool) -> WINDOW_EX_STYLE {
    let mut s = WS_EX_DLGMODALFRAME.0 | WS_EX_CONTROLPARENT.0;
    if essai {
        s |= WS_EX_TOOLWINDOW.0; // (pas dans la barre des tâches)
    }
    WINDOW_EX_STYLE(s)
}

/// Change la taille de l'intérieur de la fenêtre, sans la déplacer
fn taille_client(h: HWND, l: i32, hh: i32, essai: bool) {
    let mut r = RECT { left: 0, top: 0, right: l, bottom: hh };
    let mut actuel = RECT::default();
    // SAFETY : rectangles locaux ; fenêtre de ce programme
    unsafe {
        let _ = AdjustWindowRectEx(&mut r, STYLE, false, style_etendu(essai));
        let _ = windows::Win32::UI::WindowsAndMessaging::GetWindowRect(h, &mut actuel);
        let _ = MoveWindow(h, actuel.left, actuel.top, r.right - r.left, r.bottom - r.top, true);
    }
}

fn etat<'a>(h: HWND) -> Option<&'a mut Etat> {
    // SAFETY : le pointeur rangé dans GWLP_USERDATA est celui de la boîte créée par `afficher`, qui vit jusqu'à la fin
    // de la boucle des messages ; seul le fil de la fenêtre s'en sert
    unsafe {
        let p = GetWindowLongPtrW(h, GWLP_USERDATA) as *mut Etat;
        p.as_mut()
    }
}

extern "system" fn procedure(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if let Some(e) = etat(h) {
        match msg {
            WM_COMMAND => {
                let id = (wp.0 & 0xFFFF) as i32;
                let code = ((wp.0 >> 16) & 0xFFFF) as u32;
                match id {
                    ID_CASE if code == BN_CLICKED => case_changee(e),
                    ID_OUI => lancer(e),
                    ID_NON | ID_FERMER | IDCANCEL => fermer(e),
                    IDOK => {
                        // Entrée : le bouton qui a le focus (au départ « Annuler » : Entrée par erreur = Annuler)
                        // SAFETY : simple lecture
                        let f = unsafe { GetFocus() };
                        if f == e.oui {
                            lancer(e);
                        } else if f != e.case {
                            fermer(e);
                        }
                    }
                    _ => {}
                }
                return LRESULT(0);
            }
            WM_CTLCOLORSTATIC => {
                // Fond blanc partout ; « Attention » en rouge
                let dc = HDC(wp.0 as *mut _);
                // SAFETY : contexte d'affichage donné par Windows pour ce message
                unsafe {
                    SetBkColor(dc, COLORREF(0x00FF_FFFF));
                    if lp.0 == e.attention.0 as isize {
                        SetTextColor(dc, COLORREF(0x0020_00B0));
                    }
                }
                return LRESULT(e.blanc.0 as isize);
            }
            MSG_ETAPE => {
                let t = e.etape_texte.lock().unwrap_or_else(|p| p.into_inner()).clone();
                ecrire(e.etape, &t);
                disposer(e);
                return LRESULT(0);
            }
            MSG_FINI => {
                fini(e);
                return LRESULT(0);
            }
            MSG_DEMARRER => {
                if e.essai == 1 {
                    // SAFETY : message d'une case à cocher de cette fenêtre
                    unsafe {
                        SendMessageW(e.case, BM_SETCHECK, Some(WPARAM(1)), None);
                    }
                    case_changee(e);
                }
                lancer(e);
                return LRESULT(0);
            }
            WM_TIMER if wp.0 == MINUTERIE_FERMER => {
                // SAFETY : minuterie de cette fenêtre
                unsafe {
                    let _ = KillTimer(Some(h), MINUTERIE_FERMER);
                }
                fermer(e);
                return LRESULT(0);
            }
            WM_CLOSE => {
                fermer(e);
                return LRESULT(0);
            }
            WM_DESTROY => {
                // SAFETY : fin de la boucle des messages
                unsafe { PostQuitMessage(0) };
                return LRESULT(0);
            }
            _ => {}
        }
    }
    // SAFETY : traitement par défaut de Windows
    unsafe { DefWindowProcW(h, msg, wp, lp) }
}

fn controle(
    parent: HWND,
    instance: HINSTANCE,
    classe: PCWSTR,
    texte: &str,
    style: u32,
    id: i32,
    police: HFONT,
) -> windows::core::Result<HWND> {
    // SAFETY : création d'un contrôle enfant de cette fenêtre, avec un texte terminé par un zéro
    unsafe {
        let h = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            classe,
            &HSTRING::from(texte),
            WINDOW_STYLE(WS_CHILD.0 | style),
            0,
            0,
            10,
            10,
            Some(parent),
            Some(HMENU(id as isize as *mut _)),
            Some(instance),
            None,
        )?;
        SendMessageW(h, WM_SETFONT, Some(WPARAM(police.0 as usize)), Some(LPARAM(1)));
        Ok(h)
    }
}

fn police(dpi: i32, points: i32, gras: bool) -> HFONT {
    // SAFETY : création d'une police, rendue à la fin par DeleteObject
    unsafe {
        CreateFontW(
            -(points * dpi / 72),
            0,
            0,
            0,
            if gras { FW_BOLD.0 as i32 } else { FW_NORMAL.0 as i32 },
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            FF_DONTCARE.0 as u32,
            w!("Segoe UI"),
        )
    }
}

/// Montre la fenêtre et attend qu'elle soit fermée. `essai` : -1 normal ; 0 ou 1 (construction d'essai) : hors de
/// l'écran, sans prendre la main, la case laissée (0) ou cochée (1), puis « Désinstaller » se clique seul.
pub fn afficher(travail: Arc<Mutex<Travail<'static>>>, essai: i32) -> Result<ResultatFenetre, String> {
    // SAFETY : création de la fenêtre et de ses contrôles par le fil principal, puis boucle des messages ; l'état est
    // une boîte rangée dans la fenêtre et reprise après la boucle (plus aucun message ne s'en sert alors)
    unsafe {
        let icc = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES,
        };
        let _ = InitCommonControlsEx(&icc);
        let instance: HINSTANCE = GetModuleHandleW(None).map_err(|e| e.message())?.into();
        let dc = GetDC(None);
        let dpi = GetDeviceCaps(Some(dc), LOGPIXELSY).max(96);
        ReleaseDC(None, dc);
        let grande = LoadImageW(
            Some(instance),
            PCWSTR(1 as _),
            IMAGE_ICON,
            GetSystemMetrics(SM_CXICON),
            GetSystemMetrics(SM_CXICON),
            LR_DEFAULTCOLOR,
        )
        .map(|h| HICON(h.0))
        .unwrap_or_default();
        let petite = LoadImageW(
            Some(instance),
            PCWSTR(1 as _),
            IMAGE_ICON,
            GetSystemMetrics(SM_CXSMICON),
            GetSystemMetrics(SM_CXSMICON),
            LR_DEFAULTCOLOR,
        )
        .map(|h| HICON(h.0))
        .unwrap_or_default();
        let blanc = CreateSolidBrush(COLORREF(0x00FF_FFFF));
        let classe = w!("MindsetDesinstalleur");
        let wc = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(procedure),
            hInstance: instance,
            hIcon: grande,
            hIconSm: petite,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: blanc,
            lpszClassName: classe,
            ..Default::default()
        };
        RegisterClassExW(&wc);

        let essai_ = essai >= 0;
        let (l, hh) = (560 * dpi / 96, 330 * dpi / 96);
        let mut r = RECT { left: 0, top: 0, right: l, bottom: hh };
        let _ = AdjustWindowRectEx(&mut r, STYLE, false, style_etendu(essai_));
        let (fw, fh) = (r.right - r.left, r.bottom - r.top);
        let (x, y) = if essai_ {
            (-10_000, -10_000) // (essai automatique : hors de l'écran)
        } else {
            let mut zone = RECT::default();
            let _ = SystemParametersInfoW(
                SPI_GETWORKAREA,
                0,
                Some((&mut zone as *mut RECT).cast()),
                SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
            );
            (zone.left + (zone.right - zone.left - fw) / 2, zone.top + (zone.bottom - zone.top - fh) / 2)
        };
        let fenetre = CreateWindowExW(
            style_etendu(essai_),
            classe,
            w!("Désinstaller Mindset"),
            STYLE,
            x,
            y,
            fw,
            fh,
            None,
            None,
            Some(instance),
            None,
        )
        .map_err(|e| e.message())?;
        if !grande.is_invalid() {
            SendMessageW(fenetre, WM_SETICON, Some(WPARAM(1)), Some(LPARAM(grande.0 as isize)));
        }
        if !petite.is_invalid() {
            SendMessageW(fenetre, WM_SETICON, Some(WPARAM(0)), Some(LPARAM(petite.0 as isize)));
        }
        let p = police(dpi, 10, false);
        let pt = police(dpi, 15, true);
        let statique = w!("STATIC");
        let bouton = w!("BUTTON");
        let st = SS_LEFT | SS_NOPREFIX;
        let titre = controle(fenetre, instance, statique, "Désinstaller Mindset", WS_VISIBLE.0 | st, 0, pt);
        let texte = controle(fenetre, instance, statique, &texte_accueil(false), WS_VISIBLE.0 | st, 0, p);
        let case = controle(
            fenetre,
            instance,
            bouton,
            "Supprimer aussi mes données (réglages, rendez-vous, sauvegardes)",
            WS_VISIBLE.0 | WS_TABSTOP.0 | BS_AUTOCHECKBOX as u32,
            ID_CASE,
            p,
        );
        let attention =
            controle(fenetre, instance, statique, "Attention : tes données seront effacées pour de bon.", st, 0, p);
        let etape = controle(fenetre, instance, statique, "", st, 0, p);
        let barre = controle(fenetre, instance, w!("msctls_progress32"), "", PBS_MARQUEE, 0, p);
        let bilan = controle(
            fenetre,
            instance,
            w!("EDIT"),
            "",
            WS_VSCROLL.0 | ES_MULTILINE as u32 | ES_READONLY as u32 | ES_AUTOVSCROLL as u32,
            0,
            p,
        );
        // (ordre des tabulations : Désinstaller, Annuler, Fermer)
        let oui = controle(
            fenetre,
            instance,
            bouton,
            "Désinstaller",
            WS_VISIBLE.0 | WS_TABSTOP.0 | BS_PUSHBUTTON as u32,
            ID_OUI,
            p,
        );
        let non = controle(
            fenetre,
            instance,
            bouton,
            "Annuler",
            WS_VISIBLE.0 | WS_TABSTOP.0 | BS_PUSHBUTTON as u32,
            ID_NON,
            p,
        );
        let fermer_b = controle(fenetre, instance, bouton, "Fermer", WS_TABSTOP.0 | BS_PUSHBUTTON as u32, ID_FERMER, p);
        let (
            Ok(titre),
            Ok(texte),
            Ok(case),
            Ok(attention),
            Ok(etape),
            Ok(barre),
            Ok(bilan),
            Ok(oui),
            Ok(non),
            Ok(fermer_b),
        ) = (titre, texte, case, attention, etape, barre, bilan, oui, non, fermer_b)
        else {
            let _ = DestroyWindow(fenetre);
            return Err("les contrôles de la fenêtre n'ont pas pu être créés".into());
        };
        let accueil = texte_de(texte);
        let etat = Box::new(Etat {
            fenetre,
            titre,
            texte,
            case,
            attention,
            etape,
            barre,
            bilan,
            oui,
            non,
            fermer: fermer_b,
            police: p,
            police_titre: pt,
            blanc,
            dpi,
            essai,
            travail,
            etape_texte: Arc::new(Mutex::new(String::new())),
            fil: None,
            en_cours: false,
            annule: true,
            donnees: false,
            bilan_grand: false,
            texte_affiche: String::new(),
            vu: VuFenetre { case_au_depart: false, accueil_au_depart: accueil, accueil_au_lancement: String::new() },
        });
        let brut = Box::into_raw(etat);
        SetWindowLongPtrW(fenetre, GWLP_USERDATA, brut as isize);
        disposer(&*brut);
        if essai_ {
            let _ = ShowWindow(fenetre, SW_SHOWNOACTIVATE); // (sans prendre la main)
            let _ = PostMessageW(Some(fenetre), MSG_DEMARRER, WPARAM(0), LPARAM(0));
        } else {
            let _ = ShowWindow(fenetre, SW_SHOW);
            let _ = SetForegroundWindow(fenetre);
            let _ = SetFocus(Some(non)); // (Entrée par erreur = Annuler)
        }

        let mut m = MSG::default();
        while GetMessageW(&mut m, None, 0, 0).as_bool() {
            if !IsDialogMessageW(fenetre, &m).as_bool() {
                let _ = TranslateMessage(&m);
                DispatchMessageW(&m);
            }
        }
        let etat = Box::from_raw(brut);
        let _ = DeleteObject(HGDIOBJ(etat.police.0));
        let _ = DeleteObject(HGDIOBJ(etat.police_titre.0));
        let _ = DeleteObject(HGDIOBJ(etat.blanc.0));
        Ok(ResultatFenetre {
            annule: etat.annule,
            donnees_demandees: etat.donnees,
            texte_affiche: etat.texte_affiche.clone(),
            vu: etat.vu.clone(),
        })
    }
}
