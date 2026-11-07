//! Le noyau de Mindset en Rust (Mindset 3.0, branche rust-complet).
//!
//! Mindset est découpé en blocs, un par partie de la version PowerShell (Mindset/fichiers/modules) : données, liste
//! des applis, publications, installations, Mindset lui-même, accrochage, console 3D, écrans, paramètres, près de
//! l'horloge. Chaque bloc :
//! - donne sa part de l'état de la page ([`Bloc::etat`]) ;
//! - reçoit les actions de la page ([`Bloc::action`]) ;
//! - demande à l'hôte ce qu'il ne fait pas lui-même ([`Effet`]) : changer de page, montrer ou cacher la fenêtre, un
//!   ordre à la page, un travail de fond, un message aux autres blocs, quitter...
//! - travaille à son rythme ([`Bloc::tic`]), reçoit les messages des autres ([`Bloc::signal`]) et la fin de ses
//!   travaux de fond ([`Bloc::tache_finie`]).
//!
//! L'hôte (`mindset-appli`, Tauri) assemble l'état de tous les blocs, l'envoie à la page, passe chaque action aux
//! blocs jusqu'à ce que l'un la prenne, exécute les effets et fait tourner les travaux de fond. Tout passe par un seul
//! fil (« le fil des blocs ») : un bloc n'a jamais besoin de verrou pour lui-même.
//!
//! Les blocs ne dépendent pas les uns des autres. Ils partagent :
//! - le disque (suite.json, installations.json, reglages.json... comme la version PowerShell), par le port
//!   [`donnees::Donnees`] du contexte ;
//! - le tableau commun du contexte ([`partage`]) : chaque clé a un seul bloc qui l'écrit, les autres la lisent ;
//! - les signaux ([`signaux`]) : un message envoyé à tous les autres blocs, par l'hôte.
//!
//! Ce qui touche au PC passe par des ports ([`donnees::Donnees`], [`reseau::Reseau`],
//! [`installateur::Installateur`], [`systeme::Systeme`]) : les tests leur donnent des faux ([`essai`]), jamais le
//! vrai PC.
//!
//! LE CONTRAT CI-DESSOUS EST COMMUN À TOUS LES BLOCS : ne pas changer les signatures du trait [`Bloc`], de
//! [`Contexte`], de [`Effet`] ni des ports sans passer par l'intégration (on ajoute, on ne casse pas).

use serde_json::{Map, Value};
use std::path::PathBuf;
use std::time::Duration;

pub mod appli;
pub mod contexte;
pub mod donnees;
pub mod essai;
pub mod installateur;
pub mod moment;
pub mod partage;
pub mod reseau;
pub mod signaux;
pub mod systeme;
pub mod tache;
#[cfg(windows)]
pub mod windows;

pub use appli::{Appli, Installation};
pub use contexte::{Contexte, Lancement, Ports, Vue};
pub use donnees::{Dossiers, Suite};
pub use tache::{Progres, Tache};

/// Ce que l'hôte fait de la fenêtre principale de Mindset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fenetre {
    /// Montrer la fenêtre et la mettre devant (`Show-Fenetre`, zone.ps1:11-19 : `ShowInTaskbar`, `Show`, remise en
    /// taille normale si elle était réduite, `Activate`).
    Montrer,
    /// La cacher (près de l'horloge : `Hide-Fenetre`, zone.ps1:21-28, sans la bulle, qui est au bloc horloge).
    Cacher,
    /// La réduire dans la barre des tâches.
    Reduire,
    /// La remettre en taille normale si elle est réduite, sans la montrer si elle est cachée.
    Restaurer,
}

/// Ce qu'un bloc demande à l'hôte (il ne touche jamais la fenêtre ni la page lui-même).
#[derive(Debug, PartialEq)]
pub enum Effet {
    /// Montrer une page de Mindset : « accueil », « parametres », ou l'id d'une appli (`Show-Page`, accueil.ps1:84).
    /// L'hôte la note dans la vue du contexte ([`Contexte::vue`]) puis envoie à tous les blocs le signal
    /// [`signaux::PAGE`] `{ id, avant }`. Chaque bloc y fait sa part (onglets, appli accrochée, console...).
    Page(String),
    /// La fenêtre principale.
    Fenetre(Fenetre),
    /// Un ordre à la page, envoyé tel quel par le canal (un objet avec un champ texte `kit`, par exemple
    /// `{ "kit": "console", "appel": "etat", "args": [...] }`). Autre chose qu'un objet avec `kit` est refusé.
    Ordre(Value),
    /// Une action passée aux blocs comme si elle venait de la page (le « Oui » d'une confirmation, un clic du menu de
    /// l'horloge) : `id` et `valeur` comme [`Bloc::action`].
    Action { id: String, valeur: Value },
    /// Un message pour tous les AUTRES blocs (reçu par [`Bloc::signal`]) ; noms et champs : [`signaux`].
    Signal { nom: String, donnees: Value },
    /// Un travail de fond (`Start-Tache`, taches.ps1) : il tourne sur un autre fil, et sa fin revient au bloc qui l'a
    /// demandé ([`Bloc::tache_finie`]), sur le fil des blocs.
    Tache(Tache),
    /// Quitter Mindset (`Exit-Mindset`, interface.ps1:98). `avec_applis` : quitter pour de bon, les applis se ferment
    /// aussi (`-AvecApplis`). L'hôte envoie d'abord le signal [`signaux::QUITTER`] à tous les blocs, puis
    /// [`Bloc::fermer`].
    Quitter { avec_applis: bool },
    /// Se relancer (nouveau thème : `Restart-Mindset`, interface.ps1:105). L'hôte écrit `relance.marque` et relance
    /// Mindset.exe une fois la place libérée (Mindset.ps1:162-166).
    Relancer,
    /// Le programme à lancer une fois Mindset fermé (Mindset vient d'être installé : `$script:LancerApres`,
    /// Mindset.ps1:168-169). À donner avec [`Effet::Quitter`].
    LancerApres(PathBuf),
    /// Ouvrir une adresse `https://` ou un dossier par l'Explorateur (comme `Start-Process $url`).
    OuvrirAdresse(String),
    /// Le dossier du thème perso servi par le protocole `pack` (`http://pack.localhost/<fichier>`, règle 6 de
    /// regles-tauri.md) ; `None` : aucun.
    DossierPack(Option<PathBuf>),
    /// Un fichier du PC servi par le protocole `fichier` sous ce nom (`http://fichier.localhost/<nom>`) : seulement
    /// une image (PNG, JPEG, GIF, WebP) ou une police (TTF, OTF) reconnue à ses premiers octets, 16 Mo au plus. Le nom :
    /// 1 à 80 lettres, chiffres, `-`, `_` ou `.`. `chemin: None` retire le nom. Sert aux logos tirés des applis
    /// (console-logos) et aux images d'un thème perso pour la console (theme.mindset.local de la version PowerShell).
    Exposer { nom: String, chemin: Option<PathBuf> },
    /// Renvoyer l'état à la page même s'il n'a pas changé.
    Rafraichir,
    /// La couleur de la barre de titre de la fenêtre, « #RRGGBB » (le fond `#06050F` traduit dans le thème de la
    /// suite : `[MSNative]::SetDarkTitleBar`, interface.ps1:70-74). Demandé par le bloc « paramètres » au démarrage.
    BarreDeTitre(String),
}

/// La liste des effets demandés pendant un appel.
#[derive(Debug, Default)]
pub struct Effets(pub Vec<Effet>);

impl Effets {
    pub fn ajouter(&mut self, e: Effet) {
        self.0.push(e);
    }

    /// Un signal pour les autres blocs.
    pub fn signal(&mut self, nom: &str, donnees: Value) {
        self.0.push(Effet::Signal { nom: nom.into(), donnees });
    }

    /// Un travail de fond.
    pub fn tache(&mut self, id: &str, travail: impl FnOnce() -> Result<Value, String> + Send + 'static) {
        self.0.push(Effet::Tache(Tache::nouvelle(id, travail)));
    }

    /// Rien n'a été demandé.
    pub fn est_vide(&self) -> bool {
        self.0.is_empty()
    }
}

/// Un bloc de Mindset.
///
/// Tous les appels se font sur le fil des blocs, l'un après l'autre. Un bloc qui panique est rattrapé par l'hôte
/// (noté au journal, comme `Write-ErreurImprevue`) ; il continue d'être appelé.
pub trait Bloc: Send {
    /// Son nom court (pour le journal), par exemple « installations ».
    fn nom(&self) -> &'static str;

    /// Au lancement, une fois, dans l'ordre de `blocs()` (`mindset-appli`), AVANT que la fenêtre n'existe : lire ses
    /// fichiers, remplir le tableau commun, préparer ce qui ne dépend pas de l'écran. Un bloc peut y demander
    /// [`Effet::Quitter`] (par exemple : lancé avec Windows alors que « Mindset se lance avec Windows » est coupé).
    fn demarrer(&mut self, _ctx: &Contexte, _effets: &mut Effets) {}

    /// Sa part de l'état envoyé à la page. Les clés de tous les blocs sont fusionnées dans un seul objet : chaque bloc
    /// n'écrit QUE ses clés (la liste est dans l'architecture, une clé = un bloc). L'hôte appelle `etat` après chaque
    /// action, signal, tic ou fin de travail, et n'envoie l'état que s'il a changé.
    fn etat(&mut self, _ctx: &Contexte) -> Map<String, Value> {
        Map::new()
    }

    /// Une action de la page (ou [`Effet::Action`]) : `true` si ce bloc l'a prise (les suivants ne la voient pas).
    /// Les ids sont préfixés par le bloc (« installations:installer », « console:ouvrir »...).
    fn action(&mut self, _ctx: &Contexte, _id: &str, _valeur: &Value, _effets: &mut Effets) -> bool {
        false
    }

    /// Le travail régulier ; rend le délai avant le prochain appel (`None` : plus besoin, jusqu'à ce qu'un signal,
    /// une action ou une fin de travail le relance : l'hôte rappelle alors `tic` aussitôt). Premier appel juste après
    /// l'ouverture de la fenêtre. Mindset caché : voir [`Contexte::vue`] (faire le moins possible).
    fn tic(&mut self, _ctx: &Contexte, _effets: &mut Effets) -> Option<Duration> {
        None
    }

    /// Un message d'un autre bloc ou de l'hôte (voir [`signaux`]).
    fn signal(&mut self, _ctx: &Contexte, _nom: &str, _donnees: &Value, _effets: &mut Effets) {}

    /// La fin d'un travail de fond demandé par ce bloc ([`Effet::Tache`]) : son id, et son résultat (ou l'erreur, en
    /// français ; une panique du travail donne une erreur).
    fn tache_finie(&mut self, _ctx: &Contexte, _id: &str, _resultat: Result<Value, String>, _effets: &mut Effets) {}

    /// Mindset se ferme : rendre ce qui doit l'être (fenêtres accrochées, icône près de l'horloge...). Appelé dans
    /// l'ordre de `blocs()`, après le signal [`signaux::QUITTER`]. L'hôte attend au plus 10 s en tout.
    fn fermer(&mut self, _ctx: &Contexte) {}
}

/// Un dossier d'essai (jamais un vrai dossier de données) : pour les tests de chaque bloc.
pub fn dossier_essai(nom: &str) -> PathBuf {
    std::env::temp_dir().join(format!("mindset-essai-{nom}-{}", std::process::id()))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Vide;
    impl Bloc for Vide {
        fn nom(&self) -> &'static str {
            "vide"
        }
    }

    #[test]
    fn un_bloc_vide_ne_fait_rien() {
        let (ctx, _faux) = essai::contexte("bloc-vide");
        let mut b = Vide;
        let mut e = Effets::default();
        b.demarrer(&ctx, &mut e);
        assert!(b.etat(&ctx).is_empty());
        assert!(!b.action(&ctx, "x", &Value::Null, &mut e));
        assert_eq!(b.tic(&ctx, &mut e), None);
        assert!(e.est_vide());
    }

    #[test]
    fn effets_pratiques() {
        let mut e = Effets::default();
        e.signal("page", serde_json::json!({ "id": "accueil" }));
        e.tache("t1", || Ok(Value::Bool(true)));
        assert_eq!(e.0.len(), 2);
        assert_eq!(e.0[0], Effet::Signal { nom: "page".into(), donnees: serde_json::json!({ "id": "accueil" }) });
        let Effet::Tache(t) = e.0.remove(1) else { panic!() };
        assert_eq!(t.id, "t1");
        assert_eq!(t.lancer(), Ok(Value::Bool(true)));
    }
}
