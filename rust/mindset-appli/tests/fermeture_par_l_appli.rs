//! Reproduction du défaut vu par Jordan le 08/11/2026 à 19:53 (Mindset 3.0.3, Nevermind 2.1.2) : Nevermind est
//! affiché dans Mindset, Jordan clique sur sa croix (dans la page de Nevermind), répond « Quitter » à sa question.
//! La place de Nevermind reste noire, Mindset ne revient pas au menu : il a dû tout quitter.
//!
//! Ce que Jordan veut : quand il ferme l'appli affichée, Mindset revient tout de suite au menu (l'accueil, avec la
//! console). Nevermind se cache dès qu'on lui dit « Quitter » (sa fenêtre s'en va de l'écran), puis son programme met
//! encore plusieurs secondes à s'arrêter (20,9 s mesurées chez Jordan à 18:22:45). Mindset doit revenir à l'accueil
//! dès que la fenêtre est cachée, sans attendre la fin du programme ; et aussi quand la fenêtre disparaît d'un coup.
//! Avant la correction : la page restait sur Nevermind (« réduit près de l'horloge » ou « Nevermind est fermé. »).
//!
//! Tous les vrais blocs dans l'hôte, le faux Windows de l'accrochage (`FauxFenetres`, aussi regardé par la console),
//! un faux Nevermind déjà ouvert près de l'horloge. Rien ne touche le vrai PC.

use std::time::Duration;

use mindset_accrochage::{BlocAccrochage, FauxFenetres, Fenetres};
use mindset_appli::hote::{Ecran, Hote};
use mindset_appli::pont::MessagePage;
use mindset_console::BlocConsole;
use mindset_noyau::{Lancement, essai, partage};
use serde_json::{Value, json};

#[derive(Default)]
struct Page {
    etats: Vec<Value>,
}
impl Ecran for Page {
    fn etat(&mut self, e: Value) {
        self.etats.push(e);
    }
    fn ordre(&mut self, _: Value) {}
}

/// La console regarde les fenêtres du même faux Windows que l'accrochage.
struct VuesParLaConsole(FauxFenetres);
impl mindset_console::Fenetres for VuesParLaConsole {
    fn trouvee(&self, pid: u32, titre: &str) -> bool {
        self.0.trouver(pid, titre).is_some()
    }
}

fn action(id: &str, valeur: Value) -> MessagePage {
    MessagePage::Action { id: id.into(), valeur, ecran: String::new() }
}

/// Mindset avec Nevermind installé et déjà ouvert (caché près de l'horloge) : l'hôte, le faux Windows, la page.
fn mindset_avec_nevermind(nom: &str) -> (Hote, FauxFenetres, essai::Faux, Page) {
    let (ctx, faux) = essai::contexte_avec(nom, Lancement::default());
    ctx.ecrire_reglage("TachesRefaitesPour", json!("3.0.0"));
    let nevermind = ctx.dossiers.programmes.join("Nevermind");
    std::fs::create_dir_all(&nevermind).unwrap();
    std::fs::write(nevermind.join("Nevermind.exe"), "exe").unwrap();
    std::fs::write(nevermind.join("Mindset.exe"), "hote").unwrap();
    std::fs::write(nevermind.join("version.json"), r#"{"version":"2.1.2","appli":"nevermind"}"#).unwrap();
    let inst = json!({ "nevermind": { "dossier": nevermind.to_string_lossy(), "gere": true } });
    std::fs::write(ctx.dossiers.donnees.join("installations.json"), inst.to_string()).unwrap();
    // (la vraie liste des applis, lue par le bloc « liste » au démarrage ; ses verrous ne sont lus que dans le faux
    // Windows du test)
    std::fs::create_dir_all(&ctx.dossiers.fichiers).unwrap();
    std::fs::write(ctx.dossiers.fichiers.join("apps.json"), include_str!("../../../Mindset/fichiers/apps.json"))
        .unwrap();

    let f = FauxFenetres::nouveau();
    let mut blocs = mindset_appli::blocs();
    let i = blocs.iter().position(|b| b.nom() == "accrochage").unwrap();
    blocs[i] = Box::new(BlocAccrochage::avec(Box::new(f.clone())));
    let i = blocs.iter().position(|b| b.nom() == "console").unwrap();
    blocs[i] = Box::new(BlocConsole::avec_fenetres(Box::new(VuesParLaConsole(f.clone()))));
    let mut h = Hote::nouveau(blocs, ctx);
    h.taches_directes = true;
    let au_depart = h.demarrer();
    assert!(h.ctx.appli("nevermind").is_some(), "apps.json pas lu : {:?}", faux.donnees.lignes());
    let mut v = h.ctx.vue();
    v.visible = Hote::montree_au_depart(false, &au_depart);
    h.ctx.definir_vue(v);
    h.ctx.definir_fenetre(Some(77));
    h.fenetre_prete();
    let _ = h.etat_initial();
    let mut p = Page::default();
    let _ = h.minuterie(&mut p);
    let z = json!({ "x": 210, "y": 96, "largeur": 1100, "hauteur": 760, "visible": true });
    let _ = h.recevoir(action("accrochage:zone", z), &mut p);
    let numero = h.etat()["console"]["numero"].as_u64().expect("la console a sa scène");
    let _ = h.recevoir(action("console:pret", json!({ "cadre": numero })), &mut p);
    // Nevermind tourne déjà, caché près de l'horloge
    faux.systeme.ajouter_processus(501, &nevermind.join("Mindset.exe").to_string_lossy(), f.maintenant());
    f.creer(1001, 501, "Nevermind", "Tauri Window", false, false);
    (h, f, faux, p)
}

fn pas(h: &mut Hote, f: &FauxFenetres, p: &mut Page, ms: u64) {
    for _ in 0..ms / 100 {
        h.ctx.avancer(Duration::from_millis(100));
        f.avancer_ms(100);
        let _ = h.minuterie(p);
    }
}

/// Le dernier état reçu par la page.
fn derniere(p: &Page) -> Value {
    p.etats.last().cloned().unwrap_or(Value::Null)
}

/// Comment Nevermind s'en va, une fois « Quitter » choisi.
#[derive(Clone, Copy, Debug)]
enum Depart {
    /// Sa fenêtre est cachée tout de suite, son programme vit encore 20 s (Nevermind corrigé, chez Jordan)
    CacheeProgrammeLent,
    /// Cachée, puis fenêtre et programme partis 100 ms plus tard (Nevermind corrigé, sur un PC tranquille)
    CacheePuisPartie,
    /// Fenêtre et programme partis d'un coup, sans se cacher (Nevermind 2.1.2 sur un PC tranquille)
    Partie,
}

#[test]
fn nevermind_ferme_par_sa_croix_mindset_revient_tout_de_suite_a_l_accueil() {
    for (k, d) in [Depart::CacheeProgrammeLent, Depart::CacheePuisPartie, Depart::Partie].into_iter().enumerate() {
        fermer_par_la_croix(&format!("fermeture-croix-{k}"), d);
    }
}

fn fermer_par_la_croix(nom: &str, depart: Depart) {
    let (mut h, f, faux, mut p) = mindset_avec_nevermind(nom);
    // Jordan ouvre Nevermind depuis le menu : il est accroché et montré
    let _ = h.recevoir(action("ecrans:onglet", json!("nevermind")), &mut p);
    pas(&mut h, &f, &mut p, 1000);
    let _ = h.recevoir(
        action("accrochage:zone", json!({ "x": 210, "y": 96, "largeur": 1100, "hauteur": 760, "visible": true })),
        &mut p,
    );
    assert_eq!(h.ctx.vue().page, "nevermind");
    assert_eq!(
        derniere(&p)["pages_applis"]["nevermind"]["etat"],
        "affiche",
        "Nevermind n'est pas affiché : {} {:?}",
        derniere(&p)["pages_applis"],
        faux.donnees.lignes()
    );
    // Plus d'une minute sur la page de Nevermind : la console 3D se ferme (c'est voulu)
    pas(&mut h, &f, &mut p, 70_000);
    assert!(faux.donnees.lignes().iter().any(|l| l.contains("Console 3D fermée")), "la console devait s'être fermée");

    // Sa croix, « Quitter »
    match depart {
        Depart::CacheeProgrammeLent | Depart::CacheePuisPartie => f.changer(1001, |x| x.visible = false),
        Depart::Partie => {
            f.detruire(1001);
            faux.systeme.retirer_processus(501);
        }
    }
    let mut revenu = None;
    for k in 1..=10 {
        pas(&mut h, &f, &mut p, 100);
        if k == 1 && matches!(depart, Depart::CacheePuisPartie) {
            f.detruire(1001);
            faux.systeme.retirer_processus(501);
        }
        if h.ctx.vue().page == "accueil" && derniere(&p)["console"]["visible"] == true {
            revenu = Some(k * 100);
            break;
        }
    }
    let etat = derniere(&p);
    let hote = f.hote_de("nevermind");
    let journal = faux.donnees.lignes();
    let _ = std::fs::remove_dir_all(&faux.racine);
    println!(
        "{depart:?} : revenu en {revenu:?} ms\npage : {}\nconsole : {}\nnevermind : {}\njournal : {journal:#?}",
        h.ctx.vue().page,
        etat["console"],
        etat["pages_applis"]["nevermind"]
    );
    assert!(
        revenu.is_some(),
        "{depart:?} : 1 s après que Nevermind a quitté, Mindset n'est pas revenu à l'accueil avec la console : page \
         {}, {}",
        h.ctx.vue().page,
        etat["pages_applis"]["nevermind"]
    );
    // La console se rallume (une nouvelle scène est demandée), la place de Nevermind n'est plus montrée
    assert!(etat["console"]["numero"].as_u64().is_some(), "la console ne se rallume pas : {}", etat["console"]);
    assert_eq!(hote.map(|x| x.visible), Some(false), "le panneau noir de Nevermind est encore montré");
    assert_eq!(etat["pages_applis"]["nevermind"]["montree"], false);
    // Cachée : sa fenêtre lui est rendue (elle peut encore se montrer seule si elle ne quitte pas : « Réduire »)
    if matches!(depart, Depart::CacheeProgrammeLent) {
        assert!(f.appels().iter().any(|a| a == "liberer 1001"), "{:?}", f.appels());
    }
}

/// Ce qui ne change pas : une appli cachée hors de sa page ne fait pas changer de page, et pendant une mise à jour
/// demandée par Mindset (une occupation sur l'appli), la page reste celle de l'appli.
#[test]
fn cachee_hors_de_sa_page_la_page_ne_change_pas() {
    let (mut h, f, faux, mut p) = mindset_avec_nevermind("fermeture-ailleurs");
    let _ = h.recevoir(action("ecrans:onglet", json!("nevermind")), &mut p);
    pas(&mut h, &f, &mut p, 1000);
    assert_eq!(derniere(&p)["pages_applis"]["nevermind"]["etat"], "affiche");
    let _ = h.recevoir(action("ecrans:onglet", json!("parametres")), &mut p);
    pas(&mut h, &f, &mut p, 500);
    let page = h.ctx.vue().page;
    f.changer(1001, |x| x.visible = false);
    pas(&mut h, &f, &mut p, 1000);
    let apres = h.ctx.vue().page;
    let accrochee = h.ctx.lu(partage::ACCROCHEES).map(|a| a["nevermind"]["etat"].clone()).unwrap_or(Value::Null);
    let _ = std::fs::remove_dir_all(&faux.racine);
    assert_eq!(apres, page, "la page a changé alors que Nevermind n'était pas montré");
    assert_eq!(accrochee, "cachee");
}
