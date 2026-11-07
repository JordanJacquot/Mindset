//! Des scénarios complets, écrits à la main (en plus des juges) : la mise à jour de Mindset de bout en bout avec une
//! vraie signature, le retour après la mise à jour (et depuis Mindset 2.18 PowerShell), l'installation depuis le
//! dossier téléchargé, les raccourcis, la désinstallation sans désinstalleur, la bascule administrateur qui ne boucle
//! pas, le bandeau de bienvenue, et des cas tirés au hasard (jamais vus).

use mindset_lui_meme::bascule::{self, PcBascule};
use mindset_lui_meme::pc::{FauxPc, PcLuiMeme, Raccourci};
use mindset_lui_meme::regles::{self, DESCRIPTION_RACCOURCI, ID_APPLI, Volume};
use mindset_lui_meme::{LuiMeme, actions, historique, maj};
use mindset_noyau::essai::{self, Faux};
use mindset_noyau::reseau::ReponseHttp;
use mindset_noyau::{Appli, Bloc, Contexte, Effet, Effets, Fenetre, Lancement, Vue, partage};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

struct Menage(PathBuf);
impl Drop for Menage {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn publier(ctx: &Contexte, bloc: &'static str, cle: &str, v: Value) {
    ctx.au_nom_de(bloc, || ctx.publier(cle, v));
}

fn signaux(e: &Effets, nom: &str) -> Vec<Value> {
    e.0.iter()
        .filter_map(|x| match x {
            Effet::Signal { nom: n, donnees } if n == nom => Some(donnees.clone()),
            _ => None,
        })
        .collect()
}

fn quitte(e: &Effets) -> bool {
    e.0.iter().any(|x| matches!(x, Effet::Quitter { .. }))
}

/// Fait les travaux de fond demandés (comme l'hôte avec `taches_directes`), puis rend leur fin au bloc.
fn faire_taches(ctx: &Contexte, bloc: &mut LuiMeme, e: &mut Effets) {
    let mut reste = std::mem::take(&mut e.0);
    while !reste.is_empty() {
        for x in std::mem::take(&mut reste) {
            match x {
                Effet::Tache(t) => {
                    let id = t.id.clone();
                    let r = t.lancer();
                    let mut ef = Effets::default();
                    ctx.au_nom_de("lui-meme", || bloc.tache_finie(ctx, &id, r, &mut ef));
                    reste.extend(ef.0);
                }
                autre => e.0.push(autre),
            }
        }
    }
}

fn signal(ctx: &Contexte, bloc: &mut LuiMeme, nom: &str, d: Value) -> Effets {
    let mut e = Effets::default();
    ctx.au_nom_de("lui-meme", || bloc.signal(ctx, nom, &d, &mut e));
    faire_taches(ctx, bloc, &mut e);
    e
}

fn action(ctx: &Contexte, bloc: &mut LuiMeme, id: &str, v: Value) -> Effets {
    let mut e = Effets::default();
    let pris = ctx.au_nom_de("lui-meme", || bloc.action(ctx, id, &v, &mut e));
    assert!(pris, "action {id} pas prise");
    faire_taches(ctx, bloc, &mut e);
    e
}

fn demarrer(ctx: &Contexte, bloc: &mut LuiMeme) -> Effets {
    let mut e = Effets::default();
    ctx.au_nom_de("lui-meme", || bloc.demarrer(ctx, &mut e));
    faire_taches(ctx, bloc, &mut e);
    e
}

fn tic(ctx: &Contexte, bloc: &mut LuiMeme) -> Effets {
    let mut e = Effets::default();
    ctx.au_nom_de("lui-meme", || bloc.tic(ctx, &mut e));
    faire_taches(ctx, bloc, &mut e);
    e
}

/// La clé et la signature d'essai du juge `verif` (une vraie clé RSA de 3072 bits, faite par l'export PowerShell).
fn cle_d_essai() -> (String, Vec<u8>, Vec<u8>) {
    let t = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(r"tests\juges\verif.json")).unwrap();
    let j: Value = serde_json::from_str(t.trim_start_matches('\u{feff}')).unwrap();
    let d = |k: &str| decoder(j[k].as_str().unwrap());
    (j["cle"].as_str().unwrap().to_string(), d("zip"), d("sig_bonne"))
}

fn decoder(t: &str) -> Vec<u8> {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let (mut r, mut n, mut k) = (Vec::new(), 0u32, 0);
    for c in t.bytes() {
        let Some(v) = A.iter().position(|x| *x == c) else { continue };
        n = (n << 6) | v as u32;
        k += 1;
        if k == 4 {
            r.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8, n as u8]);
            (n, k) = (0, 0);
        }
    }
    match k {
        2 => r.push((n >> 4) as u8),
        3 => r.extend_from_slice(&[(n >> 10) as u8, (n >> 2) as u8]),
        _ => {}
    }
    r
}

fn bloc(f: &Faux) -> (LuiMeme, Arc<FauxPc>) {
    let pc = Arc::new(FauxPc::sous(&f.racine));
    (LuiMeme::neuf().avec_pc(pc.clone()).tout_en_essai(), pc)
}

// ---------------------------------------------------------------------------------------------------------------
// La mise à jour de Mindset, du premier coup
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn la_recherche_attend_la_reponse_fraiche_pour_mindset() {
    // Intégration : le bloc « publications » envoie `verifier-mindset` juste après avoir posé ses questions à GitHub ;
    // la publication encore là est celle de la recherche d'avant (recherche.mindset_en_cours vrai), et
    // `publications-changees` part pour chaque appli. Seule la réponse pour Mindset est prise.
    let (ctx, f) = essai::contexte("scenario-maj-fraiche");
    let _m = Menage(f.racine.clone());
    let (mut b, _pc) = bloc(&f);
    demarrer(&ctx, &mut b);
    let pub_mindset = |v: &str| {
        json!({ "mindset": { "version": v,
            "url_zip": format!("https://github.com/JordanJacquot/Mindset/releases/download/v{v}/Mindset.zip"),
            "url_sig": format!("https://github.com/JordanJacquot/Mindset/releases/download/v{v}/Mindset.zip.sig"),
            "notes": "", "essai": false } })
    };
    publier(&ctx, "publications", partage::PUBLICATIONS, pub_mindset("3.1.0"));
    publier(&ctx, "publications", partage::RECHERCHE, json!({ "mindset_en_cours": true }));
    signal(&ctx, &mut b, "verifier-mindset", json!({}));
    assert!(f.reseau.demandes().is_empty(), "l'ancienne réponse n'est pas téléchargée : {:?}", f.reseau.demandes());
    signal(&ctx, &mut b, "publications-changees", json!({ "id": "evermind" }));
    assert!(f.reseau.demandes().is_empty(), "la réponse pour une appli ne compte pas");
    // La réponse pour Mindset arrive
    publier(&ctx, "publications", partage::PUBLICATIONS, pub_mindset("3.2.0"));
    publier(&ctx, "publications", partage::RECHERCHE, json!({ "mindset_en_cours": false }));
    signal(&ctx, &mut b, "publications-changees", json!({ "id": "mindset" }));
    let d: Vec<String> = f.reseau.demandes().iter().map(|x| x.adresse.clone()).collect();
    assert!(d.iter().any(|a| a.contains("v3.2.0/Mindset.zip")), "{d:?}");
    assert!(!d.iter().any(|a| a.contains("v3.1.0")), "{d:?}");
}

#[test]
fn mise_a_jour_de_mindset_de_bout_en_bout() {
    let (cle, zip, sig) = cle_d_essai();
    let (ctx, f) = essai::contexte("scenario-maj");
    let _m = Menage(f.racine.clone());
    std::fs::create_dir_all(ctx.dossiers.fichiers.join("cles-publiques")).unwrap();
    std::fs::write(ctx.dossiers.fichiers.join(r"cles-publiques\essai.xml"), &cle).unwrap();
    publier(&ctx, "installations", partage::ADMIN, json!({ "tache": "systeme", "en_cours": 0 }));
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "accueil".into() });
    let (mut b, _pc) = bloc(&f);
    demarrer(&ctx, &mut b);
    assert!(!b.bandeau().visible);

    // 1. La recherche : le bloc « publications » donne la dernière version, le zip et sa signature sont téléchargés
    publier(
        &ctx,
        "publications",
        partage::PUBLICATIONS,
        json!({ "mindset": { "version": "3.1.0",
        "url_zip": "https://github.com/JordanJacquot/Mindset/releases/download/v3.1.0/Mindset.zip",
        "url_sig": "https://github.com/JordanJacquot/Mindset/releases/download/v3.1.0/Mindset.zip.sig",
        "notes": "- Plus léger", "essai": false } }),
    );
    f.reseau.repondre(
        "https://github.com/JordanJacquot/Mindset/releases/download/v3.1.0/Mindset.zip",
        Ok(ReponseHttp::ok(zip.clone())),
    );
    f.reseau.repondre(
        "https://github.com/JordanJacquot/Mindset/releases/download/v3.1.0/Mindset.zip.sig",
        Ok(ReponseHttp::ok(sig.clone())),
    );
    signal(&ctx, &mut b, "verifier-mindset", json!({}));
    let tel = ctx.dossiers.telechargements();
    assert_eq!(std::fs::read(tel.join("mindset.zip")).unwrap(), zip, "le zip vérifié est à sa place");
    assert_eq!(std::fs::read(tel.join("mindset.zip.sig")).unwrap(), sig);
    assert!(!tel.join("mindset.zip.nouveau").exists());
    let bd = b.bandeau().clone();
    assert!(bd.visible && bd.bouton_maj && bd.bouton_fermer == "Plus tard");
    assert_eq!(bd.titre, "Mindset 3.1.0 est prêt");
    let m = ctx.lu(partage::MINDSET).unwrap();
    assert_eq!(m["maj"]["version"], "3.1.0");
    assert_eq!(m["maj"]["prete"], true);

    // 2. Le clic : la demande au mini-installateur, avec exactement les champs que lit MindsetInstallateur.exe
    let e = action(&ctx, &mut b, actions::MAJ, Value::Null);
    let d = signaux(&e, "admin-demande");
    assert_eq!(d.len(), 1);
    let d = &d[0];
    assert_eq!(d["action"], "mindset-maj");
    assert_eq!(d["repli"], true, "pas automatique : sans réponse de la tâche, la demande de Windows (par la file)");
    assert_eq!(d["resultat"], maj::fichier_maj(&ctx).to_string_lossy().as_ref());
    assert_eq!(d["auto"], false);
    let p = &d["parametres"];
    assert_eq!(p["Zip"], tel.join("mindset.zip").to_string_lossy().as_ref());
    assert_eq!(p["Signature"], tel.join("mindset.zip.sig").to_string_lossy().as_ref());
    assert_eq!(p["Destination"], ctx.dossiers.mindset_installe().to_string_lossy().as_ref());
    assert_eq!(p["Version"], "3.1.0");
    assert_eq!(p["AttendrePid"], "4242");
    assert!(p.get("Cache").is_none());
    let id = d["id"].as_str().unwrap().to_string();
    assert_eq!(p["Id"], id.as_str(), "le contenu de la demande porte cet id (reconnu dans Resultat au redémarrage)");
    let mut champs: Vec<&String> = p.as_object().unwrap().keys().collect();
    champs.sort();
    assert_eq!(
        champs,
        ["AttendrePid", "Destination", "Id", "Signature", "Version", "Zip"],
        "les champs de Start-MajMindset"
    );
    assert!(suite_commun::protocole_installateur::id_valable(&id), "l'id est celui que vérifie le mini-installateur");
    assert!(!quitte(&e), "Mindset attend l'accusé de réception avant de se fermer");
    assert_eq!(f.donnees.reglages()["MajMindsetVisible"], true, "demandée à l'écran : il reviendra avec sa fenêtre");
    let attendue = historique::lire(&ctx).attendue.unwrap();
    assert_eq!((attendue.version.as_str(), attendue.auto), ("3.1.0", false));
    // (un deuxième clic pendant l'attente ne renvoie rien)
    assert!(signaux(&action(&ctx, &mut b, actions::MAJ, Value::Null), "admin-demande").is_empty());

    // 3. L'accusé de réception : Mindset note la demande et se ferme
    let e = signal(&ctx, &mut b, "admin-recu", json!({ "id": id }));
    assert!(quitte(&e));
    assert_eq!(f.donnees.reglages()["MajMindsetDemande"], id.as_str());
    assert!(f.donnees.lignes().contains(&"Mise à jour vers Mindset 3.1.0 lancée".to_string()));

    // 4. Le mini-installateur l'a relancé (tâche de démarrage : -Demarrage), version 3.1.0
    let reglages = f.donnees.reglages();
    let (mut ctx2, f2) =
        essai::contexte_avec("scenario-maj-apres", Lancement { demarrage: true, ..Default::default() });
    let _m2 = Menage(f2.racine.clone());
    ctx2.version = "3.1.0".into();
    for (k, v) in &reglages {
        ctx2.ecrire_reglage(k, v.clone());
    }
    ctx2.ecrire_reglage("LancerAvecWindows", json!(false));
    std::fs::create_dir_all(&ctx2.dossiers.donnees).unwrap();
    std::fs::copy(historique::fichier(&ctx), historique::fichier(&ctx2)).unwrap();
    let tel2 = ctx2.dossiers.telechargements();
    std::fs::create_dir_all(&tel2).unwrap();
    for n in ["mindset.zip", "mindset.zip.sig"] {
        std::fs::copy(tel.join(n), tel2.join(n)).unwrap();
    }
    f2.installateur.poser_valeur(
        "Resultat",
        &json!({ "id": id, "ok": true, "message": "Mindset 3.1.0 est installé." }).to_string(),
    );
    let (mut b2, _) = bloc(&f2);
    let e = demarrer(&ctx2, &mut b2);
    assert!(!quitte(&e), "« se lance avec Windows » coupé, mais il revient après sa mise à jour");
    assert!(e.0.contains(&Effet::Fenetre(Fenetre::Montrer)), "demandée à l'écran : il revient avec sa fenêtre");
    assert!(!b2.demarrage());
    let bd = b2.bandeau();
    assert!(bd.visible && !bd.bouton_maj && bd.bouton_fermer == "OK");
    assert_eq!(bd.titre, "Mindset est à jour (version 3.1.0)");
    assert_eq!(bd.texte, "La mise à jour s'est bien passée.");
    let r = f2.donnees.reglages();
    assert_eq!(r["MajMindsetDemande"], "");
    assert_eq!(r["MajMindsetVisible"], false);
    assert_eq!(f2.installateur.retraits(), 1, "la demande est effacée par Mindset");
    assert!(!tel2.join("mindset.zip").exists() && !tel2.join("mindset.zip.sig").exists());
    let h = historique::lire(&ctx2);
    assert!(h.attendue.is_none());
    assert_eq!((h.liste[0].id.as_str(), h.liste[0].version.as_str(), h.liste[0].auto), ("mindset", "3.1.0", false));
    let m = ctx2.lu(partage::MINDSET).unwrap();
    assert_eq!(m["derniere_maj"]["version"], "3.1.0");
    assert_eq!(m["derniere_maj"]["quand_texte"], "à 20 h 00");
}

#[test]
fn retour_depuis_mindset_2_18_powershell() {
    // Ce que Mindset 2.18 laisse en se fermant pour passer en 3.0.0, faite toute seule pendant qu'il était caché :
    // ses réglages (MajMindsetDemande, MajMindsetVisible faux), l'historique (mindsetAttendu), et la réponse du
    // mini-installateur dans HKLM. Le 3.0.0 relancé par la tâche de démarrage doit revenir caché, dire « à jour »
    // et noter la mise à jour.
    let (ctx, f) = essai::contexte_avec("scenario-depuis-218", Lancement { demarrage: true, ..Default::default() });
    let _m = Menage(f.racine.clone());
    let id = "0123456789abcdef0123456789abcdef";
    for (k, v) in [
        ("MajMindsetDemande", json!(id)),
        ("MajMindsetVisible", json!(false)),
        ("LancerAvecWindows", json!(false)),
        ("MajAuto", json!(true)),
        ("Fermeture", json!("reduire")),
    ] {
        ctx.ecrire_reglage(k, v);
    }
    // (écrit par ConvertTo-Json de Windows PowerShell : avec BOM, indenté à sa façon)
    let h = "\u{feff}{\r\n    \"historique\":  [\r\n                       {\r\n                           \"id\":  \"evermind\",\r\n                           \"nom\":  \"Evermind\",\r\n                           \"version\":  \"1.2.0\",\r\n                           \"quand\":  \"2026-11-06T10:00:00\",\r\n                           \"auto\":  true,\r\n                           \"notes\":  \"\"\r\n                       }\r\n                   ],\r\n    \"mindsetAttendu\":  {\r\n                           \"id\":  \"mindset\",\r\n                           \"nom\":  \"Mindset\",\r\n                           \"version\":  \"3.0.0\",\r\n                           \"quand\":  \"2026-11-07T19:58:00\",\r\n                           \"auto\":  true,\r\n                           \"notes\":  \"- Mindset en Rust\"\r\n                       }\r\n}";
    std::fs::write(historique::fichier(&ctx), h).unwrap();
    f.installateur.poser_valeur(
        "Resultat",
        &format!("{{\"id\":\"{id}\",\"ok\":true,\"message\":\"Mindset 3.0.0 est installé.\"}}"),
    );
    let (mut b, _) = bloc(&f);
    let e = demarrer(&ctx, &mut b);
    assert!(!quitte(&e));
    assert!(!e.0.iter().any(|x| matches!(x, Effet::Fenetre(_))), "fait caché : il revient caché près de l'horloge");
    assert!(b.demarrage());
    assert_eq!(b.bandeau().titre, "Mindset est à jour (version 3.0.0)");
    let h = historique::lire(&ctx);
    assert_eq!(h.liste.len(), 2);
    assert_eq!((h.liste[0].id.as_str(), h.liste[0].version.as_str(), h.liste[0].auto), ("mindset", "3.0.0", true));
    assert_eq!(h.liste[0].notes, "- Mindset en Rust");
    assert_eq!(h.liste[1].id, "evermind", "rien de perdu");
    assert_eq!(f.donnees.reglages()["Fermeture"], "reduire", "les réglages ne sont pas touchés");
}

#[test]
fn mise_a_jour_ratee_puis_repli_sur_la_demande_de_windows() {
    let (ctx, f) = essai::contexte("scenario-maj-repli");
    let _m = Menage(f.racine.clone());
    publier(&ctx, "installations", partage::ADMIN, json!({ "tache": "systeme", "en_cours": 0 }));
    let (mut b, _) = bloc(&f);
    b.poser_demarre();
    b.poser_maj_prete(Some(mindset_lui_meme::MajPrete {
        version: "3.1.0".into(),
        zip: r"C:\T\z".into(),
        sig: r"C:\T\s".into(),
        notes: String::new(),
    }));
    let e = action(&ctx, &mut b, actions::MAJ, Value::Null);
    let id = signaux(&e, "admin-demande")[0]["id"].as_str().unwrap().to_string();
    // La tâche ne répond pas en 30 secondes : la demande de Windows (MindsetInstallateur.exe en administrateur)
    let e = signal(
        &ctx,
        &mut b,
        "admin-fini",
        json!({ "id": id, "ok": false,
        "message": "la tâche d'installation ne répond pas (pas de réponse de la tâche en 30 secondes)." }),
    );
    let d = f.installateur.directs();
    assert_eq!(d.len(), 1);
    assert_eq!(d[0].action, "mindset-maj");
    assert_eq!(d[0].resultat, maj::fichier_maj(&ctx));
    assert!(d[0].parametres.iter().any(|(n, v)| n == "Sid" && v.starts_with("S-1-5-")));
    assert!(quitte(&e));
    // Au redémarrage (toujours 3.0.0 : l'installation a échoué), le fichier de réponse le dit
    std::fs::create_dir_all(ctx.dossiers.telechargements()).unwrap();
    std::fs::write(maj::fichier_maj(&ctx), r#"{"ok":false,"message":"Le zip n'a pas passé la vérification."}"#)
        .unwrap();
    let (mut b2, _) = bloc(&f);
    demarrer(&ctx, &mut b2);
    assert_eq!(b2.bandeau().titre, "La mise à jour de Mindset n'a pas pu se faire");
    assert_eq!(
        b2.bandeau().texte,
        "Le zip n'a pas passé la vérification. Mindset garde sa version actuelle et réessaiera plus tard."
    );
    assert!(historique::lire(&ctx).liste.is_empty(), "ratée : rien de noté");
    assert!(historique::lire(&ctx).attendue.is_none(), "et l'attente est oubliée");
}

#[test]
fn mise_a_jour_automatique_de_mindset_cache() {
    let (ctx, f) = essai::contexte("scenario-maj-auto");
    let _m = Menage(f.racine.clone());
    ctx.avancer(Duration::from_secs(3600));
    publier(&ctx, "installations", partage::ADMIN, json!({ "tache": "systeme", "en_cours": 0 }));
    let (mut b, pc) = bloc(&f);
    b.poser_demarre();
    b.poser_maj_prete(Some(mindset_lui_meme::MajPrete {
        version: "3.1.0".into(),
        zip: "z".into(),
        sig: "s".into(),
        notes: String::new(),
    }));
    // Caché près de l'horloge : tout de suite, et il reviendra caché
    let e = tic(&ctx, &mut b);
    let d = &signaux(&e, "admin-demande")[0];
    assert_eq!((d["auto"].as_bool(), d["parametres"]["Cache"].as_str()), (Some(true), Some("1")));
    assert_eq!(f.donnees.reglages()["MajMindsetVisible"], false);
    assert!(*pc.releves.lock().unwrap() >= 1, "la manette est relevée");
    // La tâche ne répond pas : pas de demande de Windows (personne pour y répondre), l'échec est dit
    let id = d["id"].as_str().unwrap().to_string();
    let e = signal(
        &ctx,
        &mut b,
        "admin-fini",
        json!({ "id": id, "ok": false, "message": "la tâche d'installation ne répond pas (refusée)." }),
    );
    assert!(f.installateur.directs().is_empty());
    assert_eq!(b.echecs()["mindset"].raison, "L'outil d'installation de Mindset n'a pas répondu.");
    let bu = signaux(&e, "bulle");
    assert_eq!(bu[0]["titre"], "La mise à jour de Mindset n'a pas pu se faire");
    assert!(
        bu[0]["texte"]
            .as_str()
            .unwrap()
            .ends_with("Mindset réessaiera tout seul dans 15 minutes, ou clique sur Réessayer.")
    );
    let ma = ctx.lu(partage::MAJ_AUTO).unwrap();
    assert_eq!(ma["echecs"]["mindset"]["reessai"], 15);
    // 10 minutes plus tard : pas encore ; 16 minutes : un nouvel essai
    ctx.avancer(Duration::from_secs(600));
    assert!(signaux(&tic(&ctx, &mut b), "admin-demande").is_empty());
    ctx.avancer(Duration::from_secs(360));
    assert_eq!(signaux(&tic(&ctx, &mut b), "admin-demande").len(), 1);
    assert_eq!(b.essais()["mindset"].nombre, 2);
}

#[test]
fn une_version_plus_recente_remplace_celle_qui_est_prete() {
    let (cle, zip, sig) = cle_d_essai();
    let (ctx, f) = essai::contexte("scenario-plus-recente");
    let _m = Menage(f.racine.clone());
    std::fs::create_dir_all(ctx.dossiers.fichiers.join("cles-publiques")).unwrap();
    std::fs::write(ctx.dossiers.fichiers.join(r"cles-publiques\essai.xml"), &cle).unwrap();
    let (mut b, _) = bloc(&f);
    b.poser_demarre();
    f.reseau.repondre("https://github.com/z", Ok(ReponseHttp::ok(zip.clone())));
    f.reseau.repondre("https://github.com/s", Ok(ReponseHttp::ok(sig.clone())));
    for (v, attendu) in [("3.0.1", "3.0.1"), ("3.0.4", "3.0.4"), ("3.0.4", "3.0.4"), ("3.0.2", "3.0.4")] {
        publier(
            &ctx,
            "publications",
            partage::PUBLICATIONS,
            json!({ "mindset": { "version": v, "url_zip": "https://github.com/z", "url_sig": "https://github.com/s", "notes": v } }),
        );
        signal(&ctx, &mut b, "publications-changees", json!({}));
        assert_eq!(b.maj_prete().unwrap().version, attendu, "publiée {v}");
        assert!(!b.recherche_en_cours());
    }
    assert!(f.donnees.lignes().contains(&"Mindset 3.0.1 était prêt, remplacé par la 3.0.4, plus récente".to_string()));
    // (la même publication revue ne relance rien)
    let n = f.reseau.demandes().len();
    signal(&ctx, &mut b, "publications-changees", json!({}));
    assert_eq!(f.reseau.demandes().len(), n);
}

#[test]
fn la_recherche_s_arrete_si_publications_ne_repond_pas() {
    let (ctx, f) = essai::contexte("scenario-recherche-muette");
    let _m = Menage(f.racine.clone());
    let (mut b, _) = bloc(&f);
    b.poser_demarre();
    signal(&ctx, &mut b, "verifier-mindset", json!({}));
    assert!(b.recherche_en_cours());
    ctx.avancer(Duration::from_secs(121));
    tic(&ctx, &mut b);
    assert!(!b.recherche_en_cours());
}

// ---------------------------------------------------------------------------------------------------------------
// L'installation depuis le dossier téléchargé
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn installation_depuis_le_dossier_telecharge() {
    let (ctx, f) = essai::contexte("scenario-installation");
    let _m = Menage(f.racine.clone());
    let (mut b, pc) = bloc(&f);
    b.en_essai.bienvenue = true;
    *pc.volumes.lock().unwrap() = vec![
        Volume { lettre: "D:".into(), systeme_fichiers: "NTFS".into(), libre: Some(1_500 * 1_073_741_824) },
        Volume { lettre: "C:".into(), systeme_fichiers: "NTFS".into(), libre: Some(80 * 1_073_741_824) },
        Volume { lettre: "E:".into(), systeme_fichiers: "exFAT".into(), libre: Some(1) },
    ];
    pc.poser_run(Some("ancien"));
    demarrer(&ctx, &mut b);
    let etat = b.etat(&ctx);
    let bv = &etat["bienvenue"];
    assert_eq!(bv["visible"], true);
    assert_eq!(bv["disques"][0]["texte"], "C: (dans Program Files, comme les autres programmes)");
    assert_eq!(bv["disques"][1]["libre"], "1\u{202F}500 Go libres");
    assert_eq!(bv["disques"][0]["coche"], true);
    assert_eq!(bv["disques"].as_array().unwrap().len(), 2, "exFAT n'est pas proposé");
    // « Chercher les nouvelles versions » coupé dans le bandeau
    let e = action(&ctx, &mut b, actions::VERIF, json!({ "oui": false }));
    assert_eq!(signaux(&e, "reglage-change")[0], json!({ "nom": "VerifVersions", "valeur": false }));
    // Un disque qui n'est pas proposé est refusé : C:
    let e = action(&ctx, &mut b, actions::INSTALLER, json!({ "disque": "Q" }));
    let d = &signaux(&e, "admin-demande")[0];
    assert_eq!(d["action"], "mindset");
    assert!(d["parametres"].get("Disque").is_none());
    assert_eq!(d["parametres"]["Version"], "3.0.0");
    assert_eq!(d["parametres"]["Source"], ctx.dossiers.mindset.to_string_lossy().as_ref());
    assert_eq!(b.texte_bienvenue(), "Installation (accepte la demande de Windows)...");
    // (un deuxième clic ne fait rien)
    assert!(signaux(&action(&ctx, &mut b, actions::INSTALLER, json!({ "disque": "D" })), "admin-demande").is_empty());
    // Installé sur D:, sans tâches planifiées
    let dossier = f.racine.join(r"D\Mindset\Programmes\Mindset");
    let id = d["id"].as_str().unwrap().to_string();
    let e = signal(
        &ctx,
        &mut b,
        "admin-fini",
        json!({ "id": id, "ok": true,
        "message": format!("{}|sans-taches : accès refusé", dossier.display()) }),
    );
    let exe = dossier.join("Mindset.exe");
    assert!(e.0.contains(&Effet::LancerApres(exe.clone())));
    assert!(quitte(&e));
    for l in pc.raccourcis_mindset() {
        let r = pc.raccourci(&l).unwrap();
        assert_eq!(r.cible, exe.to_string_lossy());
        assert_eq!(r.app_id, ID_APPLI);
        assert_eq!(r.description, DESCRIPTION_RACCOURCI);
        assert_eq!(r.dossier, dossier.to_string_lossy());
    }
    assert_eq!(pc.valeur_run(), Some(format!("\"{}\" -Demarrage", exe.display())));
    assert!(f.donnees.lignes().contains(&"Tâches planifiées : sans-taches : accès refusé".to_string()));
    // Le réglage coupé suit Mindset sur D: (X:\Mindset\Donnees\Mindset\reglages.json)
    let r: Value = serde_json::from_str(
        &std::fs::read_to_string(f.racine.join(r"D\Mindset\Donnees\Mindset\reglages.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(r["VerifVersions"], false);
}

#[test]
fn installation_refusee_puis_plus_tard() {
    let (ctx, f) = essai::contexte("scenario-installation-refus");
    let _m = Menage(f.racine.clone());
    let (mut b, pc) = bloc(&f);
    b.en_essai.bienvenue = true;
    demarrer(&ctx, &mut b);
    let e = action(&ctx, &mut b, actions::INSTALLER, json!({ "disque": "" }));
    let id = signaux(&e, "admin-demande")[0]["id"].as_str().unwrap().to_string();
    let e = signal(
        &ctx,
        &mut b,
        "admin-fini",
        json!({ "id": id, "ok": false, "message": "l'autorisation de Windows a été refusée." }),
    );
    assert!(!quitte(&e));
    assert_eq!(b.texte_bienvenue(), "Installation impossible : l'autorisation de Windows a été refusée.");
    assert!(pc.raccourcis_mindset().iter().all(|l| pc.raccourci(l).is_none()));
    action(&ctx, &mut b, actions::PLUS_TARD, Value::Null);
    assert_eq!(b.etat(&ctx)["bienvenue"]["visible"], false);
    assert_eq!(ctx.lu(partage::MINDSET).unwrap()["bienvenue"], false);
}

#[test]
fn raccourcis_d_avant_reecrits_avec_l_identite() {
    let (ctx, f) = essai::contexte("scenario-raccourcis");
    let _m = Menage(f.racine.clone());
    let (mut b, pc) = bloc(&f);
    let l = pc.raccourcis_mindset();
    let exe = ctx.dossiers.exe.to_string_lossy().into_owned();
    pc.poser_raccourci(&l[0], Raccourci { cible: exe.to_uppercase(), app_id: String::new(), ..Default::default() });
    pc.poser_raccourci(&l[1], Raccourci { cible: r"C:\Autre\Mindset.exe".into(), ..Default::default() });
    let mut e = Effets::default();
    ctx.au_nom_de("lui-meme", || b.lancer_demarrage(&ctx, &mut e));
    assert_eq!(pc.raccourci(&l[0]).unwrap().app_id, ID_APPLI, "celui de ce Mindset reçoit son identité");
    assert_eq!(pc.raccourci(&l[1]).unwrap().app_id, "", "un raccourci vers un autre programme n'est pas touché");
    assert_eq!(f.donnees.lignes(), vec![format!("Raccourci {} : identité ajoutée", l[0].display())]);
    // Un raccourci supprimé n'est pas recréé
    pc.retirer_fichier(&l[0]).unwrap();
    let mut e = Effets::default();
    ctx.au_nom_de("lui-meme", || b.lancer_demarrage(&ctx, &mut e));
    assert!(pc.raccourci(&l[0]).is_none());
}

#[test]
fn raccourci_au_nom_court_reconnu() {
    // Le raccourci garde le nom court de Windows (8.3) du dossier de Mindset : c'est bien ce Mindset
    let (ctx, f) = essai::contexte("scenario-raccourci-court");
    let _m = Menage(f.racine.clone());
    let (mut b, pc) = bloc(&f);
    let l = pc.raccourcis_mindset();
    let exe = ctx.dossiers.exe.to_string_lossy().into_owned();
    let dossier = suite_commun::chemins::parent(&exe).to_string();
    let court = format!(r"{}\MINDSE~1", suite_commun::chemins::parent(&dossier));
    pc.courts.lock().unwrap().insert(court.clone(), dossier.clone());
    let exe_court = format!(r"{court}\{}", suite_commun::chemins::feuille(&exe));
    pc.poser_raccourci(&l[0], Raccourci { cible: exe_court, app_id: String::new(), ..Default::default() });
    // (contre-épreuve : un autre dossier au nom court n'est pas ce Mindset)
    pc.poser_raccourci(&l[1], Raccourci { cible: format!(r"{court}X\Mindset.exe"), ..Default::default() });
    let mut e = Effets::default();
    ctx.au_nom_de("lui-meme", || b.lancer_demarrage(&ctx, &mut e));
    assert_eq!(pc.raccourci(&l[0]).unwrap().app_id, ID_APPLI, "nom court : reconnu, identité ajoutée");
    assert_eq!(pc.raccourci(&l[1]).unwrap().app_id, "", "un autre dossier : pas touché");
}

// ---------------------------------------------------------------------------------------------------------------
// La désinstallation
// ---------------------------------------------------------------------------------------------------------------

#[test]
fn desinstallation_par_le_desinstalleur_rust() {
    let (ctx, f) = essai::contexte("scenario-desinstalleur");
    let _m = Menage(f.racine.clone());
    std::fs::create_dir_all(&ctx.dossiers.mindset).unwrap();
    std::fs::write(ctx.dossiers.mindset.join("Desinstaller Mindset.exe"), "x").unwrap();
    let (mut b, _) = bloc(&f);
    let e = signal(&ctx, &mut b, "desinstaller-mindset", json!({}));
    let c = &signaux(&e, "confirmation")[0];
    assert_eq!(c["action"], actions::DESINSTALLER_CONTINUER);
    let e = action(&ctx, &mut b, actions::DESINSTALLER_CONTINUER, Value::Null);
    let l = f.systeme.lances();
    assert_eq!(l[0].exe, ctx.dossiers.mindset.join("Desinstaller Mindset.exe"));
    assert!(l[0].arguments.is_empty() && !l[0].sans_droits);
    assert!(e.0.contains(&Effet::Quitter { avec_applis: true }), "Mindset se ferme avec ses applis");
    // Windows refuse de le lancer : la question « Réessayer »
    f.systeme.refuser_lancement(Some("Accès refusé."));
    let e = action(&ctx, &mut b, actions::DESINSTALLER_CONTINUER, Value::Null);
    let c = &signaux(&e, "confirmation")[0];
    assert_eq!(c["titre"], "Le désinstalleur ne s'ouvre pas");
    assert!(!quitte(&e));
}

#[test]
fn desinstallation_sans_desinstalleur() {
    let (ctx, f) = essai::contexte("scenario-desinstallation");
    let _m = Menage(f.racine.clone());
    let (mut b, pc) = bloc(&f);
    b.poser_demarre();
    let l = pc.raccourcis_mindset();
    pc.poser_raccourci(&l[0], Raccourci::default());
    pc.poser_raccourci(&l[1], Raccourci::default());
    pc.poser_run(Some("x"));
    pc.refuser(&l[1]);
    // Un raccourci qui ne part pas : dit, et rien d'autre n'est fait
    let e = action(&ctx, &mut b, actions::DESINSTALLER_OUI, Value::Null);
    let c = &signaux(&e, "confirmation")[0];
    assert_eq!(c["titre"], "Désinstallation pas finie");
    assert!(c["texte"].as_str().unwrap().contains(&format!("le raccourci {}", l[1].display())));
    assert!(signaux(&e, "admin-demande").is_empty());
    pc.refus.lock().unwrap().clear();
    // Puis le dossier, par le mini-installateur ; Mindset se ferme 2 secondes plus tard
    let e = action(&ctx, &mut b, actions::DESINSTALLER_OUI, Value::Null);
    assert!(pc.valeur_run().is_none() && pc.raccourci(&l[1]).is_none());
    let d = &signaux(&e, "admin-demande")[0];
    assert_eq!(d["action"], "supprimer");
    assert_eq!(d["parametres"]["Destination"], ctx.dossiers.mindset_installe().to_string_lossy().as_ref());
    assert_eq!(d["parametres"]["AttendrePid"], "4242");
    assert!(!quitte(&tic(&ctx, &mut b)));
    ctx.avancer(Duration::from_millis(2000));
    assert!(quitte(&tic(&ctx, &mut b)));
    // Refusée : la question, et Mindset reste ouvert
    let e = action(&ctx, &mut b, actions::DESINSTALLER_OUI, Value::Null);
    let id = signaux(&e, "admin-demande")[0]["id"].as_str().unwrap().to_string();
    signal(&ctx, &mut b, "admin-fini", json!({ "id": id, "ok": false, "message": "accès refusé" }));
    ctx.avancer(Duration::from_millis(2000));
    let e = tic(&ctx, &mut b);
    assert!(!quitte(&e));
    assert_eq!(signaux(&e, "confirmation")[0]["titre"], "Désinstallation impossible");
}

#[test]
fn desinstaller_depuis_applications_installees_sans_desinstalleur() {
    let (ctx, f) =
        essai::contexte_avec("scenario-arg-desinstaller", Lancement { desinstaller: true, ..Default::default() });
    let _m = Menage(f.racine.clone());
    let (mut b, _) = bloc(&f);
    demarrer(&ctx, &mut b);
    let e = tic(&ctx, &mut b);
    assert!(e.0.contains(&Effet::Page("parametres".into())));
    assert_eq!(signaux(&e, "confirmation")[0]["titre"], "Désinstaller Mindset ?");
}

// ---------------------------------------------------------------------------------------------------------------
// Le lancement
// ---------------------------------------------------------------------------------------------------------------

struct FauxBascule(String, PathBuf);
impl PcBascule for FauxBascule {
    fn inscrit(&self) -> String {
        self.0.clone()
    }
    fn temp(&self) -> PathBuf {
        self.1.clone()
    }
    fn sid(&self) -> String {
        "S-1-5-21-1".into()
    }
    fn windows(&self) -> PathBuf {
        PathBuf::from(r"C:\Windows")
    }
}

#[test]
fn la_bascule_administrateur_ne_boucle_pas() {
    // Comme outils\tester-bascule-admin.ps1 : l'Explorateur a lui-même les droits, le Mindset relancé est encore
    // administrateur
    let lancement = Lancement { admin: true, ..Default::default() };
    let (ctx, f) = essai::contexte_avec("scenario-bascule", lancement.clone());
    let _m = Menage(f.racine.clone());
    let temp = f.racine.join("temp");
    std::fs::create_dir_all(&temp).unwrap();
    let pc = FauxBascule(ctx.dossiers.mindset.to_string_lossy().into(), temp.clone());
    let maintenant = SystemTime::now();
    let d = bascule::decider(&ctx.dossiers, &lancement, f.systeme.as_ref(), &pc, maintenant);
    assert!(d.quitter);
    let l = f.systeme.lances();
    assert_eq!(l.len(), 2);
    assert_eq!(l[0].exe, ctx.dossiers.mindset.join("MindsetInstallateur.exe"));
    assert_eq!(&l[0].arguments[..2], ["-Action", "taches"]);
    assert_eq!(l[0].dossier, PathBuf::from(r"C:\Windows"), "lancé depuis le dossier de Windows");
    assert_eq!(l[1].exe, PathBuf::from(r"C:\Windows\explorer.exe"));
    assert_eq!(l[1].arguments, vec![ctx.dossiers.exe.to_string_lossy().into_owned()]);
    for _ in 0..2 {
        let d = bascule::decider(&ctx.dossiers, &lancement, f.systeme.as_ref(), &pc, SystemTime::now());
        assert!(!d.quitter, "relancé dans les 2 minutes : pas de nouvelle relance");
        assert_eq!(f.systeme.lances().len(), 2);
    }
    let d = bascule::decider(
        &ctx.dossiers,
        &lancement,
        f.systeme.as_ref(),
        &pc,
        SystemTime::now() + Duration::from_secs(300),
    );
    assert!(d.quitter, "plus de 2 minutes après : la bascule se refait");
}

#[test]
fn rouvert_cache_apres_une_bascule_lancee_avec_windows() {
    let lancement = Lancement { admin: true, demarrage: true, ..Default::default() };
    let (ctx, f) = essai::contexte_avec("scenario-bascule-cache", lancement.clone());
    let _m = Menage(f.racine.clone());
    let temp = f.racine.join("temp");
    std::fs::create_dir_all(&temp).unwrap();
    let pc = FauxBascule(ctx.dossiers.mindset.to_string_lossy().into(), temp.clone());
    assert!(bascule::decider(&ctx.dossiers, &lancement, f.systeme.as_ref(), &pc, SystemTime::now()).quitter);
    assert!(temp.join(bascule::MARQUE_CACHE).exists());
    // Rouvert par l'Explorateur, sans les droits et sans -Demarrage : il se comporte comme lancé avec Windows
    let sans = Lancement::default();
    let d = bascule::decider(&ctx.dossiers, &sans, f.systeme.as_ref(), &pc, SystemTime::now());
    assert!(d.demarrage_force && !d.quitter);
    assert!(!temp.join(bascule::MARQUE_CACHE).exists(), "la marque ne sert qu'une fois");
}

#[test]
fn lance_avec_windows_puis_les_applis_s_ouvrent() {
    let (ctx, f) = essai::contexte_avec("scenario-demarrage", Lancement { demarrage: true, ..Default::default() });
    let _m = Menage(f.racine.clone());
    ctx.definir_applis(vec![Appli { id: "evermind".into(), nom: "Evermind".into(), ..Default::default() }]);
    publier(
        &ctx,
        "installations",
        partage::INSTALLATIONS,
        json!({ "evermind": { "dossier": "x", "gere": true, "version": "1.0.0" } }),
    );
    publier(&ctx, "installations", partage::DEMARRAGES, json!({ "evermind": true }));
    let (mut b, _) = bloc(&f);
    let e = demarrer(&ctx, &mut b);
    assert!(!quitte(&e) && b.demarrage());
    let e = tic(&ctx, &mut b);
    assert_eq!(signaux(&e, "lancer-appli"), vec![json!({ "id": "evermind", "demarrage": true })]);
    assert!(signaux(&tic(&ctx, &mut b), "lancer-appli").is_empty(), "une seule fois");
    // « Mindset se lance avec Windows » coupé : rien n'est ouvert
    let (ctx2, f2) =
        essai::contexte_avec("scenario-demarrage-coupe", Lancement { demarrage: true, ..Default::default() });
    let _m2 = Menage(f2.racine.clone());
    ctx2.ecrire_reglage("LancerAvecWindows", json!(false));
    let (mut b2, _) = bloc(&f2);
    assert!(quitte(&demarrer(&ctx2, &mut b2)));
    assert!(b2.etat(&ctx2)["maj_mindset"]["visible"] == false);
}

#[test]
fn confidentialite_d_une_appli_ou_de_mindset() {
    let (ctx, f) = essai::contexte("scenario-confidentialite");
    let _m = Menage(f.racine.clone());
    ctx.definir_applis(vec![Appli {
        id: "mindcare".into(),
        confidentialite: "https://github.com/JordanJacquot/Mindcare/blob/main/CONFIDENTIALITE.md".into(),
        ..Default::default()
    }]);
    let (mut b, _) = bloc(&f);
    let e = signal(&ctx, &mut b, "confidentialite", json!({ "id": "mindcare" }));
    assert!(e.0.contains(&Effet::OuvrirAdresse(
        "https://github.com/JordanJacquot/Mindcare/blob/main/CONFIDENTIALITE.md".into()
    )));
    let e = signal(&ctx, &mut b, "confidentialite", json!({ "id": "inconnue" }));
    assert!(e.0.contains(&Effet::OuvrirAdresse(regles::PAGE_CONFIDENTIALITE.into())));
    let e = action(&ctx, &mut b, actions::CONFIDENTIALITE, json!(""));
    assert!(e.0.contains(&Effet::OuvrirAdresse(regles::PAGE_CONFIDENTIALITE.into())));
}

#[test]
fn rien_en_essai_sans_permission() {
    // La construction d'essai : comme $EnTest, ni mises à jour automatiques, ni désinstalleur, ni applis lancées
    let (ctx, f) = essai::contexte("scenario-essai-garde");
    let _m = Menage(f.racine.clone());
    std::fs::create_dir_all(&ctx.dossiers.mindset).unwrap();
    std::fs::write(ctx.dossiers.mindset.join("Desinstaller Mindset.exe"), "x").unwrap();
    publier(&ctx, "installations", partage::ADMIN, json!({ "tache": "systeme", "en_cours": 0 }));
    let mut b = LuiMeme::neuf().avec_pc(Arc::new(FauxPc::sous(&f.racine)));
    demarrer(&ctx, &mut b);
    b.poser_maj_prete(Some(mindset_lui_meme::MajPrete {
        version: "9.0.0".into(),
        zip: "z".into(),
        sig: "s".into(),
        notes: String::new(),
    }));
    let e = tic(&ctx, &mut b);
    assert!(e.0.is_empty(), "{:?}", e.0);
    action(&ctx, &mut b, actions::DESINSTALLER_CONTINUER, Value::Null);
    assert!(f.systeme.lances().is_empty());
    signal(&ctx, &mut b, "verifier-mindset", json!({}));
    assert!(!b.recherche_en_cours());
}

// ---------------------------------------------------------------------------------------------------------------
// Des cas jamais vus, tirés au hasard
// ---------------------------------------------------------------------------------------------------------------

/// Un tirage simple et reproductible (xorshift).
struct Hasard(u64);
impl Hasard {
    fn n(&mut self, max: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % max.max(1)
    }
    fn texte(&mut self) -> String {
        const C: &[char] = &['a', 'é', 'Z', ' ', '.', '!', '\n', '0', '4', '-', 'É', ':', '🙂', '\t', '(', ')'];
        (0..self.n(200)).map(|_| C[self.n(C.len() as u64) as usize]).collect()
    }
}

#[test]
fn hasard_les_textes_restent_simples() {
    let mut h = Hasard(0x5eed_2026_1107);
    for _ in 0..3000 {
        let m = h.texte();
        let r = regles::raison_echec_maj("Mindcare", &m);
        assert!(!r.is_empty());
        assert!(!r.contains(['\u{2013}', '\u{2014}']), "tiret long : {r}");
        assert!(regles::longueur_utf16(&r) <= 141, "trop long : {r}");
        assert!(r.ends_with(['.', '!', '?']), "{r:?}");
        let (t, x) = regles::bulle_ratee("Mindcare", &r, Some(h.n(20) as i64 - 1));
        assert!(!format!("{t}{x}").contains(['\u{2013}', '\u{2014}']));
        let (_, resume) = regles::bulle_reussie("Evermind", "1.0.0", &m);
        assert!(regles::longueur_utf16(&resume) <= 180);
        assert!(!resume.starts_with(['-', '*', '#', ' ']));
        let _ = regles::nom_raison_jeu(&m);
        let _ = regles::format_de_nom(&m);
    }
}

#[test]
fn hasard_entrees_et_historique() {
    let mut h = Hasard(0xdead_beef_1234);
    let maintenant = mindset_noyau::moment::lire_iso("2026-11-07T20:00:00").unwrap();
    for _ in 0..2000 {
        let quand =
            format!("20{:02}-{:02}-{:02}T{:02}:{:02}:{:02}", h.n(40), h.n(14), h.n(33), h.n(26), h.n(61), h.n(61));
        let id = ["evermind", "a b", "", "x-1"][h.n(4) as usize];
        let version = ["1.2", "1", "1.2.3.4.5", "2.0.0"][h.n(4) as usize];
        let x = json!({ "id": id, "version": version,
            "quand": quand, "nom": h.texte(), "auto": h.n(2) == 1, "notes": h.texte() });
        if let Some(e) = regles::entree_maj(&x) {
            // Une entrée valable relue reste la même (le fichier réécrit ne change pas)
            assert_eq!(regles::entree_maj(&e.en_json()), Some(e.clone()));
            assert!(regles::longueur_utf16(&e.nom) <= 30);
            let q = regles::format_quand_maj(&e.quand, &maintenant, h.n(2) == 1).unwrap();
            assert!(q.contains(" h "), "{q}");
        }
    }
}

#[test]
fn hasard_les_essais_automatiques_sont_limites() {
    // Quels que soient les essais ratés, jamais plus de 3 par version, et jamais deux en moins de 15 minutes
    let mut h = Hasard(42);
    for _ in 0..300 {
        let mut e: Option<regles::Essai> = None;
        let mut t = 0u64;
        let mut essais = Vec::new();
        for _ in 0..40 {
            t += h.n(20 * 60_000);
            if regles::reessai(e.as_ref(), "1.0.0", t).is_none() {
                e = Some(regles::essai_suivant(e.as_ref(), "1.0.0", t));
                essais.push(t);
            }
        }
        assert!(essais.len() <= 3, "{essais:?}");
        assert!(essais.windows(2).all(|w| w[1] - w[0] >= 15 * 60_000), "{essais:?}");
    }
}

#[test]
fn hasard_les_disques() {
    let mut h = Hasard(7);
    for _ in 0..500 {
        let v: Vec<Volume> = (0..h.n(6))
            .map(|i| Volume {
                lettre: format!("{}:", (b'C' + i as u8) as char),
                systeme_fichiers: ["NTFS", "FAT32", "ntfs"][h.n(3) as usize].into(),
                libre: Some(h.n(1 << 45)),
            })
            .collect();
        for d in regles::disques(&v, "C") {
            assert!(d.libre.ends_with(" Go libres"));
            assert!(d.lettre.is_empty() || d.texte == format!(r"{}:\Mindset", d.lettre));
        }
    }
}

#[test]
fn mise_a_jour_par_la_demande_de_windows_sans_la_tache() {
    // Mindset administrateur ou tâche absente : la demande de Windows, faite par la file du bloc « installations »
    // (Start-MajMindsetDirecte) ; Mindset se ferme dès qu'elle est lancée, sa réponse arrive dans maj-mindset.json
    let (ctx, f) = essai::contexte("scenario-maj-windows");
    let _m = Menage(f.racine.clone());
    publier(&ctx, "installations", partage::ADMIN, json!({ "tache": "absente", "en_cours": 0 }));
    let (mut b, _) = bloc(&f);
    b.poser_demarre();
    b.poser_maj_prete(Some(mindset_lui_meme::MajPrete {
        version: "3.1.0".into(),
        zip: r"C:\T\z".into(),
        sig: r"C:\T\s".into(),
        notes: String::new(),
    }));
    let e = action(&ctx, &mut b, actions::MAJ, Value::Null);
    let d = &signaux(&e, "admin-demande")[0];
    let p = &d["parametres"];
    assert!(
        p.get("Id").is_none() && p.get("Cache").is_none(),
        "MindsetInstallateur.exe refuse -Id et -Cache en direct"
    );
    assert!(p["Sid"].as_str().unwrap().starts_with("S-1-5-"));
    assert_eq!(d["resultat"], maj::fichier_maj(&ctx).to_string_lossy().as_ref());
    assert!(f.installateur.directs().is_empty(), "par la file, une demande à la fois");
    let id = d["id"].as_str().unwrap().to_string();
    let e = signal(&ctx, &mut b, "admin-recu", json!({ "id": id, "direct": true }));
    assert!(quitte(&e));
    assert!(!f.donnees.reglages().contains_key("MajMindsetDemande"), "la réponse sera dans le fichier");
    assert!(f.donnees.lignes().contains(&"Mise à jour vers Mindset 3.1.0 lancée".to_string()));
}
