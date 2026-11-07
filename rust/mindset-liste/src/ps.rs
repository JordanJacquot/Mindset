//! Les petites règles de Windows PowerShell 5.1 dont la liste des applis a besoin pour lire une entrée exactement
//! comme `ConvertTo-Appli` (liste.ps1) : `[string]`, `if ($x)`, `-match` (sur un texte ou un tableau), le `$` des
//! expressions de .NET (qui accepte un dernier « \n »), `-eq $true`, `[Environment]::ExpandEnvironmentVariables`,
//! `[double]::TryParse(..., Float, InvariantCulture)` et `ConvertFrom-Json`.
//!
//! Chaque règle a été vérifiée sur la vraie version PowerShell (les juges de `tests/juges`, exportés par
//! `outils\exporter-juges-liste.ps1`).

use serde_json::{Map, Value};

pub(crate) use suite_commun::protocole_installateur::vrai_ps;

/// `[string]$x` : le texte d'une valeur lue en JSON (un tableau : ses éléments séparés par une espace ; un objet :
/// `@{a=1; b=2}`, vide s'il n'a aucun champ).
pub(crate) fn texte(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.clone(),
        Value::Array(a) => a.iter().map(texte_dans_tableau).collect::<Vec<_>>().join(" "),
        Value::Object(o) => texte_objet(o),
    }
}

/// Un élément d'un tableau mis en texte (un tableau dans un tableau : son nom de type, comme .NET).
fn texte_dans_tableau(v: &Value) -> String {
    match v {
        Value::Array(_) => "System.Object[]".into(),
        _ => texte(v),
    }
}

/// Un objet (`PSCustomObject`) mis en texte : `@{a=1; b=x}`, rien s'il n'a aucun champ.
fn texte_objet(o: &Map<String, Value>) -> String {
    if o.is_empty() {
        return String::new();
    }
    let champs: Vec<String> = o.iter().map(|(k, v)| format!("{k}={}", texte_dans_tableau(v))).collect();
    format!("@{{{}}}", champs.join("; "))
}

/// Le champ `nom` d'une entrée (les noms des champs ne tiennent pas compte des majuscules en PowerShell), `Null`
/// s'il est absent ou si l'entrée n'est pas un objet.
pub(crate) fn champ<'a>(v: &'a Value, nom: &str) -> &'a Value {
    const RIEN: &Value = &Value::Null;
    match v {
        Value::Object(o) => suite_commun::protocole_installateur::champ(o, nom).unwrap_or(RIEN),
        _ => RIEN,
    }
}

/// Le `$` des expressions de .NET : la fin du texte, ou juste avant un dernier « \n ». Vrai si `motif` (qui juge un
/// texte entier) accepte le texte, ou le texte sans son dernier « \n ».
pub(crate) fn correspond(s: &str, motif: &dyn Fn(&str) -> bool) -> bool {
    motif(s) || s.strip_suffix('\n').is_some_and(motif)
}

/// `$x -match '...'` dans un `if` : sur un tableau, les éléments qui correspondent (vrai s'il en reste, au sens de
/// PowerShell) ; sinon, le texte de la valeur.
pub(crate) fn correspond_ps(v: &Value, motif: &dyn Fn(&str) -> bool) -> bool {
    match v {
        Value::Array(a) => {
            vrai_ps(&Value::Array(a.iter().filter(|e| correspond(&texte_dans_tableau(e), motif)).cloned().collect()))
        }
        _ => correspond(&texte(v), motif),
    }
}

/// `$x -notmatch '...'` dans un `if` (sur un tableau : les éléments qui ne correspondent pas).
pub(crate) fn ne_correspond_pas_ps(v: &Value, motif: &dyn Fn(&str) -> bool) -> bool {
    match v {
        Value::Array(a) => {
            vrai_ps(&Value::Array(a.iter().filter(|e| !correspond(&texte_dans_tableau(e), motif)).cloned().collect()))
        }
        _ => !correspond(&texte(v), motif),
    }
}

/// `$x -eq $true` dans un `if` : un booléen vrai, un nombre égal à 1, le texte « true » (sans tenir compte des
/// majuscules) ; sur un tableau, les éléments qui valent `$true`.
pub(crate) fn vaut_vrai(v: &Value) -> bool {
    fn un(v: &Value) -> bool {
        match v {
            Value::Bool(b) => *b,
            Value::Number(n) => n.as_f64() == Some(1.0),
            Value::String(s) => s.eq_ignore_ascii_case("true"),
            _ => false,
        }
    }
    match v {
        Value::Array(a) => vrai_ps(&Value::Array(a.iter().filter(|e| un(e)).cloned().collect())),
        _ => un(v),
    }
}

/// Une valeur prise par `if (...) { a } else { $x }` : un tableau d'un seul élément devient cet élément, un tableau
/// vide devient `$null` (PowerShell déroule ce qui sort d'une instruction).
pub(crate) fn deroule(v: &Value) -> Value {
    match v {
        Value::Array(a) if a.is_empty() => Value::Null,
        Value::Array(a) if a.len() == 1 => a[0].clone(),
        _ => v.clone(),
    }
}

/// Un caractère de mot (`\w` de .NET : lettres, chiffres, marques, « _ » et les autres traits de liaison).
pub(crate) fn mot(c: char) -> bool {
    c.is_alphanumeric()
        || matches!(c, '_' | '\u{203F}' | '\u{2040}' | '\u{2054}' | '\u{FE33}' | '\u{FE34}' | '\u{FE4D}'..='\u{FE4F}')
        || c == '\u{FF3F}'
}

/// `[Environment]::ExpandEnvironmentVariables` : chaque `%NOM%` connu est remplacé (sans tenir compte des
/// majuscules), un nom inconnu reste tel quel (et son second « % » peut ouvrir le nom suivant).
pub(crate) fn developper_variables(s: &str, variable: &dyn Fn(&str) -> Option<String>) -> String {
    let mut sortie = String::with_capacity(s.len());
    let mut reste = s;
    while let Some(i) = reste.find('%') {
        sortie.push_str(&reste[..i]);
        let apres = &reste[i + 1..];
        let Some(j) = apres.find('%') else {
            sortie.push_str(&reste[i..]);
            return sortie;
        };
        let nom = &apres[..j];
        match (!nom.is_empty()).then(|| variable(nom)).flatten() {
            Some(valeur) => {
                sortie.push_str(&valeur);
                reste = &apres[j + 1..];
            }
            None => {
                // (le « % » de fin peut ouvrir le nom suivant)
                sortie.push('%');
                sortie.push_str(nom);
                reste = &apres[j..];
            }
        }
    }
    sortie.push_str(reste);
    sortie
}

/// Les vraies variables d'environnement de ce processus (pour `developper_variables`).
pub(crate) fn variable_du_pc(nom: &str) -> Option<String> {
    std::env::var_os(nom).map(|v| v.to_string_lossy().into_owned())
}

/// `[double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, ...)` :
/// espaces autour permis, un signe, des chiffres avec un point, un exposant. Les nombres spéciaux (infini, « NaN »)
/// ne sont jamais rendus (`None`) : une épaisseur infinie ou « NaN » n'a pas de sens.
pub(crate) fn nombre_dotnet(t: &str) -> Option<f64> {
    let t = t.trim_matches(|c: char| matches!(c, '\u{9}'..='\u{D}' | ' '));
    if t.is_empty() || !t.bytes().all(|o| o.is_ascii_digit() || matches!(o, b'+' | b'-' | b'.' | b'e' | b'E')) {
        return None;
    }
    t.parse::<f64>().ok().filter(|x| x.is_finite())
}

/// Un JSON abîmé (`ConvertFrom-Json` échoue).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JsonAbime;

/// `ConvertFrom-Json` de Windows PowerShell 5.1 sur un texte : `Ok(None)` pour un texte vide ou fait d'espaces (il ne
/// rend rien), `Ok(Some(..))` pour une valeur lue, `Err` pour un JSON abîmé (aussi : une marque d'encodage restée dans
/// le texte, ou deux champs dont les noms ne diffèrent que par les majuscules).
pub(crate) fn depuis_json(texte: &str) -> Result<Option<Value>, JsonAbime> {
    if texte.starts_with('\u{FEFF}') {
        return Err(JsonAbime);
    }
    if texte.trim().is_empty() {
        return Ok(None);
    }
    suite_commun::protocole_installateur::lire_json(texte).map(Some).ok_or(JsonAbime)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn textes_a_la_powershell() {
        assert_eq!(texte(&json!(null)), "");
        assert_eq!(texte(&json!(true)), "True");
        assert_eq!(texte(&json!(["A", "B"])), "A B");
        assert_eq!(texte(&json!({"a": 1})), "@{a=1}");
        assert_eq!(texte(&json!({})), "");
        assert_eq!(texte(&json!(1.5)), "1.5");
    }

    #[test]
    fn fin_de_texte_de_dotnet() {
        let exact = |t: &str| t == "abc";
        assert!(correspond("abc", &exact));
        assert!(correspond("abc\n", &exact));
        assert!(!correspond("abc\n\n", &exact));
        assert!(!correspond("\nabc", &exact));
        assert!(correspond_ps(&json!(["x", "abc"]), &exact));
        assert!(!correspond_ps(&json!(["x"]), &exact));
        assert!(ne_correspond_pas_ps(&json!(["abc", "x"]), &exact));
        assert!(!ne_correspond_pas_ps(&json!(["abc"]), &exact));
    }

    #[test]
    fn variables() {
        let v = |n: &str| n.eq_ignore_ascii_case("A").then(|| "[a]".to_string());
        assert_eq!(developper_variables("%A%\\x", &v), "[a]\\x");
        assert_eq!(developper_variables("%a%", &v), "[a]");
        assert_eq!(developper_variables("%B%A%", &v), "%B[a]");
        assert_eq!(developper_variables("%%A%%", &v), "%[a]%");
        assert_eq!(developper_variables("%%", &v), "%%");
        assert_eq!(developper_variables("100%", &v), "100%");
        assert_eq!(developper_variables("a%b%c", &v), "a%b%c");
    }

    #[test]
    fn nombres() {
        assert_eq!(nombre_dotnet(" 8 "), Some(8.0));
        assert_eq!(nombre_dotnet("+9"), Some(9.0));
        assert_eq!(nombre_dotnet("9."), Some(9.0));
        assert_eq!(nombre_dotnet("1e1"), Some(10.0));
        for faux in ["8,5", "abc", "", "0x10", "Infinity", "NaN", "inf", "8 9"] {
            assert_eq!(nombre_dotnet(faux), None, "{faux}");
        }
    }

    #[test]
    fn json_a_la_powershell() {
        assert_eq!(depuis_json("   "), Ok(None));
        assert_eq!(depuis_json("null"), Ok(Some(Value::Null)));
        assert!(depuis_json("\u{FEFF}{}").is_err());
        assert!(depuis_json("{\"a\":1,\"A\":2}").is_err());
        assert!(depuis_json("[ {").is_err());
    }
}
