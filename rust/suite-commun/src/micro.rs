//! Le micro et le casque de toute la suite, choisis dans Mindset (Paramètres, Son) et écrits dans
//! `%LOCALAPPDATA%\Mindset\suite.json` : `"micro"` et `"casque"`. Les applis les suivent (Evermind, la dictée de
//! Mindcare) ; ce module les lit et les retrouve parmi les appareils du PC, exactement comme le PowerShell :
//! - Mindset : `Read-Suite` et `Test-NomAppareil` (Mindset\fichiers\modules\suite.ps1) ;
//! - Mindcare : `Read-Suite` (modules\mindset.ps1) et `Get-DicteeMicro` (modules\dictee.ps1) ;
//! - Evermind : `Read-Suite` (modules\mindset.ps1), `Set-MicroActif` et `Set-CasqueActif` (modules\voix.ps1).
//!
//! Le choix est gardé par le NOM de l'appareil, celui que donne `waveInGetDevCapsW` (ou `waveOutGetDevCapsW` pour le
//! casque) : Windows le coupe à 31 lettres. Les numéros, eux, changent quand on branche un autre appareil.
//! - absent, `null`, pas une chaîne, trop long, avec un caractère de contrôle : pas de choix ([`Choix::Absent`]) ;
//! - `""` : celui de Windows ([`Choix::Windows`]) ;
//! - un nom : cherché tel quel (mêmes majuscules, mêmes espaces) parmi les noms des appareils du PC, le premier qui
//!   porte ce nom ; débranché, c'est celui de Windows en attendant (le choix, lui, reste).
//!
//! Ce module ne fait que lire `suite.json` : jamais écrit, jamais déplacé (même abîmé, comme les applis PowerShell ;
//! seul Mindset l'écrit). Il n'ouvre jamais un micro. La liste des appareils du PC est donnée par l'appelant (le trait
//! [`AppareilsAudio`]) : la lire demande du code « unsafe », interdit dans cette bibliothèque.
//!
//! Les juges : `outils\exporter-juges-micro.ps1` passe des suite.json préparés aux vraies fonctions PowerShell des trois
//! applis, et les tests (micro/tests.rs) vérifient que ce module répond pareil, écarts connus mis à part.

use std::io;
use std::path::Path;
use std::time::Duration;

use serde_json::{Map, Value};

use crate::texte::{SansMarque, decoder_fichier};

/// Le numéro qui veut dire « l'appareil de Windows » pour `waveInOpen` et `waveOutOpen` (`WAVE_MAPPER`, 0xFFFFFFFF).
pub const APPAREIL_DE_WINDOWS: u32 = u32::MAX;

/// La longueur maximale d'un nom d'appareil, en unités UTF-16 comme `String.Length` de .NET (`Test-NomAppareil`).
pub const LONGUEUR_MAX: usize = 64;

/// La profondeur maximale que `ConvertFrom-Json` de Windows PowerShell 5.1 accepte (le premier niveau compté) :
/// au-delà, tout le fichier est illisible (mesuré : 102 niveaux passent, 103 non).
const PROFONDEUR_MAX: usize = 102;

/// Le choix gardé dans suite.json pour le micro ou pour le casque.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Choix {
    /// Pas de choix valable dans suite.json (absent, abîmé, pas une chaîne...). Mindcare prend alors celui de
    /// Windows ; Evermind garde son propre réglage (voir [`Choix::ou`]).
    #[default]
    Absent,
    /// `""` : celui de Windows, choisi exprès dans Mindset
    Windows,
    /// Le nom de l'appareil choisi (coupé à 31 lettres par Windows)
    Appareil(String),
}

impl Choix {
    /// Ce choix, ou `autre` s'il est [`Choix::Absent`] (Evermind : `autre` est son propre réglage).
    pub fn ou(self, autre: Choix) -> Choix {
        match self {
            Choix::Absent => autre,
            c => c,
        }
    }

    /// Le nom gardé ; `""` pour celui de Windows, et pour un choix absent (comme le `Micro` de Mindcare).
    pub fn nom(&self) -> &str {
        match self {
            Choix::Appareil(n) => n,
            _ => "",
        }
    }

    /// Un nom d'appareil valable (`Test-NomAppareil`) : une chaîne de 64 unités UTF-16 au plus, sans caractère de
    /// contrôle de 0x00 à 0x1F (0x7F et suivants sont acceptés, comme Mindset et Mindcare).
    fn depuis(valeur: Option<&Value>) -> Choix {
        match valeur {
            Some(Value::String(s)) if s.encode_utf16().count() <= LONGUEUR_MAX && !s.chars().any(|c| c < '\u{20}') => {
                if s.is_empty() {
                    Choix::Windows
                } else {
                    Choix::Appareil(s.clone())
                }
            }
            _ => Choix::Absent,
        }
    }
}

/// Le micro et le casque de la suite.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SonSuite {
    /// Le micro (parmi les noms donnés par `waveInGetDevCapsW`)
    pub micro: Choix,
    /// Le casque ou les haut-parleurs (parmi les noms donnés par `waveOutGetDevCapsW`)
    pub casque: Choix,
}

/// Une majuscule simple par caractère, comme une comparaison `OrdinalIgnoreCase` de .NET.
fn sans_casse(cle: &str) -> String {
    cle.chars()
        .map(|c| {
            let mut m = c.to_uppercase();
            match (m.next(), m.next()) {
                (Some(u), None) => u,
                _ => c,
            }
        })
        .collect()
}

/// `ConvertFrom-Json` de Windows PowerShell 5.1 refuse tout le fichier si un objet, où qu'il soit, a deux clés qui ne
/// diffèrent que par les majuscules, ou s'il va trop profond. Vrai si `valeur` passe.
fn accepte_par_powershell(valeur: &Value, niveau: usize) -> bool {
    if niveau > PROFONDEUR_MAX {
        return false;
    }
    match valeur {
        Value::Array(t) => t.iter().all(|v| accepte_par_powershell(v, niveau + 1)),
        Value::Object(o) => {
            let mut vues = std::collections::HashSet::with_capacity(o.len());
            o.iter().all(|(k, v)| vues.insert(sans_casse(k)) && accepte_par_powershell(v, niveau + 1))
        }
        _ => true,
    }
}

/// La valeur d'une clé, sans tenir compte des majuscules (`$j.micro` en PowerShell lit aussi `"Micro"`).
fn cle<'a>(objet: &'a Map<String, Value>, nom: &str) -> Option<&'a Value> {
    let nom = sans_casse(nom);
    objet.iter().find(|(k, _)| sans_casse(k) == nom).map(|(_, v)| v)
}

/// Le micro et le casque d'un texte de suite.json ; `None` s'il n'est pas lisible (pas du JSON, pas un objet, refusé
/// par PowerShell). Une clé en double garde sa dernière valeur, comme PowerShell.
pub fn depuis_texte(texte: &str) -> Option<SonSuite> {
    let valeur: Value = serde_json::from_str(texte).ok()?;
    if !accepte_par_powershell(&valeur, 1) {
        return None;
    }
    let objet = valeur.as_object()?;
    Some(SonSuite { micro: Choix::depuis(cle(objet, "micro")), casque: Choix::depuis(cle(objet, "casque")) })
}

/// Comme [`depuis_texte`], pour les octets du fichier (lus comme `[IO.File]::ReadAllText($f, UTF8)` : marque
/// d'encodage suivie, sinon UTF-8 ; un octet invalide devient « � »).
pub fn depuis_octets(octets: &[u8]) -> Option<SonSuite> {
    depuis_texte(&decoder_fichier(octets, SansMarque::Utf8))
}

/// Ce qu'a donné la lecture de suite.json.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EtatSuite {
    /// Pas de fichier : Mindset n'a encore rien écrit
    Absent,
    /// Tenu par un autre programme à chaque essai (Mindset qui le remplace, un antivirus) : on ne sait pas ce qu'il dit
    Pris,
    /// Illisible : vide, abîmé, pas un objet JSON, ou impossible à lire
    Illisible,
    /// Lu
    Lu,
}

/// La lecture de suite.json : son état, et le micro et le casque ([`Choix::Absent`] s'il n'a pas été lu).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LectureSuite {
    /// Ce qui s'est passé
    pub etat: EtatSuite,
    /// Le micro et le casque
    pub son: SonSuite,
}

/// Un fichier tenu un instant par un autre programme (partage, verrou, ou en plein remplacement) : relu plus tard.
fn est_pris(e: &io::Error) -> bool {
    matches!(e.raw_os_error(), Some(5 | 32 | 33))
}

/// Lit suite.json comme `Read-Suite` de Mindcare et d'Evermind : `essais` lectures espacées de 300 ms tant qu'un autre
/// programme le tient (10 au démarrage, 3 pour la dictée de Mindcare), puis [`EtatSuite::Pris`]. Rien n'est jamais
/// écrit ni déplacé, et la copie `.bak` n'est pas lue (seul Mindset la reprend).
pub fn lire(fichier: &Path, essais: u32) -> LectureSuite {
    let rien = |etat| LectureSuite { etat, son: SonSuite::default() };
    if !fichier.is_file() {
        return rien(EtatSuite::Absent);
    }
    let essais = essais.max(1);
    let mut essai = 1;
    let octets = loop {
        match std::fs::read(fichier) {
            Ok(o) => break o,
            Err(e) if est_pris(&e) => {
                if essai >= essais {
                    return rien(EtatSuite::Pris);
                }
                essai += 1;
                std::thread::sleep(Duration::from_millis(300));
            }
            Err(_) => return rien(EtatSuite::Illisible),
        }
    };
    match depuis_octets(&octets) {
        Some(son) => LectureSuite { etat: EtatSuite::Lu, son },
        None => rien(EtatSuite::Illisible),
    }
}

/// Où est l'appareil choisi parmi ceux du PC.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trouve {
    /// Pas de choix, ou celui de Windows choisi exprès
    Windows,
    /// Branché : son numéro dans la liste du PC (le premier qui porte ce nom)
    Present(usize),
    /// Choisi mais pas sur le PC : celui de Windows en attendant (Mindset l'affiche « (débranché) »)
    Debranche,
}

impl Trouve {
    /// Le numéro à donner à `waveInOpen` ou `waveOutOpen` : celui de l'appareil, ou [`APPAREIL_DE_WINDOWS`].
    pub fn numero(self) -> u32 {
        match self {
            Trouve::Present(i) => u32::try_from(i).unwrap_or(APPAREIL_DE_WINDOWS),
            Trouve::Windows | Trouve::Debranche => APPAREIL_DE_WINDOWS,
        }
    }
}

/// Retrouve le choix parmi les noms des appareils du PC, dans l'ordre de leurs numéros (`[array]::IndexOf` : nom
/// identique, mêmes majuscules, le premier s'il y en a deux). Un choix absent compte comme celui de Windows.
pub fn trouver<S: AsRef<str>>(choix: &Choix, noms: &[S]) -> Trouve {
    match choix {
        Choix::Absent | Choix::Windows => Trouve::Windows,
        Choix::Appareil(nom) => match noms.iter().position(|n| n.as_ref() == nom) {
            Some(i) => Trouve::Present(i),
            None => Trouve::Debranche,
        },
    }
}

/// Les appareils audio du PC, par leur nom, dans l'ordre de leurs numéros. La vraie lecture (`waveInGetNumDevs` et
/// `waveInGetDevCapsW`, `waveOutGetNumDevs` et `waveOutGetDevCapsW`) est dans l'appli, hors de cette bibliothèque ;
/// un nom illisible y vaut `""` (comme le C# des applis), pour que les numéros restent les bons.
pub trait AppareilsAudio {
    /// Les micros (entrées)
    fn micros(&self) -> Vec<String>;
    /// Les sorties (casques, haut-parleurs)
    fn sorties(&self) -> Vec<String>;
}

impl SonSuite {
    /// Le micro choisi, retrouvé parmi ceux du PC.
    pub fn micro_sur<A: AppareilsAudio + ?Sized>(&self, pc: &A) -> Trouve {
        trouver(&self.micro, &pc.micros())
    }

    /// Le casque choisi, retrouvé parmi les sorties du PC.
    pub fn casque_sur<A: AppareilsAudio + ?Sized>(&self, pc: &A) -> Trouve {
        trouver(&self.casque, &pc.sorties())
    }
}

#[cfg(test)]
mod tests;
