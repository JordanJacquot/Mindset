//! Reproduction du défaut vu par Jordan le 15/11/2026 à 22:03 (Mindset 3.0.6) : de retour sur la console après une
//! autre page (Paymind, plus d'une minute : la console s'était fermée), le clic sur Nevermind lance bien Nevermind,
//! mais la barre « Chargement » reste à 0 % puis saute à 100 % au moment où Nevermind s'affiche, 16 s plus tard.
//! La console n'était pas regardée : l'hôte ne réveille un bloc après un geste que s'il n'avait aucun tic prévu, et la
//! console en avait un, lointain. Elle ne voyait donc ni l'attente (300 ms) ni la fenêtre avant ce tic-là.
//!
//! Même départ que `relance_visible.rs` : tous les vrais blocs dans l'hôte, le faux Windows de l'accrochage, un faux
//! Nevermind (son programme, puis sa fenêtre 15 s plus tard). Rien ne touche le vrai PC.

use std::time::Duration;

use mindset_accrochage::{BlocAccrochage, FauxFenetres, Fenetres};
use mindset_appli::hote::{Ecran, Hote};
use mindset_appli::pont::MessagePage;
use mindset_console::BlocConsole;
use mindset_noyau::appli::Appli;
use mindset_noyau::essai;
use serde_json::{Value, json};

#[derive(Default)]
struct Page {
    ordres: Vec<Value>,
}
impl Ecran for Page {
    fn etat(&mut self, _: Value) {}
    fn ordre(&mut self, o: Value) {
        self.ordres.push(o);
    }
}

struct VuesParLaConsole(FauxFenetres);
impl mindset_console::Fenetres for VuesParLaConsole {
    fn trouvee(&self, pid: u32, titre: &str) -> bool {
        self.0.trouver(pid, titre).is_some()
    }
}

fn action(id: &str, valeur: Value) -> MessagePage {
    MessagePage::Action { id: id.into(), valeur, ecran: String::new() }
}

/// Les avancées de la barre envoyées à la scène pour Nevermind.
fn avancees(p: &Page) -> Vec<f64> {
    p.ordres
        .iter()
        .filter(|o| o["appel"] == "avancee" && o["args"][0] == "nevermind")
        .filter_map(|o| o["args"][1].as_f64())
        .collect()
}

#[test]
fn de_retour_sur_la_console_la_barre_d_ouverture_avance_des_le_clic() {
    let (ctx, faux) = essai::contexte("ouverture-progressive");
    let nevermind = ctx.dossiers.programmes.join("Nevermind");
    std::fs::create_dir_all(&nevermind).unwrap();
    std::fs::write(nevermind.join("Nevermind.exe"), "exe").unwrap();
    std::fs::write(nevermind.join("Mindset.exe"), "hote").unwrap();
    std::fs::write(nevermind.join("version.json"), r#"{"version":"2.3.6","appli":"nevermind"}"#).unwrap();
    let inst = json!({ "nevermind": { "dossier": nevermind.to_string_lossy(), "gere": true } });
    std::fs::write(ctx.dossiers.donnees.join("installations.json"), inst.to_string()).unwrap();
    // (la durée retenue chez Jordan pour Nevermind)
    ctx.ecrire_reglage("Ouverture-nevermind", json!(16.1));

    let f = FauxFenetres::nouveau();
    let mut blocs = mindset_appli::blocs();
    let i = blocs.iter().position(|b| b.nom() == "accrochage").unwrap();
    blocs[i] = Box::new(BlocAccrochage::avec(Box::new(f.clone())));
    let i = blocs.iter().position(|b| b.nom() == "console").unwrap();
    blocs[i] = Box::new(BlocConsole::avec_fenetres(Box::new(VuesParLaConsole(f.clone()))));
    let mut h = Hote::nouveau(blocs, ctx);
    h.taches_directes = true;

    let _ = h.demarrer();
    h.ctx.definir_applis(vec![Appli {
        id: "nevermind".into(),
        genre: "rust".into(),
        nom: "Nevermind".into(),
        couleur: "#00E5FF".into(),
        exe: "Nevermind.exe".into(),
        mutex: r"Local\NevermindEssai-ouverture-progressive".into(),
        admin: true,
        sans_droits_depuis: "1.15.0".into(),
        cache_depuis: "0.12.6".into(),
        ..Default::default()
    }]);
    let mut v = h.ctx.vue();
    v.visible = true;
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

    let pas = |h: &mut Hote, p: &mut Page, ms: u64| {
        for _ in 0..ms / 100 {
            h.ctx.avancer(Duration::from_millis(100));
            f.avancer_ms(100);
            let _ = h.minuterie(p);
        }
    };
    pas(&mut h, &mut p, 10_000);
    // Une autre page plus d'une minute (la console se ferme), puis le retour sur l'accueil : une nouvelle scène
    let _ = h.recevoir(MessagePage::Ecran { id: "parametres".into() }, &mut p);
    pas(&mut h, &mut p, 75_000);
    let _ = h.recevoir(MessagePage::Ecran { id: "accueil".into() }, &mut p);
    pas(&mut h, &mut p, 500);
    let numero = h.etat()["console"]["numero"].as_u64().expect("de retour sur l'accueil, la console a une scène");
    let _ = h.recevoir(action("console:pret", json!({ "cadre": numero })), &mut p);
    pas(&mut h, &mut p, 3_000);

    // Le clic sur Nevermind : son programme démarre, sa fenêtre arrive 15 s plus tard
    p.ordres.clear();
    let _ = h.recevoir(action("console:action", json!({ "action": "ouvrir", "id": "nevermind" })), &mut p);
    assert_eq!(faux.systeme.lances().len(), 1, "Nevermind est lancé");
    faux.systeme.ajouter_processus(501, &nevermind.join("Mindset.exe").to_string_lossy(), f.maintenant());
    pas(&mut h, &mut p, 1_000);
    let apres_une_seconde = avancees(&p);
    pas(&mut h, &mut p, 14_000);
    let a_quinze = avancees(&p);
    f.creer(1001, 501, "Nevermind", "Tauri Window", false, false);
    pas(&mut h, &mut p, 1_000);
    let prete = p.ordres.iter().any(|o| o["appel"] == "appliPrete" && o["args"][0] == "nevermind");
    let journal = faux.donnees.lignes();
    let _ = std::fs::remove_dir_all(&faux.racine);

    assert!(
        apres_une_seconde.iter().any(|v| *v > 0.0),
        "une seconde après le clic, la barre n'a pas bougé : {apres_une_seconde:?}\n{journal:#?}"
    );
    assert!(a_quinze.len() >= 30, "la barre doit avancer tout au long des 15 s : {} avancées", a_quinze.len());
    assert!(a_quinze.windows(2).all(|w| w[0] <= w[1]), "la barre ne recule jamais : {a_quinze:?}");
    assert!(a_quinze.last().is_some_and(|v| *v > 0.7 && *v < 1.0), "à 15 s sur 16 attendues : {a_quinze:?}");
    assert!(prete, "Nevermind est prête une fois sa fenêtre trouvée");
}
