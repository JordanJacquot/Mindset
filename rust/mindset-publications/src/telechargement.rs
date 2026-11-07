//! Le téléchargement (paquets.ps1 : `Test-AdresseTelechargement`, `Get-Octets`) et la vérification de la signature
//! (signature.ps1 : `Test-Signature`, déjà portée dans `suite_commun::signature`).
//!
//! Tout passe par le port [`Reseau`] : `octets` suit lui-même les redirections (5 au plus), revérifie chaque adresse,
//! et garde les mêmes plafonds que la version PowerShell (200 Mo, 10 minutes en tout). Un zip sans signature valide
//! n'est JAMAIS rendu par [`telecharger_signe`].

use std::path::Path;
use std::time::{Duration, Instant};

use mindset_noyau::Progres;
use mindset_noyau::reseau::{DemandeHttp, Methode, Reseau};

use crate::github::Publication;

/// Le plafond par défaut de `Get-Octets` (`-MaxOctets 200MB`).
pub const MAX_OCTETS: u64 = 200 * 1024 * 1024;
/// Le délai global par défaut de `Get-Octets` (`-DelaiSecondes 600`).
pub const DELAI_SECONDES: u64 = 600;
/// Le délai de chaque étape d'une demande (`Timeout = 30000`, `ReadWriteTimeout = 30000`).
pub const DELAI_ETAPE: Duration = Duration::from_secs(30);

/// Ce que le port répond quand la réponse dépasse `max_octets` (le même début que le `FauxReseau` du noyau).
pub const ERREUR_TROP_GROS: &str = "fichier trop gros";
/// Ce que le vrai port répond quand le délai global de la demande est passé.
pub const ERREUR_DELAI: &str = "délai total dépassé";

/// Le message de .NET pour une réponse 400 ou plus (`WebException`) : « Le serveur distant a retourné une erreur :
/// (404) Introuvable. » La raison est celle de .NET en français pour les codes courants (DIVERGENCES.md).
pub fn erreur_http(code: u16) -> String {
    let raison = match code {
        400 => " Demande incorrecte",
        401 => " Non autorisé",
        403 => " Interdit",
        404 => " Introuvable",
        429 => " Too Many Requests",
        500 => " Erreur interne du serveur",
        502 => " Passerelle incorrecte",
        503 => " Serveur indisponible",
        _ => "",
    };
    format!("Le serveur distant a retourné une erreur : ({code}){raison}.")
}

/// Un caractère de l'adresse comparé à celui attendu (minuscule ASCII) comme `-match` de .NET en français : sans les
/// majuscules, et « İ » (I avec un point) vaut « i », « K » (signe kelvin) vaut « k » (juges : adresses.json).
fn meme_lettre(c: char, attendu: char) -> bool {
    c == attendu
        || c.to_ascii_lowercase() == attendu
        || (c == '\u{130}' && attendu == 'i')
        || (c == '\u{212A}' && attendu == 'k')
}

/// `Test-AdresseTelechargement` : les seules adresses d'où Mindset télécharge, GitHub et ses serveurs de fichiers
/// (`^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/`).
pub fn adresse_telechargement(adresse: &str) -> bool {
    ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"].iter().any(|hote| {
        let attendu = format!("https://{hote}/");
        let mut c = adresse.chars();
        attendu.chars().all(|a| c.next().is_some_and(|x| meme_lettre(x, a)))
    })
}

/// La fin d'une adresse : son schéma (`https:`) et son autorité (`//hôte:port`).
fn origine(adresse: &str) -> Option<(&str, &str, &str)> {
    let i = adresse.find("://")?;
    let schema = &adresse[..i];
    let reste = &adresse[i + 3..];
    let fin = reste.find(['/', '?', '#']).unwrap_or(reste.len());
    Some((schema, &reste[..fin], &reste[fin..]))
}

/// Retire les `.` et `..` d'un chemin (RFC 3986, comme `Uri`).
fn sans_points(chemin: &str) -> String {
    let mut sortie: Vec<&str> = Vec::new();
    let morceaux: Vec<&str> = chemin.split('/').collect();
    for (i, m) in morceaux.iter().enumerate() {
        let dernier = i + 1 == morceaux.len();
        match *m {
            "." => {
                if dernier {
                    sortie.push("");
                }
            }
            ".." => {
                if sortie.len() > 1 {
                    sortie.pop();
                }
                if dernier {
                    sortie.push("");
                }
            }
            x => sortie.push(x),
        }
    }
    let r = sortie.join("/");
    if r.starts_with('/') { r } else { format!("/{r}") }
}

/// `(New-Object Uri ([Uri]$Url), $vers).AbsoluteUri` : l'adresse d'une redirection (complète, sans schéma, absolue
/// ou relative), le schéma et l'hôte en minuscules.
pub fn resoudre_adresse(base: &str, vers: &str) -> Option<String> {
    let vers = vers.trim();
    let a_un_schema = vers.find(':').is_some_and(|i| {
        let s = &vers[..i];
        !s.is_empty()
            && s.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
            && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    });
    let complete = if a_un_schema {
        vers.to_string()
    } else {
        let (schema, autorite, reste) = origine(base)?;
        if let Some(r) = vers.strip_prefix("//") {
            format!("{schema}://{r}")
        } else if vers.starts_with('/') {
            format!("{schema}://{autorite}{vers}")
        } else if vers.starts_with('?') {
            let chemin = &reste[..reste.find(['?', '#']).unwrap_or(reste.len())];
            format!("{schema}://{autorite}{chemin}{vers}")
        } else if vers.is_empty() || vers.starts_with('#') {
            let sans_fragment = &base[..base.find('#').unwrap_or(base.len())];
            format!("{sans_fragment}{vers}")
        } else {
            let chemin = &reste[..reste.find(['?', '#']).unwrap_or(reste.len())];
            let dossier = &chemin[..chemin.rfind('/').map(|i| i + 1).unwrap_or(0)];
            let dossier = if dossier.is_empty() { "/" } else { dossier };
            format!("{schema}://{autorite}{dossier}{vers}")
        }
    };
    let (schema, autorite, reste) = origine(&complete)?;
    let fin_chemin = reste.find(['?', '#']).unwrap_or(reste.len());
    let chemin = if reste[..fin_chemin].is_empty() { "/".to_string() } else { sans_points(&reste[..fin_chemin]) };
    Some(format!(
        "{}://{}{}{}",
        schema.to_ascii_lowercase(),
        autorite.to_ascii_lowercase(),
        chemin,
        &reste[fin_chemin..]
    ))
}

/// Un nombre comme PowerShell l'écrit dans un texte (`"$([math]::Round(x, 1))"`) : sans zéro inutile.
fn nombre_ps(x: f64) -> String {
    if x == x.trunc() { format!("{}", x as i64) } else { format!("{x}") }
}

/// `[math]::Round(x, chiffres)` : au pair le plus proche, comme .NET.
fn arrondi(x: f64, chiffres: i32) -> f64 {
    let p = 10f64.powi(chiffres);
    let y = x * p;
    let r = y.round();
    let r = if (y - y.trunc()).abs() == 0.5 && r % 2.0 != 0.0 { r - y.signum() } else { r };
    r / p
}

/// `Get-Octets` : le contenu d'une adresse de GitHub. Au plus `max_octets` et `delai_secondes` en tout ; les
/// redirections sont suivies ici (5 au plus) et chaque adresse est revérifiée. `progres` : la barre de progression
/// (reçu, total).
pub fn octets(
    reseau: &dyn Reseau,
    adresse: &str,
    progres: Option<&Progres>,
    max_octets: u64,
    delai_secondes: u64,
) -> Result<Vec<u8>, String> {
    if !adresse_telechargement(adresse) {
        return Err(format!("Adresse de téléchargement refusée : {adresse}"));
    }
    let debut = Instant::now();
    let delai = Duration::from_secs(delai_secondes);
    let trop = format!(
        "Le fichier téléchargé est trop gros (plus de {} Mo) : rien n'a été installé.",
        nombre_ps(arrondi(max_octets as f64 / 1_048_576.0, 0))
    );
    let lent = format!(
        "Le téléchargement a pris plus de {} minutes : la connexion est peut-être trop lente, réessaie plus tard.",
        nombre_ps(arrondi(delai_secondes as f64 / 60.0, 1))
    );
    let mut url = adresse.to_string();
    for saut in 0.. {
        let reste = delai.saturating_sub(debut.elapsed()).max(Duration::from_millis(1));
        let d = DemandeHttp {
            adresse: url.clone(),
            methode: Methode::Get,
            entetes: Vec::new(),
            suivre_redirections: false,
            max_octets,
            delai: reste,
        };
        let r = reseau.demander(&d, progres).map_err(|e| {
            if e.starts_with(ERREUR_TROP_GROS) {
                trop.clone()
            } else if e == ERREUR_DELAI {
                lent.clone()
            } else {
                e
            }
        })?;
        if matches!(r.statut, 301 | 302 | 303 | 307 | 308) {
            let vers = r.entete("Location").unwrap_or("").to_string();
            if saut >= 5 || vers.is_empty() {
                return Err("Le téléchargement renvoie d'adresse en adresse : rien n'a été installé.".into());
            }
            url = resoudre_adresse(&url, &vers).unwrap_or(vers);
            if !adresse_telechargement(&url) {
                return Err(format!("Adresse de téléchargement refusée : {url}"));
            }
            if debut.elapsed() > delai {
                return Err(lent);
            }
            continue;
        }
        if r.statut >= 400 {
            return Err(crate::telechargement::erreur_http(r.statut));
        }
        if r.corps.len() as u64 > max_octets {
            return Err(trop);
        }
        if debut.elapsed() > delai {
            return Err(lent);
        }
        return Ok(r.corps);
    }
    unreachable!("la boucle des redirections rend toujours")
}

/// Le zip d'une version publiée et sa signature, téléchargés puis vérifiés avec les clés publiques de Mindset
/// (`fichiers\cles-publiques`), comme le travail de `Start-InstallAppli` : une version sans signature n'est même pas
/// téléchargée, une signature fausse fait tout refuser. Rendu : (zip, signature), seulement si la signature est bonne.
pub fn telecharger_signe(
    reseau: &dyn Reseau,
    publication: &Publication,
    cles: &Path,
    progres: Option<&Progres>,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let Some(url_sig) = publication.url_sig.as_deref().filter(|s| !s.is_empty()) else {
        return Err(format!("La version {} n'est pas signée : Mindset ne l'installera pas.", publication.version));
    };
    let zip = octets(reseau, &publication.url_zip, progres, MAX_OCTETS, DELAI_SECONDES)?;
    let sig = octets(reseau, url_sig, None, MAX_OCTETS, DELAI_SECONDES)?;
    if !suite_commun::signature::verifier_signature(&zip, &sig, cles) {
        return Err("La signature du fichier téléchargé est invalide : rien n'a été installé.".into());
    }
    Ok((zip, sig))
}

#[cfg(test)]
mod tests {
    use super::*;
    use mindset_noyau::reseau::{FauxReseau, ReponseHttp};

    fn redirection(vers: &str) -> ReponseHttp {
        ReponseHttp { statut: 302, entetes: vec![("Location".into(), vers.into())], ..Default::default() }
    }

    #[test]
    fn adresses_refusees_sans_rien_demander() {
        let f = FauxReseau::default();
        for u in [
            "http://github.com/a/b.zip",
            "https://exemple.com/b.zip",
            "https://github.com.exemple.com/b.zip",
            "https://github.com@exemple.com/b.zip",
            "https://exemple.com/https://github.com/b.zip",
            "file:///C:/Windows/win.ini",
            "",
        ] {
            let e = octets(&f, u, None, MAX_OCTETS, DELAI_SECONDES).unwrap_err();
            assert!(e.starts_with("Adresse de téléchargement refusée"), "{u} : {e}");
        }
        assert!(f.demandes().is_empty());
    }

    #[test]
    fn redirections_suivies_et_reverifiees() {
        let f = FauxReseau::default();
        let b = "https://github.com/JordanJacquot/Mindcare/releases/download/v1.0.0";
        f.repondre(&format!("{b}/saut"), Ok(redirection("https://objects.githubusercontent.com/ok")));
        f.repondre("https://objects.githubusercontent.com/ok", Ok(ReponseHttp::ok(b"bonjour".to_vec())));
        f.repondre(&format!("{b}/relatif"), Ok(redirection("../v1.0.0/ok2")));
        f.repondre(&format!("{b}/ok2"), Ok(ReponseHttp::ok(b"salut".to_vec())));
        f.repondre(&format!("{b}/dehors"), Ok(redirection("https://exemple.com/piege.zip")));
        f.repondre(&format!("{b}/boucle"), Ok(redirection("/JordanJacquot/Mindcare/releases/download/v1.0.0/boucle")));
        f.repondre(&format!("{b}/vide"), Ok(ReponseHttp { statut: 301, ..Default::default() }));
        f.repondre(&format!("{b}/absent"), Ok(ReponseHttp::code(404)));
        f.repondre(&format!("{b}/gros"), Ok(ReponseHttp::ok(vec![b'x'; 3000])));
        let p = Progres::default();
        assert_eq!(octets(&f, &format!("{b}/saut"), Some(&p), MAX_OCTETS, 600).unwrap(), b"bonjour");
        assert_eq!(p.recu(), 7);
        assert_eq!(octets(&f, &format!("{b}/relatif"), None, MAX_OCTETS, 600).unwrap(), b"salut");
        assert_eq!(
            octets(&f, &format!("{b}/dehors"), None, MAX_OCTETS, 600).unwrap_err(),
            "Adresse de téléchargement refusée : https://exemple.com/piege.zip"
        );
        let n = f.demandes().len();
        let e = octets(&f, &format!("{b}/boucle"), None, MAX_OCTETS, 600).unwrap_err();
        assert_eq!(e, "Le téléchargement renvoie d'adresse en adresse : rien n'a été installé.");
        assert_eq!(f.demandes().len() - n, 6, "5 redirections suivies au plus");
        assert!(octets(&f, &format!("{b}/vide"), None, MAX_OCTETS, 600).unwrap_err().contains("adresse en adresse"));
        assert_eq!(
            octets(&f, &format!("{b}/absent"), None, MAX_OCTETS, 600).unwrap_err(),
            "Le serveur distant a retourné une erreur : (404) Introuvable."
        );
        assert_eq!(
            octets(&f, &format!("{b}/gros"), None, 1000, 600).unwrap_err(),
            "Le fichier téléchargé est trop gros (plus de 0 Mo) : rien n'a été installé."
        );
        assert_eq!(octets(&f, &format!("{b}/gros"), None, 3000, 600).unwrap().len(), 3000);
        // Toutes les demandes : sans suivre les redirections (c'est octets qui les suit et les revérifie)
        assert!(f.demandes().iter().all(|d| !d.suivre_redirections && d.methode == Methode::Get));
    }

    #[test]
    fn messages_des_plafonds() {
        let f = FauxReseau::default();
        f.repondre("https://github.com/gros", Ok(ReponseHttp::ok(vec![0u8; 10])));
        assert_eq!(
            octets(&f, "https://github.com/gros", None, 5, 600).unwrap_err(),
            "Le fichier téléchargé est trop gros (plus de 0 Mo) : rien n'a été installé."
        );
        f.repondre("https://github.com/lent", Err(ERREUR_DELAI.into()));
        assert_eq!(
            octets(&f, "https://github.com/lent", None, MAX_OCTETS, 600).unwrap_err(),
            "Le téléchargement a pris plus de 10 minutes : la connexion est peut-être trop lente, réessaie plus tard."
        );
        assert_eq!(
            octets(&f, "https://github.com/lent", None, MAX_OCTETS, 1).unwrap_err(),
            "Le téléchargement a pris plus de 0 minutes : la connexion est peut-être trop lente, réessaie plus tard."
        );
        assert_eq!(
            octets(&f, "https://github.com/lent", None, MAX_OCTETS, 90).unwrap_err(),
            "Le téléchargement a pris plus de 1.5 minutes : la connexion est peut-être trop lente, réessaie plus tard."
        );
        f.repondre("https://github.com/gros2", Err(format!("{ERREUR_TROP_GROS} (plus de 5 octets)")));
        assert!(octets(&f, "https://github.com/gros2", None, MAX_OCTETS, 600).unwrap_err().contains("plus de 200 Mo"));
        f.repondre("https://github.com/coupe", Err("Impossible de se connecter au serveur distant".into()));
        assert_eq!(
            octets(&f, "https://github.com/coupe", None, MAX_OCTETS, 600).unwrap_err(),
            "Impossible de se connecter au serveur distant"
        );
    }

    /// La clé de TEST de l'installateur (jamais la clé de la suite).
    fn cle_de_test() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join(r"..\mindset-installateur\tests\cle-de-test")
    }

    fn signer(donnees: &[u8]) -> Vec<u8> {
        let pk8 = std::fs::read(cle_de_test().join("privee-de-test.der")).unwrap();
        let cle = ring::signature::RsaKeyPair::from_der(&pk8).unwrap();
        let mut sig = vec![0u8; cle.public().modulus_len()];
        cle.sign(&ring::signature::RSA_PKCS1_SHA256, &ring::rand::SystemRandom::new(), donnees, &mut sig).unwrap();
        sig
    }

    #[test]
    fn un_zip_sans_signature_valide_n_est_jamais_rendu() {
        let dossier = std::env::temp_dir().join(format!("mindset-publications-cles-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dossier);
        std::fs::create_dir_all(&dossier).unwrap();
        std::fs::copy(cle_de_test().join("publique-de-test.xml"), dossier.join("test.xml")).unwrap();
        let b = "https://github.com/JordanJacquot/Mindcare/releases/download/v0.90.0";
        let zip = b"PK faux zip Cafe creme".to_vec();
        let f = FauxReseau::default();
        f.repondre(&format!("{b}/Mindcare.zip"), Ok(ReponseHttp::ok(zip.clone())));
        f.repondre(&format!("{b}/Mindcare.zip.sig"), Ok(ReponseHttp::ok(signer(&zip))));
        let mut autre = zip.clone();
        autre[3] ^= 1;
        f.repondre(&format!("{b}/Abime.zip"), Ok(ReponseHttp::ok(autre)));
        f.repondre(&format!("{b}/Mauvaise.sig"), Ok(ReponseHttp::ok(signer(b"un autre fichier"))));
        f.repondre(&format!("{b}/Vide.sig"), Ok(ReponseHttp::ok(Vec::new())));
        let publication = |zip: &str, sig: Option<&str>| Publication {
            version: "0.90.0".into(),
            fichier: "Mindcare.zip".into(),
            url_zip: format!("{b}/{zip}"),
            url_sig: sig.map(|s| format!("{b}/{s}")),
            essai: true,
            ..Default::default()
        };
        let p = Progres::default();
        let (z, s) =
            telecharger_signe(&f, &publication("Mindcare.zip", Some("Mindcare.zip.sig")), &dossier, Some(&p)).unwrap();
        assert_eq!(z, zip);
        assert_eq!(s.len(), 384);
        assert_eq!(p.recu(), zip.len() as u64, "la progression suit le zip");
        let invalide = "La signature du fichier téléchargé est invalide : rien n'a été installé.";
        for (zip, sig) in
            [("Abime.zip", "Mindcare.zip.sig"), ("Mindcare.zip", "Mauvaise.sig"), ("Mindcare.zip", "Vide.sig")]
        {
            assert_eq!(telecharger_signe(&f, &publication(zip, Some(sig)), &dossier, None).unwrap_err(), invalide);
        }
        // Une autre liste de clés (vide) : tout refusé
        let vide = dossier.join("vide");
        std::fs::create_dir_all(&vide).unwrap();
        assert_eq!(
            telecharger_signe(&f, &publication("Mindcare.zip", Some("Mindcare.zip.sig")), &vide, None).unwrap_err(),
            invalide
        );
        // Pas de signature publiée : refusé AVANT tout téléchargement
        let n = f.demandes().len();
        for sig in [None, Some("")] {
            let mut x = publication("Mindcare.zip", None);
            x.url_sig = sig.map(str::to_string);
            assert_eq!(
                telecharger_signe(&f, &x, &dossier, None).unwrap_err(),
                "La version 0.90.0 n'est pas signée : Mindset ne l'installera pas."
            );
        }
        assert_eq!(f.demandes().len(), n);
        let _ = std::fs::remove_dir_all(&dossier);
    }

    #[test]
    fn resolution_des_redirections() {
        let b = "https://github.com/a/b/c?x=1#f";
        assert_eq!(resoudre_adresse(b, "/ok").as_deref(), Some("https://github.com/ok"));
        assert_eq!(resoudre_adresse(b, "d").as_deref(), Some("https://github.com/a/b/d"));
        assert_eq!(resoudre_adresse(b, "../d").as_deref(), Some("https://github.com/a/d"));
        assert_eq!(resoudre_adresse(b, "../../../../d").as_deref(), Some("https://github.com/d"));
        assert_eq!(resoudre_adresse(b, "?y=2").as_deref(), Some("https://github.com/a/b/c?y=2"));
        assert_eq!(resoudre_adresse(b, "//EXEMPLE.com/z").as_deref(), Some("https://exemple.com/z"));
        assert_eq!(resoudre_adresse(b, "HTTPS://GitHub.COM/Z").as_deref(), Some("https://github.com/Z"));
        assert_eq!(resoudre_adresse("https://github.com", "x").as_deref(), Some("https://github.com/x"));
    }
}
