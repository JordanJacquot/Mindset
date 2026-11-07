//! Les petites règles de mindset.ps1, sans rien toucher : textes en mots simples, entrées de l'historique, heures en
//! mots, essais des mises à jour automatiques, disques proposés, jeux reconnus, manette, plein écran.
//!
//! Chaque fonction suit la version PowerShell à la lettre, jusqu'aux particularités de PowerShell : `-match` sans
//! tenir compte des majuscules, `$` qui accepte un saut de ligne final, `[string]` d'une valeur JSON, énumération des
//! membres d'un tableau, longueurs comptées en UTF-16 (`Substring`), nombres au format fr-FR (`{0:N0}`). Les juges
//! exportés depuis PowerShell (tests/juges) le vérifient.

use regex::Regex;
use serde_json::{Map, Value, json};
use std::sync::OnceLock;
use suite_commun::json_sur::HeureLocale;
use suite_commun::protocole_installateur::{texte_ps, vrai_ps};

/// L'identité de Mindset dans la barre des tâches (`$AppId`).
pub const ID_APPLI: &str = "JordanJacquot.Mindset";
/// Le commentaire de ses raccourcis (`$DescriptionRaccourciMindset`).
pub const DESCRIPTION_RACCOURCI: &str = "Mindset : toutes tes applis au même endroit";
/// Ce que Mindset envoie sur Internet (`$PageConfidentialite`).
pub const PAGE_CONFIDENTIALITE: &str = "https://github.com/JordanJacquot/Mindset/blob/main/CODE_SIGNING.md";
/// Combien d'entrées garde l'historique (`$HistoriqueMajMax`).
pub const HISTORIQUE_MAX: usize = 20;
/// Combien d'heures la dernière mise à jour reste sur la carte de la console (`$DureeDerniereMaj`).
pub const DUREE_DERNIERE_MAJ: i64 = 12;
/// La couleur de Mindset dans l'historique (`Get-AppliMaj`).
pub const COULEUR_MINDSET: &str = "#ECEAF7";
/// La couleur d'une appli inconnue de la liste (`Get-AppliMaj`).
pub const COULEUR_INCONNUE: &str = "#A9A3C9";

/// Les dossiers de jeux des lanceurs connus (`$DossiersJeux`).
pub const DOSSIERS_JEUX: &[&str] = &[
    r"\steamapps\common\",
    r"\Epic Games\",
    r"\EA Games\",
    r"\Riot Games\",
    r"\Ubisoft Game Launcher\games\",
    r"\GOG Galaxy\Games\",
    r"\XboxGames\",
    r"\Rockstar Games\",
];
/// Dans ces dossiers, les lanceurs et services qui restent ouverts en fond (`$DossiersPasJeux`).
pub const DOSSIERS_PAS_JEUX: &[&str] = &[
    r"\Epic Games\Launcher\",
    r"\Epic Games\Epic Online Services\",
    r"\Riot Games\Riot Client\",
    r"\Rockstar Games\Launcher\",
    r"\Rockstar Games\Social Club\",
    r"\steamapps\common\Steamworks Shared\",
    r"\steamapps\common\wallpaper_engine\",
];

fn expression(cellule: &'static OnceLock<Regex>, motif: &str) -> &'static Regex {
    cellule.get_or_init(|| Regex::new(motif).unwrap_or_else(|_| Regex::new("$^").unwrap_or_else(|_| unreachable!())))
}

/// Les premiers `n` caractères UTF-16 (`Substring(0, n)` de .NET) ; le texte entier s'il est plus court.
pub fn debut_utf16(texte: &str, n: usize) -> String {
    let u: Vec<u16> = texte.encode_utf16().collect();
    if u.len() <= n { texte.to_string() } else { String::from_utf16_lossy(&u[..n]) }
}

/// La longueur en caractères UTF-16 (`.Length` de .NET).
pub fn longueur_utf16(texte: &str) -> usize {
    texte.encode_utf16().count()
}

/// `.Trim()` de .NET (les espaces de Unicode, comme `char.IsWhiteSpace`).
pub fn trim_dotnet(texte: &str) -> &str {
    texte.trim_matches(|c: char| c.is_whitespace())
}

// -----------------------------------------------------------------------------------------------------------------
// Les textes des mises à jour automatiques
// -----------------------------------------------------------------------------------------------------------------

/// `Get-RaisonEchecMaj` : pourquoi une mise à jour a raté, en mots simples (le message technique reste au journal).
pub fn raison_echec_maj(nom: &str, message: &str) -> String {
    static ECHEC: OnceLock<Regex> = OnceLock::new();
    static OUVERT: OnceLock<Regex> = OnceLock::new();
    static SIGNATURE: OnceLock<Regex> = OnceLock::new();
    static MUET: OnceLock<Regex> = OnceLock::new();
    static RESEAU: OnceLock<Regex> = OnceLock::new();
    static DISQUE: OnceLock<Regex> = OnceLock::new();
    static FIN: OnceLock<Regex> = OnceLock::new();
    let sans = expression(&ECHEC, r"(?i)^\s*Échec\s*:\s*").replace(message, "");
    let m = trim_dotnet(&sans).to_string();
    if expression(&OUVERT, r"(?i)encore ouvert|fichiers sont utilisés|being used|utilisé par un autre").is_match(&m) {
        return format!("{nom} était encore ouvert et n'a pas pu être fermé.");
    }
    if expression(&SIGNATURE, r"(?i)signature").is_match(&m) {
        return "Le fichier téléchargé n'a pas passé la vérification de sécurité : rien n'a été changé.".into();
    }
    if expression(&MUET, r"(?i)ne répond pas").is_match(&m) {
        return "L'outil d'installation de Mindset n'a pas répondu.".into();
    }
    if expression(
        &RESEAU,
        r"(?i)connexion|réseau|Internet|délai|timed? ?out|résoudre|remote|distant|\b(403|404|429|500|502|503)\b",
    )
    .is_match(&m)
    {
        return "Internet a coupé pendant le téléchargement.".into();
    }
    if expression(&DISQUE, r"(?i)espace disque|disque plein|not enough space|place sur le disque").is_match(&m) {
        return "Il n'y a plus assez de place sur le disque.".into();
    }
    if m.is_empty() {
        return "Une erreur inconnue l'a arrêtée.".into();
    }
    let mut m = if longueur_utf16(&m) > 140 { format!("{}...", debut_utf16(&m, 137)) } else { m };
    if !expression(&FIN, r"[.!?]\n?\z").is_match(&m) {
        m.push('.');
    }
    m
}

/// `Format-DeNom` : « de Mindcare », « d'Evermind ».
pub fn format_de_nom(nom: &str) -> String {
    static VOYELLE: OnceLock<Regex> = OnceLock::new();
    if expression(&VOYELLE, r"(?i)^[aeiouyéèêh]").is_match(nom) { format!("d'{nom}") } else { format!("de {nom}") }
}

/// `Get-NomRaisonJeu` : ce que la console met entre parenthèses après « après ta partie ».
pub fn nom_raison_jeu(raison: &str) -> String {
    static JEU: OnceLock<Regex> = OnceLock::new();
    static PLEIN: OnceLock<Regex> = OnceLock::new();
    static MANETTE: OnceLock<Regex> = OnceLock::new();
    if let Some(c) = expression(&JEU, r"(?i)^un jeu ouvert \((.+)\)\n?\z").captures(raison) {
        return c.get(1).map_or("", |x| x.as_str()).to_string();
    }
    if expression(&PLEIN, r"(?i)plein écran").is_match(raison) {
        return "une fenêtre en plein écran".into();
    }
    if expression(&MANETTE, r"(?i)manette").is_match(raison) {
        return "manette utilisée".into();
    }
    raison.to_string()
}

/// Le titre et le texte de la bulle d'une mise à jour automatique réussie (`Complete-MajAuto`).
pub fn bulle_reussie(nom: &str, version: &str, notes: &str) -> (String, String) {
    static DEBUT: OnceLock<Regex> = OnceLock::new();
    let premiere = notes.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).find(|l| !trim_dotnet(l).is_empty());
    let resume = match premiere {
        Some(l) => trim_dotnet(&expression(&DEBUT, r"^[-*#\s]+").replace(l, "")).to_string(),
        None => String::new(),
    };
    let resume = if longueur_utf16(&resume) > 180 { format!("{}...", debut_utf16(&resume, 177)) } else { resume };
    (format!("{nom} est passé en {version}"), resume)
}

/// Le titre et le texte de la bulle d'une mise à jour automatique ratée (`Set-EchecMajAuto`) : `raison` (déjà en mots
/// simples), `reessai` (`Get-MajAutoReessai`).
pub fn bulle_ratee(nom: &str, raison: &str, reessai: Option<i64>) -> (String, String) {
    let suite = match reessai {
        Some(r) if r >= 0 => format!("Mindset réessaiera tout seul dans {r} minutes, ou clique sur Réessayer."),
        _ => "Clique sur Réessayer dans Mindset.".to_string(),
    };
    (format!("La mise à jour {} n'a pas pu se faire", format_de_nom(nom)), format!("{raison} {suite}"))
}

// -----------------------------------------------------------------------------------------------------------------
// Les essais des mises à jour automatiques
// -----------------------------------------------------------------------------------------------------------------

/// Le dernier essai automatique d'une appli (`$script:MajAutoEssais[id]`) : la version, quand (en millisecondes
/// depuis le lancement de Mindset), et combien pour cette version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Essai {
    pub version: String,
    pub quand_ms: u64,
    pub nombre: u32,
}

/// `Get-MajAutoReessai` : dans combien de minutes le prochain essai tout seul : `Some(0 et plus)` (il attend),
/// `Some(-1)` (plus d'essai tout seul : 3 déjà faits), `None` (rien ne l'empêche).
pub fn reessai(essai: Option<&Essai>, version: &str, maintenant_ms: u64) -> Option<i64> {
    let d = essai?;
    if !suite_commun::chemins::egal(&d.version, version) {
        return None;
    }
    if d.nombre >= 3 {
        return Some(-1);
    }
    let ecoule = maintenant_ms.saturating_sub(d.quand_ms) as f64 / 60_000.0;
    let reste = 15.0 - ecoule;
    if reste > 0.0 { Some(reste.ceil() as i64) } else { None }
}

/// `Add-MajAutoEssai` : l'essai suivant.
pub fn essai_suivant(avant: Option<&Essai>, version: &str, maintenant_ms: u64) -> Essai {
    let nombre = match avant {
        Some(d) if suite_commun::chemins::egal(&d.version, version) => d.nombre + 1,
        _ => 1,
    };
    Essai { version: version.to_string(), quand_ms: maintenant_ms, nombre }
}

// -----------------------------------------------------------------------------------------------------------------
// L'historique des mises à jour
// -----------------------------------------------------------------------------------------------------------------

/// Une entrée de l'historique (`ConvertTo-EntreeMaj`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entree {
    pub id: String,
    pub nom: String,
    pub version: String,
    pub quand: String,
    pub auto: bool,
    pub notes: String,
}

impl Entree {
    /// L'objet écrit dans mises-a-jour.json (mêmes champs, même ordre que la version PowerShell).
    pub fn en_json(&self) -> Value {
        json!({ "id": self.id, "nom": self.nom, "version": self.version, "quand": self.quand, "auto": self.auto,
                "notes": self.notes })
    }
}

/// `$X.<nom>` de PowerShell sur une valeur lue en JSON : un champ (sans tenir compte des majuscules), l'énumération
/// des membres sur un tableau (une valeur par élément, une seule rendue telle quelle), rien sur un texte ou un nombre.
pub fn champ_ps(x: &Value, nom: &str) -> Value {
    match x {
        Value::Object(m) => {
            m.iter().find(|(k, _)| suite_commun::chemins::egal(k, nom)).map_or(Value::Null, |(_, v)| v.clone())
        }
        Value::Array(a) => {
            let l: Vec<Value> = a.iter().map(|e| champ_ps(e, nom)).collect();
            match l.len() {
                0 => Value::Null,
                1 => l.into_iter().next().unwrap_or(Value::Null),
                _ => Value::Array(l),
            }
        }
        _ => Value::Null,
    }
}

/// `TryParseExact($t, 's', InvariantCulture, None)` : « yyyy-MM-ddTHH:mm:ss » exactement (chiffres ASCII).
pub fn lire_s(t: &str) -> Option<HeureLocale> {
    let o = t.as_bytes();
    if o.len() != 19 {
        return None;
    }
    let chiffres = |a: usize, b: usize| -> Option<u32> {
        let s = &t[a..b];
        s.bytes().all(|c| c.is_ascii_digit()).then(|| s.parse().ok())?
    };
    if o[4] != b'-' || o[7] != b'-' || o[10] != b'T' || o[13] != b':' || o[16] != b':' {
        return None;
    }
    let h = HeureLocale {
        annee: chiffres(0, 4)? as i32,
        mois: chiffres(5, 7)?,
        jour: chiffres(8, 10)?,
        heure: chiffres(11, 13)?,
        minute: chiffres(14, 16)?,
        seconde: chiffres(17, 19)?,
    };
    if h.annee < 1 {
        return None;
    }
    // (les jours et les heures possibles : lire_iso du noyau les contrôle)
    mindset_noyau::moment::lire_iso(t).filter(|x| *x == h)
}

/// `ConvertTo-EntreeMaj` : seulement des valeurs attendues, `None` sinon.
pub fn entree_maj(x: &Value) -> Option<Entree> {
    static ID: OnceLock<Regex> = OnceLock::new();
    static VERSION: OnceLock<Regex> = OnceLock::new();
    if !vrai_ps(x) {
        return None;
    }
    let id = texte_ps(&champ_ps(x, "id"));
    let version = texte_ps(&champ_ps(x, "version"));
    if !expression(&ID, r"(?i)^[a-z0-9-]{1,30}\n?\z").is_match(&id)
        || !expression(&VERSION, r"^\d+(\.\d+){1,3}\n?\z").is_match(&version)
    {
        return None;
    }
    let quand = lire_s(&texte_ps(&champ_ps(x, "quand")))?;
    let nom = debut_utf16(&texte_ps(&champ_ps(x, "nom")), 30);
    let notes = texte_ps(&champ_ps(x, "notes"));
    let notes = if longueur_utf16(&notes) > 2000 { format!("{}...", debut_utf16(&notes, 1997)) } else { notes };
    Some(Entree {
        id,
        nom,
        version,
        quand: mindset_noyau::moment::iso(&quand),
        auto: vrai_ps(&champ_ps(x, "auto")),
        notes,
    })
}

/// L'historique relu (`Read-HistoriqueMaj`) depuis l'objet du fichier : les entrées valables (20 au plus), et la mise à
/// jour de Mindset attendue.
pub fn historique_depuis(j: &Map<String, Value>) -> (Vec<Entree>, Option<Entree>) {
    let o = Value::Object(j.clone());
    let h = champ_ps(&o, "historique");
    let elements: Vec<Value> = match h {
        Value::Array(a) => a,
        autre => vec![autre],
    };
    let liste: Vec<Entree> = elements.iter().filter_map(entree_maj).take(HISTORIQUE_MAX).collect();
    let a = champ_ps(&o, "mindsetAttendu");
    let attendue = if vrai_ps(&a) { entree_maj(&a) } else { None };
    (liste, attendue)
}

/// L'objet écrit dans mises-a-jour.json (`Save-HistoriqueMaj`).
pub fn historique_en_json(liste: &[Entree], attendue: Option<&Entree>) -> Value {
    json!({ "historique": liste.iter().map(Entree::en_json).collect::<Vec<_>>(),
            "mindsetAttendu": attendue.map_or(Value::Null, Entree::en_json) })
}

/// `Get-DerniereMaj` : la première entrée si elle a moins de 12 heures (et n'est pas dans le futur).
pub fn derniere_maj<'a>(liste: &'a [Entree], maintenant: &HeureLocale) -> Option<&'a Entree> {
    let e = liste.first()?;
    let q = lire_s(&e.quand)?;
    let age = mindset_noyau::moment::ecart(&q, maintenant);
    if (0..DUREE_DERNIERE_MAJ * 3600).contains(&age) { Some(e) } else { None }
}

const MOIS: [&str; 12] = [
    "janvier",
    "février",
    "mars",
    "avril",
    "mai",
    "juin",
    "juillet",
    "août",
    "septembre",
    "octobre",
    "novembre",
    "décembre",
];

/// `Format-QuandMaj` : « à 00 h 16 », « hier à 21 h 05 », « le 18 octobre à 09 h 30 » (`long` : « aujourd'hui à 00 h
/// 16 »). `None` si le moment n'est pas au format `s`.
pub fn format_quand_maj(quand: &str, maintenant: &HeureLocale, long: bool) -> Option<String> {
    let q = lire_s(quand)?;
    let h = format!("{:02} h {:02}", q.heure, q.minute);
    let jour = |x: &HeureLocale| {
        mindset_noyau::moment::secondes(&HeureLocale { heure: 0, minute: 0, seconde: 0, ..*x }) / 86400
    };
    let jours = jour(maintenant) - jour(&q);
    Some(match jours {
        0 => format!("{}à {h}", if long { "aujourd'hui " } else { "" }),
        1 => format!("hier à {h}"),
        _ => format!("le {} {} à {h}", q.jour, MOIS[(q.mois as usize).clamp(1, 12) - 1]),
    })
}

/// `Get-AppliMaj` : l'id, le nom et la couleur d'une entrée (ceux de la liste des applis, ou de Mindset).
pub fn appli_maj(id: &str, nom: &str, liste: &[mindset_noyau::Appli]) -> (String, String, String) {
    if id == "mindset" {
        return ("mindset".into(), "Mindset".into(), COULEUR_MINDSET.into());
    }
    match liste.iter().find(|a| suite_commun::chemins::egal(&a.id, id)) {
        Some(a) => (a.id.clone(), a.nom.clone(), a.couleur.clone()),
        None => (id.to_string(), nom.to_string(), COULEUR_INCONNUE.into()),
    }
}

// -----------------------------------------------------------------------------------------------------------------
// Les disques proposés à l'installation
// -----------------------------------------------------------------------------------------------------------------

/// Un disque fixe vu par Windows (`Win32_LogicalDisk` avec `DriveType=3`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Volume {
    /// « C: »
    pub lettre: String,
    /// « NTFS », « exFAT »...
    pub systeme_fichiers: String,
    /// Octets libres (`FreeSpace`), `None` s'il n'est pas connu
    pub libre: Option<u64>,
}

/// Un disque proposé (`Get-DisquesInstallation`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Disque {
    /// « » pour le disque de Windows (Program Files), sinon sa lettre
    pub lettre: String,
    pub texte: String,
    pub libre: String,
}

/// Un nombre au format `{0:N0}` de fr-FR : arrondi loin de zéro, milliers séparés par une espace fine insécable
/// (U+202F, celle de Windows 10 et 11).
pub fn nombre_n0(x: f64) -> String {
    let r = if x.is_finite() { (x.abs() + 0.5).floor() } else { 0.0 };
    let chiffres = format!("{r:.0}");
    let mut s = String::new();
    for (i, c) in chiffres.chars().enumerate() {
        if i > 0 && (chiffres.len() - i) % 3 == 0 {
            s.push('\u{202F}');
        }
        s.push(c);
    }
    if x < 0.0 && r != 0.0 { format!("-{s}") } else { s }
}

/// `Get-DisquesInstallation` : le disque de Windows (Program Files) et les autres disques fixes NTFS, triés par lettre,
/// avec leur place libre. `systeme` : la lettre du disque de Windows (« C »).
pub fn disques(volumes: &[Volume], systeme: &str) -> Vec<Disque> {
    let mut v: Vec<&Volume> = volumes.iter().collect();
    v.sort_by_key(|x| x.lettre.to_uppercase());
    let mut r = Vec::new();
    for x in v {
        if !x.systeme_fichiers.eq_ignore_ascii_case("NTFS") {
            continue;
        }
        let l: String = x.lettre.chars().take(1).collect();
        let est_systeme = l == systeme.chars().take(1).collect::<String>();
        r.push(Disque {
            lettre: if est_systeme { String::new() } else { l.clone() },
            texte: if est_systeme {
                format!("{l}: (dans Program Files, comme les autres programmes)")
            } else {
                format!(r"{l}:\Mindset")
            },
            libre: format!("{} Go libres", nombre_n0(x.libre.unwrap_or(0) as f64 / 1_073_741_824.0)),
        });
    }
    r
}

// -----------------------------------------------------------------------------------------------------------------
// Un jeu en cours
// -----------------------------------------------------------------------------------------------------------------

fn contient_sans_casse(texte: &str, morceau: &str) -> bool {
    !morceau.is_empty() && texte.to_lowercase().contains(&morceau.to_lowercase())
}

/// `MSProcessus.JeuxOuverts` : parmi ces chemins de programmes (dans l'ordre du relevé), ceux d'un dossier de jeux
/// (sauf les lanceurs) ou ceux donnés en entier (`programmes` : les jeux ajoutés dans Nevermind), sans doublon.
pub fn jeux_ouverts(chemins: &[String], programmes: &[String]) -> Vec<String> {
    let mut r: Vec<String> = Vec::new();
    for c in chemins {
        let mut jeu = programmes.iter().any(|p| suite_commun::chemins::egal(p, c));
        if !jeu && DOSSIERS_JEUX.iter().any(|m| contient_sans_casse(c, m)) {
            jeu = !DOSSIERS_PAS_JEUX.iter().any(|m| contient_sans_casse(c, m));
        }
        if jeu && !r.contains(c) {
            r.push(c.clone());
        }
    }
    r
}

/// Les jeux ajoutés à la main dans Nevermind (`CustomGames` de son parametres.json) : leurs programmes complets
/// (`X:\...\nom.exe`), dans l'ordre (`Get-JeuxNevermind`).
pub fn jeux_nevermind(parametres: &Value) -> Vec<String> {
    static EXE: OnceLock<Regex> = OnceLock::new();
    let liste = match champ_ps(parametres, "CustomGames") {
        Value::Array(a) => a,
        Value::Null => Vec::new(),
        autre => vec![autre],
    };
    liste
        .iter()
        .filter(|j| vrai_ps(j))
        .filter_map(|j| match champ_ps(j, "Exe") {
            Value::String(s) if expression(&EXE, r"(?i)^[A-Za-z]:\\.+\.exe\n?\z").is_match(&s) => Some(s),
            _ => None,
        })
        .collect()
}

/// `MSActivite.CouvreEcran` : la fenêtre couvre tout son écran.
#[allow(clippy::too_many_arguments)]
pub fn couvre_ecran(l: i32, t: i32, r: i32, b: i32, el: i32, et: i32, er: i32, eb: i32) -> bool {
    er > el && eb > et && l <= el && t <= et && r >= er && b >= eb
}

fn axe(v: i16) -> i64 {
    let a = i32::from(v);
    if a.abs() < 8000 { 0 } else { (if a < 0 { 1 } else { 2 }) + if a.abs() >= 24000 { 2 } else { 0 } }
}

/// `MSActivite.Signature` : l'état résumé d'une manette (boutons, gâchettes enfoncées, sticks poussés au-delà d'une
/// zone morte).
pub fn signature_manette(boutons: u16, gauche: u8, droite: u8, lx: i16, ly: i16, rx: i16, ry: i16) -> i64 {
    i64::from(boutons)
        | (i64::from(gauche > 40) << 16)
        | (i64::from(droite > 40) << 17)
        | (axe(lx) << 18)
        | (axe(ly) << 21)
        | (axe(rx) << 24)
        | (axe(ry) << 27)
}

/// `MSActivite.Noter` : une manette vue. `signatures` : la dernière de chaque manette (-1 : pas vue). Vrai si c'est un
/// signe d'activité (allumée à l'instant, ou état changé).
pub fn noter_manette(signatures: &mut [i64; 4], i: i32, connectee: bool, signature: i64) -> bool {
    if !(0..=3).contains(&i) {
        return false;
    }
    let i = i as usize;
    if !connectee {
        signatures[i] = -1;
        return false;
    }
    let actif = signatures[i] != signature;
    signatures[i] = signature;
    actif
}

/// La raison d'un jeu en cours (`Get-JeuEnCours`), à partir de ce qui a été vu ; « » s'il n'y en a pas.
pub fn raison_jeu(plein_ecran: bool, secondes_manette: f64, jeu: Option<&str>) -> String {
    if plein_ecran {
        return "une fenêtre en plein écran (jeu ou vidéo)".into();
    }
    if secondes_manette < 300.0 {
        return "une manette utilisée il y a moins de 5 minutes".into();
    }
    match jeu {
        Some(n) => format!("un jeu ouvert ({n})"),
        None => String::new(),
    }
}

/// `Get-NomProgramme` (la partie sans Windows) : la description, sinon le nom de produit (40 caractères au plus,
/// sans les espaces autour), sinon le nom du fichier sans extension.
pub fn nom_programme(description: Option<&str>, produit: Option<&str>, chemin: &str) -> String {
    for n in [description, produit].into_iter().flatten() {
        let n = trim_dotnet(n);
        if !n.is_empty() && longueur_utf16(n) <= 40 {
            return n.to_string();
        }
    }
    let f = suite_commun::chemins::feuille(chemin);
    match f.rfind('.') {
        Some(i) if i > 0 => f[..i].to_string(),
        Some(_) => String::new(),
        None => f.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quelques_raisons() {
        assert_eq!(
            raison_echec_maj("Mindcare", "Échec : Mindcare est encore ouvert"),
            "Mindcare était encore ouvert et n'a pas pu être fermé."
        );
        assert_eq!(raison_echec_maj("X", "  échec: erreur 404 "), "Internet a coupé pendant le téléchargement.");
        assert_eq!(raison_echec_maj("X", "code 4040"), "code 4040.");
        assert_eq!(raison_echec_maj("X", ""), "Une erreur inconnue l'a arrêtée.");
        assert_eq!(raison_echec_maj("X", "Fini !"), "Fini !");
    }

    #[test]
    fn noms() {
        assert_eq!(format_de_nom("Evermind"), "d'Evermind");
        assert_eq!(format_de_nom("Mindcare"), "de Mindcare");
        assert_eq!(format_de_nom("Écran"), "d'Écran");
        assert_eq!(nom_raison_jeu("un jeu ouvert (Battlefield 6)"), "Battlefield 6");
    }

    #[test]
    fn nombres_fr() {
        assert_eq!(nombre_n0(1234.5), "1\u{202F}235");
        assert_eq!(nombre_n0(2.5), "3");
        assert_eq!(nombre_n0(0.0), "0");
        assert_eq!(nombre_n0(1_234_567.0), "1\u{202F}234\u{202F}567");
    }

    #[test]
    fn heures() {
        let m = mindset_noyau::moment::lire_iso("2026-11-07T20:00:00").unwrap();
        assert_eq!(format_quand_maj("2026-11-07T00:16:00", &m, false).unwrap(), "à 00 h 16");
        assert_eq!(format_quand_maj("2026-11-07T00:16:00", &m, true).unwrap(), "aujourd'hui à 00 h 16");
        assert_eq!(format_quand_maj("2026-11-06T21:05:00", &m, false).unwrap(), "hier à 21 h 05");
        assert_eq!(format_quand_maj("2026-10-18T09:30:00", &m, false).unwrap(), "le 18 octobre à 09 h 30");
        assert!(lire_s("2026-1-07T10:00:00").is_none());
        assert!(lire_s("2026-02-30T10:00:00").is_none());
    }
}
