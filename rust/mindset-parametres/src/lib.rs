//! Mindset en Rust, bloc « paramètres » : les panneaux des Paramètres, les thèmes de la suite et les packs
//! (`modules\parametres.ps1`, `modules\themes.ps1`, `modules\packs.ps1`, et `Watch-ThemeSuite` d'accueil.ps1).
//!
//! Ce que fait le bloc :
//! - au démarrage, le thème de la suite (suite.json) : la table des couleurs Néon traduites (`theme` dans le tableau
//!   commun, pour la page et la console), la couleur de la barre de titre, le dossier du pack servi par
//!   `http://pack.localhost/` ; les thèmes supprimés ou mis à jour qui attendaient (`Clear-PacksARetirer`) ;
//! - l'état `parametres` (`Get-EtatParametres`, tel quel, plus l'onglet et ce que la page d'avant montrait en plus)
//!   et `admin_bandeau` (le bandeau « Installer sans demande de Windows ») ;
//! - les gestes des Paramètres (`parametres:reglage`, les mêmes « quoi » que `Invoke-ReglageConsole` : la page des
//!   Paramètres et l'écran de la console), l'onglet (`parametres:onglet`), l'activation du mini-installateur
//!   (`parametres:activer-admin`), la suppression confirmée d'un thème (`parametres:supprimer-theme`) ;
//! - l'import d'un thème (.zip), le choix d'un thème (suite.json puis Mindset se relance), la suppression ;
//! - la consommation de la suite, mesurée toutes les 2 secondes seulement quand l'onglet est à l'écran ;
//! - un thème changé ailleurs (suite.json) : Mindset se relance (pas deux fois en une minute) ;
//! - une page demandée par une appli (afficher-page.txt : `appli:<id>`, `menu`, `parametres[:onglet]`).
//!
//! Le dessin des panneaux (HTML) est dans `page/` (parametres.css, parametres.js) : il lit l'état `parametres` et
//! envoie les gestes ; il est à brancher dans la page de mindset-appli (`ui/`) à l'intégration.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value, json};
use suite_commun::protocole_installateur::{texte_ps, vrai_ps};

use mindset_noyau::signaux;
use mindset_noyau::{Bloc, Contexte, Effet, Effets, Fenetre, appli, partage};

pub mod conso;
pub mod packs;
pub mod plateforme;
pub mod textes;
pub mod theme;
#[cfg(windows)]
pub mod windows;

use plateforme::{Fausse, Plateforme};
use theme::{Carte, ThemeCourant};

/// Les onglets des Paramètres, dans l'ordre (`$OngletsParametres`).
pub const ONGLETS: [(&str, &str); 6] = [
    ("general", "Général"),
    ("apparence", "Apparence"),
    ("son", "Son"),
    ("maj", "Mises à jour"),
    ("conso", "Consommation"),
    ("dossiers", "Dossiers"),
];

/// `$TexteVersionsEssai`
pub const TEXTE_VERSIONS_ESSAI: &str = "Tu reçois aussi ses versions d'essai, avant tout le monde. Décoché, tu gardes ta version jusqu'à la prochaine version normale.";

const OCCUPE: &str = "Une installation est en cours : réessaie quand elle sera finie.";
const TEXTE_ADMIN: &str = "Mindset crée son mini-installateur : les installations et les mises à jour (seulement des fichiers signés) ne demanderont plus l'autorisation. Une dernière demande de Windows.";

/// Le bandeau « Installer sans demande de Windows » (AdminBandeau).
#[derive(Debug, Clone, PartialEq)]
struct Bandeau {
    visible: bool,
    texte: String,
    bouton_actif: bool,
}

/// Une demande en administrateur en cours (son id, et pourquoi).
#[derive(Debug, Clone, PartialEq)]
enum Demande {
    /// `Enable-MindsetAdmin`
    Activer,
}

/// Le bloc « paramètres ».
pub struct Parametres {
    plateforme: Option<Arc<dyn Plateforme>>,
    /// Les tests le mettent à vrai : ce qui ne se fait jamais en test dans la version PowerShell (relance, bandeau,
    /// tâches) se fait quand même, avec les faux ports.
    comme_en_vrai: bool,
    theme: Option<ThemeCourant>,
    onglet: String,
    theme_info: String,
    maj_info: String,
    cartes: Option<Vec<Carte>>,
    exposees: Vec<(String, PathBuf)>,
    appareils: Option<(Vec<String>, Vec<String>)>,
    conso: Option<Value>,
    conso_actif: bool,
    conso_premiere: bool,
    conso_en_cours: bool,
    conso_notee: bool,
    conso_a: Duration,
    premier_tic: bool,
    surveiller_a: Duration,
    boucle_notee: bool,
    a_retirer_a: Option<Duration>,
    relire_a: Option<Duration>,
    bandeau: Bandeau,
    demandes: Vec<(String, Demande)>,
    import_en_cours: bool,
    compteur: u32,
}

impl Parametres {
    /// Un bloc neuf (il lit tout à son démarrage).
    pub const NEUF: Parametres = Parametres {
        plateforme: None,
        comme_en_vrai: false,
        theme: None,
        onglet: String::new(),
        theme_info: String::new(),
        maj_info: String::new(),
        cartes: None,
        exposees: Vec::new(),
        appareils: None,
        conso: None,
        conso_actif: false,
        conso_premiere: true,
        conso_en_cours: false,
        conso_notee: false,
        conso_a: Duration::ZERO,
        premier_tic: true,
        surveiller_a: Duration::ZERO,
        boucle_notee: false,
        a_retirer_a: None,
        relire_a: None,
        bandeau: Bandeau { visible: false, texte: String::new(), bouton_actif: true },
        demandes: Vec::new(),
        import_en_cours: false,
        compteur: 0,
    };

    /// Pour les tests : un Windows donné (un faux), et ce qui ne se fait pas en test fait quand même.
    pub fn avec_plateforme(p: Arc<dyn Plateforme>, comme_en_vrai: bool) -> Parametres {
        Parametres { plateforme: Some(p), comme_en_vrai, ..Parametres::NEUF }
    }

    fn en_test(&self, ctx: &Contexte) -> bool {
        ctx.essai && !self.comme_en_vrai
    }

    fn plateforme(&mut self, ctx: &Contexte) -> Arc<dyn Plateforme> {
        if self.plateforme.is_none() {
            let p: Arc<dyn Plateforme> = if ctx.essai {
                Arc::new(Fausse::depuis_fichier(&ctx.dossiers.donnees.join("essai-parametres.json")))
            } else {
                vraie_plateforme()
            };
            self.plateforme = Some(p);
        }
        Arc::clone(self.plateforme.as_ref().expect("plateforme posée juste avant"))
    }

    fn dossier_packs(ctx: &Contexte) -> PathBuf {
        ctx.dossiers.donnees.join("packs")
    }

    fn reglage_theme(&self) -> String {
        self.theme.as_ref().map(|t| t.reglage.clone()).unwrap_or_else(|| "neon".into())
    }

    fn traduire(&self, hex: &str) -> String {
        match &self.theme {
            Some(t) => t.traduire(hex),
            None => hex.to_string(),
        }
    }

    fn nouvel_id(&mut self, ctx: &Contexte) -> String {
        self.compteur = self.compteur.wrapping_add(1);
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let a =
            (t as u64) ^ (u64::from(ctx.pid()) << 32) ^ u64::from(self.compteur).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        let b = a.rotate_left(29).wrapping_mul(0xBF58_476D_1CE4_E5B9) ^ u64::from(self.compteur);
        format!("{a:016x}{b:016x}")
    }

    // -----------------------------------------------------------------------------------------------------------
    // Les packs et les cartes des thèmes
    // -----------------------------------------------------------------------------------------------------------

    fn avec_packs<R>(ctx: &Contexte, f: impl FnOnce(&packs::Packs) -> R) -> R {
        let j = |t: &str| ctx.journal(t);
        let p = packs::Packs {
            packs: Self::dossier_packs(ctx),
            suite: ctx.dossiers.donnees_suite.clone(),
            donnees: ctx.dossiers.donnees.clone(),
            applis: ctx.applis().iter().map(|a| (a.nom.clone(), a.id.clone())).collect(),
            journal: &j,
        };
        f(&p)
    }

    /// `Update-ChoixThemes` / `Get-ThemesConsole` : les cartes refaites, et leurs images servies à la page.
    fn refaire_cartes(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let a_retirer = Self::avec_packs(ctx, |p| p.a_retirer());
        let cartes = theme::cartes(&Self::dossier_packs(ctx), &a_retirer, &|t| ctx.journal(t));
        let voulues: Vec<(String, PathBuf)> =
            cartes.iter().filter_map(|c| c.vignette.as_ref().map(|v| (v.nom.clone(), v.chemin.clone()))).collect();
        for (nom, _) in self.exposees.iter().filter(|e| !voulues.iter().any(|v| v.0 == e.0)) {
            effets.ajouter(Effet::Exposer { nom: nom.clone(), chemin: None });
        }
        for v in voulues.iter().filter(|v| !self.exposees.contains(v)) {
            effets.ajouter(Effet::Exposer { nom: v.0.clone(), chemin: Some(v.1.clone()) });
        }
        self.exposees = voulues;
        self.cartes = Some(cartes);
    }

    fn cartes(&self) -> &[Carte] {
        self.cartes.as_deref().unwrap_or(&[])
    }

    /// `Select-ThemeSuite` : suite.json, puis Mindset se relance.
    fn choisir_theme(&mut self, ctx: &Contexte, cle: &str, effets: &mut Effets) {
        if cle.is_empty() || packs::egal(cle, &self.reglage_theme()) {
            return;
        }
        if partage::une_occupation(ctx) {
            self.theme_info = OCCUPE.into();
            return;
        }
        ctx.donnees().ecrire_theme_suite(cle);
        if self.en_test(ctx) {
            self.theme_info = format!("Thème « {cle} » choisi (test : pas de relance).");
            return;
        }
        effets.ajouter(Effet::Relancer);
    }

    /// `Import-ThemeSuite` : la fenêtre de Windows puis l'import, dans un travail de fond (la fenêtre attend
    /// l'utilisateur).
    fn importer(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if self.import_en_cours {
            return;
        }
        self.import_en_cours = true;
        let p = self.plateforme(ctx);
        let parent = ctx.fenetre_principale();
        let donnees = ctx.donnees();
        let packs_d = Self::dossier_packs(ctx);
        let suite = ctx.dossiers.donnees_suite.clone();
        let mindset = ctx.dossiers.donnees.clone();
        let applis: Vec<(String, String)> = ctx.applis().iter().map(|a| (a.nom.clone(), a.id.clone())).collect();
        effets.tache("importer", move || {
            let initial =
                [Some(PathBuf::from(r"D:\Projets\Thème-Mindset")), p.bureau().map(|b| b.join("Thème-Mindset"))]
                    .into_iter()
                    .flatten()
                    .find(|d| d.exists());
            let Some(zip) = p.choisir_zip(parent, initial) else { return Ok(json!({ "annule": true })) };
            let j = |t: &str| donnees.journal(t);
            let pk = packs::Packs { packs: packs_d, suite, donnees: mindset, applis, journal: &j };
            Ok(match pk.importer(&zip) {
                Ok(i) => json!({ "id": i.id, "remplace": i.remplace, "attente": i.attente }),
                Err(e) => json!({ "erreur": e }),
            })
        });
    }

    fn import_fini(&mut self, ctx: &Contexte, r: Result<Value, String>, effets: &mut Effets) {
        self.import_en_cours = false;
        let r = match r {
            Ok(v) => v,
            Err(e) => json!({ "erreur": e }),
        };
        if r.get("annule").is_some() {
            return;
        }
        if let Some(e) = r.get("erreur").and_then(Value::as_str) {
            self.theme_info = format!("Ce thème n'a pas pu être importé : {e}");
            effets.ajouter(Effet::Rafraichir);
            return;
        }
        let id = r.get("id").and_then(Value::as_str).unwrap_or_default().to_string();
        self.refaire_cartes(ctx, effets);
        let nom = theme::pack(&id, &Self::dossier_packs(ctx), &|t| ctx.journal(t))
            .map(|t| t.nom)
            .unwrap_or_else(|| id.clone());
        let remplace = r.get("remplace").and_then(Value::as_bool).unwrap_or(false);
        let attente: Vec<String> = r
            .get("attente")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        let actuel = ctx.donnees().suite().theme.is_some_and(|t| packs::egal(&t, &format!("pack:{id}")));
        self.theme_info = if !remplace {
            format!("Thème « {nom} » ajouté pour Mindset et toutes ses applis : clique dessus pour le choisir.")
        } else if actuel {
            format!(
                "Thème « {nom} » mis à jour : la nouvelle version remplace l'ancienne. C'est le thème actuel : Mindset et les applis ouvertes la prendront à leur prochaine ouverture."
            )
        } else {
            format!("Thème « {nom} » mis à jour : la nouvelle version remplace l'ancienne.")
        };
        if !attente.is_empty() {
            self.theme_info = format!(
                "Thème « {nom} » mis à jour. {} s'en {} en ce moment : la nouvelle version sera prise au prochain démarrage de Mindset.",
                attente.join(" et "),
                if attente.len() > 1 { "servent" } else { "sert" }
            );
        }
        effets.ajouter(Effet::Rafraichir);
    }

    /// `Confirm-SuppressionTheme` : la question, puis `parametres:supprimer-theme`.
    fn confirmer_suppression(&mut self, ctx: &Contexte, id: &str, effets: &mut Effets) {
        let a_retirer = Self::avec_packs(ctx, |p| p.a_retirer());
        let Some(pk) = theme::packs_installes(&Self::dossier_packs(ctx), &a_retirer, &|t| ctx.journal(t))
            .into_iter()
            .find(|t| t.pack.as_ref().is_some_and(|p| p.id == id))
        else {
            return;
        };
        let actuel = ctx.donnees().suite().theme.is_some_and(|t| packs::egal(&t, &format!("pack:{id}")));
        let mut texte = "Il sera retiré de Mindset et de toutes les applis.".to_string();
        if actuel {
            texte.push_str(
                " C'est le thème actuel : la suite repasse d'abord sur le thème Néon, et Mindset se relance.",
            );
        }
        effets.ajouter(signaux::confirmation(
            &format!("Supprimer le thème « {} » ?", pk.nom),
            &texte,
            "Supprimer",
            "parametres:supprimer-theme",
            json!(id),
        ));
    }

    /// `Remove-ThemeSuite`
    fn supprimer_theme(&mut self, ctx: &Contexte, id: &str, effets: &mut Effets) {
        let a_retirer = Self::avec_packs(ctx, |p| p.a_retirer());
        let Some(pk) = theme::packs_installes(&Self::dossier_packs(ctx), &a_retirer, &|t| ctx.journal(t))
            .into_iter()
            .find(|t| t.pack.as_ref().is_some_and(|p| p.id == id))
        else {
            return;
        };
        if partage::une_occupation(ctx) {
            self.theme_info = OCCUPE.into();
            return;
        }
        let actuel = ctx.donnees().suite().theme.is_some_and(|t| packs::egal(&t, &format!("pack:{id}")));
        if actuel {
            ctx.donnees().ecrire_theme_suite("neon");
        }
        let ok = Self::avec_packs(ctx, |p| p.supprimer(id));
        self.refaire_cartes(ctx, effets);
        self.theme_info = format!("Thème « {} » supprimé de Mindset et de toutes les applis.", pk.nom);
        if actuel {
            self.theme_info.push_str(" La suite repasse sur le thème Néon.");
        }
        if !ok {
            self.theme_info.push_str(
                " Une appli ouverte s'en sert encore : il finira d'être retiré au prochain démarrage de Mindset.",
            );
        }
        if actuel && !self.en_test(ctx) {
            effets.ajouter(Effet::Relancer);
            return;
        }
        effets.ajouter(Effet::Rafraichir);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Les onglets, le son, la consommation
    // -----------------------------------------------------------------------------------------------------------

    /// `Show-OngletParametres`
    fn montrer_onglet(&mut self, ctx: &Contexte, id: &str, effets: &mut Effets) {
        let id = id.to_lowercase();
        let id = if ONGLETS.iter().any(|(k, _)| *k == id) { id } else { "general".into() };
        self.poser_onglet(ctx, &id);
        match id.as_str() {
            "son" => self.relire_appareils(ctx),
            "apparence" => self.refaire_cartes(ctx, effets),
            "conso" => self.demarrer_conso(ctx, effets),
            _ => {}
        }
    }

    fn poser_onglet(&mut self, ctx: &Contexte, id: &str) {
        if self.onglet != id {
            self.onglet = id.to_string();
            ctx.publier(partage::ONGLET_PARAMETRES, json!(id));
        }
    }

    /// `Update-AppareilsConsole` / `Update-ChoixSon` : les micros et sorties du PC relus.
    fn relire_appareils(&mut self, ctx: &Contexte) {
        let p = self.plateforme(ctx);
        self.appareils = Some((p.micros(), p.sorties()));
    }

    /// `Start-ConsoSuite` : une première mesure tout de suite, puis toutes les 2 secondes.
    fn demarrer_conso(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if self.conso_actif {
            return;
        }
        self.conso_actif = true;
        self.conso_premiere = true;
        self.mesurer(ctx, effets);
    }

    fn mesurer(&mut self, ctx: &Contexte, effets: &mut Effets) {
        self.conso_a = ctx.ecoule() + Duration::from_secs(2);
        if self.conso_en_cours {
            return;
        }
        self.conso_en_cours = true;
        let p = self.plateforme(ctx);
        let d = conso::demande(ctx);
        effets.tache("conso", move || {
            let debut = std::time::Instant::now();
            let parties = p.mesurer(&d);
            let ms = debut.elapsed().as_millis() as u64;
            let l: Vec<Value> = parties
                .iter()
                .map(|x| json!({ "nom": x.nom, "nombre": x.nombre, "memoire": x.memoire, "processeur": x.processeur }))
                .collect();
            Ok(json!({ "parties": l, "ms": ms }))
        });
    }

    fn conso_finie(&mut self, ctx: &Contexte, r: Result<Value, String>) {
        self.conso_en_cours = false;
        let v = match r {
            Ok(v) => v,
            Err(e) => {
                ctx.journal(&format!("Consommation non mesurée : {e}"));
                return;
            }
        };
        let parties: Vec<plateforme::Partie> = v
            .get("parties")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .map(|p| plateforme::Partie {
                        nom: p.get("nom").and_then(Value::as_str).unwrap_or_default().to_string(),
                        nombre: p.get("nombre").and_then(Value::as_u64).unwrap_or(0) as u32,
                        memoire: p.get("memoire").and_then(Value::as_i64).unwrap_or(0),
                        processeur: p.get("processeur").and_then(Value::as_f64).unwrap_or(0.0),
                    })
                    .collect()
            })
            .unwrap_or_default();
        if !self.conso_notee {
            self.conso_notee = true;
            ctx.journal(&format!(
                "Consommation de la suite mesurée en {} ms",
                v.get("ms").and_then(Value::as_u64).unwrap_or(0)
            ));
        }
        let premiere = self.conso_premiere;
        self.conso_premiere = false;
        self.conso = Some(conso::etat(&parties, premiere));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Le mini-installateur (AdminBandeau)
    // -----------------------------------------------------------------------------------------------------------

    /// Le bandeau au démarrage. Le remplacement de l'ancienne tâche et la remise en ordre des tâches sont faits par le
    /// bloc « installations » lui-même (il publie `admin.tache` et `admin.remplacement`) : rien n'est demandé ici.
    fn decider_bandeau(&mut self, _ctx: &Contexte) {
        self.bandeau = Bandeau { visible: true, texte: TEXTE_ADMIN.into(), bouton_actif: true };
    }

    /// Le bandeau est-il là ? Mindset installé, pas en test, et le mini-installateur pas en place (`admin.tache`) ;
    /// l'ancienne tâche est remplacée sans demande de Windows : le bandeau ne vient que si ça n'a pas marché
    /// (`admin.remplacement` : « echec »). `visible` passe à faux une fois l'activation réussie.
    fn bandeau_visible(&self, ctx: &Contexte) -> bool {
        if !self.bandeau.visible || self.premier_tic || self.en_test(ctx) {
            return false;
        }
        let installe =
            ctx.lu(partage::MINDSET).and_then(|m| m.get("installe").and_then(Value::as_bool)).unwrap_or(false);
        let admin = ctx.lu(partage::ADMIN).unwrap_or(Value::Null);
        let tache = admin.get("tache").and_then(Value::as_str).unwrap_or("inconnue");
        let remplacement = admin.get("remplacement").and_then(Value::as_str).unwrap_or("");
        match tache {
            _ if !installe => false,
            "systeme" | "inconnue" => false,
            "ancienne" if !ctx.lancement.admin => remplacement == "echec",
            _ => true,
        }
    }

    /// `Enable-MindsetAdmin`
    fn activer_admin(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if !self.bandeau.bouton_actif {
            return;
        }
        self.bandeau.texte = "Activation (accepte la demande de Windows)...".into();
        self.bandeau.bouton_actif = false;
        let sid = self.plateforme(ctx).sid();
        let id = self.nouvel_id(ctx);
        self.demandes.push((id.clone(), Demande::Activer));
        let p = json!({ "Destination": ctx.dossiers.mindset_installe().to_string_lossy(), "Sid": sid });
        effets.ajouter(signaux::admin_demande(&id, "taches", p, true, false));
    }

    fn admin_fini(&mut self, ctx: &Contexte, d: &Value) {
        let id = d.get("id").and_then(Value::as_str).unwrap_or_default();
        let Some(i) = self.demandes.iter().position(|(x, _)| x == id) else { return };
        let (_, quoi) = self.demandes.remove(i);
        let ok = d.get("ok").is_some_and(vrai_ps);
        let message = d.get("message").map(texte_ps).unwrap_or_default();
        match quoi {
            Demande::Activer => {
                self.bandeau.bouton_actif = true;
                if !ok {
                    self.bandeau.texte = format!("Activation impossible : {message}");
                    return;
                }
                if !self.en_test(ctx) || self.comme_en_vrai {
                    self.plateforme(ctx).retirer_run();
                }
                ctx.journal("Mini-installateur activé (tâches planifiées)");
                self.bandeau.visible = false;
            }
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Une page demandée, le thème changé ailleurs
    // -----------------------------------------------------------------------------------------------------------

    /// `Open-PageDemandee` (afficher-page.txt)
    fn page_demandee(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let f = ctx.dossiers.page_demandee();
        if !f.exists() {
            return;
        }
        let t = std::fs::read(&f).map(|o| suite_commun::json_sur::texte_du_fichier(&o)).unwrap_or_default();
        let t = t.trim().to_string();
        let _ = std::fs::remove_file(&f);
        let bas = t.to_lowercase();
        if let Some(id) = bas.strip_prefix("appli:")
            && (1..=30).contains(&id.len())
            && id.bytes().all(|o| o.is_ascii_lowercase() || o.is_ascii_digit() || o == b'-')
            && let Some(a) = ctx.applis().iter().find(|a| packs::egal(&a.id, id))
        {
            effets.ajouter(Effet::Fenetre(Fenetre::Montrer));
            effets.ajouter(signaux::ouvrir_appli(&a.id, true));
            return;
        }
        if bas == "menu" {
            effets.ajouter(Effet::Fenetre(Fenetre::Montrer));
            effets.ajouter(Effet::Page("accueil".into()));
            return;
        }
        let onglet = match bas.strip_prefix("parametres") {
            Some("") => "general",
            Some(r) => match r.strip_prefix(':') {
                Some(o) if ONGLETS.iter().any(|(k, _)| *k == o) => o,
                _ => return,
            },
            None => return,
        };
        effets.ajouter(Effet::Fenetre(Fenetre::Montrer));
        self.montrer_onglet(ctx, onglet, effets);
        effets.ajouter(Effet::Page("parametres".into()));
    }

    /// `Watch-ThemeSuite` : le thème de la suite changé ailleurs, Mindset le prend aussi (pas deux relances pour le
    /// même thème en une minute).
    fn surveiller_theme(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let Some(t) = ctx.donnees().suite().theme.filter(|t| !t.is_empty()) else { return };
        if packs::egal(&t, &self.reglage_theme()) || partage::une_occupation(ctx) || self.en_test(ctx) {
            return;
        }
        let r = ctx.reglage("DerniereRelanceTheme");
        let meme = r.as_ref().and_then(|r| r.get("Theme")).map(texte_ps).is_some_and(|x| packs::egal(&x, &t));
        let quand = r.as_ref().and_then(|r| r.get("Quand")).map(texte_ps).and_then(|q| textes::lire_moment(&q));
        let recent = quand.is_some_and(|q| mindset_noyau::moment::ecart(&q, &ctx.heure()) < 60);
        if meme && recent {
            if !self.boucle_notee {
                ctx.journal(&format!(
                    "Thème de la suite {t} : déjà relancé il y a moins d'une minute, pas de nouvelle relance"
                ));
                self.boucle_notee = true;
            }
            return;
        }
        ctx.ecrire_reglage("DerniereRelanceTheme", json!({ "Theme": t, "Quand": ctx.heure_iso() }));
        ctx.journal(&format!("Thème de la suite changé ailleurs : {t}"));
        effets.ajouter(Effet::Relancer);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Les gestes (Invoke-ReglageConsole)
    // -----------------------------------------------------------------------------------------------------------

    /// Les applis dont on règle le démarrage (`Get-ApplisDemarrage`).
    fn applis_demarrage(ctx: &Contexte) -> Vec<mindset_noyau::Appli> {
        ctx.applis()
            .iter()
            .filter(|a| {
                let i = partage::installation(ctx, &a.id);
                i.is_some() && (!appli::appli_admin(a, i.as_ref()) || ctx.lancement.admin)
            })
            .cloned()
            .collect()
    }

    /// `Get-ApplisVersionsEssai` : les applis installées.
    fn applis_installees(ctx: &Contexte) -> Vec<mindset_noyau::Appli> {
        ctx.applis().iter().filter(|a| partage::installation(ctx, &a.id).is_some()).cloned().collect()
    }

    fn changer(ctx: &Contexte, nom: &str, valeur: Value, effets: &mut Effets) {
        ctx.ecrire_reglage(nom, valeur.clone());
        effets.signal(signaux::REGLAGE_CHANGE, json!({ "nom": nom, "valeur": valeur }));
    }

    /// `Invoke-ReglageConsole` : seulement des réglages connus, avec des valeurs vérifiées.
    pub fn reglage(&mut self, ctx: &Contexte, m: &Value, effets: &mut Effets) {
        let quoi = m.get("quoi").map(texte_ps).unwrap_or_default();
        let v = m.get("valeur").cloned().unwrap_or(Value::Null);
        let vb = vrai_ps(&v);
        let vt = texte_ps(&v);
        let mid = m.get("id").map(texte_ps).unwrap_or_default();
        match quoi.as_str() {
            "onglet" => {
                if let Some((k, _)) = ONGLETS.iter().find(|(k, _)| packs::egal(k, &vt)) {
                    self.poser_onglet(ctx, k);
                    if *k == "son" {
                        self.relire_appareils(ctx);
                    }
                }
            }
            "reduire" => Self::changer(ctx, "ReduireHorloge", json!(vb), effets),
            "fermeture" => {
                if ["demander", "reduire", "quitter"].iter().any(|x| packs::egal(x, &vt)) {
                    Self::changer(ctx, "Fermeture", json!(vt), effets);
                }
            }
            "windows" => Self::changer(ctx, "LancerAvecWindows", json!(vb), effets),
            "majauto" => {
                Self::changer(ctx, "MajAuto", json!(vb), effets);
                ctx.journal(&format!("Mises à jour automatiques : {}", if vb { "oui" } else { "non" }));
            }
            "verif" => {
                Self::changer(ctx, "VerifVersions", json!(vb), effets);
                ctx.journal(&format!("Chercher les nouvelles versions tout seul : {}", if vb { "oui" } else { "non" }));
            }
            "essai" => {
                if let Some(a) = Self::applis_installees(ctx).into_iter().find(|a| a.id == mid) {
                    effets.signal(signaux::VERSIONS_ESSAI, json!({ "id": a.id, "oui": vb }));
                }
            }
            "confidentialite" => effets.signal(signaux::CONFIDENTIALITE, json!({ "id": "" })),
            "demarrage" => {
                if let Some(a) = Self::applis_demarrage(ctx).into_iter().find(|a| packs::egal(&a.id, &mid)) {
                    effets.signal(signaux::DEMARRAGE_APPLI, json!({ "id": a.id, "oui": vb }));
                }
            }
            "theme" => {
                if self.cartes.is_none() {
                    self.refaire_cartes(ctx, effets);
                }
                if self.cartes().iter().any(|c| packs::egal(&c.cle, &vt)) {
                    self.choisir_theme(ctx, &vt, effets);
                }
            }
            "importer" => self.importer(ctx, effets),
            "supprimerTheme" => {
                if let Some(id) = vt.strip_prefix("pack:").filter(|id| packs::id_valable(id)) {
                    let id = id.to_string();
                    self.confirmer_suppression(ctx, &id, effets);
                }
            }
            "animations" => {
                if !["completes", "express", "aucune"].iter().any(|x| packs::egal(x, &vt)) {
                    return;
                }
                Self::changer(ctx, "Animations", json!(vt), effets);
                // Sans 3D, plus de console : la page des Paramètres prend le relais, sur Apparence
                if packs::egal(&vt, "aucune") {
                    self.montrer_onglet(ctx, "apparence", effets);
                    effets.ajouter(Effet::Page("parametres".into()));
                    return;
                }
            }
            "micro" | "casque" => ctx.donnees().ecrire_son_suite(&quoi, &vt),
            "sonActualiser" => self.relire_appareils(ctx),
            "verifier" => {
                effets.ajouter(signaux::actualiser(true));
                let h = ctx.heure();
                self.maj_info = format!("Vérifié à {:02}:{:02}", h.heure, h.minute);
                self.relire_a = Some(ctx.ecoule() + Duration::from_secs(4));
            }
            "majMindset" => effets.signal(signaux::MAJ_MINDSET, json!({ "confirmer": false })),
            "dossierProgrammes" => {
                let mut d = ctx.dossiers.programmes.clone();
                if !d.exists() {
                    d = ctx.dossiers.fichiers.parent().map(PathBuf::from).unwrap_or(d);
                }
                effets.ajouter(Effet::OuvrirAdresse(d.to_string_lossy().into_owned()));
            }
            "dossierDonnees" => {
                effets.ajouter(Effet::OuvrirAdresse(ctx.dossiers.donnees_suite.to_string_lossy().into_owned()))
            }
            "desinstaller" => effets.signal(signaux::DESINSTALLER_MINDSET, json!({})),
            _ => {}
        }
        effets.ajouter(Effet::Rafraichir);
    }

    // -----------------------------------------------------------------------------------------------------------
    // L'état (Get-EtatParametres)
    // -----------------------------------------------------------------------------------------------------------

    /// `Get-EtatParametres`, tel quel (plus `onglet`, et quelques champs pour la page : `bord`, `police`, `vignette`
    /// des cartes, `texte_page` de Mindset, `onglets`).
    pub fn etat_parametres(&self, ctx: &Contexte) -> Value {
        let (micros, casques) = self.appareils.clone().unwrap_or_default();
        let (micro, casque) = ctx.donnees().son_suite();
        let verif = ctx.reglage_bool("VerifVersions", true);
        let maj = ctx.lu(partage::MINDSET).and_then(|m| m.get("maj").cloned()).filter(|m| m.is_object());
        let prete = maj
            .as_ref()
            .filter(|m| m.get("prete").is_some_and(vrai_ps))
            .map(|m| m.get("version").map(texte_ps).unwrap_or_default());
        let en_cours = maj.as_ref().is_some_and(|m| m.get("en_cours").is_some_and(vrai_ps));
        let verifie_a = ctx
            .lu(partage::RECHERCHE)
            .and_then(|r| r.get("verifie_a").cloned())
            .is_some_and(|v| v.as_str().is_some_and(|s| !s.is_empty()));
        let (texte_mindset, ton_mindset, texte_page) = match &prete {
            Some(v) => (format!("{v} prête"), "attention", format!("{v} prête : voir l'accueil")),
            None if en_cours => ("recherche...".to_string(), "", "recherche...".to_string()),
            None if !verif && !verifie_a => ("pas encore vérifié".to_string(), "", "pas encore vérifié".to_string()),
            None => ("à jour".to_string(), "ok", "à jour".to_string()),
        };
        let applis = ctx.applis();
        let reglage_liste = |n: &str| -> Vec<String> {
            match ctx.reglage(n) {
                Some(Value::Array(a)) => a.iter().map(texte_ps).collect(),
                Some(Value::Null) | None => Vec::new(),
                Some(v) => vec![texte_ps(&v)],
            }
        };
        let demarrage = reglage_liste("Demarrage");
        let essai = reglage_liste("VersionsEssai");
        let lignes_maj: Vec<Value> = applis
            .iter()
            .map(|a| {
                let i = partage::installation(ctx, &a.id);
                let p = partage::publication(ctx, &a.id).filter(|p| !p.is_null());
                let inst = match &i {
                    Some(i) => format!("version {}", i.version.clone().filter(|v| !v.is_empty()).unwrap_or("?".into())),
                    None => "pas installé".into(),
                };
                let iv = i.as_ref().and_then(|i| i.version.clone()).filter(|v| !v.is_empty());
                let (texte, ton) = match &p {
                    None => ("pas encore vérifié".to_string(), ""),
                    Some(p) if p.get("erreur").is_some_and(vrai_ps) => ("GitHub injoignable".to_string(), "urgent"),
                    Some(p)
                        if iv.as_ref().is_some_and(|v| {
                            suite_commun::version::plus_recente(&p.get("version").map(texte_ps).unwrap_or_default(), v)
                        }) =>
                    {
                        (format!("{} disponible", textes::version_publiee(p)), "attention")
                    }
                    Some(_) if i.is_some() => ("à jour".to_string(), "ok"),
                    Some(p) => (format!("dernière : {}", p.get("version").map(texte_ps).unwrap_or_default()), ""),
                };
                json!({ "nom": a.nom, "couleur": self.traduire(&a.couleur), "version": inst, "texte": texte, "ton": ton })
            })
            .collect();
        let historique = {
            let j = ctx.donnees().lire_json(&ctx.dossiers.donnees.join("mises-a-jour.json")).ok().flatten();
            let l = textes::historique(j.as_ref());
            textes::historique_affiche(&l, &applis, &ctx.heure(), &|c| self.traduire(c))
        };
        let dossiers = format!(
            "Les programmes sont dans {} (protégé : seul un administrateur peut les modifier). Les données de Mindset et de chaque appli sont dans {}, un dossier par appli.",
            ctx.dossiers.programmes.display(),
            ctx.dossiers.donnees_suite.display()
        );
        let anim_info = self.info_animations(ctx);
        let onglets: Vec<Value> = ONGLETS.iter().map(|(k, n)| json!({ "id": k, "nom": n })).collect();
        json!({
            "version": ctx.version,
            "general": {
                "reduire": ctx.reglage_bool("ReduireHorloge", true),
                "fermeture": ctx.reglage_texte("Fermeture", "demander"),
                "windows": ctx.reglage_bool("LancerAvecWindows", true),
                "applis": Self::applis_demarrage(ctx).iter().map(|a| json!({
                    "id": a.id, "nom": a.nom, "oui": demarrage.iter().any(|x| packs::egal(x, &a.id)),
                    "note": if a.rappels { "Sinon ses rappels ne sonnent pas." } else { "" },
                })).collect::<Vec<_>>(),
            },
            "apparence": {
                "actuel": self.reglage_theme(),
                "info": self.theme_info,
                "themes": self.cartes().iter().map(Carte::json).collect::<Vec<_>>(),
                "animations": ctx.reglage_texte("Animations", "completes"),
                "animInfo": anim_info,
            },
            "son": { "micros": textes::choix_son(&micros, &micro), "casques": textes::choix_son(&casques, &casque) },
            "maj": {
                "auto": ctx.reglage_bool("MajAuto", true),
                "verif": verif,
                "mindset": { "texte": texte_mindset, "ton": ton_mindset, "texte_page": texte_page },
                "prete": prete.unwrap_or_default(),
                "info": self.maj_info,
                "applis": lignes_maj,
                "historique": historique,
                "essai": Self::applis_installees(ctx).iter().map(|a| json!({
                    "id": a.id, "nom": a.nom, "oui": essai.contains(&a.id),
                })).collect::<Vec<_>>(),
                "essaiNote": TEXTE_VERSIONS_ESSAI,
            },
            "dossiers": { "texte": dossiers },
            "conso": self.conso.clone().unwrap_or(Value::Null),
            "onglet": if self.onglet.is_empty() { "general" } else { &self.onglet },
            "onglets": onglets,
            "couleurs": self.theme.as_ref().map(|t| Value::Object(t.table(&applis.iter().map(|a| a.couleur.clone()).collect::<Vec<_>>()))).unwrap_or(Value::Null),
        })
    }

    /// `AnimationsInfo` : la console ne peut pas s'afficher sur ce PC (dit par le bloc « console », s'il dit pourquoi).
    fn info_animations(&self, ctx: &Contexte) -> String {
        if packs::egal(&ctx.reglage_texte("Animations", "completes"), "aucune") {
            return String::new();
        }
        let c = ctx.lu(partage::CONSOLE).unwrap_or(Value::Null);
        let possible = c.get("possible").and_then(Value::as_bool).unwrap_or(true);
        match c.get("raison").and_then(Value::as_str).filter(|r| !r.is_empty()) {
            Some(r) if !possible => {
                format!("La console 3D ne peut pas s'afficher sur ce PC ({r}) : l'accueil classique reste.")
            }
            _ => String::new(),
        }
    }

    fn publier_theme(&self, ctx: &Contexte) {
        let Some(t) = &self.theme else { return };
        let couleurs: Vec<String> = ctx.applis().iter().map(|a| a.couleur.clone()).collect();
        ctx.publier(partage::THEME, t.publication(&couleurs));
    }
}

#[cfg(windows)]
fn vraie_plateforme() -> Arc<dyn Plateforme> {
    Arc::new(windows::PlateformeWindows::default())
}

#[cfg(not(windows))]
fn vraie_plateforme() -> Arc<dyn Plateforme> {
    Arc::new(Fausse::default())
}

/// Le bloc sous le nom que l'hôte prend (`BlocParametres::default()`, mindset-appli/src/lib.rs).
pub type BlocParametres = Parametres;

impl Default for Parametres {
    fn default() -> Parametres {
        Parametres::NEUF
    }
}

impl Bloc for Parametres {
    fn nom(&self) -> &'static str {
        "parametres"
    }

    fn demarrer(&mut self, ctx: &Contexte, effets: &mut Effets) {
        // Le thème choisi (themes.ps1) : un thème de base, ou « pack:<id> »
        let reglage = ctx.donnees().theme_suite();
        let t = ThemeCourant::charger(&reglage, &Self::dossier_packs(ctx));
        if let Some(id) = reglage.strip_prefix("pack:") {
            theme::noter_raisons(id, &t.theme, &|x| ctx.journal(x));
        }
        if reglage.starts_with("pack:") && t.pack().is_none() {
            ctx.journal(&format!("Thème personnalisé introuvable ({reglage}) : Néon en attendant"));
        }
        effets.ajouter(Effet::BarreDeTitre(t.traduire(theme::FOND_FENETRE)));
        effets.ajouter(Effet::DossierPack(t.pack().map(|p| p.dossier.clone())));
        self.theme = Some(t);
        self.publier_theme(ctx);
        self.onglet = "general".into();
        ctx.publier(partage::ONGLET_PARAMETRES, json!("general"));
        // Les thèmes supprimés dont un dossier était encore pris : retirés maintenant, puis une dernière fois 30
        // secondes plus tard
        Self::avec_packs(ctx, |p| p.nettoyer());
        if !Self::avec_packs(ctx, |p| p.a_retirer()).is_empty() {
            self.a_retirer_a = Some(ctx.ecoule() + Duration::from_secs(30));
        }
        self.refaire_cartes(ctx, effets);
    }

    fn etat(&mut self, ctx: &Contexte) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("parametres".into(), self.etat_parametres(ctx));
        m.insert(
            "admin_bandeau".into(),
            json!({ "visible": self.bandeau_visible(ctx), "texte": self.bandeau.texte, "bouton_actif": self.bandeau.bouton_actif }),
        );
        m
    }

    fn action(&mut self, ctx: &Contexte, id: &str, valeur: &Value, effets: &mut Effets) -> bool {
        match id {
            "parametres:onglet" => {
                let o = texte_ps(valeur);
                self.montrer_onglet(ctx, &o, effets);
            }
            "parametres:reglage" => self.reglage(ctx, valeur, effets),
            "parametres:activer-admin" => self.activer_admin(ctx, effets),
            "parametres:supprimer-theme" => {
                let id = texte_ps(valeur);
                if packs::id_valable(&id) {
                    self.supprimer_theme(ctx, &id, effets);
                }
            }
            _ => return false,
        }
        true
    }

    fn tic(&mut self, ctx: &Contexte, effets: &mut Effets) -> Option<Duration> {
        let maintenant = ctx.ecoule();
        if self.premier_tic {
            self.premier_tic = false;
            self.decider_bandeau(ctx);
            if !ctx.lancement.demarrage {
                self.page_demandee(ctx, effets);
            }
            self.surveiller_a = maintenant + Duration::from_secs(2);
        }
        // Le thème de la suite surveillé avec l'état (2 s, 30 s Mindset caché)
        if maintenant >= self.surveiller_a {
            self.surveiller_theme(ctx, effets);
            self.surveiller_a = maintenant + Duration::from_secs(if ctx.vue().cachee() { 30 } else { 2 });
        }
        if self.a_retirer_a.is_some_and(|a| maintenant >= a) {
            self.a_retirer_a = None;
            Self::avec_packs(ctx, |p| p.nettoyer());
        }
        if self.relire_a.is_some_and(|a| maintenant >= a) {
            self.relire_a = None;
            effets.ajouter(Effet::Rafraichir);
        }
        // La consommation : seulement quand l'onglet est à l'écran
        let visible = conso::visible(ctx, &self.onglet);
        if !visible {
            self.conso_actif = false;
        } else if !self.conso_actif {
            self.demarrer_conso(ctx, effets);
        } else if maintenant >= self.conso_a {
            self.mesurer(ctx, effets);
        }
        let mut prochain = self.surveiller_a.saturating_sub(maintenant);
        for a in [self.a_retirer_a, self.relire_a, self.conso_actif.then_some(self.conso_a)].into_iter().flatten() {
            prochain = prochain.min(a.saturating_sub(maintenant));
        }
        Some(prochain.max(Duration::from_millis(100)))
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, donnees: &Value, effets: &mut Effets) {
        match nom {
            signaux::AFFICHER_DEMANDE => self.page_demandee(ctx, effets),
            signaux::OUVRIR_PARAMETRES => {
                let o = donnees.get("onglet").map(texte_ps).unwrap_or_default();
                self.montrer_onglet(ctx, &o, effets);
                effets.ajouter(Effet::Page("parametres".into()));
            }
            signaux::ADMIN_FINI => self.admin_fini(ctx, donnees),
            // (relus à chaque ouverture : un thème importé ou un micro branché y est)
            signaux::PAGE if donnees.get("id").and_then(Value::as_str) == Some("parametres") => {
                self.refaire_cartes(ctx, effets);
                if self.onglet == "son" {
                    self.relire_appareils(ctx);
                }
            }
            _ => {}
        }
    }

    fn tache_finie(&mut self, ctx: &Contexte, id: &str, resultat: Result<Value, String>, effets: &mut Effets) {
        match id {
            "importer" => self.import_fini(ctx, resultat, effets),
            "conso" => self.conso_finie(ctx, resultat),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod juges;
