//! La dernière version publiée d'une appli sur GitHub (paquets.ps1) : `Get-Publication`, `ConvertFrom-Release`,
//! `Get-Preversion`, `Get-PreversionSansApi`, `Get-PublicationSansApi`, `Test-FichierPublie`, `Get-NotesPage`.
//!
//! Tout passe par le port [`Reseau`] : le vrai (WinHTTP, `crate::reseau_windows`) dans Mindset, le faux GitHub
//! (`FauxReseau`) dans les tests. Les mêmes questions, dans le même ordre, que la version PowerShell (les juges le
//! vérifient : tests\juges\publications.json, avec la liste des questions posées).
//!
//! Les règles, telles qu'elles sont :
//! - la dernière version normale par l'API (`releases/latest`) ; refusée (60 questions par heure et par connexion) :
//!   par la redirection de la page `releases/latest` (sans limite), puis les fichiers de cette version ;
//! - le canal d'essai (case « Recevoir les versions d'essai ») : la préversion la plus récente, si elle est plus
//!   récente que la version normale ; sans l'API : le flux `releases.atom` ;
//! - le premier des noms du zip qui est publié (le nom d'aujourd'hui, puis l'ancien) ; la signature `<zip>.sig`
//!   (absente : `url_sig` vide, et rien ne sera installé).

use std::time::Duration;

use mindset_noyau::reseau::{DemandeHttp, Methode, Reseau};
use regex::Regex;
use serde_json::{Map, Value, json};
use suite_commun::protocole_installateur::{texte_ps, vrai_ps};

use crate::html;
use crate::telechargement::erreur_http;
use crate::version_net::{self, VersionNet};

/// Une version publiée (`@{ Version; Fichier; UrlZip; UrlSig; Notes; Essai }`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Publication {
    /// Le numéro (le nom de la version sans son « v »)
    pub version: String,
    /// Le nom du zip trouvé (le nom d'aujourd'hui ou l'ancien)
    pub fichier: String,
    pub url_zip: String,
    /// La signature ; `None` : pas publiée (Mindset refuse alors d'installer)
    pub url_sig: Option<String>,
    pub notes: String,
    /// Une préversion (canal d'essai)
    pub essai: bool,
}

/// Une publication, ou l'erreur (`@{ Erreur = ... }`).
pub type Reponse = Result<Publication, String>;

/// Le délai des questions à GitHub (`-TimeoutSec 15`, `Timeout = 15000`).
const DELAI_QUESTION: Duration = Duration::from_secs(15);
/// Le délai de `Net.WebClient` (100 secondes, celui de .NET).
const DELAI_PAGE: Duration = Duration::from_secs(100);
/// Une réponse de GitHub (JSON, flux, page) plus grosse est refusée (la version PowerShell n'avait pas de plafond :
/// DIVERGENCES.md). Une liste de 30 versions fait quelques centaines de Ko.
const MAX_REPONSE: u64 = 32 * 1024 * 1024;

fn demande(adresse: &str, methode: Methode, suivre: bool, delai: Duration) -> DemandeHttp {
    DemandeHttp {
        adresse: adresse.to_string(),
        methode,
        entetes: Vec::new(),
        suivre_redirections: suivre,
        max_octets: MAX_REPONSE,
        delai,
    }
}

/// Le texte d'une réponse (UTF-8, marque d'encodage retirée, comme `DownloadString`).
fn texte(corps: &[u8]) -> String {
    let corps = corps.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(corps);
    String::from_utf8_lossy(corps).into_owned()
}

/// `Invoke-RestMethod` : la réponse lue comme du JSON (sinon le texte tel quel) ; une erreur s'il n'y a pas de réponse
/// ou si GitHub répond 400 ou plus.
fn api(reseau: &dyn Reseau, adresse: &str) -> Result<Value, String> {
    let r = reseau.demander(&demande(adresse, Methode::Get, true, DELAI_QUESTION), None)?;
    if r.statut >= 400 {
        return Err(erreur_http(r.statut));
    }
    let t = texte(&r.corps);
    Ok(serde_json::from_str::<Value>(&t).unwrap_or(Value::String(t)))
}

/// `(New-Object Net.WebClient).DownloadString` : le texte, ou une erreur.
fn page(reseau: &dyn Reseau, adresse: &str) -> Result<String, String> {
    let r = reseau.demander(&demande(adresse, Methode::Get, true, DELAI_PAGE), None)?;
    if r.statut >= 400 {
        return Err(erreur_http(r.statut));
    }
    Ok(texte(&r.corps))
}

// ---------------------------------------------------------------------------------------------------------------
// Lire le JSON comme PowerShell
// ---------------------------------------------------------------------------------------------------------------

/// `$objet.nom` : un champ (le nom sans tenir compte des majuscules, comme PowerShell) ; rien sur autre chose qu'un
/// objet.
fn champ<'a>(v: &'a Value, nom: &str) -> &'a Value {
    match v {
        Value::Object(m) => m.iter().find(|(k, _)| k.eq_ignore_ascii_case(nom)).map(|(_, x)| x).unwrap_or(&Value::Null),
        _ => &Value::Null,
    }
}

/// `@($x)` parcouru (`$x | Where-Object`) : les éléments d'un tableau, rien pour `$null`, sinon la valeur seule.
fn elements(v: &Value) -> Vec<&Value> {
    match v {
        Value::Array(a) => a.iter().collect(),
        Value::Null => Vec::new(),
        x => vec![x],
    }
}

/// `$x -eq $true` pour une valeur seule : un texte est comparé à « True » (sans les majuscules), un nombre à 1.
fn egal_vrai(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::String(s) => s.eq_ignore_ascii_case("true"),
        Value::Number(n) => n.as_f64() == Some(1.0),
        _ => false,
    }
}

/// `if ($x -eq $true)` : sur un tableau, `-eq` garde les éléments égaux (puis le tableau est vrai ou faux).
fn si_egal_vrai(v: &Value) -> bool {
    match v {
        Value::Array(a) => vrai_ps(&Value::Array(a.iter().filter(|x| egal_vrai(x)).cloned().collect())),
        x => egal_vrai(x),
    }
}

/// `if ($x -ne $true)`.
fn si_different_de_vrai(v: &Value) -> bool {
    match v {
        Value::Array(a) => vrai_ps(&Value::Array(a.iter().filter(|x| !egal_vrai(x)).cloned().collect())),
        x => !egal_vrai(x),
    }
}

/// `-eq` entre deux textes (sans les majuscules).
fn egal_texte(a: &str, b: &str) -> bool {
    a == b || a.to_lowercase() == b.to_lowercase()
}

// ---------------------------------------------------------------------------------------------------------------
// Les fonctions de paquets.ps1
// ---------------------------------------------------------------------------------------------------------------

/// `ConvertFrom-Release` : une version publiée (réponse de l'API) : son numéro, son zip (le premier des noms donnés
/// qu'elle contient), sa signature.
pub fn convertir_release(r: &Value, zips: &[&str]) -> Reponse {
    let fichiers = elements(champ(r, "assets"));
    let nom_de = |a: &Value| texte_ps(champ(a, "name"));
    let Some(nom) = zips.iter().find(|n| fichiers.iter().any(|a| egal_texte(&nom_de(a), n))) else {
        return Err(format!("La dernière version publiée ne contient pas {}.", zips.first().unwrap_or(&"")));
    };
    let z = fichiers.iter().find(|a| egal_texte(&nom_de(a), nom));
    let sig = format!("{nom}.sig");
    let s = fichiers.iter().find(|a| egal_texte(&nom_de(a), &sig));
    let tag = texte_ps(champ(r, "tag_name"));
    let version = tag.strip_prefix(['v', 'V']).unwrap_or(&tag).to_string();
    Ok(Publication {
        version,
        fichier: nom.to_string(),
        url_zip: z.map(|a| texte_ps(champ(a, "browser_download_url"))).unwrap_or_default(),
        url_sig: s.map(|a| texte_ps(champ(a, "browser_download_url"))),
        notes: texte_ps(champ(r, "body")),
        essai: false,
    })
}

fn expr(motif: &str) -> Regex {
    Regex::new(motif).unwrap_or_else(|e| panic!("expression {motif} : {e}"))
}

/// `Get-Preversion` : la préversion la plus récente (canal d'essai), ou `None` : seulement une préversion publiée (ni
/// brouillon, ni version normale), dont le nom est un numéro de version, et qui contient le zip de l'appli. L'API
/// refuse : le flux `releases.atom` ([`preversion_sans_api`]).
pub fn preversion(reseau: &dyn Reseau, depot: &str, zips: &[&str]) -> Option<Publication> {
    let liste = match api(reseau, &format!("https://api.github.com/repos/{depot}/releases?per_page=30")) {
        Ok(l) => l,
        Err(_) => return preversion_sans_api(reseau, depot, zips),
    };
    // (.NET : « $ » accepte aussi un retour à la ligne final ; le numéro tel qu'il est écrit, sans le « v »)
    let numero = expr(r"(?i)^v?([0-9]+(\.[0-9]+){1,3})\n?\z");
    let mut meilleure: Option<(Publication, VersionNet)> = None;
    // (@($liste | ForEach-Object { $_ }) : un tableau dans le tableau est déplié)
    let versions: Vec<&Value> = elements(&liste)
        .into_iter()
        .flat_map(|r| if let Value::Array(a) = r { a.iter().collect() } else { vec![r] })
        .collect();
    for r in versions {
        if si_different_de_vrai(champ(r, "prerelease")) || si_egal_vrai(champ(r, "draft")) {
            continue;
        }
        let tag = texte_ps(champ(r, "tag_name"));
        let Some(c) = numero.captures(&tag) else { continue };
        let Some(v) = VersionNet::lire(&c[1]) else { continue };
        if meilleure.as_ref().is_some_and(|(_, m)| v <= *m) {
            continue;
        }
        let Ok(p) = convertir_release(r, zips) else { continue };
        meilleure = Some((p, v));
    }
    meilleure.map(|(p, _)| Publication { essai: true, ..p })
}

/// `Get-PreversionSansApi` : la plus haute version du flux `releases.atom` (préversions comprises, jamais les
/// brouillons) dont le zip est publié ; 3 versions regardées au plus.
pub fn preversion_sans_api(reseau: &dyn Reseau, depot: &str, zips: &[&str]) -> Option<Publication> {
    let atom = page(reseau, &format!("https://github.com/{depot}/releases.atom")).ok()?;
    let motif = expr(r#"/releases/tag/v([0-9]+(?:\.[0-9]+){1,3})""#);
    let mut vues: Vec<String> = Vec::new();
    for c in motif.captures_iter(&atom) {
        if !vues.iter().any(|v| v == &c[1]) {
            vues.push(c[1].to_string());
        }
    }
    // (triées comme des versions ; une illisible fait tout échouer, comme le « catch » de la version PowerShell)
    let mut versions: Vec<(VersionNet, String)> =
        vues.into_iter().map(|t| VersionNet::lire(&t).map(|v| (v, t))).collect::<Option<_>>()?;
    versions.sort_by_key(|x| std::cmp::Reverse(x.0));
    for (_, version) in versions.into_iter().take(3) {
        let base = format!("https://github.com/{depot}/releases/download/v{version}");
        let publies: Vec<&&str> = zips.iter().filter(|z| fichier_publie(reseau, &format!("{base}/{z}"))).collect();
        let Some(nom) = publies.first() else { continue };
        let sig = fichier_publie(reseau, &format!("{base}/{nom}.sig")).then(|| format!("{base}/{nom}.sig"));
        return Some(Publication {
            notes: notes_page(reseau, depot, &version),
            url_zip: format!("{base}/{nom}"),
            url_sig: sig,
            fichier: nom.to_string(),
            version,
            essai: true,
        });
    }
    None
}

/// `Get-PublicationSansApi` : `https://github.com/<dépôt>/releases/latest` renvoie vers `/releases/tag/v<version>`
/// (sans limite de questions), et les fichiers d'une version sont à `/releases/download/v<version>/<fichier>`.
pub fn publication_sans_api(reseau: &dyn Reseau, depot: &str, zips: &[&str]) -> Option<Publication> {
    let adresse = format!("https://github.com/{depot}/releases/latest");
    let r = reseau.demander(&demande(&adresse, Methode::Head, false, DELAI_QUESTION), None).ok()?;
    if r.statut >= 400 {
        return None;
    }
    let vers = r.entete("Location").unwrap_or("");
    let c = expr(r"(?i)/releases/tag/v?([0-9]+(\.[0-9]+){1,3})\n?\z").captures(vers)?;
    let version = c[1].to_string();
    let base = format!("https://github.com/{depot}/releases/download/v{version}");
    // Plusieurs noms possibles : le premier publié dans cette version (sinon le premier, comme avec un seul nom)
    let premier = zips.first().copied().unwrap_or("");
    let nom = if zips.len() > 1 {
        let publies: Vec<&&str> = zips.iter().filter(|z| fichier_publie(reseau, &format!("{base}/{z}"))).collect();
        publies.first().map(|n| **n).unwrap_or(premier)
    } else {
        premier
    };
    let sig = fichier_publie(reseau, &format!("{base}/{nom}.sig")).then(|| format!("{base}/{nom}.sig"));
    Some(Publication {
        notes: notes_page(reseau, depot, &version),
        url_zip: format!("{base}/{nom}"),
        url_sig: sig,
        fichier: nom.to_string(),
        version,
        essai: false,
    })
}

/// `Test-FichierPublie` : un fichier d'une version publiée existe-t-il ? (200, ou une redirection 301/302 vers le
/// fichier ; sans suivre les redirections)
pub fn fichier_publie(reseau: &dyn Reseau, adresse: &str) -> bool {
    match reseau.demander(&demande(adresse, Methode::Head, false, DELAI_QUESTION), None) {
        Ok(r) => matches!(r.statut, 200 | 301 | 302),
        Err(_) => false,
    }
}

/// La longueur d'un texte comptée comme .NET (en unités UTF-16).
fn longueur_net(t: &str) -> usize {
    t.chars().map(char::len_utf16).sum()
}

/// `$t.Substring(0, n)` en unités UTF-16 (une moitié de caractère au bout n'est pas gardée : DIVERGENCES.md).
fn debut_net(t: &str, n: usize) -> &str {
    let mut u = 0;
    for (i, c) in t.char_indices() {
        if u + c.len_utf16() > n {
            return &t[..i];
        }
        u += c.len_utf16();
    }
    t
}

/// Les notes lues dans le texte d'une page de version (le bloc `markdown-body`), comme `Get-NotesPage`.
pub fn notes_html(html: &str) -> String {
    let bloc = expr(r#"(?is)<div[^>]*class="markdown-body[^"]*"[^>]*>(.*?)</div>"#);
    let Some(c) = bloc.captures(html) else { return String::new() };
    let t = expr(r"(?i)<br\s*/?>|</p>|</li>|</h\d>").replace_all(&c[1], regex::NoExpand("\n"));
    let t = expr(r"(?i)<li[^>]*>").replace_all(&t, regex::NoExpand("- "));
    let t = expr(r"<[^>]+>").replace_all(&t, regex::NoExpand(""));
    let t = html::decoder(&t);
    let t = expr(r"[ \t]+\r?\n").replace_all(&t, regex::NoExpand("\n"));
    let t = expr(r"(\r?\n){3,}").replace_all(&t, regex::NoExpand("\n\n"));
    t.trim().to_string()
}

/// `Get-NotesPage` : les notes d'une version lues sur sa page GitHub (quand l'API refuse) ; introuvables : le lien vers
/// la page. 4000 caractères au plus.
pub fn notes_page(reseau: &dyn Reseau, depot: &str, version: &str) -> String {
    let adresse = format!("https://github.com/{depot}/releases/tag/v{version}");
    let mut notes = page(reseau, &adresse).map(|h| notes_html(&h)).unwrap_or_default();
    if longueur_net(&notes) > 4000 {
        notes = format!("{}...", debut_net(&notes, 4000));
    }
    if notes.is_empty() {
        notes = format!("Les nouveautés de cette version : {adresse}");
    }
    notes
}

/// `Get-Publication` : la dernière version publiée d'une appli. `zips` : le nom de son zip, puis l'ancien (les noms
/// vides sont ignorés). `essai` : le canal d'essai de l'appli (les préversions comptent aussi). Jamais d'erreur levée :
/// l'erreur est dans la réponse, comme `@{ Erreur = ... }`.
pub fn publication(reseau: &dyn Reseau, depot: &str, zips: &[String], essai: bool) -> Reponse {
    let zips: Vec<&str> = zips.iter().map(String::as_str).filter(|z| !z.is_empty()).collect();
    let normale = match api(reseau, &format!("https://api.github.com/repos/{depot}/releases/latest")) {
        Ok(r) => convertir_release(&r, &zips),
        // L'API de GitHub limite les questions (60 par heure et par connexion) : on passe alors par la page des versions
        Err(e) => match publication_sans_api(reseau, depot, &zips) {
            Some(p) => Ok(p),
            None => Err(format!("Impossible de joindre GitHub ({e}).")),
        },
    };
    if !essai {
        return normale;
    }
    if let Some(pre) = preversion(reseau, depot, &zips) {
        let plus_recente = match &normale {
            Err(_) => true,
            Ok(n) => version_net::plus_recente(&pre.version, &n.version),
        };
        if plus_recente {
            return Ok(pre);
        }
    }
    normale
}

// ---------------------------------------------------------------------------------------------------------------
// Les formes JSON d'une publication
// ---------------------------------------------------------------------------------------------------------------

/// La forme du tableau commun (`publications`, partage.rs) : `{ version, fichier, url_zip, url_sig, notes, essai }`
/// ou `{ erreur }`.
pub fn en_partage(r: &Reponse) -> Value {
    match r {
        Ok(p) => json!({ "version": p.version, "fichier": p.fichier, "url_zip": p.url_zip, "url_sig": p.url_sig,
            "notes": p.notes, "essai": p.essai }),
        Err(e) => json!({ "erreur": e }),
    }
}

/// Relit la forme du tableau commun ; `None` si ce n'en est pas une.
pub fn depuis_partage(v: &Value) -> Option<Reponse> {
    let o = v.as_object()?;
    if let Some(e) = o.get("erreur") {
        return Some(Err(e.as_str()?.to_string()));
    }
    let t = |n: &str| o.get(n).and_then(Value::as_str).map(str::to_string);
    Some(Ok(Publication {
        version: t("version")?,
        fichier: t("fichier").unwrap_or_default(),
        url_zip: t("url_zip").unwrap_or_default(),
        url_sig: t("url_sig"),
        notes: t("notes").unwrap_or_default(),
        essai: o.get("essai").and_then(Value::as_bool).unwrap_or(false),
    }))
}

/// La forme de la version PowerShell (`@{ Version; Fichier; UrlZip; UrlSig; Notes; Essai }` ou `@{ Erreur }`), pour
/// comparer aux juges.
pub fn en_ps(r: &Reponse) -> Value {
    let mut m = Map::new();
    match r {
        Ok(p) => {
            if p.essai {
                m.insert("Essai".into(), Value::Bool(true));
            }
            m.insert("Fichier".into(), json!(p.fichier));
            m.insert("Notes".into(), json!(p.notes));
            m.insert("UrlSig".into(), json!(p.url_sig));
            m.insert("UrlZip".into(), json!(p.url_zip));
            m.insert("Version".into(), json!(p.version));
        }
        Err(e) => {
            m.insert("Erreur".into(), json!(e));
        }
    }
    Value::Object(m)
}

/// Relit la forme de la version PowerShell (un résultat de travail de fond dans les juges).
pub fn depuis_ps(v: &Value) -> Reponse {
    if let Some(e) = v.get("Erreur").filter(|e| !e.is_null()) {
        return Err(texte_ps(e));
    }
    let t = |n: &str| v.get(n).map(texte_ps).unwrap_or_default();
    Ok(Publication {
        version: t("Version"),
        fichier: t("Fichier"),
        url_zip: t("UrlZip"),
        url_sig: v.get("UrlSig").filter(|s| !s.is_null()).map(texte_ps),
        notes: t("Notes"),
        essai: v.get("Essai").is_some_and(vrai_ps),
    })
}

/// Une mise à jour est-elle proposée ? Seulement une version publiée (sans erreur) strictement plus récente que celle
/// installée : jamais une version plus ancienne, même d'essai (Update-ListeVersions, Get-EtatCarte : `Test-VersionPlusRecente`).
pub fn maj_disponible(publication: &Value, version_installee: &str) -> bool {
    match depuis_partage(publication) {
        Some(Ok(p)) => version_net::plus_recente(&p.version, version_installee),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formes() {
        let p = Publication { version: "1.2.0".into(), fichier: "A.zip".into(), essai: true, ..Default::default() };
        assert_eq!(depuis_partage(&en_partage(&Ok(p.clone()))), Some(Ok(p.clone())));
        assert_eq!(depuis_ps(&en_ps(&Ok(p.clone()))), Ok(p));
        assert_eq!(depuis_partage(&en_partage(&Err("x".into()))), Some(Err("x".into())));
        assert!(maj_disponible(&json!({ "version": "1.3.0" }), "1.2.9"));
        assert!(!maj_disponible(&json!({ "version": "0.15.3" }), "0.90.1"), "jamais une version plus ancienne");
        assert!(!maj_disponible(&json!({ "erreur": "GitHub injoignable" }), "0.1"));
    }

    #[test]
    fn longueur_comme_dotnet() {
        assert_eq!(longueur_net("é🚀"), 3);
        assert_eq!(debut_net("é🚀x", 2), "é");
        assert_eq!(debut_net("é🚀x", 3), "é🚀");
    }
}
