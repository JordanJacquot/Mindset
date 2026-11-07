//! La liste des applis de la suite (modules\liste.ps1 et `Get-Applis` de modules\applis.ps1), à l'identique : celle
//! livrée avec Mindset (`fichiers\apps.json`, son numéro dans `fichiers\apps-liste.txt`) ou celle publiée en ligne
//! (`apps-en-ligne.json` et sa signature `apps-en-ligne.json.sig`, gardées dans le dossier des données de Mindset).
//!
//! Une liste en ligne n'est prise que si TOUT est bon, sinon on garde ce qu'on avait (jamais à moitié) :
//! 1. 256 Ko au plus, signée par une des clés livrées (`fichiers\cles-publiques`, comme les zips) ;
//! 2. un objet JSON : « liste » (un entier, 1 ou plus), « mindset_min » (une version x.y.z), « applis » (un tableau
//!    non vide) ; les noms des champs comptent avec leur casse ;
//! 3. « mindset_min » pas plus récent que ce Mindset (sinon : une liste pour un Mindset plus récent, ignorée) ;
//! 4. « liste » plus grand que le numéro livré, et que celui de la liste déjà gardée : une ancienne liste signée ne
//!    revient jamais (pas de retour en arrière) ;
//! 5. chaque entrée passe les contrôles de `ConvertTo-Appli` ([`convertir`]), les mêmes que pour apps.json : une
//!    entrée refusée est ignorée (le reste est pris), comme un id déjà vu plus haut ; il doit en rester au moins une.
//!
//! La liste gardée est modifiable sans droits : à chaque lecture, tout est revérifié sur les octets lus une seule fois.
//!
//! Les messages (erreurs et journal) sont ceux de la version PowerShell, mot pour mot. Les règles de
//! `suite_commun::liste_en_ligne` (installateur et désinstalleur) sont plus simples (contrôle d'une entrée réduit à
//! id, nom et exe) : ce bloc garde celles de Mindset, avec `ConvertTo-Appli` en entier, et prend à `suite_commun` la
//! signature, les versions, la lecture du JSON « à la PowerShell » et les noms des fichiers.

use std::path::{Path, PathBuf};

use serde_json::Value;

use mindset_noyau::appli::Appli;
use suite_commun::liste_en_ligne::{FICHIER, FICHIER_NUMERO, TAILLE_MAX, TAILLE_MAX_SIGNATURE, chemin_signature};
use suite_commun::version::Version;

pub use crate::ps::JsonAbime;
use crate::ps::{
    champ, correspond, correspond_ps, deroule, developper_variables, mot, ne_correspond_pas_ps, nombre_dotnet, texte,
    vaut_vrai, vrai_ps,
};

/// Le nom de la liste gardée, dans le dossier des données de Mindset (`$NomListeEnLigne`).
pub const NOM_LISTE_EN_LIGNE: &str = FICHIER;

/// Ce qui note au journal (`Write-Log`, ou `Write-JournalListe`).
pub type Journal<'a> = &'a mut dyn FnMut(&str);

/// Les variables d'environnement (`%LOCALAPPDATA%`...) pour le dossier de données d'une appli.
pub type Variables<'a> = &'a dyn Fn(&str) -> Option<String>;

// ---------------------------------------------------------------------------------------------------------------
// ConvertTo-Appli
// ---------------------------------------------------------------------------------------------------------------

const INTERDITS: [char; 9] = ['\\', '/', ':', '*', '?', '"', '<', '>', '|'];

/// `^[^\\/:*?"<>|]+$` : un nom de fichier seul.
fn nom_fichier(t: &str) -> bool {
    !t.is_empty() && !t.contains(INTERDITS)
}

/// `^[^\\/:*?"<>|]+\.exe$` (sans tenir compte des majuscules) : un nom de programme seul.
fn nom_programme(t: &str) -> bool {
    finit_sans_casse(t, ".exe").is_some_and(nom_fichier)
}

/// `t` finit par `fin` (ASCII, sans tenir compte des majuscules) : ce qui est avant.
fn finit_sans_casse<'a>(t: &'a str, fin: &str) -> Option<&'a str> {
    let i = t.len().checked_sub(fin.len())?;
    (t.is_char_boundary(i) && t[i..].eq_ignore_ascii_case(fin)).then(|| &t[..i])
}

/// `^[\w\\.-]+\.ps1$` (sans tenir compte des majuscules) : un script, avec un dossier permis.
fn nom_script(t: &str) -> bool {
    finit_sans_casse(t, ".ps1")
        .is_some_and(|d| !d.is_empty() && d.chars().all(|c| mot(c) || matches!(c, '\\' | '.' | '-')))
}

/// `[\w.-]+`
fn mots(t: &str) -> bool {
    !t.is_empty() && t.chars().all(|c| mot(c) || matches!(c, '.' | '-'))
}

/// `^Local\\[\w.-]+$` (sans tenir compte des majuscules) : un verrou ou un signal de la session.
fn nom_local(t: &str) -> bool {
    t.get(..6).is_some_and(|d| d.eq_ignore_ascii_case("local\\")) && mots(&t[6..])
}

/// `^\d+(\.\d+){1,3}$` : une version de 2 à 4 nombres.
fn forme_version(t: &str) -> bool {
    suite_commun::version::forme_valide(t)
}

/// `^[a-z0-9-]+$` (sans tenir compte des majuscules) : l'id d'une appli.
fn forme_id(t: &str) -> bool {
    !t.is_empty() && t.bytes().all(|o| o.is_ascii_alphanumeric() || o == b'-')
}

/// `^#[0-9A-Fa-f]{6}$`
fn forme_couleur(t: &str) -> bool {
    t.len() == 7 && t.starts_with('#') && t[1..].bytes().all(|o| o.is_ascii_hexdigit())
}

/// `^[\w.-]+/[\w.-]+$` (sans tenir compte des majuscules) : « propriétaire/dépôt ».
fn forme_depot(t: &str) -> bool {
    t.split_once('/').is_some_and(|(a, b)| mots(a) && mots(b))
}

/// `-cmatch '^[A-Za-z0-9 ]{1,40} \(aide\)$'` : le nom de la tâche de l'Aide.
fn forme_aide(t: &str) -> bool {
    t.strip_suffix(" (aide)")
        .is_some_and(|d| (1..=40).contains(&d.len()) && d.bytes().all(|o| o.is_ascii_alphanumeric() || o == b' '))
}

/// `^[ML0-9., ]{3,240}$` et `^M` (sans tenir compte des majuscules) : un tracé de logo.
fn forme_logo(t: &str) -> bool {
    let n = t.chars().count();
    (3..=240).contains(&n)
        && t.starts_with(['M', 'm'])
        && t.chars().all(|c| matches!(c, 'M' | 'm' | 'L' | 'l' | '0'..='9' | '.' | ',' | ' '))
}

/// `-cmatch '^https://github\.com/JordanJacquot/[\w.-]+/blob/main/[\w.-]+\.md$'` : une page du compte de la suite.
fn forme_confidentialite(t: &str) -> bool {
    let Some(reste) = t.strip_prefix("https://github.com/JordanJacquot/") else { return false };
    let Some((depot, page)) = reste.split_once("/blob/main/") else { return false };
    mots(depot) && page.strip_suffix(".md").is_some_and(mots)
}

/// `ConvertTo-Appli` (liste.ps1:33-103) : une entrée de la liste (apps.json ou liste en ligne), vérifiée champ par
/// champ ; l'appli telle que Mindset s'en sert, ou `None` si elle est refusée (noté au journal). On n'y lit que des
/// champs connus, et aucun texte qui en vient n'est exécuté comme une commande. `origine` : le nom de la liste, pour
/// le journal ; `variables` : les variables d'environnement (`%LOCALAPPDATA%`) du dossier de données.
pub fn convertir(a: &Value, origine: &str, journal: Journal, variables: Variables) -> Option<Appli> {
    let id = match (a, champ(a, "id"), champ(a, "couleur")) {
        (Value::Object(_), Value::String(id), Value::String(_)) => id.clone(),
        _ => {
            journal(&format!("{origine} : entrée mal formée ignorée"));
            return None;
        }
    };
    // Son type (docs\contrat-appli.md, partie 1) : « powershell » (champ absent : les applis d'aujourd'hui) a un
    // script principal ; « rust » n'en a pas forcément. Tout autre type : ignorée.
    let genre = match deroule(champ(a, "type")) {
        Value::Null if champ(a, "type").is_null() => "powershell".to_string(),
        Value::String(t) if correspond(&t, &|t| t == "powershell" || t == "rust") => t,
        _ => {
            journal(&format!("{origine} : appli ignorée ({id}, type inconnu)"));
            return None;
        }
    };
    let m = |nom: &str, motif: &dyn Fn(&str) -> bool| correspond_ps(champ(a, nom), motif);
    let present = |nom: &str| vrai_ps(champ(a, nom));
    let mut ok = correspond(&id, &forme_id)
        && present("nom")
        && m("couleur", &forme_couleur)
        && m("depot", &forme_depot)
        && m("zip", &nom_fichier)
        && m("dossier_zip", &nom_fichier)
        && m("exe", &nom_programme);
    let script_sans_points = |nom: &str| ne_correspond_pas_ps(champ(a, nom), &|t| t.contains(".."));
    if genre.eq_ignore_ascii_case("powershell") || present("script") {
        ok = ok && m("script", &nom_script) && script_sans_points("script");
    }
    // Les noms de son verrou et de son signal d'affichage, et la version de « cache_depuis »
    for (nom, motif) in [
        ("mutex", &nom_local as &dyn Fn(&str) -> bool),
        ("afficher_signal", &nom_local),
        ("cache_depuis", &forme_version),
        ("desinstalleur", &nom_programme),
        ("afficher_fichier", &nom_fichier),
    ] {
        if present(nom) {
            ok = ok && m(nom, motif);
        }
    }
    if present("aide") {
        ok = ok && m("aide", &forme_aide) && m("aide_exe", &nom_programme);
    }
    if present("sans_droits_depuis") {
        ok = ok && m("sans_droits_depuis", &forme_version);
    }
    // Ses anciens noms (Nevermind s'appelait OptiGame), vérifiés comme les nouveaux
    if present("ancien_zip") {
        ok = ok && m("ancien_zip", &nom_fichier);
    }
    if present("ancien_dossier_zip") {
        ok = ok && m("ancien_dossier_zip", &nom_fichier);
    }
    if present("ancien_script") {
        ok = ok && m("ancien_script", &nom_script) && script_sans_points("ancien_script");
    }
    if present("ancien_mutex") {
        ok = ok && m("ancien_mutex", &nom_local);
    }
    if !ok {
        journal(&format!("{origine} : appli ignorée ({id})"));
        return None;
    }
    // Son logo (un tracé de traits droits sur une grille de 100) : mal formé, ignoré (la lettre reste)
    let logo_brut = texte(champ(a, "logo"));
    let logo = if correspond(&logo_brut, &forme_logo) { logo_brut } else { String::new() };
    if present("logo") && logo.is_empty() {
        journal(&format!("{origine} : logo de {id} ignoré (tracé non compris)"));
    }
    // Sa page de confidentialité : seulement une page du compte GitHub de la suite
    let page = texte(champ(a, "confidentialite"));
    let confidentialite = if correspond(&page, &forme_confidentialite) { page } else { String::new() };
    if present("confidentialite") && confidentialite.is_empty() {
        journal(&format!("{origine} : page de confidentialité de {id} ignorée (adresse non acceptée)"));
    }
    let epaisseur =
        nombre_dotnet(&texte(champ(a, "logo_epaisseur"))).filter(|e| (4.0..=25.0).contains(e)).unwrap_or(12.0);
    let t = |nom: &str| texte(champ(a, nom));
    let nom = t("nom");
    Some(Appli {
        app_id: format!("JordanJacquot.{}", nom.chars().filter(char::is_ascii_alphanumeric).collect::<String>()),
        id,
        genre,
        nom,
        couleur: t("couleur"),
        description: t("description"),
        presentation: t("presentation"),
        depot: t("depot"),
        zip: t("zip"),
        dossier_zip: t("dossier_zip"),
        exe: t("exe"),
        script: t("script"),
        mutex: t("mutex"),
        ancien_zip: t("ancien_zip"),
        ancien_dossier_zip: t("ancien_dossier_zip"),
        ancien_script: t("ancien_script"),
        ancien_mutex: t("ancien_mutex"),
        afficher_fichier: t("afficher_fichier"),
        afficher_signal: t("afficher_signal"),
        desinstalleur: t("desinstalleur"),
        donnees: developper_variables(&t("donnees"), variables),
        admin: vrai_ps(champ(a, "admin")),
        rappels: vaut_vrai(champ(a, "rappels")),
        sans_droits_depuis: t("sans_droits_depuis"),
        aide: t("aide"),
        aide_exe: t("aide_exe"),
        cache_depuis: t("cache_depuis"),
        confidentialite,
        logo,
        logo_epaisseur: epaisseur / 100.0,
    })
}

/// Un texte JSON lu comme `ConvertFrom-Json` de Windows PowerShell 5.1 : `Ok(None)` pour un texte vide ou fait
/// d'espaces, `Err` pour un JSON abîmé (pour lire une entrée comme dans une liste).
pub fn json_powershell(texte: &str) -> Result<Option<Value>, JsonAbime> {
    crate::ps::depuis_json(texte)
}

// ---------------------------------------------------------------------------------------------------------------
// La liste livrée, la liste en ligne, la liste gardée
// ---------------------------------------------------------------------------------------------------------------

/// `Get-NumeroListeLivree` : le numéro de la liste livrée (`fichiers\apps-liste.txt`) : un entier de 1 à 9 chiffres,
/// ou -1 s'il est absent ou illisible (aucune liste en ligne n'est alors prise).
pub fn numero_livre(fichiers: &Path) -> i64 {
    let Ok(octets) = std::fs::read(fichiers.join(FICHIER_NUMERO)) else { return -1 };
    let t = suite_commun::json_sur::texte_du_fichier(&octets);
    let t = t.trim();
    if (1..=9).contains(&t.len()) && t.bytes().all(|o| o.is_ascii_digit()) { t.parse().unwrap_or(-1) } else { -1 }
}

/// Une liste en ligne acceptée (`@{ Numero ; MindsetMin ; Entrees }`) : ses entrées telles qu'écrites dans la liste.
#[derive(Debug, Clone, PartialEq)]
pub struct ListeLue {
    pub numero: i64,
    pub mindset_min: String,
    pub entrees: Vec<Value>,
}

const TROP_GROSSE: &str = "liste vide ou trop grosse (plus de 256 Ko)";
const NUMERO_ILLISIBLE: &str = "numéro de la liste livrée (apps-liste.txt) illisible";

/// `Read-ListeEnLigne` : une liste en ligne (ses octets et ceux de sa signature) vérifiée selon les règles 1 à 5, avec
/// les clés de `fichiers\cles-publiques`. `numero_min` : le numéro qu'elle doit dépasser. L'erreur dit pourquoi elle
/// est refusée (le texte de la version PowerShell).
pub fn lire_en_ligne(
    json: &[u8],
    signature: &[u8],
    fichiers: &Path,
    version_mindset: &str,
    numero_min: i64,
    journal: Journal,
) -> Result<ListeLue, String> {
    // 1. Taille et signature
    if json.is_empty() || json.len() as u64 > TAILLE_MAX {
        return Err(TROP_GROSSE.into());
    }
    if !suite_commun::signature::verifier_signature(json, signature, &fichiers.join("cles-publiques")) {
        return Err("signature invalide".into());
    }
    // 2. Sa forme (UTF-8 strict, marque d'encodage permise)
    let o = json.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(json);
    let abime = || "liste illisible (JSON abîmé)".to_string();
    let texte = std::str::from_utf8(o).map_err(|_| abime())?;
    let Some(Value::Object(j)) = crate::ps::depuis_json(texte).map_err(|_| abime())? else {
        return Err("liste illisible (pas un objet JSON)".into());
    };
    for n in ["liste", "mindset_min", "applis"] {
        if !j.contains_key(n) {
            return Err(format!("liste illisible (champ « {n} » absent)"));
        }
    }
    let Some(numero) = j["liste"].as_i64().filter(|n| *n >= 1) else {
        return Err("liste illisible (« liste » doit être un entier, 1 ou plus)".into());
    };
    let min = match &j["mindset_min"] {
        Value::String(m) if version_xyz(m) => m.clone(),
        _ => return Err("liste illisible (« mindset_min » doit être une version x.y.z)".into()),
    };
    let applis = match &j["applis"] {
        Value::Array(a) if !a.is_empty() => a,
        _ => return Err("liste illisible (« applis » doit être un tableau non vide)".into()),
    };
    // 3. Pour ce Mindset
    let Some(ce) = Version::lire(version_mindset) else { return Err("version de ce Mindset inconnue".into()) };
    if Version::lire(&min).is_some_and(|m| m > ce) {
        return Err(format!("liste pour un Mindset plus récent ({min} ou plus, celui-ci est en {version_mindset})"));
    }
    // 4. Plus récente que ce qu'on a
    if numero <= numero_min {
        return Err(format!("liste n° {numero} trop ancienne (il faut un numéro plus grand que {numero_min})"));
    }
    // 5. Chaque entrée, avec les mêmes contrôles que apps.json ; un id déjà vu plus haut est ignoré
    let mut vus: Vec<String> = Vec::new();
    let mut entrees = Vec::new();
    for e in applis {
        let Some(a) = convertir(e, "liste en ligne", journal, &crate::ps::variable_du_pc) else { continue };
        if vus.contains(&a.id) {
            journal(&format!("liste en ligne : appli ignorée ({}, déjà dans la liste)", a.id));
            continue;
        }
        vus.push(a.id);
        entrees.push(e.clone());
    }
    if entrees.is_empty() {
        return Err("aucune appli valable dans la liste".into());
    }
    Ok(ListeLue { numero, mindset_min: min, entrees })
}

/// `^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}\z` (sans « \n » permis à la fin).
fn version_xyz(v: &str) -> bool {
    let m: Vec<&str> = v.split('.').collect();
    m.len() == 3 && m.iter().all(|x| (1..=9).contains(&x.len()) && x.bytes().all(|o| o.is_ascii_digit()))
}

/// La taille d'un fichier, 0 s'il est absent (comme `(New-Object IO.FileInfo $f).Length` dans un `if`).
fn taille(f: &Path) -> u64 {
    std::fs::metadata(f).map(|m| m.len()).unwrap_or(0)
}

/// `Read-ListeGardee` : la liste gardée (`fichier`, sa signature à côté), lue une seule fois puis vérifiée (règles 1
/// à 5, numéro plus grand que celui de la liste livrée). `Ok(None)` s'il n'y en a pas.
pub fn lire_gardee(
    fichier: Option<&Path>,
    fichiers: &Path,
    version_mindset: &str,
    journal: Journal,
) -> Result<Option<ListeLue>, String> {
    let Some(fichier) = fichier.filter(|f| f.is_file()) else { return Ok(None) };
    let livree = numero_livre(fichiers);
    if livree < 0 {
        return Err(NUMERO_ILLISIBLE.into());
    }
    // (sa taille regardée avant de la lire : un fichier énorme n'est jamais chargé en mémoire)
    let sig = chemin_signature(fichier);
    if taille(fichier) > TAILLE_MAX || taille(&sig) > TAILLE_MAX_SIGNATURE {
        return Err(TROP_GROSSE.into());
    }
    let (Ok(json), Ok(signature)) = (std::fs::read(fichier), std::fs::read(&sig)) else {
        return Err("liste ou signature illisible sur le disque".into());
    };
    lire_en_ligne(&json, &signature, fichiers, version_mindset, livree, journal).map(Some)
}

/// D'où vient la liste des applis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// `fichiers\apps.json`, livré avec Mindset (« livree »)
    Livree,
    /// La liste en ligne gardée (« en-ligne »)
    EnLigne,
}

/// Les entrées à utiliser (`@{ Source ; Numero ; Entrees }`).
#[derive(Debug, Clone, PartialEq)]
pub struct Entrees {
    pub source: Source,
    pub numero: i64,
    pub entrees: Vec<Value>,
}

/// `Get-EntreesApplis` : la liste gardée si elle est bonne, sinon apps.json livré. apps.json illisible : une erreur.
pub fn entrees(
    fichiers: &Path,
    gardee: Option<&Path>,
    version_mindset: &str,
    journal: Journal,
) -> Result<Entrees, String> {
    if gardee.is_some() {
        match lire_gardee(gardee, fichiers, version_mindset, journal) {
            Ok(Some(l)) => return Ok(Entrees { source: Source::EnLigne, numero: l.numero, entrees: l.entrees }),
            Ok(None) => {}
            Err(e) => journal(&format!("Liste des applis gardée refusée ({e}) : celle livrée avec Mindset est prise")),
        }
    }
    let chemin = fichiers.join("apps.json");
    let octets = std::fs::read(&chemin).map_err(|e| format!("{} : {e}", chemin.display()))?;
    let texte = suite_commun::json_sur::texte_du_fichier(&octets);
    let liste = crate::ps::depuis_json(&texte).map_err(|_| "JSON abîmé".to_string())?;
    // (un tableau : ses entrées ; une seule valeur : une entrée ; rien ou null : aucune)
    let entrees = match liste {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(a)) => a,
        Some(v) => vec![v],
    };
    Ok(Entrees { source: Source::Livree, numero: numero_livre(fichiers), entrees })
}

/// Écrit `octets` à côté de `cible` (`<cible>.tmp`) puis le met à sa place (le fichier d'avant est remplacé).
fn ecrire_puis_renommer(cible: &Path, octets: &[u8]) -> std::io::Result<()> {
    let mut tmp = cible.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, octets)?;
    std::fs::rename(&tmp, cible).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// `Add-ListeEnLigne` : une liste téléchargée, gardée à la place de `gardee` si elle passe les règles 1 à 5, avec un
/// numéro plus grand que celui de la liste livrée ET que celui de la liste déjà gardée (si elle est bonne). Écrite à
/// côté puis renommée, seulement une fois acceptée. `Ok(None)` si c'est la même que celle qu'on a déjà (même numéro :
/// rien à dire), une erreur qui dit pourquoi elle est refusée (rien n'est alors changé sur le disque).
pub fn ajouter_en_ligne(
    json: &[u8],
    signature: &[u8],
    fichiers: &Path,
    gardee: &Path,
    version_mindset: &str,
    journal: Journal,
) -> Result<Option<ListeLue>, String> {
    let mut min = numero_livre(fichiers);
    if min < 0 {
        return Err(NUMERO_ILLISIBLE.into());
    }
    if let Ok(Some(g)) = lire_gardee(Some(gardee), fichiers, version_mindset, journal) {
        min = min.max(g.numero);
    }
    // (vérifiée en entier même quand elle porte le numéro qu'on a déjà, puis laissée de côté)
    let l = lire_en_ligne(json, signature, fichiers, version_mindset, min - 1, journal)?;
    if l.numero == min {
        return Ok(None);
    }
    if let Some(d) = gardee.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    // (la signature d'abord, puis la liste : interrompu entre les deux, la signature ne va plus avec la liste, qui
    // est alors refusée à la lecture : la liste livrée est prise, et le prochain téléchargement remet tout en ordre)
    ecrire_puis_renommer(&chemin_signature(gardee), signature).map_err(|e| e.to_string())?;
    ecrire_puis_renommer(gardee, json).map_err(|e| e.to_string())?;
    Ok(Some(l))
}

// ---------------------------------------------------------------------------------------------------------------
// Get-Applis
// ---------------------------------------------------------------------------------------------------------------

/// La liste des applis à utiliser (`$Applis`), et d'où elle vient.
#[derive(Debug, Clone, PartialEq)]
pub struct Applis {
    pub applis: Vec<Appli>,
    /// `None` : apps.json illisible (aucune appli)
    pub source: Option<Source>,
    pub numero: i64,
}

/// `Get-Applis` (applis.ps1:14-28) : les entrées de [`entrees`], chacune passée à [`convertir`] ; un id déjà vu plus
/// haut est ignoré (la première entrée compte). apps.json illisible : aucune appli (noté au journal).
pub fn applis(
    fichiers: &Path,
    gardee: Option<&Path>,
    version_mindset: &str,
    journal: Journal,
    variables: Variables,
) -> Applis {
    let l = match entrees(fichiers, gardee, version_mindset, journal) {
        Ok(l) => l,
        Err(e) => {
            journal(&format!("apps.json illisible : {e}"));
            return Applis { applis: Vec::new(), source: None, numero: -1 };
        }
    };
    let origine = match l.source {
        Source::EnLigne => format!("liste en ligne n° {}", l.numero),
        Source::Livree => "apps.json".to_string(),
    };
    if l.source == Source::EnLigne {
        journal(&format!("Liste des applis : {origine} (gardée, vérifiée)"));
    }
    let mut r: Vec<Appli> = Vec::new();
    for e in &l.entrees {
        let Some(a) = convertir(e, &origine, journal, variables) else { continue };
        if r.iter().any(|x| x.id == a.id) {
            journal(&format!("{origine} : appli ignorée ({}, déjà dans la liste)", a.id));
            continue;
        }
        r.push(a);
    }
    Applis { applis: r, source: Some(l.source), numero: l.numero }
}
