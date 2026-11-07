//! Une appli de la suite, telle que Mindset s'en sert (l'objet rendu par `ConvertTo-Appli`, liste.ps1:33-103), son
//! installation (`Get-Installation`, installations.ps1:88), et les petites règles dont presque tous les blocs ont
//! besoin (applis.ps1:60-105) : a-t-elle besoin des droits, ses programmes qui tournent, est-elle ouverte.
//!
//! La liste elle-même (apps.json livré ou liste en ligne signée, chaque champ vérifié) est le travail du bloc
//! « liste », qui la donne au contexte au démarrage (`Contexte::definir_applis`).

use serde_json::{Value, json};

use crate::contexte::Contexte;
use crate::systeme::{Processus, dans_dossier};

/// Une appli de la liste, champ par champ comme `ConvertTo-Appli` (les noms de PowerShell entre parenthèses). Les
/// textes absents sont vides.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Appli {
    /// `Id` : « nevermind »
    pub id: String,
    /// `Type` : « powershell » ou « rust »
    pub genre: String,
    /// `Nom` : « Nevermind » (aussi le titre exact de sa fenêtre)
    pub nom: String,
    /// `Couleur` : « #00E5FF »
    pub couleur: String,
    /// `AppId` : « JordanJacquot.Nevermind » (son identité dans la barre des tâches)
    pub app_id: String,
    pub description: String,
    pub presentation: String,
    /// `Depot` : « JordanJacquot/Nevermind »
    pub depot: String,
    pub zip: String,
    pub dossier_zip: String,
    pub exe: String,
    pub script: String,
    pub mutex: String,
    pub ancien_zip: String,
    pub ancien_dossier_zip: String,
    pub ancien_script: String,
    pub ancien_mutex: String,
    /// `AfficherFichier` : le nom du fichier, dans son dossier de données
    pub afficher_fichier: String,
    pub afficher_signal: String,
    pub desinstalleur: String,
    /// `Donnees` : son ancien dossier de données, variables d'environnement remplacées
    pub donnees: String,
    pub admin: bool,
    pub rappels: bool,
    pub sans_droits_depuis: String,
    pub aide: String,
    pub aide_exe: String,
    pub cache_depuis: String,
    pub confidentialite: String,
    pub logo: String,
    /// `LogoEpaisseur` : déjà divisée par 100 (0.12 par défaut)
    pub logo_epaisseur: f64,
}

/// L'installation connue d'une appli (`@{ Dossier; Gere; Version }`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installation {
    pub dossier: String,
    /// Installée par Mindset dans le dossier protégé des programmes
    pub gere: bool,
    /// La version installée, `None` si elle n'a pas pu être lue (ou pendant une opération)
    pub version: Option<String>,
}

impl Installation {
    /// La forme du tableau commun (`installations`).
    pub fn en_json(&self) -> Value {
        json!({ "dossier": self.dossier, "gere": self.gere, "version": self.version })
    }

    /// Depuis le tableau commun ; `None` si la forme n'y est pas.
    pub fn depuis_json(v: &Value) -> Option<Installation> {
        Some(Installation {
            dossier: v.get("dossier")?.as_str()?.to_string(),
            gere: v.get("gere").and_then(Value::as_bool).unwrap_or(false),
            version: v.get("version").and_then(Value::as_str).map(str::to_string),
        })
    }
}

/// `Test-AppliAdmin` (applis.ps1:60-66) : l'appli a-t-elle besoin des droits administrateur ? Selon la version
/// installée : plus besoin depuis `sans_droits_depuis`.
pub fn appli_admin(appli: &Appli, inst: Option<&Installation>) -> bool {
    if !appli.admin {
        return false;
    }
    if appli.sans_droits_depuis.is_empty() {
        return true;
    }
    match inst.and_then(|i| i.version.as_deref()) {
        Some(v) => suite_commun::version::plus_recente(&appli.sans_droits_depuis, v),
        None => true,
    }
}

/// `Get-ProcessusAppli` (applis.ps1:73-81) : les programmes de l'appli qui tournent, trouvés par leur CHEMIN (jamais
/// par leur nom : l'hôte de chaque appli s'appelle Mindset.exe). `hote` : seulement son programme principal
/// (l'hôte Mindset.exe ou l'ancien <Appli>.exe, directement dans son dossier). Jamais Mindset lui-même.
pub fn processus_appli(ctx: &Contexte, appli: &Appli, hote: bool) -> Vec<Processus> {
    let Some(inst) = crate::partage::installation(ctx, &appli.id) else { return Vec::new() };
    let tous = ctx.systeme().processus();
    let noms = [appli.exe.as_str(), "Mindset.exe"];
    let noms = if hote { Some(&noms[..]) } else { None };
    let mien = ctx.dossiers.mindset.to_string_lossy();
    let pids = dans_dossier(&tous, &inst.dossier, noms, ctx.pid(), &mien);
    tous.into_iter().filter(|p| pids.contains(&p.pid)).collect()
}

/// `Test-AppliOuverte` (applis.ps1:94-105) : son verrou (ou l'ancien) existe, ou Windows refuse de l'ouvrir ; sinon,
/// son programme principal tourne depuis son dossier.
pub fn appli_ouverte(ctx: &Contexte, appli: &Appli) -> bool {
    let s = ctx.systeme();
    for nom in [&appli.mutex, &appli.ancien_mutex] {
        if !nom.is_empty() && s.verrou_existe(nom) {
            return true;
        }
    }
    !processus_appli(ctx, appli, true).is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nevermind() -> Appli {
        Appli {
            id: "nevermind".into(),
            nom: "Nevermind".into(),
            exe: "Nevermind.exe".into(),
            mutex: r"Local\Nevermind-Instance".into(),
            ancien_mutex: r"Local\OptiGame-Instance".into(),
            admin: true,
            sans_droits_depuis: "1.15.0".into(),
            ..Default::default()
        }
    }

    #[test]
    fn droits_selon_la_version() {
        let a = nevermind();
        let i = |v: Option<&str>| Installation { dossier: "x".into(), gere: true, version: v.map(str::to_string) };
        assert!(appli_admin(&a, None));
        assert!(appli_admin(&a, Some(&i(None))));
        assert!(appli_admin(&a, Some(&i(Some("1.14.2")))));
        assert!(!appli_admin(&a, Some(&i(Some("1.15.0")))));
        assert!(!appli_admin(&a, Some(&i(Some("2.0.1")))));
        assert!(!appli_admin(&Appli { admin: false, ..a.clone() }, None));
        assert!(appli_admin(&Appli { sans_droits_depuis: String::new(), ..a }, Some(&i(Some("9.0.0")))));
    }

    #[test]
    fn ouverte_par_son_verrou_ou_son_programme() {
        let (ctx, f) = crate::essai::contexte("appli-ouverte");
        ctx.definir_applis(vec![nevermind()]);
        let a = nevermind();
        assert!(!appli_ouverte(&ctx, &a));
        f.systeme.poser_verrou(r"Local\OptiGame-Instance", true);
        assert!(appli_ouverte(&ctx, &a), "l'ancien verrou compte");
        f.systeme.poser_verrou(r"Local\OptiGame-Instance", false);
        let dossier = ctx.dossiers.programmes.join("Nevermind");
        ctx.au_nom_de("installations", || {
            ctx.publier(
                crate::partage::INSTALLATIONS,
                json!({ "nevermind": { "dossier": dossier.to_string_lossy(), "gere": true, "version": "2.0.1" } }),
            )
        });
        f.systeme.ajouter_processus(77, &dossier.join("outils").join("PresentMon.exe").to_string_lossy(), 1);
        assert!(!appli_ouverte(&ctx, &a), "un programme d'aide n'est pas l'appli");
        f.systeme.ajouter_processus(78, &dossier.join("Mindset.exe").to_string_lossy(), 1);
        assert!(appli_ouverte(&ctx, &a));
        assert_eq!(processus_appli(&ctx, &a, false).len(), 2);
        let mindset = ctx.dossiers.mindset.join("Mindset.exe");
        f.systeme.retirer_processus(78);
        f.systeme.ajouter_processus(79, &mindset.to_string_lossy(), 1);
        assert!(!appli_ouverte(&ctx, &a), "Mindset lui-même n'est jamais l'appli");
    }
}
