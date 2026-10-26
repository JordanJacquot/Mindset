//! Bibliothèque commune de la suite Mindset (plan Rust, section 3.3).
//!
//! Pour commencer, trois parties, reprises à l'identique du code PowerShell de Mindset :
//! - [`signature`] : la vérification des zips signés (comme `Test-Signature`, modules\signature.ps1) ;
//! - [`paquet`] : l'installation d'un zip depuis la mémoire (comme `Install-Paquet`, modules\paquets.ps1) ;
//! - [`json_sur`] : l'écriture et la lecture sûres d'un fichier JSON (comme `Save-JsonSur` et `Read-JsonSur`,
//!   modules\donnees.ps1).
//!
//! Le banc d'essai (outils\banc-suite-commun.ps1) passe les mêmes fichiers à la version PowerShell et à cette
//! bibliothèque, et vérifie qu'elles répondent pareil.
//!
//! Aucun code « unsafe » ici (interdit dans tout le dépôt Rust, voir Cargo.toml).

#![deny(unsafe_op_in_unsafe_fn)]
#![forbid(unsafe_code)]

mod base64;
pub mod json_sur;
pub mod paquet;
pub mod signature;
mod texte;
pub mod version;
mod xml;
