//! La version d'une appli, lue dans son zip avant de l'installer (comme `Get-VersionZip`) ou dans son dossier une
//! fois installée (comme `Get-VersionDossier`), Mindset\fichiers\modules\paquets.ps1.
//!
//! `version.json` d'abord (à la racine du zip, ou dans le dossier de l'appli : plan, section 3.4), puis la ligne
//! `$AppVersion = 'x.y.z'` d'un script de `fichiers\` (les 40 premières lignes), comme aujourd'hui.

use std::io::{Cursor, Read};
use std::path::Path;

use crate::chemins::apres_debut;
use crate::paquet::lire_version_json;
use crate::version::{version_de_ligne, version_scripts};

/// La version contenue dans un zip (ses octets), sans rien extraire : `version.json` à la racine du zip, sinon la
/// ligne `$AppVersion` d'un script `<dossier_zip>\fichiers\*.ps1`. Vide si introuvable ou zip illisible.
pub fn version_zip(zip: &[u8], dossier_zip: &str) -> String {
    let Ok(mut archive) = zip::ZipArchive::new(Cursor::new(zip)) else { return String::new() };
    let prefixe = format!(r"{}\fichiers\", dossier_zip.trim_end_matches('\\'));
    let mut script = String::new();
    for i in 0..archive.len() {
        let options = zip::ZipReadOptions::new().ignore_crc32(true);
        let Ok(mut e) = archive.by_index_with_options(i, options) else { continue };
        let Ok(nom) = e.name() else { continue };
        let nom = nom.replace('/', "\\");
        if nom == "version.json" {
            let mut o = Vec::new();
            if e.by_ref().take(64 * 1024 + 1).read_to_end(&mut o).is_ok()
                && let Some(info) = lire_version_json(&o)
            {
                return info.version;
            }
            continue;
        }
        if !script.is_empty() {
            continue;
        }
        let Some(reste) = apres_debut(&nom, &prefixe) else { continue };
        if reste.is_empty() || reste.contains('\\') || !reste.to_ascii_lowercase().ends_with(".ps1") || reste.len() < 5
        {
            continue;
        }
        let mut o = Vec::new();
        if e.by_ref().take(1024 * 1024).read_to_end(&mut o).is_err() {
            continue;
        }
        // (StreamReader en UTF-8 : la marque du début est ignorée)
        let texte = String::from_utf8_lossy(o.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&o)).into_owned();
        for ligne in texte.split('\n').take(40) {
            if let Some(v) = version_de_ligne(ligne.trim_end_matches('\r')) {
                script = v.to_string();
                break;
            }
        }
    }
    script
}

/// La version d'une appli installée dans `dossier` : son `version.json`, sinon la ligne `$AppVersion` de ses
/// scripts. Vide si introuvable.
pub fn version_dossier(dossier: &Path) -> String {
    if let Ok(o) = std::fs::read(dossier.join("version.json"))
        && let Some(info) = lire_version_json(&o)
    {
        return info.version;
    }
    version_scripts(dossier)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn zip_de(entrees: &[(&str, &str)]) -> Vec<u8> {
        let mut o = Vec::new();
        {
            let mut z = zip::ZipWriter::new(Cursor::new(&mut o));
            for (n, t) in entrees {
                z.start_file(*n, zip::write::SimpleFileOptions::default()).unwrap();
                z.write_all(t.as_bytes()).unwrap();
            }
            z.finish().unwrap();
        }
        o
    }

    #[test]
    fn version_dans_le_zip() {
        let z = zip_de(&[("Appli/Appli.exe", "x"), ("Appli/fichiers/Appli.ps1", "# x\r\n$AppVersion = '2.0.1'\r\n")]);
        assert_eq!(version_zip(&z, "Appli"), "2.0.1");
        assert_eq!(version_zip(&z, "appli"), "2.0.1");
        assert_eq!(version_zip(&z, "Autre"), "");
        let z = zip_de(&[("Appli/fichiers/sous/Appli.ps1", "$AppVersion = '2.0.1'")]);
        assert_eq!(version_zip(&z, "Appli"), "");
        let z =
            zip_de(&[("version.json", r#"{"version":"3.1.0"}"#), ("Appli/fichiers/Appli.ps1", "$AppVersion = '2.0'")]);
        assert_eq!(version_zip(&z, "Appli"), "3.1.0");
        assert_eq!(version_zip(b"pas un zip", "Appli"), "");
    }
}
