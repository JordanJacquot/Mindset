//! Mindset en Rust, bloc « Mindset lui-même » : son installation sur le PC (bienvenue, choix du disque), ses
//! raccourcis, sa mise à jour, les mises à jour automatiques, l'historique des mises à jour, sa désinstallation, le
//! démarrage des applis avec Mindset (mindset.ps1, et le début de Mindset.ps1 : bascule administrateur,
//! « Mindset se lance avec Windows » coupé, `-Desinstaller`).
//!
//! [`avant_tout`] est appelé par l'hôte au lancement, après les dossiers et AVANT le verrou d'instance unique (comme
//! Mindset.ps1:52-75) : SA SIGNATURE NE CHANGE PAS.
//!
//! Le bloc lui-même est [`LuiMeme`] ; l'hôte le prend sous le nom [`BlocLuiMeme`] (une constante : `blocs()` écrit
//! `Box::new(mindset_lui_meme::BlocLuiMeme)`). Ce qui touche à Windows passe par [`pc::PcLuiMeme`] (le vrai :
//! `windows::PcWindows`, choisi au démarrage ; en essai et dans les tests : [`pc::FauxPc`]).
//!
//! Correspondance avec la version PowerShell (mindset.ps1, sauf mention) :
//! - `Test-MindsetInstalle`, `Test-MindsetDeveloppement`, `Get-DisquesInstallation`, `Install-Mindset`,
//!   `Copy-ReglageVerif`, `Update-RaccourcisMindset` : [`installation`] ;
//! - `Start-VerifMajMindset`, `Start-MajMindset`, `Start-MajMindsetDirecte`, `Show-ResultatMajMindset`,
//!   `Show-RestesDesinstallation` : [`maj`] ;
//! - `Invoke-MajAuto`, `Complete-MajAuto`, `Set-EchecMajAuto`, `Show-BulleMajAuto`, `Get-JeuEnCours`,
//!   `Get-JeuxNevermind`, `Get-NomProgramme`, `Test-MajAutoRecente`, `Get-MajAutoReessai`, `Add-MajAutoEssai` :
//!   [`auto`] (les règles pures : [`regles`]) ;
//! - l'historique : [`historique`] ; `Get-ApplisGerees`, `Confirm-DesinstallMindset` : [`desinstallation`] ;
//! - `Start-Demarrage`, Mindset.ps1:117-120 et 139 : [`demarrage`] ; Mindset.ps1:47-72 : [`bascule`].

use mindset_noyau::donnees::Dossiers;
use mindset_noyau::{Bloc, Contexte, Effet, Effets, Lancement, Ports, partage, signaux};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

pub mod auto;
pub mod bascule;
pub mod demarrage;
pub mod desinstallation;
pub mod historique;
pub mod installation;
pub mod maj;
pub mod pc;
pub mod regles;
#[cfg(windows)]
pub mod windows;

use pc::PcLuiMeme;
use regles::Essai;

/// Rouvert par l'Explorateur dans les 2 minutes après une bascule lancée avec Windows (décidé par [`avant_tout`]) : le
/// bloc se comporte comme lancé avec `-Demarrage`.
static DEMARRAGE_FORCE: AtomicBool = AtomicBool::new(false);

/// Ce qui se décide avant tout le reste (Mindset.ps1:41-75) : `Some(code)` pour quitter tout de suite (Mindset
/// ouvert en administrateur qui se rouvre sans les droits), `None` pour continuer.
///
/// Rien n'est fait dans la construction d'essai (`MINDSET_ESSAI_DONNEES`) : ni marque lue dans le vrai %TEMP%, ni
/// programme lancé.
pub fn avant_tout(dossiers: &Dossiers, lancement: &Lancement, ports: &Ports) -> Option<i32> {
    if std::env::var_os("MINDSET_ESSAI_DONNEES").is_some() {
        return None;
    }
    #[cfg(windows)]
    {
        let d = bascule::decider(
            dossiers,
            lancement,
            ports.systeme.as_ref(),
            &windows::BasculeWindows,
            std::time::SystemTime::now(),
        );
        if d.demarrage_force {
            DEMARRAGE_FORCE.store(true, Ordering::Relaxed);
        }
        if d.quitter {
            return Some(0);
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (dossiers, lancement, ports);
    }
    None
}

/// Lancé avec Windows pour de bon : l'argument `-Demarrage`, ou la marque de la bascule (Mindset.ps1:47-51). L'hôte
/// peut s'en servir pour savoir s'il montre la fenêtre (voir DIVERGENCES.md).
pub fn demarrage_force() -> bool {
    DEMARRAGE_FORCE.load(Ordering::Relaxed)
}

/// Le bloc tel que l'hôte le prend dans `blocs()`.
#[allow(non_upper_case_globals)]
pub const BlocLuiMeme: LuiMeme = LuiMeme::neuf();

/// Le bandeau de la mise à jour de Mindset (MajBandeau, MajTitre, MajTexte, BtnMajMindset, BtnMajFermer).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bandeau {
    pub visible: bool,
    pub titre: String,
    pub texte: String,
    pub bouton_maj: bool,
    pub bouton_fermer: &'static str,
}

/// La nouvelle version de Mindset, téléchargée et vérifiée (`$script:MajMindset`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MajPrete {
    pub version: String,
    pub zip: String,
    pub sig: String,
    pub notes: String,
}

/// Un échec de mise à jour automatique (`$script:MajAutoEchecs[id]`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Echec {
    pub version: String,
    pub raison: String,
}

/// Une opération en administrateur demandée par ce bloc (son id, rendu dans `admin-recu` et `admin-fini`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Demande {
    /// `Install-Mindset`
    Installation,
    /// `Start-MajMindset` par le mini-installateur : la version, et si elle est automatique
    Maj { version: String, auto: bool, recu: bool },
    /// La suppression du dossier de Mindset (`Confirm-DesinstallMindset`, sans désinstalleur autonome)
    Suppression,
}

/// Ce que les tests (et la construction d'essai, par les variables `MINDSET_*` de la version PowerShell) permettent
/// en essai, où la version PowerShell ne faisait rien (`$EnTest`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EnEssai {
    /// Le bandeau de bienvenue (`MINDSET_BIENVENUE`)
    pub bienvenue: bool,
    /// La recherche de la nouvelle version de Mindset (`MINDSET_MAJ_TEST`)
    pub maj: bool,
    /// Les mises à jour automatiques (`MINDSET_MAJAUTO_TEST`)
    pub maj_auto: bool,
    /// Les applis « S'ouvre avec Mindset » au lancement, les désinstalleurs
    pub lancements: bool,
}

/// Le bloc « Mindset lui-même ».
pub struct LuiMeme {
    pc: Option<Arc<dyn PcLuiMeme>>,
    /// Ce qui est permis en essai
    pub en_essai: EnEssai,
    demarre: bool,
    premier_tic: bool,
    /// Lancé avec Windows (après MajMindsetVisible et la marque de la bascule)
    demarrage: bool,
    // La bienvenue
    attente_bienvenue: bool,
    install_en_cours: bool,
    bienvenue_texte: String,
    disques: Vec<regles::Disque>,
    disque_coche: String,
    // La mise à jour de Mindset
    maj_prete: Option<MajPrete>,
    maj_en_cours: bool,
    /// La recherche attend la publication de Mindset (bloc publications), depuis ce moment (ms)
    attente_publication: Option<u64>,
    /// La dernière publication de Mindset traitée (pour ne pas la reprendre deux fois)
    publication_vue: Option<Value>,
    progres: Option<Arc<maj::ProgresMindset>>,
    bandeau: Bandeau,
    maj_envoyee: bool,
    demandes: BTreeMap<String, Demande>,
    // Les mises à jour automatiques
    maj_auto: BTreeMap<String, String>,
    essais: BTreeMap<String, Essai>,
    echecs: BTreeMap<String, Echec>,
    derniere_maj_auto: Option<u64>,
    jeu: String,
    jeu_note: Option<String>,
    attentes: BTreeMap<String, String>,
    jeux_nevermind: (String, Vec<String>),
    // La désinstallation
    desinstall_echec: Option<String>,
    desinstall_fin: Option<u64>,
    /// Ce qui a été publié la dernière fois (le tableau commun n'est réécrit que si ça change)
    publie: Option<(Value, Value)>,
}

impl Default for LuiMeme {
    fn default() -> Self {
        LuiMeme::neuf()
    }
}

/// Le texte du bandeau de bienvenue au départ (interface.xaml, BienvenueTexte).
pub const TEXTE_BIENVENUE: &str = "Mindset s'installe avec ses applis et leurs données sur le disque choisi, crée son raccourci sur le Bureau et dans le menu Démarrer, et se lance avec Windows. Tu pourras ensuite supprimer le dossier téléchargé.";
/// Ce qui part sur Internet (interface.xaml, BienvenueReseau, sans son lien).
pub const TEXTE_RESEAU: &str = "Mindset vérifie sur GitHub s'il existe une nouvelle version de lui-même et de tes applis. Rien d'autre n'est envoyé. Tu peux couper cette vérification ici, ou plus tard dans les Paramètres.";
/// Le lien de BienvenueReseau (LienReseauBienvenue).
pub const LIEN_RESEAU: &str = "En savoir plus";

impl LuiMeme {
    /// Un bloc neuf (rien n'est lu avant `demarrer`).
    pub const fn neuf() -> LuiMeme {
        LuiMeme {
            pc: None,
            en_essai: EnEssai { bienvenue: false, maj: false, maj_auto: false, lancements: false },
            demarre: false,
            premier_tic: true,
            demarrage: false,
            attente_bienvenue: false,
            install_en_cours: false,
            bienvenue_texte: String::new(),
            disques: Vec::new(),
            disque_coche: String::new(),
            maj_prete: None,
            maj_en_cours: false,
            attente_publication: None,
            publication_vue: None,
            progres: None,
            bandeau: Bandeau {
                visible: false,
                titre: String::new(),
                texte: String::new(),
                bouton_maj: true,
                bouton_fermer: "OK",
            },
            maj_envoyee: false,
            demandes: BTreeMap::new(),
            maj_auto: BTreeMap::new(),
            essais: BTreeMap::new(),
            echecs: BTreeMap::new(),
            derniere_maj_auto: None,
            jeu: String::new(),
            jeu_note: None,
            attentes: BTreeMap::new(),
            jeux_nevermind: (String::new(), Vec::new()),
            desinstall_echec: None,
            desinstall_fin: None,
            publie: None,
        }
    }

    /// Tests : ce faux Windows à la place du vrai.
    pub fn avec_pc(mut self, pc: Arc<dyn PcLuiMeme>) -> LuiMeme {
        self.pc = Some(pc);
        self
    }

    /// Tests : tout ce que la version PowerShell ne faisait pas en test est permis (avec les faux ports).
    pub fn tout_en_essai(mut self) -> LuiMeme {
        self.en_essai = EnEssai { bienvenue: false, maj: true, maj_auto: true, lancements: true };
        self
    }

    fn pc(&self) -> Arc<dyn PcLuiMeme> {
        match &self.pc {
            Some(p) => Arc::clone(p),
            None => Arc::new(pc::FauxPc::default()),
        }
    }

    /// Le temps écoulé depuis le lancement, en millisecondes.
    fn ms(ctx: &Contexte) -> u64 {
        ctx.ecoule().as_millis() as u64
    }

    /// La nouvelle version prête (tests).
    pub fn maj_prete(&self) -> Option<&MajPrete> {
        self.maj_prete.as_ref()
    }
    /// Le bandeau de la mise à jour (tests).
    pub fn bandeau(&self) -> &Bandeau {
        &self.bandeau
    }
    /// Les échecs des mises à jour automatiques (tests).
    pub fn echecs(&self) -> &BTreeMap<String, Echec> {
        &self.echecs
    }
    /// Les essais des mises à jour automatiques (tests).
    pub fn essais(&self) -> &BTreeMap<String, Essai> {
        &self.essais
    }
    /// Les mises à jour automatiques en cours (tests).
    pub fn en_cours_auto(&self) -> &BTreeMap<String, String> {
        &self.maj_auto
    }
    /// Pourquoi les mises à jour automatiques attendent (tests).
    pub fn attentes(&self) -> &BTreeMap<String, String> {
        &self.attentes
    }
    /// Le jeu en cours vu au dernier passage (tests).
    pub fn jeu(&self) -> &str {
        &self.jeu
    }
    /// La recherche de la nouvelle version tourne (tests).
    pub fn recherche_en_cours(&self) -> bool {
        self.maj_en_cours
    }
    /// Tests : une nouvelle version déjà prête.
    pub fn poser_maj_prete(&mut self, m: Option<MajPrete>) {
        self.maj_prete = m;
    }
    /// Tests : le moment du dernier passage des mises à jour automatiques oublié (il repasse tout de suite).
    pub fn oublier_passage(&mut self) {
        self.derniere_maj_auto = None;
    }
    /// Tests : le dernier passage des mises à jour automatiques, en millisecondes depuis le lancement.
    pub fn poser_passage(&mut self, ms: Option<u64>) {
        self.derniere_maj_auto = ms;
    }
    /// Tests : un essai automatique déjà fait.
    pub fn poser_essai(&mut self, id: &str, e: Essai) {
        self.essais.insert(id.to_string(), e);
    }
    /// Tests : un échec déjà connu.
    pub fn poser_echec(&mut self, id: &str, e: Echec) {
        self.echecs.insert(id.to_string(), e);
    }
    /// Tests : une mise à jour automatique en cours.
    pub fn poser_maj_auto(&mut self, id: &str, version: &str) {
        self.maj_auto.insert(id.to_string(), version.to_string());
    }
    /// Tests : la mise à jour de Mindset déjà envoyée au mini-installateur.
    pub fn poser_maj_envoyee(&mut self, oui: bool) {
        self.maj_envoyee = oui;
    }
    /// La mise à jour de Mindset est envoyée au mini-installateur et attend sa réponse (tests).
    pub fn maj_envoyee(&self) -> bool {
        self.maj_envoyee
    }
    /// Tests : le jeu déjà noté au journal.
    pub fn poser_jeu_note(&mut self, jeu: Option<&str>) {
        self.jeu_note = jeu.map(str::to_string);
    }
    /// Tests : la recherche de la nouvelle version en cours.
    pub fn poser_recherche(&mut self, oui: bool) {
        self.maj_en_cours = oui;
    }
    /// Lancé avec Windows, après MajMindsetVisible et la marque de la bascule (tests).
    pub fn demarrage(&self) -> bool {
        self.demarrage
    }
    /// Le texte du bandeau de bienvenue (tests).
    pub fn texte_bienvenue(&self) -> &str {
        &self.bienvenue_texte
    }
    /// Les disques proposés (tests).
    pub fn disques(&self) -> &[regles::Disque] {
        &self.disques
    }
    /// Tests : le bloc a démarré (sans passer par `demarrer`).
    pub fn poser_demarre(&mut self) {
        self.demarre = true;
        self.premier_tic = false;
    }

    /// `Test-MajAutoActive`
    pub fn maj_auto_active(ctx: &Contexte) -> bool {
        ctx.reglage_bool("MajAuto", true)
    }
    /// `Test-VerifVersionsActive`
    pub fn verif_active(ctx: &Contexte) -> bool {
        ctx.reglage_bool("VerifVersions", true)
    }

    /// `Set-VerifVersions`
    fn changer_verif(&mut self, ctx: &Contexte, oui: bool, effets: &mut Effets) {
        ctx.ecrire_reglage("VerifVersions", Value::Bool(oui));
        ctx.journal(&format!("Chercher les nouvelles versions tout seul : {}", if oui { "oui" } else { "non" }));
        effets.signal(signaux::REGLAGE_CHANGE, json!({ "nom": "VerifVersions", "valeur": oui }));
    }

    /// `Open-PageConfidentialite` : celle de Mindset, ou celle d'une appli de la liste.
    fn confidentialite(&self, ctx: &Contexte, id: &str, effets: &mut Effets) {
        let mut url = regles::PAGE_CONFIDENTIALITE.to_string();
        if !id.is_empty()
            && let Some(a) = ctx.appli(id)
            && !a.confidentialite.is_empty()
        {
            url = a.confidentialite.clone();
        }
        ctx.journal(&format!("Page de confidentialité ouverte : {url}"));
        effets.ajouter(Effet::OuvrirAdresse(url));
    }

    /// Un id de demande : 32 chiffres hexadécimaux (`[guid]::NewGuid().ToString('N')`).
    pub fn nouvel_id() -> String {
        use std::hash::{BuildHasher, Hasher};
        use std::sync::atomic::AtomicU64;
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
        let mut a = std::collections::hash_map::RandomState::new().build_hasher();
        a.write_u128(t);
        a.write_u64(n);
        let mut b = std::collections::hash_map::RandomState::new().build_hasher();
        b.write_u64(a.finish());
        b.write_u32(std::process::id());
        format!("{:016x}{:016x}", a.finish(), b.finish())
    }

    // -----------------------------------------------------------------------------------------------------------
    // Le tableau commun
    // -----------------------------------------------------------------------------------------------------------

    /// La clé `mindset` du tableau commun.
    pub fn valeur_mindset(&self, ctx: &Contexte) -> Value {
        let maj = if let Some(p) = &self.progres
            && self.maj_en_cours
            && !p.version().is_empty()
        {
            json!({ "version": p.version(), "notes": "", "prete": false, "progres": p.progres.part(), "en_cours": true })
        } else if let Some(m) = &self.maj_prete {
            json!({ "version": m.version, "notes": m.notes, "prete": true, "progres": null, "en_cours": self.maj_en_cours })
        } else if self.maj_en_cours {
            json!({ "version": null, "notes": "", "prete": false, "progres": null, "en_cours": true })
        } else {
            Value::Null
        };
        let h = historique::lire_sans_journal(ctx);
        let applis = ctx.applis();
        let maintenant = ctx.heure();
        let entree = |e: &regles::Entree| {
            let (id, nom, couleur) = regles::appli_maj(&e.id, &e.nom, &applis);
            json!({ "id": e.id, "nom": e.nom, "version": e.version, "quand": e.quand, "auto": e.auto, "notes": e.notes,
                "appli": { "id": id, "nom": nom, "couleur": couleur },
                "quand_texte": regles::format_quand_maj(&e.quand, &maintenant, false),
                "quand_long": regles::format_quand_maj(&e.quand, &maintenant, true) })
        };
        let derniere = regles::derniere_maj(&h.liste, &maintenant).map_or(Value::Null, entree);
        json!({
            "installe": installation::installe(ctx),
            "developpement": installation::developpement(ctx),
            "bienvenue": self.attente_bienvenue,
            "maj": maj,
            "derniere_maj": derniere,
            "historique": h.liste.iter().map(entree).collect::<Vec<_>>(),
            "verif": Self::verif_active(ctx),
            "auto": Self::maj_auto_active(ctx),
        })
    }

    /// La clé `maj-auto` du tableau commun.
    pub fn valeur_maj_auto(&self, ctx: &Contexte) -> Value {
        let maintenant = Self::ms(ctx);
        let echecs: Map<String, Value> = self
            .echecs
            .iter()
            .map(|(id, e)| {
                let r = regles::reessai(self.essais.get(id), &e.version, maintenant);
                (id.clone(), json!({ "version": e.version, "raison": e.raison, "reessai": r }))
            })
            .collect();
        let essais: Map<String, Value> = self
            .essais
            .iter()
            .map(|(id, e)| {
                let r = regles::reessai(Some(e), &e.version, maintenant);
                (id.clone(), json!({ "version": e.version, "nombre": e.nombre, "reessai": r }))
            })
            .collect();
        json!({ "en_cours": self.maj_auto, "echecs": echecs, "jeu": self.jeu, "jeu_nom": regles::nom_raison_jeu(&self.jeu),
            "attentes": self.attentes, "essais": essais })
    }

    /// Réécrit le tableau commun si ce bloc a changé quelque chose.
    fn publier(&mut self, ctx: &Contexte) {
        let m = self.valeur_mindset(ctx);
        let a = self.valeur_maj_auto(ctx);
        if self.publie.as_ref().is_some_and(|(x, y)| *x == m && *y == a) {
            return;
        }
        ctx.publier(partage::MINDSET, m.clone());
        ctx.publier(partage::MAJ_AUTO, a.clone());
        self.publie = Some((m, a));
    }

    /// L'état `bienvenue` de la page.
    pub fn etat_bienvenue(&self, ctx: &Contexte) -> Value {
        json!({
            "visible": self.attente_bienvenue,
            "texte": self.bienvenue_texte,
            "reseau": TEXTE_RESEAU,
            "lien_reseau": LIEN_RESEAU,
            "verif": Self::verif_active(ctx),
            "disques": self.disques.iter().map(|d| json!({ "lettre": d.lettre, "texte": d.texte, "libre": d.libre,
                "coche": d.lettre == self.disque_coche })).collect::<Vec<_>>(),
            "en_cours": self.install_en_cours,
        })
    }

    /// L'état `maj_mindset` de la page.
    pub fn etat_maj(&self) -> Value {
        json!({
            "visible": self.bandeau.visible,
            "titre": self.bandeau.titre,
            "texte": self.bandeau.texte,
            "bouton_maj": self.bandeau.bouton_maj,
            "bouton_fermer": self.bandeau.bouton_fermer,
        })
    }
}

/// Les actions de la page prises par ce bloc, et celles qu'il se renvoie (le « Oui » de ses questions).
pub mod actions {
    pub const INSTALLER: &str = "lui-meme:installer";
    pub const PLUS_TARD: &str = "lui-meme:plus-tard";
    pub const VERIF: &str = "lui-meme:verif";
    pub const MAJ: &str = "lui-meme:maj";
    pub const MAJ_FERMER: &str = "lui-meme:maj-fermer";
    pub const CONFIDENTIALITE: &str = "lui-meme:confidentialite";
    pub const MAJ_OUI: &str = "lui-meme:maj-oui";
    pub const DESINSTALLER_CONTINUER: &str = "lui-meme:desinstaller-continuer";
    pub const DESINSTALLER_OUI: &str = "lui-meme:desinstaller-oui";
    pub const DESINSTALLER_REESSAYER: &str = "lui-meme:desinstaller-reessayer";
    pub const ALLER_ACCUEIL: &str = "lui-meme:aller-accueil";
}

impl Bloc for LuiMeme {
    fn nom(&self) -> &'static str {
        "lui-meme"
    }

    fn demarrer(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if self.pc.is_none() {
            self.pc = Some(if ctx.essai {
                self.en_essai.bienvenue |= std::env::var_os("MINDSET_BIENVENUE").is_some();
                self.en_essai.maj |= std::env::var_os("MINDSET_MAJ_TEST").is_some();
                self.en_essai.maj_auto |= std::env::var_os("MINDSET_MAJAUTO_TEST").is_some();
                Arc::new(pc::FauxPc::sous(&ctx.dossiers.donnees.join("essai-windows")))
            } else {
                #[cfg(windows)]
                {
                    Arc::new(windows::PcWindows)
                }
                #[cfg(not(windows))]
                {
                    Arc::new(pc::FauxPc::default())
                }
            });
        }
        self.demarre = true;
        if !self.demarrer_lancement(ctx, effets) {
            return;
        }
        self.demarrer_installation(ctx, effets);
        self.resultat_maj(ctx);
        self.publier(ctx);
    }

    fn etat(&mut self, ctx: &Contexte) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("bienvenue".into(), self.etat_bienvenue(ctx));
        m.insert("maj_mindset".into(), self.etat_maj());
        m
    }

    fn action(&mut self, ctx: &Contexte, id: &str, valeur: &Value, effets: &mut Effets) -> bool {
        match id {
            actions::INSTALLER => {
                let d = valeur.get("disque").and_then(Value::as_str).unwrap_or("");
                self.installer(ctx, d, effets);
            }
            actions::PLUS_TARD => self.attente_bienvenue = false,
            actions::VERIF => {
                let oui = valeur
                    .get("oui")
                    .map_or(valeur.as_bool().unwrap_or(false), suite_commun::protocole_installateur::vrai_ps);
                self.changer_verif(ctx, oui, effets);
            }
            actions::MAJ | actions::MAJ_OUI => self.lancer_maj(ctx, false, false, effets),
            actions::MAJ_FERMER => self.bandeau.visible = false,
            actions::CONFIDENTIALITE => self.confidentialite(ctx, valeur.as_str().unwrap_or(""), effets),
            actions::DESINSTALLER_CONTINUER => self.lancer_desinstalleur(ctx, effets),
            actions::DESINSTALLER_OUI => self.desinstaller_sans_desinstalleur(ctx, effets),
            actions::DESINSTALLER_REESSAYER => self.confirmer_desinstallation(ctx, effets),
            actions::ALLER_ACCUEIL => effets.ajouter(Effet::Page("accueil".into())),
            _ => return false,
        }
        self.publier(ctx);
        true
    }

    fn tic(&mut self, ctx: &Contexte, effets: &mut Effets) -> Option<Duration> {
        if !self.demarre {
            return None;
        }
        if self.premier_tic {
            self.premier_tic = false;
            self.lancer_demarrage(ctx, effets);
            if ctx.lancement.desinstaller {
                effets.ajouter(Effet::Page("parametres".into()));
                self.confirmer_desinstallation(ctx, effets);
            }
        }
        self.suivre_desinstallation(ctx, effets);
        self.suivre_recherche(ctx);
        self.passer_maj_auto(ctx, effets);
        self.publier(ctx);
        Some(if ctx.vue().cachee() { Duration::from_secs(30) } else { Duration::from_secs(2) })
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, donnees: &Value, effets: &mut Effets) {
        let texte = |k: &str| donnees.get(k).map(suite_commun::protocole_installateur::texte_ps).unwrap_or_default();
        match nom {
            signaux::VERIFIER_MINDSET => self.verifier_maj(ctx, effets),
            signaux::PUBLICATIONS_CHANGEES => self.publication_recue(ctx, effets),
            signaux::MAJ_MINDSET => {
                if donnees.get("confirmer").is_some_and(suite_commun::protocole_installateur::vrai_ps) {
                    self.confirmer_maj(effets);
                } else {
                    self.lancer_maj(ctx, false, false, effets);
                }
            }
            signaux::DESINSTALLER_MINDSET => self.confirmer_desinstallation(ctx, effets),
            signaux::CONFIDENTIALITE => self.confidentialite(ctx, &texte("id"), effets),
            signaux::OPERATION_FINIE => self.operation_finie(ctx, donnees, effets),
            signaux::INSTALLER => {
                // « Réessayer » sur une carte (pas une mise à jour automatique) : l'échec n'est plus montré
                let id = texte("id");
                if !self.maj_auto.contains_key(&id) {
                    self.echecs.remove(&id);
                }
            }
            signaux::ADMIN_RECU => {
                let direct = donnees.get("direct").is_some_and(suite_commun::protocole_installateur::vrai_ps);
                self.admin_recu(ctx, &texte("id"), direct, effets);
            }
            signaux::ADMIN_FINI => {
                let ok = donnees.get("ok").is_some_and(suite_commun::protocole_installateur::vrai_ps);
                self.admin_fini(ctx, &texte("id"), ok, &texte("message"), donnees, effets);
            }
            _ => {}
        }
        self.publier(ctx);
    }

    fn tache_finie(&mut self, ctx: &Contexte, id: &str, resultat: Result<Value, String>, effets: &mut Effets) {
        match id {
            maj::TACHE_VERIF => self.verif_finie(ctx, resultat),
            installation::TACHE_DEBLOQUER => {}
            _ => {}
        }
        let _ = effets;
        self.publier(ctx);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        assert_eq!(BlocLuiMeme.nom(), "lui-meme");
        assert_eq!(LuiMeme::nouvel_id().len(), 32);
        assert_ne!(LuiMeme::nouvel_id(), LuiMeme::nouvel_id());
    }
}
