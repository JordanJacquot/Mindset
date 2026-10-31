//! Écriture et lecture sûres des fichiers JSON de la suite, comme `Save-JsonSur` et `Read-JsonSur`
//! (Mindset\fichiers\modules\donnees.ps1).
//!
//! - Écriture : le texte va dans un fichier à côté (`.tmp`), qui remplace l'ancien d'un coup ; l'ancien reste dans
//!   `.bak`. Une coupure en pleine écriture laisse toujours un fichier entier : l'ancien ou le nouveau.
//! - Lecture : un fichier pris un instant par une autre appli est relu (3 essais, ou ce que disent les [`Options`]) ;
//!   un fichier abîmé est mis de côté (`.abime-<date>`, jamais effacé) et remplacé par sa copie `.bak` si elle est
//!   bonne. Un fichier qu'on ne peut pas lire du tout n'est pas « abîmé » : c'est une erreur ([`ErreurLecture`], qui
//!   dit s'il était « pris » par un autre programme), pour que l'appelant ne reparte pas de zéro (il écraserait tout à
//!   la sauvegarde suivante).
//!
//! Divergences voulues avec Read-JsonSur et Save-JsonSur (Mindset PowerShell) :
//! - un fichier en place vide (rien, des espaces, « null ») ou qui n'est pas un objet JSON n'est jamais copié dans
//!   `.bak` à l'écriture : il remplacerait la bonne copie (constat 23 de Mindcare). Vide, il est simplement remplacé ;
//!   abîmé, il est d'abord mis de côté (`.abime-<date>`) ;
//! - une copie `.bak` illisible est elle aussi mise de côté (`.bak.abime-<date>`), comme Mindcare PowerShell ;
//! - deux mises de côté dans la même seconde ne s'écrasent plus : la seconde prend le nom suivant (`-2`, `-3`...) ;
//! - une copie `.bak` prise par un autre programme pendant tous les essais est une erreur « pris » (PowerShell la
//!   traitait comme illisible, et l'appelant repartait de zéro).

use std::fmt;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value};

use crate::texte::{SansMarque, decoder_fichier};

/// `<fichier><fin>` (« reglages.json » donne « reglages.json.bak »).
fn a_cote(fichier: &Path, fin: &str) -> PathBuf {
    let mut s = fichier.as_os_str().to_owned();
    s.push(fin);
    PathBuf::from(s)
}

/// Le nom d'un fichier (pour le journal).
fn nom_de(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Une heure locale, à la seconde (le nom d'un fichier mis de côté).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeureLocale {
    pub annee: i32,
    pub mois: u32,
    pub jour: u32,
    pub heure: u32,
    pub minute: u32,
    pub seconde: u32,
}

impl HeureLocale {
    /// `Get-Date -Format 'yyyyMMdd-HHmmss'` : « 20261026-193000 ».
    pub fn compacte(&self) -> String {
        format!(
            "{:04}{:02}{:02}-{:02}{:02}{:02}",
            self.annee, self.mois, self.jour, self.heure, self.minute, self.seconde
        )
    }
}

/// Donne l'heure locale (une horloge figée dans les tests, celle de l'appli ailleurs).
pub type Horloge = Arc<dyn Fn() -> HeureLocale + Send + Sync>;

/// L'heure locale du PC, comme `Get-Date`. Sans l'option « heure-locale » (ou hors de Windows), l'heure UTC :
/// l'appelant donne alors sa propre horloge dans les [`Options`].
pub fn heure_du_pc() -> HeureLocale {
    #[cfg(all(windows, feature = "heure-locale"))]
    {
        crate::heure_windows::heure_locale()
    }
    #[cfg(not(all(windows, feature = "heure-locale")))]
    {
        heure_utc()
    }
}

/// L'heure UTC (l'horloge de repli).
#[cfg_attr(all(windows, feature = "heure-locale"), allow(dead_code))]
fn heure_utc() -> HeureLocale {
    use std::time::{SystemTime, UNIX_EPOCH};
    let s = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let (jours, reste) = ((s / 86_400) as i64, s % 86_400);
    // Jour julien vers date (algorithme de H. Hinnant, domaine public)
    let z = jours + 719_468;
    let ere = z.div_euclid(146_097);
    let jde = z - ere * 146_097;
    let ade = (jde - jde / 1460 + jde / 36_524 - jde / 146_096) / 365;
    let jda = jde - (365 * ade + ade / 4 - ade / 100);
    let mp = (5 * jda + 2) / 153;
    let jour = jda - (153 * mp + 2) / 5 + 1;
    let mois = if mp < 10 { mp + 3 } else { mp - 9 };
    let annee = ade + ere * 400 + i64::from(mois <= 2);
    HeureLocale {
        annee: annee as i32,
        mois: mois as u32,
        jour: jour as u32,
        heure: (reste / 3600) as u32,
        minute: (reste % 3600 / 60) as u32,
        seconde: (reste % 60) as u32,
    }
}

/// Comment lire et écrire : les essais quand un fichier est pris, et l'horloge des mises de côté.
///
/// Le défaut garde le comportement de Save-JsonSur et Read-JsonSur (3 essais à 50 ms, toute erreur réessayée, heure
/// du PC). Mindcare : `Options { essais: 5, attente: Duration::from_millis(300), seulement_partage: true, horloge }`.
#[derive(Clone)]
pub struct Options {
    /// Le nombre d'essais (au moins 1).
    pub essais: u32,
    /// L'attente entre deux essais.
    pub attente: Duration,
    /// Vrai : seules les erreurs d'un fichier pris (partage refusé 32, verrou 33) sont réessayées ; une autre erreur,
    /// ou un texte abîmé, ne l'est pas. Faux : tout est réessayé (un fichier en train d'être écrit est relu).
    pub seulement_partage: bool,
    /// L'heure locale pour le nom d'un fichier mis de côté (`.abime-<date>`).
    pub horloge: Horloge,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            essais: 3,
            attente: Duration::from_millis(50),
            seulement_partage: false,
            horloge: Arc::new(heure_du_pc),
        }
    }
}

impl fmt::Debug for Options {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Options")
            .field("essais", &self.essais)
            .field("attente", &self.attente)
            .field("seulement_partage", &self.seulement_partage)
            .finish_non_exhaustive()
    }
}

impl Options {
    /// Faut-il réessayer après cette erreur ?
    fn reessayer(&self, e: &io::Error) -> bool {
        !self.seulement_partage || erreur_fichier_pris(e)
    }
}

/// L'erreur d'un fichier qu'un autre programme garde ouvert : partage refusé (ERROR_SHARING_VIOLATION, 32) ou
/// verrou (ERROR_LOCK_VIOLATION, 33), comme `Test-ErreurFichierPris` de Mindcare.
pub fn erreur_fichier_pris(e: &io::Error) -> bool {
    matches!(e.raw_os_error(), Some(32 | 33))
}

/// Le texte d'un fichier comme `[IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)` : sa marque d'encodage (UTF-8,
/// UTF-16, UTF-32) est suivie, sinon UTF-8 ; les octets invalides deviennent « � ».
pub fn texte_du_fichier(octets: &[u8]) -> String {
    decoder_fichier(octets, SansMarque::Utf8)
}

/// Un texte « vide » : rien, des espaces, ou « null » (rien à garder).
pub fn texte_vide(texte: &str) -> bool {
    let t = texte.trim_start_matches('\u{FEFF}').trim();
    t.is_empty() || t == "null"
}

/// Le contenu d'un fichier JSON, s'il contient bien un objet ; sinon pourquoi il est abîmé (« fichier vide », « ce
/// n'est pas un objet JSON », ou l'erreur de lecture du JSON).
pub fn analyser(texte: &str) -> Result<Map<String, Value>, String> {
    if texte_vide(texte) {
        return Err("fichier vide".to_string());
    }
    match serde_json::from_str::<Value>(texte.trim_start_matches('\u{FEFF}')) {
        Ok(Value::Object(o)) => Ok(o),
        Ok(_) => Err("ce n'est pas un objet JSON".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// Le contenu d'un fichier JSON, s'il contient bien un objet ; `None` sinon (abîmé, vide, coupé en plein milieu).
fn objet(texte: &str) -> Option<Map<String, Value>> {
    analyser(texte).ok()
}

/// Un nom libre `<fichier><fin>-<date>` (puis `-2`, `-3`... s'il est déjà pris), réservé en y créant un fichier vide :
/// deux mises de côté dans la même seconde, même par deux applis, ne s'écrasent jamais.
fn reserver_nom(fichier: &Path, fin: &str, o: &Options) -> io::Result<(PathBuf, std::fs::File)> {
    let base = format!("{fin}-{}", (o.horloge)().compacte());
    for n in 1u32.. {
        let p = if n == 1 { a_cote(fichier, &base) } else { a_cote(fichier, &format!("{base}-{n}")) };
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&p) {
            Ok(f) => return Ok((p, f)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists && n < 1000 => {}
            Err(e) => return Err(e),
        }
    }
    unreachable!()
}

/// Déplace `fichier` sous un nom libre `<fichier><fin>-<date>` (jamais effacé, jamais par-dessus un autre).
fn deplacer_de_cote(fichier: &Path, fin: &str, o: &Options) -> io::Result<PathBuf> {
    let (de, f) = reserver_nom(fichier, fin, o)?;
    drop(f);
    // (le nom réservé est vide : le déplacement le remplace)
    if let Err(e) = std::fs::rename(fichier, &de) {
        let _ = std::fs::remove_file(&de);
        return Err(e);
    }
    Ok(de)
}

/// Copie ces octets sous un nom libre `<fichier><fin>-<date>`.
fn copier_de_cote(fichier: &Path, fin: &str, octets: &[u8], o: &Options) -> io::Result<PathBuf> {
    let (de, mut f) = reserver_nom(fichier, fin, o)?;
    if let Err(e) = f.write_all(octets).and_then(|()| f.sync_all()) {
        drop(f);
        let _ = std::fs::remove_file(&de);
        return Err(e);
    }
    Ok(de)
}

/// Écrit `texte` dans `fichier` sans jamais laisser un fichier à moitié écrit ; l'ancien contenu reste dans
/// `<fichier>.bak`. Le remplacement est réessayé 3 fois (une appli qui lit au même moment peut le bloquer un
/// court instant). En cas d'échec, le fichier à côté est effacé et l'ancien fichier reste intact.
pub fn ecrire(fichier: &Path, texte: &str) -> io::Result<()> {
    ecrire_avec(fichier, texte, &Options::default())
}

/// [`ecrire`], avec ses essais et son horloge. Un fichier pris pendant tous les essais rend son erreur : elle se
/// reconnaît avec [`erreur_fichier_pris`].
pub fn ecrire_avec(fichier: &Path, texte: &str, o: &Options) -> io::Result<()> {
    let tmp = a_cote(fichier, ".tmp");
    let resultat = (|| {
        std::fs::write(&tmp, texte.as_bytes())?;
        let mut essai = 1;
        let mut de_cote = false;
        loop {
            match remplacer(&tmp, fichier, o, &mut de_cote) {
                Ok(()) => return Ok(()),
                Err(e) if essai >= o.essais || !o.reessayer(&e) => return Err(e),
                Err(_) => {
                    essai += 1;
                    std::thread::sleep(o.attente);
                }
            }
        }
    })();
    if resultat.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    resultat
}

/// Met `tmp` à la place de `fichier`, l'ancien `fichier` devenant `fichier.bak` (comme `[IO.File]::Replace`).
/// Chaque étape est un remplacement d'un seul coup : `fichier` est toujours entier.
/// L'ancien n'est gardé dans `.bak` que s'il contient un objet JSON : vide, il est simplement remplacé ; abîmé, il
/// est d'abord copié à côté (`.abime-<date>`). La bonne copie `.bak` n'est jamais remplacée par un fichier inutile.
/// `de_cote` : l'ancien abîmé est déjà copié à côté (un essai précédent), il ne l'est pas deux fois.
fn remplacer(tmp: &Path, fichier: &Path, o: &Options, de_cote: &mut bool) -> io::Result<()> {
    if fichier.exists() {
        let octets = std::fs::read(fichier)?;
        let ancien = texte_du_fichier(&octets);
        if objet(&ancien).is_some() {
            // L'ancien est d'abord écrit à côté puis renommé en .bak (d'un coup), puis le nouveau prend sa place
            let bak = a_cote(fichier, ".bak");
            let bak_tmp = a_cote(fichier, ".bak.tmp");
            std::fs::write(&bak_tmp, &octets)?;
            std::fs::rename(&bak_tmp, &bak)?;
        } else if !texte_vide(&ancien) && !*de_cote {
            copier_de_cote(fichier, ".abime", &octets, o)?;
            *de_cote = true;
        }
    }
    std::fs::rename(tmp, fichier)
}

/// Ce qu'a donné la lecture d'un fichier.
#[derive(Debug, Default)]
pub struct Lecture {
    /// Le contenu lu (du fichier, ou de sa copie .bak) ; `None` s'il n'y a rien de bon à lire
    pub valeur: Option<Map<String, Value>>,
    /// Le texte du fichier abîmé quand rien de bon n'a pu être lu (`None` : il n'existait pas)
    pub abime: Option<String>,
    /// Ce qui s'est passé, pour le journal de l'appli
    pub journal: Vec<String>,
}

/// Un fichier qui n'a pas pu être lu du tout (ce n'est pas un fichier abîmé : l'appelant ne doit rien écrire
/// par-dessus).
#[derive(Debug)]
pub struct ErreurLecture {
    /// Vrai : un autre programme le gardait ouvert pendant tous les essais (partage refusé, verrou). L'appelant peut
    /// lire sa copie ([`lire_copie`]) pour montrer quelque chose, et le noter « pris » : rien n'est enregistré tant
    /// qu'il n'a pas été relu.
    pub pris: bool,
    /// Le fichier qui n'a pas pu être lu (le fichier lui-même, ou sa copie `.bak`)
    pub fichier: PathBuf,
    /// L'erreur de Windows
    pub erreur: io::Error,
    /// Ce qui s'est passé avant (un fichier abîmé mis de côté...), pour le journal de l'appli
    pub journal: Vec<String>,
}

impl fmt::Display for ErreurLecture {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ne peut pas être lu ({})", nom_de(&self.fichier), self.erreur)
    }
}

impl std::error::Error for ErreurLecture {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.erreur)
    }
}

/// Ce qu'a donné une tentative de lecture des octets d'un fichier.
enum Octets {
    Absent,
    Texte(Vec<u8>),
    Erreur(io::Error),
}

/// Lit les octets d'un fichier une fois ; disparu entre-temps : absent.
fn lire_octets(p: &Path) -> Octets {
    if !p.exists() {
        return Octets::Absent;
    }
    match std::fs::read(p) {
        Ok(o) => Octets::Texte(o),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Octets::Absent,
        Err(e) => Octets::Erreur(e),
    }
}

/// Lit les octets d'un fichier avec les essais des options.
fn lire_avec_essais(p: &Path, o: &Options) -> Octets {
    let mut essai = 1;
    loop {
        match lire_octets(p) {
            Octets::Erreur(e) if essai < o.essais && o.reessayer(&e) => {
                essai += 1;
                std::thread::sleep(o.attente);
            }
            r => return r,
        }
    }
}

/// Lit un fichier écrit par [`ecrire`]. `mettre_de_cote` : faux pour une simple lecture (un test, un aperçu) qui ne
/// doit toucher à aucun fichier.
pub fn lire(fichier: &Path, mettre_de_cote: bool) -> Result<Lecture, String> {
    lire_avec(fichier, mettre_de_cote, &Options::default()).map_err(|e| e.to_string())
}

/// [`lire`], avec ses essais et son horloge. Un fichier pris pendant tous les essais donne une [`ErreurLecture`]
/// marquée `pris` ; il n'est jamais mis de côté.
pub fn lire_avec(fichier: &Path, mettre_de_cote: bool, o: &Options) -> Result<Lecture, ErreurLecture> {
    let nom = nom_de(fichier);
    let mut l = Lecture::default();
    let mut essai = 1;
    let texte: Option<String> = loop {
        match lire_octets(fichier) {
            Octets::Absent => break None,
            Octets::Erreur(e) => {
                if essai >= o.essais || !o.reessayer(&e) {
                    let pris = erreur_fichier_pris(&e);
                    return Err(ErreurLecture { pris, fichier: fichier.into(), erreur: e, journal: l.journal });
                }
            }
            Octets::Texte(octets) => {
                let t = texte_du_fichier(&octets);
                if let Some(v) = objet(&t) {
                    l.valeur = Some(v);
                    return Ok(l);
                }
                // (peut-être en train d'être écrit par une autre appli : on relit, sauf si seul un fichier pris est
                // réessayé)
                if essai >= o.essais || o.seulement_partage {
                    break Some(t);
                }
            }
        }
        essai += 1;
        std::thread::sleep(o.attente);
    };
    if let Some(t) = &texte {
        l.abime = Some(t.clone());
        if !mettre_de_cote {
            l.journal.push(format!("{nom} abîmé (illisible)"));
        } else {
            match deplacer_de_cote(fichier, ".abime", o) {
                Ok(de) => l.journal.push(format!("{nom} abîmé (illisible) : mis de côté dans {}", nom_de(&de))),
                Err(e) => l.journal.push(format!("{nom} abîmé (illisible), pas pu être mis de côté : {e}")),
            }
        }
    }
    let etat = if texte.is_some() { "abîmé" } else { "absent" };
    match lire_bak(fichier, mettre_de_cote, o, &mut l.journal) {
        Err(e) => {
            return Err(ErreurLecture { journal: std::mem::take(&mut l.journal), ..e });
        }
        Ok(Some(v)) => {
            l.journal.push(format!("{nom} {etat} : repris de sa copie ({nom}.bak)"));
            if mettre_de_cote && !fichier.exists() {
                let bak = a_cote(fichier, ".bak");
                let tmp = a_cote(fichier, ".tmp");
                if let Err(e) = std::fs::copy(&bak, &tmp).and_then(|_| std::fs::rename(&tmp, fichier)) {
                    l.journal.push(format!("{nom} non remis en place depuis sa copie : {e}"));
                }
            }
            l.abime = None;
            l.valeur = Some(v);
            return Ok(l);
        }
        Ok(None) => {}
    }
    if texte.is_some() {
        l.journal.push(format!("{nom} : aucune copie lisible, il repart de zéro"));
    }
    Ok(l)
}

/// Lit seulement la copie `<fichier>.bak` (le fichier lui-même est pris, ou absent), sans rien remettre à sa place.
/// Abîmée, elle est mise de côté (`.bak.abime-<date>`) si `mettre_de_cote`. `valeur` : son contenu, s'il est bon.
pub fn lire_copie(fichier: &Path, mettre_de_cote: bool, o: &Options) -> Result<Lecture, ErreurLecture> {
    let mut l = Lecture::default();
    match lire_bak(fichier, mettre_de_cote, o, &mut l.journal) {
        Ok(v) => {
            if v.is_some() {
                let nom = nom_de(fichier);
                l.journal.push(format!("{nom} : lu dans sa copie ({nom}.bak)"));
            }
            l.valeur = v;
            Ok(l)
        }
        Err(e) => Err(ErreurLecture { journal: l.journal, ..e }),
    }
}

/// La copie `.bak` d'un fichier : son contenu s'il est bon ; `None` si elle est absente, abîmée (mise de côté si
/// `mettre_de_cote`) ou illisible ; une erreur si elle est prise par un autre programme pendant tous les essais.
fn lire_bak(
    fichier: &Path,
    mettre_de_cote: bool,
    o: &Options,
    journal: &mut Vec<String>,
) -> Result<Option<Map<String, Value>>, ErreurLecture> {
    let nom = nom_de(fichier);
    let bak = a_cote(fichier, ".bak");
    match lire_avec_essais(&bak, o) {
        Octets::Absent => Ok(None),
        Octets::Erreur(e) if erreur_fichier_pris(&e) => {
            journal.push(format!("{nom} : sa copie ({nom}.bak) est prise par un autre programme"));
            Err(ErreurLecture { pris: true, fichier: bak, erreur: e, journal: Vec::new() })
        }
        Octets::Erreur(e) => {
            journal.push(format!("{nom} : sa copie ({nom}.bak) ne peut pas être lue ({e})"));
            Ok(None)
        }
        Octets::Texte(octets) => {
            if let Some(v) = objet(&texte_du_fichier(&octets)) {
                return Ok(Some(v));
            }
            journal.push(format!("{nom} : sa copie ({nom}.bak) est illisible aussi"));
            if mettre_de_cote {
                match deplacer_de_cote(&bak, ".abime", o) {
                    Ok(de) => journal.push(format!("{nom}.bak mis de côté dans {}", nom_de(&de))),
                    Err(e) => journal.push(format!("{nom}.bak pas pu être mis de côté : {e}")),
                }
            }
            Ok(None)
        }
    }
}

#[cfg(test)]
mod tests;
