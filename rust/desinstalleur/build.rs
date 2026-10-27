//! Construction de « Desinstaller Mindset.exe » : ses ressources Windows, écrites ici sans aucun outil de plus.
//!
//! - le manifeste (desinstalleur.manifest : droits « asInvoker », contrôles modernes, écran net) ;
//! - l'icône de Mindset (Mindset/fichiers/Mindset.ico) ;
//! - les informations de version (produit « Mindset », description « Désinstaller Mindset », version de Mindset lue
//!   sur la ligne `$AppVersion` de Mindset/fichiers/Mindset.ps1 : publier.ps1 n'a qu'un numéro à changer).
//!
//! Le tout va dans un fichier .res, que l'éditeur de liens de Microsoft (link.exe) accepte tel quel.

use std::path::{Path, PathBuf};

fn main() {
    let ici = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let depot = ici.join("..").join("..");
    let manifeste = ici.join("desinstalleur.manifest");
    let icone = depot.join("Mindset").join("fichiers").join("Mindset.ico");
    let script = depot.join("Mindset").join("fichiers").join("Mindset.ps1");
    for f in [&manifeste, &icone, &script] {
        println!("cargo:rerun-if-changed={}", f.display());
    }
    println!("cargo:rerun-if-changed=build.rs");
    // Seulement pour Windows avec l'éditeur de liens de Microsoft (la suite n'est construite que comme ça)
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() != Ok("msvc") {
        return;
    }
    let version = version_mindset(&script);
    let mut res = Res::default();
    res.vide();
    // Le manifeste : ressource 24, numéro 1 (celui que Windows lit au lancement)
    res.ajouter(24, 1, 0x0409, &std::fs::read(&manifeste).expect("manifeste illisible"));
    icones(&mut res, &std::fs::read(&icone).expect("icône illisible"));
    res.ajouter(16, 1, 0x0000, &version_info(&version));
    let sortie = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR")).join("desinstalleur.res");
    std::fs::write(&sortie, &res.octets).expect("écriture du .res impossible");
    println!("cargo:rustc-link-arg-bins={}", sortie.display());
}

/// La version de Mindset, en quatre nombres (« 2.14.0 » donne [2, 14, 0, 0]) ; [0, 0, 0, 0] si introuvable
fn version_mindset(script: &Path) -> [u16; 4] {
    let texte = std::fs::read_to_string(script).unwrap_or_default();
    let mut v = [0u16; 4];
    for ligne in texte.lines().take(60) {
        let Some(reste) = ligne.trim_start_matches('\u{feff}').strip_prefix("$AppVersion = '") else { continue };
        let Some(fin) = reste.find('\'') else { continue };
        for (i, n) in reste[..fin].split('.').take(4).enumerate() {
            v[i] = n.parse().unwrap_or(0);
        }
        break;
    }
    v
}

/// Un fichier .res : une suite de ressources, chacune avec son en-tête, alignées sur 4 octets
#[derive(Default)]
struct Res {
    octets: Vec<u8>,
}

impl Res {
    /// La ressource vide qui ouvre tout fichier .res
    fn vide(&mut self) {
        self.octets.extend_from_slice(&0u32.to_le_bytes());
        self.octets.extend_from_slice(&32u32.to_le_bytes());
        self.octets.extend_from_slice(&[0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0]);
        self.octets.extend_from_slice(&[0u8; 16]);
    }

    /// Une ressource de type et de numéro donnés (langue : 0 neutre, 0x0409...)
    fn ajouter(&mut self, type_: u16, numero: u16, langue: u16, donnees: &[u8]) {
        let o = &mut self.octets;
        o.extend_from_slice(&(donnees.len() as u32).to_le_bytes());
        o.extend_from_slice(&32u32.to_le_bytes()); // taille de l'en-tête (type et nom en numéros)
        o.extend_from_slice(&[0xFF, 0xFF]);
        o.extend_from_slice(&type_.to_le_bytes());
        o.extend_from_slice(&[0xFF, 0xFF]);
        o.extend_from_slice(&numero.to_le_bytes());
        o.extend_from_slice(&0u32.to_le_bytes()); // DataVersion
        o.extend_from_slice(&0x1030u16.to_le_bytes()); // MOVEABLE | PURE | DISCARDABLE
        o.extend_from_slice(&langue.to_le_bytes());
        o.extend_from_slice(&0u32.to_le_bytes()); // Version
        o.extend_from_slice(&0u32.to_le_bytes()); // Characteristics
        o.extend_from_slice(donnees);
        while !o.len().is_multiple_of(4) {
            o.push(0);
        }
    }
}

/// Les images du .ico (ressources 3, numéros 1, 2...) et leur groupe (ressource 14, numéro 1 : l'icône du programme)
fn icones(res: &mut Res, ico: &[u8]) {
    let mot = |i: usize| u16::from_le_bytes([ico[i], ico[i + 1]]);
    let long = |i: usize| u32::from_le_bytes([ico[i], ico[i + 1], ico[i + 2], ico[i + 3]]);
    assert!(ico.len() >= 6 && mot(0) == 0 && mot(2) == 1, "Mindset.ico n'est pas une icône");
    let n = usize::from(mot(4));
    let mut groupe = Vec::new();
    groupe.extend_from_slice(&0u16.to_le_bytes());
    groupe.extend_from_slice(&1u16.to_le_bytes());
    groupe.extend_from_slice(&(n as u16).to_le_bytes());
    for k in 0..n {
        let e = 6 + 16 * k;
        let taille = long(e + 8) as usize;
        let debut = long(e + 12) as usize;
        let image = &ico[debut..debut + taille];
        let numero = (k + 1) as u16;
        res.ajouter(3, numero, 0x0000, image);
        // Même entrée que dans le .ico, mais le numéro de la ressource à la place de la position dans le fichier
        groupe.extend_from_slice(&ico[e..e + 12]);
        groupe.extend_from_slice(&numero.to_le_bytes());
    }
    res.ajouter(14, 1, 0x0000, &groupe);
}

/// Un bloc de VERSIONINFO : longueur, longueur de la valeur, type (1 texte, 0 octets), clé, valeur, puis les enfants
fn bloc(cle: &str, valeur: &[u8], longueur_valeur: u16, texte: bool, enfants: &[Vec<u8>]) -> Vec<u8> {
    let mut b = vec![0u8; 6];
    b[2..4].copy_from_slice(&longueur_valeur.to_le_bytes());
    b[4..6].copy_from_slice(&u16::from(texte).to_le_bytes());
    for c in cle.encode_utf16().chain([0]) {
        b.extend_from_slice(&c.to_le_bytes());
    }
    while !b.len().is_multiple_of(4) {
        b.push(0);
    }
    b.extend_from_slice(valeur);
    for e in enfants {
        while !b.len().is_multiple_of(4) {
            b.push(0);
        }
        b.extend_from_slice(e);
    }
    let n = b.len() as u16;
    b[0..2].copy_from_slice(&n.to_le_bytes());
    b
}

/// Un texte des informations de version (« ProductName » = « Mindset »)
fn chaine(cle: &str, valeur: &str) -> Vec<u8> {
    let mut v = Vec::new();
    let mut n = 0u16;
    for c in valeur.encode_utf16().chain([0]) {
        v.extend_from_slice(&c.to_le_bytes());
        n += 1;
    }
    bloc(cle, &v, n, true, &[])
}

fn version_info(v: &[u16; 4]) -> Vec<u8> {
    let texte = format!("{}.{}.{}.{}", v[0], v[1], v[2], v[3]);
    let haut = (u32::from(v[0]) << 16) | u32::from(v[1]);
    let bas = (u32::from(v[2]) << 16) | u32::from(v[3]);
    let mut fixe = Vec::new();
    for x in [0xFEEF_04BDu32, 0x0001_0000, haut, bas, haut, bas, 0x3F, 0, 0x0004_0004, 1, 0, 0, 0] {
        fixe.extend_from_slice(&x.to_le_bytes());
    }
    let table = bloc(
        "000004b0",
        &[],
        0,
        true,
        &[
            chaine("Comments", "Retire Mindset et ses applis du PC"),
            chaine("FileDescription", "Désinstaller Mindset"),
            chaine("FileVersion", &texte),
            chaine("InternalName", "Desinstaller Mindset.exe"),
            chaine("OriginalFilename", "Desinstaller Mindset.exe"),
            chaine("ProductName", "Mindset"),
            chaine("ProductVersion", &texte),
        ],
    );
    let textes = bloc("StringFileInfo", &[], 0, true, &[table]);
    let traduction = bloc("Translation", &[0x00, 0x00, 0xB0, 0x04], 4, false, &[]);
    let langues = bloc("VarFileInfo", &[], 0, true, &[traduction]);
    bloc("VS_VERSION_INFO", &fixe, fixe.len() as u16, false, &[textes, langues])
}
