//! Le travail de fond du téléchargement d'une appli (installations.ps1:498-513) : le zip et sa signature depuis
//! GitHub, la signature vérifiée, le dossier principal du zip, son version.json contrôlé avant de fermer l'appli
//! (`Get-Octets`, `Test-Signature`, `Get-DossierZip`, `Test-PaquetAppli` de paquets.ps1), puis les deux fichiers
//! rangés dans `telechargements`.

use mindset_noyau::Progres;
use mindset_noyau::reseau::{DemandeHttp, Reseau};
use serde_json::{Value, json};
use std::io::Read;
use std::path::PathBuf;
use std::sync::Arc;

/// Ce que le travail emporte.
pub struct Travail {
    pub reseau: Arc<dyn Reseau>,
    pub progres: Arc<Progres>,
    pub id: String,
    pub version: String,
    pub url_zip: String,
    pub url_sig: String,
    pub dossiers_zip: Vec<String>,
    pub exe: String,
    pub cles: PathBuf,
    pub telechargements: PathBuf,
    pub version_mindset: String,
}

/// `Test-AdresseTelechargement`
pub fn adresse_permise(url: &str) -> bool {
    ["https://github.com/", "https://objects.githubusercontent.com/", "https://release-assets.githubusercontent.com/"]
        .iter()
        .any(|d| suite_commun::chemins::apres_debut(url, d).is_some())
}

/// `Get-Octets` autour du port réseau : l'adresse (et celle où l'on arrive) vérifiée, 200 Mo et 10 minutes au plus.
pub fn octets(reseau: &dyn Reseau, url: &str, progres: Option<&Progres>) -> Result<Vec<u8>, String> {
    if !adresse_permise(url) {
        return Err(format!("Adresse de téléchargement refusée : {url}"));
    }
    let r = reseau.demander(&DemandeHttp::get(url), progres)?;
    if !r.adresse_finale.is_empty() && !adresse_permise(&r.adresse_finale) {
        return Err(format!("Adresse de téléchargement refusée : {}", r.adresse_finale));
    }
    if r.statut != 200 {
        return Err(format!("Le serveur distant a retourné une erreur : ({}).", r.statut));
    }
    Ok(r.corps)
}

/// Les noms (chemins avec « \ ») des entrées d'un zip, ou `None` s'il est illisible.
pub fn noms_zip(zip: &[u8]) -> Option<Vec<String>> {
    let a = zip::ZipArchive::new(std::io::Cursor::new(zip)).ok()?;
    Some(a.file_names().flatten().map(|n| n.replace('/', "\\")).collect())
}

/// `Get-DossierZip` : le premier des noms donnés qui contient le programme ; sinon le premier nom.
pub fn dossier_zip(zip: &[u8], noms: &[String], exe: &str) -> String {
    let noms: Vec<&String> = noms.iter().filter(|n| !n.is_empty()).collect();
    if let Some(entrees) = noms_zip(zip) {
        for n in &noms {
            let voulu = format!("{}\\{exe}", n.trim_end_matches('\\'));
            if entrees.iter().any(|e| suite_commun::chemins::egal(e, &voulu)) {
                return (*n).clone();
            }
        }
    }
    noms.first().map(|n| (*n).clone()).unwrap_or_default()
}

/// `Get-VersionJsonZip` : (présent, info). Info `None` s'il est illisible ou si les deux (dossier et racine) diffèrent.
pub fn version_json_zip(zip: &[u8], dossier_zip: &str) -> (bool, Option<suite_commun::paquet::InfoVersion>) {
    let Ok(mut a) = zip::ZipArchive::new(std::io::Cursor::new(zip)) else { return (false, None) };
    let json = format!("{}\\version.json", dossier_zip.trim_end_matches('\\'));
    let (mut dans, mut racine): (Option<Vec<u8>>, Option<Vec<u8>>) = (None, None);
    for i in 0..a.len() {
        let Ok(mut e) = a.by_index(i) else { return (false, None) };
        let Ok(nom) = e.name().map(|n| n.to_string()) else { return (false, None) };
        let a_la_racine = nom == "version.json";
        if !a_la_racine && !suite_commun::chemins::egal(&nom.replace('/', "\\"), &json) {
            continue;
        }
        let mut o = Vec::new();
        if e.read_to_end(&mut o).is_err() {
            return (false, None);
        }
        if a_la_racine { racine = Some(o) } else { dans = Some(o) }
    }
    match (dans, racine) {
        (None, None) => (false, None),
        (Some(d), Some(r)) if d != r => (true, None),
        (Some(o), _) | (None, Some(o)) => (true, suite_commun::paquet::lire_version_json(&o)),
    }
}

/// `Test-PaquetAppli` : le version.json d'un zip vérifié avant de fermer quoi que ce soit.
pub fn paquet_appli(zip: &[u8], dossier_zip: &str, appli: &str, version_mindset: &str) -> Result<(), String> {
    let (present, info) = version_json_zip(zip, dossier_zip);
    if !present {
        return Ok(());
    }
    let Some(i) = info else {
        return Err("Le fichier téléchargé ne dit pas quelle version il contient : rien n'a été installé.".into());
    };
    if let Some(a) = i.appli.as_deref().filter(|a| !a.is_empty())
        && !appli.is_empty()
        && !a.eq_ignore_ascii_case(appli)
    {
        return Err(format!("Ce fichier contient l'appli {a} et pas {appli} : rien n'a été installé."));
    }
    if let Some(m) = i.mindset_min.as_deref().filter(|m| !m.is_empty())
        && !version_mindset.is_empty()
        && suite_commun::version::plus_recente(m, version_mindset)
    {
        return Err(format!("Mets d'abord Mindset à jour : cette version demande Mindset {m} ou plus récent."));
    }
    Ok(())
}

impl Travail {
    /// Le travail lui-même (sur un autre fil). Rend `{ version, zip, sig, dossier_zip }`.
    pub fn faire(self) -> Result<Value, String> {
        if self.url_sig.is_empty() {
            return Err(format!("La version {} n'est pas signée : Mindset ne l'installera pas.", self.version));
        }
        let zip = octets(&*self.reseau, &self.url_zip, Some(&self.progres))?;
        let sig = octets(&*self.reseau, &self.url_sig, None)?;
        if !suite_commun::signature::verifier_signature(&zip, &sig, &self.cles) {
            return Err("La signature du fichier téléchargé est invalide : rien n'a été installé.".into());
        }
        let dz = dossier_zip(&zip, &self.dossiers_zip, &self.exe);
        paquet_appli(&zip, &dz, &self.id, &self.version_mindset)?;
        std::fs::create_dir_all(&self.telechargements).map_err(|e| e.to_string())?;
        let fz = self.telechargements.join(format!("{}.zip", self.id));
        let fs = self.telechargements.join(format!("{}.zip.sig", self.id));
        ecrire_entier(&fz, &zip)?;
        ecrire_entier(&fs, &sig)?;
        Ok(
            json!({ "version": self.version, "zip": fz.to_string_lossy(), "sig": fs.to_string_lossy(), "dossier_zip": dz }),
        )
    }
}

/// Écrit à côté puis renomme : jamais un fichier à moitié écrit si Mindset s'arrête en route.
fn ecrire_entier(f: &std::path::Path, o: &[u8]) -> Result<(), String> {
    let tmp = PathBuf::from(format!("{}.tmp", f.display()));
    std::fs::write(&tmp, o).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, f).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })
}
