//! Le bloc console dans le temps, comme l'hôte l'appelle : le cadre créé sur l'accueil, retiré Mindset caché ou
//! réduit, en pause sur une autre page puis retiré au bout d'une minute ; les Paramètres dans l'écran ; le réglage
//! Animations ; l'ouverture d'une appli et sa barre ; l'appli de la fente qui se ferme ; le rythme des minuteries.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use mindset_console::{BlocConsole, Fenetres, RYTHME, RYTHME_CACHE};
use mindset_noyau::appli::Appli;
use mindset_noyau::essai::{self, Faux};
use mindset_noyau::{Bloc, Contexte, Effet, Effets, Fenetre, Vue, partage, signaux};
use serde_json::{Value, json};

static N: AtomicUsize = AtomicUsize::new(0);

/// Le faux des fenêtres : ces programmes ont leur fenêtre.
#[derive(Clone, Default)]
struct FenetresEssai(Arc<Mutex<Vec<u32>>>);
impl Fenetres for FenetresEssai {
    fn trouvee(&self, pid: u32, titre: &str) -> bool {
        titre == "Evermind" && self.0.lock().unwrap().contains(&pid)
    }
}

struct Essai {
    ctx: Contexte,
    faux: Faux,
    bloc: BlocConsole,
    fenetres: FenetresEssai,
}

impl Drop for Essai {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.faux.racine);
    }
}

fn evermind() -> Appli {
    Appli {
        id: "evermind".into(),
        nom: "Evermind".into(),
        couleur: "#B04BFF".into(),
        exe: "Evermind.exe".into(),
        mutex: r"Local\Evermind-Instance".into(),
        cache_depuis: "0.14.0".into(),
        ..Default::default()
    }
}

fn essai() -> Essai {
    let (ctx, faux) = essai::contexte(&format!("console-bloc-{}", N.fetch_add(1, Ordering::SeqCst)));
    ctx.definir_applis(vec![
        evermind(),
        Appli { id: "cafe-creme".into(), nom: "Café crème".into(), ..Default::default() },
    ]);
    let dossier = ctx.dossiers.programmes.join("Evermind").to_string_lossy().to_string();
    ctx.au_nom_de("installations", || {
        ctx.publier(
            partage::INSTALLATIONS,
            json!({ "evermind": { "dossier": dossier, "gere": true, "version": "0.15.0" } }),
        )
    });
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "accueil".into() });
    let fenetres = FenetresEssai::default();
    let bloc = BlocConsole::avec_fenetres(Box::new(fenetres.clone()));
    let mut e = Essai { ctx, faux, bloc, fenetres };
    let mut ef = Effets::default();
    e.bloc.demarrer(&e.ctx, &mut ef);
    // (le premier tic de l'hôte, la fenêtre ouverte : sur l'accueil, la console s'allume)
    e.bloc.tic(&e.ctx, &mut ef);
    assert_eq!(e.bloc.cadre(), Some(1), "la page d'arrivée est l'accueil : le cadre est créé au premier tic");
    e
}

impl Essai {
    fn signal(&mut self, nom: &str, donnees: Value) -> Vec<Effet> {
        let mut e = Effets::default();
        self.bloc.signal(&self.ctx, nom, &donnees, &mut e);
        e.0
    }
    fn page(&mut self, id: &str) -> Vec<Effet> {
        let mut v = self.ctx.vue();
        let avant = std::mem::replace(&mut v.page, id.to_string());
        self.ctx.definir_vue(v);
        self.signal(signaux::PAGE, json!({ "id": id, "avant": avant }))
    }
    fn fenetre(&mut self, visible: bool, reduite: bool) -> Vec<Effet> {
        let page = self.ctx.vue().page;
        self.ctx.definir_vue(Vue { visible, reduite, page });
        self.signal(signaux::FENETRE, json!({ "visible": visible, "reduite": reduite }))
    }
    fn action(&mut self, id: &str, valeur: Value) -> Vec<Effet> {
        let mut e = Effets::default();
        assert!(self.bloc.action(&self.ctx, id, &valeur, &mut e));
        e.0
    }
    fn tic(&mut self) -> (Option<Duration>, Vec<Effet>) {
        let mut e = Effets::default();
        let d = self.bloc.tic(&self.ctx, &mut e);
        (d, e.0)
    }
    fn etat(&mut self) -> Value {
        self.bloc.etat(&self.ctx)["console"].clone()
    }
    /// La scène se charge et dit « pret » (le numéro du cadre, comme console.js).
    fn pret(&mut self) -> Vec<Effet> {
        let n = self.bloc.cadre().unwrap();
        self.action("console:pret", json!({ "cadre": n }))
    }
}

fn ordres(effets: &[Effet]) -> Vec<String> {
    effets
        .iter()
        .filter_map(|e| match e {
            Effet::Ordre(o) => Some(format!(
                "{}{}",
                o["appel"].as_str().unwrap(),
                o.get("args").map(|a| a.to_string()).unwrap_or_default()
            )),
            _ => None,
        })
        .collect()
}

fn signaux_de(effets: &[Effet]) -> Vec<(String, Value)> {
    effets
        .iter()
        .filter_map(|e| match e {
            Effet::Signal { nom, donnees } => Some((nom.clone(), donnees.clone())),
            _ => None,
        })
        .collect()
}

#[test]
fn le_cadre_suit_l_accueil_et_la_fenetre() {
    let mut e = essai();
    assert!(e.bloc.possible());
    assert_eq!(
        e.ctx.lu(partage::CONSOLE),
        Some(json!({ "possible": true, "parametres": false, "en_fente": null, "raison": null }))
    );
    e.fenetre(false, false);
    assert!(e.etat()["cadre"].is_null(), "caché : pas de cadre");
    e.fenetre(true, false);
    e.fenetre(true, false);
    let c = e.etat();
    assert_eq!(c["visible"], json!(true));
    assert_eq!(c["attente"], json!(true), "« Allumage de la console... » en attendant");
    assert_eq!(c["texte_attente"], json!("Allumage de la console..."));
    assert_eq!(c["cadre"], json!("console/scene.html?vue=menu&animations=completes&couleurs=%7B%7D&n=2"));
    assert_eq!(c["fond"], json!("#07060D"));
    assert!(c["etat"]["applis"].is_array() && c["maj"]["phase"].is_string(), "l'état part avec le cadre");
    // La scène prête : plus d'attente ; ce qui attendait est joué
    assert!(ordres(&e.pret()).is_empty());
    assert_eq!(e.etat()["attente"], json!(false));
    assert!(e.faux.donnees.lignes().contains(&"Console 3D prête".to_string()));
    // Un « pret » d'un ancien cadre est ignoré
    e.fenetre(false, false);
    assert!(e.bloc.cadre().is_none(), "Mindset caché : la 3D est fermée");
    assert!(e.faux.donnees.lignes().contains(&"Console 3D fermée (Mindset caché)".to_string()));
    e.fenetre(true, false);
    assert_eq!(e.bloc.cadre(), Some(3), "réaffiché sur l'accueil : elle revient");
    e.action("console:pret", json!({ "cadre": 2 }));
    assert!(!e.bloc.pret(), "le « pret » du premier cadre ne compte pas");
    e.pret();
    e.fenetre(true, true);
    assert!(e.bloc.cadre().is_none());
    assert!(e.faux.donnees.lignes().contains(&"Console 3D fermée (Mindset réduit)".to_string()));
    e.signal(signaux::QUITTER, json!({ "avec_applis": false, "relancer": false }));
}

#[test]
fn une_autre_page_met_en_pause_puis_ferme_au_bout_d_une_minute() {
    let mut e = essai();
    e.page("accueil");
    e.pret();
    let ef = e.page("evermind");
    assert_eq!(ordres(&ef), vec!["pause[]"]);
    assert_eq!(e.etat()["visible"], json!(false));
    e.tic();
    e.ctx.avancer(Duration::from_secs(59));
    e.tic();
    assert!(e.bloc.cadre().is_some(), "59 s : encore là");
    e.ctx.avancer(Duration::from_secs(2));
    e.tic();
    assert!(e.bloc.cadre().is_none(), "une minute : fermée");
    assert!(e.faux.donnees.lignes().contains(&"Console 3D fermée (une minute sur une autre page)".to_string()));
    // Le retour : un nouveau cadre, sur le menu
    e.page("accueil");
    assert_eq!(e.bloc.cadre(), Some(2));
    // Revenue avant la minute : reprendre, et l'état renvoyé (envoi)
    e.pret();
    e.page("evermind");
    e.ctx.avancer(Duration::from_secs(10));
    let envoi = e.etat()["envoi"].clone();
    let ef = e.page("accueil");
    assert_eq!(ordres(&ef), vec!["reprendre[]"]);
    assert_ne!(e.etat()["envoi"], envoi, "Send-EtatConsole -Force");
    e.ctx.avancer(Duration::from_secs(60));
    e.tic();
    assert_eq!(e.bloc.cadre(), Some(2), "revenue : la minute repart de zéro");
}

#[test]
fn le_rythme_des_minuteries() {
    let mut e = essai();
    e.page("accueil");
    let (d, _) = e.tic();
    assert_eq!(d, Some(RYTHME));
    e.ctx.avancer(Duration::from_millis(500));
    let (d, _) = e.tic();
    assert_eq!(d, Some(RYTHME - Duration::from_millis(500)), "réveillé plus tôt (une action) : le rythme reste");
    e.fenetre(false, false);
    let (d, _) = e.tic();
    assert_eq!(d, Some(RYTHME_CACHE), "Mindset caché : toutes les 30 s");
}

#[test]
fn les_parametres_s_ouvrent_dans_l_ecran() {
    let mut e = essai();
    e.page("accueil");
    e.pret();
    e.ctx.au_nom_de("parametres", || e.ctx.publier(partage::ONGLET_PARAMETRES, json!("son")));
    // Show-Page 'parametres' (le bloc paramètres) : la console les prend dans son écran
    let ef = e.page("parametres");
    assert_eq!(ef, vec![Effet::Page("accueil".into())]);
    assert!(e.bloc.parametres_ouverts());
    let ef = e.page("accueil");
    assert_eq!(ordres(&ef), vec!["reprendre[]", "reglagesOuvrir"]);
    let Effet::Ordre(o) = &ef[1] else { panic!() };
    assert_eq!(o["onglet"], json!("son"));
    assert_eq!(o["instant"], json!(false));
    assert_eq!(e.etat()["parametres"], json!(true));
    assert_eq!(e.ctx.lu(partage::CONSOLE).unwrap()["parametres"], json!(true));
    // Un geste dans l'écran : au bloc paramètres
    let ef = e.action("console:reglage", json!({ "quoi": "majauto", "valeur": true, "id": "" }));
    assert_eq!(
        ef,
        vec![Effet::Action {
            id: "parametres:reglage".into(),
            valeur: json!({ "quoi": "majauto", "valeur": true, "id": "" })
        }]
    );
    // Retour au menu en grand
    e.action("console:action", json!({ "action": "parametresFermes" }));
    assert!(!e.bloc.parametres_ouverts());
    assert!(e.action("console:reglage", json!({ "quoi": "theme" })).is_empty(), "fermés : plus de réglage");
}

#[test]
fn le_reglage_animations() {
    let mut e = essai();
    e.page("accueil");
    e.pret();
    e.bloc.poser_fente(None, true);
    // Express, la console à l'écran : elle change de vitesse sans s'éteindre
    let ef = e.signal(signaux::REGLAGE_CHANGE, json!({ "nom": "Animations", "valeur": "express" }));
    assert_eq!(ordres(&ef), vec![r#"vitesse["express"]"#]);
    assert!(e.bloc.cadre().is_some());
    // Aucune : l'accueil classique, et la page des Paramètres d'avant sur Apparence
    e.ctx.ecrire_reglage("Animations", json!("aucune"));
    let ef = e.signal(signaux::REGLAGE_CHANGE, json!({ "nom": "Animations", "valeur": "aucune" }));
    assert!(!e.bloc.possible() && e.bloc.cadre().is_none());
    assert_eq!(signaux_de(&ef), vec![("ouvrir-parametres".to_string(), json!({ "onglet": "apparence" }))]);
    assert_eq!(e.etat()["visible"], json!(false));
    assert_eq!(e.ctx.lu(partage::CONSOLE).unwrap()["possible"], json!(false));
    assert!(e.faux.donnees.lignes().contains(&"Console 3D fermée (réglage Animations : aucune)".to_string()));
    // Express de nouveau : elle revient (à la nouvelle vitesse)
    e.ctx.ecrire_reglage("Animations", json!("express"));
    e.signal(signaux::REGLAGE_CHANGE, json!({ "nom": "Animations", "valeur": "express" }));
    assert!(e.bloc.possible());
    assert!(e.bloc.adresse_cadre().unwrap().contains("animations=express"));
    // Une autre page : recréée à la nouvelle vitesse au retour
    e.pret();
    e.page("evermind");
    e.signal(signaux::REGLAGE_CHANGE, json!({ "nom": "Animations", "valeur": "completes" }));
    assert!(e.bloc.cadre().is_none());
}

#[test]
fn au_demarrage_sans_animations_l_accueil_classique() {
    let (ctx, faux) = essai::contexte("console-bloc-aucune");
    ctx.ecrire_reglage("Animations", json!("Aucune"));
    let mut b = BlocConsole::default();
    let mut e = Effets::default();
    b.demarrer(&ctx, &mut e);
    assert!(!b.possible());
    assert_eq!(faux.donnees.lignes(), vec!["Console 3D désactivée : réglage Animations : aucune (accueil classique)"]);
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "accueil".into() });
    b.signal(&ctx, signaux::PAGE, &json!({ "id": "accueil" }), &mut e);
    assert!(b.cadre().is_none());
    assert_eq!(b.tic(&ctx, &mut e), None, "rien à surveiller");
    // Échap n'a rien à faire
    let mut e2 = Effets::default();
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "evermind".into() });
    assert!(b.action(&ctx, "menu", &Value::Null, &mut e2));
    assert!(e2.est_vide());
    let _ = std::fs::remove_dir_all(&faux.racine);
}

#[test]
fn ouvrir_une_appli_depuis_la_console() {
    let mut e = essai();
    e.page("accueil");
    e.pret();
    let ef = e.action("console:action", json!({ "action": "ouvrir", "id": "evermind" }));
    assert_eq!(signaux_de(&ef), vec![("lancer-appli".to_string(), json!({ "id": "evermind", "demarrage": true }))]);
    assert_eq!(ordres(&ef), vec![r#"jouerOuverture["evermind"]"#]);
    assert_eq!(e.bloc.attente(), Some("evermind"));
    // La barre avance (Evermind : 10 s d'habitude)
    e.ctx.avancer(Duration::from_millis(300));
    let (d, ef) = e.tic();
    assert_eq!(ordres(&ef), vec![r#"avancee["evermind",0.053]"#]);
    assert_eq!(d, Some(Duration::from_millis(300)));
    // Sa fenêtre apparaît (son programme tourne depuis son dossier)
    let exe = e.ctx.dossiers.programmes.join(r"Evermind\Mindset.exe");
    e.faux.systeme.ajouter_processus(321, &exe.to_string_lossy(), 1);
    e.fenetres.0.lock().unwrap().push(321);
    e.ctx.avancer(Duration::from_millis(2700));
    let (_, ef) = e.tic();
    assert_eq!(ordres(&ef), vec![r#"appliPrete["evermind"]"#]);
    assert_eq!(e.bloc.attente(), None);
    assert_eq!(e.ctx.reglage("Ouverture-evermind"), Some(json!(3.0)), "la durée de cette ouverture est retenue");
    // Fin de la plongée : l'appli prend la place de la console, sa cartouche dans la fente
    let ef = e.action("console:afficher", json!({ "id": "evermind" }));
    assert_eq!(signaux_de(&ef), vec![("ouvrir-appli".to_string(), json!({ "id": "evermind", "lancer": true }))]);
    assert_eq!(e.bloc.en_fente(), Some("evermind"));
    assert_eq!(e.ctx.lu(partage::CONSOLE).unwrap()["en_fente"], json!("evermind"));
}

#[test]
fn une_appli_qui_ne_demarre_pas_est_affichee_quand_meme() {
    let mut e = essai();
    e.page("accueil");
    e.pret();
    e.faux.systeme.poser_verrou(r"Local\Evermind-Instance", true);
    let ef = e.action("console:action", json!({ "action": "ouvrir", "id": "evermind" }));
    assert!(signaux_de(&ef).is_empty(), "déjà ouverte : pas relancée");
    for _ in 0..204 {
        e.ctx.avancer(Duration::from_millis(300));
        e.tic();
    }
    assert_eq!(e.bloc.attente(), None);
    assert!(
        e.faux
            .donnees
            .lignes()
            .contains(&"Console 3D : Evermind pas prête après 60 s, affichée quand même".to_string())
    );
    assert_eq!(e.ctx.reglage("Ouverture-evermind"), None, "pas lancée par ce clic : rien de retenu");
}

#[test]
fn l_appli_de_la_fente_qui_se_ferme() {
    let mut e = essai();
    e.page("accueil");
    e.pret();
    e.faux.systeme.poser_verrou(r"Local\Evermind-Instance", true);
    e.action("console:afficher", json!({ "id": "evermind" }));
    e.page("evermind");
    e.tic();
    assert_eq!(e.bloc.en_fente(), Some("evermind"), "ouverte : elle reste dans la fente");
    // Fermée pendant qu'on la regarde : retour à la console, la cartouche ressort
    e.faux.systeme.poser_verrou(r"Local\Evermind-Instance", false);
    e.ctx.avancer(RYTHME);
    let (_, ef) = e.tic();
    assert_eq!(ef, vec![Effet::Page("accueil".into())]);
    let ef = e.page("accueil");
    assert_eq!(ordres(&ef), vec!["reprendre[]", r#"jouerRetour["evermind",true]"#]);
    assert_eq!(e.bloc.en_fente(), None);
}

#[test]
fn ouverte_depuis_l_horloge_sa_cartouche_va_dans_la_fente() {
    let mut e = essai();
    e.signal(signaux::OUVRIR_APPLI, json!({ "id": "evermind", "lancer": true }));
    assert_eq!(e.bloc.en_fente(), Some("evermind"));
    assert_eq!(e.bloc.derniere_appli(), Some("evermind"));
}

#[test]
fn echap_hors_de_l_accueil() {
    let mut e = essai();
    e.page("evermind");
    assert_eq!(e.action("menu", Value::Null), vec![Effet::Page("accueil".into())]);
    e.ctx.au_nom_de("ecrans", || e.ctx.publier(partage::VOILE, json!(true)));
    assert!(e.action("menu", Value::Null).is_empty(), "sous une question : rien");
    assert_eq!(e.etat()["masquee"], json!(true), "la 3D s'efface sous une question");
}

#[test]
fn les_messages_de_mindset_sur_l_ecran() {
    let mut e = essai();
    e.page("accueil");
    assert!(ordres(&e.signal(signaux::MESSAGE_CONSOLE, json!({ "texte": "Bonjour" }))).is_empty(), "pas prête : perdu");
    e.pret();
    assert_eq!(
        ordres(&e.signal(signaux::MESSAGE_CONSOLE, json!({ "texte": "Bonjour" }))),
        vec![r#"message["Bonjour"]"#]
    );
    assert_eq!(
        ordres(&e.signal(signaux::ERREUR_IMPREVUE, json!({ "texte": "x" }))),
        vec![r#"message["Un petit problème est survenu"]"#]
    );
    assert_eq!(ordres(&e.action("console:action", json!({ "action": "veille" }))), Vec::<String>::new());
    assert_eq!(e.action("console:action", json!({ "action": "veille" })), vec![Effet::Fenetre(Fenetre::Cacher)]);
}

#[test]
fn le_logo_tire_d_une_icone_est_servi_une_fois() {
    let mut e = essai();
    let d = e.ctx.dossiers.programmes.join(r"Cafe\fichiers");
    std::fs::create_dir_all(&d).unwrap();
    let png = [0x89u8, b'P', b'N', b'G', 1, 2, 3];
    let mut ico = vec![0, 0, 1, 0, 1, 0, 32, 32, 0, 0, 1, 0, 32, 0];
    ico.extend((png.len() as u32).to_le_bytes());
    ico.extend(22u32.to_le_bytes());
    ico.extend(png);
    std::fs::write(d.join("cafe.ico"), ico).unwrap();
    let dossier = e.ctx.dossiers.programmes.join("Cafe").to_string_lossy().to_string();
    let dossier_e = e.ctx.dossiers.programmes.join("Evermind").to_string_lossy().to_string();
    e.ctx.au_nom_de("installations", || {
        e.ctx.publier(
            partage::INSTALLATIONS,
            json!({ "evermind": { "dossier": dossier_e, "gere": true, "version": "0.15.0" }, "cafe-creme": { "dossier": dossier, "gere": true, "version": "1.0" } }),
        )
    });
    e.ctx.avancer(RYTHME);
    let (_, ef) = e.tic(); // (installée après coup : son logo est tiré au passage suivant de la minuterie)
    let f = e.ctx.dans_donnees(r"console-logos\cafe-creme.png");
    assert_eq!(ef, vec![Effet::Exposer { nom: "console-logo-cafe-creme.png".into(), chemin: Some(f.clone()) }]);
    assert_eq!(std::fs::read(&f).unwrap(), png);
    let applis = e.etat()["etat"]["applis"].clone();
    assert_eq!(applis[0]["logo"], json!("logos/evermind.png"));
    assert_eq!(applis[1]["logo"], json!("http://fichier.localhost/console-logo-cafe-creme.png"));
    e.ctx.avancer(RYTHME);
    let (_, ef) = e.tic();
    assert!(ef.is_empty(), "déjà servi : pas de nouvel effet");
    assert_eq!(e.faux.donnees.lignes().iter().filter(|l| l.contains("tiré de son icône")).count(), 1);
}

#[test]
fn la_scene_d_un_theme_perso() {
    let (ctx, faux) = essai::contexte("console-bloc-pack");
    let p = ctx.dans_donnees(r"packs\foret");
    std::fs::create_dir_all(&p).unwrap();
    std::fs::write(
        p.join("pack.json"),
        r#"{ "Name": "Forêt", "Base": "crepuscule", "Console": { "Fond": "fond.jpg", "Mascotte": "m.png" } }"#,
    )
    .unwrap();
    std::fs::write(p.join("fond.jpg"), [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1]).unwrap();
    std::fs::write(p.join("m.png"), [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, 1]).unwrap();
    ctx.donnees().ecrire_theme_suite("pack:foret");
    let mut b = BlocConsole::default();
    let mut e = Effets::default();
    b.demarrer(&ctx, &mut e);
    let a = b.adresse_scene(&ctx, "menu", 7);
    assert!(
        a.starts_with("console/scene.html?vue=menu&animations=completes&couleurs=%7B%2207060D%22%3A%22%230C0708%22"),
        "{a}"
    );
    assert!(a.contains("%2200E5FF%22%3A%22%23FF8A3D%22"), "le cyan devient l'orange du thème");
    assert!(a.contains("&theme=%7B%22fond%22%3A%22http%3A%2F%2Fpack.localhost%2Ffond.jpg%22"), "{a}");
    assert!(a.ends_with("&n=7"));
    let t = b.etat(&ctx);
    assert_eq!(t["console"]["fond"], json!("#0C0708"), "le fond du cadre dans le thème (pas d'éclair)");
    let _ = std::fs::remove_dir_all(&faux.racine);
}
