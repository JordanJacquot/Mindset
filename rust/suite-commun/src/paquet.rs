//! Installation d'une appli à partir de son zip signé, comme `Install-Paquet` (Mindset\fichiers\modules\paquets.ps1).
//!
//! - Le zip est vérifié puis extrait DEPUIS LA MÉMOIRE : ce qu'on installe est exactement ce qu'on a vérifié.
//! - Seul le contenu du dossier principal du zip (« Appli\... ») est extrait ; tout chemin qui sortirait du dossier
//!   d'arrivée est refusé (zip-slip).
//! - Le nouveau dossier est préparé à côté, puis échangé d'un seul bloc avec l'ancien : une erreur en route laisse
//!   l'ancien intact.
//! - Jamais de retour en arrière : une version plus ancienne que celle installée (ou que la plus haute déjà installée
//!   sur ce PC) est refusée, même signée ; un zip dont on ne lit pas la version aussi.
//!
//! La version est lue dans `version.json` s'il existe (plan, section 3.4), sinon sur l'ancienne ligne
//! `$AppVersion = '...'` des scripts. Les messages d'erreur sont ceux de la version PowerShell, mot pour mot.

use std::fmt;
use std::io::{Cursor, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::signature::verifier_signature;
use crate::texte::{SansMarque, commence_par_sans_casse, decoder_fichier, depuis_cp1252, egal_sans_casse};
use crate::version::{forme_valide, plus_recente, version_scripts};

/// Ce qu'il faut pour installer un zip.
#[derive(Debug, Clone)]
pub struct Demande<'a> {
    /// Le zip téléchargé (ses octets)
    pub zip: &'a [u8],
    /// Sa signature (le fichier .sig)
    pub signature: &'a [u8],
    /// Le dossier des clés publiques de la suite (ou un seul fichier de clé)
    pub cles: &'a Path,
    /// Le dossier où installer l'appli
    pub destination: &'a Path,
    /// Le dossier principal du zip (« Nevermind », « Evermind »...)
    pub dossier_zip: &'a str,
    /// Le programme qui doit s'y trouver (« Nevermind.exe »...)
    pub exe: &'a str,
    /// La plus haute version de l'appli déjà installée sur ce PC (une version plus ancienne est refusée)
    pub version_minimale: Option<&'a str>,
    /// Pour `version.json` : le nom de l'appli attendue (un zip d'une autre appli est refusé)
    pub appli: Option<&'a str>,
    /// Pour `version.json` : la version de Mindset qui installe (comparée à `mindset_min`)
    pub version_mindset: Option<&'a str>,
}

/// Pourquoi une installation a été refusée.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Erreur {
    /// La signature ne correspond à aucune clé de la liste
    Signature,
    /// Un chemin du zip sortirait du dossier d'arrivée (le nom de l'entrée, tel qu'écrit dans le zip)
    CheminRefuse(String),
    /// Le programme attendu n'est pas dans le dossier principal du zip
    ExeManquant { exe: String, dossier_zip: String },
    /// Aucune version lisible dans le zip
    VersionIllisible,
    /// Une version plus récente est déjà installée
    VersionInstallee { nouvelle: String, installee: String },
    /// Une version plus récente a déjà été installée sur ce PC
    VersionMinimale { nouvelle: String, minimale: String },
    /// `version.json` annonce une autre appli
    AutreAppli { trouvee: String, attendue: String },
    /// `version.json` demande un Mindset plus récent
    MindsetTropAncien { demande: String },
    /// Les fichiers sont utilisés (appli ouverte, antivirus) : le message à montrer
    Bloque(String),
    /// Toute autre erreur (zip illisible, nom de fichier impossible, disque...) : son détail
    Autre(String),
}

impl Erreur {
    /// Une courte catégorie, pour le banc d'essai (les mêmes que celles relevées côté PowerShell).
    pub fn categorie(&self) -> &'static str {
        match self {
            Erreur::Signature => "signature",
            Erreur::CheminRefuse(_) => "chemin",
            Erreur::ExeManquant { .. } => "exe",
            Erreur::VersionIllisible => "version-illisible",
            Erreur::VersionInstallee { .. } => "version-installee",
            Erreur::VersionMinimale { .. } => "version-minimale",
            Erreur::AutreAppli { .. } => "autre-appli",
            Erreur::MindsetTropAncien { .. } => "mindset-trop-ancien",
            Erreur::Bloque(_) => "bloque",
            Erreur::Autre(_) => "autre",
        }
    }
}

impl fmt::Display for Erreur {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Erreur::Signature => write!(f, "La signature du fichier téléchargé est invalide : rien n'a été installé."),
            Erreur::CheminRefuse(nom) => write!(f, "Chemin refusé dans le zip : {nom}"),
            Erreur::ExeManquant { exe, dossier_zip } => {
                write!(f, "Le zip ne contient pas {exe} dans le dossier {dossier_zip}.")
            }
            Erreur::VersionIllisible => {
                write!(f, "Le fichier téléchargé ne dit pas quelle version il contient : rien n'a été installé.")
            }
            Erreur::VersionInstallee { nouvelle, installee } => {
                write!(f, "Version {nouvelle} refusée : la version {installee}, plus récente, est déjà installée.")
            }
            Erreur::VersionMinimale { nouvelle, minimale } => write!(
                f,
                "Version {nouvelle} refusée : la version {minimale}, plus récente, a déjà été installée sur ce PC."
            ),
            Erreur::AutreAppli { trouvee, attendue } => {
                write!(f, "Ce fichier contient l'appli {trouvee} et pas {attendue} : rien n'a été installé.")
            }
            Erreur::MindsetTropAncien { demande } => {
                write!(f, "Mets d'abord Mindset à jour : cette version demande Mindset {demande} ou plus récent.")
            }
            Erreur::Bloque(m) | Erreur::Autre(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for Erreur {}

fn autre(e: impl fmt::Display) -> Erreur {
    Erreur::Autre(e.to_string())
}

/// Ce que dit `version.json`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InfoVersion {
    pub version: String,
    pub appli: Option<String>,
    pub mindset_min: Option<String>,
}

/// Lit le texte d'un `version.json` : un objet avec `version` (« 2.0.0 », obligatoire), et si présents `appli`
/// et `mindset_min` (textes). `None` s'il est illisible ou mal formé.
pub fn lire_version_json(octets: &[u8]) -> Option<InfoVersion> {
    if octets.len() > 64 * 1024 {
        return None;
    }
    let texte = decoder_fichier(octets, SansMarque::Utf8);
    let valeur: serde_json::Value = serde_json::from_str(&texte).ok()?;
    let objet = valeur.as_object()?;
    let version = objet.get("version")?.as_str()?.to_string();
    if !forme_valide(&version) {
        return None;
    }
    let texte_facultatif = |cle: &str| -> Option<Option<String>> {
        match objet.get(cle) {
            None => Some(None),
            Some(v) => v.as_str().map(|s| Some(s.to_string())),
        }
    };
    let appli = texte_facultatif("appli")?;
    let mindset_min = texte_facultatif("mindset_min")?;
    if mindset_min.as_deref().is_some_and(|m| !forme_valide(m)) {
        return None;
    }
    Some(InfoVersion { version, appli, mindset_min })
}

/// La version d'une appli installée (ou prête à l'être) dans `dossier` : `version.json` d'abord, sinon la ligne
/// `$AppVersion` de ses scripts. Vide si introuvable ; `Err` si `version.json` existe mais est illisible.
fn version_dossier(dossier: &Path) -> Result<(String, Option<InfoVersion>), ()> {
    let fichier = dossier.join("version.json");
    if fichier.is_file() {
        let info = std::fs::read(&fichier).ok().and_then(|o| lire_version_json(&o)).ok_or(())?;
        return Ok((info.version.clone(), Some(info)));
    }
    Ok((version_scripts(dossier), None))
}

/// Le nom d'une entrée du zip, décodé comme .NET Framework : en UTF-8 si le zip le dit (drapeau « langue »),
/// sinon dans la page de code de Windows (1252).
fn nom_entree(brut: &[u8], drapeaux: u16) -> String {
    if drapeaux & 0x0800 != 0 { String::from_utf8_lossy(brut).into_owned() } else { depuis_cp1252(brut) }
}

/// Le nom brut d'une entrée et ses drapeaux, lus dans l'en-tête du répertoire central qui commence à `debut`
/// (signature PK, drapeaux à +8, longueur du nom à +28, nom à +46).
fn nom_central(zip: &[u8], debut: u64) -> Option<(&[u8], u16)> {
    let d = usize::try_from(debut).ok()?;
    let entete = zip.get(d..d.checked_add(46)?)?;
    if entete[..4] != [0x50, 0x4B, 0x01, 0x02] {
        return None;
    }
    let drapeaux = u16::from_le_bytes([entete[8], entete[9]]);
    let longueur = usize::from(u16::from_le_bytes([entete[28], entete[29]]));
    Some((zip.get(d + 46..d + 46 + longueur)?, drapeaux))
}

/// « : » (flux NTFS cachés, lecteurs) et les jokers « * ? » : GetFullPath de .NET refuse alors l'entrée par une
/// erreur. (Les autres caractères interdits ont déjà fait voir le zip comme vide.)
fn nom_impossible(rel: &str) -> bool {
    rel.chars().any(|c| matches!(c, ':' | '*' | '?'))
}

/// Renomme un dossier d'un seul bloc, en réessayant pendant 3 secondes (comme `Move-DossierEssais`) : un programme
/// qui vient de se fermer, ou l'antivirus, garde ses fichiers un court moment.
fn deplacer_avec_essais(de: &Path, vers: &Path) -> bool {
    for _ in 0..6 {
        if std::fs::rename(de, vers).is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    false
}

/// Le chemin complet, comme `[IO.Path]::GetFullPath` (Windows : GetFullPathNameW).
fn chemin_complet(p: &Path) -> Result<PathBuf, Erreur> {
    std::path::absolute(p).map_err(autre)
}

/// Huit caractères au hasard (le suffixe des dossiers temporaires, comme un morceau de GUID).
fn suffixe_au_hasard() -> Result<String, Erreur> {
    use ring::rand::SecureRandom;
    let mut o = [0u8; 4];
    ring::rand::SystemRandom::new().fill(&mut o).map_err(|_| autre("Pas de nombre au hasard"))?;
    Ok(o.iter().map(|b| format!("{b:02x}")).collect())
}

fn supprimer_dossier(p: &Path) {
    let _ = std::fs::remove_dir_all(p);
}

/// Extrait le dossier principal du zip dans `tmp` (qui n'existe pas encore). Rend le `version.json` de la racine
/// du zip s'il y en a un (hors du dossier principal).
fn extraire(
    zip: &[u8],
    archive: &mut zip::ZipArchive<Cursor<&[u8]>>,
    tmp: &Path,
    dossier_zip: &str,
) -> Result<Option<Vec<u8>>, Erreur> {
    let tmp_texte = tmp.to_string_lossy().into_owned();
    let racine = format!("{tmp_texte}\\");
    let prefixe = format!("{}\\", dossier_zip.trim_end_matches('\\'));
    let mut version_racine = None;
    std::fs::create_dir_all(tmp).map_err(autre)?;
    // Les noms, relus tels qu'écrits dans le répertoire central du zip, comme .NET : la bibliothèque zip les
    // remplacerait par un éventuel « nom Unicode » caché dans les champs en plus, que .NET ignore.
    let mut noms = Vec::with_capacity(archive.len());
    for i in 0..archive.len() {
        let debut = archive.by_index_raw(i).map_err(autre)?.central_header_start();
        let (brut, drapeaux) =
            nom_central(zip, debut).ok_or_else(|| autre("Le zip est abîmé (répertoire central illisible)."))?;
        noms.push(nom_entree(brut, drapeaux));
    }
    // Un seul nom avec « " < > | » ou un caractère de contrôle, et .NET ne sait plus lire la liste des entrées :
    // Mindset (PowerShell) voit alors un zip vide (et refuse ensuite : programme absent). Même chose ici.
    if noms.iter().any(|n| n.chars().any(|c| matches!(c, '"' | '<' | '>' | '|') || u32::from(c) < 32)) {
        return Ok(None);
    }
    for (i, nom_zip) in noms.into_iter().enumerate() {
        let nom = nom_zip.replace('/', "\\");
        // (le contrôle CRC des entrées est laissé de côté, comme .NET : la signature couvre déjà tout le zip)
        let options = || zip::ZipReadOptions::new().ignore_crc32(true);
        if nom_zip == "version.json" {
            let mut o = Vec::new();
            archive.by_index_with_options(i, options()).map_err(autre)?.read_to_end(&mut o).map_err(autre)?;
            version_racine = Some(o);
            continue;
        }
        let Some(debut) = commence_par_sans_casse(&nom, &prefixe) else { continue };
        let rel = &nom[debut..];
        if rel.is_empty() || rel.ends_with('\\') {
            continue;
        }
        if nom_impossible(rel) {
            return Err(autre(format!("Nom de fichier impossible dans le zip : {nom_zip}")));
        }
        // Join-Path ne double pas la barre ; GetFullPath résout « . » et « .. »
        let cible = chemin_complet(Path::new(&format!("{tmp_texte}\\{}", rel.trim_start_matches('\\'))))?;
        let cible_texte = cible.to_string_lossy();
        if commence_par_sans_casse(&cible_texte, &racine).is_none() {
            return Err(Erreur::CheminRefuse(nom_zip));
        }
        if let Some(parent) = cible.parent() {
            std::fs::create_dir_all(parent).map_err(autre)?;
        }
        let mut entree = archive.by_index_with_options(i, options()).map_err(autre)?;
        let mut fichier = std::fs::File::create(&cible).map_err(autre)?;
        std::io::copy(&mut entree, &mut fichier).map_err(autre)?;
        fichier.flush().map_err(autre)?;
    }
    Ok(version_racine)
}

/// Installe (ou remplace) une appli à partir de son zip signé. Rend le dossier installé (chemin complet).
pub fn installer(d: &Demande<'_>) -> Result<PathBuf, Erreur> {
    if !verifier_signature(d.zip, d.signature, d.cles) {
        return Err(Erreur::Signature);
    }
    installer_verifie(d)
}

/// La suite de [`installer`], une fois la signature vérifiée (à part pour les tests, qui n'ont pas de clé privée).
fn installer_verifie(d: &Demande<'_>) -> Result<PathBuf, Erreur> {
    let dest_texte = d.destination.to_string_lossy();
    let destination = chemin_complet(Path::new(dest_texte.trim_end_matches('\\')))?;
    let dest_texte = destination.to_string_lossy().into_owned();
    let parent = destination.parent().ok_or_else(|| autre("Dossier d'arrivée sans parent."))?.to_path_buf();
    std::fs::create_dir_all(&parent).map_err(autre)?;
    // Restes d'une installation interrompue
    if let Ok(entrees) = std::fs::read_dir(&parent) {
        for e in entrees.flatten() {
            let p = e.path();
            let texte = p.to_string_lossy();
            let reste = [".nouveau-", ".ancien-"]
                .iter()
                .any(|s| commence_par_sans_casse(&texte, &format!("{dest_texte}{s}")).is_some());
            if reste && e.file_type().is_ok_and(|t| t.is_dir()) {
                supprimer_dossier(&p);
            }
        }
    }

    let suffixe = suffixe_au_hasard()?;
    let tmp = PathBuf::from(format!("{dest_texte}.nouveau-{suffixe}"));
    let mut archive = zip::ZipArchive::new(Cursor::new(d.zip)).map_err(autre)?;
    let version_racine = match extraire(d.zip, &mut archive, &tmp, d.dossier_zip) {
        Ok(v) => v,
        Err(e) => {
            supprimer_dossier(&tmp);
            return Err(e);
        }
    };
    let refuser = |e: Erreur| -> Result<PathBuf, Erreur> {
        supprimer_dossier(&tmp);
        Err(e)
    };
    // (Join-Path : une barre au début du nom ne repart pas de la racine du disque)
    let exe = PathBuf::from(format!("{}\\{}", tmp.to_string_lossy(), d.exe.trim_start_matches('\\')));
    if !exe.exists() {
        return refuser(Erreur::ExeManquant { exe: d.exe.to_string(), dossier_zip: d.dossier_zip.to_string() });
    }
    // version.json à la racine du zip : rangé avec l'appli (pour les comparaisons suivantes) ; s'il y en a aussi
    // un dans le dossier principal, les deux doivent être identiques.
    if let Some(o) = version_racine {
        let dans_dossier = tmp.join("version.json");
        match std::fs::read(&dans_dossier) {
            Ok(existant) if existant != o => return refuser(Erreur::VersionIllisible),
            Ok(_) => {}
            Err(_) => {
                if let Err(e) = std::fs::write(&dans_dossier, &o) {
                    return refuser(autre(e));
                }
            }
        }
    }

    // Jamais de retour en arrière ; une version illisible est refusée aussi
    let (nouvelle, info) = match version_dossier(&tmp) {
        Ok(v) => v,
        Err(()) => return refuser(Erreur::VersionIllisible),
    };
    if nouvelle.is_empty() {
        return refuser(Erreur::VersionIllisible);
    }
    if let Some(info) = &info {
        // L'ancienne ligne $AppVersion, si elle est encore là, doit dire la même chose
        let ancienne = version_scripts(&tmp);
        if !ancienne.is_empty() && ancienne != info.version {
            return refuser(Erreur::VersionIllisible);
        }
        if let (Some(trouvee), Some(attendue)) = (&info.appli, d.appli)
            && !egal_sans_casse(trouvee, attendue)
        {
            return refuser(Erreur::AutreAppli { trouvee: trouvee.clone(), attendue: attendue.to_string() });
        }
        if let (Some(demande), Some(mindset)) = (&info.mindset_min, d.version_mindset)
            && plus_recente(demande, mindset)
        {
            return refuser(Erreur::MindsetTropAncien { demande: demande.clone() });
        }
    }
    // La version installée : un version.json abîmé chez l'utilisateur ne bloque pas, l'ancienne lecture prend
    // le relais
    let installee = version_dossier(&destination).map(|v| v.0).unwrap_or_else(|()| version_scripts(&destination));
    if !installee.is_empty() && plus_recente(&installee, &nouvelle) {
        return refuser(Erreur::VersionInstallee { nouvelle, installee });
    }
    if let Some(minimale) = d.version_minimale.filter(|m| !m.is_empty())
        && plus_recente(minimale, &nouvelle)
    {
        return refuser(Erreur::VersionMinimale { nouvelle, minimale: minimale.to_string() });
    }

    // Mise à jour de Mindset lui-même : l'utilisateur n'a rien à faire, Mindset réessaiera tout seul
    let message_bloque = |m: &str| -> Erreur {
        if egal_sans_casse(d.exe, "Mindset.exe") {
            Erreur::Bloque(
                "Des fichiers de Mindset étaient encore utilisés par Windows ou par l'antivirus, il n'y a rien à faire de ton côté."
                    .to_string(),
            )
        } else {
            Erreur::Bloque(m.to_string())
        }
    };
    if destination.exists() {
        let ancien = PathBuf::from(format!("{dest_texte}.ancien-{suffixe}"));
        if !deplacer_avec_essais(&destination, &ancien) {
            return refuser(message_bloque(
                "L'appli est encore ouverte (ses fichiers sont utilisés) : ferme-la puis réessaie.",
            ));
        }
        if !deplacer_avec_essais(&tmp, &destination) {
            // On remet l'ancienne version telle quelle
            if let Err(e) = std::fs::rename(&ancien, &destination) {
                return refuser(autre(e));
            }
            return refuser(message_bloque(
                "La nouvelle version n'a pas pu être mise en place (fichiers bloqués) : réessaie dans un moment.",
            ));
        }
        supprimer_dossier(&ancien); // (sinon, nettoyé la prochaine fois)
    } else if !deplacer_avec_essais(&tmp, &destination) {
        return refuser(message_bloque(
            "L'appli n'a pas pu être mise en place (fichiers bloqués) : réessaie dans un moment.",
        ));
    }
    Ok(destination)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Un dossier d'essai neuf sous le dossier temporaire, effacé à la fin.
    struct Dossier(PathBuf);
    impl Dossier {
        fn nouveau(nom: &str) -> Dossier {
            let d = std::env::temp_dir().join(format!("suite-commun-paquet-{nom}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            Dossier(d)
        }
    }
    impl Drop for Dossier {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// Un zip en mémoire : (nom, contenu)
    fn zip_de(entrees: &[(&str, &str)]) -> Vec<u8> {
        let mut z = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (nom, contenu) in entrees {
            z.start_file(*nom, o).unwrap();
            z.write_all(contenu.as_bytes()).unwrap();
        }
        z.finish().unwrap().into_inner()
    }

    fn demande<'a>(zip: &'a [u8], dest: &'a Path) -> Demande<'a> {
        Demande {
            zip,
            signature: &[],
            cles: Path::new(""),
            destination: dest,
            dossier_zip: "Appli",
            exe: "Appli.exe",
            version_minimale: None,
            appli: Some("appli"),
            version_mindset: Some("2.15.0"),
        }
    }

    fn json(version: &str) -> String {
        format!(r#"{{ "appli": "appli", "version": "{version}", "mindset_min": "2.15.0" }}"#)
    }

    #[test]
    fn signature_fausse_refusee() {
        let d = Dossier::nouveau("signature");
        let z = zip_de(&[("Appli/Appli.exe", "x"), ("Appli/version.json", &json("1.0.0"))]);
        let dest = d.0.join("Appli");
        let mut dm = demande(&z, &dest);
        dm.signature = &[1, 2, 3];
        assert_eq!(installer(&dm), Err(Erreur::Signature));
        assert!(!dest.exists());
    }

    #[test]
    fn appli_rust_sans_appversion_avec_version_json() {
        let d = Dossier::nouveau("json");
        let dest = d.0.join("Programmes").join("Appli");
        let z = zip_de(&[("Appli/Appli.exe", "x"), ("Appli/version.json", &json("2.0.0"))]);
        assert_eq!(installer_verifie(&demande(&z, &dest)).unwrap(), dest);
        assert!(dest.join("version.json").is_file());
        // Une version plus ancienne, lue elle aussi dans version.json : refusée
        let z = zip_de(&[("Appli/Appli.exe", "x"), ("Appli/version.json", &json("1.9.0"))]);
        let e = installer_verifie(&demande(&z, &dest)).unwrap_err();
        assert_eq!(e, Erreur::VersionInstallee { nouvelle: "1.9.0".into(), installee: "2.0.0".into() });
        // Plus récente : acceptée
        let z = zip_de(&[("Appli/Appli.exe", "y"), ("Appli/version.json", &json("2.1.0"))]);
        installer_verifie(&demande(&z, &dest)).unwrap();
        assert_eq!(std::fs::read_to_string(dest.join("Appli.exe")).unwrap(), "y");
    }

    #[test]
    fn version_json_a_la_racine_du_zip_range_avec_l_appli() {
        let d = Dossier::nouveau("racine");
        let dest = d.0.join("Appli");
        let z = zip_de(&[("version.json", &json("3.0.0")), ("Appli/Appli.exe", "x")]);
        installer_verifie(&demande(&z, &dest)).unwrap();
        assert_eq!(lire_version_json(&std::fs::read(dest.join("version.json")).unwrap()).unwrap().version, "3.0.0");
        // À la racine ET dans le dossier, différents : refusé
        let z = zip_de(&[
            ("version.json", &json("3.1.0")),
            ("Appli/version.json", &json("3.2.0")),
            ("Appli/Appli.exe", "x"),
        ]);
        assert_eq!(installer_verifie(&demande(&z, &dest)), Err(Erreur::VersionIllisible));
    }

    #[test]
    fn version_json_et_appversion_doivent_dire_pareil() {
        let d = Dossier::nouveau("deux-versions");
        let dest = d.0.join("Appli");
        let ps1 = "$AppVersion = '2.0.0'";
        let z = zip_de(&[
            ("Appli/Appli.exe", "x"),
            ("Appli/fichiers/Appli.ps1", ps1),
            ("Appli/version.json", &json("2.0.0")),
        ]);
        installer_verifie(&demande(&z, &dest)).unwrap();
        let z = zip_de(&[
            ("Appli/Appli.exe", "x"),
            ("Appli/fichiers/Appli.ps1", ps1),
            ("Appli/version.json", &json("2.0.1")),
        ]);
        assert_eq!(installer_verifie(&demande(&z, &dest)), Err(Erreur::VersionIllisible));
    }

    #[test]
    fn version_json_abime_ou_incomplet_refuse() {
        let d = Dossier::nouveau("json-abime");
        let dest = d.0.join("Appli");
        for texte in [
            "{ \"version\": \"2.0\"",
            "[\"2.0.0\"]",
            "{ \"appli\": \"appli\" }",
            "{ \"version\": 2 }",
            "{ \"version\": \"deux\" }",
            "{ \"version\": \"1.2.3.4.5\" }",
            "{ \"version\": \"2.0.0\", \"mindset_min\": \"bientôt\" }",
            "{ \"version\": \"2.0.0\", \"appli\": 7 }",
        ] {
            let z = zip_de(&[("Appli/Appli.exe", "x"), ("Appli/version.json", texte)]);
            assert_eq!(installer_verifie(&demande(&z, &dest)), Err(Erreur::VersionIllisible), "{texte}");
            assert!(!dest.exists());
        }
        // Avec une marque UTF-8 (BOM) : lisible
        let z = zip_de(&[("Appli/Appli.exe", "x"), ("Appli/version.json", "\u{FEFF}{ \"version\": \"2.0.0\" }")]);
        installer_verifie(&demande(&z, &dest)).unwrap();
    }

    #[test]
    fn zip_d_une_autre_appli_refuse() {
        let d = Dossier::nouveau("autre-appli");
        let dest = d.0.join("Appli");
        let z = zip_de(&[
            ("Appli/Appli.exe", "x"),
            ("Appli/version.json", r#"{ "appli": "evermind", "version": "1.0.0" }"#),
        ]);
        let e = installer_verifie(&demande(&z, &dest)).unwrap_err();
        assert_eq!(e.categorie(), "autre-appli");
        assert_eq!(e.to_string(), "Ce fichier contient l'appli evermind et pas appli : rien n'a été installé.");
        // Même nom, autres majuscules : accepté
        let z =
            zip_de(&[("Appli/Appli.exe", "x"), ("Appli/version.json", r#"{ "appli": "APPLI", "version": "1.0.0" }"#)]);
        installer_verifie(&demande(&z, &dest)).unwrap();
    }

    #[test]
    fn mindset_trop_ancien() {
        let d = Dossier::nouveau("mindset-min");
        let dest = d.0.join("Appli");
        let z = zip_de(&[
            ("Appli/Appli.exe", "x"),
            ("Appli/version.json", r#"{ "version": "1.0.0", "mindset_min": "2.16.0" }"#),
        ]);
        let e = installer_verifie(&demande(&z, &dest)).unwrap_err();
        assert_eq!(e, Erreur::MindsetTropAncien { demande: "2.16.0".into() });
        assert!(e.to_string().starts_with("Mets d'abord Mindset à jour"));
        assert!(!dest.exists());
        let z = zip_de(&[
            ("Appli/Appli.exe", "x"),
            ("Appli/version.json", r#"{ "version": "1.0.0", "mindset_min": "2.15.0" }"#),
        ]);
        installer_verifie(&demande(&z, &dest)).unwrap();
    }

    #[test]
    fn version_json_abime_chez_l_utilisateur_l_ancienne_lecture_prend_le_relais() {
        let d = Dossier::nouveau("json-installe-abime");
        let dest = d.0.join("Appli");
        std::fs::create_dir_all(dest.join("fichiers")).unwrap();
        std::fs::write(dest.join("version.json"), "abîmé").unwrap();
        std::fs::write(dest.join("fichiers").join("Appli.ps1"), "$AppVersion = '5.0.0'").unwrap();
        let z = zip_de(&[("Appli/Appli.exe", "x"), ("Appli/version.json", &json("4.0.0"))]);
        let e = installer_verifie(&demande(&z, &dest)).unwrap_err();
        assert_eq!(e, Erreur::VersionInstallee { nouvelle: "4.0.0".into(), installee: "5.0.0".into() });
    }

    #[test]
    fn zip_slip_et_exe_manquant() {
        let d = Dossier::nouveau("slip");
        let dest = d.0.join("a").join("Appli");
        let z =
            zip_de(&[("Appli/Appli.exe", "x"), ("Appli/version.json", &json("1.0.0")), ("Appli/../../piege.txt", "p")]);
        let e = installer_verifie(&demande(&z, &dest)).unwrap_err();
        assert_eq!(e, Erreur::CheminRefuse("Appli/../../piege.txt".into()));
        assert!(!d.0.join("piege.txt").exists());
        assert_eq!(std::fs::read_dir(d.0.join("a")).unwrap().count(), 0, "aucun reste");
        let z = zip_de(&[("Appli/version.json", &json("1.0.0"))]);
        let e = installer_verifie(&demande(&z, &dest)).unwrap_err();
        assert_eq!(e.to_string(), "Le zip ne contient pas Appli.exe dans le dossier Appli.");
    }

    #[test]
    fn lecture_de_version_json() {
        let i = lire_version_json(br#"{ "appli": "nevermind", "version": "2.0.0", "mindset_min": "2.15.0" }"#).unwrap();
        assert_eq!(i.version, "2.0.0");
        assert_eq!(i.appli.as_deref(), Some("nevermind"));
        assert_eq!(i.mindset_min.as_deref(), Some("2.15.0"));
        assert!(lire_version_json(&[b' '; 70_000]).is_none());
    }
}
