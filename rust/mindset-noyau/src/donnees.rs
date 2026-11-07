//! Le port vers le disque : les dossiers de la suite, le journal, les réglages, les fichiers JSON sûrs et suite.json
//! (modules\donnees.ps1 et modules\suite.ps1).
//!
//! Le noyau ne fait que décrire ce dont les blocs ont besoin ([`Donnees`]). Le vrai travail (les racines déduites de
//! l'emplacement du programme, les anciens fichiers déplacés, Read-JsonSur et Save-JsonSur avec leurs copies .bak et
//! .abime, les réglages repris d'un fichier abîmé, suite.json) est le bloc « données » (`mindset-donnees`), que l'hôte
//! branche au lancement. Les tests des autres blocs prennent [`DonneesMemoire`], qui écrit seulement dans un dossier
//! d'essai.

use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::contexte::verrou;

/// Les dossiers de Mindset (donnees.ps1:10-58, Mindset.ps1:15-18), calculés une fois au lancement par le bloc
/// « données » (`mindset_donnees::ouvrir`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Dossiers {
    /// Le dossier « fichiers » livré avec Mindset (`$AppDir`) : apps.json, apps-liste.txt, cles-publiques, console.
    pub fichiers: PathBuf,
    /// Le dossier du programme Mindset (`$MonDossier`, celui de Mindset.exe) : `...\Mindset\Mindset` une fois installé.
    pub mindset: PathBuf,
    /// Le programme lui-même (`$AppExe`).
    pub exe: PathBuf,
    /// La racine des programmes de la suite (`$RacineProgrammes`) : `C:\Program Files\Mindset` ou
    /// `X:\Mindset\Programmes`.
    pub programmes: PathBuf,
    /// Les données de la suite (`$SuiteDir`) : `%LOCALAPPDATA%\Mindset` ou `X:\Mindset\Donnees`.
    pub donnees_suite: PathBuf,
    /// Toujours `%LOCALAPPDATA%\Mindset` (`$SuiteFileDir`) : suite.json, afficher-page.txt.
    pub local_mindset: PathBuf,
    /// Les données de Mindset (`$DataDir` = `<donnees_suite>\Mindset`) : journal, réglages, installations.json.
    pub donnees: PathBuf,
    /// La lettre du disque choisi à l'installation, ou vide pour C: (Program Files).
    pub disque: String,
}

impl Dossiers {
    /// `$DataDir\journal.txt`
    pub fn journal(&self) -> PathBuf {
        self.donnees.join("journal.txt")
    }
    /// `$DataDir\reglages.json`
    pub fn reglages(&self) -> PathBuf {
        self.donnees.join("reglages.json")
    }
    /// `$DataDir\installations.json`
    pub fn installations(&self) -> PathBuf {
        self.donnees.join("installations.json")
    }
    /// `$DataDir\telechargements`
    pub fn telechargements(&self) -> PathBuf {
        self.donnees.join("telechargements")
    }
    /// `%LOCALAPPDATA%\Mindset\suite.json`
    pub fn suite(&self) -> PathBuf {
        self.local_mindset.join("suite.json")
    }
    /// `%LOCALAPPDATA%\Mindset\afficher-page.txt` (une page de Mindset demandée par une appli)
    pub fn page_demandee(&self) -> PathBuf {
        self.local_mindset.join("afficher-page.txt")
    }
    /// Le dossier de Mindset installé (`$DossierMindset` = `<programmes>\Mindset`).
    pub fn mindset_installe(&self) -> PathBuf {
        self.programmes.join("Mindset")
    }
    /// Les dossiers d'une installation de test : tout sous `racine` (programmes, données, %LOCALAPPDATA%).
    pub fn sous(racine: &Path) -> Dossiers {
        let programmes = racine.join("Programmes");
        let donnees_suite = racine.join("Donnees");
        Dossiers {
            fichiers: programmes.join(r"Mindset\fichiers"),
            mindset: programmes.join("Mindset"),
            exe: programmes.join(r"Mindset\Mindset.exe"),
            programmes,
            donnees: donnees_suite.join("Mindset"),
            donnees_suite,
            local_mindset: racine.join(r"Local\Mindset"),
            disque: String::new(),
        }
    }
}

/// Ce que l'hôte sait au lancement, avant de connaître les dossiers : ce qu'il donne à `mindset_donnees::ouvrir`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Environnement {
    /// Le programme qui tourne (Mindset.exe)
    pub exe: PathBuf,
    /// `%LOCALAPPDATA%`
    pub localappdata: PathBuf,
    /// Le dossier Program Files (`[Environment]::GetFolderPath('ProgramFiles')`)
    pub program_files: PathBuf,
    /// Construction d'essai : tout sous ce dossier (programmes, données, %LOCALAPPDATA%) comme `Dossiers::sous`, et
    /// HKLM n'est jamais lu (`MINDSET_DONNEES` de la version PowerShell).
    pub essai: Option<PathBuf>,
}

/// Ce que rend `mindset_donnees::ouvrir` : les dossiers, le disque, et les lignes à écrire au journal dès qu'il est
/// prêt (anciens fichiers déplacés, réglages repris d'un fichier abîmé...).
pub struct Ouverture {
    pub dossiers: Dossiers,
    pub donnees: std::sync::Arc<dyn Donnees>,
    pub notes: Vec<String>,
}

/// suite.json lu (`Read-Suite`, suite.ps1:23-39) : thème, micro, casque, applis gérées. `illisible` : pris par un autre
/// programme, il ne doit pas être réécrit à partir de ces valeurs vides.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Suite {
    pub theme: Option<String>,
    pub micro: Option<String>,
    pub casque: Option<String>,
    /// `{ id = dossier }`, dans l'ordre du fichier
    pub applis: Vec<(String, String)>,
    pub illisible: bool,
}

/// Ce que les blocs demandent au disque. Une seule implémentation réelle : le bloc « données ».
///
/// Les écritures se font même en essai : c'est l'implémentation qui garantit qu'un essai n'écrit que dans son dossier
/// d'essai (les dossiers du contexte).
pub trait Donnees: Send + Sync {
    /// Une ligne au journal (`Write-Log`) : « <date au format s> <texte> », UTF-8 sans BOM.
    fn journal(&self, texte: &str);
    /// Un réglage de reglages.json (`Get-Setting`), `None` s'il n'existe pas.
    fn reglage(&self, nom: &str) -> Option<Value>;
    /// Écrit un réglage (`Set-Setting`) ; une écriture impossible est notée au journal, jamais une erreur.
    fn ecrire_reglage(&self, nom: &str, valeur: Value);
    /// `Read-JsonSur` : l'objet du fichier (ou de sa copie .bak), `Ok(None)` s'il n'y en a pas ou s'il est abîmé sans
    /// copie lisible ; `Err` si un autre programme empêche de le lire (l'appelant ne doit alors pas le réécrire).
    fn lire_json(&self, fichier: &Path) -> Result<Option<Value>, String>;
    /// `Save-JsonSur` : écrit à côté (.tmp) puis remplace d'un coup, l'ancien dans .bak.
    fn ecrire_json(&self, fichier: &Path, valeur: &Value) -> Result<(), String>;
    /// `Read-Suite`
    fn suite(&self) -> Suite;
    /// `Get-SuiteTheme` : le thème de la suite, au premier lancement celui d'Evermind ou de Nevermind, sinon « neon ».
    fn theme_suite(&self) -> String;
    /// `Set-SuiteTheme`
    fn ecrire_theme_suite(&self, theme: &str);
    /// `Set-SuiteAppli` : une appli gérée (son dossier), ou retirée (`None`).
    fn ecrire_suite_appli(&self, id: &str, dossier: Option<&str>);
    /// `Get-SuiteSon` : (micro, casque), « » pour ceux de Windows.
    fn son_suite(&self) -> (String, String);
    /// `Set-SuiteSon` : `quoi` = « micro » ou « casque ».
    fn ecrire_son_suite(&self, quoi: &str, nom: &str);
}

/// Un disque d'essai : le journal et les réglages en mémoire, les fichiers JSON dans le dossier d'essai (sans .bak ni
/// mise de côté), suite.json dans `<local_mindset>`. Pour les tests des blocs autres que « données ».
#[derive(Debug)]
pub struct DonneesMemoire {
    pub dossiers: Dossiers,
    journal: Mutex<Vec<String>>,
    reglages: Mutex<Map<String, Value>>,
}

impl DonneesMemoire {
    pub fn nouvelle(dossiers: Dossiers) -> DonneesMemoire {
        DonneesMemoire { dossiers, journal: Mutex::new(Vec::new()), reglages: Mutex::new(Map::new()) }
    }

    /// Les lignes écrites au journal (sans la date).
    pub fn lignes(&self) -> Vec<String> {
        verrou(&self.journal).clone()
    }

    /// Tous les réglages.
    pub fn reglages(&self) -> Map<String, Value> {
        verrou(&self.reglages).clone()
    }

    fn lire_suite_brute(&self) -> Map<String, Value> {
        match self.lire_json(&self.dossiers.suite()) {
            Ok(Some(Value::Object(m))) => m,
            _ => Map::new(),
        }
    }

    fn ecrire_suite_brute(&self, m: Map<String, Value>) {
        let _ = self.ecrire_json(&self.dossiers.suite(), &Value::Object(m));
    }
}

impl Donnees for DonneesMemoire {
    fn journal(&self, texte: &str) {
        verrou(&self.journal).push(texte.to_string());
    }

    fn reglage(&self, nom: &str) -> Option<Value> {
        verrou(&self.reglages).get(nom).cloned()
    }

    fn ecrire_reglage(&self, nom: &str, valeur: Value) {
        verrou(&self.reglages).insert(nom.to_string(), valeur);
    }

    fn lire_json(&self, fichier: &Path) -> Result<Option<Value>, String> {
        let Ok(o) = std::fs::read(fichier) else { return Ok(None) };
        let t = suite_commun::json_sur::texte_du_fichier(&o);
        match serde_json::from_str::<Value>(&t) {
            Ok(v @ Value::Object(_)) => Ok(Some(v)),
            _ => Ok(None),
        }
    }

    fn ecrire_json(&self, fichier: &Path, valeur: &Value) -> Result<(), String> {
        if let Some(d) = fichier.parent() {
            std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
        }
        let t = serde_json::to_string_pretty(valeur).map_err(|e| e.to_string())?;
        let tmp = PathBuf::from(format!("{}.tmp", fichier.display()));
        std::fs::write(&tmp, t).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, fichier).map_err(|e| e.to_string())
    }

    fn suite(&self) -> Suite {
        let m = self.lire_suite_brute();
        let texte = |k: &str| m.get(k).and_then(Value::as_str).map(str::to_string);
        let applis = match m.get("applis") {
            Some(Value::Object(a)) => {
                a.iter().filter_map(|(k, v)| v.as_str().map(|d| (k.clone(), d.to_string()))).collect()
            }
            _ => Vec::new(),
        };
        Suite { theme: texte("theme"), micro: texte("micro"), casque: texte("casque"), applis, illisible: false }
    }

    fn theme_suite(&self) -> String {
        self.suite().theme.unwrap_or_else(|| "neon".into())
    }

    fn ecrire_theme_suite(&self, theme: &str) {
        let mut m = self.lire_suite_brute();
        m.insert("theme".into(), Value::String(theme.into()));
        self.ecrire_suite_brute(m);
    }

    fn ecrire_suite_appli(&self, id: &str, dossier: Option<&str>) {
        let mut m = self.lire_suite_brute();
        let mut applis: BTreeMap<String, Value> = match m.remove("applis") {
            Some(Value::Object(a)) => a.into_iter().collect(),
            _ => BTreeMap::new(),
        };
        match dossier {
            Some(d) => {
                applis.insert(id.into(), Value::String(d.into()));
            }
            None => {
                applis.remove(id);
            }
        }
        m.insert("applis".into(), Value::Object(applis.into_iter().collect()));
        self.ecrire_suite_brute(m);
    }

    fn son_suite(&self) -> (String, String) {
        let s = self.suite();
        (s.micro.unwrap_or_default(), s.casque.unwrap_or_default())
    }

    fn ecrire_son_suite(&self, quoi: &str, nom: &str) {
        if quoi != "micro" && quoi != "casque" {
            return;
        }
        let mut m = self.lire_suite_brute();
        m.insert(quoi.into(), Value::String(nom.into()));
        self.ecrire_suite_brute(m);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disque_d_essai() {
        let racine = crate::dossier_essai("donnees-memoire");
        let _ = std::fs::remove_dir_all(&racine);
        let d = DonneesMemoire::nouvelle(Dossiers::sous(&racine));
        d.journal("bonjour");
        d.ecrire_reglage("MajAuto", Value::Bool(false));
        assert_eq!(d.lignes(), vec!["bonjour"]);
        assert_eq!(d.reglage("MajAuto"), Some(Value::Bool(false)));
        assert_eq!(d.theme_suite(), "neon");
        d.ecrire_suite_appli("nevermind", Some(r"C:\Program Files\Mindset\Nevermind"));
        d.ecrire_theme_suite("rubis");
        let s = d.suite();
        assert_eq!(s.theme.as_deref(), Some("rubis"));
        assert_eq!(s.applis, vec![("nevermind".to_string(), r"C:\Program Files\Mindset\Nevermind".to_string())]);
        d.ecrire_suite_appli("nevermind", None);
        assert!(d.suite().applis.is_empty());
        assert!(d.dossiers.suite().starts_with(&racine), "jamais hors du dossier d'essai");
        let _ = std::fs::remove_dir_all(&racine);
    }
}
