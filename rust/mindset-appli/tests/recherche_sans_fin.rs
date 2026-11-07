//! Reproduction du défaut vu par Jordan le 07/11/2026 (Mindset 3.0.0) : « Chercher les nouvelles versions » sur la
//! console, et le petit rond tourne sans fin alors qu'il n'y a pas de nouvelle version de Mindset.
//!
//! Tous les vrais blocs dans l'hôte, les travaux de fond sur de VRAIS fils (comme dans Mindset livré, pas
//! `taches_directes`), un faux GitHub (Mindset 3.0.0 = la version en cours, Nevermind 2.0.2), une horloge d'essai.
//! Rien ne touche le vrai PC.

use std::sync::Arc;
use std::time::{Duration, Instant};

use mindset_appli::hote::{Ecran, Hote};
use mindset_appli::pont::MessagePage;
use mindset_lui_meme::pc::FauxPc;
use mindset_lui_meme::{EnEssai, LuiMeme};
use mindset_noyau::appli::Appli;
use mindset_noyau::reseau::ReponseHttp;
use mindset_noyau::{Vue, essai, partage};
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

fn release(depot: &str, zip: &str, tag: &str) -> String {
    let base = format!("https://github.com/{depot}/releases/download/{tag}");
    json!({ "tag_name": tag, "prerelease": false, "draft": false, "body": "notes",
        "assets": [ { "name": zip, "browser_download_url": format!("{base}/{zip}") },
                    { "name": format!("{zip}.sig"), "browser_download_url": format!("{base}/{zip}.sig") } ] })
    .to_string()
}

fn phase(etat: &Value) -> String {
    etat["console"]["maj"]["phase"].as_str().unwrap_or("<aucune>").to_string()
}

/// La minuterie de l'hôte, comme le fil des blocs, jusqu'à ce que tous les travaux de fond soient finis.
fn finir_taches(h: &mut Hote, p: &mut Page) {
    let debut = Instant::now();
    loop {
        let _ = h.minuterie(p);
        if h.taches_en_cours() == 0 {
            break;
        }
        assert!(debut.elapsed() < Duration::from_secs(10), "travaux de fond jamais finis");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn la_recherche_finie_n_est_jamais_renvoyee_a_la_page() {
    let (ctx, faux) = essai::contexte("recherche-sans-fin");
    let api = "https://api.github.com/repos";
    faux.reseau.repondre(
        &format!("{api}/JordanJacquot/Mindset/releases/latest"),
        Ok(ReponseHttp::ok(release("JordanJacquot/Mindset", "Mindset.zip", "v3.0.0"))),
    );
    faux.reseau.repondre(
        &format!("{api}/JordanJacquot/Nevermind/releases/latest"),
        Ok(ReponseHttp::ok(release("JordanJacquot/Nevermind", "Nevermind.zip", "v2.0.2"))),
    );
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "accueil".into() });

    // Les vrais blocs ; « lui-même » avec la recherche de Mindset permise en essai (MINDSET_MAJ_TEST)
    let mut blocs = mindset_appli::blocs();
    let i = blocs.iter().position(|b| b.nom() == "lui-meme").unwrap();
    let mut lm = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&faux.racine)));
    lm.en_essai = EnEssai { maj: true, ..Default::default() };
    blocs[i] = Box::new(lm);
    let mut h = Hote::nouveau(blocs, ctx);
    h.taches_directes = false; // (comme Mindset livré : chaque travail sur son fil)
    let mut p = Page::default();
    let _ = h.demarrer();
    h.ctx.definir_applis(vec![Appli {
        id: "nevermind".into(),
        nom: "Nevermind".into(),
        depot: "JordanJacquot/Nevermind".into(),
        zip: "Nevermind.zip".into(),
        ..Default::default()
    }]);
    h.fenetre_prete();
    let _ = h.etat_initial();
    let _ = h.minuterie(&mut p);
    let numero = h.etat()["console"]["numero"].as_u64().expect("la console a sa vue");
    let _ = h.recevoir(
        MessagePage::Action { id: "console:pret".into(), valeur: json!({ "cadre": numero }), ecran: String::new() },
        &mut p,
    );
    // La recherche du démarrage, finie ; une minute plus tard (pas de « clics répétés »)
    finir_taches(&mut h, &mut p);
    h.ctx.avancer(Duration::from_secs(60));
    let _ = h.minuterie(&mut p);
    println!("avant le clic : phase envoyée = {}, vraie = {}", phase(p.etats.last().unwrap()), phase(&h.etat()));

    // Le clic sur « Chercher les nouvelles versions » (data-r="actualiser")
    let _ = h.recevoir(
        MessagePage::Action {
            id: "console:action".into(),
            valeur: json!({ "action": "actualiser" }),
            ecran: String::new(),
        },
        &mut p,
    );
    finir_taches(&mut h, &mut p);
    let envoyes_apres_recherche = p.etats.len();
    println!(
        "recherche finie : phase envoyée = {}, vraie = {} ; mindset.maj = {} ; recherche.en_cours = {}",
        phase(p.etats.last().unwrap()),
        phase(&h.etat()),
        h.ctx.lu(partage::MINDSET).unwrap()["maj"],
        h.ctx.lu(partage::RECHERCHE).unwrap()["en_cours"]
    );
    let journal = faux.donnees.lignes();
    println!("journal : {journal:?}");

    let mut vus = Vec::new();
    for (pas, total) in [(5u64, 5u64), (25, 30), (120, 150)] {
        // (le temps passe par petits pas de 100 ms, comme le fil des blocs, pour que chaque tic tombe à son heure)
        for _ in 0..pas * 10 {
            h.ctx.avancer(Duration::from_millis(100));
            let _ = h.minuterie(&mut p);
        }
        let envoyee = phase(p.etats.last().unwrap());
        let vraie = phase(&h.etat());
        println!(
            "+{total} s : phase envoyée à la page = {envoyee}, vraie = {vraie}, états envoyés depuis : {}",
            p.etats.len() - envoyes_apres_recherche
        );
        vus.push((total, envoyee, vraie));
    }
    let _ = std::fs::remove_dir_all(&faux.racine);
    for (t, envoyee, vraie) in &vus {
        assert_ne!(vraie, "recherche", "+{t} s : la recherche est finie côté blocs");
        assert_eq!(envoyee, vraie, "+{t} s : la page a encore « {envoyee} » alors que l'état vrai est « {vraie} »");
    }
}
