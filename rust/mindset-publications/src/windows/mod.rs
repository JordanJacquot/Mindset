//! Le vrai réseau : WinHTTP, la bibliothèque de Windows (https, avec les réglages de proxy du PC), comme
//! `nevermind-noyau/src/windows/http.rs`. Seulement vers GitHub (`crate::port::HOTES`), en https.
//!
//! Ce que la version PowerShell faisait avec .NET (`Invoke-RestMethod`, `Net.WebClient`, `Net.HttpWebRequest`) :
//! - `User-Agent: Mindset` ;
//! - chaque étape (connexion, envoi, réponse, chaque morceau lu) a au plus 30 secondes (`Timeout`,
//!   `ReadWriteTimeout`), et la demande entière au plus son `delai` ;
//! - au-delà de `max_octets`, la réponse est refusée (annoncée trop grosse, ou dès que le plafond est dépassé) ;
//! - les redirections : jamais suivies par WinHTTP ; suivies ici (10 au plus) quand la demande le veut, chaque
//!   adresse revérifiée (`Get-Octets` les suit lui-même, 5 au plus, avec `suivre_redirections` faux) ;
//! - la progression (`$Progres.Recu`, `Total`) notée à chaque morceau ;
//! - la clé GitHub d'une appli privée (Mindset 3.1) : `Authorization: Bearer` seulement vers `api.github.com`, et
//!   seulement à l'adresse demandée, jamais à celle d'une redirection (`port::suivre`, `port::jeton_permis`) ; la date
//!   où elle expire (`github-authentication-token-expiration`) est rendue dans les en-têtes de la réponse.
//!
//! JAMAIS appelé vers GitHub dans un test (aucun appel à Internet) : les tests passent par le `FauxReseau` du noyau, et
//! ce module est essayé seulement contre un faux GitHub en http sur 127.0.0.1 (ses tests, `local`).

#![allow(unsafe_code)]

use std::ffi::c_void;
use std::time::{Duration, Instant};

use mindset_noyau::Progres;
use mindset_noyau::reseau::{DemandeHttp, Jeton, Methode, ReponseHttp, Reseau};
use windows::Win32::Networking::WinHttp::{
    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_ADDREQ_FLAG_ADD, WINHTTP_DISABLE_REDIRECTS, WINHTTP_FLAG_SECURE,
    WINHTTP_OPEN_REQUEST_FLAGS, WINHTTP_OPTION_DISABLE_FEATURE, WINHTTP_QUERY_CONTENT_LENGTH, WINHTTP_QUERY_CUSTOM,
    WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_LOCATION, WINHTTP_QUERY_STATUS_CODE, WinHttpAddRequestHeaders,
    WinHttpCloseHandle, WinHttpConnect, WinHttpOpen, WinHttpOpenRequest, WinHttpQueryHeaders, WinHttpReadData,
    WinHttpReceiveResponse, WinHttpSendRequest, WinHttpSetOption, WinHttpSetTimeouts,
};
use windows::core::{HSTRING, PCWSTR};

use crate::port;
use crate::telechargement::{DELAI_ETAPE, ERREUR_DELAI, ERREUR_TROP_GROS};

/// Le vrai réseau (branché par l'hôte : `crate::reseau_windows`).
#[derive(Debug, Default)]
pub struct ReseauWindows {
    /// Essai seulement (tests de ce module) : un faux GitHub sur cette machine. Chaque hôte de GitHub nommé ici
    /// (`api.github.com`, `release-assets.githubusercontent.com`...) est joint en http sur 127.0.0.1, à ce port ; les
    /// adresses et les règles restent les vraies (https, hôtes permis, clé seulement pour l'API). N'existe pas dans
    /// Mindset.
    #[cfg(test)]
    local: Vec<(String, u16)>,
}

/// Le message d'une erreur de WinHTTP, comme celui de .NET quand il en a un (le journal reste lisible).
fn message(e: &windows::core::Error, hote: &str) -> String {
    match (e.code().0 as u32) & 0xFFFF {
        12002 => "L'opération a expiré.".into(),
        12007 => format!("Le nom distant n'a pas pu être résolu: '{hote}'"),
        12029 => "Impossible de se connecter au serveur distant".into(),
        12030 | 12031 => "La connexion sous-jacente a été fermée : une erreur inattendue s'est produite lors de la réception.".into(),
        12037 | 12038 | 12044 | 12045 | 12057 | 12175 => {
            "La connexion sous-jacente a été fermée : Impossible d'établir une relation de confiance pour le canal sécurisé SSL/TLS.".into()
        }
        _ => {
            let m = e.message();
            if m.trim().is_empty() { format!("erreur réseau 0x{:08X}", e.code().0) } else { m.trim().to_string() }
        }
    }
}

/// Une poignée WinHTTP, fermée quand on la lâche.
struct Poignee(*mut c_void);

impl Poignee {
    fn de(p: *mut c_void, hote: &str) -> Result<Poignee, String> {
        if p.is_null() { Err(message(&windows::core::Error::from_thread(), hote)) } else { Ok(Poignee(p)) }
    }
}

impl Drop for Poignee {
    fn drop(&mut self) {
        // SAFETY : une poignée ouverte par WinHttpOpen, WinHttpConnect ou WinHttpOpenRequest, fermée une seule fois
        let _ = unsafe { WinHttpCloseHandle(self.0) };
    }
}

/// Un en-tête numérique de la réponse (code, taille), `None` s'il n'y est pas.
///
/// SAFETY : `demande` est une poignée de demande ouverte, dont la réponse est reçue.
unsafe fn entete_nombre(demande: *mut c_void, quoi: u32) -> Option<u32> {
    let mut n = 0u32;
    let mut longueur = std::mem::size_of::<u32>() as u32;
    // SAFETY : le tampon est un u32 vivant pendant l'appel, sa taille est donnée
    unsafe {
        WinHttpQueryHeaders(
            demande,
            quoi | WINHTTP_QUERY_FLAG_NUMBER,
            PCWSTR::null(),
            Some(&mut n as *mut u32 as *mut c_void),
            &mut longueur,
            std::ptr::null_mut(),
        )
    }
    .ok()?;
    Some(n)
}

/// Un en-tête texte de la réponse (`Location`, ou un en-tête nommé avec `WINHTTP_QUERY_CUSTOM`), `None` s'il n'y
/// est pas.
///
/// SAFETY : `demande` est une poignée de demande ouverte, dont la réponse est reçue.
unsafe fn entete_texte(demande: *mut c_void, quoi: u32, nom: Option<&HSTRING>) -> Option<String> {
    let nom = nom.map(|n| PCWSTR(n.as_ptr())).unwrap_or(PCWSTR::null());
    let mut longueur = 0u32;
    // SAFETY : sans tampon, WinHTTP dit seulement la taille nécessaire (en octets) ; l'erreur attendue est ignorée
    let _ = unsafe { WinHttpQueryHeaders(demande, quoi, nom, None, &mut longueur, std::ptr::null_mut()) };
    if longueur == 0 || longueur > 64 * 1024 {
        return None;
    }
    let mut tampon = vec![0u16; (longueur as usize).div_ceil(2) + 1];
    let mut taille = (tampon.len() * 2) as u32;
    // SAFETY : le tampon est vivant pendant l'appel, sa taille en octets est donnée
    unsafe {
        WinHttpQueryHeaders(
            demande,
            quoi,
            nom,
            Some(tampon.as_mut_ptr() as *mut c_void),
            &mut taille,
            std::ptr::null_mut(),
        )
    }
    .ok()?;
    let n = (taille as usize / 2).min(tampon.len());
    Some(String::from_utf16_lossy(&tampon[..n]).trim_end_matches('\0').to_string())
}

/// Une seule demande (sans suivre de redirection). `jeton` : la clé GitHub, seulement quand `port::suivre` la donne
/// pour cette adresse (l'API de GitHub, jamais une redirection) ; `securise` : https (toujours, sauf l'essai local).
fn une_demande(
    lieu: (String, u16, String),
    d: &DemandeHttp,
    delai: Duration,
    progres: Option<&Progres>,
    jeton: Option<&Jeton>,
    securise: bool,
) -> Result<ReponseHttp, String> {
    let debut = Instant::now();
    let (hote, port, chemin) = lieu;
    let chemin = port::encoder_chemin(&chemin);
    let ms = delai.min(DELAI_ETAPE).as_millis().clamp(1, i32::MAX as u128) as i32;
    let verbe = if d.methode == Methode::Head { "HEAD" } else { "GET" };
    // SAFETY : des chaînes terminées par un zéro (HSTRING), vivantes pendant chaque appel ; les tampons sont vivants
    // pendant les appels qui les remplissent ; les poignées sont refermées par Poignee, la demande avant la connexion
    // et la connexion avant la session (ordre de déclaration inverse)
    unsafe {
        let session = Poignee::de(
            WinHttpOpen(
                &HSTRING::from("Mindset"),
                WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                PCWSTR::null(),
                PCWSTR::null(),
                0,
            ),
            &hote,
        )?;
        WinHttpSetTimeouts(session.0, ms, ms, ms, ms).map_err(|e| message(&e, &hote))?;
        let connexion = Poignee::de(WinHttpConnect(session.0, &HSTRING::from(hote.as_str()), port, 0), &hote)?;
        let demande = Poignee::de(
            WinHttpOpenRequest(
                connexion.0,
                &HSTRING::from(verbe),
                &HSTRING::from(chemin.as_str()),
                PCWSTR::null(),
                PCWSTR::null(),
                std::ptr::null(),
                if securise { WINHTTP_FLAG_SECURE } else { WINHTTP_OPEN_REQUEST_FLAGS(0) },
            ),
            &hote,
        )?;
        // Jamais de redirection suivie par WinHTTP : chaque adresse est revérifiée ici
        let sans = WINHTTP_DISABLE_REDIRECTS.to_le_bytes();
        WinHttpSetOption(Some(demande.0 as *const c_void), WINHTTP_OPTION_DISABLE_FEATURE, Some(&sans))
            .map_err(|e| message(&e, &hote))?;
        for (nom, valeur) in &d.entetes {
            if nom.contains(['\r', '\n', ':']) || valeur.contains(['\r', '\n']) {
                return Err(format!("En-tête refusé : {nom}"));
            }
            if nom.eq_ignore_ascii_case("Authorization") {
                return Err(format!("En-tête refusé : {nom}"));
            }
            let h: Vec<u16> = format!("{nom}: {valeur}").encode_utf16().collect();
            WinHttpAddRequestHeaders(demande.0, &h, WINHTTP_ADDREQ_FLAG_ADD).map_err(|e| message(&e, &hote))?;
        }
        // La clé GitHub d'une appli privée : seulement ici, seulement quand port::suivre la donne (jamais écrite ailleurs)
        if let Some(j) = jeton {
            if j.secret().contains(['\r', '\n']) {
                return Err("Clé GitHub refusée".into());
            }
            let mut h: Vec<u16> = format!("Authorization: Bearer {}", j.secret()).encode_utf16().collect();
            let r = WinHttpAddRequestHeaders(demande.0, &h, WINHTTP_ADDREQ_FLAG_ADD);
            h.iter_mut().for_each(|x| *x = 0);
            r.map_err(|e| message(&e, &hote))?;
        }
        WinHttpSendRequest(demande.0, None, None, 0, 0, 0).map_err(|e| message(&e, &hote))?;
        WinHttpReceiveResponse(demande.0, std::ptr::null_mut()).map_err(|e| message(&e, &hote))?;
        let statut = entete_nombre(demande.0, WINHTTP_QUERY_STATUS_CODE).ok_or("réponse sans code")? as u16;
        let annonce = entete_nombre(demande.0, WINHTTP_QUERY_CONTENT_LENGTH).map(u64::from);
        let mut entetes = Vec::new();
        if let Some(l) = entete_texte(demande.0, WINHTTP_QUERY_LOCATION, None) {
            entetes.push(("Location".to_string(), l));
        }
        if jeton.is_some()
            && let Some(x) =
                entete_texte(demande.0, WINHTTP_QUERY_CUSTOM, Some(&HSTRING::from(port::ENTETE_EXPIRATION)))
        {
            entetes.push((port::ENTETE_EXPIRATION.to_string(), x));
        }
        if let Some(n) = annonce {
            entetes.push(("Content-Length".to_string(), n.to_string()));
        }
        let trop = format!("{ERREUR_TROP_GROS} (plus de {} octets)", d.max_octets);
        let mut corps = Vec::new();
        if d.methode == Methode::Get {
            if annonce.is_some_and(|n| n > d.max_octets) {
                return Err(trop);
            }
            let total = annonce.unwrap_or(0);
            if let Some(p) = progres {
                p.noter(0, total);
            }
            let mut morceau = vec![0u8; 65536];
            loop {
                let mut lu = 0u32;
                WinHttpReadData(demande.0, morceau.as_mut_ptr() as *mut c_void, morceau.len() as u32, &mut lu)
                    .map_err(|e| message(&e, &hote))?;
                if lu == 0 {
                    break;
                }
                corps.extend_from_slice(&morceau[..lu as usize]);
                if let Some(p) = progres {
                    p.noter(corps.len() as u64, total);
                }
                if corps.len() as u64 > d.max_octets {
                    return Err(trop);
                }
                if debut.elapsed() > delai {
                    return Err(ERREUR_DELAI.into());
                }
            }
        }
        // (l'adresse finale est posée par `demander`, qui sait laquelle a répondu)
        Ok(ReponseHttp { statut, entetes, corps, adresse_finale: String::new() })
    }
}

impl ReseauWindows {
    /// L'essai local : http, 127.0.0.1 seulement.
    #[cfg(test)]
    fn securise(&self) -> bool {
        self.local.is_empty()
    }

    #[cfg(not(test))]
    fn securise(&self) -> bool {
        true
    }

    /// L'adresse permise et découpée : https vers GitHub (`port::HOTES`) ; en essai local, le même contrôle, puis
    /// l'hôte joint sur 127.0.0.1 (un hôte sans faux serveur : refusé).
    fn lieu(&self, adresse: &str) -> Option<(String, u16, String)> {
        let (hote, port, chemin) = port::adresse_permise(adresse).then(|| port::decouper(adresse)).flatten()?;
        #[cfg(test)]
        if !self.local.is_empty() {
            let p = self.local.iter().find(|(h, _)| *h == hote)?.1;
            return Some(("127.0.0.1".into(), p, chemin));
        }
        Some((hote, port, chemin))
    }
}

impl Reseau for ReseauWindows {
    fn demander(&self, d: &DemandeHttp, progres: Option<&Progres>) -> Result<ReponseHttp, String> {
        let securise = self.securise();
        let mut derniere = String::new();
        let r = port::suivre(d, &|a| self.lieu(a).is_some(), &port::jeton_permis, &mut |a, jeton, reste| {
            let lieu = self.lieu(a).ok_or_else(|| port::refus(a))?;
            derniere = a.to_string();
            une_demande(lieu, d, reste, progres, jeton, securise)
        })?;
        Ok(ReponseHttp { adresse_finale: derniere, ..r })
    }
}

/// Le vrai WinHTTP essayé contre un faux GitHub sur cette machine : de petits serveurs http sur 127.0.0.1, la fausse
/// API (qui renvoie vers le stockage, comme l'API des fichiers de GitHub) et le faux stockage, joints par leurs vraies
/// adresses (`https://api.github.com/...`, `https://release-assets.githubusercontent.com/...`). Chacun note les
/// demandes reçues. Aucun accès à Internet ni à GitHub, aucune vraie clé.
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    use mindset_noyau::cle_github;

    type Repondre = Arc<dyn Fn(&str, &str) -> Vec<u8> + Send + Sync>;
    type Recues = Arc<Mutex<Vec<String>>>;

    /// Un faux serveur : `repondre(chemin, demande en minuscules)` donne la réponse ; les demandes reçues sont gardées.
    fn serveur(repondre: Repondre) -> (u16, Recues) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let recues = Arc::new(Mutex::new(Vec::new()));
        let r = Arc::clone(&recues);
        std::thread::spawn(move || {
            for c in l.incoming().take(64) {
                let Ok(mut c) = c else { continue };
                let _ = c.set_read_timeout(Some(Duration::from_secs(5)));
                let mut o = Vec::new();
                let mut b = [0u8; 4096];
                while !o.windows(4).any(|w| w == b"\r\n\r\n") {
                    match c.read(&mut b) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => o.extend_from_slice(&b[..n]),
                    }
                }
                let t = String::from_utf8_lossy(&o).to_string();
                let chemin = t.split(' ').nth(1).unwrap_or("").to_string();
                let bas = t.to_lowercase();
                r.lock().unwrap().push(bas.clone());
                let _ = c.write_all(&repondre(&chemin, &bas));
            }
        });
        (port, recues)
    }

    fn reponse(code: &str, entetes: &str, corps: &[u8]) -> Vec<u8> {
        let mut o = format!("HTTP/1.1 {code}\r\n{entetes}Content-Length: {}\r\nConnection: close\r\n\r\n", corps.len())
            .into_bytes();
        o.extend_from_slice(corps);
        o
    }

    const DEPOT: &str = "JordanJacquot/Jobmind";
    const EXPIRE: &str = "github-authentication-token-expiration: 2027-02-01 10:00:00 UTC\r\n";

    /// La clé de TEST de l'installateur (jamais la clé de la suite).
    fn cle_de_test() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(r"..\mindset-installateur\tests\cle-de-test")
    }

    fn signer(donnees: &[u8]) -> Vec<u8> {
        let pk8 = std::fs::read(cle_de_test().join("privee-de-test.der")).unwrap();
        let cle = ring::signature::RsaKeyPair::from_der(&pk8).unwrap();
        let mut sig = vec![0u8; cle.public().modulus_len()];
        cle.sign(&ring::signature::RSA_PKCS1_SHA256, &ring::rand::SystemRandom::new(), donnees, &mut sig).unwrap();
        sig
    }

    fn fichier(n: u32, nom: &str) -> String {
        format!(
            r#"{{"name":"{nom}","url":"https://api.github.com/repos/{DEPOT}/releases/assets/{n}","browser_download_url":"https://github.com/{DEPOT}/releases/download/v0.3.0/{nom}"}}"#
        )
    }

    fn vers_stockage(n: u32, jwt: &str) -> String {
        format!(
            "Location: https://release-assets.githubusercontent.com/github-production-release-asset/{n}?jwt={jwt}\r\n"
        )
    }

    /// Un faux GitHub complet pour une appli privée : le réseau, les demandes reçues par l'API et par le stockage, et
    /// la clé (de test) que l'API accepte.
    fn faux_github(zip: Vec<u8>, sig: Vec<u8>) -> (ReseauWindows, Recues, Recues, String) {
        let secret = format!("github_pat_{}", "Essai_Local_9".repeat(6));
        let (port_sto, au_stockage) = serveur(Arc::new(move |chemin: &str, _: &str| match chemin {
            "/github-production-release-asset/11?jwt=abc" => reponse("200 OK", "", &zip),
            "/github-production-release-asset/12?jwt=def" => reponse("200 OK", "", &sig),
            _ => reponse("404 Not Found", "", b""),
        }));
        let attendu = format!("authorization: bearer {}\r\n", secret.to_lowercase());
        let (port_api, a_l_api) = serveur(Arc::new(move |chemin: &str, demande: &str| {
            // (GitHub répond 404 à qui n'a pas la bonne clé pour un dépôt privé)
            if !demande.contains(&attendu) {
                return reponse("404 Not Found", "", br#"{"message":"Not Found"}"#);
            }
            let octets = demande.contains("accept: application/octet-stream");
            match chemin {
                "/repos/JordanJacquot/Jobmind" => reponse("200 OK", EXPIRE, br#"{"private":true}"#),
                "/repos/JordanJacquot/Jobmind/releases/latest" => {
                    let j = format!(
                        r#"{{"tag_name":"v0.3.0","body":"Des notes","prerelease":false,"assets":[{},{}]}}"#,
                        fichier(11, "Jobmind.zip"),
                        fichier(12, "Jobmind.zip.sig")
                    );
                    reponse("200 OK", EXPIRE, j.as_bytes())
                }
                "/repos/JordanJacquot/Jobmind/releases/assets/11" if octets => {
                    reponse("302 Found", &vers_stockage(11, "abc"), b"")
                }
                "/repos/JordanJacquot/Jobmind/releases/assets/12" if octets => {
                    reponse("302 Found", &vers_stockage(12, "def"), b"")
                }
                _ => reponse("404 Not Found", "", b""),
            }
        }));
        let reseau = ReseauWindows {
            local: vec![("api.github.com".into(), port_api), ("release-assets.githubusercontent.com".into(), port_sto)],
        };
        (reseau, a_l_api, au_stockage, secret)
    }

    #[test]
    fn appli_privee_de_bout_en_bout_par_winhttp() {
        let zip = b"PK faux zip de Jobmind, signe par la cle de test".to_vec();
        let sig = signer(&zip);
        let (reseau, a_l_api, au_stockage, secret) = faux_github(zip.clone(), sig);
        let jeton = Jeton::lire(&secret).unwrap();
        // 1. La dernière version, par l'API avec la clé : les fichiers par leur adresse de l'API
        let r = crate::github::publication_privee(&reseau, DEPOT, &["Jobmind.zip".into()], false, &jeton);
        let p = r.reponse.unwrap();
        assert_eq!((p.version.as_str(), p.fichier.as_str(), p.notes.as_str()), ("0.3.0", "Jobmind.zip", "Des notes"));
        assert_eq!(p.url_zip, format!("https://api.github.com/repos/{DEPOT}/releases/assets/11"));
        assert_eq!(p.url_sig, Some(format!("https://api.github.com/repos/{DEPOT}/releases/assets/12")));
        assert_eq!(r.expire.as_deref(), Some("2027-02-01 10:00:00 UTC"));
        // 2. Le zip et sa signature : l'API renvoie vers le stockage, suivi SANS la clé ; la signature est vérifiée
        let z = cle_github::telecharger_actif(&reseau, DEPOT, &jeton, &p.url_zip, None).unwrap();
        let s = cle_github::telecharger_actif(&reseau, DEPOT, &jeton, p.url_sig.as_deref().unwrap(), None).unwrap();
        assert_eq!(z, zip);
        let cles = mindset_noyau::dossier_essai("publications-prive-cles");
        let _ = std::fs::remove_dir_all(&cles);
        std::fs::create_dir_all(&cles).unwrap();
        std::fs::copy(cle_de_test().join("publique-de-test.xml"), cles.join("test.xml")).unwrap();
        assert!(suite_commun::signature::verifier_signature(&z, &s, &cles));
        let mut abime = z.clone();
        abime[0] ^= 1;
        assert!(!suite_commun::signature::verifier_signature(&abime, &s, &cles), "rien en moins pour une appli privée");
        let _ = std::fs::remove_dir_all(&cles);
        // 3. L'API a toujours reçu la clé, le stockage jamais (ni l'en-tête, ni le texte de la clé)
        let api = a_l_api.lock().unwrap().clone();
        let sto = au_stockage.lock().unwrap().clone();
        assert_eq!((api.len(), sto.len()), (3, 2), "{api:?}\n{sto:?}");
        assert!(api.iter().all(|d| d.contains("authorization: bearer github_pat_")));
        for d in &sto {
            assert!(
                !d.contains("authorization") && !d.contains(&secret.to_lowercase()),
                "le stockage a reçu la clé : {d}"
            );
        }
        // 4. Une clé refusée (expirée, ou d'un autre dépôt) : le message simple, jamais la clé
        let autre = Jeton::lire(&format!("github_pat_{}", "Faux_".repeat(10))).unwrap();
        let r = crate::github::publication_privee(&reseau, DEPOT, &["Jobmind.zip".into()], true, &autre);
        assert_eq!(r.reponse.unwrap_err(), cle_github::CLE_REFUSEE);
        assert_eq!(
            cle_github::telecharger_actif(&reseau, DEPOT, &autre, &p.url_zip, None).unwrap_err(),
            cle_github::CLE_REFUSEE
        );
        // 5. « Essayer » : la bonne clé ouvre Jobmind (et dit sa version), la mauvaise rien
        let privees = [("jobmind".to_string(), "Jobmind".to_string(), DEPOT.to_string())];
        let e = cle_github::essayer(&reseau, &jeton, &privees);
        assert_eq!(e.ouvertes, [("jobmind".to_string(), "Jobmind".to_string(), "0.3.0".to_string())]);
        assert_eq!(e.expire.as_deref(), Some("2027-02-01 10:00:00 UTC"));
        let e = cle_github::essayer(&reseau, &autre, &privees);
        assert!(e.ouvertes.is_empty() && !e.injoignable);
        // 6. Un fichier d'un autre dépôt, ou une autre adresse : refusé avant toute demande
        let n = a_l_api.lock().unwrap().len();
        for u in [
            "https://api.github.com/repos/JordanJacquot/Mindset/releases/assets/11",
            "https://release-assets.githubusercontent.com/github-production-release-asset/11?jwt=abc",
            "https://api.github.com/repos/JordanJacquot/Jobmind/releases/assets/11?x=1",
        ] {
            assert!(cle_github::telecharger_actif(&reseau, DEPOT, &jeton, u, None).unwrap_err().starts_with("Adresse"));
        }
        assert_eq!(a_l_api.lock().unwrap().len(), n);
        assert!(au_stockage.lock().unwrap().iter().all(|d| !d.contains("authorization")));
    }

    #[test]
    fn sans_cle_aucun_en_tete_authorization() {
        let (reseau, a_l_api, au_stockage, _) = faux_github(b"z".to_vec(), b"s".to_vec());
        let mut d = DemandeHttp::get(&format!("https://api.github.com/repos/{DEPOT}/releases/assets/11"));
        d.entetes.push(("Accept".into(), "application/octet-stream".into()));
        assert_eq!(reseau.demander(&d, None).unwrap().statut, 404);
        assert!(!a_l_api.lock().unwrap()[0].contains("authorization"));
        assert!(au_stockage.lock().unwrap().is_empty());
        // L'en-tête Authorization ne peut pas être glissé par les en-têtes ordinaires
        d.entetes.push(("Authorization".into(), "Bearer x".into()));
        assert_eq!(reseau.demander(&d, None).unwrap_err(), "En-tête refusé : Authorization");
        // Le vrai réseau (sans essai local) refuse tout ce qui n'est pas GitHub en https, sans rien envoyer
        let vrai = ReseauWindows::default();
        for a in ["http://127.0.0.1:9/x", "http://api.github.com/x", "https://exemple.com/x"] {
            assert_eq!(
                vrai.demander(&DemandeHttp::get(a), None).unwrap_err(),
                format!("Adresse refusée par Mindset : {a}")
            );
        }
    }
}
