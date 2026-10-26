//! Banc d'essai de `suite-commun` (jamais livré aux utilisateurs).
//!
//!   banc-essai.exe <cas.json> <resultats.json>
//!
//! `cas.json` est écrit par outils\banc-suite-commun.ps1 : les mêmes fichiers (zips, signatures, listes de clés)
//! sont passés à la version PowerShell et ici ; le script compare ensuite les deux réponses.

#![deny(unsafe_op_in_unsafe_fn)]
#![forbid(unsafe_code)]

use std::path::Path;
use std::process::ExitCode;

use serde_json::{Value, json};
use suite_commun::paquet::{Demande, installer};
use suite_commun::signature::verifier_signature;

fn texte<'a>(cas: &'a Value, cle: &str) -> &'a str {
    cas.get(cle).and_then(Value::as_str).unwrap_or("")
}

/// Les octets d'un fichier du cas (vide si le chemin est vide ou le fichier absent : comme un fichier vide).
fn octets(cas: &Value, cle: &str) -> Vec<u8> {
    let p = texte(cas, cle);
    if p.is_empty() { Vec::new() } else { std::fs::read(p).unwrap_or_default() }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Utilisation : banc-essai <cas.json> <resultats.json>");
        return ExitCode::from(2);
    }
    let lu = match std::fs::read_to_string(&args[1]) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Cas illisibles : {e}");
            return ExitCode::from(2);
        }
    };
    let cas: Value = match serde_json::from_str(lu.trim_start_matches('\u{FEFF}')) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Cas illisibles : {e}");
            return ExitCode::from(2);
        }
    };
    let vide = Vec::new();

    let mut signatures = Vec::new();
    for c in cas.get("signature").and_then(Value::as_array).unwrap_or(&vide) {
        let ok = verifier_signature(&octets(c, "donnees"), &octets(c, "signature"), Path::new(texte(c, "cles")));
        signatures.push(json!({ "id": texte(c, "id"), "resultat": ok }));
    }

    let mut installations = Vec::new();
    for c in cas.get("installation").and_then(Value::as_array).unwrap_or(&vide) {
        let zip = octets(c, "zip");
        let sig = octets(c, "signature");
        let facultatif = |cle: &str| Some(texte(c, cle)).filter(|t| !t.is_empty());
        let d = Demande {
            zip: &zip,
            signature: &sig,
            cles: Path::new(texte(c, "cles")),
            destination: Path::new(texte(c, "destination")),
            dossier_zip: texte(c, "dossier_zip"),
            exe: texte(c, "exe"),
            version_minimale: facultatif("version_minimale"),
            appli: facultatif("appli"),
            version_mindset: facultatif("version_mindset"),
        };
        let r = match installer(&d) {
            Ok(p) => {
                json!({ "id": texte(c, "id"), "ok": true, "categorie": "", "message": "", "retour": p.to_string_lossy() })
            }
            Err(e) => {
                json!({ "id": texte(c, "id"), "ok": false, "categorie": e.categorie(), "message": e.to_string(), "retour": "" })
            }
        };
        installations.push(r);
    }

    let sortie = json!({ "signature": signatures, "installation": installations });
    match std::fs::write(&args[2], serde_json::to_string_pretty(&sortie).unwrap_or_default()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Résultats non écrits : {e}");
            ExitCode::from(2)
        }
    }
}
