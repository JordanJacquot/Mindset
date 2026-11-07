//! L'essai RÉEL de l'accrochage : le vrai bloc, avec le vrai Windows, sur une vraie fenêtre de Mindset (construction
//! d'essai, Tauri et sa page WebView2) et de vraies fenêtres d'applis (une WPF, une Tauri) lancées par l'essai.
//!
//! À lancer SEULEMENT par `outils\essai-accrochage.ps1`, lui-même lancé sur un BUREAU WINDOWS À PART
//! (`sur-bureau.ps1`) : `EnumWindows` ne voit alors que les fenêtres de ce bureau, jamais celles de l'utilisateur.
//!
//!   essai_reel <hwnd de Mindset> <dossier des images> <pid>:<titre>:<id> [<pid>:<titre>:<id> ...]
//!
//! Pour chaque appli : sa page montrée, elle est trouvée et accrochée ; l'image de la fenêtre de Mindset
//! (`PrintWindow`, comme l'hôte) doit montrer l'appli PAR-DESSUS la page (le piège du 26/10), puis rien sous le voile,
//! puis l'appli de nouveau, à sa nouvelle taille ; Mindset quitte : elle est rendue, cachée.

#![allow(unsafe_code)]

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

use mindset_accrochage::BlocAccrochage;
use mindset_accrochage::windows::FenetresWindows;
use mindset_noyau::{Appli, Bloc, Contexte, Effets, essai, partage};

use windows::Win32::Foundation::{HWND, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, ClientToScreen, CreateCompatibleBitmap, CreateCompatibleDC, DIB_RGB_COLORS,
    DeleteDC, DeleteObject, GetDC, GetDIBits, HGDIOBJ, ReleaseDC, SelectObject,
};
use windows::Win32::Storage::Xps::{PRINT_WINDOW_FLAGS, PrintWindow};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForWindow, SetProcessDpiAwarenessContext,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GUITHREADINFO, GWL_STYLE, GetClassNameW, GetClientRect, GetGUIThreadInfo, GetParent, GetWindowLongPtrW,
    GetWindowRect, GetWindowTextW, GetWindowThreadProcessId, IsChild,
};

fn hwnd(h: isize) -> HWND {
    HWND(h as *mut core::ffi::c_void)
}

/// L'image de la fenêtre (RVB, de haut en bas) et le décalage de son intérieur.
struct Image {
    l: i32,
    h: i32,
    rvb: Vec<u8>,
    dx: i32,
    dy: i32,
}

fn capturer(f: isize) -> Option<Image> {
    let mut r = RECT::default();
    let mut o = POINT::default();
    // SAFETY : lectures seules sur la fenêtre de Mindset d'essai
    unsafe {
        GetWindowRect(hwnd(f), &mut r).ok()?;
        let _ = ClientToScreen(hwnd(f), &mut o);
    }
    let (l, h) = (r.right - r.left, r.bottom - r.top);
    if l <= 0 || h <= 0 || l > 8000 || h > 8000 {
        return None;
    }
    let mut bgra = vec![0u8; (l * h * 4) as usize];
    let mut bi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: l,
            biHeight: -h,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    // SAFETY : comme mindset-appli (windows\capture.rs) : contextes créés et rendus ici, tampon de l x h x 4 octets
    let n = unsafe {
        let ecran = GetDC(None);
        let memoire = CreateCompatibleDC(Some(ecran));
        let image = CreateCompatibleBitmap(ecran, l, h);
        let avant = SelectObject(memoire, HGDIOBJ::from(image));
        let _ = PrintWindow(hwnd(f), memoire, PRINT_WINDOW_FLAGS(2));
        SelectObject(memoire, avant);
        let n = GetDIBits(memoire, image, 0, h as u32, Some(bgra.as_mut_ptr().cast()), &mut bi, DIB_RGB_COLORS);
        let _ = DeleteObject(HGDIOBJ::from(image));
        let _ = DeleteDC(memoire);
        ReleaseDC(None, ecran);
        n
    };
    if n != h {
        return None;
    }
    let rvb = bgra.chunks(4).flat_map(|p| [p[2], p[1], p[0]]).collect();
    Some(Image { l, h, rvb, dx: o.x - r.left, dy: o.y - r.top })
}

impl Image {
    /// La couleur moyenne d'un rectangle de l'intérieur de la fenêtre.
    fn moyenne(&self, x: i32, y: i32, l: i32, h: i32) -> [f64; 3] {
        let mut s = [0.0; 3];
        let mut n = 0.0;
        for j in y.max(0)..(y + h) {
            for i in x.max(0)..(x + l) {
                let (px, py) = (i + self.dx, j + self.dy);
                if px >= self.l || py >= self.h {
                    continue;
                }
                let k = ((py * self.l + px) * 3) as usize;
                for (c, v) in s.iter_mut().enumerate() {
                    *v += f64::from(self.rvb[k + c]);
                }
                n += 1.0;
            }
        }
        s.map(|x| if n > 0.0 { x / n } else { 0.0 })
    }

    /// En PNG (sans compression : des blocs « stored »), pour le rapport.
    fn png(&self, chemin: &Path) {
        fn crc(d: &[u8]) -> u32 {
            let mut c = 0xFFFF_FFFFu32;
            for &b in d {
                c ^= u32::from(b);
                for _ in 0..8 {
                    c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
                }
            }
            !c
        }
        fn morceau(o: &mut Vec<u8>, t: &[u8], d: &[u8]) {
            o.extend((d.len() as u32).to_be_bytes());
            let mut x = t.to_vec();
            x.extend(d);
            o.extend(&x);
            o.extend(crc(&x).to_be_bytes());
        }
        let mut brut = Vec::new();
        for y in 0..self.h {
            brut.push(0u8);
            let k = (y * self.l * 3) as usize;
            brut.extend(&self.rvb[k..k + (self.l * 3) as usize]);
        }
        let mut z = vec![0x78, 0x01];
        let morceaux: Vec<&[u8]> = brut.chunks(65_535).collect();
        for (i, m) in morceaux.iter().enumerate() {
            z.push(u8::from(i + 1 == morceaux.len()));
            z.extend((m.len() as u16).to_le_bytes());
            z.extend((!(m.len() as u16)).to_le_bytes());
            z.extend(*m);
        }
        let (mut a, mut b) = (1u32, 0u32);
        for &x in &brut {
            a = (a + u32::from(x)) % 65_521;
            b = (b + a) % 65_521;
        }
        z.extend(((b << 16) | a).to_be_bytes());
        let mut o = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        let mut ihdr = Vec::new();
        ihdr.extend((self.l as u32).to_be_bytes());
        ihdr.extend((self.h as u32).to_be_bytes());
        ihdr.extend([8, 2, 0, 0, 0]);
        morceau(&mut o, b"IHDR", &ihdr);
        morceau(&mut o, b"IDAT", &z);
        morceau(&mut o, b"IEND", &[]);
        let _ = std::fs::write(chemin, o);
    }
}

fn ecart(a: [f64; 3], b: [f64; 3]) -> f64 {
    (0..3).map(|c| (a[c] - b[c]).abs()).fold(0.0, f64::max)
}

fn texte(h: isize, classe: bool) -> String {
    let mut b = [0u16; 256];
    // SAFETY : lectures seules, tampon de 256
    let n = unsafe { if classe { GetClassNameW(hwnd(h), &mut b) } else { GetWindowTextW(hwnd(h), &mut b) } };
    String::from_utf16_lossy(&b[..n.clamp(0, 256) as usize])
}

struct Essai {
    ctx: Contexte,
    bloc: BlocAccrochage,
    mindset: isize,
    sortie: PathBuf,
    echecs: u32,
}

impl Essai {
    fn verifier(&mut self, ok: bool, t: &str) {
        if ok {
            println!("OK : {t}");
        } else {
            println!("ÉCHEC : {t}");
            self.echecs += 1;
        }
    }

    fn page(&mut self, id: &str) {
        let mut v = self.ctx.vue();
        let avant = std::mem::replace(&mut v.page, id.into());
        self.ctx.definir_vue(v);
        let mut e = Effets::default();
        self.ctx.au_nom_de("accrochage", || {
            self.bloc.signal(&self.ctx, "page", &json!({ "id": id, "avant": avant }), &mut e)
        });
    }

    fn signal(&mut self, nom: &str, d: Value) {
        let mut e = Effets::default();
        self.ctx.au_nom_de("accrochage", || self.bloc.signal(&self.ctx, nom, &d, &mut e));
    }

    fn zone(&mut self, x: i32, y: i32, l: i32, h: i32) {
        let mut e = Effets::default();
        let z = json!({ "x": x, "y": y, "largeur": l, "hauteur": h, "visible": true });
        self.ctx.au_nom_de("accrochage", || self.bloc.action(&self.ctx, "accrochage:zone", &z, &mut e));
    }

    /// Les tics de la surveillance pendant `ms` (comme le fil des blocs).
    fn attendre(&mut self, ms: u64) {
        let fin = std::time::Instant::now() + Duration::from_millis(ms);
        while std::time::Instant::now() < fin {
            let mut e = Effets::default();
            self.ctx.au_nom_de("accrochage", || self.bloc.tic(&self.ctx, &mut e));
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    fn image(&self, nom: &str) -> Option<Image> {
        let i = capturer(self.mindset);
        if let Some(i) = &i {
            i.png(&self.sortie.join(format!("{nom}.png")));
        }
        i
    }

    fn accrochee(&self, id: &str) -> Option<isize> {
        self.ctx.lu(partage::ACCROCHEES)?.get(id)?.get("fenetre")?.as_i64().map(|h| h as isize)
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 {
        eprintln!("essai_reel <hwnd de Mindset> <dossier des images> <pid>:<titre>:<id> ...");
        std::process::exit(2);
    }
    // (en pixels de l'écran, comme Mindset : la zone de la page est déjà multipliée par l'échelle)
    // SAFETY : réglage de ce processus, avant toute fenêtre
    let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
    let mindset: isize = a[1].parse().expect("hwnd de Mindset");
    let sortie = PathBuf::from(&a[2]);
    let _ = std::fs::create_dir_all(&sortie);
    let mut applis = Vec::new();
    for x in &a[3..] {
        let mut m = x.splitn(3, ':');
        let pid: u32 = m.next().and_then(|p| p.parse().ok()).expect("pid");
        let titre = m.next().expect("titre").to_string();
        let id = m.next().expect("id").to_string();
        applis.push((pid, titre, id));
    }
    let (ctx, faux) = essai::contexte("accrochage-reel");
    let mut e =
        Essai { ctx, bloc: BlocAccrochage::avec(Box::new(FenetresWindows::nouveau())), mindset, sortie, echecs: 0 };
    // La fenêtre de Mindset : celle de la construction d'essai, sur ce bureau
    let ok = texte(mindset, true) == "Tauri Window" && texte(mindset, false) == "Mindset";
    e.verifier(ok, "la fenêtre de Mindset d'essai (« Tauri Window », « Mindset »)");
    if !ok {
        std::process::exit(1);
    }
    e.ctx.definir_fenetre(Some(mindset));
    // Les applis : leurs programmes (vrais numéros), dans un dossier d'installation inventé
    let mut inst = serde_json::Map::new();
    let mut l = Vec::new();
    for (pid, titre, id) in &applis {
        let dossier = format!(r"C:\Essai\Programmes\{id}");
        faux.systeme.ajouter_processus(*pid, &format!(r"{dossier}\Mindset.exe"), 1);
        inst.insert(id.clone(), json!({ "dossier": dossier, "gere": true, "version": "9.0.0" }));
        l.push(Appli {
            id: id.clone(),
            nom: titre.clone(),
            couleur: "#00E5FF".into(),
            exe: "Mindset.exe".into(),
            ..Default::default()
        });
    }
    e.ctx.definir_applis(l);
    e.ctx.au_nom_de("installations", || e.ctx.publier(partage::INSTALLATIONS, Value::Object(inst)));
    let mut d = Effets::default();
    e.ctx.au_nom_de("accrochage", || e.bloc.demarrer(&e.ctx, &mut d));
    let mut v = e.ctx.vue();
    v.visible = true;
    e.ctx.definir_vue(v);

    let (zx, zy, zl, zh) = (220, 110, 640, 420);
    // (le centre de la zone, et un coin de la page hors de la zone)
    let centre = |i: &Image| i.moyenne(zx + zl / 4, zy + zh / 4, zl / 2, zh / 2);
    let dehors = |i: &Image| i.moyenne(20, zy + zh + 20, 60, 40);
    let Some(avant) = e.image("0-page-seule") else {
        e.verifier(false, "image de la fenêtre de Mindset (PrintWindow)");
        std::process::exit(1);
    };
    let page = centre(&avant);
    let page_dehors = dehors(&avant);
    println!("     page seule : centre {page:?}, dehors {page_dehors:?}");
    e.zone(zx, zy, zl, zh);

    let mut precedente: Option<(String, isize)> = None;
    for (n, (pid, titre, id)) in applis.iter().enumerate() {
        e.page(id);
        e.attendre(2500);
        let h = e.accrochee(id);
        e.verifier(h.is_some(), &format!("{titre} : trouvée (pid {pid}) et accrochée"));
        let Some(h) = h else { continue };
        // SAFETY : lectures seules
        let (parent, style, dpi_m, dpi_a) = unsafe {
            (
                GetParent(hwnd(h)).map_or(0, |p| p.0 as isize),
                GetWindowLongPtrW(hwnd(h), GWL_STYLE) as u32,
                GetDpiForWindow(hwnd(mindset)),
                GetDpiForWindow(hwnd(h)),
            )
        };
        // SAFETY : lecture seule
        let parent_du_panneau = unsafe { GetParent(hwnd(parent)) }.map_or(0, |p| p.0 as isize);
        e.verifier(parent_du_panneau == mindset, &format!("{titre} : dans un panneau de la fenêtre de Mindset"));
        e.verifier(
            style & 0x4000_0000 != 0 && style & 0x00C0_0000 == 0,
            &format!("{titre} : fenêtre enfant, sans barre de titre"),
        );
        let mut r = RECT::default();
        // SAFETY : lecture seule
        let _ = unsafe { GetClientRect(hwnd(h), &mut r) };
        e.verifier(
            (r.right, r.bottom) == (zl, zh),
            &format!("{titre} : à la taille de la zone ({} x {}, attendu {zl} x {zh} ; échelle Mindset {dpi_m}, appli {dpi_a})", r.right, r.bottom),
        );
        // Le clavier : le focus de son fil est sur elle (ou un de ses enfants)
        let mut pid_a = 0u32;
        // SAFETY : lecture seule
        let fil = unsafe { GetWindowThreadProcessId(hwnd(h), Some(&mut pid_a)) };
        let mut g = GUITHREADINFO { cbSize: size_of::<GUITHREADINFO>() as u32, ..Default::default() };
        // SAFETY : lecture seule ; g a sa taille
        let _ = unsafe { GetGUIThreadInfo(fil, &mut g) };
        let f = g.hwndFocus.0 as isize;
        // SAFETY : lecture seule
        let focus = f == h || (f != 0 && unsafe { IsChild(hwnd(h), g.hwndFocus) }.as_bool());
        e.verifier(focus, &format!("{titre} : le clavier va à l'appli (focus de son fil : {f:#x})"));

        // (l'image de la fenêtre de l'appli seule : se dessine-t-elle ?)
        if let Some(s) = capturer(h) {
            s.png(&e.sortie.join(format!("{}-{id}-seule.png", n + 1)));
            println!("     {titre} seule : {:?}", s.moyenne(r.right / 4, r.bottom / 4, r.right / 2, r.bottom / 2));
        }
        let i = e.image(&format!("{}-{id}-accrochee", n + 1));
        let c = i.as_ref().map(centre).unwrap_or_default();
        println!("     {titre} accrochée : centre {c:?}");
        // (WPF : son dessin ne se lit pas sur l'image d'une fenêtre accrochée dans un autre programme, même avec
        // Mindset 2.18 ; l'image montre seulement que la page ne la recouvre pas)
        let wpf = id == "foret";
        if wpf {
            e.verifier(ecart(c, page) > 5.0, &format!("{titre} (WPF) : la page ne la recouvre pas sur l'image"));
        } else {
            e.verifier(
                ecart(c, page) > 12.0 && c.iter().sum::<f64>() > 30.0,
                &format!("{titre} : VISIBLE par-dessus la page sur l'image (ni la page, ni un panneau noir)"),
            );
        }
        if id == "cafe-creme" {
            e.verifier(
                c[0] > 200.0 && (90.0..180.0).contains(&c[1]) && c[2] < 70.0,
                &format!("{titre} : son orange (#FF8A00) sur l'image"),
            );
        }
        e.verifier(
            i.as_ref().is_some_and(|i| ecart(dehors(i), page_dehors) < 8.0),
            &format!("{titre} : la page hors de la zone n'a pas changé"),
        );
        if let Some((tp, hp)) = &precedente {
            // SAFETY : lecture seule
            let p = unsafe { GetParent(hwnd(*hp)) }.map_or(0, |p| p.0 as isize);
            // SAFETY : lecture seule
            let visible = unsafe { windows::Win32::UI::WindowsAndMessaging::IsWindowVisible(hwnd(p)) }.as_bool();
            e.verifier(!visible, &format!("{tp} : son panneau est caché quand la page de {titre} est montrée"));
        }

        // Le voile : l'appli s'efface
        e.signal("voile", json!({ "visible": true }));
        e.attendre(800);
        let i = e.image(&format!("{}-{id}-voile", n + 1));
        let c = i.as_ref().map(centre).unwrap_or_default();
        e.verifier(ecart(c, page) < 8.0, &format!("{titre} : effacée sous le voile (la page revient : {c:?})"));
        e.signal("voile", json!({ "visible": false }));
        e.attendre(800);
        // Une autre taille de zone
        e.zone(zx, zy, zl - 200, zh - 120);
        let mut r = RECT::default();
        let mut vues = Vec::new();
        for _ in 0..20 {
            e.attendre(200);
            // SAFETY : lecture seule
            let _ = unsafe { GetClientRect(hwnd(h), &mut r) };
            vues.push((r.right, r.bottom));
            if (r.right, r.bottom) == (zl - 200, zh - 120) {
                break;
            }
        }
        println!("     {titre} : tailles vues toutes les 200 ms {vues:?}");
        e.verifier(
            (r.right, r.bottom) == (zl - 200, zh - 120),
            &format!("{titre} : redimensionnée avec la zone ({} x {})", r.right, r.bottom),
        );
        let i = e.image(&format!("{}-{id}-redimensionnee", n + 1));
        let c = i.as_ref().map(|i| i.moyenne(zx + 40, zy + 40, zl / 3, zh / 3)).unwrap_or_default();
        e.verifier(
            ecart(c, page) > if wpf { 5.0 } else { 12.0 },
            &format!("{titre} : de nouveau là après le voile, à sa nouvelle taille"),
        );
        e.zone(zx, zy, zl, zh);
        e.attendre(600);
        precedente = Some((titre.clone(), h));
    }

    // Mindset quitte : chaque fenêtre est rendue, cachée
    let fenetres: Vec<(String, isize)> =
        applis.iter().filter_map(|(_, t, id)| e.accrochee(id).map(|h| (t.clone(), h))).collect();
    e.ctx.au_nom_de("accrochage", || e.bloc.fermer(&e.ctx));
    std::thread::sleep(Duration::from_millis(1500));
    for (t, h) in fenetres {
        // SAFETY : lectures seules
        let (parent, style) =
            unsafe { (GetParent(hwnd(h)).map_or(0, |p| p.0 as isize), GetWindowLongPtrW(hwnd(h), GWL_STYLE) as u32) };
        e.verifier(
            parent == 0 && style & 0x1000_0000 == 0 && style & 0x4000_0000 == 0,
            &format!("{t} : rendue telle qu'elle était, cachée"),
        );
    }
    let i = e.image("9-mindset-a-quitte");
    let c = i.as_ref().map(centre).unwrap_or_default();
    e.verifier(ecart(c, page) < 8.0, "après la fin, la page de Mindset est de nouveau seule");
    let _ = std::fs::remove_dir_all(&faux.racine);
    println!("{} échec(s)", e.echecs);
    std::process::exit(i32::from(e.echecs > 0));
}
