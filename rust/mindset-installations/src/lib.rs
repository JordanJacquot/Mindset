//! Mindset en Rust, bloc « installations » : installer, mettre à jour, prendre en charge, ouvrir et désinstaller une
//! appli, ses raccourcis, son démarrage avec Mindset, la file des demandes au mini-installateur (installations.ps1,
//! taches.ps1 ; `Write-DemandeQuitter` et `Request-FermetureApplis` d'integration.ps1, la fin de Mindset.ps1:139-156).
//!
//! Ce que le bloc publie dans le tableau commun : `installations`, `occupations`, `messages`, `trouvees`,
//! `demarrages`, `admin` (formes dans `mindset_noyau::partage`). Ce qu'il reçoit : les signaux `installer`,
//! `desinstaller`, `utiliser-trouvee`, `lancer-appli`, `demande-quitter`, `demarrage-appli`, `admin-demande`,
//! `publications-changees`, `quitter` ; et les actions de la page `installations:*`, qui ne font que nommer l'appli :
//! le dossier est une copie trouvée par Mindset, et `desinstaller` pose la question de la carte (audit du 08/11, M7).
//! Ce qu'il envoie : `operation-finie`, `installations-changees`, `admin-recu`, `admin-fini`, `ouvrir-appli`.
//!
//! Tout ce qui touche à Windows passe par les ports : ceux du noyau (disque, réseau, mini-installateur, programmes)
//! et le sien ([`poste::Poste`] : raccourcis, entrées « Run », tâches de démarrage, variables, copie de dossier).
//! [`installateur_windows`] est le vrai mini-installateur, branché par l'hôte (jamais dans un test).

use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use mindset_noyau::appli::{appli_admin, appli_ouverte, processus_appli};
use mindset_noyau::donnees::Dossiers;
use mindset_noyau::installateur::Installateur;
use mindset_noyau::systeme::Lancer;
use mindset_noyau::{Appli, Bloc, Contexte, Effet, Effets, Installation, Progres, partage, signaux};
use suite_commun::chemins;

pub mod admin;
pub mod copies;
pub mod installations;
pub mod poste;
pub mod regles;
pub mod telechargement;
#[cfg(windows)]
pub mod windows;

use admin::{FileAdmin, Fin};
use installations::{dossier_donnees, dossier_gere, enregistrer, installation, suite_dir};
use poste::Poste;
use regles::{existe, joindre};

/// Le vrai mini-installateur, branché par l'hôte (jamais dans un test) : `installation.demande` dans les données de
/// Mindset, `schtasks.exe` sans fenêtre, `HKLM\SOFTWARE\Mindset\Installation` en lecture, et la demande de Windows
/// (`MindsetInstallateur.exe` à côté de Mindset.exe, en « runas »).
pub fn installateur_windows(dossiers: &Dossiers) -> Arc<dyn Installateur> {
    #[cfg(windows)]
    {
        Arc::new(windows::installateur::InstallateurWindows::nouveau(dossiers))
    }
    #[cfg(not(windows))]
    {
        let _ = dossiers;
        Arc::new(mindset_noyau::installateur::SansInstallateur)
    }
}

/// Le temps laissé à une appli pour se fermer avant son installation (`$DelaiFermetureAppli`).
pub const DELAI_FERMETURE: Duration = Duration::from_secs(30);
/// Le temps donné à un désinstalleur d'appli (10 minutes).
pub const DELAI_DESINSTALLEUR: Duration = Duration::from_secs(600);
/// Le temps d'attente d'une version publiée quand elle n'est pas encore connue (voir DIVERGENCES.md).
pub const DELAI_PUBLICATION: Duration = Duration::from_secs(90);

/// Les tâches de démarrage d'une appli d'avant (`$TachesDemarrageAppli`).
pub const TACHES_DEMARRAGE: &[(&str, &[&str])] =
    &[("nevermind", &["Nevermind (démarrage)", "OptiGame (démarrage)", "Nexo (démarrage)"])];

/// L'opération en cours sur une appli (`$script:Occupe`).
#[derive(Debug, Clone, PartialEq)]
pub struct Occupation {
    pub texte: String,
    /// « installation », « desinstallation » ou « deplacement »
    pub quoi: &'static str,
}

/// Une installation en cours (`$script:EnCours`).
#[derive(Debug, Clone, PartialEq)]
pub struct EnCours {
    pub ancien: Option<String>,
    pub version: String,
    pub zip: String,
    pub dossier_zip: String,
    /// Les paramètres de la demande « appli » au mini-installateur, dans l'ordre
    pub parametres: Vec<(String, String)>,
    /// L'appli s'ouvrira avec Mindset une fois installée
    pub demarrage: bool,
    /// La version d'avant (« » : première installation)
    pub avant: String,
}

#[derive(Debug, Clone)]
struct AttenteDesinstall {
    id: String,
    dossier: String,
    debut: Duration,
}

/// Le bloc « installations ».
pub struct BlocInstallations {
    poste: Option<Arc<dyn Poste>>,
    /// Les tests du bloc : ce que la version PowerShell ne faisait jamais en test (`$EnTest`) est fait avec les faux
    /// ports (relance des applis, démarrage, remise en ordre des tâches, fermeture des applis en quittant).
    essai_complet: bool,
    occupe: BTreeMap<String, Occupation>,
    messages: BTreeMap<String, String>,
    en_cours: BTreeMap<String, EnCours>,
    progres: BTreeMap<String, (Arc<Progres>, String)>,
    a_relancer: BTreeSet<String>,
    maj_auto: BTreeSet<String>,
    attentes_fermeture: BTreeMap<String, Duration>,
    attente_desinstall: Option<AttenteDesinstall>,
    attentes_publication: BTreeMap<String, (Option<String>, Duration)>,
    admin: FileAdmin,
    trouvees: BTreeMap<String, String>,
    recherche_trouvees: bool,
    connues: BTreeMap<String, Installation>,
    publie_installations: Option<Value>,
    premier_tic: bool,
    dernier_releve: Option<Duration>,
    fermer_applis: bool,
    historique_a_envoyer: BTreeMap<String, (Value, String)>,
    dernieres_versions: BTreeMap<String, String>,
    deplacements: BTreeMap<String, (String, String, String)>,
}

/// Le bloc tel que l'hôte le crée (`BlocInstallations::default()`, dans `blocs()`) : son poste Windows est branché à
/// `demarrer` (le vrai, ou aucun dans la construction d'essai de Mindset).
impl Default for BlocInstallations {
    fn default() -> BlocInstallations {
        BlocInstallations::NEUF
    }
}

impl BlocInstallations {
    const NEUF: BlocInstallations = BlocInstallations {
        poste: None,
        essai_complet: false,
        occupe: BTreeMap::new(),
        messages: BTreeMap::new(),
        en_cours: BTreeMap::new(),
        progres: BTreeMap::new(),
        a_relancer: BTreeSet::new(),
        maj_auto: BTreeSet::new(),
        attentes_fermeture: BTreeMap::new(),
        attente_desinstall: None,
        attentes_publication: BTreeMap::new(),
        admin: FileAdmin::NEUVE,
        trouvees: BTreeMap::new(),
        recherche_trouvees: false,
        connues: BTreeMap::new(),
        publie_installations: None,
        premier_tic: false,
        dernier_releve: None,
        fermer_applis: false,
        historique_a_envoyer: BTreeMap::new(),
        dernieres_versions: BTreeMap::new(),
        deplacements: BTreeMap::new(),
    };

    /// Un bloc pour les tests, avec ce faux poste : tout est fait, comme hors essai (les ports sont des faux).
    pub fn pour_essai(poste: Arc<dyn Poste>) -> BlocInstallations {
        BlocInstallations { poste: Some(poste), essai_complet: true, ..BlocInstallations::NEUF }
    }

    fn poste(&mut self, ctx: &Contexte) -> Arc<dyn Poste> {
        if self.poste.is_none() {
            self.poste = Some(poste_par_defaut(ctx));
        }
        Arc::clone(self.poste.as_ref().unwrap_or_else(|| unreachable!()))
    }

    /// Fait ce que la version PowerShell ne faisait pas en test.
    fn complet(&self, ctx: &Contexte) -> bool {
        !ctx.essai || self.essai_complet
    }

    fn occupee(&self, id: &str) -> bool {
        self.occupe.contains_key(id)
    }

    /// `$script:TacheInstallationOk` (`None` : pas encore regardée).
    pub fn tache_connue(&self) -> Option<bool> {
        self.admin.tache_connue()
    }

    /// `Get-Installation` (avec l'opération en cours sur l'appli).
    /// `dossier` est-il une copie de l'appli que Mindset connaît lui-même ? La copie trouvée sur le PC (`trouvees`),
    /// ou la copie non gérée qu'il ouvre (les deux que la carte propose de prendre en charge).
    fn copie_connue(&self, ctx: &Contexte, id: &str, dossier: &str) -> bool {
        if self.trouvees.get(id).is_some_and(|d| chemins::egal(d, dossier)) {
            return true;
        }
        Self::appli(ctx, id)
            .and_then(|a| self.installation(ctx, &a))
            .is_some_and(|i| !i.gere && chemins::egal(&i.dossier, dossier))
    }

    pub fn installation(&self, ctx: &Contexte, appli: &Appli) -> Option<Installation> {
        installation(ctx, appli, self.occupee(&appli.id))
    }

    fn appli(ctx: &Contexte, id: &str) -> Option<Appli> {
        ctx.appli(id)
    }

    fn mindset_admin(ctx: &Contexte) -> bool {
        ctx.lancement.admin
    }

    // -------------------------------------------------------------------------------------------------------------
    // Le tableau commun
    // -------------------------------------------------------------------------------------------------------------

    /// Relit l'installation de chaque appli (`Get-Installation`, comme les cartes le faisaient sans cesse).
    fn relever(&mut self, ctx: &Contexte) {
        let mut c = BTreeMap::new();
        for a in ctx.applis().iter() {
            if let Some(i) = self.installation(ctx, a) {
                c.insert(a.id.clone(), i);
            }
        }
        self.connues = c;
        self.dernier_releve = Some(ctx.ecoule());
    }

    /// Le tableau commun, et `installations-changees` si les installations ou les démarrages ont changé.
    fn publier(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let applis = ctx.applis();
        let mut inst = Map::new();
        for a in applis.iter() {
            if let Some(i) = self.connues.get(&a.id) {
                inst.insert(a.id.clone(), i.en_json());
            }
        }
        let mut dem = Map::new();
        for a in applis.iter() {
            dem.insert(a.id.clone(), Value::Bool(demarrage_appli(ctx, &a.id)));
        }
        let ensemble = json!({ "i": inst, "d": dem });
        if self.publie_installations.as_ref() != Some(&ensemble) {
            let premiere = self.publie_installations.is_none();
            self.publie_installations = Some(ensemble);
            ctx.publier(partage::INSTALLATIONS, Value::Object(inst));
            ctx.publier(partage::DEMARRAGES, Value::Object(dem));
            if !premiere {
                effets.signal(signaux::INSTALLATIONS_CHANGEES, json!({}));
            }
        }
        let mut occ = Map::new();
        for (id, o) in &self.occupe {
            let (progres, recu, total, version) = match self.progres.get(id) {
                Some((p, v)) => (json!(p.part()), json!(p.recu()), json!(p.total()), json!(v)),
                None => (Value::Null, Value::Null, Value::Null, Value::Null),
            };
            let version = self.en_cours.get(id).map(|c| json!(c.version)).unwrap_or(version);
            occ.insert(
                id.clone(),
                json!({ "texte": o.texte, "progres": progres, "version": version, "auto": self.maj_auto.contains(id),
                        "quoi": o.quoi, "recu": recu, "total": total }),
            );
        }
        ctx.publier(partage::OCCUPATIONS, Value::Object(occ));
        ctx.publier(partage::MESSAGES, json!(self.messages));
        ctx.publier(partage::TROUVEES, json!(self.trouvees));
        ctx.publier(partage::ADMIN, self.admin.etat_publie());
    }

    /// `Update-Trouvees` : une copie déjà sur le PC, pour chaque appli pas installée (cherchée dans un travail de
    /// fond : Téléchargements, Bureau et Documents sont parcourus).
    fn chercher_trouvees(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if self.recherche_trouvees {
            return;
        }
        self.recherche_trouvees = true;
        let applis: Vec<Appli> = ctx.applis().iter().filter(|a| !self.connues.contains_key(&a.id)).cloned().collect();
        let poste = self.poste(ctx);
        // (le travail n'a pas le contexte : ce dont il a besoin est emporté ; les installations ont été relevées)
        let mon = ctx.dossiers.mindset.to_string_lossy().into_owned();
        let programmes = ctx.dossiers.programmes.to_string_lossy().into_owned();
        let processus = ctx.systeme().processus();
        effets.tache("trouvees", move || {
            let mut r = Map::new();
            for a in applis {
                if let Some(d) = copies::trouver(&*poste, &a, &mon, &programmes, &processus) {
                    r.insert(a.id.clone(), Value::String(d));
                }
            }
            Ok(Value::Object(r))
        });
    }

    // -------------------------------------------------------------------------------------------------------------
    // Ouvrir
    // -------------------------------------------------------------------------------------------------------------

    /// `Open-Appli` : lancer l'appli, ou ramener sa fenêtre si elle tourne déjà.
    pub fn ouvrir_appli(&mut self, ctx: &Contexte, id: &str, demarrage: bool) {
        let Some(a) = Self::appli(ctx, id) else { return };
        let Some(inst) = self.installation(ctx, &a) else { return };
        // En cours d'installation : pas maintenant ; elle est relancée à la fin
        if self.occupee(id) {
            self.a_relancer.insert(id.into());
            return;
        }
        if appli_ouverte(ctx, &a) {
            if demarrage {
                return;
            }
            let poste = self.poste(ctx);
            poste.autoriser_premier_plan();
            if !a.afficher_signal.is_empty() && ctx.systeme().lever_signal(&a.afficher_signal) {
                return;
            }
            if !a.afficher_fichier.is_empty() {
                let f = joindre(&dossier_donnees(ctx, &a), &a.afficher_fichier);
                let ok = Path::new(&f).parent().is_some_and(|p| std::fs::create_dir_all(p).is_ok())
                    && std::fs::write(&f, ctx.pid().to_string()).is_ok();
                if ok {
                    return;
                }
            }
        }
        let mon = ctx.dossiers.mindset.to_string_lossy();
        let mut exe = joindre(&inst.dossier, "Mindset.exe");
        if !existe(&exe) || chemins::egal(&inst.dossier, &mon) {
            exe = joindre(&inst.dossier, &a.exe);
        }
        let avec_droits =
            appli_admin(&a, Some(&inst)) && inst.gere && chemins::egal(&inst.dossier, &dossier_gere(ctx, &a));
        let l = Lancer {
            exe: PathBuf::from(&exe),
            arguments: if demarrage { vec!["-Demarrage".into()] } else { Vec::new() },
            dossier: PathBuf::from(&inst.dossier),
            sans_droits: Self::mindset_admin(ctx) && !avec_droits,
        };
        if let Err(e) = ctx.systeme().lancer(&l) {
            ctx.journal(&format!("Lancement de {} : {e}", a.nom));
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Installer, mettre à jour, prendre en charge
    // -------------------------------------------------------------------------------------------------------------

    /// `Start-InstallAppli` : `ancien` : la copie existante qu'on prend en charge ; `auto` : une mise à jour
    /// automatique (demandée par le bloc « lui-même »).
    pub fn installer(&mut self, ctx: &Contexte, effets: &mut Effets, id: &str, ancien: Option<String>, auto: bool) {
        let Some(a) = Self::appli(ctx, id) else { return };
        if self.occupee(id) {
            return;
        }
        // Ouverte, ou qui s'ouvre avec Mindset : relancée une fois installée. Mise à jour automatique : seulement si
        // elle était ouverte (une appli que l'utilisateur a fermée reste fermée).
        let ouverte = appli_ouverte(ctx, &a);
        let relancer = if auto { ouverte } else { ouverte || demarrage_appli(ctx, id) };
        if relancer {
            self.a_relancer.insert(id.into());
        } else {
            self.a_relancer.remove(id);
        }
        if auto {
            self.maj_auto.insert(id.into());
        } else {
            self.maj_auto.remove(id);
        }
        self.occupe.insert(id.into(), Occupation { texte: "Téléchargement...".into(), quoi: "installation" });
        self.messages.remove(id);
        let _ = std::fs::create_dir_all(ctx.dossiers.telechargements());
        self.progres.insert(id.into(), (Arc::new(Progres::default()), String::new()));
        let ancien = ancien.filter(|d| !d.is_empty());
        match publication_prete(ctx, id) {
            Some(p) => self.lancer_telechargement(ctx, effets, &a, ancien, p),
            None => {
                // La version publiée n'est pas encore connue (ou en erreur) : une recherche est demandée (voir
                // DIVERGENCES.md), le téléchargement part quand elle a répondu
                self.attentes_publication.insert(id.into(), (ancien, ctx.ecoule()));
                effets.signal(signaux::ACTUALISER, json!({ "clic": true }));
            }
        }
    }

    fn lancer_telechargement(
        &mut self,
        ctx: &Contexte,
        effets: &mut Effets,
        a: &Appli,
        ancien: Option<String>,
        p: Value,
    ) {
        let t = |k: &str| p.get(k).map(suite_commun::protocole_installateur::texte_ps).unwrap_or_default();
        let version = t("version");
        let progres = match self.progres.get_mut(&a.id) {
            Some((pr, v)) => {
                *v = version.clone();
                Arc::clone(pr)
            }
            None => return,
        };
        let travail = telechargement::Travail {
            reseau: ctx.reseau(),
            progres,
            id: a.id.clone(),
            version,
            url_zip: t("url_zip"),
            url_sig: t("url_sig"),
            dossiers_zip: vec![a.dossier_zip.clone(), a.ancien_dossier_zip.clone()],
            exe: a.exe.clone(),
            cles: ctx.dossiers.fichiers.join("cles-publiques"),
            telechargements: ctx.dossiers.telechargements(),
            version_mindset: ctx.version.clone(),
        };
        let ancien = ancien.unwrap_or_default();
        effets.tache(&format!("telechargement:{}:{ancien}", a.id), move || travail.faire());
    }

    /// Les versions publiées ont changé : les installations qui attendaient la leur partent (ou s'arrêtent).
    fn publications_changees(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let en_cours = ctx
            .lu(partage::RECHERCHE)
            .and_then(|r| r.get("en_cours").cloned())
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default();
        for id in self.attentes_publication.keys().cloned().collect::<Vec<_>>() {
            if en_cours.iter().any(|x| x.as_str() == Some(&id)) {
                continue;
            }
            let Some(a) = Self::appli(ctx, &id) else { continue };
            if let Some(p) = publication_prete(ctx, &id) {
                let (ancien, _) = self.attentes_publication.remove(&id).unwrap_or_default();
                self.lancer_telechargement(ctx, effets, &a, ancien, p);
            } else if let Some(e) =
                partage::publication(ctx, &id).and_then(|p| p.get("erreur").and_then(Value::as_str).map(str::to_string))
            {
                self.attentes_publication.remove(&id);
                self.complete_telechargement(ctx, effets, &id, None, Err(e));
            }
        }
    }

    /// `Complete-Telechargement`
    fn complete_telechargement(
        &mut self,
        ctx: &Contexte,
        effets: &mut Effets,
        id: &str,
        ancien: Option<String>,
        resultat: Result<Value, String>,
    ) {
        self.progres.remove(id);
        let Some(a) = Self::appli(ctx, id) else { return };
        let r = match resultat {
            Ok(r) if !r.is_null() => r,
            Ok(_) => return self.arreter(ctx, effets, id, "Échec : ".into(), "installation"),
            Err(e) => return self.arreter(ctx, effets, id, format!("Échec : {e}"), "installation"),
        };
        let t = |k: &str| r.get(k).map(suite_commun::protocole_installateur::texte_ps).unwrap_or_default();
        let dossier_zip = if t("dossier_zip").is_empty() { a.dossier_zip.clone() } else { t("dossier_zip") };
        let poste = self.poste(ctx);
        let mut p: Vec<(String, String)> = vec![
            ("Appli".into(), a.id.clone()),
            ("Zip".into(), t("zip")),
            ("Signature".into(), t("sig")),
            ("Destination".into(), dossier_gere(ctx, &a)),
            ("DossierZip".into(), dossier_zip.clone()),
            ("Exe".into(), a.exe.clone()),
        ];
        let mut poser = |k: &str, v: String| match p.iter_mut().find(|(n, _)| n == k) {
            Some(x) => x.1 = v,
            None => p.push((k.into(), v)),
        };
        if let Some(d) = &ancien {
            poser("AncienExe", joindre(d, &a.exe));
            poser("Sid", poste.sid());
        }
        if !a.aide.is_empty() {
            poser("TacheAide", a.aide.clone());
            poser("ExeAide", a.aide_exe.clone());
            poser("Sid", poste.sid());
        }
        let liste = ctx.dossiers.donnees.join("apps-en-ligne.json");
        if liste.is_file() {
            poser("Liste", liste.to_string_lossy().into_owned());
        }
        // Première installation ou prise en charge : l'appli qui se lançait avec Windows s'ouvrira avec Mindset
        let inst = self.installation(ctx, &a);
        let mut demarrage = false;
        if !inst.as_ref().is_some_and(|i| i.gere) && !demarrage_appli(ctx, id) {
            demarrage = match self.demarrage_windows(ctx, &a) {
                Some(b) => b,
                None => a.rappels,
            };
        }
        let avant = inst.and_then(|i| i.version).unwrap_or_default();
        self.en_cours.insert(
            id.into(),
            EnCours { ancien, version: t("version"), zip: t("zip"), dossier_zip, parametres: p, demarrage, avant },
        );
        // Ouverte : d'abord priée de quitter proprement, le temps d'enregistrer ce qu'elle fait
        if appli_ouverte(ctx, &a) {
            copies::ecrire_demande_quitter(ctx, &a);
            ctx.journal(&format!("{} : fermeture demandée avant l'installation", a.nom));
            self.occupe
                .insert(id.into(), Occupation { texte: format!("Fermeture de {}...", a.nom), quoi: "installation" });
            self.attentes_fermeture.insert(id.into(), ctx.ecoule());
            return;
        }
        self.envoyer_installation(ctx, effets, id);
    }

    /// La minuterie de 300 ms : les applis priées de quitter avant leur installation.
    fn attendre_fermetures(&mut self, ctx: &Contexte, effets: &mut Effets) {
        for id in self.attentes_fermeture.keys().cloned().collect::<Vec<_>>() {
            let a = Self::appli(ctx, &id);
            let ouverte = a.as_ref().is_some_and(|a| appli_ouverte(ctx, a));
            let debut = self.attentes_fermeture.get(&id).copied().unwrap_or_default();
            let ecoule = ctx.ecoule().saturating_sub(debut);
            if ouverte && ecoule < DELAI_FERMETURE {
                continue;
            }
            self.attentes_fermeture.remove(&id);
            let Some(a) = a else { continue };
            if ouverte {
                ctx.journal(&format!("{} ne s'est pas fermé en 30 s : l'installateur le fermera", a.nom));
            } else {
                ctx.journal(&format!("{} s'est fermé proprement ({} s)", a.nom, arrondi_1(ecoule.as_secs_f64())));
            }
            self.envoyer_installation(ctx, effets, &id);
        }
    }

    /// `Send-InstallationAppli`
    fn envoyer_installation(&mut self, ctx: &Contexte, effets: &mut Effets, id: &str) {
        let Some(c) = self.en_cours.get(id).cloned() else { return };
        let par_tache = !Self::mindset_admin(ctx) && self.admin.tache_ok(ctx);
        let texte = if par_tache { "Installation..." } else { "Installation (accepte la demande de Windows)..." };
        self.occupe.insert(id.into(), Occupation { texte: texte.into(), quoi: "installation" });
        let auto = self.maj_auto.contains(id);
        self.invoquer_admin(ctx, effets, "appli", c.parametres, Fin::Installation(id.into()), auto, None);
    }

    /// `Complete-Installation`
    fn complete_installation(&mut self, ctx: &Contexte, effets: &mut Effets, id: &str, dossier: &str) {
        let Some(a) = Self::appli(ctx, id) else { return };
        let c = self.en_cours.remove(id);
        let ancien = c.as_ref().and_then(|c| c.ancien.clone());
        enregistrer(ctx, id, Some(dossier), true);
        ctx.donnees().ecrire_suite_appli(id, Some(dossier));
        let poste = self.poste(ctx);
        copies::maj_raccourci_appli(ctx, &*poste, &a, true);
        let mut notes: Vec<String> = copies::retirer_doublons(ctx, &*poste, &a).into_iter().collect();
        if let (Some(an), Some(c)) = (&ancien, &c) {
            notes.push(copies::retirer_ancienne_copie(ctx, &*poste, &a, an, &c.zip, &c.dossier_zip));
        }
        if let Ok(l) = std::fs::read_dir(ctx.dossiers.telechargements()) {
            let debut = format!("{id}.");
            for f in l.flatten() {
                if chemins::apres_debut(&f.file_name().to_string_lossy(), &debut).is_some() {
                    let _ = std::fs::remove_file(f.path());
                }
            }
        }
        let version = c.as_ref().map(|c| c.version.clone()).unwrap_or_default();
        let pris = ancien.as_ref().map(|d| format!(" (pris en charge depuis {d})")).unwrap_or_default();
        ctx.journal(&format!("{} {version} installé dans {dossier}{pris}", a.nom));
        // Une mise à jour (plus récente que la version d'avant) : pour l'historique (bloc « lui-même »)
        let mut historique = Value::Null;
        if let Some(c) = &c
            && !c.avant.is_empty()
            && suite_commun::version::plus_recente(&c.version, &c.avant)
        {
            let pubv = partage::publication(ctx, id);
            let notes_version = match &pubv {
                Some(p)
                    if p.get("version").map(suite_commun::protocole_installateur::texte_ps)
                        == Some(c.version.clone()) =>
                {
                    p.get("notes").map(suite_commun::protocole_installateur::texte_ps).unwrap_or_default()
                }
                _ => String::new(),
            };
            historique = json!({ "id": id, "nom": a.nom, "version": c.version, "auto": self.maj_auto.contains(id),
                                 "notes": notes_version });
        }
        self.historique_a_envoyer
            .insert(id.into(), (historique, c.as_ref().map(|c| c.avant.clone()).unwrap_or_default()));
        if c.as_ref().is_some_and(|c| c.demarrage) && !demarrage_appli(ctx, id) {
            self.mettre_demarrage(ctx, id, true);
            self.a_relancer.insert(id.into());
            ctx.journal(&format!(
                "{} s'ouvre avec Mindset (il se lançait avec Windows, ou ses rappels en ont besoin)",
                a.nom
            ));
        }
        let mut fin = vec![format!("{} {version} est installé.", a.nom)];
        fin.extend(notes.into_iter().filter(|n| !n.is_empty()));
        self.deplacer_donnees(ctx, effets, &a, fin.join(" "));
    }

    /// `Move-DonneesAppli` : les données d'avant rejoignent celles de la suite (d'un disque à l'autre : copiées,
    /// vérifiées, puis l'ancien dossier supprimé ; sur le même disque, l'appli renomme elle-même).
    fn deplacer_donnees(&mut self, ctx: &Contexte, effets: &mut Effets, a: &Appli, message: String) {
        let poste = self.poste(ctx);
        let dest = joindre(&suite_dir(ctx), &a.nom);
        let local = joindre(&poste.localappdata(), &format!(r"Mindset\{}", a.nom));
        let src =
            [local, a.donnees.clone()].into_iter().find(|s| !s.is_empty() && !chemins::egal(s, &dest) && existe(s));
        let Some(src) = src else { return self.arreter(ctx, effets, &a.id, message, "installation") };
        if existe(&dest) || chemins::egal(&racine(&src), &racine(&dest)) {
            return self.arreter(ctx, effets, &a.id, message, "installation");
        }
        if !regles::dossier_sur(&src, &poste.dossiers_interdits()) {
            ctx.journal(&format!("Données de {} : {src} est un lien vers un autre dossier, pas déplacé", a.nom));
            return self.arreter(ctx, effets, &a.id, message, "installation");
        }
        let (_, taille) = mesurer(Path::new(&src));
        let go = taille as f64 / (1u64 << 30) as f64;
        self.occupe.insert(
            a.id.clone(),
            Occupation {
                texte: format!("Déplacement des données vers {dest} ({} Go)...", regles::nombre_n1(go)),
                quoi: "deplacement",
            },
        );
        self.deplacements.insert(a.id.clone(), (message, src.clone(), dest.clone()));
        effets.tache(&format!("donnees:{}", a.id), move || copier_donnees(&*poste, &src, &dest));
    }

    /// La fin du déplacement des données.
    fn donnees_deplacees(&mut self, ctx: &Contexte, effets: &mut Effets, id: &str, r: Result<Value, String>) {
        let Some((message, src, dest)) = self.deplacements.remove(id) else { return };
        let nom = Self::appli(ctx, id).map(|a| a.nom).unwrap_or_default();
        match r {
            Err(e) => {
                ctx.journal(&format!("Données de {nom} : {e}"));
                self.arreter(ctx, effets, id, format!("{message} Attention : {e}"), "installation");
            }
            Ok(v) => {
                ctx.journal(&format!("Données de {nom} déplacées : {src} -> {dest}"));
                let reste = suite_commun::protocole_installateur::texte_ps(&v);
                let m = format!("{message} Ses données sont maintenant dans {dest}. {reste}");
                self.arreter(ctx, effets, id, m.trim().to_string(), "installation");
            }
        }
    }

    /// `Stop-Operation` : l'opération est finie (réussie ou non) ; `quoi` : « installation » ou
    /// « desinstallation » (pour `operation-finie`).
    fn arreter(&mut self, ctx: &Contexte, effets: &mut Effets, id: &str, message: String, quoi: &str) {
        self.occupe.remove(id);
        self.progres.remove(id);
        let Some(a) = Self::appli(ctx, id) else { return };
        let auto = self.maj_auto.remove(id);
        let ok = match quoi {
            "desinstallation" => message.to_lowercase().contains("est désinstallé"),
            "utilisation" => message.starts_with("Mindset ouvrira"),
            _ => message.to_lowercase().contains("est installé"),
        };
        let mut carte = message.clone();
        if auto && !message.to_lowercase().contains("est installé") {
            carte = format!(
                "La mise à jour automatique n'a pas pu se faire : {} Clique sur « Mettre à jour » pour réessayer.",
                regles::raison_echec_maj(&a.nom, &message)
            );
        }
        self.messages.insert(id.into(), carte);
        let (historique, avant) = self.historique_a_envoyer.remove(id).unwrap_or((Value::Null, String::new()));
        let version = self.dernieres_versions.remove(id).unwrap_or_default();
        effets.signal(
            signaux::OPERATION_FINIE,
            json!({ "id": id, "quoi": quoi, "ok": ok, "message": message, "auto": auto, "version": version,
                    "avant": avant, "historique": historique }),
        );
        self.relever(ctx);
        self.recherche_trouvees = false;
        self.chercher_trouvees(ctx, effets);
        // Fermée par l'installation (ou demandée pendant) : relancée, cachée, puis accrochée si son onglet est montré
        if self.a_relancer.remove(id) {
            let i = self.installation(ctx, &a);
            if i.is_some_and(|i| i.gere) && self.complet(ctx) {
                if ctx.vue().page == id {
                    effets.ajouter(signaux::ouvrir_appli(id, true));
                } else {
                    self.ouvrir_appli(ctx, id, true);
                }
            }
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // « S'ouvre avec Mindset », démarrage avec Windows
    // -------------------------------------------------------------------------------------------------------------

    /// Ses tâches de démarrage qui existent encore (`Get-TachesDemarrageAppli`).
    fn taches_demarrage(&mut self, ctx: &Contexte, id: &str) -> Vec<String> {
        let poste = self.poste(ctx);
        taches_de(id).iter().filter(|n| poste.tache_existe(&format!("\\{n}"))).map(|n| n.to_string()).collect()
    }

    /// `Get-DemarrageWindowsAppli` : l'appli se lançait-elle avec Windows par elle-même ? `None` : on ne sait pas.
    pub fn demarrage_windows(&mut self, ctx: &Contexte, a: &Appli) -> Option<bool> {
        let poste = self.poste(ctx);
        if !copies::demarrages_appli(&*poste, a).is_empty() {
            return Some(true);
        }
        if Self::mindset_admin(ctx) && !self.taches_demarrage(ctx, &a.id).is_empty() {
            return Some(true);
        }
        let mut ds = vec![dossier_donnees(ctx, a), a.donnees.clone()];
        ds.retain(|d| !d.is_empty());
        ds.dedup();
        for d in ds {
            for n in ["reglages.json", "parametres.json"] {
                let f = joindre(&d, n);
                let Ok(o) = std::fs::read(&f) else { continue };
                let Ok(Value::Object(j)) = serde_json::from_str::<Value>(&suite_commun::json_sur::texte_du_fichier(&o))
                else {
                    continue;
                };
                if let Some(Value::Bool(b)) = j.get("DemarrageWindows") {
                    return Some(*b);
                }
            }
        }
        None
    }

    /// `Repair-DemarrageApplis` (une fois, réglage « DemarrageRepris »).
    pub fn reparer_demarrages(&mut self, ctx: &Contexte) {
        if ctx.reglage_bool("DemarrageRepris", false) {
            return;
        }
        for a in ctx.applis().iter() {
            let i = self.installation(ctx, a);
            if !i.is_some_and(|i| i.gere) || demarrage_appli(ctx, &a.id) {
                continue;
            }
            let oui = self.demarrage_windows(ctx, a).unwrap_or(a.rappels);
            if !oui {
                continue;
            }
            self.mettre_demarrage(ctx, &a.id, true);
            ctx.journal(&format!(
                "{} s'ouvre avec Mindset (il se lançait avec Windows avant d'être pris en charge)",
                a.nom
            ));
        }
        ctx.ecrire_reglage("DemarrageRepris", Value::Bool(true));
    }

    /// `Set-DemarrageAppli`
    pub fn mettre_demarrage(&mut self, ctx: &Contexte, id: &str, oui: bool) {
        let mut l: Vec<String> = liste_demarrage(ctx).into_iter().filter(|x| x != id).collect();
        if oui {
            l.push(id.into());
        }
        ctx.ecrire_reglage("Demarrage", json!(l));
        if Self::mindset_admin(ctx) {
            self.retirer_taches_demarrage(ctx, id);
        }
    }

    /// `Remove-TachesDemarrageAppli`
    fn retirer_taches_demarrage(&mut self, ctx: &Contexte, id: &str) {
        let poste = self.poste(ctx);
        for n in taches_de(id) {
            if poste.retirer_tache(&format!("\\{n}")) {
                ctx.journal(&format!(
                    "Tâche « {n} » retirée : le démarrage de {id} se règle dans Mindset (S'ouvre avec Mindset)"
                ));
            }
        }
    }

    /// `Move-TachesDemarrage` (Mindset administrateur).
    pub fn reprendre_taches_demarrage(&mut self, ctx: &Contexte) {
        if !Self::mindset_admin(ctx) {
            return;
        }
        for (id, _) in TACHES_DEMARRAGE {
            let Some(a) = Self::appli(ctx, id) else { continue };
            if !self.installation(ctx, &a).is_some_and(|i| i.gere) {
                continue;
            }
            if !self.taches_demarrage(ctx, id).is_empty() && !demarrage_appli(ctx, id) {
                self.mettre_demarrage(ctx, id, true);
                ctx.journal(&format!("{} s'ouvre avec Mindset (sa tâche de démarrage est reprise)", a.nom));
            }
            self.retirer_taches_demarrage(ctx, id);
        }
    }

    /// `Update-RaccourcisApplis`
    pub fn maj_raccourcis(&mut self, ctx: &Contexte) {
        let poste = self.poste(ctx);
        for a in ctx.applis().iter() {
            copies::maj_raccourci_appli(ctx, &*poste, a, self.occupee(&a.id));
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Désinstaller
    // -------------------------------------------------------------------------------------------------------------

    /// `Start-DesinstallAppli` (seulement une installation gérée).
    pub fn desinstaller(&mut self, ctx: &Contexte, effets: &mut Effets, id: &str) {
        let Some(a) = Self::appli(ctx, id) else { return };
        if self.occupee(id) {
            return;
        }
        let Some(inst) = self.installation(ctx, &a) else { return };
        if !inst.gere || !chemins::egal(&inst.dossier, &dossier_gere(ctx, &a)) {
            return;
        }
        // Ses programmes d'aide lancés depuis son dossier de données : fermés d'abord, par leur chemin
        if self.complet(ctx) {
            let s = ctx.systeme();
            for pid in copies::processus_donnees(ctx, &a) {
                match s.arreter(pid) {
                    Ok(()) => {
                        s.attendre_fin(pid, 3000);
                        ctx.journal(&format!("Désinstallation de {} : programme d'aide fermé ({pid})", a.nom));
                    }
                    Err(e) => {
                        ctx.journal(&format!("Désinstallation de {} : programme d'aide {pid} pas fermé ({e})", a.nom))
                    }
                }
            }
        }
        if !a.desinstalleur.is_empty() {
            let l = Lancer {
                exe: PathBuf::from(joindre(&inst.dossier, &a.desinstalleur)),
                arguments: Vec::new(),
                dossier: PathBuf::from(&inst.dossier),
                sans_droits: false,
            };
            if ctx.systeme().lancer(&l).is_err() {
                return self.arreter(ctx, effets, id, "Désinstallation annulée.".into(), "desinstallation");
            }
            self.occupe.insert(
                id.into(),
                Occupation {
                    texte: "Désinstallation (suis les étapes de son désinstalleur)...".into(),
                    quoi: "desinstallation",
                },
            );
            self.attente_desinstall =
                Some(AttenteDesinstall { id: id.into(), dossier: inst.dossier, debut: ctx.ecoule() });
            return;
        }
        self.occupe.insert(
            id.into(),
            Occupation { texte: "Désinstallation (accepte la demande de Windows)...".into(), quoi: "desinstallation" },
        );
        let p = vec![("Destination".into(), inst.dossier), ("Exe".into(), a.exe.clone())];
        self.invoquer_admin(ctx, effets, "supprimer", p, Fin::Desinstallation(id.into()), false, None);
    }

    /// `Complete-Desinstallation`
    fn complete_desinstallation(&mut self, ctx: &Contexte, effets: &mut Effets, id: &str) {
        let Some(a) = Self::appli(ctx, id) else { return };
        enregistrer(ctx, id, None, false);
        ctx.donnees().ecrire_suite_appli(id, None);
        self.mettre_demarrage(ctx, id, false);
        let poste = self.poste(ctx);
        copies::retirer_raccourci_appli(ctx, &*poste, &a);
        let (_, message) = copies::nettoyer_desinstallation(ctx, &a);
        self.arreter(ctx, effets, id, message, "desinstallation");
    }

    /// La minuterie d'une seconde : le désinstalleur de l'appli a-t-il fini ?
    fn attendre_desinstalleur(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let Some(w) = self.attente_desinstall.clone() else { return };
        let Some(a) = Self::appli(ctx, &w.id) else {
            self.attente_desinstall = None;
            return;
        };
        if !existe(&joindre(&w.dossier, &a.exe)) {
            self.attente_desinstall = None;
            self.complete_desinstallation(ctx, effets, &w.id);
        } else if ctx.ecoule().saturating_sub(w.debut) > DELAI_DESINSTALLEUR {
            self.attente_desinstall = None;
            self.arreter(ctx, effets, &w.id, "Désinstallation annulée ou pas terminée.".into(), "desinstallation");
        }
    }

    /// `Use-InstallationTrouvee` : une copie trouvée, ouverte telle quelle (sans la gérer).
    pub fn utiliser_trouvee(&mut self, ctx: &Contexte, effets: &mut Effets, id: &str, dossier: &str) {
        let Some(a) = Self::appli(ctx, id) else { return };
        if !regles::dossier_appli(dossier, &a) {
            return self.arreter(ctx, effets, id, format!("Ce dossier ne contient pas {}.", a.nom), "utilisation");
        }
        enregistrer(ctx, id, Some(dossier), false);
        let poste = self.poste(ctx);
        copies::maj_raccourci_appli(ctx, &*poste, &a, self.occupee(id));
        self.arreter(
            ctx,
            effets,
            id,
            format!("Mindset ouvrira la copie de {dossier}. Elle se met à jour toute seule et garde son propre thème."),
            "utilisation",
        );
    }

    // -------------------------------------------------------------------------------------------------------------
    // Au démarrage de Mindset, et en quittant
    // -------------------------------------------------------------------------------------------------------------

    /// La part de `Start-Demarrage` (mindset.ps1:159-171) qui revient à ce bloc, et le mini-installateur au
    /// démarrage (parametres.ps1:515-526) : au premier tic.
    fn au_premier_tic(&mut self, ctx: &Contexte, effets: &mut Effets) {
        self.admin.tache_ok(ctx);
        if !self.complet(ctx) {
            return;
        }
        self.maj_raccourcis(ctx);
        self.reparer_demarrages(ctx);
        // (relancé depuis moins de 2 minutes : relance.marque, que le bloc « lui-même » efface)
        let marque = ctx.dossiers.donnees.join("relance.marque");
        let recente = std::fs::metadata(&marque)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| std::time::SystemTime::now().duration_since(t).ok())
            .is_some_and(|d| d.as_secs() < 120);
        if !recente {
            self.reprendre_taches_demarrage(ctx);
        }
        self.mini_installateur_au_demarrage(ctx, effets);
        self.relever(ctx);
    }

    /// Mindset installé, sans les droits : l'ancienne tâche se remplace (`Start-RemplacementTache`), ou les tâches
    /// d'avant sont refaites (`Start-RemiseEnOrdreTaches`).
    pub fn mini_installateur_au_demarrage(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let installe = chemins::egal(
            chemins::parent(&ctx.dossiers.fichiers.to_string_lossy()),
            &ctx.dossiers.mindset_installe().to_string_lossy(),
        );
        if !installe || Self::mindset_admin(ctx) {
            return;
        }
        self.admin.tache_ok(ctx);
        match self.admin.etat_tache() {
            Some(mindset_noyau::installateur::EtatTache::Ancienne) => self.remplacer_tache(ctx, effets),
            Some(mindset_noyau::installateur::EtatTache::Systeme)
                if ctx.reglage_texte("TachesRefaitesPour", "") != ctx.version || self.taches_anciennes(ctx) =>
            {
                self.remettre_taches_en_ordre(ctx, effets)
            }
            _ => {}
        }
    }

    /// `Request-FermetureApplis` : chaque appli ouverte est priée de quitter.
    fn demander_fermeture_applis(&mut self, ctx: &Contexte) {
        for a in ctx.applis().iter() {
            if !appli_ouverte(ctx, a) {
                continue;
            }
            copies::ecrire_demande_quitter(ctx, a);
            ctx.journal(&format!("Fermeture de {} demandée (Mindset quitte)", a.nom));
        }
    }

    /// Mindset.ps1:139-156 : 6 s pour que les applis se ferment, puis celles qui tournent encore sont arrêtées
    /// (seulement leur programme principal, trouvé par son chemin).
    fn fermer_applis_restantes(&mut self, ctx: &Contexte) {
        let a_fermer = || -> Vec<(String, u32)> {
            ctx.applis()
                .iter()
                .flat_map(|a| processus_appli(ctx, a, true).into_iter().map(|p| (a.nom.clone(), p.pid)))
                .collect()
        };
        let debut = std::time::Instant::now();
        while debut.elapsed() < Duration::from_secs(6) && !a_fermer().is_empty() && !ctx.essai {
            std::thread::sleep(Duration::from_millis(300));
        }
        let mut fermes: BTreeMap<String, u32> = BTreeMap::new();
        let mut refuses: BTreeMap<String, u32> = BTreeMap::new();
        for (nom, pid) in a_fermer() {
            match ctx.systeme().arreter(pid) {
                Ok(()) => *fermes.entry(nom).or_default() += 1,
                Err(_) => *refuses.entry(nom).or_default() += 1,
            }
        }
        for (n, k) in fermes {
            let plus = if k > 1 { format!(" ({k} processus)") } else { String::new() };
            ctx.journal(&format!("{n} ne répondait pas : fermé par Mindset{plus}"));
        }
        for n in refuses.keys() {
            ctx.journal(&format!("{n} tourne encore (fermeture refusée par Windows)"));
        }
    }
}

/// Le poste quand l'hôte crée le bloc : le vrai Windows, sauf en essai (aucun).
fn poste_par_defaut(ctx: &Contexte) -> Arc<dyn Poste> {
    #[cfg(windows)]
    if !ctx.essai {
        return Arc::new(windows::PosteWindows::nouveau());
    }
    let _ = ctx;
    Arc::new(poste::SansPoste)
}

/// La publication d'une appli, si elle donne une version à télécharger.
fn publication_prete(ctx: &Contexte, id: &str) -> Option<Value> {
    let p = partage::publication(ctx, id)?;
    if p.get("erreur").is_some_and(|e| !e.is_null()) {
        return None;
    }
    let v = p.get("version").and_then(Value::as_str).unwrap_or("");
    let z = p.get("url_zip").and_then(Value::as_str).unwrap_or("");
    (!v.is_empty() && !z.is_empty()).then_some(p)
}

fn taches_de(id: &str) -> &'static [&'static str] {
    TACHES_DEMARRAGE.iter().find(|(i, _)| *i == id).map(|(_, t)| *t).unwrap_or(&[])
}

/// Le réglage « Demarrage » (une liste d'id, ou un seul texte).
fn liste_demarrage(ctx: &Contexte) -> Vec<String> {
    match ctx.reglage("Demarrage") {
        Some(Value::Array(a)) => a.iter().map(suite_commun::protocole_installateur::texte_ps).collect(),
        Some(Value::Null) | None => Vec::new(),
        Some(v) => vec![suite_commun::protocole_installateur::texte_ps(&v)],
    }
}

/// `Get-DemarrageAppli` : « S'ouvre avec Mindset » (`-in` ne tient pas compte des majuscules).
pub fn demarrage_appli(ctx: &Contexte, id: &str) -> bool {
    liste_demarrage(ctx).iter().any(|x| x.eq_ignore_ascii_case(id))
}

/// `[IO.Path]::GetPathRoot` : « C:\ », ou « \\serveur\partage ».
pub fn racine(chemin: &str) -> String {
    let o = chemin.as_bytes();
    if o.len() >= 2 && o[1] == b':' {
        return if o.len() >= 3 && (o[2] == b'\\' || o[2] == b'/') {
            chemin[..3].to_string()
        } else {
            chemin[..2].to_string()
        };
    }
    if let Some(r) = chemin.strip_prefix(r"\\") {
        let mut morceaux = r.splitn(3, '\\');
        let serveur = morceaux.next().unwrap_or("");
        let partage = morceaux.next().unwrap_or("");
        return if partage.is_empty() { format!(r"\\{serveur}") } else { format!(r"\\{serveur}\{partage}") };
    }
    if chemin.starts_with('\\') { "\\".into() } else { String::new() }
}

/// `[math]::Round($x, 1)` écrit comme PowerShell dans un texte (« 1.5 », « 2 »).
pub fn arrondi_1(x: f64) -> String {
    let d = x * 10.0;
    let r = d.round();
    let r = if (d - d.trunc()).abs() == 0.5 && r % 2.0 != 0.0 { r - d.signum() } else { r };
    let v = r / 10.0;
    if v.fract() == 0.0 { format!("{}", v as i64) } else { format!("{v}") }
}

/// Le nombre de fichiers et leur taille (liens non suivis).
pub fn mesurer(d: &Path) -> (u64, u64) {
    let Ok(l) = std::fs::read_dir(d) else { return (0, 0) };
    let (mut n, mut t) = (0, 0);
    for e in l.flatten() {
        let p = e.path();
        let Ok(m) = std::fs::symlink_metadata(&p) else { continue };
        if regles::est_lien(&p) == Some(true) {
            continue;
        }
        if m.is_dir() {
            let (a, b) = mesurer(&p);
            n += a;
            t += b;
        } else {
            n += 1;
            t += m.len();
        }
    }
    (n, t)
}

/// Le travail du déplacement des données d'un disque à l'autre : copie à côté, vérifiée (nombre de fichiers et
/// taille), renommée d'un bloc, puis l'ancien dossier supprimé. Rend le message en plus (« » ou l'ancien dossier pas
/// supprimé).
pub fn copier_donnees(poste: &dyn Poste, src: &str, dest: &str) -> Result<Value, String> {
    let dest_p = Path::new(dest);
    if let Some(p) = dest_p.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    let tmp = PathBuf::from(format!("{dest}.copie"));
    if tmp.exists() {
        copies::supprimer_sans_liens(&tmp).map_err(|e| e.to_string())?;
    }
    let incomplete = format!("la copie de {src} n'est pas complète : les données restent à leur place.");
    let copie = poste.copier_dossier(Path::new(src), &tmp);
    if copie.is_err() || mesurer(Path::new(src)) != mesurer(&tmp) {
        let _ = copies::supprimer_sans_liens(&tmp);
        return Err(incomplete);
    }
    std::fs::rename(&tmp, dest_p).map_err(|e| e.to_string())?;
    match copies::supprimer_sans_liens(Path::new(src)) {
        Ok(()) => Ok(Value::String(String::new())),
        Err(_) => Ok(Value::String(format!(
            "L'ancien dossier {src} n'a pas pu être supprimé (un fichier est ouvert) : supprime-le plus tard."
        ))),
    }
}

fn texte_de(v: &Value, k: &str) -> String {
    v.get(k).map(suite_commun::protocole_installateur::texte_ps).unwrap_or_default()
}

impl Bloc for BlocInstallations {
    fn nom(&self) -> &'static str {
        "installations"
    }

    fn demarrer(&mut self, ctx: &Contexte, effets: &mut Effets) {
        self.poste(ctx);
        self.relever(ctx);
        self.publier(ctx, effets);
        self.chercher_trouvees(ctx, effets);
    }

    // (Audit du 08/11, M7 : ces actions viennent de la page. Une page compromise ne doit pouvoir ni donner un chemin,
    // ni désinstaller sans la question. Elle ne fait que nommer l'appli : le dossier est une copie déjà trouvée par
    // Mindset, et la désinstallation passe par la question de la carte, posée côté Rust. Les blocs, eux, passent par
    // les signaux installer, utiliser-trouvee et desinstaller, qui gardent leurs paramètres.)
    fn action(&mut self, ctx: &Contexte, id: &str, valeur: &Value, effets: &mut Effets) -> bool {
        let appli = |v: &Value| v.as_str().map(str::to_string).unwrap_or_else(|| texte_de(v, "id"));
        match id {
            "installations:installer" => {
                let id = appli(valeur);
                let ancien = valeur.get("ancien").and_then(Value::as_str).filter(|d| !d.is_empty());
                match ancien {
                    Some(d) if !self.copie_connue(ctx, &id, d) => {
                        ctx.journal(&format!("Écran : installation de {id} refusée (copie inconnue de Mindset)"));
                        return true;
                    }
                    _ => self.installer(ctx, effets, &id, ancien.map(str::to_string), false),
                }
            }
            "installations:desinstaller" => {
                let id = appli(valeur);
                effets.ajouter(Effet::Action {
                    id: "ecrans:carte".into(),
                    valeur: json!({ "id": id, "quoi": "desinstaller" }),
                });
            }
            "installations:utiliser" => {
                let id = appli(valeur);
                let donne = texte_de(valeur, "dossier");
                match self.trouvees.get(&id).cloned() {
                    Some(d) if donne.is_empty() || chemins::egal(&donne, &d) => {
                        self.utiliser_trouvee(ctx, effets, &id, &d)
                    }
                    _ => {
                        ctx.journal(&format!("Écran : copie de {id} refusée (pas une copie trouvée par Mindset)"));
                        return true;
                    }
                }
            }
            "installations:demarrage" => {
                let oui = valeur.get("oui").is_some_and(suite_commun::protocole_installateur::vrai_ps);
                self.mettre_demarrage(ctx, &appli(valeur), oui)
            }
            _ => return false,
        }
        self.publier(ctx, effets);
        true
    }

    fn tic(&mut self, ctx: &Contexte, effets: &mut Effets) -> Option<Duration> {
        if !self.premier_tic {
            self.premier_tic = true;
            self.au_premier_tic(ctx, effets);
        }
        self.maj_attentes_admin(ctx, effets);
        self.attendre_fermetures(ctx, effets);
        self.attendre_desinstalleur(ctx, effets);
        for (id, (ancien, debut)) in self.attentes_publication.clone() {
            if ctx.ecoule().saturating_sub(debut) >= DELAI_PUBLICATION {
                self.attentes_publication.remove(&id);
                let _ = ancien;
                self.complete_telechargement(
                    ctx,
                    effets,
                    &id,
                    None,
                    Err("la version publiée n'a pas pu être lue sur GitHub : réessaie plus tard.".into()),
                );
            }
        }
        let rythme = if ctx.vue().cachee() { Duration::from_secs(30) } else { Duration::from_secs(2) };
        if self.dernier_releve.is_none_or(|d| ctx.ecoule().saturating_sub(d) >= rythme) {
            self.relever(ctx);
        }
        self.publier(ctx, effets);
        let mut delai = rythme;
        if !self.admin.vide() {
            delai = delai.min(Duration::from_millis(500));
        }
        if !self.attentes_fermeture.is_empty() {
            delai = delai.min(Duration::from_millis(300));
        }
        if self.attente_desinstall.is_some() || !self.attentes_publication.is_empty() {
            delai = delai.min(Duration::from_secs(1));
        }
        if !self.progres.is_empty() {
            delai = delai.min(Duration::from_millis(500));
        }
        Some(delai)
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, d: &Value, effets: &mut Effets) {
        let id = texte_de(d, "id");
        match nom {
            signaux::INSTALLER => {
                let ancien = d.get("ancien").and_then(Value::as_str).map(str::to_string);
                let auto = d.get("auto").is_some_and(suite_commun::protocole_installateur::vrai_ps);
                self.installer(ctx, effets, &id, ancien, auto);
            }
            signaux::DESINSTALLER => self.desinstaller(ctx, effets, &id),
            signaux::UTILISER_TROUVEE => self.utiliser_trouvee(ctx, effets, &id, &texte_de(d, "dossier")),
            signaux::LANCER_APPLI => {
                let demarrage = d.get("demarrage").is_some_and(suite_commun::protocole_installateur::vrai_ps);
                self.ouvrir_appli(ctx, &id, demarrage);
            }
            signaux::DEMANDE_QUITTER => {
                if let Some(a) = Self::appli(ctx, &id) {
                    copies::ecrire_demande_quitter(ctx, &a);
                }
            }
            signaux::DEMARRAGE_APPLI => {
                let oui = d.get("oui").is_some_and(suite_commun::protocole_installateur::vrai_ps);
                if Self::appli(ctx, &id).is_some() {
                    self.mettre_demarrage(ctx, &id, oui);
                }
            }
            signaux::ADMIN_DEMANDE => self.demande_externe(ctx, effets, d),
            signaux::PUBLICATIONS_CHANGEES => self.publications_changees(ctx, effets),
            signaux::QUITTER => {
                if d.get("avec_applis").is_some_and(suite_commun::protocole_installateur::vrai_ps) {
                    self.fermer_applis = true;
                    self.demander_fermeture_applis(ctx);
                }
            }
            _ => return,
        }
        self.publier(ctx, effets);
    }

    fn tache_finie(&mut self, ctx: &Contexte, id: &str, resultat: Result<Value, String>, effets: &mut Effets) {
        if id == "trouvees" {
            self.recherche_trouvees = false;
            if let Ok(Value::Object(m)) = resultat {
                self.trouvees = m
                    .into_iter()
                    .filter(|(k, _)| !self.connues.contains_key(k))
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect();
            }
        } else if let Some(reste) = id.strip_prefix("telechargement:") {
            let (appli, ancien) = reste.split_once(':').unwrap_or((reste, ""));
            let ancien = (!ancien.is_empty()).then(|| ancien.to_string());
            if let Ok(v) = &resultat {
                self.dernieres_versions.insert(appli.into(), texte_de(v, "version"));
            }
            self.complete_telechargement(ctx, effets, appli, ancien, resultat);
        } else if let Some(appli) = id.strip_prefix("donnees:") {
            self.donnees_deplacees(ctx, effets, appli, resultat);
        }
        self.publier(ctx, effets);
    }

    fn fermer(&mut self, ctx: &Contexte) {
        if self.fermer_applis && self.complet(ctx) {
            self.fermer_applis_restantes(ctx);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        assert_eq!(BlocInstallations::default().nom(), "installations");
    }

    #[test]
    fn racines_et_arrondis() {
        assert_eq!(racine(r"C:\Users\x"), r"C:\");
        assert_eq!(racine(r"D:\"), r"D:\");
        assert_eq!(racine(r"\\pc\partage\x"), r"\\pc\partage");
        assert_eq!(arrondi_1(1.25), "1.2");
        assert_eq!(arrondi_1(1.35), "1.4");
        assert_eq!(arrondi_1(2.0), "2");
        assert_eq!(arrondi_1(0.04), "0");
    }
}
