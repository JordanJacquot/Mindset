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
//! - [`micro`] : le micro et le casque de la suite (suite.json), retrouvés parmi ceux du PC comme en PowerShell.
//!
//! Le banc d'essai (outils\banc-suite-commun.ps1) passe les mêmes fichiers à la version PowerShell et à cette
//! bibliothèque, et vérifie qu'elles répondent pareil.
//!
//! Options (features Cargo), toutes activées par défaut ; une appli qui n'a besoin que de [`json_sur`] et
//! [`chemins`] (Mindcare) les coupe (`default-features = false`) et ne tire ni ring ni zip :
//! - « signature » : [`signature`] (tire ring) ;
//! - « paquet » : [`paquet`], [`version_paquet`] et [`liste_en_ligne`] (tire zip, et « signature ») ;
//! - « heure-locale » : l'heure du PC pour les noms des fichiers mis de côté par [`json_sur`] (tire windows). Sans
//!   elle, l'appli donne sa propre horloge à `json_sur::Options`.
//!
//! Aucun code « unsafe » ici (interdit dans tout le dépôt Rust, voir Cargo.toml), sauf l'appel à l'heure de Windows
//! (heure_windows, avec l'option « heure-locale »), qui l'autorise lui-même.

#![deny(unsafe_op_in_unsafe_fn)]
#![deny(unsafe_code)]

// Aussi pour les tests, même sans « signature » : les juges du micro donnent leurs octets en base64
#[cfg(any(feature = "signature", test))]
mod base64;
pub mod chemins;
#[cfg(all(windows, feature = "heure-locale"))]
mod heure_windows;
pub mod json_sur;
#[cfg(feature = "paquet")]
pub mod liste_en_ligne;
pub mod micro;
#[cfg(feature = "paquet")]
pub mod paquet;
pub mod protocole_installateur;
#[cfg(feature = "signature")]
pub mod signature;
mod texte;
pub mod themes;
pub mod version;
#[cfg(feature = "paquet")]
pub mod version_paquet;
#[cfg(feature = "signature")]
mod xml;
