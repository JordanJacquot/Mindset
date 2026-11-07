//! Désinstaller Mindset (mindset.ps1:93-154) : par son désinstalleur autonome (`Desinstaller Mindset.exe`, le
//! désinstalleur Rust, à côté de Mindset.exe), qui retire aussi les applis, propose de garder les données et affiche
//! ce qui n'a pas pu être retiré ; Mindset se ferme pour lui laisser la place. Sans lui (copie de travail, copie pas
//! installée, ou d'avant lui) : raccourcis, lancement avec Windows, puis le dossier par le mini-installateur.

use mindset_noyau::systeme::Lancer;
use mindset_noyau::{Contexte, Effet, Effets, partage, signaux};
use serde_json::{Value, json};
use std::path::PathBuf;

use crate::{Demande, LuiMeme, actions, installation};

/// Le désinstalleur autonome, à côté de Mindset.exe (`$DesinstalleurMindset`).
pub const DESINSTALLEUR: &str = "Desinstaller Mindset.exe";
/// Le temps laissé au mini-installateur pour refuser la suppression avant que Mindset ne se ferme.
pub const ATTENTE_SUPPRESSION_MS: u64 = 2000;

/// Le dossier de Windows (`$env:SystemRoot`), le dossier de travail du désinstalleur.
fn dossier_windows() -> PathBuf {
    std::env::var_os("SystemRoot").map_or_else(|| PathBuf::from(r"C:\Windows"), PathBuf::from)
}

impl LuiMeme {
    /// `Get-ApplisGerees` : les noms des applis installées par Mindset.
    pub fn applis_gerees(ctx: &Contexte) -> Vec<String> {
        ctx.applis()
            .iter()
            .filter(|a| partage::installation(ctx, &a.id).is_some_and(|i| i.gere))
            .map(|a| a.nom.clone())
            .collect()
    }

    fn desinstalleur(ctx: &Contexte) -> PathBuf {
        ctx.dossiers.mindset.join(DESINSTALLEUR)
    }

    /// `Confirm-DesinstallMindset`
    pub(crate) fn confirmer_desinstallation(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let g = Self::applis_gerees(ctx);
        if installation::installe(ctx) && Self::desinstalleur(ctx).is_file() {
            let applis = if g.is_empty() {
                String::new()
            } else {
                format!(" Les applis qu'il a installées ({}) seront retirées aussi.", g.join(", "))
            };
            effets.ajouter(signaux::confirmation(
                "Désinstaller Mindset ?",
                &format!(
                    "Mindset va se fermer et ouvrir son désinstalleur (accepte la demande de Windows).{applis} Tu pourras choisir de garder tes données."
                ),
                "Continuer",
                actions::DESINSTALLER_CONTINUER,
                Value::Null,
            ));
            return;
        }
        // Sans désinstalleur autonome : ce qui ne part pas est dit à l'utilisateur
        if !g.is_empty() {
            effets.ajouter(signaux::confirmation(
                "Désinstalle d'abord les applis",
                &format!(
                    "Mindset gère encore {} : désinstalle-les depuis l'accueil, puis reviens ici. Leurs données sont gardées.",
                    g.join(" et ")
                ),
                "Aller à l'accueil",
                actions::ALLER_ACCUEIL,
                Value::Null,
            ));
            return;
        }
        effets.ajouter(signaux::confirmation(
            "Désinstaller Mindset ?",
            &format!(
                "Mindset, son raccourci et son lancement au démarrage vont être retirés. Ses données (et celles des applis) restent dans {} : une réinstallation les retrouve.",
                ctx.dossiers.donnees_suite.display()
            ),
            "Désinstaller",
            actions::DESINSTALLER_OUI,
            Value::Null,
        ));
    }

    /// « Continuer » : le désinstalleur autonome est lancé, Mindset se ferme (avec ses applis).
    pub(crate) fn lancer_desinstalleur(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if ctx.essai && !self.en_essai.lancements {
            return;
        }
        let exe = Self::desinstalleur(ctx);
        let l = Lancer { exe: exe.clone(), arguments: Vec::new(), dossier: dossier_windows(), sans_droits: false };
        if let Err(e) = ctx.systeme().lancer(&l) {
            effets.ajouter(signaux::confirmation(
                "Le désinstalleur ne s'ouvre pas",
                &format!("Windows n'a pas pu lancer {} ({e}).", exe.display()),
                "Réessayer",
                actions::DESINSTALLER_REESSAYER,
                Value::Null,
            ));
            return;
        }
        ctx.journal("Désinstallation de Mindset : désinstalleur lancé");
        effets.ajouter(Effet::Quitter { avec_applis: true });
    }

    /// « Désinstaller » sans désinstalleur autonome.
    pub(crate) fn desinstaller_sans_desinstalleur(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let pc = self.pc();
        let mut restes: Vec<String> = Vec::new();
        for l in pc.raccourcis_mindset() {
            if pc.existe(&l) && pc.retirer_fichier(&l).is_err() {
                restes.push(format!("le raccourci {}", l.display()));
            }
        }
        if pc.run().is_some() && pc.retirer_run().is_err() {
            restes.push("le lancement avec Windows (registre)".into());
        }
        if !restes.is_empty() {
            let r = restes.join(", ");
            ctx.journal(&format!("Désinstallation de Mindset : il reste {r}"));
            effets.ajouter(signaux::confirmation(
                "Désinstallation pas finie",
                &format!(
                    "Ces éléments n'ont pas pu être retirés : {r}. Ferme les programmes qui pourraient les utiliser, puis réessaie."
                ),
                "Réessayer",
                actions::DESINSTALLER_REESSAYER,
                Value::Null,
            ));
            return;
        }
        if installation::installe(ctx) {
            // Le dossier est supprimé en administrateur une fois ce Mindset fermé ; si la demande ne part même pas,
            // Mindset reste ouvert et le dit
            self.desinstall_echec = None;
            let id = Self::nouvel_id();
            self.demandes.insert(id.clone(), Demande::Suppression);
            let p = json!({ "Destination": ctx.dossiers.mindset_installe().to_string_lossy(),
                "AttendrePid": ctx.pid().to_string() });
            effets.ajouter(signaux::admin_demande(&id, "supprimer", p, true, false));
            self.desinstall_fin = Some(Self::ms(ctx) + ATTENTE_SUPPRESSION_MS);
        } else {
            ctx.journal("Mindset désinstallé");
            effets.ajouter(Effet::Quitter { avec_applis: false });
        }
    }

    /// Les 2 secondes après la demande de suppression : Mindset se ferme, sauf si elle a été refusée.
    pub(crate) fn suivre_desinstallation(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let Some(t) = self.desinstall_fin else { return };
        if Self::ms(ctx) < t {
            return;
        }
        self.desinstall_fin = None;
        if let Some(e) = self.desinstall_echec.take() {
            effets.ajouter(signaux::confirmation(
                "Désinstallation impossible",
                &format!(
                    "Le dossier {} et les tâches planifiées de Mindset n'ont pas pu être retirés : {e}",
                    ctx.dossiers.mindset_installe().display()
                ),
                "Réessayer",
                actions::DESINSTALLER_REESSAYER,
                Value::Null,
            ));
            return;
        }
        ctx.journal("Mindset désinstallé");
        effets.ajouter(Effet::Quitter { avec_applis: false });
    }
}
