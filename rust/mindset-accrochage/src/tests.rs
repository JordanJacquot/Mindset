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
    // (mindset-appli écrit `Box::new(mindset_accrochage::BlocAccrochage::default())`)
    let b: Box<dyn Bloc> = Box::new(BlocAccrochage::default());
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
    let mut b = BlocAccrochage::default();
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

/// Avant le 08/11/2026 (audit G4), ce test renvoyait lui-même le signal « page » pour faire réessayer : dans Mindset,
/// personne ne le renvoie. Ici, seule la surveillance (les tics) fait réessayer.
#[test]
fn une_appli_figee_ou_sans_fenetre_de_mindset_attend() {
    let mut b = Banc::nouveau("accrochage-figee");
    b.zone(900, 700);
    b.evermind_ouverte(1001);
    b.f.changer(1001, |x| x.repond = false);
    b.ctx.definir_fenetre(None);
    b.page("evermind");
    assert!(b.f.appels().is_empty(), "ni accrochée, ni bloquée avec elle");
    assert!(b.bloc.minuterie(), "pas encore prête : la surveillance la regarde");
    assert_eq!(b.pages()["evermind"]["etat"], "lancement");
    assert!(!b.pages()["evermind"]["jauge"].is_null(), "la jauge « Ouverture... », pas une page vide");
    b.ctx.definir_fenetre(Some(77));
    b.avancer(400);
    assert_eq!(b.tic().0, Some(INTERVALLE), "elle ne répond toujours pas : la surveillance continue");
    assert!(b.f.appels().is_empty(), "elle ne répond toujours pas");
    b.f.changer(1001, |x| x.repond = true);
    b.avancer(400);
    b.tic();
    assert_eq!(b.f.appels(), vec!["accrocher 1001 900x700", "focus 1001"]);
    assert_eq!(b.pages()["evermind"]["etat"], "affiche");
    let notes: Vec<String> = b.faux.donnees.lignes().into_iter().filter(|l| l.contains("pas encore")).collect();
    assert_eq!(notes.len(), 1, "une seule ligne au journal pour toute l'attente : {notes:?}");
}

/// Audit G4, cas A : lancée par Mindset, sa fenêtre arrive pendant qu'elle est occupée (Nevermind qui démarre). Avant
/// le 08/11/2026, la surveillance s'arrêtait là, et la jauge « Ouverture... » restait pour toujours.
#[test]
fn lancee_puis_occupee_un_instant_elle_est_accrochee_quand_elle_repond() {
    let mut b = Banc::nouveau("accrochage-occupee-lancee");
    b.zone(1100, 760);
    b.page("evermind");
    let mut e = Effets::default();
    b.bloc.action(&b.ctx, "accrochage:ouvrir-ici", &json!("evermind"), &mut e);
    assert!(b.bloc.minuterie());
    // Son programme démarre, sa fenêtre existe, mais il ne répond pas dans la seconde
    b.faux.systeme.ajouter_processus(501, r"C:\Essai\Programmes\evermind\Mindset.exe", b.f.maintenant());
    b.f.creer(1001, 501, "Evermind", "HwndWrapper[Mindset.exe;;1]", false, false);
    b.f.changer(1001, |x| x.repond = false);
    for _ in 0..5 {
        b.avancer(400);
        assert_eq!(b.tic().0, Some(INTERVALLE), "trouvée mais pas prête : la surveillance continue");
    }
    assert!(b.f.appels().is_empty());
    assert_eq!(b.pages()["evermind"]["etat"], "lancement");
    assert!(!b.pages()["evermind"]["jauge"].is_null());
    // Elle répond : accrochée au passage suivant, sans rien d'autre
    b.f.changer(1001, |x| x.repond = true);
    b.avancer(400);
    b.tic();
    assert_eq!(b.f.appels(), vec!["accrocher 1001 1100x760", "focus 1001"]);
    let p = b.pages()["evermind"].clone();
    assert_eq!(p["etat"], "affiche");
    assert_eq!(p["jauge"], Value::Null);
    assert_eq!(
        b.faux.donnees.lignes().iter().filter(|l| l.contains("ne répond pas encore")).count(),
        1,
        "une seule ligne : {:?}",
        b.faux.donnees.lignes()
    );
}

/// Audit G4, cas B : déjà ouverte près de l'horloge, occupée au moment du clic sur son onglet. Avant le 08/11/2026,
/// la page restait vide (seulement son nom), sans jauge ni surveillance.
#[test]
fn deja_ouverte_mais_occupee_elle_est_accrochee_quand_elle_repond() {
    let mut b = Banc::nouveau("accrochage-occupee-ouverte");
    b.zone(1100, 760);
    b.evermind_ouverte(1001);
    b.f.changer(1001, |x| x.repond = false);
    b.page("evermind");
    assert!(b.bloc.minuterie(), "la surveillance la regarde");
    let p = b.pages()["evermind"].clone();
    assert_eq!(p["etat"], "lancement");
    assert_eq!(p["titre"], "Evermind");
    assert!(!p["jauge"].is_null(), "la jauge « Ouverture... »");
    b.f.changer(1001, |x| x.repond = true);
    b.avancer(400);
    b.tic();
    assert_eq!(b.f.appels(), vec!["accrocher 1001 1100x760", "focus 1001"]);
    assert_eq!(b.pages()["evermind"]["etat"], "affiche");
}

/// Une appli trouvée qui ne répond jamais : la limite d'une minute s'applique comme pour une fenêtre jamais venue.
#[test]
fn trouvee_mais_jamais_prete_la_limite_s_applique() {
    let mut b = Banc::nouveau("accrochage-jamais-prete");
    b.zone(1100, 760);
    b.evermind_ouverte(1001);
    b.f.changer(1001, |x| x.repond = false);
    b.page("evermind");
    for _ in 0..160 {
        b.avancer(400);
        b.tic();
    }
    assert!(!b.bloc.minuterie(), "après une minute, la surveillance s'arrête");
    let p = b.pages()["evermind"].clone();
    assert_eq!(p["etat"], "vide");
    assert_eq!(p["texte"], "Evermind n'a pas pu s'ouvrir.");
    assert!(b.f.appels().is_empty());
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

/// DIVERGENCES.md, point 9 (Jordan, 08/11/2026) : l'appli montrée qui se cache elle-même (sa croix, « Quitter » ou
/// « Réduire ») ramène Mindset à l'accueil au passage suivant, sans attendre la fin de son programme. Pas pendant une
/// mise à jour de l'appli faite par Mindset (une occupation sur elle) : l'écran « réduit près de l'horloge » reste.
#[test]
fn cachee_elle_meme_dans_sa_page_retour_a_l_accueil() {
    let mut b = Banc::nouveau("accrochage-retour-accueil");
    b.zone(1100, 760);
    b.evermind_ouverte(1001);
    b.page("evermind");
    assert_eq!(b.pages()["evermind"]["etat"], "affiche");
    b.f.changer(1001, |x| x.visible = false);
    b.avancer(400);
    let (_, e) = b.tic();
    assert_eq!(e.0, vec![Effet::Page("accueil".into())], "retour à l'accueil");
    assert_eq!(b.pages()["evermind"]["etat"], "cachee");
    assert!(!b.f.hote_de("evermind").unwrap().visible, "sa place est effacée");
    assert_eq!(b.f.appels().last().map(String::as_str), Some("liberer 1001"), "sa fenêtre lui est rendue");
    assert_eq!(
        b.faux.donnees.lignes(),
        vec!["Evermind affiché dans Mindset", "Evermind fermé ou réduit dans Mindset : retour à l'accueil"]
    );

    // Pendant une mise à jour demandée par Mindset : la page reste, avec l'écran « réduit près de l'horloge »
    let mut b = Banc::nouveau("accrochage-retour-occupee");
    b.zone(1100, 760);
    b.evermind_ouverte(1001);
    b.page("evermind");
    b.ctx.au_nom_de("installations", || {
        b.ctx.publier(partage::OCCUPATIONS, json!({ "evermind": { "texte": "Fermeture d'Evermind..." } }))
    });
    b.f.changer(1001, |x| x.visible = false);
    b.avancer(400);
    let (_, e) = b.tic();
    assert!(e.est_vide(), "{:?}", e.0);
    assert_eq!(b.pages()["evermind"]["texte"], "Evermind est réduit près de l'horloge.");

    // Sa fenêtre disparaît sans s'être cachée d'abord : l'accueil aussi (avant : l'écran « Evermind est fermé. »)
    let mut b = Banc::nouveau("accrochage-retour-fermee");
    b.zone(1100, 760);
    b.evermind_ouverte(1001);
    b.page("evermind");
    b.f.detruire(1001);
    b.avancer(400);
    let (_, e) = b.tic();
    assert_eq!(e.0, vec![Effet::Page("accueil".into())]);
    assert_eq!(b.pages()["evermind"]["etat"], "relance", "une relance serait encore raccrochée");
    assert!(!b.f.hote_de("evermind").unwrap().visible);
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

/// `ouvrir.demande` : Evermind montrée, son dossier de données (celui de la suite, elle est gérée), et une autre appli
/// de la liste, « Autre » (installée seulement si `autre_installee`), avec son propre dossier de données.
fn banc_ouvrir(nom: &str, autre_installee: bool) -> (Banc, std::path::PathBuf, std::path::PathBuf) {
    let mut b = Banc::nouveau(nom);
    let donnees_autre = b.faux.racine.join(r"Anciennes\Autre");
    let autre = Appli {
        id: "autre".into(),
        nom: "Autre".into(),
        exe: "Autre.exe".into(),
        donnees: donnees_autre.to_string_lossy().into_owned(),
        ..Default::default()
    };
    b.ctx.definir_applis(vec![evermind(), autre]);
    if autre_installee {
        b.ctx.au_nom_de("installations", || {
            b.ctx.publier(
                partage::INSTALLATIONS,
                json!({
                    "evermind": { "dossier": r"C:\Essai\Programmes\evermind", "gere": true, "version": "1.3.0" },
                    "autre": { "dossier": r"C:\Essai\Programmes\autre", "gere": true, "version": "1.0.0" },
                }),
            )
        });
    }
    let donnees = b.ctx.dossiers.donnees_suite.join("Evermind");
    std::fs::create_dir_all(&donnees).unwrap();
    std::fs::create_dir_all(&donnees_autre).unwrap();
    b.zone(1100, 760);
    b.evermind_ouverte(1001);
    b.page("evermind");
    assert_eq!(b.pages()["evermind"]["etat"], "affiche");
    (b, donnees.join(OUVRIR_DEMANDE), donnees_autre.join(OUVRIR_DEMANDE))
}

fn ouvrir_autre() -> Vec<Effet> {
    vec![signaux::ouvrir_appli("autre", true), Effet::Page("autre".into())]
}

/// Le bouton « Ouvrir Nevermind » de Mindcare : un id valide ouvre l'autre appli (sa page, puis elle est lancée),
/// le fichier est supprimé, une ligne au journal.
#[test]
fn ouvrir_demande_valide_ouvre_l_autre_appli() {
    let (mut b, f, _) = banc_ouvrir("accrochage-ouvrir-demande", true);
    std::fs::write(&f, "autre\r\n").unwrap();
    b.avancer(400);
    let (_, e) = b.tic();
    assert_eq!(e.0, ouvrir_autre());
    assert!(!f.exists(), "supprimé après lecture");
    assert!(b.faux.donnees.lignes().contains(&"Evermind demande d'ouvrir Autre".to_string()));
    // (sa page : elle est lancée, comme après un clic sur sa carte)
    let e = b.page("autre");
    assert_eq!(
        e.0,
        vec![Effet::Signal { nom: "lancer-appli".into(), donnees: json!({ "id": "autre", "demarrage": false }) }]
    );
    // (lu une seule fois : rien au passage suivant)
    b.page("evermind");
    b.avancer(400);
    let (_, e) = b.tic();
    assert!(!e.0.iter().any(|x| matches!(x, Effet::Page(_))), "{:?}", e.0);

    // Juste sous la limite (63 octets, espaces autour) : accepté
    let (mut b, f, _) = banc_ouvrir("accrochage-ouvrir-63", true);
    std::fs::write(&f, format!("autre{}", " ".repeat(58))).unwrap();
    assert_eq!(std::fs::metadata(&f).unwrap().len(), 63);
    b.avancer(400);
    let (_, e) = b.tic();
    assert_eq!(e.0, ouvrir_autre());
}

/// L'autre appli pas installée : sa page dit qu'elle ne l'est pas, rien n'est lancé ni installé.
#[test]
fn ouvrir_demande_appli_pas_installee_montre_sa_page() {
    let (mut b, f, _) = banc_ouvrir("accrochage-ouvrir-pas-installee", false);
    std::fs::write(&f, "autre").unwrap();
    b.avancer(400);
    let (_, e) = b.tic();
    assert_eq!(e.0, ouvrir_autre());
    let e = b.page("autre");
    assert!(e.est_vide(), "ni lancement ni installation : {:?}", e.0);
    assert_eq!(b.pages()["autre"]["titre"], "Autre n'est pas installé.");
    assert_eq!(b.pages()["autre"]["texte"], "Installe-le depuis l'accueil.");
}

/// Contenu refusé (id inconnu, elle-même, mal formé, trop gros, vide) : supprimé, ignoré, une ligne au journal.
#[test]
fn ouvrir_demande_refusee_supprimee_et_ignoree() {
    let cas: [(&str, Vec<u8>); 7] = [
        ("inconnue", b"inconnue".to_vec()),
        ("soi-meme", b"evermind".to_vec()),
        ("majuscules", b"Autre".to_vec()),
        ("chemin", br"..\autre".to_vec()),
        ("trop-gros", format!("autre{}", " ".repeat(59)).into_bytes()),
        ("vide", Vec::new()),
        ("deux-lignes", b"autre\nautre".to_vec()),
    ];
    for (nom, contenu) in cas {
        let (mut b, f, _) = banc_ouvrir(&format!("accrochage-ouvrir-{nom}"), true);
        std::fs::write(&f, &contenu).unwrap();
        b.avancer(400);
        let (_, e) = b.tic();
        assert!(e.est_vide(), "{nom} : {:?}", e.0);
        assert!(!f.exists(), "{nom} : supprimé quand même");
        assert!(
            b.faux.donnees.lignes().contains(&"Demande d'ouverture de Evermind illisible, ignorée".to_string()),
            "{nom} : {:?}",
            b.faux.donnees.lignes()
        );
    }
}

/// Seulement l'appli affichée à l'écran : Mindset sur l'accueil, caché ou réduit, ou la demande d'une autre appli
/// que celle montrée, le fichier est laissé tel quel, rien ne s'ouvre.
#[test]
fn ouvrir_demande_ignoree_hors_de_l_appli_montree() {
    // La demande d'une autre appli que celle montrée
    let (mut b, f, f_autre) = banc_ouvrir("accrochage-ouvrir-autre-appli", true);
    std::fs::write(&f_autre, "evermind").unwrap();
    b.avancer(400);
    let (_, e) = b.tic();
    assert!(e.est_vide(), "{:?}", e.0);
    assert!(f_autre.exists(), "pas l'appli montrée : laissé");
    assert!(!f.exists());

    // Mindset caché près de l'horloge, puis réduit
    for (nom, visible, reduite) in [("cache", false, false), ("reduit", true, true)] {
        let (mut b, f, _) = banc_ouvrir(&format!("accrochage-ouvrir-{nom}"), true);
        std::fs::write(&f, "autre").unwrap();
        let mut v = b.ctx.vue();
        v.visible = visible;
        v.reduite = reduite;
        b.ctx.definir_vue(v);
        b.avancer(400);
        let (_, e) = b.tic();
        assert!(e.est_vide(), "{nom} : {:?}", e.0);
        assert!(f.exists(), "{nom} : laissé");
    }

    // Mindset revenu sur l'accueil (Evermind toujours accrochée, sa page n'est plus montrée)
    let (mut b, f, _) = banc_ouvrir("accrochage-ouvrir-accueil", true);
    b.page("accueil");
    std::fs::write(&f, "autre").unwrap();
    b.avancer(400);
    let (_, e) = b.tic();
    assert!(!e.0.iter().any(|x| matches!(x, Effet::Page(_))), "{:?}", e.0);
    assert!(f.exists(), "accueil : laissé");
}

#[test]
fn ouvrir_demande_id_valable() {
    assert!(id_demande("nevermind") && id_demande("evermind-mobile") && id_demande("a1"));
    assert!(!id_demande("") && !id_demande("Nevermind") && !id_demande("a b") && !id_demande("é"));
    assert!(id_demande(&"a".repeat(30)) && !id_demande(&"a".repeat(31)));
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
