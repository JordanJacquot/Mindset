//! Le vrai disque de Mindset (le trait `Donnees` du noyau) : le journal, les réglages, les fichiers JSON sûrs et
//! suite.json, exactement comme donnees.ps1 et suite.ps1.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use mindset_noyau::donnees::{Donnees, Dossiers, Suite};
use mindset_noyau::moment;
use serde_json::{Map, Value};
use suite_commun::json_sur::{self, Horloge, Options};

use crate::reglages::{self, REGLAGES_PRUDENTS};
use crate::{json_ps, suite};

fn verrou<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Les réglages en mémoire (`$script:Settings`, `$script:ReglagesChanges`, `$script:ReglagesIllisibles`,
/// `$script:ReglagesRepris`).
#[derive(Debug, Default)]
struct EtatReglages {
    valeurs: Map<String, Value>,
    changes: Vec<String>,
    illisibles: bool,
    repris: bool,
}

/// Ce qu'a donné `Read-JsonSur` : l'objet, ou rien (et le texte abîmé), ou une erreur (le fichier ne se lit pas).
struct LuSur {
    valeur: Option<Map<String, Value>>,
    abime: Option<String>,
}

/// Le disque de Mindset.
pub struct DisqueMindset {
    dossiers: Dossiers,
    /// `%LOCALAPPDATA%` (Evermind et l'ancien OptiGame y ont leurs réglages)
    localappdata: PathBuf,
    /// Construction d'essai : rien n'est lu ni écrit hors de ce dossier.
    garde: Option<PathBuf>,
    /// L'heure locale (journal, `modifie` de suite.json, noms `.abime-<date>`)
    horloge: Horloge,
    options: Options,
    journal: Mutex<()>,
    reglages: Mutex<EtatReglages>,
}

impl std::fmt::Debug for DisqueMindset {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DisqueMindset")
            .field("dossiers", &self.dossiers)
            .field("garde", &self.garde)
            .finish_non_exhaustive()
    }
}

impl DisqueMindset {
    /// Le disque de ces dossiers. Les réglages ne sont pas encore lus ([`DisqueMindset::lire_reglages_au_demarrage`]).
    pub fn nouveau(
        dossiers: Dossiers,
        localappdata: PathBuf,
        garde: Option<PathBuf>,
        horloge: Horloge,
    ) -> DisqueMindset {
        let options = Options { horloge: horloge.clone(), ..Options::default() };
        DisqueMindset {
            dossiers,
            localappdata,
            garde,
            horloge,
            options,
            journal: Mutex::new(()),
            reglages: Mutex::new(EtatReglages::default()),
        }
    }

    pub fn dossiers(&self) -> &Dossiers {
        &self.dossiers
    }

    /// L'heure locale de ce disque.
    pub fn heure(&self) -> moment::HeureLocale {
        (self.horloge)()
    }

    /// Tous les réglages en mémoire (`$script:Settings`).
    pub fn reglages(&self) -> Map<String, Value> {
        verrou(&self.reglages).valeurs.clone()
    }

    /// (`$script:ReglagesIllisibles`, `$script:ReglagesRepris`)
    pub fn etat_reglages(&self) -> (bool, bool) {
        let e = verrou(&self.reglages);
        (e.illisibles, e.repris)
    }

    /// Un fichier hors du dossier d'essai, dans la construction d'essai : refusé (et noté).
    fn hors_essai(&self, fichier: &Path) -> bool {
        match &self.garde {
            Some(g) if !fichier.starts_with(g) => {
                self.journal(&format!("Essai : {} est hors du dossier d'essai, refusé", fichier.display()));
                true
            }
            _ => false,
        }
    }

    /// `Read-JsonSur` (donnees.ps1:114-153), avec le texte du fichier abîmé (`$script:JsonAbime`).
    fn lire_sur(&self, fichier: &Path) -> Result<LuSur, String> {
        if self.hors_essai(fichier) {
            return Err(format!("{} ne peut pas être lu (hors du dossier d'essai)", fichier.display()));
        }
        match json_sur::lire_avec(fichier, true, &self.options) {
            Ok(l) if l.journal.is_empty() && l.valeur.as_ref().is_some_and(suite::objet_en_double) => {
                // (lu dans le fichier lui-même, mais deux clés n'y diffèrent que par les majuscules : ConvertFrom-Json
                // de PowerShell 5.1 le refuse, il est donc abîmé pour la version 2.18 aussi)
                self.lire_double(fichier)
            }
            Ok(l) => {
                for t in &l.journal {
                    self.journal(t);
                }
                Ok(LuSur { valeur: l.valeur, abime: l.abime })
            }
            Err(e) => {
                for t in &e.journal {
                    self.journal(t);
                }
                Err(e.to_string())
            }
        }
    }

    /// `Read-JsonSur` d'un fichier aux clés en double (aux majuscules près) : abîmé, comme pour PowerShell. Mis de
    /// côté (`.abime-<date>`), puis repris de sa copie `.bak` si elle est bonne.
    fn lire_double(&self, fichier: &Path) -> Result<LuSur, String> {
        let nom = fichier.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let texte = std::fs::read(fichier).map(|o| json_sur::texte_du_fichier(&o)).unwrap_or_default();
        let de_cote = match mettre_de_cote(fichier, &self.heure()) {
            Ok(de) => {
                let n = de.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                self.journal(&format!("{nom} abîmé (illisible) : mis de côté dans {n}"));
                true
            }
            Err(e) => {
                self.journal(&format!("{nom} abîmé (illisible), pas pu être mis de côté : {e}"));
                false
            }
        };
        // Mis de côté : le fichier est absent, la lecture reprend sa copie et la remet en place ; sinon, la copie seule
        let lu = if de_cote {
            json_sur::lire_avec(fichier, true, &self.options)
        } else {
            json_sur::lire_copie(fichier, true, &self.options)
        };
        let l = match lu {
            Ok(l) => l,
            Err(e) => {
                for t in &e.journal {
                    self.journal(t);
                }
                return Err(e.to_string());
            }
        };
        // (les mots de Read-JsonSur : le fichier était abîmé, pas absent)
        let repris = format!("{nom} abîmé : repris de sa copie ({nom}.bak)");
        for t in &l.journal {
            if *t == format!("{nom} absent : repris de sa copie ({nom}.bak)")
                || *t == format!("{nom} : lu dans sa copie ({nom}.bak)")
            {
                self.journal(&repris);
            } else {
                self.journal(t);
            }
        }
        if l.valeur.is_some() {
            return Ok(LuSur { valeur: l.valeur, abime: None });
        }
        self.journal(&format!("{nom} : aucune copie lisible, il repart de zéro"));
        Ok(LuSur { valeur: None, abime: Some(texte) })
    }

    /// `Save-JsonSur $Fichier ($valeur | ConvertTo-Json)`
    fn ecrire_sur(&self, fichier: &Path, valeur: &Value) -> Result<(), String> {
        if self.hors_essai(fichier) {
            return Err(format!("{} hors du dossier d'essai", fichier.display()));
        }
        json_sur::ecrire_avec(fichier, &json_ps::lisible(valeur), &self.options).map_err(|e| e.to_string())
    }

    // ---------------------------------------------------------------------------------------------------------
    // Les réglages
    // ---------------------------------------------------------------------------------------------------------

    /// `Read-Reglages` (donnees.ps1:159-180) : (réglages, illisibles, repris).
    fn lire_reglages(&self) -> (Map<String, Value>, bool, bool) {
        let mut illisibles = false;
        let lu = match self.lire_sur(&self.dossiers.reglages()) {
            Ok(l) => Some(l),
            Err(e) => {
                self.journal(&format!("Réglages : {e}"));
                illisibles = true;
                None
            }
        };
        let abime = match lu {
            Some(LuSur { valeur: Some(o), .. }) => return (reglages::table(o), false, false),
            Some(LuSur { abime, .. }) => abime,
            None => None,
        };
        if abime.is_none() && !illisibles {
            // (pas encore de réglages : valeurs par défaut)
            return (Map::new(), false, false);
        }
        let mut r = Map::new();
        if let Some(a) = abime.filter(|a| !a.is_empty()) {
            r = reglages::reprise(&a);
            if !r.is_empty() {
                self.journal(&format!("Réglages repris du fichier abîmé : {}", reglages::noms_tries(&r).join(", ")));
            }
        }
        for n in REGLAGES_PRUDENTS {
            if reglages::cle(&r, n).is_none() {
                r.insert(n.to_string(), Value::Bool(false));
                self.journal(&format!("Réglage {n} perdu : coupé par prudence (il se rallume dans les Paramètres)"));
            }
        }
        (r, illisibles, true)
    }

    /// Le haut de donnees.ps1 (lignes 181-186) : les réglages lus au démarrage ; repris d'un fichier abîmé, ils sont
    /// écrits tout de suite (sinon, au prochain lancement, les valeurs par défaut reviendraient).
    pub fn lire_reglages_au_demarrage(&self) {
        let (valeurs, illisibles, repris) = self.lire_reglages();
        let mut e = verrou(&self.reglages);
        *e = EtatReglages { valeurs, changes: Vec::new(), illisibles, repris };
        if repris
            && !illisibles
            && let Err(x) = self.ecrire_sur(&self.dossiers.reglages(), &Value::Object(e.valeurs.clone()))
        {
            self.journal(&format!("Réglages non enregistrés : {x}"));
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // suite.json
    // ---------------------------------------------------------------------------------------------------------

    /// `Read-Suite` (suite.ps1:23-39).
    fn lire_suite(&self) -> Suite {
        let mut s = Suite::default();
        let j = match self.lire_sur(&self.dossiers.suite()) {
            Ok(LuSur { valeur: Some(j), .. }) => Value::Object(j),
            Ok(_) => return s,
            Err(e) => {
                // (pris par un autre programme : pas réécrit à partir de ces valeurs vides)
                self.journal(&format!("suite.json illisible : {e}"));
                s.illisible = true;
                return s;
            }
        };
        if let Value::String(t) = suite::propriete(&j, "theme")
            && suite::theme_valable(&t)
        {
            s.theme = Some(t);
        }
        if let Value::String(m) = suite::propriete(&j, "micro")
            && suite::nom_appareil(&m)
        {
            s.micro = Some(m);
        }
        if let Value::String(c) = suite::propriete(&j, "casque")
            && suite::nom_appareil(&c)
        {
            s.casque = Some(c);
        }
        if let Value::Object(a) = suite::propriete(&j, "applis") {
            for (k, v) in a {
                if let Value::String(d) = v
                    && suite::id_valable(&k)
                {
                    suite::poser_appli(&mut s.applis, &k, &d);
                }
            }
        }
        s
    }

    /// `Write-Suite` (suite.ps1:41-52).
    fn ecrire_suite(&self, s: &Suite) {
        if s.illisible {
            self.journal("suite.json pas modifié : il n'a pas pu être lu");
            return;
        }
        let o = suite::objet_suite(s, &moment::iso(&self.heure()));
        if let Err(e) = self.ecrire_sur(&self.dossiers.suite(), &o) {
            self.journal(&format!("suite.json non enregistré : {e}"));
        }
    }

    /// `[IO.File]::ReadAllText($f) | ConvertFrom-Json`, `None` si le fichier ne se lit pas ou n'est pas du JSON.
    fn json_d_une_appli(&self, f: &Path) -> Option<Value> {
        if self.garde.as_ref().is_some_and(|g| !f.starts_with(g)) {
            return None;
        }
        let o = std::fs::read(f).ok()?;
        suite::convertir(&json_sur::texte_du_fichier(&o))
    }

    /// Les réglages d'Evermind (thème, micro, casque) : `<données de la suite>\Evermind`, puis `%LOCALAPPDATA%\Evermind`.
    fn reglages_evermind(&self) -> [PathBuf; 2] {
        [self.dossiers.donnees_suite.join(r"Evermind\reglages.json"), self.localappdata.join(r"Evermind\reglages.json")]
    }
}

/// Déplace `fichier` sous un nom libre `<fichier>.abime-<date>` (puis `-2`, `-3`... s'il est pris), jamais par-dessus
/// un autre fichier.
fn mettre_de_cote(fichier: &Path, h: &moment::HeureLocale) -> std::io::Result<PathBuf> {
    let base = format!("{}.abime-{}", fichier.display(), h.compacte());
    for n in 1u32..1000 {
        let de = PathBuf::from(if n == 1 { base.clone() } else { format!("{base}-{n}") });
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&de) {
            Ok(f) => {
                drop(f);
                if let Err(e) = std::fs::rename(fichier, &de) {
                    let _ = std::fs::remove_file(&de);
                    return Err(e);
                }
                return Ok(de);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
    }
    Err(std::io::Error::other("aucun nom libre"))
}

impl Donnees for DisqueMindset {
    /// `Write-Log` : « <date au format s> <texte> », UTF-8 sans BOM ; une écriture impossible est ignorée.
    fn journal(&self, texte: &str) {
        use std::io::Write;
        let _v = verrou(&self.journal);
        let ligne = format!("{} {texte}\r\n", moment::iso(&self.heure()));
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(self.dossiers.journal()) {
            let _ = f.write_all(ligne.as_bytes());
        }
    }

    /// `Get-Setting` (sans tenir compte des majuscules, comme la table de PowerShell).
    fn reglage(&self, nom: &str) -> Option<Value> {
        reglages::lire(&verrou(&self.reglages).valeurs, nom).cloned()
    }

    /// `Set-Setting` (donnees.ps1:190-204).
    fn ecrire_reglage(&self, nom: &str, valeur: Value) {
        let mut e = verrou(&self.reglages);
        reglages::poser(&mut e.valeurs, nom, valeur);
        if !e.changes.iter().any(|c| suite_commun::chemins::egal(c, nom)) {
            e.changes.push(nom.to_string());
        }
        // reglages.json n'a pas pu être lu au démarrage (pris par un autre programme) : relu avant d'écrire, pour ne
        // pas remplacer les réglages de l'utilisateur par les valeurs par défaut
        if e.illisibles {
            let (mut relus, illisibles, repris) = self.lire_reglages();
            e.illisibles = illisibles;
            e.repris = repris;
            if illisibles {
                self.journal("Réglages non enregistrés : reglages.json ne peut toujours pas être lu");
                return;
            }
            for k in e.changes.clone() {
                let v = reglages::lire(&e.valeurs, &k).cloned().unwrap_or(Value::Null);
                reglages::poser(&mut relus, &k, v);
            }
            e.valeurs = relus;
        }
        if let Err(x) = self.ecrire_sur(&self.dossiers.reglages(), &Value::Object(e.valeurs.clone())) {
            self.journal(&format!("Réglages non enregistrés : {x}"));
        }
    }

    fn lire_json(&self, fichier: &Path) -> Result<Option<Value>, String> {
        self.lire_sur(fichier).map(|l| l.valeur.map(Value::Object))
    }

    fn ecrire_json(&self, fichier: &Path, valeur: &Value) -> Result<(), String> {
        self.ecrire_sur(fichier, valeur)
    }

    fn suite(&self) -> Suite {
        self.lire_suite()
    }

    /// `Get-SuiteTheme` (suite.ps1:56-66) : au tout premier lancement, celui d'Evermind ou de Nevermind s'il est déjà
    /// installé (`%LOCALAPPDATA%\OptiGame` : l'ancien dossier de données de Nevermind, sous son ancien nom).
    fn theme_suite(&self) -> String {
        if let Some(t) = self.lire_suite().theme {
            return t;
        }
        let [a, b] = self.reglages_evermind();
        for f in [
            a,
            b,
            self.dossiers.donnees_suite.join(r"Nevermind\parametres.json"),
            self.localappdata.join(r"OptiGame\parametres.json"),
        ] {
            if let Some(j) = self.json_d_une_appli(&f) {
                let t = suite_commun::protocole_installateur::texte_ps(&suite::propriete(&j, "Theme"));
                if suite::theme_de_base(&t) {
                    return t;
                }
            }
        }
        "neon".into()
    }

    /// `Set-SuiteTheme`
    fn ecrire_theme_suite(&self, theme: &str) {
        if !suite::theme_valable(theme) {
            return;
        }
        let mut s = self.lire_suite();
        s.theme = Some(theme.to_string());
        self.ecrire_suite(&s);
        self.journal(&format!("Thème de la suite : {theme}"));
    }

    /// `Set-SuiteAppli` : une appli installée ou prise en charge par Mindset (son dossier), ou retirée.
    fn ecrire_suite_appli(&self, id: &str, dossier: Option<&str>) {
        let mut s = self.lire_suite();
        match dossier.filter(|d| !d.is_empty()) {
            Some(d) => suite::poser_appli(&mut s.applis, id, d),
            None => suite::retirer_appli(&mut s.applis, id),
        }
        if s.theme.is_none() {
            s.theme = Some(self.theme_suite());
        }
        self.ecrire_suite(&s);
    }

    /// `Get-SuiteSon` : tant qu'ils n'ont jamais été choisis dans Mindset, ceux d'Evermind (s'il est installé).
    fn son_suite(&self) -> (String, String) {
        let s = self.lire_suite();
        let (mut micro, mut casque) = (s.micro, s.casque);
        if micro.is_none() || casque.is_none() {
            for f in self.reglages_evermind() {
                let Some(j) = self.json_d_une_appli(&f) else { continue };
                let texte = |n| suite_commun::protocole_installateur::texte_ps(&suite::propriete(&j, n));
                if micro.is_none() {
                    micro = Some(texte("Micro")).filter(|m| suite::nom_appareil(m));
                }
                if casque.is_none() {
                    casque = Some(texte("Casque")).filter(|c| suite::nom_appareil(c));
                }
                break;
            }
        }
        (micro.unwrap_or_default(), casque.unwrap_or_default())
    }

    /// `Set-SuiteSon` : `quoi` = « micro » ou « casque » ; `nom` : l'appareil, « » pour celui de Windows.
    fn ecrire_son_suite(&self, quoi: &str, nom: &str) {
        let micro = suite_commun::chemins::egal(quoi, "micro");
        if !(micro || suite_commun::chemins::egal(quoi, "casque")) || !suite::nom_appareil(nom) {
            return;
        }
        let mut s = self.lire_suite();
        if micro {
            s.micro = Some(nom.to_string());
        } else {
            s.casque = Some(nom.to_string());
        }
        // (le premier choix fixe aussi l'autre, pour que les applis ne retombent pas sur leur ancien réglage)
        let (m, c) = self.son_suite();
        if s.micro.is_none() {
            s.micro = Some(m);
        }
        if s.casque.is_none() {
            s.casque = Some(c);
        }
        if s.theme.is_none() {
            s.theme = Some(self.theme_suite());
        }
        self.ecrire_suite(&s);
        self.journal(&format!("Son de la suite : {quoi} = « {nom} »"));
    }
}
