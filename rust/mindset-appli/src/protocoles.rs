//! Les deux protocoles maison de la page (règle 6 de docs\regles-tauri.md) :
//!
//! - `pack` (`http://pack.localhost/<fichier>`) : une image ou une police du thème perso, lue par
//!   `suite_commun::fichier_pack::lire` dans le dossier du pack donné par le bloc « paramètres »
//!   (`Effet::DossierPack`) ; toute erreur : « introuvable » ;
//! - `fichier` (`http://fichier.localhost/<nom>`) : un fichier du PC qu'un bloc a déclaré sous un nom
//!   (`Effet::Exposer`) : les logos tirés des applis installées (`https://applogos.mindset.local/` de la version
//!   PowerShell, console.ps1:105-119), les images d'un thème perso pour la console (`https://theme.mindset.local/`,
//!   console.ps1:197-208). Seulement un nom déclaré, une image ou une police reconnue à ses premiers octets, 16 Mo au
//!   plus ; sinon « introuvable ».
//!
//! Les deux répondent avec `Access-Control-Allow-Origin: http://tauri.localhost` : la console dessine ces images
//! dans sa 3D (WebGL), ce que le navigateur n'accepte qu'avec cette autorisation (console.ps1:117).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use suite_commun::fichier_pack::{self, Refus};
use tauri::http::{Response, StatusCode, header};

/// L'origine des pages de l'appli
pub const ORIGINE_PAGES: &str = "http://tauri.localhost";
/// Le début des adresses du protocole `fichier`
pub const ADRESSE_FICHIER: &str = "http://fichier.localhost/";
/// Le début des adresses du protocole `pack`
pub const ADRESSE_PACK: &str = "http://pack.localhost/";
/// Un fichier déclaré plus gros n'est pas servi
pub const TAILLE_MAX_FICHIER: u64 = 16 * 1024 * 1024;

fn reponse(lu: Result<(Vec<u8>, &'static str), ()>) -> Response<Vec<u8>> {
    let base = Response::builder()
        .header(header::CACHE_CONTROL, "no-store")
        .header(header::X_CONTENT_TYPE_OPTIONS, "nosniff")
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, ORIGINE_PAGES);
    let r = match lu {
        Ok((octets, t)) => base.status(StatusCode::OK).header(header::CONTENT_TYPE, t).body(octets),
        Err(()) => base.status(StatusCode::NOT_FOUND).body(Vec::new()),
    };
    r.unwrap_or_else(|_| Response::new(Vec::new()))
}

/// Le dossier du pack servi, partagé entre le fil des blocs (qui le change) et le protocole.
#[derive(Clone, Default)]
pub struct DossierPack(Arc<Mutex<Option<PathBuf>>>);

impl DossierPack {
    pub fn changer(&self, d: Option<PathBuf>) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = d;
    }

    /// Le protocole `pack` : `chemin` est celui de l'adresse demandée (`/fond.png`).
    pub fn repondre(&self, chemin: &str) -> (Response<Vec<u8>>, Option<Refus>) {
        let dossier = self.0.lock().unwrap_or_else(|e| e.into_inner()).clone();
        repondre_pack(dossier.as_deref(), chemin)
    }
}

/// Le protocole `pack` pour ce dossier.
pub fn repondre_pack(dossier_pack: Option<&Path>, chemin: &str) -> (Response<Vec<u8>>, Option<Refus>) {
    let lu = match (dossier_pack, fichier_pack::nom_depuis_adresse(chemin)) {
        (Some(dossier), Some(nom)) => fichier_pack::lire(dossier, &nom),
        (None, _) => Err(Refus::Dossier),
        (_, None) => Err(Refus::Nom),
    };
    match lu {
        Ok(f) => (reponse(Ok((f.octets, f.type_contenu))), None),
        Err(r) => (reponse(Err(())), Some(r)),
    }
}

/// Un nom du protocole `fichier` : 1 à 80 lettres, chiffres, `-`, `_` ou `.`, sans « .. ».
pub fn nom_valable(nom: &str) -> bool {
    (1..=80).contains(&nom.len())
        && !nom.contains("..")
        && nom.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// Les fichiers déclarés par les blocs (nom vers chemin), partagés entre le fil des blocs et le protocole.
#[derive(Clone, Default)]
pub struct Fichiers(Arc<Mutex<HashMap<String, PathBuf>>>);

impl Fichiers {
    /// `Effet::Exposer` : `false` si le nom est refusé.
    pub fn exposer(&self, nom: &str, chemin: Option<PathBuf>) -> bool {
        if !nom_valable(nom) {
            return false;
        }
        let mut t = self.0.lock().unwrap_or_else(|e| e.into_inner());
        match chemin {
            Some(c) => t.insert(nom.to_string(), c),
            None => t.remove(nom),
        };
        true
    }

    /// Le protocole `fichier` : `chemin` est celui de l'adresse (`/nevermind.png`).
    pub fn repondre(&self, chemin: &str) -> Response<Vec<u8>> {
        let nom = chemin.trim_start_matches('/');
        let f =
            if nom_valable(nom) { self.0.lock().unwrap_or_else(|e| e.into_inner()).get(nom).cloned() } else { None };
        let lu = f
            .filter(|f| std::fs::symlink_metadata(f).is_ok_and(|m| m.is_file() && m.len() <= TAILLE_MAX_FICHIER))
            .and_then(|f| std::fs::read(f).ok())
            .and_then(|o| {
                let debut = &o[..o.len().min(64)];
                let t = fichier_pack::type_image(debut).or_else(|| fichier_pack::type_police(debut))?;
                Some((o, t))
            });
        reponse(lu.ok_or(()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, b'I', b'H', b'D', b'R'];

    #[test]
    fn seuls_les_fichiers_declares_et_reconnus() {
        let d = mindset_noyau::dossier_essai("protocole-fichier");
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let logo = d.join("nevermind.png");
        std::fs::write(&logo, PNG).unwrap();
        let faux = d.join("faux.png");
        std::fs::write(&faux, b"pas une image").unwrap();
        let f = Fichiers::default();
        assert!(f.exposer("logo-nevermind.png", Some(logo.clone())));
        assert!(f.exposer("faux.png", Some(faux)));
        assert!(!f.exposer("../x.png", Some(logo.clone())));
        assert!(!f.exposer("a/b.png", Some(logo.clone())));
        let r = f.repondre("/logo-nevermind.png");
        assert_eq!(r.status(), StatusCode::OK);
        assert_eq!(r.headers()[header::CONTENT_TYPE], "image/png");
        assert_eq!(r.headers()[header::ACCESS_CONTROL_ALLOW_ORIGIN], ORIGINE_PAGES);
        assert_eq!(f.repondre("/faux.png").status(), StatusCode::NOT_FOUND, "pas une image");
        assert_eq!(f.repondre("/inconnu.png").status(), StatusCode::NOT_FOUND);
        assert_eq!(f.repondre("/..%2F..%2Fwin.ini").status(), StatusCode::NOT_FOUND);
        assert!(f.exposer("logo-nevermind.png", None));
        assert_eq!(f.repondre("/logo-nevermind.png").status(), StatusCode::NOT_FOUND, "retiré");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn pack_sans_dossier() {
        let p = DossierPack::default();
        let (r, refus) = p.repondre("/fond.png");
        assert_eq!(r.status(), StatusCode::NOT_FOUND);
        assert_eq!(refus, Some(Refus::Dossier));
    }
}
