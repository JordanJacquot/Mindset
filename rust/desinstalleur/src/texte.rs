//! Petits outils sur les textes et les chemins, comme .NET les compare (sans tenir compte des majuscules).

use std::path::{Path, PathBuf};

/// Un caractère en majuscule simple, comme `OrdinalIgnoreCase` de .NET (« ß » reste « ß »)
fn majuscule(c: char) -> char {
    let mut m = c.to_uppercase();
    match (m.next(), m.next()) {
        (Some(u), None) => u,
        _ => c,
    }
}

/// Égaux sans tenir compte des majuscules
pub fn egal(a: &str, b: &str) -> bool {
    a.chars().map(majuscule).eq(b.chars().map(majuscule))
}

/// `texte` commence-t-il par `debut`, sans tenir compte des majuscules ?
pub fn commence_par(texte: &str, debut: &str) -> bool {
    let mut t = texte.chars();
    for d in debut.chars() {
        match t.next() {
            Some(c) if majuscule(c) == majuscule(d) => {}
            _ => return false,
        }
    }
    true
}

/// `texte` contient-il `morceau`, sans tenir compte des majuscules ?
pub fn contient(texte: &str, morceau: &str) -> bool {
    let t: Vec<char> = texte.chars().map(majuscule).collect();
    let m: Vec<char> = morceau.chars().map(majuscule).collect();
    m.is_empty() || t.windows(m.len()).any(|w| w == m.as_slice())
}

/// Un chemin en texte
pub fn t(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// Sans les barres de la fin (« C:\x\ » donne « C:\x »)
pub fn sans_barre(s: &str) -> &str {
    s.trim_end_matches('\\')
}

/// Le chemin est-il DANS le dossier (pas le dossier lui-même) ? Comme `Dans` de la version C#.
pub fn dans(chemin: &str, dossier: &str) -> bool {
    commence_par(chemin, &format!("{}\\", sans_barre(dossier)))
}

/// Le chemin complet, comme `Path.GetFullPath` (« . » et « .. » résolus, sans toucher au disque)
pub fn complet(p: &Path) -> PathBuf {
    std::path::absolute(p).unwrap_or_else(|_| p.to_path_buf())
}

/// Le nom du fichier (dernier morceau du chemin), ou ""
pub fn nom(p: &str) -> String {
    Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Un nom de fichier simple : `^[^\\/:*?"<>|]+$`
pub fn nom_simple(s: &str) -> bool {
    !s.is_empty() && !s.chars().any(|c| matches!(c, '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|'))
}

/// Un argument entre guillemets pour une ligne de commande (même règle que la version C#)
pub fn citer(s: &str) -> String {
    if !s.is_empty() && !s.chars().any(|c| matches!(c, ' ' | '\t' | '"')) {
        return s.to_string();
    }
    let mut r = String::from("\"");
    let mut barres = 0usize;
    for c in s.chars() {
        if c == '\\' {
            barres += 1;
            continue;
        }
        if c == '"' {
            r.push_str(&"\\".repeat(barres * 2 + 1));
            r.push('"');
        } else {
            r.push_str(&"\\".repeat(barres));
            r.push(c);
        }
        barres = 0;
    }
    r.push_str(&"\\".repeat(barres * 2));
    r.push('"');
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comparaisons_sans_casse() {
        assert!(egal("C:\\Program Files\\Mindset", "c:\\program files\\MINDSET"));
        assert!(egal("Désinstaller", "DÉSINSTALLER"));
        assert!(commence_par("C:\\Mindset\\Programmes", "c:\\mindset\\"));
        assert!(!commence_par("C:\\Mind", "C:\\Mindset"));
        assert!(contient("--user-data-dir=C:\\X\\Mindset\\WebView2", "c:\\x\\mindset\\"));
        assert!(dans("C:\\A\\B\\c.exe", "C:\\a\\b"));
        assert!(dans("C:\\A\\B\\c.exe", "C:\\a\\b\\"));
        assert!(!dans("C:\\A\\B", "C:\\a\\b"));
        assert!(!dans("C:\\A\\Bx\\c.exe", "C:\\a\\b"));
    }

    #[test]
    fn noms_et_guillemets() {
        assert!(nom_simple("Désinstaller Nevermind.exe"));
        assert!(!nom_simple("..\\x.exe"));
        assert!(!nom_simple(""));
        assert_eq!(citer("simple"), "simple");
        assert_eq!(citer("C:\\Program Files\\x.exe"), "\"C:\\Program Files\\x.exe\"");
        assert_eq!(citer("a\\\"b"), "\"a\\\\\\\"b\"");
        assert_eq!(citer("C:\\dossier avec espace\\"), "\"C:\\dossier avec espace\\\\\"");
        assert_eq!(citer(""), "\"\"");
    }
}
