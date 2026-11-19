//! Les tests du bloc (avec le contexte d'essai du noyau : rien ne touche le vrai PC).

use super::*;
use mindset_noyau::essai;
use std::sync::Arc;

fn appli(id: &str, nom: &str) -> mindset_noyau::Appli {
    mindset_noyau::Appli { id: id.into(), nom: nom.into(), couleur: "#00E5FF".into(), ..Default::default() }
}

fn bloc() -> (Parametres, Arc<Fausse>) {
    let f = Arc::new(Fausse::default());
    (Parametres::avec_plateforme(f.clone(), true), f)
}

#[test]
fn nom_du_bloc() {
    // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
    assert_eq!(BlocParametres::default().nom(), "parametres");
}

#[test]
fn demarrage_publie_le_theme() {
    let (ctx, f) = essai::contexte("parametres-demarrage");
    ctx.donnees().ecrire_theme_suite("rubis");
    let (mut b, _) = bloc();
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    assert!(e.0.contains(&Effet::BarreDeTitre("#0A0A0D".into())));
    assert!(e.0.contains(&Effet::DossierPack(None)));
    let t = ctx.lu(partage::THEME).unwrap();
    assert_eq!(t["id"], "rubis");
    assert_eq!(partage::couleur(&ctx, "#00e5ff"), "#FF3B3B");
    assert_eq!(ctx.lu(partage::ONGLET_PARAMETRES), Some(json!("general")));
    let etat = b.etat(&ctx);
    assert_eq!(etat["parametres"]["apparence"]["themes"].as_array().unwrap().len(), 5);
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn choisir_un_theme_relance() {
    let (ctx, f) = essai::contexte("parametres-choix");
    let (mut b, _) = bloc();
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    let mut e = Effets::default();
    assert!(b.action(&ctx, "parametres:reglage", &json!({ "quoi": "theme", "valeur": "terminal" }), &mut e));
    assert!(e.0.contains(&Effet::Relancer));
    assert_eq!(ctx.donnees().theme_suite(), "terminal");
    // Un thème inconnu : rien
    let mut e = Effets::default();
    b.action(&ctx, "parametres:reglage", &json!({ "quoi": "theme", "valeur": "inconnu" }), &mut e);
    assert!(!e.0.contains(&Effet::Relancer));
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn en_test_pas_de_relance() {
    let (ctx, f) = essai::contexte("parametres-choix-test");
    let mut b = Parametres::avec_plateforme(Arc::new(Fausse::default()), false);
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    let mut e = Effets::default();
    b.action(&ctx, "parametres:reglage", &json!({ "quoi": "theme", "valeur": "arcade" }), &mut e);
    assert!(!e.0.contains(&Effet::Relancer));
    assert_eq!(b.etat(&ctx)["parametres"]["apparence"]["info"], "Thème « arcade » choisi (test : pas de relance).");
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn page_demandee() {
    let (ctx, f) = essai::contexte("parametres-page");
    ctx.definir_applis(vec![appli("evermind", "Evermind")]);
    let (mut b, _) = bloc();
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    std::fs::create_dir_all(&ctx.dossiers.local_mindset).unwrap();
    for (texte, attendu) in [
        ("parametres:son\r\n", Some(Effet::Page("parametres".into()))),
        ("menu", Some(Effet::Page("accueil".into()))),
        ("appli:evermind", Some(signaux::ouvrir_appli("evermind", true))),
        ("appli:inconnue", None),
        ("parametres:rien", None),
    ] {
        std::fs::write(ctx.dossiers.page_demandee(), texte).unwrap();
        let mut e = Effets::default();
        ctx.au_nom_de("parametres", || b.signal(&ctx, signaux::AFFICHER_DEMANDE, &json!({}), &mut e));
        assert!(!ctx.dossiers.page_demandee().exists(), "le fichier est retiré");
        match attendu {
            Some(a) => assert!(e.0.contains(&a), "{texte} : {:?}", e.0),
            None => assert!(e.0.is_empty(), "{texte} : {:?}", e.0),
        }
    }
    assert_eq!(b.onglet, "son");
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn surveiller_le_theme() {
    let (ctx, f) = essai::contexte("parametres-surveiller");
    let (mut b, _) = bloc();
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    ctx.donnees().ecrire_theme_suite("arcade");
    let mut e = Effets::default();
    b.surveiller_theme(&ctx, &mut e);
    assert!(e.0.contains(&Effet::Relancer));
    // Déjà relancé pour ce thème il y a moins d'une minute : pas de nouvelle relance
    let mut e = Effets::default();
    b.surveiller_theme(&ctx, &mut e);
    assert!(e.0.is_empty());
    assert!(f.donnees.lignes().iter().any(|l| l.contains("déjà relancé")));
    ctx.avancer(Duration::from_secs(61));
    let mut e = Effets::default();
    b.surveiller_theme(&ctx, &mut e);
    assert!(e.0.contains(&Effet::Relancer));
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn conso_seulement_a_l_ecran() {
    let (ctx, f) = essai::contexte("parametres-conso");
    let (mut b, faux) = bloc();
    *faux.parties.lock().unwrap() = vec![
        plateforme::Partie { nom: "Mindset".into(), nombre: 2, memoire: 300 * 1_048_576, processeur: 1.25 },
        plateforme::Partie { nom: conso::NOM_WEBVIEW.into(), nombre: 0, memoire: 0, processeur: 0.0 },
    ];
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    let mut e = Effets::default();
    b.tic(&ctx, &mut e);
    assert!(faux.mesures().is_empty(), "rien tant que l'onglet n'est pas à l'écran");
    ctx.definir_vue(mindset_noyau::Vue { visible: true, reduite: false, page: "parametres".into() });
    let mut e = Effets::default();
    b.action(&ctx, "parametres:onglet", &json!("conso"), &mut e);
    let Some(Effet::Tache(t)) = e.0.into_iter().find(|x| matches!(x, Effet::Tache(_))) else { panic!("une mesure") };
    let r = t.lancer();
    let mut e = Effets::default();
    b.tache_finie(&ctx, "conso", r, &mut e);
    let c = b.etat(&ctx)["parametres"]["conso"].clone();
    assert_eq!(c["memoire"], "300 Mo");
    assert_eq!(c["processeur"], "...");
    assert_eq!(c["lignes"][0]["detail"], "le portail, 2 programmes");
    assert_eq!(c["lignes"].as_array().unwrap().len(), 1);
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn bandeau_admin() {
    let (ctx, f) = essai::contexte("parametres-admin");
    let (mut b, faux) = bloc();
    ctx.au_nom_de("lui-meme", || ctx.publier(partage::MINDSET, json!({ "installe": true })));
    ctx.au_nom_de("installations", || ctx.publier(partage::ADMIN, json!({ "tache": "absente" })));
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    let mut e = Effets::default();
    b.tic(&ctx, &mut e);
    assert_eq!(b.etat(&ctx)["admin_bandeau"]["visible"], true);
    let mut e = Effets::default();
    b.action(&ctx, "parametres:activer-admin", &Value::Null, &mut e);
    let Some(Effet::Signal { donnees, .. }) = e.0.first() else { panic!() };
    assert_eq!(donnees["action"], "taches");
    assert_eq!(donnees["parametres"]["Sid"], "S-1-5-21-1-2-3-1001");
    let id = donnees["id"].as_str().unwrap().to_string();
    assert_eq!(id.len(), 32);
    assert_eq!(b.etat(&ctx)["admin_bandeau"]["bouton_actif"], false);
    let mut e = Effets::default();
    b.signal(&ctx, signaux::ADMIN_FINI, &json!({ "id": id, "ok": true, "message": "" }), &mut e);
    assert_eq!(b.etat(&ctx)["admin_bandeau"]["visible"], false);
    assert!(*faux.run_retire.lock().unwrap());
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn la_page_suit_les_regles_de_la_suite() {
    // regles-tauri.md : rien d'autre qu'ipc.js ne parle à Rust ; textes sans tiret long ni demi-cadratin
    let dossier = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("page");
    for f in ["parametres.js", "parametres.css"] {
        let t = std::fs::read_to_string(dossier.join(f)).unwrap();
        for interdit in
            ["__TAURI", "invoke", "ipc.localhost", "chrome.webview", "\u{2014}", "\u{2013}", "http://", "https://"]
        {
            assert!(!t.contains(interdit), "{f} contient « {interdit} »");
        }
    }
    // (et le Rust du bloc non plus : aucun tiret long dans les textes ni les commentaires)
    for f in std::fs::read_dir(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src")).unwrap().flatten() {
        if f.path().is_file() {
            let t = std::fs::read_to_string(f.path()).unwrap();
            assert!(!t.contains('\u{2014}') && !t.contains('\u{2013}'), "{}", f.path().display());
        }
    }
}

#[test]
fn fermeture_changee_par_l_horloge() {
    // Le bloc « horloge » écrit Fermeture (« Ne plus me demander ») puis envoie reglage-change : le panneau suit
    let (ctx, f) = essai::contexte("parametres-fermeture");
    let (mut b, _) = bloc();
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    assert_eq!(b.etat(&ctx)["parametres"]["general"]["fermeture"], "demander");
    ctx.ecrire_reglage("Fermeture", json!("reduire"));
    let mut e = Effets::default();
    b.signal(&ctx, signaux::REGLAGE_CHANGE, &json!({ "nom": "Fermeture", "valeur": "reduire" }), &mut e);
    assert_eq!(b.etat(&ctx)["parametres"]["general"]["fermeture"], "reduire");
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn bandeau_admin_ancienne_tache() {
    // L'ancienne tâche est remplacée par le bloc « installations » (rien n'est demandé ici) : le bandeau ne vient que
    // si le remplacement a échoué (admin.remplacement)
    let (ctx, f) = essai::contexte("parametres-admin-ancienne");
    let (mut b, _) = bloc();
    ctx.au_nom_de("lui-meme", || ctx.publier(partage::MINDSET, json!({ "installe": true })));
    let admin = |t: &str, r: Value| {
        ctx.au_nom_de("installations", || ctx.publier(partage::ADMIN, json!({ "tache": t, "remplacement": r })))
    };
    admin("ancienne", Value::Null);
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    let mut e = Effets::default();
    b.tic(&ctx, &mut e);
    assert!(!e.0.iter().any(|x| matches!(x, Effet::Signal { nom, .. } if nom == signaux::ADMIN_DEMANDE)));
    assert_eq!(b.etat(&ctx)["admin_bandeau"]["visible"], false);
    admin("ancienne", json!("en_cours"));
    assert_eq!(b.etat(&ctx)["admin_bandeau"]["visible"], false);
    admin("ancienne", json!("echec"));
    assert_eq!(b.etat(&ctx)["admin_bandeau"]["visible"], true);
    admin("systeme", json!("ok"));
    assert_eq!(b.etat(&ctx)["admin_bandeau"]["visible"], false);
    let _ = std::fs::remove_dir_all(&f.racine);
}

// ---------------------------------------------------------------------------------------------------------------
// Applis privées (Mindset 3.1) : la clé GitHub
// ---------------------------------------------------------------------------------------------------------------

/// Les travaux de fond demandés, faits tout de suite (rend les effets qui suivent).
fn faire_taches(b: &mut Parametres, ctx: &Contexte, e: Effets) -> Effets {
    let mut suite = Effets::default();
    for x in e.0 {
        if let Effet::Tache(t) = x {
            let id = t.id.clone();
            let r = t.lancer();
            ctx.au_nom_de("parametres", || b.tache_finie(ctx, &id, r, &mut suite));
        }
    }
    suite
}

fn reglage_cle(b: &mut Parametres, ctx: &Contexte, quoi: &str, valeur: Value) -> Effets {
    let mut e = Effets::default();
    assert!(b.action(ctx, "parametres:reglage", &json!({ "quoi": quoi, "valeur": valeur }), &mut e));
    e
}

#[cfg(windows)]
#[test]
fn applis_privees_essayer_garder_retirer_sans_jamais_ecrire_la_cle() {
    let (ctx, f) = essai::contexte("parametres-cle");
    let (mut b, _) = bloc();
    let mut e = Effets::default();
    ctx.au_nom_de("parametres", || b.demarrer(&ctx, &mut e));
    let prive = |b: &Parametres| b.etat_parametres(&ctx)["maj"]["prive"].clone();
    // Sans appli privée dans la liste : la section ne se montre pas
    assert_eq!(prive(&b)["visible"], false);
    ctx.au_nom_de("liste", || {
        ctx.publier(
            partage::LISTE,
            json!({ "source": "apps.json", "numero": 3, "privees": [{ "id": "jobmind", "nom": "Jobmind", "depot": "JordanJacquot/Jobmind" }] }),
        )
    });
    let p = prive(&b);
    assert_eq!((p["visible"].clone(), p["cle"].clone()), (json!(true), json!(false)));
    assert_eq!(p["applis"], json!([]), "sans clé, la section ne nomme aucune appli privée");
    assert!(!p.to_string().contains("Jobmind"));
    assert_eq!(p["etapes"].as_array().unwrap().len(), 6);
    // « Ouvrir la page de GitHub »
    let e = reglage_cle(&mut b, &ctx, "clePage", Value::Null);
    assert!(e.0.contains(&Effet::OuvrirAdresse("https://github.com/settings/personal-access-tokens/new".into())));
    // Pas une clé à grain fin : refusée tout de suite, rien demandé à GitHub
    reglage_cle(&mut b, &ctx, "cleEssayer", json!("ghp_abcdefghijklmnopqrstuvwxyz0123456789"));
    assert!(prive(&b)["info"].as_str().unwrap().starts_with("Ce n'est pas une clé GitHub à grain fin"));
    assert!(f.reseau.demandes().is_empty());
    // Une clé que GitHub refuse : pas gardée
    let api = "https://api.github.com/repos/JordanJacquot/Jobmind";
    let mauvaise = format!("github_pat_{}", "Mauvaise_".repeat(6));
    f.reseau.repondre(api, Ok(mindset_noyau::reseau::ReponseHttp::code(404)));
    let e = reglage_cle(&mut b, &ctx, "cleEssayer", json!(mauvaise));
    assert_eq!(prive(&b)["en_cours"], true);
    faire_taches(&mut b, &ctx, e);
    let p = prive(&b);
    assert_eq!((p["cle"].clone(), p["ton"].clone()), (json!(false), json!("urgent")));
    assert!(p["info"].as_str().unwrap().starts_with("Cette clé n'ouvre aucune appli privée"));
    assert!(!mindset_noyau::cle_github::chemin(&ctx.dossiers).exists());
    // La bonne clé : gardée chiffrée, la date où elle expire notée, Jobmind nommée, « Relancer Mindset » proposé
    let bonne = format!("github_pat_{}", "Bonne_Cle_".repeat(6));
    let mut ok = mindset_noyau::reseau::ReponseHttp::ok("{}");
    ok.entetes.push(("github-authentication-token-expiration".into(), "2026-11-12 10:00:00 UTC".into()));
    f.reseau.repondre(api, Ok(ok));
    f.reseau.repondre(
        &format!("{api}/releases/latest"),
        Ok(mindset_noyau::reseau::ReponseHttp::ok(r#"{"tag_name":"v0.3.0"}"#)),
    );
    let e = reglage_cle(&mut b, &ctx, "cleEssayer", json!(format!("  {bonne}\n")));
    faire_taches(&mut b, &ctx, e);
    let p = prive(&b);
    assert_eq!(p["cle"], true);
    assert_eq!(p["ton"], "ok");
    assert_eq!(
        p["info"],
        "Ta clé marche : elle ouvre Jobmind (version 0.3.0). Elle est gardée chiffrée sur ce PC. Relance Mindset pour la voir dans l'accueil."
    );
    assert_eq!(p["relancer"], true);
    assert_eq!(p["expire"], "12/11/2026");
    assert_eq!(
        p["rappel"],
        "Ta clé GitHub expire dans 4 jours (le 12/11/2026) : refais-en une avant, avec le guide juste en dessous."
    );
    assert_eq!(mindset_noyau::cle_github::lire(&ctx.dossiers).map(|j| j.secret().to_string()), Some(bonne.clone()));
    // Toutes les questions : vers l'API, avec la clé essayée
    for d in f.reseau.demandes() {
        assert!(d.adresse.starts_with("https://api.github.com/repos/JordanJacquot/Jobmind"));
        assert!(d.jeton.is_some());
    }
    // « Relancer Mindset »
    let e = reglage_cle(&mut b, &ctx, "cleRelancer", Value::Null);
    assert!(e.0.contains(&Effet::Relancer));
    // La clé n'est nulle part en clair : ni dans l'état de la page, ni au journal, ni dans un fichier
    let tout = b.etat(&ctx);
    for s in [&bonne, &mauvaise] {
        let morceau = &s[11..30];
        assert!(!serde_json::to_string(&tout).unwrap().contains(morceau));
        assert!(!f.donnees.lignes().iter().any(|l| l.contains(morceau)), "journal");
        let utf16: Vec<u8> = s.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut pile = vec![f.racine.clone()];
        while let Some(d) = pile.pop() {
            for x in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                let p = x.path();
                if p.is_dir() {
                    pile.push(p);
                } else {
                    let o = std::fs::read(&p).unwrap_or_default();
                    for a in [morceau.as_bytes(), &utf16[22..60]] {
                        assert!(!o.windows(a.len()).any(|w| w == a), "clé en clair dans {}", p.display());
                    }
                }
            }
        }
        // (ni dans les réglages, gardés en mémoire par le faux disque)
        assert!(!format!("{:?}", ctx.reglage("CleGithubExpire")).contains(morceau));
    }
    // « Retirer la clé »
    reglage_cle(&mut b, &ctx, "cleRetirer", Value::Null);
    let p = prive(&b);
    assert_eq!((p["cle"].clone(), p["expire"].clone(), p["rappel"].clone()), (json!(false), json!(""), json!("")));
    assert_eq!(p["info"], "Clé retirée de ce PC.");
    assert!(!mindset_noyau::cle_github::chemin(&ctx.dossiers).exists());
    let _ = std::fs::remove_dir_all(&f.racine);
}
