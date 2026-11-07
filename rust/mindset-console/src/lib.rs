//! Mindset en Rust, bloc « console 3D » : l'accueil de Mindset en 3D (`modules/console.ps1`, `console/scene.html`).
//!
//! La scène (`mindset-appli/ui/console/scene.html`, reprise telle quelle) est un cadre (`<iframe>`) de la page, posé
//! dans `#page-console` par `console/console.js` d'après l'état `console.cadre`. Elle ne fait rien d'elle-même : elle
//! envoie des actions connues (ouvrir, installer, mettre à jour, fermer...) avec l'identifiant d'une appli, que ce
//! bloc vérifie avant de demander aux autres blocs de les faire (signaux, `Effet::Action`). Ce bloc lui envoie l'état
//! des applis et des mises à jour (`console.etat`, `console.maj`, donnés par console.js à `window.mindset.etat` et
//! `window.mindset.majAuto`), et ses ordres (`Effet::Ordre { kit: 'console', appel, args }`, comme
//! `Invoke-ScriptConsole`).
//!
//! Économie, comme la version PowerShell :
//! - Mindset caché près de l'horloge ou réduit : le cadre est retiré (plus rien, ni processeur, ni mémoire) ;
//! - une autre page de Mindset : la 3D est mise en pause, puis le cadre est retiré au bout d'une minute ;
//! - il revient au retour sur l'accueil (« Allumage de la console... » en attendant) ;
//! - la scène dessine au plus 60 images par seconde (DIVERGENCES.md).
//!
//! Repli : réglage « Animations : aucune », ou trop d'incidents : l'accueil classique (les cartes), comme avant.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::Duration;

use mindset_noyau::appli::{self, Appli};
use mindset_noyau::{Bloc, Contexte, Effet, Effets, Fenetre, partage, signaux};
use serde_json::{Map, Value, json};
use suite_commun::themes::{self, Theme};

pub mod calculs;
pub mod images;
#[cfg(windows)]
mod windows;

/// La scène, telle qu'elle est rangée dans la page (ses couleurs sont lues ici, comme `Get-CouleursConsole`).
pub const SCENE: &str = include_str!("../../mindset-appli/ui/console/scene.html");
/// Les logos livrés avec la console (`ui/console/logos/<id>.png`).
pub const LOGOS_LIVRES: &[&str] = &["evermind", "mindcare", "mindset", "nevermind"];
/// Le texte de l'attente (`ConsoleAttente`, interface.xaml:305).
pub const TEXTE_ATTENTE: &str = "Allumage de la console...";
/// L'état des applis est revu toutes les 1,5 s (`$script:ConsoleTimer`), toutes les 30 s Mindset caché.
pub const RYTHME: Duration = Duration::from_millis(1500);
pub const RYTHME_CACHE: Duration = Duration::from_secs(30);
/// Pendant une ouverture, la fenêtre de l'appli est cherchée toutes les 300 ms (`$script:ConsoleAttenteTimer`).
pub const RYTHME_ATTENTE: Duration = Duration::from_millis(300);
/// Une minute sur une autre page : le cadre est retiré.
pub const DELAI_FERMETURE: Duration = Duration::from_secs(60);
/// Un message de la scène plus long est ignoré (`$Json.Length -gt 2000`).
pub const MESSAGE_MAX: usize = 2000;
/// Les onglets des Paramètres (`$OngletsParametres`, parametres.ps1:306).
pub const ONGLETS: &[&str] = &["general", "apparence", "son", "maj", "conso", "dossiers"];

/// Trouver la fenêtre principale d'une appli (`[MSIntegration]::Trouver`) : le vrai est dans le module Windows, les
/// tests en donnent un faux.
pub trait Fenetres: Send {
    fn trouvee(&self, pid: u32, titre: &str) -> bool;
}

struct FenetresWindows;

impl Fenetres for FenetresWindows {
    #[cfg(windows)]
    fn trouvee(&self, pid: u32, titre: &str) -> bool {
        windows::fenetre_trouvee(pid, titre)
    }
    #[cfg(not(windows))]
    fn trouvee(&self, _pid: u32, _titre: &str) -> bool {
        false
    }
}

/// Le bloc « console 3D » (`$script:Console`).
pub struct BlocConsole {
    /// La 3D peut s'afficher (sinon : l'accueil classique)
    possible: bool,
    /// Le thème de la suite (lu au démarrage : un nouveau thème relance Mindset)
    theme: Option<Theme>,
    /// Le numéro du cadre affiché (`$script:Console.Vue`), `None` : pas de cadre
    vue: Option<u64>,
    numero: u64,
    /// L'adresse du cadre affiché
    adresse: String,
    /// La scène a dit qu'elle était prête
    pret: bool,
    derniere_appli: Option<String>,
    /// Les ordres à jouer quand la scène sera prête (`AJouer`)
    a_jouer: Vec<Value>,
    /// Quittée (une autre page) à ce moment (temps écoulé depuis le lancement)
    quittee_a: Option<Duration>,
    en_fente: Option<String>,
    ejecter: Option<String>,
    /// L'appli qui s'ouvre (`Attente`), depuis quand
    attente: Option<String>,
    attente_depuis: Duration,
    lancee: bool,
    duree_attendue: Option<f64>,
    /// Les Paramètres sont ouverts dans l'écran de la console
    parametres: bool,
    arretee_a: Option<Duration>,
    incidents: Vec<Duration>,
    /// Le logo de chaque appli (`Get-LogoConsole`), ceux déjà essayés, ceux déjà servis par l'hôte
    logos: BTreeMap<String, Option<String>>,
    logos_essayes: BTreeSet<String>,
    logos_exposes: BTreeSet<String>,
    /// Augmente pour que console.js renvoie tout à la scène même sans changement (`-Force`)
    envoi: u64,
    /// « Actualiser » : la dernière recherche d'avant le clic, pour le message
    actualiser_avant: Option<Option<Value>>,
    prochaine_minuterie: Duration,
    prochaine_attente: Duration,
    fenetres: Option<Box<dyn Fenetres>>,
    publie: Option<Value>,
    /// Le premier tic est passé
    premier_tic_fait: bool,
}

/// Le bloc, prêt à être donné à l'hôte (`Box::new(mindset_console::BlocConsole)` dans `blocs()`).
#[allow(non_upper_case_globals)]
pub const BlocConsole: BlocConsole = BlocConsole::NEUF;

impl Default for BlocConsole {
    fn default() -> Self {
        BlocConsole::NEUF
    }
}

/// Un ordre à la scène (`window.mindset.<appel>(...args)`).
pub fn ordre(appel: &str, args: Vec<Value>) -> Value {
    json!({ "kit": "console", "appel": appel, "args": args })
}

/// `$Texte -replace '\s+', ' '`
fn espaces(t: &str) -> String {
    let mut s = String::new();
    let mut avant = false;
    for c in t.chars() {
        if c.is_whitespace() {
            if !avant {
                s.push(' ');
            }
            avant = true;
        } else {
            s.push(c);
            avant = false;
        }
    }
    s
}

/// `Get-Appli` sur un id venu de la scène : seulement `^[a-z0-9-]{1,30}$` (sans les majuscules, comme `-match`).
fn appli_de(ctx: &Contexte, id: &str) -> Option<Appli> {
    let n = id.chars().count();
    if !(1..=30).contains(&n) || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return None;
    }
    ctx.applis().iter().find(|a| a.id.eq_ignore_ascii_case(id)).cloned()
}

fn texte(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(v) => suite_commun::protocole_installateur::texte_ps(v),
    }
}

fn vrai(v: Option<&Value>) -> bool {
    v.is_some_and(suite_commun::protocole_installateur::vrai_ps)
}

/// L'appli est-elle accrochée dans Mindset avec sa fenêtre (`$i.Fenetre -ne 0`) ?
fn accrochee(ctx: &Contexte, id: &str) -> bool {
    ctx.lu(partage::ACCROCHEES)
        .and_then(|v| v.get(id).and_then(|x| x.get("etat")).and_then(Value::as_str).map(|e| e == "affiche"))
        .unwrap_or(false)
}

impl BlocConsole {
    /// Un bloc neuf (la 3D est décidée au démarrage).
    pub const NEUF: BlocConsole = BlocConsole {
        possible: false,
        theme: None,
        vue: None,
        numero: 0,
        adresse: String::new(),
        pret: false,
        derniere_appli: None,
        a_jouer: Vec::new(),
        quittee_a: None,
        en_fente: None,
        ejecter: None,
        attente: None,
        attente_depuis: Duration::ZERO,
        lancee: false,
        duree_attendue: None,
        parametres: false,
        arretee_a: None,
        incidents: Vec::new(),
        logos: BTreeMap::new(),
        logos_essayes: BTreeSet::new(),
        logos_exposes: BTreeSet::new(),
        envoi: 0,
        actualiser_avant: None,
        prochaine_minuterie: Duration::ZERO,
        prochaine_attente: Duration::ZERO,
        fenetres: None,
        publie: None,
        premier_tic_fait: false,
    };

    /// Pour les tests : un faux pour trouver les fenêtres des applis.
    pub fn avec_fenetres(f: Box<dyn Fenetres>) -> BlocConsole {
        BlocConsole { fenetres: Some(f), ..BlocConsole::NEUF }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Ce que les tests regardent ou posent
    // -----------------------------------------------------------------------------------------------------------

    pub fn possible(&self) -> bool {
        self.possible
    }
    pub fn cadre(&self) -> Option<u64> {
        self.vue
    }
    pub fn adresse_cadre(&self) -> Option<&str> {
        self.vue.map(|_| self.adresse.as_str())
    }
    pub fn pret(&self) -> bool {
        self.pret
    }
    pub fn en_fente(&self) -> Option<&str> {
        self.en_fente.as_deref()
    }
    pub fn parametres_ouverts(&self) -> bool {
        self.parametres
    }
    pub fn attente(&self) -> Option<&str> {
        self.attente.as_deref()
    }
    pub fn a_jouer(&self) -> &[Value] {
        &self.a_jouer
    }
    pub fn quittee(&self) -> bool {
        self.quittee_a.is_some()
    }
    pub fn derniere_appli(&self) -> Option<&str> {
        self.derniere_appli.as_deref()
    }
    pub fn ejecter(&self) -> Option<&str> {
        self.ejecter.as_deref()
    }
    pub fn arretee(&self) -> bool {
        self.arretee_a.is_some()
    }
    pub fn lancee(&self) -> bool {
        self.lancee
    }
    /// Tests : quittée (une autre page) il y a un instant.
    pub fn poser_quittee(&mut self, ctx: &Contexte) {
        self.quittee_a = Some(ctx.ecoule());
    }
    pub fn nombre_incidents(&self) -> usize {
        self.incidents.len()
    }

    /// Tests : la console comme la version PowerShell la laisse (pour rejouer un juge).
    pub fn poser(&mut self, possible: bool, cadre: bool, pret: bool, derniere: Option<&str>, ejecter: Option<&str>) {
        self.possible = possible;
        if cadre {
            self.numero += 1;
            self.vue = Some(self.numero);
        } else {
            self.vue = None;
        }
        self.pret = pret;
        self.derniere_appli = derniere.map(str::to_string);
        self.ejecter = ejecter.map(str::to_string);
    }
    /// Tests : la fente et les Paramètres.
    pub fn poser_fente(&mut self, en_fente: Option<&str>, parametres: bool) {
        self.en_fente = en_fente.map(str::to_string);
        self.parametres = parametres;
    }
    /// Tests : des incidents passés (il y a tant de secondes).
    pub fn poser_incidents(&mut self, ctx: &Contexte, il_y_a: &[u64]) {
        let now = ctx.ecoule();
        self.incidents = il_y_a.iter().map(|s| now.saturating_sub(Duration::from_secs(*s))).collect();
    }
    /// Tests : la 3D arrêtée il y a tant de secondes.
    pub fn poser_arret(&mut self, ctx: &Contexte, il_y_a: Option<u64>) {
        self.arretee_a = il_y_a.map(|s| ctx.ecoule().saturating_sub(Duration::from_secs(s)));
    }

    // -----------------------------------------------------------------------------------------------------------
    // Le thème et l'adresse de la scène
    // -----------------------------------------------------------------------------------------------------------

    fn charger_theme(&mut self, ctx: &Contexte) {
        if self.theme.is_none() {
            let choix = ctx.donnees().theme_suite();
            self.theme = Some(themes::charger(Some(&choix), &[ctx.dans_donnees("packs")]));
        }
    }

    fn theme(&mut self, ctx: &Contexte) -> &Theme {
        self.charger_theme(ctx);
        self.theme.get_or_insert_with(Theme::neon)
    }

    /// L'adresse de la scène (`Navigate("https://mindset.local/scene.html?...")`, console.ps1:125-130), relative à
    /// la page de Mindset : le départ, la vitesse, les couleurs du thème, ses images, et le numéro du cadre.
    pub fn adresse_scene(&mut self, ctx: &Contexte, depart: &str, numero: u64) -> String {
        let anim = if ctx.reglage_texte("Animations", "completes").eq_ignore_ascii_case("express") {
            "express"
        } else {
            "completes"
        };
        let theme = self.theme(ctx).clone();
        let couleurs = calculs::couleurs_console(SCENE, &theme);
        let mut a = format!(
            "console/scene.html?vue={depart}&animations={anim}&couleurs={}",
            calculs::echapper(&calculs::json_compact(&Value::Object(couleurs)))
        );
        if let Some(t) = calculs::theme_console(theme.pack.as_ref(), &mut |f| images::fichier_anime(f)) {
            a.push_str(&format!("&theme={}", calculs::echapper(&calculs::json_compact(&t))));
        }
        // (essai : le décor, quelle que soit l'heure)
        if ctx.essai
            && let Ok(d) = std::env::var("MINDSET_TEST_DECOR")
            && ["jour", "soir", "nuit"].contains(&d.as_str())
        {
            a.push_str(&format!("&decor={d}"));
        }
        a.push_str(&format!("&n={numero}"));
        a
    }

    // -----------------------------------------------------------------------------------------------------------
    // Le cadre
    // -----------------------------------------------------------------------------------------------------------

    /// `Test-ConsolePossible` : la raison si la 3D n'est pas possible.
    fn raison_impossible(ctx: &Contexte) -> Option<String> {
        ctx.reglage_texte("Animations", "completes")
            .eq_ignore_ascii_case("aucune")
            .then(|| "réglage Animations : aucune".to_string())
    }

    /// `New-VueConsole`
    fn nouvelle_vue(&mut self, ctx: &Contexte, depart: &str, effets: &mut Effets) {
        if self.vue.is_some() || !self.possible {
            return;
        }
        self.numero += 1;
        self.adresse = self.adresse_scene(ctx, depart, self.numero);
        self.vue = Some(self.numero);
        self.pret = false;
        self.rafraichir_logos(ctx, effets);
    }

    /// `Remove-VueConsole`
    fn retirer_vue(&mut self, ctx: &Contexte, pourquoi: Option<&str>) {
        if self.vue.is_none() {
            return;
        }
        self.vue = None;
        self.pret = false;
        if let Some(p) = pourquoi {
            ctx.journal(&format!("Console 3D fermée ({p})"));
        }
    }

    /// `Invoke-ScriptConsole` : seulement à une scène prête.
    fn appeler(&self, effets: &mut Effets, appel: &str, args: Vec<Value>) {
        if self.vue.is_some() && self.pret {
            effets.ajouter(Effet::Ordre(ordre(appel, args)));
        }
    }

    /// `Stop-Console` : l'accueil classique reprend (réessayé au plus tôt 10 minutes plus tard).
    fn arreter(&mut self, ctx: &Contexte, raison: &str, effets: &mut Effets) {
        ctx.journal(&format!("Console 3D : {raison}, accueil classique"));
        self.possible = false;
        self.arretee_a = Some(ctx.ecoule());
        self.retirer_vue(ctx, None);
        self.mettre_a_jour_page(ctx, effets);
    }

    /// `Resume-ConsoleArretee`
    pub fn reprendre_arretee(&mut self, ctx: &Contexte) {
        let Some(a) = self.arretee_a else { return };
        if self.possible || ctx.ecoule().saturating_sub(a) < Duration::from_secs(600) {
            return;
        }
        self.arretee_a = None;
        self.incidents.clear();
        if let Some(r) = Self::raison_impossible(ctx) {
            ctx.journal(&format!("Console 3D : toujours impossible ({r})"));
            return;
        }
        ctx.journal("Console 3D : nouvel essai après un incident");
        self.possible = true;
    }

    /// `Receive-IncidentConsole` : un processus de la 3D s'est arrêté.
    pub fn incident(&mut self, ctx: &Contexte, genre: &str, effets: &mut Effets) {
        if calculs::reaction_incident(genre) == "continuer" {
            ctx.journal(&format!("Console 3D : incident sans gravité ({genre}), elle continue"));
            return;
        }
        let maintenant = ctx.ecoule();
        self.incidents.retain(|t| maintenant.saturating_sub(*t) < Duration::from_secs(600));
        self.incidents.push(maintenant);
        if self.incidents.len() > 3 {
            self.incidents.clear();
            self.arreter(ctx, "processus de la 3D arrêté 4 fois en 10 minutes", effets);
            return;
        }
        ctx.journal(&format!("Console 3D : processus de la 3D arrêté ({genre}), elle redémarre"));
        self.retirer_vue(ctx, None);
        self.mettre_a_jour_page(ctx, effets);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Quelle page montrer (Update-PageConsole)
    // -----------------------------------------------------------------------------------------------------------

    /// `Update-PageConsole` : la console à la place de l'accueil, en pause sur une autre page.
    pub fn mettre_a_jour_page(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let vue = ctx.vue();
        let accueil = vue.page == "accueil";
        if !self.possible {
            return;
        }
        if accueil && vue.visible && !vue.reduite {
            self.quittee_a = None;
            // Ce que la scène joue en revenant : d'une appli qui tourne encore, le menu en grand dans l'écran ; d'une
            // appli fermée, la caméra ressort de l'écran et sa cartouche ressort de la fente. Les Paramètres demandés
            // s'ouvrent ensuite dans l'écran, sur leur onglet.
            let depuis = self.derniere_appli.take();
            let mut js = Vec::new();
            if let Some(d) = &depuis {
                js.push(if self.ejecter.is_some() {
                    ordre("jouerRetour", vec![json!(d), json!(true)])
                } else {
                    ordre("jouerMenu", vec![json!(d)])
                });
            }
            self.ejecter = None;
            if self.parametres {
                let onglet = ctx
                    .lu(partage::ONGLET_PARAMETRES)
                    .and_then(|o| o.as_str().map(str::to_string))
                    .filter(|o| ONGLETS.contains(&o.as_str()))
                    .unwrap_or_else(|| "general".into());
                // (console.js y met l'état des Paramètres et les images des thèmes : `window.mindset.reglages`)
                js.push(json!({ "kit": "console", "appel": "reglagesOuvrir", "onglet": onglet, "instant": self.vue.is_none() }));
            }
            if self.vue.is_none() {
                self.a_jouer = js;
                self.nouvelle_vue(ctx, if depuis.is_some() { "dedans" } else { "menu" }, effets);
            } else if !self.pret {
                if !js.is_empty() {
                    self.a_jouer = js;
                }
            } else {
                self.appeler(effets, "reprendre", Vec::new());
                effets.0.extend(js.into_iter().map(Effet::Ordre));
                self.envoi += 1;
            }
        } else {
            if !accueil {
                self.parametres = false;
            }
            if self.vue.is_some() {
                // Une autre page : pause tout de suite, fermeture au bout d'une minute
                self.appeler(effets, "pause", Vec::new());
                if self.quittee_a.is_none() {
                    self.quittee_a = Some(ctx.ecoule());
                }
            }
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Les logos (Get-LogoConsole)
    // -----------------------------------------------------------------------------------------------------------

    /// Le nom sous lequel l'hôte sert le logo tiré d'une appli (`http://fichier.localhost/<nom>`).
    pub fn nom_logo(id: &str) -> String {
        format!("console-logo-{id}.png")
    }

    /// Le logo connu d'une appli (après `rafraichir_logos`).
    pub fn logo(&self, id: &str) -> Option<String> {
        self.logos.get(id).cloned().flatten()
    }

    /// Le logo de chaque appli : celui livré avec Mindset, sinon celui déjà tiré de son icône (servi par l'hôte),
    /// sinon tiré une fois de l'icône de l'appli installée ; sans rien, la scène dessine la première lettre.
    pub fn rafraichir_logos(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let dossier = ctx.dans_donnees("console-logos");
        for a in ctx.applis().iter() {
            let logo = if LOGOS_LIVRES.contains(&a.id.as_str()) {
                Some(format!("logos/{}.png", a.id))
            } else {
                let f = dossier.join(format!("{}.png", a.id));
                if f.is_file() || self.tirer_logo(ctx, a, &f) {
                    if self.logos_exposes.insert(a.id.clone()) {
                        effets.ajouter(Effet::Exposer { nom: Self::nom_logo(&a.id), chemin: Some(f) });
                    }
                    Some(format!("http://fichier.localhost/{}", Self::nom_logo(&a.id)))
                } else {
                    None
                }
            };
            self.logos.insert(a.id.clone(), logo);
        }
    }

    /// Le logo tiré une fois de l'icône de l'appli installée, écrit dans `console-logos\<id>.png`.
    fn tirer_logo(&mut self, ctx: &Contexte, a: &Appli, f: &Path) -> bool {
        let Some(inst) = partage::installation(ctx, &a.id) else { return false };
        if !self.logos_essayes.insert(a.id.clone()) {
            return false;
        }
        let png = images::icone_appli(Path::new(&inst.dossier))
            .and_then(|i| std::fs::read(i).ok())
            .and_then(|b| images::png_de_icone(&b));
        let Some(png) = png else { return false };
        let ecrit = f.parent().is_some_and(|d| std::fs::create_dir_all(d).is_ok()) && std::fs::write(f, png).is_ok();
        if ecrit {
            ctx.journal(&format!("Console 3D : logo de {} tiré de son icône", a.nom));
        }
        ecrit
    }

    // -----------------------------------------------------------------------------------------------------------
    // Les minuteries
    // -----------------------------------------------------------------------------------------------------------

    /// `$script:ConsoleTimer` : l'appli dans la fente fermée, la minute sur une autre page, les logos.
    fn minuterie(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if let Some(en) = self.en_fente.clone()
            && let Some(a) = ctx.appli(&en)
            && !appli::appli_ouverte(ctx, &a)
        {
            self.en_fente = None;
            if ctx.vue().page == en {
                self.ejecter = Some(en.clone());
                self.derniere_appli = Some(en);
                effets.ajouter(Effet::Page("accueil".into()));
            } else {
                self.appeler(effets, "jouerEjection", vec![json!(en)]);
            }
        }
        if self.vue.is_none() {
            return;
        }
        if let Some(q) = self.quittee_a
            && ctx.ecoule().saturating_sub(q) >= DELAI_FERMETURE
        {
            self.retirer_vue(ctx, Some("une minute sur une autre page"));
            self.quittee_a = None;
            return;
        }
        self.rafraichir_logos(ctx, effets);
    }

    /// Une fenêtre de l'appli est-elle prête (accrochée, ou trouvée parmi celles de ses programmes) ?
    fn fenetre_prete(&self, ctx: &Contexte, a: &Appli) -> bool {
        if accrochee(ctx, &a.id) {
            return true;
        }
        let pids: Vec<u32> = appli::processus_appli(ctx, a, true).iter().map(|p| p.pid).collect();
        match &self.fenetres {
            Some(f) => pids.iter().any(|p| f.trouvee(*p, &a.nom)),
            None => pids.iter().any(|p| FenetresWindows.trouvee(*p, &a.nom)),
        }
    }

    /// `$script:ConsoleAttenteTimer` : pendant l'animation d'ouverture, la fenêtre de l'appli est-elle prête ?
    fn minuterie_attente(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let Some(id) = self.attente.clone() else { return };
        let Some(a) = ctx.appli(&id) else {
            self.attente = None;
            return;
        };
        let prete = self.fenetre_prete(ctx, &a);
        let ecoule = ctx.ecoule().saturating_sub(self.attente_depuis).as_secs_f64();
        if !prete {
            let d = *self.duree_attendue.get_or_insert_with(|| calculs::duree_attendue(ctx, &id));
            self.appeler(effets, "avancee", vec![json!(id), json!(calculs::avancee_ouverture(d, ecoule))]);
        }
        if prete || ecoule > 60.0 || (ecoule > 15.0 && !appli::appli_ouverte(ctx, &a)) {
            self.attente = None;
            // (Save-DureeOuverture : la durée de cette ouverture est retenue pour la prochaine barre)
            if prete && self.lancee && (1.0..=120.0).contains(&ecoule) {
                ctx.ecrire_reglage(&format!("Ouverture-{id}"), json!(calculs::arrondi(ecoule, 1)));
            }
            self.appeler(effets, "appliPrete", vec![json!(id)]);
            if !prete {
                ctx.journal(&format!(
                    "Console 3D : {} pas prête après {} s, affichée quand même",
                    a.nom,
                    ecoule.round_ties_even() as i64
                ));
            }
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Ce que la scène demande (Receive-MessageConsole)
    // -----------------------------------------------------------------------------------------------------------

    /// Un message de la scène (`{ type, ... }`, sans `type` dans `m`) : seulement des actions connues, sur une appli
    /// de la liste.
    pub fn message(&mut self, ctx: &Contexte, type_: &str, m: &Map<String, Value>, effets: &mut Effets) {
        let mut tout = Map::new();
        tout.insert("type".into(), json!(type_));
        tout.extend(m.iter().filter(|(k, _)| k.as_str() != "cadre").map(|(k, v)| (k.clone(), v.clone())));
        if calculs::json_compact(&Value::Object(tout)).encode_utf16().count() > MESSAGE_MAX {
            return;
        }
        match type_ {
            "pret" => {
                let cadre = m.get("cadre").and_then(Value::as_u64);
                if self.vue.is_none() || cadre.is_some_and(|c| Some(c) != self.vue) {
                    return;
                }
                self.pret = true;
                self.envoi += 1;
                for o in std::mem::take(&mut self.a_jouer) {
                    effets.ajouter(Effet::Ordre(o));
                }
                ctx.journal("Console 3D prête");
                return;
            }
            "erreur" => {
                ctx.journal(&format!("Console 3D : erreur du script ({})", espaces(&texte(m.get("texte")))));
                return;
            }
            "reglage" => {
                if self.parametres {
                    let mut v = Map::new();
                    for k in ["quoi", "valeur", "id"] {
                        if let Some(x) = m.get(k) {
                            v.insert(k.into(), x.clone());
                        }
                    }
                    effets.ajouter(Effet::Action { id: "parametres:reglage".into(), valeur: Value::Object(v) });
                    self.envoi += 1;
                }
                return;
            }
            _ => {}
        }
        let id = texte(m.get("id"));
        let a = appli_de(ctx, &id);
        if type_ == "afficher" {
            // Fin de la plongée dans l'écran : l'appli prend la place de la console
            if let Some(a) = a {
                self.derniere_appli = Some(a.id.clone());
                self.en_fente = Some(a.id.clone());
                effets.ajouter(signaux::ouvrir_appli(&a.id, true));
            }
            return;
        }
        if type_ != "action" {
            return;
        }
        match texte(m.get("action")).as_str() {
            "ouvrir" => {
                if let Some(a) = a
                    && let Some(inst) = partage::installation(ctx, &a.id)
                {
                    self.lancee = !appli::appli_ouverte(ctx, &a);
                    self.duree_attendue = None;
                    if self.lancee {
                        // Start-AppliCachee : cachée (-Demarrage) si sa version sait se dessiner une fois accrochée
                        let v = inst.version.unwrap_or_default();
                        let cache = !a.cache_depuis.is_empty()
                            && !v.is_empty()
                            && !suite_commun::version::plus_recente(&a.cache_depuis, &v);
                        effets.signal(signaux::LANCER_APPLI, json!({ "id": a.id, "demarrage": cache }));
                    }
                    self.attente = Some(a.id.clone());
                    self.attente_depuis = ctx.ecoule();
                    self.appeler(effets, "jouerOuverture", vec![json!(a.id)]);
                    self.prochaine_attente = ctx.ecoule() + RYTHME_ATTENTE;
                }
            }
            "installer" => {
                if let Some(a) = a
                    && partage::installation(ctx, &a.id).is_none()
                {
                    let trouvee = ctx.lu(partage::TROUVEES).is_some_and(|t| !texte(t.get(&a.id)).is_empty());
                    let quoi = if trouvee { "prendre" } else { "installer" };
                    effets.ajouter(Effet::Action {
                        id: "ecrans:carte".into(),
                        valeur: json!({ "id": a.id, "quoi": quoi }),
                    });
                }
            }
            "maj" => {
                if let Some(a) = a {
                    effets.ajouter(Effet::Action {
                        id: "ecrans:carte".into(),
                        valeur: json!({ "id": a.id, "quoi": "maj" }),
                    });
                } else if id == "mindset"
                    && ctx.lu(partage::MINDSET).is_some_and(|m| m.get("maj").is_some_and(|x| vrai(x.get("prete"))))
                {
                    effets.signal(signaux::MAJ_MINDSET, json!({ "confirmer": true }));
                }
            }
            "confidentialite" => {
                if let Some(a) = a {
                    effets.signal(signaux::CONFIDENTIALITE, json!({ "id": a.id }));
                }
            }
            "fermer" => {
                if let Some(a) = a {
                    self.fermer_appli(ctx, &a, effets);
                }
            }
            "parametres" => effets.signal(signaux::OUVRIR_PARAMETRES, json!({ "onglet": "general" })),
            "parametresFermes" => self.parametres = false,
            "actualiser" => {
                self.actualiser_avant = Some(ctx.lu(partage::RECHERCHE).and_then(|r| r.get("derniere").cloned()));
                effets.ajouter(signaux::actualiser(true));
            }
            "majAuto" => self.pastille_maj_auto(ctx, vrai(m.get("valeur")), effets),
            "majReglages" => effets.signal(signaux::OUVRIR_PARAMETRES, json!({ "onglet": "maj" })),
            "majTout" => {
                let premiere =
                    ctx.applis().iter().find(|a| calculs::etat_carte(ctx, a).maj_dispo).map(|a| a.id.clone());
                match premiere {
                    Some(id) => effets.ajouter(Effet::Action {
                        id: "ecrans:carte".into(),
                        valeur: json!({ "id": id, "quoi": "maj" }),
                    }),
                    None => self.appeler(effets, "message", vec![json!("Toutes tes applis sont à jour")]),
                }
            }
            "veille" => effets.ajouter(Effet::Fenetre(Fenetre::Cacher)),
            _ => {}
        }
    }

    /// `Set-MajAutoConsole` : la pastille « Mise à jour automatique » (le même réglage que Paramètres > Mises à jour).
    /// Recherche coupée : elle ne change pas.
    fn pastille_maj_auto(&mut self, ctx: &Contexte, oui: bool, effets: &mut Effets) {
        if ctx.reglage_bool("VerifVersions", true) {
            ctx.ecrire_reglage("MajAuto", json!(oui));
            ctx.journal(&format!(
                "Mises à jour automatiques : {} (pastille de la console)",
                if oui { "oui" } else { "non" }
            ));
            effets.signal(signaux::REGLAGE_CHANGE, json!({ "nom": "MajAuto", "valeur": oui }));
        }
        self.envoi += 1;
    }

    /// `Stop-AppliConsole` : sa fenêtre affichée dans Mindset reçoit « Fermer », sinon sa demande de fermeture.
    fn fermer_appli(&mut self, ctx: &Contexte, a: &Appli, effets: &mut Effets) {
        if self.en_fente.as_deref() == Some(a.id.as_str()) {
            self.en_fente = None;
        }
        self.appeler(effets, "jouerEjection", vec![json!(a.id)]);
        if accrochee(ctx, &a.id) {
            effets.signal(signaux::FERMER_APPLI, json!({ "id": a.id }));
            ctx.journal(&format!("{} fermé depuis la console", a.nom));
            return;
        }
        if !appli::appli_ouverte(ctx, a) {
            return;
        }
        effets.signal(signaux::DEMANDE_QUITTER, json!({ "id": a.id }));
        ctx.journal(&format!("Fermeture de {} demandée depuis la console", a.nom));
    }

    /// `Set-ReglageAnimations` (le réglage est déjà écrit par le bloc « paramètres ») : la console s'éteint, se
    /// rallume, ou repart à la bonne vitesse.
    pub fn reglage_animations(&mut self, ctx: &Contexte, choix: &str, effets: &mut Effets) {
        if choix.eq_ignore_ascii_case("aucune") {
            if !self.possible {
                return;
            }
            self.possible = false;
            self.retirer_vue(ctx, Some("réglage Animations : aucune"));
            // Sans 3D, plus de console : la page des Paramètres d'avant prend le relais, sur Apparence
            if self.parametres {
                self.parametres = false;
                effets.signal(signaux::OUVRIR_PARAMETRES, json!({ "onglet": "apparence" }));
            }
        } else if !self.possible {
            if Self::raison_impossible(ctx).is_some() {
                return;
            }
            self.possible = true;
        } else {
            if self.vue.is_some() && self.pret && ctx.vue().page == "accueil" {
                self.appeler(effets, "vitesse", vec![json!(choix)]);
                return;
            }
            self.retirer_vue(ctx, Some("réglage Animations changé"));
            return;
        }
        self.mettre_a_jour_page(ctx, effets);
    }

    /// Le tableau commun `console` (`{ possible, parametres, en_fente }`), écrit quand il change.
    fn publier(&mut self, ctx: &Contexte) {
        let v = json!({ "possible": self.possible, "parametres": self.parametres, "en_fente": self.en_fente });
        if self.publie.as_ref() != Some(&v) {
            ctx.publier(partage::CONSOLE, v.clone());
            self.publie = Some(v);
        }
    }

    fn prochain_reveil(&self) -> Option<Duration> {
        let a = self.attente.as_ref().map(|_| self.prochaine_attente);
        let m = (self.possible || self.en_fente.is_some()).then_some(self.prochaine_minuterie);
        match (a, m) {
            (Some(a), Some(m)) => Some(a.min(m)),
            (a, m) => a.or(m),
        }
    }
}

impl Bloc for BlocConsole {
    fn nom(&self) -> &'static str {
        "console"
    }

    fn demarrer(&mut self, ctx: &Contexte, _effets: &mut Effets) {
        self.charger_theme(ctx);
        match Self::raison_impossible(ctx) {
            Some(r) => {
                self.possible = false;
                ctx.journal(&format!("Console 3D désactivée : {r} (accueil classique)"));
            }
            None => self.possible = true,
        }
        self.publier(ctx);
    }

    fn etat(&mut self, ctx: &Contexte) -> Map<String, Value> {
        let vue = ctx.vue();
        let theme = self.theme(ctx).clone();
        let (etat, maj) = if self.vue.is_some() {
            let logos = &self.logos;
            let logo = |id: &str| logos.get(id).cloned().flatten();
            (calculs::etat_applis(ctx, &theme, &logo), calculs::etat_maj(ctx, &theme))
        } else {
            (Value::Null, Value::Null)
        };
        let mut m = Map::new();
        m.insert(
            "console".into(),
            json!({
                "possible": self.possible,
                "visible": self.possible && vue.page == "accueil",
                "attente": self.vue.is_none() || !self.pret,
                "texte_attente": TEXTE_ATTENTE,
                "cadre": self.adresse_cadre(),
                "numero": self.vue,
                "fond": theme.traduire("#07060D"),
                "masquee": partage::voile(ctx),
                "parametres": self.parametres && vue.page == "accueil",
                "envoi": self.envoi,
                "etat": etat,
                "maj": maj,
            }),
        );
        m
    }

    fn action(&mut self, ctx: &Contexte, id: &str, valeur: &Value, effets: &mut Effets) -> bool {
        let pris = if id == "menu" {
            // Échap ou le bouton Menu : retour au menu en grand dans l'écran de la console
            if self.possible && ctx.vue().page != "accueil" && !partage::voile(ctx) {
                effets.ajouter(Effet::Page("accueil".into()));
            }
            true
        } else if id == "console:incident" {
            let genre = valeur.as_str().unwrap_or_default().to_string();
            self.incident(ctx, &genre, effets);
            true
        } else if let Some(type_) = id.strip_prefix("console:") {
            let vide = Map::new();
            let m = valeur.as_object().unwrap_or(&vide).clone();
            self.message(ctx, type_, &m, effets);
            true
        } else {
            false
        };
        if pris {
            self.publier(ctx);
        }
        pris
    }

    fn tic(&mut self, ctx: &Contexte, effets: &mut Effets) -> Option<Duration> {
        let maintenant = ctx.ecoule();
        // Le premier tic (la fenêtre vient de s'ouvrir) : la page d'arrivée est peut-être déjà l'accueil (console.ps1:710)
        if !self.premier_tic_fait {
            self.premier_tic_fait = true;
            self.mettre_a_jour_page(ctx, effets);
        }
        // « Actualiser » : le message d'après la recherche demandée
        if let Some(avant) = self.actualiser_avant.take() {
            let apres = ctx.lu(partage::RECHERCHE).and_then(|r| r.get("derniere").cloned());
            let t = if apres != avant { "Recherche des nouvelles versions..." } else { "Tout vient d'être vérifié" };
            self.appeler(effets, "message", vec![json!(t)]);
        }
        if self.attente.is_some() && maintenant >= self.prochaine_attente {
            self.minuterie_attente(ctx, effets);
            self.prochaine_attente = maintenant + RYTHME_ATTENTE;
        }
        if (self.possible || self.en_fente.is_some()) && maintenant >= self.prochaine_minuterie {
            self.minuterie(ctx, effets);
            let rythme = if ctx.vue().cachee() { RYTHME_CACHE } else { RYTHME };
            self.prochaine_minuterie = maintenant + rythme;
        }
        self.publier(ctx);
        self.prochain_reveil().map(|t| t.saturating_sub(maintenant))
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, donnees: &Value, effets: &mut Effets) {
        match nom {
            signaux::PAGE => {
                if texte(donnees.get("id")) == "parametres" && self.possible {
                    // Avec la console, les Paramètres s'ouvrent dans son écran (Open-ParametresConsole)
                    self.parametres = true;
                    effets.ajouter(Effet::Page("accueil".into()));
                } else {
                    self.mettre_a_jour_page(ctx, effets);
                }
            }
            signaux::FENETRE => {
                let v = ctx.vue();
                if !v.visible {
                    self.retirer_vue(ctx, Some("Mindset caché"));
                } else if v.reduite {
                    self.retirer_vue(ctx, Some("Mindset réduit"));
                } else {
                    self.reprendre_arretee(ctx);
                    if v.page == "accueil" {
                        self.mettre_a_jour_page(ctx, effets);
                    }
                }
                // (le rythme de la minuterie change tout de suite : Update-RythmeMinuteries)
                self.prochaine_minuterie = ctx.ecoule();
            }
            signaux::OUVRIR_APPLI => {
                // Ouverte sans passer par la console (menu de l'horloge, bulle) : sa cartouche va dans la fente
                if self.possible
                    && let Some(id) = donnees.get("id").and_then(Value::as_str)
                {
                    self.derniere_appli = Some(id.to_string());
                    self.en_fente = Some(id.to_string());
                }
            }
            signaux::MESSAGE_CONSOLE => {
                let v = ctx.vue();
                if v.visible && !v.reduite {
                    self.appeler(effets, "message", vec![json!(texte(donnees.get("texte")))]);
                }
            }
            signaux::ERREUR_IMPREVUE => {
                if ctx.vue().visible {
                    self.appeler(effets, "message", vec![json!("Un petit problème est survenu")]);
                }
            }
            signaux::REGLAGE_CHANGE => {
                let n = texte(donnees.get("nom"));
                if n == "Animations" {
                    self.reglage_animations(ctx, &texte(donnees.get("valeur")), effets);
                } else if n == "MajAuto" || n == "VerifVersions" {
                    self.envoi += 1;
                }
            }
            signaux::INSTALLATIONS_CHANGEES | signaux::OPERATION_FINIE | signaux::PUBLICATIONS_CHANGEES => {
                if self.vue.is_some() {
                    self.rafraichir_logos(ctx, effets);
                }
            }
            signaux::QUITTER => self.retirer_vue(ctx, None),
            _ => {}
        }
        self.publier(ctx);
    }

    fn fermer(&mut self, ctx: &Contexte) {
        self.retirer_vue(ctx, None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocConsole.nom(), "console");
    }

    #[test]
    fn espaces_comme_powershell() {
        assert_eq!(espaces("  a\n\tb  c "), " a b c ");
    }
}
