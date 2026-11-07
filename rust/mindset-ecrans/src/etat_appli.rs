//! Le résumé qu'une appli gérée écrit dans son dossier de données (`etat.json`), lu pour sa carte de l'accueil
//! (`Get-EtatAppli`, accueil.ps1:150-181) :
//! - Nevermind : `{ Score, Protection, AFaire, Urgent, NbAFaire }` ;
//! - Evermind : `{ Prochains : [ { Id, Titre, Quand, Journee } ] }` ;
//! - toute autre appli (format commun) : `{ Titre, Scores : [ { Nom, Valeur 0 à 100 } ] (2 au plus),
//!   Lignes : [ { Texte, Etat : ok | info | attention | urgent } ] (3 au plus) }`.
//!
//! Seulement lu pour afficher du texte et des nombres, jamais exécuté ni ouvert : 32 Ko au plus, textes coupés à 80
//! caractères, identifiants de rendez-vous de 32 chiffres hexadécimaux. Les règles de PowerShell 5.1 sont reprises
//! telles quelles (`ConvertFrom-Json`, `[string]`, `[int]::TryParse`, `-eq $true`, champs sans tenir compte des
//! majuscules).

use std::path::Path;

use mindset_noyau::moment::{self, HeureLocale};
use serde_json::Value;
use suite_commun::protocole_installateur::{champ, texte_ps, vrai_ps};

/// 32 Ko : un fichier plus gros n'est pas lu.
pub const TAILLE_MAX: u64 = 32 * 1024;

/// Un rendez-vous d'Evermind.
#[derive(Debug, Clone, PartialEq)]
pub struct Rdv {
    pub id: String,
    pub titre: String,
    pub quand: HeureLocale,
    pub journee: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Score {
    pub nom: String,
    pub valeur: u8,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Ligne {
    pub texte: String,
    /// « ok », « info », « attention » ou « urgent » (en minuscules)
    pub etat: String,
}

/// Ce qu'une appli a écrit.
#[derive(Debug, Clone, PartialEq)]
pub enum Resume {
    Nevermind { score: Option<u8>, protection: Option<u8>, a_faire: String, urgent: bool },
    Evermind { prochains: Vec<Rdv> },
    Commun { titre: String, scores: Vec<Score>, lignes: Vec<Ligne> },
}

/// `$txt` : `[string]`, caractères de contrôle remplacés par des espaces, espaces autour retirés, 80 caractères au
/// plus (des unités UTF-16, comme `Substring(0, 80)` de .NET).
pub fn texte(v: Option<&Value>) -> String {
    let brut = v.map(texte_ps).unwrap_or_default();
    let s: String = brut.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let s = s.trim_matches(espace_net);
    let unites: Vec<u16> = s.encode_utf16().collect();
    if unites.len() > 80 { String::from_utf16_lossy(&unites[..80]) } else { s.to_string() }
}

/// Les espaces que retire `String.Trim()` de .NET (tous les espaces de Unicode).
fn espace_net(c: char) -> bool {
    c.is_whitespace()
}

/// `$pct` : un nombre entier de 0 à 100 (`[int]::TryParse([string]$v)`), sinon rien. Un nombre écrit avec une virgule
/// (« 75.0 ») est refusé : PowerShell 5.1 le lit en décimal et `[string]` garde « .0 ».
pub fn pourcent(v: Option<&Value>) -> Option<u8> {
    let v = v?;
    if v.is_null() {
        return None;
    }
    let t = texte_ps(v);
    let t = t.trim_matches(|c: char| matches!(c, '\u{9}'..='\u{d}' | ' '));
    let n: i64 = t.parse().ok()?;
    if !(i64::from(i32::MIN)..=i64::from(i32::MAX)).contains(&n) {
        return None;
    }
    (0..=100).contains(&n).then_some(n as u8)
}

/// `$x -eq $true` de PowerShell : vrai, le texte « true » (sans tenir compte des majuscules) ou le nombre 1.
pub fn egal_vrai(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => s.eq_ignore_ascii_case("true"),
        Some(Value::Number(n)) => n.as_f64() == Some(1.0),
        Some(Value::Array(a)) => a.iter().any(|x| egal_vrai(Some(x))),
        _ => false,
    }
}

/// `@($x | Select-Object -First n)` : une liste, un seul objet (une liste d'un), ou rien.
fn premiers(v: Option<&Value>, n: usize) -> Vec<Value> {
    match v {
        None => Vec::new(),
        Some(Value::Array(a)) => a.iter().take(n).cloned().collect(),
        Some(x) => vec![x.clone()],
    }
}

fn champ_de<'a>(v: &'a Value, nom: &str) -> Option<&'a Value> {
    v.as_object().and_then(|o| champ(o, nom))
}

/// `[datetime]::TryParseExact($q, 's', ...)` : exactement « yyyy-MM-ddTHH:mm:ss ».
fn date_s(t: &str) -> Option<HeureLocale> {
    let b = t.as_bytes();
    let forme = b.len() == 19
        && b.iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            10 => *c == b'T',
            13 | 16 => *c == b':',
            _ => c.is_ascii_digit(),
        });
    if !forme { None } else { moment::lire_iso(t) }
}

fn id_rdv(t: &str) -> bool {
    t.len() == 32 && t.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

/// Le résumé lu dans un texte d'etat.json (`None` : illisible).
pub fn lire_texte(id_appli: &str, texte_json: &str) -> Option<Resume> {
    let t = texte_json.trim_start_matches('\u{FEFF}');
    // (un fichier vide ou d'espaces : ConvertFrom-Json rend $null sans erreur, le résumé existe, tout y est vide)
    let j = if t.trim().is_empty() { Value::Null } else { suite_commun::protocole_installateur::lire_json(t)? };
    let f = |n: &str| champ_de(&j, n);
    Some(match id_appli {
        "nevermind" => Resume::Nevermind {
            score: pourcent(f("Score")),
            protection: pourcent(f("Protection")),
            a_faire: texte(f("AFaire")),
            urgent: egal_vrai(f("Urgent")),
        },
        "evermind" => Resume::Evermind {
            prochains: premiers(f("Prochains"), 10)
                .iter()
                .filter_map(|p| {
                    let id = champ_de(p, "Id").map(texte_ps).unwrap_or_default();
                    let quand = date_s(&champ_de(p, "Quand").map(texte_ps).unwrap_or_default())?;
                    id_rdv(&id).then(|| Rdv {
                        id,
                        titre: texte(champ_de(p, "Titre")),
                        quand,
                        journee: egal_vrai(champ_de(p, "Journee")),
                    })
                })
                .collect(),
        },
        _ => Resume::Commun {
            titre: texte(f("Titre")),
            scores: premiers(f("Scores"), 2)
                .iter()
                .filter_map(|s| {
                    let v = pourcent(champ_de(s, "Valeur"))?;
                    champ_de(s, "Nom").filter(|n| vrai_ps(n))?;
                    Some(Score { nom: texte(champ_de(s, "Nom")), valeur: v })
                })
                .collect(),
            lignes: premiers(f("Lignes"), 3)
                .iter()
                .filter(|l| champ_de(l, "Texte").is_some_and(vrai_ps))
                .map(|l| {
                    let e = champ_de(l, "Etat").map(texte_ps).unwrap_or_default().to_lowercase();
                    let etat =
                        if ["ok", "info", "attention", "urgent"].contains(&e.as_str()) { e } else { "info".into() };
                    Ligne { texte: texte(champ_de(l, "Texte")), etat }
                })
                .collect(),
        },
    })
}

/// `Get-EtatAppli` : le résumé de l'appli dans son dossier de données (`None` : pas de fichier, trop gros ou illisible).
pub fn lire(id_appli: &str, dossier: &Path) -> Option<Resume> {
    let f = dossier.join("etat.json");
    let md = std::fs::metadata(&f).ok().filter(|m| m.is_file())?;
    if md.len() > TAILLE_MAX {
        return None;
    }
    let octets = std::fs::read(&f).ok()?;
    lire_texte(id_appli, &String::from_utf8_lossy(&octets))
}

/// La date de modification du fichier (le résumé n'est relu que si elle change, comme `$script:EtatsApplis`).
pub fn date_fichier(dossier: &Path) -> Option<std::time::SystemTime> {
    std::fs::metadata(dossier.join("etat.json")).and_then(|m| m.modified()).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn nombres_comme_powershell() {
        assert_eq!(pourcent(Some(&json!(82))), Some(82));
        assert_eq!(pourcent(Some(&json!("  33 "))), Some(33));
        assert_eq!(pourcent(Some(&json!("+7"))), Some(7));
        assert_eq!(pourcent(Some(&json!(75.0))), None);
        assert_eq!(pourcent(Some(&json!(true))), None);
        assert_eq!(pourcent(Some(&json!(101))), None);
        assert_eq!(pourcent(Some(&json!(-1))), None);
        assert_eq!(pourcent(Some(&json!([40]))), Some(40));
        assert_eq!(pourcent(None), None);
    }

    #[test]
    fn textes_coupes_et_nettoyes() {
        assert_eq!(texte(Some(&json!("  a\tb\u{1}c  "))), "a b c");
        assert_eq!(texte(Some(&json!("x".repeat(100)))).len(), 80);
        assert_eq!(texte(None), "");
        assert!(egal_vrai(Some(&json!("TRUE"))) && egal_vrai(Some(&json!(1))) && !egal_vrai(Some(&json!("oui"))));
    }

    #[test]
    fn illisible_ou_vide() {
        assert_eq!(lire_texte("nevermind", "{\"Score\":"), None);
        assert_eq!(
            lire_texte("nevermind", ""),
            Some(Resume::Nevermind { score: None, protection: None, a_faire: String::new(), urgent: false })
        );
    }
}
