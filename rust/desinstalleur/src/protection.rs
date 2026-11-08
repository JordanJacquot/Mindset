//! Un dossier protégé : seuls les administrateurs peuvent le changer. La même règle que `dossier_protege` de
//! l'installateur (mindset-installateur, installateur.rs, et Test-DossierProtege de la version PowerShell) :
//! propriétaire Administrateurs, SYSTEM ou TrustedInstaller, et aucune autorisation d'écrire pour un autre compte
//! (une règle qui ne vaut que pour ce qui sera créé dessous, comme « CREATOR OWNER », ne compte pas).

/// Les comptes d'administration : Administrateurs, SYSTEM, TrustedInstaller.
const COMPTES_ADMIN: [&str; 3] =
    ["S-1-5-32-544", "S-1-5-18", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"];
/// Les droits d'écriture (écrire, ajouter, supprimer, changer les droits ou le propriétaire, et les droits
/// « génériques » tout et écriture), comme l'installateur.
const DROITS_ECRITURE: u32 = 0x2 | 0x4 | 0x10 | 0x100 | 0x10000 | 0x40 | 0x40000 | 0x80000 | 0x5000_0000;

/// Une entrée de la liste d'accès d'un dossier
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Regle {
    /// Le compte ou le groupe (SID)
    pub sid: String,
    /// Autorisation (vrai) ou refus (faux)
    pub autorise: bool,
    /// Elle ne vaut que pour ce qui sera créé dessous (InheritOnly)
    pub herite_seulement: bool,
    /// Les droits (masque de Windows)
    pub masque: u32,
}

impl Regle {
    /// Une liste d'accès absente : tout le monde peut tout faire
    pub fn tout_le_monde() -> Regle {
        Regle { sid: "S-1-1-0".into(), autorise: true, herite_seulement: false, masque: 0x1F_01FF }
    }
}

fn admin(sid: &str) -> bool {
    COMPTES_ADMIN.iter().any(|c| c.eq_ignore_ascii_case(sid))
}

/// Le dossier (son propriétaire, ses règles) est-il protégé ?
pub fn protege(proprietaire: Option<&str>, regles: &[Regle]) -> bool {
    proprietaire.is_some_and(admin)
        && regles.iter().all(|r| !r.autorise || r.herite_seulement || admin(&r.sid) || r.masque & DROITS_ECRITURE == 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(sid: &str, masque: u32) -> Regle {
        Regle { sid: sid.into(), autorise: true, herite_seulement: false, masque }
    }

    /// Les mêmes situations que le faux PC de l'installateur (tests\corpus.rs) : posé par l'installateur, ouvert aux
    /// utilisateurs, appartenant à l'utilisateur
    #[test]
    fn regle_de_l_installateur() {
        let pose = [
            r("S-1-5-32-544", 0x001F_01FF),
            r("S-1-5-32-545", 0x0012_00A9),
            Regle { herite_seulement: true, ..r("S-1-3-0", 0x001F_01FF) },
        ];
        assert!(protege(Some("S-1-5-32-544"), &pose));
        assert!(protege(Some("S-1-5-18"), &pose));
        let utilisateur = "S-1-5-21-1000000001-2000000002-3000000003-1001";
        assert!(!protege(Some(utilisateur), &pose), "il appartient à l'utilisateur");
        assert!(!protege(None, &pose));
        let ouvert = [r("S-1-5-32-544", 0x001F_01FF), r("S-1-5-32-545", 0x0013_01BF)];
        assert!(!protege(Some("S-1-5-32-544"), &ouvert), "les utilisateurs peuvent y écrire");
        // (un compte authentifié qui peut seulement y créer des dossiers, comme à la racine de C:)
        assert!(!protege(Some("S-1-5-32-544"), &[r("S-1-5-11", 0x4)]));
        // Un refus ne donne aucun droit
        assert!(protege(Some("S-1-5-32-544"), &[Regle { autorise: false, ..r("S-1-1-0", 0x001F_01FF) }]));
        assert!(!protege(Some("S-1-5-32-544"), &[Regle::tout_le_monde()]));
    }
}
