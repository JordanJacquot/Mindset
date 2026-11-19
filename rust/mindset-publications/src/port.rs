//! Les règles du vrai réseau (sans Windows, donc testées partout) : seulement GitHub, en https, l'adresse découpée
//! pour WinHTTP, et la clé GitHub d'une appli privée envoyée seulement à l'API de GitHub, jamais à l'adresse d'une
//! redirection ([`suivre`]). Le port lui-même est dans `windows` (jamais appelé vers GitHub dans un test).

use std::time::{Duration, Instant};

use mindset_noyau::reseau::{DemandeHttp, HOTE_API, Jeton, ReponseHttp};

use crate::telechargement::{ERREUR_DELAI, resoudre_adresse};

/// Les redirections suivies au plus par une demande qui les suit (.NET en suivait 50).
pub const REDIRECTIONS: usize = 10;

/// L'en-tête de GitHub qui dit quand la clé (le jeton) expire, par exemple « 2027-02-01 10:00:00 UTC ».
pub const ENTETE_EXPIRATION: &str = "github-authentication-token-expiration";

/// La clé GitHub part-elle vers cette adresse ? Seulement l'adresse demandée elle-même (`saut` 0 : jamais celle d'une
/// redirection, même vers l'API), en https, sur `api.github.com`, port 443.
pub fn jeton_permis(adresse: &str, saut: usize) -> bool {
    saut == 0 && decouper(adresse).is_some_and(|(h, p, _)| p == 443 && h == HOTE_API)
}

/// Une seule demande, sans suivre de redirection : (adresse, clé à envoyer ou non, temps qui reste).
pub type UneDemande<'a> = dyn FnMut(&str, Option<&Jeton>, Duration) -> Result<ReponseHttp, String> + 'a;

/// Une adresse refusée par le vrai réseau.
pub fn refus(adresse: &str) -> String {
    format!("Adresse refusée par Mindset : {adresse}")
}

/// La boucle du vrai réseau autour d'une seule demande (`une` : WinHTTP, ou un faux dans les tests) : l'adresse
/// vérifiée (`permise`), les redirections suivies (10 au plus) quand la demande le veut, chaque nouvelle adresse
/// revérifiée, le délai total tenu. `une` reçoit la clé GitHub seulement quand `jeton_ok(adresse, saut)` le permet
/// ([`jeton_permis`] dans Mindset) : la redirection vers le stockage des fichiers de GitHub ne l'emporte jamais.
pub fn suivre(
    d: &DemandeHttp,
    permise: &dyn Fn(&str) -> bool,
    jeton_ok: &dyn Fn(&str, usize) -> bool,
    une: &mut UneDemande,
) -> Result<ReponseHttp, String> {
    if !permise(&d.adresse) {
        return Err(refus(&d.adresse));
    }
    let debut = Instant::now();
    let mut adresse = d.adresse.clone();
    for saut in 0..=REDIRECTIONS {
        let reste = d.delai.saturating_sub(debut.elapsed());
        if reste.is_zero() {
            return Err(ERREUR_DELAI.into());
        }
        let jeton = d.jeton.as_ref().filter(|_| jeton_ok(&adresse, saut));
        let r = une(&adresse, jeton, reste)?;
        if d.suivre_redirections
            && matches!(r.statut, 301 | 302 | 303 | 307 | 308)
            && let Some(vers) = r.entete("Location")
        {
            let suivante = resoudre_adresse(&adresse, vers).unwrap_or_else(|| vers.to_string());
            if !permise(&suivante) {
                return Err(refus(&suivante));
            }
            adresse = suivante;
            continue;
        }
        return Ok(r);
    }
    Err("GitHub renvoie d'adresse en adresse".into())
}

/// Les seuls hôtes que le vrai réseau accepte : l'API de GitHub (la dernière version, la liste des versions),
/// github.com (la redirection, le flux atom, les pages, les fichiers publiés, la liste des applis en ligne) et les
/// serveurs de fichiers de GitHub (ceux de `Test-AdresseTelechargement`).
pub const HOTES: &[&str] =
    &["api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"];

/// Une adresse https découpée : l'hôte (en minuscules), le port, le chemin avec sa requête (sans le fragment).
pub fn decouper(adresse: &str) -> Option<(String, u16, String)> {
    let debut = adresse.get(..8)?;
    if !debut.eq_ignore_ascii_case("https://") {
        return None;
    }
    let reste = &adresse[8..];
    let fin = reste.find(['/', '?', '#', '\\']).unwrap_or(reste.len());
    let autorite = &reste[..fin];
    if autorite.contains('@') || reste[fin..].starts_with('\\') {
        return None;
    }
    let (hote, port) = match autorite.rsplit_once(':') {
        Some((h, p)) => (h, p.parse::<u16>().ok()?),
        None => (autorite, 443),
    };
    if hote.is_empty() || !hote.bytes().all(|o| o.is_ascii_alphanumeric() || o == b'.' || o == b'-') {
        return None;
    }
    let apres = &reste[fin..];
    let apres = &apres[..apres.find('#').unwrap_or(apres.len())];
    let chemin = if apres.starts_with('/') { apres.to_string() } else { format!("/{apres}") };
    Some((hote.to_ascii_lowercase(), port, chemin))
}

/// Le vrai réseau répond-il à cette adresse ? (https, un des [`HOTES`], le port 443)
pub fn adresse_permise(adresse: &str) -> bool {
    decouper(adresse).is_some_and(|(h, p, _)| p == 443 && HOTES.contains(&h.as_str()))
}

/// Le chemin tel qu'il part sur le réseau : les caractères hors ASCII (« Forêt ») et ceux qu'une adresse ne peut pas
/// porter sont écrits en %XX (UTF-8), comme `Uri` de .NET ; un « % » déjà là est gardé.
pub fn encoder_chemin(chemin: &str) -> String {
    let mut s = String::with_capacity(chemin.len());
    for o in chemin.bytes() {
        let garder =
            o.is_ascii_graphic() && !matches!(o, b'"' | b'<' | b'>' | b'\\' | b'^' | b'`' | b'{' | b'|' | b'}');
        if garder {
            s.push(o as char);
        } else {
            s.push_str(&format!("%{o:02X}"));
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seulement_github() {
        for bonne in [
            "https://api.github.com/repos/JordanJacquot/Mindcare/releases/latest",
            "https://github.com/JordanJacquot/Mindcare/releases.atom",
            "HTTPS://GitHub.com/x",
            "https://objects.githubusercontent.com/a?b=c",
            "https://release-assets.githubusercontent.com/a",
            "https://github.com:443/x",
            "https://github.com",
        ] {
            assert!(adresse_permise(bonne), "{bonne}");
        }
        for mauvaise in [
            "http://github.com/x",
            "https://exemple.com/x",
            "https://github.com.exemple.com/x",
            "https://github.com@exemple.com/x",
            "https://github.com:8080/x",
            "https://raw.githubusercontent.com/x",
            "https://github.com\\@exemple.com/x",
            "file:///C:/Windows/win.ini",
            "",
            "https://gİthub.com/x",
        ] {
            assert!(!adresse_permise(mauvaise), "{mauvaise}");
        }
        assert_eq!(decouper("https://GITHUB.com?x#y"), Some(("github.com".into(), 443, "/?x".into())));
    }

    /// Le jeton passé à chaque adresse par [`suivre`] : (adresse, jeton reçu ?).
    fn derouler(
        d: &DemandeHttp,
        reponses: &[(&str, ReponseHttp)],
    ) -> (Result<ReponseHttp, String>, Vec<(String, bool)>) {
        let mut vus = Vec::new();
        let r = suivre(d, &adresse_permise, &jeton_permis, &mut |a, j, _| {
            vus.push((a.to_string(), j.is_some()));
            reponses.iter().find(|(x, _)| *x == a).map(|(_, r)| r.clone()).ok_or_else(|| format!("inconnue : {a}"))
        });
        (r, vus)
    }

    fn vers(adresse: &str) -> ReponseHttp {
        ReponseHttp { statut: 302, entetes: vec![("Location".into(), adresse.into())], ..Default::default() }
    }

    #[test]
    fn la_cle_ne_part_que_vers_l_api_et_jamais_apres_une_redirection() {
        let jeton = Jeton::lire(&format!("github_pat_{}", "a".repeat(40)));
        let actif = "https://api.github.com/repos/JordanJacquot/Jobmind/releases/assets/42";
        let stockage = "https://release-assets.githubusercontent.com/github-production-release-asset/1?sig=x";
        let mut d = DemandeHttp::get(actif);
        d.jeton = jeton.clone();
        let (r, vus) = derouler(&d, &[(actif, vers(stockage)), (stockage, ReponseHttp::ok(b"zip".to_vec()))]);
        assert_eq!(r.unwrap().corps, b"zip");
        assert_eq!(vus, [(actif.to_string(), true), (stockage.to_string(), false)]);
        // Une redirection qui revient sur l'API : toujours sans la clé
        let api2 = "https://api.github.com/repositories/9/releases/assets/42";
        let (_, vus) = derouler(&d, &[(actif, vers(api2)), (api2, ReponseHttp::code(404))]);
        assert_eq!(vus, [(actif.to_string(), true), (api2.to_string(), false)]);
        // Une redirection relative (même hôte) : sans la clé
        let (_, vus) =
            derouler(&d, &[(actif, vers("/autre")), ("https://api.github.com/autre", ReponseHttp::code(200))]);
        assert_eq!(vus[1], ("https://api.github.com/autre".to_string(), false));
        // github.com (une page, un fichier publié) ne la reçoit jamais, ni le stockage demandé directement
        for a in ["https://github.com/JordanJacquot/Jobmind/releases/latest", stockage] {
            let mut d = DemandeHttp::get(a);
            d.jeton = jeton.clone();
            let (_, vus) = derouler(&d, &[(a, ReponseHttp::code(200))]);
            assert_eq!(vus, [(a.to_string(), false)], "{a}");
        }
        // Une appli publique (pas de clé) : rien, même vers l'API
        let (_, vus) = derouler(&DemandeHttp::get(actif), &[(actif, ReponseHttp::code(200))]);
        assert_eq!(vus, [(actif.to_string(), false)]);
        // Une redirection hors de GitHub : refusée avant d'y aller
        let (r, vus) = derouler(&d, &[(actif, vers("https://exemple.com/x"))]);
        assert_eq!(r.unwrap_err(), "Adresse refusée par Mindset : https://exemple.com/x");
        assert_eq!(vus.len(), 1);
        // L'API sur un autre port, ou en http : jamais
        assert!(!jeton_permis("https://api.github.com:444/x", 0));
        assert!(!jeton_permis("http://api.github.com/x", 0));
        assert!(!jeton_permis("https://api.github.com.exemple.com/x", 0));
        assert!(jeton_permis("https://API.GitHub.com/x", 0));
        assert!(!jeton_permis("https://api.github.com/x", 1));
    }

    #[test]
    fn chemin_encode() {
        assert_eq!(encoder_chemin("/JordanJacquot/Forêt/releases/latest"), "/JordanJacquot/For%C3%AAt/releases/latest");
        assert_eq!(encoder_chemin("/a b/%20?x=1"), "/a%20b/%20?x=1");
    }
}
