//! La clé GitHub des applis privées (Mindset 3.1) : un jeton à grain fin de GitHub, en lecture seule, que
//! l'utilisateur colle dans les Paramètres (« Applis privées »). Elle est gardée chiffrée sur le PC, dans le dossier des
//! données de Mindset (`cle-github.bin`), par DPAPI de Windows (`CryptProtectData`) pour le compte Windows de
//! l'utilisateur, avec une entropie propre à Mindset : un autre compte du PC, ou une copie du fichier sur un autre PC,
//! ne peut pas la lire.
//!
//! Règles :
//! - la clé n'est JAMAIS écrite en clair : ni dans un fichier, ni au journal, ni dans l'état envoyé à la page ;
//! - elle n'est lue que pour une appli privée de la liste (`Appli::prive`), et seulement envoyée à `api.github.com`
//!   (voir `reseau::DemandeHttp::jeton`) ;
//! - fichier absent, abîmé, d'un autre compte : pas de clé (les applis privées ne sont pas montrées).
//!
//! Ce qui n'est pas secret (la date où elle expire, les applis qu'elle ouvre) est dans les réglages de Mindset
//! (`CleGithubExpire`, `CleGithubApplis`).

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use crate::donnees::Dossiers;
use crate::reseau::{DemandeHttp, Jeton, Methode, Reseau};

/// Ce que voit l'utilisateur quand GitHub refuse la clé (401, 403, 404) : jamais la clé elle-même.
pub const CLE_REFUSEE: &str =
    "Ta clé GitHub ne marche plus : refais-en une dans les Paramètres (Mises à jour, Applis privées).";
/// Une appli privée sans clé gardée sur le PC (retirée pendant que Mindset tourne).
pub const SANS_CLE: &str =
    "Aucune clé GitHub sur ce PC : ajoute-la dans les Paramètres (Mises à jour, Applis privées).";
/// La page de GitHub où l'on crée une clé à grain fin (« Fine-grained personal access token »).
pub const PAGE_NOUVELLE_CLE: &str = "https://github.com/settings/personal-access-tokens/new";

/// Une question à l'API de GitHub avec la clé : `Accept` donné, les redirections suivies par le vrai réseau (qui les
/// revérifie et ne donne JAMAIS la clé à une redirection : `mindset_publications::port::suivre`).
pub fn demande_api(adresse: &str, accept: &str, jeton: &Jeton, max_octets: u64, delai: Duration) -> DemandeHttp {
    DemandeHttp {
        adresse: adresse.to_string(),
        methode: Methode::Get,
        entetes: vec![("Accept".into(), accept.into()), ("X-GitHub-Api-Version".into(), "2022-11-28".into())],
        suivre_redirections: true,
        max_octets,
        delai,
        jeton: Some(jeton.clone()),
    }
}

/// L'adresse d'un fichier d'une version d'un dépôt privé, par l'API (`https://api.github.com/repos/<dépôt>/releases/
/// assets/<numéro>`) : seulement de CE dépôt (sans tenir compte des majuscules, comme GitHub) et un numéro.
pub fn adresse_actif_prive(depot: &str, adresse: &str) -> bool {
    let Some(reste) = adresse.strip_prefix("https://api.github.com/repos/") else { return false };
    let Some((d, numero)) = reste.rsplit_once("/releases/assets/") else { return false };
    d.eq_ignore_ascii_case(depot)
        && !depot.is_empty()
        && !d.contains(['?', '#', '\\', '@'])
        && d.split('/').count() == 2
        && (1..=20).contains(&numero.len())
        && numero.bytes().all(|o| o.is_ascii_digit())
}

/// Là où un fichier d'une appli privée peut arriver après les redirections : l'API elle-même ou le stockage des
/// fichiers de GitHub (le vrai réseau n'en suit pas d'autres).
fn arrivee_permise(adresse: &str) -> bool {
    [
        "https://api.github.com/",
        "https://objects.githubusercontent.com/",
        "https://release-assets.githubusercontent.com/",
    ]
    .iter()
    .any(|d| adresse.get(..d.len()).is_some_and(|x| x.eq_ignore_ascii_case(d)))
}

/// Un fichier d'une version d'une appli privée (le zip ou sa signature), par l'API de GitHub avec la clé et
/// `Accept: application/octet-stream` : seulement une adresse de fichier de SON dépôt ([`adresse_actif_prive`]).
/// GitHub renvoie vers son stockage, que le vrai réseau suit SANS la clé ; l'adresse d'arrivée est revérifiée ;
/// 200 Mo et 10 minutes au plus, comme les autres téléchargements. La clé refusée : [`CLE_REFUSEE`].
pub fn telecharger_actif(
    reseau: &dyn Reseau,
    depot: &str,
    jeton: &Jeton,
    url: &str,
    progres: Option<&crate::tache::Progres>,
) -> Result<Vec<u8>, String> {
    if !adresse_actif_prive(depot, url) {
        return Err(format!("Adresse de téléchargement refusée : {url}"));
    }
    let base = DemandeHttp::get(url);
    let d = demande_api(url, "application/octet-stream", jeton, base.max_octets, base.delai);
    let r = reseau.demander(&d, progres)?;
    if !r.adresse_finale.is_empty() && !arrivee_permise(&r.adresse_finale) {
        return Err(format!("Adresse de téléchargement refusée : {}", r.adresse_finale));
    }
    match r.statut {
        200 if r.corps.len() as u64 <= base.max_octets => Ok(r.corps),
        200 => Err("Le fichier téléchargé est trop gros (plus de 200 Mo) : rien n'a été installé.".into()),
        401 | 403 | 404 => Err(CLE_REFUSEE.into()),
        s => Err(format!("Le serveur distant a retourné une erreur : ({s}).")),
    }
}

/// Ce que dit l'essai d'une clé (« Essayer », dans les Paramètres).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Essai {
    /// Les applis privées que la clé ouvre : (id, nom, dernière version ou vide)
    pub ouvertes: Vec<(String, String, String)>,
    /// La date où la clé expire, telle que GitHub la donne (`github-authentication-token-expiration`)
    pub expire: Option<String>,
    /// Pas de réponse de GitHub (pas d'Internet) : on ne sait pas si la clé marche
    pub injoignable: bool,
}

/// Essaie une clé sur chaque appli privée de la liste (`(id, nom, dépôt)`) : la clé ouvre-t-elle son dépôt, et sa
/// dernière version publiée. Rien n'est gardé ici.
pub fn essayer(reseau: &dyn Reseau, jeton: &Jeton, privees: &[(String, String, String)]) -> Essai {
    let mut e = Essai::default();
    let delai = Duration::from_secs(15);
    for (id, nom, depot) in privees {
        let base = format!("https://api.github.com/repos/{depot}");
        let mut lire = |adresse: &str| -> Option<(u16, Value)> {
            match reseau.demander(&demande_api(adresse, "application/vnd.github+json", jeton, 4 << 20, delai), None) {
                Ok(r) => {
                    if let Some(x) = r.entete("github-authentication-token-expiration") {
                        e.expire = Some(x.to_string());
                    }
                    let t = String::from_utf8_lossy(&r.corps).into_owned();
                    Some((r.statut, serde_json::from_str(&t).unwrap_or(Value::Null)))
                }
                Err(_) => {
                    e.injoignable = true;
                    None
                }
            }
        };
        let Some((statut, _)) = lire(&base) else { continue };
        if statut != 200 {
            continue;
        }
        let version = match lire(&format!("{base}/releases/latest")) {
            Some((200, v)) => {
                v.get("tag_name").and_then(Value::as_str).unwrap_or("").trim_start_matches(['v', 'V']).to_string()
            }
            _ => String::new(),
        };
        e.ouvertes.push((id.clone(), nom.clone(), version));
    }
    e
}

/// Le fichier chiffré, dans le dossier des données de Mindset.
pub const FICHIER: &str = "cle-github.bin";
/// L'entropie propre à Mindset donnée à DPAPI (un autre programme du compte qui appelle DPAPI sans elle ne lit rien).
pub const ENTROPIE: &[u8] = b"Mindset.CleGithub.1";
/// Le fichier chiffré fait quelques centaines d'octets : au-delà, il n'est même pas lu.
const TAILLE_MAX: u64 = 16 * 1024;

/// Le chemin du fichier chiffré.
pub fn chemin(dossiers: &Dossiers) -> PathBuf {
    dossiers.donnees.join(FICHIER)
}

/// La clé gardée, déchiffrée ; `None` s'il n'y en a pas ou si elle est illisible (jamais d'erreur visible).
pub fn lire(dossiers: &Dossiers) -> Option<Jeton> {
    lire_dans(&chemin(dossiers))
}

/// Une clé est-elle gardée (et lisible) sur ce PC ?
pub fn presente(dossiers: &Dossiers) -> bool {
    lire(dossiers).is_some()
}

fn lire_dans(f: &Path) -> Option<Jeton> {
    let m = std::fs::symlink_metadata(f).ok()?;
    if !m.is_file() || m.len() > TAILLE_MAX {
        return None;
    }
    let chiffre = std::fs::read(f).ok()?;
    let clair = dechiffrer(&chiffre)?;
    let texte = String::from_utf8(clair).ok()?;
    Jeton::lire(&texte)
}

/// Garde la clé, chiffrée (écrite à côté puis renommée : jamais un fichier à moitié écrit).
pub fn enregistrer(dossiers: &Dossiers, jeton: &Jeton) -> Result<(), String> {
    let f = chemin(dossiers);
    let chiffre = chiffrer(jeton.secret().as_bytes())?;
    if let Some(d) = f.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let tmp = f.with_extension("bin.tmp");
    std::fs::write(&tmp, &chiffre).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &f).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })?;
    // (relue tout de suite : une clé qui ne se relit pas n'est pas gardée)
    if lire_dans(&f).as_ref() != Some(jeton) {
        let _ = std::fs::remove_file(&f);
        return Err("la clé n'a pas pu être relue après l'avoir gardée".into());
    }
    Ok(())
}

/// Retire la clé gardée (rien à faire s'il n'y en a pas).
pub fn retirer(dossiers: &Dossiers) -> Result<(), String> {
    match std::fs::remove_file(chemin(dossiers)) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(windows)]
fn chiffrer(clair: &[u8]) -> Result<Vec<u8>, String> {
    crate::windows::proteger(clair, ENTROPIE)
}

#[cfg(windows)]
fn dechiffrer(chiffre: &[u8]) -> Option<Vec<u8>> {
    crate::windows::deproteger(chiffre, ENTROPIE)
}

#[cfg(not(windows))]
fn chiffrer(_: &[u8]) -> Result<Vec<u8>, String> {
    Err("la clé GitHub ne peut être gardée que sous Windows".into())
}

#[cfg(not(windows))]
fn dechiffrer(_: &[u8]) -> Option<Vec<u8>> {
    None
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn gardee_chiffree_relue_puis_retiree() {
        let racine = crate::dossier_essai("cle-github");
        let _ = std::fs::remove_dir_all(&racine);
        let d = Dossiers::sous(&racine);
        assert!(lire(&d).is_none(), "pas de clé au départ");
        let secret = format!("github_pat_{}", "Zx9_".repeat(20));
        let j = Jeton::lire(&secret).unwrap();
        enregistrer(&d, &j).unwrap();
        assert_eq!(lire(&d), Some(j.clone()));
        assert!(presente(&d));
        // Jamais en clair sur le disque (ni le texte, ni ses 16 premiers caractères, ni en UTF-16)
        let o = std::fs::read(chemin(&d)).unwrap();
        let utf16: Vec<u8> = secret.encode_utf16().flat_map(u16::to_le_bytes).collect();
        for aiguille in [secret.as_bytes(), &secret.as_bytes()[..16], &utf16[..32]] {
            assert!(!o.windows(aiguille.len()).any(|w| w == aiguille), "la clé est lisible dans le fichier");
        }
        // Sans l'entropie de Mindset : rien
        assert!(crate::windows::deproteger(&o, b"autre").is_none());
        // Abîmé : pas de clé, pas d'erreur
        let mut abime = o.clone();
        let n = abime.len() / 2;
        abime[n] ^= 0x55;
        std::fs::write(chemin(&d), &abime).unwrap();
        assert!(lire(&d).is_none());
        // Un fichier énorme n'est pas lu
        std::fs::write(chemin(&d), vec![0u8; 20 * 1024]).unwrap();
        assert!(lire(&d).is_none());
        enregistrer(&d, &j).unwrap();
        retirer(&d).unwrap();
        assert!(!chemin(&d).exists() && lire(&d).is_none());
        retirer(&d).unwrap();
        let _ = std::fs::remove_dir_all(&racine);
    }
}
