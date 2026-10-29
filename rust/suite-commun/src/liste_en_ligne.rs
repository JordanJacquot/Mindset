//! La liste des applis en ligne (Mindset 2.16) : ses règles d'acceptation, les mêmes pour l'installateur
//! (MindsetInstallateur.exe, `-Liste <chemin>`) et pour le désinstalleur (la liste gardée dans le dossier des
//! données de Mindset). Côté PowerShell, les mêmes règles sont dans Mindset (applis.ps1).
//!
//! Le fichier `apps-en-ligne.json` (avec sa signature `apps-en-ligne.json.sig` à côté), en UTF-8, au plus 256 Ko :
//! `{ "liste": 4, "mindset_min": "2.16.0", "applis": [ ...entrées de la même forme que apps.json... ] }`.
//!
//! Une liste n'est acceptée que si TOUT est bon (sinon on garde la liste livrée, jamais à moitié) :
//! 1. taille au plus 256 Ko, signature valide avec les clés livrées avec Mindset ;
//! 2. JSON objet avec `liste` entier au moins 1, `mindset_min` version x.y.z, `applis` tableau non vide (noms des
//!    champs exacts, majuscules comprises, comme Mindset) ;
//! 3. `mindset_min` au plus la version de ce Mindset ;
//! 4. `liste` strictement plus grand que le numéro livré (`fichiers\apps-liste.txt`) : une ancienne liste signée ne
//!    peut pas revenir ;
//! 5. une entrée mal formée (pas un objet, `id`, `nom` ou `exe` absent ou mal écrit) est ignorée, le reste est pris ;
//!    deux entrées avec le même id (comparé exactement) : la première gagne ; au moins une entrée valable, sinon la
//!    liste est refusée. Chaque lecteur contrôle ensuite les entrées gardées comme celles de apps.json.
//!
//! Le dossier des données est modifiable sans droits : la liste et sa signature sont lues UNE fois en mémoire, et
//! tout est vérifié sur ces octets-là (rien n'est relu entre la vérification et l'usage).

use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::protocole_installateur::lire_json;
use crate::signature::verifier_signature;
use crate::version::plus_recente;
use crate::version_paquet::version_dossier;

/// Le nom du fichier de la liste (publiée, et gardée dans le dossier des données de Mindset).
pub const FICHIER: &str = "apps-en-ligne.json";
/// Le numéro de la liste livrée avec Mindset, dans son dossier `fichiers`.
pub const FICHIER_NUMERO: &str = "apps-liste.txt";
/// Au plus 256 Ko pour la liste.
pub const TAILLE_MAX: u64 = 256 * 1024;
/// Au plus 64 Ko pour sa signature (une vraie fait quelques centaines d'octets).
pub const TAILLE_MAX_SIGNATURE: u64 = 64 * 1024;

/// Pourquoi une liste en ligne n'est pas prise (le texte va au journal).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refus {
    /// Le fichier de la liste est absent ou illisible
    Absente,
    /// Sa signature (`<liste>.sig`) est absente ou illisible
    SignatureAbsente,
    /// Plus de 256 Ko (ou une signature de plus de 64 Ko)
    TropGrosse,
    /// La signature n'est pas valide avec les clés livrées
    SignatureInvalide,
    /// Pas un objet JSON lisible avec `liste`, `mindset_min` et `applis` bien formés
    MalFormee(&'static str),
    /// Le numéro de la liste livrée (`apps-liste.txt`) est absent ou illisible
    NumeroLivreIllisible,
    /// La version de ce Mindset est introuvable
    VersionMindsetIllisible,
    /// Liste faite pour un Mindset plus récent
    PourMindsetPlusRecent { min: String, version: String },
    /// Numéro pas plus grand que celui de la liste livrée
    PasPlusRecente { liste: i64, livree: i64 },
    /// Aucune entrée valable
    AucuneAppliValable,
}

impl fmt::Display for Refus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refus::Absente => write!(f, "fichier absent ou illisible"),
            Refus::SignatureAbsente => write!(f, "signature absente ou illisible"),
            Refus::TropGrosse => write!(f, "fichier trop gros"),
            Refus::SignatureInvalide => write!(f, "signature invalide"),
            Refus::MalFormee(quoi) => write!(f, "liste mal formée ({quoi})"),
            Refus::NumeroLivreIllisible => write!(f, "numéro de la liste livrée ({FICHIER_NUMERO}) illisible"),
            Refus::VersionMindsetIllisible => write!(f, "version de Mindset introuvable"),
            Refus::PourMindsetPlusRecent { min, version } => {
                write!(f, "liste pour Mindset {min} ou plus récent (celui-ci : {version})")
            }
            Refus::PasPlusRecente { liste, livree } => {
                write!(f, "liste {liste} pas plus récente que la liste livrée ({livree})")
            }
            Refus::AucuneAppliValable => write!(f, "aucune appli valable"),
        }
    }
}

/// Une liste acceptée : elle remplace la liste livrée (c'est la liste complète).
#[derive(Debug, Clone, PartialEq)]
pub struct ListeAcceptee {
    pub numero: i64,
    pub mindset_min: String,
    /// Les entrées valables, sans id en double : chaque lecteur les contrôle ensuite comme celles de apps.json
    pub applis: Vec<Value>,
}

/// Lit un fichier une seule fois, sans jamais prendre plus de `max` octets. `Ok(None)` : absent ou illisible.
fn lire_borne(chemin: &Path, max: u64) -> Result<Option<Vec<u8>>, Refus> {
    let Ok(f) = std::fs::File::open(chemin) else { return Ok(None) };
    match f.metadata() {
        Ok(m) if m.is_file() => {
            if m.len() > max {
                return Err(Refus::TropGrosse);
            }
        }
        _ => return Ok(None),
    }
    let mut o = Vec::new();
    // (le fichier peut grandir entre-temps : jamais plus que max + 1 octets lus)
    if f.take(max + 1).read_to_end(&mut o).is_err() {
        return Ok(None);
    }
    if o.len() as u64 > max {
        return Err(Refus::TropGrosse);
    }
    Ok(Some(o))
}

/// Le chemin de la signature d'une liste : `<liste>.sig`.
pub fn chemin_signature(liste: &Path) -> PathBuf {
    let mut s = liste.as_os_str().to_owned();
    s.push(".sig");
    PathBuf::from(s)
}

/// Lit la liste et sa signature (`<liste>.sig`), une seule fois chacune, en mémoire.
pub fn lire_fichiers(liste: &Path) -> Result<(Vec<u8>, Vec<u8>), Refus> {
    let octets = lire_borne(liste, TAILLE_MAX)?.ok_or(Refus::Absente)?;
    let sig = lire_borne(&chemin_signature(liste), TAILLE_MAX_SIGNATURE)?.ok_or(Refus::SignatureAbsente)?;
    Ok((octets, sig))
}

/// Le numéro écrit dans `apps-liste.txt` : un entier positif ou nul (marque UTF-8 et espaces autour permis).
pub fn lire_numero(octets: &[u8]) -> Option<i64> {
    let o = octets.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(octets);
    let t = std::str::from_utf8(o).ok()?.trim();
    if t.is_empty() || t.len() > 15 || !t.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    t.parse().ok()
}

/// Une version de la forme x.y.z (trois nombres).
fn version_xyz(v: &str) -> bool {
    let m: Vec<&str> = v.split('.').collect();
    m.len() == 3 && m.iter().all(|x| !x.is_empty() && x.len() <= 9 && x.bytes().all(|b| b.is_ascii_digit()))
}

/// Un nom de programme seul : `^[^\\/:*?"<>|]+\.exe$` (majuscules permises).
fn programme(nom: &str) -> bool {
    nom.len() > 4
        && nom.to_ascii_lowercase().ends_with(".exe")
        && !nom.chars().any(|c| matches!(c, '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || (c as u32) < 0x20)
}

/// Une entrée bien formée (la base commune des contrôles d'apps.json) : un objet, `id` texte de lettres, chiffres et
/// tirets (`^[a-z0-9-]+$` de Mindset, qui ne tient pas compte des majuscules), `nom` texte non vide, `exe` un nom de
/// programme seul.
pub fn entree_valable(a: &Value) -> bool {
    let Some(o) = a.as_object() else { return false };
    let texte = |n: &str| o.get(n).and_then(Value::as_str);
    texte("id").is_some_and(|id| !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
        && texte("nom").is_some_and(|n| !n.is_empty())
        && texte("exe").is_some_and(programme)
}

/// Les règles 1 à 5 sur des octets déjà lus. `numero_livre` : celui de `apps-liste.txt` (`None` : illisible) ;
/// `version_mindset` : la version de ce Mindset ; `cles` : le dossier des clés publiques livrées.
pub fn accepter(
    octets: &[u8],
    signature: &[u8],
    cles: &Path,
    numero_livre: Option<i64>,
    version_mindset: &str,
) -> Result<ListeAcceptee, Refus> {
    // 1. taille et signature
    if octets.len() as u64 > TAILLE_MAX || signature.len() as u64 > TAILLE_MAX_SIGNATURE {
        return Err(Refus::TropGrosse);
    }
    if signature.is_empty() {
        return Err(Refus::SignatureAbsente);
    }
    if !verifier_signature(octets, signature, cles) {
        return Err(Refus::SignatureInvalide);
    }
    // 2. la forme
    let o = octets.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(octets);
    let texte = std::str::from_utf8(o).map_err(|_| Refus::MalFormee("pas du texte UTF-8"))?;
    let Some(Value::Object(objet)) = lire_json(texte) else {
        return Err(Refus::MalFormee("pas un objet JSON"));
    };
    let numero = objet.get("liste").and_then(Value::as_i64).filter(|n| *n >= 1);
    let Some(numero) = numero else { return Err(Refus::MalFormee("liste")) };
    let min = objet.get("mindset_min").and_then(Value::as_str).filter(|v| version_xyz(v));
    let Some(min) = min else { return Err(Refus::MalFormee("mindset_min")) };
    let applis = objet.get("applis").and_then(Value::as_array).filter(|a| !a.is_empty());
    let Some(applis) = applis else { return Err(Refus::MalFormee("applis")) };
    // 3. pour ce Mindset
    if version_mindset.is_empty() || crate::version::Version::lire(version_mindset).is_none() {
        return Err(Refus::VersionMindsetIllisible);
    }
    if plus_recente(min, version_mindset) {
        return Err(Refus::PourMindsetPlusRecent { min: min.to_string(), version: version_mindset.to_string() });
    }
    // 4. plus récente que la liste livrée
    let livree = numero_livre.ok_or(Refus::NumeroLivreIllisible)?;
    if numero <= livree {
        return Err(Refus::PasPlusRecente { liste: numero, livree });
    }
    // 5. les entrées mal formées ignorées, la première d'un id gagne, au moins une valable
    let mut gardees: Vec<Value> = Vec::new();
    for a in applis.iter().filter(|a| entree_valable(a)) {
        let id = a.get("id").and_then(Value::as_str);
        if !gardees.iter().any(|g| g.get("id").and_then(Value::as_str) == id) {
            gardees.push(a.clone());
        }
    }
    if gardees.is_empty() {
        return Err(Refus::AucuneAppliValable);
    }
    Ok(ListeAcceptee { numero, mindset_min: min.to_string(), applis: gardees })
}

/// Tout en un : la liste `liste` (et `<liste>.sig`), jugée avec les clés, le numéro livré et la version du Mindset
/// installé dans `dossier_mindset` (`<dossier>\fichiers\cles-publiques`, `<dossier>\fichiers\apps-liste.txt`, la
/// version de son dossier).
pub fn lire_et_accepter(liste: &Path, dossier_mindset: &Path) -> Result<ListeAcceptee, Refus> {
    let (octets, sig) = lire_fichiers(liste)?;
    let fichiers = dossier_mindset.join("fichiers");
    let numero = lire_borne(&fichiers.join(FICHIER_NUMERO), 64).ok().flatten().and_then(|o| lire_numero(&o));
    let version = version_dossier(dossier_mindset);
    accepter(&octets, &sig, &fichiers.join("cles-publiques"), numero, &version)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// La clé de TEST de l'installateur (jamais la clé de la suite)
    fn cle_de_test() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join(r"..\mindset-installateur\tests\cle-de-test")
    }

    fn signer(donnees: &[u8]) -> Vec<u8> {
        let pk8 = std::fs::read(cle_de_test().join("privee-de-test.der")).unwrap();
        let cle = ring::signature::RsaKeyPair::from_der(&pk8).unwrap();
        let mut sig = vec![0u8; cle.public().modulus_len()];
        cle.sign(&ring::signature::RSA_PKCS1_SHA256, &ring::rand::SystemRandom::new(), donnees, &mut sig).unwrap();
        sig
    }

    /// Un dossier de test avec la seule clé publique de test
    struct Dossier(PathBuf);
    impl Dossier {
        fn nouveau(nom: &str) -> Dossier {
            let d = std::env::temp_dir().join(format!("suite-commun-liste-{nom}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(d.join("cles")).unwrap();
            std::fs::copy(cle_de_test().join("publique-de-test.xml"), d.join("cles").join("test.xml")).unwrap();
            Dossier(d)
        }
        fn cles(&self) -> PathBuf {
            self.0.join("cles")
        }
    }
    impl Drop for Dossier {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    const APPLIS: &str =
        r#"[{"id":"appli","nom":"Appli","exe":"Appli.exe"},{"id":"nouvelle","nom":"Nouvelle","exe":"Nouvelle.exe"}]"#;

    fn liste(numero: &str, min: &str, applis: &str) -> Vec<u8> {
        format!(r#"{{"liste":{numero},"mindset_min":{min},"applis":{applis}}}"#).into_bytes()
    }

    fn juger(d: &Dossier, o: &[u8], livree: Option<i64>, version: &str) -> Result<ListeAcceptee, Refus> {
        accepter(o, &signer(o), &d.cles(), livree, version)
    }

    #[test]
    fn bonne_liste_acceptee() {
        let d = Dossier::nouveau("bonne");
        let o = liste("4", r#""2.16.0""#, APPLIS);
        let l = juger(&d, &o, Some(3), "2.16.0").unwrap();
        assert_eq!((l.numero, l.mindset_min.as_str(), l.applis.len()), (4, "2.16.0", 2));
        // (marque UTF-8 au début permise, comme pour apps.json)
        let mut avec_marque = b"\xEF\xBB\xBF".to_vec();
        avec_marque.extend_from_slice(&o);
        assert!(juger(&d, &avec_marque, Some(3), "2.17.1").is_ok());
    }

    #[test]
    fn signature_fausse_ou_absente_refusee() {
        let d = Dossier::nouveau("signature");
        let o = liste("4", r#""2.16.0""#, APPLIS);
        // signature d'un autre contenu
        assert_eq!(accepter(&o, &signer(b"autre"), &d.cles(), Some(3), "2.16.0"), Err(Refus::SignatureInvalide));
        // signature vide
        assert_eq!(accepter(&o, &[], &d.cles(), Some(3), "2.16.0"), Err(Refus::SignatureAbsente));
        // modifiée après signature (une entrée ajoutée)
        let sig = signer(&o);
        let modifiee = liste("4", r#""2.16.0""#, r#"[{"id":"piege","nom":"Piege","exe":"Piege.exe"}]"#);
        assert_eq!(accepter(&modifiee, &sig, &d.cles(), Some(3), "2.16.0"), Err(Refus::SignatureInvalide));
        // sans clés : refusée
        assert_eq!(accepter(&o, &sig, &d.0.join("aucune"), Some(3), "2.16.0"), Err(Refus::SignatureInvalide));
    }

    #[test]
    fn fichier_sig_absent_refuse() {
        let d = Dossier::nouveau("sig-absent");
        let f = d.0.join(FICHIER);
        std::fs::write(&f, liste("4", r#""2.16.0""#, APPLIS)).unwrap();
        assert_eq!(lire_fichiers(&f), Err(Refus::SignatureAbsente));
        assert_eq!(lire_fichiers(&d.0.join("absente.json")), Err(Refus::Absente));
        std::fs::write(chemin_signature(&f), signer(&std::fs::read(&f).unwrap())).unwrap();
        assert!(lire_fichiers(&f).is_ok());
    }

    #[test]
    fn numero_pas_plus_grand_refuse() {
        let d = Dossier::nouveau("numero");
        let o = liste("4", r#""2.16.0""#, APPLIS);
        assert_eq!(juger(&d, &o, Some(4), "2.16.0"), Err(Refus::PasPlusRecente { liste: 4, livree: 4 }));
        assert_eq!(juger(&d, &o, Some(9), "2.16.0"), Err(Refus::PasPlusRecente { liste: 4, livree: 9 }));
        assert_eq!(juger(&d, &o, None, "2.16.0"), Err(Refus::NumeroLivreIllisible));
        assert!(juger(&d, &o, Some(3), "2.16.0").is_ok());
        assert!(juger(&d, &o, Some(0), "2.16.0").is_ok());
    }

    #[test]
    fn numero_livre_lu() {
        assert_eq!(lire_numero(b"3"), Some(3));
        assert_eq!(lire_numero(b"\xEF\xBB\xBF 12\r\n"), Some(12));
        assert_eq!(lire_numero(b"0"), Some(0));
        for faux in [&b""[..], b"-1", b"3.0", b"trois", b"1 2", b"99999999999999999999"] {
            assert_eq!(lire_numero(faux), None, "{faux:?}");
        }
    }

    #[test]
    fn mindset_min_trop_haut_refuse() {
        let d = Dossier::nouveau("min");
        let o = liste("4", r#""2.17.0""#, APPLIS);
        assert!(matches!(juger(&d, &o, Some(3), "2.16.9"), Err(Refus::PourMindsetPlusRecent { .. })));
        assert!(juger(&d, &o, Some(3), "2.17.0").is_ok());
        assert_eq!(juger(&d, &o, Some(3), ""), Err(Refus::VersionMindsetIllisible));
    }

    #[test]
    fn json_abime_ou_mal_forme_refuse() {
        let d = Dossier::nouveau("json");
        for (o, quoi) in [
            (b"{ \"liste\": 4, \"mindset_min\": ".to_vec(), "pas un objet JSON"),
            (b"[1, 2]".to_vec(), "pas un objet JSON"),
            (b"\xFF\xFE{}".to_vec(), "pas du texte UTF-8"),
            (br#"{"liste":4,"Liste":5,"mindset_min":"2.16.0","applis":[{"id":"a"}]}"#.to_vec(), "pas un objet JSON"),
            (liste("0", r#""2.16.0""#, APPLIS), "liste"),
            (liste("4.5", r#""2.16.0""#, APPLIS), "liste"),
            (liste(r#""4""#, r#""2.16.0""#, APPLIS), "liste"),
            (liste("4", r#""2.16""#, APPLIS), "mindset_min"),
            (liste("4", r#""2.16.0.1""#, APPLIS), "mindset_min"),
            (liste("4", "2.16", APPLIS), "mindset_min"),
            (liste("4", r#""2.16.0""#, "[]"), "applis"),
            (liste("4", r#""2.16.0""#, r#"{"id":"a"}"#), "applis"),
            // noms des champs exacts, majuscules comprises
            (br#"{"Liste":4,"mindset_min":"2.16.0","applis":[{"id":"a","nom":"A","exe":"A.exe"}]}"#.to_vec(), "liste"),
            (
                br#"{"liste":4,"Mindset_min":"2.16.0","applis":[{"id":"a","nom":"A","exe":"A.exe"}]}"#.to_vec(),
                "mindset_min",
            ),
            (br#"{"liste":4,"mindset_min":"2.16.0","Applis":[{"id":"a","nom":"A","exe":"A.exe"}]}"#.to_vec(), "applis"),
        ] {
            assert_eq!(
                juger(&d, &o, Some(3), "2.16.0"),
                Err(Refus::MalFormee(quoi)),
                "{}",
                String::from_utf8_lossy(&o)
            );
        }
    }

    #[test]
    fn trop_gros_refuse() {
        let d = Dossier::nouveau("gros");
        let mut o = liste("4", r#""2.16.0""#, APPLIS);
        o.extend(std::iter::repeat_n(b' ', TAILLE_MAX as usize + 1 - o.len()));
        assert_eq!(juger(&d, &o, Some(3), "2.16.0"), Err(Refus::TropGrosse));
        // le même fichier sur le disque : refusé avant d'être lu en entier
        let f = d.0.join(FICHIER);
        std::fs::write(&f, &o).unwrap();
        std::fs::write(chemin_signature(&f), signer(&o)).unwrap();
        assert_eq!(lire_fichiers(&f), Err(Refus::TropGrosse));
        // juste à la limite : accepté
        o.pop();
        assert!(juger(&d, &o, Some(3), "2.16.0").is_ok());
    }

    #[test]
    fn id_en_double_la_premiere_gagne() {
        let d = Dossier::nouveau("ids");
        let a = r#"{"id":"appli","nom":"A","exe":"A.exe"}"#;
        let b = r#"{"id":"appli","nom":"B","exe":"B.exe"}"#;
        let l = juger(&d, &liste("4", r#""2.16.0""#, &format!("[{a},{b}]")), Some(3), "2.16.0").unwrap();
        assert_eq!(l.applis.len(), 1);
        assert_eq!(l.applis[0]["nom"], "A");
        // (comparaison exacte : « Appli » est un autre id)
        let c = r#"{"id":"Appli","nom":"C","exe":"C.exe"}"#;
        let l = juger(&d, &liste("4", r#""2.16.0""#, &format!("[{a},{c}]")), Some(3), "2.16.0").unwrap();
        assert_eq!(l.applis.len(), 2);
    }

    #[test]
    fn entrees_mal_formees_ignorees_au_moins_une_valable() {
        let d = Dossier::nouveau("entrees");
        let bonne = r#"{"id":"bonne","nom":"Bonne","exe":"Bonne.exe"}"#;
        let fausses = [
            r#""texte""#,
            r#"{"id":5,"nom":"X","exe":"X.exe"}"#,
            r#"{"id":"a b","nom":"X","exe":"X.exe"}"#,
            r#"{"id":"","nom":"X","exe":"X.exe"}"#,
            r#"{"id":"x","nom":"","exe":"X.exe"}"#,
            r#"{"id":"x","exe":"X.exe"}"#,
            r#"{"id":"x","nom":"X","exe":"..\\X.exe"}"#,
            r#"{"id":"x","nom":"X","exe":"X.bat"}"#,
            r#"{"Id":"x","nom":"X","exe":"X.exe"}"#,
        ];
        let o = liste("4", r#""2.16.0""#, &format!("[{},{bonne}]", fausses.join(",")));
        let l = juger(&d, &o, Some(3), "2.16.0").unwrap();
        assert_eq!(l.applis.len(), 1, "{:?}", l.applis);
        assert_eq!(l.applis[0]["id"], "bonne");
        // aucune valable : refusée
        let o = liste("4", r#""2.16.0""#, &format!("[{}]", fausses.join(",")));
        assert_eq!(juger(&d, &o, Some(3), "2.16.0"), Err(Refus::AucuneAppliValable));
    }

    #[test]
    fn tout_en_un_depuis_le_dossier_de_mindset() {
        let d = Dossier::nouveau("dossier");
        let mindset = d.0.join("Mindset");
        let fichiers = mindset.join("fichiers");
        std::fs::create_dir_all(fichiers.join("cles-publiques")).unwrap();
        std::fs::copy(cle_de_test().join("publique-de-test.xml"), fichiers.join("cles-publiques").join("t.xml"))
            .unwrap();
        std::fs::write(fichiers.join("Mindset.ps1"), "$AppVersion = '2.16.0'\r\n").unwrap();
        std::fs::write(fichiers.join(FICHIER_NUMERO), "3\r\n").unwrap();
        let f = d.0.join(FICHIER);
        let o = liste("4", r#""2.16.0""#, APPLIS);
        std::fs::write(&f, &o).unwrap();
        std::fs::write(chemin_signature(&f), signer(&o)).unwrap();
        assert_eq!(lire_et_accepter(&f, &mindset).unwrap().numero, 4);
        // apps-liste.txt absent : refusée
        std::fs::remove_file(fichiers.join(FICHIER_NUMERO)).unwrap();
        assert_eq!(lire_et_accepter(&f, &mindset), Err(Refus::NumeroLivreIllisible));
        std::fs::write(fichiers.join(FICHIER_NUMERO), "4").unwrap();
        assert!(matches!(lire_et_accepter(&f, &mindset), Err(Refus::PasPlusRecente { .. })));
        // modifiée après signature : refusée
        std::fs::write(fichiers.join(FICHIER_NUMERO), "3").unwrap();
        std::fs::write(&f, liste("4", r#""2.16.0""#, r#"[{"id":"piege","nom":"P","exe":"P.exe"}]"#)).unwrap();
        assert_eq!(lire_et_accepter(&f, &mindset), Err(Refus::SignatureInvalide));
    }
}
