//! Les juges exportés de la version PowerShell (`outils\exporter-juges-console.ps1`, tests\juges\*.json), rejoués
//! par le bloc Rust : chaque cas doit donner la même sortie. Les entrées sont écrites dans le vocabulaire du tableau
//! commun ; les seules différences acceptées sont celles de DIVERGENCES.md :
//! - les adresses des images (`https://applogos.mindset.local/<id>.png` devient
//!   `http://fichier.localhost/console-logo-<id>.png`, `https://theme.mindset.local/` devient `http://pack.localhost/`) ;
//! - l'état et les Paramètres passent par l'état de la page (pas d'appel `etat()` dans la liste des ordres) ;
//! - une durée d'ouverture illisible dans les réglages : 8 s (PowerShell levait une erreur).

use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};

use mindset_console::{BlocConsole, Fenetres, calculs, images};
use mindset_noyau::appli::Appli;
use mindset_noyau::essai::{self, Faux};
use mindset_noyau::{Bloc, Contexte, Effet, Effets, Fenetre, Vue, moment, partage};
use serde_json::{Map, Value, json};

fn juge(nom: &str) -> Value {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(nom);
    let t = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{} : {e}", p.display()));
    serde_json::from_str(t.trim_start_matches('\u{feff}')).unwrap_or_else(|e| panic!("{nom} : {e}"))
}

fn cas(nom: &str) -> Vec<Value> {
    juge(nom).as_array().cloned().unwrap_or_default()
}

/// Deux valeurs JSON égales, les nombres comparés comme des nombres (1 et 1.0), et les objets dans l'ordre des clés.
fn pareil(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            (x.as_f64().unwrap_or(f64::NAN) - y.as_f64().unwrap_or(f64::NAN)).abs() < 1e-9
        }
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(p, q)| pareil(p, q)),
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|((k1, v1), (k2, v2))| k1 == k2 && pareil(v1, v2))
        }
        _ => a == b,
    }
}

/// Les adresses de la version Rust remises dans la forme de la version PowerShell.
fn adresses_ps(v: &Value) -> Value {
    match v {
        Value::String(s) => Value::String(
            s.replace("http://fichier.localhost/console-logo-", "https://applogos.mindset.local/")
                .replace("http://pack.localhost/", "https://theme.mindset.local/"),
        ),
        Value::Array(l) => Value::Array(l.iter().map(adresses_ps).collect()),
        Value::Object(m) => Value::Object(m.iter().map(|(k, v)| (k.clone(), adresses_ps(v))).collect()),
        x => x.clone(),
    }
}

fn texte(v: Option<&Value>) -> String {
    v.and_then(Value::as_str).unwrap_or_default().to_string()
}

static NUMERO: AtomicUsize = AtomicUsize::new(0);

/// Un faux pour la recherche des fenêtres : aucune n'est trouvée.
struct SansFenetre;
impl Fenetres for SansFenetre {
    fn trouvee(&self, _pid: u32, _titre: &str) -> bool {
        false
    }
}

/// Le monde d'un cas : un contexte d'essai rempli comme le décrit le juge.
struct Monde {
    ctx: Contexte,
    faux: Faux,
}

impl Drop for Monde {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.faux.racine);
    }
}

fn monde(m: &Value) -> Monde {
    let n = NUMERO.fetch_add(1, Ordering::SeqCst);
    let (mut ctx, faux) = essai::contexte(&format!("console-juge-{n}"));
    let racine = faux.racine.clone();
    ctx.version = m.get("version").and_then(Value::as_str).unwrap_or("3.0.0").to_string();
    ctx.lancement.admin = m.get("admin").and_then(Value::as_bool).unwrap_or(false);
    if let Some(h) = moment::lire_iso(m.get("maintenant").and_then(Value::as_str).unwrap_or(essai::HEURE_ESSAI)) {
        ctx.figer_heure(h);
    }
    if let Some(r) = m.get("reglages").and_then(Value::as_object) {
        for (k, v) in r {
            ctx.ecrire_reglage(k, v.clone());
        }
    }
    ctx.donnees().ecrire_theme_suite(m.get("theme").and_then(Value::as_str).unwrap_or("neon"));
    // Les fichiers du cas : « Donnees\... » dans les données de Mindset, le reste sous la racine
    if let Some(f) = m.get("fichiers").and_then(Value::as_object) {
        for (k, v) in f {
            let chemin = match k.strip_prefix(r"Donnees\") {
                Some(reste) => ctx.dossiers.donnees.join(reste),
                None => racine.join(k),
            };
            std::fs::create_dir_all(chemin.parent().unwrap()).unwrap();
            std::fs::write(&chemin, b64(v.as_str().unwrap()).unwrap()).unwrap();
        }
    }
    let applis: Vec<Appli> = m
        .get("applis")
        .and_then(Value::as_array)
        .map(|l| {
            l.iter()
                .map(|a| Appli {
                    id: texte(a.get("id")),
                    nom: texte(a.get("nom")),
                    couleur: texte(a.get("couleur")),
                    description: texte(a.get("description")),
                    presentation: texte(a.get("presentation")),
                    confidentialite: texte(a.get("confidentialite")),
                    cache_depuis: texte(a.get("cache_depuis")),
                    mutex: format!(r"Local\Essai-{}-Instance", texte(a.get("id"))),
                    exe: "Mindset.exe".into(),
                    ..Default::default()
                })
                .collect()
        })
        .unwrap_or_default();
    ctx.definir_applis(applis);
    // Le tableau commun, chaque clé au nom de son bloc ; « <essai> » : la racine du cas
    if let Some(p) = m.get("partage").and_then(Value::as_object) {
        let r = racine.to_string_lossy().to_string();
        for (cle, v) in p {
            let v: Value = serde_json::from_str(&v.to_string().replace("<essai>", &r.replace('\\', "\\\\"))).unwrap();
            let bloc = partage::proprietaire(cle).unwrap_or_else(|| panic!("clé inconnue {cle}"));
            ctx.au_nom_de(bloc, || ctx.publier(cle, v.clone()));
        }
        // (une appli « ouverte » : son verrou est tenu, comme Test-AppliOuverte)
        if let Some(o) = p.get("ouvertes").and_then(Value::as_object) {
            for (id, oui) in o {
                if oui.as_bool() == Some(true) {
                    faux.systeme.poser_verrou(&format!(r"Local\Essai-{id}-Instance"), true);
                }
            }
        }
    }
    let vue = m.get("vue");
    ctx.definir_vue(Vue {
        visible: !vue.and_then(|v| v.get("visible")).is_some_and(|v| v == &json!(false)),
        reduite: vue.and_then(|v| v.get("reduite")).and_then(Value::as_bool).unwrap_or(false),
        page: m.get("page").and_then(Value::as_str).unwrap_or("accueil").to_string(),
    });
    Monde { ctx, faux }
}

/// La console posée comme dans le cas.
fn console(w: &Monde, m: &Value) -> BlocConsole {
    let mut b = BlocConsole::avec_fenetres(Box::new(SansFenetre));
    let mut e = Effets::default();
    b.demarrer(&w.ctx, &mut e);
    // (le premier tic de l'hôte est passé avant le cas)
    b.tic(&w.ctx, &mut e);
    if let Some(c) = m.get("console") {
        let s = |k: &str| c.get(k).and_then(Value::as_str);
        let oui = |k: &str| c.get(k).and_then(Value::as_bool).unwrap_or(false);
        b.poser(
            c.get("possible").and_then(Value::as_bool).unwrap_or(true),
            oui("cadre"),
            oui("pret"),
            s("derniere"),
            s("ejecter"),
        );
        b.poser_fente(s("en_fente"), oui("parametres"));
        if oui("quittee") {
            b.poser_quittee(&w.ctx);
        }
    }
    b
}

fn theme_du_cas(w: &Monde, m: &Value) -> suite_commun::themes::Theme {
    suite_commun::themes::charger(
        Some(m.get("theme").and_then(Value::as_str).unwrap_or("neon")),
        &[w.ctx.dans_donnees("packs")],
    )
}

/// Un ordre de la version Rust, dans la forme d'un script noté par la version PowerShell (`{ appel, args }`).
fn script(o: &Value) -> Value {
    if o.get("appel").and_then(Value::as_str) == Some("reglagesOuvrir") {
        // (Update-PageConsole : « window.mindset.reglages($etat, 'onglet', instant, $images) », les faux donnent {})
        return json!({ "appel": "reglages", "args": [{}, o["onglet"], o["instant"], {}] });
    }
    json!({ "appel": o["appel"], "args": o["args"] })
}

/// Les effets de la version Rust traduits en ce que les faux de la version PowerShell notent.
fn notes(effets: &[Effet]) -> (Vec<String>, Vec<Value>) {
    let mut appels = Vec::new();
    let mut scripts = Vec::new();
    for e in effets {
        match e {
            Effet::Ordre(o) => scripts.push(script(o)),
            Effet::Signal { nom, donnees } => {
                let id = texte(donnees.get("id"));
                match nom.as_str() {
                    "ouvrir-appli" => appels.push(format!("ouvrir-ici:{id}")),
                    "lancer-appli" => appels.push(format!(
                        "lancer:{id}:{}",
                        if donnees["demarrage"] == json!(true) { "cache" } else { "normal" }
                    )),
                    "maj-mindset" => appels.push("maj-mindset".into()),
                    "confidentialite" => appels.push(format!("confidentialite:{id}")),
                    "demande-quitter" => appels.push(format!("demande-quitter:{id}")),
                    "fermer-appli" => appels.push(format!("fermer:{id}")),
                    "ouvrir-parametres" => appels.push(format!("page:parametres@{}", texte(donnees.get("onglet")))),
                    "actualiser" => appels.push("actualiser".into()),
                    "reglage-change" => appels.push("reglages-maj".into()),
                    autre => appels.push(format!("signal:{autre}")),
                }
            }
            Effet::Action { id, valeur } if id == "ecrans:carte" => {
                appels.push(format!("{}:{}", texte(valeur.get("quoi")), texte(valeur.get("id"))))
            }
            Effet::Action { id, valeur } if id == "parametres:reglage" => {
                appels.push(format!("reglage-console:{}", texte(valeur.get("quoi"))))
            }
            Effet::Fenetre(Fenetre::Cacher) => appels.push("veille".into()),
            Effet::Page(p) => appels.push(format!("page:{p}")),
            Effet::Exposer { .. } => {}
            autre => appels.push(format!("{autre:?}")),
        }
    }
    (appels, scripts)
}

fn chaines(v: &Value) -> Vec<String> {
    v.as_array().map(|l| l.iter().map(|x| x.as_str().unwrap_or_default().to_string()).collect()).unwrap_or_default()
}

/// Les échecs d'une famille, montrés tous ensemble.
struct Bilan {
    famille: &'static str,
    total: usize,
    echecs: Vec<String>,
}

impl Bilan {
    fn nouveau(famille: &'static str) -> Bilan {
        Bilan { famille, total: 0, echecs: Vec::new() }
    }
    fn verifier(&mut self, nom: &str, ok: bool, detail: impl FnOnce() -> String) {
        self.total += 1;
        if !ok {
            self.echecs.push(format!("{nom} : {}", detail()));
        }
    }
    fn fin(self, au_moins: usize) {
        assert!(
            self.total >= au_moins,
            "{} : {} cas seulement (au moins {au_moins} attendus)",
            self.famille,
            self.total
        );
        assert!(
            self.echecs.is_empty(),
            "{} : {} cas sur {} en échec :\n{}",
            self.famille,
            self.echecs.len(),
            self.total,
            self.echecs.join("\n")
        );
    }
}

// ---------------------------------------------------------------------------------------------------------------
// 1. L'état des applis (Get-EtatConsole, Get-LogoConsole)
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_etat_des_applis() {
    let mut b = Bilan::nouveau("etat-applis");
    for c in cas("etat-applis.json") {
        let nom = texte(c.get("nom"));
        let m = &c["entree"];
        let w = monde(m);
        let mut bloc = console(&w, m);
        let mut e = Effets::default();
        bloc.rafraichir_logos(&w.ctx, &mut e);
        let theme = theme_du_cas(&w, m);
        let logo = |id: &str| bloc.logo(id);
        let sortie = adresses_ps(&calculs::etat_applis(&w.ctx, &theme, &logo));
        b.verifier(&nom, pareil(&sortie, &c["sortie"]), || format!("\n  Rust : {sortie}\n  PS   : {}", c["sortie"]));
        // Les logos écrits dans console-logos, et ceux servis par l'hôte
        let dossier = w.ctx.dans_donnees("console-logos");
        let mut ecrits = Map::new();
        if let Ok(l) = std::fs::read_dir(&dossier) {
            for f in l.flatten() {
                let o = std::fs::read(f.path()).unwrap();
                ecrits.insert(f.file_name().to_string_lossy().to_string(), json!(o));
            }
        }
        let attendus: Map<String, Value> = c["logos_ecrits"]
            .as_object()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .map(|(k, v)| (k, json!(b64(v.as_str().unwrap()).unwrap())))
            .collect();
        b.verifier(&format!("{nom} (logos écrits)"), Value::Object(ecrits) == Value::Object(attendus), String::new);
        b.verifier(&format!("{nom} (journal)"), w.faux.donnees.lignes() == chaines(&c["journal"]), || {
            format!("{:?} / {:?}", w.faux.donnees.lignes(), c["journal"])
        });
        for x in &e.0 {
            let Effet::Exposer { nom: n, chemin } = x else { panic!("{nom} : effet inattendu {x:?}") };
            assert!(n.starts_with("console-logo-") && chemin.as_ref().is_some_and(|p| p.starts_with(&dossier)));
        }
    }
    b.fin(60);
}

// ---------------------------------------------------------------------------------------------------------------
// 2. La carte des mises à jour (Get-EtatMajConsole)
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_carte_des_mises_a_jour() {
    let mut b = Bilan::nouveau("etat-maj");
    for c in cas("etat-maj.json") {
        let nom = texte(c.get("nom"));
        let w = monde(&c["entree"]);
        let theme = theme_du_cas(&w, &c["entree"]);
        let sortie = calculs::etat_maj(&w.ctx, &theme);
        b.verifier(&nom, pareil(&sortie, &c["sortie"]), || format!("\n  Rust : {sortie}\n  PS   : {}", c["sortie"]));
    }
    b.fin(80);
}

// ---------------------------------------------------------------------------------------------------------------
// 3. Les couleurs de la scène, les images du thème, les images animées
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_couleurs_et_theme() {
    let mut b = Bilan::nouveau("theme");
    for c in cas("theme.json") {
        let nom = texte(c.get("nom"));
        let w = monde(&c["entree"]);
        let theme = theme_du_cas(&w, &c["entree"]);
        let couleurs = calculs::json_compact(&Value::Object(calculs::couleurs_console(mindset_console::SCENE, &theme)));
        b.verifier(&format!("{nom} (couleurs)"), couleurs == texte(c.get("couleurs")), || {
            format!("\n  Rust : {couleurs}\n  PS   : {}", c["couleurs"])
        });
        let t = calculs::theme_console(theme.pack.as_ref(), &mut |f| images::fichier_anime(f)).map(|t| adresses_ps(&t));
        let t = t.unwrap_or(Value::Null);
        b.verifier(&format!("{nom} (images)"), pareil(&t, &c["theme"]), || {
            format!("\n  Rust : {t}\n  PS   : {}", c["theme"])
        });
    }
    b.fin(10);
}

#[test]
fn juges_images_animees() {
    let mut b = Bilan::nouveau("images-animees");
    for c in cas("images-animees.json") {
        let o = b64(c["octets"].as_str().unwrap()).unwrap();
        let r = images::image_animee(&o);
        b.verifier(&texte(c.get("nom")), Some(r) == c["animee"].as_bool(), || format!("Rust {r}"));
    }
    b.fin(40);
}

// ---------------------------------------------------------------------------------------------------------------
// 4. Les petites règles
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_petites_regles() {
    let j = juge("regles.json");
    let mut b = Bilan::nouveau("regles");
    for c in j["quand"].as_array().unwrap() {
        let m = moment::lire_iso(c["maintenant"].as_str().unwrap()).unwrap();
        let r = calculs::quand_maj(c["quand"].as_str().unwrap(), &m).unwrap_or_default();
        b.verifier(&format!("quand {}", c["quand"]), r == texte(c.get("texte")), || {
            format!("Rust « {r} », PS {}", c["texte"])
        });
    }
    for c in j["jeu"].as_array().unwrap() {
        let r = calculs::nom_raison_jeu(c["raison"].as_str().unwrap());
        b.verifier(&format!("jeu {}", c["raison"]), r == texte(c.get("nom")), || {
            format!("Rust « {r} », PS {}", c["nom"])
        });
    }
    for c in j["incident"].as_array().unwrap() {
        let r = calculs::reaction_incident(c["genre"].as_str().unwrap());
        b.verifier(&format!("incident {}", c["genre"]), r == texte(c.get("reaction")), || format!("Rust {r}"));
    }
    for c in j["avancee"].as_array().unwrap() {
        let (ctx, f) = essai::contexte(&format!("console-avancee-{}", NUMERO.fetch_add(1, Ordering::SeqCst)));
        let id = c["id"].as_str().unwrap();
        if !c["reglage"].is_null() {
            ctx.ecrire_reglage(&format!("Ouverture-{id}"), c["reglage"].clone());
        }
        let e = c["ecoule"].as_f64().unwrap();
        let r = calculs::avancee_ouverture(calculs::duree_attendue(&ctx, id), e);
        let attendu = match &c["avancee"] {
            // (une durée illisible : PowerShell levait une erreur, la version Rust prend 8 s : DIVERGENCES.md)
            Value::String(s) if s == "erreur" => calculs::avancee_ouverture(8.0, e),
            v => v.as_f64().unwrap(),
        };
        b.verifier(&format!("avancée {id} {} {e}", c["reglage"]), (r - attendu).abs() < 1e-9, || {
            format!("Rust {r}, PS {}", c["avancee"])
        });
        let _ = std::fs::remove_dir_all(&f.racine);
    }
    b.fin(200);
}

// ---------------------------------------------------------------------------------------------------------------
// 5. Les incidents dans le temps
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_incidents() {
    let mut b = Bilan::nouveau("incidents");
    for c in cas("incidents.json") {
        let nom = texte(c.get("nom"));
        let w = monde(&json!({ "applis": [], "partage": {} }));
        w.ctx.definir_vue(Vue { visible: true, reduite: false, page: "accueil".into() });
        let mut bloc = console(&w, &json!({ "console": { "possible": true, "cadre": true, "pret": true } }));
        for (i, p) in c["etapes"].as_array().unwrap().iter().enumerate() {
            let pas = &p["pas"];
            w.ctx.avancer(std::time::Duration::from_secs_f64(pas["attendre"].as_f64().unwrap()));
            let avant = w.faux.donnees.lignes().len();
            let mut e = Effets::default();
            match pas["quoi"].as_str().unwrap() {
                "incident" => bloc.incident(&w.ctx, pas["genre"].as_str().unwrap(), &mut e),
                // (Mindset rouvert : Resume-ConsoleArretee, puis la page d'accueil la remontre)
                "rouvrir" => {
                    bloc.reprendre_arretee(&w.ctx);
                    bloc.mettre_a_jour_page(&w.ctx, &mut e);
                }
                "reglage" => w.ctx.ecrire_reglage("Animations", pas["valeur"].clone()),
                q => panic!("pas inconnu {q}"),
            }
            let journal: Vec<String> = w.faux.donnees.lignes()[avant..].to_vec();
            let ok = bloc.possible() == p["possible"].as_bool().unwrap()
                && bloc.arretee() == p["arretee"].as_bool().unwrap()
                && bloc.nombre_incidents() as u64 == p["incidents"].as_u64().unwrap()
                && journal == chaines(&p["journal"])
                // (la 3D recréée après un incident, l'accueil étant à l'écran ; sinon pas de cadre)
                && bloc.cadre().is_some() == bloc.possible();
            b.verifier(&format!("{nom}, étape {}", i + 1), ok, || {
                format!(
                    "Rust : possible {}, arrêtée {}, incidents {}, journal {journal:?} ; PS : {p}",
                    bloc.possible(),
                    bloc.arretee(),
                    bloc.nombre_incidents()
                )
            });
        }
    }
    b.fin(20);
}

// ---------------------------------------------------------------------------------------------------------------
// 6. Quelle page montrer (Update-PageConsole)
// ---------------------------------------------------------------------------------------------------------------

fn final_rust(bloc: &mut BlocConsole, ctx: &Contexte) -> Value {
    let etat = bloc.etat(ctx);
    json!({
        "possible": bloc.possible(),
        "cadre": bloc.cadre().is_some(),
        "pret": bloc.pret(),
        "derniere": bloc.derniere_appli(),
        "ejecter": bloc.ejecter(),
        "en_fente": bloc.en_fente(),
        "attente": bloc.attente(),
        "lancee": bloc.lancee(),
        "parametres": bloc.parametres_ouverts(),
        "quittee": bloc.quittee(),
        "a_jouer": bloc.a_jouer().iter().map(script).collect::<Vec<_>>(),
        "page_console": if etat["console"]["visible"] == json!(true) { "Visible" } else { "Collapsed" },
    })
}

fn comparer_final(rust: &Value, ps: &Value, champs: &[&str]) -> Vec<String> {
    champs
        .iter()
        .filter(|k| !pareil(&rust[**k], &ps[**k]))
        .map(|k| format!("{k} : Rust {} / PS {}", rust[*k], ps[*k]))
        .collect()
}

#[test]
fn juges_page() {
    let mut b = Bilan::nouveau("page");
    for c in cas("page.json") {
        let nom = texte(c.get("nom"));
        let m = &c["entree"];
        let w = monde(m);
        let mut bloc = console(&w, m);
        let cadre_avant = bloc.cadre();
        let mut e = Effets::default();
        bloc.mettre_a_jour_page(&w.ctx, &mut e);
        let (mut appels, scripts) = notes(&e.0);
        if cadre_avant.is_none() && bloc.cadre().is_some() {
            let a = bloc.adresse_cadre().unwrap_or_default();
            let depart = if a.contains("vue=dedans") { "dedans" } else { "menu" };
            appels.insert(0, format!("vue:{depart}"));
        }
        let ps = &c["notes"];
        let mut final_ps = c["final"].clone();
        final_ps["a_jouer"] = scripts_ps(&final_ps["a_jouer"]);
        let ecarts = comparer_final(
            &final_rust(&mut bloc, &w.ctx),
            &final_ps,
            &["possible", "cadre", "pret", "derniere", "ejecter", "parametres", "quittee", "a_jouer", "page_console"],
        );
        let ok = appels == chaines(&ps["appels"])
            && pareil(&json!(scripts), &scripts_ps(&ps["scripts"]))
            && ecarts.is_empty();
        b.verifier(&nom, ok, || {
            format!(
                "\n  Rust : {appels:?} {}\n  PS   : {} {}\n  {ecarts:?}",
                json!(scripts),
                ps["appels"],
                scripts_ps(&ps["scripts"])
            )
        });
    }
    b.fin(18);
}

// ---------------------------------------------------------------------------------------------------------------
// 7. Ce que la scène demande (Receive-MessageConsole)
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn juges_messages() {
    let mut b = Bilan::nouveau("messages");
    for c in cas("messages.json") {
        let nom = texte(c.get("nom"));
        assert!(c["erreur"].is_null(), "{nom} : la version PowerShell a levé une erreur ({})", c["erreur"]);
        let m = &c["entree"];
        let w = monde(m);
        let mut bloc = console(&w, m);
        let message: Value = serde_json::from_str(c["message"].as_str().unwrap()).unwrap();
        let mut reste = message.as_object().unwrap().clone();
        let type_ = reste.remove("type").and_then(|t| t.as_str().map(str::to_string)).unwrap();
        let attente_avant = bloc.attente().is_some();
        let lignes_avant = w.faux.donnees.lignes().len();
        let mut e = Effets::default();
        assert!(
            bloc.action(&w.ctx, &format!("console:{type_}"), &Value::Object(reste), &mut e),
            "{nom} : action pas prise"
        );
        // « Actualiser » : la recherche demandée a eu lieu (ou non), puis le message vient au tic suivant
        if m["actualiser_change"] == json!(true) {
            w.ctx.au_nom_de("publications", || {
                w.ctx.publier(partage::RECHERCHE, json!({ "derniere": "2026-11-07T20:00:00" }))
            });
        }
        if texte(message.get("action")) == "actualiser" {
            bloc.tic(&w.ctx, &mut e);
        }
        let (mut appels, scripts) = notes(&e.0);
        if !attente_avant && bloc.attente().is_some() {
            appels.push("attente".into());
        }
        let ps = &c["notes"];
        let ps_appels: Vec<String> =
            chaines(&ps["appels"]).into_iter().filter(|a| !a.starts_with("reglage:")).collect();
        let journal: Vec<String> = w.faux.donnees.lignes()[lignes_avant..].to_vec();
        let mut ecarts = comparer_final(
            &final_rust(&mut bloc, &w.ctx),
            &c["final"],
            &["pret", "derniere", "en_fente", "attente", "lancee", "parametres"],
        );
        // Les réglages écrits (Set-Setting)
        for (k, v) in c["final"]["reglages"].as_object().cloned().unwrap_or_default() {
            let r = w.ctx.reglage(&k).unwrap_or(Value::Null);
            if !pareil(&r, &v) {
                ecarts.push(format!("réglage {k} : Rust {r} / PS {v}"));
            }
        }
        let ok = appels == ps_appels
            && pareil(&json!(scripts), &scripts_ps(&ps["scripts"]))
            && journal == chaines(&ps["journal"])
            && ecarts.is_empty();
        b.verifier(&nom, ok, || {
            format!(
                "\n  Rust : {appels:?} {} {journal:?}\n  PS   : {ps_appels:?} {} {}\n  {ecarts:?}",
                json!(scripts),
                scripts_ps(&ps["scripts"]),
                ps["journal"]
            )
        });
    }
    b.fin(40);
}

// ---------------------------------------------------------------------------------------------------------------
// La contre-épreuve : un juge abîmé d'un octet doit échouer
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn contre_epreuve_un_octet_change_fait_echouer() {
    let c = &cas("etat-maj.json")[6];
    let w = monde(&c["entree"]);
    let theme = theme_du_cas(&w, &c["entree"]);
    let sortie = calculs::etat_maj(&w.ctx, &theme);
    assert!(pareil(&sortie, &c["sortie"]));
    // Chaque champ changé d'un rien : le test le voit
    let texte_juge = c["sortie"].to_string();
    let mut vus = 0;
    for (i, o) in texte_juge.bytes().enumerate() {
        let remplace = match o {
            b'0'..=b'8' => o + 1,
            b'a'..=b'y' => o + 1,
            _ => continue,
        };
        let mut abime = texte_juge.clone().into_bytes();
        abime[i] = remplace;
        let Ok(v) = serde_json::from_slice::<Value>(&abime) else { continue };
        if v != c["sortie"] {
            vus += 1;
            assert!(!pareil(&sortie, &v), "octet {i} changé ({}) : pas vu", String::from_utf8_lossy(&abime));
        }
    }
    assert!(vus > 50, "{vus} octets essayés");
}

#[test]
fn les_logos_livres_sont_ceux_du_dossier() {
    let d = Path::new(env!("CARGO_MANIFEST_DIR")).join("../mindset-appli/ui/console/logos");
    let mut l: Vec<String> = std::fs::read_dir(&d)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().trim_end_matches(".png").to_string())
        .collect();
    l.sort();
    assert_eq!(l, mindset_console::LOGOS_LIVRES);
}

/// Le base64 des juges (`[Convert]::ToBase64String`).
fn b64(t: &str) -> Option<Vec<u8>> {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut sortie = Vec::new();
    let (mut acc, mut n) = (0u32, 0u32);
    for c in t.bytes().filter(|c| *c != b'=') {
        acc = (acc << 6) | A.iter().position(|x| *x == c)? as u32;
        n += 6;
        if n >= 8 {
            n -= 8;
            sortie.push((acc >> n) as u8);
            acc &= (1 << n) - 1;
        }
    }
    Some(sortie)
}

/// Les scripts notés par la version PowerShell (`{ appel, args: "<texte JSON>" }`), arguments lus.
fn scripts_ps(v: &Value) -> Value {
    Value::Array(
        v.as_array()
            .map(|l| {
                l.iter()
                    .map(|s| {
                        let args: Value =
                            serde_json::from_str(s["args"].as_str().unwrap_or("[]")).unwrap_or(Value::Null);
                        json!({ "appel": s["appel"], "args": args })
                    })
                    .collect()
            })
            .unwrap_or_default(),
    )
}
