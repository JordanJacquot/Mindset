//! Les règles de noms d'installer-admin.ps1, écrites sans expressions régulières (même sens que les motifs cités).

/// Un caractère interdit dans un nom de fichier : `\ / : * ? " < > |` et les caractères de contrôle.
fn interdit(c: char) -> bool {
    matches!(c, '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || (c as u32) < 0x20
}

/// `^[^\\/:*?"<>|\x00-\x1f]+\z` : un nom de fichier ou de dossier seul.
pub fn nom_fichier(nom: &str) -> bool {
    !nom.is_empty() && !nom.chars().any(interdit)
}

/// `$RegleProgramme` : `^[^\\/:*?"<>|\x00-\x1f]+\.exe\z` (majuscules permises) : un nom de programme seul.
pub fn programme(nom: &str) -> bool {
    nom_fichier(nom) && nom.chars().count() > 4 && nom.to_lowercase().ends_with(".exe")
}

/// `$RegleTacheAide` : `^[A-Za-z0-9 ]{1,40} \(aide\)\z`, majuscules comprises (`-cmatch`).
pub fn tache_aide(nom: &str) -> bool {
    let Some(debut) = nom.strip_suffix(" (aide)") else { return false };
    (1..=40).contains(&debut.len()) && debut.bytes().all(|o| o.is_ascii_alphanumeric() || o == b' ')
}

/// `^[a-z0-9-]{1,40}\z` (`-cnotmatch`) : l'identifiant d'une appli.
pub fn id_appli(id: &str) -> bool {
    (1..=40).contains(&id.len()) && id.bytes().all(|o| o.is_ascii_lowercase() || o.is_ascii_digit() || o == b'-')
}

/// Un caractère « de mot » (`\w` de .NET : lettres, chiffres, souligné).
fn mot(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Le nom d'une appli dans apps.json (celui de son dossier) : `^[\w][\w .-]{0,39}\z`, sans point final, et jamais
/// « Mindset ».
pub fn nom_appli(nom: &str) -> bool {
    let mut c = nom.chars();
    let Some(premier) = c.next() else { return false };
    let reste: Vec<char> = c.collect();
    mot(premier)
        && reste.len() <= 39
        && reste.iter().all(|&x| mot(x) || matches!(x, ' ' | '.' | '-'))
        && !nom.ends_with('.')
        && !suite_commun::chemins::egal(nom, "Mindset")
}

/// `^[A-Za-z]:\\[^%"*?<>|]+$` : le dossier d'un profil, une fois %SystemDrive% remplacé.
pub fn dossier_profil(p: &str) -> bool {
    suite_commun::chemins::commence_par_disque(p)
        && p.len() > 3
        && !p[3..].chars().any(|c| matches!(c, '%' | '"' | '*' | '?' | '<' | '>' | '|'))
}

/// `^[A-Za-z]:\\[^"*?<>|]+\z` : l'ancienne copie d'une appli, par son chemin complet.
pub fn chemin_ancienne_copie(p: &str) -> bool {
    suite_commun::chemins::commence_par_disque(p)
        && p.len() > 3
        && !p[3..].chars().any(|c| matches!(c, '"' | '*' | '?' | '<' | '>' | '|'))
}

/// `^S-1-[\d-]+$` (sans tenir compte des majuscules) : un compte déjà donné par son SID.
pub fn forme_sid(t: &str) -> bool {
    t.len() > 4 && t[..4].eq_ignore_ascii_case("S-1-") && t[4..].bytes().all(|o| o.is_ascii_digit() || o == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noms() {
        assert!(programme("Appli.exe") && programme("Aide.EXE") && !programme(r"..\Appli.exe") && !programme(".exe"));
        assert!(
            tache_aide("Appli (aide)")
                && !tache_aide("appli (Aide)")
                && !tache_aide(" (aide)")
                && !tache_aide("A (aide)\n")
        );
        assert!(id_appli("nevermind") && !id_appli("Nevermind") && !id_appli(""));
        assert!(
            nom_appli("Nevermind")
                && nom_appli("Appli 2")
                && !nom_appli(r"..\Mindset")
                && !nom_appli("mindset")
                && !nom_appli("A.")
        );
        assert!(
            dossier_profil(r"C:\Users\Élodie") && !dossier_profil(r"%SystemDrive%\Users\x") && !dossier_profil(r"C:\")
        );
        assert!(forme_sid("S-1-5-18") && forme_sid("s-1-5-21-1") && !forme_sid("SYSTEM"));
    }
}
