//! `[Net.WebUtility]::HtmlDecode` de .NET Framework 4.8 (celle de PowerShell 5.1), que `Get-NotesPage` utilise pour
//! lire les notes d'une version sur sa page GitHub. Mode « Compat » de .NET (vérifié par les juges) : un caractère
//! `&#..;` n'est décodé que de 1 à 0xFFFF ; au-delà, ou 0, il reste tel quel.
//!
//! Juges : tests\juges\html.json (la table des noms et des décodages faits par .NET).

use crate::entites::ENTITES;

/// Un nom (`eacute`) : son caractère, sensible à la casse comme .NET.
fn nom(entite: &str) -> Option<char> {
    ENTITES.iter().find(|(n, _)| *n == entite).and_then(|(_, c)| char::from_u32(u32::from(*c)))
}

/// `UInt32.TryParse(t, NumberStyles.AllowHexSpecifier, ...)` : des chiffres hexadécimaux seulement.
fn hexadecimal(t: &str) -> Option<u32> {
    if t.is_empty() || !t.bytes().all(|o| o.is_ascii_hexdigit()) {
        return None;
    }
    let mut v: u64 = 0;
    for o in t.bytes() {
        v = v * 16 + u64::from((o as char).to_digit(16)?);
        if v > u64::from(u32::MAX) {
            return None;
        }
    }
    Some(v as u32)
}

/// `UInt32.TryParse(t, NumberStyles.Integer, ...)` : blancs autour, un signe permis (« -0 » vaut 0).
fn decimal(t: &str) -> Option<u32> {
    let t = t.trim_matches(|c: char| matches!(c, '\u{9}'..='\u{D}' | ' '));
    let (negatif, chiffres) = match t.as_bytes().first() {
        Some(b'+') => (false, &t[1..]),
        Some(b'-') => (true, &t[1..]),
        _ => (false, t),
    };
    if chiffres.is_empty() || !chiffres.bytes().all(|o| o.is_ascii_digit()) {
        return None;
    }
    let mut v: u64 = 0;
    for o in chiffres.bytes() {
        v = v * 10 + u64::from(o - b'0');
        if v > u64::from(u32::MAX) {
            return None;
        }
    }
    if negatif && v != 0 {
        return None;
    }
    Some(v as u32)
}

/// Décode les `&nom;`, `&#65;` et `&#x41;` d'un texte, exactement comme .NET (même ce qu'il laisse tel quel).
/// Seule différence : un `&#xD800;` (une moitié de caractère, que .NET rend telle quelle) devient U+FFFD, une chaîne
/// Rust ne pouvant pas la garder (DIVERGENCES.md).
pub fn decoder(texte: &str) -> String {
    if !texte.contains('&') {
        return texte.to_string();
    }
    let c: Vec<char> = texte.chars().collect();
    let mut sortie = String::with_capacity(texte.len());
    let mut i = 0;
    while i < c.len() {
        let ch = c[i];
        if ch == '&'
            && let Some(rel) = c[i + 1..].iter().position(|&x| x == ';' || x == '&')
        {
            let fin = i + 1 + rel;
            if c[fin] == ';' {
                let entite: String = c[i + 1..fin].iter().collect();
                if c[i + 1..fin].len() > 1 && c[i + 1] == '#' {
                    let valeur = if c[i + 2] == 'x' || c[i + 2] == 'X' {
                        hexadecimal(&entite[2..])
                    } else {
                        decimal(&entite[1..])
                    };
                    if let Some(v) = valeur.filter(|v| (1..=0xFFFF).contains(v)) {
                        sortie.push(char::from_u32(v).unwrap_or('\u{FFFD}'));
                        i = fin + 1;
                        continue;
                    }
                } else {
                    match nom(&entite) {
                        Some(x) => sortie.push(x),
                        None => {
                            sortie.push('&');
                            sortie.push_str(&entite);
                            sortie.push(';');
                        }
                    }
                    i = fin + 1;
                    continue;
                }
            }
        }
        sortie.push(ch);
        i += 1;
    }
    sortie
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quelques_cas() {
        assert_eq!(decoder("Caf&eacute; &amp; cr&#232;me &#xE8;"), "Café & crème è");
        assert_eq!(decoder("&amp"), "&amp");
        assert_eq!(decoder("&am&amp;"), "&am&");
        assert_eq!(decoder("&#0;&#65536;&#x;"), "&#0;&#65536;&#x;");
        assert_eq!(decoder("&#xD800;"), "\u{FFFD}");
        assert_eq!(ENTITES.len(), 253);
    }
}
