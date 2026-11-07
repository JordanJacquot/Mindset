//! Mindset en Rust, bloc « écrans » : les écrans WPF (interface.xaml) refaits en HTML à l'identique, et ce qui leur
//! donne leur état : l'en-tête (logo animé, nom, version, mascotte), les onglets et leurs icônes, les bandeaux, l'accueil
//! classique et ses cartes, la page d'une appli (jauge, messages, écran « Ouvrir »), la zone des Paramètres, la question
//! « Êtes-vous sûr ? », la question de la croix (dessinée ici, décidée par le bloc « horloge »).
//!
//! Le HTML vit dans `mindset-appli/ui/` (index.html, coquille.*, ecrans/) ; ce bloc lui envoie sa clé `ecrans` (forme
//! ci-dessous) et reçoit ses gestes (`ecrans:*`). La page dessine aussi les clés des autres blocs (`bienvenue`,
//! `maj_mindset`, `admin_bandeau`, `parametres`, `pages_applis`, `fermeture`, `console`) et leur envoie leurs actions.
//!
//! Porté de la version PowerShell : accueil.ps1 (sauf `Invoke-Actualiser`, la recherche de `Update-InfoActualiser`, la
//! minuterie d'une heure et `Watch-ThemeSuite`), interface.ps1 (`Show-Confirmation`, `Close-Confirmation`,
//! `New-Button`, `New-Text`), le dessin de chargement.ps1 et de logo.ps1, le dessin de packs.ps1.
//!
//! La clé `ecrans` :
//! ```text
//! { version: "version 3.0.0", page, console: bool (navigation par la console : ni en-tête ni onglets),
//!   voile: bool, bonjour: "Bonsoir !", actualiser: "Vérifié à 20:00" | "Recherche automatique coupée" | "",
//!   onglets: [ { id, texte, actif, icone } ], onglets_bas: [ ... ],
//!   cartes: [ { id, couleur, elements: [ ... ] } ],          (cartes.rs : la forme des éléments)
//!   lettres: { <id>: { d, epaisseur } | { texte } },          (la lettre de chaque appli, sur une grille de 100)
//!   m: { d, epaisseur },  menu: tracé de la maison du bouton « Menu »,
//!   appli: null | { id, nom, couleur, titre, texte, installee }, (la page d'une appli quand l'accrochage n'en dit rien)
//!   confirmation: null | { titre, texte, bouton },
//!   parametres: { onglets: [ { id, texte } ], actif },
//!   theme: { id, palette: { "00E5FF": "#FF8A3D", ... }, police_titres, police_texte, pack: null | { ... } } }
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::{Duration, SystemTime};

use mindset_noyau::appli::{Appli, Installation, appli_admin};
use mindset_noyau::partage;
use mindset_noyau::signaux;
use mindset_noyau::{Bloc, Contexte, Effet, Effets};
use serde_json::{Map, Value, json};

pub mod cartes;
pub mod couleurs;
pub mod dessins;
pub mod etat_appli;
pub mod pack;
pub mod rdv;
#[cfg(windows)]
mod windows;

use cartes::{EtatCarte, Question, Suite};
use couleurs::Traducteur;
use etat_appli::Resume;

/// L'état relu toutes les 2 secondes, toutes les 30 secondes Mindset caché ou réduit (`Update-RythmeMinuteries`).
pub const RYTHME: Duration = Duration::from_secs(2);
pub const RYTHME_CACHE: Duration = Duration::from_secs(30);

/// Les onglets des Paramètres (parametres.ps1:306) ; leurs panneaux sont au bloc « paramètres ».
pub const ONGLETS_PARAMETRES: &[(&str, &str)] = &[
    ("general", "Général"),
    ("apparence", "Apparence"),
    ("son", "Son"),
    ("maj", "Mises à jour"),
    ("conso", "Consommation"),
    ("dossiers", "Dossiers"),
];

const POLICE_TITRES: &str = "Segoe UI Variable Display, Segoe UI";
const POLICE_TEXTE: &str = "Segoe UI Variable Text, Segoe UI";

static NEON: LazyLock<Traducteur> = LazyLock::new(Traducteur::default);

/// Ce qui est lu sur le disque pour une carte (relu au rythme de l'état, pas à chaque envoi).
#[derive(Debug, Clone, Default)]
struct Disque {
    /// Le résumé (etat.json), la date du fichier lu et son dossier
    resume: Option<Resume>,
    date: Option<SystemTime>,
    dossier_resume: Option<PathBuf>,
    donnees_existe: bool,
    /// La copie trouvée (et si c'est un dossier de travail)
    trouvee: Option<String>,
    travail: bool,
}

/// Le bloc « écrans ». L'hôte le crée par `BlocEcrans::default()` ([`BlocEcrans`] est son autre nom), comme les autres
/// blocs.
pub struct Ecrans {
    choix_theme: Option<String>,
    trad: Option<Traducteur>,
    pack: Value,
    disque: BTreeMap<String, Disque>,
    question: Option<Question>,
    voile_publie: Option<bool>,
    fermeture: bool,
    /// « S'ouvre avec Mindset » cliqué, en attendant que le bloc « installations » le reprenne
    interrupteurs: BTreeMap<String, bool>,
    /// Les messages de ce bloc sur une carte (le dossier choisi ne contient pas l'appli : `Stop-Operation`)
    messages: BTreeMap<String, String>,
}

/// Le nom du bloc pour l'hôte (`BlocEcrans::default()` dans `blocs()`).
pub type BlocEcrans = Ecrans;

impl Default for Ecrans {
    fn default() -> Self {
        Ecrans::VIDE
    }
}

impl std::fmt::Debug for Ecrans {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Ecrans").field("choix_theme", &self.choix_theme).field("question", &self.question).finish()
    }
}

/// `Get-DossierDonnees` : celui de la suite si l'appli est gérée et l'a déjà adopté, sinon l'ancien.
pub fn dossier_donnees(ctx: &Contexte, a: &Appli, inst: Option<&Installation>) -> PathBuf {
    let suite = ctx.dossiers.donnees_suite.join(&a.nom);
    if inst.is_some_and(|i| i.gere) && suite.is_dir() { suite } else { PathBuf::from(&a.donnees) }
}

/// `Test-DossierTravail` : une copie de travail (Git), dans ce dossier ou juste au-dessus.
pub fn dossier_travail(d: &str) -> bool {
    if d.is_empty() {
        return false;
    }
    let p = Path::new(d);
    p.join(".git").exists() || p.parent().is_some_and(|x| x.join(".git").exists())
}

/// `Test-DossierAppli` : le dossier contient-il bien l'appli (son programme, et son script ou un version.json à son
/// nom à côté de Mindset.exe) ?
pub fn dossier_appli(d: &Path, a: &Appli) -> bool {
    if a.exe.is_empty() || !d.join(&a.exe).exists() {
        return false;
    }
    if [&a.script, &a.ancien_script].iter().any(|s| !s.is_empty() && d.join(s).is_file()) {
        return true;
    }
    let j = d.join("version.json");
    if !d.join("Mindset.exe").is_file() || !j.is_file() {
        return false;
    }
    std::fs::read(&j)
        .ok()
        .and_then(|o| suite_commun::paquet::lire_version_json(&o))
        .and_then(|i| i.appli)
        .is_some_and(|x| x.eq_ignore_ascii_case(&a.id))
}

fn texte_de(v: Option<Value>) -> Option<String> {
    v.and_then(|v| v.as_str().map(str::to_string)).filter(|s| !s.is_empty())
}

/// « S'ouvre avec Mindset » : ce que dit le bloc « installations » (`demarrages`), sinon le réglage `Demarrage`
/// (`Get-DemarrageAppli`).
fn demarrage(ctx: &Contexte, id: &str) -> bool {
    if let Some(b) = ctx.lu(partage::DEMARRAGES).and_then(|d| d.get(id).and_then(Value::as_bool)) {
        return b;
    }
    match ctx.reglage("Demarrage") {
        Some(Value::Array(l)) => l.iter().any(|x| x.as_str() == Some(id)),
        Some(Value::String(s)) => s == id,
        _ => false,
    }
}

impl Ecrans {
    /// Le bloc au lancement : rien de lu.
    pub const VIDE: Ecrans = Ecrans {
        choix_theme: None,
        trad: None,
        pack: Value::Null,
        disque: BTreeMap::new(),
        question: None,
        voile_publie: None,
        fermeture: false,
        interrupteurs: BTreeMap::new(),
        messages: BTreeMap::new(),
    };

    pub fn nouveau() -> Ecrans {
        Ecrans::VIDE
    }

    fn t(&self) -> &Traducteur {
        self.trad.as_ref().unwrap_or(&NEON)
    }

    /// La question ouverte.
    pub fn question(&self) -> Option<&Question> {
        self.question.as_ref()
    }

    /// Le thème de la suite : celui que le bloc « paramètres » a publié (`theme`), sinon celui de suite.json. Relu
    /// seulement s'il change (un nouveau thème relance Mindset).
    fn suivre_theme(&mut self, ctx: &Contexte, effets: Option<&mut Effets>) {
        let publie = ctx.lu(partage::THEME);
        let choix = publie
            .as_ref()
            .and_then(|t| t.get("id").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_else(|| ctx.donnees().theme_suite());
        let table =
            publie.as_ref().and_then(|t| t.get("couleurs").and_then(Value::as_object).cloned()).unwrap_or_default();
        if self.choix_theme.as_deref() == Some(choix.as_str()) {
            if let Some(t) = self.trad.as_mut().filter(|t| t.table() != &table) {
                *t = Traducteur::nouveau(t.theme().clone(), table);
            }
            return;
        }
        let packs = ctx.dossiers.donnees.join("packs");
        let theme = suite_commun::themes::charger((!choix.is_empty()).then_some(choix.as_str()), &[packs]);
        for r in &theme.raisons {
            ctx.journal(&format!("Écrans : {r}"));
        }
        self.pack = Value::Null;
        if let Some(p) = &theme.pack {
            let nevermind = ctx.dossiers.donnees_suite.join("Nevermind").join("packs").join(&p.id);
            let v = pack::visuels(p, Some(&nevermind));
            if let (Some(chemin), Some(e)) = (v.exposer, effets) {
                e.ajouter(Effet::Exposer { nom: pack::NOM_JAUGE.into(), chemin: Some(chemin) });
            }
            self.pack = v.page;
        }
        self.trad = Some(Traducteur::nouveau(theme, table));
        self.choix_theme = Some(choix);
    }

    /// Ce qui se lit sur le disque pour les cartes (`Get-EtatAppli`, `Test-Path $Appli.Donnees`,
    /// `Test-DossierTravail`) : au rythme de l'état.
    fn relire_disque(&mut self, ctx: &Contexte) {
        let trouvees = ctx.lu(partage::TROUVEES);
        for a in ctx.applis().iter() {
            let inst = partage::installation(ctx, &a.id);
            let d = self.disque.entry(a.id.clone()).or_default();
            let dossier = dossier_donnees(ctx, a, inst.as_ref());
            if inst.as_ref().is_some_and(|i| i.gere) {
                let date = etat_appli::date_fichier(&dossier);
                if date.is_none() || date != d.date || d.dossier_resume.as_ref() != Some(&dossier) {
                    d.resume = date.and_then(|_| etat_appli::lire(&a.id, &dossier));
                    d.date = date;
                    d.dossier_resume = Some(dossier);
                }
            } else {
                d.resume = None;
                d.date = None;
                d.dossier_resume = None;
            }
            d.donnees_existe = !a.donnees.is_empty() && Path::new(&a.donnees).exists();
            let t = trouvees.as_ref().and_then(|v| v.get(&a.id)).and_then(Value::as_str).map(str::to_string);
            if t != d.trouvee {
                d.travail = t.as_deref().is_some_and(dossier_travail);
                d.trouvee = t;
            }
        }
    }

    /// `Get-EtatCarte`
    pub fn etat_carte(&self, ctx: &Contexte, a: &Appli) -> EtatCarte {
        let inst = partage::installation(ctx, &a.id);
        let pub_ = partage::publication(ctx, &a.id);
        let d = self.disque.get(&a.id).cloned().unwrap_or_default();
        let trouvee = if inst.is_some() { None } else { d.trouvee.clone() };
        let demarrage = self.interrupteurs.get(&a.id).copied().unwrap_or_else(|| demarrage(ctx, &a.id));
        EtatCarte {
            appli_admin: appli_admin(a, inst.as_ref()),
            inst,
            pub_version: pub_.as_ref().and_then(|p| texte_de(p.get("version").cloned())),
            pub_erreur: pub_.as_ref().and_then(|p| texte_de(p.get("erreur").cloned())),
            ouverte: partage::ouverte(ctx, &a.id),
            trouvee_travail: trouvee.is_some() && d.travail,
            trouvee,
            occupe: partage::occupation(ctx, &a.id).filter(|o| !o.is_empty()),
            message: self
                .messages
                .get(&a.id)
                .cloned()
                .or_else(|| ctx.lu(partage::MESSAGES).and_then(|m| texte_de(m.get(&a.id).cloned()))),
            resume: d.resume,
            donnees_existe: d.donnees_existe,
            demarrage,
            mindset_admin: ctx.lancement.admin,
        }
    }

    /// La carte d'une appli, prête pour la page : `{ id, couleur, elements }`.
    pub fn carte(&self, ctx: &Contexte, a: &Appli) -> Value {
        let e = self.etat_carte(ctx, a);
        json!({ "id": a.id, "couleur": self.t().tr(&a.couleur),
            "elements": cartes::elements(a, &e, self.t(), &ctx.heure()) })
    }

    fn icone(&self, id: &str, a: Option<&Appli>) -> Value {
        let t = self.t();
        match id {
            "accueil" => json!({ "genre": "accueil", "d": dessins::MAISON, "couleur": t.tr("#ECEAF7") }),
            "parametres" => json!({ "genre": "parametres", "d": dessins::roue(), "couleur": t.tr("#6F6894") }),
            _ => json!({ "genre": "appli", "lettre": dessins::lettre(a), "couleur": t.tr("#ECEAF7"),
                "anneau": [t.tr("#00E5FF"), t.tr("#B04BFF"), t.tr("#FF2EB5")] }),
        }
    }

    fn onglet(&self, id: &str, texte: &str, page: &str, a: Option<&Appli>) -> Value {
        json!({ "id": id, "texte": texte, "actif": id == page, "icone": self.icone(id, a) })
    }

    /// Le texte à côté d'« Actualiser » (`Update-InfoActualiser`).
    fn actualiser(&self, ctx: &Contexte) -> String {
        let auto = ctx.reglage_bool("VerifVersions", true);
        let verifie =
            ctx.lu(partage::RECHERCHE).and_then(|r| texte_de(r.get("verifie_a").cloned())).filter(|v| v.len() <= 5);
        match verifie {
            Some(h) => format!("Vérifié à {h}{}", if auto { "" } else { " (recherche automatique coupée)" }),
            None if !auto => "Recherche automatique coupée".into(),
            None => String::new(),
        }
    }

    /// Les polices de la fenêtre (`Add-PackFontXaml`, `Convert-ThemeXaml`) : celle des titres, celle du reste.
    fn polices(&self) -> (String, String) {
        let base_t = self.t().theme().police.unwrap_or(POLICE_TITRES).to_string();
        let base_x = self.t().theme().police.unwrap_or(POLICE_TEXTE).to_string();
        match self.pack.get("police").filter(|p| p.is_object()) {
            Some(p) => {
                let titres = format!("MindsetPack, {base_t}");
                let partout = p.get("partout").and_then(Value::as_bool).unwrap_or(false);
                let texte = if partout { titres.clone() } else { base_x };
                (titres, texte)
            }
            None => (base_t, base_x),
        }
    }

    /// Une question est ouverte : l'appli accrochée et la console s'effacent (`voile`, `Update-HotesVisibles`).
    fn publier_voile(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let v = self.question.is_some() || self.fermeture;
        if self.voile_publie == Some(v) {
            return;
        }
        self.voile_publie = Some(v);
        ctx.publier(partage::VOILE, json!(v));
        effets.signal(signaux::VOILE, json!({ "visible": v }));
    }

    fn poser_question(&mut self, ctx: &Contexte, q: Question, effets: &mut Effets) {
        self.question = Some(q);
        self.publier_voile(ctx, effets);
    }

    fn faire(&mut self, s: Suite, effets: &mut Effets) {
        match s {
            Suite::Signal { nom, donnees } => effets.signal(&nom, donnees),
            Suite::Action { id, valeur } => effets.ajouter(Effet::Action { id, valeur }),
        }
    }

    /// Un bouton d'une carte (`New-BoutonAction` et ses clics), aussi demandé par la console (`Effet::Action`).
    fn bouton_carte(&mut self, ctx: &Contexte, v: &Value, effets: &mut Effets) {
        let id = v.get("id").and_then(Value::as_str).unwrap_or("");
        let quoi = v.get("quoi").and_then(Value::as_str).unwrap_or("");
        let Some(a) = ctx.appli(id) else { return };
        let inst = partage::installation(ctx, id);
        let ouverte = partage::ouverte(ctx, id);
        match quoi {
            "installer" => effets.ajouter(signaux::installer(id, None, false)),
            "maj" => {
                let version =
                    partage::publication(ctx, id).and_then(|p| texte_de(p.get("version").cloned())).unwrap_or_default();
                match cartes::question_maj(&a, ouverte, &version) {
                    Ok(q) => self.poser_question(ctx, q, effets),
                    Err(s) => self.faire(s, effets),
                }
            }
            "ouvrir" => effets.ajouter(signaux::ouvrir_appli(id, true)),
            "desinstaller" => self.poser_question(ctx, cartes::question_desinstallation(&a), effets),
            "prendre" => {
                let dossier = match &inst {
                    Some(i) if !i.gere => Some(i.dossier.clone()),
                    Some(_) => None,
                    None => ctx.lu(partage::TROUVEES).and_then(|t| texte_de(t.get(id).cloned())),
                };
                if let Some(d) = dossier {
                    self.prise_en_charge(ctx, &a, &d, effets);
                }
            }
            "utiliser" => {
                if let Some(d) = ctx.lu(partage::TROUVEES).and_then(|t| texte_de(t.get(id).cloned())) {
                    effets.signal(signaux::UTILISER_TROUVEE, json!({ "id": id, "dossier": d }));
                }
            }
            "choisir" => self.choisir_dossier(ctx, &a, effets),
            "rdv" => self.ouvrir_rdv(ctx, &a, v, effets),
            _ => return,
        }
        // (une nouvelle opération : le message de ce bloc sur la carte s'efface)
        self.messages.remove(id);
    }

    fn prise_en_charge(&mut self, ctx: &Contexte, a: &Appli, dossier: &str, effets: &mut Effets) {
        let gere = ctx.dossiers.programmes.join(&a.nom);
        let q = cartes::question_prise_en_charge(
            a,
            dossier,
            &gere.to_string_lossy(),
            &ctx.dossiers.donnees_suite.to_string_lossy(),
            dossier_travail(dossier),
            partage::ouverte(ctx, &a.id),
        );
        self.poser_question(ctx, q, effets);
    }

    /// `Select-DossierAppli` : la boîte « choisir un dossier » de Windows, dans un travail de fond (jamais en essai).
    fn choisir_dossier(&mut self, ctx: &Contexte, a: &Appli, effets: &mut Effets) {
        let description = format!("Le dossier de {} (celui qui contient {})", a.nom, a.exe);
        if ctx.essai {
            ctx.journal(&format!("Écrans (essai) : la boîte « {description} » n'est pas ouverte"));
            return;
        }
        #[cfg(windows)]
        {
            let parent = ctx.fenetre_principale();
            effets.tache(&format!("choisir:{}", a.id), move || {
                Ok(windows::choisir_dossier(parent, &description).map_or(Value::Null, Value::String))
            });
        }
        #[cfg(not(windows))]
        let _ = effets;
    }

    /// `Open-RdvEvermind` : Evermind s'ouvre dans son onglet, sur la fiche de ce rendez-vous.
    fn ouvrir_rdv(&mut self, ctx: &Contexte, a: &Appli, v: &Value, effets: &mut Effets) {
        let rid = v.get("rdv").and_then(Value::as_str).unwrap_or("");
        let moment = v.get("moment").and_then(Value::as_str).unwrap_or("");
        let inst = partage::installation(ctx, &a.id);
        let d = dossier_donnees(ctx, a, inst.as_ref());
        let id_ok = rid.len() == 32 && rid.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c));
        let moment_ok =
            mindset_noyau::moment::lire_iso(moment).is_some_and(|h| mindset_noyau::moment::iso(&h) == moment);
        // (en essai, seulement dans le dossier d'essai)
        let racine = ctx.dossiers.donnees_suite.parent().unwrap_or(&ctx.dossiers.donnees_suite);
        let permis = !ctx.essai || d.starts_with(racine);
        if id_ok
            && moment_ok
            && permis
            && d.is_dir()
            && let Err(e) = std::fs::write(d.join("afficher-rdv.demande"), format!("{rid}|{moment}"))
        {
            ctx.journal(&format!("Rendez-vous d'Evermind : demande non écrite ({e})"));
        }
        effets.ajouter(signaux::ouvrir_appli(&a.id, true));
    }

    /// La page d'une appli quand le bloc « accrochage » n'en dit encore rien (`Show-AppliIntegree`, début).
    fn page_appli(&self, ctx: &Contexte, page: &str) -> Value {
        let Some(a) = ctx.appli(page) else { return Value::Null };
        let inst = partage::installation(ctx, page);
        let (titre, texte) = if inst.is_none() {
            (format!("{} n'est pas installé.", a.nom), "Installe-le depuis l'accueil.".to_string())
        } else {
            (a.nom.clone(), String::new())
        };
        json!({ "id": a.id, "nom": a.nom, "couleur": self.t().tr(&a.couleur), "titre": titre, "texte": texte,
            "installee": inst.is_some() })
    }
}

impl Bloc for Ecrans {
    fn nom(&self) -> &'static str {
        "ecrans"
    }

    fn demarrer(&mut self, ctx: &Contexte, effets: &mut Effets) {
        self.suivre_theme(ctx, Some(effets));
        self.relire_disque(ctx);
        ctx.publier(partage::VOILE, json!(false));
        self.voile_publie = Some(false);
    }

    fn etat(&mut self, ctx: &Contexte) -> Map<String, Value> {
        self.suivre_theme(ctx, None);
        let page = ctx.vue().page;
        let applis = ctx.applis();
        let mut onglets = vec![self.onglet("accueil", "Accueil", &page, None)];
        let mut l_cartes = Vec::new();
        let mut lettres = Map::new();
        for a in applis.iter() {
            onglets.push(self.onglet(&a.id, &a.nom, &page, Some(a)));
            l_cartes.push(self.carte(ctx, a));
            lettres.insert(a.id.clone(), dessins::lettre(Some(a)));
        }
        let console =
            ctx.lu(partage::CONSOLE).and_then(|c| c.get("possible").and_then(Value::as_bool)).unwrap_or(false);
        let onglet_p = ctx
            .lu(partage::ONGLET_PARAMETRES)
            .and_then(|v| v.as_str().map(str::to_string))
            .filter(|o| ONGLETS_PARAMETRES.iter().any(|(i, _)| i == o))
            .unwrap_or_else(|| "general".into());
        let (police_titres, police_texte) = self.polices();
        let t = self.t();
        let mut m = Map::new();
        m.insert(
            "ecrans".into(),
            json!({
                "version": format!("version {}", ctx.version),
                "page": page,
                "console": console,
                "voile": self.question.is_some() || self.fermeture,
                "bonjour": dessins::bonjour(ctx.heure().heure, t.theme().pack.as_ref()),
                "actualiser": self.actualiser(ctx),
                "onglets": onglets,
                "onglets_bas": [self.onglet("parametres", "Paramètres", &page, None)],
                "cartes": l_cartes,
                "lettres": lettres,
                "m": dessins::m_mindset(),
                "menu": dessins::MAISON_MENU,
                "appli": self.page_appli(ctx, &page),
                "confirmation": self.question.as_ref().map(|q| json!({ "titre": q.titre, "texte": q.texte, "bouton": q.bouton })),
                "parametres": {
                    "onglets": ONGLETS_PARAMETRES.iter().map(|(i, x)| json!({ "id": i, "texte": x })).collect::<Vec<_>>(),
                    "actif": onglet_p,
                },
                "theme": {
                    "id": t.theme().id,
                    "palette": t.palette(),
                    "police_titres": police_titres,
                    "police_texte": police_texte,
                    "pack": self.pack,
                },
            }),
        );
        m
    }

    fn action(&mut self, ctx: &Contexte, id: &str, valeur: &Value, effets: &mut Effets) -> bool {
        match id {
            "ecrans:onglet" => {
                let p = valeur.as_str().unwrap_or("");
                if p == "accueil" || p == "parametres" || ctx.appli(p).is_some() {
                    effets.ajouter(Effet::Page(p.to_string()));
                }
            }
            "ecrans:menu" => effets.ajouter(Effet::Page("accueil".into())),
            "ecrans:actualiser" => effets.ajouter(signaux::actualiser(true)),
            "ecrans:carte" => self.bouton_carte(ctx, valeur, effets),
            "ecrans:interrupteur" => {
                let a = valeur.get("id").and_then(Value::as_str).unwrap_or("");
                let oui = valeur.get("oui").and_then(Value::as_bool).unwrap_or(false);
                if ctx.appli(a).is_some() {
                    self.interrupteurs.insert(a.to_string(), oui);
                    effets.signal(signaux::DEMARRAGE_APPLI, json!({ "id": a, "oui": oui }));
                }
            }
            "ecrans:confirmation" => {
                let oui = valeur.get("oui").and_then(Value::as_bool).unwrap_or(false);
                // (Close-Confirmation, puis le « Oui »)
                if let Some(q) = self.question.take() {
                    self.publier_voile(ctx, effets);
                    if oui {
                        self.faire(q.suite, effets);
                    }
                }
            }
            "ecrans:confidentialite" => {
                let a = valeur.as_str().unwrap_or("");
                effets.signal(signaux::CONFIDENTIALITE, json!({ "id": if ctx.appli(a).is_some() { a } else { "" } }));
            }
            // (la question de la croix est montrée par la page : elle le dit, pour que l'appli accrochée s'efface)
            "ecrans:voile-fermeture" => {
                self.fermeture = valeur.get("visible").and_then(Value::as_bool).unwrap_or(false);
                self.publier_voile(ctx, effets);
            }
            _ => return false,
        }
        true
    }

    fn tic(&mut self, ctx: &Contexte, _effets: &mut Effets) -> Option<Duration> {
        let vue = ctx.vue();
        if !vue.cachee() {
            self.relire_disque(ctx);
        }
        // (le réglage repris par le bloc « installations » : l'interrupteur suit de nouveau ce qu'il dit)
        if let Some(d) = ctx.lu(partage::DEMARRAGES) {
            self.interrupteurs.retain(|id, oui| d.get(id).and_then(Value::as_bool) != Some(*oui));
        }
        Some(if vue.cachee() { RYTHME_CACHE } else { RYTHME })
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, donnees: &Value, effets: &mut Effets) {
        match nom {
            signaux::CONFIRMATION => {
                let t = |k: &str| donnees.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                let action = t("action");
                if action.is_empty() {
                    return;
                }
                let q = Question {
                    titre: t("titre"),
                    texte: t("texte"),
                    bouton: t("bouton"),
                    suite: Suite::Action { id: action, valeur: donnees.get("valeur").cloned().unwrap_or(Value::Null) },
                };
                self.poser_question(ctx, q, effets);
            }
            signaux::INSTALLATIONS_CHANGEES | signaux::OPERATION_FINIE | signaux::PUBLICATIONS_CHANGEES => {
                if let Some(id) = donnees.get("id").and_then(Value::as_str) {
                    self.messages.remove(id);
                }
                self.relire_disque(ctx);
            }
            // (Mindset réaffiché : les cartes tout de suite, Update-RythmeMinuteries)
            signaux::FENETRE if donnees.get("visible").and_then(Value::as_bool) == Some(true) => {
                self.relire_disque(ctx)
            }
            _ => {}
        }
    }

    fn tache_finie(&mut self, ctx: &Contexte, id: &str, resultat: Result<Value, String>, effets: &mut Effets) {
        let Some(appli) = id.strip_prefix("choisir:") else { return };
        let Some(a) = ctx.appli(appli) else { return };
        let choisi = match resultat {
            Ok(Value::String(d)) => d,
            Ok(_) => return,
            Err(e) => {
                ctx.journal(&format!("Choisir le dossier de {} : {e}", a.nom));
                return;
            }
        };
        if !dossier_appli(Path::new(&choisi), &a) {
            let quoi = if a.script.is_empty() { "version.json" } else { a.script.as_str() };
            let m = format!("Ce dossier ne contient pas {} ({} et {quoi}).", a.nom, a.exe);
            ctx.journal(&format!("{} : {m}", a.nom));
            self.messages.insert(a.id.clone(), m);
            return;
        }
        self.prise_en_charge(ctx, &a, &choisi, effets);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocEcrans::default().nom(), "ecrans");
    }
}
