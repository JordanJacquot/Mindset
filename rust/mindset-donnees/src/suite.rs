//! Le fichier commun de la suite, `%LOCALAPPDATA%\Mindset\suite.json` (modules\suite.ps1) : ses règles et la lecture
//! « à la PowerShell » des réglages des autres applis (Evermind, Nevermind, l'ancien OptiGame).
//!
//! - `theme` : le thème de la suite (neon, crepuscule, terminal, arcade, rubis, ou « pack:<id> ») ;
//! - `micro`, `casque` : le nom de l'appareil (coupé à 31 lettres par Windows), « » pour celui de Windows ;
//! - `applis` : `{ id = dossier }`, les applis installées ou prises en charge par Mindset.
//!
//! Sécurité : n'importe quel programme de l'utilisateur peut modifier ce fichier. On n'y accepte qu'un nom de thème
//! connu, et un dossier n'y sert qu'à comparer, jamais à lancer quoi que ce soit.

use serde_json::{Map, Value};
use suite_commun::chemins::{apres_debut, egal};

/// `$ThemesSuite` : les 5 thèmes de base.
pub const THEMES_SUITE: [&str; 5] = ["neon", "crepuscule", "terminal", "arcade", "rubis"];

/// Le texte sans un saut de ligne final : `$` de .NET accepte la fin du texte ou juste avant un dernier « \n ».
fn sans_saut_final(t: &str) -> &str {
    t.strip_suffix('\n').unwrap_or(t)
}

/// Un des 5 thèmes de base, sans tenir compte des majuscules (`-in $ThemesSuite`).
pub fn theme_de_base(t: &str) -> bool {
    THEMES_SUITE.iter().any(|x| egal(x, t))
}

/// `Test-ThemeSuite` : un des 5 thèmes de base, ou « pack:<id> » (`^pack:[a-z0-9-]{1,40}$`, sans tenir compte des
/// majuscules).
pub fn theme_valable(t: &str) -> bool {
    if theme_de_base(t) {
        return true;
    }
    let Some(id) = apres_debut(sans_saut_final(t), "pack:") else { return false };
    (1..=40).contains(&id.chars().count()) && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// `Test-NomAppareil` : au plus 64 caractères (UTF-16, comme .NET), sans caractère de contrôle `[\x00-\x1F]`.
pub fn nom_appareil(nom: &str) -> bool {
    nom.encode_utf16().count() <= 64 && !nom.chars().any(|c| (c as u32) < 0x20)
}

/// Un id d'appli de suite.json (`^[a-z0-9-]+$`, sans tenir compte des majuscules).
pub fn id_valable(id: &str) -> bool {
    let id = sans_saut_final(id);
    !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// `$j.<nom>` de PowerShell : une propriété sans tenir compte des majuscules ; sur une liste, celle de chacun de ses
/// objets (« énumération des membres » : une seule valeur trouvée est rendue seule).
pub fn propriete(v: &Value, nom: &str) -> Value {
    match v {
        Value::Object(o) => o.iter().find(|(k, _)| egal(k, nom)).map(|(_, x)| x.clone()).unwrap_or(Value::Null),
        Value::Array(a) => {
            let mut r: Vec<Value> = a.iter().map(|x| propriete(x, nom)).filter(|x| !x.is_null()).collect();
            match r.len() {
                0 => Value::Null,
                1 => r.remove(0),
                _ => Value::Array(r),
            }
        }
        _ => Value::Null,
    }
}

/// `$texte | ConvertFrom-Json` (sans exiger un objet) : un texte vide donne `$null` ; un JSON mal écrit, ou un objet
/// aux clés qui ne diffèrent que par les majuscules (refusé par PowerShell 5.1), `None` (une erreur pour PowerShell).
pub fn convertir(texte: &str) -> Option<Value> {
    let t = texte.trim_start_matches('\u{FEFF}');
    if t.trim().is_empty() {
        return Some(Value::Null);
    }
    let v: Value = serde_json::from_str(t).ok()?;
    (!cles_en_double(&v)).then_some(v)
}

/// [`cles_en_double`] pour un objet lu.
pub fn objet_en_double(o: &Map<String, Value>) -> bool {
    let cles: Vec<&String> = o.keys().collect();
    cles.iter().enumerate().any(|(i, a)| cles[i + 1..].iter().any(|b| egal(a, b))) || o.values().any(cles_en_double)
}

/// Un objet (à n'importe quelle profondeur) dont deux clés ne diffèrent que par les majuscules.
pub fn cles_en_double(v: &Value) -> bool {
    match v {
        Value::Object(o) => objet_en_double(o),
        Value::Array(a) => a.iter().any(cles_en_double),
        _ => false,
    }
}

/// La forme de suite.json écrite par `Write-Suite` : theme, micro, casque (s'ils sont connus), applis, modifie.
pub fn objet_suite(s: &mindset_noyau::donnees::Suite, modifie: &str) -> Value {
    let mut o = Map::new();
    o.insert("theme".into(), s.theme.clone().map_or(Value::Null, Value::String));
    if let Some(m) = &s.micro {
        o.insert("micro".into(), Value::String(m.clone()));
    }
    if let Some(c) = &s.casque {
        o.insert("casque".into(), Value::String(c.clone()));
    }
    let applis: Map<String, Value> = s.applis.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
    o.insert("applis".into(), Value::Object(applis));
    o.insert("modifie".into(), Value::String(modifie.to_string()));
    Value::Object(o)
}

/// `$s.applis[$id] = $dossier` (la table de PowerShell ne tient pas compte des majuscules).
pub fn poser_appli(applis: &mut Vec<(String, String)>, id: &str, dossier: &str) {
    match applis.iter_mut().find(|(k, _)| egal(k, id)) {
        Some(e) => e.1 = dossier.to_string(),
        None => applis.push((id.to_string(), dossier.to_string())),
    }
}

/// `$s.applis.Remove($id)`
pub fn retirer_appli(applis: &mut Vec<(String, String)>, id: &str) {
    applis.retain(|(k, _)| !egal(k, id));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn regles() {
        assert!(
            theme_valable("neon")
                && theme_valable("RUBIS")
                && theme_valable("pack:cafe-creme")
                && theme_valable("PACK:A-1")
        );
        assert!(
            theme_valable("pack:a\n")
                && !theme_valable("neon\n")
                && !theme_valable("pack:")
                && !theme_valable("pack:é")
        );
        assert!(
            theme_valable(&format!("pack:{}", "z".repeat(40))) && !theme_valable(&format!("pack:{}", "z".repeat(41)))
        );
        assert!(
            nom_appareil("")
                && nom_appareil(&"😀".repeat(32))
                && !nom_appareil(&"😀".repeat(33))
                && !nom_appareil("a\tb")
        );
        assert!(nom_appareil("a\u{7f}") && !nom_appareil("a\u{1f}"));
        assert!(
            id_valable("nevermind")
                && id_valable("Mind-2")
                && id_valable("b\n")
                && !id_valable("a b")
                && !id_valable("")
        );
    }

    #[test]
    fn proprietes_a_la_powershell() {
        assert_eq!(propriete(&json!({"theme": "x"}), "Theme"), json!("x"));
        assert_eq!(propriete(&json!([{"Theme": "x"}, {"a": 1}]), "theme"), json!("x"));
        assert_eq!(propriete(&json!([{"Theme": "x"}, {"theme": "y"}]), "theme"), json!(["x", "y"]));
        assert_eq!(propriete(&json!("texte"), "theme"), Value::Null);
        assert_eq!(convertir(""), Some(Value::Null));
        assert_eq!(convertir("\u{FEFF} 1 "), Some(json!(1)));
        assert!(convertir("{\"a\":1,\"A\":2}").is_none() && convertir("{").is_none());
    }
}
