//! Le protocole du mini-installateur de Mindset (la tâche SYSTEM « \Mindset\Mindset (installation) »), le même
//! qu'avec installer-admin.ps1 :
//!
//! 1. Mindset (sans droits) écrit sa demande, en JSON, dans `installation.demande` de son dossier de données, puis
//!    lance la tâche ;
//! 2. l'installateur (en SYSTEM) accuse réception (valeur `Recu` : le numéro de la demande), puis répond (valeur
//!    `Resultat` : `{ "id", "ok", "message" }`), dans `HKLM\SOFTWARE\Mindset\Installation`, jamais dans un dossier
//!    modifiable sans droits ;
//! 3. Mindset efface sa demande.
//!
//! La demande est lue comme Windows PowerShell 5.1 la lisait (`ConvertFrom-Json`, puis `[string]`, `[int]`) : un
//! champ qui n'est pas du texte est ignoré, les noms des champs ne tiennent pas compte des majuscules.

use serde_json::{Map, Value};

/// Le dossier des tâches de la suite, et les tâches de Mindset.
pub const DOSSIER_TACHES: &str = r"\Mindset\";
pub const TACHE_INSTALLATION: &str = "Mindset (installation)";
pub const TACHE_DEMARRAGE: &str = "Mindset (démarrage)";
/// La très vieille tâche (Mindset ouvert en administrateur), retirée partout.
pub const TACHE_ANCIENNE: &str = "Mindset";

/// La clé de la réponse, ses valeurs, et celle des versions gardées (sous HKLM).
pub const CLE_INSTALLATION: &str = r"SOFTWARE\Mindset\Installation";
pub const VALEUR_RECU: &str = "Recu";
pub const VALEUR_RESULTAT: &str = "Resultat";
pub const VALEUR_RESTES: &str = "Restes";
pub const CLE_MINDSET: &str = r"SOFTWARE\Mindset";
pub const CLE_VERSIONS: &str = r"SOFTWARE\Mindset\Versions";
/// La liste des applis qui a servi (sous `CLE_INSTALLATION`), notée seulement quand Mindset a donné une liste en
/// ligne (`Liste`) : « en ligne <numéro> » ou « livrée (<raison du refus>) ».
pub const VALEUR_LISTE: &str = "Liste";

/// Le fichier de la demande, dans le dossier de données de Mindset.
pub const FICHIER_DEMANDE: &str = "installation.demande";
/// Au plus 16 Ko : au-delà, la demande est ignorée.
pub const TAILLE_MAX_DEMANDE: u64 = 16 * 1024;

/// Les actions qu'une demande peut porter (les autres sont refusées : « Demande refusée. »).
pub const ACTIONS_PAR_TACHE: [&str; 4] = ["appli", "mindset-maj", "supprimer", "taches"];
/// Les champs texte repris d'une demande (tout autre champ est ignoré, comme `Sid` ou `Resultat`). `Liste` (Mindset
/// 2.16) : la liste des applis en ligne gardée par Mindset, à côté de la demande.
pub const CHAMPS_TEXTE: [&str; 11] = [
    "Zip",
    "Signature",
    "Destination",
    "DossierZip",
    "Exe",
    "AncienExe",
    "Version",
    "TacheAide",
    "ExeAide",
    "Appli",
    "Liste",
];

/// Un numéro de demande valable : 8 à 32 chiffres hexadécimaux (majuscules permises).
pub fn id_valable(id: &str) -> bool {
    (8..=32).contains(&id.len()) && id.bytes().all(|o| o.is_ascii_hexdigit())
}

/// Un compte d'utilisateur valable pour la suite : `S-1-5-21-a-b-c-d` (jamais le système ni un groupe).
pub fn sid_valable(sid: &str) -> bool {
    let Some(reste) = sid.get(..9).filter(|d| d.eq_ignore_ascii_case("S-1-5-21-")).map(|_| &sid[9..]) else {
        return false;
    };
    let morceaux: Vec<&str> = reste.split('-').collect();
    morceaux.len() == 4 && morceaux.iter().all(|m| !m.is_empty() && m.bytes().all(|o| o.is_ascii_digit()))
}

/// La réponse écrite dans `Resultat`.
pub fn reponse(id: &str, ok: bool, message: &str) -> String {
    serde_json::json!({ "id": id, "ok": ok, "message": message }).to_string()
}

/// La réponse écrite dans le fichier `-Resultat` d'un lancement direct (la demande de Windows).
pub fn reponse_fichier(ok: bool, message: &str) -> String {
    serde_json::to_string_pretty(&serde_json::json!({ "ok": ok, "message": message })).unwrap_or_default()
}

/// `[string]` de PowerShell sur une valeur lue en JSON.
pub fn texte_ps(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.clone(),
        Value::Array(a) => a.iter().map(texte_ps).collect::<Vec<_>>().join(" "),
        Value::Object(_) => String::new(),
    }
}

/// Vrai ou faux au sens de PowerShell (`if ($x)`).
pub fn vrai_ps(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|x| x != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => match a.len() {
            0 => false,
            1 => vrai_ps(&a[0]),
            _ => true,
        },
        Value::Object(_) => true,
    }
}

/// Arrondi « au pair le plus proche », comme les conversions de .NET.
fn arrondi_pair(x: f64) -> f64 {
    let r = x.round();
    if (x - x.trunc()).abs() == 0.5 && r % 2.0 != 0.0 { r - x.signum() } else { r }
}

fn vers_entier(x: f64) -> Option<i32> {
    let r = arrondi_pair(x);
    (r.is_finite() && r >= f64::from(i32::MIN) && r <= f64::from(i32::MAX)).then_some(r as i32)
}

/// `[int]` de PowerShell sur un texte (espaces autour permis, « 0x » hexadécimal, nombre à virgule arrondi).
pub fn entier_ps_texte(t: &str) -> Option<i32> {
    let t = t.trim();
    if let Ok(n) = t.parse::<i32>() {
        return Some(n);
    }
    if let Some(h) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
        return u32::from_str_radix(h, 16).ok().map(|n| n as i32);
    }
    if t.is_empty() || !t.bytes().all(|o| o.is_ascii_digit() || matches!(o, b'.' | b'-' | b'+' | b'e' | b'E')) {
        return None;
    }
    t.parse::<f64>().ok().and_then(vers_entier)
}

/// `[int]` de PowerShell sur une valeur lue en JSON ; `None` : la conversion échoue (la demande est illisible).
pub fn entier_ps(v: &Value) -> Option<i32> {
    match v {
        Value::Bool(b) => Some(i32::from(*b)),
        Value::Number(n) => n.as_i64().and_then(|i| i32::try_from(i).ok()).or_else(|| n.as_f64().and_then(vers_entier)),
        Value::String(s) => entier_ps_texte(s),
        _ => None,
    }
}

/// Le champ `nom` d'un objet, sans tenir compte des majuscules (comme `PSObject.Properties[$nom]`).
pub fn champ<'a>(objet: &'a Map<String, Value>, nom: &str) -> Option<&'a Value> {
    objet.iter().find(|(k, _)| k.eq_ignore_ascii_case(nom) || crate::chemins::egal(k, nom)).map(|(_, v)| v)
}

/// Le texte d'une demande lu en JSON, comme `ConvertFrom-Json` de Windows PowerShell 5.1 : `None` s'il est illisible.
/// Deux champs dont les noms ne diffèrent que par les majuscules rendent aussi la demande illisible (PowerShell
/// refuse de les lire).
pub fn lire_json(texte: &str) -> Option<Value> {
    let v: Value = serde_json::from_str(texte.trim_start_matches('\u{FEFF}')).ok()?;
    fn doublons(v: &Value) -> bool {
        match v {
            Value::Object(m) => {
                let cles: Vec<&String> = m.keys().collect();
                cles.iter().enumerate().any(|(i, a)| cles[i + 1..].iter().any(|b| crate::chemins::egal(a, b)))
                    || m.values().any(doublons)
            }
            Value::Array(a) => a.iter().any(doublons),
            _ => false,
        }
    }
    (!doublons(&v)).then_some(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numeros_et_comptes() {
        assert!(id_valable("abcdef12") && id_valable("ABCDEF12") && id_valable(&"a".repeat(32)));
        assert!(!id_valable("abcdef1") && !id_valable(&"a".repeat(33)) && !id_valable("abcdef12 ") && !id_valable(""));
        assert!(sid_valable("S-1-5-21-1-2-3-1001") && sid_valable("s-1-5-21-1-2-3-1001"));
        assert!(!sid_valable("S-1-5-18") && !sid_valable("S-1-5-21-1-2-3") && !sid_valable("S-1-5-21-1-2-3-x"));
        assert!(!sid_valable("S-1-5-21-1-2-3-4\n") && !sid_valable(""));
    }

    #[test]
    fn conversions_comme_powershell() {
        assert_eq!(texte_ps(&serde_json::json!(["abcdef12"])), "abcdef12");
        assert_eq!(texte_ps(&serde_json::json!(12345678)), "12345678");
        assert_eq!(texte_ps(&serde_json::json!(true)), "True");
        assert_eq!(entier_ps(&serde_json::json!("abc")), None);
        assert_eq!(entier_ps(&serde_json::json!(" 42 ")), Some(42));
        assert_eq!(entier_ps(&serde_json::json!("0x10")), Some(16));
        assert_eq!(entier_ps(&serde_json::json!(2.5)), Some(2));
        assert_eq!(entier_ps(&serde_json::json!(3.5)), Some(4));
        assert!(
            !vrai_ps(&serde_json::json!(0)) && vrai_ps(&serde_json::json!("0")) && !vrai_ps(&serde_json::json!([]))
        );
        assert!(lire_json(r#"{"Zip":"a","zip":"b"}"#).is_none());
        assert!(lire_json("{ Id: 'abcdef12', Action: taches").is_none());
        assert!(lire_json("\u{FEFF}{\"Id\":\"abcdef12\"}").is_some());
    }
}
