//! Le port vers les fenêtres de Windows dont l'accrochage a besoin (`MSIntegration`, natif.cs:36-137), et son faux
//! pour les tests ([`FauxFenetres`]).
//!
//! Comme dans la version PowerShell, l'appli n'est pas posée directement sur la page : elle devient l'enfant d'un
//! PANNEAU (« hôte », le `WindowsFormsHost` + `Panel` de `Get-Integration`), une fenêtre noire de Mindset posée sur
//! la zone `#zone-appli`. Montrer ou cacher l'appli, c'est montrer ou cacher son panneau : la fenêtre de l'appli garde
//! son propre drapeau `WS_VISIBLE`, que la surveillance lit pour savoir si l'appli s'est cachée elle-même.
//!
//! Le vrai port est `crate::windows::FenetresWindows`. Les fenêtres sont des nombres (`HWND`), 0 n'en est pas une.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard};

/// La place de l'appli (`accrochage:zone`, envoyée par la coquille) : en pixels de l'écran, depuis le coin haut gauche
/// de l'intérieur de la fenêtre de Mindset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Zone {
    pub x: i32,
    pub y: i32,
    pub largeur: i32,
    pub hauteur: i32,
    /// La zone est à l'écran (la page d'une appli est montrée)
    pub visible: bool,
}

impl Zone {
    /// Une zone où poser une fenêtre : montrée, et d'une vraie taille (Mindset réduit envoie une taille nulle : elle
    /// est ignorée, essai du 26/10).
    pub fn utilisable(&self) -> bool {
        self.visible && self.largeur > 0 && self.hauteur > 0
    }

    /// La taille du panneau (`Panel.ClientSize`) : celle de la zone, ou 0 x 0 quand la page de l'appli n'est pas
    /// montrée (le panneau d'une page repliée n'a pas de taille).
    pub fn taille(&self) -> (i32, i32) {
        if self.utilisable() { (self.largeur, self.hauteur) } else { (0, 0) }
    }
}

/// Les styles d'une fenêtre avant son accrochage (`GWL_STYLE`, `GWL_EXSTYLE`), pour la rendre telle quelle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Styles {
    pub style: i64,
    pub ex: i64,
}

/// `MSIntegration.Trouver` (natif.cs:61-74), la règle seule : une fenêtre de premier niveau du processus `pid`, sans
/// propriétaire (ni alerte, ni menu), au titre exactement `titre`, de classe `HwndWrapper*` (WPF) ou exactement
/// « Tauri Window » (Tauri).
pub fn convient(pid_voulu: u32, titre_voulu: &str, pid: u32, possedee: bool, titre: &str, classe: &str) -> bool {
    pid == pid_voulu
        && !possedee
        && titre == titre_voulu
        && (classe.starts_with("HwndWrapper") || classe == "Tauri Window")
}

/// Ce que l'accrochage demande à Windows.
pub trait Fenetres: Send {
    /// L'heure (`Get-Date`), en FILETIME : 100 ns depuis 1601, temps universel (comme `Processus::creation`).
    fn maintenant(&self) -> u64;
    /// `MSIntegration.Trouver` : la fenêtre principale du processus `pid`, d'après [`convient`].
    fn trouver(&self, pid: u32, titre: &str) -> Option<isize>;
    /// `IsWindow`
    fn existe(&self, h: isize) -> bool;
    /// `MSIntegration.Processus` : le processus de la fenêtre (0 si elle n'existe plus).
    fn processus(&self, h: isize) -> u32;
    /// L'appli répond-elle (un message vide, rendu en moins d'une seconde) ? Une appli figée n'est pas accrochée tout
    /// de suite (Mindset resterait bloqué avec elle).
    fn repond(&self, h: isize) -> bool;
    /// Le panneau de l'appli `id` dans la fenêtre `parent` de Mindset, créé caché la première fois.
    fn hote(&self, id: &str, parent: isize) -> Option<isize>;
    /// Montre le panneau sur la zone (au-dessus de la page, tout redessiné), ou le cache.
    fn placer_hote(&self, hote: isize, zone: Zone, visible: bool);
    /// `MSIntegration.Accrocher` : la fenêtre devient l'enfant du panneau, sans barre ni bordure, à cette taille ;
    /// rend ses styles d'avant, ou `None` si Windows refuse.
    fn accrocher(&self, h: isize, hote: isize, largeur: i32, hauteur: i32) -> Option<Styles>;
    /// `MSIntegration.Redimensionner`
    fn redimensionner(&self, h: isize, largeur: i32, hauteur: i32);
    /// `MSIntegration.EstMontree` : son propre drapeau `WS_VISIBLE` (pas celui de ses parents).
    fn est_montree(&self, h: isize) -> bool;
    /// `MSIntegration.BarrePropre` : la propriété `Mindset.BarrePropre` est posée sur sa fenêtre.
    fn barre_propre(&self, h: isize) -> bool;
    /// `MSIntegration.Fermer` : `WM_CLOSE`, comme un clic sur sa croix.
    fn fermer(&self, h: isize);
    /// `MSIntegration.Liberer` : rendue telle qu'elle était, cachée. `false` : l'appli ne traitait pas ses messages,
    /// elle n'est pas encore rendue (elle le sera dès qu'elle les traitera ; Mindset n'attend pas, audit M3).
    fn liberer(&self, h: isize, styles: Styles) -> bool;
    /// [`Fenetres::liberer`] sans l'attendre du tout : une appli qui s'est cachée pour quitter ne traite souvent plus
    /// ses messages, et Mindset revient à l'accueil sans elle (DIVERGENCES.md, point 9). Elle est rendue dès
    /// qu'elle les traite ; Mindset qui quitte attend encore ce rendu (`windows::ATTENTE_FIN`).
    fn liberer_sans_attendre(&self, h: isize, styles: Styles) {
        let _ = self.liberer(h, styles);
    }
    /// `MSIntegration.Focus` : le clavier va à l'appli.
    fn focus(&self, h: isize);
    /// Mindset se ferme : plus rien ne sera demandé (les panneaux s'en vont).
    fn fin(&self) {}
}

/// Une fenêtre du faux Windows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FausseFenetre {
    pub pid: u32,
    pub titre: String,
    pub classe: String,
    pub possedee: bool,
    /// Son drapeau `WS_VISIBLE`
    pub visible: bool,
    pub barre_propre: bool,
    /// Le panneau qui la tient (accrochée)
    pub parent: Option<isize>,
    pub taille: (i32, i32),
    /// Elle répond aux messages
    pub repond: bool,
    /// Le prochain accrochage est refusé par Windows
    pub refus: bool,
}

/// Un panneau du faux Windows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FauxHote {
    pub id: String,
    pub parent: isize,
    pub visible: bool,
    pub zone: Zone,
}

#[derive(Debug, Default)]
struct Interieur {
    maintenant: u64,
    fenetres: BTreeMap<isize, FausseFenetre>,
    ordre: Vec<isize>,
    hotes: Vec<(isize, FauxHote)>,
    appels: Vec<String>,
    fini: bool,
}

/// Le faux Windows des tests : des fenêtres inventées, et la liste de ce qui leur a été fait.
#[derive(Debug, Clone, Default)]
pub struct FauxFenetres(Arc<Mutex<Interieur>>);

/// La date FILETIME de départ des essais (le 07/11/2026 à 19 h, temps universel).
pub const DEPART_ESSAI: u64 = 134_385_516_000_000_000;

impl FauxFenetres {
    pub fn nouveau() -> FauxFenetres {
        let f = FauxFenetres::default();
        f.i().maintenant = DEPART_ESSAI;
        f
    }

    fn i(&self) -> MutexGuard<'_, Interieur> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// L'heure avance.
    pub fn avancer_ms(&self, ms: u64) {
        self.i().maintenant += ms * 10_000;
    }

    /// Une fenêtre apparaît (de premier niveau, sans parent).
    pub fn creer(&self, h: isize, pid: u32, titre: &str, classe: &str, possedee: bool, visible: bool) {
        let mut i = self.i();
        i.fenetres.insert(
            h,
            FausseFenetre {
                pid,
                titre: titre.into(),
                classe: classe.into(),
                possedee,
                visible,
                barre_propre: false,
                parent: None,
                taille: (0, 0),
                repond: true,
                refus: false,
            },
        );
        i.ordre.retain(|x| *x != h);
        i.ordre.push(h);
    }

    /// Elle est détruite (l'appli s'est fermée ou se relance).
    pub fn detruire(&self, h: isize) {
        let mut i = self.i();
        i.fenetres.remove(&h);
        i.ordre.retain(|x| *x != h);
    }

    /// L'appli change une de ses fenêtres (se cache, pose sa barre, ne répond plus...).
    pub fn changer(&self, h: isize, f: impl FnOnce(&mut FausseFenetre)) {
        if let Some(x) = self.i().fenetres.get_mut(&h) {
            f(x);
        }
    }

    pub fn fenetre(&self, h: isize) -> Option<FausseFenetre> {
        self.i().fenetres.get(&h).cloned()
    }

    /// Les panneaux, dans l'ordre de leur création.
    pub fn hotes(&self) -> Vec<(isize, FauxHote)> {
        self.i().hotes.clone()
    }

    /// Le panneau de l'appli `id`.
    pub fn hote_de(&self, id: &str) -> Option<FauxHote> {
        self.i().hotes.iter().find(|(_, x)| x.id == id).map(|(_, x)| x.clone())
    }

    /// Ce qui a été fait aux fenêtres des applis (accrocher, redimensionner, liberer, focus, fermer).
    pub fn appels(&self) -> Vec<String> {
        self.i().appels.clone()
    }

    /// Les appels faits depuis le dernier `prendre_appels`.
    pub fn prendre_appels(&self) -> Vec<String> {
        std::mem::take(&mut self.i().appels)
    }

    /// `fin` a été appelé.
    pub fn fini(&self) -> bool {
        self.i().fini
    }
}

impl Fenetres for FauxFenetres {
    fn maintenant(&self) -> u64 {
        self.i().maintenant
    }
    fn trouver(&self, pid: u32, titre: &str) -> Option<isize> {
        let i = self.i();
        i.ordre.iter().copied().find(|h| {
            i.fenetres
                .get(h)
                .is_some_and(|f| f.parent.is_none() && convient(pid, titre, f.pid, f.possedee, &f.titre, &f.classe))
        })
    }
    fn existe(&self, h: isize) -> bool {
        self.i().fenetres.contains_key(&h)
    }
    fn processus(&self, h: isize) -> u32 {
        self.i().fenetres.get(&h).map_or(0, |f| f.pid)
    }
    fn repond(&self, h: isize) -> bool {
        self.i().fenetres.get(&h).is_some_and(|f| f.repond)
    }
    fn hote(&self, id: &str, parent: isize) -> Option<isize> {
        let mut i = self.i();
        if let Some((h, _)) = i.hotes.iter().find(|(_, x)| x.id == id) {
            return Some(*h);
        }
        let h = 9000 + i.hotes.len() as isize;
        i.hotes.push((h, FauxHote { id: id.into(), parent, visible: false, zone: Zone::default() }));
        Some(h)
    }
    fn placer_hote(&self, hote: isize, zone: Zone, visible: bool) {
        if let Some((_, x)) = self.i().hotes.iter_mut().find(|(h, _)| *h == hote) {
            x.visible = visible;
            x.zone = zone;
        }
    }
    fn accrocher(&self, h: isize, hote: isize, largeur: i32, hauteur: i32) -> Option<Styles> {
        let mut i = self.i();
        i.appels.push(format!("accrocher {h} {largeur}x{hauteur}"));
        let f = i.fenetres.get_mut(&h)?;
        if std::mem::take(&mut f.refus) {
            return None;
        }
        let avant = Styles { style: if f.visible { 0x16CF_0000 } else { 0x06CF_0000 }, ex: 0x0004_0100 };
        f.parent = Some(hote);
        f.visible = true;
        f.taille = (largeur, hauteur);
        Some(avant)
    }
    fn redimensionner(&self, h: isize, largeur: i32, hauteur: i32) {
        let mut i = self.i();
        i.appels.push(format!("redimensionner {h} {largeur}x{hauteur}"));
        if let Some(f) = i.fenetres.get_mut(&h) {
            f.taille = (largeur, hauteur);
        }
    }
    fn est_montree(&self, h: isize) -> bool {
        self.i().fenetres.get(&h).is_some_and(|f| f.visible)
    }
    fn barre_propre(&self, h: isize) -> bool {
        self.i().fenetres.get(&h).is_some_and(|f| f.barre_propre)
    }
    fn fermer(&self, h: isize) {
        self.i().appels.push(format!("fermer {h}"));
    }
    fn liberer(&self, h: isize, _styles: Styles) -> bool {
        let mut i = self.i();
        i.appels.push(format!("liberer {h}"));
        // (comme le vrai : une appli qui ne répond pas est rendue plus tard, ici tout de suite ; `false` est rendu)
        i.fenetres.get_mut(&h).is_none_or(|f| {
            f.parent = None;
            f.visible = false;
            f.repond
        })
    }
    fn focus(&self, h: isize) {
        self.i().appels.push(format!("focus {h}"));
    }
    fn fin(&self) {
        self.i().fini = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn la_regle_de_trouver() {
        assert!(convient(7, "Nevermind", 7, false, "Nevermind", "Tauri Window"));
        assert!(convient(7, "Evermind", 7, false, "Evermind", "HwndWrapper[Evermind.exe;;1a2b]"));
        assert!(!convient(7, "Nevermind", 8, false, "Nevermind", "Tauri Window"), "un autre processus");
        assert!(!convient(7, "Nevermind", 7, true, "Nevermind", "Tauri Window"), "possédée : une alerte");
        assert!(!convient(7, "Nevermind", 7, false, "nevermind", "Tauri Window"), "titre exact, majuscules comprises");
        assert!(!convient(7, "Nevermind", 7, false, "Nevermind ", "Tauri Window"));
        assert!(!convient(7, "Nevermind", 7, false, "Nevermind", "Tauri Window2"), "classe exacte pour Tauri");
        assert!(!convient(7, "Nevermind", 7, false, "Nevermind", "Chrome_WidgetWin_1"));
        assert!(!convient(7, "Nevermind", 7, false, "Nevermind", "hwndwrapper[x]"), "HwndWrapper avec ses majuscules");
        assert!(!convient(7, "Nevermind", 7, false, "Nevermind", ""));
    }

    #[test]
    fn la_zone() {
        let z = Zone { x: 1, y: 2, largeur: 300, hauteur: 200, visible: true };
        assert!(z.utilisable());
        assert_eq!(z.taille(), (300, 200));
        assert_eq!(Zone { visible: false, ..z }.taille(), (0, 0));
        assert_eq!(Zone { largeur: 0, ..z }.taille(), (0, 0));
    }

    #[test]
    fn le_faux_trouve_dans_l_ordre_et_ecarte_les_accrochees() {
        let f = FauxFenetres::nouveau();
        f.creer(1, 5, "Evermind", "HwndWrapper[a]", true, false);
        f.creer(2, 5, "Evermind", "HwndWrapper[b]", false, false);
        f.creer(3, 5, "Evermind", "HwndWrapper[c]", false, false);
        assert_eq!(f.trouver(5, "Evermind"), Some(2));
        let hote = f.hote("evermind", 77).unwrap();
        assert_eq!(f.hote("evermind", 77), Some(hote), "un seul panneau par appli");
        assert!(f.accrocher(2, hote, 200, 200).is_some());
        assert_eq!(f.trouver(5, "Evermind"), Some(3), "accrochée, elle n'est plus de premier niveau");
        f.changer(3, |x| x.refus = true);
        assert!(f.accrocher(3, hote, 200, 200).is_none());
        assert!(f.accrocher(3, hote, 200, 200).is_some(), "le refus ne vaut qu'une fois");
    }
}
