//! Le contexte donné à chaque bloc : les dossiers, la version, comment Mindset a été lancé, les ports (disque, réseau,
//! mini-installateur, Windows), la liste des applis, le tableau commun, la vue (fenêtre et page montrées), l'heure.
//!
//! Il est créé une fois par l'hôte et vit sur le fil des blocs ; tout ce qui change est derrière un verrou, pour que
//! les ports (des `Arc`) puissent être emportés par un travail de fond. Aucun verrou n'est gardé pendant un appel à un
//! port.

use serde_json::{Map, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::{Duration, Instant};

use crate::appli::Appli;
use crate::donnees::{Donnees, Dossiers};
use crate::installateur::Installateur;
use crate::moment::{self, HeureLocale};
use crate::reseau::Reseau;
use crate::systeme::Systeme;

pub(crate) fn verrou<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Comment Mindset a été lancé (Mindset.ps1:13-33).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Lancement {
    /// `-Demarrage` : lancé avec Windows (ou relancé par le mini-installateur), caché près de l'horloge
    pub demarrage: bool,
    /// `-Desinstaller` : depuis « Applications installées »
    pub desinstaller: bool,
    /// Mindset tourne avec les droits administrateur (`$EstAdmin`, `$MindsetAdmin`)
    pub admin: bool,
}

/// Ce que l'utilisateur voit, tenu à jour par l'hôte.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Vue {
    /// La fenêtre est montrée (pas cachée près de l'horloge)
    pub visible: bool,
    /// La fenêtre est réduite dans la barre des tâches
    pub reduite: bool,
    /// La page montrée (`$script:PageCourante`) : « accueil », « parametres » ou l'id d'une appli
    pub page: String,
}

impl Default for Vue {
    fn default() -> Vue {
        Vue { visible: false, reduite: false, page: "accueil".into() }
    }
}

impl Vue {
    /// Personne ne regarde Mindset (caché ou réduit) : faire le moins possible (`Update-RythmeMinuteries`).
    pub fn cachee(&self) -> bool {
        !self.visible || self.reduite
    }
}

/// Les ports branchés par l'hôte (ou les faux d'un test : [`crate::essai`]).
#[derive(Clone)]
pub struct Ports {
    pub donnees: Arc<dyn Donnees>,
    pub reseau: Arc<dyn Reseau>,
    pub installateur: Arc<dyn Installateur>,
    pub systeme: Arc<dyn Systeme>,
}

/// L'horloge du contexte : l'heure locale, et le temps écoulé depuis le lancement (les deux figés en test).
enum Horloge {
    Vraie { debut: Instant },
    Figee { heure: HeureLocale, ecoule: Duration },
}

pub struct Contexte {
    /// Les dossiers de Mindset
    pub dossiers: Dossiers,
    /// La version de Mindset (`$AppVersion`)
    pub version: String,
    /// Comment Mindset a été lancé
    pub lancement: Lancement,
    /// Mode essai : rien ne touche le vrai PC (les ports sont des faux, les dossiers sont des dossiers d'essai)
    pub essai: bool,
    ports: Ports,
    pid: u32,
    applis: RwLock<Arc<Vec<Appli>>>,
    partage: Mutex<Map<String, Value>>,
    vue: Mutex<Vue>,
    fenetre: Mutex<Option<isize>>,
    bloc: Mutex<Option<&'static str>>,
    horloge: Mutex<Horloge>,
}

impl Contexte {
    /// Le contexte de Mindset. `pid` : le numéro de son processus (`$PID`).
    pub fn nouveau(
        dossiers: Dossiers,
        version: &str,
        lancement: Lancement,
        essai: bool,
        ports: Ports,
        pid: u32,
    ) -> Contexte {
        Contexte {
            dossiers,
            version: version.to_string(),
            lancement,
            essai,
            ports,
            pid,
            applis: RwLock::new(Arc::new(Vec::new())),
            partage: Mutex::new(Map::new()),
            vue: Mutex::new(Vue::default()),
            fenetre: Mutex::new(None),
            bloc: Mutex::new(None),
            horloge: Mutex::new(Horloge::Vraie { debut: Instant::now() }),
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Les ports
    // -----------------------------------------------------------------------------------------------------------

    /// Le disque (journal, réglages, JSON sûrs, suite.json).
    pub fn donnees(&self) -> Arc<dyn Donnees> {
        Arc::clone(&self.ports.donnees)
    }
    /// Internet (GitHub).
    pub fn reseau(&self) -> Arc<dyn Reseau> {
        Arc::clone(&self.ports.reseau)
    }
    /// Le mini-installateur (seul le bloc « installations » s'en sert).
    pub fn installateur(&self) -> Arc<dyn Installateur> {
        Arc::clone(&self.ports.installateur)
    }
    /// Windows (programmes, verrous, lancements).
    pub fn systeme(&self) -> Arc<dyn Systeme> {
        Arc::clone(&self.ports.systeme)
    }
    /// Le numéro du processus de Mindset (`$PID`).
    pub fn pid(&self) -> u32 {
        self.pid
    }

    // -----------------------------------------------------------------------------------------------------------
    // Le journal et les réglages (raccourcis vers le disque)
    // -----------------------------------------------------------------------------------------------------------

    /// `Write-Log`
    pub fn journal(&self, texte: &str) {
        self.ports.donnees.journal(texte);
    }
    /// `Get-Setting <nom>` (`None` s'il n'existe pas)
    pub fn reglage(&self, nom: &str) -> Option<Value> {
        self.ports.donnees.reglage(nom)
    }
    /// `Get-Setting <nom> <défaut>`
    pub fn reglage_ou(&self, nom: &str, defaut: Value) -> Value {
        self.reglage(nom).unwrap_or(defaut)
    }
    /// `[bool](Get-Setting <nom> <défaut>)`, vrai au sens de PowerShell (`$null`, 0, « », tableau vide : faux)
    pub fn reglage_bool(&self, nom: &str, defaut: bool) -> bool {
        match self.reglage(nom) {
            Some(v) => suite_commun::protocole_installateur::vrai_ps(&v),
            None => defaut,
        }
    }
    /// `[string](Get-Setting <nom> <défaut>)`
    pub fn reglage_texte(&self, nom: &str, defaut: &str) -> String {
        match self.reglage(nom) {
            Some(v) => suite_commun::protocole_installateur::texte_ps(&v),
            None => defaut.to_string(),
        }
    }
    /// `Set-Setting`
    pub fn ecrire_reglage(&self, nom: &str, valeur: Value) {
        self.ports.donnees.ecrire_reglage(nom, valeur);
    }

    // -----------------------------------------------------------------------------------------------------------
    // La liste des applis
    // -----------------------------------------------------------------------------------------------------------

    /// La liste des applis (`$Applis`), vide tant que le bloc « liste » ne l'a pas donnée.
    pub fn applis(&self) -> Arc<Vec<Appli>> {
        Arc::clone(&self.applis.read().unwrap_or_else(|e| e.into_inner()))
    }
    /// `Get-Appli <id>`
    pub fn appli(&self, id: &str) -> Option<Appli> {
        self.applis().iter().find(|a| a.id == id).cloned()
    }
    /// Le bloc « liste » donne la liste, une fois, au démarrage (elle ne change plus ensuite : une nouvelle liste en
    /// ligne sert au prochain démarrage, applis.ps1:41-44).
    pub fn definir_applis(&self, l: Vec<Appli>) {
        *self.applis.write().unwrap_or_else(|e| e.into_inner()) = Arc::new(l);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Le tableau commun
    // -----------------------------------------------------------------------------------------------------------

    /// L'hôte appelle un bloc : ce qu'il publie pendant `f` est à son nom (et contrôlé).
    pub fn au_nom_de<R>(&self, bloc: &'static str, f: impl FnOnce() -> R) -> R {
        let avant = verrou(&self.bloc).replace(bloc);
        let r = f();
        *verrou(&self.bloc) = avant;
        r
    }

    /// Le bloc appelé en ce moment (`None` : l'hôte lui-même).
    pub fn bloc_courant(&self) -> Option<&'static str> {
        *verrou(&self.bloc)
    }

    /// Écrit une clé du tableau commun (voir [`crate::partage`]). Refusé, et noté au journal, si la clé est inconnue
    /// ou appartient à un autre bloc.
    pub fn publier(&self, cle: &str, valeur: Value) {
        let courant = self.bloc_courant();
        match (crate::partage::proprietaire(cle), courant) {
            (Some(p), Some(b)) if p != b => {
                self.journal(&format!("Tableau commun : « {cle} » appartient au bloc {p}, refusé au bloc {b}"));
                return;
            }
            (None, _) => {
                self.journal(&format!("Tableau commun : clé inconnue « {cle} », refusée"));
                return;
            }
            _ => {}
        }
        verrou(&self.partage).insert(cle.to_string(), valeur);
    }

    /// Lit une clé du tableau commun (une copie).
    pub fn lu(&self, cle: &str) -> Option<Value> {
        verrou(&self.partage).get(cle).cloned()
    }

    // -----------------------------------------------------------------------------------------------------------
    // La vue et la fenêtre
    // -----------------------------------------------------------------------------------------------------------

    /// Ce que l'utilisateur voit.
    pub fn vue(&self) -> Vue {
        verrou(&self.vue).clone()
    }
    /// L'hôte tient la vue à jour (un bloc demande `Effet::Page` ou `Effet::Fenetre`, jamais ceci).
    pub fn definir_vue(&self, v: Vue) {
        *verrou(&self.vue) = v;
    }
    /// La fenêtre principale de Mindset (son `HWND`), une fois créée : pour accrocher les applis dedans.
    pub fn fenetre_principale(&self) -> Option<isize> {
        *verrou(&self.fenetre)
    }
    /// L'hôte donne la fenêtre principale.
    pub fn definir_fenetre(&self, h: Option<isize>) {
        *verrou(&self.fenetre) = h;
    }

    // -----------------------------------------------------------------------------------------------------------
    // L'heure
    // -----------------------------------------------------------------------------------------------------------

    /// L'heure locale (`Get-Date`), figée en test.
    pub fn heure(&self) -> HeureLocale {
        match &*verrou(&self.horloge) {
            Horloge::Vraie { .. } => suite_commun::json_sur::heure_du_pc(),
            Horloge::Figee { heure, .. } => *heure,
        }
    }
    /// L'heure locale au format `s` (« 2026-11-07T21:05:09 »).
    pub fn heure_iso(&self) -> String {
        moment::iso(&self.heure())
    }
    /// Le temps écoulé depuis le lancement de Mindset (pour les minuteries), figé en test.
    pub fn ecoule(&self) -> Duration {
        match &*verrou(&self.horloge) {
            Horloge::Vraie { debut } => debut.elapsed(),
            Horloge::Figee { ecoule, .. } => *ecoule,
        }
    }
    /// Tests : l'horloge s'arrête à cette heure, et le temps écoulé repart de zéro.
    pub fn figer_heure(&self, heure: HeureLocale) {
        *verrou(&self.horloge) = Horloge::Figee { heure, ecoule: Duration::ZERO };
    }
    /// Tests : l'horloge figée avance (l'heure et le temps écoulé).
    pub fn avancer(&self, d: Duration) {
        let mut h = verrou(&self.horloge);
        if let Horloge::Figee { heure, ecoule } = &mut *h {
            let total = ecoule.as_millis() as i64 + d.as_millis() as i64;
            let secondes = total / 1000 - ecoule.as_millis() as i64 / 1000;
            *heure = moment::ajouter(heure, secondes);
            *ecoule += d;
        }
    }

    /// Un dossier sous les données de Mindset (`$DataDir\<nom>`).
    pub fn dans_donnees(&self, nom: &str) -> PathBuf {
        self.dossiers.donnees.join(nom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reglages_et_heure() {
        let (ctx, f) = crate::essai::contexte("contexte");
        assert!(ctx.reglage_bool("MajAuto", true));
        ctx.ecrire_reglage("MajAuto", json!(false));
        assert!(!ctx.reglage_bool("MajAuto", true));
        ctx.ecrire_reglage("Demarrage", json!([]));
        assert!(!ctx.reglage_bool("Demarrage", true), "un tableau vide est faux, comme en PowerShell");
        assert_eq!(ctx.reglage_texte("Fermeture", "demander"), "demander");
        ctx.journal("une ligne");
        assert_eq!(f.donnees.lignes(), vec!["une ligne"]);
        let h = moment::lire_iso("2026-11-07T23:59:59").unwrap();
        ctx.figer_heure(h);
        ctx.avancer(Duration::from_millis(1500));
        assert_eq!(ctx.heure_iso(), "2026-11-08T00:00:00");
        ctx.avancer(Duration::from_millis(600));
        assert_eq!(ctx.heure_iso(), "2026-11-08T00:00:01");
        assert_eq!(ctx.ecoule(), Duration::from_millis(2100));
    }

    #[test]
    fn la_vue_et_les_applis() {
        let (ctx, _f) = crate::essai::contexte("contexte-vue");
        assert!(ctx.vue().cachee());
        ctx.definir_vue(Vue { visible: true, reduite: false, page: "parametres".into() });
        assert!(!ctx.vue().cachee());
        assert!(ctx.appli("evermind").is_none());
        ctx.definir_applis(vec![Appli { id: "evermind".into(), nom: "Evermind".into(), ..Default::default() }]);
        assert_eq!(ctx.appli("evermind").unwrap().nom, "Evermind");
        assert_eq!(ctx.au_nom_de("liste", || ctx.bloc_courant()), Some("liste"));
        assert_eq!(ctx.bloc_courant(), None);
    }
}
