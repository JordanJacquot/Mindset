//! Petits outils de texte qui imitent .NET : lecture d'un fichier selon sa marque d'encodage (BOM), page de code
//! Windows-1252, comparaison sans tenir compte des majuscules.

/// Page de code Windows-1252 : les caractères de 0x80 à 0x9F (les autres octets valent leur point de code).
/// Les cinq octets sans caractère gardent leur valeur, comme .NET.
const CP1252_80_9F: [u16; 32] = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D,
    0x017D, 0x008F, 0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
    0x0153, 0x009D, 0x017E, 0x0178,
];

/// Des octets lus en Windows-1252 (la page de code « ANSI » d'un Windows français ou anglais).
pub fn depuis_cp1252(octets: &[u8]) -> String {
    octets
        .iter()
        .map(|&o| {
            let point = if (0x80..=0x9F).contains(&o) { CP1252_80_9F[usize::from(o - 0x80)] } else { u16::from(o) };
            char::from_u32(u32::from(point)).unwrap_or('\u{FFFD}')
        })
        .collect()
}

/// L'encodage à utiliser quand le fichier n'a pas de marque (BOM).
#[derive(Clone, Copy)]
pub enum SansMarque {
    /// UTF-8 (comme `[IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)`)
    Utf8,
    /// Windows-1252 (comme `Get-Content` de Windows PowerShell 5.1)
    Ansi,
}

/// Le texte d'un fichier : sa marque d'encodage (UTF-8, UTF-16, UTF-32) est suivie, sinon `sans_marque`.
/// Les octets invalides deviennent « � », comme avec .NET.
pub fn decoder_fichier(octets: &[u8], sans_marque: SansMarque) -> String {
    if let Some(reste) = octets.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(reste).into_owned();
    }
    if let Some(reste) = octets.strip_prefix(&[0xFF, 0xFE, 0x00, 0x00]) {
        return utf32(reste, u32::from_le_bytes);
    }
    if let Some(reste) = octets.strip_prefix(&[0x00, 0x00, 0xFE, 0xFF]) {
        return utf32(reste, u32::from_be_bytes);
    }
    if let Some(reste) = octets.strip_prefix(&[0xFF, 0xFE]) {
        return utf16(reste, u16::from_le_bytes);
    }
    if let Some(reste) = octets.strip_prefix(&[0xFE, 0xFF]) {
        return utf16(reste, u16::from_be_bytes);
    }
    match sans_marque {
        SansMarque::Utf8 => String::from_utf8_lossy(octets).into_owned(),
        SansMarque::Ansi => depuis_cp1252(octets),
    }
}

fn utf16(octets: &[u8], lire: fn([u8; 2]) -> u16) -> String {
    let unites: Vec<u16> = octets.as_chunks::<2>().0.iter().map(|c| lire(*c)).collect();
    String::from_utf16_lossy(&unites)
}

fn utf32(octets: &[u8], lire: fn([u8; 4]) -> u32) -> String {
    octets.as_chunks::<4>().0.iter().map(|c| char::from_u32(lire(*c)).unwrap_or('\u{FFFD}')).collect()
}

/// Un caractère en majuscule « invariante » simple, comme `OrdinalIgnoreCase` de .NET (un seul caractère : « ß »
/// reste « ß »).
#[cfg(feature = "paquet")]
fn majuscule(c: char) -> char {
    let mut m = c.to_uppercase();
    match (m.next(), m.next()) {
        (Some(u), None) => u,
        _ => c,
    }
}

/// `texte.StartsWith(debut, OrdinalIgnoreCase)` : la longueur en octets du début trouvé dans `texte`, ou `None`.
#[cfg(feature = "paquet")]
pub fn commence_par_sans_casse(texte: &str, debut: &str) -> Option<usize> {
    let mut t = texte.char_indices();
    for d in debut.chars() {
        let (_, c) = t.next()?;
        if majuscule(c) != majuscule(d) {
            return None;
        }
    }
    Some(t.next().map_or(texte.len(), |(i, _)| i))
}

/// Comparaison sans tenir compte des majuscules (`-ieq`, `OrdinalIgnoreCase`).
#[cfg(feature = "paquet")]
pub fn egal_sans_casse(a: &str, b: &str) -> bool {
    a.chars().count() == b.chars().count() && commence_par_sans_casse(a, b).is_some()
}

/// Les lignes d'un texte, coupées comme `StreamReader.ReadLine` (« \r\n », « \n » ou « \r »).
pub fn lignes(texte: &str) -> impl Iterator<Item = &str> {
    let mut reste = Some(texte);
    std::iter::from_fn(move || {
        let t = reste?;
        if t.is_empty() {
            reste = None;
            return None;
        }
        match t.find(['\r', '\n']) {
            Some(i) => {
                let suite = if t[i..].starts_with("\r\n") { i + 2 } else { i + 1 };
                reste = Some(&t[suite..]);
                Some(&t[..i])
            }
            None => {
                reste = None;
                Some(t)
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cp1252() {
        assert_eq!(depuis_cp1252(b"th\xE8me \x80 \xA0"), "thème € \u{A0}");
    }

    #[test]
    fn marques() {
        assert_eq!(decoder_fichier(b"\xEF\xBB\xBFabc", SansMarque::Ansi), "abc");
        assert_eq!(decoder_fichier(b"\xFF\xFEa\x00b\x00", SansMarque::Utf8), "ab");
        assert_eq!(decoder_fichier(b"\xE9", SansMarque::Ansi), "é");
        assert_eq!(decoder_fichier(b"\xE9", SansMarque::Utf8), "\u{FFFD}");
    }

    #[cfg(feature = "paquet")]
    #[test]
    fn sans_casse() {
        assert_eq!(commence_par_sans_casse("APPLI\\x", "appli\\"), Some(6));
        assert_eq!(commence_par_sans_casse("Appli", "Appli\\"), None);
        assert!(egal_sans_casse("Mindset.EXE", "mindset.exe"));
        assert!(!egal_sans_casse("Mindset.exe2", "mindset.exe"));
    }

    #[test]
    fn coupe_des_lignes() {
        let l: Vec<&str> = lignes("a\r\nb\nc\rd\r\n").collect();
        assert_eq!(l, ["a", "b", "c", "d"]);
        let l: Vec<&str> = lignes("a\n\nb").collect();
        assert_eq!(l, ["a", "", "b"]);
        assert_eq!(lignes("").count(), 0);
    }
}
