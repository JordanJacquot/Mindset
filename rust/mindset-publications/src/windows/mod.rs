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
//! - la progression (`$Progres.Recu`, `Total`) notée à chaque morceau.
//!
//! JAMAIS appelé dans un test (aucun appel réseau réel) : les tests passent par le `FauxReseau` du noyau.

#![allow(unsafe_code)]

use std::ffi::c_void;
use std::time::{Duration, Instant};

use mindset_noyau::Progres;
use mindset_noyau::reseau::{DemandeHttp, Methode, ReponseHttp, Reseau};
use windows::Win32::Networking::WinHttp::{
    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_ADDREQ_FLAG_ADD, WINHTTP_DISABLE_REDIRECTS, WINHTTP_FLAG_SECURE,
    WINHTTP_OPTION_DISABLE_FEATURE, WINHTTP_QUERY_CONTENT_LENGTH, WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_LOCATION,
    WINHTTP_QUERY_STATUS_CODE, WinHttpAddRequestHeaders, WinHttpCloseHandle, WinHttpConnect, WinHttpOpen,
    WinHttpOpenRequest, WinHttpQueryHeaders, WinHttpReadData, WinHttpReceiveResponse, WinHttpSendRequest,
    WinHttpSetOption, WinHttpSetTimeouts,
};
use windows::core::{HSTRING, PCWSTR};

use crate::port;
use crate::telechargement::{DELAI_ETAPE, ERREUR_DELAI, ERREUR_TROP_GROS, resoudre_adresse};

/// Le vrai réseau (branché par l'hôte : `crate::reseau_windows`).
#[derive(Debug, Default)]
pub struct ReseauWindows;

/// Les redirections suivies au plus par une demande qui les suit (.NET en suivait 50).
const REDIRECTIONS: usize = 10;

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

/// Un en-tête texte de la réponse (`Location`), `None` s'il n'y est pas.
///
/// SAFETY : `demande` est une poignée de demande ouverte, dont la réponse est reçue.
unsafe fn entete_texte(demande: *mut c_void, quoi: u32) -> Option<String> {
    let mut longueur = 0u32;
    // SAFETY : sans tampon, WinHTTP dit seulement la taille nécessaire (en octets) ; l'erreur attendue est ignorée
    let _ = unsafe { WinHttpQueryHeaders(demande, quoi, PCWSTR::null(), None, &mut longueur, std::ptr::null_mut()) };
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
            PCWSTR::null(),
            Some(tampon.as_mut_ptr() as *mut c_void),
            &mut taille,
            std::ptr::null_mut(),
        )
    }
    .ok()?;
    let n = (taille as usize / 2).min(tampon.len());
    Some(String::from_utf16_lossy(&tampon[..n]).trim_end_matches('\0').to_string())
}

/// Une seule demande (sans suivre de redirection).
fn une_demande(
    adresse: &str,
    d: &DemandeHttp,
    delai: Duration,
    progres: Option<&Progres>,
) -> Result<ReponseHttp, String> {
    let debut = Instant::now();
    let (hote, port, chemin) =
        port::decouper(adresse).ok_or_else(|| format!("Adresse refusée par Mindset : {adresse}"))?;
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
                WINHTTP_FLAG_SECURE,
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
            let h: Vec<u16> = format!("{nom}: {valeur}").encode_utf16().collect();
            WinHttpAddRequestHeaders(demande.0, &h, WINHTTP_ADDREQ_FLAG_ADD).map_err(|e| message(&e, &hote))?;
        }
        WinHttpSendRequest(demande.0, None, None, 0, 0, 0).map_err(|e| message(&e, &hote))?;
        WinHttpReceiveResponse(demande.0, std::ptr::null_mut()).map_err(|e| message(&e, &hote))?;
        let statut = entete_nombre(demande.0, WINHTTP_QUERY_STATUS_CODE).ok_or("réponse sans code")? as u16;
        let annonce = entete_nombre(demande.0, WINHTTP_QUERY_CONTENT_LENGTH).map(u64::from);
        let mut entetes = Vec::new();
        if let Some(l) = entete_texte(demande.0, WINHTTP_QUERY_LOCATION) {
            entetes.push(("Location".to_string(), l));
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
        Ok(ReponseHttp { statut, entetes, corps, adresse_finale: adresse.to_string() })
    }
}

impl Reseau for ReseauWindows {
    fn demander(&self, d: &DemandeHttp, progres: Option<&Progres>) -> Result<ReponseHttp, String> {
        if !port::adresse_permise(&d.adresse) {
            return Err(format!("Adresse refusée par Mindset : {}", d.adresse));
        }
        let debut = Instant::now();
        let mut adresse = d.adresse.clone();
        for _ in 0..=REDIRECTIONS {
            let reste = d.delai.saturating_sub(debut.elapsed());
            if reste.is_zero() {
                return Err(ERREUR_DELAI.into());
            }
            let r = une_demande(&adresse, d, reste, progres)?;
            if d.suivre_redirections
                && matches!(r.statut, 301 | 302 | 303 | 307 | 308)
                && let Some(vers) = r.entete("Location")
            {
                let suivante = resoudre_adresse(&adresse, vers).unwrap_or_else(|| vers.to_string());
                if !port::adresse_permise(&suivante) {
                    return Err(format!("Adresse refusée par Mindset : {suivante}"));
                }
                adresse = suivante;
                continue;
            }
            return Ok(r);
        }
        Err("GitHub renvoie d'adresse en adresse".into())
    }
}
