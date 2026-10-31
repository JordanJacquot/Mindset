//! Bibliothèque commune de la suite Mindset (plan Rust, section 3.3).
//!
//! Pour commencer, trois parties, reprises à l'identique du code PowerShell de Mindset :
//! - [`signature`] : la vérification des zips signés (comme `Test-Signature`, modules\signature.ps1) ;
//! - [`paquet`] : l'installation d'un zip depuis la mémoire (comme `Install-Paquet`, modules\paquets.ps1) ;
//! - [`json_sur`] : l'écriture et la lecture sûres d'un fichier JSON (comme `Save-JsonSur` et `Read-JsonSur`,
//!   modules\donnees.ps1).
//!
//! Pour l'installateur de Mindset en Rust (étape 2) :
//! - [`chemins`] : les chemins de la suite, et les chemins complets comme .NET les calcule ;
//! - [`protocole_installateur`] : la demande et la réponse de la tâche SYSTEM du mini-installateur ;
//! - [`version_paquet`] : la version d'une appli dans son zip ou dans son dossier.
//!
//! Pour la liste des applis en ligne (Mindset 2.16) :
//! - [`liste_en_ligne`] : ses règles d'acceptation, les mêmes pour l'installateur et le désinstalleur.
//!
//! Pour les applis en Rust (Mindcare d'abord) :
//! - [`themes`] : le thème de la suite (suite.json, thèmes intégrés et packs, couleurs vérifiées), prêt pour l'écran.
//!
//! Le banc d'essai (outils\banc-suite-commun.ps1) passe les mêmes fichiers à la version PowerShell et à cette
//! bibliothèque, et vérifie qu'elles répondent pareil.
//!
//! Aucun code « unsafe » ici (interdit dans tout le dépôt Rust, voir Cargo.toml).

#![deny(unsafe_op_in_unsafe_fn)]
#![forbid(unsafe_code)]

mod base64;
pub mod chemins;
pub mod json_sur;
pub mod liste_en_ligne;
pub mod paquet;
pub mod protocole_installateur;
pub mod signature;
mod texte;
pub mod themes;
pub mod version;
pub mod version_paquet;
mod xml;
