//! Les petits textes des Paramètres, à l'identique de parametres.ps1 et mindset.ps1 : la mémoire et le processeur
//! (`Format-MemoireConso`, `Format-ProcesseurConso`), le nom d'un appareil audio (`Get-NomAppareil`) et la liste des
//! choix (`Get-ChoixSonConsole`), une version publiée (`Format-VersionPubliee`), l'historique des mises à jour
//! (`ConvertTo-EntreeMaj`, `Read-HistoriqueMaj` en lecture seule, `Format-QuandMaj`, `Get-AppliMaj`,
//! `Get-HistoriqueMajAffiche`).

use serde_json::{Value, json};
use suite_commun::protocole_installateur::{texte_ps, vrai_ps};

use mindset_noyau::Appli;
use mindset_noyau::moment::HeureLocale;

/// `[math]::Round(x, n)` de .NET Framework : multiplié, arrondi au pair, divisé.
pub fn arrondi(x: f64, chiffres: i32) -> f64 {
    if x.abs() >= 1e16 {
        return x;
    }
    let p = 10f64.powi(chiffres);
    (x * p).round_ties_even() / p
}

/// `ToString('0.#', fr-FR)` d'un nombre déjà arrondi à un chiffre après la virgule.
fn un_chiffre(x: f64) -> String {
    let t = format!("{x:.1}");
    let t = t.strip_suffix(".0").map(str::to_string).unwrap_or(t);
    t.replace('.', ",")
}

/// `ToString('0', fr-FR)` d'un nombre déjà arrondi.
fn entier(x: f64) -> String {
    format!("{x:.0}")
}

/// `Format-MemoireConso` : « 380 Mo », « 1,2 Go ».
pub fn memoire(octets: i64) -> String {
    let mo = octets as f64 / 1_048_576.0;
    if mo < 1000.0 {
        return format!("{} Mo", entier(mo.round_ties_even()));
    }
    format!("{} Go", un_chiffre(arrondi(mo / 1024.0, 1)))
}

/// `Format-ProcesseurConso` : « 1,5 % », « 12 % ».
pub fn processeur(p: f64) -> String {
    if p < 10.0 { format!("{} %", un_chiffre(arrondi(p, 1))) } else { format!("{} %", entier(p.round_ties_even())) }
}

/// `Get-NomAppareil` : Windows coupe les noms à 31 lettres ; « … » le montre au lieu d'une parenthèse qui ne se ferme
/// pas.
pub fn nom_appareil(nom: &str) -> String {
    let u: Vec<u16> = nom.encode_utf16().collect();
    let debut = |n: usize| String::from_utf16_lossy(&u[..n.min(u.len())]);
    let fin = |n: usize| String::from_utf16_lossy(&u[n.min(u.len())..]);
    if u.len() >= 31 {
        let d = debut(31);
        // (-match '\([^)]*$' : une parenthèse ouverte qui ne se ferme pas)
        let ouverte = d.rfind('(').is_some_and(|i| !d[i..].contains(')'));
        if ouverte {
            return format!("{}…){}", d.trim_end(), fin(31));
        }
    }
    if u.len() == 31 {
        return format!("{}…", nom.trim_end());
    }
    nom.to_string()
}

/// `Get-ChoixSonConsole` : « Celui de Windows », puis chaque appareil du PC, puis le choisi s'il est débranché.
pub fn choix_son(noms: &[String], choisi: &str) -> Vec<Value> {
    let mut l = vec![json!({ "cle": "", "nom": "Celui de Windows", "oui": choisi.is_empty() })];
    let mut vus: Vec<&str> = Vec::new();
    for n in noms {
        if vus.contains(&n.as_str()) {
            continue;
        }
        vus.push(n);
        if !n.is_empty() {
            l.push(json!({ "cle": n, "nom": nom_appareil(n), "oui": crate::packs::egal(n, choisi) }));
        }
    }
    if !choisi.is_empty() && !noms.iter().any(|n| crate::packs::egal(n, choisi)) {
        l.push(json!({ "cle": choisi, "nom": format!("{} (débranché)", nom_appareil(choisi)), "oui": true }));
    }
    l
}

/// `Format-VersionPubliee` : « 0.90.0 », ou « 0.90.0 (essai) ».
pub fn version_publiee(p: &Value) -> String {
    let essai = p.get("essai").is_some_and(vrai_ps);
    format!("{}{}", p.get("version").map(texte_ps).unwrap_or_default(), if essai { " (essai)" } else { "" })
}

// ---------------------------------------------------------------------------------------------------------------
// L'historique des mises à jour (mises-a-jour.json, écrit par le bloc « lui-même » : lu ici seulement)
// ---------------------------------------------------------------------------------------------------------------

/// Une entrée de l'historique.
#[derive(Debug, Clone, PartialEq)]
pub struct Entree {
    pub id: String,
    pub nom: String,
    pub version: String,
    /// Au format « s »
    pub quand: String,
    pub auto: bool,
}

/// `^\d+(\.\d+){1,3}$`
fn version_valable(v: &str) -> bool {
    let v = v.strip_suffix('\n').unwrap_or(v);
    let p: Vec<&str> = v.split('.').collect();
    (2..=4).contains(&p.len()) && p.iter().all(|x| !x.is_empty() && x.chars().all(|c| c.is_ascii_digit()))
}

/// `^[a-z0-9-]{1,30}$` sans tenir compte des majuscules (`-notmatch`)
fn id_valable(v: &str) -> bool {
    let v = v.strip_suffix('\n').unwrap_or(v);
    (1..=30).contains(&v.len()) && v.bytes().all(|o| o.is_ascii_alphanumeric() || o == b'-')
}

/// `TryParseExact(.., 's')` : « yyyy-MM-ddTHH:mm:ss » exactement, une vraie date.
pub fn lire_moment(t: &str) -> Option<HeureLocale> {
    let b = t.as_bytes();
    if b.len() != 19 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let n = |a: usize, z: usize| -> Option<u32> {
        let s = t.get(a..z)?;
        if s.bytes().all(|o| o.is_ascii_digit()) { s.parse().ok() } else { None }
    };
    let (annee, mois, jour) = (n(0, 4)?, n(5, 7)?, n(8, 10)?);
    let (heure, minute, seconde) = (n(11, 13)?, n(14, 16)?, n(17, 19)?);
    let bissextile = (annee % 4 == 0 && annee % 100 != 0) || annee % 400 == 0;
    let jours = [31, if bissextile { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if annee == 0 || !(1..=12).contains(&mois) || jour == 0 || jour > jours[mois as usize - 1] {
        return None;
    }
    if heure > 23 || minute > 59 || seconde > 59 {
        return None;
    }
    Some(HeureLocale { annee: annee as i32, mois, jour, heure, minute, seconde })
}

/// `ConvertTo-EntreeMaj` : seulement des valeurs attendues.
pub fn entree(x: &Value) -> Option<Entree> {
    if !vrai_ps(x) {
        return None;
    }
    let champ = |n: &str| x.as_object().and_then(|o| o.get(n)).map(texte_ps).unwrap_or_default();
    let id = champ("id");
    let version = champ("version");
    if !id_valable(&id) || !version_valable(&version) {
        return None;
    }
    let quand = lire_moment(&champ("quand"))?;
    let nom: String = {
        let u: Vec<u16> = champ("nom").encode_utf16().collect();
        String::from_utf16_lossy(&u[..u.len().min(30)])
    };
    let auto = x.as_object().and_then(|o| o.get("auto")).is_some_and(vrai_ps);
    Some(Entree { id, nom, version, quand: mindset_noyau::moment::iso(&quand), auto })
}

/// L'historique lu (`(Read-HistoriqueMaj).Liste`) : 20 entrées au plus, les mal écrites oubliées.
pub fn historique(j: Option<&Value>) -> Vec<Entree> {
    let Some(j) = j else { return Vec::new() };
    let h = j.as_object().and_then(|o| o.get("historique"));
    let liste: Vec<&Value> = match h {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(a)) => a.iter().collect(),
        Some(v) => vec![v],
    };
    liste.into_iter().filter_map(entree).take(20).collect()
}

/// Le numéro du jour (jours depuis le 01/01/1970) d'une date.
fn jour(a: i32, m: u32, j: u32) -> i64 {
    let (a, m) = if m <= 2 { (i64::from(a) - 1, i64::from(m) + 9) } else { (i64::from(a), i64::from(m) - 3) };
    let ere = a.div_euclid(400);
    let ae = a - ere * 400;
    let jda = (153 * m + 2) / 5 + i64::from(j) - 1;
    let jde = ae * 365 + ae / 4 - ae / 100 + jda;
    ere * 146_097 + jde - 719_468
}

const MOIS: [&str; 12] = [
    "janvier",
    "février",
    "mars",
    "avril",
    "mai",
    "juin",
    "juillet",
    "août",
    "septembre",
    "octobre",
    "novembre",
    "décembre",
];

/// `Format-QuandMaj` : « à 00 h 16 », « hier à 21 h 05 », « le 18 octobre à 09 h 30 » (`long` : « aujourd'hui à
/// 00 h 16 »).
pub fn quand(q: &HeureLocale, maintenant: &HeureLocale, long: bool) -> String {
    let h = format!("{:02} h {:02}", q.heure, q.minute);
    let jours = jour(maintenant.annee, maintenant.mois, maintenant.jour) - jour(q.annee, q.mois, q.jour);
    if jours == 0 {
        return format!("{}à {h}", if long { "aujourd'hui " } else { "" });
    }
    if jours == 1 {
        return format!("hier à {h}");
    }
    format!("le {} {} à {h}", q.jour, MOIS[(q.mois as usize).clamp(1, 12) - 1])
}

/// `Get-AppliMaj` : le nom et la couleur d'une entrée (ceux de l'appli de la liste, ou de Mindset, sinon le nom noté).
pub fn appli_maj(applis: &[Appli], id: &str, nom: &str) -> (String, String) {
    if crate::packs::egal(id, "mindset") {
        return ("Mindset".into(), "#ECEAF7".into());
    }
    match applis.iter().find(|a| crate::packs::egal(&a.id, id)) {
        Some(a) => (a.nom.clone(), a.couleur.clone()),
        None => (nom.to_string(), "#A9A3C9".into()),
    }
}

/// La première lettre en majuscule (`$q.Substring(0, 1).ToUpper() + $q.Substring(1)`).
fn majuscule(t: &str) -> String {
    let mut c = t.chars();
    match c.next() {
        Some(p) => p.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// `Get-HistoriqueMajAffiche` : nom, couleur (traduite), brut, version, quand, automatique ou non.
pub fn historique_affiche(
    liste: &[Entree],
    applis: &[Appli],
    maintenant: &HeureLocale,
    traduire: &dyn Fn(&str) -> String,
) -> Vec<Value> {
    liste
        .iter()
        .map(|e| {
            let (nom, couleur) = appli_maj(applis, &e.id, &e.nom);
            let q = lire_moment(&e.quand).map(|q| quand(&q, maintenant, true)).unwrap_or_default();
            json!({ "nom": nom, "couleur": traduire(&couleur), "brut": couleur, "version": e.version,
                "quand": majuscule(&q), "auto": e.auto })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chiffres() {
        assert_eq!(memoire(380 * 1_048_576), "380 Mo");
        assert_eq!(memoire(1536 * 1_048_576), "1,5 Go");
        assert_eq!(memoire(1024 * 1_048_576), "1 Go");
        assert_eq!(processeur(0.0), "0 %");
        assert_eq!(processeur(2.25), "2,2 %");
        assert_eq!(processeur(12.5), "12 %");
    }

    #[test]
    fn appareils() {
        assert_eq!(nom_appareil("Haut-parleurs (Realtek High Def"), "Haut-parleurs (Realtek High Def…)");
        assert_eq!(nom_appareil("Micro (Realtek(R) Audio Haute D"), "Micro (Realtek(R) Audio Haute D…");
        assert_eq!(nom_appareil("Casque"), "Casque");
        let l = choix_son(&["A".into(), "A".into(), "".into()], "B");
        assert_eq!(l.len(), 3);
        assert_eq!(l[2]["nom"], "B (débranché)");
    }

    #[test]
    fn moments() {
        let m = lire_moment("2026-11-07T20:00:00").unwrap();
        assert_eq!(quand(&lire_moment("2026-11-07T00:16:00").unwrap(), &m, true), "aujourd'hui à 00 h 16");
        assert_eq!(quand(&lire_moment("2026-11-06T21:05:00").unwrap(), &m, false), "hier à 21 h 05");
        assert_eq!(quand(&lire_moment("2026-10-18T09:30:00").unwrap(), &m, true), "le 18 octobre à 09 h 30");
        assert!(lire_moment("2026-02-30T00:00:00").is_none());
        assert!(lire_moment("2026-11-07 20:00:00").is_none());
    }
}
