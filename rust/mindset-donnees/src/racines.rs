//! Où sont les programmes et les données de la suite (donnees.ps1:4-38).
//!
//! Mindset s'installe sur le disque choisi à l'installation :
//! - par défaut : programmes `C:\Program Files\Mindset\<Appli>`, données `%LOCALAPPDATA%\Mindset\<Appli>` ;
//! - autre disque : programmes `X:\Mindset\Programmes\<Appli>`, données `X:\Mindset\Donnees\<Appli>`.
//!
//! L'emplacement se déduit toujours de celui du programme (protégé : seul un administrateur peut y écrire), jamais
//! d'un fichier modifiable. suite.json reste toujours dans `%LOCALAPPDATA%\Mindset`.

use suite_commun::chemins::{egal, feuille, joindre, parent};

/// Les racines d'une installation (`Get-RacinesDepuis`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Racines {
    /// `$Racines.Programmes` : `X:\Mindset\Programmes` ou `<Program Files>\Mindset`
    pub programmes: String,
    /// `$Racines.Donnees` : `X:\Mindset\Donnees` ou `%LOCALAPPDATA%\Mindset`
    pub donnees: String,
    /// `$Racines.Disque` : la lettre du disque (en majuscule), vide pour Program Files
    pub disque: String,
}

/// `Get-RacinesDepuis` : les racines d'une installation dont on connaît le dossier du programme Mindset
/// (`...\Mindset`). `program_files` : `$env:ProgramFiles` ; `suite_file_dir` : `%LOCALAPPDATA%\Mindset`.
///
/// Comme `Split-Path`, les barres « / » comptent comme « \ » et les barres de fin sont ignorées.
pub fn racines_depuis(dossier_mindset: &str, program_files: &str, suite_file_dir: &str) -> Racines {
    let d = dossier_mindset.replace('/', "\\");
    let p = parent(&d);
    let m = parent(p);
    if egal(feuille(p), "Programmes") && !m.is_empty() && egal(feuille(m), "Mindset") {
        let disque = m.chars().next().map(|c| c.to_uppercase().collect::<String>()).unwrap_or_default();
        return Racines { programmes: p.to_string(), donnees: joindre(m, "Donnees"), disque };
    }
    defaut(program_files, suite_file_dir)
}

/// Les racines par défaut (Program Files et le profil de l'utilisateur).
fn defaut(program_files: &str, suite_file_dir: &str) -> Racines {
    Racines {
        programmes: joindre(program_files, "Mindset"),
        donnees: suite_file_dir.to_string(),
        disque: String::new(),
    }
}

/// Les racines de CE Mindset (donnees.ps1:25-33) : installé, elles viennent de son propre dossier ; sinon (lancé
/// depuis le dossier téléchargé), du Mindset inscrit dans « Applications installées » (`inscrit` : InstallLocation,
/// écrit en administrateur), s'il contient bien Mindset.exe ; sans installation, les racines par défaut.
/// `inscrit` n'est appelé que si ce Mindset n'est pas installé. Rend aussi vrai si le registre a été lu.
pub fn racines_de(
    mon_dossier: &str,
    program_files: &str,
    suite_file_dir: &str,
    inscrit: impl FnOnce() -> Option<String>,
    existe: impl Fn(&str) -> bool,
) -> (Racines, bool) {
    let r = racines_depuis(mon_dossier, program_files, suite_file_dir);
    if egal(feuille(mon_dossier), "Mindset") && egal(&joindre(&r.programmes, "Mindset"), mon_dossier) {
        return (r, false);
    }
    let mut r = defaut(program_files, suite_file_dir);
    if let Some(i) = inscrit().filter(|i| !i.is_empty())
        && existe(&joindre(&i, "Mindset.exe"))
    {
        r = racines_depuis(&i, program_files, suite_file_dir);
    }
    (r, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn racines() {
        let pf = r"C:\Program Files";
        let local = r"C:\Users\Élodie\AppData\Local\Mindset";
        let r = racines_depuis(r"D:\Mindset\Programmes\Mindset", pf, local);
        assert_eq!(
            r,
            Racines {
                programmes: r"D:\Mindset\Programmes".into(),
                donnees: r"D:\Mindset\Donnees".into(),
                disque: "D".into()
            }
        );
        let r = racines_depuis(r"C:\Program Files\Mindset\Mindset", pf, local);
        assert_eq!(
            r,
            Racines { programmes: r"C:\Program Files\Mindset".into(), donnees: local.into(), disque: String::new() }
        );
        assert_eq!(racines_depuis(r"e:/mindset/programmes/Mindset/", pf, local).disque, "E");
        assert_eq!(racines_depuis(r"C:\", pf, local).disque, "");
        assert_eq!(racines_depuis("", pf, local).disque, "");
    }

    #[test]
    fn choix_des_racines() {
        let pf = r"C:\Program Files";
        let local = r"C:\L\Mindset";
        let jamais = || -> Option<String> { panic!("le registre ne doit pas être lu") };
        let (r, lu) = racines_de(r"C:\Program Files\Mindset\Mindset", pf, local, jamais, |_| true);
        assert!(!lu && r.disque.is_empty());
        let (r, lu) = racines_de(r"D:\Mindset\Programmes\Mindset", pf, local, jamais, |_| true);
        assert!(!lu && r.disque == "D");
        let inscrit = || Some(r"E:\Mindset\Programmes\Mindset".to_string());
        let (r, lu) = racines_de(r"C:\Users\x\Downloads\Mindset", pf, local, inscrit, |p| p.ends_with("Mindset.exe"));
        assert!(lu && r.disque == "E");
        let (r, _) = racines_de(r"C:\Users\x\Downloads\Mindset", pf, local, inscrit, |_| false);
        assert_eq!(r.programmes, r"C:\Program Files\Mindset");
        let (r, _) = racines_de(r"C:\Users\x\Downloads\Mindset", pf, local, || None, |_| true);
        assert_eq!(r.donnees, local);
    }
}
