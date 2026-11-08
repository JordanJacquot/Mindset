//! L'hôte des blocs : il fait tourner tous les blocs sur un seul fil (« le fil des blocs »), comme la fenêtre WPF
//! faisait tourner tous les modules de la version PowerShell sur le sien.
//!
//! - au lancement : `Bloc::demarrer` de chaque bloc, dans l'ordre de `blocs()` ;
//! - un message de la page : une action passée aux blocs dans l'ordre, jusqu'à ce que l'un la prenne ;
//! - les effets demandés : exécutés ici (page, signaux, actions, travaux de fond, ordres à la page, protocoles) ou
//!   rendus au programme ([`Demande`] : la fenêtre, quitter, relancer, ouvrir une adresse) ;
//! - les tics : chaque bloc est rappelé quand il l'a demandé ; un signal, une action ou une fin de travail réveille un
//!   bloc qui ne demandait plus rien ;
//! - les travaux de fond : chacun sur son fil ; sa fin revient au bloc qui l'a demandé ;
//! - l'état : les parts de tous les blocs fusionnées, plus `_vue` (`{ page, visible, reduite, version }`, tenu par
//!   l'hôte), envoyé à la page seulement s'il a changé ;
//! - un bloc qui panique est rattrapé : noté au journal (3 fois au plus pour la même erreur), le signal
//!   `erreur-imprevue` part une fois (`Write-ErreurImprevue`, interface.ps1:127-170) ; un tic qui a paniqué est rappelé
//!   10 s plus tard.
//!
//! Sans Tauri ni Windows : la page est derrière le trait [`Ecran`], et les tests font tourner des blocs factices.

use std::collections::{HashMap, HashSet, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;

use mindset_noyau::tache::texte_panique;
use mindset_noyau::{Bloc, Contexte, Effet, Effets, Fenetre, Tache, Vue, signaux};
use serde_json::{Map, Value, json};

use crate::pont::MessagePage;
use crate::protocoles::{DossierPack, Fichiers};

/// La page, vue de l'hôte.
pub trait Ecran {
    /// Un nouvel état complet : gardé, et envoyé si la page suit.
    fn etat(&mut self, etat: Value);
    /// Un ordre à la page (`{ kit: ... }`).
    fn ordre(&mut self, ordre: Value);
    /// Mindset quitte : la fenêtre est cachée TOUT DE SUITE, avant que les blocs ne soient fermés (les applis ont
    /// jusqu'à 6 s pour se fermer ; sans cela, la fenêtre restait affichée et figée pendant ce temps). Comme
    /// Exit-Mindset puis `$Window.Close()` de la version PowerShell (interface.ps1:98-101).
    fn cacher_avant_fermeture(&mut self) {}
}

/// Ce que l'hôte demande au programme (le fil de la fenêtre).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Demande {
    /// Montrer, cacher, réduire ou remettre la fenêtre
    Fenetre(Fenetre),
    /// La couleur de la barre de titre (« #RRGGBB », déjà vérifiée)
    BarreDeTitre(String),
    /// Ouvrir une adresse ou un dossier (vérifiée par le programme)
    OuvrirAdresse(String),
    /// Les blocs sont fermés : le programme s'arrête. `relancer` : un nouveau Mindset démarre une fois la place
    /// libérée ; `lancer_apres` : ce programme est lancé à la place (Mindset vient d'être installé).
    Fin { relancer: bool, lancer_apres: Option<PathBuf> },
}

/// Au-delà, les effets d'un tour sont abandonnés (une boucle de signaux entre deux blocs).
pub const EFFETS_MAX: usize = 2000;
/// Un tic qui a paniqué est rappelé après ce délai.
pub const APRES_ERREUR: Duration = Duration::from_secs(10);
/// La même erreur n'est notée que tant de fois.
pub const ERREURS_NOTEES: u32 = 3;

/// D'où vient un effet : un bloc (son rang dans la liste), ou l'hôte.
type Source = Option<usize>;
/// La fin d'un travail de fond : le bloc, l'id, le résultat.
type FinTache = (usize, String, Result<Value, String>);

pub struct Hote {
    blocs: Vec<Box<dyn Bloc>>,
    pub ctx: Contexte,
    /// Le prochain tic de chaque bloc (temps écoulé du contexte), `None` : il ne demande rien
    prochains: Vec<Option<Duration>>,
    dernier_etat: Option<Value>,
    force: bool,
    fin_taches: Sender<FinTache>,
    taches_finies: Receiver<FinTache>,
    /// Tests : les travaux de fond sont faits tout de suite, sur ce fil
    pub taches_directes: bool,
    taches_en_cours: usize,
    erreurs: HashMap<String, u32>,
    erreur_signalee: bool,
    signaux_inconnus: HashSet<String>,
    collisions: HashSet<String>,
    quitter: Option<bool>,
    relancer: bool,
    lancer_apres: Option<PathBuf>,
    ferme: bool,
    /// Le dossier du thème perso servi par le protocole `pack`
    pub pack: DossierPack,
    /// Les fichiers servis par le protocole `fichier`
    pub fichiers: Fichiers,
}

impl Hote {
    pub fn nouveau(blocs: Vec<Box<dyn Bloc>>, ctx: Contexte) -> Hote {
        let (fin_taches, taches_finies) = channel();
        let n = blocs.len();
        Hote {
            blocs,
            ctx,
            prochains: vec![None; n],
            dernier_etat: None,
            force: false,
            fin_taches,
            taches_finies,
            taches_directes: false,
            taches_en_cours: 0,
            erreurs: HashMap::new(),
            erreur_signalee: false,
            signaux_inconnus: HashSet::new(),
            collisions: HashSet::new(),
            quitter: None,
            relancer: false,
            lancer_apres: None,
            ferme: false,
            pack: DossierPack::default(),
            fichiers: Fichiers::default(),
        }
    }

    /// Les blocs ont-ils été fermés (Mindset s'arrête) ?
    pub fn ferme(&self) -> bool {
        self.ferme
    }

    /// Combien de travaux de fond tournent encore.
    pub fn taches_en_cours(&self) -> usize {
        self.taches_en_cours
    }

    // -----------------------------------------------------------------------------------------------------------
    // Appeler un bloc, sans jamais laisser passer une panique
    // -----------------------------------------------------------------------------------------------------------

    fn appeler<R>(&mut self, i: usize, quoi: &str, f: impl FnOnce(&mut dyn Bloc, &Contexte) -> R) -> Option<R> {
        let nom = self.blocs[i].nom();
        let ctx = &self.ctx;
        let bloc = &mut self.blocs[i];
        let r = ctx.au_nom_de(nom, || catch_unwind(AssertUnwindSafe(|| f(bloc.as_mut(), ctx))));
        match r {
            Ok(x) => Some(x),
            Err(p) => {
                let texte = format!("bloc {nom} ({quoi}) : {}", texte_panique(p.as_ref()));
                self.noter_erreur(&texte);
                None
            }
        }
    }

    fn noter_erreur(&mut self, texte: &str) {
        let n = self.erreurs.entry(texte.to_string()).or_insert(0);
        *n += 1;
        if *n <= ERREURS_NOTEES {
            let fin = if *n == ERREURS_NOTEES { " [elle se répète : plus notée]" } else { "" };
            self.ctx.journal(&format!("Erreur imprévue, Mindset continue : {texte}{fin}"));
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Les effets
    // -----------------------------------------------------------------------------------------------------------

    fn reveiller(&mut self, i: usize) {
        if self.prochains[i].is_none() {
            self.prochains[i] = Some(self.ctx.ecoule());
        }
    }

    /// Exécute les effets (et ceux qu'ils entraînent), puis envoie l'état s'il a changé.
    fn traiter(&mut self, depart: Vec<(Source, Effet)>, ecran: &mut dyn Ecran) -> Vec<Demande> {
        let mut file: VecDeque<(Source, Effet)> = depart.into();
        let mut demandes = Vec::new();
        let mut n = 0;
        while let Some((source, e)) = file.pop_front() {
            n += 1;
            if n > EFFETS_MAX {
                self.ctx.journal(&format!("Hôte : plus de {EFFETS_MAX} effets d'un coup, le reste est abandonné"));
                break;
            }
            match e {
                Effet::Page(id) => {
                    let mut v = self.ctx.vue();
                    let avant = std::mem::replace(&mut v.page, id.clone());
                    self.ctx.definir_vue(v);
                    file.push_back((None, signal(signaux::PAGE, json!({ "id": id, "avant": avant }))));
                }
                Effet::Fenetre(f) => {
                    let mut v = self.ctx.vue();
                    match f {
                        Fenetre::Montrer => {
                            v.visible = true;
                            v.reduite = false;
                        }
                        Fenetre::Cacher => v.visible = false,
                        Fenetre::Reduire => v.reduite = true,
                        Fenetre::Restaurer => v.reduite = false,
                    }
                    if let Some(s) = self.changer_vue(v) {
                        file.push_back((None, s));
                    }
                    demandes.push(Demande::Fenetre(f));
                }
                Effet::Ordre(o) => {
                    if o.get("kit").is_some_and(Value::is_string) {
                        ecran.ordre(o);
                    } else {
                        self.ctx.journal("Hôte : ordre à la page refusé (pas de « kit »)");
                    }
                }
                Effet::Action { id, valeur } => {
                    for x in self.action(&id, &valeur) {
                        file.push_back(x);
                    }
                }
                Effet::Signal { nom, donnees } => {
                    if !signaux::connu(&nom) && self.signaux_inconnus.insert(nom.clone()) {
                        self.ctx.journal(&format!("Hôte : signal inconnu « {nom} » (voir mindset_noyau::signaux)"));
                    }
                    for i in 0..self.blocs.len() {
                        if source == Some(i) {
                            continue;
                        }
                        let mut ef = Effets::default();
                        let r = self.appeler(i, "signal", |b, ctx| b.signal(ctx, &nom, &donnees, &mut ef));
                        if r.is_some() {
                            self.reveiller(i);
                        }
                        file.extend(ef.0.into_iter().map(|x| (Some(i), x)));
                    }
                }
                Effet::Tache(t) => match source {
                    Some(i) => self.lancer_tache(i, t),
                    None => self.ctx.journal("Hôte : travail de fond sans bloc, ignoré"),
                },
                Effet::Quitter { avec_applis } => {
                    let avant = self.quitter.unwrap_or(false);
                    self.quitter = Some(avant || avec_applis);
                }
                Effet::Relancer => {
                    self.relancer = true;
                    self.quitter.get_or_insert(false);
                }
                Effet::LancerApres(p) => self.lancer_apres = Some(p),
                Effet::OuvrirAdresse(a) => demandes.push(Demande::OuvrirAdresse(a)),
                Effet::DossierPack(d) => self.pack.changer(d),
                Effet::Exposer { nom, chemin } => {
                    if !self.fichiers.exposer(&nom, chemin) {
                        self.ctx.journal(&format!("Hôte : nom de fichier refusé pour la page ({})", court(&nom)));
                    }
                }
                Effet::Rafraichir => self.force = true,
                Effet::BarreDeTitre(c) => match couleur_rgb(&c) {
                    Some(_) => demandes.push(Demande::BarreDeTitre(c)),
                    None => self.ctx.journal(&format!("Hôte : couleur de la barre de titre refusée ({})", court(&c))),
                },
            }
            // (les fins de travaux arrivées pendant ce tour, avec leurs effets)
            if file.is_empty() {
                file.extend(self.taches_terminees());
            }
        }
        if let Some(avec_applis) = self.quitter.take() {
            // (la fenêtre d'abord, puis les blocs, qui ferment les applis : jusqu'à 6 s)
            ecran.cacher_avant_fermeture();
            self.fermer(avec_applis, ecran);
            demandes.push(Demande::Fin { relancer: self.relancer, lancer_apres: self.lancer_apres.take() });
            return demandes;
        }
        self.envoyer_etat(ecran);
        demandes
    }

    fn changer_vue(&mut self, v: Vue) -> Option<Effet> {
        let avant = self.ctx.vue();
        let change = avant.visible != v.visible || avant.reduite != v.reduite;
        self.ctx.definir_vue(v.clone());
        change.then(|| signal(signaux::FENETRE, json!({ "visible": v.visible, "reduite": v.reduite })))
    }

    fn action(&mut self, id: &str, valeur: &Value) -> Vec<(Source, Effet)> {
        for i in 0..self.blocs.len() {
            let mut ef = Effets::default();
            let prise = self.appeler(i, "action", |b, ctx| b.action(ctx, id, valeur, &mut ef)).unwrap_or(false);
            if prise {
                self.reveiller(i);
                return ef.0.into_iter().map(|x| (Some(i), x)).collect();
            }
            // (un bloc qui ne prend pas l'action ne demande rien : ses effets éventuels sont ignorés)
        }
        self.ctx.journal(&format!("Écran : action {} prise par aucun bloc", court(id)));
        Vec::new()
    }

    fn lancer_tache(&mut self, i: usize, t: Tache) {
        self.taches_en_cours += 1;
        let fin = self.fin_taches.clone();
        let id = t.id.clone();
        if self.taches_directes {
            let _ = fin.send((i, id, t.lancer()));
            return;
        }
        let r = std::thread::Builder::new().name(format!("tache-{}", self.blocs[i].nom())).spawn(move || {
            let r = t.lancer();
            let _ = fin.send((i, id, r));
        });
        if let Err(e) = r {
            self.taches_en_cours -= 1;
            self.ctx.journal(&format!("Hôte : travail de fond pas lancé ({e})"));
        }
    }

    /// Les fins de travaux arrivées, rendues à leurs blocs ; rend leurs effets.
    fn taches_terminees(&mut self) -> Vec<(Source, Effet)> {
        let mut r = Vec::new();
        while let Ok((i, id, res)) = self.taches_finies.try_recv() {
            self.taches_en_cours = self.taches_en_cours.saturating_sub(1);
            let mut ef = Effets::default();
            if self.appeler(i, "fin de travail", |b, ctx| b.tache_finie(ctx, &id, res, &mut ef)).is_some() {
                self.reveiller(i);
            }
            r.extend(ef.0.into_iter().map(|x| (Some(i), x)));
        }
        r
    }

    // -----------------------------------------------------------------------------------------------------------
    // L'état
    // -----------------------------------------------------------------------------------------------------------

    /// L'état assemblé : les parts de tous les blocs, plus `_vue`.
    pub fn etat(&mut self) -> Value {
        let mut tout = Map::new();
        let mut proprietaires: HashMap<String, &'static str> = HashMap::new();
        for i in 0..self.blocs.len() {
            let nom = self.blocs[i].nom();
            let part = self.appeler(i, "état", |b, ctx| b.etat(ctx)).unwrap_or_default();
            for (k, v) in part {
                if k == "_vue" {
                    continue;
                }
                if let Some(autre) = proprietaires.get(&k)
                    && *autre != nom
                    && self.collisions.insert(k.clone())
                {
                    self.ctx.journal(&format!("Hôte : la clé d'état « {k} » est donnée par {autre} et par {nom}"));
                }
                proprietaires.insert(k.clone(), nom);
                tout.insert(k, v);
            }
        }
        let v = self.ctx.vue();
        tout.insert(
            "_vue".into(),
            json!({ "page": v.page, "visible": v.visible, "reduite": v.reduite, "version": self.ctx.version }),
        );
        Value::Object(tout)
    }

    fn envoyer_etat(&mut self, ecran: &mut dyn Ecran) {
        let e = self.etat();
        if self.force || self.dernier_etat.as_ref() != Some(&e) {
            self.force = false;
            self.dernier_etat = Some(e.clone());
            ecran.etat(e);
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Ce que le programme appelle
    // -----------------------------------------------------------------------------------------------------------

    /// Le lancement : `demarrer` de chaque bloc (avant la fenêtre). Les effets demandés sont exécutés ensuite (les
    /// signaux après le démarrage de tous). L'état n'est pas envoyé (la page n'existe pas encore).
    pub fn demarrer(&mut self) -> Vec<Demande> {
        let mut effets = Vec::new();
        for i in 0..self.blocs.len() {
            let mut ef = Effets::default();
            let _ = self.appeler(i, "démarrage", |b, ctx| b.demarrer(ctx, &mut ef));
            effets.extend(ef.0.into_iter().map(|x| (Some(i), x)));
        }
        self.traiter(effets, &mut SansEcran)
    }

    /// La ligne « Démarrage Mindset X (Rust)[, lancé avec Windows] » (Mindset.ps1:135), écrite APRÈS le démarrage des
    /// blocs (comme dans Mindset.ps1, après le chargement des modules) : aucune si un bloc a demandé de quitter (lancé
    /// avec Windows alors que c'est coupé, Mindset.ps1:123 s'arrêtait avant), et sans « lancé avec Windows » si un bloc
    /// a demandé de montrer la fenêtre (relancé après une mise à jour demandée à l'écran, Mindset.ps1:122).
    pub fn ligne_demarrage(version: &str, demarrage: bool, au_depart: &[Demande]) -> Option<String> {
        if au_depart.iter().any(|d| matches!(d, Demande::Fin { .. })) {
            return None;
        }
        let montree = au_depart.iter().any(|d| matches!(d, Demande::Fenetre(Fenetre::Montrer)));
        let avec = if demarrage && !montree { ", lancé avec Windows" } else { "" };
        Some(format!("Démarrage Mindset {version} (Rust){avec}"))
    }

    /// La fenêtre est-elle montrée dès sa création (et la vue de départ des blocs « visible ») ? Ouvert à la main, oui ;
    /// lancé avec `-Demarrage`, seulement si un bloc l'a demandé au départ (relancé après une mise à jour demandée à
    /// l'écran). Avant le 08/11/2026, seulement `!demarrage` : la fenêtre était montrée par la demande du départ, mais
    /// les blocs la croyaient cachée ; la console 3D se fermait au bout d'une minute sous les yeux de l'utilisateur,
    /// et l'appli qu'il ouvrait depuis elle n'était jamais affichée (tests/relance_visible.rs).
    pub fn montree_au_depart(demarrage: bool, au_depart: &[Demande]) -> bool {
        !demarrage || au_depart.iter().any(|d| matches!(d, Demande::Fenetre(Fenetre::Montrer)))
    }

    /// La fenêtre existe : chaque bloc aura son premier tic tout de suite.
    pub fn fenetre_prete(&mut self) {
        let t = self.ctx.ecoule();
        self.prochains.fill(Some(t));
    }

    /// L'état de départ (ce que la page reçoit en arrivant).
    pub fn etat_initial(&mut self) -> Value {
        let e = self.etat();
        self.dernier_etat = Some(e.clone());
        e
    }

    /// Un message de la page.
    pub fn recevoir(&mut self, m: MessagePage, ecran: &mut dyn Ecran) -> Vec<Demande> {
        if self.ferme {
            return Vec::new();
        }
        let effets = match m {
            MessagePage::Pret => {
                self.ctx.journal("Écran prêt");
                self.force = true;
                Vec::new()
            }
            MessagePage::Action { id, valeur, .. } => self.action(&id, &valeur),
            MessagePage::Reponse { id, valeur } => self.action(&id, &Value::String(valeur)),
            MessagePage::Menu => self.action("menu", &Value::Null),
            MessagePage::Ecran { id } => {
                self.ctx.journal(&format!("Écran : montre {id}"));
                Vec::new()
            }
            MessagePage::Erreur { texte } => {
                self.ctx.journal(&format!("Écran : erreur ({})", court(&texte)));
                Vec::new()
            }
        };
        self.traiter(effets, ecran)
    }

    /// Un événement de la fenêtre ou de Windows, donné aux blocs comme un signal de l'hôte (`croix`, `reduite`,
    /// `afficher-demande`).
    pub fn evenement(&mut self, nom: &str, ecran: &mut dyn Ecran) -> Vec<Demande> {
        if self.ferme {
            return Vec::new();
        }
        self.traiter(vec![(None, signal(nom, json!({})))], ecran)
    }

    /// La fenêtre a changé d'elle-même (l'utilisateur l'a réduite, Windows l'a remise) : la vue suit, et le signal
    /// `fenetre` part si quelque chose a changé.
    pub fn fenetre_changee(&mut self, visible: bool, reduite: bool, ecran: &mut dyn Ecran) -> Vec<Demande> {
        if self.ferme {
            return Vec::new();
        }
        let mut v = self.ctx.vue();
        v.visible = visible;
        v.reduite = reduite;
        let s = self.changer_vue(v);
        self.traiter(s.into_iter().map(|e| (None, e)).collect(), ecran)
    }

    /// La minuterie : les tics dus, et les fins de travaux.
    pub fn minuterie(&mut self, ecran: &mut dyn Ecran) -> Vec<Demande> {
        if self.ferme {
            return Vec::new();
        }
        let t = self.ctx.ecoule();
        let avant = self.taches_en_cours;
        let mut effets = self.taches_terminees();
        // (un tic a tourné ou un travail a fini : l'état d'un bloc a pu changer, même sans aucun effet)
        let mut appele = self.taches_en_cours != avant;
        for i in 0..self.blocs.len() {
            if !self.prochains[i].is_some_and(|p| p <= t) {
                continue;
            }
            // (sauf un bloc dont le tic ne change jamais rien sans effet : l'icône près de l'horloge, toutes les
            // 150 ms ; audit M2, tests/rythme_etat.rs)
            appele |= self.blocs[i].tic_change_l_etat();
            let mut ef = Effets::default();
            match self.appeler(i, "tic", |b, ctx| b.tic(ctx, &mut ef)) {
                Some(d) => self.prochains[i] = d.map(|d| t + d),
                None => self.prochains[i] = Some(t + APRES_ERREUR),
            }
            effets.extend(ef.0.into_iter().map(|x| (Some(i), x)));
        }
        if effets.is_empty() && !self.force {
            // Aucun effet, mais l'état est relu (et envoyé à la page seulement s'il a changé). Avant le 07/11/2026,
            // il ne l'était pas : la fin d'une recherche « à jour » ou une appli fermée dans Mindset (l'écran
            // « Ouvrir » de l'accrochage) ne changent que l'état, et la page restait sur l'ancien (le rond
            // « Recherche des mises à jour... » sans fin, vu par Jordan ; tests/recherche_sans_fin.rs).
            if appele {
                self.envoyer_etat(ecran);
            }
            return Vec::new();
        }
        self.traiter(effets, ecran)
    }

    /// Le temps avant le prochain tic dû (au plus `max`).
    pub fn prochain_tic(&self, max: Duration) -> Duration {
        let t = self.ctx.ecoule();
        self.prochains.iter().flatten().map(|p| p.saturating_sub(t)).min().unwrap_or(max).min(max)
    }

    /// Quitter : le signal `quitter` à tous les blocs, puis `fermer` de chacun (dans l'ordre de `blocs()`).
    pub fn fermer(&mut self, avec_applis: bool, ecran: &mut dyn Ecran) {
        if self.ferme {
            return;
        }
        self.ferme = true;
        let donnees = json!({ "avec_applis": avec_applis, "relancer": self.relancer });
        for i in 0..self.blocs.len() {
            let mut ef = Effets::default();
            let _ = self.appeler(i, "signal", |b, ctx| b.signal(ctx, signaux::QUITTER, &donnees, &mut ef));
            // (en fermant, seuls les ordres à la page et les protocoles comptent encore)
            for e in ef.0 {
                if let Effet::Ordre(o) = e {
                    ecran.ordre(o);
                }
            }
        }
        for i in 0..self.blocs.len() {
            let _ = self.appeler(i, "fermeture", |b, ctx| b.fermer(ctx));
        }
    }

    /// Une erreur imprévue de l'hôte lui-même (pas d'un bloc) : notée, et signalée une fois aux blocs.
    pub fn erreur(&mut self, texte: &str, ecran: &mut dyn Ecran) -> Vec<Demande> {
        self.noter_erreur(texte);
        self.signaler_erreur(texte, ecran)
    }

    fn signaler_erreur(&mut self, texte: &str, ecran: &mut dyn Ecran) -> Vec<Demande> {
        if self.erreur_signalee || self.ferme {
            return Vec::new();
        }
        self.erreur_signalee = true;
        self.traiter(vec![(None, signal(signaux::ERREUR_IMPREVUE, json!({ "texte": court(texte) })))], ecran)
    }

    /// Après chaque tour : une panique d'un bloc (notée) part une fois en signal `erreur-imprevue`.
    pub fn signaler_paniques(&mut self, ecran: &mut dyn Ecran) -> Vec<Demande> {
        if self.erreur_signalee || self.erreurs.is_empty() {
            return Vec::new();
        }
        let texte = self.erreurs.keys().next().cloned().unwrap_or_default();
        self.signaler_erreur(&texte, ecran)
    }
}

fn signal(nom: &str, donnees: Value) -> Effet {
    Effet::Signal { nom: nom.into(), donnees }
}

/// « #RRGGBB » en (rouge, vert, bleu) ; `None` si la couleur est mal écrite.
pub fn couleur_rgb(c: &str) -> Option<(u8, u8, u8)> {
    let h = c.strip_prefix('#')?;
    if h.len() != 6 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let o = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok();
    Some((o(0)?, o(2)?, o(4)?))
}

fn court(t: &str) -> String {
    t.chars().take(120).collect()
}

/// Un écran qui ne montre rien (avant que la page existe).
pub struct SansEcran;
impl Ecran for SansEcran {
    fn etat(&mut self, _: Value) {}
    fn ordre(&mut self, _: Value) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use mindset_noyau::essai;
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct Page {
        etats: Vec<Value>,
        ordres: Vec<Value>,
        /// Les notes des blocs, où la page écrit « page:cachee » quand la fenêtre est cachée (pour l'ordre)
        notes: Option<Notes>,
    }
    impl Ecran for Page {
        fn etat(&mut self, e: Value) {
            self.etats.push(e);
        }
        fn ordre(&mut self, o: Value) {
            self.ordres.push(o);
        }
        fn cacher_avant_fermeture(&mut self) {
            if let Some(n) = &self.notes {
                n.lock().unwrap().push("page:cachee".into());
            }
        }
    }

    type Notes = Arc<Mutex<Vec<String>>>;

    /// Un bloc factice : il note ce qu'il reçoit, et réagit à quelques actions.
    struct Factice {
        nom: &'static str,
        notes: Notes,
        compteur: u32,
    }
    impl Factice {
        fn nouveau(nom: &'static str, notes: &Notes) -> Box<dyn Bloc> {
            Box::new(Factice { nom, notes: notes.clone(), compteur: 0 })
        }
        fn noter(&self, t: String) {
            self.notes.lock().unwrap().push(format!("{}:{t}", self.nom));
        }
    }
    impl Bloc for Factice {
        fn nom(&self) -> &'static str {
            self.nom
        }
        fn demarrer(&mut self, _: &Contexte, e: &mut Effets) {
            self.noter("demarrer".into());
            if self.nom == "liste" {
                e.signal(signaux::VERIFIER_LISTE, json!({}));
            }
        }
        fn etat(&mut self, _: &Contexte) -> Map<String, Value> {
            let mut m = Map::new();
            m.insert(self.nom.to_string(), json!({ "compteur": self.compteur }));
            m
        }
        fn action(&mut self, ctx: &Contexte, id: &str, v: &Value, e: &mut Effets) -> bool {
            let Some(reste) = id.strip_prefix(&format!("{}:", self.nom)) else { return false };
            self.noter(format!("action {reste} {v}"));
            match reste {
                "plus" => self.compteur += 1,
                "page" => e.ajouter(Effet::Page(v.as_str().unwrap_or("").into())),
                "signal" => e.signal(signaux::ACTUALISER, json!({ "clic": true })),
                "tache" => e.tache("t1", || Ok(json!(42))),
                "tache-panique" => e.tache("t2", || panic!("dans le travail")),
                "panique" => panic!("dans l'action"),
                "ordre" => {
                    e.ajouter(Effet::Ordre(json!({ "kit": "console", "appel": "pause" })));
                    e.ajouter(Effet::Ordre(json!({ "appel": "sans kit" })));
                }
                "cacher" => e.ajouter(Effet::Fenetre(Fenetre::Cacher)),
                "quitter" => e.ajouter(Effet::Quitter { avec_applis: true }),
                "relancer" => e.ajouter(Effet::Relancer),
                "publier" => ctx.publier(mindset_noyau::partage::OUVERTES, json!({ "x": true })),
                "boucle" => e.signal("boucle", json!({})),
                "question" => e.ajouter(mindset_noyau::signaux::confirmation(
                    "Sûr ?",
                    "Texte",
                    "Oui",
                    "ecrans:oui",
                    json!("evermind"),
                )),
                _ => {}
            }
            true
        }
        fn tic(&mut self, _: &Contexte, _: &mut Effets) -> Option<Duration> {
            self.noter("tic".into());
            if self.nom == "horloge" { Some(Duration::from_secs(1)) } else { None }
        }
        fn signal(&mut self, _: &Contexte, nom: &str, d: &Value, e: &mut Effets) {
            self.noter(format!("signal {nom} {d}"));
            if nom == "boucle" {
                e.signal("boucle", json!({}));
            }
            if nom == signaux::CONFIRMATION && self.nom == "ecrans" {
                // (l'écran montre la question ; ici, on répond « Oui » tout de suite)
                e.ajouter(Effet::Action { id: d["action"].as_str().unwrap().into(), valeur: d["valeur"].clone() });
            }
        }
        fn tache_finie(&mut self, _: &Contexte, id: &str, r: Result<Value, String>, _: &mut Effets) {
            self.noter(format!("fin {id} {r:?}"));
        }
        fn fermer(&mut self, _: &Contexte) {
            self.noter("fermer".into());
        }
    }

    fn hote(nom: &str) -> (Hote, Notes, essai::Faux) {
        let notes: Notes = Default::default();
        let (ctx, faux) = essai::contexte(nom);
        let blocs = vec![
            Factice::nouveau("liste", &notes),
            Factice::nouveau("ecrans", &notes),
            Factice::nouveau("horloge", &notes),
        ];
        let mut h = Hote::nouveau(blocs, ctx);
        h.taches_directes = true;
        (h, notes, faux)
    }

    fn action(id: &str, valeur: Value) -> MessagePage {
        MessagePage::Action { id: id.into(), valeur, ecran: "accueil".into() }
    }

    fn prendre(n: &Notes) -> Vec<String> {
        std::mem::take(&mut *n.lock().unwrap())
    }

    #[test]
    fn demarrage_puis_signaux_apres_tous() {
        let (mut h, notes, _f) = hote("hote-demarrage");
        assert!(h.demarrer().is_empty());
        assert_eq!(
            prendre(&notes),
            [
                "liste:demarrer",
                "ecrans:demarrer",
                "horloge:demarrer",
                "ecrans:signal verifier-liste {}",
                "horloge:signal verifier-liste {}"
            ],
            "le signal part après le démarrage de tous, et pas vers celui qui l'envoie"
        );
        let e = h.etat_initial();
        assert_eq!(e["ecrans"]["compteur"], 0);
        assert_eq!(e["_vue"]["page"], "accueil");
        assert_eq!(e["_vue"]["version"], "3.0.0");
    }

    #[test]
    fn actions_etat_et_page() {
        let (mut h, notes, _f) = hote("hote-actions");
        h.demarrer();
        prendre(&notes);
        let mut p = Page::default();
        h.recevoir(action("ecrans:plus", Value::Null), &mut p);
        assert_eq!(p.etats.len(), 1);
        assert_eq!(p.etats[0]["ecrans"]["compteur"], 1);
        h.recevoir(action("ecrans:rien", Value::Null), &mut p);
        assert_eq!(p.etats.len(), 1, "l'état n'a pas changé : rien n'est envoyé");
        h.recevoir(action("liste:page", json!("parametres")), &mut p);
        assert_eq!(h.ctx.vue().page, "parametres");
        assert_eq!(p.etats.last().unwrap()["_vue"]["page"], "parametres");
        let n = prendre(&notes);
        assert!(n.contains(&r#"ecrans:signal page {"id":"parametres","avant":"accueil"}"#.to_string()), "{n:?}");
        assert!(n.contains(&r#"liste:signal page {"id":"parametres","avant":"accueil"}"#.to_string()));
        h.recevoir(action("inconnu:x", Value::Null), &mut p);
        assert!(_f.donnees.lignes().iter().any(|l| l.contains("prise par aucun bloc")));
    }

    #[test]
    fn travaux_de_fond_et_paniques() {
        let (mut h, notes, f) = hote("hote-taches");
        h.demarrer();
        prendre(&notes);
        let mut p = Page::default();
        h.recevoir(action("horloge:tache", Value::Null), &mut p);
        h.recevoir(action("horloge:tache-panique", Value::Null), &mut p);
        let n = prendre(&notes);
        assert!(n.contains(&"horloge:fin t1 Ok(Number(42))".to_string()), "{n:?}");
        assert!(n.contains(&"horloge:fin t2 Err(\"erreur imprévue (dans le travail)\")".to_string()), "{n:?}");
        assert_eq!(h.taches_en_cours(), 0);
        // (une panique d'un bloc : notée, Mindset continue, le signal part une fois)
        h.recevoir(action("ecrans:panique", Value::Null), &mut p);
        h.recevoir(action("ecrans:panique", Value::Null), &mut p);
        h.signaler_paniques(&mut p);
        h.signaler_paniques(&mut p);
        let l = f.donnees.lignes();
        assert_eq!(l.iter().filter(|x| x.starts_with("Erreur imprévue, Mindset continue : bloc ecrans")).count(), 2);
        let n = prendre(&notes);
        assert_eq!(n.iter().filter(|x| x.contains("signal erreur-imprevue")).count(), 3, "une fois, vers chaque bloc");
    }

    #[test]
    fn ordres_fenetre_quitter() {
        let (mut h, notes, _f) = hote("hote-fin");
        h.demarrer();
        let mut p = Page::default();
        h.recevoir(action("ecrans:ordre", Value::Null), &mut p);
        assert_eq!(p.ordres, vec![json!({ "kit": "console", "appel": "pause" })], "sans « kit » : refusé");
        h.fenetre_changee(true, false, &mut p);
        prendre(&notes);
        let d = h.recevoir(action("ecrans:cacher", Value::Null), &mut p);
        assert_eq!(d, vec![Demande::Fenetre(Fenetre::Cacher)]);
        assert!(!h.ctx.vue().visible);
        assert!(prendre(&notes).iter().any(|x| x == r#"liste:signal fenetre {"visible":false,"reduite":false}"#));
        let d = h.recevoir(action("ecrans:quitter", Value::Null), &mut p);
        assert_eq!(d, vec![Demande::Fin { relancer: false, lancer_apres: None }]);
        assert!(h.ferme());
        let n = prendre(&notes);
        assert_eq!(
            n,
            [
                "ecrans:action quitter null",
                r#"liste:signal quitter {"avec_applis":true,"relancer":false}"#,
                r#"ecrans:signal quitter {"avec_applis":true,"relancer":false}"#,
                r#"horloge:signal quitter {"avec_applis":true,"relancer":false}"#,
                "liste:fermer",
                "ecrans:fermer",
                "horloge:fermer"
            ]
        );
        assert!(h.recevoir(action("ecrans:plus", Value::Null), &mut p).is_empty(), "plus rien une fois fermé");
    }

    /// « Tout quitter », « Quitter », une relance : la fenêtre est cachée AVANT que les blocs ne soient prévenus et
    /// fermés (avant le 08/11/2026, elle restait affichée et figée jusqu'à 6 s, le temps que les applis se ferment).
    #[test]
    fn quitter_cache_la_fenetre_avant_de_fermer_les_blocs() {
        for quoi in ["ecrans:quitter", "liste:relancer"] {
            let (mut h, notes, _f) = hote("hote-cacher-avant");
            h.demarrer();
            let mut p = Page { notes: Some(notes.clone()), ..Default::default() };
            prendre(&notes);
            let d = h.recevoir(action(quoi, Value::Null), &mut p);
            assert!(matches!(d.last(), Some(Demande::Fin { .. })), "{d:?}");
            let n = prendre(&notes);
            let cachee = n.iter().position(|x| x == "page:cachee");
            let premier = n.iter().position(|x| x.contains("signal quitter") || x.ends_with(":fermer"));
            assert!(cachee.is_some(), "{quoi} : la fenêtre n'est jamais cachée avant la fin : {n:?}");
            assert!(cachee < premier, "{quoi} : cachée après la fermeture des blocs : {n:?}");
            assert_eq!(n.iter().filter(|x| *x == "page:cachee").count(), 1);
        }
    }

    #[test]
    fn relancer_et_confirmation() {
        let (mut h, notes, _f) = hote("hote-relance");
        h.demarrer();
        let mut p = Page::default();
        prendre(&notes);
        h.recevoir(action("liste:question", Value::Null), &mut p);
        let n = prendre(&notes);
        assert!(n.contains(&r#"ecrans:action oui "evermind""#.to_string()), "« Oui » rend l'action : {n:?}");
        let d = h.recevoir(action("liste:relancer", Value::Null), &mut p);
        assert_eq!(d, vec![Demande::Fin { relancer: true, lancer_apres: None }]);
    }

    #[test]
    fn tics_reveil_et_boucle() {
        let (mut h, notes, f) = hote("hote-tics");
        h.demarrer();
        h.fenetre_prete();
        let mut p = Page::default();
        prendre(&notes);
        h.minuterie(&mut p);
        assert_eq!(prendre(&notes), ["liste:tic", "ecrans:tic", "horloge:tic"]);
        h.minuterie(&mut p);
        assert!(prendre(&notes).is_empty(), "personne n'est dû");
        h.ctx.avancer(Duration::from_millis(1000));
        h.minuterie(&mut p);
        assert_eq!(prendre(&notes), ["horloge:tic"]);
        // (une action réveille le bloc qui ne demandait plus rien)
        h.recevoir(action("ecrans:plus", Value::Null), &mut p);
        prendre(&notes);
        h.minuterie(&mut p);
        assert_eq!(prendre(&notes), ["ecrans:tic"]);
        assert!(h.prochain_tic(Duration::from_millis(200)) <= Duration::from_secs(1));
        // (deux blocs qui se renvoient un signal sans fin : arrêtés)
        h.recevoir(action("liste:boucle", Value::Null), &mut p);
        assert!(f.donnees.lignes().iter().any(|l| l.contains("effets d'un coup")));
        assert!(f.donnees.lignes().iter().any(|l| l.contains("signal inconnu « boucle »")));
    }

    #[test]
    fn couleurs_de_la_barre() {
        assert_eq!(couleur_rgb("#06050F"), Some((6, 5, 15)));
        assert_eq!(couleur_rgb("#ff8a3d"), Some((255, 138, 61)));
        for c in ["06050F", "#06050", "#06050FF", "#GG0000", ""] {
            assert_eq!(couleur_rgb(c), None, "{c}");
        }
    }

    #[test]
    fn le_tableau_commun_est_controle() {
        let (mut h, _notes, f) = hote("hote-partage");
        h.demarrer();
        let mut p = Page::default();
        h.recevoir(action("liste:publier", Value::Null), &mut p);
        assert_eq!(h.ctx.lu(mindset_noyau::partage::OUVERTES), Some(json!({ "x": true })));
        h.recevoir(action("ecrans:publier", Value::Null), &mut p);
        assert!(f.donnees.lignes().iter().any(|l| l.contains("appartient au bloc liste, refusé au bloc ecrans")));
    }
}
