//! Mindset en Rust, bloc « près de l'horloge » : l'icône près de l'horloge, son menu, les bulles, la croix rouge
//! (modules\zone.ps1 de la version PowerShell, en entier).
//!
//! - **Réduire** : Mindset se cache près de l'horloge (réglage « ReduireHorloge », oui par défaut) : signal `reduite`.
//! - **La croix rouge** (signal `croix`) : selon le réglage « Fermeture » (demander, reduire ou quitter, sans tenir
//!   compte des majuscules), réduire, tout quitter, ou la question « Fermer Mindset ? » (clé `fermeture` de l'état,
//!   dessinée par les écrans avec `ui/fermeture.js` ; ses boutons : action `horloge:fermeture`). Sans icône, la croix
//!   ferme Mindset sans fermer les applis (comme la fenêtre WPF qui se fermait).
//! - **L'icône** : un clic rouvre Mindset ; clic droit : « Ouvrir Mindset » (en gras), « Ouvrir <appli> » pour chaque
//!   appli installée, « Tout quitter (Mindset et ses applis) ».
//! - **Les bulles** : celle de la première fois (« Mindset reste ici »), celles des autres blocs (signal `bulle`), le
//!   message d'erreur imprévue (signal `erreur-imprevue`), et les notifications des applis
//!   (`notification.demande` dans leur dossier de données, relu toutes les 2 s) ; un clic sur la bulle d'une appli
//!   l'ouvre dans Mindset et lui renvoie « notif:<id> » dans son fichier d'affichage.
//! - **Rouvrir** (clic, menu, bulle, autre lancement de Mindset : signal `afficher-demande`) : Mindset caché, et la
//!   dernière recherche des nouvelles versions a au moins 15 minutes : elle est relancée (signal `actualiser`).
//!
//! La vraie icône ([`windows::IconeWindows`]) n'est jamais créée dans un contexte d'essai (sauf la construction
//! d'essai lancée sur un bureau Windows à part avec `MINDSET_ESSAI_ICONE=1`). Les tests donnent une
//! [`icone::FausseIcone`].

use std::path::PathBuf;
use std::time::Duration;

use mindset_noyau::appli::Appli;
use mindset_noyau::{Bloc, Contexte, Effet, Effets, Fenetre, partage, signaux};
use serde_json::{Map, Value, json};

pub mod icone;
pub mod json_ps;
pub mod ui;
#[cfg(windows)]
pub mod windows;

use icone::{Choix, Dessin, Geste, Icone, Ligne};

/// La bulle de la première fois (Hide-Fenetre, zone.ps1:25).
pub const BULLE_TITRE: &str = "Mindset reste ici";
pub const BULLE_TEXTE: &str = "Clique sur l'icône pour le rouvrir. Clic droit pour tes applis ou pour quitter.";
/// Le message d'erreur imprévue (Show-MessageErreurImprevue, interface.ps1:159-160).
pub const ERREUR_TITRE: &str = "Un petit problème est survenu";
pub const ERREUR_TEXTE: &str =
    "Mindset continue. Si ça se répète, quitte Mindset (clic droit sur son icône près de l'horloge) puis rouvre-le.";
/// Le fichier qu'une appli écrit dans son dossier de données pour une bulle.
pub const NOTIFICATION: &str = "notification.demande";

/// Le rythme du bloc tant que l'icône existe (ses gestes sont lus à chaque fois).
const RYTHME_ICONE: Duration = Duration::from_millis(150);
/// Les notifications des applis (le DispatcherTimer de 2 s, zone.ps1:170-173).
const RYTHME_NOTIFICATIONS: Duration = Duration::from_secs(2);

/// Le bloc « près de l'horloge ».
///
/// `BlocHorloge::default()` est le bloc tel que `blocs()` le crée (la vraie icône est faite au démarrage, sauf en
/// essai) ; les tests prennent [`BlocHorloge::avec_icone`] ou [`BlocHorloge::sans_icone`].
#[derive(Default)]
pub struct BlocHorloge {
    /// L'icône donnée par un test : `Some(None)` = aucune, `None` = la vraie (si permise)
    donnee: Option<Option<Box<dyn Icone>>>,
    e: Option<Etat>,
}

impl std::fmt::Debug for BlocHorloge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BlocHorloge").field("icone", &self.e.as_ref().is_some_and(|e| e.icone.is_some())).finish()
    }
}

#[derive(Default)]
struct Etat {
    icone: Option<Box<dyn Icone>>,
    /// La question de la croix est montrée (`$ui.Fermeture.Visibility`)
    question: bool,
    /// Combien de fois elle a été ouverte (la page décoche « Ne plus me demander » à chaque nouvelle ouverture)
    ouvertures: u64,
    /// La dernière bulle montrée est celle de cette appli : (id, numéro de la notification) (`$script:BulleAppli`)
    bulle_appli: Option<(String, String)>,
    /// La fenêtre était montrée (dernier signal `fenetre`)
    visible: bool,
    /// Le menu déjà donné à l'icône
    menu: Vec<Ligne>,
    /// Le prochain relevé des notifications (temps écoulé depuis le lancement)
    prochain_releve: Duration,
    ferme: bool,
    /// Mindset a déjà demandé à quitter (`$script:QuitterVraiment`) : la croix ne pose plus de question
    quitte: bool,
}

impl BlocHorloge {
    /// Le bloc avec cette icône (tests : une [`icone::FausseIcone`]).
    pub fn avec_icone(i: Box<dyn Icone>) -> BlocHorloge {
        BlocHorloge { donnee: Some(Some(i)), e: None }
    }
    /// Le bloc sans icône (comme Mindset en mode test, ou une icône impossible à créer).
    pub fn sans_icone() -> BlocHorloge {
        BlocHorloge { donnee: Some(None), e: None }
    }
    /// La question de la croix est-elle montrée ?
    pub fn question(&self) -> bool {
        self.e.as_ref().is_some_and(|e| e.question)
    }
    /// La bulle d'appli en attente d'un clic : (id de l'appli, numéro), pour les tests.
    pub fn bulle_appli(&self) -> Option<(String, String)> {
        self.e.as_ref().and_then(|e| e.bulle_appli.clone())
    }

    fn etat(&mut self) -> &mut Etat {
        self.e.get_or_insert_with(Etat::default)
    }
}

/// La vraie icône est-elle permise ? Toujours dans le vrai Mindset ; jamais dans un contexte d'essai, sauf la
/// construction d'essai lancée sur un bureau Windows à part avec `MINDSET_ESSAI_ICONE=1` (là, il n'y a pas de barre
/// des tâches : rien ne peut apparaître).
fn icone_permise(ctx: &Contexte) -> bool {
    if !ctx.essai {
        return true;
    }
    // (construction d'essai seulement : dans le Mindset livré, un contexte d'essai n'a jamais d'icône)
    #[cfg(all(windows, feature = "essai"))]
    {
        std::env::var("MINDSET_ESSAI_ICONE").is_ok_and(|v| v == "1") && windows::bureau_a_part()
    }
    #[cfg(not(all(windows, feature = "essai")))]
    {
        false
    }
}

fn vraie_icone(ctx: &Contexte) -> Option<Box<dyn Icone>> {
    if !icone_permise(ctx) {
        return None;
    }
    #[cfg(windows)]
    {
        match windows::IconeWindows::creer(&ctx.dossiers.fichiers.join("Mindset.ico")) {
            Ok(i) => Some(Box::new(i)),
            Err(e) => {
                ctx.journal(&format!("Icône près de l'horloge impossible : {e}"));
                None
            }
        }
    }
    #[cfg(not(windows))]
    {
        None
    }
}

impl Bloc for BlocHorloge {
    fn nom(&self) -> &'static str {
        "horloge"
    }

    fn demarrer(&mut self, ctx: &Contexte, _effets: &mut Effets) {
        let icone = match self.donnee.take() {
            Some(i) => i,
            None => vraie_icone(ctx),
        };
        self.e = Some(Etat {
            icone,
            visible: ctx.vue().visible,
            prochain_releve: ctx.ecoule() + RYTHME_NOTIFICATIONS,
            ..Default::default()
        });
    }

    fn etat(&mut self, _ctx: &Contexte) -> Map<String, Value> {
        let e = self.etat();
        let mut m = Map::new();
        m.insert("fermeture".into(), json!({ "visible": e.question, "ouverture": e.ouvertures }));
        m
    }

    fn action(&mut self, ctx: &Contexte, id: &str, valeur: &Value, effets: &mut Effets) -> bool {
        if id != "horloge:fermeture" {
            return false;
        }
        let choix = valeur.get("choix").and_then(Value::as_str).unwrap_or("");
        let souvenir = valeur.get("souvenir").is_some_and(suite_commun::protocole_installateur::vrai_ps);
        match choix {
            "reduire" | "quitter" => self.fermer_choix(ctx, choix, souvenir, effets),
            // (BtnFermetureAnnuler)
            "annuler" => self.etat().question = false,
            _ => {}
        }
        true
    }

    fn tic(&mut self, ctx: &Contexte, effets: &mut Effets) -> Option<Duration> {
        if self.etat().ferme {
            return None;
        }
        // Le menu : redonné à l'icône quand la liste des applis installées change (Update-MenuHorloge le refaisait
        // à chaque ouverture)
        let lignes = menu(ctx);
        let e = self.etat();
        if let Some(i) = &e.icone
            && e.menu != lignes
        {
            i.menu(&lignes);
            e.menu = lignes;
        }
        let gestes = e.icone.as_ref().map(|i| i.gestes()).unwrap_or_default();
        for g in gestes {
            self.geste(ctx, g, effets);
        }
        // Les notifications des applis (pas en essai sans icône, comme la minuterie de zone.ps1 en mode test)
        let avec_icone = self.etat().icone.is_some();
        let releve = avec_icone || !ctx.essai;
        if releve && ctx.ecoule() >= self.etat().prochain_releve {
            self.etat().prochain_releve = ctx.ecoule() + RYTHME_NOTIFICATIONS;
            self.relever_notifications(ctx);
        }
        if avec_icone {
            Some(RYTHME_ICONE)
        } else if releve {
            Some(RYTHME_NOTIFICATIONS)
        } else {
            None
        }
    }

    /// Non : le tic ne fait que donner le menu à l'icône, lire ses gestes et relever les notifications des applis.
    /// Ce qui change l'état ou la fenêtre passe toujours par un effet (montrer, quitter, ouvrir une appli) ; le reste
    /// (le menu, la bulle d'appli en attente d'un clic, le prochain relevé) n'est pas dans l'état. Audit M2.
    fn tic_change_l_etat(&self) -> bool {
        false
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, donnees: &Value, effets: &mut Effets) {
        match nom {
            signaux::CROIX => self.croix(ctx, effets),
            signaux::REDUITE => {
                // (Add_StateChanged : réduite, avec l'icône et « ReduireHorloge » : remise en taille normale, cachée)
                if self.etat().icone.is_some() && ctx.reglage_bool("ReduireHorloge", true) {
                    effets.ajouter(Effet::Fenetre(Fenetre::Restaurer));
                    self.cacher(ctx, effets);
                }
            }
            signaux::AFFICHER_DEMANDE => self.montrer(ctx, effets),
            signaux::FENETRE => {
                let visible = donnees.get("visible").and_then(Value::as_bool).unwrap_or(false);
                let avant = std::mem::replace(&mut self.etat().visible, visible);
                // Mindset vient d'être caché (la croix, la réduction, la console) : la bulle de la première fois
                if avant && !visible {
                    self.bulle_premiere_fois(ctx);
                }
            }
            signaux::BULLE => {
                let t = |c: &str| donnees.get(c).and_then(Value::as_str).unwrap_or("").to_string();
                let duree = donnees.get("duree_ms").and_then(Value::as_u64).unwrap_or(4000).min(u64::from(u32::MAX));
                self.bulle_mindset(duree as u32, &t("titre"), &t("texte"), Dessin::depuis(&t("icone")));
            }
            signaux::ERREUR_IMPREVUE => {
                // (Show-MessageErreurImprevue ; le message sur l'écran de la console est au bloc console)
                ctx.journal(&format!("Message montré : {ERREUR_TITRE}. {ERREUR_TEXTE}"));
                self.bulle_mindset(8000, ERREUR_TITRE, ERREUR_TEXTE, Dessin::Attention);
            }
            signaux::QUITTER => self.retirer_icone(),
            _ => {}
        }
    }

    fn fermer(&mut self, _ctx: &Contexte) {
        self.retirer_icone();
    }
}

impl BlocHorloge {
    /// `Show-Fenetre` (zone.ps1:11-19)
    fn montrer(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if !ctx.vue().visible && recherche_ancienne(ctx) {
            effets.ajouter(signaux::actualiser(false));
        }
        effets.ajouter(Effet::Fenetre(Fenetre::Montrer));
    }

    /// `Hide-Fenetre` (zone.ps1:21-28). La bulle de la première fois vient au signal `fenetre` qui suit (ainsi elle
    /// vient aussi quand un autre bloc cache Mindset, comme la console et sa « veille ») ; Mindset déjà caché (pas
    /// de signal) : tout de suite.
    fn cacher(&mut self, ctx: &Contexte, effets: &mut Effets) {
        effets.ajouter(Effet::Fenetre(Fenetre::Cacher));
        if !ctx.vue().visible {
            self.bulle_premiere_fois(ctx);
        }
    }

    /// `Exit-Mindset -AvecApplis` : quitter pour de bon, les applis se ferment aussi.
    fn quitter(&mut self, effets: &mut Effets) {
        self.etat().quitte = true;
        effets.ajouter(Effet::Quitter { avec_applis: true });
    }

    fn bulle_premiere_fois(&mut self, ctx: &Contexte) {
        if !ctx.reglage_bool("BulleHorlogeVue", false) && self.etat().icone.is_some() {
            self.bulle_mindset(4000, BULLE_TITRE, BULLE_TEXTE, Dessin::Aucun);
            ctx.ecrire_reglage("BulleHorlogeVue", Value::Bool(true));
        }
    }

    /// La croix rouge (`Add_Closing`, zone.ps1:80-97)
    fn croix(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let e = self.etat();
        if e.icone.is_none() || e.quitte {
            // (sans icône, ou Mindset déjà en train de quitter, la fenêtre WPF se fermait : Mindset s'arrête, sans
            // fermer les applis s'il ne l'avait pas déjà demandé)
            effets.ajouter(Effet::Quitter { avec_applis: false });
            return;
        }
        match ctx.reglage_texte("Fermeture", "demander").to_lowercase().as_str() {
            "reduire" => self.cacher(ctx, effets),
            "quitter" => self.quitter(effets),
            _ => {
                if ctx.vue().reduite {
                    effets.ajouter(Effet::Fenetre(Fenetre::Restaurer));
                }
                let e = self.etat();
                e.question = true;
                e.ouvertures += 1;
            }
        }
    }

    /// `Close-ChoixFermeture` (zone.ps1:99-103)
    fn fermer_choix(&mut self, ctx: &Contexte, choix: &str, souvenir: bool, effets: &mut Effets) {
        self.etat().question = false;
        if souvenir {
            ctx.ecrire_reglage("Fermeture", json!(choix));
            // (Update-ReglageFermeture : le bloc « paramètres » remontre le choix)
            effets.signal(signaux::REGLAGE_CHANGE, json!({ "nom": "Fermeture", "valeur": choix }));
        }
        if choix == "quitter" {
            self.quitter(effets);
        } else {
            self.cacher(ctx, effets);
        }
    }

    /// Un geste sur l'icône (appelé par `tic` avec les gestes de l'icône ; public pour les tests).
    pub fn geste(&mut self, ctx: &Contexte, g: Geste, effets: &mut Effets) {
        match g {
            Geste::Clic | Geste::Menu(Choix::OuvrirMindset) => self.montrer(ctx, effets),
            Geste::Menu(Choix::OuvrirAppli(id)) => {
                self.montrer(ctx, effets);
                effets.ajouter(signaux::ouvrir_appli(&id, true));
            }
            Geste::Menu(Choix::ToutQuitter) => self.quitter(effets),
            Geste::BulleCliquee => self.ouvrir_bulle_appli(ctx, effets),
            Geste::BulleFermee => self.etat().bulle_appli = None,
        }
    }

    /// `Show-BulleMindset` (zone.ps1:152-155) : la bulle n'est plus celle d'une appli. Un texte vide n'est pas montré
    /// (Windows Forms le refuse).
    fn bulle_mindset(&mut self, duree_ms: u32, titre: &str, texte: &str, dessin: Dessin) {
        let e = self.etat();
        e.bulle_appli = None;
        if let Some(i) = &e.icone
            && !texte.is_empty()
        {
            i.bulle(duree_ms, titre, texte, dessin);
        }
    }

    /// `Open-BulleAppli` (zone.ps1:157-167)
    fn ouvrir_bulle_appli(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let b = self.etat().bulle_appli.take();
        self.montrer(ctx, effets);
        let Some((id, numero)) = b else { return };
        let Some(a) = ctx.appli(&id) else { return };
        effets.ajouter(signaux::ouvrir_appli(&a.id, true));
        if !numero.is_empty() {
            let Some(d) = dossier_donnees(ctx, &a) else { return };
            if let Err(e) = std::fs::write(d.join(&a.afficher_fichier), format!("notif:{numero}")) {
                ctx.journal(&format!("Notification de {} : {e}", a.nom));
            }
        }
    }

    /// `Watch-NotificationsApplis` (zone.ps1:132-148) : appelé par `tic` toutes les 2 s.
    pub fn relever_notifications(&mut self, ctx: &Contexte) {
        for a in ctx.applis().iter().filter(|a| !a.afficher_fichier.is_empty()) {
            let Some(d) = dossier_donnees(ctx, a) else { continue };
            let f = d.join(NOTIFICATION);
            if !f.is_file() {
                continue;
            }
            let j = std::fs::metadata(&f)
                .ok()
                .filter(|m| m.len() < 8192)
                .and_then(|_| std::fs::read(&f).ok())
                .and_then(|o| json_ps::lire(&suite_commun::json_sur::texte_du_fichier(&o)));
            let _ = std::fs::remove_file(&f);
            let Some(j) = j.filter(json_ps::vrai) else { continue };
            let Some(i) = &self.etat().icone else { continue };
            let n = Notification::depuis(&j, &a.nom);
            i.bulle(8000, &n.titre, if n.texte.is_empty() { " " } else { &n.texte }, Dessin::Info);
            self.etat().bulle_appli = Some((a.id.clone(), n.id));
        }
    }

    fn retirer_icone(&mut self) {
        let e = self.etat();
        e.ferme = true;
        if let Some(i) = e.icone.take() {
            i.retirer();
        }
    }
}

/// Ce que Mindset montre d'une notification (zone.ps1:140-144).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notification {
    pub titre: String,
    pub texte: String,
    /// Le numéro (12 chiffres hexadécimaux), vide s'il n'est pas valable
    pub id: String,
}

impl Notification {
    pub fn depuis(j: &json_ps::Ps, nom_appli: &str) -> Notification {
        let mut titre = json_ps::texte(&json_ps::membre(j, "titre"));
        let texte = couper(&json_ps::texte(&json_ps::membre(j, "texte")), 250);
        let mut id = json_ps::texte(&json_ps::membre(j, "id"));
        if titre.is_empty() {
            titre = nom_appli.to_string();
        }
        if !id_valable(&id) {
            id.clear();
        }
        Notification { titre: couper(&titre, 63), texte, id }
    }
}

/// Plus de `max` unités UTF-16 (`$x.Length`) : les `max - 1` premières et « … » (une paire coupée devient « � »,
/// comme `Substring` puis l'écriture en UTF-8).
pub fn couper(t: &str, max: usize) -> String {
    let u: Vec<u16> = t.encode_utf16().collect();
    if u.len() <= max {
        return t.to_string();
    }
    format!("{}…", String::from_utf16_lossy(&u[..max - 1]))
}

/// `$id -match '^[0-9a-f]{12}$'` (sans tenir compte des majuscules ; `$` accepte aussi un retour à la ligne final).
pub fn id_valable(id: &str) -> bool {
    let id = id.strip_suffix('\n').unwrap_or(id);
    id.len() == 12 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

/// `Get-DossierDonnees` (installations.ps1:24-28) : le dossier de la suite si l'appli est gérée et qu'il existe,
/// sinon son ancien dossier. `None` : aucun dossier connu (jamais un chemin relatif, donc jamais le dossier courant).
pub fn dossier_donnees(ctx: &Contexte, a: &Appli) -> Option<PathBuf> {
    let suite = ctx.dossiers.donnees_suite.join(&a.nom);
    let gere = partage::installation(ctx, &a.id).is_some_and(|i| i.gere);
    let d = if gere && suite.exists() { suite } else { PathBuf::from(&a.donnees) };
    d.is_absolute().then_some(d)
}

/// La dernière recherche des nouvelles versions date-t-elle d'au moins 15 minutes, ou n'a-t-elle jamais eu lieu ?
/// (`$script:DernieresPublications`, publié par le bloc « publications » dans `recherche.derniere`)
pub fn recherche_ancienne(ctx: &Contexte) -> bool {
    let derniere =
        ctx.lu(partage::RECHERCHE).and_then(|r| r.get("derniere").and_then(Value::as_str).map(str::to_string));
    match derniere.as_deref().and_then(mindset_noyau::moment::lire_iso) {
        None => true,
        Some(d) => mindset_noyau::moment::secondes(&ctx.heure()) - mindset_noyau::moment::secondes(&d) >= 15 * 60,
    }
}

/// Le menu du clic droit (`Update-MenuHorloge`, zone.ps1:49-65).
pub fn menu(ctx: &Contexte) -> Vec<Ligne> {
    let mut l = vec![Ligne::Choix { texte: "Ouvrir Mindset".into(), gras: true, choix: Choix::OuvrirMindset }];
    // (une seule lecture du tableau commun, dans l'ordre de la liste des applis : appelé à chaque tic)
    let installees: Vec<String> = partage::installations(ctx).into_iter().map(|(id, _)| id).collect();
    if !installees.is_empty() {
        l.push(Ligne::Separateur);
        for id in installees {
            let nom = ctx.appli(&id).map(|a| a.nom).unwrap_or_default();
            l.push(Ligne::Choix { texte: format!("Ouvrir {nom}"), gras: false, choix: Choix::OuvrirAppli(id) });
        }
    }
    l.push(Ligne::Separateur);
    l.push(Ligne::Choix {
        texte: "Tout quitter (Mindset et ses applis)".into(),
        gras: false,
        choix: Choix::ToutQuitter,
    });
    l
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocHorloge::default().nom(), "horloge");
    }

    #[test]
    fn coupes_et_numeros() {
        assert_eq!(couper("abc", 3), "abc");
        assert_eq!(couper("abcd", 3), "ab…");
        assert_eq!(couper(&format!("{}😀😀", "a".repeat(61)), 63), format!("{}\u{FFFD}…", "a".repeat(61)));
        assert!(id_valable("0123456789AB") && id_valable("0123456789ab\n"));
        assert!(!id_valable("0123456789ab\n\n") && !id_valable("0123456789ab ") && !id_valable("0123456789a"));
    }
}
