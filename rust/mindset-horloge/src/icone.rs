//! L'icône près de l'horloge, vue du bloc : un port (le vrai est dans [`crate::windows`], le faux ici pour les
//! tests). Le bloc lui donne son menu et ses bulles ; elle lui rend les gestes de l'utilisateur, lus dans `tic`.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};

/// Le dessin de la bulle (`[System.Windows.Forms.ToolTipIcon]`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dessin {
    /// `Info`
    Info,
    /// `Warning`
    Attention,
    /// `None`
    Aucun,
}

impl Dessin {
    /// Depuis le signal `bulle` (« info », « attention », « aucune » ; autre chose : info, comme `Show-BulleMindset`
    /// appelé avec une icône inconnue n'existe pas).
    pub fn depuis(t: &str) -> Dessin {
        match t {
            "attention" => Dessin::Attention,
            "aucune" => Dessin::Aucun,
            _ => Dessin::Info,
        }
    }
    /// Le nom de .NET (`ToolTipIcon.ToString()`), pour les juges.
    pub fn nom(self) -> &'static str {
        match self {
            Dessin::Info => "Info",
            Dessin::Attention => "Warning",
            Dessin::Aucun => "None",
        }
    }
}

/// Ce que fait un choix du menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Choix {
    /// « Ouvrir Mindset »
    OuvrirMindset,
    /// « Ouvrir <appli> »
    OuvrirAppli(String),
    /// « Tout quitter (Mindset et ses applis) »
    ToutQuitter,
}

/// Une ligne du menu (`Update-MenuHorloge`, zone.ps1:49-65).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ligne {
    Separateur,
    Choix { texte: String, gras: bool, choix: Choix },
}

/// Un geste de l'utilisateur sur l'icône.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Geste {
    /// Clic gauche sur l'icône (`Add_MouseClick`, bouton gauche)
    Clic,
    /// Un choix du menu du clic droit
    Menu(Choix),
    /// Clic sur la bulle (`Add_BalloonTipClicked`)
    BulleCliquee,
    /// La bulle s'est fermée (`Add_BalloonTipClosed`)
    BulleFermee,
}

/// L'icône près de l'horloge.
pub trait Icone: Send {
    /// `ShowBalloonTip(duree, titre, texte, dessin)`
    fn bulle(&self, duree_ms: u32, titre: &str, texte: &str, dessin: Dessin);
    /// Le menu du clic droit (refait quand il change ; montré tel quel au prochain clic droit).
    fn menu(&self, lignes: &[Ligne]);
    /// Les gestes arrivés depuis le dernier appel.
    fn gestes(&self) -> Vec<Geste>;
    /// Retirer l'icône (Mindset se ferme : `Visible = $false`, `Dispose`). Plus rien ensuite.
    fn retirer(&self);
}

fn verrou<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Ce que la fausse icône a vu (partagé avec le test).
#[derive(Debug, Default)]
pub struct Vu {
    /// Les bulles montrées : « bulle:<durée>|<titre>|<texte>|<dessin> » (la forme des juges)
    pub bulles: Vec<String>,
    /// Le dernier menu donné
    pub menu: Vec<Ligne>,
    /// Combien de fois le menu a été donné
    pub menus_donnes: usize,
    /// Les gestes en attente (posés par le test)
    pub gestes: VecDeque<Geste>,
    pub retiree: bool,
}

/// La fausse icône des tests : rien ne touche Windows.
#[derive(Debug, Clone, Default)]
pub struct FausseIcone(pub Arc<Mutex<Vu>>);

impl FausseIcone {
    pub fn nouvelle() -> FausseIcone {
        FausseIcone::default()
    }
    /// Le test simule un geste de l'utilisateur.
    pub fn geste(&self, g: Geste) {
        verrou(&self.0).gestes.push_back(g);
    }
    /// Les bulles montrées depuis le dernier appel (elles sont retirées de la liste).
    pub fn bulles(&self) -> Vec<String> {
        std::mem::take(&mut verrou(&self.0).bulles)
    }
    pub fn dernier_menu(&self) -> Vec<Ligne> {
        verrou(&self.0).menu.clone()
    }
    pub fn menus_donnes(&self) -> usize {
        verrou(&self.0).menus_donnes
    }
    pub fn retiree(&self) -> bool {
        verrou(&self.0).retiree
    }
}

impl Icone for FausseIcone {
    fn bulle(&self, duree_ms: u32, titre: &str, texte: &str, dessin: Dessin) {
        let mut v = verrou(&self.0);
        if !v.retiree {
            v.bulles.push(format!("bulle:{duree_ms}|{titre}|{texte}|{}", dessin.nom()));
        }
    }
    fn menu(&self, lignes: &[Ligne]) {
        let mut v = verrou(&self.0);
        v.menu = lignes.to_vec();
        v.menus_donnes += 1;
    }
    fn gestes(&self) -> Vec<Geste> {
        verrou(&self.0).gestes.drain(..).collect()
    }
    fn retirer(&self) {
        verrou(&self.0).retiree = true;
    }
}
