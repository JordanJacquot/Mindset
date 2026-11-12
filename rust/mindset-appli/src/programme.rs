//! Le programme Mindset.exe : tout est branché ici (Mindset.ps1 et lanceur.cs).
//!
//! 1. L'identité `JordanJacquot.Mindset`, les arguments (`-Demarrage`, `-Desinstaller`). `-Desinstaller` avec le
//!    désinstalleur autonome à côté : il est lancé, Mindset ne s'ouvre pas (lanceur.cs:28-41).
//! 2. Les dossiers et le disque (bloc « données »), les ports (réseau : bloc « publications » ; mini-installateur :
//!    bloc « installations » ; Windows : le noyau), ce qui se décide avant tout (bloc « Mindset lui-même »).
//! 3. Un seul Mindset à la fois (`Local\Mindset-Instance`, `Local\Mindset-Afficher`).
//! 4. Le contexte, l'hôte des blocs et leur démarrage (avant la fenêtre ; un bloc peut y demander de quitter).
//! 5. Tauri : la page et ses trois commandes, les protocoles `pack` et `fichier`, la fenêtre « principale » créée une
//!    seule fois, cachée, puis montrée sauf avec `-Demarrage`.
//! 6. Deux fils :
//!    - le fil de la fenêtre (celui de Tauri), pas de 100 ms : les demandes de l'hôte (montrer, cacher, réduire,
//!      ouvrir une adresse, fin), le signal d'un autre lancement (toutes les 300 ms), l'état de la fenêtre (montrée,
//!      réduite : la veille de la page suit) ; il ne fait jamais attendre la fenêtre ;
//!    - le fil des blocs : l'hôte et tous les blocs (messages de la page, événements, tics, fins de travaux). Un bloc
//!      lent ne fige jamais la fenêtre. Les deux fils se parlent par des files.
//! 7. La fin : les blocs fermés (sur leur fil, attendu au plus 12 s), la place libérée (verrou rendu), la relance ou
//!    le programme à lancer après, puis `std::process::exit`.

use std::cell::RefCell;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use mindset_noyau::donnees::Environnement;
use mindset_noyau::installateur::Installateur;
use mindset_noyau::reseau::Reseau;
use mindset_noyau::systeme::Systeme;
use mindset_noyau::windows::{SANS_CONSOLE, SystemeWindows};
use mindset_noyau::{Contexte, Fenetre, Lancement, Ports};
use serde_json::Value;
use tauri::{App, AppHandle, Manager, WebviewWindow, Window, WindowEvent};

use crate::commandes::Page;
use crate::depart::{self, DESINSTALLEUR};
use crate::fenetre::{LABEL, creer_principale};
use crate::hote::{Demande, Ecran, Hote};
use crate::pont::MessagePage;
use crate::protocoles::{DossierPack, Fichiers};
use crate::windows::synchro::{self, Instance, Prise};
use crate::windows::{fenetre as fenetre_windows, identite, webview2};
use crate::{VERSION, blocs};

/// Le pas du fil de la fenêtre.
const PAS: Duration = Duration::from_millis(100);
/// Le signal d'un autre lancement est regardé tant (interface.ps1:114 : 300 ms).
const PAS_SIGNAL: Duration = Duration::from_millis(300);
/// Le fil des blocs se réveille au moins tant (les fins de travaux, les tics).
const PAS_BLOCS: Duration = Duration::from_millis(200);
/// La fermeture des blocs est attendue au plus tant (les applis ont 6 s pour se fermer, Mindset.ps1:141-156).
const ATTENTE_FERMETURE: Duration = Duration::from_secs(12);
/// Le verrou et le signal de Mindset.
const VERROU_MINDSET: &str = r"Local\Mindset-Instance";
const SIGNAL_MINDSET: &str = r"Local\Mindset-Afficher";

/// Ce que le fil de la fenêtre demande au fil des blocs.
enum Ordre {
    Message(MessagePage),
    /// Un événement donné aux blocs comme signal de l'hôte (`croix`, `reduite`, `afficher-demande`)
    Evenement(&'static str),
    /// La fenêtre a changé d'elle-même (montrée, réduite)
    Fenetre {
        visible: bool,
        reduite: bool,
    },
    /// Fermer les blocs (s'ils ne le sont pas déjà), puis répondre
    Fermer(Sender<()>),
}

/// La file des ordres vers le fil des blocs (la page y dépose ses messages depuis n'importe quel fil).
static ORDRES: OnceLock<Sender<Ordre>> = OnceLock::new();

fn ordonner(o: Ordre) {
    if let Some(t) = ORDRES.get() {
        let _ = t.send(o);
    }
}

/// L'état du fil de la fenêtre.
struct Etat {
    hote: Option<Hote>,
    demandes: Option<Receiver<Vec<Demande>>>,
    fenetre: Option<WebviewWindow>,
    instance: Option<Instance>,
    systeme: Arc<dyn Systeme>,
    donnees: PathBuf,
    exe: PathBuf,
    montree: bool,
    dernier_signal: Instant,
    vu: Option<(bool, bool)>,
    fin: Option<(bool, Option<PathBuf>)>,
    essai: bool,
    /// Les demandes faites au démarrage des blocs, avant que la fenêtre n'existe (la couleur de la barre de titre...)
    au_depart: Vec<Demande>,
}

thread_local! {
    static ETAT: RefCell<Option<Etat>> = const { RefCell::new(None) };
}

/// La page de Tauri, vue de l'hôte (et `etat.json` dans la construction d'essai).
struct EcranPage {
    app: AppHandle,
    etat_essai: Option<PathBuf>,
    /// La file des demandes vers le fil de la fenêtre (pour la cacher avant de fermer les blocs)
    demandes: Sender<Vec<Demande>>,
}

impl Ecran for EcranPage {
    fn etat(&mut self, etat: Value) {
        if let Some(f) = &self.etat_essai {
            let _ = std::fs::write(f, serde_json::to_vec_pretty(&etat).unwrap_or_default());
        }
        self.app.state::<Page>().changer(etat);
    }
    fn ordre(&mut self, ordre: Value) {
        self.app.state::<Page>().ordre(ordre);
    }
    fn cacher_avant_fermeture(&mut self) {
        // (envoyée tout de suite : le fil de la fenêtre la cache à son pas suivant, 100 ms au plus, pendant que ce fil
        // ferme les blocs ; la fin, elle, part une fois les blocs fermés)
        let _ = self.demandes.send(vec![Demande::Fenetre(Fenetre::Cacher)]);
    }
}

/// Une ligne au journal avant le contexte, ou depuis le fil de la fenêtre (le contexte vit avec les blocs).
fn journal_dans(dossier: &Path, texte: &str) {
    use std::io::Write;
    let _ = std::fs::create_dir_all(dossier);
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dossier.join("journal.txt")) {
        let _ = write!(f, "{} {texte}\r\n", mindset_noyau::moment::iso(&suite_commun::json_sur::heure_du_pc()));
    }
}

fn variable(n: &str) -> Option<PathBuf> {
    std::env::var_os(n).filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// `-Desinstaller` (lanceur.cs:28-41) : le désinstalleur autonome à côté de Mindset.exe, lancé depuis le dossier de
/// Windows (le dossier de Mindset doit pouvoir être supprimé). `true` s'il a été lancé.
fn desinstalleur_autonome(exe: &Path) -> bool {
    let Some(d) = exe.parent().map(|d| d.join(DESINSTALLEUR)) else { return false };
    if !d.is_file() {
        return false;
    }
    let windows = variable("SystemRoot").unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    std::process::Command::new(&d).current_dir(windows.join("System32")).creation_flags(SANS_CONSOLE).spawn().is_ok()
}

/// Les fichiers livrés sans lesquels Mindset ne peut rien faire (Mindset.ps1:104-113) : la liste des applis et les clés
/// publiques (le reste de la page est rangé dans l'exe).
pub fn fichiers_manquants(fichiers: &Path) -> Vec<String> {
    let mut m = Vec::new();
    if !fichiers.join("apps.json").is_file() {
        m.push("apps.json".to_string());
    }
    let cles = std::fs::read_dir(fichiers.join("cles-publiques"))
        .map(|l| l.flatten().any(|e| e.path().extension().is_some_and(|x| x.eq_ignore_ascii_case("xml"))))
        .unwrap_or(false);
    if !cles {
        m.push("cles-publiques".to_string());
    }
    m
}

/// L'environnement et les ports : les vrais, ou ceux de la construction d'essai.
#[cfg(not(feature = "essai"))]
fn environnement(exe: &Path) -> (Environnement, Option<(String, String)>, Ports2) {
    let env = Environnement {
        exe: exe.to_path_buf(),
        localappdata: variable("LOCALAPPDATA").unwrap_or_default(),
        program_files: variable("ProgramW6432")
            .or_else(|| variable("ProgramFiles"))
            .unwrap_or_else(|| PathBuf::from(r"C:\Program Files")),
        essai: None,
    };
    (env, None, Ports2 { reseau: None, installateur: None, systeme: Arc::new(SystemeWindows::nouveau()) })
}

#[cfg(feature = "essai")]
fn environnement(exe: &Path) -> (Environnement, Option<(String, String)>, Ports2) {
    let Ok(e) = crate::essai::lire() else { std::process::exit(4) };
    let env = Environnement { exe: exe.to_path_buf(), essai: Some(e.racine.clone()), ..Default::default() };
    let systeme: Arc<dyn Systeme> = Arc::new(crate::essai::SystemeEssai(SystemeWindows::nouveau()));
    let reseau: Arc<dyn Reseau> = Arc::new(mindset_noyau::reseau::SansReseau);
    let installateur: Arc<dyn Installateur> = Arc::new(mindset_noyau::installateur::SansInstallateur);
    (env, Some(e.noms()), Ports2 { reseau: Some(reseau), installateur: Some(installateur), systeme })
}

/// Les ports déjà choisis par l'environnement (`None` : les vrais, branchés par leurs blocs).
struct Ports2 {
    reseau: Option<Arc<dyn Reseau>>,
    installateur: Option<Arc<dyn Installateur>>,
    systeme: Arc<dyn Systeme>,
}

/// Le programme : ne revient jamais (`std::process::exit`).
pub fn lancer() -> ! {
    let _ = identite::poser();
    let arguments = depart::lire_arguments(std::env::args().skip(1));
    let exe = std::env::current_exe().unwrap_or_default();
    let essai = cfg!(feature = "essai");
    if arguments.desinstaller && !essai && desinstalleur_autonome(&exe) {
        std::process::exit(0);
    }
    let (env, noms_essai, p2) = environnement(&exe);
    let ouverture = mindset_donnees::ouvrir(&env);
    let dossiers = ouverture.dossiers.clone();
    let manquants = fichiers_manquants(&dossiers.fichiers);
    if !essai && !manquants.is_empty() {
        journal_dans(&dossiers.donnees, &format!("Fichiers de Mindset manquants : {}", manquants.join(", ")));
        crate::windows::message::informer(
            &format!(
                "Des fichiers de Mindset sont manquants :

{}

Retélécharge Mindset et remplace tout le dossier.",
                manquants.join(", ")
            ),
            crate::NOM_APPLI,
        );
        std::process::exit(1);
    }
    let ports = Ports {
        donnees: ouverture.donnees.clone(),
        reseau: p2.reseau.unwrap_or_else(mindset_publications::reseau_windows),
        installateur: p2.installateur.unwrap_or_else(|| mindset_installations::installateur_windows(&dossiers)),
        systeme: p2.systeme.clone(),
    };
    let mut lancement = Lancement {
        demarrage: arguments.demarrage,
        desinstaller: arguments.desinstaller,
        admin: ports.systeme.est_admin(),
    };
    if let Some(code) = mindset_lui_meme::avant_tout(&dossiers, &lancement, &ports) {
        std::process::exit(code);
    }
    // Rouvert par l'Explorateur juste après la bascule administrateur d'un Mindset lancé avec Windows
    // (Mindset.ps1:47-51) : comme `-Demarrage` pour tous les blocs, et la fenêtre n'est jamais montrée
    lancement.demarrage |= mindset_lui_meme::demarrage_force();
    let demarrage = lancement.demarrage;
    let (verrou, signal) = noms_essai.unwrap_or_else(|| (VERROU_MINDSET.to_string(), SIGNAL_MINDSET.to_string()));
    let instance = match synchro::prendre(&verrou, &signal, demarrage) {
        Prise::Premier(i) => Some(i),
        Prise::DejaOuvert => std::process::exit(0),
        Prise::Refuse => {
            journal_dans(&dossiers.donnees, "Un seul Mindset à la fois : verrou refusé par Windows, Mindset continue");
            None
        }
    };
    let ctx = Contexte::nouveau(dossiers.clone(), VERSION, lancement, essai, ports.clone(), std::process::id());
    for n in &ouverture.notes {
        ctx.journal(n);
    }
    let mut hote = Hote::nouveau(blocs(), ctx);
    let au_depart = hote.demarrer();
    let Some(ligne) = Hote::ligne_demarrage(VERSION, demarrage, &au_depart) else {
        // (un bloc a demandé de quitter avant la fenêtre : rien n'est ouvert)
        drop(instance);
        std::process::exit(0);
    };
    hote.ctx.journal(&ligne);
    let pack: DossierPack = hote.pack.clone();
    let fichiers: Fichiers = hote.fichiers.clone();
    let page = {
        let d = dossiers.donnees.clone();
        Page::new(hote.etat_initial(), move |t: &str| journal_dans(&d, t))
    };
    page.recevoir(|m| ordonner(Ordre::Message(m)));
    ETAT.with(|e| {
        *e.borrow_mut() = Some(Etat {
            hote: Some(hote),
            demandes: None,
            fenetre: None,
            instance,
            systeme: ports.systeme.clone(),
            donnees: dossiers.donnees.clone(),
            exe: exe.clone(),
            montree: Hote::montree_au_depart(demarrage, &au_depart),
            dernier_signal: Instant::now(),
            vu: None,
            fin: None,
            essai,
            au_depart,
        })
    });
    let pour_pack = dossiers.donnees.clone();
    let suite = dossiers.donnees_suite.clone();
    let donnees = dossiers.donnees.clone();
    let constructeur = crate::preparer(tauri::Builder::default(), page)
        .register_uri_scheme_protocol("pack", move |_, demande| {
            let chemin = demande.uri().path();
            let (reponse, refus) = pack.repondre(chemin);
            if let Some(r) = refus {
                let c: String = chemin.chars().take(120).collect();
                journal_dans(&pour_pack, &format!("Thème : fichier refusé ({}) : {c}", r.raison()));
            }
            reponse
        })
        .register_uri_scheme_protocol("fichier", move |_, demande| fichiers.repondre(demande.uri().path()))
        .setup(move |app| {
            ouvrir_fenetre(app, &suite, &donnees);
            Ok(())
        })
        .on_window_event(evenement_fenetre);
    match constructeur.build(crate::contexte()) {
        Ok(app) => {
            let _ = app.run_return(|_, _| {});
        }
        Err(e) => {
            journal_dans(&dossiers.donnees, &format!("Écran impossible : Tauri n'a pas pu démarrer ({e})"));
            ecran_impossible(essai);
        }
    }
    finir()
}

/// Un message simple quand l'écran ne peut pas s'afficher (interface.ps1:9-16), jamais dans la construction d'essai.
fn ecran_impossible(essai: bool) {
    if !essai {
        crate::windows::message::informer(
            "Mindset n'a pas pu s'ouvrir.\n\nRedémarre le PC. Si ça continue, retélécharge Mindset et remplace tout le dossier.",
            crate::NOM_APPLI,
        );
    }
}

/// La zone utile de l'écran principal, en pixels logiques (`SystemParameters.WorkArea`).
fn zone_utile(app: &App) -> Option<(f64, f64)> {
    let m = app.primary_monitor().ok().flatten()?;
    let z = m.work_area();
    let e = m.scale_factor();
    (e > 0.0).then(|| (z.size.width as f64 / e, z.size.height as f64 / e))
}

/// Crée la fenêtre principale (une seule fois), coupe les réglages de WebView2, la montre si elle n'est pas lancée
/// cachée, puis démarre le fil des blocs et la minuterie de la fenêtre.
fn ouvrir_fenetre(app: &App, suite: &Path, donnees: &Path) {
    if app.get_webview_window(LABEL).is_some() {
        return;
    }
    let d = donnees.to_path_buf();
    let journal = move |t: &str| journal_dans(&d, t);
    let pour_page = journal.clone();
    let zone = zone_utile(app);
    let (f, choix) = match creer_principale(app, suite, donnees, zone, Arc::new(move |t: &str| pour_page(t))) {
        Ok(x) => x,
        Err(e) => {
            journal(&format!("Écran impossible : la fenêtre n'a pas pu être créée ({e})"));
            let essai = cfg!(feature = "essai");
            ecran_impossible(essai);
            app.handle().exit(1);
            return;
        }
    };
    journal(&format!("Écran : dossier WebView2 {}", choix.dossier.display()));
    if let Some(r) = &choix.raison {
        journal(&format!("Écran : dossier WebView2 de la suite non pris, repli ({r})"));
    }
    let h = f.hwnd().map(|h| h.0 as usize).unwrap_or(0);
    if !fenetre_windows::garder_taille_minimale(h) {
        journal("Écran : taille minimale non gardée (sous-classe refusée)");
    }
    let pour_reglages = journal.clone();
    if let Err(e) = webview2::couper_reglages(&f, move |t| pour_reglages(t)) {
        journal(&format!("Écran : réglages de WebView2 non posés ({e})"));
    }
    // Un incident de WebView2 (un de ses processus s'est arrêté) : la page est rouverte si c'est celui qui la dessine
    // (webview2.rs), et la console en tient le compte (Receive-IncidentConsole : action `console:incident`)
    let pour_incident = journal.clone();
    let suivi = webview2::surveiller_incidents(&f, move |nom| {
        let rouverte = if webview2::page_a_rouvrir(nom) { ", page rouverte" } else { "" };
        pour_incident(&format!("Écran : incident de WebView2 ({nom}){rouverte}"));
        let valeur = Value::String(nom.to_string());
        ordonner(Ordre::Message(MessagePage::Action { id: "console:incident".into(), valeur, ecran: String::new() }));
    });
    if let Err(e) = suivi {
        journal(&format!("Écran : incidents de WebView2 non suivis ({e})"));
    }
    ETAT.with(|e| {
        let mut e = e.borrow_mut();
        let Some(etat) = e.as_mut() else { return };
        if etat.montree {
            let _ = f.show();
            let _ = f.set_focus();
        }
        if let Some(mut hote) = etat.hote.take() {
            hote.ctx.definir_fenetre(Some(h as isize));
            let mut v = hote.ctx.vue();
            v.visible = etat.montree;
            hote.ctx.definir_vue(v);
            hote.fenetre_prete();
            etat.vu = Some((etat.montree, false));
            let (to, ro) = mpsc::channel();
            let (td, rd) = mpsc::channel();
            let _ = ORDRES.set(to);
            etat.demandes = Some(rd);
            let a = app.handle().clone();
            let etat_essai = etat.essai.then(|| etat.donnees.join("etat.json"));
            let r = std::thread::Builder::new().name("blocs".into()).spawn(move || {
                let ecran = EcranPage { app: a, etat_essai, demandes: td.clone() };
                fil_des_blocs(hote, ecran, ro, td)
            });
            if let Err(x) = r {
                journal(&format!("Écran impossible : le fil des blocs n'a pas pu démarrer ({x})"));
            }
        }
        etat.fenetre = Some(f);
        let attente = std::mem::take(&mut etat.au_depart);
        etat.demandes(attente, app.handle());
    });
    minuterie(app.handle().clone());
}

/// Le fil des blocs : l'hôte, ses ordres, ses tics. Il finit sur `Ordre::Fermer`, quand la file se ferme, ou quand
/// l'hôte a fermé les blocs (Mindset quitte).
fn fil_des_blocs(mut hote: Hote, mut ecran: EcranPage, ordres: Receiver<Ordre>, demandes: Sender<Vec<Demande>>) {
    loop {
        let attente = hote.prochain_tic(PAS_BLOCS);
        let mut d = match ordres.recv_timeout(attente) {
            Ok(Ordre::Message(m)) => hote.recevoir(m, &mut ecran),
            Ok(Ordre::Evenement(nom)) => hote.evenement(nom, &mut ecran),
            Ok(Ordre::Fenetre { visible, reduite }) => hote.fenetre_changee(visible, reduite, &mut ecran),
            Ok(Ordre::Fermer(fini)) => {
                hote.fermer(false, &mut ecran);
                let _ = fini.send(());
                return;
            }
            Err(RecvTimeoutError::Timeout) => hote.minuterie(&mut ecran),
            Err(RecvTimeoutError::Disconnected) => {
                hote.fermer(false, &mut ecran);
                return;
            }
        };
        d.extend(hote.signaler_paniques(&mut ecran));
        if !d.is_empty() {
            let _ = demandes.send(d);
        }
        if hote.ferme() {
            // (les blocs sont fermés : la fin est demandée au fil de la fenêtre ; ce fil répond encore à Fermer)
            while let Ok(o) = ordres.recv() {
                if let Ordre::Fermer(fini) = o {
                    let _ = fini.send(());
                    return;
                }
            }
            return;
        }
    }
}

/// La minuterie : toutes les 100 ms, un tour demandé au fil de la fenêtre.
fn minuterie(app: AppHandle) {
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(PAS);
            let a = app.clone();
            if app.run_on_main_thread(move || tour(&a)).is_err() {
                break;
            }
        }
    });
}

/// Une adresse que Mindset accepte d'ouvrir : une page web, un réglage de Windows, ou un chemin complet.
pub fn adresse_ouvrable(a: &str) -> bool {
    a.starts_with("https://") || a.starts_with("http://") || a.starts_with("ms-settings:") || Path::new(a).is_absolute()
}

impl Etat {
    fn journal(&self, t: &str) {
        journal_dans(&self.donnees, t);
    }

    /// Ce que l'hôte demande à la fenêtre.
    fn demandes(&mut self, d: Vec<Demande>, app: &AppHandle) {
        for x in d {
            match x {
                Demande::Fenetre(quoi) => {
                    let Some(f) = self.fenetre.as_ref() else { continue };
                    match quoi {
                        Fenetre::Montrer => {
                            let _ = f.show();
                            if f.is_minimized().unwrap_or(false) {
                                let _ = f.unminimize();
                            }
                            let _ = f.set_focus();
                        }
                        Fenetre::Cacher => {
                            let _ = f.hide();
                        }
                        Fenetre::Reduire => {
                            let _ = f.minimize();
                        }
                        Fenetre::Restaurer => {
                            if f.is_minimized().unwrap_or(false) {
                                let _ = f.unminimize();
                            }
                        }
                    }
                    let maintenant = (f.is_visible().unwrap_or(false), f.is_minimized().unwrap_or(false));
                    // (12/11, écran noir) la page suit aussi la fenêtre montrée ou cachée par Mindset lui-même : sinon
                    // tour() ne voit aucun changement, et WebView2 garde la page cachée (rien n'est dessiné)
                    let _ = webview2::page_visible(f, maintenant.0 && !maintenant.1);
                    self.vu = Some(maintenant);
                }
                Demande::BarreDeTitre(c) => {
                    let h = self.fenetre.as_ref().and_then(|f| f.hwnd().ok()).map(|h| h.0 as usize).unwrap_or(0);
                    if let Some(rgb) = crate::hote::couleur_rgb(&c) {
                        let _ = fenetre_windows::couleur_barre(h, rgb);
                    }
                }
                Demande::OuvrirAdresse(a) => {
                    if !adresse_ouvrable(&a) || self.systeme.ouvrir(&a).is_err() {
                        self.journal(&format!("Ouverture impossible : {}", a.chars().take(120).collect::<String>()));
                    }
                }
                Demande::Fin { relancer, lancer_apres } => {
                    if self.fin.is_none() {
                        self.journal(if relancer { "Fermeture pour relancer Mindset" } else { "Fermeture" });
                        self.fin = Some((relancer, lancer_apres));
                        if let Some(f) = self.fenetre.as_ref() {
                            let _ = f.hide();
                        }
                        app.exit(0);
                    }
                }
            }
        }
    }

    /// Un pas du fil de la fenêtre.
    fn tour(&mut self, app: &AppHandle) {
        if let Some(r) = &self.demandes {
            let recues: Vec<Vec<Demande>> = r.try_iter().collect();
            for d in recues {
                self.demandes(d, app);
            }
        }
        if self.fin.is_some() {
            return;
        }
        // Un autre lancement de Mindset : la fenêtre revient (interface.ps1:112-117)
        if self.dernier_signal.elapsed() >= PAS_SIGNAL {
            self.dernier_signal = Instant::now();
            if self.instance.as_ref().is_some_and(Instance::signal_leve) {
                ordonner(Ordre::Evenement(mindset_noyau::signaux::AFFICHER_DEMANDE));
            }
        }
        // La fenêtre a changé d'elle-même : la vue suit, la page se met en veille si personne ne la voit
        let Some(f) = self.fenetre.as_ref() else { return };
        let maintenant = (f.is_visible().unwrap_or(false), f.is_minimized().unwrap_or(false));
        if self.vu != Some(maintenant) {
            let reduite_avant = self.vu.is_some_and(|v| v.1);
            self.vu = Some(maintenant);
            let _ = webview2::page_visible(f, maintenant.0 && !maintenant.1);
            ordonner(Ordre::Fenetre { visible: maintenant.0, reduite: maintenant.1 });
            if maintenant.1 && !reduite_avant {
                ordonner(Ordre::Evenement(mindset_noyau::signaux::REDUITE));
            }
        }
    }
}

fn tour(app: &AppHandle) {
    ETAT.with(|e| {
        if let Ok(mut e) = e.try_borrow_mut()
            && let Some(etat) = e.as_mut()
        {
            etat.tour(app);
            #[cfg(feature = "essai")]
            essai_demandes(etat);
        }
    });
}

/// La croix, Alt + F4 : la fenêtre ne se ferme pas, le bloc « près de l'horloge » décide (réduire, quitter, ou la
/// question). La fenêtre n'est jamais détruite par Tauri.
fn evenement_fenetre(w: &Window, ev: &WindowEvent) {
    match ev {
        WindowEvent::CloseRequested { api, .. } => {
            api.prevent_close();
            ordonner(Ordre::Evenement(mindset_noyau::signaux::CROIX));
        }
        WindowEvent::Destroyed => w.app_handle().exit(0),
        _ => {}
    }
}

/// Construction d'essai : les messages demandés (`actions.demande`, un JSON par ligne, comme ceux de la page ; ou un
/// ordre `{ "kit": ... }` envoyé tel quel ; ou `{ "script": "..." }` joué dans la page), et la capture demandée.
#[cfg(feature = "essai")]
fn essai_demandes(etat: &mut Etat) {
    use crate::essai::{ACTIONS_DEMANDE, CAPTURE, CAPTURE_DEMANDE};
    let demande = etat.donnees.join(ACTIONS_DEMANDE);
    if let Ok(texte) = std::fs::read_to_string(&demande) {
        let _ = std::fs::remove_file(&demande);
        for ligne in texte.trim_start_matches('\u{feff}').lines().map(str::trim).filter(|l| !l.is_empty()) {
            let Ok(v) = serde_json::from_str::<Value>(ligne) else { continue };
            if let Some(s) = v.get("script").and_then(Value::as_str) {
                if let Some(f) = etat.fenetre.as_ref() {
                    let _ = f.eval(s);
                }
                continue;
            }
            if v.get("kit").is_some() {
                if let Some(f) = etat.fenetre.as_ref() {
                    f.app_handle().state::<Page>().ordre(v);
                }
                continue;
            }
            match crate::pont::lire_message(&v) {
                Ok(m) => ordonner(Ordre::Message(m)),
                Err(r) => etat.journal(&format!("Essai : demande refusée ({})", r.raison())),
            }
        }
    }
    let demande = etat.donnees.join(CAPTURE_DEMANDE);
    if demande.is_file() {
        let _ = std::fs::remove_file(&demande);
        let Some(f) = etat.fenetre.as_ref() else { return };
        let h = f.hwnd().map(|h| h.0 as usize).unwrap_or(0);
        let png = crate::windows::capture::capturer(h)
            .and_then(|(l, ht, px)| crate::png::encoder(l, ht, &px).map(|p| (l, ht, p)));
        match png {
            Some((l, ht, p)) => match std::fs::write(etat.donnees.join(CAPTURE), p) {
                Ok(()) => etat.journal(&format!("Essai : capture de {l} x {ht}")),
                Err(e) => etat.journal(&format!("Essai : capture non écrite ({e})")),
            },
            None => etat.journal("Essai : capture impossible"),
        }
    }
}

/// La fin (Mindset.ps1:139-169) : les blocs fermés sur leur fil, la place libérée, la relance (`relance.marque`
/// d'abord, interface.ps1:105-109) ou le programme à lancer après, puis `std::process::exit`.
fn finir() -> ! {
    let (t, r) = mpsc::channel();
    ordonner(Ordre::Fermer(t));
    let fermes = ORDRES.get().is_none() || r.recv_timeout(ATTENTE_FERMETURE).is_ok();
    let suite = ETAT.with(|e| {
        let mut e = e.try_borrow_mut().ok()?;
        let etat = e.as_mut()?;
        if etat.fin.is_none() {
            etat.journal("Fermeture : la fenêtre a disparu");
        }
        if !fermes {
            etat.journal("Fermeture : les blocs n'ont pas fini à temps");
        }
        // (la place est libérée avant toute relance : le nouveau Mindset prend le verrou)
        etat.instance = None;
        let (relancer, apres) = etat.fin.clone().unwrap_or((false, None));
        Some((relancer, apres, etat.exe.clone(), etat.donnees.clone(), etat.essai))
    });
    if let Some((relancer, apres, exe, donnees, essai)) = suite
        && !essai
    {
        let lancer = |p: &Path| {
            let dossier = p.parent().map(Path::to_path_buf).unwrap_or_default();
            let r = std::process::Command::new(p).current_dir(dossier).creation_flags(SANS_CONSOLE).spawn();
            if let Err(e) = r {
                journal_dans(&donnees, &format!("Relance impossible ({e})"));
            }
        };
        if relancer {
            let _ = std::fs::write(donnees.join("relance.marque"), std::process::id().to_string());
            lancer(&exe);
        } else if let Some(p) = apres {
            lancer(&p);
        }
    }
    quitter_sans_rien_lacher(0)
}

/// Quitte le processus sans lâcher l'état du fil qui quitte (voir Nevermind et Mindcare en Rust : lâcher là des fils
/// déjà arrêtés par Windows pouvait bloquer la fin pour toujours).
fn quitter_sans_rien_lacher(code: i32) -> ! {
    let reste = ETAT.with(|e| e.try_borrow_mut().ok().and_then(|mut e| e.take()));
    std::mem::forget(reste);
    std::process::exit(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fichiers_livres() {
        let d = mindset_noyau::dossier_essai("fichiers-livres");
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("cles-publiques")).unwrap();
        assert_eq!(fichiers_manquants(&d), ["apps.json", "cles-publiques"]);
        std::fs::write(d.join("apps.json"), "[]").unwrap();
        std::fs::write(d.join("cles-publiques").join("principale.xml"), "<x/>").unwrap();
        assert!(fichiers_manquants(&d).is_empty());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn adresses_ouvrables() {
        assert!(adresse_ouvrable("https://github.com/JordanJacquot/Mindset"));
        assert!(adresse_ouvrable(r"C:\Program Files\Mindset"));
        assert!(adresse_ouvrable("ms-settings:sound"));
        for a in ["calc.exe", "file:///C:/x", "javascript:x", "..\\x", ""] {
            assert!(!adresse_ouvrable(a), "{a}");
        }
    }
}
