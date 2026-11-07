//! Sur de vraies fenêtres Windows créées sur un BUREAU WINDOWS À PART (CreateDesktop, propre au fil du test) : même
//! montrées, elles n'apparaissent jamais à l'écran. Une « fenêtre de Mindset » (avec sa page, une fenêtre enfant qui la
//! couvre), et des « applis » des deux sortes (classe `HwndWrapper[...]` comme WPF, « Tauri Window » comme Tauri).

use super::*;
use windows::Win32::Foundation::{GENERIC_ALL, HANDLE, RECT};
use windows::Win32::System::StationsAndDesktops::{CloseDesktop, CreateDesktopW, DESKTOP_CONTROL_FLAGS};
use windows::Win32::UI::WindowsAndMessaging::{
    GetClientRect, PM_REMOVE, PeekMessageW, SetPropW, WINDOW_STYLE, WS_CAPTION as WS_CAPTION_W, WS_OVERLAPPEDWINDOW,
    WS_VISIBLE as WS_VISIBLE_W,
};
use windows::core::{HSTRING, PCWSTR};

unsafe extern "system" fn proc_essai(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    // SAFETY : traitement par défaut
    unsafe { DefWindowProcW(h, msg, wp, lp) }
}

fn classe(nom: &str) {
    let n = HSTRING::from(nom);
    let c = WNDCLASSW { lpfnWndProc: Some(proc_essai), lpszClassName: PCWSTR(n.as_ptr()), ..Default::default() };
    // SAFETY : classe de ce test (déjà là : refus sans effet) ; le nom est copié par Windows
    unsafe { RegisterClassW(&c) };
}

fn creer(classe: &str, titre: &str, style: WINDOW_STYLE, parent: Option<isize>, proprietaire: Option<isize>) -> isize {
    let c = HSTRING::from(classe);
    let t = HSTRING::from(titre);
    let p = parent.or(proprietaire).map(hwnd);
    // SAFETY : classes de ce test ; la fenêtre est détruite à la fin
    unsafe { CreateWindowExW(WINDOW_EX_STYLE(0), &c, &t, style, 10, 10, 400, 300, p, None, None, None) }
        .expect("fenêtre d'essai")
        .0 as isize
}

fn detruire(h: isize) {
    // SAFETY : une fenêtre d'essai de ce fil
    unsafe {
        let _ = DestroyWindow(hwnd(h));
    }
}

/// Les messages de ce fil (les tailles demandées sans attendre arrivent ainsi).
fn pomper() {
    for _ in 0..20 {
        let mut m = MSG::default();
        // SAFETY : la file de ce fil
        unsafe {
            while PeekMessageW(&mut m, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&m);
                DispatchMessageW(&m);
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

fn taille(h: isize) -> (i32, i32) {
    let mut r = RECT::default();
    // SAFETY : lecture seule
    let _ = unsafe { GetClientRect(hwnd(h), &mut r) };
    (r.right - r.left, r.bottom - r.top)
}

fn parent(h: isize) -> isize {
    // SAFETY : lecture seule
    unsafe { GetParent(hwnd(h)) }.map_or(0, |p| p.0 as isize)
}

fn sur_un_bureau_a_part(essai: impl FnOnce() + Send + 'static) {
    std::thread::spawn(move || {
        static NUMERO: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NUMERO.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let nom = HSTRING::from(format!("MindsetEssai-{}-accrochage-{n}", std::process::id()));
        // SAFETY : nom valide ; bureau neuf, jamais affiché
        let bureau =
            unsafe { CreateDesktopW(&nom, PCWSTR::null(), None, DESKTOP_CONTROL_FLAGS(0), GENERIC_ALL.0, None) }
                .expect("bureau d'essai");
        // SAFETY : ce fil n'a encore aucune fenêtre ; il revient à son bureau avant de fermer celui d'essai
        unsafe {
            let avant = GetThreadDesktop(GetCurrentThreadId()).expect("bureau du fil");
            SetThreadDesktop(bureau).expect("passer sur le bureau d'essai");
            essai();
            SetThreadDesktop(avant).expect("revenir au bureau d'avant");
            let _ = CloseDesktop(bureau);
        }
    })
    .join()
    .expect("essai sur le bureau à part");
}

#[test]
fn trouver_la_fenetre_principale_des_deux_sortes() {
    sur_un_bureau_a_part(|| {
        classe("HwndWrapper[essai.exe;;5e1f]");
        classe("Tauri Window");
        classe("Chrome_WidgetWin_1");
        let moi = std::process::id();
        let f = FenetresWindows::nouveau();
        let navigateur = creer("Chrome_WidgetWin_1", "Forêt", WS_OVERLAPPEDWINDOW, None, None);
        let wpf = creer("HwndWrapper[essai.exe;;5e1f]", "Forêt", WS_OVERLAPPEDWINDOW, None, None);
        let alerte = creer("Tauri Window", "Café crème", WS_OVERLAPPEDWINDOW, None, Some(wpf));
        assert_eq!(f.trouver(moi, "Forêt"), Some(wpf), "la WPF, pas l'autre classe");
        assert_eq!(f.trouver(moi, "Café crème"), None, "une fenêtre possédée est écartée");
        let tauri = creer("Tauri Window", "Café crème", WS_OVERLAPPEDWINDOW, None, None);
        assert_eq!(f.trouver(moi, "Café crème"), Some(tauri));
        assert_eq!(f.trouver(moi, "café crème"), None, "titre exact");
        assert_eq!(f.trouver(moi + 1, "Café crème"), None, "un autre processus");
        assert_eq!(f.processus(tauri), moi);
        assert!(f.repond(tauri), "ce fil tourne : il répond");
        for h in [alerte, tauri, wpf, navigateur] {
            detruire(h);
        }
        assert!(!f.existe(tauri));
    });
}

#[test]
fn accrocher_dans_le_panneau_par_dessus_la_page_puis_rendre() {
    sur_un_bureau_a_part(|| {
        classe("Tauri Window");
        classe("WRY_WEBVIEW");
        classe("HwndWrapper[essai.exe;;77]");
        let f = FenetresWindows::nouveau();
        let mindset = creer("Tauri Window", "Mindset", WS_OVERLAPPEDWINDOW | WS_VISIBLE_W, None, None);
        let page = creer("WRY_WEBVIEW", "", WS_CHILD | WS_VISIBLE_W, Some(mindset), None);
        let appli = creer("HwndWrapper[essai.exe;;77]", "Forêt", WS_OVERLAPPEDWINDOW, None, None);
        let avant = Styles { style: style(appli), ex: ex(appli) };

        let hote = f.hote("foret", mindset).expect("panneau créé");
        assert_eq!(parent(hote), mindset);
        assert_eq!(f.hote("foret", 0), None, "jamais sans fenêtre de Mindset");
        let zone = Zone { x: 210, y: 60, largeur: 320, hauteur: 180, visible: true };
        f.placer_hote(hote, zone, true);
        assert!(style(mindset) & i64::from(WS_CLIPCHILDREN.0) != 0, "Mindset : WS_CLIPCHILDREN");
        assert!(style(page) & i64::from(WS_CLIPSIBLINGS.0) != 0, "la page : WS_CLIPSIBLINGS (essai du 26/10)");
        assert!(style(hote) & WS_VISIBLE != 0);
        // SAFETY : lecture seule
        let premier = unsafe { GetWindow(hwnd(mindset), GW_CHILD) }.map_or(0, |e| e.0 as isize);
        assert_eq!(premier, hote, "le panneau est devant la page");
        assert_eq!(taille(hote), (320, 180));

        let s = f.accrocher(appli, hote, 320, 180).expect("Windows accepte");
        assert_eq!(s, avant, "ses styles d'avant");
        pomper();
        assert_eq!(parent(appli), hote);
        assert!(style(appli) & WS_CHILD_L != 0 && style(appli) & i64::from(WS_CAPTION_W.0) == 0, "sans barre de titre");
        assert!(f.est_montree(appli));
        assert_eq!(taille(appli), (320, 180));
        f.redimensionner(appli, 300, 150);
        pomper();
        assert_eq!(taille(appli), (300, 150));

        assert!(!f.barre_propre(appli));
        // SAFETY : une propriété entière sur une fenêtre d'essai
        unsafe {
            let _ = SetPropW(hwnd(appli), w!("Mindset.BarrePropre"), Some(HANDLE(std::ptr::dangling_mut())));
        }
        assert!(f.barre_propre(appli));

        // Le voile : le panneau se cache, l'appli garde son drapeau à elle
        f.placer_hote(hote, zone, false);
        assert!(style(hote) & WS_VISIBLE == 0);
        assert!(f.est_montree(appli), "cachée avec son panneau, pas par elle-même");
        f.placer_hote(hote, Zone { largeur: 0, ..zone }, true);
        assert!(style(hote) & WS_VISIBLE == 0, "une zone sans taille (Mindset réduit) ne montre rien");

        f.liberer(appli, s);
        pomper();
        assert_eq!(parent(appli), 0, "rendue au bureau");
        assert!(!f.est_montree(appli), "rendue cachée");
        assert_eq!(style(appli) & !WS_VISIBLE, avant.style & !WS_VISIBLE, "ses styles d'avant");
        assert_eq!(ex(appli), avant.ex);
        f.liberer(appli, s);
        assert!(f.maintenant() > 134_000_000_000_000_000);

        f.fin();
        pomper();
        detruire(appli);
        detruire(mindset);
    });
}

#[test]
fn accrochage_refuse_quand_le_panneau_n_existe_pas() {
    sur_un_bureau_a_part(|| {
        classe("Tauri Window");
        let f = FenetresWindows::nouveau();
        let appli = creer("Tauri Window", "Forêt", WS_OVERLAPPEDWINDOW, None, None);
        let avant = style(appli);
        assert_eq!(f.accrocher(appli, 0x7FFF_FFF0, 200, 200), None, "SetParent refusé");
        assert_eq!(style(appli), avant, "ses styles sont remis");
        detruire(appli);
    });
}
