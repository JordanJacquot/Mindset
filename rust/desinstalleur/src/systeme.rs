//! Ce que le travail demande à Windows : processus, programmes lancés, registre, tâches planifiées. Les fichiers et les
//! dossiers passent directement par la bibliothèque standard (ils sont faux, dans un dossier de test, pendant les
//! essais). Le vrai Windows est dans `os` ; `cargo test` le remplace par un faux (voir travail.rs).

use std::path::Path;
use std::time::Duration;

/// Une ruche du registre, telle que la voit le travail. Les vraies : HKLM (vue 64 bits) et celle de l'utilisateur qui a
/// lancé la désinstallation ; dans un faux environnement (essais), toutes deux sous HKCU\Software\MindsetTest-...
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ruche {
    Machine,
    Utilisateur,
}

/// Une erreur du Planificateur de tâches : `absent` quand ce qui est visé n'existe déjà plus (rien à signaler)
#[derive(Debug, Clone)]
pub struct ErreurTache {
    pub absent: bool,
    pub message: String,
}

/// Ce que contient un dossier du Planificateur de tâches
#[derive(Debug, Clone, Default)]
pub struct DossierTaches {
    /// Ses sous-dossiers : (nom, chemin complet « \Mindset\... »)
    pub sous_dossiers: Vec<(String, String)>,
    /// Ses tâches, cachées comprises : (nom, chemin complet)
    pub taches: Vec<(String, String)>,
}

/// Pourquoi on ne peut pas lire un dossier de tâches
#[derive(Debug, Clone)]
pub enum LectureTaches {
    /// Le Planificateur de tâches ne répond pas
    Connexion(String),
    /// Le dossier existe peut-être, mais Windows refuse de le lire
    Erreur(String),
}

/// La fin d'un programme lancé et attendu
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fin {
    /// Fini, avec ce code de sortie
    Code(i32),
    /// Pas fini à la limite
    TropLong,
}

pub trait Systeme: Sync {
    /// Le numéro de ce processus
    fn mon_pid(&self) -> u32;
    /// Les processus en cours dont Windows donne le chemin du programme : (numéro, chemin complet)
    fn processus(&self) -> Vec<(u32, String)>;
    /// La ligne de commande d'un processus (None si Windows refuse)
    fn ligne_commande(&self, pid: u32) -> Option<String>;
    /// Ferme un processus et attend sa fin (`attente` au plus)
    fn fermer(&self, pid: u32, attente: Duration) -> Result<(), String>;
    /// Un programme de ce nom (sans « .exe ») tourne-t-il ? (comme Process.GetProcessesByName)
    fn tourne_nomme(&self, nom: &str) -> bool;
    /// Lance un programme avec un argument, dans un dossier, et attend sa fin
    fn lancer_et_attendre(&self, exe: &Path, argument: &str, dossier: &Path, limite: Duration) -> Result<Fin, String>;

    /// Le nom d'une ruche dans les messages (« HKEY_LOCAL_MACHINE »...)
    fn nom_ruche(&self, ruche: Ruche) -> String;
    fn cle_existe(&self, ruche: Ruche, cle: &str) -> Result<bool, String>;
    /// Supprime une clé avec tout ce qu'elle contient
    fn supprimer_cle(&self, ruche: Ruche, cle: &str) -> Result<(), String>;
    /// La valeur existe-t-elle ? (clé absente : non)
    fn valeur_existe(&self, ruche: Ruche, cle: &str, nom: &str) -> Result<bool, String>;
    fn supprimer_valeur(&self, ruche: Ruche, cle: &str, nom: &str) -> Result<(), String>;
    /// Écrit une valeur texte, seulement si la clé existe déjà
    fn ecrire_texte_si_cle(&self, ruche: Ruche, cle: &str, nom: &str, valeur: &str) -> Result<(), String>;

    /// Le contenu d'un dossier du Planificateur de tâches (None : il n'existe pas)
    fn dossier_taches(&self, chemin: &str) -> Result<Option<DossierTaches>, LectureTaches>;
    /// Arrête une tâche si elle est en cours
    fn arreter_tache(&self, chemin: &str);
    /// Supprime la tâche `nom` du dossier `dossier`
    fn supprimer_tache(&self, dossier: &str, nom: &str) -> Result<(), ErreurTache>;
    /// Supprime le sous-dossier `nom` (vide) du dossier `parent`
    fn supprimer_dossier_taches(&self, parent: &str, nom: &str) -> Result<(), ErreurTache>;
}
