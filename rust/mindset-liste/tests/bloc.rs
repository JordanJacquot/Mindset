//! Le bloc « liste » dans un contexte d'essai (faux disque, faux GitHub, faux Windows) : la liste donnée au démarrage,
//! le relevé des applis ouvertes, la recherche de la liste en ligne (6 heures, réessai dans une heure, adresses et
//! limites), et `Get-ProcessusDonneesAppli`. Les octets d'une liste signée viennent des juges (clé de TEST).

use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};

use mindset_liste::{BlocListe, URL_LISTE_EN_LIGNE, processus_donnees_appli};
use mindset_noyau::contexte::{Contexte, Vue};
use mindset_noyau::essai::{Faux, contexte};
use mindset_noyau::reseau::ReponseHttp;
use mindset_noyau::{Bloc, Effet, Effets, partage, signaux};

fn juge(nom: &str) -> Value {
    let f = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("juges").join(nom);
    serde_json::from_str(std::fs::read_to_string(f).unwrap().trim_start_matches('\u{FEFF}')).unwrap()
}

fn base64(t: &str) -> Vec<u8> {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let (mut sortie, mut acc, mut n) = (Vec::new(), 0u32, 0);
    for c in t.bytes().filter(|c| *c != b'=') {
        acc = (acc << 6) | A.iter().position(|x| *x == c).unwrap() as u32;
        n += 6;
        if n >= 8 {
            n -= 8;
            sortie.push((acc >> n) as u8);
            acc &= (1 << n) - 1;
        }
    }
    sortie
}

/// Un cas des juges (listes.json) par son nom : (clé publique, cas).
fn cas(nom: &str) -> (String, Value) {
    let j = juge("listes.json");
    let c = j["cas"].as_array().unwrap().iter().find(|c| c["nom"] == nom).unwrap_or_else(|| panic!("{nom}")).clone();
    (j["cle_publique"].as_str().unwrap().to_string(), c)
}

fn octets(v: &Value) -> Vec<u8> {
    base64(v["b64"].as_str().unwrap())
}

/// Un Mindset d'essai : le vrai apps.json livré du dépôt, son numéro 3, la clé publique de test des juges.
fn mindset(nom: &str) -> (Contexte, Faux, String) {
    let (ctx, faux) = contexte(&format!("liste-bloc-{nom}"));
    let (cle, _) = cas("bonne liste");
    let f = &ctx.dossiers.fichiers;
    std::fs::create_dir_all(f.join("cles-publiques")).unwrap();
    std::fs::write(f.join(r"cles-publiques\test.xml"), &cle).unwrap();
    let livre = Path::new(env!("CARGO_MANIFEST_DIR")).join(r"..\..\Mindset\fichiers\apps.json");
    std::fs::copy(livre, f.join("apps.json")).unwrap();
    std::fs::write(f.join("apps-liste.txt"), "3\r\n").unwrap();
    (ctx, faux, cle)
}

fn demarrer(ctx: &Contexte, bloc: &mut BlocListe) -> Effets {
    let mut e = Effets::default();
    ctx.au_nom_de("liste", || bloc.demarrer(ctx, &mut e));
    e
}

fn signal(ctx: &Contexte, bloc: &mut BlocListe, nom: &str) -> Effets {
    let mut e = Effets::default();
    ctx.au_nom_de("liste", || bloc.signal(ctx, nom, &json!({}), &mut e));
    e
}

/// Le travail de fond demandé (il y en a au plus un).
fn tache(e: Effets) -> Option<mindset_noyau::tache::Tache> {
    e.0.into_iter().find_map(|x| match x {
        Effet::Tache(t) => Some(t),
        _ => None,
    })
}

fn finir(ctx: &Contexte, bloc: &mut BlocListe, t: mindset_noyau::tache::Tache) {
    let id = t.id.clone();
    let r = t.lancer();
    let mut e = Effets::default();
    ctx.au_nom_de("liste", || bloc.tache_finie(ctx, &id, r, &mut e));
}

fn nettoyer(f: &Faux) {
    let _ = std::fs::remove_dir_all(&f.racine);
}

#[test]
fn au_demarrage_la_liste_livree_et_d_ou_elle_vient() {
    let (ctx, faux, _) = mindset("livree");
    let mut bloc = BlocListe;
    assert!(demarrer(&ctx, &mut bloc).est_vide());
    let ids: Vec<String> = ctx.applis().iter().map(|a| a.id.clone()).collect();
    assert_eq!(ids, ["nevermind", "evermind", "mindcare"]);
    assert_eq!(ctx.lu(partage::LISTE), Some(json!({ "source": "apps.json", "numero": 3 })));
    // (en essai, %LOCALAPPDATA% est le dossier d'essai : jamais les vraies données d'une appli)
    let e = ctx.appli("evermind").unwrap();
    assert!(Path::new(&e.donnees).starts_with(&faux.racine), "{}", e.donnees);
    assert_eq!(ctx.lu(partage::OUVERTES), Some(json!({ "nevermind": false, "evermind": false, "mindcare": false })));
    assert!(faux.donnees.lignes().is_empty(), "{:?}", faux.donnees.lignes());
    nettoyer(&faux);
}

#[test]
fn au_demarrage_la_liste_gardee_si_elle_est_bonne() {
    let (ctx, faux, _) = mindset("gardee");
    let (_, c) = cas("applis : liste gardée bonne");
    std::fs::create_dir_all(&ctx.dossiers.donnees).unwrap();
    std::fs::write(ctx.dossiers.donnees.join("apps-en-ligne.json"), octets(&c["gardee"])).unwrap();
    std::fs::write(ctx.dossiers.donnees.join("apps-en-ligne.json.sig"), octets(&c["gardee_sig"])).unwrap();
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    assert_eq!(ctx.applis().len(), 4);
    assert!(ctx.appli("nouvelle").is_some_and(|a| a.genre == "rust" && a.nom == "Nouvelle"));
    assert_eq!(ctx.lu(partage::LISTE), Some(json!({ "source": "en-ligne", "numero": 4 })));
    assert_eq!(faux.donnees.lignes(), ["Liste des applis : liste en ligne n° 4 (gardée, vérifiée)"]);
    nettoyer(&faux);

    // abîmée sur le disque : la liste livrée, et le refus noté
    let (ctx, faux, _) = mindset("gardee-abimee");
    std::fs::create_dir_all(&ctx.dossiers.donnees).unwrap();
    let mut j = octets(&c["gardee"]);
    j[10] ^= 1;
    std::fs::write(ctx.dossiers.donnees.join("apps-en-ligne.json"), j).unwrap();
    std::fs::write(ctx.dossiers.donnees.join("apps-en-ligne.json.sig"), octets(&c["gardee_sig"])).unwrap();
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    assert_eq!(ctx.applis().len(), 3);
    assert_eq!(ctx.lu(partage::LISTE), Some(json!({ "source": "apps.json", "numero": 3 })));
    assert_eq!(
        faux.donnees.lignes(),
        ["Liste des applis gardée refusée (signature invalide) : celle livrée avec Mindset est prise"]
    );
    nettoyer(&faux);
}

#[test]
fn apps_json_illisible_aucune_appli() {
    let (ctx, faux, _) = mindset("illisible");
    std::fs::write(ctx.dossiers.fichiers.join("apps.json"), "[ { \"id\": ").unwrap();
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    assert!(ctx.applis().is_empty());
    assert_eq!(ctx.lu(partage::LISTE), Some(json!({ "source": "apps.json", "numero": null })));
    assert!(faux.donnees.lignes()[0].starts_with("apps.json illisible : "));
    nettoyer(&faux);
}

#[test]
fn releve_des_applis_ouvertes() {
    let (ctx, faux, _) = mindset("ouvertes");
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    faux.systeme.poser_verrou(r"Local\Evermind-Instance", true);
    let mut e = Effets::default();
    // Mindset caché : toutes les 30 s
    assert_eq!(ctx.au_nom_de("liste", || bloc.tic(&ctx, &mut e)), Some(Duration::from_secs(30)));
    assert_eq!(ctx.lu(partage::OUVERTES).unwrap()["evermind"], json!(true));
    // montré : toutes les 1,5 s ; l'ancien verrou de Nevermind compte aussi
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "accueil".into() });
    faux.systeme.poser_verrou(r"Local\OptiGame-Instance", true);
    faux.systeme.poser_verrou(r"Local\Evermind-Instance", false);
    assert_eq!(ctx.au_nom_de("liste", || bloc.tic(&ctx, &mut e)), Some(Duration::from_millis(1500)));
    assert_eq!(ctx.lu(partage::OUVERTES), Some(json!({ "nevermind": true, "evermind": false, "mindcare": false })));
    // réduite : 30 s
    ctx.definir_vue(Vue { visible: true, reduite: true, page: "accueil".into() });
    assert_eq!(ctx.au_nom_de("liste", || bloc.tic(&ctx, &mut e)), Some(Duration::from_secs(30)));
    assert!(e.est_vide());
    nettoyer(&faux);
}

#[test]
fn liste_en_ligne_cherchee_au_plus_toutes_les_six_heures() {
    let (ctx, faux, _) = mindset("en-ligne");
    let (_, c) = cas("recevoir : bonne liste");
    let (json6, sig6) = (octets(&c["json"]), octets(&c["sig"]));
    faux.reseau.repondre(URL_LISTE_EN_LIGNE, Ok(ReponseHttp::ok(json6.clone())));
    faux.reseau.repondre(&format!("{URL_LISTE_EN_LIGNE}.sig"), Ok(ReponseHttp::ok(sig6.clone())));
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    // un autre signal ne fait rien
    assert!(signal(&ctx, &mut bloc, signaux::ACTUALISER).est_vide());
    let t = tache(signal(&ctx, &mut bloc, signaux::VERIFIER_LISTE)).expect("téléchargement demandé");
    assert_eq!(t.id, mindset_liste::TACHE);
    finir(&ctx, &mut bloc, t);
    // les adresses (sans l'API de GitHub), les limites de taille et de temps
    let d = faux.reseau.demandes();
    assert_eq!(d.len(), 2);
    assert_eq!(
        d[0].adresse,
        "https://github.com/JordanJacquot/Mindset/releases/download/liste-applis/apps-en-ligne.json"
    );
    assert_eq!((d[0].max_octets, d[0].delai), (256 * 1024, Duration::from_secs(15)));
    assert_eq!(d[1].adresse, format!("{URL_LISTE_EN_LIGNE}.sig"));
    assert_eq!((d[1].max_octets, d[1].delai), (64 * 1024, Duration::from_secs(15)));
    // gardée (liste et signature), notée, prise au prochain démarrage seulement
    let gardee = ctx.dossiers.donnees.join("apps-en-ligne.json");
    assert_eq!(std::fs::read(&gardee).unwrap(), json6);
    assert_eq!(std::fs::read(ctx.dossiers.donnees.join("apps-en-ligne.json.sig")).unwrap(), sig6);
    assert_eq!(
        faux.donnees.lignes(),
        ["Liste des applis en ligne n° 6 gardée (4 applis) : elle sera prise au prochain démarrage de Mindset"]
    );
    assert_eq!(ctx.applis().len(), 3, "la liste de ce démarrage ne change pas");
    // pas deux fois en 6 heures
    ctx.avancer(Duration::from_secs(6 * 3600 - 1));
    assert!(tache(signal(&ctx, &mut bloc, signaux::VERIFIER_LISTE)).is_none());
    ctx.avancer(Duration::from_secs(1));
    let t = tache(signal(&ctx, &mut bloc, signaux::VERIFIER_LISTE)).expect("6 heures après");
    // (la même liste : rien à dire)
    finir(&ctx, &mut bloc, t);
    assert_eq!(faux.donnees.lignes().len(), 1);
    // au démarrage suivant : la nouvelle liste
    let mut neuf = BlocListe;
    demarrer(&ctx, &mut neuf);
    assert_eq!(ctx.lu(partage::LISTE), Some(json!({ "source": "en-ligne", "numero": 6 })));
    assert_eq!(ctx.applis().len(), 4);
    nettoyer(&faux);
}

#[test]
fn pas_telechargee_reessai_dans_une_heure() {
    let (ctx, faux, _) = mindset("reessai");
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    // (aucune réponse prévue : le faux GitHub répond par une erreur)
    let t = tache(signal(&ctx, &mut bloc, signaux::VERIFIER_LISTE)).unwrap();
    ctx.avancer(Duration::from_secs(10));
    finir(&ctx, &mut bloc, t);
    let l = faux.donnees.lignes();
    assert!(l[0].starts_with("Liste des applis en ligne : pas téléchargée (pas de réponse prévue"), "{l:?}");
    assert!(!ctx.dossiers.donnees.join("apps-en-ligne.json").exists());
    ctx.avancer(Duration::from_secs(3599));
    assert!(tache(signal(&ctx, &mut bloc, signaux::VERIFIER_LISTE)).is_none());
    ctx.avancer(Duration::from_secs(1));
    // la signature introuvable (404) : pas téléchargée non plus
    let (_, c) = cas("recevoir : bonne liste");
    faux.reseau.repondre(URL_LISTE_EN_LIGNE, Ok(ReponseHttp::ok(octets(&c["json"]))));
    faux.reseau.repondre(&format!("{URL_LISTE_EN_LIGNE}.sig"), Ok(ReponseHttp::code(404)));
    let t = tache(signal(&ctx, &mut bloc, signaux::VERIFIER_LISTE)).expect("une heure après");
    finir(&ctx, &mut bloc, t);
    let l = faux.donnees.lignes();
    assert!(l[1].starts_with("Liste des applis en ligne : pas téléchargée (le serveur a répondu 404"), "{l:?}");
    assert!(!ctx.dossiers.donnees.join("apps-en-ligne.json").exists());
    nettoyer(&faux);
}

#[test]
fn liste_telechargee_refusee_rien_ne_change() {
    let (ctx, faux, _) = mindset("refusee");
    let (_, c) = cas("recevoir : mal signée");
    faux.reseau.repondre(URL_LISTE_EN_LIGNE, Ok(ReponseHttp::ok(octets(&c["json"]))));
    faux.reseau.repondre(&format!("{URL_LISTE_EN_LIGNE}.sig"), Ok(ReponseHttp::ok(octets(&c["sig"]))));
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    let t = tache(signal(&ctx, &mut bloc, signaux::VERIFIER_LISTE)).unwrap();
    finir(&ctx, &mut bloc, t);
    assert_eq!(
        faux.donnees.lignes(),
        ["Liste des applis en ligne refusée : signature invalide (on garde celle qu'on avait)"]
    );
    assert!(!ctx.dossiers.donnees.join("apps-en-ligne.json").exists());
    assert!(!ctx.dossiers.donnees.join("apps-en-ligne.json.sig").exists());
    nettoyer(&faux);
}

#[test]
fn une_liste_plus_recente_remplace_la_gardee() {
    // (le défaut corrigé de la version PowerShell : voir DIVERGENCES.md)
    let (ctx, faux, _) = mindset("remplace");
    let (_, g) = cas("applis : liste gardée bonne");
    std::fs::create_dir_all(&ctx.dossiers.donnees).unwrap();
    std::fs::write(ctx.dossiers.donnees.join("apps-en-ligne.json"), octets(&g["gardee"])).unwrap();
    std::fs::write(ctx.dossiers.donnees.join("apps-en-ligne.json.sig"), octets(&g["gardee_sig"])).unwrap();
    let (_, c) = cas("recevoir : bonne liste");
    faux.reseau.repondre(URL_LISTE_EN_LIGNE, Ok(ReponseHttp::ok(octets(&c["json"]))));
    faux.reseau.repondre(&format!("{URL_LISTE_EN_LIGNE}.sig"), Ok(ReponseHttp::ok(octets(&c["sig"]))));
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    let t = tache(signal(&ctx, &mut bloc, signaux::VERIFIER_LISTE)).unwrap();
    finir(&ctx, &mut bloc, t);
    assert_eq!(std::fs::read(ctx.dossiers.donnees.join("apps-en-ligne.json")).unwrap(), octets(&c["json"]));
    assert_eq!(std::fs::read(ctx.dossiers.donnees.join("apps-en-ligne.json.sig")).unwrap(), octets(&c["sig"]));
    let restes: Vec<_> = std::fs::read_dir(&ctx.dossiers.donnees)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".tmp"))
        .collect();
    assert!(restes.is_empty(), "{restes:?}");
    nettoyer(&faux);
}

#[test]
fn programmes_lances_depuis_le_dossier_de_donnees() {
    let (ctx, faux, _) = mindset("donnees");
    let mut bloc = BlocListe;
    demarrer(&ctx, &mut bloc);
    let evermind = ctx.appli("evermind").unwrap();
    let ancien = evermind.donnees.clone();
    // installée par Mindset, avec son dossier dans les données de la suite
    let suite = ctx.dossiers.donnees_suite.join("Evermind");
    std::fs::create_dir_all(&suite).unwrap();
    ctx.au_nom_de("installations", || {
        ctx.publier(
            partage::INSTALLATIONS,
            json!({ "evermind": { "dossier": "C:\\Prog\\Evermind", "gere": true, "version": "1.0.0" } }),
        )
    });
    let s = suite.to_string_lossy().into_owned();
    faux.systeme.ajouter_processus(10, &format!(r"{s}\voix\Mindset.exe"), 1);
    faux.systeme.ajouter_processus(11, &format!(r"{ancien}\ia\moteur.exe"), 1);
    faux.systeme.ajouter_processus(12, &format!(r"{}\Mindset.exe", ctx.dossiers.mindset.to_string_lossy()), 1);
    faux.systeme.ajouter_processus(ctx.pid(), &format!(r"{s}\Mindset.exe"), 1);
    faux.systeme.ajouter_processus(13, r"C:\Ailleurs\Mindset.exe", 1);
    let pids: Vec<u32> = processus_donnees_appli(&ctx, &evermind).iter().map(|p| p.pid).collect();
    assert_eq!(pids, [10, 11]);
    // pas installée par Mindset : seulement l'ancien dossier
    ctx.au_nom_de("installations", || {
        ctx.publier(
            partage::INSTALLATIONS,
            json!({ "evermind": { "dossier": "C:\\Prog\\Evermind", "gere": false, "version": null } }),
        )
    });
    let pids: Vec<u32> = processus_donnees_appli(&ctx, &evermind).iter().map(|p| p.pid).collect();
    assert_eq!(pids, [11]);
    // jamais toutes les données de la suite
    let mut tout = evermind.clone();
    tout.donnees = ctx.dossiers.donnees_suite.to_string_lossy().into_owned() + "\\";
    assert!(processus_donnees_appli(&ctx, &tout).is_empty());
    nettoyer(&faux);
}
