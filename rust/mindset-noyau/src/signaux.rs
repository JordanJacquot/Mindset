//! Les signaux : un message d'un bloc (ou de l'hôte) à tous les autres, reçu par `Bloc::signal`. C'est ainsi qu'un
//! bloc demande à un autre ce qu'il ne fait pas lui-même, sans dépendre de lui (la version PowerShell appelait
//! directement la fonction d'un autre module).
//!
//! Le bloc qui envoie n'attend pas de réponse : quand il y en a une, c'est un autre signal (`admin-fini`...). Un signal
//! envoyé pendant `etat()` n'existe pas (etat ne reçoit pas d'effets) ; pendant `demarrer`, il est rendu après le
//! démarrage de tous les blocs.
//!
//! **Envoyés par l'hôte** (`mindset-appli`) :
//!
//! | Signal | Données | Quand |
//! |---|---|---|
//! | `page` | `{ "id", "avant" }` | après `Effet::Page` (la vue du contexte est déjà à jour) |
//! | `fenetre` | `{ "visible": bool, "reduite": bool }` | la fenêtre est montrée, cachée, réduite ou remise |
//! | `afficher-demande` | `{}` | un autre lancement de Mindset a levé `Local\Mindset-Afficher` (Mindset.ps1:83-98, interface.ps1:112-117) |
//! | `croix` | `{}` | la croix rouge, Alt+F4 (`Add_Closing`, zone.ps1:80-97) : la fenêtre n'est pas fermée, le bloc horloge décide |
//! | `reduite` | `{}` | la fenêtre vient d'être réduite (`Add_StateChanged`, zone.ps1:70-75) |
//! | `quitter` | `{ "avec_applis": bool, "relancer": bool }` | juste avant `Bloc::fermer` |
//! | `erreur-imprevue` | `{ "texte" }` | la première fois qu'un bloc panique (`Show-MessageErreurImprevue`, interface.ps1:158-165) |
//!
//! **Envoyés par les blocs** :
//!
//! | Signal | Données | Envoyé par | Pris par |
//! |---|---|---|---|
//! | `actualiser` | `{ "clic": bool }` | ecrans, console, horloge, parametres | publications (`Invoke-Actualiser`) |
//! | `verifier-mindset` | `{}` | publications | lui-meme (`Start-VerifMajMindset`) |
//! | `verifier-liste` | `{}` | publications | liste (`Update-ListeEnLigne`) |
//! | `publications-changees` | `{}` | publications | ecrans, console, parametres, lui-meme |
//! | `installer` | `{ "id", "ancien": dossier ou null, "auto": bool }` | ecrans, console, lui-meme | installations (`Start-InstallAppli`) |
//! | `desinstaller` | `{ "id" }` | ecrans | installations (`Start-DesinstallAppli`) |
//! | `utiliser-trouvee` | `{ "id", "dossier" }` | ecrans | installations (`Use-InstallationTrouvee`) |
//! | `operation-finie` | `{ "id", "quoi": "installation" \| "desinstallation", "ok": bool, "message", "auto": bool }` | installations | lui-meme, console, ecrans |
//! | `installations-changees` | `{}` | installations | tous ceux qui montrent les applis |
//! | `lancer-appli` | `{ "id", "demarrage": bool }` | accrochage, lui-meme | installations (`Open-Appli`) |
//! | `demande-quitter` | `{ "id" }` | accrochage, console | installations (`Write-DemandeQuitter`) |
//! | `ouvrir-appli` | `{ "id", "lancer": bool }` | console, horloge, parametres, ecrans | accrochage (`Open-AppliIci`, `Show-AppliIntegree -Lancer`) |
//! | `fermer-appli` | `{ "id" }` | console, ecrans | accrochage (`WM_CLOSE` si accrochée, sinon `demande-quitter`) |
//! | `admin-demande` | `{ "id", "action", "parametres": {..}, "repli": bool, "auto": bool }` | lui-meme, parametres | installations (`Invoke-Admin`, `Send-DemandeInstallation`) |
//! | `admin-recu` | `{ "id" }` | installations | celui qui a demandé (accusé de réception de la tâche) |
//! | `admin-fini` | `{ "id", "ok": bool, "message" }` | installations | celui qui a demandé |
//! | `confirmation` | `{ "titre", "texte", "bouton", "action", "valeur" }` | tous | ecrans (`Show-Confirmation`) : « Oui » rend `Effet::Action { action, valeur }` |
//! | `bulle` | `{ "titre", "texte", "icone": "info" \| "attention" \| "aucune", "duree_ms" }` | tous | horloge (`Show-BulleMindset`) |
//! | `message-console` | `{ "texte" }` | tous | console (`window.mindset.message`) |
//! | `voile` | `{ "visible": bool }` | ecrans | accrochage, console (`Update-HotesVisibles`, `Update-ConsoleMasquee`) |
//! | `reglage-change` | `{ "nom", "valeur" }` | parametres, console, horloge | tous (un réglage commun vient de changer) |
//! | `ouvrir-parametres` | `{ "onglet" }` | console, horloge, ecrans | parametres (`Show-OngletParametres` puis la page) |
//! | `demarrage-appli` | `{ "id", "oui": bool }` | ecrans, parametres | installations (`Set-DemarrageAppli` : « S'ouvre avec Mindset ») |
//! | `versions-essai` | `{ "id", "oui": bool }` | parametres | publications (`Set-VersionsEssaiAppli`) |
//! | `maj-mindset` | `{ "confirmer": bool }` | console, ecrans, parametres | lui-meme (`Start-MajMindset` ; `confirmer` : `Confirm-MajMindsetConsole` d'abord) |
//! | `desinstaller-mindset` | `{}` | parametres | lui-meme (`Confirm-DesinstallMindset`) |
//! | `confidentialite` | `{ "id" }` (« » : celle de Mindset) | console, ecrans, parametres | lui-meme (`Open-PageConfidentialite`) |

use crate::Effet;
use serde_json::{Value, json};

pub const PAGE: &str = "page";
pub const FENETRE: &str = "fenetre";
pub const AFFICHER_DEMANDE: &str = "afficher-demande";
pub const CROIX: &str = "croix";
pub const REDUITE: &str = "reduite";
pub const QUITTER: &str = "quitter";
pub const ERREUR_IMPREVUE: &str = "erreur-imprevue";

pub const ACTUALISER: &str = "actualiser";
pub const VERIFIER_MINDSET: &str = "verifier-mindset";
pub const VERIFIER_LISTE: &str = "verifier-liste";
pub const PUBLICATIONS_CHANGEES: &str = "publications-changees";
pub const INSTALLER: &str = "installer";
pub const DESINSTALLER: &str = "desinstaller";
pub const UTILISER_TROUVEE: &str = "utiliser-trouvee";
pub const OPERATION_FINIE: &str = "operation-finie";
pub const INSTALLATIONS_CHANGEES: &str = "installations-changees";
pub const LANCER_APPLI: &str = "lancer-appli";
pub const DEMANDE_QUITTER: &str = "demande-quitter";
pub const OUVRIR_APPLI: &str = "ouvrir-appli";
pub const FERMER_APPLI: &str = "fermer-appli";
pub const ADMIN_DEMANDE: &str = "admin-demande";
pub const ADMIN_RECU: &str = "admin-recu";
pub const ADMIN_FINI: &str = "admin-fini";
pub const CONFIRMATION: &str = "confirmation";
pub const BULLE: &str = "bulle";
pub const MESSAGE_CONSOLE: &str = "message-console";
pub const VOILE: &str = "voile";
pub const REGLAGE_CHANGE: &str = "reglage-change";
pub const OUVRIR_PARAMETRES: &str = "ouvrir-parametres";
pub const DEMARRAGE_APPLI: &str = "demarrage-appli";
pub const VERSIONS_ESSAI: &str = "versions-essai";
pub const MAJ_MINDSET: &str = "maj-mindset";
pub const DESINSTALLER_MINDSET: &str = "desinstaller-mindset";
pub const CONFIDENTIALITE: &str = "confidentialite";

/// Tous les signaux connus : un signal inconnu est noté au journal par l'hôte (une faute de frappe se voit).
pub const TOUS: &[&str] = &[
    PAGE,
    FENETRE,
    AFFICHER_DEMANDE,
    CROIX,
    REDUITE,
    QUITTER,
    ERREUR_IMPREVUE,
    ACTUALISER,
    VERIFIER_MINDSET,
    VERIFIER_LISTE,
    PUBLICATIONS_CHANGEES,
    INSTALLER,
    DESINSTALLER,
    UTILISER_TROUVEE,
    OPERATION_FINIE,
    INSTALLATIONS_CHANGEES,
    LANCER_APPLI,
    DEMANDE_QUITTER,
    OUVRIR_APPLI,
    FERMER_APPLI,
    ADMIN_DEMANDE,
    ADMIN_RECU,
    ADMIN_FINI,
    CONFIRMATION,
    BULLE,
    MESSAGE_CONSOLE,
    VOILE,
    REGLAGE_CHANGE,
    OUVRIR_PARAMETRES,
    DEMARRAGE_APPLI,
    VERSIONS_ESSAI,
    MAJ_MINDSET,
    DESINSTALLER_MINDSET,
    CONFIDENTIALITE,
];

/// Le signal est-il connu ?
pub fn connu(nom: &str) -> bool {
    TOUS.contains(&nom)
}

fn signal(nom: &str, donnees: Value) -> Effet {
    Effet::Signal { nom: nom.into(), donnees }
}

/// `confirmation` : la question « Êtes-vous sûr ? » (`Show-Confirmation`) ; « Oui » renvoie l'action `action` avec
/// `valeur`, « Annuler » ne fait rien.
pub fn confirmation(titre: &str, texte: &str, bouton: &str, action: &str, valeur: Value) -> Effet {
    signal(
        CONFIRMATION,
        json!({ "titre": titre, "texte": texte, "bouton": bouton, "action": action, "valeur": valeur }),
    )
}

/// `bulle` : une bulle près de l'horloge (`Show-BulleMindset`). `icone` : « info », « attention » ou « aucune ».
pub fn bulle(titre: &str, texte: &str, icone: &str, duree_ms: u32) -> Effet {
    signal(BULLE, json!({ "titre": titre, "texte": texte, "icone": icone, "duree_ms": duree_ms }))
}

/// `admin-demande` : une opération en administrateur, par le bloc « installations » (`Invoke-Admin`). `id` : choisi
/// par le demandeur (32 chiffres hexadécimaux), rendu dans `admin-recu` et `admin-fini`.
pub fn admin_demande(id: &str, action: &str, parametres: Value, repli: bool, auto: bool) -> Effet {
    signal(ADMIN_DEMANDE, json!({ "id": id, "action": action, "parametres": parametres, "repli": repli, "auto": auto }))
}

/// `ouvrir-appli` : l'appli dans son onglet de Mindset (`lancer` : elle est lancée si elle ne tourne pas).
pub fn ouvrir_appli(id: &str, lancer: bool) -> Effet {
    signal(OUVRIR_APPLI, json!({ "id": id, "lancer": lancer }))
}

/// `installer` : installer ou mettre à jour une appli (`ancien` : la copie trouvée qu'on prend en charge).
pub fn installer(id: &str, ancien: Option<&str>, auto: bool) -> Effet {
    signal(INSTALLER, json!({ "id": id, "ancien": ancien, "auto": auto }))
}

/// `actualiser` : chercher les nouvelles versions (`clic` : demandé par l'utilisateur).
pub fn actualiser(clic: bool) -> Effet {
    signal(ACTUALISER, json!({ "clic": clic }))
}

/// `message-console` : une phrase courte sur l'écran de la console.
pub fn message_console(texte: &str) -> Effet {
    signal(MESSAGE_CONSOLE, json!({ "texte": texte }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn champs_fixes() {
        assert_eq!(
            confirmation("Désinstaller ?", "Texte", "Désinstaller", "installations:desinstaller", json!("evermind")),
            Effet::Signal {
                nom: "confirmation".into(),
                donnees: json!({ "titre": "Désinstaller ?", "texte": "Texte", "bouton": "Désinstaller",
                    "action": "installations:desinstaller", "valeur": "evermind" })
            }
        );
        assert!(connu("admin-fini"));
        assert!(!connu("admin-finie"));
        let mut vus = std::collections::HashSet::new();
        assert!(TOUS.iter().all(|s| vus.insert(*s)), "un signal en double");
    }
}
