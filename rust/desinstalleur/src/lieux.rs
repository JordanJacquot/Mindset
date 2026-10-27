//! Où sont les choses : les vrais emplacements (lus par `os::lieux_reels`, jamais dans l'environnement de l'utilisateur),
//! ou ceux d'un faux environnement de test (construction d'essai seulement).

use std::path::{Path, PathBuf};

use crate::texte::{egal, sans_barre, t};

#[derive(Debug, Clone, Default)]
pub struct Lieux {
    /// Faux environnement (tests) : jamais de demande de Windows, rien de réel n'est touché
    pub test: bool,
    pub program_files: PathBuf,
    /// Les dossiers de l'utilisateur qui a lancé la désinstallation (None : inconnus, l'étape est passée)
    pub local_app_data: Option<PathBuf>,
    pub bureau: Option<PathBuf>,
    pub menu: Option<PathBuf>,
    /// Le dossier de la copie temporaire et du journal
    pub temp: PathBuf,
    /// Les disques fixes (« D:\ »...)
    pub disques: Vec<PathBuf>,
    pub cle_desinstall: String,
    pub cle_mindset: String,
    pub cle_run: String,
    pub dossier_taches: String,
}

/// Ajoute un dossier à la liste s'il existe (chemin complet, sans doublon)
fn ajouter(r: &mut Vec<PathBuf>, d: &Path) {
    let complet = std::path::absolute(d).unwrap_or_else(|_| d.to_path_buf());
    let texte = sans_barre(&t(&complet)).to_string();
    let p = PathBuf::from(&texte);
    if p.is_dir() && !r.iter().any(|x| egal(&t(x), &texte)) {
        r.push(p);
    }
}

impl Lieux {
    /// Les dossiers des programmes qui existent : <Program Files>\Mindset, X:\Mindset\Programmes
    pub fn racines_programmes(&self) -> Vec<PathBuf> {
        let mut r = Vec::new();
        ajouter(&mut r, &self.program_files.join("Mindset"));
        for d in &self.disques {
            ajouter(&mut r, &d.join("Mindset").join("Programmes"));
        }
        r
    }

    /// Les dossiers des données qui existent : %LOCALAPPDATA%\Mindset, X:\Mindset\Donnees
    pub fn racines_donnees(&self) -> Vec<PathBuf> {
        let mut r = Vec::new();
        if let Some(l) = &self.local_app_data {
            ajouter(&mut r, &l.join("Mindset"));
        }
        for d in &self.disques {
            ajouter(&mut r, &d.join("Mindset").join("Donnees"));
        }
        r
    }

    /// Faux environnement : tout vient du fichier de test, et les noms de la clé et du dossier de tâches doivent être
    /// des noms de test (une erreur dans le fichier ne peut pas viser les vrais)
    #[cfg(feature = "essai")]
    pub fn de_test(fichier: &Path) -> Result<Lieux, String> {
        let octets = std::fs::read(fichier).map_err(|e| e.to_string())?;
        let texte = String::from_utf8_lossy(octets.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&octets)).into_owned();
        let c: serde_json::Value = serde_json::from_str(&texte).map_err(|e| e.to_string())?;
        let champ = |cle: &str| -> Result<String, String> {
            c.get(cle).and_then(|v| v.as_str()).map(str::to_string).ok_or_else(|| format!("{cle} manque"))
        };
        let registre = champ("Registre")?;
        let taches = champ("Taches")?;
        let hexa = |s: &str| (8..=32).contains(&s.len()) && s.bytes().all(|o| matches!(o, b'0'..=b'9' | b'a'..=b'f'));
        if !registre.strip_prefix("Software\\MindsetTest-").is_some_and(hexa) {
            return Err(format!("Clé de test refusée : {registre}"));
        }
        if !taches.strip_prefix("\\MindsetTest-").is_some_and(hexa) {
            return Err(format!("Dossier de tâches de test refusé : {taches}"));
        }
        let disques = c
            .get("Disques")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|d| d.as_str()).map(PathBuf::from).collect())
            .unwrap_or_default();
        Ok(Lieux {
            test: true,
            program_files: PathBuf::from(champ("ProgramFiles")?),
            local_app_data: Some(PathBuf::from(champ("LocalAppData")?)),
            bureau: Some(PathBuf::from(champ("Bureau")?)),
            menu: Some(PathBuf::from(champ("Menu")?)),
            temp: PathBuf::from(champ("Temp")?),
            disques,
            cle_desinstall: format!("{registre}\\Uninstall\\Mindset"),
            cle_mindset: format!("{registre}\\Mindset"),
            cle_run: format!("{registre}\\Run"),
            dossier_taches: taches,
        })
    }
}

#[cfg(all(test, feature = "essai"))]
mod tests {
    use super::*;

    #[test]
    fn noms_de_test_obligatoires() {
        let d = std::env::temp_dir().join(format!("desinst-lieux-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("test.json");
        let ecrire = |registre: &str, taches: &str| {
            let j = serde_json::json!({ "ProgramFiles": "C:\\pf", "LocalAppData": "C:\\l", "Bureau": "C:\\b", "Menu": "C:\\m",
                "Temp": "C:\\t", "Disques": ["C:\\x"], "Registre": registre, "Taches": taches });
            std::fs::write(&f, j.to_string()).unwrap();
        };
        ecrire("Software\\MindsetTest-0123abcd", "\\MindsetTest-0123abcd");
        let l = Lieux::de_test(&f).unwrap();
        assert!(l.test);
        assert_eq!(l.cle_mindset, "Software\\MindsetTest-0123abcd\\Mindset");
        ecrire("SOFTWARE\\Mindset", "\\MindsetTest-0123abcd");
        assert!(Lieux::de_test(&f).is_err());
        ecrire("Software\\MindsetTest-0123abcd", "\\Mindset");
        assert!(Lieux::de_test(&f).is_err());
        ecrire("Software\\MindsetTest-0123ABCD", "\\MindsetTest-0123abcd");
        assert!(Lieux::de_test(&f).is_err());
        let _ = std::fs::remove_dir_all(&d);
    }
}
