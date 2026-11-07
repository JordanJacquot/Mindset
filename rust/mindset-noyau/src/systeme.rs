//! Le port vers Windows pour ce dont plusieurs blocs ont besoin : les programmes qui tournent et leur chemin
//! (`MSProcessus`, natif.cs:507-700), les verrous et signaux nommés des applis (`Mutex.OpenExisting`,
//! `EventWaitHandle.OpenExisting`), lancer et arrêter un programme, ouvrir par l'Explorateur, savoir si Mindset a les
//! droits administrateur.
//!
//! Le vrai port est [`crate::windows::SystemeWindows`] (dans ce noyau). Les tests ont [`FauxSysteme`] : des programmes
//! inventés, des verrous posés à la main, et la liste de ce qui aurait été lancé ou arrêté. Ce qui ne sert qu'à un
//! bloc (raccourcis, registre, tâches planifiées, fenêtres d'une autre appli, icône près de l'horloge...) est dans le
//! module `windows` de ce bloc, derrière son propre trait.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

use crate::contexte::verrou;

/// Un programme qui tourne.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Processus {
    pub pid: u32,
    /// Le nom de son fichier (« Mindset.exe »)
    pub nom: String,
    /// Son chemin complet (`QueryFullProcessImageName`, mis en forme comme `GetFullPath`), `None` si Windows refuse
    pub chemin: Option<String>,
    /// Son heure de création (100 ns depuis 1601, comme `FILETIME`)
    pub creation: u64,
}

/// Un programme à lancer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lancer {
    pub exe: PathBuf,
    /// Les arguments, chacun mis entre guillemets s'il le faut (règles de Windows)
    pub arguments: Vec<String>,
    /// Le dossier de travail
    pub dossier: PathBuf,
    /// Sans les droits administrateur, même si Mindset les a (`MSLanceur.SansAdmin`, avec le jeton de l'Explorateur)
    pub sans_droits: bool,
}

/// Ce que plusieurs blocs demandent à Windows.
pub trait Systeme: Send + Sync {
    /// Tous les programmes qui tournent (`MSProcessus.Releve`, avec le chemin gardé : `CheminGarde`).
    fn processus(&self) -> Vec<Processus>;
    /// Le verrou nommé existe, ou Windows refuse de l'ouvrir (il existe, à un programme administrateur).
    fn verrou_existe(&self, nom: &str) -> bool;
    /// Lève le signal nommé d'un autre programme (`EventWaitHandle.OpenExisting(...).Set()`) : `false` s'il n'existe
    /// pas. Jamais `Local\Mindset-Afficher` (le sien) : l'hôte refuse.
    fn lever_signal(&self, nom: &str) -> bool;
    /// Lance un programme (sans console : CREATE_NO_WINDOW), rend son numéro de processus.
    fn lancer(&self, l: &Lancer) -> Result<u32, String>;
    /// Arrête un programme (`Process.Kill`).
    fn arreter(&self, pid: u32) -> Result<(), String>;
    /// Attend la fin d'un programme, au plus `ms` millisecondes : `true` s'il est fini.
    fn attendre_fin(&self, pid: u32, ms: u32) -> bool;
    /// Ouvre une adresse, un dossier ou un fichier par l'Explorateur (`Start-Process $x`).
    fn ouvrir(&self, cible: &str) -> Result<(), String>;
    /// Mindset tourne-t-il avec les droits administrateur ?
    fn est_admin(&self) -> bool;
}

/// `Dossier` de natif.cs : le chemin complet du dossier terminé par « \ », `None` s'il est vide ou refusé.
pub fn dossier_normal(d: &str) -> Option<String> {
    if d.is_empty() {
        return None;
    }
    let c = suite_commun::chemins::chemin_complet(d).ok()?;
    Some(format!("{}\\", c.trim_end_matches('\\')))
}

fn commence_par(texte: &str, debut: &str) -> bool {
    suite_commun::chemins::apres_debut(texte, debut).is_some()
}

/// `MSProcessus.Dans` : le chemin est-il dans ce dossier (sous-dossiers compris) ?
pub fn dans(chemin: Option<&str>, dossier: &str) -> bool {
    match (chemin, dossier_normal(dossier)) {
        (Some(c), Some(d)) => commence_par(c, &d),
        _ => false,
    }
}

/// `MSProcessus.DansDossier` : les programmes lancés depuis `dossier` (sous-dossiers compris) ; `noms` : seulement
/// ces programmes-là, directement dans le dossier ; jamais `exclu` (Mindset lui-même), ni un programme du dossier
/// `interdit` (celui de Mindset).
pub fn dans_dossier(liste: &[Processus], dossier: &str, noms: Option<&[&str]>, exclu: u32, interdit: &str) -> Vec<u32> {
    let Some(d) = dossier_normal(dossier) else { return Vec::new() };
    let mut r = Vec::new();
    for p in liste {
        if p.pid == exclu {
            continue;
        }
        if let Some(n) = noms
            && !n.iter().any(|x| x.eq_ignore_ascii_case(&p.nom))
        {
            continue;
        }
        let Some(c) = p.chemin.as_deref() else { continue };
        if !commence_par(c, &d) {
            continue;
        }
        if noms.is_some() {
            let parent = suite_commun::chemins::parent(c);
            if !suite_commun::chemins::egal(&format!("{}\\", parent.trim_end_matches('\\')), &d) {
                continue;
            }
        }
        if dans(Some(c), interdit) {
            continue;
        }
        r.push(p.pid);
    }
    r
}

/// `MSProcessus.Chemins` : les chemins (sans doublon) des programmes qui tournent sous ces noms de fichier.
pub fn chemins_nommes(liste: &[Processus], noms: &[&str]) -> Vec<String> {
    let mut r: Vec<String> = Vec::new();
    for p in liste {
        if !noms.iter().any(|n| n.eq_ignore_ascii_case(&p.nom)) {
            continue;
        }
        if let Some(c) = &p.chemin
            && !r.contains(c)
        {
            r.push(c.clone());
        }
    }
    r
}

/// Le faux Windows des tests.
#[derive(Debug, Default)]
pub struct FauxSysteme {
    processus: Mutex<Vec<Processus>>,
    verrous: Mutex<HashSet<String>>,
    signaux: Mutex<HashSet<String>>,
    pub admin: Mutex<bool>,
    lances: Mutex<Vec<Lancer>>,
    arretes: Mutex<Vec<u32>>,
    ouverts: Mutex<Vec<String>>,
    signaux_leves: Mutex<Vec<String>>,
    refus_lancement: Mutex<Option<String>>,
    pid_suivant: Mutex<u32>,
}

impl FauxSysteme {
    /// Un programme qui tourne.
    pub fn ajouter_processus(&self, pid: u32, chemin: &str, creation: u64) {
        let nom = suite_commun::chemins::feuille(chemin).to_string();
        verrou(&self.processus).push(Processus { pid, nom, chemin: Some(chemin.to_string()), creation });
    }
    /// Il s'arrête.
    pub fn retirer_processus(&self, pid: u32) {
        verrou(&self.processus).retain(|p| p.pid != pid);
    }
    /// Un verrou nommé tenu (`Local\Nevermind-Instance`), ou rendu.
    pub fn poser_verrou(&self, nom: &str, tenu: bool) {
        let mut v = verrou(&self.verrous);
        if tenu {
            v.insert(nom.into());
        } else {
            v.remove(nom);
        }
    }
    /// Un signal nommé qui existe (`Local\Evermind-Afficher`).
    pub fn poser_signal(&self, nom: &str) {
        verrou(&self.signaux).insert(nom.into());
    }
    /// Le prochain lancement sera refusé avec ce message.
    pub fn refuser_lancement(&self, message: Option<&str>) {
        *verrou(&self.refus_lancement) = message.map(str::to_string);
    }
    /// Ce qui a été lancé.
    pub fn lances(&self) -> Vec<Lancer> {
        verrou(&self.lances).clone()
    }
    /// Ce qui a été arrêté.
    pub fn arretes(&self) -> Vec<u32> {
        verrou(&self.arretes).clone()
    }
    /// Ce qui a été ouvert par l'Explorateur.
    pub fn ouverts(&self) -> Vec<String> {
        verrou(&self.ouverts).clone()
    }
    /// Les signaux levés.
    pub fn signaux_leves(&self) -> Vec<String> {
        verrou(&self.signaux_leves).clone()
    }
}

impl Systeme for FauxSysteme {
    fn processus(&self) -> Vec<Processus> {
        verrou(&self.processus).clone()
    }
    fn verrou_existe(&self, nom: &str) -> bool {
        verrou(&self.verrous).contains(nom)
    }
    fn lever_signal(&self, nom: &str) -> bool {
        if !verrou(&self.signaux).contains(nom) {
            return false;
        }
        verrou(&self.signaux_leves).push(nom.into());
        true
    }
    fn lancer(&self, l: &Lancer) -> Result<u32, String> {
        if let Some(m) = verrou(&self.refus_lancement).take() {
            return Err(m);
        }
        verrou(&self.lances).push(l.clone());
        let mut n = verrou(&self.pid_suivant);
        *n += 1;
        Ok(50_000 + *n)
    }
    fn arreter(&self, pid: u32) -> Result<(), String> {
        verrou(&self.arretes).push(pid);
        self.retirer_processus(pid);
        Ok(())
    }
    fn attendre_fin(&self, pid: u32, _ms: u32) -> bool {
        !verrou(&self.processus).iter().any(|p| p.pid == pid)
    }
    fn ouvrir(&self, cible: &str) -> Result<(), String> {
        verrou(&self.ouverts).push(cible.into());
        Ok(())
    }
    fn est_admin(&self) -> bool {
        *verrou(&self.admin)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn programmes_d_un_dossier() {
        let f = FauxSysteme::default();
        f.ajouter_processus(10, r"C:\Program Files\Mindset\Nevermind\Mindset.exe", 1);
        f.ajouter_processus(11, r"C:\Program Files\Mindset\Nevermind\outils\PresentMon.exe", 1);
        f.ajouter_processus(12, r"C:\Program Files\Mindset\Mindset\Mindset.exe", 1);
        f.ajouter_processus(13, r"C:\Program Files\Mindset\NevermindBis\Mindset.exe", 1);
        f.ajouter_processus(14, r"c:\program files\mindset\nevermind\Nevermind.exe", 1);
        let l = f.processus();
        let tous =
            dans_dossier(&l, r"C:\Program Files\Mindset\Nevermind", None, 0, r"C:\Program Files\Mindset\Mindset");
        assert_eq!(tous, vec![10, 11, 14]);
        let hotes = dans_dossier(
            &l,
            r"C:\Program Files\Mindset\Nevermind\",
            Some(&["Nevermind.exe", "Mindset.exe"]),
            10,
            r"C:\Program Files\Mindset\Mindset",
        );
        assert_eq!(hotes, vec![14], "sans l'exclu, sans les programmes d'aide, sans le dossier voisin");
        let m = dans_dossier(&l, r"C:\Program Files\Mindset", None, 0, r"C:\Program Files\Mindset\Mindset");
        assert!(!m.contains(&12), "jamais Mindset lui-même");
        assert!(dans_dossier(&l, "", None, 0, "").is_empty());
        assert_eq!(chemins_nommes(&l, &["mindset.exe"]).len(), 3);
    }
}
