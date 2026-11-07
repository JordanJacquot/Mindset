//! Ce que le bloc demande à Windows, derrière un trait (les tests et la construction d'essai ont un faux) :
//! - la fenêtre « ouvrir un fichier » d'Importer un thème (`Select-FichierThemeSuite`, `Microsoft.Win32.OpenFileDialog`) ;
//! - les noms des micros et des sorties audio (`[MSAudio]::Micros()`, `Sorties()`), lus sans rien ouvrir ;
//! - ce que consomment les programmes de la suite (`[MSProcessus]::Mesurer`) ;
//! - le compte de l'utilisateur (son SID, pour la demande « taches ») et la valeur « Mindset » de la clé Run, retirée
//!   quand le mini-installateur est activé (`Enable-MindsetAdmin`).

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::Value;

/// Ce qu'on mesure (`MSProcessus.Mesurer(moi, nomMoi, dossierMoi, noms, dossiers, nomWebView, marqueurs)`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DemandeMesure {
    pub moi: u32,
    pub nom_moi: String,
    pub dossier_moi: String,
    /// Le nom de chaque partie, et son dossier (même ordre) : le premier dossier qui contient le programme l'emporte
    pub noms: Vec<String>,
    pub dossiers: Vec<String>,
    pub nom_webview: String,
    /// Des morceaux de la ligne de commande des msedgewebview2.exe de la suite (leurs dossiers de données)
    pub marqueurs: Vec<String>,
}

/// Une partie mesurée (`MSProcessus.Partie`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Partie {
    pub nom: String,
    pub nombre: u32,
    /// En octets (mémoire privée)
    pub memoire: i64,
    /// En % de tout le PC depuis la mesure précédente (0 à la première)
    pub processeur: f64,
}

pub trait Plateforme: Send + Sync {
    /// La fenêtre « Choisis le thème de la suite (.zip) » : le fichier choisi, `None` si on annule.
    fn choisir_zip(&self, parent: Option<isize>, dossier_initial: Option<PathBuf>) -> Option<PathBuf>;
    /// Le dossier du Bureau de l'utilisateur.
    fn bureau(&self) -> Option<PathBuf>;
    /// Les noms des micros (waveIn), dans l'ordre de Windows.
    fn micros(&self) -> Vec<String>;
    /// Les noms des sorties audio (waveOut).
    fn sorties(&self) -> Vec<String>;
    /// Ce que consomme chaque partie de la suite.
    fn mesurer(&self, d: &DemandeMesure) -> Vec<Partie>;
    /// Le SID du compte de l'utilisateur.
    fn sid(&self) -> String;
    /// Retire la valeur « Mindset » de `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
    fn retirer_run(&self);
}

/// Le faux de Windows : ce qu'on lui a donné, et ce qu'on lui a demandé.
#[derive(Debug, Default)]
pub struct Fausse {
    pub zip: Mutex<Option<PathBuf>>,
    pub micros: Mutex<Vec<String>>,
    pub sorties: Mutex<Vec<String>>,
    pub parties: Mutex<Vec<Partie>>,
    pub mesures: Mutex<Vec<DemandeMesure>>,
    pub dialogues: Mutex<Vec<Option<PathBuf>>>,
    pub run_retire: Mutex<bool>,
}

fn verrou<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Fausse {
    /// Le faux de la construction d'essai : `essai-parametres.json` dans le dossier des données de Mindset (s'il est
    /// là) donne le zip choisi, les appareils et les mesures, pour les captures.
    pub fn depuis_fichier(f: &Path) -> Fausse {
        let x = Fausse::default();
        let Ok(o) = std::fs::read(f) else { return x };
        let Ok(Value::Object(j)) = serde_json::from_slice::<Value>(&o) else { return x };
        let textes = |n: &str| -> Vec<String> {
            j.get(n)
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                .unwrap_or_default()
        };
        *verrou(&x.micros) = textes("micros");
        *verrou(&x.sorties) = textes("sorties");
        *verrou(&x.zip) = j.get("zip").and_then(Value::as_str).map(PathBuf::from);
        if let Some(a) = j.get("parties").and_then(Value::as_array) {
            *verrou(&x.parties) = a
                .iter()
                .map(|p| Partie {
                    nom: p.get("nom").and_then(Value::as_str).unwrap_or_default().to_string(),
                    nombre: p.get("nombre").and_then(Value::as_u64).unwrap_or(0) as u32,
                    memoire: p.get("memoire").and_then(Value::as_i64).unwrap_or(0),
                    processeur: p.get("processeur").and_then(Value::as_f64).unwrap_or(0.0),
                })
                .collect();
        }
        x
    }

    pub fn mesures(&self) -> Vec<DemandeMesure> {
        verrou(&self.mesures).clone()
    }
}

impl Plateforme for Fausse {
    fn choisir_zip(&self, _parent: Option<isize>, dossier_initial: Option<PathBuf>) -> Option<PathBuf> {
        verrou(&self.dialogues).push(dossier_initial);
        verrou(&self.zip).clone()
    }
    fn bureau(&self) -> Option<PathBuf> {
        None
    }
    fn micros(&self) -> Vec<String> {
        verrou(&self.micros).clone()
    }
    fn sorties(&self) -> Vec<String> {
        verrou(&self.sorties).clone()
    }
    fn mesurer(&self, d: &DemandeMesure) -> Vec<Partie> {
        verrou(&self.mesures).push(d.clone());
        verrou(&self.parties).clone()
    }
    fn sid(&self) -> String {
        "S-1-5-21-1-2-3-1001".into()
    }
    fn retirer_run(&self) {
        *verrou(&self.run_retire) = true;
    }
}
