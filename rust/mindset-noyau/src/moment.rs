//! L'heure locale du PC (`Get-Date`) et les calculs de dates dont Mindset a besoin : le format `s` du journal et des
//! réglages (« 2026-11-07T21:05:09 »), la différence entre deux moments (`(Get-Date) - $x`), ajouter des secondes
//! (`AddHours`, `AddMinutes`).
//!
//! Les moments sont des heures LOCALES sans fuseau, comme les `[datetime]` de la version PowerShell écrits avec
//! `ToString('s')` : les comparer entre eux suffit (un changement d'heure peut décaler d'une heure, comme avant).

pub use suite_commun::json_sur::HeureLocale;

/// L'heure locale du PC (`Get-Date`). Les blocs prennent plutôt `Contexte::heure`, figée en test.
pub fn heure_du_pc() -> HeureLocale {
    suite_commun::json_sur::heure_du_pc()
}

/// Le moment au format `s` : « 2026-11-07T21:05:09 » (`(Get-Date).ToString('s')`).
pub fn iso(h: &HeureLocale) -> String {
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}", h.annee, h.mois, h.jour, h.heure, h.minute, h.seconde)
}

/// Lit un moment écrit au format `s` (ou avec une fraction de seconde, ou un espace à la place du T, comme
/// `[datetime]` les accepte) ; `None` sinon.
pub fn lire_iso(t: &str) -> Option<HeureLocale> {
    let t = t.trim();
    let (date, heure) = t.split_once(['T', ' '])?;
    let mut d = date.split('-');
    let annee: i32 = d.next()?.parse().ok()?;
    let mois: u32 = d.next()?.parse().ok()?;
    let jour: u32 = d.next()?.parse().ok()?;
    if d.next().is_some() {
        return None;
    }
    let heure = heure.split(['.', 'Z', '+']).next()?;
    let mut h = heure.split(':');
    let hh: u32 = h.next()?.parse().ok()?;
    let mm: u32 = h.next()?.parse().ok()?;
    let ss: u32 = h.next().unwrap_or("0").parse().ok()?;
    let r = HeureLocale { annee, mois, jour, heure: hh, minute: mm, seconde: ss };
    if !(1..=12).contains(&mois) || jour == 0 || jour > jours_du_mois(annee, mois) || hh > 23 || mm > 59 || ss > 59 {
        return None;
    }
    Some(r)
}

fn bissextile(a: i32) -> bool {
    (a % 4 == 0 && a % 100 != 0) || a % 400 == 0
}

fn jours_du_mois(a: i32, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if bissextile(a) => 29,
        _ => 28,
    }
}

/// Le nombre de jours depuis le 1er janvier 1970 (calendrier grégorien).
fn jours_depuis_1970(a: i32, m: u32, j: u32) -> i64 {
    let (a, m) = if m <= 2 { (a as i64 - 1, m as i64 + 9) } else { (a as i64, m as i64 - 3) };
    let era = a.div_euclid(400);
    let yoe = a - era * 400;
    let doy = (153 * m + 2) / 5 + j as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Le moment en secondes (heure locale comptée depuis 1970) : pour comparer et soustraire.
pub fn secondes(h: &HeureLocale) -> i64 {
    jours_depuis_1970(h.annee, h.mois, h.jour) * 86400 + h.heure as i64 * 3600 + h.minute as i64 * 60 + h.seconde as i64
}

/// Le moment de ces secondes (l'inverse de [`secondes`]).
pub fn depuis_secondes(s: i64) -> HeureLocale {
    let jours = s.div_euclid(86400);
    let reste = s.rem_euclid(86400);
    let z = jours + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let jour = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let mois = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let annee = (yoe + era * 400 + i64::from(mois <= 2)) as i32;
    HeureLocale {
        annee,
        mois,
        jour,
        heure: (reste / 3600) as u32,
        minute: (reste % 3600 / 60) as u32,
        seconde: (reste % 60) as u32,
    }
}

/// `$h.AddSeconds(n)`.
pub fn ajouter(h: &HeureLocale, secondes_en_plus: i64) -> HeureLocale {
    depuis_secondes(secondes(h) + secondes_en_plus)
}

/// `(b - a).TotalSeconds`, à la seconde.
pub fn ecart(a: &HeureLocale, b: &HeureLocale) -> i64 {
    secondes(b) - secondes(a)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(annee: i32, mois: u32, jour: u32, heure: u32, minute: u32, seconde: u32) -> HeureLocale {
        HeureLocale { annee, mois, jour, heure, minute, seconde }
    }

    #[test]
    fn format_s() {
        assert_eq!(iso(&h(2026, 11, 7, 21, 5, 9)), "2026-11-07T21:05:09");
        assert_eq!(lire_iso("2026-11-07T21:05:09"), Some(h(2026, 11, 7, 21, 5, 9)));
        assert_eq!(lire_iso("2026-11-07 21:05"), Some(h(2026, 11, 7, 21, 5, 0)));
        assert_eq!(lire_iso("2026-11-07T21:05:09.1234567"), Some(h(2026, 11, 7, 21, 5, 9)));
        for faux in ["", "2026-13-01T00:00:00", "2026-02-30T00:00:00", "hier", "2026-11-07", "2026-11-07T25:00:00"] {
            assert_eq!(lire_iso(faux), None, "{faux}");
        }
        assert_eq!(lire_iso("2024-02-29T12:00:00"), Some(h(2024, 2, 29, 12, 0, 0)));
    }

    #[test]
    fn calculs() {
        assert_eq!(secondes(&h(1970, 1, 1, 0, 0, 0)), 0);
        let a = h(2026, 12, 31, 23, 59, 30);
        assert_eq!(ajouter(&a, 45), h(2027, 1, 1, 0, 0, 15));
        assert_eq!(ajouter(&h(2024, 3, 1, 0, 0, 0), -1), h(2024, 2, 29, 23, 59, 59));
        assert_eq!(ecart(&a, &ajouter(&a, 3600 * 6)), 21600);
        for s in [-86_401_i64, 0, 951_782_400, 1_793_000_000, 4_102_444_800] {
            assert_eq!(secondes(&depuis_secondes(s)), s);
        }
    }
}
