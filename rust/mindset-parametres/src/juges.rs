//! Les juges : les cas exportés depuis la version PowerShell (`outils\exporter-juges-parametres.ps1`, dans
//! `tests\juges\*.json`), rejoués ici. Chaque différence voulue est écrite dans le test, avec sa raison (et dans
//! DIVERGENCES.md). La contre-épreuve (un octet changé dans un juge fait échouer la comparaison) est à la fin.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Map, Value, json};

use mindset_noyau::{Appli, Bloc, Contexte, Effet, Effets, Lancement, essai, partage};

use crate::packs::Packs;
use crate::plateforme::{Fausse, Partie};
use crate::theme::ThemeCourant;
use crate::{Parametres, conso, packs, textes};

fn juge(nom: &str) -> Value {
    let f = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(format!("{nom}.json"));
    let o = std::fs::read(&f).unwrap_or_else(|e| panic!("{} : {e}", f.display()));
    serde_json::from_slice(&o).unwrap_or_else(|e| panic!("{} : {e}", f.display()))
}

fn cas(j: &Value) -> Vec<Value> {
    match j.get("cas") {
        Some(Value::Array(a)) => a.clone(),
        Some(v @ Value::Object(_)) => vec![v.clone()],
        _ => Vec::new(),
    }
}

fn liste(v: &Value) -> Vec<Value> {
    match v {
        Value::Array(a) => a.clone(),
        Value::Null => Vec::new(),
        v => vec![v.clone()],
    }
}

fn texte(v: &Value) -> String {
    suite_commun::protocole_installateur::texte_ps(v)
}

/// Un dossier d'essai neuf (jamais un vrai dossier de données).
fn dossier(nom: &str) -> PathBuf {
    let d = mindset_noyau::dossier_essai(&format!("juge-{nom}"));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("Donnees").join("Mindset")).unwrap();
    std::fs::create_dir_all(d.join("Local").join("Mindset")).unwrap();
    d
}

fn poser_arbre(racine: &Path, fichiers: &Value) {
    for f in liste(fichiers) {
        let Some(c) = f.get("chemin").and_then(Value::as_str).filter(|c| !c.is_empty()) else { continue };
        let p = racine.join(c);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, decoder_b64(f["b64"].as_str().unwrap_or(""))).unwrap();
    }
}

fn decoder_b64(t: &str) -> Vec<u8> {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut v = Vec::new();
    let (mut acc, mut n) = (0u32, 0);
    for c in t.bytes() {
        let Some(x) = A.iter().position(|&a| a == c) else { continue };
        acc = (acc << 6) | x as u32;
        n += 6;
        if n >= 8 {
            n -= 8;
            v.push((acc >> n) as u8);
        }
    }
    v
}

/// Les fichiers d'un dossier, chemins relatifs (les anciennes versions sous un nom tiré au hasard : « * »).
fn arbre(racine: &Path) -> Vec<(String, u64)> {
    fn parcourir(d: &Path, base: &Path, l: &mut Vec<(String, u64)>) {
        let Ok(e) = std::fs::read_dir(d) else { return };
        for x in e.flatten() {
            let p = x.path();
            if p.is_dir() {
                parcourir(&p, base, l);
            } else {
                let mut rel = p.strip_prefix(base).unwrap().to_string_lossy().into_owned();
                if let Some(i) = rel.find(r"\packs-anciens\") {
                    let debut = i + r"\packs-anciens\".len();
                    if let Some(j) = rel[debut..].find('\\') {
                        rel = format!("{}*{}", &rel[..debut], &rel[debut + j..]);
                    }
                }
                l.push((rel, x.metadata().map(|m| m.len()).unwrap_or(0)));
            }
        }
    }
    let mut l = Vec::new();
    parcourir(racine, racine, &mut l);
    l.sort();
    l
}

fn arbre_juge(v: &Value) -> Vec<(String, u64)> {
    let mut l: Vec<(String, u64)> =
        liste(v).iter().map(|f| (texte(&f["chemin"]), f["taille"].as_u64().unwrap_or(0))).collect();
    l.sort();
    l
}

/// Garde des fichiers ouverts comme `[IO.File]::Open(.., 'Read', 'Read')` (les autres peuvent lire, pas écrire ni
/// supprimer, ni renommer le dossier).
fn tenir(racine: &Path, pris: &Value) -> Vec<std::fs::File> {
    liste(pris)
        .iter()
        .filter_map(|p| p.as_str())
        .map(|p| {
            let mut o = std::fs::OpenOptions::new();
            o.read(true);
            #[cfg(windows)]
            {
                use std::os::windows::fs::OpenOptionsExt;
                o.share_mode(1); // FILE_SHARE_READ
            }
            o.open(racine.join(p)).unwrap()
        })
        .collect()
}

/// Une ligne du journal sans le message de Windows (sa langue et ses mots ne sont pas ceux de .NET).
fn ligne_normale(l: &str, racine: &Path) -> String {
    let l = l.replace(&*racine.to_string_lossy(), "<racine>");
    if l.starts_with("Pack ")
        && let Some(i) = l.find(" illisible : ")
    {
        return format!("{} (…)", &l[..i + " illisible :".len()]);
    }
    for m in [" pas encore retiré (", " pas mise en place ("] {
        if let Some(i) = l.find(m) {
            return format!("{}(…)", &l[..i + m.len() - 1]);
        }
    }
    l
}

fn journal_juge(v: &Value) -> Vec<String> {
    liste(v).iter().map(|l| ligne_normale(&texte(l), Path::new("<racine>"))).collect()
}

fn applis_juge(v: &Value) -> Vec<(String, String)> {
    liste(v)
        .iter()
        .map(|a| {
            let a = liste(a);
            (texte(&a[0]), texte(&a[1]))
        })
        .collect()
}

fn packs_de<'a>(racine: &Path, applis: Vec<(String, String)>, j: &'a dyn Fn(&str)) -> Packs<'a> {
    let suite = racine.join("Donnees");
    Packs { packs: suite.join(r"Mindset\packs"), donnees: suite.join("Mindset"), suite, applis, journal: j }
}

// ---------------------------------------------------------------------------------------------------------------
// 1. Les couleurs
// ---------------------------------------------------------------------------------------------------------------

fn rejouer_couleurs(cas: &[Value], nom: &str) -> usize {
    let mut n = 0;
    for c in cas {
        let d = dossier(nom);
        let packs_d = d.join("packs");
        let theme = texte(&c["theme"]);
        if let Some(p) = c["pack"].as_str() {
            let id = &theme["pack:".len()..];
            std::fs::create_dir_all(packs_d.join(id)).unwrap();
            std::fs::write(packs_d.join(id).join("pack.json"), p).unwrap();
        }
        let t = ThemeCourant::charger(&theme, &packs_d);
        if let Some(b) = c.get("base").and_then(Value::as_str) {
            assert_eq!(t.theme.id, b, "{theme} : le thème de couleurs");
            assert_eq!(t.bonjour(), texte(&c["bonjour"]), "{theme} : Get-ThemeHello");
        }
        for (k, v) in c["couleurs"].as_object().unwrap() {
            assert_eq!(t.traduire(k), texte(v), "{theme} : ConvertTo-ThemeHex {k}");
            n += 1;
        }
        let _ = std::fs::remove_dir_all(&d);
    }
    n
}

#[test]
fn juges_couleurs() {
    let n = rejouer_couleurs(&cas(&juge("themes")), "couleurs");
    assert!(n > 500, "{n} couleurs seulement");
}

// ---------------------------------------------------------------------------------------------------------------
// 2. L'import d'un thème
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_import() {
    let j = juge("import");
    let zips = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges");
    let tous = cas(&j);
    assert!(tous.len() >= 30);
    for c in tous {
        let nom = texte(&c["nom"]);
        let racine = dossier("import");
        poser_arbre(&racine, &c["avant"]);
        if let Some(t) = c["a_retirer_avant"].as_str() {
            std::fs::write(racine.join(r"Donnees\Mindset\packs-a-retirer.txt"), t).unwrap();
        }
        let tenus = tenir(&racine, &c["pris"]);
        let lignes = RefCell::new(Vec::new());
        let jl = |t: &str| lignes.borrow_mut().push(t.to_string());
        let p = packs_de(&racine, applis_juge(&c["applis"]), &jl);
        let r = p.importer(&zips.join(texte(&c["zip"])));
        drop(tenus);
        let attendu = &c["resultat"];
        match (&r, attendu.get("erreur")) {
            (Err(e), Some(a)) => assert_eq!(e, &texte(a), "{nom}"),
            (Ok(i), None) => {
                assert_eq!(i.id, texte(&attendu["id"]), "{nom}");
                assert_eq!(i.remplace, attendu["remplace"].as_bool().unwrap(), "{nom} : remplace");
                let att: Vec<String> = liste(&attendu["attente"]).iter().map(texte).collect();
                assert_eq!(i.attente, att, "{nom} : attente");
            }
            _ => panic!("{nom} : {r:?} au lieu de {attendu}"),
        }
        assert_eq!(arbre(&racine), arbre_juge(&c["apres"]), "{nom} : les fichiers");
        let l: Vec<String> = lignes.borrow().iter().map(|l| ligne_normale(l, &racine)).collect();
        assert_eq!(l, journal_juge(&c["journal"]), "{nom} : le journal");
        let _ = std::fs::remove_dir_all(&racine);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// 3. Supprimer, nettoyer
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_suppression() {
    for c in cas(&juge("suppression")) {
        let nom = texte(&c["nom"]);
        let racine = dossier("suppression");
        poser_arbre(&racine, &c["avant"]);
        let fichier = racine.join(r"Donnees\Mindset\packs-a-retirer.txt");
        if let Some(t) = c["a_retirer_avant"].as_str() {
            std::fs::write(&fichier, t).unwrap();
        }
        let tenus = tenir(&racine, &c["pris"]);
        let lignes = RefCell::new(Vec::new());
        let jl = |t: &str| lignes.borrow_mut().push(t.to_string());
        let p = packs_de(&racine, applis_juge(&c["applis"]), &jl);
        let id = texte(&c["id"]);
        let r = match texte(&c["action"]).as_str() {
            "supprimer" => json!(p.supprimer(&id)),
            "nettoyer" => {
                p.nettoyer();
                Value::Null
            }
            "liste" => json!(p.a_retirer()),
            "dossiers" => json!(
                p.dossiers_du_pack(&id)
                    .iter()
                    .map(|d| d.to_string_lossy().replace(&*racine.to_string_lossy(), "<racine>"))
                    .collect::<Vec<_>>()
            ),
            "themes" => {
                let a = p.a_retirer();
                json!(
                    crate::theme::packs_installes(&p.packs, &a, p.journal)
                        .iter()
                        .filter_map(|t| t.pack.as_ref().map(|k| k.id.clone()))
                        .collect::<Vec<_>>()
                )
            }
            x => panic!("action {x}"),
        };
        drop(tenus);
        let mut attendu = c["resultat"].clone();
        if texte(&c["action"]) == "themes" {
            // Divergence voulue : un dossier de pack au nom en majuscules (« Beta ») n'est pas un thème ; la version
            // PowerShell le lisait (`-notmatch` sans tenir compte des majuscules), mais « pack:Beta » écrit dans
            // suite.json serait refusé par toutes les applis (suite-commun). DIVERGENCES.md, point 2.
            attendu =
                json!(liste(&attendu).into_iter().filter(|x| texte(x) == texte(x).to_lowercase()).collect::<Vec<_>>());
        }
        if texte(&c["action"]) == "dossiers" || texte(&c["action"]) == "liste" || texte(&c["action"]) == "themes" {
            assert_eq!(json!(liste(&r)), json!(liste(&attendu)), "{nom}");
        } else {
            assert_eq!(r, attendu, "{nom}");
        }
        assert_eq!(arbre(&racine), arbre_juge(&c["apres"]), "{nom} : les fichiers");
        let reste = std::fs::read_to_string(&fichier).ok();
        assert_eq!(reste.as_deref(), c["a_retirer"].as_str(), "{nom} : packs-a-retirer.txt");
        let l: Vec<String> = lignes.borrow().iter().map(|l| ligne_normale(l, &racine)).collect();
        assert_eq!(l, journal_juge(&c["journal"]), "{nom} : le journal");
        let _ = std::fs::remove_dir_all(&racine);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Le contexte d'un cas
// ---------------------------------------------------------------------------------------------------------------

fn appli_de(a: &Value) -> Appli {
    let b = |n: &str| a.get(n).is_some_and(suite_commun::protocole_installateur::vrai_ps);
    let t = |n: &str| a.get(n).map(texte).unwrap_or_default();
    Appli {
        id: t("Id"),
        nom: t("Nom"),
        couleur: t("Couleur"),
        rappels: b("Rappels"),
        admin: b("Admin"),
        sans_droits_depuis: t("SansDroitsDepuis"),
        donnees: t("Donnees"),
        ..Default::default()
    }
}

fn applis_suite() -> Vec<Appli> {
    vec![
        Appli {
            id: "nevermind".into(),
            nom: "Nevermind".into(),
            couleur: "#00E5FF".into(),
            admin: true,
            sans_droits_depuis: "2.0.0".into(),
            ..Default::default()
        },
        Appli {
            id: "evermind".into(),
            nom: "Evermind".into(),
            couleur: "#B04BFF".into(),
            rappels: true,
            ..Default::default()
        },
        Appli { id: "mindcare".into(), nom: "Mindcare".into(), couleur: "#FF2EB5".into(), ..Default::default() },
    ]
}

fn minuscules(v: &Value) -> Value {
    match v {
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.to_lowercase(), minuscules(x))).collect()),
        v => v.clone(),
    }
}

/// Un contexte d'essai et un bloc démarré pour l'entrée d'un cas.
fn preparer(nom: &str, e: &Value) -> (Contexte, essai::Faux, Parametres, Arc<Fausse>) {
    static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let lancement = Lancement { admin: e["admin"].as_bool().unwrap_or(false), ..Default::default() };
    let (ctx, f) = essai::contexte_avec(&format!("{nom}-{n}"), lancement);
    let applis: Vec<Appli> = match e.get("applis") {
        Some(Value::Array(a)) if !a.is_empty() => a.iter().map(appli_de).collect(),
        _ => applis_suite(),
    };
    ctx.definir_applis(applis);
    poser_arbre(&f.racine, &e["fichiers"]);
    if let Some(r) = e["reglages"].as_object() {
        for (k, v) in r {
            ctx.ecrire_reglage(k, v.clone());
        }
    }
    let insts = e.get("installations").filter(|v| v.is_object()).cloned().unwrap_or_else(|| json!({}));
    ctx.au_nom_de("installations", || {
        ctx.publier(partage::INSTALLATIONS, minuscules(&insts));
        if e["occupe"].as_bool() == Some(true) {
            ctx.publier(partage::OCCUPATIONS, json!({ "evermind": { "texte": "Téléchargement..." } }));
        }
    });
    if let Some(p) = e["publications"].as_object() {
        let p: Map<String, Value> = p.iter().map(|(k, v)| (k.clone(), minuscules(v))).collect();
        ctx.au_nom_de("publications", || ctx.publier(partage::PUBLICATIONS, Value::Object(p)));
    }
    if let Some(s) = e["son"].as_object() {
        for (k, v) in s {
            ctx.donnees().ecrire_son_suite(k, &texte(v));
        }
    }
    if let Some(t) = e["theme"].as_str() {
        ctx.donnees().ecrire_theme_suite(t);
    }
    let maj = match (e["maj_mindset"].as_str(), e["maj_en_cours"].as_bool() == Some(true)) {
        (Some(v), _) => json!({ "version": v, "prete": true }),
        (None, true) => json!({ "en_cours": true }),
        _ => Value::Null,
    };
    ctx.au_nom_de("lui-meme", || ctx.publier(partage::MINDSET, json!({ "installe": false, "maj": maj })));
    if e["verifie_a"].as_bool() == Some(true) {
        ctx.au_nom_de("publications", || ctx.publier(partage::RECHERCHE, json!({ "verifie_a": "20:00" })));
    }
    let fausse = Arc::new(Fausse::default());
    *fausse.micros.lock().unwrap() = liste(&e["micros"]).iter().map(texte).collect();
    *fausse.sorties.lock().unwrap() = liste(&e["sorties"]).iter().map(texte).collect();
    let en_test = e["en_test"].as_bool().unwrap_or(true);
    let mut b = Parametres::avec_plateforme(fausse.clone(), !en_test);
    let mut ef = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut ef));
    (ctx, f, b, fausse)
}

/// Les champs ajoutés pour la page (pas dans `Get-EtatParametres`), retirés pour comparer.
fn sans_ajouts(mut v: Value) -> Value {
    if let Some(o) = v.as_object_mut() {
        o.remove("onglet");
        o.remove("onglets");
        o.remove("couleurs");
    }
    if let Some(t) = v.pointer_mut("/apparence/themes").and_then(Value::as_array_mut) {
        for c in t {
            if let Some(c) = c.as_object_mut() {
                c.remove("bord");
                c.remove("police");
                c.remove("vignette");
            }
        }
    }
    if let Some(m) = v.pointer_mut("/maj/mindset").and_then(Value::as_object_mut) {
        m.remove("texte_page");
    }
    v
}

fn remplacer(v: &Value, de: &str, par: &str) -> Value {
    match v {
        Value::String(s) => Value::String(s.replace(de, par)),
        Value::Array(a) => Value::Array(a.iter().map(|x| remplacer(x, de, par)).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), remplacer(x, de, par))).collect()),
        v => v.clone(),
    }
}

// ---------------------------------------------------------------------------------------------------------------
// 4. L'état des Paramètres
// ---------------------------------------------------------------------------------------------------------------

fn etat_du_cas(c: &Value) -> (Value, Value) {
    let e = &c["entree"];
    let (ctx, f, mut b, _) = preparer("juge-etat", e);
    b.theme_info = texte(&e["theme_info"]);
    b.maj_info = texte(&e["maj_info"]);
    if let Some(o) = e["onglet"].as_str() {
        b.onglet = o.to_string();
    }
    b.relire_appareils(&ctx);
    if let Some(p) = e["parties"].as_array() {
        let parties: Vec<Partie> = p
            .iter()
            .map(|x| Partie {
                nom: texte(&x["nom"]),
                nombre: x["nombre"].as_u64().unwrap_or(0) as u32,
                memoire: x["memoire"].as_i64().unwrap_or(0),
                processeur: x["processeur"].as_f64().unwrap_or(0.0),
            })
            .collect();
        b.conso = Some(conso::etat(&parties, e["premiere"].as_bool() == Some(true)));
    }
    let r = remplacer(&sans_ajouts(b.etat_parametres(&ctx)), &f.racine.to_string_lossy(), "<racine>");
    let attendu: Value = serde_json::from_str(c["sortie"].as_str().unwrap()).unwrap();
    let _ = std::fs::remove_dir_all(&f.racine);
    (r, attendu)
}

#[test]
fn juges_etat() {
    let tous = cas(&juge("etat"));
    assert!(tous.len() >= 10);
    for c in &tous {
        let (r, attendu) = etat_du_cas(c);
        assert_eq!(r, attendu, "{}", texte(&c["nom"]));
    }
}

// ---------------------------------------------------------------------------------------------------------------
// 5. Ce qui est demandé à Windows pour la consommation
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_conso() {
    for c in cas(&juge("conso")) {
        let nom = texte(&c["nom"]);
        let (ctx, f) = essai::contexte("juge-conso");
        let racine = f.racine.to_string_lossy().into_owned();
        let applis: Vec<Appli> = liste(&c["applis"])
            .iter()
            .map(|a| {
                let mut x = appli_de(a);
                x.donnees = x.donnees.replace("<racine>", &racine);
                x
            })
            .collect();
        ctx.definir_applis(applis);
        for d in liste(&c["dossiers"]) {
            std::fs::create_dir_all(f.racine.join(texte(&d))).unwrap();
        }
        let insts = minuscules(&c["installations"]);
        ctx.au_nom_de("installations", || ctx.publier(partage::INSTALLATIONS, insts));
        let d = conso::demande(&ctx);
        let norm = |l: &[String]| -> Vec<String> { l.iter().map(|x| x.replace(&racine, "<racine>")).collect() };
        let noms: Vec<String> = liste(&c["noms"]).iter().map(texte).collect();
        let chemins: Vec<String> = liste(&c["chemins"]).iter().map(texte).collect();
        assert_eq!(d.noms, noms, "{nom} : les noms");
        assert_eq!(norm(&d.dossiers), chemins, "{nom} : les dossiers");
        assert_eq!(d.dossier_moi.replace(&racine, "<racine>"), texte(&c["moi"]), "{nom}");
        let _ = std::fs::remove_dir_all(&f.racine);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// 6. Les gestes, la suppression confirmée
// ---------------------------------------------------------------------------------------------------------------

/// Les effets d'un geste, dans le vocabulaire des faux PowerShell.
fn evenements(e: &Effets, racine: &str) -> Vec<Value> {
    let mut l = Vec::new();
    for x in &e.0 {
        match x {
            Effet::Signal { nom, donnees } => match nom.as_str() {
                "versions-essai" | "demarrage-appli" => {
                    l.push(json!({ "signal": nom, "id": donnees["id"], "oui": donnees["oui"] }))
                }
                "confidentialite" => l.push(json!({ "signal": nom, "id": donnees["id"] })),
                "actualiser" => l.push(json!({ "signal": nom, "clic": donnees["clic"] })),
                "maj-mindset" | "desinstaller-mindset" => l.push(json!({ "signal": nom })),
                "confirmation" => l.push(json!({ "confirmation": {
                    "titre": donnees["titre"], "texte": donnees["texte"], "bouton": donnees["bouton"] } })),
                _ => {}
            },
            Effet::OuvrirAdresse(a) => l.push(json!({ "ouvrir": a.replace(racine, "<racine>") })),
            Effet::Relancer => l.push(json!({ "relancer": true })),
            Effet::Page(p) => l.push(json!({ "page": p })),
            Effet::Tache(t) if t.id == "importer" => l.push(json!({ "importer": true })),
            _ => {}
        }
    }
    l
}

/// Les événements PowerShell sans ceux qui se comparent autrement (suite.json, l'onglet).
fn evenements_juge(v: &Value) -> Vec<Value> {
    liste(v)
        .into_iter()
        .filter(|x| x.get("son").is_none() && x.get("theme_suite").is_none() && x.get("onglet").is_none())
        .collect()
}

#[test]
fn juges_gestes() {
    for c in cas(&juge("gestes")) {
        let nom = texte(&c["nom"]);
        let mut e = c["entree"].clone();
        if e.get("installations").is_none_or(|v| !v.is_object()) {
            e["installations"] = json!({ "evermind": { "dossier": r"C:\P\Evermind", "gere": true, "version": "1.0.0" },
                "nevermind": { "dossier": r"C:\P\Nevermind", "gere": true, "version": "1.0.0" } });
        }
        let (ctx, f, mut b, _) = preparer("juge-gestes", &e);
        let racine = f.racine.to_string_lossy().into_owned();
        let avant = f.donnees.lignes().len();
        let mut ev = Vec::new();
        for g in liste(&c["gestes"]) {
            let mut ef = Effets::default();
            ctx.au_nom_de("parametres", || b.action(&ctx, "parametres:reglage", &g, &mut ef));
            ev.extend(evenements(&ef, &racine));
        }
        assert_eq!(ev, evenements_juge(&c["evenements"]), "{nom} : les événements");
        // Les réglages
        let mut r: Vec<(String, Value)> = f.donnees.reglages().into_iter().collect();
        r.sort_by(|a, b| a.0.cmp(&b.0));
        let attendu: Vec<(String, Value)> = c["reglages"]
            .as_object()
            .map(|o| o.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
            .unwrap_or_default();
        assert_eq!(r, attendu, "{nom} : les réglages");
        assert!(packs::egal(&b.onglet, &texte(&c["onglet"])), "{nom} : l'onglet {}", b.onglet);
        assert_eq!(b.theme_info, texte(&c["info"]), "{nom} : ThemeInfo");
        assert_eq!(b.maj_info, texte(&c["maj_info"]), "{nom} : MajInfo");
        assert_eq!(ctx.donnees().theme_suite(), texte(&c["suite_theme"]), "{nom} : suite.json");
        // Le son : le dernier choix noté par PowerShell est dans suite.json
        let (micro, casque) = ctx.donnees().son_suite();
        for x in liste(&c["evenements"]) {
            if let Some(s) = x.get("son") {
                let (q, n) = (texte(&s[0]), texte(&s[1]));
                assert_eq!(if q == "micro" { &micro } else { &casque }, &n, "{nom} : {q}");
            }
        }
        let l: Vec<String> = f.donnees.lignes()[avant..].to_vec();
        assert_eq!(l, journal_juge(&c["journal"]), "{nom} : le journal");
        let _ = std::fs::remove_dir_all(&f.racine);
    }
}

#[test]
fn juges_retrait() {
    let j = juge("retrait");
    for c in cas(&j) {
        let nom = texte(&c["nom"]);
        let e = json!({ "theme": c["theme"], "en_test": c["en_test"], "occupe": c["occupe"], "fichiers": j["avant"] });
        let (ctx, f, mut b, _) = preparer("juge-retrait", &e);
        let avant = f.donnees.lignes().len();
        let tenus = tenir(&f.racine, &c["pris"]);
        let mut ef = Effets::default();
        ctx.au_nom_de("parametres", || b.action(&ctx, "parametres:supprimer-theme", &c["id"], &mut ef));
        drop(tenus);
        assert_eq!(evenements(&ef, &f.racine.to_string_lossy()), evenements_juge(&c["evenements"]), "{nom}");
        assert_eq!(b.theme_info, texte(&c["info"]), "{nom} : ThemeInfo");
        assert_eq!(ctx.donnees().theme_suite(), texte(&c["suite_theme"]), "{nom} : suite.json");
        // (suite.json est écrit ici dans <racine>\Local, hors des fichiers comparés par PowerShell)
        let apres: Vec<(String, u64)> =
            arbre(&f.racine).into_iter().filter(|(c, _)| !c.starts_with(r"Local\")).collect();
        assert_eq!(apres, arbre_juge(&c["apres"]), "{nom} : les fichiers");
        let l: Vec<String> = f.donnees.lignes()[avant..].iter().map(|l| ligne_normale(l, &f.racine)).collect();
        assert_eq!(l, journal_juge(&c["journal"]), "{nom} : le journal");
        let _ = std::fs::remove_dir_all(&f.racine);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// 7. Une page demandée, 8. le thème changé ailleurs
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_page() {
    for c in cas(&juge("page")) {
        let t = c["texte"].as_str();
        let (ctx, f, mut b, _) = preparer("juge-page", &json!({}));
        std::fs::create_dir_all(&ctx.dossiers.local_mindset).unwrap();
        if let Some(t) = t {
            std::fs::write(ctx.dossiers.page_demandee(), t).unwrap();
        }
        let mut ef = Effets::default();
        ctx.au_nom_de("parametres", || b.signal(&ctx, mindset_noyau::signaux::AFFICHER_DEMANDE, &json!({}), &mut ef));
        let mut ev = Vec::new();
        for x in &ef.0 {
            match x {
                Effet::Fenetre(mindset_noyau::Fenetre::Montrer) => ev.push(json!({ "fenetre": "montrer" })),
                Effet::Page(p) => ev.push(json!({ "page": p })),
                // (l'id de l'appli est celui de la liste : « Evermind » demandé ouvre « evermind », DIVERGENCES.md)
                Effet::Signal { nom, donnees } if nom == "ouvrir-appli" => {
                    ev.push(json!({ "ouvrir_appli": texte(&donnees["id"]).to_lowercase() }))
                }
                _ => {}
            }
        }
        let mut attendu = Vec::new();
        let mut onglet = None;
        for x in liste(&c["evenements"]) {
            if let Some(o) = x.get("onglet") {
                onglet = Some(texte(o));
            } else if let Some(a) = x.get("ouvrir_appli") {
                attendu.push(json!({ "ouvrir_appli": texte(a).to_lowercase() }));
            } else {
                attendu.push(x);
            }
        }
        assert_eq!(ev, attendu, "« {t:?} »");
        if let Some(o) = onglet {
            assert!(packs::egal(&b.onglet, &o), "« {t:?} » : onglet {}", b.onglet);
        }
        assert_eq!(!ctx.dossiers.page_demandee().exists(), c["retire"].as_bool().unwrap(), "« {t:?} » : retiré");
        let _ = std::fs::remove_dir_all(&f.racine);
    }
}

#[test]
fn juges_surveillance() {
    for c in cas(&juge("surveillance")) {
        let nom = texte(&c["nom"]);
        let e = json!({ "theme": c["actuel"], "en_test": false, "occupe": c["occupe"] });
        let (ctx, f, mut b, _) = preparer("juge-surveillance", &e);
        let mut suite = ctx.dossiers.suite();
        if let Some(t) = c["suite"].as_str() {
            ctx.donnees().ecrire_theme_suite(t);
        } else {
            let _ = std::fs::remove_file(&suite);
            suite.pop();
        }
        if let Some(d) = c["derniere"].as_object() {
            ctx.ecrire_reglage("DerniereRelanceTheme", Value::Object(d.clone()));
        }
        let avant = f.donnees.lignes().len();
        let mut ef = Effets::default();
        b.surveiller_theme(&ctx, &mut ef);
        assert_eq!(evenements(&ef, ""), evenements_juge(&c["evenements"]), "{nom}");
        let d = ctx.reglage("DerniereRelanceTheme").map(|d| json!({ "Theme": d["Theme"], "Quand": d["Quand"] }));
        assert_eq!(d.unwrap_or(Value::Null), c["derniere_apres"], "{nom} : DerniereRelanceTheme");
        assert_eq!(f.donnees.lignes()[avant..].to_vec(), journal_juge(&c["journal"]), "{nom} : le journal");
        let _ = std::fs::remove_dir_all(&f.racine);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// 9. Les petits textes, 10. les cas tirés au hasard
// ---------------------------------------------------------------------------------------------------------------

fn paires(v: &Value) -> Vec<(Value, String)> {
    liste(v)
        .iter()
        .map(|p| {
            let p = liste(p);
            (p[0].clone(), texte(&p[1]))
        })
        .collect()
}

fn rejouer_textes(j: &Value) -> usize {
    let mut n = 0;
    for (o, a) in paires(&j["memoire"]) {
        assert_eq!(textes::memoire(o.as_i64().unwrap()), a, "Format-MemoireConso {o}");
        n += 1;
    }
    for (p, a) in paires(&j["processeur"]) {
        assert_eq!(textes::processeur(p.as_f64().unwrap()), a, "Format-ProcesseurConso {p}");
        n += 1;
    }
    for (x, a) in paires(&j["appareils"]) {
        assert_eq!(textes::nom_appareil(&texte(&x)), a, "Get-NomAppareil « {x} »");
        n += 1;
    }
    for (x, a) in paires(&j["ids_zip"]) {
        let z = PathBuf::from(r"C:\x").join(texte(&x));
        assert_eq!(packs::id_depuis_zip(&z), a, "l'id de « {x} »");
        n += 1;
    }
    for p in liste(&j["noms_fichiers"]) {
        let p = liste(&p);
        assert_eq!(
            packs::nom_fichier_valable(&texte(&p[0])),
            p[1].as_bool().unwrap(),
            "Test-NomFichierPack « {} »",
            p[0]
        );
        n += 1;
    }
    for c in liste(&j["choix_son"]) {
        let noms: Vec<String> = liste(&c["noms"]).iter().map(texte).collect();
        assert_eq!(json!(textes::choix_son(&noms, &texte(&c["choisi"]))), json!(liste(&c["attendu"])), "{c}");
        n += 1;
    }
    for c in liste(&j["entrees"]) {
        let r = textes::entree(&c["x"])
            .map(|e| json!({ "id": e.id, "nom": e.nom, "version": e.version, "quand": e.quand, "auto": e.auto }));
        let a = c["attendu"].as_object().map(|a| {
            json!({ "id": a["id"], "nom": a["nom"], "version": a["version"], "quand": a["quand"], "auto": a["auto"] })
        });
        assert_eq!(r, a, "ConvertTo-EntreeMaj {}", c["x"]);
        n += 1;
    }
    let maintenant = textes::lire_moment("2026-11-07T20:00:00").unwrap();
    for c in liste(&j["quand"]) {
        let q = textes::lire_moment(&texte(&c["quand"])).unwrap();
        assert_eq!(textes::quand(&q, &maintenant, c["long"].as_bool().unwrap()), texte(&c["attendu"]), "{c}");
        n += 1;
    }
    for c in liste(&j["versions"]) {
        assert_eq!(textes::version_publiee(&minuscules(&c["p"])), texte(&c["attendu"]), "{c}");
        n += 1;
    }
    n
}

#[test]
fn juges_textes() {
    let n = rejouer_textes(&juge("textes"));
    assert!(n > 80, "{n}");
}

#[test]
fn juges_hasard() {
    let j = juge("hasard");
    let n = rejouer_textes(&j) + rejouer_couleurs(&liste(&j["themes"]), "hasard");
    assert!(n > 2000, "{n} cas tirés au hasard seulement");
}

// ---------------------------------------------------------------------------------------------------------------
// La contre-épreuve : un juge changé d'un octet doit faire échouer la comparaison
// ---------------------------------------------------------------------------------------------------------------

/// Change un caractère d'une valeur texte (la première qui en a un qu'on peut changer).
fn changer_un_octet(v: &mut Value) -> bool {
    match v {
        Value::String(s) if !s.is_empty() => {
            let mut o = s.clone().into_bytes();
            let i = o.iter().position(|c| c.is_ascii_alphanumeric()).unwrap_or(0);
            o[i] = if o[i] == b'a' { b'b' } else { b'a' };
            *s = String::from_utf8_lossy(&o).into_owned();
            true
        }
        Value::Array(a) => a.iter_mut().any(changer_un_octet),
        Value::Object(m) => m.iter_mut().any(|(_, x)| changer_un_octet(x)),
        _ => false,
    }
}

#[test]
fn contre_epreuve() {
    // L'état : chaque cas, avec une seule valeur changée, ne doit plus être égal
    for c in cas(&juge("etat")) {
        let (r, mut attendu) = etat_du_cas(&c);
        assert_eq!(r, attendu);
        assert!(changer_un_octet(&mut attendu));
        assert_ne!(r, attendu, "la contre-épreuve n'a rien vu : {}", texte(&c["nom"]));
    }
    // Les couleurs : une traduction changée d'un octet ne passe plus
    let mut themes = cas(&juge("themes"));
    let c = themes[1]["couleurs"].as_object_mut().unwrap();
    let (k, v) = c.iter_mut().find(|(k, _)| k.as_str() == "#0C0920").unwrap();
    assert_eq!(k, "#0C0920");
    *v = json!("#1A0B13");
    let r = std::panic::catch_unwind(|| rejouer_couleurs(&themes[1..2], "contre"));
    assert!(r.is_err(), "une couleur fausse n'a pas été vue");
    // Les textes : un chiffre changé
    let mut t = juge("textes");
    t["memoire"][3][1] = json!("1 Mo de trop");
    assert!(std::panic::catch_unwind(|| rejouer_textes(&t)).is_err());
    // Le fichier lui-même : un octet changé au milieu d'un texte attendu de l'import
    let f = Path::new(env!("CARGO_MANIFEST_DIR")).join(r"tests\juges\import.json");
    let mut o = std::fs::read(f).unwrap();
    let i = o.windows(5).position(|w| w == b"foret").unwrap();
    o[i] = b'F';
    let j: Value = serde_json::from_slice(&o).unwrap();
    assert_ne!(j, juge("import"));
}

#[test]
fn bloc_complet_avec_l_hote_du_noyau() {
    // Le bloc tel que l'hôte le crée (`BlocParametres::default()`), démarré puis interrogé
    let (ctx, f) = essai::contexte("juge-bloc");
    let mut b = crate::BlocParametres::default();
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    assert!(b.etat(&ctx).contains_key("parametres"));
    let _ = std::fs::remove_dir_all(&f.racine);
}
