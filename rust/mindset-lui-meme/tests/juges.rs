//! Les juges exportés depuis la version PowerShell (outils\exporter-juges-lui-meme.ps1 : les vraies fonctions de
//! mindset.ps1 et de Mindset.ps1, avec des entrées inventées) : la version Rust doit donner exactement la même chose.
//! Chaque juge est rejoué par une fonction qui rend la liste des différences ; la contre-épreuve vérifie qu'un juge
//! changé d'un caractère est bien refusé.

use mindset_lui_meme::bascule::{self, PcBascule};
use mindset_lui_meme::pc::FauxPc;
use mindset_lui_meme::regles::{self, Essai, Volume};
use mindset_lui_meme::{Echec, LuiMeme, MajPrete, historique, maj};
use mindset_noyau::donnees::Dossiers;
use mindset_noyau::essai::{self, Faux};
use mindset_noyau::reseau::ReponseHttp;
use mindset_noyau::{Appli, Bloc, Contexte, Effet, Effets, Lancement, Ports, Vue, moment, partage};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

// ---------------------------------------------------------------------------------------------------------------
// Outils
// ---------------------------------------------------------------------------------------------------------------

fn juge_texte(nom: &str) -> String {
    let f = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(format!("{nom}.json"));
    std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{}: {e}", f.display()))
}

fn lire_juge(t: &str) -> Value {
    serde_json::from_str(t.trim_start_matches('\u{feff}')).expect("juge illisible")
}

fn cas(v: &Value) -> Vec<Value> {
    match v {
        Value::Array(a) => a.clone(),
        autre => vec![autre.clone()],
    }
}

fn juge(nom: &str) -> Vec<Value> {
    let l = cas(&lire_juge(&juge_texte(nom)));
    if nom != "maj-auto" {
        return l;
    }
    // Écart voulu avec la version PowerShell (décision de Jordan du 07/11/2026) : un jeu ouvert n'arrête plus les
    // mises à jour automatiques. Les cas « pendant un jeu » du juge ne sont plus rejoués ; c'est
    // maj_auto_meme_pendant_un_jeu qui vérifie le contraire.
    l.into_iter().filter(|c| s(&c["scenario"]["jeu"]).is_empty()).collect()
}

/// Un texte du juge (null : « »).
fn s(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(t) => t.clone(),
        autre => autre.to_string(),
    }
}

fn b(v: &Value) -> bool {
    v.as_bool().unwrap_or(false)
}

fn ecart(e: &mut Vec<String>, i: usize, quoi: &str, attendu: &Value, obtenu: &Value) {
    if attendu != obtenu {
        e.push(format!("cas {i} ({quoi}) : attendu {attendu}, obtenu {obtenu}"));
    }
}

fn verifier(nom: &str, e: Vec<String>) {
    assert!(e.is_empty(), "juge {nom} : {} différence(s)\n{}", e.len(), e[..e.len().min(12)].join("\n"));
}

/// Le dossier d'essai d'un cas, effacé à la fin du cas.
struct Menage(PathBuf);
impl Drop for Menage {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Un nom de dossier d'essai à part pour chaque cas (les tests tournent en parallèle).
fn unique(base: &str) -> String {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static N: AtomicUsize = AtomicUsize::new(0);
    format!("{base}-{}", N.fetch_add(1, Ordering::Relaxed))
}

fn publier(ctx: &Contexte, bloc: &'static str, cle: &str, v: Value) {
    ctx.au_nom_de(bloc, || ctx.publier(cle, v));
}

fn signaux(e: &Effets, nom: &str) -> Vec<Value> {
    e.0.iter()
        .filter_map(|x| match x {
            Effet::Signal { nom: n, donnees } if n == nom => Some(donnees.clone()),
            _ => None,
        })
        .collect()
}

fn quitte(e: &Effets) -> bool {
    e.0.iter().any(|x| matches!(x, Effet::Quitter { .. }))
}

fn journal(f: &Faux) -> Value {
    json!(f.donnees.lignes())
}

/// Les bulles demandées (titre et texte), comme les a reçues `Show-BulleMajAuto` (son texte par défaut retiré).
fn bulles(e: &Effets) -> Value {
    json!(
        signaux(e, "bulle")
            .iter()
            .map(|d| {
                let t = s(&d["texte"]);
                json!({ "titre": d["titre"], "texte": if t == "Mise à jour faite toute seule." { String::new() } else { t } })
            })
            .collect::<Vec<_>>()
    )
}

fn echec_json(bloc: &LuiMeme, id: &str) -> Value {
    bloc.echecs().get(id).map_or(Value::Null, |e| json!({ "version": e.version, "raison": e.raison }))
}

fn bandeau(bloc: &LuiMeme) -> Value {
    let b = bloc.bandeau();
    json!({ "visible": b.visible, "titre": b.titre, "texte": b.texte, "bouton_maj": b.bouton_maj, "bouton_fermer": b.bouton_fermer })
}

/// Un contexte d'essai dont les dossiers sont changés.
fn contexte_dossiers(nom: &str, lancement: Lancement, changer: impl FnOnce(&mut Dossiers)) -> (Contexte, Faux) {
    let (ctx, f) = essai::contexte_avec(nom, lancement.clone());
    let mut d = ctx.dossiers.clone();
    changer(&mut d);
    let ports = Ports {
        donnees: f.donnees.clone(),
        reseau: f.reseau.clone(),
        installateur: f.installateur.clone(),
        systeme: f.systeme.clone(),
    };
    let c = Contexte::nouveau(d, "3.0.0", lancement, true, ports, 4242);
    c.figer_heure(moment::lire_iso(essai::HEURE_ESSAI).unwrap());
    (c, f)
}

fn appli(id: &str, nom: &str) -> Appli {
    Appli { id: id.into(), nom: nom.into(), ..Default::default() }
}

fn essai_de(v: &Value, maintenant_ms: u64) -> Option<Essai> {
    if v.is_null() {
        return None;
    }
    let minutes = v["minutes"].as_f64().unwrap_or(0.0);
    Some(Essai {
        version: s(&v["version"]),
        quand_ms: maintenant_ms - (minutes * 60_000.0).round() as u64,
        nombre: v["nombre"].as_u64().unwrap_or(1) as u32,
    })
}

// ---------------------------------------------------------------------------------------------------------------
// Les rejeux
// ---------------------------------------------------------------------------------------------------------------

fn rejouer_raisons(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let r = regles::raison_echec_maj(&s(&c["nom"]), &s(&c["message"]));
        ecart(&mut e, i, &format!("raison de « {} »", s(&c["message"])), &c["attendu"], &json!(r));
    }
    e
}

fn rejouer_noms(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let x = s(&c["entree"]);
        let r = if c["quoi"] == "de" { regles::format_de_nom(&x) } else { regles::nom_raison_jeu(&x) };
        ecart(&mut e, i, &x, &c["attendu"], &json!(r));
    }
    e
}

fn rejouer_entrees(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let x: Value = serde_json::from_str(&s(&c["texte"])).unwrap_or(Value::Null);
        let r = regles::entree_maj(&x).map_or(Value::Null, |x| x.en_json());
        ecart(&mut e, i, &s(&c["texte"]).chars().take(80).collect::<String>(), &c["attendu"], &r);
    }
    e
}

fn rejouer_quand(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let m = moment::lire_iso(&s(&c["maintenant"])).unwrap();
        let r = regles::format_quand_maj(&s(&c["quand"]), &m, b(&c["long"]));
        ecart(&mut e, i, &s(&c["quand"]), &c["attendu"], &json!(r));
    }
    e
}

fn rejouer_reessai(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let mut essais: std::collections::BTreeMap<String, Essai> = Default::default();
        for (k, x) in cas(&c["etapes"]).iter().enumerate() {
            let ms = (x["minutes"].as_f64().unwrap() * 60_000.0).round() as u64;
            let id = s(&x["id"]);
            let v = s(&x["version"]);
            if x["op"] == "ajouter" {
                let n = regles::essai_suivant(essais.get(&id), &v, ms);
                essais.insert(id, n);
            } else {
                let r = regles::reessai(essais.get(&id), &v, ms);
                ecart(&mut e, i, &format!("étape {k}"), &x["attendu"], &json!(r));
            }
        }
    }
    e
}

fn rejouer_historique(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    let base = moment::lire_iso("2026-11-07T20:00:00").unwrap();
    for (i, c) in l.iter().enumerate() {
        let (mut ctx, f) = essai::contexte(&unique("juge-historique"));
        let _menage = Menage(f.racine.clone());
        ctx.version = s(&c["version"]);
        let fichier = historique::fichier(&ctx);
        if let Some(t) = c["texte"].as_str() {
            std::fs::write(&fichier, t).unwrap();
        }
        let mut dernieres = Vec::new();
        for x in cas(&c["etapes"]) {
            let minutes = x["minutes"].as_i64().unwrap_or(0);
            ctx.figer_heure(moment::ajouter(&base, minutes * 60));
            match x["op"].as_str() {
                Some("ajouter") => historique::ajouter(
                    &ctx,
                    &s(&x["id"]),
                    &s(&x["nom"]),
                    &s(&x["version"]),
                    b(&x["auto"]),
                    &s(&x["notes"]),
                ),
                Some("attendre") => {
                    historique::attendre_mindset(&ctx, &s(&x["version"]), b(&x["auto"]), &s(&x["notes"]))
                }
                Some("resoudre") => historique::resoudre_mindset(&ctx),
                Some("derniere") => {
                    let h = historique::lire(&ctx);
                    dernieres.push(regles::derniere_maj(&h.liste, &ctx.heure()).map_or(Value::Null, |x| x.en_json()));
                }
                _ => {}
            }
        }
        let nom = format!("{} / {} / {}", s(&c["depart"]), s(&c["suite"]), s(&c["version"]));
        ecart(&mut e, i, &format!("{nom} : dernières"), &c["dernieres"], &json!(dernieres));
        let lu = std::fs::read_to_string(&fichier).ok();
        let obtenu = match &lu {
            None => Value::Null,
            Some(t) => serde_json::from_str::<Value>(t).unwrap_or_else(|_| json!({ "texte_brut": t })),
        };
        // (le faux disque des tests ne met pas de côté un fichier abîmé, le vrai port le fait : PowerShell le voit
        // disparaître, ici il reste tel quel)
        let abime_garde = c["fichier"].is_null() && lu.as_deref() == c["texte"].as_str();
        // (ConvertTo-Json de PowerShell écrit un tableau relu comme { value, Count })
        let attendu = match c["fichier"].as_object() {
            Some(m) if m.len() == 2 && m.contains_key("value") && m.contains_key("Count") => m["value"].clone(),
            _ => c["fichier"].clone(),
        };
        if !abime_garde {
            ecart(&mut e, i, &format!("{nom} : fichier"), &attendu, &obtenu);
        }
        let j: Vec<String> = f.donnees.lignes().into_iter().filter(|x| x.starts_with("Historique")).collect();
        ecart(&mut e, i, &format!("{nom} : journal"), &c["journal"], &json!(j));
    }
    e
}

fn rejouer_disques(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let v: Vec<Volume> = cas(&c["volumes"])
            .iter()
            .map(|x| Volume {
                lettre: s(&x["lettre"]),
                systeme_fichiers: s(&x["systeme_fichiers"]),
                libre: x["libre"].as_f64().map(|n| n as u64),
            })
            .collect();
        let r: Vec<Value> = regles::disques(&v, &s(&c["systeme"]))
            .iter()
            .map(|d| json!({ "lettre": d.lettre, "texte": d.texte, "libre": d.libre }))
            .collect();
        ecart(&mut e, i, "disques", &c["attendu"], &json!(r));
    }
    e
}

fn rejouer_bulles(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let (ctx, f) = essai::contexte(&unique("juge-bulles"));
        let _menage = Menage(f.racine.clone());
        ctx.avancer(Duration::from_secs(36_000));
        let maintenant = 36_000_000;
        let id = s(&c["id"]);
        let v = s(&c["version"]);
        ctx.definir_applis(vec![appli(&id, &s(&c["nom"]))]);
        publier(
            &ctx,
            "publications",
            partage::PUBLICATIONS,
            json!({ id.clone(): { "version": v, "notes": c["notes"] } }),
        );
        let mut bloc = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine))).tout_en_essai();
        bloc.poser_demarre();
        bloc.poser_maj_auto(&id, &v);
        if let Some(x) = essai_de(&c["essai"], maintenant) {
            bloc.poser_essai(&id, x);
        }
        if b(&c["echec_avant"]) {
            bloc.poser_echec(&id, Echec { version: v.clone(), raison: "avant".into() });
        }
        let mut ef = Effets::default();
        let d = json!({ "id": id, "quoi": "installation", "ok": true, "message": c["message"], "auto": true });
        ctx.au_nom_de("lui-meme", || bloc.signal(&ctx, "operation-finie", &d, &mut ef));
        let mut attendues = c["bulles"].clone();
        if !c["erreur"].is_null() {
            // Défaut de la version PowerShell (DIVERGENCES.md) : des notes vides la faisaient planter avant la bulle ;
            // ici la bulle part, avec le texte par défaut
            attendues = json!([{ "titre": format!("{} est passé en {v}", s(&c["nom"])), "texte": "" }]);
            let mut j = c["journal"].as_array().cloned().unwrap_or_default();
            j.push(json!(format!("Mise à jour automatique : {} est passé en {v}", s(&c["nom"]))));
            ecart(&mut e, i, "journal", &json!(j), &journal(&f));
        } else {
            ecart(&mut e, i, "journal", &c["journal"], &journal(&f));
        }
        ecart(&mut e, i, "bulles", &attendues, &bulles(&ef));
        ecart(&mut e, i, "échec", &c["echec"], &echec_json(&bloc, &id));
    }
    e
}

fn rejouer_maj_auto(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let sc = &c["scenario"];
        let (ctx, f) =
            essai::contexte_avec(&unique("juge-maj-auto"), Lancement { admin: b(&sc["admin"]), ..Default::default() });
        let _menage = Menage(f.racine.clone());
        ctx.avancer(Duration::from_secs(36_000));
        let maintenant: u64 = 36_000_000;
        if !sc["maj_auto"].is_null() {
            ctx.ecrire_reglage("MajAuto", sc["maj_auto"].clone());
        }
        if !sc["verif"].is_null() {
            ctx.ecrire_reglage("VerifVersions", sc["verif"].clone());
        }
        let applis = cas(&sc["applis"]);
        ctx.definir_applis(applis.iter().map(|a| appli(&s(&a["id"]), &s(&a["nom"]))).collect());
        let mut inst = Map::new();
        let mut pubs = Map::new();
        let mut ouvertes = Map::new();
        for a in &applis {
            let id = s(&a["id"]);
            inst.insert(id.clone(), json!({ "dossier": "x", "gere": a["gere"], "version": a["installee"] }));
            if !a["pub"].is_null() {
                pubs.insert(id.clone(), json!({ "version": a["pub"] }));
            }
            ouvertes.insert(id, a["ouverte"].clone());
        }
        publier(&ctx, "installations", partage::INSTALLATIONS, Value::Object(inst));
        publier(&ctx, "publications", partage::PUBLICATIONS, Value::Object(pubs));
        publier(&ctx, "liste", partage::OUVERTES, Value::Object(ouvertes));
        let occ = if b(&sc["occupe"]) { json!({ "autre": { "texte": "Installation..." } }) } else { json!({}) };
        publier(&ctx, "installations", partage::OCCUPATIONS, occ);
        let tache = if b(&sc["tache"]) { "systeme" } else { "absente" };
        let en_cours = if b(&sc["attentes_admin"]) { 1 } else { 0 };
        publier(&ctx, "installations", partage::ADMIN, json!({ "tache": tache, "en_cours": en_cours }));
        ctx.definir_vue(Vue { visible: b(&sc["visible"]), reduite: b(&sc["reduite"]), page: "accueil".into() });
        let pc = Arc::new(FauxPc::sous(&f.racine));
        match s(&sc["jeu"]).as_str() {
            "une fenêtre en plein écran (jeu ou vidéo)" => pc.poser_plein_ecran(true),
            "une manette utilisée il y a moins de 5 minutes" => pc.poser_manette(10.0),
            "un jeu ouvert (Jeu Essai)" => {
                let j = r"C:\Jeux\steamapps\common\Essai\jeu.exe";
                f.systeme.ajouter_processus(9001, j, 1);
                pc.programmes.lock().unwrap().insert(j.into(), (Some("Jeu Essai".into()), None));
            }
            _ => {}
        }
        match &sc["inactif"] {
            Value::String(_) => pc.poser_inactif(Err("relevé impossible".into())),
            n => pc.poser_inactif(Ok(n.as_f64().unwrap_or(0.0))),
        }
        let mut bloc = LuiMeme::neuf().avec_pc(pc.clone()).tout_en_essai();
        bloc.poser_demarre();
        bloc.poser_passage(sc["derniere"].as_u64().map(|x| maintenant - x * 1000));
        if b(&sc["deja"]) {
            bloc.poser_maj_auto("autre", "1.0.0");
        }
        bloc.poser_jeu_note(sc["jeu_note"].as_str());
        for a in &applis {
            if let Some(x) = essai_de(&a["essai"], maintenant) {
                bloc.poser_essai(&s(&a["id"]), x);
            }
        }
        if !sc["mindset"].is_null() {
            let m = &sc["mindset"];
            bloc.poser_maj_prete(Some(MajPrete {
                version: s(&m["version"]),
                zip: "Z".into(),
                sig: "S".into(),
                notes: String::new(),
            }));
            bloc.poser_recherche(b(&m["en_cours"]));
            if let Some(x) = essai_de(&m["essai"], maintenant) {
                bloc.poser_essai("mindset", x);
            }
        }
        let mut ef = Effets::default();
        ctx.au_nom_de("lui-meme", || bloc.tic(&ctx, &mut ef));
        let mut actions = Vec::new();
        for x in &ef.0 {
            if let Effet::Signal { nom, donnees } = x {
                if nom == "installer" {
                    actions.push(json!({ "quoi": "installer", "id": donnees["id"] }));
                } else if nom == "admin-demande" && donnees["action"] == "mindset-maj" {
                    actions.push(json!({ "quoi": "mindset", "auto": donnees["auto"],
                        "cache": donnees["parametres"].get("Cache").is_some() }));
                }
            }
        }
        ecart(&mut e, i, "actions", &c["actions"], &json!(actions));
        ecart(&mut e, i, "attentes", &c["attentes"], &json!(bloc.attentes()));
        ecart(&mut e, i, "jeu", &c["jeu"], &json!(bloc.jeu()));
        let essais: Map<String, Value> = bloc
            .essais()
            .iter()
            .map(|(k, x)| (k.clone(), json!({ "version": x.version, "nombre": x.nombre })))
            .collect();
        // (une version absente du scénario est « » ici : même effet, Get-MajAutoReessai compare des textes)
        let mut attendus = c["essais"].clone();
        if let Some(m) = attendus.as_object_mut() {
            for x in m.values_mut() {
                if x["version"].is_null() {
                    x["version"] = json!("");
                }
            }
        }
        ecart(&mut e, i, "essais", &attendus, &Value::Object(essais));
        ecart(&mut e, i, "en cours", &c["en_cours"], &json!(bloc.en_cours_auto()));
        ecart(&mut e, i, "journal", &c["journal"], &journal(&f));
    }
    e
}

fn rejouer_maj_mindset(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let sc = &c["scenario"];
        let (ctx, f) = essai::contexte_avec(
            &unique("juge-maj-mindset"),
            Lancement { admin: b(&sc["admin"]), ..Default::default() },
        );
        let _menage = Menage(f.racine.clone());
        ctx.avancer(Duration::from_secs(36_000));
        let maintenant: u64 = 36_000_000;
        let tache = if b(&sc["tache"]) { "systeme" } else { "absente" };
        publier(&ctx, "installations", partage::ADMIN, json!({ "tache": tache, "en_cours": 0 }));
        if b(&sc["occupe"]) {
            publier(&ctx, "installations", partage::OCCUPATIONS, json!({ "evermind": { "texte": "Installation..." } }));
        }
        let mut bloc = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine))).tout_en_essai();
        bloc.poser_demarre();
        if b(&sc["prete"]) {
            bloc.poser_maj_prete(Some(MajPrete {
                version: "3.1.0".into(),
                zip: r"C:\T\mindset.zip".into(),
                sig: r"C:\T\mindset.zip.sig".into(),
                notes: "- Nouveautés".into(),
            }));
        }
        bloc.poser_maj_envoyee(b(&sc["envoyee"]));
        if b(&sc["echec"]) {
            bloc.poser_echec("mindset", Echec { version: "3.1.0".into(), raison: "avant".into() });
        }
        if let Some(x) = essai_de(&sc["essai"], maintenant) {
            bloc.poser_essai("mindset", x);
        }
        let fm = maj::fichier_maj(&ctx);
        std::fs::create_dir_all(fm.parent().unwrap()).unwrap();
        std::fs::write(&fm, "{}").unwrap();
        let mut ef = Effets::default();
        ctx.au_nom_de("lui-meme", || bloc.lancer_maj(&ctx, b(&sc["cache"]), b(&sc["auto"]), &mut ef));
        let destination = ctx.dossiers.mindset_installe().to_string_lossy().into_owned();
        // La demande passe toujours par la file du bloc « installations ». Par la tâche (paramètre Id = son id) : le
        // contenu de Send-DemandeInstallation. Sans elle : la demande de Windows, que fait le bloc « installations »
        // (le faux Start-MajMindsetDirecte du juge) ; de même pour le repli (pas automatique : repli vrai).
        let mut demande = Value::Null;
        let mut directes = 0u64;
        let mut attente_windows = false;
        if let Some(d) = signaux(&ef, "admin-demande").first() {
            let id = s(&d["id"]);
            let par_tache = d["parametres"].get("Id").is_some();
            if d["resultat"] != json!(fm.to_string_lossy()) {
                e.push(format!("cas {i} : la réponse de la demande de Windows n'est pas maj-mindset.json"));
            }
            if d["repli"] != json!(!b(&d["auto"])) {
                e.push(format!("cas {i} : repli {} pour auto {}", d["repli"], d["auto"]));
            }
            if !par_tache {
                directes = 1;
                attente_windows = true;
                if d["parametres"].get("Cache").is_some() || d["parametres"].get("Sid").is_none() {
                    e.push(format!("cas {i} : la demande de Windows a Cache ou n'a pas Sid"));
                }
            } else {
                if s(&d["parametres"]["Id"]) != id {
                    e.push(format!("cas {i} : l'Id de la demande n'est pas celui du bloc"));
                }
                let mut p: Map<String, Value> = Map::new();
                let mut cles: Vec<(String, Value)> = d["parametres"].as_object().unwrap().clone().into_iter().collect();
                cles.push(("Action".into(), d["action"].clone()));
                cles.sort_by_key(|a| a.0.to_lowercase());
                for (k, v) in cles {
                    let v = match k.as_str() {
                        "Id" => continue,
                        "AttendrePid" => json!("PID"),
                        "Destination" if s(&v) == destination => json!("DOSSIER"),
                        _ => v,
                    };
                    p.insert(k, v);
                }
                demande = json!({ "contenu": Value::Object(p), "auto": d["auto"] });
                let mut ef2 = Effets::default();
                match s(&sc["fin"]).as_str() {
                    "recu" => {
                        ctx.au_nom_de("lui-meme", || bloc.signal(&ctx, "admin-recu", &json!({ "id": id }), &mut ef2))
                    }
                    "ok" => {
                        let d = json!({ "id": id, "ok": true, "message": "Mindset 3.1.0 est installé." });
                        ctx.au_nom_de("lui-meme", || bloc.signal(&ctx, "admin-fini", &d, &mut ef2));
                    }
                    "ko" => {
                        let d = json!({ "id": id, "ok": false, "message": sc["message"] });
                        ctx.au_nom_de("lui-meme", || bloc.signal(&ctx, "admin-fini", &d, &mut ef2));
                    }
                    _ if b(&d["repli"]) => {
                        // (le bloc « installations » fait lui-même la demande de Windows)
                        directes = 1;
                        attente_windows = true;
                    }
                    _ => {
                        let d = json!({ "id": id, "ok": false,
                            "message": "la tâche d'installation ne répond pas (pas de réponse de la tâche en 30 secondes)." });
                        ctx.au_nom_de("lui-meme", || bloc.signal(&ctx, "admin-fini", &d, &mut ef2));
                    }
                }
                ef.0.extend(ef2.0);
            }
        }
        ecart(&mut e, i, "demande", &c["demande"], &demande);
        ecart(&mut e, i, "directes", &c["directes"], &json!(directes));
        if !f.installateur.directs().is_empty() {
            e.push(format!("cas {i} : demande de Windows faite par ce bloc au lieu de la file"));
        }
        ecart(&mut e, i, "texte", &c["texte"], &json!(bloc.bandeau().texte));
        let r = f.donnees.reglages();
        ecart(
            &mut e,
            i,
            "MajMindsetVisible",
            &c["visible_reglage"],
            r.get("MajMindsetVisible").unwrap_or(&Value::Null),
        );
        let dr = if r.contains_key("MajMindsetDemande") { json!("ID") } else { Value::Null };
        ecart(&mut e, i, "MajMindsetDemande", &c["demande_reglage"], &dr);
        let h = historique::lire(&ctx);
        let att = match h.attendue {
            Some(a) => json!([{ "version": a.version, "auto": a.auto, "notes": a.notes }]),
            None => json!([]),
        };
        ecart(&mut e, i, "attendue", &c["attendues"], &att);
        // (en attendant la demande de Windows faite par le bloc « installations », la demande reste envoyée : un
        // deuxième clic ne la refait pas)
        let envoyee = if attente_windows { json!(true) } else { c["envoyee"].clone() };
        ecart(&mut e, i, "envoyée", &envoyee, &json!(bloc.maj_envoyee()));
        ecart(&mut e, i, "fichier", &c["fichier_maj"], &json!(fm.exists()));
        ecart(&mut e, i, "sortie", &c["sortie"], &json!(quitte(&ef)));
        ecart(&mut e, i, "échec", &c["echec"], &echec_json(&bloc, "mindset"));
        ecart(&mut e, i, "bulles", &c["bulles"], &bulles(&ef));
        ecart(&mut e, i, "journal", &c["journal"], &journal(&f));
    }
    e
}

fn rejouer_maj_directe(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let (ctx, f) = essai::contexte(&unique("juge-maj-directe"));
        let _menage = Menage(f.racine.clone());
        let pc = Arc::new(FauxPc::sous(&f.racine));
        *pc.sid.lock().unwrap() = "SID".into();
        let mut bloc = LuiMeme::neuf().avec_pc(pc).tout_en_essai();
        if b(&c["prete"]) {
            bloc.poser_maj_prete(Some(MajPrete {
                version: "3.1.0".into(),
                zip: s(&c["zip"]),
                sig: r"C:\T\mindset.zip.sig".into(),
                notes: String::new(),
            }));
        }
        if b(&c["refus"]) {
            f.installateur.refuser_direct(Some("l'autorisation de Windows a été refusée."));
        }
        let mut ef = Effets::default();
        ctx.au_nom_de("lui-meme", || bloc.lancer_maj_directe(&ctx, &mut ef));
        let destination = ctx.dossiers.mindset_installe().to_string_lossy().into_owned();
        let p = f.installateur.directs().first().map_or(Value::Null, |d| {
            json!(
                d.parametres
                    .iter()
                    .map(|(n, v)| {
                        let v = match n.as_str() {
                            "AttendrePid" => "PID".to_string(),
                            "Destination" if *v == destination => "DOSSIER".to_string(),
                            _ => v.clone(),
                        };
                        json!([n, v])
                    })
                    .collect::<Vec<_>>()
            )
        });
        ecart(&mut e, i, "paramètres", &c["parametres"], &p);
        ecart(&mut e, i, "texte", &c["texte"], &json!(bloc.bandeau().texte));
        ecart(&mut e, i, "sortie", &c["sortie"], &json!(quitte(&ef)));
        ecart(&mut e, i, "journal", &c["journal"], &journal(&f));
    }
    e
}

fn rejouer_resultat(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let sc = &c["scenario"];
        let (mut ctx, f) = essai::contexte(&unique("juge-resultat"));
        let _menage = Menage(f.racine.clone());
        ctx.version = s(&sc["version"]);
        match sc["demande"].as_str() {
            Some("ID") => ctx.ecrire_reglage("MajMindsetDemande", json!("0123456789abcdef0123456789abcdef")),
            Some(x) => ctx.ecrire_reglage("MajMindsetDemande", json!(x)),
            None => {}
        }
        if !sc["visible"].is_null() {
            ctx.ecrire_reglage("MajMindsetVisible", sc["visible"].clone());
        }
        f.installateur.poser_valeur("Resultat", &s(&c["resultat_valeur"]));
        f.installateur.poser_valeur("Restes", &s(&sc["restes"]));
        let tel = ctx.dossiers.telechargements();
        std::fs::create_dir_all(&tel).unwrap();
        if let Some(t) = sc["fichier"].as_str() {
            std::fs::write(maj::fichier_maj(&ctx), t).unwrap();
        }
        if b(&sc["zips"]) {
            for n in ["mindset.zip", "mindset.zip.sig", "mindset.zip.nouveau", "mindset.zip.nouveau.sig"] {
                std::fs::write(tel.join(n), "x").unwrap();
            }
        }
        let mut bloc = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine))).tout_en_essai();
        ctx.au_nom_de("lui-meme", || bloc.resultat_maj(&ctx));
        ecart(&mut e, i, "bandeau", &c["bandeau"], &bandeau(&bloc));
        let r = f.donnees.reglages();
        ecart(&mut e, i, "MajMindsetDemande", &c["demande_apres"], r.get("MajMindsetDemande").unwrap_or(&Value::Null));
        ecart(&mut e, i, "MajMindsetVisible", &c["visible_apres"], r.get("MajMindsetVisible").unwrap_or(&Value::Null));
        ecart(&mut e, i, "retraits", &c["retraits"], &json!(f.installateur.retraits()));
        let mut restants: Vec<String> =
            std::fs::read_dir(&tel).unwrap().flatten().map(|x| x.file_name().to_string_lossy().into_owned()).collect();
        restants.sort_by_key(|x| x.to_lowercase());
        ecart(&mut e, i, "restants", &c["restants"], &json!(restants));
        ecart(&mut e, i, "journal", &c["journal"], &journal(&f));
    }
    e
}

fn rejouer_verif(j: &Value) -> Vec<String> {
    use base64_lite::decoder;
    let mut e = Vec::new();
    let zip = decoder(&s(&j["zip"]));
    let sig_bonne = decoder(&s(&j["sig_bonne"]));
    let sig_fausse = decoder(&s(&j["sig_fausse"]));
    for (i, c) in cas(&j["cas"]).iter().enumerate() {
        let (ctx, f) = essai::contexte(&unique("juge-verif"));
        let _menage = Menage(f.racine.clone());
        let cles = ctx.dossiers.fichiers.join("cles-publiques");
        std::fs::create_dir_all(&cles).unwrap();
        std::fs::write(cles.join("essai.xml"), s(&j["cle"])).unwrap();
        let tel = ctx.dossiers.telechargements();
        std::fs::create_dir_all(&tel).unwrap();
        let mut bloc = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine))).tout_en_essai();
        bloc.poser_demarre();
        if let Some(p) = c["prete_avant"].as_str() {
            std::fs::write(tel.join("mindset.zip"), format!("zip {p}")).unwrap();
            std::fs::write(tel.join("mindset.zip.sig"), format!("sig {p}")).unwrap();
            bloc.poser_maj_prete(Some(MajPrete {
                version: p.into(),
                zip: tel.join("mindset.zip").to_string_lossy().into(),
                sig: tel.join("mindset.zip.sig").to_string_lossy().into(),
                notes: "ancienne".into(),
            }));
        }
        publier(&ctx, "publications", partage::PUBLICATIONS, json!({ "mindset": c["publication"] }));
        if c["zip"] == "bon" {
            f.reseau.repondre("https://github.com/z", Ok(ReponseHttp::ok(zip.clone())));
        } else {
            f.reseau.repondre("https://github.com/z", Err("Impossible de se connecter au serveur distant".into()));
        }
        match s(&c["signature"]).as_str() {
            "bonne" => f.reseau.repondre("https://github.com/s", Ok(ReponseHttp::ok(sig_bonne.clone()))),
            "fausse" => f.reseau.repondre("https://github.com/s", Ok(ReponseHttp::ok(sig_fausse.clone()))),
            _ => f.reseau.repondre("https://github.com/s", Err("Adresse inconnue : https://github.com/s".into())),
        }
        let mut ef = Effets::default();
        ctx.au_nom_de("lui-meme", || bloc.signal(&ctx, "verifier-mindset", &json!({}), &mut ef));
        for x in std::mem::take(&mut ef.0) {
            if let Effet::Tache(t) = x {
                let id = t.id.clone();
                let r = t.lancer();
                let mut ef2 = Effets::default();
                ctx.au_nom_de("lui-meme", || bloc.tache_finie(&ctx, &id, r, &mut ef2));
            }
        }
        let prete = bloc.maj_prete().map_or(Value::Null, |m| {
            json!({ "version": m.version, "notes": m.notes,
                "zip": Path::new(&m.zip).file_name().unwrap().to_string_lossy(),
                "sig": Path::new(&m.sig).file_name().unwrap().to_string_lossy() })
        });
        ecart(&mut e, i, "prête", &c["prete"], &prete);
        ecart(&mut e, i, "en cours", &c["en_cours"], &json!(bloc.recherche_en_cours()));
        let mut fichiers: Vec<(String, String)> = std::fs::read_dir(&tel)
            .unwrap()
            .flatten()
            .map(|x| {
                (x.file_name().to_string_lossy().into_owned(), base64_lite::encoder(&std::fs::read(x.path()).unwrap()))
            })
            .collect();
        fichiers.sort_by_key(|x| x.0.to_lowercase());
        let fichiers: Map<String, Value> = fichiers.into_iter().map(|(k, v)| (k, json!(v))).collect();
        ecart(&mut e, i, "fichiers", &c["fichiers"], &Value::Object(fichiers));
        ecart(&mut e, i, "bandeau", &c["bandeau"], &bandeau(&bloc));
        ecart(&mut e, i, "journal", &c["journal"], &journal(&f));
    }
    e
}

fn rejouer_desinstallation(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let installe = b(&c["installe"]);
        let (ctx, f) = contexte_dossiers(&unique("juge-desinstallation"), Lancement::default(), |d| {
            if !installe {
                d.mindset = d.programmes.parent().unwrap().join(r"Telecharge\Mindset");
                d.exe = d.mindset.join("Mindset.exe");
            }
        });
        std::fs::create_dir_all(&ctx.dossiers.mindset).unwrap();
        if b(&c["desinstalleur"]) {
            std::fs::write(ctx.dossiers.mindset.join("Desinstaller Mindset.exe"), "x").unwrap();
        }
        let applis = cas(&c["applis"]);
        ctx.definir_applis(applis.iter().map(|a| appli(&s(&a["id"]), &s(&a["nom"]))).collect());
        let inst: Map<String, Value> = applis
            .iter()
            .map(|a| (s(&a["id"]), json!({ "dossier": "x", "gere": a["gere"], "version": null })))
            .collect();
        publier(&ctx, "installations", partage::INSTALLATIONS, Value::Object(inst));
        let mut bloc = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine))).tout_en_essai();
        let mut ef = Effets::default();
        ctx.au_nom_de("lui-meme", || bloc.signal(&ctx, "desinstaller-mindset", &json!({}), &mut ef));
        let suite = ctx.dossiers.donnees_suite.to_string_lossy().into_owned();
        let r: Vec<Value> = signaux(&ef, "confirmation")
            .iter()
            .map(|d| json!({ "titre": d["titre"], "texte": s(&d["texte"]).replace(&suite, "SUITE"), "bouton": d["bouton"] }))
            .collect();
        ecart(&mut e, i, "confirmations", &c["confirmations"], &json!(r));
    }
    e
}

fn rejouer_lancement(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let (ctx, f) = essai::contexte_avec(
            &unique("juge-lancement"),
            Lancement { demarrage: b(&c["demarrage"]), ..Default::default() },
        );
        let _menage = Menage(f.racine.clone());
        if let Some(r) = c["reglages"].as_object() {
            for (k, v) in r {
                ctx.ecrire_reglage(k, v.clone());
            }
        }
        let mut bloc = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine)));
        let mut ef = Effets::default();
        ctx.au_nom_de("lui-meme", || bloc.demarrer_lancement(&ctx, &mut ef));
        ecart(&mut e, i, "sortie", &c["sortie"], &json!(quitte(&ef)));
        ecart(&mut e, i, "démarrage", &c["demarrage_apres"], &json!(bloc.demarrage()));
        let v = f.donnees.reglages().get("MajMindsetVisible").cloned().unwrap_or(json!("-"));
        ecart(&mut e, i, "MajMindsetVisible", &c["visible_apres"], &v);
        ecart(&mut e, i, "journal", &c["journal"], &journal(&f));
    }
    e
}

fn rejouer_demarrage(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let (ctx, f) =
            essai::contexte_avec(&unique("juge-demarrage"), Lancement { admin: b(&c["admin"]), ..Default::default() });
        let _menage = Menage(f.racine.clone());
        let applis = cas(&c["applis"]);
        ctx.definir_applis(
            applis
                .iter()
                .map(|a| Appli {
                    admin: b(&a["admin"]),
                    sans_droits_depuis: s(&a["depuis"]),
                    ..appli(&s(&a["id"]), &s(&a["nom"]))
                })
                .collect(),
        );
        let mut inst = Map::new();
        let mut dem = Vec::new();
        for a in &applis {
            if !a["installation"].is_null() {
                inst.insert(s(&a["id"]), json!({ "dossier": "x", "gere": a["installation"]["gere"], "version": a["installation"]["version"] }));
            }
            if b(&a["demarrage"]) {
                dem.push(a["id"].clone());
            }
        }
        publier(&ctx, "installations", partage::INSTALLATIONS, Value::Object(inst));
        ctx.ecrire_reglage("Demarrage", Value::Array(dem));
        let marque = ctx.dossiers.donnees.join("relance.marque");
        if let Some(age) = c["marque_age"].as_u64() {
            std::fs::write(&marque, "1").unwrap();
            let t = SystemTime::now() - Duration::from_secs(age);
            std::fs::File::options().write(true).open(&marque).unwrap().set_modified(t).unwrap();
        }
        let mut bloc = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine))).tout_en_essai();
        let mut ef = Effets::default();
        ctx.au_nom_de("lui-meme", || bloc.lancer_demarrage(&ctx, &mut ef));
        let ouvertes: Vec<Value> = signaux(&ef, "lancer-appli").iter().map(|d| d["id"].clone()).collect();
        ecart(&mut e, i, "ouvertes", &c["ouvertes"], &json!(ouvertes));
        ecart(&mut e, i, "marque", &c["marque_apres"], &json!(marque.exists()));
        if signaux(&ef, "lancer-appli").iter().any(|d| d["demarrage"] != true) {
            e.push(format!("cas {i} : une appli lancée sans « demarrage »"));
        }
    }
    e
}

struct FauxBascule {
    inscrit: String,
    temp: PathBuf,
}
impl PcBascule for FauxBascule {
    fn inscrit(&self) -> String {
        self.inscrit.clone()
    }
    fn temp(&self) -> PathBuf {
        self.temp.clone()
    }
    fn sid(&self) -> String {
        "SID".into()
    }
    fn windows(&self) -> PathBuf {
        PathBuf::from(r"C:\Windows")
    }
}

fn rejouer_bascule(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let lancement =
            Lancement { demarrage: b(&c["demarrage"]), desinstaller: b(&c["desinstaller"]), admin: b(&c["admin"]) };
        let (ctx, f) = essai::contexte_avec(&unique("juge-bascule"), lancement.clone());
        let _menage = Menage(f.racine.clone());
        let copie = ctx.dossiers.mindset.to_string_lossy().into_owned();
        let exe = ctx.dossiers.exe.to_string_lossy().into_owned();
        let temp = f.racine.join("temp");
        std::fs::create_dir_all(&temp).unwrap();
        let inscrit = match s(&c["inscrit"]).as_str() {
            "copie" => copie.clone(),
            "copie-majuscules" => copie.to_uppercase(),
            "copie-barre" => format!("{copie}\\"),
            "autre" => r"C:\Autre\Mindset".to_string(),
            _ => String::new(),
        };
        let marquer = |t: &str| {
            t.replace(&exe, "EXE")
                .replace(&copie.to_uppercase(), "COPIE-MAJUSCULES")
                .replace(&format!("{copie}\\"), "COPIE-BARRE")
                .replace(&copie, "COPIE")
                .replace(r"C:\Autre\Mindset", "AUTRE")
        };
        let ma = temp.join(bascule::MARQUE_ADMIN);
        let mc = temp.join(bascule::MARQUE_CACHE);
        for (age, m) in [(&c["age_admin"], &ma), (&c["age_cache"], &mc)] {
            if let Some(a) = age.as_u64() {
                std::fs::write(m, "1").unwrap();
                std::fs::File::options()
                    .write(true)
                    .open(m)
                    .unwrap()
                    .set_modified(SystemTime::now() - Duration::from_secs(a))
                    .unwrap();
            }
        }
        let d = bascule::decider(
            &ctx.dossiers,
            &lancement,
            f.systeme.as_ref(),
            &FauxBascule { inscrit, temp },
            SystemTime::now(),
        );
        let lances: Vec<String> = f
            .systeme
            .lances()
            .iter()
            .map(|l| {
                let nom = l.exe.file_name().unwrap().to_string_lossy().into_owned();
                if nom == bascule::INSTALLATEUR {
                    let a = &l.arguments;
                    let apres = |n: &str| a.iter().position(|x| x == n).map(|k| a[k + 1].clone()).unwrap_or_default();
                    format!(
                        "{}|Destination={}|Sid={}",
                        apres("-Action"),
                        marquer(&apres("-Destination")),
                        apres("-Sid")
                    )
                } else {
                    format!("explorer|{}", marquer(&l.arguments.join(" ")))
                }
            })
            .collect();
        let nom = format!(
            "admin {} désinst {} dém {} {} {} {}",
            c["admin"], c["desinstaller"], c["demarrage"], c["inscrit"], c["age_admin"], c["age_cache"]
        );
        ecart(&mut e, i, &format!("{nom} : lancements"), &c["lancements"], &json!(lances));
        ecart(&mut e, i, &format!("{nom} : sortie"), &c["sortie"], &json!(d.quitter));
        ecart(
            &mut e,
            i,
            &format!("{nom} : démarrage"),
            &c["demarrage_apres"],
            &json!(lancement.demarrage || d.demarrage_force),
        );
        ecart(&mut e, i, &format!("{nom} : marque admin"), &c["marque_admin"], &json!(ma.exists()));
        ecart(&mut e, i, &format!("{nom} : marque caché"), &c["marque_cache"], &json!(mc.exists()));
    }
    e
}

fn rejouer_jeux_nevermind(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let r = match serde_json::from_str::<Value>(&s(&c["contenu"])) {
            Ok(v) => regles::jeux_nevermind(&v),
            Err(_) => Vec::new(),
        };
        ecart(&mut e, i, &s(&c["contenu"]), &c["attendu"], &json!(r));
    }
    e
}

fn rejouer_activite(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let v: Vec<i64> = cas(&c["e"]).iter().map(|x| x.as_i64().unwrap()).collect();
        let r = if c["quoi"] == "signature" {
            json!(regles::signature_manette(
                v[0] as u16,
                v[1] as u8,
                v[2] as u8,
                v[3] as i16,
                v[4] as i16,
                v[5] as i16,
                v[6] as i16
            ))
        } else {
            let w: Vec<i32> = v.iter().map(|x| *x as i32).collect();
            json!(regles::couvre_ecran(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]))
        };
        ecart(&mut e, i, "activité", &c["attendu"], &r);
    }
    e
}

fn rejouer_copie_verif(l: &[Value]) -> Vec<String> {
    let mut e = Vec::new();
    for (i, c) in l.iter().enumerate() {
        let (ctx, f) = essai::contexte(&unique("juge-copie-verif"));
        let _menage = Menage(f.racine.clone());
        if let Some(v) = c["verif"].as_bool() {
            ctx.ecrire_reglage("VerifVersions", json!(v));
        }
        let cible = f.racine.join(s(&c["fichier"]));
        if let Some(a) = c["avant"].as_str() {
            std::fs::create_dir_all(cible.parent().unwrap()).unwrap();
            std::fs::write(&cible, a).unwrap();
        }
        let dossier = f.racine.join(s(&c["dossier"]));
        let bloc = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine)));
        bloc.copier_reglage_verif(&ctx, &dossier.to_string_lossy());
        let obtenu = match std::fs::read_to_string(&cible) {
            Err(_) => Value::Null,
            Ok(t) => serde_json::from_str::<Value>(&t).unwrap_or(json!(t)),
        };
        ecart(&mut e, i, &format!("{} {}", s(&c["dossier"]), s(&c["avant"])), &c["apres"], &obtenu);
    }
    e
}

/// Un petit base64 (encodage et décodage standard) pour les fichiers des juges.
mod base64_lite {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    pub fn encoder(o: &[u8]) -> String {
        let mut s = String::new();
        for c in o.chunks(3) {
            let n = (u32::from(c[0]) << 16)
                | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
                | u32::from(*c.get(2).unwrap_or(&0));
            for k in 0..4 {
                if k <= c.len() {
                    s.push(A[(n >> (18 - 6 * k) & 63) as usize] as char);
                } else {
                    s.push('=');
                }
            }
        }
        s
    }
    pub fn decoder(t: &str) -> Vec<u8> {
        let mut r = Vec::new();
        let mut n = 0u32;
        let mut k = 0;
        for c in t.bytes() {
            let Some(v) = A.iter().position(|x| *x == c) else { continue };
            n = (n << 6) | v as u32;
            k += 1;
            if k == 4 {
                r.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8, n as u8]);
                n = 0;
                k = 0;
            }
        }
        match k {
            2 => r.push((n >> 4) as u8),
            3 => r.extend_from_slice(&[(n >> 10) as u8, (n >> 2) as u8]),
            _ => {}
        }
        r
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Les tests
// ---------------------------------------------------------------------------------------------------------------

type Rejeu = fn(&[Value]) -> Vec<String>;

const JUGES: &[(&str, Rejeu)] = &[
    ("raisons", rejouer_raisons),
    ("noms", rejouer_noms),
    ("entrees", rejouer_entrees),
    ("quand", rejouer_quand),
    ("reessai", rejouer_reessai),
    ("historique", rejouer_historique),
    ("disques", rejouer_disques),
    ("bulles", rejouer_bulles),
    ("maj-auto", rejouer_maj_auto),
    ("maj-mindset", rejouer_maj_mindset),
    ("maj-directe", rejouer_maj_directe),
    ("resultat", rejouer_resultat),
    ("desinstallation", rejouer_desinstallation),
    ("lancement", rejouer_lancement),
    ("demarrage", rejouer_demarrage),
    ("bascule", rejouer_bascule),
    ("jeux-nevermind", rejouer_jeux_nevermind),
    ("activite", rejouer_activite),
    ("copie-verif", rejouer_copie_verif),
];

macro_rules! test_juge {
    ($nom:ident, $fichier:literal, $rejeu:ident) => {
        #[test]
        fn $nom() {
            let l = juge($fichier);
            assert!(!l.is_empty(), "juge {} vide", $fichier);
            verifier($fichier, $rejeu(&l));
        }
    };
}

test_juge!(juge_raisons, "raisons", rejouer_raisons);
test_juge!(juge_noms, "noms", rejouer_noms);
test_juge!(juge_entrees, "entrees", rejouer_entrees);
test_juge!(juge_quand, "quand", rejouer_quand);
test_juge!(juge_reessai, "reessai", rejouer_reessai);
test_juge!(juge_historique, "historique", rejouer_historique);
test_juge!(juge_disques, "disques", rejouer_disques);
test_juge!(juge_bulles, "bulles", rejouer_bulles);
test_juge!(juge_maj_auto, "maj-auto", rejouer_maj_auto);
test_juge!(juge_maj_mindset, "maj-mindset", rejouer_maj_mindset);
test_juge!(juge_maj_directe, "maj-directe", rejouer_maj_directe);
test_juge!(juge_resultat, "resultat", rejouer_resultat);
test_juge!(juge_desinstallation, "desinstallation", rejouer_desinstallation);
test_juge!(juge_lancement, "lancement", rejouer_lancement);
test_juge!(juge_demarrage, "demarrage", rejouer_demarrage);
test_juge!(juge_bascule, "bascule", rejouer_bascule);
test_juge!(juge_jeux_nevermind, "jeux-nevermind", rejouer_jeux_nevermind);
test_juge!(juge_activite, "activite", rejouer_activite);
test_juge!(juge_copie_verif, "copie-verif", rejouer_copie_verif);

#[test]
fn juge_verif() {
    let j = lire_juge(&juge_texte("verif"));
    assert!(!cas(&j["cas"]).is_empty());
    verifier("verif", rejouer_verif(&j));
}

/// Change un résultat attendu du juge (le premier texte, nombre ou booléen non vide d'un champ de résultat) : vrai si
/// quelque chose a été changé.
fn alterer(v: &mut Value, dans_resultat: bool) -> bool {
    const RESULTATS: &[&str] = &[
        "attendu",
        "journal",
        "bulles",
        "actions",
        "attentes",
        "bandeau",
        "confirmations",
        "ouvertes",
        "lancements",
        "fichier",
        "dernieres",
        "parametres",
        "apres",
        "echec",
        "sortie",
        "titre",
        "prete",
        "restants",
        "marque_apres",
    ];
    match v {
        Value::String(t) if dans_resultat && !t.is_empty() => {
            // (un caractère changé au milieu)
            let mut c: Vec<char> = t.chars().collect();
            let k = c.len() / 2;
            c[k] = if c[k] == 'é' { 'e' } else { 'é' };
            *t = c.into_iter().collect();
            true
        }
        Value::Bool(x) if dans_resultat => {
            *x = !*x;
            true
        }
        Value::Number(n) if dans_resultat => {
            *v = json!(n.as_f64().unwrap_or(0.0) + 1.0);
            true
        }
        Value::Array(a) => a.iter_mut().any(|x| alterer(x, dans_resultat)),
        Value::Object(m) => {
            for (k, x) in m.iter_mut().filter(|(k, _)| k.as_str() != "scenario") {
                if alterer(x, dans_resultat || RESULTATS.contains(&k.as_str())) {
                    return true;
                }
            }
            false
        }
        _ => false,
    }
}

/// La contre-épreuve : un juge changé d'un caractère (dans un cas pris au milieu) doit être refusé, pour chaque juge.
#[test]
fn contre_epreuve() {
    for (nom, rejeu) in JUGES {
        let l = juge(nom);
        let mut changes = 0;
        let pas = (l.len() / 9).max(1);
        for k in (0..l.len()).rev().step_by(pas) {
            if changes >= 4 {
                break;
            }
            let mut c = vec![l[k].clone()];
            if !alterer(&mut c[0], false) {
                continue;
            }
            changes += 1;
            assert!(
                !rejeu(&c).is_empty(),
                "juge {nom} : le cas {k} changé passe encore (la contre-épreuve échoue) : {}",
                c[0]
            );
            assert!(rejeu(&[l[k].clone()]).is_empty(), "juge {nom} : le cas {k} intact ne passe pas");
        }
        assert!(changes > 0, "juge {nom} : rien à changer pour la contre-épreuve");
    }
    let mut j = lire_juge(&juge_texte("verif"));
    let mut c = cas(&j["cas"]);
    assert!(alterer(&mut c[1], false));
    j["cas"] = json!(c);
    assert!(!rejouer_verif(&j).is_empty(), "juge verif changé : il passe encore");
}

/// Un jeu ouvert n'arrête plus les mises à jour automatiques (décision de Jordan du 07/11/2026) : chaque cas du juge
/// sans jeu, rejoué avec un jeu en plein écran, une manette utilisée ou un jeu ouvert, doit donner exactement la même
/// chose que sans jeu (mêmes installations, mêmes attentes, même journal).
#[test]
fn maj_auto_meme_pendant_un_jeu() {
    let l = juge("maj-auto");
    assert!(l.len() > 100, "juge maj-auto : trop peu de cas sans jeu ({})", l.len());
    let mut installe = 0;
    for jeu in [
        "une fenêtre en plein écran (jeu ou vidéo)",
        "une manette utilisée il y a moins de 5 minutes",
        "un jeu ouvert (Jeu Essai)",
    ] {
        let avec: Vec<Value> = l
            .iter()
            .map(|c| {
                let mut c = c.clone();
                c["scenario"]["jeu"] = json!(jeu);
                c
            })
            .collect();
        installe += avec.iter().filter(|c| c["actions"].as_array().is_some_and(|a| !a.is_empty())).count();
        verifier(&format!("maj-auto avec {jeu}"), rejouer_maj_auto(&avec));
    }
    assert!(installe > 0, "aucun cas où une mise à jour part");
}
