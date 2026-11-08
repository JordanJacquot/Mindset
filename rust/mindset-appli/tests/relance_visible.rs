//! Reproduction du défaut vu par Jordan le 08/11/2026 à 14:35 (Mindset 3.0.2, déjà dans 3.0.0 et 3.0.1) : Mindset se
//! relance après une mise à jour demandée à l'écran (`-Demarrage` et `MajMindsetVisible`), sa fenêtre est montrée,
//! mais les blocs la croient cachée. La console 3D se ferme alors au bout d'une minute (« une minute sur une autre
//! page »), même sous les yeux de Jordan : Nevermind, qu'il ouvrait depuis la console, s'est lancé caché et n'a jamais
//! été affiché (la scène fermée ne pouvait plus dire « afficher »), la page est restée vide.
//!
//! Le départ est celui de `programme.rs` (la vue de départ vient de [`Hote::montree_au_depart`]), puis tous les vrais
//! blocs dans l'hôte, le faux Windows de l'accrochage (`FauxFenetres`, aussi regardé par la console), un faux
//! Nevermind (son programme, puis sa fenêtre 15 s plus tard). La scène de la console est jouée par le test : elle dit
//! « afficher » quand Mindset lui dit que l'appli est prête, comme scene.html. Rien ne touche le vrai PC.

use std::time::Duration;

use mindset_accrochage::{BlocAccrochage, FauxFenetres, Fenetres};
use mindset_appli::hote::{Demande, Ecran, Hote};
use mindset_appli::pont::MessagePage;
use mindset_console::BlocConsole;
use mindset_noyau::appli::Appli;
use mindset_noyau::{Lancement, essai, partage};
use serde_json::{Value, json};

#[derive(Default)]
struct Page {
    etats: Vec<Value>,
    ordres: Vec<Value>,
}
impl Ecran for Page {
    fn etat(&mut self, e: Value) {
        self.etats.push(e);
    }
    fn ordre(&mut self, o: Value) {
        self.ordres.push(o);
    }
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

#[test]
fn relance_apres_une_mise_a_jour_a_l_ecran_nevermind_ouvert_depuis_la_console_est_affiche() {
    let (ctx, faux) = essai::contexte_avec("relance-visible", Lancement { demarrage: true, ..Default::default() });
    // (ce que Mindset écrit avant de se relancer pour une mise à jour demandée à l'écran)
    ctx.ecrire_reglage("MajMindsetVisible", json!(true));
    ctx.ecrire_reglage("TachesRefaitesPour", json!("3.0.0"));
    let nevermind = ctx.dossiers.programmes.join("Nevermind");
    std::fs::create_dir_all(&nevermind).unwrap();
    std::fs::write(nevermind.join("Nevermind.exe"), "exe").unwrap();
    std::fs::write(nevermind.join("Mindset.exe"), "hote").unwrap();
    std::fs::write(nevermind.join("version.json"), r#"{"version":"2.1.0","appli":"nevermind"}"#).unwrap();
    let inst = json!({ "nevermind": { "dossier": nevermind.to_string_lossy(), "gere": true } });
    std::fs::write(ctx.dossiers.donnees.join("installations.json"), inst.to_string()).unwrap();

    let f = FauxFenetres::nouveau();
    let mut blocs = mindset_appli::blocs();
    let i = blocs.iter().position(|b| b.nom() == "accrochage").unwrap();
    blocs[i] = Box::new(BlocAccrochage::avec(Box::new(f.clone())));
    let i = blocs.iter().position(|b| b.nom() == "console").unwrap();
    blocs[i] = Box::new(BlocConsole::avec_fenetres(Box::new(VuesParLaConsole(f.clone()))));
    let mut h = Hote::nouveau(blocs, ctx);
    h.taches_directes = true;

    // Le départ, comme programme.rs : les blocs démarrent, puis la fenêtre est créée, montrée si elle doit l'être
    let au_depart = h.demarrer();
    // (la liste des applis, après le démarrage du bloc « liste » qui n'a pas d'apps.json ici)
    h.ctx.definir_applis(vec![Appli {
        id: "nevermind".into(),
        genre: "rust".into(),
        nom: "Nevermind".into(),
        couleur: "#00E5FF".into(),
        exe: "Nevermind.exe".into(),
        mutex: r"Local\NevermindEssai-relance-visible".into(),
        admin: true,
        sans_droits_depuis: "1.15.0".into(),
        cache_depuis: "0.12.6".into(),
        ..Default::default()
    }]);
    assert!(au_depart.iter().any(|d| matches!(d, Demande::Fenetre(mindset_noyau::Fenetre::Montrer))));
    let montree = Hote::montree_au_depart(true, &au_depart);
    let mut v = h.ctx.vue();
    v.visible = montree;
    h.ctx.definir_vue(v);
    h.ctx.definir_fenetre(Some(77));
    h.fenetre_prete();
    let _ = h.etat_initial();
    let mut p = Page::default();
    let _ = h.minuterie(&mut p);
    // (la fenêtre de Mindset est à l'écran : Windows la montre, quoi que pensent les blocs)
    let z = json!({ "x": 210, "y": 96, "largeur": 1100, "hauteur": 760, "visible": true });
    let _ = h.recevoir(action("accrochage:zone", z), &mut p);
    let numero = h.etat()["console"]["numero"].as_u64().expect("la console a sa scène");
    let _ = h.recevoir(action("console:pret", json!({ "cadre": numero })), &mut p);

    let pas = |h: &mut Hote, p: &mut Page, s: u64| {
        for _ in 0..s * 10 {
            h.ctx.avancer(Duration::from_millis(100));
            f.avancer_ms(100);
            let _ = h.minuterie(p);
        }
    };
    // 45 s plus tard (la mise à jour de Nevermind vient de finir), le clic sur « Ouvrir Nevermind » dans la console
    pas(&mut h, &mut p, 45);
    let _ = h.recevoir(action("console:action", json!({ "action": "ouvrir", "id": "nevermind" })), &mut p);
    let lance = faux.systeme.lances();
    assert_eq!(lance.len(), 1, "Nevermind est lancé : {lance:?}");
    // Son programme démarre tout de suite ; sa fenêtre (cachée, comme -Demarrage) arrive 15 s plus tard
    faux.systeme.ajouter_processus(501, &nevermind.join("Mindset.exe").to_string_lossy(), f.maintenant());
    pas(&mut h, &mut p, 15);
    f.creer(1001, 501, "Nevermind", "Tauri Window", false, false);
    // La scène : « appliPrete » reçu, elle plonge dans l'écran et dit « afficher » (scene.html, remplirEcran)
    let mut affichee = false;
    for _ in 0..100 {
        pas(&mut h, &mut p, 1);
        let prete = p.ordres.iter().any(|o| o["appel"] == "appliPrete" && o["args"][0] == "nevermind");
        if prete && !affichee {
            affichee = true;
            let _ = h.recevoir(action("console:afficher", json!({ "id": "nevermind" })), &mut p);
        }
    }
    let accrochee = h.ctx.lu(partage::ACCROCHEES).map(|a| a["nevermind"].clone()).unwrap_or(Value::Null);
    let journal = faux.donnees.lignes();
    let vue = h.ctx.vue();
    let _ = std::fs::remove_dir_all(&faux.racine);
    println!("vue : {vue:?}\naccrochée : {accrochee}\njournal : {journal:#?}");
    assert!(vue.visible, "la fenêtre est montrée, les blocs la croient cachée");
    // (une minute après que Nevermind a pris la place de la console, elle se ferme : c'est voulu ; avant, jamais)
    let fermee = journal.iter().position(|l| l.contains("Console 3D fermée"));
    let affiche = journal.iter().position(|l| l == "Nevermind affiché dans Mindset");
    assert!(
        fermee.is_none() || affiche.is_some_and(|a| fermee > Some(a)),
        "la console s'est fermée sous les yeux de Jordan, avant que Nevermind soit affiché : {journal:#?}"
    );
    assert_eq!(accrochee["etat"], "affiche", "Nevermind n'a jamais été affiché dans Mindset : {journal:#?}");
}
