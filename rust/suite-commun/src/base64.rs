//! Décodage base64 comme `Convert.FromBase64String` de .NET (utilisé pour les clés XML).

/// Valeur d'un caractère base64 (alphabet standard), ou `None`.
fn valeur(c: u8) -> Option<u8> {
    match c {
        b'A'..=b'Z' => Some(c - b'A'),
        b'a'..=b'z' => Some(c - b'a' + 26),
        b'0'..=b'9' => Some(c - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

/// Décode un texte base64. Les espaces sont ignorés (comme .NET) ; la longueur doit être un multiple de 4, avec au
/// plus deux « = » à la fin. Tout autre écart : `None`.
pub fn decoder(texte: &str) -> Option<Vec<u8>> {
    let octets: Vec<u8> = texte.bytes().filter(|c| !matches!(c, b' ' | b'\t' | b'\r' | b'\n')).collect();
    if !octets.is_ascii() || !octets.len().is_multiple_of(4) {
        return None;
    }
    let bourrage = octets.iter().rev().take_while(|&&c| c == b'=').count();
    if bourrage > 2 {
        return None;
    }
    let utiles = &octets[..octets.len() - bourrage];
    let mut sortie = Vec::with_capacity(octets.len() / 4 * 3);
    let mut tampon: u32 = 0;
    let mut bits = 0;
    for &c in utiles {
        tampon = (tampon << 6) | u32::from(valeur(c)?);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            sortie.push((tampon >> bits) as u8);
            tampon &= (1 << bits) - 1;
        }
    }
    Some(sortie)
}

#[cfg(test)]
mod tests {
    use super::decoder;

    #[test]
    fn decodage() {
        assert_eq!(decoder("AQAB"), Some(vec![1, 0, 1]));
        assert_eq!(decoder("AAEAAQ=="), Some(vec![0, 1, 0, 1]));
        assert_eq!(decoder(" AQ\r\nAB "), Some(vec![1, 0, 1]));
        assert_eq!(decoder(""), Some(vec![]));
        assert_eq!(decoder("AQA"), None);
        assert_eq!(decoder("A==="), None);
        assert_eq!(decoder("pas une clé"), None);
        assert_eq!(decoder("AQ&B"), None);
    }
}
