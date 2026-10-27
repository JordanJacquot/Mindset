//! Le mini-installateur de Mindset (MindsetInstallateur.exe), qui remplace installer-admin.ps1 avec les mêmes
//! contrôles et les mêmes réponses (plan Rust, étape 2).
//!
//! Il tourne en administrateur :
//! - lancé par la tâche SYSTEM « \Mindset\Mindset (installation) » (`-Action demande -Sid <utilisateur> -Demande
//!   <fichier>`), sans fenêtre ni demande de Windows : il lit la demande écrite par Mindset sans droits et revérifie
//!   tout (voir [`installateur`]) ;
//! - ou lancé après la demande de Windows (les autres actions, `-Resultat <fichier>`), par installer-admin.ps1, réduit
//!   à un relais qui lui passe la main.
//!
//! Le dossier des programmes est déduit de l'emplacement de l'exe (`<programmes>\Mindset\MindsetInstallateur.exe`),
//! jamais de la demande. Toute la partie Windows passe par le trait [`systeme::Systeme`] : l'exe le remplit avec les
//! vrais appels, `cargo test` avec un faux Windows (tests/corpus.rs, le corpus cas\installateur).
//!
//! Aucun code « unsafe » dans la bibliothèque.

#![deny(unsafe_op_in_unsafe_fn)]
#![forbid(unsafe_code)]

pub mod arguments;
pub mod installateur;
pub mod regles;
pub mod systeme;

pub use installateur::executer;

/// Le nom de l'exe, à côté de Mindset.exe dans le dossier de Mindset.
pub const NOM_EXE: &str = "MindsetInstallateur.exe";
