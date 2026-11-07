//! Les numéros de version lus EXACTEMENT comme `[version]` de .NET (Version.Parse), que paquets.ps1 utilise pour
//! comparer les versions publiées (`Test-VersionPlusRecente`, `Get-Preversion`, `Get-PreversionSansApi`).
//!
//! `suite_commun::version` est plus strict (chiffres seulement) : c'est voulu là-bas (version.json, installation).
//! Ici, une version publiée sur GitHub peut porter un nom comme « v 1.5 » ; .NET l'accepte (espaces et signe « + »
//! permis autour de chaque nombre, zéros devant), la version PowerShell la compare donc : ce bloc fait pareil, sinon
//! il ne proposerait pas la même mise à jour (juges : tests\juges\versions.json).

use std::cmp::Ordering;

/// Une version : 2 à 4 nombres ; un nombre absent vaut -1 (« 1.2 » est plus ancienne que « 1.2.0 »).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct VersionNet(pub [i64; 4]);

/// Les blancs de `NumberStyles.Integer` (avant et après le nombre) : tabulation à retour chariot, et l'espace.
fn blanc(c: char) -> bool {
    matches!(c, '\u{9}'..='\u{D}' | ' ')
}

/// Un morceau, comme `Int32.TryParse(morceau, NumberStyles.Integer, InvariantCulture)` puis « au moins 0 ».
fn morceau(m: &str) -> Option<i64> {
    let m = m.trim_matches(blanc);
    let (negatif, chiffres) = match m.as_bytes().first() {
        Some(b'+') => (false, &m[1..]),
        Some(b'-') => (true, &m[1..]),
        _ => (false, m),
    };
    if chiffres.is_empty() || !chiffres.bytes().all(|o| o.is_ascii_digit()) {
        return None;
    }
    let mut v: i64 = 0;
    for o in chiffres.bytes() {
        v = v.checked_mul(10)?.checked_add(i64::from(o - b'0'))?;
        if v > i64::from(i32::MAX) + 1 {
            return None;
        }
    }
    let v = if negatif { -v } else { v };
    if v > i64::from(i32::MAX) || v < 0 {
        return None;
    }
    Some(v)
}

impl VersionNet {
    /// `[version]$texte` ; `None` là où .NET lève une erreur.
    pub fn lire(texte: &str) -> Option<VersionNet> {
        let morceaux: Vec<&str> = texte.split('.').collect();
        if !(2..=4).contains(&morceaux.len()) {
            return None;
        }
        let mut v = [-1i64; 4];
        for (i, m) in morceaux.iter().enumerate() {
            v[i] = morceau(m)?;
        }
        Some(VersionNet(v))
    }

    /// `ToString()` : les nombres présents, séparés par des points.
    pub fn texte(&self) -> String {
        self.0.iter().filter(|n| **n >= 0).map(|n| n.to_string()).collect::<Vec<_>>().join(".")
    }
}

/// `Test-VersionPlusRecente` (paquets.ps1) : vrai si `distante` est strictement plus récente que `locale` ; faux si
/// l'une des deux est illisible.
pub fn plus_recente(distante: &str, locale: &str) -> bool {
    match (VersionNet::lire(distante), VersionNet::lire(locale)) {
        (Some(a), Some(b)) => a.cmp(&b) == Ordering::Greater,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comme_dotnet() {
        assert_eq!(VersionNet::lire(" 1.2").map(|v| v.texte()).as_deref(), Some("1.2"));
        assert_eq!(VersionNet::lire("01.+2 ").map(|v| v.texte()).as_deref(), Some("1.2"));
        assert_eq!(VersionNet::lire("-0.1").map(|v| v.texte()).as_deref(), Some("0.1"));
        for faux in ["", "1", "1.", "1.-2", "1.2.3.4.5", "1,2", "2147483648.0", "١.٢", "+ 1.2"] {
            assert!(VersionNet::lire(faux).is_none(), "{faux}");
        }
        assert!(plus_recente("1.2.0", "1.2"));
        assert!(!plus_recente("1.2", "1.2.0"));
        assert!(plus_recente("1.10", "1.9.9"));
        assert!(!plus_recente("abc", "1.0"));
    }
}
