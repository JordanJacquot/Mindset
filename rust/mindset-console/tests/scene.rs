//! La scène 3D (`mindset-appli/ui/console/scene.html`) est celle de la version PowerShell
//! (`Mindset/fichiers/console/scene.html`), avec seulement les changements permis (architecture, bloc 7) :
//! 1. `hote()` envoie à la coquille (`window.parent.postMessage`) au lieu de `chrome.webview` (règle 1) ;
//! 2. au plus 60 images par seconde : la boucle 3D (`renderer.setAnimationLoop(image)`), le carrousel du menu en grand
//!    (`requestAnimationFrame(boucleCarrousel)`), et les animations CSS sans fin, qui avancent par pas (`steps(n)`, au
//!    plus 60 pas par seconde) au lieu d'avancer en continu (`linear infinite`) : mesuré le 06/11/2026 sur Nevermind
//!    (écran à 360 Hz : la page redessinée 360 fois par seconde), corrigé dans Nevermind 2.0.1 ;
//! 3. les adresses des images servies par Mindset (`http://fichier.localhost/`, `http://pack.localhost/`).
//!
//! Tout autre changement fait échouer `seulement_les_changements_permis`.

use std::path::{Path, PathBuf};

fn racine() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
}

fn lire(p: &Path) -> String {
    std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{} : {e}", p.display())).replace("\r\n", "\n")
}

fn scene() -> String {
    lire(&racine().join("rust/mindset-appli/ui/console/scene.html"))
}

/// La durée d'une animation (`7s`, `2.2s`, `300ms`) en secondes.
fn secondes(t: &str) -> Option<f64> {
    if let Some(ms) = t.strip_suffix("ms") {
        return ms.parse::<f64>().ok().map(|v| v / 1000.0);
    }
    t.strip_suffix('s')?.parse().ok()
}

/// Le corps d'une fonction de la scène (de `function nom(` à la ligne `}` qui la ferme).
fn fonction<'a>(js: &'a str, debut: &str) -> &'a str {
    let i = js.find(debut).unwrap_or_else(|| panic!("scene.html : {debut} a disparu"));
    let fin = js[i..].find("\n}").unwrap_or_else(|| panic!("scene.html : fin de {debut}"));
    &js[i..i + fin]
}

#[test]
fn la_boucle_3d_est_limitee_a_60_images_par_seconde() {
    let js = scene();
    assert!(js.contains("const PAS_IMAGE = 1000 / 60;"), "scene.html : la limite de 60 images par seconde a disparu");
    // La boucle 3D : elle saute l'image en trop avant tout calcul et tout dessin
    let boucle = fonction(&js, "function image(maintenant) {");
    let saut = boucle
        .find("if (maintenant - derniereImage < PAS_IMAGE - 1) return;")
        .expect("scene.html : la boucle 3D ne saute plus les images en trop");
    assert!(boucle.contains("derniereImage = Math.max(derniereImage + PAS_IMAGE, maintenant - PAS_IMAGE);"));
    for dessin in ["renderer.render(", "dessinerEcran(", "effets(", "a.maj(p)", "performance.now()"] {
        let i = boucle.find(dessin).unwrap_or_else(|| panic!("scene.html : {dessin} a disparu de la boucle"));
        assert!(saut < i, "scene.html : {dessin} est fait avant le saut des images en trop");
    }
    assert_eq!(js.matches("setAnimationLoop(image)").count(), 2, "scene.html : la boucle 3D est lancée ailleurs");
    // Le carrousel du menu en grand
    let car = fonction(&js, "function boucleCarrousel(maintenant) {");
    let saut = car
        .find("if (maintenant - car.derniere < PAS_IMAGE - 1) { car.boucle = requestAnimationFrame(boucleCarrousel); return; }")
        .expect("scene.html : le carrousel ne saute plus les images en trop");
    assert!(saut < car.find("placerCarrousel()").unwrap(), "scene.html : le carrousel bouge avant le saut");
    assert!(saut < car.find("car.pos +=").unwrap(), "scene.html : le carrousel avance avant le saut");
    // Aucune autre boucle d'images
    assert_eq!(
        js.matches("requestAnimationFrame(").count(),
        3,
        "scene.html : une autre boucle d'animation est apparue (elle doit sauter les images en trop)"
    );
}

#[test]
fn les_animations_sans_fin_avancent_par_pas() {
    let css = scene();
    let mut vues = 0;
    for (i, _) in css.match_indices("animation:") {
        let regle: String = css[i + "animation:".len()..].chars().take_while(|c| *c != ';' && *c != '}').collect();
        let mots: Vec<&str> = regle.split_whitespace().collect();
        if !mots.contains(&"infinite") {
            continue;
        }
        assert!(!mots.contains(&"linear"), "scene.html : animation sans fin en continu ({})", regle.trim());
        if let Some(pas) = mots.iter().find(|m| m.starts_with("steps(")) {
            vues += 1;
            let n: f64 = pas.trim_start_matches("steps(").trim_end_matches(')').parse().expect("steps(n)");
            let duree = mots.iter().find_map(|m| secondes(m)).expect("durée de l'animation");
            assert!(n / duree <= 60.5, "scene.html : plus de 60 pas par seconde ({})", regle.trim());
            assert!(
                n / duree >= 59.5,
                "scene.html : moins de 60 pas par seconde, le mouvement saccade ({})",
                regle.trim()
            );
        }
    }
    assert_eq!(vues, 8, "scene.html : les 8 animations sans fin de la version PowerShell");
}

/// Les changements permis, de la version PowerShell vers la version Rust (texte exact).
const CHANGEMENTS: &[(&str, &str)] = &[
    // 1. hote() parle à la coquille
    (
        "const hote = (type, donnees = {}) => { try { window.chrome?.webview?.postMessage({ type, ...donnees }); } catch (e) {} };",
        "const hote = (type, donnees = {}) => { try { if (window.parent !== window) window.parent.postMessage({ type, ...donnees }, 'http://tauri.localhost'); } catch (e) {} };",
    ),
    // 2. au plus 60 images par seconde
    (
        "let vitesse = params.get('animations') === 'express' || reduit ? 0.4 : 1;   // (changée par les Paramètres : window.mindset.vitesse)\n",
        "let vitesse = params.get('animations') === 'express' || reduit ? 0.4 : 1;   // (changée par les Paramètres : window.mindset.vitesse)\n// Au plus 60 images par seconde (millisecondes entre deux images) : la boucle 3D et le carrousel du menu en grand\nconst PAS_IMAGE = 1000 / 60;\n",
    ),
    (
        "const car = { pos: 0, cible: 0, tenu: null, boucle: 0 };",
        "const car = { pos: 0, cible: 0, tenu: null, boucle: 0, derniere: -Infinity };",
    ),
    (
        "function boucleCarrousel() {\n  car.boucle = 0; if (ouverte !== MENU) return;\n",
        "function boucleCarrousel(maintenant) {\n  car.boucle = 0; if (ouverte !== MENU) return;\n  if (maintenant - car.derniere < PAS_IMAGE - 1) { car.boucle = requestAnimationFrame(boucleCarrousel); return; }   // (au plus 60 images par seconde)\n  car.derniere = Math.max(car.derniere + PAS_IMAGE, maintenant - PAS_IMAGE);\n",
    ),
    (
        "function image() {\n",
        "// Au plus 60 images par seconde, quel que soit l'écran (sur un écran à 360 Hz, la 3D était dessinée 360 fois par\n// seconde pendant une animation, pour le même rendu à l'oeil ; comme Nevermind 2.0.1)\nlet derniereImage = -Infinity;\nfunction image(maintenant) {\n  if (maintenant - derniereImage < PAS_IMAGE - 1) return;\n  derniereImage = Math.max(derniereImage + PAS_IMAGE, maintenant - PAS_IMAGE);\n",
    ),
    (" 0.9s linear infinite", " 0.9s steps(54) infinite"),
    (" 1s linear infinite", " 1s steps(60) infinite"),
    (" 2.4s linear infinite", " 2.4s steps(144) infinite"),
    (" 2.6s linear infinite", " 2.6s steps(156) infinite"),
    (" 30s linear infinite", " 30s steps(1800) infinite"),
    (" 3s linear infinite", " 3s steps(180) infinite"),
    (" 7s linear infinite", " 7s steps(420) infinite"),
    // 4. une appli encore ouverte (réduite ou en fond) : « Ouverte » sous sa tuile, sur l'écran de la console
    //    (demande de Jordan du 08/11/2026 : revenir au menu après « Réduire » et voir que l'appli tourne encore)
    (
        "ex.fillText('Mise à jour', X + s / 2, Y + s + 31); }",
        "ex.fillText('Mise à jour', X + s / 2, Y + s + 31); } else if (app.etat !== 'ferme') { ex.fillStyle = C('#3FD99A'); ex.font = `700 24px ${POLICE}`; ex.fillText('Ouverte', X + s / 2, Y + s + 34); }",
    ),
    // 3. les adresses des images servies par Mindset
    ("https://theme.mindset.local/) et sa police", "http://pack.localhost/) et sa police"),
    (
        "if (url.startsWith('https://')) im.crossOrigin",
        "if (/^http:\\/\\/(fichier|pack)\\.localhost\\//.test(url)) im.crossOrigin",
    ),
    (
        "/^(logos\\/|https:\\/\\/applogos\\.mindset\\.local\\/)[a-z0-9-]+\\.png$/",
        "/^(logos\\/|http:\\/\\/fichier\\.localhost\\/)[a-z0-9-]+\\.png$/",
    ),
    (
        "/^https:\\/\\/theme\\.mindset\\.local\\/[\\w.%()-]{1,240}$/",
        "/^http:\\/\\/pack\\.localhost\\/[\\w.%()-]{1,240}$/",
    ),
];

#[test]
fn seulement_les_changements_permis() {
    let mut attendu = lire(&racine().join("Mindset/fichiers/console/scene.html"));
    for (avant, apres) in CHANGEMENTS {
        assert!(attendu.contains(avant), "la version PowerShell n'a plus : {avant}");
        attendu = attendu.replace(avant, apres);
    }
    let reel = scene();
    if reel != attendu {
        let l = reel.lines().zip(attendu.lines()).enumerate().find(|(_, (a, b))| a != b);
        panic!(
            "scene.html a un changement non permis (ligne {:?}) : voir DIVERGENCES.md",
            l.map(|(i, (a, b))| (i + 1, a, b))
        );
    }
    // (la règle 1 : rien d'autre qu'ipc.js ne parle à Tauri ou à WebView2)
    for interdit in ["chrome.webview", "__TAURI", "ipc.localhost", ".invoke(", "mindset.local"] {
        assert!(!reel.contains(interdit), "scene.html contient encore {interdit}");
    }
}

#[test]
fn les_fichiers_de_la_scene_sont_ceux_de_la_version_powershell() {
    // three.js, le décor et les logos : copiés tels quels
    let ps = racine().join("Mindset/fichiers/console");
    let rust = racine().join("rust/mindset-appli/ui/console");
    let mut n = 0;
    let mut pile = vec![PathBuf::new()];
    while let Some(rel) = pile.pop() {
        for e in std::fs::read_dir(ps.join(&rel)).unwrap().flatten() {
            let r = rel.join(e.file_name());
            if e.path().is_dir() {
                pile.push(r);
            } else if r != Path::new("scene.html") {
                let a = std::fs::read(e.path()).unwrap();
                let b =
                    std::fs::read(rust.join(&r)).unwrap_or_else(|_| panic!("{} manque dans ui/console", r.display()));
                assert!(a == b, "{} : différent de la version PowerShell", r.display());
                n += 1;
            }
        }
    }
    assert!(n >= 10, "{n} fichiers seulement");
}

#[test]
fn console_js_ne_parle_qu_a_la_coquille() {
    let js = lire(&racine().join("rust/mindset-appli/ui/console/console.js"));
    for interdit in ["__TAURI", "ipc.localhost", "chrome.webview", ".invoke(", "eval(", "innerHTML"] {
        assert!(!js.contains(interdit), "console.js contient {interdit}");
    }
    // Les messages de la scène : seulement de son cadre et de cette page
    assert!(js.contains("ev.source !== cadre.contentWindow || ev.origin !== location.origin"));
    // Le cadre vient de l'état, seulement vers la scène
    assert!(js.contains(r"/^console\/scene\.html\?/.test(c.cadre)"));
    // (aucun tiret long dans ce qui s'affiche)
    for f in ["console.js", "scene.html"] {
        let t = lire(&racine().join("rust/mindset-appli/ui/console").join(f));
        assert!(!t.contains('\u{2014}') && !t.contains('\u{2013}'), "{f} : tiret long");
    }
}
