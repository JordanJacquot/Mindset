//! Le bloc entier, avec les faux ports (faux GitHub, faux mini-installateur, faux Windows, faux poste) : installer,
//! mettre à jour (appli ouverte priée de quitter), prendre en charge une copie trouvée, déplacer les données d'un
//! disque à l'autre, désinstaller (avec ou sans désinstalleur), ouvrir, raccourci du menu Démarrer, démarrage avec
//! Mindset, mise à jour automatique ratée, quitter avec les applis. Les cas sont ceux des tests de la version
//! PowerShell (tester-mises-a-jour.ps1, tester-raccourcis.ps1, tester-desinstallation.ps1, tester-renommage.ps1,
//! tester-securite.ps1), rejoués sur le bloc Rust.

use mindset_installations::BlocInstallations;
use mindset_installations::poste::{FauxPoste, Poste};
use mindset_noyau::essai::Faux;
use mindset_noyau::installateur::EtatTache;
use mindset_noyau::reseau::ReponseHttp;
use mindset_noyau::{Appli, Bloc, Contexte, Effet, Effets, Lancement};
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

const ZIP: &str = "https://github.com/JordanJacquot/Evermind/releases/download/v2.5.0/Evermind.zip";
const SIG: &str = "https://github.com/JordanJacquot/Evermind/releases/download/v2.5.0/Evermind.zip.sig";

fn evermind(racine: &Path) -> Appli {
    Appli {
        id: "evermind".into(),
        genre: "powershell".into(),
        nom: "Evermind".into(),
        app_id: "JordanJacquot.Evermind".into(),
        description: "Evermind".into(),
        depot: "JordanJacquot/Evermind".into(),
        zip: "Evermind.zip".into(),
        dossier_zip: "Evermind".into(),
        exe: "Evermind.exe".into(),
        script: r"fichiers\Evermind.ps1".into(),
        mutex: r"Local\EvermindEssai-Instance".into(),
        afficher_signal: r"Local\EvermindEssai-Afficher".into(),
        donnees: racine.join(r"Anciennes\Evermind").to_string_lossy().into_owned(),
        rappels: true,
        ..Default::default()
    }
}

fn nevermind(racine: &Path) -> Appli {
    Appli {
        id: "nevermind".into(),
        genre: "rust".into(),
        nom: "Nevermind".into(),
        app_id: "JordanJacquot.Nevermind".into(),
        dossier_zip: "Nevermind".into(),
        exe: "Nevermind.exe".into(),
        script: r"fichiers\Nevermind.ps1".into(),
        mutex: r"Local\NevermindEssai-Instance".into(),
        afficher_fichier: "afficher.demande".into(),
        desinstalleur: "Désinstaller Nevermind.exe".into(),
        donnees: racine.join(r"Anciennes\Nevermind").to_string_lossy().into_owned(),
        admin: true,
        sans_droits_depuis: "1.15.0".into(),
        ..Default::default()
    }
}

struct Monde {
    ctx: Contexte,
    faux: Faux,
    poste: Arc<FauxPoste>,
    bloc: BlocInstallations,
    signaux: Vec<(String, Value)>,
}

impl Monde {
    fn nouveau(nom: &str) -> Monde {
        Monde::avec(nom, Lancement::default())
    }

    fn avec(nom: &str, l: Lancement) -> Monde {
        let (ctx, faux) = mindset_noyau::essai::contexte_avec(nom, l);
        let applis = vec![evermind(&faux.racine), nevermind(&faux.racine)];
        ctx.definir_applis(applis);
        // (les tâches déjà refaites pour cette version : sinon le premier tic dépose une demande « taches »)
        ctx.ecrire_reglage("TachesRefaitesPour", json!("3.0.0"));
        let cles = ctx.dossiers.fichiers.join("cles-publiques");
        std::fs::create_dir_all(&cles).unwrap();
        std::fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR")).join(r"tests\cle-de-test\publique-de-test.xml"),
            cles.join("test.xml"),
        )
        .unwrap();
        let poste = Arc::new(FauxPoste::nouveau(&faux.racine));
        let bloc = BlocInstallations::pour_essai(poste.clone());
        let mut m = Monde { ctx, faux, poste, bloc, signaux: Vec::new() };
        let mut e = Effets::default();
        m.ctx.au_nom_de("installations", || m.bloc.demarrer(&m.ctx, &mut e));
        m.pomper(e);
        m
    }

    /// Les effets : les travaux de fond sont faits tout de suite, les signaux gardés.
    fn pomper(&mut self, mut e: Effets) {
        while !e.0.is_empty() {
            let mut suite = Effets::default();
            for x in std::mem::take(&mut e.0) {
                match x {
                    Effet::Tache(t) => {
                        let id = t.id.clone();
                        let r = t.lancer();
                        let b = &mut self.bloc;
                        let ctx = &self.ctx;
                        ctx.au_nom_de("installations", || b.tache_finie(ctx, &id, r, &mut suite));
                    }
                    Effet::Signal { nom, donnees } => self.signaux.push((nom, donnees)),
                    _ => {}
                }
            }
            e = suite;
        }
    }

    fn signal(&mut self, nom: &str, d: Value) {
        let mut e = Effets::default();
        let b = &mut self.bloc;
        let ctx = &self.ctx;
        ctx.au_nom_de("installations", || b.signal(ctx, nom, &d, &mut e));
        self.pomper(e);
    }

    fn tic(&mut self) -> Option<Duration> {
        let mut e = Effets::default();
        let b = &mut self.bloc;
        let ctx = &self.ctx;
        let d = ctx.au_nom_de("installations", || b.tic(ctx, &mut e));
        self.pomper(e);
        d
    }

    fn avancer(&mut self, s: u64) {
        self.ctx.avancer(Duration::from_secs(s));
    }

    fn publier_version(&self, id: &str, version: &str) {
        let p = json!({ id: { "version": version, "url_zip": ZIP, "url_sig": SIG, "notes": "- Rappels plus doux\n- Autre", "essai": false } });
        self.ctx.au_nom_de("publications", || self.ctx.publier("publications", p));
    }

    fn message(&self, id: &str) -> String {
        self.ctx.lu("messages").and_then(|m| m.get(id).and_then(Value::as_str).map(str::to_string)).unwrap_or_default()
    }

    fn occupation(&self, id: &str) -> Option<String> {
        mindset_noyau::partage::occupation(&self.ctx, id)
    }

    fn finies(&self) -> Vec<Value> {
        self.signaux.iter().filter(|(n, _)| n == "operation-finie").map(|(_, d)| d.clone()).collect()
    }

    fn gere(&self, nom: &str) -> PathBuf {
        self.ctx.dossiers.programmes.join(nom)
    }
}

impl Drop for Monde {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.faux.racine);
    }
}

fn signer(donnees: &[u8]) -> Vec<u8> {
    let pk8 =
        std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join(r"tests\cle-de-test\privee-de-test.der")).unwrap();
    let cle = ring::signature::RsaKeyPair::from_der(&pk8).unwrap();
    let mut sig = vec![0u8; cle.public().modulus_len()];
    cle.sign(&ring::signature::RSA_PKCS1_SHA256, &ring::rand::SystemRandom::new(), donnees, &mut sig).unwrap();
    sig
}

fn zip(entrees: &[(&str, &str)]) -> Vec<u8> {
    let mut z = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    for (n, t) in entrees {
        z.start_file(*n, o).unwrap();
        z.write_all(t.as_bytes()).unwrap();
    }
    z.finish().unwrap().into_inner()
}

fn zip_evermind(version: &str) -> Vec<u8> {
    zip(&[
        ("Evermind/Evermind.exe", "exe"),
        ("Evermind/fichiers/Evermind.ps1", &format!("$AppVersion = '{version}'\n")),
        ("Evermind/fichiers/modules/rappels.ps1", "#"),
    ])
}

/// Une installation de l'appli dans ce dossier (ce que ferait le mini-installateur).
fn poser_evermind(d: &Path, version: &str) {
    std::fs::create_dir_all(d.join("fichiers")).unwrap();
    std::fs::write(d.join("Evermind.exe"), "exe").unwrap();
    std::fs::write(d.join(r"fichiers\Evermind.ps1"), format!("$AppVersion = '{version}'\n")).unwrap();
}

fn poser_nevermind(d: &Path, version: &str) {
    std::fs::create_dir_all(d).unwrap();
    std::fs::write(d.join("Nevermind.exe"), "exe").unwrap();
    std::fs::write(d.join("Mindset.exe"), "hote").unwrap();
    std::fs::write(d.join("version.json"), format!(r#"{{"version":"{version}","appli":"nevermind"}}"#)).unwrap();
}

/// GitHub répond le zip et sa signature ; le mini-installateur installe vraiment (dans le dossier d'essai) et répond.
fn preparer_installation(m: &Monde, version: &str) {
    let z = zip_evermind(version);
    m.faux.reseau.repondre(SIG, Ok(ReponseHttp::ok(signer(&z))));
    m.faux.reseau.repondre(ZIP, Ok(ReponseHttp::ok(z)));
    let v = version.to_string();
    m.faux.installateur.repondre(move |d| match d["Action"].as_str() {
        Some("appli") => {
            let dest = PathBuf::from(d["Destination"].as_str().unwrap());
            poser_evermind(&dest, &v);
            Some((true, dest.to_string_lossy().into_owned()))
        }
        Some("supprimer") => {
            let _ = std::fs::remove_dir_all(d["Destination"].as_str().unwrap());
            Some((true, String::new()))
        }
        _ => None,
    });
}

#[test]
fn installation_par_la_tache() {
    let mut m = Monde::nouveau("flux-installation");
    preparer_installation(&m, "2.5.0");
    m.publier_version("evermind", "2.5.0");
    m.tic();
    m.signal("installer", json!({ "id": "evermind", "ancien": null, "auto": false }));
    // (téléchargé et vérifié, déposé pour la tâche, qui a répondu tout de suite)
    let d = m.faux.installateur.deposees();
    assert_eq!(d.len(), 1, "{d:?}");
    assert_eq!(d[0]["Action"], "appli");
    assert_eq!(d[0]["Appli"], "evermind");
    assert_eq!(d[0]["DossierZip"], "Evermind");
    assert_eq!(d[0]["Exe"], "Evermind.exe");
    assert_eq!(d[0]["Destination"], m.gere("Evermind").to_string_lossy().as_ref());
    assert!(d[0]["Zip"].as_str().unwrap().ends_with(r"telechargements\evermind.zip"));
    assert!(d[0].get("Sid").is_none(), "première installation : pas de Sid");
    assert_eq!(m.occupation("evermind").as_deref(), Some("Installation..."));
    m.tic();
    assert_eq!(m.occupation("evermind"), None);
    assert_eq!(m.message("evermind"), "Evermind 2.5.0 est installé.");
    let i = mindset_noyau::partage::installation(&m.ctx, "evermind").unwrap();
    assert!(i.gere);
    assert_eq!(i.version.as_deref(), Some("2.5.0"));
    assert_eq!(
        m.ctx.donnees().suite().applis,
        vec![("evermind".into(), m.gere("Evermind").to_string_lossy().into_owned())]
    );
    // (appli de rappels : elle s'ouvre avec Mindset, et tout de suite, cachée)
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!(["evermind"])));
    let l = m.faux.systeme.lances();
    assert_eq!(l.len(), 1);
    assert!(l[0].exe.ends_with(r"Evermind\Evermind.exe"));
    assert_eq!(l[0].arguments, vec!["-Demarrage"]);
    let f = m.finies();
    assert_eq!(f.len(), 1);
    assert_eq!(f[0]["ok"], true);
    assert_eq!(f[0]["quoi"], "installation");
    assert_eq!(f[0]["historique"], Value::Null, "première installation : pas dans l'historique");
    assert!(!m.ctx.dossiers.telechargements().join("evermind.zip").exists(), "le zip téléchargé est effacé");
    assert!(m.signaux.iter().any(|(n, _)| n == "installations-changees"));
    let lignes = m.faux.donnees.lignes();
    assert!(lignes.iter().any(|l| l.starts_with("Evermind 2.5.0 installé dans ")), "{lignes:?}");
}

#[test]
fn mise_a_jour_avec_l_appli_ouverte() {
    let mut m = Monde::nouveau("flux-maj-ouverte");
    poser_evermind(&m.gere("Evermind"), "2.4.0");
    let donnees = m.ctx.dossiers.donnees_suite.join("Evermind");
    std::fs::create_dir_all(&donnees).unwrap();
    m.tic();
    preparer_installation(&m, "2.5.0");
    m.publier_version("evermind", "2.5.0");
    m.faux.systeme.poser_verrou(r"Local\EvermindEssai-Instance", true);
    m.signal("installer", json!({ "id": "evermind" }));
    assert_eq!(m.occupation("evermind").as_deref(), Some("Fermeture de Evermind..."));
    assert!(donnees.join("quitter.demande").exists(), "priée de quitter proprement");
    assert_eq!(std::fs::read_to_string(donnees.join("quitter.demande")).unwrap(), "4242");
    assert!(m.faux.installateur.deposees().is_empty(), "pas avant qu'elle se ferme");
    m.avancer(10);
    m.tic();
    assert!(m.faux.installateur.deposees().is_empty());
    m.avancer(21);
    m.tic();
    assert_eq!(m.faux.installateur.deposees().len(), 1, "après 30 s, l'installation part quand même");
    assert!(
        m.faux.donnees.lignes().iter().any(|l| l == "Evermind ne s'est pas fermé en 30 s : l'installateur le fermera")
    );
    m.faux.systeme.poser_verrou(r"Local\EvermindEssai-Instance", false);
    m.tic();
    assert_eq!(m.message("evermind"), "Evermind 2.5.0 est installé.");
    let f = m.finies();
    assert_eq!(f[0]["historique"]["version"], "2.5.0", "une mise à jour va dans l'historique");
    assert_eq!(f[0]["historique"]["notes"], "- Rappels plus doux\n- Autre");
    assert_eq!(f[0]["avant"], "2.4.0");
    // (elle était ouverte : relancée cachée)
    assert_eq!(m.faux.systeme.lances().len(), 1);
}

#[test]
fn fermee_proprement_avant_le_delai() {
    let mut m = Monde::nouveau("flux-fermee");
    poser_evermind(&m.gere("Evermind"), "2.4.0");
    m.tic();
    preparer_installation(&m, "2.5.0");
    m.publier_version("evermind", "2.5.0");
    m.faux.systeme.poser_verrou(r"Local\EvermindEssai-Instance", true);
    m.signal("installer", json!({ "id": "evermind" }));
    m.faux.systeme.poser_verrou(r"Local\EvermindEssai-Instance", false);
    m.ctx.avancer(Duration::from_millis(1500));
    m.tic();
    assert!(m.faux.donnees.lignes().iter().any(|l| l == "Evermind s'est fermé proprement (1.5 s)"));
    assert_eq!(m.faux.installateur.deposees().len(), 1);
}

#[test]
fn signature_invalide_rien_n_est_installe() {
    let mut m = Monde::nouveau("flux-signature");
    let z = zip_evermind("2.5.0");
    m.faux.reseau.repondre(SIG, Ok(ReponseHttp::ok(signer(b"autre chose"))));
    m.faux.reseau.repondre(ZIP, Ok(ReponseHttp::ok(z)));
    m.publier_version("evermind", "2.5.0");
    m.signal("installer", json!({ "id": "evermind" }));
    assert_eq!(
        m.message("evermind"),
        "Échec : La signature du fichier téléchargé est invalide : rien n'a été installé."
    );
    assert!(m.faux.installateur.deposees().is_empty());
    assert_eq!(m.finies()[0]["ok"], false);
}

#[test]
fn zip_d_une_autre_appli_refuse_avant_de_fermer() {
    let mut m = Monde::nouveau("flux-autre-appli");
    let z =
        zip(&[("Evermind/Evermind.exe", "x"), ("Evermind/version.json", r#"{"version":"2.5.0","appli":"nevermind"}"#)]);
    m.faux.reseau.repondre(SIG, Ok(ReponseHttp::ok(signer(&z))));
    m.faux.reseau.repondre(ZIP, Ok(ReponseHttp::ok(z)));
    m.publier_version("evermind", "2.5.0");
    m.faux.systeme.poser_verrou(r"Local\EvermindEssai-Instance", true);
    m.signal("installer", json!({ "id": "evermind" }));
    assert_eq!(
        m.message("evermind"),
        "Échec : Ce fichier contient l'appli nevermind et pas evermind : rien n'a été installé."
    );
    assert!(m.faux.installateur.deposees().is_empty());
}

#[test]
fn version_non_signee_et_adresse_refusee() {
    let mut m = Monde::nouveau("flux-non-signee");
    let p = json!({ "evermind": { "version": "2.5.0", "url_zip": ZIP, "url_sig": "", "notes": "" } });
    m.ctx.au_nom_de("publications", || m.ctx.publier("publications", p));
    m.signal("installer", json!({ "id": "evermind" }));
    assert_eq!(m.message("evermind"), "Échec : La version 2.5.0 n'est pas signée : Mindset ne l'installera pas.");
    let p =
        json!({ "evermind": { "version": "2.5.1", "url_zip": "https://exemple.com/Evermind.zip", "url_sig": SIG } });
    m.ctx.au_nom_de("publications", || m.ctx.publier("publications", p));
    m.signal("installer", json!({ "id": "evermind" }));
    assert_eq!(m.message("evermind"), "Échec : Adresse de téléchargement refusée : https://exemple.com/Evermind.zip");
    assert!(m.faux.reseau.demandes().iter().all(|d| d.adresse.starts_with("https://github.com/")), "jamais ailleurs");
}

#[test]
fn version_pas_encore_connue_une_recherche_est_demandee() {
    let mut m = Monde::nouveau("flux-publication-attendue");
    preparer_installation(&m, "2.5.0");
    m.signal("installer", json!({ "id": "evermind" }));
    assert!(m.signaux.iter().any(|(n, d)| n == "actualiser" && d["clic"] == true));
    assert_eq!(m.occupation("evermind").as_deref(), Some("Téléchargement..."));
    m.publier_version("evermind", "2.5.0");
    m.signal("publications-changees", json!({}));
    assert_eq!(m.faux.installateur.deposees().len(), 1);
    // (une erreur de GitHub arrête l'installation)
    let p = json!({ "nevermind": { "erreur": "GitHub ne répond pas (403)" } });
    m.signal("installer", json!({ "id": "nevermind" }));
    m.ctx.au_nom_de("publications", || m.ctx.publier("publications", p));
    m.signal("publications-changees", json!({}));
    assert_eq!(m.message("nevermind"), "Échec : GitHub ne répond pas (403)");
}

#[test]
fn prise_en_charge_d_une_copie_trouvee() {
    let mut m = Monde::nouveau("flux-prise-en-charge");
    let ancienne = m.poste.lieu(r"Telechargements\Evermind");
    poser_evermind(&ancienne, "2.3.0");
    std::fs::write(ancienne.join("notes perso.txt"), "à garder").unwrap();
    let cible = ancienne.join("Evermind.exe").to_string_lossy().into_owned();
    m.poste.poser_raccourci(&m.poste.lieu(r"Bureau\Evermind.lnk"), &cible, "", "");
    m.poste.poser_run("Evermind", Some(&format!("\"{cible}\" -Demarrage")));
    m.tic();
    // (la copie est trouvée par le travail de fond du démarrage)
    let mut e = Effets::default();
    m.ctx.au_nom_de("installations", || m.bloc.demarrer(&m.ctx, &mut e));
    m.pomper(e);
    assert_eq!(m.ctx.lu("trouvees").unwrap()["evermind"].as_str(), Some(ancienne.to_string_lossy().as_ref()));
    preparer_installation(&m, "2.5.0");
    m.publier_version("evermind", "2.5.0");
    m.signal("installer", json!({ "id": "evermind", "ancien": ancienne.to_string_lossy() }));
    let d = m.faux.installateur.deposees();
    assert_eq!(d[0]["AncienExe"], cible.as_str());
    assert_eq!(d[0]["Sid"], "S-1-5-21-1111-2222-3333-1001");
    m.tic();
    let msg = m.message("evermind");
    assert!(
        msg.starts_with(
            "Evermind 2.5.0 est installé. 1 raccourci direct retiré : Evermind s'ouvre maintenant depuis Mindset. "
        ),
        "{msg}"
    );
    assert!(msg.contains("a été vidée de Evermind ; 1 fichier qui n'en faisait pas partie y reste."), "{msg}");
    assert!(!m.poste.lieu(r"Bureau\Evermind.lnk").exists(), "raccourci direct retiré");
    assert_eq!(m.poste.run_retirees(), vec!["Evermind"]);
    assert!(ancienne.join("notes perso.txt").exists(), "un fichier qui n'est pas livré reste");
    assert!(!ancienne.join("Evermind.exe").exists());
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!(["evermind"])), "elle se lançait avec Windows : par Mindset");
    assert_eq!(m.ctx.lu("trouvees").unwrap().get("evermind"), None, "plus trouvée : installée");
}

#[test]
fn dossier_de_travail_garde() {
    let mut m = Monde::nouveau("flux-travail");
    let ancienne = m.faux.racine.join(r"Projets\Evermind\Evermind");
    poser_evermind(&ancienne, "2.3.0");
    std::fs::create_dir_all(m.faux.racine.join(r"Projets\Evermind\.git")).unwrap();
    preparer_installation(&m, "2.5.0");
    m.publier_version("evermind", "2.5.0");
    m.signal("installer", json!({ "id": "evermind", "ancien": ancienne.to_string_lossy() }));
    m.tic();
    assert!(m.message("evermind").ends_with("est un dossier de travail : elle est gardée telle quelle."));
    assert!(ancienne.join("Evermind.exe").exists());
}

#[test]
fn donnees_deplacees_d_un_disque_a_l_autre() {
    // (l'ancien dossier de données sur D:, la suite sous le dossier temporaire, sur C:)
    let autre = PathBuf::from(r"D:\Outils\Rust\essais\installations").join(format!("donnees-{}", std::process::id()));
    if !Path::new(r"D:\").exists() {
        return;
    }
    let mut m = Monde::nouveau("flux-donnees");
    let mut a = evermind(&m.faux.racine);
    a.donnees = autre.to_string_lossy().into_owned();
    m.ctx.definir_applis(vec![a]);
    std::fs::create_dir_all(autre.join("sous")).unwrap();
    std::fs::write(autre.join("reglages.json"), "{}").unwrap();
    std::fs::write(autre.join(r"sous\journal.txt"), "ligne").unwrap();
    preparer_installation(&m, "2.5.0");
    m.publier_version("evermind", "2.5.0");
    m.signal("installer", json!({ "id": "evermind" }));
    m.tic();
    let dest = m.ctx.dossiers.donnees_suite.join("Evermind");
    assert_eq!(
        m.message("evermind"),
        format!("Evermind 2.5.0 est installé. Ses données sont maintenant dans {}.", dest.display())
    );
    assert!(dest.join(r"sous\journal.txt").exists());
    assert!(!autre.exists(), "l'ancien dossier est supprimé");
    let _ = std::fs::remove_dir_all(&autre);
}

#[test]
fn donnees_sur_le_meme_disque_pas_deplacees() {
    let mut m = Monde::nouveau("flux-meme-disque");
    let anciennes = m.faux.racine.join(r"Anciennes\Evermind");
    std::fs::create_dir_all(&anciennes).unwrap();
    preparer_installation(&m, "2.5.0");
    m.publier_version("evermind", "2.5.0");
    m.signal("installer", json!({ "id": "evermind" }));
    m.tic();
    assert_eq!(m.message("evermind"), "Evermind 2.5.0 est installé.");
    assert!(anciennes.exists(), "même disque : l'appli renomme elle-même");
}

#[test]
fn desinstallation_par_le_mini_installateur() {
    let mut m = Monde::nouveau("flux-desinstallation");
    poser_evermind(&m.gere("Evermind"), "2.5.0");
    let donnees = m.ctx.dossiers.donnees_suite.join("Evermind");
    std::fs::create_dir_all(&donnees).unwrap();
    std::fs::write(donnees.join("reglages.json"), "{}").unwrap();
    m.ctx.ecrire_reglage("Demarrage", json!(["evermind"]));
    m.tic();
    preparer_installation(&m, "2.5.0");
    m.signal("desinstaller", json!({ "id": "evermind" }));
    assert_eq!(m.faux.installateur.deposees()[0]["Action"], "supprimer");
    m.tic();
    assert_eq!(
        m.message("evermind"),
        format!(
            "Evermind est désinstallé. Ses données sont gardées dans {} : une réinstallation les retrouve.",
            donnees.display()
        )
    );
    assert!(mindset_noyau::partage::installation(&m.ctx, "evermind").is_none());
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!([])));
    assert_eq!(m.finies()[0]["quoi"], "desinstallation");
    assert_eq!(m.finies()[0]["ok"], true);
}

#[test]
fn une_copie_non_geree_n_est_jamais_desinstallee() {
    let mut m = Monde::nouveau("flux-pas-geree");
    let d = m.faux.racine.join(r"Travail\Evermind");
    poser_evermind(&d, "2.5.0");
    mindset_installations::installations::enregistrer(&m.ctx, "evermind", Some(&d.to_string_lossy()), false);
    m.tic();
    m.signal("desinstaller", json!({ "id": "evermind" }));
    assert!(m.faux.installateur.deposees().is_empty());
    assert!(d.join("Evermind.exe").exists());
}

#[test]
fn desinstallation_par_son_desinstalleur() {
    let mut m = Monde::nouveau("flux-desinstalleur");
    let g = m.gere("Nevermind");
    poser_nevermind(&g, "2.0.1");
    let aide = m.faux.racine.join(r"Anciennes\Nevermind\outils");
    std::fs::create_dir_all(&aide).unwrap();
    m.faux.systeme.ajouter_processus(900, &aide.join("Mindset.exe").to_string_lossy(), 1);
    m.tic();
    m.signal("desinstaller", json!({ "id": "nevermind" }));
    assert_eq!(m.faux.systeme.arretes(), vec![900], "son programme d'aide (dans ses données) est fermé d'abord");
    let l = m.faux.systeme.lances();
    assert!(l[0].exe.ends_with("Désinstaller Nevermind.exe"));
    assert!(l[0].arguments.is_empty(), "sans option : c'est lui qui demande pour les données");
    assert_eq!(m.occupation("nevermind").as_deref(), Some("Désinstallation (suis les étapes de son désinstalleur)..."));
    m.avancer(5);
    m.tic();
    assert!(m.occupation("nevermind").is_some());
    std::fs::remove_dir_all(&g).unwrap();
    m.tic();
    assert_eq!(m.message("nevermind"), "Nevermind est désinstallé, avec ses données (réglages, journal, sauvegarde).");
}

#[test]
fn desinstalleur_qui_ne_finit_pas() {
    let mut m = Monde::nouveau("flux-desinstalleur-long");
    poser_nevermind(&m.gere("Nevermind"), "2.0.1");
    m.tic();
    m.signal("desinstaller", json!({ "id": "nevermind" }));
    m.avancer(601);
    m.tic();
    assert_eq!(m.message("nevermind"), "Désinstallation annulée ou pas terminée.");
    let mut m2 = Monde::nouveau("flux-desinstalleur-refuse");
    poser_nevermind(&m2.gere("Nevermind"), "2.0.1");
    m2.tic();
    m2.faux.systeme.refuser_lancement(Some("refusé"));
    m2.signal("desinstaller", json!({ "id": "nevermind" }));
    assert_eq!(m2.message("nevermind"), "Désinstallation annulée.");
}

#[test]
fn mise_a_jour_automatique_ratee() {
    let mut m = Monde::nouveau("flux-maj-auto");
    poser_evermind(&m.gere("Evermind"), "2.4.0");
    m.tic();
    let z = zip_evermind("2.5.0");
    m.faux.reseau.repondre(SIG, Ok(ReponseHttp::ok(signer(&z))));
    m.faux.reseau.repondre(ZIP, Ok(ReponseHttp::ok(z)));
    m.publier_version("evermind", "2.5.0");
    m.signal("installer", json!({ "id": "evermind", "auto": true }));
    assert_eq!(m.faux.installateur.deposees().len(), 1);
    let occ = m.ctx.lu("occupations").unwrap();
    assert_eq!(occ["evermind"]["auto"], true);
    m.avancer(31);
    m.tic();
    assert_eq!(
        m.message("evermind"),
        "La mise à jour automatique n'a pas pu se faire : L'outil d'installation de Mindset n'a pas répondu. Clique sur « Mettre à jour » pour réessayer."
    );
    assert!(m.faux.installateur.directs().is_empty(), "jamais de demande de Windows pour la mise à jour automatique");
    let f = m.finies();
    assert_eq!(f[0]["auto"], true);
    assert_eq!(f[0]["ok"], false);
    assert!(f[0]["message"].as_str().unwrap().contains("ne répond pas"));
    assert!(m.faux.systeme.lances().is_empty(), "une appli fermée par l'utilisateur reste fermée");
}

#[test]
fn installation_par_la_demande_de_windows() {
    let mut m = Monde::nouveau("flux-direct");
    m.faux.installateur.poser_etat(EtatTache::Absente);
    let z = zip_evermind("2.5.0");
    m.faux.reseau.repondre(SIG, Ok(ReponseHttp::ok(signer(&z))));
    m.faux.reseau.repondre(ZIP, Ok(ReponseHttp::ok(z)));
    m.publier_version("evermind", "2.5.0");
    m.signal("installer", json!({ "id": "evermind" }));
    assert_eq!(m.occupation("evermind").as_deref(), Some("Installation (accepte la demande de Windows)..."));
    let d = m.faux.installateur.directs();
    assert_eq!(d.len(), 1);
    assert_eq!(d[0].action, "appli");
    poser_evermind(&m.gere("Evermind"), "2.5.0");
    m.faux.installateur.finir_direct(0, true, &m.gere("Evermind").to_string_lossy());
    m.tic();
    assert_eq!(m.message("evermind"), "Evermind 2.5.0 est installé.");
    assert!(!d[0].resultat.exists(), "le fichier de réponse est effacé");
}

#[test]
fn ouvrir_une_appli() {
    let mut m = Monde::nouveau("flux-ouvrir");
    poser_nevermind(&m.gere("Nevermind"), "2.0.1");
    m.tic();
    m.signal("lancer-appli", json!({ "id": "nevermind", "demarrage": false }));
    let l = m.faux.systeme.lances();
    assert!(l[0].exe.ends_with(r"Nevermind\Mindset.exe"), "l'hôte Mindset.exe d'une appli récente");
    assert!(!l[0].sans_droits);
    // Ouverte : réveillée par son fichier (dans ses données)
    m.faux.systeme.poser_verrou(r"Local\NevermindEssai-Instance", true);
    let anciennes = m.faux.racine.join(r"Anciennes\Nevermind");
    m.signal("lancer-appli", json!({ "id": "nevermind" }));
    assert_eq!(std::fs::read_to_string(anciennes.join("afficher.demande")).unwrap(), "4242");
    assert_eq!(m.faux.systeme.lances().len(), 1);
    // Au démarrage et déjà ouverte : rien
    m.signal("lancer-appli", json!({ "id": "nevermind", "demarrage": true }));
    assert_eq!(m.faux.systeme.lances().len(), 1);
    // Evermind ouverte : son signal
    poser_evermind(&m.gere("Evermind"), "2.5.0");
    m.avancer(3);
    m.tic();
    m.faux.systeme.poser_signal(r"Local\EvermindEssai-Afficher");
    m.faux.systeme.poser_verrou(r"Local\EvermindEssai-Instance", true);
    m.signal("lancer-appli", json!({ "id": "evermind" }));
    assert_eq!(m.faux.systeme.signaux_leves(), vec![r"Local\EvermindEssai-Afficher"]);
}

#[test]
fn mindset_administrateur_lance_sans_les_droits() {
    let mut m = Monde::avec("flux-admin-lance", Lancement { admin: true, ..Default::default() });
    poser_evermind(&m.gere("Evermind"), "2.5.0");
    poser_nevermind(&m.gere("Nevermind"), "1.14.0");
    m.tic();
    m.signal("lancer-appli", json!({ "id": "evermind" }));
    m.signal("lancer-appli", json!({ "id": "nevermind" }));
    let l = m.faux.systeme.lances();
    assert!(l[0].sans_droits, "Evermind : avec les droits de l'utilisateur");
    assert!(!l[1].sans_droits, "Nevermind d'avant 1.15 installé par Mindset : il hérite des droits");
}

#[test]
fn raccourci_du_menu_demarrer() {
    let mut m = Monde::nouveau("flux-raccourci");
    let g = m.gere("Nevermind");
    poser_nevermind(&g, "2.0.1");
    m.tic();
    m.bloc.maj_raccourcis(&m.ctx);
    let lien = m.poste.lieu(r"Menu\Mindset\Nevermind.lnk");
    let r = m.poste.lire_raccourci(&lien).unwrap();
    let hote = g.join("Mindset.exe").to_string_lossy().into_owned();
    assert_eq!(r.cible, hote);
    assert_eq!(r.icone, format!("{hote},0"));
    assert_eq!(r.identite, "JordanJacquot.Nevermind");
    assert_eq!(m.poste.ecrits().len(), 1);
    m.bloc.maj_raccourcis(&m.ctx);
    assert_eq!(m.poste.ecrits().len(), 1, "déjà juste : pas réécrit");
    m.poste.poser_raccourci(&lien, &hote, &format!("{hote},0"), "");
    m.bloc.maj_raccourcis(&m.ctx);
    assert_eq!(m.poste.ecrits().len(), 2, "sans identité : remplacé");
    // Le même programme écrit sous son nom court de Windows (8.3), pour la cible comme pour l'icône : déjà juste
    let long = g.to_string_lossy().into_owned();
    let court = format!(r"{}\NEVERM~1", suite_commun::chemins::parent(&long));
    m.poste.poser_nom_court(&court, &long);
    let hote_court = format!(r"{court}\Mindset.exe");
    m.poste.poser_raccourci(&lien, &hote_court, &format!("{},0", hote.to_uppercase()), "JordanJacquot.Nevermind");
    m.bloc.maj_raccourcis(&m.ctx);
    assert_eq!(m.poste.ecrits().len(), 2, "cible courte, icône longue : le même programme, pas réécrit");
    m.poste.poser_raccourci(&lien, &hote, &format!("{hote_court},0"), "JordanJacquot.Nevermind");
    m.bloc.maj_raccourcis(&m.ctx);
    assert_eq!(m.poste.ecrits().len(), 2, "icône courte : pas réécrit");
    // (contre-épreuve : un autre dossier, ou une autre icône, est bien remplacé)
    m.poste.poser_raccourci(&lien, &format!(r"{court}X\Mindset.exe"), &format!("{hote},0"), "JordanJacquot.Nevermind");
    m.bloc.maj_raccourcis(&m.ctx);
    assert_eq!(m.poste.ecrits().len(), 3, "une autre cible : remplacé");
    m.poste.poser_raccourci(&lien, &hote, &format!("{hote_court},1"), "JordanJacquot.Nevermind");
    m.bloc.maj_raccourcis(&m.ctx);
    assert_eq!(m.poste.ecrits().len(), 4, "une autre image de l'icône : remplacé");
    // (ce raccourci n'est jamais pris pour un raccourci direct à retirer)
    let a = m.ctx.appli("nevermind").unwrap();
    assert_eq!(mindset_installations::copies::retirer_doublons(&m.ctx, &*m.poste, &a), None);
    assert!(lien.exists());
    // Evermind n'a pas d'hôte Mindset.exe : pas de raccourci
    poser_evermind(&m.gere("Evermind"), "2.5.0");
    m.bloc.maj_raccourcis(&m.ctx);
    assert!(!m.poste.lieu(r"Menu\Mindset\Evermind.lnk").exists());
    // Désinstallée : le raccourci part, et le dossier vide aussi
    std::fs::remove_dir_all(&g).unwrap();
    m.bloc.maj_raccourcis(&m.ctx);
    assert!(!lien.exists());
    assert!(!m.poste.lieu(r"Menu\Mindset").exists());
}

#[test]
fn utiliser_une_copie_trouvee() {
    let mut m = Monde::nouveau("flux-utiliser");
    let d = m.faux.racine.join(r"Ailleurs\Evermind");
    m.signal("utiliser-trouvee", json!({ "id": "evermind", "dossier": d.to_string_lossy() }));
    assert_eq!(m.message("evermind"), "Ce dossier ne contient pas Evermind.");
    poser_evermind(&d, "2.0.0");
    m.signal("utiliser-trouvee", json!({ "id": "evermind", "dossier": d.to_string_lossy() }));
    assert_eq!(
        m.message("evermind"),
        format!(
            "Mindset ouvrira la copie de {}. Elle se met à jour toute seule et garde son propre thème.",
            d.display()
        )
    );
    let i = mindset_noyau::partage::installation(&m.ctx, "evermind").unwrap();
    assert!(!i.gere);
}

#[test]
fn s_ouvre_avec_mindset() {
    let mut m = Monde::avec("flux-demarrage", Lancement { admin: true, ..Default::default() });
    m.poste.poser_tache(r"\Nevermind (démarrage)");
    m.signal("demarrage-appli", json!({ "id": "evermind", "oui": true }));
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!(["evermind"])));
    assert_eq!(m.ctx.lu("demarrages").unwrap()["evermind"], true);
    m.signal("demarrage-appli", json!({ "id": "nevermind", "oui": true }));
    assert_eq!(m.poste.taches_retirees(), vec![r"\Nevermind (démarrage)"], "administrateur : sa propre tâche part");
    m.signal("demarrage-appli", json!({ "id": "evermind", "oui": false }));
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!(["nevermind"])));
    m.signal("demarrage-appli", json!({ "id": "inconnue", "oui": true }));
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!(["nevermind"])));
}

#[test]
fn reprise_des_demarrages_une_seule_fois() {
    let mut m = Monde::nouveau("flux-reprise");
    poser_evermind(&m.gere("Evermind"), "2.5.0");
    m.tic();
    m.bloc.reparer_demarrages(&m.ctx);
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!(["evermind"])), "appli de rappels");
    assert_eq!(m.ctx.reglage("DemarrageRepris"), Some(json!(true)));
    m.ctx.ecrire_reglage("Demarrage", json!([]));
    m.bloc.reparer_demarrages(&m.ctx);
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!([])), "une seule fois : le choix de l'utilisateur reste");
}

#[test]
fn taches_de_demarrage_reprises_en_administrateur() {
    let mut m = Monde::avec("flux-taches-demarrage", Lancement { admin: true, ..Default::default() });
    poser_nevermind(&m.gere("Nevermind"), "2.0.1");
    m.tic();
    m.poste.poser_tache(r"\OptiGame (démarrage)");
    m.bloc.reprendre_taches_demarrage(&m.ctx);
    assert_eq!(m.ctx.reglage("Demarrage"), Some(json!(["nevermind"])));
    assert_eq!(m.poste.taches_retirees(), vec![r"\OptiGame (démarrage)"]);
}

#[test]
fn quitter_avec_les_applis() {
    let mut m = Monde::nouveau("flux-quitter");
    poser_evermind(&m.gere("Evermind"), "2.5.0");
    let donnees = m.ctx.dossiers.donnees_suite.join("Evermind");
    std::fs::create_dir_all(&donnees).unwrap();
    m.tic();
    m.faux.systeme.poser_verrou(r"Local\EvermindEssai-Instance", true);
    m.signal("quitter", json!({ "avec_applis": true, "relancer": false }));
    assert!(donnees.join("quitter.demande").exists());
    assert!(m.faux.donnees.lignes().iter().any(|l| l == "Fermeture de Evermind demandée (Mindset quitte)"));
    let hote = m.gere("Evermind").join("Evermind.exe");
    m.faux.systeme.ajouter_processus(777, &hote.to_string_lossy(), 1);
    m.bloc.fermer(&m.ctx);
    assert_eq!(m.faux.systeme.arretes(), vec![777]);
    assert!(m.faux.donnees.lignes().iter().any(|l| l == "Evermind ne répondait pas : fermé par Mindset"));
}

#[test]
fn demande_d_un_autre_bloc() {
    let mut m = Monde::nouveau("flux-admin-externe");
    m.signal(
        "admin-demande",
        json!({ "id": "0123456789abcdef0123456789abcdef", "action": "mindset-maj", "parametres": { "Zip": "x.zip", "Cache": "1", "Vide": "" }, "repli": false, "auto": true }),
    );
    let d = m.faux.installateur.deposees();
    assert_eq!(d[0]["Zip"], "x.zip");
    assert!(d[0].get("Vide").is_none());
    let id = d[0]["Id"].as_str().unwrap().to_string();
    // (l'accusé de réception de la tâche : la mise à jour de Mindset se ferme alors)
    m.faux.installateur.poser_valeur("Recu", &id);
    m.tic();
    let recu = m.signaux.iter().find(|(n, _)| n == "admin-recu").unwrap();
    assert_eq!(recu.1["id"], "0123456789abcdef0123456789abcdef", "le demandeur reconnaît son id");
    assert!(!m.signaux.iter().any(|(n, _)| n == "admin-fini"));
    m.faux.installateur.poser_valeur("Resultat", &json!({ "id": id, "ok": true, "message": "fait" }).to_string());
    m.tic();
    let fini = m.signaux.iter().find(|(n, _)| n == "admin-fini").unwrap();
    assert_eq!(fini.1["ok"], true);
    assert_eq!(fini.1["message"], "fait");
    assert_eq!(fini.1["sans_tache"], false);
    assert_eq!(m.signaux.iter().filter(|(n, _)| n == "admin-recu").count(), 1, "un seul accusé de réception");
    assert_eq!(m.ctx.lu("admin").unwrap()["tache"], "systeme");
}

#[test]
fn demande_d_un_autre_bloc_sans_tache() {
    // (intégration : le bloc « lui-même » lit `admin-fini.sans_tache` pour le repli d'une mise à jour automatique)
    let mut m = Monde::nouveau("flux-admin-sans-tache");
    m.signal(
        "admin-demande",
        json!({ "id": "0123456789abcdef0123456789abcdef", "action": "mindset-maj", "parametres": { "Zip": "x.zip" }, "repli": false, "auto": true }),
    );
    assert_eq!(m.faux.installateur.deposees().len(), 1);
    // (la tâche ne donne pas son accusé de réception en 30 s : pas de demande de Windows pour une mise à jour
    // automatique, la fin dit « sans tâche »)
    m.ctx.avancer(Duration::from_secs(31));
    m.tic();
    assert!(m.faux.installateur.directs().is_empty());
    let fini = m.signaux.iter().find(|(n, _)| n == "admin-fini").unwrap();
    assert_eq!(fini.1["ok"], false);
    assert_eq!(fini.1["sans_tache"], true, "{}", fini.1);
    assert!(fini.1["message"].as_str().unwrap().starts_with("la tâche d'installation ne répond pas"));
}

#[test]
fn remise_en_ordre_des_taches() {
    let mut m = Monde::nouveau("flux-remise");
    m.faux.installateur.repondre(|d| (d["Action"] == "taches").then(|| (true, String::new())));
    m.tic();
    assert!(m.faux.installateur.deposees().is_empty(), "déjà refaites pour cette version");
    // (une nouvelle version de Mindset : refaites une fois)
    m.ctx.ecrire_reglage("TachesRefaitesPour", json!("2.18.0"));
    let mut e = Effets::default();
    m.bloc.mini_installateur_au_demarrage(&m.ctx, &mut e);
    m.pomper(e);
    assert_eq!(m.faux.installateur.deposees()[0]["Action"], "taches");
    m.tic();
    assert_eq!(m.ctx.reglage("TachesRefaitesPour"), Some(json!("3.0.0")));
    let mut e = Effets::default();
    m.bloc.mini_installateur_au_demarrage(&m.ctx, &mut e);
    assert_eq!(m.faux.installateur.deposees().len(), 1);
    // (la très vieille tâche « \Mindset\Mindset » est encore là : refaites quand même)
    m.faux.installateur.poser_tache("Mindset", "S-1-5-21-1111-2222-3333-1001");
    let mut e = Effets::default();
    m.bloc.mini_installateur_au_demarrage(&m.ctx, &mut e);
    assert_eq!(m.faux.installateur.deposees().len(), 2);
}

#[test]
fn remplacement_de_l_ancienne_tache() {
    let mut m = Monde::nouveau("flux-remplacement");
    m.faux.installateur.poser_etat(EtatTache::Ancienne);
    let fi = m.faux.installateur.clone();
    m.faux.installateur.repondre(move |d| {
        if d["Action"] == "taches" {
            fi.poser_etat(EtatTache::Systeme);
            Some((true, String::new()))
        } else {
            None
        }
    });
    // (au premier tic : l'ancienne tâche sert une dernière fois, à se remplacer)
    m.tic();
    assert_eq!(m.faux.installateur.deposees()[0]["Action"], "taches");
    assert_eq!(m.ctx.lu("admin").unwrap()["remplacement"], "ok");
    assert_eq!(m.ctx.lu("admin").unwrap()["tache"], "systeme");
    // (l'ancienne tâche ne sert jamais à installer)
    let mut m2 = Monde::nouveau("flux-ancienne-jamais");
    m2.faux.installateur.poser_etat(EtatTache::Ancienne);
    m2.signal("admin-demande", json!({ "id": "abcdabcdabcdabcd", "action": "appli", "parametres": {} }));
    assert!(m2.faux.installateur.deposees().is_empty());
    assert_eq!(m2.faux.installateur.directs().len(), 1);
}

#[test]
fn rythme_des_tics() {
    let mut m = Monde::nouveau("flux-rythme");
    assert_eq!(m.tic(), Some(Duration::from_secs(30)), "Mindset caché : toutes les 30 s");
    m.ctx.definir_vue(mindset_noyau::Vue { visible: true, reduite: false, page: "accueil".into() });
    assert_eq!(m.tic(), Some(Duration::from_secs(2)));
    m.faux.installateur.poser_etat(EtatTache::Systeme);
    m.signal("admin-demande", json!({ "id": "abcdabcdabcdabcd", "action": "appli", "parametres": {} }));
    assert_eq!(m.tic(), Some(Duration::from_millis(500)), "une demande en cours : toutes les 500 ms");
}

#[test]
fn le_bloc_de_l_hote_n_a_pas_de_poste_en_essai() {
    // (la construction d'essai de Mindset : aucun raccourci, aucune entrée Run, rien n'est écrit)
    let (ctx, faux) = mindset_noyau::essai::contexte("flux-hote");
    ctx.definir_applis(vec![evermind(&faux.racine)]);
    let mut b = mindset_installations::BlocInstallations::default();
    let mut e = Effets::default();
    ctx.au_nom_de("installations", || b.demarrer(&ctx, &mut e));
    ctx.au_nom_de("installations", || b.tic(&ctx, &mut e));
    assert!(faux.installateur.deposees().is_empty(), "en essai, rien au démarrage (comme $EnTest)");
    let _ = std::fs::remove_dir_all(&faux.racine);
}
