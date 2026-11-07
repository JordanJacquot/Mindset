//! Le bloc « publications » : chercher les nouvelles versions (Mindset et ses applis), au démarrage, toutes les
//! heures, en rouvrant Mindset depuis l'horloge (si la dernière fois date de plus de 15 minutes) et avec
//! « Actualiser » (accueil.ps1 : `Invoke-Actualiser`, `Update-InfoActualiser`, la minuterie d'une heure ; zone.ps1 :
//! `Show-Fenetre` ; installations.ps1 : `Update-Publications`, `Get-VersionsEssaiAppli`, `Set-VersionsEssaiAppli`).
//!
//! GitHub accepte 60 questions par heure : une recherche en pose une par appli, plus une pour Mindset. Refusé (403 ou
//! 429) : la prochaine recherche automatique est avancée à dans 30 minutes. Tout seul, seulement si « Chercher les
//! nouvelles versions » (réglage `VerifVersions`) est activé et pas tant que le bandeau d'installation de Mindset est
//! affiché (`mindset.bienvenue`, du bloc « lui-même »). Un clic (`actualiser { clic: true }`) : toujours, mais pas deux
//! fois en 20 secondes.
//!
//! Ce que le bloc publie (tableau commun) :
//! - `publications` : `{ <id> | "mindset": { version, fichier, url_zip, url_sig, notes, essai } | { erreur } }` ;
//! - `recherche` : `{ verifie_a: "HH:mm" | null, texte, auto, en_cours: [ids sans réponse depuis moins de 2 minutes],
//!   en_attente: { id: moment }, mindset_en_cours: bool, depuis: moment | null, derniere: moment | null }`. `texte` est
//!   celui de `Update-InfoActualiser` (« Vérifié à 20:00 », « Recherche automatique coupée »...), `depuis` le moment de
//!   la dernière recherche lancée (`$script:RechercheDepuis` : la console montre « Recherche... » au moins 2 secondes).
//!
//! Signaux envoyés : `verifier-mindset` et `verifier-liste` à chaque recherche, `publications-changees { id }` à
//! chaque réponse (id : l'appli, ou « mindset »), `message-console` si la recherche vient du bouton de la console
//! (`actualiser { clic: true, console: true }`).

use std::collections::BTreeMap;
use std::time::Duration;

use mindset_noyau::moment;
use mindset_noyau::partage;
use mindset_noyau::signaux;
use mindset_noyau::{Bloc, Contexte, Effets};
use serde_json::{Map, Value, json};
use suite_commun::protocole_installateur::vrai_ps;

use crate::github::{self, Reponse};

/// Le dépôt et le zip de Mindset lui-même (`Start-VerifMajMindset` : `Get-Publication 'JordanJacquot/Mindset' 'Mindset.zip'`).
pub const DEPOT_MINDSET: &str = "JordanJacquot/Mindset";
pub const ZIP_MINDSET: &str = "Mindset.zip";

/// Le préfixe des travaux de fond : « publication:<id> » pour une appli, et celui de Mindset.
const TACHE_APPLI: &str = "publication:";
const TACHE_MINDSET: &str = "publication-mindset";

/// Une question posée à GitHub pour une appli (les paramètres du travail de `Update-Publications`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Question {
    pub id: String,
    pub depot: String,
    /// Le nom du zip puis l'ancien (vide s'il n'y en a pas), tels quels
    pub zips: Vec<String>,
    pub essai: bool,
}

/// Le bloc « publications ».
#[derive(Debug, Default)]
pub struct BlocPublications {
    /// `$script:Publications` (id -> publication ou erreur), « mindset » compris
    publications: BTreeMap<String, Reponse>,
    /// `$script:Recherches` : id -> moment de la question (en secondes, voir `moment::secondes`)
    recherches: BTreeMap<String, i64>,
    /// La question de Mindset lui-même est en route
    mindset_en_cours: bool,
    /// `$script:DernieresPublications` (`None` : `[datetime]::MinValue`)
    pub(crate) dernieres: Option<i64>,
    /// `$script:VerifieA`
    verifie_a: Option<i64>,
    /// `$script:RechercheDepuis`
    recherche_depuis: Option<i64>,
    /// La première recherche (celle du démarrage) est faite
    demarre: bool,
    /// La fenêtre était montrée au dernier signal `fenetre` (`$Window.IsVisible`)
    pub(crate) visible: bool,
    /// Les dernières questions lancées (pour les tests et le journal de débogage), 64 au plus
    pub(crate) lancees: Vec<Question>,
}

impl BlocPublications {
    /// Un bloc neuf (la même chose que `BlocPublications::default()`, utilisable dans une constante).
    pub const fn nouveau() -> BlocPublications {
        BlocPublications {
            publications: BTreeMap::new(),
            recherches: BTreeMap::new(),
            mindset_en_cours: false,
            dernieres: None,
            verifie_a: None,
            recherche_depuis: None,
            demarre: false,
            visible: false,
            lancees: Vec::new(),
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Les règles de la version PowerShell
    // -----------------------------------------------------------------------------------------------------------

    fn maintenant(ctx: &Contexte) -> i64 {
        moment::secondes(&ctx.heure())
    }

    /// Les secondes écoulées depuis `$script:DernieresPublications` (énorme si jamais).
    fn depuis_dernieres(&self, ctx: &Contexte) -> i64 {
        match self.dernieres {
            Some(d) => Self::maintenant(ctx) - d,
            None => i64::MAX,
        }
    }

    /// `Test-VerifVersionsActive` : `[bool](Get-Setting 'VerifVersions' $true)`.
    fn verif_active(ctx: &Contexte) -> bool {
        ctx.reglage_bool("VerifVersions", true)
    }

    /// `$script:AttenteBienvenue` : le bandeau d'installation de Mindset est affiché (bloc « lui-même »).
    fn bienvenue(ctx: &Contexte) -> bool {
        ctx.lu(partage::MINDSET).and_then(|m| m.get("bienvenue").and_then(Value::as_bool)).unwrap_or(false)
    }

    /// `Update-InfoActualiser` : le texte sous « Actualiser ».
    pub fn texte_info(&self, ctx: &Contexte) -> String {
        let auto = Self::verif_active(ctx);
        match self.verifie_a {
            Some(v) => {
                format!("Vérifié à {}{}", heure_minutes(v), if auto { "" } else { " (recherche automatique coupée)" })
            }
            None if !auto => "Recherche automatique coupée".into(),
            None => String::new(),
        }
    }

    /// `Invoke-Actualiser [-Clic]` ; vrai si la recherche est partie.
    pub fn actualiser(&mut self, ctx: &Contexte, clic: bool, effets: &mut Effets) -> bool {
        if !clic && (!Self::verif_active(ctx) || Self::bienvenue(ctx)) {
            return false;
        }
        if clic && self.depuis_dernieres(ctx) < 20 {
            return false; // (clics répétés)
        }
        let maintenant = Self::maintenant(ctx);
        self.dernieres = Some(maintenant);
        self.update_publications(ctx, effets);
        // Start-VerifMajMindset (bloc « lui-même »), puis la liste des applis en ligne (bloc « liste »)
        effets.signal(signaux::VERIFIER_MINDSET, json!({}));
        effets.signal(signaux::VERIFIER_LISTE, json!({}));
        self.verifie_a = Some(maintenant);
        if clic {
            ctx.journal("Actualiser : recherche des nouvelles versions");
        }
        // La console le montre tout de suite (« Recherche des mises à jour... », au moins 2 secondes)
        self.recherche_depuis = Some(maintenant);
        true
    }

    /// `Update-Publications` : une question par appli (et une pour Mindset lui-même), chacune dans un travail de fond.
    fn update_publications(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let maintenant = Self::maintenant(ctx);
        for a in ctx.applis().iter() {
            self.recherches.insert(a.id.clone(), maintenant);
            let q = Question {
                id: a.id.clone(),
                depot: a.depot.clone(),
                zips: vec![a.zip.clone(), a.ancien_zip.clone()],
                essai: versions_essai_appli(ctx, &a.id),
            };
            if self.lancees.len() >= 64 {
                self.lancees.remove(0);
            }
            self.lancees.push(q.clone());
            let reseau = ctx.reseau();
            effets.tache(&format!("{TACHE_APPLI}{}", q.id), move || {
                Ok(github::en_partage(&github::publication(&*reseau, &q.depot, &q.zips, q.essai)))
            });
        }
        self.mindset_en_cours = true;
        let reseau = ctx.reseau();
        effets.tache(TACHE_MINDSET, move || {
            Ok(github::en_partage(&github::publication(&*reseau, DEPOT_MINDSET, &[ZIP_MINDSET.to_string()], false)))
        });
    }

    /// `Set-VersionsEssaiAppli` : la case « Recevoir les versions d'essai » d'une appli. Changer la case oublie la
    /// version publiée connue de l'appli et relance la recherche au prochain passage de la minuterie.
    pub fn changer_versions_essai(&mut self, ctx: &Contexte, id: &str, oui: bool) {
        // (Get-Appli : l'id sans tenir compte des majuscules)
        if !ctx.applis().iter().any(|a| a.id.to_lowercase() == id.to_lowercase()) {
            return;
        }
        if versions_essai_appli(ctx, id) == oui {
            return;
        }
        let mut l: Vec<Value> =
            liste_ps(ctx.reglage_ou("VersionsEssai", json!([]))).into_iter().filter(|e| !egal_ps(e, id)).collect();
        if oui {
            l.push(Value::String(id.to_string()));
        }
        ctx.ecrire_reglage("VersionsEssai", Value::Array(l));
        ctx.journal(&format!("Versions d'essai de {id} : {}", if oui { "oui" } else { "non" }));
        // ($script:Publications.Remove : les clés d'une table PowerShell, sans tenir compte des majuscules)
        let id_bas = id.to_lowercase();
        self.publications.retain(|k, _| k.to_lowercase() != id_bas);
        self.dernieres = None;
    }

    /// La fin d'une question (la fin du travail de `Update-Publications`).
    fn reponse(&mut self, ctx: &Contexte, id: &str, resultat: Result<Value, String>, effets: &mut Effets) {
        let reponse = match resultat {
            Err(e) => Err(e),
            Ok(v) => github::depuis_partage(&v).unwrap_or_else(|| Err("réponse illisible".into())),
        };
        // GitHub limite les questions (60 par heure et par connexion) : refusé, on réessaie dans 30 minutes
        // ("$Erreur $($Resultat.Erreur)" -match '403|429' : l'erreur du travail ou celle de la réponse)
        if reponse.as_ref().err().is_some_and(|e| e.contains("403") || e.contains("429")) {
            self.dernieres = Some(Self::maintenant(ctx) - 1800);
        }
        self.publications.insert(id.to_string(), reponse);
        effets.signal(signaux::PUBLICATIONS_CHANGEES, json!({ "id": id }));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Ce que le bloc publie
    // -----------------------------------------------------------------------------------------------------------

    fn publier(&self, ctx: &Contexte) {
        let maintenant = Self::maintenant(ctx);
        let pubs: Map<String, Value> =
            self.publications.iter().map(|(k, v)| (k.clone(), github::en_partage(v))).collect();
        ctx.publier(partage::PUBLICATIONS, Value::Object(pubs));
        let iso = |s: i64| Value::String(moment::iso(&moment::depuis_secondes(s)));
        let en_cours: Vec<&String> =
            self.recherches.iter().filter(|(_, d)| maintenant - **d < 120).map(|(k, _)| k).collect();
        let en_attente: Map<String, Value> = self.recherches.iter().map(|(k, d)| (k.clone(), iso(*d))).collect();
        ctx.publier(
            partage::RECHERCHE,
            json!({
                "verifie_a": self.verifie_a.map(heure_minutes),
                "texte": self.texte_info(ctx),
                "auto": Self::verif_active(ctx),
                "en_cours": en_cours,
                "en_attente": en_attente,
                "mindset_en_cours": self.mindset_en_cours,
                "depuis": self.recherche_depuis.map(iso),
                "derniere": self.dernieres.map(iso),
            }),
        );
    }

    /// Les recherches sans réponse (`$script:Recherches.Keys`).
    pub fn recherches(&self) -> Vec<String> {
        self.recherches.keys().cloned().collect()
    }

    /// La publication connue d'une appli (ou de « mindset »).
    pub fn publication(&self, id: &str) -> Option<&Reponse> {
        self.publications.get(id)
    }

    /// Toutes les publications connues.
    pub fn publications(&self) -> &BTreeMap<String, Reponse> {
        &self.publications
    }

    /// `$script:VerifieA` au format « HH:mm ».
    pub fn verifie_a(&self) -> Option<String> {
        self.verifie_a.map(heure_minutes)
    }
}

/// « HH:mm » d'un moment (`ToString('HH:mm')`).
fn heure_minutes(s: i64) -> String {
    let h = moment::depuis_secondes(s);
    format!("{:02}:{:02}", h.heure, h.minute)
}

/// `@(Get-Setting 'VersionsEssai' @())` : le réglage vu comme une liste (une valeur seule, même `null`, en est une).
fn liste_ps(v: Value) -> Vec<Value> {
    match v {
        Value::Array(a) => a,
        x => vec![x],
    }
}

/// `$element -ceq $id` (l'élément à gauche, comme `-cin` et `Where-Object { $_ -cne $Id }`) : un texte comparé
/// avec les majuscules, un nombre comparé au nombre que fait l'id, un booléen à « l'id n'est pas vide ».
fn egal_ps(element: &Value, id: &str) -> bool {
    match element {
        Value::String(s) => s == id,
        Value::Number(n) => {
            let t = id.trim();
            match (n.as_f64(), t.parse::<f64>()) {
                (Some(a), Ok(b)) if !t.is_empty() => a == b,
                _ => false,
            }
        }
        Value::Bool(b) => *b == !id.is_empty(),
        _ => false,
    }
}

/// `Get-VersionsEssaiAppli` : l'appli reçoit-elle les versions d'essai ? (réglage `VersionsEssai`, la liste des id,
/// avec les majuscules ; absent : aucune, comme avant)
pub fn versions_essai_appli(ctx: &Contexte, id: &str) -> bool {
    liste_ps(ctx.reglage_ou("VersionsEssai", json!([]))).iter().any(|e| egal_ps(e, id))
}

impl Bloc for BlocPublications {
    fn nom(&self) -> &'static str {
        "publications"
    }

    fn demarrer(&mut self, ctx: &Contexte, _effets: &mut Effets) {
        // (Update-InfoActualiser au chargement : le texte est là dès la première image)
        self.publier(ctx);
    }

    fn tic(&mut self, ctx: &Contexte, effets: &mut Effets) -> Option<Duration> {
        if !self.demarre {
            // La recherche du démarrage (accueil.ps1 : Invoke-Actualiser au chargement), une fois tous les blocs
            // démarrés (le bandeau d'installation est alors connu)
            self.demarre = true;
            self.visible = ctx.vue().visible;
            self.actualiser(ctx, false, effets);
        } else if self.depuis_dernieres(ctx) >= 3600 {
            // Toutes les heures (si la recherche est activée : Invoke-Actualiser)
            self.actualiser(ctx, false, effets);
        }
        self.publier(ctx);
        // (comme l'EtatTimer : 2 secondes, 30 secondes Mindset caché ou réduit)
        Some(Duration::from_secs(if ctx.vue().cachee() { 30 } else { 2 }))
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, donnees: &Value, effets: &mut Effets) {
        match nom {
            signaux::ACTUALISER => {
                let clic = donnees.get("clic").is_some_and(vrai_ps);
                let parti = self.actualiser(ctx, clic, effets);
                // Le bouton de la console (console.ps1, « actualiser ») dit ce qui se passe
                if donnees.get("console").is_some_and(vrai_ps) {
                    let t = if parti { "Recherche des nouvelles versions..." } else { "Tout vient d'être vérifié" };
                    effets.ajouter(signaux::message_console(t));
                }
            }
            signaux::VERSIONS_ESSAI => {
                if let Some(id) = donnees.get("id").and_then(Value::as_str) {
                    let oui = donnees.get("oui").is_some_and(vrai_ps);
                    self.changer_versions_essai(ctx, id, oui);
                }
            }
            signaux::FENETRE => {
                let visible = donnees.get("visible").is_some_and(vrai_ps);
                // Show-Fenetre : rouvert depuis l'horloge après un moment, les nouvelles versions sont cherchées
                // tout de suite (si « Chercher les nouvelles versions » est activé)
                if visible && !self.visible && self.demarre && self.depuis_dernieres(ctx) >= 900 {
                    self.actualiser(ctx, false, effets);
                }
                self.visible = visible;
            }
            _ => {}
        }
        self.publier(ctx);
    }

    fn tache_finie(&mut self, ctx: &Contexte, id: &str, resultat: Result<Value, String>, effets: &mut Effets) {
        if id == TACHE_MINDSET {
            self.mindset_en_cours = false;
            self.reponse(ctx, partage::MINDSET, resultat, effets);
        } else if let Some(appli) = id.strip_prefix(TACHE_APPLI) {
            self.recherches.remove(appli);
            self.reponse(ctx, appli, resultat, effets);
        }
        self.publier(ctx);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mindset_noyau::reseau::ReponseHttp;
    use mindset_noyau::{Appli, Effet, Tache, essai};

    fn appli(id: &str, depot: &str, zip: &str) -> Appli {
        Appli { id: id.into(), nom: id.into(), depot: depot.into(), zip: zip.into(), ..Default::default() }
    }

    fn release(tag: &str, depot: &str, zip: &str, pre: bool) -> Value {
        let base = format!("https://github.com/{depot}/releases/download/{tag}");
        json!({ "tag_name": tag, "prerelease": pre, "draft": false, "body": format!("notes {tag}"),
            "assets": [
                { "name": zip, "browser_download_url": format!("{base}/{zip}") },
                { "name": format!("{zip}.sig"), "browser_download_url": format!("{base}/{zip}.sig") },
            ] })
    }

    /// Les travaux de fond demandés, faits ici l'un après l'autre (comme l'hôte avec `taches_directes`).
    fn faire(b: &mut BlocPublications, ctx: &Contexte, effets: Effets) -> Effets {
        let mut suite = Effets::default();
        for e in effets.0 {
            match e {
                Effet::Tache(t) => {
                    let id = t.id.clone();
                    let r = Tache::lancer(t);
                    ctx.au_nom_de("publications", || b.tache_finie(ctx, &id, r, &mut suite));
                }
                autre => suite.ajouter(autre),
            }
        }
        suite
    }

    fn signaux_nommes(e: &Effets, nom: &str) -> usize {
        e.0.iter().filter(|x| matches!(x, Effet::Signal { nom: n, .. } if n == nom)).count()
    }

    #[test]
    fn une_recherche_complete_par_le_faux_github() {
        let (ctx, faux) = essai::contexte("publications-recherche");
        ctx.definir_applis(vec![
            appli("mindcare", "JordanJacquot/Mindcare", "Mindcare.zip"),
            appli("evermind", "JordanJacquot/Evermind", "Evermind.zip"),
        ]);
        ctx.ecrire_reglage("VersionsEssai", json!(["mindcare"]));
        let api = "https://api.github.com/repos";
        let r = &faux.reseau;
        let mc = release("v0.15.3", "JordanJacquot/Mindcare", "Mindcare.zip", false);
        r.repondre(&format!("{api}/JordanJacquot/Mindcare/releases/latest"), Ok(ReponseHttp::ok(mc.to_string())));
        let pre = json!([release("v0.90.0", "JordanJacquot/Mindcare", "Mindcare.zip", true)]);
        r.repondre(&format!("{api}/JordanJacquot/Mindcare/releases?per_page=30"), Ok(ReponseHttp::ok(pre.to_string())));
        r.repondre(&format!("{api}/JordanJacquot/Evermind/releases/latest"), Ok(ReponseHttp::code(403)));
        r.repondre("https://github.com/JordanJacquot/Evermind/releases/latest", Ok(ReponseHttp::code(429)));
        let ms = release("v3.0.1", "JordanJacquot/Mindset", "Mindset.zip", false);
        r.repondre(&format!("{api}/JordanJacquot/Mindset/releases/latest"), Ok(ReponseHttp::ok(ms.to_string())));
        let mut b = BlocPublications::nouveau();
        let mut e = Effets::default();
        ctx.au_nom_de("publications", || b.demarrer(&ctx, &mut e));
        assert_eq!(ctx.lu(partage::RECHERCHE).unwrap()["texte"], "");
        let delai = ctx.au_nom_de("publications", || b.tic(&ctx, &mut e));
        assert_eq!(delai, Some(Duration::from_secs(30)), "Mindset caché : 30 secondes");
        let rech = ctx.lu(partage::RECHERCHE).unwrap();
        assert_eq!(rech["en_cours"], json!(["evermind", "mindcare"]));
        assert_eq!(rech["mindset_en_cours"], true);
        assert_eq!(rech["texte"], "Vérifié à 20:00");
        assert_eq!(rech["depuis"], "2026-11-07T20:00:00");
        let ids: Vec<String> =
            e.0.iter().filter_map(|x| if let Effet::Tache(t) = x { Some(t.id.clone()) } else { None }).collect();
        assert_eq!(ids, ["publication:mindcare", "publication:evermind", "publication-mindset"]);
        assert_eq!(signaux_nommes(&e, signaux::VERIFIER_MINDSET), 1);
        assert_eq!(signaux_nommes(&e, signaux::VERIFIER_LISTE), 1);
        let suite = faire(&mut b, &ctx, e);
        let pubs = ctx.lu(partage::PUBLICATIONS).unwrap();
        assert_eq!(pubs["mindcare"]["version"], "0.90.0", "canal d'essai coché : la préversion");
        assert_eq!(pubs["mindcare"]["essai"], true);
        assert_eq!(pubs["mindset"]["version"], "3.0.1");
        assert_eq!(
            pubs["mindset"]["url_sig"],
            "https://github.com/JordanJacquot/Mindset/releases/download/v3.0.1/Mindset.zip.sig"
        );
        assert!(pubs["evermind"]["erreur"].as_str().unwrap().contains("(403) Interdit"));
        // GitHub a refusé (403) : la prochaine recherche automatique dans 30 minutes, pas dans une heure
        assert_eq!(ctx.lu(partage::RECHERCHE).unwrap()["derniere"], "2026-11-07T19:30:00");
        assert_eq!(signaux_nommes(&suite, signaux::PUBLICATIONS_CHANGEES), 3);
        assert_eq!(ctx.lu(partage::RECHERCHE).unwrap()["en_cours"], json!([]));
        assert_eq!(ctx.lu(partage::RECHERCHE).unwrap()["mindset_en_cours"], false);
        ctx.avancer(Duration::from_secs(29 * 60));
        let mut e = Effets::default();
        ctx.au_nom_de("publications", || b.tic(&ctx, &mut e));
        assert!(e.est_vide(), "29 minutes après le refus : rien");
        ctx.avancer(Duration::from_secs(60));
        ctx.au_nom_de("publications", || b.tic(&ctx, &mut e));
        assert_eq!(e.0.iter().filter(|x| matches!(x, Effet::Tache(_))).count(), 3, "30 minutes après : on réessaie");
        let _ = std::fs::remove_dir_all(&faux.racine);
    }

    #[test]
    fn mindset_refuse_par_github_reessai_dans_30_minutes() {
        let (ctx, faux) = essai::contexte("publications-mindset-403");
        let mut b = BlocPublications::nouveau();
        let mut e = Effets::default();
        let refus = "Impossible de joindre GitHub ((429) Too Many Requests.).";
        ctx.au_nom_de("publications", || {
            b.tic(&ctx, &mut e);
            b.tache_finie(&ctx, TACHE_MINDSET, Err(refus.into()), &mut e);
        });
        // (la version PowerShell avançait de 5 h 30 : la recherche repartait au tic suivant, DIVERGENCES.md)
        assert_eq!(b.dernieres, Some(moment::secondes(&ctx.heure()) - 1800));
        assert_eq!(ctx.lu(partage::PUBLICATIONS).unwrap()["mindset"]["erreur"], refus);
        let _ = std::fs::remove_dir_all(&faux.racine);
    }

    #[test]
    fn le_bouton_de_la_console() {
        let (ctx, faux) = essai::contexte("publications-console");
        let mut b = BlocPublications::nouveau();
        let mut e = Effets::default();
        let clic = json!({ "clic": true, "console": true });
        ctx.au_nom_de("publications", || b.signal(&ctx, signaux::ACTUALISER, &clic, &mut e));
        assert!(e.0.contains(&signaux::message_console("Recherche des nouvelles versions...")));
        let mut e = Effets::default();
        ctx.au_nom_de("publications", || b.signal(&ctx, signaux::ACTUALISER, &clic, &mut e));
        assert_eq!(e.0, vec![signaux::message_console("Tout vient d'être vérifié")], "clics répétés : rien d'autre");
        assert_eq!(faux.donnees.lignes(), vec!["Actualiser : recherche des nouvelles versions"]);
        let _ = std::fs::remove_dir_all(&faux.racine);
    }

    #[test]
    fn rythme_de_la_minuterie() {
        let (ctx, faux) = essai::contexte("publications-rythme");
        let mut b = BlocPublications::nouveau();
        let mut e = Effets::default();
        ctx.definir_vue(mindset_noyau::Vue { visible: true, reduite: false, page: "accueil".into() });
        assert_eq!(b.tic(&ctx, &mut e), Some(Duration::from_secs(2)));
        assert!(b.visible);
        ctx.definir_vue(mindset_noyau::Vue { visible: true, reduite: true, page: "accueil".into() });
        assert_eq!(b.tic(&ctx, &mut e), Some(Duration::from_secs(30)));
        let _ = std::fs::remove_dir_all(&faux.racine);
    }

    #[test]
    fn egalites_a_la_powershell() {
        assert!(egal_ps(&json!("mindcare"), "mindcare"));
        assert!(!egal_ps(&json!("Mindcare"), "mindcare"));
        assert!(egal_ps(&json!(5), "5"));
        assert!(egal_ps(&json!(5), " 5 "));
        assert!(!egal_ps(&json!(5), "cinq"));
        assert!(egal_ps(&json!(true), "nevermind"));
        assert!(!egal_ps(&Value::Null, "nevermind"));
        assert_eq!(liste_ps(json!("a")), vec![json!("a")]);
        assert_eq!(liste_ps(Value::Null), vec![Value::Null]);
    }
}
