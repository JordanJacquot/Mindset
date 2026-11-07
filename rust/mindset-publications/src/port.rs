//! Les règles du vrai réseau (sans Windows, donc testées partout) : seulement GitHub, en https, et l'adresse découpée
//! pour WinHTTP. Le port lui-même est dans `windows` (jamais appelé dans un test).

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

    #[test]
    fn chemin_encode() {
        assert_eq!(encoder_chemin("/JordanJacquot/Forêt/releases/latest"), "/JordanJacquot/For%C3%AAt/releases/latest");
        assert_eq!(encoder_chemin("/a b/%20?x=1"), "/a%20b/%20?x=1");
    }
}
