//! Les cartes de l'accueil classique, une par appli (`Update-Carte`, `Get-EtatCarte`, `Add-ResumeCarte`,
//! `New-Pastille`, `New-BoutonAction`, `New-JaugeScore`, `New-LigneVivante`, `New-InterrupteurOuverture`,
//! `New-PhraseReseau`, accueil.ps1:112-438) et les questions de leurs boutons (`Confirm-MiseAJour`,
//! `Confirm-PriseEnCharge`, `Confirm-Desinstallation`, accueil.ps1:443-475).
//!
//! Une carte est envoyée à la page comme la liste de ses éléments, dans l'ordre où `Update-Carte` les pose, avec leurs
//! textes, tailles, couleurs (déjà dans le thème) et marges : la page ne fait que les dessiner. C'est la même forme que
//! les juges relus dans la vraie fenêtre WPF (outils\exporter-juges-ecrans.ps1).

use mindset_noyau::appli::{Appli, Installation};
use mindset_noyau::moment::HeureLocale;
use serde_json::{Value, json};

use crate::couleurs::Traducteur;
use crate::etat_appli::Resume;
use crate::rdv;

/// Ce que la carte doit montrer (`Get-EtatCarte`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct EtatCarte {
    pub inst: Option<Installation>,
    /// La dernière version publiée (`$pub.Version`)
    pub pub_version: Option<String>,
    /// L'erreur de la dernière recherche (`$pub.Erreur`)
    pub pub_erreur: Option<String>,
    pub ouverte: bool,
    /// Une copie trouvée sur le PC (`$script:Trouvees`)
    pub trouvee: Option<String>,
    /// Cette copie est un dossier de travail (Git) : `Test-DossierTravail`
    pub trouvee_travail: bool,
    /// L'opération en cours (`$script:Occupe`)
    pub occupe: Option<String>,
    pub message: Option<String>,
    pub resume: Option<Resume>,
    /// Son ancien dossier de données existe (`Test-Path $Appli.Donnees`)
    pub donnees_existe: bool,
    /// « S'ouvre avec Mindset »
    pub demarrage: bool,
    /// Elle a besoin des droits administrateur (`Test-AppliAdmin`)
    pub appli_admin: bool,
    /// Mindset a les droits administrateur (`$MindsetAdmin`)
    pub mindset_admin: bool,
}

impl EtatCarte {
    /// `MajDispo` : installée par Mindset, et une version publiée plus récente.
    pub fn maj_dispo(&self) -> bool {
        match (&self.inst, &self.pub_version) {
            (Some(i), Some(p)) if i.gere => {
                i.version.as_deref().is_some_and(|v| suite_commun::version::plus_recente(p, v))
            }
            _ => false,
        }
    }
}

fn texte(t: &Traducteur, texte: &str, taille: f64, couleur: &str, poids: &str, marge: Option<&str>) -> Value {
    let mut o = json!({ "t": "texte", "texte": texte, "taille": taille, "couleur": t.tr(couleur), "poids": poids });
    if let Some(m) = marge {
        o["marge"] = json!(m);
    }
    o
}

fn pastille(t: &Traducteur, texte: &str, couleur: &str) -> Value {
    json!({ "texte": texte, "couleur": t.tr(couleur) })
}

fn bouton(texte: &str, primaire: bool, quoi: &str) -> Value {
    json!({ "texte": texte, "style": if primaire { "primaire" } else { "secondaire" }, "quoi": quoi })
}

/// Une jauge de score (`New-JaugeScore`) : son nom, sa valeur et les deux couleurs de son anneau.
fn jauge(t: &Traducteur, nom: &str, valeur: u8, paire: (&str, &str)) -> Value {
    json!({ "nom": nom, "valeur": valeur, "c1": t.tr(paire.0), "c2": t.tr(paire.1) })
}

const PAIRES: [(&str, &str); 2] = [("#00E5FF", "#7A7BFF"), ("#FF2EB5", "#B04BFF")];

/// `Add-ResumeCarte`
fn resume(t: &Traducteur, r: &Resume, maintenant: &HeureLocale) -> Value {
    match r {
        Resume::Nevermind { score, protection, a_faire, urgent } => {
            let scores: Vec<Value> = [("Optimisation", *score, PAIRES[0]), ("Protection", *protection, PAIRES[1])]
                .iter()
                .filter_map(|(n, v, p)| v.map(|v| jauge(t, n, v, *p)))
                .collect();
            let texte = if a_faire.is_empty() {
                "Rien à corriger : ton PC est prêt pour jouer.".to_string()
            } else {
                format!("À faire : {a_faire}")
            };
            let couleur = if *urgent {
                "#FFB020"
            } else if !a_faire.is_empty() {
                "#ECEAF7"
            } else {
                "#3DDC84"
            };
            json!({ "t": "resume", "genre": "nevermind", "scores": scores, "ligne": { "texte": texte, "couleur": t.tr(couleur) } })
        }
        Resume::Evermind { prochains } => {
            let l: Vec<Value> = rdv::prochains(prochains, maintenant)
                .iter()
                .map(|r| {
                    json!({ "quand": rdv::quand(r, maintenant), "titre": r.titre, "id": r.id,
                        "moment": mindset_noyau::moment::iso(&r.quand) })
                })
                .collect();
            let mut o = json!({ "t": "resume", "genre": "evermind", "rdv": l });
            if l.is_empty() {
                o["vide"] = json!("Rien de prévu pour le moment.");
            }
            o
        }
        Resume::Commun { titre, scores, lignes } => {
            let s: Vec<Value> = scores.iter().zip(PAIRES).map(|(s, p)| jauge(t, &s.nom, s.valeur, p)).collect();
            let l: Vec<Value> = lignes
                .iter()
                .map(|l| {
                    let c = match l.etat.as_str() {
                        "ok" => "#3DDC84",
                        "attention" => "#FFB020",
                        "urgent" => "#FF5C7A",
                        _ => "#ECEAF7",
                    };
                    json!({ "texte": l.texte, "couleur": t.tr(c) })
                })
                .collect();
            json!({ "t": "resume", "genre": "commun", "titre": if titre.is_empty() { Value::Null } else { json!(titre) },
                "scores": s, "lignes": l })
        }
    }
}

/// `Get-PhraseReseauAppli` : ce qui part sur Internet quand Mindset installe l'appli.
pub fn phrase_reseau(a: &Appli) -> String {
    let mut t = format!(
        "{} se télécharge depuis GitHub. Ensuite, Mindset vérifie sur GitHub s'il en existe une nouvelle version. Rien d'autre n'est envoyé par Mindset, et tu peux couper cette vérification dans les Paramètres.",
        a.nom
    );
    if !a.confidentialite.is_empty() {
        t.push_str(&format!(" Ce que {} envoie lui-même sur Internet est expliqué sur sa page.", a.nom));
    }
    t
}

/// `Get-LienReseauAppli`
pub fn lien_reseau(a: &Appli) -> String {
    if a.confidentialite.is_empty() { "Ce qui part sur Internet".into() } else { format!("La page de {}", a.nom) }
}

/// `Update-Carte` : les éléments de la carte, dans l'ordre.
pub fn elements(a: &Appli, e: &EtatCarte, t: &Traducteur, maintenant: &HeureLocale) -> Vec<Value> {
    let mut l = vec![
        texte(t, &a.nom, 20.0, &a.couleur, "SemiBold", None),
        texte(t, &a.description, 13.0, "#A9A3C9", "Normal", Some("0,4,0,12")),
    ];
    let maj = e.maj_dispo();

    // Pastilles : installée (version) ou non, ouverte ou non, mise à jour disponible
    let mut p = Vec::new();
    if let Some(i) = &e.inst {
        p.push(pastille(
            t,
            &format!("Version {}", i.version.as_deref().filter(|v| !v.is_empty()).unwrap_or("?")),
            "#A9A3C9",
        ));
        p.push(if e.ouverte { pastille(t, "Ouvert", "#3DDC84") } else { pastille(t, "Fermé", "#6F6894") });
        if maj {
            p.push(pastille(t, &format!("Nouvelle version {}", e.pub_version.as_deref().unwrap_or("")), "#FFB020"));
        }
    } else if e.trouvee.is_some() {
        p.push(pastille(t, "Trouvé sur ce PC", "#FFB020"));
    } else {
        p.push(pastille(t, "Pas installé", "#6F6894"));
    }
    l.push(json!({ "t": "pastilles", "marge": "0,0,0,12", "liste": p }));
    if let Some(r) = e.resume.as_ref().filter(|_| e.inst.as_ref().is_some_and(|i| i.gere)) {
        l.push(resume(t, r, maintenant));
    }

    if let Some(i) = e.inst.as_ref().filter(|i| !i.gere) {
        l.push(texte(t, &format!("Copie de {}, non gérée par Mindset.", i.dossier), 12.0, "#6F6894", "Normal", None));
    }
    if let (None, Some(tr)) = (&e.inst, &e.trouvee) {
        l.push(texte(
            t,
            &format!(
                "Une copie existe déjà dans {tr}. Prends-la en charge pour continuer à l'utiliser : tes réglages et tes données sont gardés."
            ),
            12.0,
            "#A9A3C9",
            "Normal",
            None,
        ));
    }

    // Boutons : ce qu'on peut faire dans cette situation
    let mut b = Vec::new();
    if let Some(o) = &e.occupe {
        l.push(texte(t, o, 13.0, "#00E5FF", "Normal", None));
    } else if e.inst.is_none() && e.trouvee.is_some() {
        b.push(bouton("Prendre en charge", true, "prendre"));
        // (hors de Mindset, les applis ne s'ouvrent plus : seule une copie de travail peut servir telle quelle)
        if e.trouvee_travail {
            b.push(bouton("Utiliser telle quelle", false, "utiliser"));
        }
    } else if e.inst.is_none() {
        b.push(bouton("Installer", true, "installer"));
        if e.donnees_existe {
            l.push(texte(
                t,
                &format!(
                    "Tu avais déjà {} ? Montre son dossier pour qu'il soit pris en charge (sinon il resterait en double).",
                    a.nom
                ),
                12.0,
                "#A9A3C9",
                "Normal",
                None,
            ));
            b.push(bouton("Choisir son dossier", false, "choisir"));
        }
    } else if let Some(i) = &e.inst {
        if maj {
            b.push(bouton("Mettre à jour", true, "maj"));
        }
        b.push(bouton("Ouvrir", !maj, "ouvrir"));
        b.push(if i.gere {
            bouton("Désinstaller", false, "desinstaller")
        } else {
            bouton("Prendre en charge", false, "prendre")
        });
    }
    if !b.is_empty() {
        l.push(json!({ "t": "boutons", "marge": "0,10,0,0", "liste": b }));
    }
    // Pas encore installée : ce qui partira sur Internet, avant le clic
    if e.inst.is_none() && e.occupe.is_none() {
        l.push(
            json!({ "t": "reseau", "texte": format!("{} ", phrase_reseau(a)), "lien": lien_reseau(a), "taille": 11.5,
            "couleur": t.tr("#6F6894"), "lien_couleur": t.tr("#A9A3C9"), "marge": "0,12,0,0" }),
        );
    }

    // « S'ouvre avec Mindset » : l'appli démarre en arrière-plan à l'ouverture de Mindset (et donc avec Windows)
    if e.inst.as_ref().is_some_and(|i| i.gere) && e.occupe.is_none() && (!e.appli_admin || e.mindset_admin) {
        let (tx, aide) = if a.rappels {
            (
                "S'ouvre avec Mindset (sinon tes rappels ne sonnent pas)",
                "En arrière-plan : ses rappels sonnent même avant que tu ouvres son onglet.",
            )
        } else {
            ("S'ouvre avec Mindset", "En arrière-plan, prêt dans son onglet.")
        };
        l.push(json!({ "t": "interrupteur", "oui": e.demarrage, "texte": tx, "aide": aide, "marge": "0,16,0,0" }));
    }

    if let Some(m) = e.message.as_ref().filter(|m| !m.is_empty() && e.occupe.is_none()) {
        l.push(texte(t, m, 12.0, "#A9A3C9", "Normal", Some("0,12,0,0")));
    } else if let Some(err) = e.pub_erreur.as_ref().filter(|x| !x.is_empty() && e.inst.is_none()) {
        l.push(texte(t, err, 12.0, "#6F6894", "Normal", Some("0,12,0,0")));
    }
    l
}

// ---------------------------------------------------------------------------------------------------------------
// Les questions des boutons
// ---------------------------------------------------------------------------------------------------------------

/// Ce que fait le « Oui » d'une question.
#[derive(Debug, Clone, PartialEq)]
pub enum Suite {
    /// Un signal aux autres blocs (installer, désinstaller...)
    Signal { nom: String, donnees: Value },
    /// Une action passée aux blocs (une question posée par un autre bloc : signal `confirmation`)
    Action { id: String, valeur: Value },
}

/// « Êtes-vous sûr ? » (`Show-Confirmation`).
#[derive(Debug, Clone, PartialEq)]
pub struct Question {
    pub titre: String,
    pub texte: String,
    pub bouton: String,
    pub suite: Suite,
}

fn installer(id: &str, ancien: Option<&str>) -> Suite {
    Suite::Signal {
        nom: mindset_noyau::signaux::INSTALLER.into(),
        donnees: json!({ "id": id, "ancien": ancien, "auto": false }),
    }
}

/// `Confirm-MiseAJour` : une question si l'appli est ouverte ; sinon `Err` avec ce qu'il faut faire tout de suite.
pub fn question_maj(a: &Appli, ouverte: bool, version: &str) -> Result<Question, Suite> {
    if !ouverte {
        return Err(installer(&a.id, None));
    }
    Ok(Question {
        titre: format!("Mettre à jour {} ?", a.nom),
        texte: format!(
            "{} va être fermé le temps de la mise à jour (version {version}). Ses réglages et ses données sont gardés.",
            a.nom
        ),
        bouton: "Fermer et mettre à jour".into(),
        suite: installer(&a.id, None),
    })
}

/// `Confirm-PriseEnCharge`. `gere` : le dossier où Mindset l'installe (`Get-DossierGere`) ; `suite_dir` : les données
/// de la suite (`$SuiteDir`) ; `travail` : la copie est un dossier de travail (Git).
pub fn question_prise_en_charge(
    a: &Appli,
    dossier: &str,
    gere: &str,
    suite_dir: &str,
    travail: bool,
    ouverte: bool,
) -> Question {
    let mut t = format!(
        "Mindset installe la dernière version signée de {n} dans {gere}. Ses raccourcis directs sont retirés : il s'ouvrira depuis Mindset. S'il se lançait avec Windows, c'est Mindset qui le lancera. Ses réglages et ses données sont gardés (ils rejoignent {suite_dir}\\{n}).",
        n = a.nom
    );
    if travail {
        t.push_str(&format!("\n\n{dossier} est un dossier de travail : il est gardé tel quel."));
    } else {
        t.push_str(&format!(
            "\n\nL'ancienne copie ({dossier}) est ensuite supprimée (seulement les fichiers de {}).",
            a.nom
        ));
    }
    if ouverte {
        t.push_str(&format!(" {} va être fermé pendant l'opération.", a.nom));
    }
    t.push_str(&format!("\n\n{}", phrase_reseau(a)));
    Question {
        titre: format!("Prendre en charge {} ?", a.nom),
        texte: t,
        bouton: "Prendre en charge".into(),
        suite: installer(&a.id, Some(dossier)),
    }
}

/// `Confirm-Desinstallation`
pub fn question_desinstallation(a: &Appli) -> Question {
    let texte = if !a.desinstalleur.is_empty() {
        format!(
            "Le désinstalleur de {} va s'ouvrir : il remet comme avant les réglages de Windows qu'il a modifiés, puis supprime ses fichiers. Il te demande aussi si tu gardes tes données : elles sont gardées si tu ne coches rien.",
            a.nom
        )
    } else {
        format!(
            "{} va être fermé et ses fichiers supprimés (une demande de Windows). Ses données (réglages, rendez-vous) sont gardées : une réinstallation les retrouve.",
            a.nom
        )
    };
    Question {
        titre: format!("Désinstaller {} ?", a.nom),
        texte,
        bouton: "Désinstaller".into(),
        suite: Suite::Signal { nom: mindset_noyau::signaux::DESINSTALLER.into(), donnees: json!({ "id": a.id }) },
    }
}
