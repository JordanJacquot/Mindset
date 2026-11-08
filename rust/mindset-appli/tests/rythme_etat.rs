//! Audit M2 (08/11/2026) : depuis la correction du 07/11 (c3bac20), l'hôte refait l'état complet après chaque tic,
//! même sans effet. Le bloc « près de l'horloge » tique toutes les 150 ms tant que l'icône existe (pour lire ses
//! clics) : l'état était donc refait environ 6,7 fois par seconde, pour toujours, Mindset caché compris (pendant les
//! jeux), avec suite.json relu sur le disque à chaque fois (`son_suite`, appelé par l'état des Paramètres).
//!
//! Ici : tous les vrais blocs dans l'hôte, l'icône est une fausse icône (aucune fenêtre), le disque d'essai compte les
//! lectures de suite.json. Le temps avance comme dans le fil des blocs (jusqu'au prochain tic dû, 200 ms au plus).
//! Rien ne touche le vrai PC.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use mindset_appli::hote::{Ecran, Hote};
use mindset_horloge::BlocHorloge;
use mindset_horloge::icone::FausseIcone;
use mindset_noyau::donnees::{Donnees, DonneesMemoire, Dossiers, Suite};
use mindset_noyau::{Contexte, Lancement, Ports, Vue, essai};
use serde_json::Value;

/// Le disque d'essai, qui compte les lectures de suite.json (`suite` et `son_suite` le relisent chacun une fois).
struct Compteur {
    d: Arc<DonneesMemoire>,
    lectures: Arc<AtomicUsize>,
}

impl Donnees for Compteur {
    fn journal(&self, t: &str) {
        self.d.journal(t)
    }
    fn reglage(&self, n: &str) -> Option<Value> {
        self.d.reglage(n)
    }
    fn ecrire_reglage(&self, n: &str, v: Value) {
        self.d.ecrire_reglage(n, v)
    }
    fn lire_json(&self, f: &Path) -> Result<Option<Value>, String> {
        self.d.lire_json(f)
    }
    fn ecrire_json(&self, f: &Path, v: &Value) -> Result<(), String> {
        self.d.ecrire_json(f, v)
    }
    fn suite(&self) -> Suite {
        self.lectures.fetch_add(1, Ordering::Relaxed);
        self.d.suite()
    }
    fn theme_suite(&self) -> String {
        self.d.theme_suite()
    }
    fn ecrire_theme_suite(&self, t: &str) {
        self.d.ecrire_theme_suite(t)
    }
    fn ecrire_suite_appli(&self, id: &str, d: Option<&str>) {
        self.d.ecrire_suite_appli(id, d)
    }
    fn son_suite(&self) -> (String, String) {
        self.lectures.fetch_add(1, Ordering::Relaxed);
        self.d.son_suite()
    }
    fn ecrire_son_suite(&self, q: &str, n: &str) {
        self.d.ecrire_son_suite(q, n)
    }
}

#[derive(Default)]
struct Page {
    etats: usize,
}
impl Ecran for Page {
    fn etat(&mut self, _: Value) {
        self.etats += 1;
    }
    fn ordre(&mut self, _: Value) {}
}

/// Le fil des blocs pendant `secondes` : (lectures de suite.json par seconde, états envoyés à la page).
fn tourner(h: &mut Hote, p: &mut Page, lectures: &AtomicUsize, secondes: u64) -> (f64, usize) {
    let avant = lectures.load(Ordering::Relaxed);
    let envoyes = p.etats;
    let fin = h.ctx.ecoule() + Duration::from_secs(secondes);
    while h.ctx.ecoule() < fin {
        let attente = h.prochain_tic(Duration::from_millis(200)).max(Duration::from_millis(1));
        h.ctx.avancer(attente);
        let _ = h.minuterie(p);
    }
    ((lectures.load(Ordering::Relaxed) - avant) as f64 / secondes as f64, p.etats - envoyes)
}

#[test]
fn l_etat_n_est_pas_refait_a_chaque_tic_de_l_icone() {
    let (_, faux) = essai::contexte("rythme-etat");
    let dossiers = Dossiers::sous(&faux.racine);
    let lectures = Arc::new(AtomicUsize::new(0));
    let ports = Ports {
        donnees: Arc::new(Compteur { d: faux.donnees.clone(), lectures: lectures.clone() }),
        reseau: faux.reseau.clone(),
        installateur: faux.installateur.clone(),
        systeme: faux.systeme.clone(),
    };
    let ctx = Contexte::nouveau(dossiers, "3.0.0", Lancement::default(), true, ports, 4242);
    if let Some(heure) = mindset_noyau::moment::lire_iso(essai::HEURE_ESSAI) {
        ctx.figer_heure(heure);
    }
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "accueil".into() });
    let mut blocs = mindset_appli::blocs();
    let i = blocs.iter().position(|b| b.nom() == "horloge").unwrap();
    let icone = FausseIcone::nouvelle();
    blocs[i] = Box::new(BlocHorloge::avec_icone(Box::new(icone.clone())));
    let mut h = Hote::nouveau(blocs, ctx);
    h.taches_directes = true;
    let mut p = Page::default();
    let _ = h.demarrer();
    h.fenetre_prete();
    let _ = h.etat_initial();
    // (le démarrage passé : les premiers tics, les recherches d'essai)
    let _ = tourner(&mut h, &mut p, &lectures, 5);

    let (montre, envoyes_montre) = tourner(&mut h, &mut p, &lectures, 20);
    let _ = h.fenetre_changee(false, false, &mut p);
    let _ = tourner(&mut h, &mut p, &lectures, 2);
    let (cache, envoyes_cache) = tourner(&mut h, &mut p, &lectures, 60);
    println!(
        "Mindset montré : {montre:.2} lectures de suite.json par seconde ({envoyes_montre} états envoyés en 20 s)"
    );
    println!("Mindset caché : {cache:.2} lectures de suite.json par seconde ({envoyes_cache} états envoyés en 60 s)");

    // Un clic sur l'icône (un tic de l'horloge AVEC un effet) : l'état suit toujours
    icone.geste(mindset_horloge::icone::Geste::Clic);
    let _ = tourner(&mut h, &mut p, &lectures, 1);
    let vue = h.ctx.vue();
    let _ = std::fs::remove_dir_all(&faux.racine);
    assert!(vue.visible, "le clic sur l'icône rouvre Mindset");
    assert!(cache <= 0.5, "Mindset caché : {cache:.2} lectures de suite.json par seconde (au plus 0,5 voulu)");
    assert!(montre <= 2.0, "Mindset montré : {montre:.2} lectures de suite.json par seconde (au plus 2 voulu)");
}
