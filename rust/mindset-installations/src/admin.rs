//! La file des demandes en administrateur (installations.ps1:231-476) : le mini-installateur (la tâche SYSTEM
//! « \Mindset\Mindset (installation) »), une demande à la fois, son accusé de réception en 30 s, sa réponse en
//! 10 minutes, et à défaut la demande normale de Windows (MindsetInstallateur.exe en administrateur, sa réponse dans
//! un fichier). `Get-EtatTacheInstallation` est au port (`Installateur::etat_tache`), le reste est ici :
//! `Test-TacheInstallation`, `Send-DemandeInstallation`, `Skip-TacheInstallation`, `Invoke-Admin`,
//! `Format-ArgumentAdmin`, `Get-RefusVariablesAdmin`, `Invoke-AdminDirect`, `Send-DemandeSuivante`,
//! `Update-AttentesAdmin`, `Start-RemplacementTache`, `Test-TachesAnciennes`, `Start-RemiseEnOrdreTaches`.
//!
//! Les autres blocs passent leurs demandes par le signal `admin-demande` ; ils reçoivent `admin-recu` (l'accusé de
//! réception) puis `admin-fini`.

use mindset_noyau::installateur::{Direct, EtatTache};
use mindset_noyau::{Contexte, Effets, signaux};
use serde_json::{Map, Value, json};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::time::Duration;
use suite_commun::protocole_installateur::{texte_ps, vrai_ps};

use crate::BlocInstallations;
use crate::regles::{argument_admin, refus_variables};

/// Le délai de l'accusé de réception de la tâche (`$DelaiAccuseTache`).
pub const DELAI_ACCUSE: Duration = Duration::from_secs(30);
/// Le délai de la réponse de la tâche (10 minutes).
pub const DELAI_REPONSE: Duration = Duration::from_secs(600);
/// Le délai de la réponse d'une demande de Windows (5 minutes après la fin de son programme... ou sans fin).
pub const DELAI_DIRECT: Duration = Duration::from_secs(300);

/// Ce qui est fait à la fin d'une demande.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fin {
    /// L'installation d'une appli (`Send-InstallationAppli`)
    Installation(String),
    /// La désinstallation d'une appli (`Start-DesinstallAppli`)
    Desinstallation(String),
    /// L'ancienne tâche se remplace par la tâche SYSTEM (`Start-RemplacementTache`)
    Remplacement,
    /// Les tâches d'avant sont refaites (`Start-RemiseEnOrdreTaches`)
    RemiseEnOrdre,
    /// La demande d'un autre bloc (`admin-demande`) : `admin-recu` et `admin-fini` avec son id
    Externe { id: String, action: String },
}

/// Une demande (`$D` : Contenu, Fin, Repli, Action, Parametres).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Demande {
    pub contenu: Map<String, Value>,
    pub action: String,
    pub parametres: Vec<(String, String)>,
    pub fin: Fin,
    /// Si la tâche ne marche pas : la demande de Windows (sinon l'opération est abandonnée)
    pub repli: bool,
    /// Le fichier de réponse voulu pour la demande de Windows (sinon `telechargements\admin-xxxxxxxx.json`)
    pub resultat: Option<String>,
}

#[derive(Debug, Clone)]
enum Attente {
    Tache { numero: u64, id: String, demande: Demande, debut: Duration, recu: bool },
    Direct { numero: u64, processus: u32, reponse: PathBuf, fin: Fin, debut: Duration },
}

impl Attente {
    fn numero(&self) -> u64 {
        match self {
            Attente::Tache { numero, .. } | Attente::Direct { numero, .. } => *numero,
        }
    }
}

/// La file (`$script:AttentesAdmin`, `$script:DemandesEnAttente`, `$script:TacheInstallationOk`).
#[derive(Debug)]
pub struct FileAdmin {
    attentes: Vec<Attente>,
    en_attente: VecDeque<Demande>,
    tache_ok: Option<bool>,
    etat: Option<EtatTache>,
    serie: u64,
    remplacement: Option<&'static str>,
}

impl FileAdmin {
    pub const NEUVE: FileAdmin = FileAdmin {
        attentes: Vec::new(),
        en_attente: VecDeque::new(),
        tache_ok: None,
        etat: None,
        serie: 0,
        remplacement: None,
    };

    /// `Test-TacheInstallation` : la tâche SYSTEM inscrite pour cet utilisateur est-elle là (lu une fois) ?
    pub fn tache_ok(&mut self, ctx: &Contexte) -> bool {
        if self.tache_ok.is_none() {
            let e = ctx.installateur().etat_tache();
            self.etat = Some(e);
            self.tache_ok = Some(e == EtatTache::Systeme);
        }
        self.tache_ok.unwrap_or(false)
    }

    /// `$script:TacheInstallationOk` : `None` tant que la tâche n'a pas été regardée.
    pub fn tache_connue(&self) -> Option<bool> {
        self.tache_ok
    }

    /// L'état de la tâche lu par `tache_ok`.
    pub fn etat_tache(&self) -> Option<EtatTache> {
        self.etat
    }

    /// Plus rien en cours ni en attente.
    pub fn vide(&self) -> bool {
        self.attentes.is_empty() && self.en_attente.is_empty()
    }

    /// La forme du tableau commun (`admin`).
    pub fn etat_publie(&self) -> Value {
        let tache = match (self.tache_ok, self.etat) {
            (Some(true), _) => "systeme",
            (_, Some(EtatTache::Ancienne)) => "ancienne",
            (Some(false), _) | (_, Some(_)) => "absente",
            (None, None) => "inconnue",
        };
        json!({ "tache": tache, "en_cours": self.attentes.len() + self.en_attente.len(),
                "remplacement": self.remplacement })
    }

    fn numero(&mut self) -> u64 {
        self.serie += 1;
        self.serie
    }
}

/// Un id de demande (32 chiffres hexadécimaux, comme `[guid]::NewGuid().ToString('N')`).
pub fn nouvel_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    use std::sync::atomic::{AtomicU64, Ordering};
    static COMPTEUR: AtomicU64 = AtomicU64::new(0);
    let mut morceaux = [0u64; 2];
    for m in &mut morceaux {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u64(COMPTEUR.fetch_add(1, Ordering::Relaxed));
        h.write_u128(
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0),
        );
        h.write_u32(std::process::id());
        *m = h.finish();
    }
    format!("{:016x}{:016x}", morceaux[0], morceaux[1])
}

impl BlocInstallations {
    /// `Invoke-Admin` : par la tâche si elle marche (une demande à la fois), sinon la demande de Windows. `auto` :
    /// une mise à jour automatique (pas de demande de Windows en repli : personne n'est là pour y répondre).
    #[allow(clippy::too_many_arguments)]
    pub fn invoquer_admin(
        &mut self,
        ctx: &Contexte,
        effets: &mut Effets,
        action: &str,
        parametres: Vec<(String, String)>,
        fin: Fin,
        auto: bool,
        resultat: Option<String>,
    ) {
        let _ = std::fs::create_dir_all(ctx.dossiers.telechargements());
        let parametres: Vec<(String, String)> = parametres.into_iter().filter(|(_, v)| !v.is_empty()).collect();
        if !ctx.lancement.admin && action != "mindset" && self.admin.tache_ok(ctx) {
            let mut c = Map::new();
            c.insert("Id".into(), Value::String(nouvel_id()));
            c.insert("Action".into(), Value::String(action.into()));
            for (k, v) in &parametres {
                c.insert(k.clone(), Value::String(v.clone()));
            }
            let d = Demande { contenu: c, action: action.into(), parametres, fin, repli: !auto, resultat };
            if self.admin.attentes.iter().any(|a| matches!(a, Attente::Tache { .. })) {
                self.admin.en_attente.push_back(d);
                return;
            }
            self.envoyer_demande(ctx, effets, d);
            return;
        }
        self.admin_direct(ctx, effets, action, &parametres, fin, resultat);
    }

    /// `Send-DemandeInstallation` : la demande déposée pour la tâche ; `false` si la tâche n'a pas démarré.
    pub fn envoyer_demande(&mut self, ctx: &Contexte, effets: &mut Effets, d: Demande) -> bool {
        let inst = ctx.installateur();
        if let Err(e) = inst.deposer(&Value::Object(d.contenu.clone())) {
            inst.retirer_demande();
            self.passer_tache(ctx, effets, d, &e);
            return false;
        }
        let id = d.contenu.get("Id").map(texte_ps).unwrap_or_default();
        let numero = self.admin.numero();
        self.admin.attentes.push(Attente::Tache { numero, id, demande: d, debut: ctx.ecoule(), recu: false });
        true
    }

    /// `Skip-TacheInstallation` : la tâche ne marche pas ; elle n'est plus utilisée jusqu'au prochain lancement, et
    /// l'opération passe par la demande de Windows (son repli) ou s'arrête.
    fn passer_tache(&mut self, ctx: &Contexte, effets: &mut Effets, d: Demande, raison: &str) {
        let suite = if d.repli { "demande de Windows à la place" } else { "opération abandonnée" };
        ctx.journal(&format!("Mini-installateur : {raison} ; {suite}"));
        self.admin.tache_ok = Some(false);
        if d.repli {
            self.admin_direct(ctx, effets, &d.action, &d.parametres, d.fin, d.resultat);
        } else {
            self.finir_admin(ctx, effets, d.fin, false, format!("la tâche d'installation ne répond pas ({raison})."));
        }
    }

    /// `Invoke-AdminDirect` : la demande normale de Windows, sa réponse dans un fichier.
    fn admin_direct(
        &mut self,
        ctx: &Contexte,
        effets: &mut Effets,
        action: &str,
        parametres: &[(String, String)],
        fin: Fin,
        resultat: Option<String>,
    ) {
        let rep = match resultat.filter(|r| !r.is_empty()) {
            Some(r) => PathBuf::from(r),
            None => ctx.dossiers.telechargements().join(format!("admin-{}.json", &nouvel_id()[..8])),
        };
        let poste = self.poste(ctx);
        let mut noms = poste.variables_processus();
        noms.extend(poste.variables_compte());
        if let Some((journal, message)) = refus_variables(&noms) {
            ctx.journal(&journal);
            return self.finir_admin(ctx, effets, fin, false, message);
        }
        // (un guillemet dans une valeur : refusé avant de rien lancer)
        let r = std::iter::once(rep.to_string_lossy().into_owned())
            .chain(parametres.iter().map(|(_, v)| v.clone()))
            .try_for_each(|v| argument_admin(&v).map(|_| ()));
        if let Err(e) = r {
            return self.finir_admin(ctx, effets, fin, false, e);
        }
        let demande = Direct {
            action: action.into(),
            parametres: parametres.iter().filter(|(_, v)| !v.is_empty()).cloned().collect(),
            resultat: rep.clone(),
        };
        match ctx.installateur().lancer_direct(&demande) {
            Err(_) => self.finir_admin(ctx, effets, fin, false, "l'autorisation de Windows a été refusée.".into()),
            Ok(processus) => {
                // (une demande de Windows lancée vaut accusé de réception : la mise à jour de Mindset se ferme alors,
                // comme Start-MajMindsetDirecte)
                if let Fin::Externe { id, .. } = &fin {
                    effets.signal(signaux::ADMIN_RECU, json!({ "id": id, "direct": true }));
                }
                let numero = self.admin.numero();
                self.admin.attentes.push(Attente::Direct { numero, processus, reponse: rep, fin, debut: ctx.ecoule() });
            }
        }
    }

    /// `Send-DemandeSuivante`
    fn demande_suivante(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let Some(s) = self.admin.en_attente.pop_front() else { return };
        if self.admin.tache_ok(ctx) {
            self.envoyer_demande(ctx, effets, s);
        } else if s.repli {
            self.admin_direct(ctx, effets, &s.action, &s.parametres, s.fin, s.resultat);
        } else {
            self.finir_admin(ctx, effets, s.fin, false, "la tâche d'installation ne répond pas.".into());
        }
    }

    fn retirer_attente(&mut self, numero: u64) {
        self.admin.attentes.retain(|a| a.numero() != numero);
    }

    /// `Update-AttentesAdmin` (toutes les 500 ms tant qu'une demande est en cours).
    pub fn maj_attentes_admin(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let inst = ctx.installateur();
        let numeros: Vec<u64> = self.admin.attentes.iter().map(Attente::numero).collect();
        for n in numeros {
            let Some(w) = self.admin.attentes.iter().find(|a| a.numero() == n).cloned() else { continue };
            match w {
                Attente::Tache { numero, id, demande, debut, recu } => {
                    // Sa réponse, reconnue à son numéro
                    let r = suite_commun::protocole_installateur::lire_json(&inst.valeur("Resultat"))
                        .filter(|r| r.get("id").map(texte_ps).as_deref() == Some(id.as_str()));
                    if r.is_none() {
                        let ecoule = ctx.ecoule().saturating_sub(debut);
                        let mut recu = recu;
                        if !recu && inst.valeur("Recu") == id {
                            recu = true;
                            self.noter_recu(numero);
                            self.accuse(ctx, effets, &demande);
                        }
                        if !recu && ecoule >= DELAI_ACCUSE {
                            // Pas d'accusé de réception : la demande est retirée, puis on regarde une dernière fois
                            inst.retirer_demande();
                            if inst.valeur("Recu") == id {
                                self.noter_recu(numero);
                                continue;
                            }
                            self.retirer_attente(numero);
                            self.passer_tache(ctx, effets, demande, "pas de réponse de la tâche en 30 secondes");
                            self.demande_suivante(ctx, effets);
                            continue;
                        }
                        if ecoule < DELAI_REPONSE {
                            continue;
                        }
                    }
                    self.retirer_attente(numero);
                    inst.retirer_demande();
                    match r {
                        Some(r) => {
                            let ok = r.get("ok").is_some_and(vrai_ps);
                            let m = r.get("message").map(texte_ps).unwrap_or_default();
                            self.finir_admin(ctx, effets, demande.fin, ok, m);
                        }
                        None => self.finir_admin(
                            ctx,
                            effets,
                            demande.fin,
                            false,
                            "pas de réponse du mini-installateur (opération interrompue ?).".into(),
                        ),
                    }
                    self.demande_suivante(ctx, effets);
                }
                Attente::Direct { numero, processus, reponse, fin, debut } => {
                    let fini = inst.direct_fini(processus);
                    if !fini && ctx.ecoule().saturating_sub(debut) < DELAI_DIRECT {
                        continue;
                    }
                    self.retirer_attente(numero);
                    let r = std::fs::read(&reponse).ok().and_then(|o| {
                        suite_commun::protocole_installateur::lire_json(&suite_commun::json_sur::texte_du_fichier(&o))
                    });
                    if r.is_some() {
                        let _ = std::fs::remove_file(&reponse);
                    }
                    match r {
                        Some(r) => {
                            let ok = r.get("ok").is_some_and(vrai_ps);
                            let m = r.get("message").map(texte_ps).unwrap_or_default();
                            self.finir_admin(ctx, effets, fin, ok, m);
                        }
                        None => self.finir_admin(
                            ctx,
                            effets,
                            fin,
                            false,
                            "pas de réponse (opération interrompue ?).".into(),
                        ),
                    }
                }
            }
        }
    }

    fn noter_recu(&mut self, numero: u64) {
        for a in &mut self.admin.attentes {
            if let Attente::Tache { numero: n, recu, .. } = a
                && *n == numero
            {
                *recu = true;
            }
        }
    }

    /// L'accusé de réception de la tâche (`$D.Recu`).
    fn accuse(&mut self, _ctx: &Contexte, effets: &mut Effets, d: &Demande) {
        if let Fin::Externe { id, .. } = &d.fin {
            effets.signal(signaux::ADMIN_RECU, json!({ "id": id }));
        }
    }

    /// La fin d'une demande (`& $w.Fin $ok $message`).
    fn finir_admin(&mut self, ctx: &Contexte, effets: &mut Effets, fin: Fin, ok: bool, message: String) {
        match fin {
            Fin::Installation(id) => {
                if ok {
                    self.complete_installation(ctx, effets, &id, &message);
                } else {
                    self.arreter(ctx, effets, &id, format!("Échec : {message}"), "installation");
                }
            }
            Fin::Desinstallation(id) => {
                if ok {
                    self.complete_desinstallation(ctx, effets, &id);
                } else {
                    self.arreter(
                        ctx,
                        effets,
                        &id,
                        format!("Désinstallation impossible : {message}"),
                        "desinstallation",
                    );
                }
            }
            Fin::Remplacement => {
                if ok {
                    ctx.journal("Mini-installateur : l'ancienne tâche est remplacée par la tâche SYSTEM");
                } else {
                    ctx.journal(&format!("Mini-installateur : l'ancienne tâche n'a pas pu être remplacée ({message})"));
                }
                self.admin.tache_ok = None;
                let bon = self.admin.tache_ok(ctx) && ok;
                self.admin.remplacement = Some(if bon { "ok" } else { "echec" });
            }
            Fin::RemiseEnOrdre => {
                if ok {
                    ctx.journal("Mini-installateur : tâches refaites (parties administrateur en SYSTEM, plus de très vieille tâche)");
                    ctx.ecrire_reglage("TachesRefaitesPour", Value::String(ctx.version.clone()));
                } else {
                    ctx.journal(&format!("Mini-installateur : les tâches n'ont pas pu être refaites ({message})"));
                }
            }
            Fin::Externe { id, action } => {
                // (Enable-MindsetAdmin : la tâche est là une fois l'activation réussie)
                if ok && action == "taches" {
                    self.admin.tache_ok = Some(true);
                    self.admin.etat = Some(EtatTache::Systeme);
                }
                let tache = self.admin.etat_publie()["tache"].clone();
                effets.signal(signaux::ADMIN_FINI, json!({ "id": id, "ok": ok, "message": message, "tache": tache }));
            }
        }
    }

    /// `Start-RemplacementTache` : l'ancienne tâche sert une dernière fois, à se remplacer par la tâche SYSTEM.
    pub fn remplacer_tache(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let mut c = Map::new();
        c.insert("Id".into(), Value::String(nouvel_id()));
        c.insert("Action".into(), Value::String("taches".into()));
        c.insert("Destination".into(), Value::String(ctx.dossiers.mindset_installe().to_string_lossy().into_owned()));
        self.admin.remplacement = Some("en_cours");
        let d = Demande {
            contenu: c,
            action: "taches".into(),
            parametres: Vec::new(),
            fin: Fin::Remplacement,
            repli: false,
            resultat: None,
        };
        self.envoyer_demande(ctx, effets, d);
    }

    /// `Test-TachesAnciennes` : une partie administrateur d'appli sous le compte de l'utilisateur, ou la très vieille
    /// tâche « \Mindset\Mindset ».
    pub fn taches_anciennes(&mut self, ctx: &Contexte) -> bool {
        let poste = self.poste(ctx);
        let moi = poste.sid();
        let inst = ctx.installateur();
        for a in ctx.applis().iter() {
            if a.aide.is_empty() {
                continue;
            }
            if inst.compte_tache(&a.aide).is_some_and(|c| c == moi) {
                return true;
            }
        }
        inst.compte_tache("Mindset").is_some()
    }

    /// `Start-RemiseEnOrdreTaches` : une demande « taches » par la tâche SYSTEM, sans fenêtre.
    pub fn remettre_taches_en_ordre(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let mut c = Map::new();
        c.insert("Id".into(), Value::String(nouvel_id()));
        c.insert("Action".into(), Value::String("taches".into()));
        c.insert("Destination".into(), Value::String(ctx.dossiers.mindset_installe().to_string_lossy().into_owned()));
        ctx.journal(
            "Mini-installateur : tâches à refaire (tâches d'avant, ou nouvelle version de Mindset), demande « taches »",
        );
        let d = Demande {
            contenu: c,
            action: "taches".into(),
            parametres: Vec::new(),
            fin: Fin::RemiseEnOrdre,
            repli: false,
            resultat: None,
        };
        self.envoyer_demande(ctx, effets, d);
    }

    /// Le signal `admin-demande` d'un autre bloc : `{ id, action, parametres: {..}, repli, auto, resultat? }`.
    pub fn demande_externe(&mut self, ctx: &Contexte, effets: &mut Effets, d: &Value) {
        let id = d.get("id").map(texte_ps).unwrap_or_default();
        let action = d.get("action").map(texte_ps).unwrap_or_default();
        if id.is_empty() || action.is_empty() {
            ctx.journal("Demande en administrateur refusée : sans id ou sans action");
            return;
        }
        let parametres: Vec<(String, String)> = match d.get("parametres") {
            Some(Value::Object(m)) => {
                m.iter().filter(|(_, v)| !v.is_null()).map(|(k, v)| (k.clone(), texte_ps(v))).collect()
            }
            _ => Vec::new(),
        };
        let repli = d.get("repli").is_none_or(vrai_ps);
        let auto = d.get("auto").is_some_and(vrai_ps) || !repli;
        let resultat = d.get("resultat").map(texte_ps).filter(|r| !r.is_empty());
        let fin = Fin::Externe { id, action: action.clone() };
        self.invoquer_admin(ctx, effets, &action, parametres, fin, auto, resultat);
    }
}
