//! Les prochains rendez-vous d'Evermind sur sa carte (`Get-ProchainsRdv`, `Format-QuandRdv`, accueil.ps1:184-194).

use mindset_noyau::moment::{self, HeureLocale};

use crate::etat_appli::Rdv;

/// Le jour (à minuit) d'un moment, en jours depuis 1970.
fn jour(h: &HeureLocale) -> i64 {
    moment::secondes(&HeureLocale { heure: 0, minute: 0, seconde: 0, ..*h }).div_euclid(86_400)
}

/// Les 3 prochains rendez-vous encore à venir (ceux d'une journée entière restent toute la journée).
pub fn prochains(liste: &[Rdv], maintenant: &HeureLocale) -> Vec<Rdv> {
    liste
        .iter()
        .filter(|r| {
            if r.journee {
                jour(&r.quand) >= jour(maintenant)
            } else {
                moment::secondes(&r.quand) >= moment::secondes(maintenant)
            }
        })
        .take(3)
        .cloned()
        .collect()
}

const JOURS: [&str; 7] = ["Jeudi", "Vendredi", "Samedi", "Dimanche", "Lundi", "Mardi", "Mercredi"];
// (les abréviations de .NET pour fr-FR, `MMM`)
const MOIS: [&str; 12] =
    ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."];

/// « Aujourd'hui 21:15 », « Demain », « Mardi 18:00 », « 14 nov. 12:00 »...
pub fn quand(r: &Rdv, maintenant: &HeureLocale) -> String {
    let j = jour(&r.quand) - jour(maintenant);
    let q = &r.quand;
    let jour_texte = match j {
        0 => "Aujourd'hui".to_string(),
        1 => "Demain".to_string(),
        // (le 01/01/1970 était un jeudi)
        _ if j < 7 => JOURS[jour(q).rem_euclid(7) as usize].to_string(),
        _ => format!("{} {}", q.jour, MOIS[(q.mois as usize).clamp(1, 12) - 1]),
    };
    if r.journee { jour_texte } else { format!("{jour_texte} {:02}:{:02}", q.heure, q.minute) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(t: &str) -> HeureLocale {
        moment::lire_iso(t).unwrap()
    }

    #[test]
    fn jours() {
        let m = h("2026-11-07T20:00:00");
        let r = |q: &str, journee| Rdv { id: String::new(), titre: String::new(), quand: h(q), journee };
        assert_eq!(quand(&r("2026-11-07T21:15:00", false), &m), "Aujourd'hui 21:15");
        assert_eq!(quand(&r("2026-11-08T00:00:00", true), &m), "Demain");
        assert_eq!(quand(&r("2026-11-10T18:00:00", false), &m), "Mardi 18:00");
        assert_eq!(quand(&r("2026-11-14T12:00:00", false), &m), "14 nov. 12:00");
        let l = vec![r("2026-11-07T19:59:59", false), r("2026-11-07T00:00:00", true), r("2026-11-07T20:00:00", false)];
        assert_eq!(prochains(&l, &m).len(), 2);
    }
}
