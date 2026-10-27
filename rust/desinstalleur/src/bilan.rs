//! Ce qui a été fait, ce qui reste (à afficher), et ce qu'il faut savoir (un désinstalleur d'appli qui a échoué).

/// Écrit une ligne dans le journal (Mindset-desinstallation.txt) ; fourni par main.rs
pub type Journal = Box<dyn Fn(&str) + Send + Sync>;
/// Montre l'étape en cours dans la fenêtre
pub type SurEtape = Box<dyn Fn(&str) + Send + Sync>;

#[derive(Default)]
pub struct Bilan {
    pub faits: Vec<String>,
    pub restes: Vec<String>,
    pub alertes: Vec<String>,
    pub sur_etape: Option<SurEtape>,
    pub journal: Option<Journal>,
}

impl Bilan {
    pub fn etape(&self, t: &str) {
        self.journal(t);
        if let Some(f) = &self.sur_etape {
            f(t);
        }
    }

    pub fn fait(&mut self, t: String) {
        self.journal(&format!("Fait : {t}"));
        self.faits.push(t);
    }

    pub fn reste(&mut self, t: String) {
        self.journal(&format!("Reste : {t}"));
        self.restes.push(t);
    }

    pub fn alerte(&mut self, t: String) {
        self.journal(&format!("À savoir : {t}"));
        self.alertes.push(t);
    }

    pub fn journal(&self, t: &str) {
        if let Some(j) = &self.journal {
            j(t);
        }
    }
}
