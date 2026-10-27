//! Tout ce que l'installateur demande à Windows, derrière un trait : l'exe le remplit avec les vrais appels
//! (src/windows), `cargo test` avec un faux Windows qui note chaque action dans un journal (tests/corpus.rs). Rien
//! d'autre ne distingue les deux : aucun réglage de test dans l'exe livré.
//!
//! Les fichiers sont lus et écrits pour de vrai, dans les deux cas : seul le chemin passe par [`Systeme::reel`]
//! (dans les tests, un faux disque « X: » est un dossier de test, comme un lecteur PowerShell).

use std::path::PathBuf;

/// Une valeur écrite dans le registre.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValeurRegistre {
    Texte(String),
    Nombre(u32),
}

/// Une règle des droits d'un dossier (une entrée de sa liste d'accès).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegleAcces {
    /// Le compte ou le groupe (SID)
    pub sid: String,
    /// Autorisation (vrai) ou refus (faux)
    pub autorise: bool,
    /// Elle ne vaut que pour ce qui sera créé dessous (InheritOnly), pas pour le dossier lui-même
    pub herite_seulement: bool,
    /// Les droits (masque de Windows, droits « génériques » compris)
    pub masque: u32,
}

/// Les droits d'un dossier : son propriétaire et ses règles.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Droits {
    pub proprietaire: Option<String>,
    pub regles: Vec<RegleAcces>,
}

/// Un programme ouvert.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Processus {
    pub id: u32,
    /// Son chemin complet (`None` : illisible)
    pub chemin: Option<String>,
    pub session: u32,
}

/// Une action d'une tâche planifiée : le programme lancé (`None` pour une action qui n'en lance pas) et ses
/// arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActionTache {
    pub execute: Option<String>,
    pub arguments: String,
}

/// Une tâche planifiée vue sur le PC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TacheVue {
    /// Son dossier, avec les barres (« \ », « \Mindset\ »)
    pub dossier: String,
    pub nom: String,
    /// Le compte sous lequel elle tourne, tel que Windows le donne (nom ou SID ; `None` : un groupe)
    pub compte: Option<String>,
    pub actions: Vec<ActionTache>,
}

/// Sous quel compte tourne une tâche créée.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompteTache {
    /// SYSTEM, avec les droits les plus élevés (le mini-installateur, les parties administrateur des applis)
    Systeme,
    /// L'utilisateur (son SID), sans droits, dans sa session (le démarrage de Mindset)
    Utilisateur(String),
}

/// Plusieurs lancements à la fois.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Instances {
    /// Tous en même temps
    Parallele,
    /// Chacun son tour
    File,
    /// Un seul : les suivants sont ignorés
    IgnorerNouvelle,
}

/// Une tâche à créer (ou remplacer) dans `\Mindset\`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NouvelleTache {
    pub nom: String,
    /// Le programme lancé, tel qu'écrit dans la tâche (entre guillemets s'il le faut)
    pub execute: String,
    pub arguments: String,
    pub dossier_travail: String,
    pub compte: CompteTache,
    /// Lancée à l'ouverture de session de ce compte (son nom), 10 secondes après
    pub ouverture_session: Option<String>,
    /// Durée maximale en minutes (`None` : sans limite)
    pub duree_max_minutes: Option<u32>,
    pub instances: Instances,
    pub description: String,
}

/// Le genre et le système de fichiers d'un disque (comme `Win32_LogicalDisk` : 3 = disque fixe).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Disque {
    pub genre: u32,
    pub systeme_fichiers: String,
}

/// Tout ce que l'installateur demande à Windows.
pub trait Systeme {
    // --- Dossiers et programme ------------------------------------------------------------------------------
    /// Le dossier de Windows (C:\Windows), demandé à Windows
    fn dossier_windows(&self) -> String;
    /// System32, demandé à Windows
    fn dossier_systeme(&self) -> String;
    /// Program Files (64 bits), demandé à Windows
    fn dossier_programmes(&self) -> String;
    /// Le chemin de ce programme (MindsetInstallateur.exe)
    fn exe_courant(&self) -> String;
    /// Le chemin réel d'un fichier (le même, sauf dans les tests : un faux disque)
    fn reel(&self, chemin: &str) -> PathBuf {
        PathBuf::from(chemin)
    }

    // --- Comptes --------------------------------------------------------------------------------------------
    /// Le compte sous lequel tourne l'installateur (son SID)
    fn sid_courant(&self) -> String;
    /// Un nom de compte (« PC\Élodie », « SYSTEM ») en SID ; `None` si inconnu
    fn sid_de_compte(&self, compte: &str) -> Option<String>;
    /// Un SID en nom de compte (« PC\Élodie ») ; `None` si inconnu
    fn compte_de_sid(&self, sid: &str) -> Option<String>;
    /// Le dossier du profil d'un utilisateur, lu dans HKLM (ProfileList), sans remplacer %SystemDrive%
    fn profil_brut(&self, sid: &str) -> Option<String>;

    // --- Disques et droits des dossiers ---------------------------------------------------------------------
    /// Le disque `X:` (`None` : il n'existe pas)
    fn disque(&self, lettre: char) -> Option<Disque>;
    /// Les droits d'un dossier (`None` : illisibles)
    fn droits(&self, dossier: &str) -> Option<Droits>;
    /// Pose les droits de `X:\Mindset` : propriétaire Administrateurs, administrateurs et système en contrôle
    /// total, utilisateurs en lecture, sans hériter de ceux du disque
    fn poser_droits_racine(&mut self, dossier: &str) -> Result<(), String>;
    /// Remet un dossier et tout ce qu'il contient aux droits hérités de son parent (icacls /reset /T /C /Q)
    fn reprendre_droits_herites(&mut self, dossier: &str);
    /// Le dossier appartient désormais aux Administrateurs
    fn poser_proprietaire_admins(&mut self, dossier: &str) -> Result<(), String>;
    /// L'utilisateur `sid` peut modifier le dossier et ce qu'il contient
    fn ajouter_droit_modifier(&mut self, dossier: &str, sid: &str) -> Result<(), String>;

    // --- Registre (HKLM) ------------------------------------------------------------------------------------
    /// Une valeur texte d'une clé de HKLM (`None` : absente)
    fn registre_lire(&self, cle: &str, nom: &str) -> Option<String>;
    /// Une clé de HKLM existe-t-elle ?
    fn registre_existe(&self, cle: &str) -> bool;
    /// Crée la clé (comme `New-Item -Force`)
    fn registre_creer(&mut self, cle: &str) -> Result<(), String>;
    /// Écrit une valeur (la clé doit exister)
    fn registre_ecrire(&mut self, cle: &str, nom: &str, valeur: &ValeurRegistre) -> Result<(), String>;
    /// Retire une clé et tout ce qu'elle contient
    fn registre_supprimer(&mut self, cle: &str) -> Result<(), String>;

    // --- Tâches planifiées ----------------------------------------------------------------------------------
    /// Les tâches d'un dossier (`Some(r"\Mindset\")`), ou toutes celles du PC (`None`)
    fn taches(&self, dossier: Option<&str>) -> Vec<TacheVue>;
    /// Une tâche
    fn tache(&self, dossier: &str, nom: &str) -> Option<TacheVue>;
    /// Crée ou remplace une tâche de `\Mindset\`
    fn enregistrer_tache(&mut self, tache: &NouvelleTache) -> Result<(), String>;
    /// Qui peut lire et lancer une tâche de `\Mindset\` (SDDL)
    fn droits_tache(&mut self, nom: &str, sddl: &str) -> Result<(), String>;
    /// Retire une tâche (sans erreur si elle n'existe pas)
    fn retirer_tache(&mut self, dossier: &str, nom: &str);
    /// Retire le dossier de tâches `\Mindset` (vide)
    fn retirer_dossier_taches(&mut self, nom: &str);
    /// Remplace les actions d'une tâche (toutes gardées, dans l'ordre)
    fn modifier_actions(&mut self, dossier: &str, nom: &str, actions: &[ActionTache]) -> Result<(), String>;
    /// Lance une tâche (comme `schtasks /Run /TN <chemin>`) ; rend le code de sortie de schtasks
    fn lancer_tache(&mut self, chemin: &str) -> i32;

    // --- Programmes -----------------------------------------------------------------------------------------
    /// Ce programme (son numéro) et sa session
    fn pid(&self) -> u32;
    fn session(&self) -> u32;
    /// Les programmes ouverts sur le PC
    fn processus(&self) -> Vec<Processus>;
    /// Le compte d'un programme ouvert (son SID)
    fn proprietaire_processus(&self, id: u32) -> Option<String>;
    /// Ferme un programme d'un coup
    fn arreter(&mut self, p: &Processus);
    /// Attend la fin d'un programme, au plus `secondes`
    fn attendre_fin(&mut self, pid: i32, secondes: u32);
    /// Attend un peu
    fn pause(&mut self, millisecondes: u64);
    /// Lance un programme par l'Explorateur (avec les droits de l'utilisateur de la session)
    fn lancer_par_explorateur(&mut self, programme: &str);
    /// Affiche un message (seulement en lancement direct : personne ne verrait une fenêtre de la tâche)
    fn fenetre(&mut self, texte: &str, titre: &str);
    /// Ce fichier sera effacé au prochain démarrage de Windows (un programme en cours ne peut pas l'être avant)
    fn effacer_au_redemarrage(&mut self, chemin: &str);
}
