//! Mindset en Rust, bloc « données » : les dossiers de la suite, le journal, les réglages, les fichiers JSON sûrs et
//! suite.json (donnees.ps1, suite.ps1).
//!
//! Posé vide par les fondations (07/11/2026) : l'agent du bloc le remplit, en suivant
//! `D:\Projets\_plans\architecture-mindset-rust.md`. Le contrat (`Bloc`, `Effet`, `Contexte`, les ports, le tableau
//! commun, les signaux) est dans `mindset-noyau` et ne change pas.
//!
//! [`ouvrir`] est appelé par l'hôte au lancement, avant tout le reste : SA SIGNATURE NE CHANGE PAS. Aujourd'hui elle
//! rend des dossiers simples et le disque d'essai du noyau (`DonneesMemoire` : réglages en mémoire) ; le bloc la
//! remplace par le vrai travail (`Get-RacinesDepuis`, anciens fichiers, `Read-Reglages`, `Read-JsonSur`,
//! `Save-JsonSur`, suite.json).

use std::path::Path;
use std::sync::Arc;

use mindset_noyau::Bloc;
use mindset_noyau::donnees::{Donnees, DonneesMemoire, Dossiers, Environnement, Ouverture, Suite};
use serde_json::Value;

/// Les dossiers et le disque de Mindset, au lancement (donnees.ps1:10-58 et 155-186).
pub fn ouvrir(env: &Environnement) -> Ouverture {
    let dossiers = match &env.essai {
        Some(racine) => Dossiers::sous(racine),
        None => {
            let mindset = env.exe.parent().map(|p| p.to_path_buf()).unwrap_or_default();
            let programmes = env.program_files.join("Mindset");
            let donnees_suite = env.localappdata.join("Mindset");
            Dossiers {
                fichiers: mindset.join("fichiers"),
                exe: env.exe.clone(),
                mindset,
                programmes,
                donnees: donnees_suite.join("Mindset"),
                local_mindset: donnees_suite.clone(),
                donnees_suite,
                disque: String::new(),
            }
        }
    };
    let _ = std::fs::create_dir_all(&dossiers.donnees);
    Ouverture {
        donnees: Arc::new(Provisoire(DonneesMemoire::nouvelle(dossiers.clone()))),
        dossiers,
        notes: vec!["Données : bloc pas encore porté (réglages en mémoire)".into()],
    }
}

/// En attendant le vrai bloc : le disque d'essai du noyau, avec le journal écrit dans journal.txt.
struct Provisoire(DonneesMemoire);

impl Donnees for Provisoire {
    fn journal(&self, texte: &str) {
        use std::io::Write;
        let h = mindset_noyau::moment::iso(&mindset_noyau::moment::heure_du_pc());
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(self.0.dossiers.journal()) {
            let _ = write!(f, "{h} {texte}\r\n");
        }
        self.0.journal(texte);
    }
    fn reglage(&self, nom: &str) -> Option<Value> {
        self.0.reglage(nom)
    }
    fn ecrire_reglage(&self, nom: &str, valeur: Value) {
        self.0.ecrire_reglage(nom, valeur)
    }
    fn lire_json(&self, fichier: &Path) -> Result<Option<Value>, String> {
        self.0.lire_json(fichier)
    }
    fn ecrire_json(&self, fichier: &Path, valeur: &Value) -> Result<(), String> {
        self.0.ecrire_json(fichier, valeur)
    }
    fn suite(&self) -> Suite {
        self.0.suite()
    }
    fn theme_suite(&self) -> String {
        self.0.theme_suite()
    }
    fn ecrire_theme_suite(&self, theme: &str) {
        self.0.ecrire_theme_suite(theme)
    }
    fn ecrire_suite_appli(&self, id: &str, dossier: Option<&str>) {
        self.0.ecrire_suite_appli(id, dossier)
    }
    fn son_suite(&self) -> (String, String) {
        self.0.son_suite()
    }
    fn ecrire_son_suite(&self, quoi: &str, nom: &str) {
        self.0.ecrire_son_suite(quoi, nom)
    }
}

/// Le bloc « données ».
#[derive(Debug, Default)]
pub struct BlocDonnees;

impl Bloc for BlocDonnees {
    fn nom(&self) -> &'static str {
        "donnees"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        assert_eq!(BlocDonnees.nom(), "donnees");
    }

    #[test]
    fn ouverture_d_essai_sous_son_dossier() {
        let racine = mindset_noyau::dossier_essai("donnees-ouvrir");
        let o = ouvrir(&Environnement { essai: Some(racine.clone()), ..Default::default() });
        assert!(o.dossiers.donnees.starts_with(&racine));
        assert!(o.dossiers.suite().starts_with(&racine));
        o.donnees.journal("essai");
        assert!(std::fs::read_to_string(o.dossiers.journal()).unwrap().ends_with(" essai\r\n"));
        let _ = std::fs::remove_dir_all(&racine);
    }
}
