//! Les réglages (donnees.ps1:155-209) : une table aux noms sans majuscules (`@{}` de PowerShell), et la reprise de
//! ce qui se lit encore dans un reglages.json abîmé sans copie lisible.
//!
//! La reprise suit exactement les trois motifs de `Read-Reglages` (sensibles aux majuscules, comme `[regex]::Matches`) :
//! - `"(LancerAvecWindows|VerifVersions|MajAuto|ReduireHorloge|BulleHorlogeVue|DemarrageRepris)"\s*:\s*(true|false)\b`
//! - `"(Fermeture|Animations)"\s*:\s*"([a-z]{1,20})"`
//! - `"Demarrage"\s*:\s*(\[[^\]]*\]|"[a-z0-9-]+")` (le premier seulement), puis chaque `"([a-z0-9-]{1,30})"` dedans.

use serde_json::{Map, Value};
use suite_commun::chemins::egal;

/// Les réglages qui restent coupés quand ils sont perdus (`$ReglagesPrudents`) : jamais rallumés en silence.
pub const REGLAGES_PRUDENTS: [&str; 2] = ["VerifVersions", "MajAuto"];

const OUI_NON: [&str; 6] =
    ["LancerAvecWindows", "VerifVersions", "MajAuto", "ReduireHorloge", "BulleHorlogeVue", "DemarrageRepris"];
const MOTS: [&str; 2] = ["Fermeture", "Animations"];

/// Le nom déjà présent dans la table qui vaut `nom` sans tenir compte des majuscules.
pub fn cle<'a>(m: &'a Map<String, Value>, nom: &str) -> Option<&'a String> {
    m.keys().find(|k| egal(k, nom))
}

/// `$table[$nom]` : la valeur, sans tenir compte des majuscules.
pub fn lire<'a>(m: &'a Map<String, Value>, nom: &str) -> Option<&'a Value> {
    cle(m, nom).and_then(|k| m.get(k))
}

/// `$table[$nom] = $valeur` : un nom qui existe déjà (aux majuscules près) garde son écriture.
pub fn poser(m: &mut Map<String, Value>, nom: &str, valeur: Value) {
    match cle(m, nom).cloned() {
        Some(k) => {
            m.insert(k, valeur);
        }
        None => {
            m.insert(nom.to_string(), valeur);
        }
    }
}

/// Un objet JSON lu devient une table (`foreach ($p in $j.PSObject.Properties) { $r[$p.Name] = $p.Value }`).
pub fn table(o: Map<String, Value>) -> Map<String, Value> {
    let mut r = Map::new();
    for (k, v) in o {
        poser(&mut r, &k, v);
    }
    r
}

/// `\s` de .NET : les espaces de Unicode (les mêmes que `char::is_whitespace`).
fn espace(c: char) -> bool {
    c.is_whitespace()
}

/// `\w` de .NET (lettres, chiffres, trait bas), pour `\b`.
fn lettre_de_mot(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Après `:` entouré d'espaces (`\s*:\s*`) à partir de `i` : la position qui suit, ou `None`.
fn deux_points(t: &[char], mut i: usize) -> Option<usize> {
    while i < t.len() && espace(t[i]) {
        i += 1;
    }
    if t.get(i) != Some(&':') {
        return None;
    }
    i += 1;
    while i < t.len() && espace(t[i]) {
        i += 1;
    }
    Some(i)
}

/// `"<un des noms>"` à la position `i` : le nom et la position qui suit le guillemet fermant.
fn nom_entre_guillemets<'a>(t: &[char], i: usize, noms: &[&'a str]) -> Option<(&'a str, usize)> {
    if t.get(i) != Some(&'"') {
        return None;
    }
    for n in noms {
        let fin = i + 1 + n.chars().count();
        if fin < t.len() && t[i + 1..fin].iter().copied().eq(n.chars()) && t[fin] == '"' {
            return Some((n, fin + 1));
        }
    }
    None
}

fn commence_par(t: &[char], i: usize, mot: &str) -> bool {
    let n = mot.chars().count();
    i + n <= t.len() && t[i..i + n].iter().copied().eq(mot.chars())
}

/// Un motif essayé à chaque position, de gauche à droite, sans chevauchement (`[regex]::Matches`).
fn chaque<T>(t: &[char], mut essai: impl FnMut(usize) -> Option<(T, usize)>) -> Vec<T> {
    let mut r = Vec::new();
    let mut i = 0;
    while i < t.len() {
        match essai(i) {
            Some((x, fin)) => {
                r.push(x);
                i = fin.max(i + 1);
            }
            None => i += 1,
        }
    }
    r
}

/// `"([a-z0-9-]{1,30})"` à chaque position de `t`.
fn identifiants(t: &[char]) -> Vec<String> {
    chaque(t, |i| {
        if t[i] != '"' {
            return None;
        }
        let mut j = i + 1;
        while j < t.len() && (t[j].is_ascii_lowercase() || t[j].is_ascii_digit() || t[j] == '-') {
            j += 1;
        }
        let n = j - i - 1;
        ((1..=30).contains(&n) && t.get(j) == Some(&'"')).then(|| (t[i + 1..j].iter().collect(), j + 1))
    })
}

/// Ce qui se lit encore dans un reglages.json abîmé (`Read-Reglages`, donnees.ps1:168-173), dans l'ordre des motifs.
pub fn reprise(abime: &str) -> Map<String, Value> {
    let t: Vec<char> = abime.chars().collect();
    let mut r = Map::new();
    // 1. Les oui / non
    for (n, v) in chaque(&t, |i| {
        let (n, j) = nom_entre_guillemets(&t, i, &OUI_NON)?;
        let j = deux_points(&t, j)?;
        let (v, fin) = if commence_par(&t, j, "true") {
            (true, j + 4)
        } else if commence_par(&t, j, "false") {
            (false, j + 5)
        } else {
            return None;
        };
        if t.get(fin).is_some_and(|c| lettre_de_mot(*c)) {
            return None;
        }
        Some(((n, v), fin))
    }) {
        poser(&mut r, n, Value::Bool(v));
    }
    // 2. Fermeture, Animations
    for (n, v) in chaque(&t, |i| {
        let (n, j) = nom_entre_guillemets(&t, i, &MOTS)?;
        let j = deux_points(&t, j)?;
        if t.get(j) != Some(&'"') {
            return None;
        }
        let mut k = j + 1;
        while k < t.len() && t[k].is_ascii_lowercase() {
            k += 1;
        }
        let n_lettres = k - j - 1;
        ((1..=20).contains(&n_lettres) && t.get(k) == Some(&'"'))
            .then(|| ((n, t[j + 1..k].iter().collect::<String>()), k + 1))
    }) {
        poser(&mut r, n, Value::String(v));
    }
    // 3. Demarrage (la première fois seulement)
    let demarrage = chaque(&t, |i| {
        let (_, j) = nom_entre_guillemets(&t, i, &["Demarrage"])?;
        let j = deux_points(&t, j)?;
        match t.get(j) {
            Some('[') => {
                let k = (j + 1..t.len()).find(|&k| t[k] == ']')?;
                Some((t[j..=k].to_vec(), k + 1))
            }
            Some('"') => {
                let mut k = j + 1;
                while k < t.len() && (t[k].is_ascii_lowercase() || t[k].is_ascii_digit() || t[k] == '-') {
                    k += 1;
                }
                (k > j + 1 && t.get(k) == Some(&'"')).then(|| (t[j..=k].to_vec(), k + 1))
            }
            _ => None,
        }
    });
    if let Some(g) = demarrage.first() {
        let ids = identifiants(g).into_iter().map(Value::String).collect();
        poser(&mut r, "Demarrage", Value::Array(ids));
    }
    r
}

/// Les noms repris, dans l'ordre de `Sort-Object` (sans tenir compte des majuscules), pour le journal.
pub fn noms_tries(m: &Map<String, Value>) -> Vec<String> {
    let mut n: Vec<String> = m.keys().cloned().collect();
    n.sort_by_key(|k| k.to_lowercase());
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reprise_d_un_fichier_coupe() {
        let r = reprise(
            "{\r\n  \"LancerAvecWindows\": false,\r\n  \"VerifVersions\": false,\r\n  \"Demarrage\": [ \"evermind\", \"mindcare\" ],\r\n  \"Fermeture\": \"reduire\",\r\n  \"Animations\": \"compl",
        );
        assert_eq!(
            Value::Object(r),
            json!({ "LancerAvecWindows": false, "VerifVersions": false, "Fermeture": "reduire", "Demarrage": ["evermind", "mindcare"] })
        );
    }

    #[test]
    fn reprise_au_plus_pres_des_motifs() {
        // (\b : « falsex » ne compte pas ; majuscules : « MAJAUTO » ne compte pas ; la dernière valeur gagne)
        let r = reprise(r#"{"MajAuto":falsex,"MAJAUTO":true,"ReduireHorloge" : true,"ReduireHorloge":false}"#);
        assert_eq!(Value::Object(r), json!({ "ReduireHorloge": false }));
        let r = reprise(r#"{"Fermeture":"QUITTER","Animations":"aucune","Demarrage":"nevermind","Demarrage":["x"]}"#);
        assert_eq!(Value::Object(r), json!({ "Animations": "aucune", "Demarrage": ["nevermind"] }));
        let r = reprise(r#"{"Demarrage": [], "x": 1}"#);
        assert_eq!(Value::Object(r), json!({ "Demarrage": [] }));
        let long = format!(r#"{{"Demarrage":["{}","ok"]}}"#, "a".repeat(31));
        assert_eq!(Value::Object(reprise(&long)), json!({ "Demarrage": ["ok"] }));
        assert!(reprise("").is_empty());
    }

    #[test]
    fn table_sans_majuscules() {
        let mut m = Map::new();
        poser(&mut m, "MajAuto", json!(true));
        poser(&mut m, "majauto", json!(false));
        assert_eq!(Value::Object(m.clone()), json!({ "MajAuto": false }));
        assert_eq!(lire(&m, "MAJAUTO"), Some(&json!(false)));
        assert_eq!(
            noms_tries(&table(json!({"b":1,"A":2,"Demarrage":3,"DemarrageRepris":4}).as_object().unwrap().clone())),
            ["A", "b", "Demarrage", "DemarrageRepris"]
        );
    }
}
