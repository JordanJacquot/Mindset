//! Les juges exportés de la version PowerShell (outils\exporter-juges-installations.ps1 -> tests\juges\*.json) :
//! chaque cas est rejoué ici et doit donner exactement la même sortie. La contre-épreuve (un juge changé d'un octet
//! doit faire échouer la comparaison) est à la fin.

use mindset_installations::poste::FauxPoste;
use mindset_installations::{BlocInstallations, copies, regles, telechargement};
use mindset_noyau::installateur::{Direct, EtatTache, Installateur};
use mindset_noyau::{Appli, Bloc, Contexte, Effet, Effets, Lancement, Ports};
use serde_json::{Map, Value, json};
use std::path::Path;
use std::sync::{Arc, Mutex};

fn juge(nom: &str) -> Value {
    let f = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(format!("{nom}.json"));
    let t = std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{}: {e}", f.display()));
    serde_json::from_str(t.trim_start_matches('\u{feff}')).unwrap()
}

fn cas(j: &Value) -> Vec<Value> {
    j["cas"].as_array().cloned().unwrap_or_default()
}

fn s(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(t) => t.clone(),
        x => x.to_string(),
    }
}

/// Une liste du juge (ConvertTo-Json de PowerShell écrit une liste d'un seul élément telle quelle, et une liste vide
/// comme `[]` ou `null`).
fn liste(v: &Value) -> Vec<Value> {
    match v {
        Value::Array(a) => a.clone(),
        Value::Null => Vec::new(),
        x => vec![x.clone()],
    }
}

fn appli(a: &Value, r: &str) -> Appli {
    Appli {
        id: s(&a["id"]),
        nom: s(&a["nom"]),
        exe: s(&a["exe"]),
        script: s(&a["script"]),
        ancien_script: s(&a["ancien_script"]),
        dossier_zip: s(&a["dossier_zip"]),
        ancien_dossier_zip: s(&a["ancien_dossier_zip"]),
        donnees: s(&a["donnees"]).replace("<R>", r),
        rappels: a["rappels"].as_bool().unwrap_or(false),
        aide: s(&a["aide"]),
        ..Default::default()
    }
}

fn base64(t: &str) -> Vec<u8> {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut r = Vec::new();
    let (mut acc, mut n) = (0u32, 0);
    for c in t.bytes() {
        let Some(v) = A.iter().position(|x| *x == c) else { continue };
        acc = (acc << 6) | v as u32;
        n += 6;
        if n >= 8 {
            n -= 8;
            r.push((acc >> n) as u8);
            acc &= (1 << n) - 1;
        }
    }
    r
}

fn fichiers(dossier: &Path, l: &Value, r: &str) {
    for f in liste(l) {
        if f.is_null() {
            continue;
        }
        let p = dossier.join(s(&f["chemin"]));
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        if f["dossier"].as_bool() == Some(true) {
            std::fs::create_dir_all(&p).unwrap();
        } else if !f["b64"].is_null() {
            std::fs::write(&p, base64(&s(&f["b64"]))).unwrap();
        } else {
            std::fs::write(&p, s(&f["texte"]).replace("<R>", r)).unwrap();
        }
        if f["lecture"].as_bool() == Some(true) {
            let mut perm = std::fs::metadata(&p).unwrap().permissions();
            perm.set_readonly(true);
            std::fs::set_permissions(&p, perm).unwrap();
        }
    }
}

/// `Get-Arbre` : les chemins relatifs (« \ » à la fin d'un dossier), triés sans tenir compte des majuscules.
fn arbre(d: &Path) -> Vec<String> {
    fn tout(base: &Path, d: &Path, r: &mut Vec<String>) {
        let Ok(l) = std::fs::read_dir(d) else { return };
        for e in l.flatten() {
            let p = e.path();
            let rel = p.strip_prefix(base).unwrap().to_string_lossy().into_owned();
            if p.is_dir() {
                r.push(format!("{rel}\\"));
                tout(base, &p, r);
            } else {
                r.push(rel);
            }
        }
    }
    let mut r = Vec::new();
    tout(d, d, &mut r);
    r.sort_by_key(|x| x.to_lowercase());
    r
}

fn r_de(ctx: &Contexte) -> String {
    ctx.dossiers.programmes.parent().unwrap().to_string_lossy().into_owned()
}

fn cacher(t: &str, r: &str) -> String {
    t.replace(r, "<R>")
}

/// Le nom du dossier d'essai d'un cas (unique).
fn nom_essai(famille: &str, i: usize) -> String {
    format!("juge-{famille}-{i}")
}

/// L'ordre des champs d'un objet ne compte pas (une table de PowerShell n'en a pas).
fn canon(v: &Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut l: Vec<(&String, &Value)> = m.iter().collect();
            l.sort_by(|a, b| a.0.cmp(b.0));
            Value::Object(l.into_iter().map(|(k, x)| (k.clone(), canon(x))).collect())
        }
        Value::Array(a) => Value::Array(a.iter().map(canon).collect()),
        x => x.clone(),
    }
}

fn ecarts(nom: &str, attendu: &Value, obtenu: &Value, e: &mut Vec<String>) {
    if canon(attendu) != canon(obtenu) {
        e.push(format!("{nom} : attendu {attendu}, obtenu {obtenu}"));
    }
}

fn texte_ou_nul(v: Option<String>) -> Value {
    v.map(Value::String).unwrap_or(Value::Null)
}

fn lignes(v: &Value) -> Value {
    Value::Array(liste(v))
}

// -----------------------------------------------------------------------------------------------------------------
// Chaque famille : rejoue un cas, rend les écarts
// -----------------------------------------------------------------------------------------------------------------

fn dossiers(i: usize, c: &Value) -> Vec<String> {
    let (ctx, faux) = mindset_noyau::essai::contexte(&nom_essai("dossiers", i));
    let r = r_de(&ctx);
    let d = faux.racine.join(s(&c["sous"]));
    std::fs::create_dir_all(&d).unwrap();
    fichiers(&d, &c["fichiers"], &r);
    let a = appli(&c["appli"], &r);
    let dt = d.to_string_lossy().into_owned();
    let mut e = Vec::new();
    ecarts("dossier_appli", &c["dossier_appli"], &json!(regles::dossier_appli(&dt, &a)), &mut e);
    ecarts("version", &c["version"], &texte_ou_nul(regles::version_dans(&dt, &a)), &mut e);
    let sc = regles::script_appli(&dt, &a).map(|x| x[dt.len() + 1..].to_string());
    ecarts("script", &c["script"], &texte_ou_nul(sc), &mut e);
    let _ = std::fs::remove_dir_all(&faux.racine);
    e
}

fn json_fichier(t: &str, r: &str) -> String {
    // (le juge écrit les « \ » doublés ; <R> est un chemin, à doubler aussi)
    t.replace("<R>", &r.replace('\\', "\\\\"))
}

fn installations(i: usize, c: &Value) -> Vec<String> {
    let (ctx, faux) = mindset_noyau::essai::contexte(&nom_essai("installations", i));
    let r = r_de(&ctx);
    for d in liste(&c["dossiers"]) {
        let p = faux.racine.join(s(&d["chemin"]));
        std::fs::create_dir_all(&p).unwrap();
        fichiers(&p, &d["fichiers"], &r);
    }
    if !c["fichier"].is_null() {
        std::fs::write(ctx.dossiers.installations(), json_fichier(&s(&c["fichier"]), &r)).unwrap();
    }
    if let Value::Object(m) = &c["suite_avant"] {
        for (k, v) in m {
            ctx.donnees().ecrire_suite_appli(k, Some(&s(v).replace("<R>", &r)));
        }
    }
    let a = appli(&c["appli"], &r);
    let occ = c["occupee"].as_bool().unwrap_or(false);
    let inst = mindset_installations::installations::installation(&ctx, &a, occ);
    let obtenu = inst
        .map(|i| json!({ "dossier": cacher(&i.dossier, &r), "gere": i.gere, "version": i.version }))
        .unwrap_or(Value::Null);
    let mut e = Vec::new();
    ecarts("installation", &c["installation"], &obtenu, &mut e);
    let apres = match std::fs::read(ctx.dossiers.installations()) {
        Err(_) => Value::Null,
        Ok(o) if String::from_utf8_lossy(&o).trim().is_empty() => Value::Null,
        Ok(o) => match serde_json::from_slice::<Value>(&o) {
            Ok(Value::Object(m)) => Value::Object(
                m.iter()
                    .map(|(k, v)| {
                        (k.clone(), json!({ "dossier": cacher(&s(&v["dossier"]), &r), "gere": suite_commun::protocole_installateur::vrai_ps(&v["gere"]) }))
                    })
                    .collect(),
            ),
            Ok(v) => v,
            Err(_) => json!("abime"),
        },
    };
    // (PowerShell relit un fichier écrit comme un objet vide `{}` : le même objet)
    ecarts("fichier_apres", &c["fichier_apres"], &apres, &mut e);
    let suite: Map<String, Value> =
        ctx.donnees().suite().applis.into_iter().map(|(k, v)| (k, Value::String(cacher(&v, &r)))).collect();
    let attendu_suite = if c["suite"].is_null() { json!({}) } else { c["suite"].clone() };
    ecarts("suite", &attendu_suite, &Value::Object(suite), &mut e);
    let j: Vec<Value> = faux.donnees.lignes().iter().map(|l| Value::String(cacher(l, &r))).collect();
    ecarts("journal", &lignes(&c["journal"]), &Value::Array(j), &mut e);
    let _ = std::fs::remove_dir_all(&faux.racine);
    e
}

fn arguments(_: usize, c: &Value) -> Vec<String> {
    let mut e = Vec::new();
    match regles::argument_admin(&s(&c["valeur"])) {
        Ok(t) => {
            ecarts("resultat", &c["resultat"], &json!(t), &mut e);
            ecarts("erreur", &c["erreur"], &Value::Null, &mut e);
        }
        Err(m) => {
            ecarts("resultat", &c["resultat"], &Value::Null, &mut e);
            ecarts("erreur", &c["erreur"], &json!(m), &mut e);
        }
    }
    e
}

fn variables(_: usize, c: &Value) -> Vec<String> {
    let mut noms: Vec<String> = liste(&c["processus"]).iter().map(s).collect();
    noms.extend(liste(&c["compte"]).iter().map(s));
    let r = regles::refus_variables(&noms);
    let mut e = Vec::new();
    ecarts("message", &c["message"], &json!(r.as_ref().map(|x| x.1.clone()).unwrap_or_default()), &mut e);
    let j: Vec<Value> = r.iter().map(|x| json!(x.0)).collect();
    ecarts("journal", &lignes(&c["journal"]), &Value::Array(j), &mut e);
    e
}

fn raisons(_: usize, c: &Value) -> Vec<String> {
    let mut e = Vec::new();
    ecarts("raison", &c["raison"], &json!(regles::raison_echec_maj(&s(&c["nom"]), &s(&c["message"]))), &mut e);
    e
}

fn poser_run(poste: &FauxPoste, l: &Value) {
    for x in liste(l) {
        if x.is_null() {
            continue;
        }
        let v = if x.get("nombre").is_some_and(|n| !n.is_null()) { None } else { Some(s(&x["valeur"])) };
        poste.poser_run(&s(&x["nom"]), v.as_deref());
    }
}

fn run(i: usize, c: &Value) -> Vec<String> {
    let racine = mindset_noyau::dossier_essai(&nom_essai("run", i));
    let poste = FauxPoste::nouveau(&racine);
    poser_run(&poste, &c["entrees"]);
    let a = Appli { exe: s(&c["exe"]), ..Default::default() };
    let t: Vec<Value> =
        copies::demarrages_appli(&poste, &a).into_iter().map(|d| json!({ "nom": d.nom, "cible": d.cible })).collect();
    let mut e = Vec::new();
    ecarts("trouvees", &lignes(&c["trouvees"]), &Value::Array(t), &mut e);
    let _ = std::fs::remove_dir_all(&racine);
    e
}

fn demarrage(i: usize, c: &Value) -> Vec<String> {
    let admin = c["admin"].as_bool().unwrap_or(false);
    let (ctx, faux) =
        mindset_noyau::essai::contexte_avec(&nom_essai("demarrage", i), Lancement { admin, ..Default::default() });
    let r = r_de(&ctx);
    fichiers(&faux.racine, &c["fichiers"], &r);
    if !c["installations"].is_null() {
        std::fs::write(ctx.dossiers.installations(), json_fichier(&s(&c["installations"]), &r)).unwrap();
    }
    let poste = Arc::new(FauxPoste::nouveau(&faux.racine));
    poser_run(&poste, &c["run"]);
    for t in liste(&c["taches"]) {
        poste.poser_tache(&s(&t));
    }
    let mut b = BlocInstallations::pour_essai(poste);
    let a = appli(&c["appli"], &r);
    let v = b.demarrage_windows(&ctx, &a);
    let mut e = Vec::new();
    ecarts("resultat", &c["resultat"], &v.map(Value::Bool).unwrap_or(Value::Null), &mut e);
    let _ = std::fs::remove_dir_all(&faux.racine);
    e
}

fn paquets(_: usize, c: &Value) -> Vec<String> {
    let zip = base64(&s(&c["zip"]));
    let noms: Vec<String> = liste(&c["noms"]).iter().map(s).collect();
    let dz = telechargement::dossier_zip(&zip, &noms, &s(&c["exe"]));
    let mut e = Vec::new();
    ecarts("dossier_zip", &c["dossier_zip"], &json!(dz), &mut e);
    let err = telechargement::paquet_appli(&zip, &dz, &s(&c["appli"]), &s(&c["mindset"])).err();
    ecarts("erreur", &c["erreur"], &texte_ou_nul(err), &mut e);
    e
}

fn copie(i: usize, c: &Value) -> Vec<String> {
    let (ctx, faux) = mindset_noyau::essai::contexte(&nom_essai("copie", i));
    let r = r_de(&ctx);
    let poste = FauxPoste::nouveau(&faux.racine);
    let d = faux.racine.join(s(&c["sous"]));
    std::fs::create_dir_all(&d).unwrap();
    fichiers(&d, &c["arbre"], &r);
    fichiers(d.parent().unwrap(), &c["parent"], &r);
    fichiers(d.parent().unwrap(), &c["dehors"], &r);
    let zip = faux.racine.join("appli.zip");
    std::fs::write(&zip, base64(&s(&c["zip"]))).unwrap();
    let a = appli(&c["appli"], &r);
    let mut arg = d.to_string_lossy().into_owned();
    if c["barre"].as_bool() == Some(true) {
        arg.push('\\');
    }
    let m = copies::retirer_ancienne_copie(&ctx, &poste, &a, &arg, &zip.to_string_lossy(), &s(&c["dossier_zip"]));
    let mut e = Vec::new();
    ecarts("message", &c["message"], &json!(cacher(&m, &r)), &mut e);
    ecarts("existe", &c["existe"], &json!(d.exists()), &mut e);
    let rest: Vec<Value> = arbre(&d).into_iter().map(Value::String).collect();
    ecarts("restants", &lignes(&c["restants"]), &Value::Array(rest), &mut e);
    let feuille = d.file_name().unwrap().to_string_lossy().into_owned();
    let dehors: Vec<Value> = arbre(d.parent().unwrap())
        .into_iter()
        .filter(|x| {
            x != &format!("{feuille}\\") && !x.to_lowercase().starts_with(&format!("{}\\", feuille.to_lowercase()))
        })
        .map(Value::String)
        .collect();
    ecarts("dehors_restants", &lignes(&c["dehors_restants"]), &Value::Array(dehors), &mut e);
    let _ = std::fs::remove_dir_all(&faux.racine);
    e
}

fn desinstallation(i: usize, c: &Value) -> Vec<String> {
    let (ctx, faux) = mindset_noyau::essai::contexte(&nom_essai("desinstallation", i));
    let r = r_de(&ctx);
    fichiers(&ctx.dossiers.donnees_suite, &c["suite"], &r);
    let mut a = appli(&c["appli"], &r);
    if !c["nom_force"].is_null() {
        a.nom = s(&c["nom_force"]);
    }
    let (_, m) = copies::nettoyer_desinstallation(&ctx, &a);
    let mut e = Vec::new();
    ecarts("message", &c["message"], &json!(cacher(&m, &r)), &mut e);
    let j: Vec<Value> = faux.donnees.lignes().iter().map(|l| Value::String(cacher(l, &r))).collect();
    ecarts("journal", &lignes(&c["journal"]), &Value::Array(j), &mut e);
    let rest: Vec<Value> = arbre(&ctx.dossiers.donnees_suite)
        .into_iter()
        .filter(|x| x != "Mindset\\" && !x.starts_with("Mindset\\"))
        .map(Value::String)
        .collect();
    ecarts("restants", &lignes(&c["restants"]), &Value::Array(rest), &mut e);
    let _ = std::fs::remove_dir_all(&faux.racine);
    e
}

// -----------------------------------------------------------------------------------------------------------------
// La file du mini-installateur : un faux mini-installateur qui fait comme les faux de PowerShell
// -----------------------------------------------------------------------------------------------------------------

#[derive(Default)]
struct Scenario {
    etat: Mutex<Option<EtatTache>>,
    run_ok: Mutex<bool>,
    runas_ok: Mutex<bool>,
    valeurs: Mutex<std::collections::HashMap<String, String>>,
    ids: Mutex<Vec<String>>,
    taches: Mutex<Vec<String>>,
    retraits: Mutex<u32>,
    runas: Mutex<Vec<Direct>>,
    recu_tardif: Mutex<Option<String>>,
}

fn v<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap()
}

impl Installateur for Scenario {
    fn etat_tache(&self) -> EtatTache {
        v(&self.etat).unwrap_or(EtatTache::Absente)
    }
    fn deposer(&self, d: &Value) -> Result<(), String> {
        v(&self.taches).push(s(&d["Action"]));
        v(&self.ids).push(s(&d["Id"]));
        if *v(&self.run_ok) { Ok(()) } else { Err("la tâche d'installation n'a pas démarré (code 1)".into()) }
    }
    fn retirer_demande(&self) {
        *v(&self.retraits) += 1;
        if let Some(id) = v(&self.recu_tardif).take() {
            v(&self.valeurs).insert("Recu".into(), id);
        }
    }
    fn valeur(&self, nom: &str) -> String {
        v(&self.valeurs).get(nom).cloned().unwrap_or_default()
    }
    fn lancer_direct(&self, d: &Direct) -> Result<u32, String> {
        v(&self.runas).push(d.clone());
        if !*v(&self.runas_ok) {
            return Err("refusée".into());
        }
        Ok((v(&self.runas).len() - 1) as u32)
    }
    fn direct_fini(&self, _: u32) -> bool {
        true
    }
    fn compte_tache(&self, _: &str) -> Option<String> {
        None
    }
}

fn admin(i: usize, c: &Value) -> Vec<String> {
    let racine = mindset_noyau::dossier_essai(&nom_essai("admin", i));
    let _ = std::fs::remove_dir_all(&racine);
    let dossiers = mindset_noyau::Dossiers::sous(&racine);
    std::fs::create_dir_all(&dossiers.donnees).unwrap();
    let r = racine.to_string_lossy().into_owned();
    let debut = &c["debut"];
    let sc = Arc::new(Scenario::default());
    *v(&sc.etat) = Some(match s(&debut["tache"]).as_str() {
        "systeme" => EtatTache::Systeme,
        "ancienne" => EtatTache::Ancienne,
        _ => EtatTache::Absente,
    });
    *v(&sc.run_ok) = debut["run_ok"].as_bool().unwrap_or(true);
    *v(&sc.runas_ok) = debut["runas"].as_bool().unwrap_or(true);
    let donnees = Arc::new(mindset_noyau::donnees::DonneesMemoire::nouvelle(dossiers.clone()));
    let ports = Ports {
        donnees: donnees.clone(),
        reseau: Arc::new(mindset_noyau::reseau::FauxReseau::default()),
        installateur: sc.clone(),
        systeme: Arc::new(mindset_noyau::systeme::FauxSysteme::default()),
    };
    let lancement = Lancement { admin: debut["admin"].as_bool().unwrap_or(false), ..Default::default() };
    let ctx = Contexte::nouveau(dossiers, "3.0.0", lancement, true, ports, 4242);
    ctx.figer_heure(mindset_noyau::moment::lire_iso("2026-11-07T20:00:00").unwrap());
    let poste = Arc::new(FauxPoste::nouveau(&racine));
    let compte: Vec<String> = liste(&debut["compte"]).iter().map(s).collect();
    let compte: Vec<&str> = compte.iter().map(String::as_str).collect();
    poste.poser_variables(&[], &compte);
    let mut b = BlocInstallations::pour_essai(poste);
    let etapes = liste(&c["etapes"]);
    let sorties = liste(&c["sorties"]);
    let mut e = Vec::new();
    if etapes.len() != sorties.len() {
        e.push(format!("{} étapes pour {} sorties", etapes.len(), sorties.len()));
    }
    let mut journal_avant = 0;
    for (n, (et, so)) in etapes.iter().zip(sorties.iter()).enumerate() {
        let (t0, rt0, ra0) = (v(&sc.taches).len(), *v(&sc.retraits), v(&sc.runas).len());
        let mut effets = Effets::default();
        if let Some(a) = et.get("admin").filter(|a| !a.is_null()) {
            let mut p = Map::new();
            for x in liste(&a["parametres"]) {
                let x = liste(&x);
                p.insert(s(&x[0]), Value::String(s(&x[1]).replace("<R>", &r)));
            }
            let auto = a["auto"].as_bool().unwrap_or(false);
            b.signal(
                &ctx,
                "admin-demande",
                &json!({ "id": s(&a["nom"]), "action": s(&a["action"]), "parametres": p, "repli": !auto, "auto": auto }),
                &mut effets,
            );
        }
        if let Some(x) = et.get("avancer").and_then(Value::as_u64) {
            ctx.avancer(std::time::Duration::from_secs(x));
        }
        let id_de = |k: u64| v(&sc.ids).get(k as usize).cloned().unwrap_or_default();
        if let Some(k) = et.get("recu").and_then(Value::as_u64) {
            let id = id_de(k);
            v(&sc.valeurs).insert("Recu".into(), id);
        }
        if let Some(k) = et.get("recu_tardif").and_then(Value::as_u64) {
            *v(&sc.recu_tardif) = Some(id_de(k));
        }
        if let Some(x) = et.get("resultat").filter(|x| !x.is_null()) {
            let id = id_de(x["de"].as_u64().unwrap_or(0));
            let m = s(&x["message"]).replace("<R>", &r);
            v(&sc.valeurs).insert("Resultat".into(), json!({ "id": id, "ok": x["ok"], "message": m }).to_string());
        }
        if let Some(x) = et.get("resultat_brut").filter(|x| !x.is_null()) {
            let id = id_de(x["de"].as_u64().unwrap_or(0));
            v(&sc.valeurs).insert("Resultat".into(), s(&x["json"]).replace("<ID>", &id));
        }
        if et.get("resultat_autre").is_some_and(|x| x.as_bool() == Some(true)) {
            v(&sc.valeurs).insert(
                "Resultat".into(),
                r#"{"id":"00000000000000000000000000000000","ok":true,"message":"autre"}"#.into(),
            );
        }
        if let Some(x) = et.get("reponse_directe").filter(|x| !x.is_null()) {
            let k = x["de"].as_u64().unwrap_or(0) as usize;
            let f = v(&sc.runas)[k].resultat.clone();
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            std::fs::write(&f, json!({ "ok": x["ok"], "message": x["message"] }).to_string()).unwrap();
        }
        if et.get("tic").is_some_and(|x| x.as_bool() == Some(true)) {
            b.maj_attentes_admin(&ctx, &mut effets);
        }
        let taches: Vec<Value> = v(&sc.taches)[t0..].iter().map(|x| json!(x)).collect();
        ecarts(&format!("étape {n} taches"), &lignes(&so["taches"]), &Value::Array(taches), &mut e);
        ecarts(&format!("étape {n} retraits"), &so["retraits"], &json!(*v(&sc.retraits) - rt0), &mut e);
        let runas: Vec<Value> = v(&sc.runas)[ra0..]
            .iter()
            .map(|d| {
                let mut p: Vec<(String, String)> = d.parametres.clone();
                p.sort_by(|a, b| a.0.cmp(&b.0));
                let p: Vec<Value> = p
                    .into_iter()
                    .map(|(k, x)| json!([k, cacher(&regles::argument_admin(&x).unwrap_or_default(), &r)]))
                    .collect();
                json!({ "action": d.action, "parametres": p })
            })
            .collect();
        let attendu_runas: Vec<Value> = liste(&so["runas"])
            .into_iter()
            .map(|x| json!({ "action": x["action"], "parametres": liste(&x["parametres"]).into_iter().map(|p| Value::Array(liste(&p))).collect::<Vec<_>>() }))
            .collect();
        ecarts(&format!("étape {n} runas"), &Value::Array(attendu_runas), &Value::Array(runas), &mut e);
        let fins: Vec<Value> = effets
            .0
            .iter()
            .filter_map(|x| match x {
                Effet::Signal { nom, donnees } if nom == "admin-fini" => {
                    Some(json!([s(&donnees["id"]), donnees["ok"], cacher(&s(&donnees["message"]), &r)]))
                }
                _ => None,
            })
            .collect();
        let attendu_fins: Vec<Value> = liste(&so["fins"]).into_iter().map(|f| Value::Array(liste(&f))).collect();
        ecarts(&format!("étape {n} fins"), &Value::Array(attendu_fins), &Value::Array(fins), &mut e);
        let tout = donnees.lignes();
        let j: Vec<Value> = tout[journal_avant..].iter().map(|l| json!(cacher(l, &r))).collect();
        journal_avant = tout.len();
        ecarts(&format!("étape {n} journal"), &lignes(&so["journal"]), &Value::Array(j), &mut e);
    }
    ecarts("tache_ok", &c["tache_ok"], &b.tache_connue().map(Value::Bool).unwrap_or(Value::Null), &mut e);
    let _ = std::fs::remove_dir_all(&racine);
    e
}

// -----------------------------------------------------------------------------------------------------------------
// Les familles, leurs tests, et la contre-épreuve
// -----------------------------------------------------------------------------------------------------------------

type Rejouer = fn(usize, &Value) -> Vec<String>;

const FAMILLES: &[(&str, Rejouer)] = &[
    ("dossiers", dossiers),
    ("installations", installations),
    ("arguments", arguments),
    ("variables", variables),
    ("raisons", raisons),
    ("run", run),
    ("demarrage", demarrage),
    ("paquets", paquets),
    ("copie", copie),
    ("desinstallation", desinstallation),
    ("admin", admin),
];

fn rejouer(famille: &str, f: Rejouer, j: &Value) -> (usize, Vec<String>) {
    let mut tous = Vec::new();
    let l = cas(j);
    for (i, c) in l.iter().enumerate() {
        for e in f(i, c) {
            tous.push(format!("[{famille}] {} : {e}", s(&c["nom"])));
        }
    }
    (l.len(), tous)
}

fn famille(nom: &str) {
    let (_, f) = FAMILLES.iter().find(|(n, _)| *n == nom).unwrap();
    let (n, e) = rejouer(nom, *f, &juge(nom));
    assert!(n > 0, "aucun cas dans {nom}.json");
    assert!(e.is_empty(), "{} écart(s) sur {n} cas :\n{}", e.len(), e.join("\n"));
}

#[test]
fn juges_dossiers() {
    famille("dossiers");
}
#[test]
fn juges_installations() {
    famille("installations");
}
#[test]
fn juges_arguments() {
    famille("arguments");
}
#[test]
fn juges_variables() {
    famille("variables");
}
#[test]
fn juges_raisons() {
    famille("raisons");
}
#[test]
fn juges_run() {
    famille("run");
}
#[test]
fn juges_demarrage() {
    famille("demarrage");
}
#[test]
fn juges_paquets() {
    famille("paquets");
}
#[test]
fn juges_copie() {
    famille("copie");
}
#[test]
fn juges_desinstallation() {
    famille("desinstallation");
}
#[test]
fn juges_admin() {
    famille("admin");
}

/// Change la première sortie de texte (ou booléen) d'un cas : la comparaison doit le voir.
fn changer_un_octet(v: &mut Value, cles: &[&str]) -> bool {
    match v {
        Value::Object(m) => {
            for k in cles {
                if let Some(x) = m.get_mut(*k) {
                    match x {
                        Value::String(t) => {
                            t.push('#');
                            return true;
                        }
                        Value::Bool(b) => {
                            *b = !*b;
                            return true;
                        }
                        Value::Null => {
                            *x = json!("#");
                            return true;
                        }
                        Value::Array(a) if a.is_empty() => {
                            a.push(json!("#"));
                            return true;
                        }
                        _ => {
                            if changer_un_octet(x, &["message", "action", "0", "nom", "dossier"]) {
                                return true;
                            }
                        }
                    }
                }
            }
            false
        }
        Value::Array(a) => {
            for x in a.iter_mut() {
                if changer_un_octet(x, cles) {
                    return true;
                }
                if let Value::String(t) = x {
                    t.push('#');
                    return true;
                }
            }
            false
        }
        _ => false,
    }
}

#[test]
fn contre_epreuve_chaque_cas_change_echoue() {
    let sorties: &[(&str, &[&str])] = &[
        ("dossiers", &["version", "dossier_appli"]),
        ("installations", &["installation", "journal"]),
        ("arguments", &["resultat", "erreur"]),
        ("variables", &["message"]),
        ("raisons", &["raison"]),
        ("run", &["trouvees"]),
        ("demarrage", &["resultat"]),
        ("paquets", &["dossier_zip"]),
        ("copie", &["message"]),
        ("desinstallation", &["message"]),
        ("admin", &["tache_ok"]),
    ];
    for (nom, cles) in sorties {
        let (_, f) = FAMILLES.iter().find(|(n, _)| n == nom).unwrap();
        let j = juge(nom);
        for (i, c) in cas(&j).iter().enumerate() {
            let mut c2 = c.clone();
            assert!(changer_un_octet(&mut c2, cles), "[{nom}] {} : rien à changer", s(&c["nom"]));
            let e = f(1000 + i, &c2);
            assert!(!e.is_empty(), "[{nom}] {} : le juge changé passe encore", s(&c["nom"]));
        }
    }
}

/// Le fichier du juge lui-même, changé d'un octet (dans une sortie), ne passe plus.
#[test]
fn contre_epreuve_un_octet_du_fichier() {
    let f = Path::new(env!("CARGO_MANIFEST_DIR")).join(r"tests\juges\raisons.json");
    let t = std::fs::read_to_string(f).unwrap();
    let i = t.find("Internet a coupé").unwrap();
    let mut o = t.into_bytes();
    o[i] = b'J';
    let j: Value = serde_json::from_slice(&o).unwrap();
    let (_, e) = rejouer("raisons", raisons, &j);
    assert!(!e.is_empty());
}
