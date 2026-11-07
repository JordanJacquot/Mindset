//! Les juges du bloc « près de l'horloge » : chaque cas a été joué par la VRAIE version PowerShell (zone.ps1, ses
//! gestionnaires et les fonctions qu'il appelle, voir `outils/exporter-juges-horloge.ps1`) ; le bloc Rust rejoue les
//! mêmes gestes et doit faire exactement la même chose, geste par geste : ce qui arrive à la fenêtre (montrée,
//! cachée, remise en taille normale), Mindset qui quitte (avec ou sans les applis), les bulles, l'appli ouverte, la
//! recherche des nouvelles versions, la question de la croix, la bulle d'appli en attente, le menu de l'icône ; et à
//! la fin les réglages écrits, le journal et les fichiers (notification lue et effacée, « notif:<id> » écrit).
//!
//! Un petit hôte de test tient la vue (comme `mindset-appli` : le signal `fenetre` quand elle change) et traduit
//! les effets du bloc dans les mots des juges.

use std::path::Path;
use std::time::Duration;

use mindset_horloge::BlocHorloge;
use mindset_horloge::icone::{Choix, FausseIcone, Geste, Ligne};
use mindset_noyau::appli::Appli;
use mindset_noyau::contexte::Vue;
use mindset_noyau::essai::{self, Faux};
use mindset_noyau::{Bloc, Contexte, Effet, Effets, Fenetre, moment, signaux};
use serde_json::{Map, Value, json};

struct Banc {
    ctx: Contexte,
    faux: Faux,
    icone: Option<FausseIcone>,
    bloc: BlocHorloge,
    trace: Vec<String>,
    profondeur: usize,
}

fn texte(v: &Value, c: &str) -> String {
    v.get(c).and_then(Value::as_str).unwrap_or("").to_string()
}

impl Banc {
    fn nouveau(nom: &str, cas: &Value) -> Banc {
        let (ctx, faux) = essai::contexte(nom);
        // Les réglages, tels que reglages.json les donne
        if let Ok(Value::Object(r)) = serde_json::from_str::<Value>(&texte(cas, "reglages_json")) {
            for (k, v) in r {
                ctx.ecrire_reglage(&k, v);
            }
        }
        // Les applis, leurs dossiers, leurs installations
        let mut applis = Vec::new();
        for a in cas["applis"].as_array().into_iter().flatten() {
            let donnees = faux.racine.join(texte(a, "donnees"));
            if !texte(a, "donnees").ends_with("absent") {
                std::fs::create_dir_all(&donnees).unwrap();
            }
            applis.push(Appli {
                id: texte(a, "id"),
                nom: texte(a, "nom"),
                afficher_fichier: texte(a, "afficher"),
                donnees: donnees.to_string_lossy().into_owned(),
                ..Default::default()
            });
        }
        ctx.definir_applis(applis);
        let _ = std::fs::create_dir_all(&ctx.dossiers.donnees_suite);
        for n in cas["dossiers_suite"].as_array().into_iter().flatten() {
            std::fs::create_dir_all(ctx.dossiers.donnees_suite.join(n.as_str().unwrap_or("?"))).unwrap();
        }
        let mut inst = Map::new();
        if let Some(Value::Object(i)) = cas.get("installations") {
            for (id, v) in i {
                let gere = v.get("gere").and_then(Value::as_bool).unwrap_or(false);
                inst.insert(
                    id.clone(),
                    json!({ "dossier": format!(r"X:\Programmes\{id}"), "gere": gere, "version": null }),
                );
            }
        }
        ctx.au_nom_de("installations", || ctx.publier("installations", Value::Object(inst)));
        // La dernière recherche des nouvelles versions
        let derniere =
            cas["derniere_minutes"].as_f64().map(|m| moment::iso(&moment::ajouter(&ctx.heure(), -(m * 60.0) as i64)));
        ctx.au_nom_de("publications", || ctx.publier("recherche", json!({ "derniere": derniere })));
        ctx.definir_vue(Vue {
            visible: cas["visible"].as_bool().unwrap_or(true),
            reduite: cas["minimisee"].as_bool().unwrap_or(false),
            page: "accueil".into(),
        });
        let (bloc, icone) = if cas["icone"].as_bool().unwrap_or(false) {
            let i = FausseIcone::nouvelle();
            (BlocHorloge::avec_icone(Box::new(i.clone())), Some(i))
        } else {
            (BlocHorloge::sans_icone(), None)
        };
        let mut b = Banc { ctx, faux, icone, bloc, trace: Vec::new(), profondeur: 0 };
        let mut e = Effets::default();
        b.bloc.demarrer(&b.ctx, &mut e);
        assert!(e.est_vide());
        b
    }

    /// Un appel au bloc, puis ses effets traités comme l'hôte (et ce qu'ils entraînent), puis les bulles montrées
    /// pendant tout cela (le moment exact d'une bulle par rapport à la fenêtre ne se voit pas).
    fn appeler(&mut self, f: impl FnOnce(&mut BlocHorloge, &Contexte, &mut Effets)) {
        self.profondeur += 1;
        let mut e = Effets::default();
        f(&mut self.bloc, &self.ctx, &mut e);
        for x in e.0 {
            self.effet(x);
        }
        self.profondeur -= 1;
        if self.profondeur == 0
            && let Some(i) = &self.icone
        {
            self.trace.extend(i.bulles());
        }
    }

    fn signal(&mut self, nom: &str, d: Value) {
        self.appeler(|b, c, e| b.signal(c, nom, &d, e));
    }

    fn changer_vue(&mut self, f: impl FnOnce(&mut Vue)) {
        let avant = self.ctx.vue();
        let mut v = avant.clone();
        f(&mut v);
        self.ctx.definir_vue(v.clone());
        if avant.visible != v.visible || avant.reduite != v.reduite {
            self.signal(signaux::FENETRE, json!({ "visible": v.visible, "reduite": v.reduite }));
        }
    }

    fn effet(&mut self, x: Effet) {
        match x {
            Effet::Fenetre(Fenetre::Montrer) => {
                self.trace.push("montrer".into());
                if self.ctx.vue().reduite {
                    self.trace.push("normal".into());
                }
                self.changer_vue(|v| {
                    v.visible = true;
                    v.reduite = false;
                });
            }
            Effet::Fenetre(Fenetre::Cacher) => {
                self.trace.push("cacher".into());
                self.changer_vue(|v| v.visible = false);
            }
            Effet::Fenetre(Fenetre::Restaurer) => {
                if self.ctx.vue().reduite {
                    self.trace.push("normal".into());
                    self.changer_vue(|v| v.reduite = false);
                }
            }
            Effet::Quitter { avec_applis } => {
                self.trace.push(if avec_applis { "quitter:avec" } else { "fermee" }.into())
            }
            Effet::Signal { nom, donnees } => match nom.as_str() {
                signaux::OUVRIR_APPLI => {
                    assert_eq!(donnees["lancer"], json!(true));
                    self.trace.push(format!("ouvrir:{}", texte(&donnees, "id")));
                }
                signaux::ACTUALISER => {
                    assert_eq!(donnees, json!({ "clic": false }));
                    self.trace.push("actualiser".into());
                }
                signaux::REGLAGE_CHANGE => {}
                autre => panic!("signal inattendu : {autre}"),
            },
            autre => panic!("effet inattendu : {autre:?}"),
        }
    }

    fn geste(&mut self, g: Geste) {
        match &self.icone {
            Some(i) => {
                i.geste(g);
                self.appeler(|b, c, e| {
                    b.tic(c, e);
                });
            }
            // (sans icône, pas de geste possible : la version PowerShell appelait quand même la fonction)
            None => self.appeler(|b, c, e| b.geste(c, g, e)),
        }
    }

    fn pas(&mut self, p: &Value) {
        match texte(p, "quoi").as_str() {
            "croix" => self.signal(signaux::CROIX, json!({})),
            "reduire" => {
                self.changer_vue(|v| v.reduite = true);
                self.signal(signaux::REDUITE, json!({}));
            }
            "bouton" => {
                let v = json!({ "choix": texte(p, "choix"), "souvenir": p["souvenir"].as_bool().unwrap_or(false) });
                let mut prise = false;
                self.appeler(|b, c, e| prise = b.action(c, "horloge:fermeture", &v, e));
                assert!(prise);
            }
            "clic" => self.geste(Geste::Clic),
            "menu" => self.appeler(|b, c, e| {
                b.tic(c, e);
            }),
            "menu-choix" => {
                let n = p["n"].as_u64().unwrap() as usize;
                let choix: Vec<Choix> = mindset_horloge::menu(&self.ctx)
                    .into_iter()
                    .filter_map(|l| match l {
                        Ligne::Choix { choix, .. } => Some(choix),
                        Ligne::Separateur => None,
                    })
                    .collect();
                self.geste(Geste::Menu(choix[n].clone()));
            }
            "notifications" => {
                for f in p["fichiers"].as_array().into_iter().flatten() {
                    let a = self.ctx.appli(&texte(f, "appli")).unwrap();
                    let d = if texte(f, "dossier") == "suite" {
                        self.ctx.dossiers.donnees_suite.join(&a.nom)
                    } else {
                        Path::new(&a.donnees).to_path_buf()
                    };
                    std::fs::write(d.join("notification.demande"), base64(&texte(f, "octets"))).unwrap();
                }
                self.ctx.avancer(Duration::from_secs(2));
                match self.icone.is_some() {
                    true => self.appeler(|b, c, e| {
                        b.tic(c, e);
                    }),
                    // (la version PowerShell relevait quand même : appelé directement)
                    false => self.appeler(|b, c, _| b.relever_notifications(c)),
                }
            }
            "bulle-clic" => self.geste(Geste::BulleCliquee),
            "bulle-fermee" => self.geste(Geste::BulleFermee),
            "bulle" => {
                let d = json!({ "titre": texte(p, "titre"), "texte": texte(p, "texte"), "icone": texte(p, "icone"), "duree_ms": p["duree"] });
                self.signal(signaux::BULLE, d);
            }
            "erreur" => self.signal(signaux::ERREUR_IMPREVUE, json!({ "texte": "Plantage de test" })),
            "afficher" => self.signal(signaux::AFFICHER_DEMANDE, json!({})),
            // (la console met Mindset en veille : un autre bloc cache la fenêtre)
            "veille" => self.effet(Effet::Fenetre(Fenetre::Cacher)),
            "reglage" => {
                let v: Value = serde_json::from_str(&texte(p, "valeur_json")).unwrap();
                self.ctx.ecrire_reglage(&texte(p, "nom"), v.clone());
                self.signal(signaux::REGLAGE_CHANGE, json!({ "nom": texte(p, "nom"), "valeur": v }));
            }
            autre => panic!("geste inconnu : {autre}"),
        }
    }
}

fn base64(t: &str) -> Vec<u8> {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut sortie = Vec::new();
    let mut acc = 0u32;
    let mut n = 0;
    for c in t.bytes() {
        if c == b'=' {
            break;
        }
        let Some(v) = A.iter().position(|&x| x == c) else { continue };
        acc = (acc << 6) | v as u32;
        n += 6;
        if n >= 8 {
            n -= 8;
            sortie.push((acc >> n) as u8);
            acc &= (1 << n) - 1;
        }
    }
    sortie
}

fn ligne_menu(l: &Ligne) -> Value {
    match l {
        Ligne::Separateur => json!({ "separateur": true }),
        Ligne::Choix { texte, gras, choix } => json!({
            "separateur": false, "texte": texte, "gras": gras,
            "appli": match choix { Choix::OuvrirAppli(id) => json!(id), _ => Value::Null },
        }),
    }
}

/// Rejoue un cas ; `Err` : la première différence.
fn rejouer(nom: &str, cas: &Value) -> Result<bool, String> {
    let mut b = Banc::nouveau(nom, cas);
    let pas = cas["pas"].as_array().cloned().unwrap_or_default();
    let etapes = cas["etapes"].as_array().cloned().unwrap_or_default();
    if pas.len() != etapes.len() {
        return Err("nombre d'étapes".into());
    }
    let mut reglages_touches = std::collections::HashSet::new();
    for (k, (p, attendu)) in pas.iter().zip(&etapes).enumerate() {
        // Situation impossible : la console met en veille un Mindset déjà caché (son bouton est dans la fenêtre).
        // La version PowerShell remontrait la bulle de la première fois ; l'hôte Rust n'envoie pas de signal
        // `fenetre` (rien ne change), donc pas de bulle : quand c'est la seule différence, le reste du cas n'est plus
        // comparé (DIVERGENCES.md).
        let impossible = texte(p, "quoi") == "veille" && !b.ctx.vue().visible;
        b.trace.clear();
        b.pas(p);
        if texte(p, "quoi") == "reglage" {
            reglages_touches.insert(texte(p, "nom"));
        }
        let vue = b.ctx.vue();
        let mut vu = json!({
            "trace": b.trace,
            "question": b.bloc.question(),
            "visible": vue.visible,
            "minimisee": vue.reduite,
            "bulle_appli": b.bloc.bulle_appli().map(|(a, i)| json!({ "appli": a, "id": i })),
        });
        if attendu.get("menu").is_some() {
            let m = mindset_horloge::menu(&b.ctx);
            if let Some(i) = &b.icone
                && i.dernier_menu() != m
            {
                return Err(format!("geste {k} : le menu donné à l'icône n'est pas le menu"));
            }
            vu["menu"] = Value::Array(m.iter().map(ligne_menu).collect());
        }
        if impossible && &vu != attendu {
            let bulle = format!("bulle:4000|{}|{}|None", mindset_horloge::BULLE_TITRE, mindset_horloge::BULLE_TEXTE);
            if attendu["trace"] == json!(["cacher", bulle]) && vu["trace"] == json!(["cacher"]) {
                let _ = std::fs::remove_dir_all(&b.faux.racine);
                return Ok(false);
            }
        }
        if &vu != attendu {
            return Err(format!("geste {k} ({}) :\n  attendu {attendu}\n  obtenu  {vu}", texte(p, "quoi")));
        }
    }
    // Les réglages écrits (le dernier de chaque nom, sauf ceux aussi changés par un geste « reglage »)
    let reglages = b.faux.donnees.reglages();
    let mut derniers: Map<String, Value> = Map::new();
    for e in cas["ecrits"].as_array().into_iter().flatten() {
        derniers.insert(texte(e, "nom"), e["valeur"].clone());
    }
    for (n, v) in &derniers {
        if !reglages_touches.contains(n) && reglages.get(n) != Some(v) {
            return Err(format!("réglage {n} : attendu {v}, obtenu {:?}", reglages.get(n)));
        }
    }
    let initiaux: Map<String, Value> = serde_json::from_str(&texte(cas, "reglages_json")).unwrap_or_default();
    for n in ["Fermeture", "BulleHorlogeVue", "ReduireHorloge"] {
        if !derniers.contains_key(n) && !reglages_touches.contains(n) && reglages.get(n) != initiaux.get(n) {
            return Err(format!("réglage {n} écrit sans raison : {:?}", reglages.get(n)));
        }
    }
    // Le journal (le message d'une erreur d'écriture vient de Windows, pas de .NET : seul le début compte)
    let journal = b.faux.donnees.lignes();
    let attendu: Vec<String> =
        cas["journal"].as_array().into_iter().flatten().map(|l| l.as_str().unwrap_or("").to_string()).collect();
    let court = |l: &str| {
        if l.starts_with("Notification de ") { l.split(" : ").next().unwrap_or(l).to_string() } else { l.to_string() }
    };
    let j1: Vec<String> = journal.iter().map(|l| court(l)).collect();
    let j2: Vec<String> = attendu.iter().map(|l| court(l)).collect();
    if j1 != j2 {
        return Err(format!("journal : attendu {j2:?}, obtenu {j1:?}"));
    }
    // Les fichiers à la fin
    if let Some(Value::Object(f)) = cas.get("fichiers") {
        for (cle, v) in f {
            let parts: Vec<&str> = cle.splitn(3, '/').collect();
            let a = b.ctx.appli(parts[0]).ok_or("appli des fichiers")?;
            let d = if parts[1] == "suite" {
                b.ctx.dossiers.donnees_suite.join(&a.nom)
            } else {
                Path::new(&a.donnees).to_path_buf()
            };
            let lu = std::fs::read(d.join(parts[2])).ok().map(|o| suite_commun::json_sur::texte_du_fichier(&o));
            if lu.as_deref() != v.as_str() {
                return Err(format!("fichier {cle} : attendu {v}, obtenu {lu:?}"));
            }
        }
    }
    let _ = std::fs::remove_dir_all(&b.faux.racine);
    Ok(true)
}

fn juges(fichier: &str) -> Vec<Value> {
    let chemin = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(format!("{fichier}.json"));
    let texte = std::fs::read_to_string(&chemin).unwrap_or_else(|e| panic!("{}: {e}", chemin.display()));
    let v: Value = serde_json::from_str(texte.trim_start_matches('\u{feff}')).unwrap();
    v["cas"].as_array().cloned().unwrap()
}

fn tout_rejouer(fichier: &str) {
    let cas = juges(fichier);
    assert!(!cas.is_empty());
    let mut echecs = Vec::new();
    let mut arretes = 0;
    for (k, c) in cas.iter().enumerate() {
        match rejouer(&format!("horloge-{fichier}-{k}"), c) {
            Ok(true) => {}
            Ok(false) => arretes += 1,
            Err(e) => echecs.push(format!("{} : {e}", texte(c, "nom"))),
        }
    }
    assert!(
        echecs.is_empty(),
        "{} cas sur {} différents de PowerShell :\n{}",
        echecs.len(),
        cas.len(),
        echecs.join("\n")
    );
    // (les cas arrêtés sur la situation impossible restent rares : sinon le juge ne prouverait plus grand-chose)
    assert!(arretes * 10 <= cas.len(), "{arretes} cas arrêtés sur {}", cas.len());
    eprintln!("{fichier} : {} cas comme PowerShell ({arretes} arrêtés sur une situation impossible)", cas.len());
}

#[test]
fn juges_fermeture() {
    tout_rejouer("fermeture");
}
#[test]
fn juges_reduction() {
    tout_rejouer("reduction");
}
#[test]
fn juges_rouvrir() {
    tout_rejouer("rouvrir");
}
#[test]
fn juges_menu() {
    tout_rejouer("menu");
}
#[test]
fn juges_notifications() {
    tout_rejouer("notifications");
}
#[test]
fn juges_bulles() {
    tout_rejouer("bulles");
}
/// Les cas tirés au hasard par l'export (jamais écrits à la main).
#[test]
fn juges_hasard() {
    tout_rejouer("hasard");
}

/// Les cas jamais vus : tirés au hasard par l'export (`-Grain <n>`) APRÈS l'écriture du code (contenus de
/// notification.demande fabriqués au hasard, suites de gestes au hasard).
#[test]
fn juges_jamais_vus() {
    let dossier = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges");
    let mut n = 0;
    for f in std::fs::read_dir(&dossier).unwrap().flatten() {
        let nom = f.file_name().to_string_lossy().into_owned();
        if let Some(lot) = nom.strip_prefix("jamais-vus-").and_then(|x| x.strip_suffix(".json")) {
            tout_rejouer(&format!("jamais-vus-{lot}"));
            n += 1;
        }
    }
    assert!(n >= 1, "aucun lot de cas jamais vus");
}

/// La contre-épreuve : un juge modifié (un seul détail) doit faire échouer le rejeu. Sinon, les tests ne prouvent
/// rien.
#[test]
fn contre_epreuve() {
    let mut alea: u64 = 0x2026_1107;
    let mut tirer = |n: usize| {
        alea ^= alea << 13;
        alea ^= alea >> 7;
        alea ^= alea << 17;
        (alea % n as u64) as usize
    };
    let mut essais = 0;
    for fichier in ["fermeture", "reduction", "rouvrir", "menu", "notifications", "bulles", "hasard"] {
        let cas = juges(fichier);
        for _ in 0..12 {
            let mut c = cas[tirer(cas.len())].clone();
            let n = c["etapes"].as_array().map_or(0, Vec::len);
            // (seulement un cas rejoué jusqu'au bout tel quel)
            if n == 0 || rejouer("horloge-contre-original", &c) != Ok(true) {
                continue;
            }
            let k = tirer(n);
            let e = &mut c["etapes"][k];
            match tirer(5) {
                0 => e["question"] = json!(!e["question"].as_bool().unwrap()),
                1 => e["visible"] = json!(!e["visible"].as_bool().unwrap()),
                2 => {
                    let t = e["trace"].as_array_mut().unwrap();
                    if t.is_empty() {
                        t.push(json!("montrer"));
                    } else {
                        let i = tirer(t.len());
                        let mut s = t[i].as_str().unwrap().to_string();
                        // (un seul octet change : le dernier caractère)
                        let fin = s.pop().unwrap_or('x');
                        s.push(if fin == 'x' { 'y' } else { 'x' });
                        t[i] = json!(s);
                    }
                }
                3 => {
                    let t = e["trace"].as_array_mut().unwrap();
                    if t.is_empty() {
                        t.push(json!("cacher"));
                    } else {
                        t.remove(tirer(t.len()));
                    }
                }
                _ => e["minimisee"] = json!(!e["minimisee"].as_bool().unwrap()),
            }
            essais += 1;
            assert!(
                rejouer(&format!("horloge-contre-{essais}"), &c).is_err(),
                "juge modifié accepté : {}",
                texte(&c, "nom")
            );
        }
    }
    assert!(essais >= 70);
}
