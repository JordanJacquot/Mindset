//! Audit G4 (08/11/2026), par l'hôte : une appli lancée par Mindset dont la fenêtre arrive pendant qu'elle est occupée
//! (Nevermind qui démarre). Avant la correction, la surveillance de l'accrochage s'arrêtait à ce moment-là, et la page
//! gardait la jauge « Ouverture... » pour toujours, même quand l'appli répondait une seconde plus tard.
//!
//! Le vrai bloc d'accrochage dans le vrai hôte, sa vraie minuterie, sur le faux Windows (`FauxFenetres`) : aucune
//! fenêtre, aucun programme, rien sur le vrai PC. Personne ne renvoie de signal à la main.

use std::time::Duration;

use mindset_accrochage::{BlocAccrochage, FauxFenetres, Fenetres};
use mindset_appli::hote::{Ecran, Hote};
use mindset_appli::pont::MessagePage;
use mindset_noyau::appli::Appli;
use mindset_noyau::{Bloc, Vue, essai, partage};
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

fn action(id: &str, valeur: Value) -> MessagePage {
    MessagePage::Action { id: id.into(), valeur, ecran: String::new() }
}

/// L'état de la page d'Evermind tel que la page l'a reçu en dernier.
fn page_evermind(p: &Page) -> Value {
    p.etats.last().map(|e| e["pages_applis"]["evermind"].clone()).unwrap_or(Value::Null)
}

#[test]
fn occupee_au_moment_ou_sa_fenetre_arrive_elle_finit_affichee() {
    let (ctx, faux) = essai::contexte("accrochage-occupee-hote");
    ctx.definir_applis(vec![Appli {
        id: "evermind".into(),
        nom: "Evermind".into(),
        couleur: "#B04BFF".into(),
        exe: "Evermind.exe".into(),
        mutex: r"Local\Evermind-Instance".into(),
        cache_depuis: "0.12.6".into(),
        ..Default::default()
    }]);
    ctx.definir_fenetre(Some(77));
    ctx.au_nom_de("installations", || {
        ctx.publier(
            partage::INSTALLATIONS,
            json!({ "evermind": { "dossier": r"C:\Essai\Programmes\evermind", "gere": true, "version": "1.3.0" } }),
        )
    });
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "evermind".into() });
    let f = FauxFenetres::nouveau();
    let blocs: Vec<Box<dyn Bloc>> = vec![Box::new(BlocAccrochage::avec(Box::new(f.clone())))];
    let mut h = Hote::nouveau(blocs, ctx);
    h.taches_directes = true;
    let mut p = Page::default();
    let _ = h.demarrer();
    h.fenetre_prete();
    let _ = h.etat_initial();
    let z = json!({ "x": 210, "y": 96, "largeur": 1100, "hauteur": 760, "visible": true });
    let _ = h.recevoir(action("accrochage:zone", z), &mut p);
    // Le clic sur « Ouvrir Evermind »
    let _ = h.recevoir(action("accrochage:ouvrir-ici", json!("evermind")), &mut p);
    assert_eq!(page_evermind(&p)["etat"], "lancement");

    // Son programme démarre ; sa fenêtre existe, mais il ne répond pas pendant 2 s
    faux.systeme.ajouter_processus(501, r"C:\Essai\Programmes\evermind\Mindset.exe", f.maintenant());
    f.creer(1001, 501, "Evermind", "HwndWrapper[Mindset.exe;;1]", false, false);
    f.changer(1001, |x| x.repond = false);
    let pas = |h: &mut Hote, p: &mut Page, n: u32| {
        for _ in 0..n {
            h.ctx.avancer(Duration::from_millis(100));
            f.avancer_ms(100);
            let _ = h.minuterie(p);
        }
    };
    pas(&mut h, &mut p, 20);
    assert_eq!(page_evermind(&p)["etat"], "lancement", "elle ne répond pas encore");
    // Elle répond : la surveillance l'accroche d'elle-même
    f.changer(1001, |x| x.repond = true);
    pas(&mut h, &mut p, 10);
    let vue = page_evermind(&p);
    let appels = f.appels();
    let journal = faux.donnees.lignes();
    let _ = std::fs::remove_dir_all(&faux.racine);
    println!("page reçue : {vue}\nappels : {appels:?}\njournal : {journal:?}");
    assert!(appels.iter().any(|a| a == "accrocher 1001 1100x760"), "jamais accrochée : {appels:?}");
    assert_eq!(vue["etat"], "affiche", "la page a encore la jauge : {vue}");
    assert_eq!(vue["jauge"], Value::Null);
    assert_eq!(vue["montree"], true);
    assert_eq!(journal.iter().filter(|l| l.contains("ne répond pas encore")).count(), 1, "{journal:?}");
}
