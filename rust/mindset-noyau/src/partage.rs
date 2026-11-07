//! Le tableau commun : ce qu'un bloc sait et que les autres lisent, à la place des variables `$script:` que les modules
//! PowerShell partageaient (`$script:Publications`, `$script:Occupe`, `$script:Progres`, `$script:Trouvees`...).
//!
//! Règle : **chaque clé a un seul bloc qui l'écrit** ([`PROPRIETAIRES`]) ; les autres ne font que la lire.
//! `Contexte::publier` refuse (et note au journal) une clé écrite par un autre bloc que le sien, ou une clé inconnue.
//! Les valeurs sont du JSON, dans la forme décrite ici (champs en minuscules, sans accents) ; un bloc peut ajouter des
//! champs, jamais en retirer ni en changer le sens.
//!
//! | Clé | Bloc | Forme |
//! |---|---|---|
//! | `installations` | installations | `{ <id>: { "dossier", "gere": bool, "version": texte ou null } }` : `Get-Installation` de chaque appli installée ou prise en charge (absente : pas installée) |
//! | `occupations` | installations | `{ <id>: { "texte": "Téléchargement...", "progres": 0..1 ou null, "version": texte ou null, "auto": bool, "quoi": "installation" \| "desinstallation" \| "deplacement" } }` : `$script:Occupe`, `$script:Progres`, `$script:EnCours` |
//! | `messages` | installations | `{ <id>: texte }` : le dernier message de la carte (`$script:Messages`) |
//! | `trouvees` | installations | `{ <id>: dossier }` : une copie déjà sur le PC (`$script:Trouvees`, `Find-InstallationExistante`) |
//! | `demarrages` | installations | `{ <id>: bool }` : « S'ouvre avec Mindset » (`Get-DemarrageAppli`) |
//! | `admin` | installations | `{ "tache": "systeme" | "ancienne" | "absente" | "inconnue", "en_cours": nombre de demandes en attente, "remplacement": null | "en_cours" | "ok" | "echec" }` (le remplacement de l'ancienne tâche au démarrage) || "ancienne" \| "absente", "en_cours": nombre de demandes en attente }` |
//! | `publications` | publications | `{ <id ou "mindset">: { "version", "url_zip", "url_sig", "notes", "essai": bool } ou { "erreur": texte } }` : `$script:Publications` |
//! | `recherche` | publications | `{ "verifie_a": "HH:mm" ou null, "texte", "auto": bool, "en_cours": [ids], "en_attente": { <id>: moment }, "mindset_en_cours": bool (la question pour Mindset lui-même est partie, pas encore de réponse), "depuis": moment au format s ou null, "derniere": moment ou null }` : `$script:Recherches`, `$script:RechercheDepuis`, `$script:DernieresPublications`, `$script:VerifieA` |
//! | `ouvertes` | liste | `{ <id>: bool }` : `Test-AppliOuverte` de chaque appli, relu toutes les 1,5 s (30 s Mindset caché) |
//! | `liste` | liste | `{ "source": "apps.json" \| "en-ligne", "numero": nombre ou null }` : d'où vient la liste des applis |
//! | `mindset` | lui-meme | `{ "installe": bool, "developpement": bool, "bienvenue": bool, "maj": { "version", "notes", "prete": bool, "progres": 0..1 ou null, "en_cours": bool } ou null, "derniere_maj": { "id", "nom", "version", "quand", "auto", "notes" } ou null, "historique": [...], "verif": bool, "auto": bool }` |
//! | `maj-auto` | lui-meme | `{ "en_cours": { <id>: version }, "echecs": { <id>: { "version", "raison", "reessai": minutes ou -1 } }, "jeu": nom ou "", "jeu_nom", "attentes": { <id>: "utilise" | "page" | "veille" }, "essais": { <id>: { "version", "quand": moment au format s, "nombre", "reessai" } } }` || "page" \| "veille" } }` |
//! | `accrochees` | accrochage | `{ <id>: { "etat": "vide" \| "lancement" \| "relance" \| "affiche" \| "cachee" \| "refus", "pid": nombre ou null, "fenetre": nombre ou null } }` : `$script:Integrees` |
//! | `console` | console | `{ "possible": bool, "parametres": bool, "en_fente": id ou null, "raison": texte ou null (ce qui empêche la 3D sur ce PC : toujours null en Rust) }` : `$script:Console` |
//! | `voile` | ecrans | `bool` : une question de Mindset (confirmation, croix) est par-dessus : l'appli accrochée et la console s'effacent |
//! | `theme` | parametres | `{ "id": "neon" \| ... \| "pack:<id>", "couleurs": { "#00E5FF": "#FF8A3D", ... }, "police": nom ou null, "pack": objet ou null }` : `ConvertTo-ThemeHex` pour chaque couleur Néon |
//! | `onglet-parametres` | parametres | `"general" \| "apparence" \| "son" \| "maj" \| "conso" \| "dossiers"` : `$script:OngletParametres` |

use serde_json::Value;

use crate::appli::Installation;
use crate::contexte::Contexte;

pub const INSTALLATIONS: &str = "installations";
pub const OCCUPATIONS: &str = "occupations";
pub const MESSAGES: &str = "messages";
pub const TROUVEES: &str = "trouvees";
pub const DEMARRAGES: &str = "demarrages";
pub const ADMIN: &str = "admin";
pub const PUBLICATIONS: &str = "publications";
pub const RECHERCHE: &str = "recherche";
pub const OUVERTES: &str = "ouvertes";
pub const LISTE: &str = "liste";
pub const MINDSET: &str = "mindset";
pub const MAJ_AUTO: &str = "maj-auto";
pub const ACCROCHEES: &str = "accrochees";
pub const CONSOLE: &str = "console";
pub const VOILE: &str = "voile";
pub const THEME: &str = "theme";
pub const ONGLET_PARAMETRES: &str = "onglet-parametres";

/// Chaque clé et le seul bloc qui l'écrit (son `Bloc::nom`).
pub const PROPRIETAIRES: &[(&str, &str)] = &[
    (INSTALLATIONS, "installations"),
    (OCCUPATIONS, "installations"),
    (MESSAGES, "installations"),
    (TROUVEES, "installations"),
    (DEMARRAGES, "installations"),
    (ADMIN, "installations"),
    (PUBLICATIONS, "publications"),
    (RECHERCHE, "publications"),
    (OUVERTES, "liste"),
    (LISTE, "liste"),
    (MINDSET, "lui-meme"),
    (MAJ_AUTO, "lui-meme"),
    (ACCROCHEES, "accrochage"),
    (CONSOLE, "console"),
    (VOILE, "ecrans"),
    (THEME, "parametres"),
    (ONGLET_PARAMETRES, "parametres"),
];

/// Le bloc qui écrit cette clé, `None` si elle est inconnue.
pub fn proprietaire(cle: &str) -> Option<&'static str> {
    PROPRIETAIRES.iter().find(|(c, _)| *c == cle).map(|(_, b)| *b)
}

/// L'installation connue d'une appli (`installations`), `None` si elle n'est pas installée.
pub fn installation(ctx: &Contexte, id: &str) -> Option<Installation> {
    let v = ctx.lu(INSTALLATIONS)?;
    Installation::depuis_json(v.get(id)?)
}

/// Toutes les installations connues, dans l'ordre de la liste des applis.
pub fn installations(ctx: &Contexte) -> Vec<(String, Installation)> {
    let Some(v) = ctx.lu(INSTALLATIONS) else { return Vec::new() };
    ctx.applis().iter().filter_map(|a| Some((a.id.clone(), Installation::depuis_json(v.get(&a.id)?)?))).collect()
}

/// Le texte de l'opération en cours sur cette appli (`$script:Occupe[id]`), `None` si rien.
pub fn occupation(ctx: &Contexte, id: &str) -> Option<String> {
    let v = ctx.lu(OCCUPATIONS)?;
    v.get(id)?.get("texte")?.as_str().map(str::to_string)
}

/// Une opération est-elle en cours sur une appli (`$script:Occupe.Count`) ?
pub fn une_occupation(ctx: &Contexte) -> bool {
    ctx.lu(OCCUPATIONS).is_some_and(|v| v.as_object().is_some_and(|m| !m.is_empty()))
}

/// L'appli est-elle ouverte, d'après le dernier relevé du bloc « liste » (`ouvertes`) ?
pub fn ouverte(ctx: &Contexte, id: &str) -> bool {
    ctx.lu(OUVERTES).and_then(|v| v.get(id).and_then(Value::as_bool)).unwrap_or(false)
}

/// La dernière publication connue d'une appli (ou de « mindset »).
pub fn publication(ctx: &Contexte, id: &str) -> Option<Value> {
    ctx.lu(PUBLICATIONS)?.get(id).cloned()
}

/// Une question de Mindset est-elle par-dessus (`voile`) ?
pub fn voile(ctx: &Contexte) -> bool {
    ctx.lu(VOILE).and_then(|v| v.as_bool()).unwrap_or(false)
}

/// Une couleur Néon traduite dans le thème de la suite (`ConvertTo-ThemeHex`), telle quelle si le thème ne la change
/// pas (ou n'est pas encore connu).
pub fn couleur(ctx: &Contexte, hex: &str) -> String {
    let haut = hex.to_uppercase();
    ctx.lu(THEME)
        .and_then(|t| t.get("couleurs").and_then(|c| c.get(&haut)).and_then(Value::as_str).map(str::to_string))
        .unwrap_or(haut)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn chaque_cle_a_un_seul_bloc() {
        let mut vues = std::collections::HashSet::new();
        for (c, _) in PROPRIETAIRES {
            assert!(vues.insert(*c), "clé en double : {c}");
        }
        assert_eq!(proprietaire(INSTALLATIONS), Some("installations"));
        assert_eq!(proprietaire("inconnue"), None);
    }

    #[test]
    fn lectures() {
        let (ctx, _f) = crate::essai::contexte("partage");
        assert!(installation(&ctx, "evermind").is_none());
        ctx.au_nom_de("installations", || {
            ctx.publier(
                INSTALLATIONS,
                json!({ "evermind": { "dossier": r"C:\P\Evermind", "gere": true, "version": "1.2.0" } }),
            );
            ctx.publier(OCCUPATIONS, json!({ "evermind": { "texte": "Téléchargement..." } }));
        });
        let i = installation(&ctx, "evermind").unwrap();
        assert!(i.gere);
        assert_eq!(i.version.as_deref(), Some("1.2.0"));
        assert_eq!(occupation(&ctx, "evermind").as_deref(), Some("Téléchargement..."));
        assert!(une_occupation(&ctx));
        assert_eq!(couleur(&ctx, "#00e5ff"), "#00E5FF");
        ctx.au_nom_de("parametres", || ctx.publier(THEME, json!({ "couleurs": { "#00E5FF": "#FF8A3D" } })));
        assert_eq!(couleur(&ctx, "#00e5ff"), "#FF8A3D");
    }

    #[test]
    fn une_cle_d_un_autre_bloc_est_refusee() {
        let (ctx, f) = crate::essai::contexte("partage-refus");
        ctx.au_nom_de("console", || ctx.publier(INSTALLATIONS, json!({})));
        assert!(ctx.lu(INSTALLATIONS).is_none());
        ctx.au_nom_de("console", || ctx.publier("inventee", json!(1)));
        assert!(ctx.lu("inventee").is_none());
        assert_eq!(f.donnees.lignes().len(), 2);
    }
}
