//! Le port vers le mini-installateur (installations.ps1:231-476) : la tâche SYSTEM « \Mindset\Mindset (installation) »
//! (MindsetInstallateur.exe -Action demande), et à défaut la demande normale de Windows (MindsetInstallateur.exe en
//! administrateur, sa réponse dans un fichier).
//!
//! Ce port ne fait que les gestes de bas niveau ; la file des demandes (une à la fois, accusé de réception en 30 s,
//! réponse en 10 minutes, repli sur la demande de Windows) est la logique du bloc « installations », le seul à s'en
//! servir : les autres blocs lui passent leurs demandes par le signal `admin-demande` (voir [`crate::signaux`]).
//! Le vrai port (schtasks.exe sans fenêtre, HKLM en lecture, ShellExecute « runas ») est écrit par le bloc
//! « installations » (`mindset_installations::installateur_windows`). Les tests ont [`FauxInstallateur`].

use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::contexte::verrou;

/// La tâche du mini-installateur, pour cet utilisateur (`Get-EtatTacheInstallation`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EtatTache {
    /// La tâche SYSTEM inscrite pour cet utilisateur (`-Sid <le sien>`)
    Systeme,
    /// Celle d'avant (sous son compte, avec les droits les plus élevés) : elle ne sert plus qu'à se remplacer
    Ancienne,
    /// Absente, illisible, ou celle d'un autre compte
    Absente,
}

/// Une demande lancée en direct (demande de Windows), avec son fichier de réponse.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Direct {
    pub action: String,
    pub parametres: Vec<(String, String)>,
    pub resultat: PathBuf,
}

/// Les gestes de bas niveau vers le mini-installateur.
pub trait Installateur: Send + Sync {
    /// `Get-EtatTacheInstallation`
    fn etat_tache(&self) -> EtatTache;
    /// `Send-DemandeInstallation` : écrit la demande (JSON compact) dans `installation.demande` (dossier des données
    /// de Mindset) puis lance la tâche (`schtasks /Run`). `Err` : la tâche n'a pas démarré (la demande est retirée).
    fn deposer(&self, demande: &Value) -> Result<(), String>;
    /// `Remove-DemandeInstallation`
    fn retirer_demande(&self);
    /// `Get-ValeurInstallation` : `Recu`, `Resultat` ou `Restes` de `HKLM:\SOFTWARE\Mindset\Installation` (« » si
    /// absente).
    fn valeur(&self, nom: &str) -> String;
    /// `Invoke-AdminDirect` / `Start-MajMindsetDirecte` : MindsetInstallateur.exe en administrateur (demande de
    /// Windows), avec `-Action <action>`, les paramètres (`-Nom valeur`) et `-Resultat <fichier>`. Rend un numéro pour
    /// [`Installateur::direct_fini`]. `Err` : refusé (« l'autorisation de Windows a été refusée. »).
    fn lancer_direct(&self, demande: &Direct) -> Result<u32, String>;
    /// La demande directe `numero` est-elle finie (son programme s'est arrêté) ?
    fn direct_fini(&self, numero: u32) -> bool;
    /// Mindset n'attend plus la demande directe `numero` (pas finie dans le délai) : ce qui la suivait est rendu à
    /// Windows (le handle de son programme). Sans effet si elle est déjà finie.
    fn oublier_direct(&self, _numero: u32) {}
    /// Le compte (SID) d'une tâche `\Mindset\<nom>` si elle existe (`Test-TachesAnciennes`), `None` sinon.
    fn compte_tache(&self, nom: &str) -> Option<String>;
}

/// Aucun mini-installateur (l'hôte tant que le bloc « installations » n'a pas branché le sien) : tâche absente, toute
/// demande refusée.
#[derive(Debug, Default)]
pub struct SansInstallateur;

impl Installateur for SansInstallateur {
    fn etat_tache(&self) -> EtatTache {
        EtatTache::Absente
    }
    fn deposer(&self, _: &Value) -> Result<(), String> {
        Err("la tâche d'installation n'est pas là".into())
    }
    fn retirer_demande(&self) {}
    fn valeur(&self, _: &str) -> String {
        String::new()
    }
    fn lancer_direct(&self, _: &Direct) -> Result<u32, String> {
        Err("l'autorisation de Windows a été refusée.".into())
    }
    fn direct_fini(&self, _: u32) -> bool {
        true
    }
    fn compte_tache(&self, _: &str) -> Option<String> {
        None
    }
}

/// Ce qu'un faux mini-installateur répond à une demande déposée : `(ok, message)`, ou `None` pour ne jamais répondre
/// (ni accusé de réception, ni réponse).
pub type Repondeur = Box<dyn Fn(&Value) -> Option<(bool, String)> + Send + Sync>;

/// Le faux mini-installateur des tests. Une demande déposée est gardée ; si un répondeur est posé, l'accusé de
/// réception (`Recu` = son id) et la réponse (`Resultat` = `{"id","ok","message"}`) sont écrits aussitôt, comme le
/// ferait la tâche.
pub struct FauxInstallateur {
    pub etat: Mutex<EtatTache>,
    deposees: Mutex<Vec<Value>>,
    retraits: Mutex<u32>,
    valeurs: Mutex<HashMap<String, String>>,
    directs: Mutex<Vec<Direct>>,
    directs_finis: Mutex<Vec<u32>>,
    directs_oublies: Mutex<Vec<u32>>,
    taches: Mutex<HashMap<String, String>>,
    repondeur: Mutex<Option<Repondeur>>,
    refus_direct: Mutex<Option<String>>,
}

impl Default for FauxInstallateur {
    fn default() -> Self {
        FauxInstallateur {
            etat: Mutex::new(EtatTache::Systeme),
            deposees: Mutex::new(Vec::new()),
            retraits: Mutex::new(0),
            valeurs: Mutex::new(HashMap::new()),
            directs: Mutex::new(Vec::new()),
            directs_finis: Mutex::new(Vec::new()),
            directs_oublies: Mutex::new(Vec::new()),
            taches: Mutex::new(HashMap::new()),
            repondeur: Mutex::new(None),
            refus_direct: Mutex::new(None),
        }
    }
}

impl FauxInstallateur {
    /// L'état de la tâche.
    pub fn poser_etat(&self, e: EtatTache) {
        *verrou(&self.etat) = e;
    }
    /// Le répondeur (voir [`Repondeur`]).
    pub fn repondre(&self, r: impl Fn(&Value) -> Option<(bool, String)> + Send + Sync + 'static) {
        *verrou(&self.repondeur) = Some(Box::new(r));
    }
    /// Une valeur de `HKLM:\SOFTWARE\Mindset\Installation` (Recu, Resultat, Restes).
    pub fn poser_valeur(&self, nom: &str, valeur: &str) {
        verrou(&self.valeurs).insert(nom.into(), valeur.into());
    }
    /// Une tâche `\Mindset\<nom>` et son compte.
    pub fn poser_tache(&self, nom: &str, compte: &str) {
        verrou(&self.taches).insert(nom.into(), compte.into());
    }
    /// La demande de Windows sera refusée avec ce message.
    pub fn refuser_direct(&self, message: Option<&str>) {
        *verrou(&self.refus_direct) = message.map(str::to_string);
    }
    /// La demande directe `numero` est finie : sa réponse est écrite dans son fichier.
    pub fn finir_direct(&self, numero: u32, ok: bool, message: &str) {
        let d = verrou(&self.directs).get(numero as usize).cloned();
        if let Some(d) = d {
            let _ = write_reponse(&d.resultat, ok, message);
        }
        verrou(&self.directs_finis).push(numero);
    }
    /// Les demandes déposées pour la tâche, dans l'ordre.
    pub fn deposees(&self) -> Vec<Value> {
        verrou(&self.deposees).clone()
    }
    /// Combien de fois la demande a été retirée.
    pub fn retraits(&self) -> u32 {
        *verrou(&self.retraits)
    }
    /// Les demandes lancées en direct.
    pub fn directs(&self) -> Vec<Direct> {
        verrou(&self.directs).clone()
    }
    /// Les demandes directes que Mindset n'attend plus (pas finies dans le délai), dans l'ordre.
    pub fn directs_oublies(&self) -> Vec<u32> {
        verrou(&self.directs_oublies).clone()
    }
}

fn write_reponse(f: &Path, ok: bool, message: &str) -> std::io::Result<()> {
    if let Some(d) = f.parent() {
        std::fs::create_dir_all(d)?;
    }
    std::fs::write(f, serde_json::json!({ "ok": ok, "message": message }).to_string())
}

impl Installateur for FauxInstallateur {
    fn etat_tache(&self) -> EtatTache {
        *verrou(&self.etat)
    }
    fn deposer(&self, demande: &Value) -> Result<(), String> {
        if *verrou(&self.etat) == EtatTache::Absente {
            return Err("la tâche d'installation n'a pas démarré (code 1)".into());
        }
        verrou(&self.deposees).push(demande.clone());
        let id = demande.get("Id").and_then(Value::as_str).unwrap_or("").to_string();
        let r = verrou(&self.repondeur).as_ref().and_then(|f| f(demande));
        if let Some((ok, message)) = r {
            let mut v = verrou(&self.valeurs);
            v.insert("Recu".into(), id.clone());
            v.insert("Resultat".into(), serde_json::json!({ "id": id, "ok": ok, "message": message }).to_string());
        }
        Ok(())
    }
    fn retirer_demande(&self) {
        *verrou(&self.retraits) += 1;
    }
    fn valeur(&self, nom: &str) -> String {
        verrou(&self.valeurs).get(nom).cloned().unwrap_or_default()
    }
    fn lancer_direct(&self, d: &Direct) -> Result<u32, String> {
        if let Some(m) = verrou(&self.refus_direct).clone() {
            return Err(m);
        }
        let mut l = verrou(&self.directs);
        l.push(d.clone());
        Ok((l.len() - 1) as u32)
    }
    fn direct_fini(&self, numero: u32) -> bool {
        verrou(&self.directs_finis).contains(&numero)
    }
    fn oublier_direct(&self, numero: u32) {
        verrou(&self.directs_oublies).push(numero);
    }
    fn compte_tache(&self, nom: &str) -> Option<String> {
        verrou(&self.taches).get(nom).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn faux_mini_installateur() {
        let f = FauxInstallateur::default();
        f.repondre(|d| (d["Action"] == "installer").then(|| (true, r"C:\Program Files\Mindset\Evermind".to_string())));
        f.deposer(&json!({ "Id": "a1", "Action": "installer" })).unwrap();
        assert_eq!(f.valeur("Recu"), "a1");
        let r: Value = serde_json::from_str(&f.valeur("Resultat")).unwrap();
        assert_eq!(r["ok"], true);
        f.deposer(&json!({ "Id": "a2", "Action": "supprimer" })).unwrap();
        assert_eq!(f.valeur("Recu"), "a1", "sans réponse prévue : rien n'est écrit");
        f.poser_etat(EtatTache::Absente);
        assert!(f.deposer(&json!({ "Id": "a3" })).is_err());
        assert_eq!(f.deposees().len(), 2);
        let n = f
            .lancer_direct(&Direct { action: "mindset".into(), parametres: vec![], resultat: PathBuf::from("x") })
            .unwrap();
        assert!(!f.direct_fini(n));
        f.refuser_direct(Some("refusé"));
        assert!(f.lancer_direct(&Direct { action: "a".into(), parametres: vec![], resultat: PathBuf::new() }).is_err());
    }
}
