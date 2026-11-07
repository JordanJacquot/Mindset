//! Le port vers Internet (GitHub) : une demande HTTP et sa réponse (paquets.ps1 : `Get-Octets`, `Get-Publication`,
//! `Test-FichierPublie`, `Get-NotesPage`).
//!
//! Le vrai réseau (WinHTTP, limites de taille et de temps, adresses permises seulement) est écrit par le bloc
//! « publications » (`mindset_publications::reseau_windows`), que l'hôte branche au lancement. Les tests ont
//! [`FauxReseau`] : des réponses écrites d'avance, et la liste des demandes reçues. Aucun test ne parle à GitHub.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use crate::contexte::verrou;
use crate::tache::Progres;

/// GET ou HEAD.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Methode {
    Get,
    Head,
}

/// Une demande.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DemandeHttp {
    pub adresse: String,
    pub methode: Methode,
    /// En-têtes en plus (par exemple `Accept: application/vnd.github+json`)
    pub entetes: Vec<(String, String)>,
    /// Suivre les redirections (vrai par défaut) ; faux pour lire `Location` (la dernière version sans l'API)
    pub suivre_redirections: bool,
    /// Au-delà, la réponse est refusée (`-MaxOctets`, 200 Mo par défaut)
    pub max_octets: u64,
    /// Le temps maximal (`-DelaiSecondes`, 600 s par défaut)
    pub delai: Duration,
}

impl DemandeHttp {
    /// Un GET avec les valeurs par défaut de `Get-Octets`.
    pub fn get(adresse: &str) -> DemandeHttp {
        DemandeHttp {
            adresse: adresse.to_string(),
            methode: Methode::Get,
            entetes: Vec::new(),
            suivre_redirections: true,
            max_octets: 200 * 1024 * 1024,
            delai: Duration::from_secs(600),
        }
    }
}

/// Une réponse (quel que soit son code : 404 n'est pas une erreur du port).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ReponseHttp {
    pub statut: u16,
    pub entetes: Vec<(String, String)>,
    pub corps: Vec<u8>,
    /// L'adresse finale (après les redirections suivies)
    pub adresse_finale: String,
}

impl ReponseHttp {
    /// Une réponse 200 avec ce corps.
    pub fn ok(corps: impl Into<Vec<u8>>) -> ReponseHttp {
        ReponseHttp { statut: 200, corps: corps.into(), ..Default::default() }
    }

    /// Une réponse sans corps, avec ce code.
    pub fn code(statut: u16) -> ReponseHttp {
        ReponseHttp { statut, ..Default::default() }
    }

    /// La valeur d'un en-tête (sans tenir compte des majuscules).
    pub fn entete(&self, nom: &str) -> Option<&str> {
        self.entetes.iter().find(|(n, _)| n.eq_ignore_ascii_case(nom)).map(|(_, v)| v.as_str())
    }
}

/// Ce que les blocs demandent à Internet. `Err` : pas de réponse du tout (pas de connexion, délai dépassé, trop
/// gros, adresse refusée), en français.
pub trait Reseau: Send + Sync {
    fn demander(&self, demande: &DemandeHttp, progres: Option<&Progres>) -> Result<ReponseHttp, String>;
}

/// Aucun réseau : chaque demande échoue (l'hôte tant que le bloc « publications » n'a pas branché le sien).
#[derive(Debug, Default)]
pub struct SansReseau;

impl Reseau for SansReseau {
    fn demander(&self, _: &DemandeHttp, _: Option<&Progres>) -> Result<ReponseHttp, String> {
        Err("pas de connexion à Internet".into())
    }
}

/// Le faux GitHub des tests : une réponse (ou une erreur) par adresse ; une adresse inconnue donne une erreur.
#[derive(Debug, Default)]
pub struct FauxReseau {
    reponses: Mutex<HashMap<String, Result<ReponseHttp, String>>>,
    demandes: Mutex<Vec<DemandeHttp>>,
}

impl FauxReseau {
    /// La réponse à donner pour cette adresse (GET ou HEAD).
    pub fn repondre(&self, adresse: &str, reponse: Result<ReponseHttp, String>) {
        verrou(&self.reponses).insert(adresse.to_string(), reponse);
    }

    /// Les demandes reçues, dans l'ordre.
    pub fn demandes(&self) -> Vec<DemandeHttp> {
        verrou(&self.demandes).clone()
    }
}

impl Reseau for FauxReseau {
    fn demander(&self, d: &DemandeHttp, progres: Option<&Progres>) -> Result<ReponseHttp, String> {
        verrou(&self.demandes).push(d.clone());
        let r = verrou(&self.reponses)
            .get(&d.adresse)
            .cloned()
            .unwrap_or_else(|| Err(format!("pas de réponse prévue pour {} (essai)", d.adresse)))?;
        if r.corps.len() as u64 > d.max_octets {
            return Err(format!("fichier trop gros (plus de {} octets)", d.max_octets));
        }
        if let Some(p) = progres {
            p.noter(r.corps.len() as u64, r.corps.len() as u64);
        }
        if d.methode == Methode::Head {
            return Ok(ReponseHttp { corps: Vec::new(), ..r });
        }
        Ok(r)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn faux_github() {
        let f = FauxReseau::default();
        f.repondre("https://github.com/x", Ok(ReponseHttp::ok(b"abc".to_vec())));
        let p = Progres::default();
        let r = f.demander(&DemandeHttp::get("https://github.com/x"), Some(&p)).unwrap();
        assert_eq!(r.corps, b"abc");
        assert_eq!(p.part(), 1.0);
        let mut petit = DemandeHttp::get("https://github.com/x");
        petit.max_octets = 2;
        assert!(f.demander(&petit, None).is_err());
        assert!(f.demander(&DemandeHttp::get("https://ailleurs"), None).is_err());
        assert_eq!(f.demandes().len(), 3);
        assert!(SansReseau.demander(&DemandeHttp::get("https://github.com/x"), None).is_err());
    }
}
