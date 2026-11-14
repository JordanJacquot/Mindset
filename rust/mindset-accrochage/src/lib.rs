//! Mindset en Rust, bloc « accrochage » : la vraie fenêtre d'une appli affichée dans Mindset (integration.ps1,
//! `MSIntegration` de natif.cs, et les états de la jauge de chargement.ps1).
//!
//! - L'appli ne tourne pas : Mindset la lance cachée (`-Demarrage`, signal `lancer-appli` au bloc « installations »),
//!   attend sa fenêtre (la jauge), puis l'accroche.
//! - Elle tourne déjà (près de l'horloge, ou dans sa fenêtre) : sa fenêtre est accrochée telle quelle.
//! - Elle se relance (nouveau thème, mise à jour) ou se ferme : Mindset le voit, et la raccroche quand elle revient.
//! - Elle se cache elle-même (sa croix la range près de l'horloge) : elle est rendue telle quelle, elle y reste.
//! - Une question de Mindset passe par-dessus (le voile) : l'appli s'efface le temps qu'elle s'en aille.
//! - Mindset quitte : chaque fenêtre est rendue telle qu'elle était, cachée ; l'appli continue près de l'horloge.
//!
//! La fenêtre de l'appli devient l'enfant d'un panneau noir de Mindset (un par appli, comme le `WindowsFormsHost` de
//! `Get-Integration`), posé sur la zone `#zone-appli` de la page, au-dessus d'elle (voir [`fenetres`] et
//! `windows`). Toutes les décisions (quelle fenêtre, quand, quelle taille, quels textes) sont ici, sans Windows : elles
//! sont jugées sur les cas exportés de la version PowerShell (`tests/juges`).

use serde_json::{Map, Value, json};
use std::path::PathBuf;
use std::time::Duration;

use mindset_noyau::appli::{self, Appli};
use mindset_noyau::{Bloc, Contexte, Effet, Effets, partage, signaux};

pub mod fenetres;
#[cfg(windows)]
pub mod windows;

pub use fenetres::{FauxFenetres, Fenetres, Styles, Zone};

/// La surveillance (`$script:IntegrationTimer`, integration.ps1:181-182).
const INTERVALLE: Duration = Duration::from_millis(400);
/// La demande d'ouverture d'une autre appli, dans le dossier de données de l'appli montrée (docs\contrat-appli.md)
pub const OUVRIR_DEMANDE: &str = "ouvrir.demande";
/// Au-delà (64 octets ou plus), la demande est supprimée sans être lue
const OUVRIR_TAILLE_MAX: u64 = 64;
/// 100 ns par seconde (FILETIME).
const FT_SECONDE: u64 = 10_000_000;
/// Le 01/01/1970 en FILETIME.
const FT_EPOQUE_UNIX: u64 = 116_444_736_000_000_000;

/// `$i.Etat` : où en est l'appli dans Mindset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Etat {
    /// Rien d'affiché (fermée, ou pas encore ouverte)
    Vide,
    /// Lancée (ou qui démarre) : sa fenêtre est attendue
    Lancement,
    /// Sa fenêtre est partie : fermée, ou relancée (thème, mise à jour)
    Relance,
    /// Accrochée et affichée
    Affiche,
    /// Elle s'est cachée elle-même (près de l'horloge)
    Cachee,
    /// Windows a refusé de l'accrocher
    Refus,
}

impl Etat {
    pub fn nom(self) -> &'static str {
        match self {
            Etat::Vide => "vide",
            Etat::Lancement => "lancement",
            Etat::Relance => "relance",
            Etat::Affiche => "affiche",
            Etat::Cachee => "cachee",
            Etat::Refus => "refus",
        }
    }
}

/// Une appli dans Mindset (`Get-Integration` : `@{ Hote; Panneau; Fenetre; Styles; Etat; Depuis; Pid; ... }`).
#[derive(Debug)]
struct Integration {
    id: String,
    /// Le panneau (créé à la première accroche)
    hote: Option<isize>,
    /// `$i.Hote.Visibility -eq 'Visible'`
    hote_visible: bool,
    /// `$i.Panneau.ClientSize` : la dernière taille du panneau
    taille: (i32, i32),
    fenetre: Option<isize>,
    styles: Option<Styles>,
    etat: Etat,
    /// `$i.Depuis` (FILETIME)
    depuis: u64,
    debloquee: bool,
    relancee: bool,
    pid: Option<u32>,
    /// L'attente d'une fenêtre trouvée mais pas prête est déjà notée au journal (une fois par attente)
    attente_notee: bool,
}

/// Pourquoi une fenêtre trouvée n'est pas encore accrochée (audit G4 : c'est une attente, pas un abandon).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PasPrete {
    /// Elle ne répond pas dans la seconde (elle démarre, ou elle travaille)
    NeRepondPas,
    /// Mindset n'a pas encore sa fenêtre
    SansFenetreDeMindset,
    /// Le panneau n'a pas pu être créé
    SansPanneau,
}

impl PasPrete {
    fn texte(self) -> &'static str {
        match self {
            PasPrete::NeRepondPas => "ne répond pas encore : il sera affiché dès qu'il répondra",
            PasPrete::SansFenetreDeMindset => "pas encore affiché : Mindset n'a pas encore sa fenêtre",
            PasPrete::SansPanneau => "pas encore affiché : sa place dans Mindset n'a pas pu être créée",
        }
    }
}

/// Ce que la page de l'appli affiche quand l'appli n'y est pas (PageAppliTitre, PageAppliTexte, BtnPageAppliIci).
#[derive(Debug, Clone, Default, PartialEq)]
struct EcranAppli {
    titre: String,
    couleur: String,
    /// Vide : le texte est replié
    texte: String,
    bouton_ici: bool,
    bouton_texte: String,
}

/// `$script:Jauge` : la jauge d'ouverture (ou l'écran « Ouvrir », `Ecran`), une seule à la fois.
#[derive(Debug, Clone, PartialEq)]
struct Jauge {
    id: String,
    ecran: bool,
    depuis: u64,
    duree: f64,
}

/// Le bloc « accrochage ».
///
/// `mindset-appli` (`blocs()`) écrit `BlocAccrochage::default()` : un
/// bloc neuf, qui prend le vrai Windows à son démarrage. Les tests prennent [`BlocAccrochage::avec`].
pub struct BlocAccrochage {
    fenetres: Option<Box<dyn Fenetres>>,
    /// Un port donné par un test : les vraies applis ne sont jamais concernées, la garde d'essai ne s'applique pas
    injecte: bool,
    port_essaye: bool,
    integrees: Vec<Integration>,
    ecrans: Vec<(String, EcranAppli)>,
    jauge: Option<Jauge>,
    /// `$ui.BarreAppli.Visibility -eq 'Collapsed'` : l'appli affichée a sa propre barre
    barre_cachee: bool,
    /// `$ui.PageAppliCadre.Visibility -eq 'Visible'` : l'appli de la page est affichée
    cadre: bool,
    /// La surveillance tourne
    minuterie: bool,
    /// Le prochain passage de la surveillance (temps écoulé du contexte)
    prochain: Duration,
    zone: Zone,
    /// Le dernier signal `voile` (avant le premier : le tableau commun)
    voile: Option<bool>,
    /// `Open-AppliIci` : l'appli à lancer une fois sa page montrée
    lancer_apres_page: Option<String>,
    /// Les tâches d'arrêt d'un programme bloqué en cours
    numero_tache: u32,
    publie: Option<Value>,
    /// L'appli de la page qui se cache elle-même ramène Mindset à l'accueil (DIVERGENCES.md, point 9 ; coupé
    /// seulement pour rejouer les juges de la version PowerShell)
    retour_accueil: bool,
    /// Un `ouvrir.demande` impossible à supprimer : déjà noté au journal (il est ignoré tant qu'il reste)
    ouvrir_bloque: bool,
}

/// Un bloc neuf (voir [`BlocAccrochage`]).
impl Default for BlocAccrochage {
    fn default() -> BlocAccrochage {
        BlocAccrochage::VIDE
    }
}

impl std::fmt::Debug for BlocAccrochage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BlocAccrochage").field("integrees", &self.integrees).field("jauge", &self.jauge).finish()
    }
}

fn arrondi_pair(x: f64) -> f64 {
    // [math]::Round et [int] de PowerShell : au plus proche, un demi vers le nombre pair
    x.round_ties_even()
}

/// L'heure du PC en FILETIME (quand aucun port n'est là).
fn horloge_systeme() -> u64 {
    let d = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    FT_EPOQUE_UNIX + d.as_secs() * FT_SECONDE + u64::from(d.subsec_nanos()) / 100
}

/// FILETIME en millisecondes depuis 1970 (le `Date.now()` de la page).
fn en_ms(ft: u64) -> i64 {
    (ft as i64 - FT_EPOQUE_UNIX as i64) / 10_000
}

fn secondes(depuis: u64, maintenant: u64) -> f64 {
    (maintenant as f64 - depuis as f64) / FT_SECONDE as f64
}

/// Une page de Mindset qui n'est pas une appli.
fn page_de_mindset(id: &str) -> bool {
    id == "accueil" || id == "parametres"
}

/// Le contenu de `ouvrir.demande` : un id d'appli (`^[a-z0-9-]{1,30}$`).
fn id_demande(id: &str) -> bool {
    (1..=30).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Le dossier de données d'une appli, comme pour ses autres fichiers `.demande` (`dossier_donnees` de
/// mindset-horloge, `Get-DossierDonnees`) : celui de la suite si l'appli est gérée et qu'il existe, sinon son ancien
/// dossier ; jamais un chemin relatif.
fn dossier_donnees(ctx: &Contexte, a: &Appli) -> Option<PathBuf> {
    let suite = ctx.dossiers.donnees_suite.join(&a.nom);
    let gere = partage::installation(ctx, &a.id).is_some_and(|i| i.gere);
    let d = if gere && suite.exists() { suite } else { PathBuf::from(&a.donnees) };
    d.is_absolute().then_some(d)
}

impl BlocAccrochage {
    const VIDE: BlocAccrochage = BlocAccrochage {
        fenetres: None,
        injecte: false,
        port_essaye: false,
        integrees: Vec::new(),
        ecrans: Vec::new(),
        jauge: None,
        barre_cachee: false,
        cadre: false,
        minuterie: false,
        prochain: Duration::ZERO,
        zone: Zone { x: 0, y: 0, largeur: 0, hauteur: 0, visible: false },
        voile: None,
        lancer_apres_page: None,
        numero_tache: 0,
        publie: None,
        retour_accueil: true,
        ouvrir_bloque: false,
    };

    /// Un bloc sur ce port (tests : [`FauxFenetres`]).
    pub fn avec(fenetres: Box<dyn Fenetres>) -> BlocAccrochage {
        BlocAccrochage { fenetres: Some(fenetres), injecte: true, port_essaye: true, ..BlocAccrochage::VIDE }
    }

    /// Pour rejouer les juges de la version PowerShell : l'appli qui se cache elle-même laisse Mindset sur sa page,
    /// avec l'écran « réduit près de l'horloge » (comme avant le 08/11/2026 ; DIVERGENCES.md, point 9).
    pub fn sans_retour_accueil(mut self) -> BlocAccrochage {
        self.retour_accueil = false;
        self
    }

    /// La surveillance de 400 ms tourne (`$script:IntegrationTimer.IsEnabled`).
    pub fn minuterie(&self) -> bool {
        self.minuterie
    }

    // -----------------------------------------------------------------------------------------------------------
    // Le port
    // -----------------------------------------------------------------------------------------------------------

    /// En essai, jamais les vraies applis (integration.ps1:73-74) : sauf essai d'accrochage demandé
    /// (`MINDSET_INTEGRATION_TEST`) ou port donné par un test.
    fn garde(&self, ctx: &Contexte) -> bool {
        !self.injecte && ctx.essai && std::env::var_os("MINDSET_INTEGRATION_TEST").is_none()
    }

    fn assurer_port(&mut self, ctx: &Contexte) {
        if self.port_essaye {
            return;
        }
        self.port_essaye = true;
        if self.garde(ctx) {
            return;
        }
        #[cfg(windows)]
        {
            self.fenetres = Some(Box::new(windows::FenetresWindows::nouveau()));
        }
    }

    fn f(&self) -> Option<&dyn Fenetres> {
        self.fenetres.as_deref()
    }

    fn maintenant(&self) -> u64 {
        self.f().map_or_else(horloge_systeme, |f| f.maintenant())
    }

    fn existe(&self, h: isize) -> bool {
        self.f().is_some_and(|f| f.existe(h))
    }

    /// Une variable d'essai des captures (`$EnTest -and $env:MINDSET_ECRAN`), jamais avec un port de test.
    fn variable_essai(&self, ctx: &Contexte, nom: &str) -> Option<String> {
        if self.injecte || !ctx.essai {
            return None;
        }
        std::env::var(nom).ok().filter(|v| !v.is_empty())
    }

    // -----------------------------------------------------------------------------------------------------------
    // Get-Integration, la page courante, la jauge
    // -----------------------------------------------------------------------------------------------------------

    fn index(&mut self, id: &str) -> usize {
        if let Some(k) = self.integrees.iter().position(|i| i.id == id) {
            return k;
        }
        let depuis = self.maintenant();
        self.integrees.push(Integration {
            id: id.into(),
            hote: None,
            hote_visible: false,
            taille: (0, 0),
            fenetre: None,
            styles: None,
            etat: Etat::Vide,
            depuis,
            debloquee: false,
            relancee: false,
            pid: None,
            attente_notee: false,
        });
        self.integrees.len() - 1
    }

    fn ecran_mut(&mut self, id: &str) -> &mut EcranAppli {
        if let Some(k) = self.ecrans.iter().position(|(x, _)| x == id) {
            return &mut self.ecrans[k].1;
        }
        self.ecrans.push((id.into(), EcranAppli::default()));
        &mut self.ecrans.last_mut().expect("ajouté").1
    }

    fn ecran(&self, id: &str) -> Option<&EcranAppli> {
        self.ecrans.iter().find(|(x, _)| x == id).map(|(_, e)| e)
    }

    fn page(ctx: &Contexte) -> String {
        ctx.vue().page
    }

    fn voile(&self, ctx: &Contexte) -> bool {
        self.voile.unwrap_or_else(|| partage::voile(ctx))
    }

    fn demarrer_minuterie(&mut self, ctx: &Contexte) {
        // (DispatcherTimer.Start : déjà en route, rien ne change ; arrêtée, un passage dans 400 ms)
        if !self.minuterie {
            self.minuterie = true;
            self.prochain = ctx.ecoule() + INTERVALLE;
        }
    }

    /// `Stop-JaugeAppli`
    fn arreter_jauge(&mut self) {
        self.jauge = None;
    }

    /// `Set-EtatPageAppli` (integration.ps1:118-127)
    fn etat_page(&mut self, ctx: &Contexte, a: &Appli, titre: &str, texte: &str) {
        if Self::page(ctx) != a.id {
            return;
        }
        self.arreter_jauge();
        let couleur = partage::couleur(ctx, &a.couleur);
        let e = self.ecran_mut(&a.id);
        e.titre = titre.into();
        e.couleur = couleur;
        e.texte = texte.into();
        e.bouton_ici = false;
    }

    /// `Show-JaugeAppli` (chargement.ps1:255-282) : la jauge de l'appli sur sa page ; déjà là, elle continue.
    fn montrer_jauge(&mut self, ctx: &Contexte, a: &Appli, texte: &str) {
        if Self::page(ctx) != a.id {
            return;
        }
        let couleur = partage::couleur(ctx, &a.couleur);
        let e = self.ecran_mut(&a.id);
        e.titre = a.nom.clone();
        e.couleur = couleur;
        e.texte = texte.into();
        e.bouton_ici = false;
        if self.jauge.as_ref().is_some_and(|j| j.id == a.id && !j.ecran) {
            return;
        }
        self.arreter_jauge();
        let k = self.index(&a.id);
        let defaut = match a.id.as_str() {
            "nevermind" => Some(20.0),
            "evermind" => Some(10.0),
            _ => None,
        };
        // ([double](Get-Setting "Ouverture-<id>" <défaut>), puis 10 s si elle est absente ou de moins de 2 s)
        let lu = ctx.reglage(&format!("Ouverture-{}", a.id));
        let duree = match lu {
            Some(v) => duree_reglage(&v),
            None => defaut.unwrap_or(0.0),
        };
        let duree = if duree.is_nan() || duree < 2.0 { 10.0 } else { duree };
        self.jauge = Some(Jauge { id: a.id.clone(), ecran: false, depuis: self.integrees[k].depuis, duree });
    }

    /// `Show-EcranOuvrir` (chargement.ps1:321-337) : l'écran de l'appli fermée, avec « Ouvrir ».
    fn ecran_ouvrir(&mut self, ctx: &Contexte, a: &Appli, texte: &str) {
        if Self::page(ctx) != a.id {
            return;
        }
        self.arreter_jauge();
        let couleur = partage::couleur(ctx, &a.couleur);
        let e = self.ecran_mut(&a.id);
        e.titre = a.nom.clone();
        e.couleur = couleur;
        e.texte = texte.into();
        e.bouton_ici = true;
        e.bouton_texte = format!("Ouvrir {}", a.nom);
        self.jauge = Some(Jauge { id: a.id.clone(), ecran: true, depuis: 0, duree: 0.0 });
    }

    /// `Save-DureeOuverture` (chargement.ps1:314-317)
    fn retenir_duree(&self, ctx: &Contexte, a: &Appli, depuis: u64) {
        let s = secondes(depuis, self.maintenant());
        if (1.0..=120.0).contains(&s) {
            ctx.ecrire_reglage(&format!("Ouverture-{}", a.id), json!(arrondi_pair(s * 10.0) / 10.0));
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // integration.ps1
    // -----------------------------------------------------------------------------------------------------------

    /// `Find-FenetreAppli` (integration.ps1:35-41)
    fn trouver_fenetre(&self, ctx: &Contexte, a: &Appli) -> Option<isize> {
        let f = self.f()?;
        appli::processus_appli(ctx, a, true).iter().find_map(|p| f.trouver(p.pid, &a.nom))
    }

    /// `Start-AppliCachee` (integration.ps1:45-49) : cachée (`-Demarrage`) si sa version sait se dessiner une fois
    /// accrochée, sinon normalement.
    fn lancer_cachee(&self, ctx: &Contexte, a: &Appli, e: &mut Effets) {
        let inst = partage::installation(ctx, &a.id);
        let version = inst.and_then(|i| i.version).unwrap_or_default();
        let cache = !a.cache_depuis.is_empty()
            && !version.is_empty()
            && !suite_commun::version::plus_recente(&a.cache_depuis, &version);
        e.signal(signaux::LANCER_APPLI, json!({ "id": a.id, "demarrage": cache }));
    }

    /// `Stop-AppliBloquee`, la décision (integration.ps1:53-63) : les programmes de l'appli ouverts depuis plus d'une
    /// minute sans aucune fenêtre. L'arrêt lui-même (et l'attente de 3 s) est un travail de fond.
    fn bloques(&self, ctx: &Contexte, a: &Appli) -> Vec<u32> {
        if partage::installation(ctx, &a.id).is_none() {
            return Vec::new();
        }
        let maintenant = self.maintenant();
        let mut r = Vec::new();
        for p in appli::processus_appli(ctx, a, true) {
            // (StartTime illisible : l'âge compte pour 0)
            let age = if p.creation == 0 { 0.0 } else { secondes(p.creation, maintenant) };
            if age < 60.0 || self.f().and_then(|f| f.trouver(p.pid, &a.nom)).is_some() {
                continue;
            }
            r.push(p.pid);
        }
        r
    }

    /// `Test-NouveauProcessus` (integration.ps1:162-168)
    fn nouveau_processus(&self, ctx: &Contexte, a: &Appli, k: usize) -> bool {
        let i = &self.integrees[k];
        let seuil = i.depuis.saturating_sub(10 * FT_SECONDE);
        appli::processus_appli(ctx, a, true)
            .iter()
            .any(|p| Some(p.pid) != i.pid && p.creation != 0 && p.creation >= seuil)
    }

    /// `Show-AppliIntegree` (integration.ps1:67-95)
    fn afficher(&mut self, ctx: &Contexte, a: &Appli, lancer: bool, e: &mut Effets) {
        let k = self.index(&a.id);
        if self.variable_essai(ctx, "MINDSET_ECRAN").is_some() {
            self.ecran_ouvrir(ctx, a, &format!("{} est fermé.", a.nom));
            return;
        }
        if let Some(s) = self.variable_essai(ctx, "MINDSET_JAUGE") {
            let s: f64 = s.trim().parse().unwrap_or(0.0);
            self.integrees[k].depuis = self.maintenant().saturating_sub((s.max(0.0) * FT_SECONDE as f64) as u64);
            self.montrer_jauge(ctx, a, "Ouverture...");
            return;
        }
        let Some(inst) = partage::installation(ctx, &a.id) else {
            self.etat_page(ctx, a, &format!("{} n'est pas installé.", a.nom), "Installe-le depuis l'accueil.");
            return;
        };
        if self.garde(ctx) {
            self.etat_page(
                ctx,
                a,
                &format!("{} s'affichera ici", a.nom),
                "(test : les vraies applis ne sont pas lancées)",
            );
            return;
        }
        if let Some(h) = self.integrees[k].fenetre
            && self.existe(h)
        {
            self.hotes_visibles(ctx);
            return;
        }
        // (les applis ne s'ouvrent que dans Mindset : sans ses droits, Nevermind n'est pas lancé à côté)
        if appli::appli_admin(a, Some(&inst)) && !ctx.lancement.admin {
            self.etat_page(
                ctx,
                a,
                &format!("{} doit être mis à jour", a.nom),
                "Cette version demande les droits administrateur. Mets-le à jour depuis sa carte de l'accueil : la nouvelle version n'en a plus besoin.",
            );
            return;
        }
        if let Some(h) = self.trouver_fenetre(ctx, a) {
            if self.connecter(ctx, a, h).is_err() {
                // Trouvée mais pas encore prête (audit G4) : elle démarre, la jauge, et la surveillance la raccroche
                // dès qu'elle répond (avant le 08/11/2026, la page restait vide et plus personne ne la regardait)
                let etat = self.integrees[k].etat;
                if etat != Etat::Lancement && etat != Etat::Relance {
                    let maintenant = self.maintenant();
                    let i = &mut self.integrees[k];
                    i.etat = Etat::Lancement;
                    i.depuis = maintenant;
                    i.debloquee = false;
                }
                if self.integrees[k].etat == Etat::Lancement {
                    self.montrer_jauge(ctx, a, "Ouverture...");
                }
                self.demarrer_minuterie(ctx);
            }
            return;
        }
        let etat = self.integrees[k].etat;
        let mut en_cours = etat == Etat::Lancement || (etat == Etat::Relance && self.nouveau_processus(ctx, a, k));
        if !en_cours && etat != Etat::Relance && appli::appli_ouverte(ctx, a) {
            // (elle démarre : sa fenêtre arrive)
            let maintenant = self.maintenant();
            let i = &mut self.integrees[k];
            i.etat = Etat::Lancement;
            i.depuis = maintenant;
            i.debloquee = false;
            en_cours = true;
        }
        if !en_cours && !lancer {
            self.integrees[k].etat = Etat::Vide;
            self.ecran_ouvrir(ctx, a, &format!("{} est fermé.", a.nom));
            return;
        }
        if !en_cours {
            let maintenant = self.maintenant();
            let i = &mut self.integrees[k];
            i.etat = Etat::Lancement;
            i.depuis = maintenant;
            i.debloquee = false;
            self.lancer_cachee(ctx, a, e);
        }
        self.montrer_jauge(ctx, a, "Ouverture...");
        self.demarrer_minuterie(ctx);
    }

    /// `Connect-Fenetre` (integration.ps1:97-115). `Err` : la fenêtre est trouvée mais pas encore prête (l'appli ne
    /// répond pas, Mindset n'a pas encore de fenêtre, ou pas de panneau) : rien n'est fait, c'est une attente, à
    /// réessayer au passage suivant de la surveillance (une ligne au journal la première fois).
    fn connecter(&mut self, ctx: &Contexte, a: &Appli, h: isize) -> Result<(), PasPrete> {
        let k = self.index(&a.id);
        let Some(f) = self.fenetres.as_deref() else { return Ok(()) };
        let pret = if !f.repond(h) {
            // (une appli figée n'est pas accrochée maintenant : Mindset resterait bloqué avec elle)
            Err(PasPrete::NeRepondPas)
        } else if let Some(parent) = ctx.fenetre_principale() {
            match self.integrees[k].hote {
                Some(x) => Ok(x),
                None => f.hote(&a.id, parent).ok_or(PasPrete::SansPanneau),
            }
        } else {
            Err(PasPrete::SansFenetreDeMindset)
        };
        let hote = match pret {
            Ok(x) => x,
            Err(raison) => {
                if !std::mem::replace(&mut self.integrees[k].attente_notee, true) {
                    ctx.journal(&format!("{} {}", a.nom, raison.texte()));
                }
                return Err(raison);
            }
        };
        let Some(f) = self.fenetres.as_deref() else { return Ok(()) };
        // (le panneau est montré pour avoir sa taille : celle de la zone, rien si la page de l'appli est repliée)
        let taille = self.zone.taille();
        f.placer_hote(hote, self.zone, true);
        let styles = f.accrocher(h, hote, taille.0.max(200), taille.1.max(200));
        {
            let i = &mut self.integrees[k];
            i.hote = Some(hote);
            i.hote_visible = true;
            i.taille = taille;
        }
        let Some(styles) = styles else {
            f.placer_hote(hote, self.zone, false);
            self.integrees[k].hote_visible = false;
            self.integrees[k].etat = Etat::Refus;
            self.etat_page(
                ctx,
                a,
                &format!("{} n'a pas pu s'afficher ici", a.nom),
                "Windows a refusé de l'accrocher : quitte tout (icône près de l'horloge) puis rouvre Mindset.",
            );
            ctx.journal(&format!("Intégration de {} refusée par Windows", a.nom));
            return Ok(());
        };
        if self.integrees[k].etat == Etat::Lancement {
            self.retenir_duree(ctx, a, self.integrees[k].depuis);
        }
        let pid = f.processus(h);
        {
            let i = &mut self.integrees[k];
            i.fenetre = Some(h);
            i.styles = Some(styles);
            i.etat = Etat::Affiche;
            i.pid = Some(pid);
            i.attente_notee = false;
        }
        ctx.journal(&format!("{} affiché dans Mindset", a.nom));
        self.hotes_visibles(ctx);
        if let Some(f) = self.f() {
            f.focus(h);
        }
        self.demarrer_minuterie(ctx);
        Ok(())
    }

    /// `Update-HotesVisibles` (integration.ps1:131-144) : une seule appli visible, celle de la page montrée, et aucune
    /// sous une question de Mindset.
    fn hotes_visibles(&mut self, ctx: &Contexte) {
        let dessus = self.voile(ctx);
        let page = Self::page(ctx);
        let zone = self.zone;
        for k in 0..self.integrees.len() {
            let voir = !dessus && page == self.integrees[k].id && self.integrees[k].fenetre.is_some();
            self.montrer_hote(k, voir, zone);
        }
        let montree = self.integrees.iter().any(|i| i.id == page && i.fenetre.is_some());
        if self.jauge.as_ref().is_some_and(|j| montree || j.id != page) {
            self.arreter_jauge();
        }
        self.cadre = montree;
        self.maj_barre(ctx);
    }

    /// Le panneau d'une appli montré ou caché ; montré, il prend la taille de la zone, et la fenêtre de l'appli avec
    /// lui (le `Add_Resize` du panneau, integration.ps1:29).
    fn montrer_hote(&mut self, k: usize, voir: bool, zone: Zone) {
        let Some(f) = self.fenetres.as_deref() else { return };
        let i = &mut self.integrees[k];
        let Some(hote) = i.hote else {
            i.hote_visible = false;
            return;
        };
        if voir {
            f.placer_hote(hote, zone, true);
            i.hote_visible = true;
            let t = zone.taille();
            if zone.utilisable() && t != i.taille {
                i.taille = t;
                if let Some(h) = i.fenetre {
                    f.redimensionner(h, t.0, t.1);
                }
            }
        } else if i.hote_visible {
            f.placer_hote(hote, zone, false);
            i.hote_visible = false;
        }
    }

    /// `Update-BarreAppli` (integration.ps1:147-152) : la barre de Mindset s'efface quand l'appli affichée a la sienne.
    fn maj_barre(&mut self, ctx: &Contexte) {
        let page = Self::page(ctx);
        let fenetre = self.integrees.iter().find(|i| i.id == page).and_then(|i| i.fenetre);
        self.barre_cachee = fenetre.is_some_and(|h| self.f().is_some_and(|f| f.barre_propre(h)));
    }

    /// La surveillance de 400 ms (integration.ps1:183-238) : fenêtre attendue (lancement, relance), fenêtre fermée ou
    /// cachée par l'appli elle-même.
    fn surveiller(&mut self, ctx: &Contexte, e: &mut Effets) {
        let mut attente = false;
        self.maj_barre(ctx);
        for k in 0..self.integrees.len() {
            let id = self.integrees[k].id.clone();
            // (une appli sortie de la liste : plus rien à surveiller pour elle)
            let Some(a) = ctx.appli(&id) else { continue };
            if let Some(h) = self.integrees[k].fenetre {
                if !self.existe(h) {
                    // Fermée (sa croix, son menu Quitter) ou relancée (mise à jour) : l'écran « Ouvrir », et si un
                    // nouveau processus démarre, c'est une relance : la jauge, puis sa nouvelle fenêtre est raccrochée
                    let maintenant = self.maintenant();
                    let i = &mut self.integrees[k];
                    i.fenetre = None;
                    i.styles = None;
                    i.etat = Etat::Relance;
                    i.depuis = maintenant;
                    i.relancee = false;
                    self.hotes_visibles(ctx);
                    // (l'appli montrée, fermée par l'utilisateur : retour à l'accueil, DIVERGENCES.md point 9 ; une
                    // relance pour un thème se fait depuis les Paramètres, une mise à jour est une occupation)
                    if !self.retour_a_l_accueil(ctx, &a, e) {
                        self.ecran_ouvrir(ctx, &a, &format!("{} est fermé.", a.nom));
                    }
                } else if !self.f().is_some_and(|f| f.est_montree(h)) {
                    // Elle s'est cachée elle-même (sa croix : « Quitter » ou « Réduire ») : sa place est effacée
                    // tout de suite, sa fenêtre lui est rendue telle quelle (sans l'attendre : une appli qui quitte
                    // ne traite plus ses messages), et si c'était l'appli montrée, Mindset revient à l'accueil
                    // (DIVERGENCES.md, point 9 ; avant le 08/11/2026, la page de l'appli restait sur elle)
                    let s = self.integrees[k].styles;
                    let i = &mut self.integrees[k];
                    i.fenetre = None;
                    i.styles = None;
                    i.etat = Etat::Cachee;
                    self.hotes_visibles(ctx);
                    if let (Some(f), Some(s)) = (self.f(), s) {
                        f.liberer_sans_attendre(h, s);
                    }
                    if !self.retour_a_l_accueil(ctx, &a, e) {
                        self.ecran_ouvrir(ctx, &a, &format!("{} est réduit près de l'horloge.", a.nom));
                    }
                }
            }
            let etat = self.integrees[k].etat;
            if etat != Etat::Lancement && etat != Etat::Relance {
                continue;
            }
            // (trouvée mais pas encore prête, audit G4 : c'est une attente comme une autre, la surveillance continue et
            // la limite d'une minute ci-dessous s'applique ; avant le 08/11/2026 : `continue` sans attente, la
            // surveillance s'arrêtait et la jauge « Ouverture... » restait pour toujours)
            if let Some(h) = self.trouver_fenetre(ctx, &a)
                && self.connecter(ctx, &a, h).is_ok()
            {
                continue;
            }
            if etat == Etat::Relance && !self.integrees[k].relancee && self.nouveau_processus(ctx, &a, k) {
                self.integrees[k].relancee = true;
            }
            if etat == Etat::Relance
                && self.integrees[k].relancee
                && self.jauge.as_ref().is_some_and(|j| j.ecran && j.id == a.id)
            {
                self.montrer_jauge(ctx, &a, "Relance...");
            }
            let ecoule = secondes(self.integrees[k].depuis, self.maintenant());
            // Un programme de l'appli resté ouvert sans fenêtre : la fenêtre attendue ne viendra jamais. Il est arrêté,
            // puis l'appli est relancée (une fois par ouverture).
            if etat == Etat::Lancement && !self.integrees[k].debloquee && ecoule > 5.0 {
                self.integrees[k].debloquee = true;
                let pids = self.bloques(ctx, &a);
                if !pids.is_empty() {
                    self.arreter_bloques(ctx, &id, pids, e);
                    attente = true;
                    continue;
                }
            }
            // (Nevermind met près de 20 s à démarrer : on lui laisse une minute ; arrêtée pendant son démarrage,
            // inutile d'attendre)
            let vivant = appli::appli_ouverte(ctx, &a);
            let limite = if etat == Etat::Lancement && !vivant { 15.0 } else { 60.0 };
            if ecoule > limite {
                let echec = etat == Etat::Lancement || self.integrees[k].relancee;
                self.integrees[k].etat = Etat::Vide;
                if echec {
                    self.ecran_ouvrir(ctx, &a, &format!("{} n'a pas pu s'ouvrir.", a.nom));
                    ctx.journal(&format!(
                        "{} ne s'est pas affiché après {} s ({})",
                        a.nom,
                        arrondi_pair(ecoule) as i64,
                        if vivant { "son programme tourne encore" } else { "son programme s'est arrêté" }
                    ));
                }
            } else {
                attente = true;
            }
        }
        if !attente && !self.integrees.iter().any(|i| i.fenetre.is_some()) {
            self.minuterie = false;
        }
    }

    /// L'appli montrée vient de se cacher ou de se fermer elle-même : Mindset revient à l'accueil (DIVERGENCES.md,
    /// point 9), sauf pendant une opération de Mindset sur elle (une occupation : mise à jour, installation). `true` :
    /// l'accueil est demandé.
    fn retour_a_l_accueil(&self, ctx: &Contexte, a: &Appli, e: &mut Effets) -> bool {
        if !self.retour_accueil || Self::page(ctx) != a.id || partage::occupation(ctx, &a.id).is_some() {
            return false;
        }
        ctx.journal(&format!("{} fermé ou réduit dans Mindset : retour à l'accueil", a.nom));
        e.ajouter(Effet::Page("accueil".into()));
        true
    }

    /// `ouvrir.demande` (docs\contrat-appli.md, partie 5) : l'appli montrée en ce moment demande d'ouvrir une autre
    /// appli de la suite (le bouton « Ouvrir Nevermind » de Mindcare). Seulement l'appli affichée à l'écran (sa page,
    /// Mindset montré, sa fenêtre accrochée) ; le fichier, dans son dossier de données, contient l'id d'une appli de
    /// la liste, autre qu'elle. Lu une fois puis supprimé (même illisible), il fait ce que fait un clic sur la carte :
    /// sa page, puis elle est lancée si elle est installée. Jamais d'installation.
    fn relever_ouvrir(&mut self, ctx: &Contexte, e: &mut Effets) {
        let vue = ctx.vue();
        if !vue.visible || vue.reduite || page_de_mindset(&vue.page) {
            return;
        }
        if !self.integrees.iter().any(|i| i.id == vue.page && i.fenetre.is_some()) {
            return;
        }
        let Some(a) = ctx.appli(&vue.page) else { return };
        let Some(d) = dossier_donnees(ctx, &a) else { return };
        // (en essai, seulement dans le dossier d'essai : jamais les données des vraies applis)
        let racine = ctx.dossiers.donnees_suite.parent().unwrap_or(&ctx.dossiers.donnees_suite);
        if ctx.essai && !d.starts_with(racine) {
            return;
        }
        let f = d.join(OUVRIR_DEMANDE);
        // (un dossier ou un lien à ce nom : laissé tel quel, jamais suivi)
        let Ok(m) = std::fs::symlink_metadata(&f) else {
            self.ouvrir_bloque = false;
            return;
        };
        if !m.is_file() {
            return;
        }
        let contenu = (m.len() < OUVRIR_TAILLE_MAX)
            .then(|| std::fs::read(&f).ok())
            .flatten()
            .map(|o| suite_commun::json_sur::texte_du_fichier(&o).trim_start_matches('\u{FEFF}').trim().to_string());
        if let Err(x) = std::fs::remove_file(&f) {
            // (noté une fois : la surveillance repasse toutes les 400 ms)
            if !self.ouvrir_bloque {
                self.ouvrir_bloque = true;
                ctx.journal(&format!("Demande d'ouverture de {} non supprimée, ignorée : {x}", a.nom));
            }
            return;
        }
        self.ouvrir_bloque = false;
        let cible = contenu.filter(|c| id_demande(c) && *c != a.id).and_then(|c| ctx.appli(&c));
        let Some(c) = cible else {
            ctx.journal(&format!("Demande d'ouverture de {} illisible, ignorée", a.nom));
            return;
        };
        ctx.journal(&format!("{} demande d'ouvrir {}", a.nom, c.nom));
        // (le signal pour les autres blocs, la console : l'hôte ne le rend pas à son auteur, d'où `ouvrir_ici`)
        e.ajouter(signaux::ouvrir_appli(&c.id, true));
        self.ouvrir_ici(ctx, &c.id, true, e);
    }

    /// Le signal `ouvrir-appli`, `Open-AppliIci` (integration.ps1:178) : son onglet, puis elle est lancée (`lancer`).
    /// Pas installée : sa page dit « n'est pas installé » ([`Self::afficher`]), rien n'est lancé.
    fn ouvrir_ici(&mut self, ctx: &Contexte, id: &str, lancer: bool, e: &mut Effets) {
        if ctx.appli(id).is_some() {
            if lancer {
                self.lancer_apres_page = Some(id.to_string());
            }
            e.ajouter(Effet::Page(id.to_string()));
        }
    }

    /// L'arrêt des programmes bloqués (`$p.Kill(); $p.WaitForExit(3000)`), sur un autre fil : la fin revient dans
    /// [`Bloc::tache_finie`].
    fn arreter_bloques(&mut self, ctx: &Contexte, id: &str, pids: Vec<u32>, e: &mut Effets) {
        self.numero_tache += 1;
        let systeme = ctx.systeme();
        let id = id.to_string();
        e.tache(&format!("bloques:{}:{id}", self.numero_tache), move || {
            let mut n = 0;
            let mut refus = Vec::new();
            for pid in pids {
                match systeme.arreter(pid) {
                    Ok(()) => {
                        systeme.attendre_fin(pid, 3000);
                        n += 1;
                    }
                    Err(m) => refus.push(Value::String(m)),
                }
            }
            Ok(json!({ "id": id, "arretes": n, "refus": refus }))
        });
    }

    /// `Disconnect-Applis` (integration.ps1:241-246) : chaque appli retrouve sa fenêtre, cachée près de l'horloge.
    /// Une appli figée n'est pas attendue plus de `windows::DELAI_APPLI` (audit M3) : Mindset quitte quand même.
    fn decrocher_tout(&mut self, ctx: &Contexte) {
        for k in 0..self.integrees.len() {
            if let (Some(h), Some(s)) = (self.integrees[k].fenetre, self.integrees[k].styles)
                && let Some(f) = self.f()
                && !f.liberer(h, s)
            {
                let nom = ctx.appli(&self.integrees[k].id).map_or_else(|| self.integrees[k].id.clone(), |a| a.nom);
                ctx.journal(&format!(
                    "{nom} ne répondait pas quand Mindset a quitté : sa fenêtre lui est rendue s'il répond dans les 10 s"
                ));
            }
            self.integrees[k].fenetre = None;
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Ce que voient la page et les autres blocs
    // -----------------------------------------------------------------------------------------------------------

    fn publier(&mut self, ctx: &Contexte) {
        let mut m = Map::new();
        for i in &self.integrees {
            // (« fenetre » en plus : la fenêtre accrochée, pour la console qui attend qu'elle soit prête)
            m.insert(i.id.clone(), json!({ "etat": i.etat.nom(), "pid": i.pid, "fenetre": i.fenetre }));
        }
        let v = Value::Object(m);
        if self.publie.as_ref() != Some(&v) {
            ctx.publier(partage::ACCROCHEES, v.clone());
            self.publie = Some(v);
        }
    }

    fn pages_applis(&self, ctx: &Contexte) -> Value {
        let page = Self::page(ctx);
        let mut ids: Vec<String> = self.ecrans.iter().map(|(x, _)| x.clone()).collect();
        for i in &self.integrees {
            if !ids.contains(&i.id) {
                ids.push(i.id.clone());
            }
        }
        let mut m = Map::new();
        for id in ids {
            let e = self.ecran(&id).cloned().unwrap_or_default();
            let etat = self.integrees.iter().find(|i| i.id == id).map_or(Etat::Vide, |i| i.etat);
            let jauge = self.jauge.as_ref().filter(|j| j.id == id);
            let ici = page == id;
            m.insert(
                id.clone(),
                json!({
                    "etat": etat.nom(),
                    "titre": e.titre,
                    "couleur": e.couleur,
                    "texte": e.texte,
                    "bouton_ici": e.bouton_ici,
                    "bouton_texte": e.bouton_texte,
                    "jauge": jauge.filter(|j| !j.ecran).map(|j| json!({
                        "texte": e.texte,
                        "depuis_ms": en_ms(j.depuis),
                        "duree_s": j.duree,
                    })),
                    "ecran_ouvrir": jauge.is_some_and(|j| j.ecran),
                    "barre_propre": ici && self.barre_cachee,
                    "montree": ici && self.cadre,
                }),
            );
        }
        Value::Object(m)
    }

    fn lire_zone(v: &Value) -> Option<Zone> {
        let n = |c: &str| -> Option<i32> {
            let x = v.get(c)?.as_f64()?;
            (x.is_finite() && x.abs() <= 1_000_000.0).then_some(x.round() as i32)
        };
        Some(Zone {
            x: n("x")?,
            y: n("y")?,
            largeur: n("largeur")?.max(0),
            hauteur: n("hauteur")?.max(0),
            visible: v.get("visible").and_then(Value::as_bool).unwrap_or(false),
        })
    }

    /// La zone `#zone-appli` a changé : le panneau affiché la suit, et la fenêtre de l'appli avec lui.
    fn nouvelle_zone(&mut self, ctx: &Contexte, z: Zone) {
        // (une zone sans taille : la page de l'appli n'est pas montrée, ou Mindset est réduit dans la barre des tâches ;
        // la place de l'appli ne change pas, et c'est la page montrée qui dit si la zone est là : signal « page »)
        if z.largeur <= 0 || z.hauteur <= 0 || z == self.zone {
            return;
        }
        self.zone = z;
        let page = Self::page(ctx);
        let dessus = self.voile(ctx);
        for k in 0..self.integrees.len() {
            let i = &self.integrees[k];
            if i.hote_visible {
                let voir = !dessus && page == i.id && i.fenetre.is_some();
                self.montrer_hote(k, voir, z);
            }
        }
    }
}

/// `[double]` d'un réglage (un nombre, ou un texte de nombre) ; autre chose compte pour 0 (10 s).
fn duree_reglage(v: &Value) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().unwrap_or(0.0),
        Value::String(s) => s.trim().parse().unwrap_or(0.0),
        Value::Bool(b) => f64::from(u8::from(*b)),
        _ => 0.0,
    }
}

impl Bloc for BlocAccrochage {
    fn nom(&self) -> &'static str {
        "accrochage"
    }

    fn demarrer(&mut self, ctx: &Contexte, _effets: &mut Effets) {
        self.assurer_port(ctx);
        self.publier(ctx);
    }

    fn etat(&mut self, ctx: &Contexte) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("pages_applis".into(), self.pages_applis(ctx));
        m
    }

    fn action(&mut self, ctx: &Contexte, id: &str, valeur: &Value, effets: &mut Effets) -> bool {
        self.assurer_port(ctx);
        match id {
            "accrochage:zone" => {
                if let Some(z) = Self::lire_zone(valeur) {
                    self.nouvelle_zone(ctx, z);
                }
            }
            "accrochage:ouvrir-ici" => {
                // (BtnPageAppliIci : l'appli de son écran « Ouvrir », celle de la page sinon)
                let id = valeur.as_str().map(str::to_string).unwrap_or_else(|| Self::page(ctx));
                if let Some(a) = ctx.appli(&id) {
                    self.ecran_mut(&id).bouton_ici = false;
                    self.afficher(ctx, &a, true, effets);
                }
            }
            "accrochage:fermer" => {
                // BtnAppliFermer : sa propre règle s'applique (elle demande, se réduit ou quitte)
                let page = Self::page(ctx);
                if let Some(h) = self.integrees.iter().find(|i| i.id == page).and_then(|i| i.fenetre)
                    && let Some(f) = self.f()
                {
                    f.fermer(h);
                }
            }
            _ => return false,
        }
        self.publier(ctx);
        true
    }

    fn tic(&mut self, ctx: &Contexte, effets: &mut Effets) -> Option<Duration> {
        if !self.minuterie {
            return None;
        }
        let maintenant = ctx.ecoule();
        if maintenant < self.prochain {
            return Some(self.prochain - maintenant);
        }
        self.assurer_port(ctx);
        // (avant la surveillance : l'appli montrée l'est encore, même si elle se ferme à ce passage)
        self.relever_ouvrir(ctx, effets);
        self.surveiller(ctx, effets);
        self.publier(ctx);
        self.prochain = maintenant + INTERVALLE;
        self.minuterie.then_some(INTERVALLE)
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, donnees: &Value, effets: &mut Effets) {
        self.assurer_port(ctx);
        let id = donnees.get("id").and_then(Value::as_str).unwrap_or("").to_string();
        match nom {
            signaux::PAGE => {
                // Show-Page (accueil.ps1:84-107) : la page d'une appli l'affiche ici. Sa zone a toujours la même place :
                // elle est là dès que la page est une appli (la coquille la confirme ensuite)
                self.zone.visible = !page_de_mindset(&id) && self.zone.largeur > 0 && self.zone.hauteur > 0;
                self.hotes_visibles(ctx);
                if !page_de_mindset(&id)
                    && let Some(a) = ctx.appli(&id)
                {
                    self.afficher(ctx, &a, false, effets);
                    if self.lancer_apres_page.as_deref() == Some(id.as_str()) {
                        self.lancer_apres_page = None;
                        self.afficher(ctx, &a, true, effets);
                    }
                }
            }
            signaux::OUVRIR_APPLI => {
                let lancer = donnees.get("lancer").and_then(Value::as_bool).unwrap_or(true);
                self.ouvrir_ici(ctx, &id, lancer, effets);
            }
            signaux::FERMER_APPLI => {
                // Stop-AppliConsole (console.ps1:540-548) : sa fenêtre affichée reçoit « Fermer », sinon sa demande
                if let Some(a) = ctx.appli(&id) {
                    let h = self.integrees.iter().find(|i| i.id == id).and_then(|i| i.fenetre);
                    if let (Some(h), Some(f)) = (h, self.f()) {
                        f.fermer(h);
                        ctx.journal(&format!("{} fermé depuis la console", a.nom));
                    } else if appli::appli_ouverte(ctx, &a) {
                        effets.signal(signaux::DEMANDE_QUITTER, json!({ "id": id }));
                        ctx.journal(&format!("Fermeture de {} demandée depuis la console", a.nom));
                    }
                }
            }
            signaux::VOILE => {
                self.voile = donnees.get("visible").and_then(Value::as_bool);
                self.hotes_visibles(ctx);
            }
            _ => {}
        }
        self.publier(ctx);
    }

    fn tache_finie(&mut self, ctx: &Contexte, _id: &str, resultat: Result<Value, String>, effets: &mut Effets) {
        let Ok(r) = resultat else { return };
        let id = r.get("id").and_then(Value::as_str).unwrap_or("").to_string();
        let Some(a) = ctx.appli(&id) else { return };
        for m in r.get("refus").and_then(Value::as_array).into_iter().flatten() {
            ctx.journal(&format!(
                "{} bloqué sans fenêtre, arrêt refusé par Windows : {}",
                a.nom,
                m.as_str().unwrap_or("")
            ));
        }
        if r.get("arretes").and_then(Value::as_u64).unwrap_or(0) > 0 {
            let k = self.index(&id);
            if self.integrees[k].etat == Etat::Lancement {
                self.integrees[k].depuis = self.maintenant();
            }
            ctx.journal(&format!("{} restait ouvert sans fenêtre : arrêté par Mindset, puis relancé", a.nom));
            self.lancer_cachee(ctx, &a, effets);
        }
        self.demarrer_minuterie(ctx);
        self.publier(ctx);
    }

    fn fermer(&mut self, ctx: &Contexte) {
        self.decrocher_tout(ctx);
        if let Some(f) = self.f() {
            f.fin();
        }
        self.publier(ctx);
    }
}

#[cfg(test)]
mod tests;
