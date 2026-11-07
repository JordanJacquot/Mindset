//! Ce que les juges PowerShell ne couvrent pas : la garde d'essai, le rythme de la surveillance, une appli figée, la
//! fenêtre de Mindset absente, la forme de l'état et du tableau commun, la zone, la fin.

use super::*;
use mindset_noyau::essai;
use serde_json::json;

fn evermind() -> Appli {
    Appli {
        id: "evermind".into(),
        nom: "Evermind".into(),
        couleur: "#B04BFF".into(),
        exe: "Evermind.exe".into(),
        mutex: r"Local\Evermind-Instance".into(),
        cache_depuis: "0.12.6".into(),
        ..Default::default()
    }
}

struct Banc {
    ctx: Contexte,
    faux: essai::Faux,
    f: FauxFenetres,
    bloc: BlocAccrochage,
}

impl Banc {
    fn nouveau(nom: &str) -> Banc {
        let (ctx, faux) = essai::contexte(nom);
        ctx.definir_applis(vec![evermind()]);
        ctx.definir_fenetre(Some(77));
        let dossier = r"C:\Essai\Programmes\evermind";
        ctx.au_nom_de("installations", || {
            ctx.publier(
                partage::INSTALLATIONS,
                json!({ "evermind": { "dossier": dossier, "gere": true, "version": "1.3.0" } }),
            )
        });
        let f = FauxFenetres::nouveau();
        let bloc = BlocAccrochage::avec(Box::new(f.clone()));
        Banc { ctx, faux, f, bloc }
    }

    fn page(&mut self, id: &str) -> Effets {
        let mut v = self.ctx.vue();
        v.page = id.into();
        v.visible = true;
        self.ctx.definir_vue(v);
        let mut e = Effets::default();
        self.ctx.au_nom_de("accrochage", || self.bloc.signal(&self.ctx, "page", &json!({ "id": id }), &mut e));
        e
    }

    fn zone(&mut self, l: i32, h: i32) {
        let mut e = Effets::default();
        let z = json!({ "x": 210, "y": 96, "largeur": l, "hauteur": h, "visible": l > 0 });
        assert!(self.bloc.action(&self.ctx, "accrochage:zone", &z, &mut e));
    }

    fn tic(&mut self) -> (Option<Duration>, Effets) {
        let mut e = Effets::default();
        let r = self.ctx.au_nom_de("accrochage", || self.bloc.tic(&self.ctx, &mut e));
        (r, e)
    }

    fn avancer(&self, ms: u64) {
        self.ctx.avancer(Duration::from_millis(ms));
        self.f.avancer_ms(ms);
    }

    /// Evermind tourne, avec sa fenêtre (cachée près de l'horloge).
    fn evermind_ouverte(&self, h: isize) {
        self.faux.systeme.ajouter_processus(501, r"C:\Essai\Programmes\evermind\Mindset.exe", self.f.maintenant() - 1);
        self.f.creer(h, 501, "Evermind", "HwndWrapper[Mindset.exe;;1]", false, false);
    }

    fn pages(&mut self) -> Value {
        self.bloc.etat(&self.ctx)["pages_applis"].clone()
    }
}

impl Drop for Banc {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.faux.racine);
    }
}

#[test]
fn le_bloc_de_l_hote_et_son_nom() {
    // (mindset-appli écrit `Box::new(mindset_accrochage::BlocAccrochage)`)
    let b: Box<dyn Bloc> = Box::new(BlocAccrochage);
    assert_eq!(b.nom(), "accrochage");
    assert!(!BlocAccrochage::default().minuterie());
}

#[test]
fn en_essai_jamais_les_vraies_applis() {
    let (ctx, faux) = essai::contexte("accrochage-garde");
    ctx.definir_applis(vec![evermind()]);
    ctx.au_nom_de("installations", || {
        ctx.publier(
            partage::INSTALLATIONS,
            json!({ "evermind": { "dossier": r"C:\x", "gere": true, "version": "1.3.0" } }),
        )
    });
    let mut b = BlocAccrochage;
    let mut e = Effets::default();
    b.demarrer(&ctx, &mut e);
    assert!(b.fenetres.is_none(), "en essai, sans MINDSET_INTEGRATION_TEST : aucun vrai Windows");
    let mut v = ctx.vue();
    v.page = "evermind".into();
    ctx.definir_vue(v);
    b.signal(&ctx, "page", &json!({ "id": "evermind" }), &mut e);
    let p = &b.etat(&ctx)["pages_applis"]["evermind"];
    assert_eq!(p["titre"], "Evermind s'affichera ici");
    assert_eq!(p["texte"], "(test : les vraies applis ne sont pas lancées)");
    assert!(e.est_vide(), "rien n'est lancé");
    let _ = std::fs::remove_dir_all(&faux.racine);
}

#[test]
fn la_surveillance_garde_son_rythme() {
    let mut b = Banc::nouveau("accrochage-rythme");
    assert_eq!(b.tic().0, None, "rien à surveiller");
    b.zone(1100, 760);
    let e = b.page("evermind");
    assert!(e.est_vide(), "fermée, rien ne demande de la lancer : l'écran Ouvrir");
    let mut e = Effets::default();
    assert!(b.bloc.action(&b.ctx, "accrochage:ouvrir-ici", &json!("evermind"), &mut e));
    assert_eq!(
        e.0,
        vec![Effet::Signal { nom: "lancer-appli".into(), donnees: json!({ "id": "evermind", "demarrage": true }) }]
    );
    assert!(b.bloc.minuterie());
    // Réveillé tout de suite par l'hôte (après une action) : pas de passage avant 400 ms
    b.evermind_ouverte(1001);
    assert_eq!(b.tic().0, Some(INTERVALLE));
    assert!(b.f.appels().is_empty());
    b.avancer(150);
    assert_eq!(b.tic().0, Some(Duration::from_millis(250)));
    b.avancer(250);
    assert_eq!(b.tic().0, Some(INTERVALLE), "accrochée : la surveillance continue");
    assert_eq!(b.f.appels(), vec!["accrocher 1001 1100x760", "focus 1001"]);
    let p = b.pages()["evermind"].clone();
    assert_eq!(p["montree"], true);
    assert_eq!(p["etat"], "affiche");
    let a = b.ctx.lu(partage::ACCROCHEES).unwrap();
    assert_eq!(a, json!({ "evermind": { "etat": "affiche", "pid": 501, "fenetre": 1001 } }));
    let hote = b.f.hote_de("evermind").unwrap();
    assert!(hote.visible);
    assert_eq!(hote.parent, 77, "dans la fenêtre de Mindset");
    assert_eq!(hote.zone, Zone { x: 210, y: 96, largeur: 1100, hauteur: 760, visible: true });
}

#[test]
fn une_appli_figee_ou_sans_fenetre_de_mindset_attend() {
    let mut b = Banc::nouveau("accrochage-figee");
    b.zone(900, 700);
    b.evermind_ouverte(1001);
    b.f.changer(1001, |x| x.repond = false);
    b.ctx.definir_fenetre(None);
    b.page("evermind");
    assert!(b.f.appels().is_empty(), "ni accrochée, ni bloquée avec elle");
    assert_eq!(b.pages()["evermind"]["etat"], "vide");
    b.ctx.definir_fenetre(Some(77));
    b.page("evermind");
    assert!(b.f.appels().is_empty(), "elle ne répond toujours pas");
    b.f.changer(1001, |x| x.repond = true);
    b.page("evermind");
    assert_eq!(b.f.appels(), vec!["accrocher 1001 900x700", "focus 1001"]);
}

#[test]
fn la_jauge_dans_l_etat_de_la_page() {
    let mut b = Banc::nouveau("accrochage-jauge");
    b.ctx.ecrire_reglage("Ouverture-evermind", json!(6.5));
    b.zone(1100, 760);
    b.page("evermind");
    let mut e = Effets::default();
    b.bloc.action(&b.ctx, "accrochage:ouvrir-ici", &json!(null), &mut e);
    let p = b.pages()["evermind"].clone();
    let debut = (fenetres::DEPART_ESSAI - FT_EPOQUE_UNIX) / 10_000;
    assert_eq!(p["jauge"], json!({ "texte": "Ouverture...", "depuis_ms": debut, "duree_s": 6.5 }));
    assert_eq!(p["ecran_ouvrir"], false);
    assert_eq!(p["bouton_ici"], false);
    assert_eq!(p["couleur"], "#B04BFF");
    b.page("accueil");
    assert_eq!(b.pages()["evermind"]["jauge"], Value::Null, "la jauge ne reste que sur sa page");
    // (le thème change la couleur du titre)
    b.ctx.au_nom_de("parametres", || b.ctx.publier(partage::THEME, json!({ "couleurs": { "#B04BFF": "#FF8A3D" } })));
    b.page("evermind");
    assert_eq!(b.pages()["evermind"]["couleur"], "#FF8A3D");
}

#[test]
fn le_voile_du_tableau_commun_et_la_zone_sans_taille() {
    let mut b = Banc::nouveau("accrochage-voile");
    b.zone(1100, 760);
    b.evermind_ouverte(1001);
    b.ctx.au_nom_de("ecrans", || b.ctx.publier(partage::VOILE, json!(true)));
    b.page("evermind");
    assert!(!b.f.hote_de("evermind").unwrap().visible, "une question est par-dessus (lue dans le tableau commun)");
    let mut e = Effets::default();
    b.bloc.signal(&b.ctx, "voile", &json!({ "visible": false }), &mut e);
    assert!(b.f.hote_de("evermind").unwrap().visible);
    // Mindset réduit : la zone sans taille est ignorée, l'appli garde sa place et sa taille
    b.f.prendre_appels();
    b.zone(0, 0);
    assert!(b.f.prendre_appels().is_empty());
    assert_eq!(b.f.fenetre(1001).unwrap().taille, (1100, 760));
    b.zone(1000, 700);
    assert_eq!(b.f.prendre_appels(), vec!["redimensionner 1001 1000x700"]);
    assert_eq!(b.f.hote_de("evermind").unwrap().zone.largeur, 1000);
    // (une zone illisible est ignorée)
    assert!(b.bloc.action(&b.ctx, "accrochage:zone", &json!({ "x": "a" }), &mut e));
    assert!(!b.bloc.action(&b.ctx, "accrochage:autre", &json!(null), &mut e));
}

#[test]
fn ouvrir_appli_change_de_page_puis_la_lance() {
    let mut b = Banc::nouveau("accrochage-ouvrir");
    let mut e = Effets::default();
    b.bloc.signal(&b.ctx, "ouvrir-appli", &json!({ "id": "evermind", "lancer": false }), &mut e);
    assert_eq!(e.0, vec![Effet::Page("evermind".into())]);
    let e = b.page("evermind");
    assert!(e.est_vide(), "sans « lancer » : seulement sa page");
    let mut e = Effets::default();
    b.bloc.signal(&b.ctx, "ouvrir-appli", &json!({ "id": "evermind", "lancer": true }), &mut e);
    let e = b.page("evermind");
    assert_eq!(
        e.0,
        vec![Effet::Signal { nom: "lancer-appli".into(), donnees: json!({ "id": "evermind", "demarrage": true }) }]
    );
    let mut e = Effets::default();
    b.bloc.signal(&b.ctx, "ouvrir-appli", &json!({ "id": "inconnue" }), &mut e);
    assert!(e.est_vide(), "une appli hors de la liste");
}

#[test]
fn un_arret_refuse_est_note_et_la_fin_rend_tout() {
    let mut b = Banc::nouveau("accrochage-fin");
    let mut e = Effets::default();
    let r = Ok(json!({ "id": "evermind", "arretes": 0, "refus": ["Accès refusé."] }));
    b.bloc.tache_finie(&b.ctx, "bloques:1:evermind", r, &mut e);
    assert_eq!(b.faux.donnees.lignes(), vec!["Evermind bloqué sans fenêtre, arrêt refusé par Windows : Accès refusé."]);
    assert!(e.est_vide(), "rien d'arrêté : pas de relance");
    b.bloc.tache_finie(&b.ctx, "x", Err("panique".into()), &mut e);
    b.zone(800, 600);
    b.evermind_ouverte(1001);
    b.page("evermind");
    b.bloc.fermer(&b.ctx);
    assert_eq!(b.f.appels().last().map(String::as_str), Some("liberer 1001"));
    assert!(b.f.fini());
    assert_eq!(b.f.fenetre(1001).unwrap().parent, None);
}

#[test]
fn arrondis_comme_powershell() {
    assert_eq!(arrondi_pair(2.5), 2.0);
    assert_eq!(arrondi_pair(3.5), 4.0);
    assert_eq!(arrondi_pair(60.4), 60.0);
    assert_eq!(duree_reglage(&json!("12.5")), 12.5);
    assert_eq!(duree_reglage(&json!(true)), 1.0);
    assert_eq!(duree_reglage(&json!([1])), 0.0);
    assert_eq!(duree_reglage(&json!("abc")), 0.0);
}
