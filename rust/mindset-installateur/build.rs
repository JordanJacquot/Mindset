//! Réglages de l'exe livré, donnés à l'éditeur de liens de Windows (aucune bibliothèque en plus) :
//! - un manifeste intégré « asInvoker » : l'exe ne demande jamais lui-même les droits administrateur (il les reçoit
//!   de la tâche SYSTEM, ou du relais lancé après la demande de Windows) ;
//! - les DLL dont il dépend ne sont cherchées que dans System32, jamais à côté de lui (/DEPENDENTLOADFLAG).

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        println!("cargo:rustc-link-arg-bins=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg-bins=/MANIFESTUAC:level='asInvoker' uiAccess='false'");
        println!("cargo:rustc-link-arg-bins=/DEPENDENTLOADFLAG:0x800");
    }
}
