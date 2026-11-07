//! Les juges de la version PowerShell (outils\exporter-juges-donnees.ps1 -> tests\juges\donnees.json) rejoués par le
//! bloc Rust : mêmes installations d'essai, mêmes étapes, et la même sortie (dossiers, réponses, TOUS les fichiers du
//! dossier d'essai à la fin, journal compris).
//!
//! Les différences voulues (DIVERGENCES.md) sont listées dans [`ECARTS`], cas par cas, avec ce qu'elles changent.
//! La contre-épreuve vérifie qu'un juge modifié d'un seul caractère fait bien échouer la comparaison.

use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::os::windows::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use mindset_donnees::{DisqueMindset, json_ps};
use mindset_noyau::donnees::{Donnees, Environnement};
use serde_json::{Map, Value};

const JUGES: &str = include_str!("juges/donnees.json");

/// Les différences voulues (DIVERGENCES.md), cas par cas : (début du nom du cas, ce qui est permis).
///
/// - `nombres` : un nombre décimal relu garde sa valeur mais pas son écriture (« 1.50 » devient « 1.5 ») ;
/// - `forme` : la forme du JSON écrit (un nombre décimal « 3.0 » s'écrit « 3 »).
///
/// Et partout, celles de suite_commun::json_sur (voir [`selon_json_sur`]) : une copie `.bak` illisible est mise de
/// côté (`.bak.abime-<date>`, une ligne de plus au journal), et un fichier vide ou abîmé n'est jamais copié dans `.bak`.
const ECARTS: &[(&str, &[&str])] = &[
    ("reglages.json : très grand nombre et nombre décimal", &["nombres"]),
    ("forme JSON de {\"n\":[0,-1,2147483647", &["forme"]),
];

fn ecarts(nom: &str) -> Vec<&'static str> {
    ECARTS.iter().filter(|(d, _)| nom.starts_with(d)).flat_map(|(_, e)| e.iter().copied()).collect()
}

// ---------------------------------------------------------------------------------------------------------------
// Normalisation et comparaison
// ---------------------------------------------------------------------------------------------------------------

/// Remplace les chiffres d'un motif (`9` = un chiffre) par `remplacement`, partout dans le texte.
fn remplacer_motif(t: &str, motif: &str, remplacement: &str) -> String {
    let c: Vec<char> = t.chars().collect();
    let m: Vec<char> = motif.chars().collect();
    let mut r = String::new();
    let mut i = 0;
    while i < c.len() {
        let ok = i + m.len() <= c.len()
            && m.iter().zip(&c[i..]).all(|(a, b)| if *a == '9' { b.is_ascii_digit() } else { a == b });
        if ok {
            r.push_str(remplacement);
            i += m.len();
        } else {
            r.push(c[i]);
            i += 1;
        }
    }
    r
}

/// Un texte comparable : le dossier du cas devient `<T>`, les dates `<date>`, les messages d'erreur de Windows
/// (différents entre .NET et Rust) sont coupés.
fn normaliser(t: &str, cas: &Path) -> String {
    let mut s = t.replace(&cas.display().to_string(), "<T>");
    s = remplacer_motif(&s, "9999-99-99T99:99:99", "<date>");
    s = remplacer_motif(&s, ".abime-99999999-999999", ".abime-<date>");
    s = remplacer_motif(&s, "99/99/9999", "<jour>");
    let lignes: Vec<String> = s
        .split("\r\n")
        .map(|l| match l.find("ne peut pas être lu (") {
            Some(i) => format!("{}ne peut pas être lu (…)", &l[..i]),
            None => l.to_string(),
        })
        .collect();
    lignes.join("\r\n")
}

/// Deux valeurs JSON égales : les objets sans tenir compte de l'ordre, les nombres par leur valeur.
fn egal_json(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(a, b)| egal_json(a, b)),
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| egal_json(v, w)))
        }
        _ => a == b,
    }
}

/// `v` dont les clés suivent l'ordre de `modele` (le fichier de PowerShell), pour comparer la forme du texte.
fn dans_l_ordre(v: &Value, modele: &Value) -> Value {
    match (v, modele) {
        (Value::Object(o), Value::Object(m)) => {
            let mut r = Map::new();
            for (k, mv) in m {
                if let Some(x) = o.get(k) {
                    r.insert(k.clone(), dans_l_ordre(x, mv));
                }
            }
            for (k, x) in o {
                if !r.contains_key(k) {
                    r.insert(k.clone(), x.clone());
                }
            }
            Value::Object(r)
        }
        (Value::Array(a), Value::Array(m)) => Value::Array(
            a.iter().enumerate().map(|(i, x)| m.get(i).map_or(x.clone(), |mv| dans_l_ordre(x, mv))).collect(),
        ),
        _ => v.clone(),
    }
}

fn analyser(t: &str) -> Option<Value> {
    serde_json::from_str(t.trim_start_matches('\u{FEFF}')).ok()
}

/// Le texte JSON d'une réponse de PowerShell (« null » : rien).
fn valeur_ps(v: &Value) -> Value {
    // (un texte qui n'est pas du JSON ne vaut jamais « rien » : il ne peut être égal à aucune valeur)
    match v.as_str() {
        Some(t) => serde_json::from_str(t).unwrap_or_else(|_| Value::String(format!("<pas du JSON : {t}>"))),
        None => Value::String(format!("<pas un texte : {v}>")),
    }
}

fn texte_ou_null(v: Option<&str>) -> Value {
    v.map_or(Value::Null, |t| Value::String(t.to_string()))
}

// ---------------------------------------------------------------------------------------------------------------
// Le dossier d'essai
// ---------------------------------------------------------------------------------------------------------------

fn joindre(t: &Path, rel: &str) -> PathBuf {
    if rel.is_empty() { t.to_path_buf() } else { PathBuf::from(format!("{}\\{rel}", t.display())) }
}

/// Change la date d'un fichier ou d'un dossier (FILE_WRITE_ATTRIBUTES, FILE_FLAG_BACKUP_SEMANTICS).
fn dater(p: &Path, jours: u64) {
    let f = std::fs::OpenOptions::new()
        .access_mode(0x100)
        .custom_flags(0x0200_0000)
        .open(p)
        .unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    f.set_modified(SystemTime::now() - Duration::from_secs(jours * 86_400)).unwrap();
}

/// Tous les fichiers et dossiers sous `t` (chemins relatifs, triés).
fn contenu(t: &Path) -> (BTreeMap<String, String>, Vec<String>) {
    let mut fichiers = BTreeMap::new();
    let mut dossiers = Vec::new();
    let mut a_voir = vec![t.to_path_buf()];
    while let Some(d) = a_voir.pop() {
        for e in std::fs::read_dir(&d).unwrap().flatten() {
            let p = e.path();
            let rel = p.strip_prefix(t).unwrap().display().to_string();
            if p.is_dir() {
                dossiers.push(rel);
                a_voir.push(p);
            } else {
                let o = std::fs::read(&p).unwrap();
                fichiers.insert(rel, String::from_utf8_lossy(&o).into_owned());
            }
        }
    }
    dossiers.sort();
    (fichiers, dossiers)
}

// ---------------------------------------------------------------------------------------------------------------
// Un cas
// ---------------------------------------------------------------------------------------------------------------

fn texte<'a>(v: &'a Value, cle: &str) -> &'a str {
    v.get(cle).and_then(Value::as_str).unwrap_or("")
}

/// Rejoue un cas dans `t` ; rend les différences avec le juge (vide : pareil).
fn rejouer(cas: &Value, t: &Path) -> Vec<String> {
    let nom = texte(cas, "nom").to_string();
    let ec = ecarts(&nom);
    let mut diff = Vec::new();
    let _ = std::fs::remove_dir_all(t);
    std::fs::create_dir_all(t).unwrap();
    let localappdata = joindre(t, texte(cas, "localappdata"));
    let pf = joindre(t, texte(cas, "program_files"));
    let exe = joindre(t, texte(cas, "exe"));
    for d in [&localappdata, &pf, &exe.parent().unwrap().to_path_buf()] {
        std::fs::create_dir_all(d).unwrap();
    }
    let inscrit: Option<String> = match (cas.get("inscrit_rel").and_then(Value::as_str), cas.get("inscrit_brut")) {
        (Some(r), _) if !r.is_empty() => Some(joindre(t, r).display().to_string()),
        (_, Some(Value::String(b))) => Some(b.clone()),
        _ => None,
    };
    let mut ages = Vec::new();
    for a in cas["avant"].as_array().unwrap() {
        let p = joindre(t, texte(a, "chemin"));
        if a.get("dossier").and_then(Value::as_bool) == Some(true) {
            std::fs::create_dir_all(&p).unwrap();
        } else {
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, texte(a, "texte")).unwrap();
        }
        if let Some(j) = a.get("jours").and_then(Value::as_u64) {
            ages.push((p, j));
        }
    }
    ages.sort_by_key(|(p, _)| std::cmp::Reverse(p.as_os_str().len()));
    for (p, j) in &ages {
        dater(p, *j);
    }

    let n = |x: &str| normaliser(x, t);
    let mut flux: HashMap<String, File> = HashMap::new();
    let mut disque: Option<Arc<DisqueMindset>> = None;
    let etapes = cas["etapes"].as_array().unwrap();
    let resultats = cas["resultats"].as_array().unwrap();
    for (i, (e, r)) in etapes.iter().zip(resultats).enumerate() {
        let op = texte(e, "op");
        let mut ecart = |quoi: &str, rust: String, ps: String| {
            if rust != ps {
                diff.push(format!("étape {i} ({op}) {quoi} : Rust {rust} / PowerShell {ps}"));
            }
        };
        let d = || disque.clone().expect("ouvrir d'abord");
        // (la réponse a exactement les champs de cette étape : un champ renommé ou perdu est une différence)
        let mut champs: Vec<&str> = r.as_object().map(|o| o.keys().map(String::as_str).collect()).unwrap_or_default();
        champs.sort_unstable();
        if !champs_attendus(op).contains(&champs.as_slice()) || r["op"] != op {
            ecart("champs", format!("{champs:?}"), format!("ceux de {op}"));
        }
        match op {
            "ouvrir" => {
                let env = Environnement {
                    exe: exe.clone(),
                    localappdata: localappdata.clone(),
                    program_files: pf.clone(),
                    essai: None,
                };
                let lu = AtomicBool::new(false);
                let lire = || {
                    lu.store(true, Ordering::SeqCst);
                    inscrit.clone()
                };
                let (dos, dq) =
                    mindset_donnees::ouvrir_disque(&env, &lire, Arc::new(mindset_noyau::moment::heure_du_pc));
                let ps = &r["dossiers"];
                let mut cles: Vec<&String> = ps.as_object().map(|o| o.keys().collect()).unwrap_or_default();
                cles.sort();
                ecart(
                    "champs des dossiers",
                    format!("{cles:?}"),
                    r#"["disque", "donnees", "donnees_suite", "fichiers", "local_mindset", "mindset", "programmes"]"#
                        .into(),
                );
                for (cle, rust) in [
                    ("fichiers", &dos.fichiers),
                    ("mindset", &dos.mindset),
                    ("programmes", &dos.programmes),
                    ("donnees_suite", &dos.donnees_suite),
                    ("local_mindset", &dos.local_mindset),
                    ("donnees", &dos.donnees),
                ] {
                    ecart(cle, n(&rust.display().to_string()), texte(ps, cle).to_string());
                }
                ecart("disque", dos.disque.clone(), texte(ps, "disque").to_string());
                ecart("registre_lu", lu.load(Ordering::SeqCst).to_string(), r["registre_lu"].to_string());
                let (ill, rep) = dq.etat_reglages();
                ecart("illisibles", ill.to_string(), r["illisibles"].to_string());
                ecart("repris", rep.to_string(), r["repris"].to_string());
                disque = Some(dq);
            }
            "reglages" => {
                let rust = d().reglages();
                let ps = r["valeurs"].as_object().cloned().unwrap_or_default();
                let mut cr: Vec<&String> = rust.keys().collect();
                let mut cp: Vec<&String> = ps.keys().collect();
                cr.sort();
                cp.sort();
                if cr != cp && !ec.contains(&"doubles") {
                    ecart("noms", format!("{cr:?}"), format!("{cp:?}"));
                }
                for (k, v) in &ps {
                    if let Some(x) = rust.get(k)
                        && !egal_json(x, &valeur_ps(v))
                    {
                        ecart(k, x.to_string(), v.to_string());
                    }
                }
            }
            "reglage" => {
                let v = d().reglage(texte(e, "nom"));
                ecart("existe", v.is_some().to_string(), r["existe"].to_string());
                let v = v.unwrap_or(Value::Null);
                if !egal_json(&v, &valeur_ps(&r["valeur"])) {
                    ecart("valeur", v.to_string(), r["valeur"].to_string());
                }
            }
            "ecrire_reglage" => d().ecrire_reglage(texte(e, "nom"), serde_json::from_str(texte(e, "valeur")).unwrap()),
            "lancer_avec_windows" => {
                ecart("oui", mindset_donnees::lancer_avec_windows(&*d()).to_string(), r["oui"].to_string())
            }
            "ecrire_lancer_avec_windows" => {
                mindset_donnees::ecrire_lancer_avec_windows(&*d(), e["oui"].as_bool().unwrap())
            }
            "lire_json" => {
                let f = joindre(t, texte(e, "fichier"));
                match (d().lire_json(&f), r.get("erreur")) {
                    (Err(m), Some(p)) => ecart("erreur", n(&m), n(p.as_str().unwrap_or(""))),
                    (Err(m), None) => ecart("erreur", m, "pas d'erreur".into()),
                    (Ok(v), Some(p)) => ecart("erreur", format!("{v:?}"), p.to_string()),
                    (Ok(v), None) => {
                        let v = v.unwrap_or(Value::Null);
                        if !egal_json(&v, &valeur_ps(&r["valeur"])) {
                            ecart("valeur", v.to_string(), r["valeur"].to_string());
                        }
                    }
                }
            }
            "ecrire_json" => {
                let f = joindre(t, texte(e, "fichier"));
                let ok = d().ecrire_json(&f, &serde_json::from_str(texte(e, "valeur")).unwrap()).is_ok();
                ecart("ok", ok.to_string(), r["ok"].to_string());
            }
            "json_texte" => {
                let v: Value = serde_json::from_str(texte(e, "valeur")).unwrap();
                let mut ps = texte(r, "texte").to_string();
                if ec.contains(&"forme") {
                    // (le décimal « 3.0 » relu par PowerShell garde son « .0 » ; Rust écrit « 3 »)
                    ps = ps.replace("3.0,", "3,");
                }
                ecart("texte", json_ps::lisible(&v), ps);
            }
            "suite" => {
                let s = d().suite();
                ecart("theme", texte_ou_null(s.theme.as_deref()).to_string(), r["theme"].to_string());
                ecart("micro", texte_ou_null(s.micro.as_deref()).to_string(), r["micro"].to_string());
                ecart("casque", texte_ou_null(s.casque.as_deref()).to_string(), r["casque"].to_string());
                let mut a: Vec<(String, String)> = s.applis.clone();
                a.sort();
                let mut b: Vec<(String, String)> = r["applis"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|p| (p[0].as_str().unwrap().to_string(), p[1].as_str().unwrap().to_string()))
                    .collect();
                b.sort();
                ecart("applis", format!("{a:?}"), format!("{b:?}"));
                ecart("illisible", s.illisible.to_string(), r["illisible"].to_string());
            }
            "theme_suite" => ecart("theme", d().theme_suite(), texte(r, "theme").to_string()),
            "ecrire_theme_suite" => d().ecrire_theme_suite(texte(e, "theme")),
            "ecrire_suite_appli" => d().ecrire_suite_appli(texte(e, "id"), e["dossier"].as_str()),
            "son_suite" => {
                let (m, c) = d().son_suite();
                ecart("micro", m, texte(r, "micro").to_string());
                ecart("casque", c, texte(r, "casque").to_string());
            }
            "ecrire_son_suite" => d().ecrire_son_suite(texte(e, "quoi"), texte(e, "nom")),
            "theme_valable" => {
                ecart("oui", mindset_donnees::suite::theme_valable(texte(e, "theme")).to_string(), r["oui"].to_string())
            }
            "nom_appareil" => {
                ecart("oui", mindset_donnees::suite::nom_appareil(texte(e, "nom")).to_string(), r["oui"].to_string())
            }
            "racines_depuis" => {
                if r["erreur"].as_bool() != Some(true) {
                    let local = localappdata.join("Mindset").display().to_string();
                    let x = mindset_donnees::racines_depuis(texte(e, "dossier"), &pf.display().to_string(), &local);
                    ecart("programmes", n(&x.programmes), texte(r, "programmes").to_string());
                    ecart("disque", x.disque, texte(r, "disque").to_string());
                    // (null : Join-Path refuse un disque qui n'existe pas sur le PC ; rien à comparer)
                    if let Some(p) = r["donnees"].as_str() {
                        ecart("donnees", n(&x.donnees), p.to_string());
                    }
                }
            }
            "verrouiller" => {
                let f = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .share_mode(0)
                    .open(joindre(t, texte(e, "fichier")))
                    .unwrap();
                flux.insert(texte(e, "fichier").to_string(), f);
            }
            "liberer" => {
                flux.remove(texte(e, "fichier"));
            }
            "ecrire_fichier" => {
                let p = joindre(t, texte(e, "fichier"));
                std::fs::create_dir_all(p.parent().unwrap()).unwrap();
                std::fs::write(&p, texte(e, "texte")).unwrap();
            }
            "effacer_fichier" => {
                let _ = std::fs::remove_file(joindre(t, texte(e, "fichier")));
            }
            autre => panic!("étape inconnue : {autre}"),
        }
    }
    if etapes.len() != resultats.len() {
        diff.push(format!("{} étapes pour {} résultats", etapes.len(), resultats.len()));
    }
    drop(flux);
    drop(disque);

    // Les fichiers à la fin
    let (fichiers, dossiers) = contenu(t);
    let rust: BTreeMap<String, String> = fichiers.into_iter().map(|(k, v)| (n(&k), v)).collect();
    let ps: BTreeMap<String, String> =
        cas["fichiers"].as_object().unwrap().iter().map(|(k, v)| (n(k), v.as_str().unwrap().to_string())).collect();
    let (rust, ps) = selon_json_sur(rust, ps, &mut diff, cas);
    for k in rust.keys().chain(ps.keys()).collect::<std::collections::BTreeSet<_>>() {
        match (rust.get(k), ps.get(k)) {
            (Some(a), Some(b)) => {
                let (na, nb) = (n(a), n(b));
                if na == nb {
                    continue;
                }
                match (analyser(&na), analyser(&nb)) {
                    (Some(va), Some(vb)) if egal_json(&va, &vb) => {
                        // (même contenu : la forme doit être celle de ConvertTo-Json, à l'ordre des clés près)
                        let forme = n(&json_ps::lisible(&dans_l_ordre(&analyser(a).unwrap(), &vb)));
                        if forme != nb && !ec.contains(&"nombres") {
                            diff.push(format!("fichier {k} : forme Rust\n{forme}\n/ PowerShell\n{nb}"));
                        }
                    }
                    _ => diff.push(format!("fichier {k} : Rust\n{na}\n/ PowerShell\n{nb}")),
                }
            }
            (Some(_), None) => diff.push(format!("fichier {k} : en plus chez Rust")),
            (None, Some(_)) => diff.push(format!("fichier {k} : absent chez Rust")),
            (None, None) => {}
        }
    }
    let dps: Vec<String> = cas["dossiers_apres"].as_array().unwrap().iter().map(|d| n(d.as_str().unwrap())).collect();
    let drs: Vec<String> = dossiers.iter().map(|d| n(d)).collect();
    if drs != dps {
        diff.push(format!("dossiers : Rust {drs:?} / PowerShell {dps:?}"));
    }
    let _ = std::fs::remove_dir_all(t);
    diff.into_iter().map(|d| format!("[{nom}] {d}")).collect()
}

/// Les fichiers comparables malgré les divergences voulues de suite_commun::json_sur (rust\suite-commun\src\json_sur.rs) :
/// - une copie `.bak` illisible est mise de côté (`.bak.abime-<date>`) au lieu de rester `.bak` : ramenée à `.bak`,
///   et la ligne « X.bak mis de côté dans ... » retirée du journal ;
/// - un fichier vide ou abîmé n'est jamais copié dans `.bak` : quand le `.bak` de PowerShell n'est pas un objet JSON
///   (donc inutile), celui de Rust peut différer, mais doit être un objet JSON ou absent (jamais pire).
fn selon_json_sur(
    mut rust: BTreeMap<String, String>,
    mut ps: BTreeMap<String, String>,
    diff: &mut Vec<String>,
    cas: &Value,
) -> (BTreeMap<String, String>, BTreeMap<String, String>) {
    for k in rust.keys().filter(|k| k.contains(".bak.abime-<date>")).cloned().collect::<Vec<_>>() {
        let bak = k.replace(".bak.abime-<date>", ".bak");
        let v = rust.remove(&k).unwrap();
        if let std::collections::btree_map::Entry::Vacant(e) = rust.entry(bak) {
            e.insert(v);
        } else if analyser(&v).is_some_and(|x| x.is_object()) {
            // (une copie mise de côté est toujours illisible : sinon, c'est une vraie différence)
            diff.push(format!("fichier {k} : mis de côté alors qu'il se lit"));
        }
        // (sinon : PowerShell a remplacé cette copie illisible à l'écriture suivante, Rust l'a gardée de côté)
    }
    for (k, v) in rust.iter_mut() {
        if k.ends_with("journal.txt") {
            *v = v.split_inclusive("\r\n").filter(|l| !l.contains(".bak mis de côté dans ")).collect();
        }
    }
    // (seulement une copie d'un texte abîmé donné par le cas lui-même : un fichier d'avant ou écrit par une étape)
    let originaux: Vec<String> = cas["avant"]
        .as_array()
        .into_iter()
        .chain(cas["etapes"].as_array())
        .flatten()
        .filter_map(|a| a.get("texte").and_then(Value::as_str).map(str::to_string))
        .collect();
    let objet = |t: &str| analyser(t).is_some_and(|v| v.is_object());
    for k in ps.keys().filter(|k| k.ends_with(".bak")).cloned().collect::<Vec<_>>() {
        if !objet(&ps[&k]) && originaux.contains(&ps[&k]) && rust.get(&k).is_none_or(|r| r != &ps[&k]) {
            if rust.get(&k).is_some_and(|r| !objet(r)) {
                diff.push(format!("fichier {k} : la copie de Rust n'est pas un objet JSON"));
            }
            ps.remove(&k);
            rust.remove(&k);
        }
    }
    (rust, ps)
}

fn juges() -> Vec<Value> {
    let v: Value = serde_json::from_str(JUGES).expect("juges lisibles");
    v["cas"].as_array().unwrap().clone()
}

fn dossier(nom: &str) -> PathBuf {
    std::env::temp_dir().join(format!("mindset-juges-donnees-{nom}-{}", std::process::id()))
}

#[test]
fn juges_powershell() {
    let cas = juges();
    assert!(cas.len() >= 200, "{} cas seulement", cas.len());
    let racine = dossier("juges");
    let mut toutes = Vec::new();
    for (i, c) in cas.iter().enumerate() {
        toutes.extend(rejouer(c, &racine.join(format!("c{i:03}"))));
    }
    let _ = std::fs::remove_dir_all(&racine);
    assert!(toutes.is_empty(), "{} différence(s) :\n{}", toutes.len(), toutes.join("\n"));
}

/// Change un texte d'un caractère (un « x » ajouté au début).
fn changer(t: &str) -> String {
    // (au début : jamais dans une partie que la normalisation efface, une date ou un message de Windows)
    format!("x{t}")
}

/// La contre-épreuve : un juge modifié d'un seul caractère (un dossier, un fichier, une réponse) doit échouer.
#[test]
fn contre_epreuve() {
    let racine = dossier("contre");
    let mut passes = Vec::new();
    for (i, c) in juges().iter().enumerate() {
        let nom = texte(c, "nom").to_string();
        // 1. Le dossier des données de la première étape (ouvrir)
        let mut m = c.clone();
        let o = m["resultats"].as_array().unwrap().iter().position(|r| r["op"] == "ouvrir").unwrap();
        let d = texte(&m["resultats"][o]["dossiers"], "donnees").to_string();
        m["resultats"][o]["dossiers"]["donnees"] = Value::String(changer(&d));
        if rejouer(&m, &racine.join(format!("a{i:03}"))).is_empty() {
            passes.push(format!("{nom} (dossier)"));
        }
        // 2. Le premier fichier
        let mut m = c.clone();
        if let Some((k, v)) =
            m["fichiers"].as_object().and_then(|o| o.iter().next()).map(|(k, v)| (k.clone(), v.clone()))
        {
            m["fichiers"][&k] = Value::String(changer(v.as_str().unwrap()));
            if rejouer(&m, &racine.join(format!("b{i:03}"))).is_empty() {
                passes.push(format!("{nom} (fichier {k})"));
            }
        }
        // 3. La dernière réponse qui dit quelque chose (en dehors de « op »)
        let mut m = c.clone();
        let res = m["resultats"].as_array_mut().unwrap();
        if let Some(r) = res.iter_mut().skip(1).rev().find(|r| r.as_object().is_some_and(|o| o.len() > 1)) {
            let o = r.as_object_mut().unwrap();
            let (k, v) = o.iter().find(|(k, _)| *k != "op").map(|(k, v)| (k.clone(), v.clone())).unwrap();
            let nouveau = match v {
                Value::Bool(b) => Value::Bool(!b),
                Value::String(s) => Value::String(changer(&s)),
                Value::Null => Value::String("x".into()),
                Value::Array(mut a) => {
                    a.push(Value::Array(vec![Value::String("x".into()), Value::String("y".into())]));
                    Value::Array(a)
                }
                Value::Object(mut o) => {
                    o.insert("ajout".into(), Value::String("\"x\"".into()));
                    Value::Object(o)
                }
                autre => Value::String(format!("{autre}x")),
            };
            o.insert(k.clone(), nouveau);
            if rejouer(&m, &racine.join(format!("c{i:03}"))).is_empty() {
                passes.push(format!("{nom} (réponse {k})"));
            }
        }
    }
    let _ = std::fs::remove_dir_all(&racine);
    assert!(passes.is_empty(), "juges modifiés qui passent quand même :\n{}", passes.join("\n"));
}

/// La contre-épreuve au plus près du fichier : un seul octet du juge changé (une lettre, tirée au hasard dans les
/// réponses et les fichiers d'un cas, hors des noms d'étape) fait échouer ce cas.
#[test]
fn contre_epreuve_un_octet() {
    // (un cas par ligne, suivi d'une virgule sauf le dernier)
    let lignes: Vec<&str> =
        JUGES.lines().filter(|l| l.starts_with("{\"nom\":")).map(|l| l.trim_end_matches(',')).collect();
    assert!(lignes.len() >= 200);
    let racine = dossier("octet");
    let mut graine: u64 = 0x2026_1107;
    let mut hasard = |n: usize| {
        graine = graine.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (graine >> 33) as usize % n
    };
    let mut passes = Vec::new();
    let mut essais = 0;
    while essais < 200 {
        let l = lignes[hasard(lignes.len())];
        let (Some(debut), Some(fin)) = (l.find("\"resultats\":"), l.find(",\"dossiers_apres\"")) else { continue };
        let o = l.as_bytes();
        let places: Vec<usize> = (debut + 12..fin)
            .filter(|&i| o[i].is_ascii_lowercase())
            .filter(|&i| !dans_un_nom_d_etape(o, i) && !dans_un_message_de_windows(o, i))
            .collect();
        if places.is_empty() {
            continue;
        }
        let i = places[hasard(places.len())];
        let mut m = o.to_vec();
        m[i] = if m[i] == b'q' { b'w' } else { b'q' };
        let Ok(cas) = serde_json::from_slice::<Value>(&m) else { continue };
        essais += 1;
        // (une réponse si abîmée que la comparaison s'arrête compte aussi comme un échec)
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            rejouer(&cas, &racine.join(format!("o{essais:02}")))
        }));
        if r.is_ok_and(|d| d.is_empty()) {
            passes.push(format!(
                "{} (octet {i} : {:?})",
                texte(&cas, "nom"),
                String::from_utf8_lossy(&o[i.saturating_sub(20)..(i + 10).min(o.len())])
            ));
        }
    }
    let _ = std::fs::remove_dir_all(&racine);
    assert!(passes.is_empty(), "un octet changé et pourtant pareil :\n{}", passes.join("\n"));
}

/// L'octet `i` est-il dans le nom d'une étape (`"op":"..."`), que la comparaison ne lit pas dans les réponses ?
fn dans_un_nom_d_etape(o: &[u8], i: usize) -> bool {
    let motif = b"\"op\":\"";
    let avant = &o[..i];
    match avant.windows(motif.len()).rposition(|w| w == motif) {
        Some(p) => !o[p + motif.len()..i].contains(&b'"'),
        None => false,
    }
}

/// Les champs (triés) de la réponse de chaque étape, telle que l'écrit outils\exporter-juges-donnees.ps1.
fn champs_attendus(op: &str) -> &'static [&'static [&'static str]] {
    match op {
        "ouvrir" => &[&["dossiers", "illisibles", "op", "registre_lu", "repris"]],
        "reglages" => &[&["op", "valeurs"]],
        "reglage" => &[&["existe", "op", "valeur"]],
        "lancer_avec_windows" | "theme_valable" | "nom_appareil" => &[&["op", "oui"]],
        "lire_json" => &[&["op", "valeur"], &["erreur", "op"]],
        "ecrire_json" => &[&["ok", "op"]],
        "json_texte" => &[&["op", "texte"]],
        "suite" => &[&["applis", "casque", "illisible", "micro", "op", "theme"]],
        "theme_suite" => &[&["op", "theme"]],
        "son_suite" => &[&["casque", "micro", "op"]],
        "racines_depuis" => &[&["disque", "donnees", "op", "programmes"], &["erreur", "op"]],
        _ => &[&["op"]],
    }
}

/// L'octet `i` est-il dans le message d'erreur de Windows d'une ligne du journal (« ne peut pas être lu (...) »),
/// que la comparaison coupe (il diffère entre .NET et Rust) ?
fn dans_un_message_de_windows(o: &[u8], i: usize) -> bool {
    let motif = "ne peut pas être lu (".as_bytes();
    let avant = &o[..i];
    match avant.windows(motif.len()).rposition(|w| w == motif) {
        Some(p) => !o[p..i].windows(4).any(|w| w == b"\r\n"),
        None => false,
    }
}
