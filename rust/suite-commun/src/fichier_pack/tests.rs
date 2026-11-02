//! Tests de la lecture des fichiers d'un pack : un cas servi par type, puis pour chaque règle au moins un cas qui
//! doit être refusé avec sa raison exacte (contre-épreuve : sans la règle, le cas est servi ou refusé pour une autre
//! raison, et le test échoue). Les packs d'essai sont inventés (« essai-bleu »).

use super::*;

const PNG: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, b'I', b'H', b'D', b'R'];
const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, b'J', b'F', b'I', b'F', 0, 1, 1, 0];
const GIF: &[u8] = b"GIF89a\x01\x00\x01\x00\x80\x00\x00";
const WEBP: &[u8] = b"RIFF\x24\x00\x00\x00WEBPVP8 ";
const TTF: &[u8] = &[0, 1, 0, 0, 0, 0x0A, 0, 0x80, 0, 3, 0, 0x20, 0, 0];
const OTF: &[u8] = b"OTTO\x00\x0A\x00\x80\x00\x03\x00\x20";

/// Un dossier d'essai neuf sous le dossier temporaire, effacé à la fin, avec un pack « essai-bleu ».
struct Essai(PathBuf);
impl Essai {
    fn nouveau(nom: &str) -> Essai {
        let d = std::env::temp_dir().join(format!("suite-commun-pack-{nom}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join(r"donnees\Mindcare\packs\essai-bleu")).unwrap();
        std::fs::create_dir_all(d.join("ailleurs")).unwrap();
        Essai(d)
    }
    fn pack(&self) -> PathBuf {
        self.0.join(r"donnees\Mindcare\packs\essai-bleu")
    }
    /// Écrit un fichier (dossiers compris), relatif au dossier d'essai.
    fn ecrire(&self, chemin: &str, contenu: &[u8]) -> PathBuf {
        let f = self.0.join(chemin);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(&f, contenu).unwrap();
        f
    }
    fn dans_pack(&self, nom: &str, contenu: &[u8]) -> PathBuf {
        self.ecrire(&format!(r"donnees\Mindcare\packs\essai-bleu\{nom}"), contenu)
    }
}
impl Drop for Essai {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Une jonction (sans droit d'administrateur), par `mklink /J`, sans fenêtre. `false` si Windows refuse.
#[cfg(windows)]
fn jonction(lien: &Path, cible: &Path) -> bool {
    use std::os::windows::process::CommandExt;
    std::process::Command::new("cmd")
        // (CREATE_NO_WINDOW : jamais de fenêtre à l'écran)
        .creation_flags(0x0800_0000)
        .args(["/C", "mklink", "/J"])
        .arg(lien)
        .arg(cible)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

#[test]
fn chaque_type_est_servi_d_apres_ses_octets() {
    let e = Essai::nouveau("servi");
    for (nom, contenu, type_attendu) in [
        ("logo.png", PNG, "image/png"),
        ("fond.jpg", JPEG, "image/jpeg"),
        ("fond (2).jpeg", JPEG, "image/jpeg"),
        ("mascotte.gif", GIF, "image/gif"),
        ("tuile_pc.webp", WEBP, "image/webp"),
        ("Écran-Été.PNG", PNG, "image/png"),
        ("titre.ttf", TTF, "font/ttf"),
        ("titre2.ttf", b"true\x00\x0A\x00\x80\x00\x03\x00\x20", "font/ttf"),
        ("texte.otf", OTF, "font/otf"),
        // Une image sous l'extension d'une autre : servie avec son vrai type (comme l'import de Mindset)
        ("photo.png", JPEG, "image/jpeg"),
    ] {
        e.dans_pack(nom, contenu);
        let f = lire(&e.pack(), nom).unwrap_or_else(|r| panic!("{nom} refusé : {}", r.raison()));
        assert_eq!((f.type_contenu, f.octets.as_slice()), (type_attendu, contenu), "{nom}");
    }
}

#[test]
fn fichier_absent() {
    let e = Essai::nouveau("absent");
    assert_eq!(lire(&e.pack(), "logo.png"), Err(Refus::Introuvable));
    // Un dossier qui porte un nom d'image n'est pas un fichier
    std::fs::create_dir_all(e.pack().join("dossier.png")).unwrap();
    assert_eq!(lire(&e.pack(), "dossier.png"), Err(Refus::Introuvable));
    // Un pack qui n'existe pas
    assert_eq!(lire(&e.0.join(r"donnees\Mindcare\packs\essai-autre"), "logo.png"), Err(Refus::Introuvable));
}

/// Règle 1 : un nom simple. Chaque cas vise un vrai fichier (à côté du pack, dans un sous-dossier, ailleurs) : sans la
/// règle, il serait servi ou refusé pour une autre raison.
#[test]
fn regle_1_nom_simple() {
    let e = Essai::nouveau("nom");
    let ailleurs = e.ecrire(r"ailleurs\secret.png", PNG);
    e.ecrire(r"donnees\Mindcare\packs\voisin.png", PNG);
    e.dans_pack(r"sous\logo.png", PNG);
    let complet = ailleurs.to_string_lossy().into_owned();
    for nom in [
        r"..\voisin.png",
        "../voisin.png",
        r"..\..\..\..\ailleurs\secret.png",
        r"sous\logo.png",
        "sous/logo.png",
        complet.as_str(),
        "logo.png:flux.png",
        "CON.png",
        "logo.png.",
        "logo.png ",
        "",
        "~logo.png",
        "logo%2e.png",
    ] {
        assert_eq!(lire(&e.pack(), nom), Err(Refus::Nom), "{nom:?}");
    }
    // Trop long : 81 caractères
    let long = format!("{}.png", "a".repeat(77));
    e.dans_pack(&long, PNG);
    assert_eq!(lire(&e.pack(), &long), Err(Refus::Nom));
}

/// Règle 2 : seulement les extensions des images et des polices du thème (pas le réglage json, pas de SVG).
#[test]
fn regle_2_extension() {
    let e = Essai::nouveau("extension");
    for nom in ["pack-mindset.json", "page.html", "dessin.svg", "logo", "logo.png.txt", "police.woff2"] {
        e.dans_pack(nom, PNG);
        assert_eq!(lire(&e.pack(), nom), Err(Refus::Extension), "{nom}");
    }
}

/// Règle 3 : le dossier d'un pack, `<...>\packs\<id>`, en chemin complet.
#[test]
fn regle_3_dossier_du_pack() {
    let e = Essai::nouveau("dossier");
    e.ecrire(r"ailleurs\logo.png", PNG);
    e.ecrire(r"donnees\Mindcare\pas-packs\essai-bleu\logo.png", PNG);
    e.ecrire(r"donnees\Mindcare\packs\Essai_Bleu\logo.png", PNG);
    for d in [
        e.0.join("ailleurs"),
        e.0.join(r"donnees\Mindcare\pas-packs\essai-bleu"),
        e.0.join(r"donnees\Mindcare\packs\Essai_Bleu"),
        PathBuf::from(r"donnees\Mindcare\packs\essai-bleu"),
    ] {
        assert_eq!(lire(&d, "logo.png"), Err(Refus::Dossier), "{}", d.display());
    }
    // « packs » sans tenir compte des majuscules, comme PowerShell (-eq)
    e.ecrire(r"donnees\Evermind\PACKS\essai-bleu\logo.png", PNG);
    assert!(lire(&e.0.join(r"donnees\Evermind\PACKS\essai-bleu"), "logo.png").is_ok());
    // Un fichier qui porte le nom du dossier « packs » ou du pack
    e.ecrire(r"donnees\Nevermind\packs", b"");
    assert_eq!(lire(&e.0.join(r"donnees\Nevermind\packs\essai-bleu"), "logo.png"), Err(Refus::Dossier));
}

/// Règle 4 : ni lien ni jonction, pour le pack, son dossier « packs » ou le fichier.
#[cfg(windows)]
#[test]
fn regle_4_ni_lien_ni_jonction() {
    let e = Essai::nouveau("liens");
    let ailleurs = e.0.join("ailleurs");
    e.ecrire(r"ailleurs\logo.png", PNG);
    // Le pack lui-même est une jonction vers un autre dossier
    let pack_lien = e.0.join(r"donnees\Mindcare\packs\essai-lien");
    if !jonction(&pack_lien, &ailleurs) {
        eprintln!("jonction impossible ici : test des liens sauté");
        return;
    }
    assert_eq!(lire(&pack_lien, "logo.png"), Err(Refus::Lien));
    // Le dossier « packs » est une jonction
    std::fs::create_dir_all(e.0.join(r"ailleurs\packs\essai-bleu")).unwrap();
    e.ecrire(r"ailleurs\packs\essai-bleu\logo.png", PNG);
    std::fs::create_dir_all(e.0.join(r"donnees\Evermind")).unwrap();
    assert!(jonction(&e.0.join(r"donnees\Evermind\packs"), &e.0.join(r"ailleurs\packs")));
    assert_eq!(lire(&e.0.join(r"donnees\Evermind\packs\essai-bleu"), "logo.png"), Err(Refus::Lien));
    // Une jonction au nom d'une image, dans un vrai pack
    assert!(jonction(&e.pack().join("fond.png"), &ailleurs));
    assert_eq!(lire(&e.pack(), "fond.png"), Err(Refus::Lien));
    // Un lien symbolique vers un fichier (il faut le mode développeur ou des droits : sinon, cas sauté)
    let lien = e.pack().join("mascotte.png");
    match std::os::windows::fs::symlink_file(ailleurs.join("logo.png"), &lien) {
        Ok(()) => assert_eq!(lire(&e.pack(), "mascotte.png"), Err(Refus::Lien)),
        Err(err) => eprintln!("lien symbolique impossible ici ({err}) : cas sauté"),
    }
    // L'image vraie du même pack reste servie
    e.dans_pack("logo.png", PNG);
    assert!(lire(&e.pack(), "logo.png").is_ok());
}

/// Règle 5 : les chemins canoniques. Les règles 1 et 4 arrêtent avant elle tous les cas qu'on sait fabriquer ;
/// elle est vérifiée ici seule, sur des chemins.
#[test]
fn regle_5_directement_dans_le_dossier() {
    let d = Path::new(r"\\?\C:\donnees\Mindcare\packs\essai-bleu");
    assert!(directement_dans(d, Path::new(r"\\?\C:\donnees\Mindcare\packs\essai-bleu\logo.png")));
    assert!(!directement_dans(d, Path::new(r"\\?\C:\donnees\Mindcare\packs\essai-bleu\sous\logo.png")));
    assert!(!directement_dans(d, Path::new(r"\\?\C:\donnees\Mindcare\packs\voisin.png")));
    assert!(!directement_dans(d, Path::new(r"\\?\C:\ailleurs\logo.png")));
    assert!(!directement_dans(d, Path::new(r"\\?\C:\donnees\Mindcare\packs\essai-bleu2\logo.png")));
}

/// Règle 6 : les limites de l'import, 15 Mo pour une image, 10 Mo pour une police (pile la limite : servie).
#[test]
fn regle_6_taille() {
    let e = Essai::nouveau("taille");
    let grossir = |f: &Path, taille: u64| {
        std::fs::OpenOptions::new().write(true).open(f).unwrap().set_len(taille).unwrap();
    };
    grossir(&e.dans_pack("pile.png", PNG), TAILLE_MAX_IMAGE);
    grossir(&e.dans_pack("lourd.png", PNG), TAILLE_MAX_IMAGE + 1);
    grossir(&e.dans_pack("pile.ttf", TTF), TAILLE_MAX_POLICE);
    grossir(&e.dans_pack("lourd.ttf", TTF), TAILLE_MAX_POLICE + 1);
    assert_eq!(lire(&e.pack(), "pile.png").map(|f| f.octets.len() as u64), Ok(TAILLE_MAX_IMAGE));
    assert_eq!(lire(&e.pack(), "lourd.png"), Err(Refus::TropLourd));
    assert_eq!(lire(&e.pack(), "pile.ttf").map(|f| f.octets.len() as u64), Ok(TAILLE_MAX_POLICE));
    // Une police de 10 Mo et un octet : refusée, alors qu'une image de cette taille passerait
    assert_eq!(lire(&e.pack(), "lourd.ttf"), Err(Refus::TropLourd));
}

/// Règle 7 : le type reconnu à ses premiers octets.
#[test]
fn regle_7_type() {
    let e = Essai::nouveau("type");
    for (nom, contenu) in [
        ("faux.png", &b"<svg onload=alert(1)></svg>"[..]),
        ("court.png", &PNG[..8]),
        ("vide.gif", b""),
        ("riff.webp", b"RIFF\x24\x00\x00\x00WAVEfmt "),
        // Une police déguisée en image, une image déguisée en police
        ("police.png", TTF),
        ("image.ttf", PNG),
        ("texte.otf", b"<html><script>x</script></html>"),
    ] {
        e.dans_pack(nom, contenu);
        assert_eq!(lire(&e.pack(), nom), Err(Refus::Type), "{nom}");
    }
}

#[test]
fn types_d_apres_les_octets() {
    assert_eq!(type_image(PNG), Some("image/png"));
    assert_eq!(type_image(&PNG[..11]), None);
    assert_eq!(type_image(b"RIFF\0\0\0\0WEBP"), Some("image/webp"));
    assert_eq!(type_police(OTF), Some("font/otf"));
    assert_eq!(type_police(b"ttcf\0\x01\0\0\0\0\0\0"), None);
}

#[test]
fn noms_depuis_l_adresse() {
    assert_eq!(nom_depuis_adresse("/logo.png").as_deref(), Some("logo.png"));
    assert_eq!(nom_depuis_adresse("/logo%20bleu.png").as_deref(), Some("logo bleu.png"));
    assert_eq!(nom_depuis_adresse("/%C3%89t%C3%A9.png").as_deref(), Some("Été.png"));
    // Décodé une seule fois : « %252e » donne « %2e », jamais « . »
    assert_eq!(nom_depuis_adresse("/%252e%252e.png").as_deref(), Some("%2e%2e.png"));
    // Un nom piégé est décodé tel quel, puis refusé par lire
    assert_eq!(nom_depuis_adresse("/%2e%2e%5csecret.png").as_deref(), Some(r"..\secret.png"));
    for mauvais in ["/a%2", "/a%zz.png", "/a%+1.png", "/%FF.png", "/a.png?x=1", "/a.png#b"] {
        assert_eq!(nom_depuis_adresse(mauvais), None, "{mauvais}");
    }
}
