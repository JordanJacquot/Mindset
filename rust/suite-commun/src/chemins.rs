//! Les chemins de la suite, et les règles de chemins de Windows telles que la version PowerShell les applique.
//!
//! - Les dossiers de la suite : `Program Files\Mindset\<Appli>` ou `X:\Mindset\Programmes\<Appli>` pour les
//!   programmes (modifiables par les seuls administrateurs), `X:\Mindset\Donnees` ou le profil de l'utilisateur pour
//!   les données (comme `Get-RacinesDepuis`, modules\donnees.ps1, et `Get-DonneesMindset`, installer-admin.ps1).
//! - Les chemins complets comme `[IO.Path]::GetFullPath` de .NET Framework (celui de Windows PowerShell) : mêmes refus
//!   (deux points ailleurs qu'après la lettre du disque, caractères interdits), puis la même mise en forme par Windows
//!   (GetFullPathNameW : « .. » résolus, points et espaces de fin retirés).
//! - Les comparaisons sans tenir compte des majuscules, comme `OrdinalIgnoreCase` de .NET (`-ieq`, `StartsWith`).

use std::path::Path;

/// Le dossier des programmes de la suite dans Program Files (`Program Files\Mindset`).
pub const DOSSIER_PROGRAMMES: &str = "Mindset";
/// Le dossier de Mindset lui-même, dans le dossier des programmes.
pub const DOSSIER_MINDSET: &str = "Mindset";
/// Le dossier de la suite à la racine d'un autre disque (`X:\Mindset`).
pub const RACINE_DISQUE: &str = "Mindset";
/// Ses deux dossiers : les programmes (protégés) et les données (modifiables par l'utilisateur de Mindset).
pub const PROGRAMMES_DISQUE: &str = "Programmes";
pub const DONNEES_DISQUE: &str = "Donnees";
/// Les données de Mindset dans le profil de l'utilisateur.
pub const DONNEES_PROFIL: &str = r"AppData\Local\Mindset\Mindset";
/// Le dossier des zips téléchargés par Mindset, dans son dossier de données.
pub const TELECHARGEMENTS: &str = "telechargements";

/// Un caractère en majuscule « invariante » simple, comme `OrdinalIgnoreCase` de .NET (un seul caractère : « ß »
/// reste « ß »).
fn majuscule(c: char) -> char {
    let mut m = c.to_uppercase();
    match (m.next(), m.next()) {
        (Some(u), None) => u,
        _ => c,
    }
}

/// `texte.StartsWith(debut, OrdinalIgnoreCase)` : le reste de `texte` après le début trouvé, ou `None`.
pub fn apres_debut<'a>(texte: &'a str, debut: &str) -> Option<&'a str> {
    let mut t = texte.char_indices();
    for d in debut.chars() {
        let (_, c) = t.next()?;
        if majuscule(c) != majuscule(d) {
            return None;
        }
    }
    Some(t.next().map_or("", |(i, _)| &texte[i..]))
}

/// Comparaison sans tenir compte des majuscules (`-ieq`, `-eq` de PowerShell sur des textes).
pub fn egal(a: &str, b: &str) -> bool {
    a.chars().count() == b.chars().count() && apres_debut(a, b).is_some()
}

/// Le dernier élément d'un chemin (`Split-Path -Leaf`), barres finales ignorées.
pub fn feuille(chemin: &str) -> &str {
    let c = chemin.trim_end_matches(['\\', '/']);
    c.rfind(['\\', '/']).map_or(c, |i| &c[i + 1..])
}

/// Le dossier parent (`Split-Path -Parent`) : vide pour une racine (« C:\ ») ou un nom seul.
pub fn parent(chemin: &str) -> &str {
    let c = chemin.trim_end_matches(['\\', '/']);
    match c.rfind(['\\', '/']) {
        // (le parent de « C:\x » est « C:\ »)
        Some(i) if i == 2 && c.as_bytes().get(1) == Some(&b':') => &chemin[..3],
        Some(0) => "",
        Some(i) => &c[..i],
        None => "",
    }
}

/// `Join-Path` : les deux morceaux séparés par une seule barre.
pub fn joindre(a: &str, b: &str) -> String {
    let b = b.trim_start_matches(['\\', '/']);
    if a.is_empty() {
        return b.to_string();
    }
    if a.ends_with(['\\', '/']) { format!("{a}{b}") } else { format!(r"{a}\{b}") }
}

/// Un chemin qui commence par une lettre de disque et une barre (« C:\... »), comme le motif `^[A-Za-z]:\\`.
pub fn commence_par_disque(chemin: &str) -> bool {
    let o = chemin.as_bytes();
    o.len() >= 3 && o[0].is_ascii_alphabetic() && o[1] == b':' && o[2] == b'\\'
}

/// Comme `[IO.Path]::GetFullPath` de .NET Framework 4.8 : le chemin complet, ou l'erreur que .NET donnerait.
pub fn chemin_complet(chemin: &str) -> Result<String, String> {
    if chemin.is_empty() || chemin.trim().is_empty() {
        return Err("Le chemin d'accès n'est pas de forme conforme.".into());
    }
    let long = chemin.starts_with(r"\\?\") || chemin.starts_with(r"\\.\");
    // Caractères interdits dans un chemin (.NET : « Caractères non conformes dans le chemin d'accès »)
    if chemin.chars().any(|c| (c as u32) < 32 || matches!(c, '"' | '<' | '>' | '|')) {
        return Err("Caractères non conformes dans le chemin d'accès.".into());
    }
    if !long {
        if chemin.chars().any(|c| matches!(c, '*' | '?')) {
            return Err("Caractères non conformes dans le chemin d'accès.".into());
        }
        // Deux points ailleurs qu'après la lettre du disque (un flux NTFS « fichier:flux », « C:\a:b »)
        let deux_points = chemin.char_indices().filter(|(_, c)| *c == ':').map(|(i, _)| i).collect::<Vec<_>>();
        let disque = chemin.as_bytes().first().is_some_and(u8::is_ascii_alphabetic);
        if deux_points.iter().any(|&i| !(i == 1 && disque)) {
            return Err("Le format du chemin d'accès donné n'est pas pris en charge.".into());
        }
    }
    let complet = std::path::absolute(Path::new(chemin)).map_err(|e| e.to_string())?;
    Ok(complet.to_string_lossy().into_owned())
}

/// Le dossier des données de Mindset de l'utilisateur dont le profil est `profil` (comme `Get-DonneesMindset`) :
/// `X:\Mindset\Donnees\Mindset` quand Mindset est dans `X:\Mindset\Programmes\Mindset`, sinon
/// `<profil>\AppData\Local\Mindset\Mindset`. `profil` n'est demandé que dans le second cas.
pub fn donnees_mindset(
    dossier_mindset: &str,
    profil: impl FnOnce() -> Result<String, String>,
) -> Result<String, String> {
    let p = parent(dossier_mindset);
    let m = parent(p);
    if egal(feuille(p), PROGRAMMES_DISQUE) && !m.is_empty() && egal(feuille(m), RACINE_DISQUE) {
        return Ok(joindre(m, &format!(r"{DONNEES_DISQUE}\{DOSSIER_MINDSET}")));
    }
    Ok(joindre(&profil()?, DONNEES_PROFIL))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn morceaux_de_chemins() {
        assert_eq!(feuille(r"C:\a\Mindset\"), "Mindset");
        assert_eq!(parent(r"C:\a\Mindset"), r"C:\a");
        assert_eq!(parent(r"C:\a"), r"C:\");
        assert_eq!(parent(r"C:\"), "");
        assert_eq!(joindre(r"C:\a\", r"\b"), r"C:\a\b");
        assert_eq!(apres_debut(r"c:\PROGRAM files\x", r"C:\Program Files\"), Some("x"));
        assert!(egal("Mindset", "MINDSET") && !egal("Mindset", "Mindsets"));
        assert!(commence_par_disque(r"x:\y") && !commence_par_disque(r"\\serveur\x") && !commence_par_disque("x:y"));
    }

    #[test]
    fn chemins_complets_comme_dotnet() {
        assert_eq!(chemin_complet(r"C:\a\b\..\c\").as_deref(), Ok(r"C:\a\c\"));
        assert!(chemin_complet(r"C:\a\X:flux").is_err());
        assert!(chemin_complet(r"C:\a\x*").is_err());
        assert!(chemin_complet("C:\\a\\\"x").is_err());
        assert!(chemin_complet("").is_err());
        assert_eq!(chemin_complet(r"C:\a\b. ").as_deref(), Ok(r"C:\a\b"));
    }

    #[test]
    fn donnees() {
        let p = || Ok::<_, String>(r"C:\Users\Élodie".to_string());
        assert_eq!(donnees_mindset(r"D:\Mindset\Programmes\Mindset", p).as_deref(), Ok(r"D:\Mindset\Donnees\Mindset"));
        assert_eq!(
            donnees_mindset(r"C:\Program Files\Mindset\Mindset", p).as_deref(),
            Ok(r"C:\Users\Élodie\AppData\Local\Mindset\Mindset")
        );
    }
}
