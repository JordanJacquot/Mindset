//! Les juges : les scénarios rejoués sur la version PowerShell (outils\exporter-juges-accrochage.ps1, les vraies
//! fonctions d'integration.ps1 et de chargement.ps1 sur des fenêtres et des programmes inventés) sont rejoués ici sur le
//! bloc Rust, par ses seules entrées (signaux, actions, tics, fermeture) et ses seules sorties (l'état de la page, le
//! tableau commun, les signaux, le journal, les réglages, ce qui a été fait aux fenêtres). Après chaque pas, ce que
//! montre et fait le bloc doit être exactement ce que montrait et faisait la version PowerShell.
//!
//! Plus la contre-épreuve : un juge changé d'un seul caractère doit faire échouer la comparaison.

use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::time::Duration;

use mindset_accrochage::{BlocAccrochage, FauxFenetres, Fenetres, fenetres::DEPART_ESSAI};
use mindset_noyau::essai::{self, Faux};
use mindset_noyau::{Appli, Bloc, Contexte, Effet, Effets, Lancement, partage};

const JUGES: &str = include_str!("juges/accrochage.json");

fn texte(v: &Value, c: &str) -> String {
    v.get(c).and_then(Value::as_str).unwrap_or("").to_string()
}

fn appli(v: &Value) -> Appli {
    Appli {
        id: texte(v, "Id"),
        nom: texte(v, "Nom"),
        couleur: texte(v, "Couleur"),
        exe: texte(v, "Exe"),
        mutex: texte(v, "Mutex"),
        ancien_mutex: texte(v, "AncienMutex"),
        admin: v.get("Admin").and_then(Value::as_bool).unwrap_or(false),
        sans_droits_depuis: texte(v, "SansDroitsDepuis"),
        cache_depuis: texte(v, "CacheDepuis"),
        ..Default::default()
    }
}

fn dossier(id: &str) -> String {
    format!(r"C:\Essai\Programmes\{id}")
}

/// Le banc : le bloc, ses faux, et ce que l'hôte et les autres blocs auraient fait de ses demandes.
struct Banc {
    ctx: Contexte,
    faux: Faux,
    f: FauxFenetres,
    bloc: BlocAccrochage,
    installations: Map<String, Value>,
    zone: (i64, i64),
    /// Une zone avec sa taille a déjà été envoyée au bloc
    zone_envoyee: bool,
    journal_vu: usize,
    arretes_vu: usize,
    lances: Vec<Value>,
    demandes: Vec<Value>,
}

impl Banc {
    fn nouveau(nom: &str, applis: Vec<Appli>, admin: bool) -> Banc {
        let (ctx, faux) = essai::contexte_avec(nom, Lancement { admin, ..Default::default() });
        ctx.definir_applis(applis);
        ctx.definir_fenetre(Some(77));
        let mut v = ctx.vue();
        v.visible = true;
        ctx.definir_vue(v);
        let f = FauxFenetres::nouveau();
        let bloc = BlocAccrochage::avec(Box::new(f.clone()));
        let mut b = Banc {
            ctx,
            faux,
            f,
            bloc,
            installations: Map::new(),
            zone: (0, 0),
            zone_envoyee: false,
            journal_vu: 0,
            arretes_vu: 0,
            lances: Vec::new(),
            demandes: Vec::new(),
        };
        let mut e = Effets::default();
        b.ctx.au_nom_de("accrochage", || b.bloc.demarrer(&b.ctx, &mut e));
        b.effets(e);
        b
    }

    fn avancer(&self, s: f64) {
        let ms = (s * 1000.0).round() as u64;
        self.ctx.avancer(Duration::from_millis(ms));
        self.f.avancer_ms(ms);
    }

    fn publier_installations(&self) {
        let v = Value::Object(self.installations.clone());
        self.ctx.au_nom_de("installations", || self.ctx.publier(partage::INSTALLATIONS, v));
    }

    /// Ce que l'hôte et les autres blocs font des demandes du bloc.
    fn effets(&mut self, e: Effets) {
        for x in e.0 {
            match x {
                Effet::Signal { nom, donnees } => match nom.as_str() {
                    "lancer-appli" => {
                        self.lances.push(json!({ "id": donnees["id"], "demarrage": donnees["demarrage"] }))
                    }
                    "demande-quitter" => self.demandes.push(donnees["id"].clone()),
                    autre => panic!("signal inattendu : {autre}"),
                },
                Effet::Page(id) => self.page(&id),
                Effet::Tache(t) => {
                    let id = t.id.clone();
                    let r = t.lancer();
                    let mut e2 = Effets::default();
                    self.ctx.au_nom_de("accrochage", || self.bloc.tache_finie(&self.ctx, &id, r, &mut e2));
                    self.effets(e2);
                }
                autre => panic!("effet inattendu : {autre:?}"),
            }
        }
    }

    fn signal(&mut self, nom: &str, d: Value) {
        let mut e = Effets::default();
        self.ctx.au_nom_de("accrochage", || self.bloc.signal(&self.ctx, nom, &d, &mut e));
        self.effets(e);
    }

    fn action(&mut self, id: &str, v: Value) {
        let mut e = Effets::default();
        let pris = self.ctx.au_nom_de("accrochage", || self.bloc.action(&self.ctx, id, &v, &mut e));
        assert!(pris, "action {id} non prise");
        self.effets(e);
    }

    fn page_appli(&self) -> bool {
        let p = self.ctx.vue().page;
        p != "accueil" && p != "parametres"
    }

    /// La zone envoyée par la coquille (sans taille quand la page de l'appli n'est pas montrée).
    fn envoyer_zone(&mut self) {
        let (l, h) = self.zone;
        let z = if self.page_appli() && l > 0 && h > 0 {
            self.zone_envoyee = true;
            json!({ "x": 210, "y": 96, "largeur": l, "hauteur": h, "visible": true })
        } else {
            json!({ "x": 0, "y": 0, "largeur": 0, "hauteur": 0, "visible": false })
        };
        self.action("accrochage:zone", z);
    }

    /// Effet::Page de l'hôte : la vue, le signal « page » à tous, puis la coquille redit la place de la zone.
    fn page(&mut self, id: &str) {
        let mut v = self.ctx.vue();
        let avant = std::mem::replace(&mut v.page, id.to_string());
        self.ctx.definir_vue(v);
        self.signal("page", json!({ "id": id, "avant": avant }));
        self.envoyer_zone();
    }

    fn pas(&mut self, p: &Value) {
        let q = texte(p, "q");
        let n = |c: &str| p.get(c).and_then(Value::as_f64).unwrap_or(0.0);
        let id = texte(p, "id");
        match q.as_str() {
            "installer" => {
                self.installations.insert(
                    id.clone(),
                    json!({ "dossier": dossier(&id), "gere": true, "version": p.get("version").cloned().unwrap_or(Value::Null) }),
                );
                self.publier_installations();
            }
            "desinstaller" => {
                self.installations.remove(&id);
                self.publier_installations();
            }
            "processus" => {
                let creation = if p.get("illisible").and_then(Value::as_bool).unwrap_or(false) {
                    0
                } else {
                    self.f.maintenant() - (n("age") * 10_000_000.0) as u64
                };
                let chemin = format!(r"{}\{}", dossier(&id), texte(p, "nom"));
                self.faux.systeme.ajouter_processus(n("pid") as u32, &chemin, creation);
            }
            "fin_processus" => self.faux.systeme.retirer_processus(n("pid") as u32),
            "verrou" => self.faux.systeme.poser_verrou(&texte(p, "nom"), p["tenu"].as_bool().unwrap_or(false)),
            "fenetre" => {
                let classe = texte(p, "classe");
                self.f.creer(
                    n("h") as isize,
                    n("pid") as u32,
                    &texte(p, "titre"),
                    if classe.is_empty() { "Tauri Window" } else { &classe },
                    p.get("possedee").and_then(Value::as_bool).unwrap_or(false),
                    p.get("visible").and_then(Value::as_bool).unwrap_or(false),
                );
            }
            "detruire" => self.f.detruire(n("h") as isize),
            "cacher" => self.f.changer(n("h") as isize, |x| x.visible = false),
            "barre" => {
                let oui = p["oui"].as_bool().unwrap_or(false);
                self.f.changer(n("h") as isize, |x| x.barre_propre = oui);
            }
            "refus" => self.f.changer(n("h") as isize, |x| x.refus = true),
            "reglage" => self.ctx.ecrire_reglage(&texte(p, "nom"), p["valeur"].clone()),
            "attendre" => self.avancer(n("s")),
            "tic" => {
                self.avancer(0.4);
                let mut e = Effets::default();
                self.ctx.au_nom_de("accrochage", || self.bloc.tic(&self.ctx, &mut e));
                self.effets(e);
            }
            "page" => self.page(&id),
            "ouvrir" => self.signal("ouvrir-appli", json!({ "id": id, "lancer": true })),
            "ici" => {
                let page = self.ctx.vue().page;
                self.action("accrochage:ouvrir-ici", json!(page));
            }
            "fermer" => self.action("accrochage:fermer", Value::Null),
            "fermer_appli" => self.signal("fermer-appli", json!({ "id": id })),
            "voile" => {
                let v = p["visible"].as_bool().unwrap_or(false);
                self.ctx.au_nom_de("ecrans", || self.ctx.publier(partage::VOILE, json!(v)));
                self.signal("voile", json!({ "visible": v }));
            }
            "zone" => {
                let (l, h) = (n("largeur") as i64, n("hauteur") as i64);
                if l > 0 && h > 0 {
                    self.zone = (l, h);
                    self.envoyer_zone();
                } else {
                    // (Mindset réduit : la coquille envoie une zone sans taille)
                    self.action(
                        "accrochage:zone",
                        json!({ "x": 0, "y": 0, "largeur": l, "hauteur": h, "visible": false }),
                    );
                }
            }
            "quitter" => self.ctx.au_nom_de("accrochage", || self.bloc.fermer(&self.ctx)),
            autre => panic!("pas inconnu : {autre}"),
        }
    }

    /// Ce que montre et fait le bloc, dans la forme de `Get-Instantane` (l'exporteur).
    fn instantane(&mut self) -> Value {
        let page = self.ctx.vue().page;
        let accrochees = self.ctx.lu(partage::ACCROCHEES).unwrap_or(json!({}));
        let mut int = BTreeMap::new();
        for (id, a) in accrochees.as_object().into_iter().flatten() {
            int.insert(
                id.clone(),
                json!({
                    "etat": a["etat"],
                    "fenetre": a["fenetre"],
                    "pid": a["pid"],
                    "hote": self.f.hote_de(id).is_some_and(|h| h.visible),
                }),
            );
        }
        let etat = self.ctx.au_nom_de("accrochage", || self.bloc.etat(&self.ctx));
        let pa = etat["pages_applis"].get(&page).cloned();
        let appli = self.page_appli();
        let (mut ecran, mut cadre, mut barre) = (Value::Null, Value::Null, Value::Null);
        if appli {
            let pa = pa.unwrap_or_else(|| panic!("pages_applis sans la page {page}"));
            let montree = pa["montree"].as_bool().unwrap();
            cadre = json!(montree);
            barre = json!(!pa["barre_propre"].as_bool().unwrap());
            if !montree {
                let jauge = if let Some(j) = pa["jauge"].as_object() {
                    let t0 = (DEPART_ESSAI as i64 - 116_444_736_000_000_000) / 10_000;
                    let depuis = (j["depuis_ms"].as_i64().unwrap() - t0) as f64 / 1000.0;
                    json!({ "ecran": false, "depuis": (depuis * 10.0).round() / 10.0, "duree": j["duree_s"] })
                } else if pa["ecran_ouvrir"].as_bool().unwrap() {
                    json!({ "ecran": true })
                } else {
                    Value::Null
                };
                let ici = pa["bouton_ici"].as_bool().unwrap();
                ecran = json!({
                    "titre": pa["titre"],
                    "couleur": pa["couleur"],
                    "texte": pa["texte"],
                    "bouton_ici": ici,
                    "bouton_texte": if ici { pa["bouton_texte"].clone() } else { json!("") },
                    "jauge": jauge,
                });
            }
        }
        let lignes = self.faux.donnees.lignes();
        let journal: Vec<String> = lignes[self.journal_vu..].to_vec();
        self.journal_vu = lignes.len();
        let arretes = self.faux.systeme.arretes();
        let nouveaux: Vec<u32> = arretes[self.arretes_vu..].to_vec();
        self.arretes_vu = arretes.len();
        let mut reglages = BTreeMap::new();
        for (k, v) in self.faux.donnees.reglages() {
            if k.starts_with("Ouverture-") {
                reglages.insert(k, v);
            }
        }
        json!({
            "page": page,
            "integrees": int,
            "ecran": ecran,
            "cadre": cadre,
            "barre": barre,
            "minuterie": self.bloc.minuterie(),
            "journal": journal,
            "appels": self.f.prendre_appels(),
            "lances": std::mem::take(&mut self.lances),
            "arretes": nouveaux,
            "demandes": std::mem::take(&mut self.demandes),
            "reglages": reglages,
        })
    }
}

/// Deux valeurs JSON égales (les nombres à 1e-9 près : 12 et 12.0 sont égaux). Rend le chemin de la première
/// différence.
fn difference(a: &Value, b: &Value, chemin: &str) -> Option<String> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (x.as_f64().unwrap(), y.as_f64().unwrap());
            ((x - y).abs() > 1e-9).then(|| format!("{chemin} : {x} au lieu de {y}"))
        }
        (Value::Object(x), Value::Object(y)) => {
            let mut cles: Vec<&String> = x.keys().chain(y.keys()).collect();
            cles.sort();
            cles.dedup();
            cles.into_iter().find_map(|k| {
                difference(x.get(k).unwrap_or(&Value::Null), y.get(k).unwrap_or(&Value::Null), &format!("{chemin}.{k}"))
            })
        }
        (Value::Array(x), Value::Array(y)) => {
            if x.len() != y.len() {
                return Some(format!("{chemin} : {a} au lieu de {b}"));
            }
            x.iter().zip(y).enumerate().find_map(|(k, (u, v))| difference(u, v, &format!("{chemin}[{k}]")))
        }
        _ => (a != b).then(|| format!("{chemin} : {a} au lieu de {b}")),
    }
}

/// Les seules différences voulues, chacune décrite dans DIVERGENCES.md :
/// - point 1 : avant la toute première page d'appli (`zone_inconnue`), la coquille n'a pas encore donné la taille de la
///   zone (elle ne la mesure que montrée), alors que le panneau WPF avait déjà la sienne. Le bloc accroche alors à
///   200 x 200 (comme un panneau sans taille), puis redimensionne dès que la zone arrive, dans le même pas. Ces deux
///   appels valent le seul « accrocher h L x H » de la version PowerShell ; refusé, « accrocher h 200x200 » vaut
///   « accrocher h L x H » ;
/// - point 2 : en quittant, les fenêtres sont rendues dans l'ordre où les applis ont été ouvertes (la version
///   PowerShell : l'ordre d'une table de hachage, sans règle) ; seul l'ensemble compte.
fn normaliser(vu: &mut Value, attendu: &Value, zone_inconnue: bool, quitter: bool) {
    let (Some(v), Some(a)) = (vu["appels"].as_array().cloned(), attendu["appels"].as_array()) else { return };
    if &v == a {
        return;
    }
    let mut l: Vec<String> = v.iter().filter_map(|x| x.as_str().map(str::to_string)).collect();
    let a: Vec<String> = a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect();
    if quitter {
        let (mut x, mut y) = (l.clone(), a.clone());
        x.sort();
        y.sort();
        if x == y {
            vu["appels"] = json!(a);
        }
        return;
    }
    if !zone_inconnue {
        return;
    }
    for i in 0..l.len() {
        let Some(h) = l[i].strip_prefix("accrocher ").and_then(|r| r.strip_suffix(" 200x200")).map(str::to_string)
        else {
            continue;
        };
        let debut = format!("redimensionner {h} ");
        if let Some(j) = (i + 1..l.len()).find(|&j| l[j].starts_with(&debut)) {
            let taille = l[j][debut.len()..].to_string();
            l[i] = format!("accrocher {h} {taille}");
            l.remove(j);
        } else if let Some(x) = a.iter().find(|x| x.starts_with(&format!("accrocher {h} "))) {
            l[i] = x.clone();
        }
        break;
    }
    if l == a {
        vu["appels"] = json!(l);
    }
}

/// Rejoue tous les scénarios ; rend les différences (vide : tout est pareil) et le nombre de pas.
fn rejouer(juges: &Value) -> (Vec<String>, usize) {
    let mut erreurs = Vec::new();
    let mut n = 0;
    for (k, s) in juges["scenarios"].as_array().expect("scénarios").iter().enumerate() {
        let nom = texte(s, "nom");
        let applis = s["applis"].as_array().unwrap().iter().map(appli).collect();
        let mut b = Banc::nouveau(&format!("juge-{k}"), applis, s["admin"].as_bool().unwrap_or(false));
        let pas = s["pas"].as_array().unwrap();
        let attendu = s["attendu"].as_array().unwrap();
        assert_eq!(pas.len(), attendu.len(), "{nom}");
        for (i, (p, a)) in pas.iter().zip(attendu).enumerate() {
            let zone_inconnue = !b.zone_envoyee;
            b.pas(p);
            n += 1;
            let mut vu = b.instantane();
            normaliser(&mut vu, a, zone_inconnue, texte(p, "q") == "quitter");
            if let Some(d) = difference(&vu, a, "") {
                erreurs.push(format!("« {nom} », pas {i} ({p}) : {d}"));
                break;
            }
        }
        let _ = std::fs::remove_dir_all(&b.faux.racine);
    }
    (erreurs, n)
}

#[test]
fn les_juges_powershell() {
    let juges: Value = serde_json::from_str(JUGES).expect("juges lisibles");
    let (erreurs, n) = rejouer(&juges);
    assert!(n > 1000, "trop peu de pas : {n}");
    assert!(
        erreurs.is_empty(),
        "{} scénarios différents de la version PowerShell :\n{}",
        erreurs.len(),
        erreurs.join("\n")
    );
}

#[test]
fn contre_epreuve_un_caractere_change_fait_echouer() {
    // Des changements d'un seul caractère, à des endroits différents des juges : chacun doit être vu
    let changements = [
        ("est fermé.", "est fermè."),
        ("\"demarrage\":true", "\"demarrage\":fals"),
        ("Evermind affiché dans Mindset", "Evermind affiché dans Mindsex"),
        ("\"etat\":\"lancement\"", "\"etat\":\"lancemenu\""),
        ("accrocher 1001 1100x760", "accrocher 1001 1100x761"),
        ("\"duree\":7.3", "\"duree\":7.4"),
        ("\"minuterie\":true", "\"minuterie\":tru0"),
        ("\"hote\":true", "\"hote\":fals0"),
    ];
    for (avant, apres) in changements {
        assert!(JUGES.contains(avant), "le juge ne contient pas {avant}");
        let change = JUGES.replacen(avant, apres, 1);
        let Ok(juges) = serde_json::from_str::<Value>(&change) else {
            // (un caractère qui casse le JSON : l'échec est déjà là)
            continue;
        };
        let (erreurs, _) = rejouer(&juges);
        assert!(!erreurs.is_empty(), "« {avant} » changé en « {apres} » n'a pas été vu");
    }
}
