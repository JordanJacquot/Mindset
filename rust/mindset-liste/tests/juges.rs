//! Les juges du bloc « liste » : les réponses de la VRAIE version PowerShell (modules\liste.ps1, Get-Applis et
//! Receive-ListeEnLigne de modules\applis.ps1), exportées par `outils\exporter-juges-liste.ps1` dans `tests/juges` :
//! - `convertir.json` : des entrées passées à `ConvertTo-Appli` (l'appli rendue, ou le refus, et le journal) ;
//! - `listes.json` : des dossiers préparés (apps.json, apps-liste.txt, liste gardée et sa signature) et une liste
//!   téléchargée, passés aux autres fonctions (le résultat, l'erreur, le journal, les fichiers après) ;
//! - `hasard.json` : des cas tirés au hasard par l'export (graine fixe), jamais écrits à la main.
//!
//! Chaque cas est rejoué ici sur la version Rust, qui doit rendre exactement la même chose. La contre-épreuve : chaque
//! valeur attendue changée (un texte, un nombre, un booléen, un élément de tableau) doit faire échouer le cas.
//!
//! Un seul défaut de la version PowerShell est corrigé (DIVERGENCES.md) : `[IO.File]::Replace($tmp, $x[0], $null)`
//! (une liste gardée n'est jamais remplacée). L'export joue alors la version corrigée de cet appel, et note la réponse
//! d'aujourd'hui dans `divergence_ps` : ce test vérifie que c'est bien ce seul défaut.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use mindset_liste::liste::{self, Source};
use mindset_liste::{BlocListe, resultat_telechargement};
use mindset_noyau::{Bloc, Effet, Effets, signaux};

// ---------------------------------------------------------------------------------------------------------------
// Les outils
// ---------------------------------------------------------------------------------------------------------------

fn juge(nom: &str) -> Value {
    let f = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(nom);
    let t = std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{} : {e}", f.display()));
    serde_json::from_str(t.trim_start_matches('\u{FEFF}')).expect("juge illisible")
}

/// Base64 (le format des octets dans les juges).
fn base64(t: &str) -> Vec<u8> {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut sortie = Vec::new();
    let (mut acc, mut n) = (0u32, 0);
    for c in t.bytes().filter(|c| *c != b'=') {
        let v = A.iter().position(|x| *x == c).expect("base64") as u32;
        acc = (acc << 6) | v;
        n += 6;
        if n >= 8 {
            n -= 8;
            sortie.push((acc >> n) as u8);
            acc &= (1 << n) - 1;
        }
    }
    sortie
}

fn en_base64(o: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in o.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let v = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= c.len() {
                s.push(A[((v >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                s.push('=');
            }
        }
    }
    s
}

/// Un bloc d'octets d'un juge : `{ b64, bourrage }` (bourrage : autant d'espaces à la fin), ou null.
fn octets(v: &Value) -> Option<Vec<u8>> {
    let o = v.as_object()?;
    let mut b = base64(o["b64"].as_str()?);
    b.extend(std::iter::repeat_n(b' ', o["bourrage"].as_u64().unwrap_or(0) as usize));
    Some(b)
}

/// Un dossier d'essai neuf (jamais un vrai dossier de données).
struct Dossier(PathBuf);
impl Dossier {
    fn nouveau(nom: &str) -> Dossier {
        let d = std::env::temp_dir().join(format!("mindset-liste-juges-{nom}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        Dossier(d)
    }
}
impl Drop for Dossier {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Les variables d'environnement du juge (`env`), sans tenir compte des majuscules.
fn variables(env: &Value) -> impl Fn(&str) -> Option<String> + '_ {
    move |nom: &str| {
        env.as_object()?
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(nom))
            .and_then(|(_, v)| v.as_str())
            .map(String::from)
    }
}

/// Une appli sous la forme du juge (les noms des champs de mindset_noyau::appli::Appli).
fn appli_en_json(a: &mindset_noyau::appli::Appli) -> Value {
    json!({
        "id": a.id, "genre": a.genre, "nom": a.nom, "couleur": a.couleur, "app_id": a.app_id,
        "description": a.description, "presentation": a.presentation, "depot": a.depot, "zip": a.zip,
        "dossier_zip": a.dossier_zip, "exe": a.exe, "script": a.script, "mutex": a.mutex, "ancien_zip": a.ancien_zip,
        "ancien_dossier_zip": a.ancien_dossier_zip, "ancien_script": a.ancien_script, "ancien_mutex": a.ancien_mutex,
        "afficher_fichier": a.afficher_fichier, "afficher_signal": a.afficher_signal,
        "desinstalleur": a.desinstalleur, "donnees": a.donnees, "admin": a.admin, "rappels": a.rappels,
        "sans_droits_depuis": a.sans_droits_depuis, "aide": a.aide, "aide_exe": a.aide_exe,
        "cache_depuis": a.cache_depuis, "confidentialite": a.confidentialite, "logo": a.logo,
        "logo_epaisseur": a.logo_epaisseur,
    })
}

/// `logo_epaisseur` du juge est un texte (format « R » de .NET) : changé en nombre pour la comparaison.
fn normaliser_appli(mut a: Value) -> Value {
    if let Some(t) = a.get("logo_epaisseur").and_then(Value::as_str).map(str::to_string) {
        a["logo_epaisseur"] = json!(t.parse::<f64>().expect("épaisseur"));
    }
    a
}

/// La comparaison : égalité exacte, avec le chemin de la première différence.
fn comparer(attendu: &Value, obtenu: &Value, ou: &str) -> Result<(), String> {
    match (attendu, obtenu) {
        (Value::Object(a), Value::Object(o)) => {
            for (k, v) in a {
                comparer(v, o.get(k).unwrap_or(&Value::Null), &format!("{ou}.{k}"))?;
            }
            for k in o.keys() {
                if !a.contains_key(k) {
                    return Err(format!("{ou}.{k} : en trop"));
                }
            }
            Ok(())
        }
        (Value::Array(a), Value::Array(o)) => {
            if a.len() != o.len() {
                return Err(format!("{ou} : {} éléments attendus, {} obtenus ({obtenu})", a.len(), o.len()));
            }
            a.iter().zip(o).enumerate().try_for_each(|(i, (x, y))| comparer(x, y, &format!("{ou}[{i}]")))
        }
        (Value::Number(a), Value::Number(o)) if a.as_f64() == o.as_f64() => Ok(()),
        _ if attendu == obtenu => Ok(()),
        _ => Err(format!("{ou} : attendu {attendu}, obtenu {obtenu}")),
    }
}

/// Les mutants d'une valeur attendue (la contre-épreuve) : chaque feuille changée une à une.
fn mutants(v: &Value) -> Vec<Value> {
    let mut r = Vec::new();
    match v {
        Value::Null => r.push(json!("x")),
        Value::Bool(b) => r.push(Value::Bool(!b)),
        Value::Number(n) => r.push(json!(n.as_f64().unwrap_or(0.0) + 1.0)),
        Value::String(s) => r.push(Value::String(format!("{s}x"))),
        Value::Array(a) => {
            let mut plus = a.clone();
            plus.push(json!("x"));
            r.push(Value::Array(plus));
            for (i, e) in a.iter().enumerate() {
                for m in mutants(e) {
                    let mut c = a.clone();
                    c[i] = m;
                    r.push(Value::Array(c));
                }
            }
        }
        Value::Object(o) => {
            for (k, e) in o {
                for m in mutants(e) {
                    let mut c = o.clone();
                    c.insert(k.clone(), m);
                    r.push(Value::Object(c));
                }
            }
        }
    }
    r
}

// ---------------------------------------------------------------------------------------------------------------
// ConvertTo-Appli
// ---------------------------------------------------------------------------------------------------------------

fn obtenu_convertir(cas: &Value, env: &Value) -> Value {
    let entree = cas["entree"].as_str().unwrap();
    let origine = cas["origine"].as_str().unwrap();
    let mut journal = Vec::<String>::new();
    let lu = liste::json_powershell(&format!("[{entree}]"));
    let (lisible, appli) = match lu {
        Ok(Some(Value::Array(v))) => {
            let mut j = |t: &str| journal.push(t.to_string());
            let a = liste::convertir(&v[0], origine, &mut j, &variables(env));
            (true, a.map(|a| appli_en_json(&a)).unwrap_or(Value::Null))
        }
        _ => (false, Value::Null),
    };
    json!({ "lisible": lisible, "appli": appli, "journal": journal })
}

fn attendu_convertir(cas: &Value) -> Value {
    let appli = if cas["appli"].is_null() { Value::Null } else { normaliser_appli(cas["appli"].clone()) };
    json!({ "lisible": cas["lisible"], "appli": appli, "journal": cas["journal"] })
}

fn rejouer_convertir(fichier: &str, hasard: Option<bool>) -> (usize, Vec<String>) {
    let j = juge(fichier);
    let mut echecs = Vec::new();
    let mut n = 0;
    for cas in j["cas"].as_array().unwrap() {
        if hasard.is_some_and(|h| cas["hasard"].as_bool() != Some(h)) {
            continue;
        }
        n += 1;
        if let Err(e) = comparer(&attendu_convertir(cas), &obtenu_convertir(cas, &j["env"]), "") {
            echecs.push(format!("{} : {e}", cas["nom"]));
        }
    }
    (n, echecs)
}

#[test]
fn convertir_comme_powershell() {
    let (n, echecs) = rejouer_convertir("convertir.json", Some(false));
    assert!(n > 300, "trop peu de cas : {n}");
    assert!(echecs.is_empty(), "{} cas sur {n} différents :\n{}", echecs.len(), echecs.join("\n"));
}

#[test]
fn convertir_cas_tires_au_hasard() {
    let (n, echecs) = rejouer_convertir("convertir.json", Some(true));
    assert!(n >= 100, "trop peu de cas : {n}");
    assert!(echecs.is_empty(), "{} cas sur {n} différents :\n{}", echecs.len(), echecs.join("\n"));
}

#[test]
fn convertir_contre_epreuve() {
    let j = juge("convertir.json");
    let mut verifies = 0;
    for cas in j["cas"].as_array().unwrap() {
        let attendu = attendu_convertir(cas);
        let obtenu = obtenu_convertir(cas, &j["env"]);
        for m in mutants(&attendu) {
            verifies += 1;
            assert!(comparer(&m, &obtenu, "").is_err(), "{} : un juge changé passe encore ({m})", cas["nom"]);
        }
    }
    assert!(verifies > 5000, "{verifies}");
}

// ---------------------------------------------------------------------------------------------------------------
// Les dossiers : Get-NumeroListeLivree, Read-ListeEnLigne, Read-ListeGardee, Get-EntreesApplis, Add-ListeEnLigne,
// Get-Applis, Receive-ListeEnLigne
// ---------------------------------------------------------------------------------------------------------------

/// Les dossiers d'un cas, comme ceux de l'export : `<racine>\Mindset\fichiers`, `<racine>\Donnees\Mindset`.
struct Lieux {
    fichiers: PathBuf,
    donnees: PathBuf,
}

fn poser(cas: &Value, cle: &str, fichiers: &Path, donnees: &Path) {
    std::fs::create_dir_all(fichiers.join("cles-publiques")).unwrap();
    std::fs::write(fichiers.join("cles-publiques").join("test.xml"), cle).unwrap();
    if let Some(o) = octets(&cas["apps"]) {
        std::fs::write(fichiers.join("apps.json"), o).unwrap();
    }
    if let Some(o) = octets(&cas["numero"]) {
        std::fs::write(fichiers.join("apps-liste.txt"), o).unwrap();
    }
    let gardee = donnees.join("apps-en-ligne.json");
    if !cas["gardee"].is_null() || !cas["gardee_sig"].is_null() {
        std::fs::create_dir_all(donnees).unwrap();
    }
    if let Some(o) = octets(&cas["gardee"]) {
        std::fs::write(&gardee, o).unwrap();
    }
    if let Some(o) = octets(&cas["gardee_sig"]) {
        std::fs::write(donnees.join("apps-en-ligne.json.sig"), o).unwrap();
    }
}

fn disque(donnees: &Path) -> Value {
    let lire = |n: &str| std::fs::read(donnees.join(n)).ok().map(|o| en_base64(&o));
    let mut autres: Vec<String> = std::fs::read_dir(donnees)
        .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    autres.retain(|n| n != "apps-en-ligne.json" && n != "apps-en-ligne.json.sig");
    autres.sort();
    json!({ "gardee": lire("apps-en-ligne.json"), "sig": lire("apps-en-ligne.json.sig"), "autres": autres })
}

fn resultat_liste(l: Option<&liste::ListeLue>) -> Value {
    match l {
        None => Value::Null,
        Some(l) => {
            let texte = |e: &Value, n: &str| match e
                .as_object()
                .and_then(|o| o.iter().find(|(k, _)| k.eq_ignore_ascii_case(n)))
            {
                Some((_, Value::String(s))) => s.clone(),
                _ => String::new(),
            };
            json!({
                "numero": l.numero, "mindset_min": l.mindset_min,
                "ids": l.entrees.iter().map(|e| texte(e, "id")).collect::<Vec<_>>(),
                "noms": l.entrees.iter().map(|e| texte(e, "nom")).collect::<Vec<_>>(),
            })
        }
    }
}

/// Les messages propres à .NET (lecture d'apps.json impossible) : comparés seulement sur leur début.
fn normaliser(op: &str, mut v: Value) -> Value {
    if op == "entrees" && v["ok"] == json!(false) {
        v["erreur"] = json!("<apps.json illisible>");
    }
    if let Some(j) = v["journal"].as_array_mut() {
        for l in j.iter_mut() {
            if l.as_str().is_some_and(|t| t.starts_with("apps.json illisible : ")) {
                *l = json!("apps.json illisible : <message de lecture>");
            }
        }
    }
    if op == "applis"
        && let Some(a) = v["resultat"].as_array_mut()
    {
        for x in a.iter_mut() {
            *x = normaliser_appli(x.take());
        }
    }
    if let Some(a) = v["disque"]["autres"].as_array_mut() {
        a.sort_by_key(|x| x.as_str().unwrap_or_default().to_string());
    }
    v
}

fn obtenu_dossier(cas: &Value, cle: &str, env: &Value, nom: &str) -> Value {
    let op = cas["op"].as_str().unwrap();
    if op == "recevoir" {
        return obtenu_recevoir(cas, cle, nom);
    }
    let d = Dossier::nouveau(nom);
    let l = Lieux { fichiers: d.0.join(r"Mindset\fichiers"), donnees: d.0.join(r"Donnees\Mindset") };
    poser(cas, cle, &l.fichiers, &l.donnees);
    let gardee = l.donnees.join("apps-en-ligne.json");
    let gardee_opt = cas["avec_gardee"].as_bool().unwrap().then_some(gardee.as_path());
    let version = cas["version"].as_str().unwrap();
    let json = octets(&cas["json"]).unwrap_or_default();
    let sig = octets(&cas["sig"]).unwrap_or_default();
    let mut journal = Vec::<String>::new();
    let mut j = |t: &str| journal.push(t.to_string());
    let r: Result<Value, String> = match op {
        "numero" => Ok(json!(liste::numero_livre(&l.fichiers))),
        "en_ligne" => {
            let min = cas["numero_min"].as_i64().unwrap();
            liste::lire_en_ligne(&json, &sig, &l.fichiers, version, min, &mut j).map(|x| resultat_liste(Some(&x)))
        }
        "gardee" => liste::lire_gardee(gardee_opt, &l.fichiers, version, &mut j).map(|x| resultat_liste(x.as_ref())),
        "entrees" => liste::entrees(&l.fichiers, gardee_opt, version, &mut j).map(|x| {
            let ids: Vec<String> = x.entrees.iter().map(mindset_liste_texte_id).collect();
            let source = if x.source == Source::EnLigne { "en-ligne" } else { "livree" };
            json!({ "source": source, "numero": x.numero, "ids": ids })
        }),
        "ajouter" => liste::ajouter_en_ligne(&json, &sig, &l.fichiers, &gardee, version, &mut j)
            .map(|x| resultat_liste(x.as_ref())),
        "applis" => {
            let a = liste::applis(&l.fichiers, gardee_opt, version, &mut j, &variables(env));
            Ok(Value::Array(a.applis.iter().map(appli_en_json).collect()))
        }
        autre => panic!("op inconnue {autre}"),
    };
    let (ok, erreur, resultat) = match r {
        Ok(v) => (true, Value::Null, v),
        Err(e) => (false, json!(e), Value::Null),
    };
    json!({ "ok": ok, "erreur": erreur, "resultat": resultat, "journal": journal, "disque": disque(&l.donnees) })
}

/// `[string]$e.id` d'une entrée (rien si ce n'est pas un objet).
fn mindset_liste_texte_id(e: &Value) -> String {
    match e.as_object().and_then(|o| suite_commun::protocole_installateur::champ(o, "id")) {
        Some(v) => suite_commun::protocole_installateur::texte_ps(v),
        None => String::new(),
    }
}

/// Receive-ListeEnLigne : la fin du téléchargement, jouée sur le bloc lui-même (dans un contexte d'essai).
fn obtenu_recevoir(cas: &Value, cle: &str, nom: &str) -> Value {
    let (ctx, faux) = mindset_noyau::essai::contexte(&format!("liste-juge-{nom}"));
    poser(cas, cle, &ctx.dossiers.fichiers, &ctx.dossiers.donnees);
    let resultat = match (&cas["erreur_telechargement"], octets(&cas["json"]), octets(&cas["sig"])) {
        (Value::String(e), _, _) => Err(e.clone()),
        (_, None, None) => Ok(Value::Null),
        (_, j, s) => Ok(resultat_telechargement(&j.unwrap_or_default(), &s.unwrap_or_default())),
    };
    let mut bloc = BlocListe;
    let mut effets = Effets::default();
    let avant = faux.donnees.lignes().len();
    ctx.au_nom_de("liste", || bloc.tache_finie(&ctx, mindset_liste::TACHE, resultat, &mut effets));
    let journal: Vec<String> = faux.donnees.lignes()[avant..].to_vec();
    // (réessai dans une heure : une nouvelle recherche, demandée tout de suite, n'est pas lancée)
    let mut effets = Effets::default();
    ctx.au_nom_de("liste", || bloc.signal(&ctx, signaux::VERIFIER_LISTE, &json!({}), &mut effets));
    let relance = effets.0.iter().any(|e| matches!(e, Effet::Tache(_)));
    let v = json!({
        "ok": true, "erreur": null, "resultat": { "reessai_dans_une_heure": !relance }, "journal": journal,
        "disque": disque(&ctx.dossiers.donnees),
    });
    let _ = std::fs::remove_dir_all(&faux.racine);
    v
}

fn attendu_dossier(cas: &Value) -> Value {
    let a = &cas["attendu"];
    json!({ "ok": a["ok"], "erreur": a["erreur"], "resultat": a["resultat"], "journal": a["journal"], "disque": a["disque"] })
}

fn rejouer_dossiers(fichier: &str) -> (usize, Vec<String>) {
    let j = juge(fichier);
    let cle = j["cle_publique"].as_str().unwrap();
    let mut echecs = Vec::new();
    let cas = j["cas"].as_array().unwrap();
    for (i, c) in cas.iter().enumerate() {
        let op = c["op"].as_str().unwrap();
        let nom = format!("{}-{i}", fichier.trim_end_matches(".json"));
        let attendu = normaliser(op, attendu_dossier(c));
        let obtenu = normaliser(op, obtenu_dossier(c, cle, &j["env"], &nom));
        if let Err(e) = comparer(&attendu, &obtenu, "") {
            echecs.push(format!("{} ({op}) : {e}", c["nom"]));
        }
    }
    (cas.len(), echecs)
}

#[test]
fn dossiers_comme_powershell() {
    let (n, echecs) = rejouer_dossiers("listes.json");
    assert!(n > 120, "trop peu de cas : {n}");
    assert!(echecs.is_empty(), "{} cas sur {n} différents :\n{}", echecs.len(), echecs.join("\n"));
}

#[test]
fn dossiers_cas_tires_au_hasard() {
    let (n, echecs) = rejouer_dossiers("hasard.json");
    assert!(n >= 100, "trop peu de cas : {n}");
    assert!(echecs.is_empty(), "{} cas sur {n} différents :\n{}", echecs.len(), echecs.join("\n"));
}

#[test]
fn dossiers_contre_epreuve() {
    for fichier in ["listes.json", "hasard.json"] {
        let j = juge(fichier);
        let cle = j["cle_publique"].as_str().unwrap();
        for (i, c) in j["cas"].as_array().unwrap().iter().enumerate() {
            let op = c["op"].as_str().unwrap();
            let attendu = normaliser(op, attendu_dossier(c));
            let obtenu = normaliser(op, obtenu_dossier(c, cle, &j["env"], &format!("contre-{i}")));
            for m in mutants(&attendu) {
                assert!(comparer(&m, &obtenu, "").is_err(), "{} : un juge changé passe encore ({m})", c["nom"]);
            }
        }
    }
}

/// Le seul défaut corrigé : l'appel à `[IO.File]::Replace` (une liste gardée n'était jamais remplacée).
#[test]
fn seule_divergence_le_remplacement_de_la_liste_gardee() {
    let mut vues = 0;
    for fichier in ["listes.json", "hasard.json"] {
        for c in juge(fichier)["cas"].as_array().unwrap() {
            let d = &c["divergence_ps"];
            if d.is_null() {
                continue;
            }
            vues += 1;
            let texte = format!("{} {}", d["erreur"], d["journal"]);
            assert!(
                texte.contains("Replace") && texte.contains("forme conforme"),
                "{} : divergence inattendue {d}",
                c["nom"]
            );
            // (la version corrigée a bien gardé la nouvelle liste)
            assert!(c["attendu"]["disque"]["autres"].as_array().unwrap().is_empty(), "{}", c["nom"]);
        }
    }
    assert!(vues >= 5, "{vues}");
}

// ---------------------------------------------------------------------------------------------------------------
// Des cas jamais vus par l'export : la liste livrée de ce dépôt, lue en entier
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn apps_json_livre_du_depot() {
    let fichiers = Path::new(env!("CARGO_MANIFEST_DIR")).join(r"..\..\Mindset\fichiers");
    let mut journal = Vec::<String>::new();
    let mut j = |t: &str| journal.push(t.to_string());
    let a = liste::applis(&fichiers, None, "3.0.0", &mut j, &|n: &str| {
        n.eq_ignore_ascii_case("LOCALAPPDATA").then(|| r"C:\Essai".to_string())
    });
    assert!(journal.is_empty(), "{journal:?}");
    assert_eq!(a.source, Some(Source::Livree));
    assert!(a.numero >= 1);
    let ids: Vec<&str> = a.applis.iter().map(|x| x.id.as_str()).collect();
    assert!(ids.contains(&"nevermind") && ids.contains(&"evermind") && ids.contains(&"mindcare"), "{ids:?}");
    let n = a.applis.iter().find(|x| x.id == "nevermind").unwrap();
    assert_eq!(n.donnees, r"C:\Essai\OptiGame");
    assert_eq!(n.app_id, "JordanJacquot.Nevermind");
    assert!(n.admin && !n.rappels && n.genre == "powershell");
}
