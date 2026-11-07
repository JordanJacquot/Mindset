//! Les juges : les réponses de la version PowerShell (exportées par `outils\exporter-juges-publications.ps1` dans
//! tests\juges\*.json), rejouées ici devant le même faux GitHub. Chaque juge doit donner exactement la même sortie.
//!
//! La contre-épreuve : un juge changé d'un caractère doit faire échouer la comparaison (sinon le test ne prouverait
//! rien). Les cas jamais vus : 40 cas tirés au hasard par l'exportation (graine fixe), et ici des entrées tirées au
//! hasard comparées à une autre lecture (suite_commun pour les versions, aller-retour pour le HTML).

use std::path::PathBuf;
use std::time::Duration;

use mindset_noyau::reseau::{FauxReseau, Methode, ReponseHttp};
use mindset_noyau::{Appli, Bloc, Effet, Effets, essai, moment, signaux};
use serde_json::{Value, json};

use crate::bloc::BlocPublications;
use crate::entites::ENTITES;
use crate::github;
use crate::html;
use crate::telechargement::adresse_telechargement;
use crate::version_net::{self, VersionNet};

fn juge(nom: &str) -> Value {
    let f = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(nom);
    let t = std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{} : {e}", f.display()));
    serde_json::from_str(t.trim_start_matches('\u{feff}')).unwrap_or_else(|e| panic!("{nom} : {e}"))
}

fn t(v: &Value) -> String {
    v.as_str().unwrap_or("").to_string()
}

/// Le faux GitHub d'un juge : `[{ url, statut, corps, location, erreur }]`.
fn faux_github(entrees: &Value) -> FauxReseau {
    let f = FauxReseau::default();
    for e in entrees.as_array().into_iter().flatten() {
        let url = t(&e["url"]);
        if !t(&e["erreur"]).is_empty() {
            f.repondre(&url, Err(t(&e["erreur"])));
            continue;
        }
        let mut r = ReponseHttp {
            statut: e["statut"].as_u64().unwrap_or(200) as u16,
            corps: t(&e["corps"]).into_bytes(),
            ..Default::default()
        };
        if !t(&e["location"]).is_empty() {
            r.entetes.push(("Location".into(), t(&e["location"])));
        }
        f.repondre(&url, Ok(r));
    }
    f
}

fn demandes(f: &FauxReseau) -> Value {
    Value::Array(
        f.demandes()
            .iter()
            .map(|d| json!(format!("{} {}", if d.methode == Methode::Head { "HEAD" } else { "GET" }, d.adresse)))
            .collect(),
    )
}

/// Un tableau JSON, même si PowerShell a écrit un seul élément ou rien.
fn liste(v: &Value) -> Vec<Value> {
    match v {
        Value::Array(a) => a.clone(),
        Value::Null => Vec::new(),
        x => vec![x.clone()],
    }
}

fn ecart(quoi: &str, attendu: &Value, obtenu: &Value) -> Result<(), String> {
    if attendu == obtenu { Ok(()) } else { Err(format!("{quoi} : attendu {attendu}, obtenu {obtenu}")) }
}

// ---------------------------------------------------------------------------------------------------------------
// Get-Publication
// ---------------------------------------------------------------------------------------------------------------

fn verifier_publication(c: &Value) -> Result<(), String> {
    let nom = t(&c["nom"]);
    if !c["exception"].is_null() {
        return Err(format!("{nom} : la version PowerShell a levé une erreur ({})", c["exception"]));
    }
    let f = faux_github(&c["github"]);
    let zips: Vec<String> = liste(&c["zips"]).iter().map(t).collect();
    let r = github::publication(&f, &t(&c["depot"]), &zips, c["essai"].as_bool().unwrap_or(false));
    ecart(&format!("{nom} (résultat)"), &c["resultat"], &github::en_ps(&r))?;
    ecart(&format!("{nom} (questions)"), &Value::Array(liste(&c["demandes"])), &demandes(&f))
}

#[test]
fn juges_publications() {
    let cas = juge("publications.json");
    let cas = cas.as_array().expect("une liste");
    assert!(cas.len() >= 90, "{} cas seulement", cas.len());
    let erreurs: Vec<String> = cas.iter().filter_map(|c| verifier_publication(c).err()).collect();
    assert!(erreurs.is_empty(), "{} juges sur {} échouent :\n{}", erreurs.len(), cas.len(), erreurs.join("\n"));
}

// ---------------------------------------------------------------------------------------------------------------
// Get-NotesPage, HtmlDecode, Test-AdresseTelechargement, Test-VersionPlusRecente
// ---------------------------------------------------------------------------------------------------------------

fn verifier_notes(c: &Value) -> Result<(), String> {
    let nom = t(&c["nom"]);
    let f = faux_github(&c["github"]);
    let n = github::notes_page(&f, &t(&c["depot"]), &t(&c["version"]));
    ecart(&nom, &c["notes"], &json!(n))?;
    ecart(&format!("{nom} (questions)"), &Value::Array(liste(&c["demandes"])), &demandes(&f))
}

#[test]
fn juges_notes() {
    let cas = juge("notes.json");
    let erreurs: Vec<String> = liste(&cas).iter().filter_map(|c| verifier_notes(c).err()).collect();
    assert!(erreurs.is_empty(), "{}", erreurs.join("\n"));
}

fn verifier_html(h: &Value) -> Result<(), String> {
    let entites: Vec<Value> = ENTITES.iter().map(|(n, c)| json!({ "nom": n, "code": c })).collect();
    ecart("table des noms", &h["entites"], &Value::Array(entites))?;
    for d in liste(&h["decode"]) {
        ecart(&format!("HtmlDecode {}", d["entree"]), &d["sortie"], &json!(html::decoder(&t(&d["entree"]))))?;
    }
    Ok(())
}

#[test]
fn juges_html() {
    let h = juge("html.json");
    assert!(liste(&h["decode"]).len() >= 40);
    verifier_html(&h).unwrap();
}

fn verifier_adresses(a: &Value) -> Result<(), String> {
    for x in liste(a) {
        ecart(&format!("adresse {}", x["adresse"]), &x["acceptee"], &json!(adresse_telechargement(&t(&x["adresse"]))))?;
    }
    Ok(())
}

#[test]
fn juges_adresses() {
    verifier_adresses(&juge("adresses.json")).unwrap();
}

fn verifier_versions(v: &Value) -> Result<(), String> {
    for l in liste(&v["lectures"]) {
        let lue = VersionNet::lire(&t(&l["texte"])).map(|x| x.texte());
        ecart(&format!("[version] {}", l["texte"]), &l["version"], &json!(lue))?;
    }
    for c in liste(&v["comparaisons"]) {
        let r = version_net::plus_recente(&t(&c["a"]), &t(&c["b"]));
        ecart(&format!("Test-VersionPlusRecente {} {}", c["a"], c["b"]), &c["plus_recente"], &json!(r))?;
    }
    Ok(())
}

#[test]
fn juges_versions() {
    let v = juge("versions.json");
    assert!(liste(&v["comparaisons"]).len() > 200);
    verifier_versions(&v).unwrap();
}

// ---------------------------------------------------------------------------------------------------------------
// Les scénarios : la recherche pas à pas
// ---------------------------------------------------------------------------------------------------------------

fn verifier_scenario(s: &Value, n: usize) -> Result<(), String> {
    let nom = t(&s["nom"]);
    let (ctx, faux) = essai::contexte(&format!("publications-scenario-{n}"));
    let applis: Vec<Appli> = liste(&s["applis"])
        .iter()
        .map(|a| Appli {
            id: t(&a["id"]),
            nom: t(&a["nom"]),
            depot: t(&a["depot"]),
            zip: t(&a["zip"]),
            ancien_zip: t(&a["ancien_zip"]),
            ..Default::default()
        })
        .collect();
    ctx.definir_applis(applis);
    for (k, v) in s["reglages"].as_object().into_iter().flatten() {
        ctx.ecrire_reglage(k, v.clone());
    }
    let bienvenue = |oui: bool| ctx.au_nom_de("lui-meme", || ctx.publier("mindset", json!({ "bienvenue": oui })));
    bienvenue(s["bienvenue"].as_bool().unwrap_or(false));
    let mut b = BlocPublications::nouveau();
    ctx.au_nom_de("publications", || b.demarrer(&ctx, &mut Effets::default()));
    let pas = liste(&s["pas"]);
    let sorties = liste(&s["sorties"]);
    if pas.len() != sorties.len() {
        return Err(format!("{nom} : {} pas, {} sorties", pas.len(), sorties.len()));
    }
    for (i, (p, attendu)) in pas.iter().zip(sorties.iter()).enumerate() {
        let quoi = format!("{nom}, pas {i} ({})", p["pas"]);
        let mut e = Effets::default();
        b.lancees.clear();
        let j0 = faux.donnees.lignes().len();
        match p["pas"].as_str().unwrap_or("") {
            "avancer" => ctx.avancer(Duration::from_secs(p["secondes"].as_u64().unwrap_or(0))),
            "bienvenue" => bienvenue(p["oui"].as_bool().unwrap_or(false)),
            "reglage" => {
                ctx.ecrire_reglage(&t(&p["nom"]), p["valeur"].clone());
                ctx.au_nom_de("publications", || {
                    b.signal(&ctx, signaux::REGLAGE_CHANGE, &json!({ "nom": p["nom"], "valeur": p["valeur"] }), &mut e)
                });
            }
            autre => ctx.au_nom_de("publications", || match autre {
                "demarrage" | "minuterie" => {
                    b.tic(&ctx, &mut e);
                }
                "clic" => b.signal(&ctx, signaux::ACTUALISER, &json!({ "clic": true }), &mut e),
                "auto" => b.signal(&ctx, signaux::ACTUALISER, &json!({ "clic": false }), &mut e),
                "fenetre" => {
                    b.visible = p["avant"].as_bool().unwrap_or(false);
                    b.signal(&ctx, signaux::FENETRE, &json!({ "visible": true, "reduite": false }), &mut e);
                }
                "essai" => b.signal(&ctx, signaux::VERSIONS_ESSAI, &json!({ "id": p["id"], "oui": p["oui"] }), &mut e),
                "reponse" => {
                    let r = if p.get("resultat").is_some() {
                        Ok(github::en_partage(&github::depuis_ps(&p["resultat"])))
                    } else {
                        Err(t(&p["erreur"]))
                    };
                    b.tache_finie(&ctx, &format!("publication:{}", t(&p["id"])), r, &mut e);
                }
                x => panic!("pas inconnu : {x}"),
            }),
        }
        // Ce qui a été demandé pendant ce pas
        let mut appels = Vec::new();
        let mut cartes = 0;
        let mut taches = Vec::new();
        for x in &e.0 {
            match x {
                Effet::Signal { nom, .. } if nom == signaux::VERIFIER_MINDSET => {
                    appels.push(json!("Start-VerifMajMindset"))
                }
                Effet::Signal { nom, .. } if nom == signaux::VERIFIER_LISTE => {
                    appels.push(json!("Update-ListeEnLigne"))
                }
                Effet::Signal { nom, .. } if nom == signaux::PUBLICATIONS_CHANGEES => cartes += 1,
                Effet::Tache(tache) => taches.push(tache.id.clone()),
                _ => {}
            }
        }
        let lancees: Vec<Value> =
            b.lancees.iter().map(|q| json!({ "depot": q.depot, "zip": q.zips, "essai": q.essai })).collect();
        // (chaque question d'appli est un travail de fond, plus celle de Mindset lui-même)
        let attendues: Vec<String> = b
            .lancees
            .iter()
            .map(|q| format!("publication:{}", q.id))
            .chain((!b.lancees.is_empty()).then(|| "publication-mindset".to_string()))
            .collect();
        if taches != attendues && !(b.lancees.is_empty() && ctx.applis().is_empty()) {
            return Err(format!("{quoi} (travaux de fond) : {taches:?} au lieu de {attendues:?}"));
        }
        let pubs: serde_json::Map<String, Value> = b
            .publications()
            .iter()
            .filter(|(k, _)| k.as_str() != "mindset")
            .map(|(k, v)| (k.clone(), github::en_ps(v)))
            .collect();
        let iso = |s: i64| moment::iso(&moment::depuis_secondes(s));
        let obtenu = json!({
            "taches": lancees,
            "appels": appels,
            "journal": faux.donnees.lignes()[j0..].to_vec(),
            "info": b.texte_info(&ctx),
            "dernieres": b.dernieres.map(iso),
            "verifie_a": b.verifie_a(),
            "publications": pubs,
            "recherches": b.recherches(),
            "cartes": cartes,
            "versions_essai": ctx.reglage("VersionsEssai").unwrap_or(json!("absent")),
            "visible": b.visible,
        });
        for (cle, a) in attendu.as_object().into_iter().flatten() {
            let a = match cle.as_str() {
                "taches" | "appels" | "journal" | "recherches" => Value::Array(liste(a)),
                _ => a.clone(),
            };
            ecart(&format!("{quoi} « {cle} »"), &a, &obtenu[cle.as_str()])?;
        }
    }
    let _ = std::fs::remove_dir_all(&faux.racine);
    Ok(())
}

#[test]
fn juges_scenarios() {
    let s = juge("scenarios.json");
    let erreurs: Vec<String> =
        liste(&s).iter().enumerate().filter_map(|(n, x)| verifier_scenario(x, n).err()).collect();
    assert!(erreurs.is_empty(), "{}", erreurs.join("\n"));
}

// ---------------------------------------------------------------------------------------------------------------
// La contre-épreuve : un juge changé d'un caractère fait échouer la comparaison
// ---------------------------------------------------------------------------------------------------------------

/// Change le dernier caractère du premier texte non vide trouvé à ce chemin (ou ajoute « x » à un texte vide).
fn abimer(v: &mut Value, chemin: &[&str]) -> bool {
    let mut x = v;
    for c in chemin {
        x = match x {
            Value::Object(m) => match m.get_mut(*c) {
                Some(y) => y,
                None => return false,
            },
            Value::Array(a) => match c.parse::<usize>().ok().and_then(|i| a.get_mut(i)) {
                Some(y) => y,
                None => return false,
            },
            _ => return false,
        };
    }
    match x {
        Value::String(s) => {
            let dernier = s.pop();
            s.push(if dernier == Some('Z') { 'Y' } else { 'Z' });
            true
        }
        Value::Bool(b) => {
            *b = !*b;
            true
        }
        Value::Number(n) => {
            *x = json!(n.as_i64().unwrap_or(0) + 1);
            true
        }
        Value::Null => {
            *x = json!("Z");
            true
        }
        _ => false,
    }
}

#[test]
fn contre_epreuve() {
    // Get-Publication : chaque champ du résultat, et une question de la liste
    let cas = juge("publications.json");
    let mut abimes = 0;
    for (i, c) in liste(&cas).iter().enumerate().step_by(3) {
        assert!(verifier_publication(c).is_ok(), "témoin {i}");
        for champ in ["Version", "UrlZip", "UrlSig", "Notes", "Erreur", "Essai", "Fichier"] {
            let mut x = c.clone();
            if abimer(&mut x, &["resultat", champ]) {
                assert!(verifier_publication(&x).is_err(), "cas {i}, {champ} abîmé : le test passe encore");
                abimes += 1;
            }
        }
        let mut x = c.clone();
        if abimer(&mut x, &["demandes", "0"]) {
            assert!(verifier_publication(&x).is_err(), "cas {i}, question abîmée : le test passe encore");
            abimes += 1;
        }
    }
    assert!(abimes > 80, "{abimes} juges abîmés seulement");
    // Les notes, le HTML, les adresses, les versions
    let notes = juge("notes.json");
    for (i, c) in liste(&notes).iter().enumerate() {
        let mut x = c.clone();
        assert!(abimer(&mut x, &["notes"]));
        assert!(verifier_notes(&x).is_err(), "notes {i}");
    }
    let mut h = juge("html.json");
    assert!(abimer(&mut h, &["decode", "7", "sortie"]));
    assert!(verifier_html(&h).is_err());
    let mut h = juge("html.json");
    assert!(abimer(&mut h, &["entites", "100", "code"]));
    assert!(verifier_html(&h).is_err());
    let mut a = juge("adresses.json");
    assert!(abimer(&mut a, &["15", "acceptee"]));
    assert!(verifier_adresses(&a).is_err());
    let mut v = juge("versions.json");
    assert!(abimer(&mut v, &["comparaisons", "40", "plus_recente"]));
    assert!(verifier_versions(&v).is_err());
    // Les scénarios : un champ de chaque sortie, dans chaque scénario
    let s = juge("scenarios.json");
    for (n, sc) in liste(&s).iter().enumerate() {
        let sorties = liste(&sc["sorties"]).len();
        for (k, champ) in ["info", "dernieres", "verifie_a", "cartes", "visible"].iter().enumerate() {
            let p = ((n + k * 3) % sorties).to_string();
            let mut x = sc.clone();
            assert!(abimer(&mut x, &["sorties", &p, champ]));
            assert!(verifier_scenario(&x, 1000 + n * 10 + k).is_err(), "scénario {n}, sortie {p}, {champ} abîmé");
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Des cas jamais vus (tirés au hasard ici, comparés à une autre lecture)
// ---------------------------------------------------------------------------------------------------------------

/// Un tirage simple et reproductible (xorshift).
struct Hasard(u64);
impl Hasard {
    fn suivant(&mut self, n: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % n
    }
}

#[test]
fn hasard_versions_comme_suite_commun() {
    // Pour des numéros faits de chiffres seulement, les deux lectures (.NET ici, stricte dans suite-commun) sont d'accord
    let mut h = Hasard(0x5EED_2026_1107);
    for _ in 0..5000 {
        let n = 1 + h.suivant(5);
        let t: Vec<String> = (0..n).map(|_| h.suivant(30).to_string()).collect();
        let a = t.join(".");
        let m = 1 + h.suivant(5);
        let b = (0..m).map(|_| h.suivant(30).to_string()).collect::<Vec<_>>().join(".");
        assert_eq!(version_net::plus_recente(&a, &b), suite_commun::version::plus_recente(&a, &b), "{a} {b}");
        assert_eq!(VersionNet::lire(&a).is_some(), suite_commun::version::forme_valide(&a), "{a}");
    }
}

#[test]
fn hasard_html_sans_entite_inchange() {
    // Un texte sans « & » ressort tel quel ; un nom encodé puis décodé redonne son caractère
    let mut h = Hasard(0xC0FFEE);
    let alphabet: Vec<char> = "abcé€ <>;#x0123456789\n\tà🚀".chars().collect();
    for _ in 0..2000 {
        let s: String = (0..h.suivant(40)).map(|_| alphabet[h.suivant(alphabet.len() as u64) as usize]).collect();
        assert_eq!(html::decoder(&s), s);
        let (nom, code) = ENTITES[h.suivant(ENTITES.len() as u64) as usize];
        let c = char::from_u32(u32::from(code)).unwrap();
        assert_eq!(html::decoder(&format!("{s}&{nom};{s}")), format!("{s}{c}{s}"));
        assert_eq!(html::decoder(&format!("&#{};", u32::from(c))), c.to_string());
        assert_eq!(html::decoder(&format!("&#x{:x};", u32::from(c))), c.to_string());
    }
}

#[test]
fn hasard_github_jamais_de_panique_et_toujours_les_memes_questions() {
    // Des réponses de GitHub tirées au hasard (codes, JSON abîmé, redirections) : jamais de panique, au plus une
    // question à l'API par version demandée, et jamais une adresse hors de GitHub
    let mut h = Hasard(0xBADC0DE);
    let corps = [
        "",
        "{",
        "[]",
        "null",
        "42",
        r#"{"tag_name":"v1.2.3","assets":[{"name":"A.zip","browser_download_url":"https://github.com/x/A.zip"}]}"#,
        r#"[{"tag_name":"v9.0","prerelease":true,"assets":[{"name":"A.zip"},{"name":"A.zip.sig"}]}]"#,
        r#"{"assets":"pas une liste"}"#,
        r#"{"tag_name":{"x":1},"assets":[{"name":["A.zip"]}]}"#,
    ];
    for _ in 0..300 {
        let f = FauxReseau::default();
        let api = "https://api.github.com/repos/J/A";
        let gh = "https://github.com/J/A";
        for url in [
            format!("{api}/releases/latest"),
            format!("{api}/releases?per_page=30"),
            format!("{gh}/releases/latest"),
            format!("{gh}/releases.atom"),
        ] {
            let r = match h.suivant(4) {
                0 => Err("Impossible de se connecter au serveur distant".to_string()),
                1 => Ok(ReponseHttp::code([403, 404, 429, 500][h.suivant(4) as usize])),
                2 => Ok(ReponseHttp {
                    statut: 302,
                    entetes: vec![("Location".into(), format!("{gh}/releases/tag/v{}.{}", h.suivant(3), h.suivant(9)))],
                    ..Default::default()
                }),
                _ => Ok(ReponseHttp::ok(corps[h.suivant(corps.len() as u64) as usize].as_bytes().to_vec())),
            };
            f.repondre(&url, r);
        }
        let essai = h.suivant(2) == 0;
        let r = github::publication(&f, "J/A", &["A.zip".to_string(), String::new()], essai);
        if let Ok(p) = &r {
            assert!(p.essai == (p.essai && essai), "une préversion seulement si la case est cochée");
        }
        let d = f.demandes();
        assert!(
            d.iter()
                .all(|x| x.adresse.starts_with("https://api.github.com/")
                    || x.adresse.starts_with("https://github.com/"))
        );
        assert_eq!(
            d.iter().filter(|x| x.adresse.ends_with("/releases/latest") && x.adresse.contains("api.")).count(),
            1
        );
        assert!(d.iter().filter(|x| x.adresse.contains("per_page")).count() <= usize::from(essai));
    }
}
