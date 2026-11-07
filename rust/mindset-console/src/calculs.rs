//! Ce que la console calcule sans rien toucher : l'état des applis envoyé à la scène (`Get-EtatConsole`), la carte des
//! mises à jour (`Get-EtatMajConsole`), les couleurs et les images du thème (`Get-CouleursConsole`,
//! `Get-ThemeConsole`), l'avancée de la barre d'ouverture (`Get-AvanceeOuverture`), la réaction à un incident
//! (`Get-ReactionIncidentConsole`), et les petites règles d'autres modules dont la console a besoin
//! (`Get-PhraseReseauAppli`, `Format-QuandMaj`, `Get-NomRaisonJeu`, `Get-MajAutoReessai`, `[uri]::EscapeDataString`).
//!
//! Tout se lit dans le tableau commun et les réglages (voir `mindset_noyau::partage`) : les variables `$script:` de
//! la version PowerShell y ont leur équivalent (`$script:Occupe` et `$script:Progres` : `occupations` ;
//! `$script:MajAuto`, `$script:MajAutoEchecs`, `$script:MajAutoEssais`, `$script:MajAutoJeu`,
//! `$script:MajAutoAttentes` : `maj-auto` ; `$script:MajMindset`, `$script:MajMindsetEnCours`,
//! `$script:ProgresMindset` : `mindset.maj` ; `$script:Recherches`, `$script:RechercheDepuis` : `recherche`).

use mindset_noyau::appli::Appli;
use mindset_noyau::moment::{self, HeureLocale};
use mindset_noyau::{Contexte, partage};
use serde_json::{Map, Value, json};
use suite_commun::themes::{Pack, Theme};
use suite_commun::version::plus_recente;

/// La couleur de Mindset dans la carte des mises à jour (`Get-AppliMaj 'mindset'`).
pub const COULEUR_MINDSET: &str = "#ECEAF7";
/// La couleur d'une appli qui n'est plus dans la liste (`Get-AppliMaj`).
pub const COULEUR_INCONNUE: &str = "#A9A3C9";
/// La deuxième couleur des cartouches (`c2` de `Get-EtatConsole`).
pub const COULEUR_C2: &str = "#B04BFF";
/// La dernière mise à jour reste sur la carte pendant ces heures (`$DureeDerniereMaj`, mindset.ps1:569).
pub const DUREE_DERNIERE_MAJ: i64 = 12;
/// Les durées d'ouverture par défaut (`$script:JaugeDureesDefaut`, chargement.ps1:12).
pub const DUREES_DEFAUT: &[(&str, f64)] = &[("nevermind", 20.0), ("evermind", 10.0)];

/// `[math]::Round($x, n)` de .NET : l'arrondi « au pair » (0,0005 donne 0 ; 0,0015 donne 0,002).
pub fn arrondi(x: f64, chiffres: i32) -> f64 {
    let p = 10f64.powi(chiffres);
    (x * p).round_ties_even() / p
}

/// `[uri]::EscapeDataString` de .NET Framework (Windows PowerShell 5.1) : tout est échappé (en UTF-8, `%XX` en
/// majuscules) sauf les lettres et chiffres ASCII et `- _ . ~ ! * ' ( )` (vérifié : `!*'()~` restent tels quels).
pub fn echapper(t: &str) -> String {
    let mut s = String::with_capacity(t.len());
    for o in t.bytes() {
        if o.is_ascii_alphanumeric() || b"-_.~!*'()".contains(&o) {
            s.push(o as char);
        } else {
            s.push_str(&format!("%{o:02X}"));
        }
    }
    s
}

/// `ConvertTo-Json -Compress` d'une valeur (la console met ces textes dans l'adresse de la scène).
pub fn json_compact(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_default()
}

/// `[bool]` de PowerShell sur une valeur JSON.
fn vrai(v: Option<&Value>) -> bool {
    v.is_some_and(suite_commun::protocole_installateur::vrai_ps)
}

/// `[string]` de PowerShell sur une valeur JSON (`$null` : « »).
fn texte(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(v) => suite_commun::protocole_installateur::texte_ps(v),
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Les petites règles d'autres modules
// ---------------------------------------------------------------------------------------------------------------

/// `Get-PhraseReseauAppli` (accueil.ps1:423) : ce qui part sur Internet quand Mindset installe l'appli.
pub fn phrase_reseau(a: &Appli) -> String {
    let mut t = format!(
        "{} se télécharge depuis GitHub. Ensuite, Mindset vérifie sur GitHub s'il en existe une nouvelle version. Rien d'autre n'est envoyé par Mindset, et tu peux couper cette vérification dans les Paramètres.",
        a.nom
    );
    if !a.confidentialite.is_empty() {
        t.push_str(&format!(" Ce que {} envoie lui-même sur Internet est expliqué sur sa page.", a.nom));
    }
    t
}

/// `Get-LienReseauAppli` (accueil.ps1:428).
pub fn lien_reseau(a: &Appli) -> String {
    if a.confidentialite.is_empty() { "Ce qui part sur Internet".into() } else { format!("La page de {}", a.nom) }
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

/// `Format-QuandMaj` (mindset.ps1:640) : « à 00 h 16 », « hier à 21 h 05 », « le 18 octobre à 09 h 30 ». `None` si
/// `quand` n'est pas au format `s` (PowerShell lève alors une erreur).
pub fn quand_maj(quand: &str, maintenant: &HeureLocale) -> Option<String> {
    let q = lire_s(quand)?;
    let h = format!("à {:02} h {:02}", q.heure, q.minute);
    let jours = moment::ecart(&jour_seul(&q), &jour_seul(maintenant)) / 86400;
    Some(match jours {
        0 => h,
        1 => format!("hier {h}"),
        _ => format!("le {} {} {h}", q.jour, MOIS[(q.mois as usize).clamp(1, 12) - 1]),
    })
}

fn jour_seul(h: &HeureLocale) -> HeureLocale {
    HeureLocale { heure: 0, minute: 0, seconde: 0, ..*h }
}

/// `[datetime]::ParseExact($t, 's', ...)` : exactement « aaaa-mm-jjThh:mm:ss ».
pub fn lire_s(t: &str) -> Option<HeureLocale> {
    let o = t.as_bytes();
    let forme = o.len() == 19
        && o.iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            10 => *c == b'T',
            13 | 16 => *c == b':',
            _ => c.is_ascii_digit(),
        });
    if forme { moment::lire_iso(t) } else { None }
}

/// `Get-NomRaisonJeu` (mindset.ps1:451) : ce que la console met entre parenthèses après « après ta partie ».
pub fn nom_raison_jeu(raison: &str) -> String {
    // (`-match` : sans les majuscules)
    const DEBUT: &str = "un jeu ouvert (";
    if let Some(debut) = raison.get(..DEBUT.len())
        && debut.eq_ignore_ascii_case(DEBUT)
        && let Some(nom) = raison[DEBUT.len()..].strip_suffix(')')
        && !nom.is_empty()
    {
        return nom.to_string();
    }
    let bas = raison.to_lowercase();
    if bas.contains("plein écran") {
        return "une fenêtre en plein écran".into();
    }
    if bas.contains("manette") {
        return "manette utilisée".into();
    }
    raison.to_string()
}

/// `Get-MajAutoReessai` (mindset.ps1:387) : dans combien de minutes le prochain essai tout seul (0 et plus), -1 (plus
/// d'essai tout seul : 3 déjà faits), `None` (rien ne l'empêche). `essai` : `maj-auto.essais[id]`
/// (`{ version, quand, nombre }`, `$script:MajAutoEssais`).
pub fn maj_auto_reessai(essai: Option<&Value>, version: &str, maintenant: &HeureLocale) -> Option<i64> {
    let d = essai?;
    if texte(d.get("version")) != version {
        return None;
    }
    if d.get("nombre").and_then(Value::as_f64).unwrap_or(0.0) >= 3.0 {
        return Some(-1);
    }
    let quand = moment::lire_iso(d.get("quand")?.as_str()?)?;
    let reste = 15.0 - moment::ecart(&quand, maintenant) as f64 / 60.0;
    (reste > 0.0).then(|| reste.ceil() as i64)
}

/// `Get-AvanceeOuverture` (console.ps1:596) : l'avancée de la barre d'ouverture après `ecoule` secondes, quand
/// l'ouverture dure `duree` secondes d'habitude (90 % à cette durée, puis vers 99 %).
pub fn avancee_ouverture(duree: f64, ecoule: f64) -> f64 {
    let k = (ecoule / duree).max(0.0);
    let v = if k < 1.0 { 0.9 * (1.0 - (1.0 - k).powi(2)) } else { 0.9 + 0.09 * (1.0 - (-(k - 1.0)).exp()) };
    arrondi(v, 3)
}

/// La durée d'ouverture attendue d'une appli (`Get-AvanceeOuverture`) : celle retenue (`Ouverture-<id>`), sinon
/// celle par défaut, sinon 8 s (et 8 s si elle vaut moins de 1 s).
pub fn duree_attendue(ctx: &Contexte, id: &str) -> f64 {
    let defaut = DUREES_DEFAUT.iter().find(|(i, _)| *i == id).map(|(_, d)| *d);
    let d = match ctx.reglage(&format!("Ouverture-{id}")) {
        Some(v) => suite_commun::protocole_installateur::texte_ps(&v).trim().parse::<f64>().unwrap_or(0.0),
        None => defaut.unwrap_or(0.0),
    };
    if d >= 1.0 { d } else { 8.0 }
}

/// `Get-ReactionIncidentConsole` (console.ps1:248) : « recreer » (le processus principal ou celui de la page s'est
/// arrêté) ou « continuer » (un autre, que WebView2 relance tout seul).
pub fn reaction_incident(genre: &str) -> &'static str {
    if ["BrowserProcessExited", "RenderProcessExited", "RenderProcessUnresponsive"]
        .iter()
        .any(|g| g.eq_ignore_ascii_case(genre))
    {
        "recreer"
    } else {
        "continuer"
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Le thème
// ---------------------------------------------------------------------------------------------------------------

/// `Get-CouleursConsole` (console.ps1:155) : chaque couleur « #RRGGBB » écrite dans scene.html, traduite dans le
/// thème, seulement celles qui changent, dans l'ordre où elles apparaissent (`{ "00E5FF": "#FF8A3D" }`).
pub fn couleurs_console(html: &str, theme: &Theme) -> Map<String, Value> {
    let mut t = Map::new();
    let o = html.as_bytes();
    let mot = |c: u8| c.is_ascii_alphanumeric() || c == b'_';
    for i in 0..o.len() {
        if o[i] != b'#' || i + 7 > o.len() || !o[i + 1..i + 7].iter().all(u8::is_ascii_hexdigit) {
            continue;
        }
        // (`\b` après les 6 chiffres : la fin du texte, ou autre chose qu'une lettre, un chiffre ou « _ »)
        if i + 7 < o.len() && mot(o[i + 7]) {
            continue;
        }
        let h = html[i + 1..i + 7].to_ascii_uppercase();
        let v = theme.traduire(&format!("#{h}")).to_uppercase();
        if !v.eq_ignore_ascii_case(&format!("#{h}")) && !t.contains_key(&h) {
            t.insert(h, Value::String(v));
        }
    }
    t
}

/// L'adresse d'un fichier du pack pour la scène (`https://theme.mindset.local/<nom>` de la version PowerShell).
pub fn adresse_pack(fichier: &str) -> String {
    format!("http://pack.localhost/{}", echapper(fichier))
}

/// `Get-ThemeConsole` (console.ps1:166) : les images et la police du thème perso, seulement s'il a un bloc
/// « Console » ; `None` sinon. `animee` : `Test-ImageAnimee` sur un chemin.
pub fn theme_console(pack: Option<&Pack>, animee: &mut dyn FnMut(&std::path::Path) -> bool) -> Option<Value> {
    let p = pack?;
    let c = p.console.as_ref()?;
    let url = |i: Option<&suite_commun::themes::Image>| i.map(|i| adresse_pack(&i.fichier)).unwrap_or_default();
    let logo = if c.logo.is_some() {
        url(c.logo.as_ref())
    } else if let Some(l) = p.logo.as_ref().filter(|l| l.images <= 1) {
        url(Some(&l.image))
    } else {
        String::new()
    };
    Some(json!({
        "fond": url(c.fond.as_ref()),
        "opacite": c.fond_opacite,
        "mascotte": url(c.mascotte.as_ref()),
        "mascotteAnimee": c.mascotte.as_ref().is_some_and(|m| animee(&m.chemin)),
        "chargement": url(c.chargement.as_ref().map(|x| &x.image)),
        "effet": c.chargement.as_ref().map(|x| if x.tourne { "tourne" } else { "aucun" }).unwrap_or(""),
        "logo": logo,
        "police": url(p.police.as_ref().map(|x| &x.fichier)),
    }))
}

// ---------------------------------------------------------------------------------------------------------------
// L'état des applis (Get-EtatConsole)
// ---------------------------------------------------------------------------------------------------------------

/// `Get-EtatCarte` (accueil.ps1:299), la partie dont la console se sert.
pub struct EtatCarte {
    pub installee: bool,
    pub gere: bool,
    pub version_installee: Option<String>,
    pub publication: Option<Value>,
    pub ouverte: bool,
    /// `$script:Occupe[id]` (non vide)
    pub occupe: bool,
    /// `occupations[id]` tel quel
    pub occupation: Option<Value>,
    pub maj_dispo: bool,
}

pub fn etat_carte(ctx: &Contexte, a: &Appli) -> EtatCarte {
    let inst = partage::installation(ctx, &a.id);
    let publication = partage::publication(ctx, &a.id);
    let occupation = ctx.lu(partage::OCCUPATIONS).and_then(|o| o.get(&a.id).cloned());
    let occupe = occupation.as_ref().is_some_and(|o| !texte(o.get("texte")).is_empty());
    let version_pub = publication.as_ref().map(|p| texte(p.get("version"))).unwrap_or_default();
    let maj_dispo = inst.as_ref().is_some_and(|i| {
        i.gere && !version_pub.is_empty() && plus_recente(&version_pub, i.version.as_deref().unwrap_or(""))
    });
    EtatCarte {
        installee: inst.is_some(),
        gere: inst.as_ref().is_some_and(|i| i.gere),
        version_installee: inst.and_then(|i| i.version),
        publication,
        ouverte: partage::ouverte(ctx, &a.id),
        occupe,
        occupation,
        maj_dispo,
    }
}

/// Le progrès d'un téléchargement (`$script:Progres[id]`), `None` s'il n'y en a pas.
fn progres(occupation: Option<&Value>) -> Option<f64> {
    occupation?.get("progres")?.as_f64()
}

/// `Get-EtatConsole` (console.ps1:336). `logo` : le logo de chaque appli (`Get-LogoConsole`, calculé à part).
pub fn etat_applis(ctx: &Contexte, theme: &Theme, logo: &dyn Fn(&str) -> Option<String>) -> Value {
    let mut liste = Vec::new();
    for a in ctx.applis().iter() {
        let e = etat_carte(ctx, a);
        let maj = if e.occupe {
            match progres(e.occupation.as_ref()) {
                Some(p) => json!({ "etat": "telechargement", "progres": arrondi(p, 3) }),
                None => json!({ "etat": "installation", "progres": 1 }),
            }
        } else if e.maj_dispo {
            json!({ "etat": "dispo", "progres": 0 })
        } else {
            Value::Null
        };
        liste.push(json!({
            "id": a.id,
            "nom": a.nom,
            "c1": theme.traduire(&a.couleur),
            "c2": theme.traduire(COULEUR_C2),
            "logo": logo(&a.id),
            "installee": e.installee,
            "desc": if a.presentation.is_empty() { &a.description } else { &a.presentation },
            "reseau": if e.installee { String::new() } else { phrase_reseau(a) },
            "lien": if e.installee { String::new() } else { lien_reseau(a) },
            "etat": if e.ouverte { "fond" } else { "ferme" },
            "maj": maj,
        }));
    }
    json!({ "applis": liste })
}

// ---------------------------------------------------------------------------------------------------------------
// La carte des mises à jour (Get-EtatMajConsole)
// ---------------------------------------------------------------------------------------------------------------

fn infos(theme: &Theme, id: &str, nom: &str, couleur: &str, version: &str) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("id".into(), json!(id));
    m.insert("nom".into(), json!(nom));
    m.insert("c".into(), json!(theme.traduire(couleur)));
    m.insert("version".into(), json!(version));
    m
}

/// `Test-TacheInstallation` (installations.ps1:268) : la tâche du mini-installateur est-elle celle du système ?
fn tache_installation(ctx: &Contexte) -> bool {
    ctx.lu(partage::ADMIN).and_then(|a| a.get("tache").and_then(Value::as_str).map(|t| t == "systeme")).unwrap_or(false)
}

/// `Get-EtatMajConsole` (console.ps1:400).
pub fn etat_maj(ctx: &Contexte, theme: &Theme) -> Value {
    let maintenant = ctx.heure();
    let verif = ctx.reglage_bool("VerifVersions", true);
    let auto = ctx.reglage_bool("MajAuto", true);
    let auto_possible = auto && verif && !ctx.lancement.admin && tache_installation(ctx);
    let applis = ctx.applis();
    let maj_auto = ctx.lu(partage::MAJ_AUTO).unwrap_or(Value::Null);
    let mindset = ctx.lu(partage::MINDSET).unwrap_or(Value::Null);
    let maj_mindset = mindset.get("maj").filter(|m| m.is_object());
    let mindset_en_cours = maj_mindset.is_some_and(|m| vrai(m.get("en_cours")));
    let progres_mindset = maj_mindset.and_then(|m| m.get("progres").and_then(Value::as_f64));
    let mut phase = "";
    let mut appli = Value::Null;
    let mut progres_v = 0.0;
    let mut raison = String::new();
    let mut en_auto = false;
    let mut jeu = String::new();
    let mut echec = String::new();
    let mut reessai: Option<i64> = None;

    // 1. Ce qui se télécharge ou s'installe (pas une désinstallation)
    let cartes: Vec<(&Appli, EtatCarte)> = applis.iter().map(|a| (a, etat_carte(ctx, a))).collect();
    let en_installation = |e: &EtatCarte| texte(e.occupation.as_ref().and_then(|o| o.get("quoi"))) == "installation";
    let occupees: Vec<&(&Appli, EtatCarte)> = cartes
        .iter()
        .filter(|(_, e)| e.occupe && (progres(e.occupation.as_ref()).is_some() || en_installation(e)))
        .collect();
    let choisie =
        occupees.iter().find(|(_, e)| progres(e.occupation.as_ref()).is_some()).or_else(|| occupees.first()).copied();
    if let Some((a, e)) = choisie {
        let pr = progres(e.occupation.as_ref());
        let version_en_cours = if pr.is_none() && en_installation(e) {
            texte(e.occupation.as_ref().and_then(|o| o.get("version")))
        } else {
            String::new()
        };
        let version_pub = e.publication.as_ref().map(|p| texte(p.get("version"))).unwrap_or_default();
        let en_cours_auto = maj_auto.get("en_cours").and_then(|m| m.get(&a.id));
        let v = if !version_en_cours.is_empty() {
            version_en_cours
        } else if !version_pub.is_empty() {
            version_pub
        } else {
            texte(en_cours_auto)
        };
        appli = Value::Object(infos(theme, &a.id, &a.nom, &a.couleur, &v));
        en_auto = vrai(en_cours_auto);
        match pr {
            Some(p) => {
                phase = "telechargement";
                progres_v = p.min(1.0);
            }
            None => {
                phase = "installation";
                progres_v = 1.0;
            }
        }
    } else if mindset_en_cours
        && let Some(p) = progres_mindset
        && let Some(v) = maj_mindset.map(|m| texte(m.get("version"))).filter(|v| !v.is_empty())
    {
        // Mindset lui-même : sa nouvelle version se télécharge
        appli = Value::Object(infos(theme, "mindset", "Mindset", COULEUR_MINDSET, &v));
        phase = "telechargement";
        progres_v = p.min(1.0);
    }

    // 2. Une recherche en cours (au moins 2 secondes)
    if phase.is_empty() {
        let recherche = ctx.lu(partage::RECHERCHE).unwrap_or(Value::Null);
        let en_recherche = recherche.get("en_cours").and_then(Value::as_array).is_some_and(|l| !l.is_empty())
            || (mindset_en_cours && progres_mindset.is_none());
        let recente = recherche
            .get("depuis")
            .and_then(Value::as_str)
            .and_then(moment::lire_iso)
            .is_some_and(|d| moment::ecart(&d, &maintenant) < 2);
        if en_recherche || recente {
            phase = "recherche";
        }
    }

    // 3. Une version disponible : prête (à toi de lancer) ou en attente (elle se fera toute seule)
    if phase.is_empty() {
        let mut dispo: Vec<(String, String, String, String)> = cartes
            .iter()
            .filter(|(_, e)| e.maj_dispo && !e.occupe)
            .map(|(a, e)| {
                let v = e.publication.as_ref().map(|p| texte(p.get("version"))).unwrap_or_default();
                (a.id.clone(), a.nom.clone(), a.couleur.clone(), v)
            })
            .collect();
        if let Some(m) = maj_mindset.filter(|m| vrai(m.get("prete"))) {
            let v = texte(m.get("version"));
            if plus_recente(&v, &ctx.version) {
                dispo.push(("mindset".into(), "Mindset".into(), COULEUR_MINDSET.into(), v));
            }
        }
        if let Some((id, nom, couleur, version)) = dispo.into_iter().next() {
            appli = Value::Object(infos(theme, &id, &nom, &couleur, &version));
            let x = maj_auto.get("echecs").and_then(|e| e.get(&id)).filter(|x| x.is_object());
            let essai = maj_auto.get("essais").and_then(|e| e.get(&id));
            if let Some(x) = x.filter(|x| texte(x.get("version")) == version) {
                phase = "echec";
                echec = texte(x.get("raison"));
                reessai = if auto_possible { maj_auto_reessai(essai, &version, &maintenant) } else { Some(-1) };
            } else if !auto_possible || maj_auto_reessai(essai, &version, &maintenant).is_some() {
                phase = "prete";
            } else {
                phase = "attente";
                let jeu_brut = texte(maj_auto.get("jeu"));
                let attente = texte(maj_auto.get("attentes").and_then(|a| a.get(&id)));
                raison = if !jeu_brut.is_empty() {
                    "jeu".into()
                } else if !attente.is_empty() {
                    attente
                } else if id == "mindset" {
                    "veille".into()
                } else {
                    "bientot".into()
                };
                if raison == "jeu" {
                    jeu = nom_raison_jeu(&jeu_brut);
                }
            }
        }
    }
    if phase.is_empty() {
        phase = if verif { "ajour" } else { "coupee" };
    }

    // La dernière mise à jour faite (12 heures), et ses nouveautés
    let fait = derniere_maj(&mindset, &maintenant).map(|f| {
        let id = texte(f.get("id"));
        let nom_note = texte(f.get("nom"));
        let (id, nom, couleur) = if id == "mindset" {
            ("mindset".to_string(), "Mindset".to_string(), COULEUR_MINDSET.to_string())
        } else if let Some(a) = applis.iter().find(|a| a.id == id) {
            (a.id.clone(), a.nom.clone(), a.couleur.clone())
        } else {
            (id, nom_note, COULEUR_INCONNUE.to_string())
        };
        let mut m = infos(theme, &id, &nom, &couleur, &texte(f.get("version")));
        m.insert("quand".into(), json!(quand_maj(&texte(f.get("quand")), &maintenant).unwrap_or_default()));
        m.insert("auto".into(), json!(vrai(f.get("auto"))));
        m.insert("notes".into(), json!(texte(f.get("notes"))));
        Value::Object(m)
    });

    json!({
        "auto": auto,
        "verif": verif,
        "phase": phase,
        "raison": raison,
        "appli": appli,
        "progres": arrondi(progres_v, 3),
        "enAuto": en_auto,
        "jeu": jeu,
        "echec": echec,
        "reessai": reessai,
        "fait": fait,
    })
}

/// `Get-DerniereMaj` (mindset.ps1:631) : la dernière mise à jour (`mindset.derniere_maj`), si elle date de moins de
/// 12 heures.
fn derniere_maj<'a>(mindset: &'a Value, maintenant: &HeureLocale) -> Option<&'a Value> {
    let e = mindset.get("derniere_maj").filter(|e| e.is_object())?;
    let q = lire_s(e.get("quand")?.as_str()?)?;
    let age = moment::ecart(&q, maintenant);
    (0..DUREE_DERNIERE_MAJ * 3600).contains(&age).then_some(e)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arrondi_comme_dotnet() {
        assert_eq!(arrondi(0.6666, 3), 0.667);
        assert_eq!(arrondi(0.0005, 3), 0.0);
        assert_eq!(arrondi(0.0015, 3), 0.002);
        assert_eq!(arrondi(1.0, 3), 1.0);
    }

    #[test]
    fn echappement() {
        assert_eq!(echapper(r##"{"00E5FF":"#FF8A3D"}"##), "%7B%2200E5FF%22%3A%22%23FF8A3D%22%7D");
        assert_eq!(echapper("Café crème.png"), "Caf%C3%A9%20cr%C3%A8me.png");
        assert_eq!(echapper("a-b_c.d~e!*'()"), "a-b_c.d~e!*'()");
        assert_eq!(echapper("#&+,/:;=?@[]"), "%23%26%2B%2C%2F%3A%3B%3D%3F%40%5B%5D");
    }

    #[test]
    fn quand() {
        let m = moment::lire_iso("2026-11-07T20:00:00").unwrap();
        assert_eq!(quand_maj("2026-11-07T00:16:00", &m).as_deref(), Some("à 00 h 16"));
        assert_eq!(quand_maj("2026-11-06T21:05:00", &m).as_deref(), Some("hier à 21 h 05"));
        assert_eq!(quand_maj("2026-10-18T09:30:00", &m).as_deref(), Some("le 18 octobre à 09 h 30"));
        assert_eq!(quand_maj("2026-11-07 00:16", &m), None);
    }

    #[test]
    fn jeu() {
        assert_eq!(nom_raison_jeu("un jeu ouvert (Forêt magique)"), "Forêt magique");
        assert_eq!(nom_raison_jeu("une fenêtre en plein écran (jeu ou vidéo)"), "une fenêtre en plein écran");
        assert_eq!(nom_raison_jeu("une manette utilisée il y a moins de 5 minutes"), "manette utilisée");
        assert_eq!(nom_raison_jeu("autre"), "autre");
    }

    #[test]
    fn incidents() {
        assert_eq!(reaction_incident("RenderProcessExited"), "recreer");
        assert_eq!(reaction_incident("GpuProcessExited"), "continuer");
    }
}
