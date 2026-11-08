//! Essai RÉEL de l'audit M3 (08/11/2026) : une appli accrochée qui se fige peut-elle bloquer le fil des blocs de
//! Mindset (`liberer`, `accrocher`, et Mindset qui quitte) ?
//!
//! À lancer SEULEMENT par `outils\essai-figee.ps1`, lui-même lancé sur un BUREAU WINDOWS À PART (`sur-bureau.ps1`) :
//! le programme refuse de tourner sur le bureau de l'écran (« Default »).
//!
//!   essai_figee mesure      : la fausse fenêtre de Mindset, le vrai port Windows et le vrai bloc ; il lance la fausse
//!                             appli (ce même programme, `essai_figee appli`), sur ce bureau, sans console ;
//!   essai_figee appli       : la fausse appli : une fenêtre « Tauri Window » nommée « Figée », cachée, dans un AUTRE
//!                             processus, qui se fige sur demande (elle cesse de traiter ses messages).
//!
//! Mesures : la durée de `repond`, `liberer` et `accrocher` quand l'appli est figée, et celle des deux chemins du
//! bloc (l'appli se range elle-même puis travaille, comme Nevermind qui quitte ; Mindset quitte avec une appli figée).

#![allow(unsafe_code)]

use std::time::{Duration, Instant};

use mindset_accrochage::windows::FenetresWindows;
use mindset_accrochage::{BlocAccrochage, Fenetres, Zone};
use mindset_noyau::{Appli, Bloc, Effets, essai, partage};
use serde_json::json;

use windows::Win32::Foundation::{HANDLE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::StationsAndDesktops::{GetThreadDesktop, GetUserObjectInformationW, UOI_NAME};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, GetParent, MSG, PostMessageW, PostQuitMessage,
    RegisterClassW, SMTO_NORMAL, SW_HIDE, SendMessageTimeoutW, ShowWindow, TranslateMessage, WINDOW_EX_STYLE, WM_APP,
    WM_NULL, WNDCLASSW, WS_OVERLAPPEDWINDOW, WS_VISIBLE,
};
use windows::core::{HSTRING, PCWSTR};

/// L'appli se fige `wParam` millisecondes.
const FIGER: u32 = WM_APP + 7;
/// L'appli se cache elle-même (sa croix la range près de l'horloge), puis se fige `wParam` millisecondes.
const CACHER_PUIS_FIGER: u32 = WM_APP + 8;
/// L'appli s'arrête.
const QUITTER: u32 = WM_APP + 9;
/// La durée du figement (Nevermind met près de 10 s à finir de quitter).
const FIGEE_MS: usize = 10_000;

fn hwnd(h: isize) -> HWND {
    HWND(h as *mut core::ffi::c_void)
}

/// Le bureau de ce fil n'est pas celui de l'écran (même garde que mindset-horloge, `bureau_a_part`).
fn bureau_a_part() -> Option<String> {
    let mut nom = [0u16; 256];
    let mut taille = 0u32;
    // SAFETY : GetThreadDesktop rend le bureau du fil (pas à fermer) ; tampon de 512 octets, taille donnée
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
    lu.ok()?;
    let n = nom.iter().position(|&c| c == 0).unwrap_or(nom.len());
    let nom = String::from_utf16_lossy(&nom[..n]);
    (!nom.is_empty() && !nom.eq_ignore_ascii_case("Default") && !nom.eq_ignore_ascii_case("Winlogon")).then_some(nom)
}

unsafe extern "system" fn proc_appli(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        FIGER => {
            std::thread::sleep(Duration::from_millis(wp.0 as u64));
            LRESULT(0)
        }
        CACHER_PUIS_FIGER => {
            // SAFETY : sa propre fenêtre
            unsafe {
                let _ = ShowWindow(h, SW_HIDE);
            }
            std::thread::sleep(Duration::from_millis(wp.0 as u64));
            LRESULT(0)
        }
        QUITTER => {
            // SAFETY : sa propre boucle
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        // SAFETY : traitement par défaut
        _ => unsafe { DefWindowProcW(h, msg, wp, lp) },
    }
}

unsafe extern "system" fn proc_defaut(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    // SAFETY : traitement par défaut
    unsafe { DefWindowProcW(h, msg, wp, lp) }
}

fn classe(nom: &str, p: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT) -> HSTRING {
    let n = HSTRING::from(nom);
    let c = WNDCLASSW { lpfnWndProc: Some(p), lpszClassName: PCWSTR(n.as_ptr()), ..Default::default() };
    // SAFETY : classe de ce programme, nom copié par Windows
    unsafe { RegisterClassW(&c) };
    n
}

fn creer(classe: &HSTRING, titre: &str, visible: bool) -> isize {
    let t = HSTRING::from(titre);
    let style = if visible { WS_OVERLAPPEDWINDOW | WS_VISIBLE } else { WS_OVERLAPPEDWINDOW };
    // SAFETY : classe de ce programme
    unsafe { CreateWindowExW(WINDOW_EX_STYLE(0), classe, &t, style, 10, 10, 500, 400, None, None, None, None) }
        .expect("fenêtre d'essai")
        .0 as isize
}

fn pomper_toujours() {
    let mut m = MSG::default();
    // SAFETY : la boucle de messages de ce fil
    unsafe {
        while GetMessageW(&mut m, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }
}

fn poster(h: isize, msg: u32, wp: usize) {
    // SAFETY : un message posté à la fausse appli, sans attendre
    unsafe {
        let _ = PostMessageW(Some(hwnd(h)), msg, WPARAM(wp), LPARAM(0));
    }
}

/// La fausse appli : sa fenêtre cachée (comme lancée avec -Demarrage), sa boucle, 120 s au plus.
fn appli() {
    let c = classe("Tauri Window", proc_appli);
    let _h = creer(&c, "Figée", false);
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(120));
        std::process::exit(0);
    });
    pomper_toujours();
}

/// La fenêtre de Mindset répond-elle ? (sa durée, 15 s au plus)
fn sonder(h: isize) -> Duration {
    let t = Instant::now();
    let mut r = 0usize;
    // SAFETY : un message vide à notre fausse fenêtre de Mindset
    unsafe {
        let _ = SendMessageTimeoutW(hwnd(h), WM_NULL, WPARAM(0), LPARAM(0), SMTO_NORMAL, 15_000, Some(&mut r));
    }
    t.elapsed()
}

fn parent(h: isize) -> isize {
    // SAFETY : lecture seule
    unsafe { GetParent(hwnd(h)) }.map_or(0, |p| p.0 as isize)
}

fn ms(d: Duration) -> String {
    format!("{} ms", d.as_millis())
}

/// `f` mesurée ; en même temps, un autre fil regarde si la fenêtre de Mindset (son fil à elle) répond encore.
fn chrono<R>(mindset: isize, f: impl FnOnce() -> R) -> (R, Duration, Duration) {
    let fini = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let f2 = fini.clone();
    let sonde = std::thread::spawn(move || {
        let mut pire = Duration::ZERO;
        while !f2.load(std::sync::atomic::Ordering::Relaxed) {
            pire = pire.max(sonder(mindset));
            std::thread::sleep(Duration::from_millis(50));
        }
        pire
    });
    let t = Instant::now();
    let r = f();
    let d = t.elapsed();
    fini.store(true, std::sync::atomic::Ordering::Relaxed);
    let pire = sonde.join().unwrap_or_default();
    (r, d, pire)
}

fn attendre_qu_elle_reponde(f: &FenetresWindows, h: isize) {
    let fin = Instant::now() + Duration::from_secs(20);
    while Instant::now() < fin && !f.repond(h) {
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn mesure() -> i32 {
    // La fausse fenêtre de Mindset, sur son fil (comme le fil de Tauri), qui tourne sa boucle
    let (envoi, recu) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let c = classe("MindsetEssaiFenetre", proc_defaut);
        let h = creer(&c, "Mindset", true);
        let _ = envoi.send(h);
        pomper_toujours();
    });
    let mindset = recu.recv().expect("fenêtre de Mindset d'essai");
    // La fausse appli : ce programme, dans un autre processus, sur ce bureau (hérité), sans console
    let exe = std::env::current_exe().expect("ce programme");
    let mut enfant = {
        use std::os::windows::process::CommandExt;
        std::process::Command::new(&exe).arg("appli").creation_flags(0x0800_0000).spawn().expect("fausse appli")
    };
    let pid = enfant.id();
    let f = FenetresWindows::nouveau();
    let mut app = None;
    let fin = Instant::now() + Duration::from_secs(20);
    while app.is_none() && Instant::now() < fin {
        app = f.trouver(pid, "Figée");
        std::thread::sleep(Duration::from_millis(100));
    }
    let Some(app) = app else {
        println!("ÉCHEC : la fenêtre de la fausse appli n'est pas venue");
        let _ = enfant.kill();
        return 1;
    };
    println!("Fausse appli : processus {pid}, fenêtre {app} ; fausse fenêtre de Mindset : {mindset}");
    let zone = Zone { x: 20, y: 20, largeur: 400, hauteur: 300, visible: true };
    let panneau = f.hote("figee", mindset).expect("panneau");
    f.placer_hote(panneau, zone, true);

    // 1. Accrochée normalement (elle répond)
    let (styles, d, _) = chrono(mindset, || f.accrocher(app, panneau, 400, 300));
    let styles = styles.expect("accrochée");
    println!("1. accrocher, appli qui répond : {}", ms(d));

    // 2. Elle se fige ; `repond` puis `liberer` (Mindset quitte, ou l'appli s'est rangée)
    poster(app, FIGER, FIGEE_MS);
    std::thread::sleep(Duration::from_millis(300));
    let (r, d, _) = chrono(mindset, || f.repond(app));
    println!("2a. repond, appli figée : {r} en {}", ms(d));
    let (rendue, d, pire) = chrono(mindset, || f.liberer(app, styles));
    println!(
        "2b. liberer, appli figée : {} (rendue à temps : {rendue:?}) (la fenêtre de Mindset a mis jusqu'à {} à répondre)",
        ms(d),
        ms(pire)
    );
    attendre_qu_elle_reponde(&f, app);
    std::thread::sleep(Duration::from_millis(300));
    println!("2c. après le dégel : parent de l'appli = {} (0 : rendue au bureau)", parent(app));

    // 3. `repond` dit oui, puis elle se fige juste avant `accrocher`
    let r = f.repond(app);
    poster(app, FIGER, FIGEE_MS);
    std::thread::sleep(Duration::from_millis(100));
    let (s, d, pire) = chrono(mindset, || f.accrocher(app, panneau, 400, 300));
    println!(
        "3. accrocher juste après un repond réussi ({r}), appli figée : {} ({}) (Mindset : jusqu'à {})",
        ms(d),
        if s.is_some() { "accrochée" } else { "refusée" },
        ms(pire)
    );
    attendre_qu_elle_reponde(&f, app);
    if let Some(s) = s {
        f.liberer(app, s);
    }

    // 4 et 5 : par le vrai bloc, comme dans Mindset
    let (ctx, faux) = essai::contexte("accrochage-figee-reel");
    let dossier = r"C:\Essai\Programmes\figee";
    faux.systeme.ajouter_processus(pid, &format!(r"{dossier}\Mindset.exe"), 1);
    ctx.definir_applis(vec![Appli {
        id: "figee".into(),
        nom: "Figée".into(),
        couleur: "#00E5FF".into(),
        exe: "Mindset.exe".into(),
        ..Default::default()
    }]);
    ctx.au_nom_de("installations", || {
        ctx.publier(
            partage::INSTALLATIONS,
            json!({ "figee": { "dossier": dossier, "gere": true, "version": "9.0.0" } }),
        )
    });
    ctx.definir_fenetre(Some(mindset));
    let mut bloc = BlocAccrochage::avec(Box::new(FenetresWindows::nouveau()));
    let mut e = Effets::default();
    ctx.au_nom_de("accrochage", || bloc.demarrer(&ctx, &mut e));
    let mut v = ctx.vue();
    v.visible = true;
    v.page = "figee".into();
    ctx.definir_vue(v);
    let z = json!({ "x": 20, "y": 20, "largeur": 400, "hauteur": 300, "visible": true });
    ctx.au_nom_de("accrochage", || bloc.action(&ctx, "accrochage:zone", &z, &mut e));
    let afficher = |bloc: &mut BlocAccrochage| {
        let mut e = Effets::default();
        ctx.au_nom_de("accrochage", || bloc.signal(&ctx, "page", &json!({ "id": "figee" }), &mut e));
        ctx.lu(partage::ACCROCHEES).and_then(|a| a["figee"]["fenetre"].as_i64()).is_some()
    };
    let tic = |bloc: &mut BlocAccrochage| {
        ctx.avancer(Duration::from_millis(400));
        let mut e = Effets::default();
        ctx.au_nom_de("accrochage", || bloc.tic(&ctx, &mut e));
    };
    println!("4. par le bloc : accrochée = {}", afficher(&mut bloc));
    // 4. L'appli se range elle-même puis travaille 10 s (Nevermind qui quitte) : le tic suivant la rend
    poster(app, CACHER_PUIS_FIGER, FIGEE_MS);
    std::thread::sleep(Duration::from_millis(300));
    let ((), d, pire) = chrono(mindset, || tic(&mut bloc));
    let etat = ctx.lu(partage::ACCROCHEES).map(|a| a["figee"]["etat"].clone()).unwrap_or_default();
    println!(
        "4. tic de la surveillance, appli rangée puis figée : {} (état {etat}) (Mindset : jusqu'à {})",
        ms(d),
        ms(pire)
    );
    attendre_qu_elle_reponde(&f, app);

    // 5. Mindset quitte (relance pour une mise à jour, nouveau thème) pendant que l'appli accrochée est figée
    let accrochee = afficher(&mut bloc);
    println!("5. par le bloc : raccrochée = {accrochee}");
    poster(app, FIGER, FIGEE_MS);
    std::thread::sleep(Duration::from_millis(300));
    let ((), d, pire) = chrono(mindset, || ctx.au_nom_de("accrochage", || bloc.fermer(&ctx)));
    println!("5. fermeture du bloc (Mindset quitte), appli figée : {} (Mindset : jusqu'à {})", ms(d), ms(pire));
    attendre_qu_elle_reponde(&f, app);
    std::thread::sleep(Duration::from_millis(300));
    println!(
        "5b. après le dégel : la fenêtre de l'appli existe = {}, parent = {} (0 : rendue au bureau)",
        f.existe(app),
        parent(app)
    );

    // 6. Pareil, mais figée 20 s : plus que ce que Mindset attend en quittant (la borne)
    let mut bloc = BlocAccrochage::avec(Box::new(FenetresWindows::nouveau()));
    ctx.au_nom_de("accrochage", || bloc.demarrer(&ctx, &mut e));
    ctx.au_nom_de("accrochage", || bloc.action(&ctx, "accrochage:zone", &z, &mut e));
    if f.existe(app) {
        println!("6. par un bloc neuf : accrochée = {}", afficher(&mut bloc));
        poster(app, FIGER, 2 * FIGEE_MS);
        std::thread::sleep(Duration::from_millis(300));
        let ((), d, pire) = chrono(mindset, || ctx.au_nom_de("accrochage", || bloc.fermer(&ctx)));
        println!("6. fermeture du bloc, appli figée 20 s : {} (Mindset : jusqu'à {})", ms(d), ms(pire));
        attendre_qu_elle_reponde(&f, app);
        std::thread::sleep(Duration::from_millis(300));
        println!("6b. après le dégel : la fenêtre de l'appli existe = {}, parent = {}", f.existe(app), parent(app));
    }

    let journal = faux.donnees.lignes();
    println!("Journal du bloc : {journal:?}");
    poster(app, QUITTER, 0);
    std::thread::sleep(Duration::from_millis(300));
    let _ = enfant.kill();
    let _ = enfant.wait();
    let _ = std::fs::remove_dir_all(&faux.racine);
    0
}

fn main() {
    let Some(bureau) = bureau_a_part() else {
        eprintln!("Refusé : cet essai ne tourne que sur un bureau Windows à part (sur-bureau.ps1).");
        std::process::exit(3);
    };
    match std::env::args().nth(1).as_deref() {
        Some("appli") => appli(),
        Some("mesure") => {
            println!("Bureau : {bureau}");
            std::process::exit(mesure());
        }
        _ => {
            eprintln!("essai_figee mesure | appli");
            std::process::exit(2);
        }
    }
}
