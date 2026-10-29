//! Le travail de l'installateur, action par action, comme installer-admin.ps1 (même ordre des contrôles, mêmes
//! messages). Chaque fonction cite celle de la version PowerShell qu'elle reprend.
//!
//! - `appli` : installe une appli de apps.json à partir de son zip signé (vérifié ici, sur le contenu lu en mémoire) ;
//!   son dossier, le dossier de son zip, son programme et sa partie administrateur viennent de apps.json (lu à côté de
//!   l'exe, dans le dossier protégé), jamais de la demande. La plus haute version installée de chaque appli est gardée
//!   dans HKLM\SOFTWARE\Mindset\Versions : une version plus ancienne est refusée, même après une suppression.
//!   Avec `-Liste` (Mindset 2.16) : la liste des applis en ligne gardée par Mindset, signée, remplace apps.json si
//!   elle passe toutes les règles (suite_commun::liste_en_ligne) ; sinon apps.json livré, comme avant.
//! - `mindset` : installe Mindset lui-même (Program Files\Mindset\Mindset, ou X:\Mindset\Programmes\Mindset).
//! - `mindset-maj` : met Mindset à jour, puis le relance sans droits.
//! - `taches` : les tâches planifiées de Mindset.
//! - `supprimer` : une appli, ou Mindset lui-même (chemin de secours, sans « Desinstaller Mindset.exe »).
//! - `demande` : par la tâche SYSTEM, la demande écrite par Mindset (une des quatre actions ci-dessus sauf
//!   `mindset`) ; tout y est revérifié, seuls les zips signés de son dossier telechargements s'installent, et
//!   l'utilisateur est toujours celui de la tâche. Sans `-Sid` : l'ancienne tâche (jusqu'à Mindset 2.9.0), qui ne
//!   sert plus qu'à se remplacer par la tâche SYSTEM.
//!
//! Seuls des dossiers directement dans Program Files\Mindset ou X:\Mindset\Programmes sont acceptés. Rien ne vient
//! de l'utilisateur : ni ses variables d'environnement (les dossiers sont demandés à Windows), ni ses « dossiers du
//! shell ».

use std::panic::{AssertUnwindSafe, catch_unwind};

use serde_json::Value;
use suite_commun::chemins::{self, apres_debut, chemin_complet, commence_par_disque, egal, feuille, joindre, parent};
use suite_commun::liste_en_ligne::{self, ListeAcceptee};
use suite_commun::paquet;
use suite_commun::protocole_installateur::{
    self as protocole, ACTIONS_PAR_TACHE, CHAMPS_TEXTE, CLE_INSTALLATION, CLE_MINDSET, CLE_VERSIONS, DOSSIER_TACHES,
    TACHE_ANCIENNE, TACHE_DEMARRAGE, TACHE_INSTALLATION, VALEUR_LISTE, VALEUR_RECU, VALEUR_RESTES, VALEUR_RESULTAT,
    champ, entier_ps, id_valable, lire_json, sid_valable, texte_ps, vrai_ps,
};
use suite_commun::signature::verifier_signature;
use suite_commun::version::{forme_valide, plus_recente};
use suite_commun::version_paquet::{version_dossier, version_zip};

use crate::NOM_EXE;
use crate::arguments::{self, Action, Parametres};
use crate::regles;
use crate::systeme::{CompteTache, Instances, NouvelleTache, Processus, Systeme, ValeurRegistre};

/// « Applications installées » de Windows : l'entrée de Mindset.
const CLE_DESINSTALL: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset";
/// Le désinstalleur autonome, à côté de Mindset.exe.
const NOM_DESINSTALLEUR: &str = "Desinstaller Mindset.exe";
/// Les comptes d'administration : Administrateurs, SYSTEM, TrustedInstaller.
const COMPTES_ADMIN: [&str; 3] =
    ["S-1-5-32-544", "S-1-5-18", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"];
/// Les droits d'écriture (écrire, ajouter, supprimer, changer les droits ou le propriétaire, et les droits
/// « génériques » tout et écriture), comme Test-DossierProtege.
const DROITS_ECRITURE: u32 = 0x2 | 0x4 | 0x10 | 0x100 | 0x10000 | 0x40 | 0x40000 | 0x80000 | 0x5000_0000;

/// Le message d'une erreur qui arrête l'action (le `throw` de la version PowerShell).
type Res<T> = Result<T, String>;

/// Une appli de apps.json, vérifiée.
struct Appli {
    id: String,
    nom: String,
    exe: String,
    dossiers_zip: Vec<String>,
    tache_aide: String,
    exe_aide: String,
}

/// La demande de Windows (sans `-Sid`), vue par l'ancienne tâche ou par la nouvelle : fin de la lecture.
enum Suite {
    Continuer,
    Arreter,
}

/// L'installateur, pour une exécution.
struct Installateur<'a> {
    sys: &'a mut dyn Systeme,
    p: Parametres,
    /// Lancé par la tâche (`-Action demande`)
    par_tache: bool,
    /// Le numéro de la demande (par la tâche) : la réponse va dans HKLM
    id_demande: String,
    /// Le dossier de l'exe (le dossier de Mindset d'où il tourne)
    dossier_exe: String,
    /// Par la tâche : le dossier de Mindset et le dossier des programmes, vérifiés
    dossier_mindset_tache: String,
    racine_tache: String,
    /// La liste des applis en ligne acceptée (`-Liste`), lue une seule fois ; `None` : apps.json livré
    applis_en_ligne: Option<Vec<Value>>,
}

/// Lance l'installateur avec ces arguments (la ligne de commande, sans le nom du programme). `Err` : paramètres
/// refusés dès le départ (rien n'est fait, aucune réponse), comme PowerShell qui ne lançait pas le script.
pub fn executer(args: &[String], sys: &mut dyn Systeme) -> Result<(), String> {
    let p = arguments::lire(args)?;
    let exe = sys.exe_courant();
    let dossier_exe = parent(&exe).to_string();
    let mut i = Installateur {
        sys,
        par_tache: p.action == Action::Demande,
        p,
        id_demande: String::new(),
        dossier_exe,
        dossier_mindset_tache: String::new(),
        racine_tache: String::new(),
        applis_en_ligne: None,
    };
    // Une erreur imprévue (une panique) donne une réponse, au lieu d'un silence
    let r = catch_unwind(AssertUnwindSafe(|| {
        if i.par_tache
            && let Suite::Arreter = i.lire_demande()
        {
            return;
        }
        i.travail();
    }));
    if r.is_err() {
        i.ecrire_resultat(false, "Erreur inattendue de l'installateur : rien d'autre n'a été fait.");
    }
    Ok(())
}

impl Installateur<'_> {
    // =========================================================================================================
    // Réponse
    // =========================================================================================================

    /// Write-Resultat : par la tâche, dans HKLM (jamais dans un dossier modifiable sans droits) ; sinon dans le
    /// fichier -Resultat.
    fn ecrire_resultat(&mut self, ok: bool, message: &str) {
        if !self.id_demande.is_empty() {
            if self.sys.registre_creer(CLE_INSTALLATION).is_ok() {
                let r = protocole::reponse(&self.id_demande, ok, message);
                let _ = self.sys.registre_ecrire(CLE_INSTALLATION, VALEUR_RESULTAT, &ValeurRegistre::Texte(r));
            }
            return;
        }
        if !self.p.resultat.is_empty() {
            let chemin = self.sys.reel(&self.p.resultat);
            let _ = std::fs::write(chemin, protocole::reponse_fichier(ok, message));
        }
    }

    // =========================================================================================================
    // Fichiers (au travers de Systeme::reel)
    // =========================================================================================================

    fn existe(&self, chemin: &str) -> bool {
        !chemin.is_empty() && self.sys.reel(chemin).exists()
    }
    fn est_fichier(&self, chemin: &str) -> bool {
        !chemin.is_empty() && self.sys.reel(chemin).is_file()
    }
    fn est_dossier(&self, chemin: &str) -> bool {
        !chemin.is_empty() && self.sys.reel(chemin).is_dir()
    }
    fn lire_octets(&self, chemin: &str) -> Res<Vec<u8>> {
        if chemin.is_empty() {
            return Err("Fichier introuvable : aucun chemin donné.".into());
        }
        std::fs::read(self.sys.reel(chemin)).map_err(|e| format!("Fichier illisible ({chemin}) : {e}"))
    }
    /// Un fichier texte en UTF-8 (marque du début retirée), comme `[IO.File]::ReadAllText($f, UTF8)`.
    fn lire_texte(&self, chemin: &str) -> Res<String> {
        let o = self.lire_octets(chemin)?;
        Ok(texte_utf(&o))
    }
    fn creer_dossier(&self, chemin: &str) -> Res<()> {
        std::fs::create_dir_all(self.sys.reel(chemin)).map_err(|e| format!("{chemin} : {e}"))
    }
    fn renommer(&self, de: &str, vers: &str) -> Res<()> {
        std::fs::rename(self.sys.reel(de), self.sys.reel(vers)).map_err(|e| format!("{de} : {e}"))
    }
    fn supprimer_tout(&self, chemin: &str) -> Res<()> {
        let r = self.sys.reel(chemin);
        let res = if r.is_dir() { std::fs::remove_dir_all(&r) } else { std::fs::remove_file(&r) };
        res.map_err(|e| format!("{chemin} : {e}"))
    }
    fn copier_fichier(&self, de: &str, vers_dossier: &str) -> Res<()> {
        let cible = joindre(vers_dossier, feuille(de));
        std::fs::copy(self.sys.reel(de), self.sys.reel(&cible)).map(|_| ()).map_err(|e| format!("{de} : {e}"))
    }
    /// Copy-Item -Recurse d'un dossier dans un autre (le dossier copié garde son nom).
    fn copier_dossier(&self, de: &str, vers_dossier: &str) -> Res<()> {
        fn copier(de: &std::path::Path, vers: &std::path::Path) -> std::io::Result<()> {
            std::fs::create_dir_all(vers)?;
            for e in std::fs::read_dir(de)? {
                let e = e?;
                let cible = vers.join(e.file_name());
                if e.file_type()?.is_dir() {
                    copier(&e.path(), &cible)?;
                } else {
                    std::fs::copy(e.path(), &cible)?;
                }
            }
            Ok(())
        }
        copier(&self.sys.reel(de), &self.sys.reel(&joindre(vers_dossier, feuille(de))))
            .map_err(|e| format!("{de} : {e}"))
    }

    /// Test-SansLien : un chemin sans lien (point de jonction, lien symbolique) sur lui ni sur un de ses dossiers
    /// parents. `Err` : le chemin lui-même est refusé par Windows (GetFullPath).
    fn sans_lien(&self, chemin: &str) -> Res<bool> {
        let mut x = chemin_complet(chemin)?;
        while x.chars().count() > 3 {
            match std::fs::symlink_metadata(self.sys.reel(&x)) {
                Ok(m) if !lien(&m) => {}
                _ => return Ok(false),
            }
            match nom_dossier(&x) {
                Some(p) => x = p,
                None => break,
            }
        }
        Ok(true)
    }

    // =========================================================================================================
    // Dossiers et comptes
    // =========================================================================================================

    fn programmes_mindset(&self) -> Res<String> {
        programmes_mindset(&*self.sys)
    }

    /// Get-ProfilUtilisateur : le dossier de l'utilisateur, lu dans HKLM (ProfileList), jamais dans ses variables
    /// ni dans ses « dossiers du shell » (HKCU), qu'il peut rediriger.
    fn profil_utilisateur(&self, sid: &str) -> Res<String> {
        if !sid_valable(sid) {
            return Err("Utilisateur inconnu.".into());
        }
        let windows = self.sys.dossier_windows();
        let disque: String = windows.chars().take(2).collect();
        let p = self.sys.profil_brut(sid).unwrap_or_default();
        let p = remplacer_sans_casse(&p, "%SystemDrive%", &disque);
        let p = remplacer_sans_casse(&p, "%SystemRoot%", &windows);
        let p = remplacer_sans_casse(&p, "%windir%", &windows);
        if !regles::dossier_profil(&p) {
            return Err("Le dossier de cet utilisateur est introuvable.".into());
        }
        Ok(p.trim_end_matches('\\').to_string())
    }

    /// Get-DonneesMindset : le dossier des données de Mindset de l'utilisateur.
    fn donnees_mindset(&self, dossier_mindset: &str, sid: &str) -> Res<String> {
        chemins::donnees_mindset(dossier_mindset, || self.profil_utilisateur(sid))
    }

    /// ConvertTo-Sid : un compte (nom ou SID, comme les tâches planifiées le donnent) en SID ; vide si inconnu.
    fn vers_sid(&self, compte: &str) -> String {
        if compte.is_empty() {
            return String::new();
        }
        if regles::forme_sid(compte) {
            return compte.to_string();
        }
        self.sys.sid_de_compte(compte).unwrap_or_default()
    }

    fn disque_fixe(&self, lettre: &str) -> Res<()> {
        disque_fixe(&*self.sys, lettre)
    }

    fn dossier_mindset(&self, dossier: &str) -> Res<String> {
        dossier_mindset(&*self.sys, dossier)
    }

    /// Test-DossierProtege : un dossier que seuls les administrateurs peuvent changer.
    fn dossier_protege(&self, dossier: &str) -> bool {
        let Some(droits) = self.sys.droits(dossier) else { return false };
        let Some(proprietaire) = droits.proprietaire.as_deref() else { return false };
        if !COMPTES_ADMIN.iter().any(|c| egal(c, proprietaire)) {
            return false;
        }
        droits.regles.iter().all(|r| {
            !r.autorise
                || r.herite_seulement
                || COMPTES_ADMIN.iter().any(|c| egal(c, &r.sid))
                || r.masque & DROITS_ECRITURE == 0
        })
    }

    /// Set-ProprietaireAdmins : le dossier appartient aux Administrateurs (s'il n'appartient pas déjà à un compte
    /// d'administration). Les erreurs sont ignorées.
    fn proprietaire_admins(&mut self, dossier: &str) {
        let Some(d) = self.sys.droits(dossier) else { return };
        if d.proprietaire.as_deref().is_some_and(|p| COMPTES_ADMIN.iter().any(|c| egal(c, p))) {
            return;
        }
        let _ = self.sys.poser_proprietaire_admins(dossier);
    }

    /// Initialize-RacineTache : par la tâche, le dossier de Mindset est celui d'où la tâche lance l'exe, et le
    /// dossier des programmes celui qui le contient. Il doit être protégé, sans lien sur son chemin.
    fn initialiser_racine_tache(&mut self) -> Res<()> {
        let mindset = chemin_complet(&self.dossier_exe)?.trim_end_matches('\\').to_string();
        let racine = parent(&mindset).to_string();
        let pf = self.programmes_mindset()?.trim_end_matches('\\').to_string();
        let sur_disque = racine.as_bytes().first().is_some_and(u8::is_ascii_alphabetic)
            && apres_debut(&racine[1..], r":\Mindset\Programmes").is_some_and(str::is_empty);
        let ok = egal(feuille(&mindset), chemins::DOSSIER_MINDSET) && (egal(&racine, &pf) || sur_disque);
        if ok && !egal(&racine, &pf) {
            self.disque_fixe(&racine[..1])?;
        }
        if !ok || !self.sans_lien(&mindset).unwrap_or(false) || !self.dossier_protege(&racine) {
            return Err(format!("Mindset n'est pas installé dans un dossier protégé ({racine}) : rien n'a été fait."));
        }
        self.dossier_mindset_tache = mindset;
        self.racine_tache = racine;
        Ok(())
    }

    /// Get-DossierTache : par la tâche, un dossier directement dans le dossier des programmes de la tâche (Mindset
    /// compris), sans lien.
    fn dossier_tache(&self, dossier: &str) -> Res<String> {
        let d = if commence_par_disque(dossier) {
            chemin_complet(dossier.trim_end_matches('\\')).unwrap_or_default()
        } else {
            String::new()
        };
        if d.is_empty()
            || !egal(parent(&d), &self.racine_tache)
            || (self.est_dossier(&d) && !self.sans_lien(&d).unwrap_or(false))
        {
            return Err(format!("Dossier refusé : {dossier}"));
        }
        Ok(d)
    }

    /// Par la tâche : le dossier de la tâche ; sinon (la demande de Windows) : Test-DossierMindset.
    fn dossier_demande(&self, dossier: &str) -> Res<String> {
        if self.par_tache { self.dossier_tache(dossier) } else { self.dossier_mindset(dossier) }
    }

    /// Assert-Telechargement : par la tâche, le zip et sa signature ne sont lus que dans le dossier telechargements
    /// de l'utilisateur (à côté de la demande), jamais ailleurs sur le PC.
    fn telechargement(&self, fichier: &str) -> Res<()> {
        if !self.par_tache {
            return Ok(());
        }
        let dossier = joindre(parent(&self.p.demande), chemins::TELECHARGEMENTS);
        let f = if commence_par_disque(fichier) { chemin_complet(fichier).unwrap_or_default() } else { String::new() };
        let ok =
            !f.is_empty() && nom_dossier(&f).is_some_and(|d| egal(&d, &dossier)) && self.sans_lien(&f).unwrap_or(false);
        if !ok {
            return Err(format!("Fichier refusé (il doit être dans {dossier}) : {fichier}"));
        }
        Ok(())
    }

    // =========================================================================================================
    // apps.json et versions
    // =========================================================================================================

    /// Les applis connues : la liste en ligne acceptée (elle REMPLACE apps.json : c'est la liste complète), sinon
    /// apps.json livré.
    fn apps_json(&self) -> Vec<Value> {
        if let Some(l) = &self.applis_en_ligne {
            return l.clone();
        }
        let f = joindre(&joindre(&self.dossier_exe, "fichiers"), "apps.json");
        match self.lire_texte(&f).ok().and_then(|t| lire_json(&t)) {
            Some(Value::Array(l)) => l,
            Some(Value::Null) | None => Vec::new(),
            Some(autre) => vec![autre],
        }
    }

    /// Get-AppliConnue : une appli de apps.json, vérifiée comme Mindset le fait.
    fn appli_connue(&self, id: &str) -> Res<Appli> {
        if !regles::id_appli(id) {
            return Err("Appli inconnue.".into());
        }
        for a in self.apps_json() {
            let Value::Object(o) = &a else {
                if texte_ps(&a) == id {
                    break;
                }
                continue;
            };
            let t = |n: &str| champ(o, n).map(texte_ps).unwrap_or_default();
            let v = |n: &str| champ(o, n).is_some_and(vrai_ps);
            if t("id") != id {
                continue;
            }
            let (nom, exe) = (t("nom"), t("exe"));
            let mut ok = regles::nom_appli(&nom) && regles::programme(&exe) && regles::nom_fichier(&t("dossier_zip"));
            if v("ancien_dossier_zip") {
                ok = ok && regles::nom_fichier(&t("ancien_dossier_zip"));
            }
            let aide = v("aide");
            if aide {
                ok = ok && regles::tache_aide(&t("aide")) && regles::programme(&t("aide_exe"));
            }
            if !ok {
                break;
            }
            return Ok(Appli {
                id: id.to_string(),
                nom,
                exe,
                dossiers_zip: [t("dossier_zip"), t("ancien_dossier_zip")]
                    .into_iter()
                    .filter(|d| !d.is_empty())
                    .collect(),
                tache_aide: if aide { t("aide") } else { String::new() },
                exe_aide: if aide { t("aide_exe") } else { String::new() },
            });
        }
        Err("Appli inconnue.".into())
    }

    /// La liste des applis en ligne donnée par Mindset (`-Liste`, Mindset 2.16) : lue une seule fois en mémoire avec
    /// sa signature, jugée par les règles de [`liste_en_ligne`] avec les clés, le numéro livré (`apps-liste.txt`) et
    /// la version du Mindset d'où tourne l'exe. Acceptée : elle remplace apps.json ; refusée : apps.json livré seul
    /// (une appli inconnue est alors refusée, comme avant). La liste qui a servi est notée (HKLM, `Liste`).
    fn choisir_liste(&mut self) {
        if self.p.liste.is_empty() {
            return;
        }
        let note = match self.lire_liste_en_ligne() {
            Ok(l) => {
                self.applis_en_ligne = Some(l.applis);
                format!("en ligne {}", l.numero)
            }
            Err(e) => format!("livrée (liste en ligne refusée : {e})"),
        };
        if self.sys.registre_creer(CLE_INSTALLATION).is_ok() {
            let _ = self.sys.registre_ecrire(CLE_INSTALLATION, VALEUR_LISTE, &ValeurRegistre::Texte(note));
        }
    }

    fn lire_liste_en_ligne(&self) -> Res<ListeAcceptee> {
        let f = self.p.liste.clone();
        // Par la tâche : seulement la liste gardée par Mindset, à côté de la demande, sans lien (comme les zips, jamais
        // un autre fichier du PC)
        if self.par_tache {
            let attendu = joindre(parent(&self.p.demande), liste_en_ligne::FICHIER);
            let c = if commence_par_disque(&f) { chemin_complet(&f).unwrap_or_default() } else { String::new() };
            let sig = format!("{c}.sig");
            let ok = !c.is_empty()
                && chemin_complet(&attendu).is_ok_and(|a| egal(&a, &c))
                && self.sans_lien(&c).unwrap_or(false)
                && (!self.existe(&sig) || self.sans_lien(&sig).unwrap_or(false));
            if !ok {
                return Err(format!("fichier refusé, il doit être {attendu}"));
            }
        }
        liste_en_ligne::lire_et_accepter(&self.sys.reel(&f), &self.sys.reel(&self.dossier_exe))
            .map_err(|e| e.to_string())
    }

    fn version_gardee(&self, id: &str) -> String {
        self.sys.registre_lire(CLE_VERSIONS, id).unwrap_or_default()
    }

    /// Save-VersionGardee : la plus haute version installée d'une appli (jamais en arrière).
    fn garder_version(&mut self, id: &str, version: &str) -> Res<()> {
        if !forme_valide(version) {
            return Ok(());
        }
        let avant = self.version_gardee(id);
        if !avant.is_empty() && !plus_recente(version, &avant) {
            return Ok(());
        }
        if !self.sys.registre_existe(CLE_VERSIONS) {
            self.sys.registre_creer(CLE_VERSIONS)?;
        }
        self.sys.registre_ecrire(CLE_VERSIONS, id, &ValeurRegistre::Texte(version.to_string()))
    }

    /// Save-VersionsInstallees : par la tâche, à chaque demande, les versions des applis déjà installées.
    fn garder_versions_installees(&mut self) {
        for a in self.apps_json() {
            let id = match &a {
                Value::Object(o) => champ(o, "id").map(texte_ps).unwrap_or_default(),
                _ => String::new(),
            };
            let Ok(x) = self.appli_connue(&id) else { continue };
            let d = joindre(&self.racine_tache, &x.nom);
            if self.est_dossier(&d) && self.sans_lien(&d).unwrap_or(false) {
                let v = version_dossier(&self.sys.reel(&d));
                let _ = self.garder_version(&x.id, &v);
            }
        }
    }

    // =========================================================================================================
    // Tâches planifiées
    // =========================================================================================================

    fn sddl_tache(sid: &str) -> String {
        format!("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;{sid})")
    }

    /// Register-TachesMindset : les tâches de Mindset pour l'utilisateur `sid` seulement.
    ///   \Mindset\Mindset (démarrage)     à l'ouverture de session, Mindset.exe -Demarrage, SANS droits ;
    ///   \Mindset\Mindset (installation)  à la demande de Mindset, MindsetInstallateur.exe -Action demande -Sid
    ///                                    <utilisateur>, en SYSTEM : seul cet utilisateur (et les administrateurs)
    ///                                    peut la lancer et la lire.
    fn enregistrer_taches_mindset(&mut self, dossier: &str, sid: &str) -> Res<()> {
        if !sid_valable(sid) {
            return Err("Utilisateur inconnu.".into());
        }
        let exe = joindre(dossier, "Mindset.exe");
        if !self.existe(&exe) {
            return Err(format!("Mindset.exe introuvable dans {dossier}"));
        }
        let utilisateur =
            self.sys.compte_de_sid(sid).ok_or("Ce compte d'utilisateur est introuvable sur ce PC.".to_string())?;
        self.sys.retirer_tache(DOSSIER_TACHES, TACHE_ANCIENNE);
        // Le mini-installateur, en SYSTEM : une demande à la fois (les suivantes attendent leur tour)
        let installateur = joindre(dossier, NOM_EXE);
        let fichier = joindre(&self.donnees_mindset(dossier, sid)?, protocole::FICHIER_DEMANDE);
        self.sys.enregistrer_tache(&NouvelleTache {
            nom: TACHE_INSTALLATION.into(),
            execute: format!("\"{installateur}\""),
            arguments: format!("-Action demande -Sid {sid} -Demande \"{fichier}\""),
            dossier_travail: self.sys.dossier_systeme(),
            compte: CompteTache::Systeme,
            ouverture_session: None,
            duree_max_minutes: Some(30),
            instances: Instances::File,
            description:
                "Installe et met à jour Mindset et ses applis (zips signés seulement), à la demande de Mindset.".into(),
        })?;
        self.sys.droits_tache(TACHE_INSTALLATION, &Self::sddl_tache(sid))?;
        self.sys.enregistrer_tache(&NouvelleTache {
            nom: TACHE_DEMARRAGE.into(),
            execute: format!("\"{exe}\""),
            arguments: "-Demarrage".into(),
            dossier_travail: dossier.to_string(),
            compte: CompteTache::Utilisateur(sid.to_string()),
            ouverture_session: Some(utilisateur),
            duree_max_minutes: None,
            instances: Instances::Parallele,
            description: "Lance Mindset à l'ouverture de session, caché près de l'horloge.".into(),
        })?;
        // Les parties administrateur des applis de cet utilisateur encore sous son compte : refaites en SYSTEM
        self.refaire_taches_aide(sid);
        Ok(())
    }

    /// Unregister-TachesMindset : les tâches de Mindset, toutes celles du dossier, puis le dossier.
    fn retirer_taches_mindset(&mut self) {
        for t in [TACHE_ANCIENNE, TACHE_DEMARRAGE, TACHE_INSTALLATION] {
            self.sys.retirer_tache(DOSSIER_TACHES, t);
        }
        for t in self.sys.taches(Some(DOSSIER_TACHES)) {
            self.sys.retirer_tache(DOSSIER_TACHES, &t.nom);
        }
        self.sys.retirer_dossier_taches("Mindset");
    }

    /// Register-TacheAide : la partie administrateur d'une appli, à la demande, en SYSTEM, pour l'utilisateur `sid`
    /// seulement (inscrit dans ses arguments).
    fn enregistrer_tache_aide(&mut self, nom: &str, exe_aide: &str, sid: &str) -> Res<()> {
        if !regles::tache_aide(nom) {
            return Err("Nom de tâche refusé.".into());
        }
        if !sid_valable(sid) {
            return Err("Utilisateur inconnu.".into());
        }
        if !self.existe(exe_aide) {
            return Err(format!("Programme introuvable : {exe_aide}"));
        }
        self.sys.enregistrer_tache(&NouvelleTache {
            nom: nom.to_string(),
            execute: format!("\"{exe_aide}\""),
            arguments: format!("-Sid {sid}"),
            dossier_travail: parent(exe_aide).to_string(),
            compte: CompteTache::Systeme,
            ouverture_session: None,
            duree_max_minutes: None,
            instances: Instances::IgnorerNouvelle,
            description: "Partie administrateur de l'appli : ne fait que les actions de sa liste stricte, à la demande de l'appli."
                .into(),
        })?;
        self.sys.droits_tache(nom, &Self::sddl_tache(sid))
    }

    /// Update-TachesAide : les tâches d'aide de l'utilisateur encore sous son compte (Mindset 2.10.0 ou avant),
    /// refaites en SYSTEM pour lui, vers le même programme s'il est bien dans le dossier protégé d'une appli.
    fn refaire_taches_aide(&mut self, sid: &str) {
        for t in self.sys.taches(Some(DOSSIER_TACHES)) {
            if !regles::tache_aide(&t.nom) {
                continue;
            }
            if !egal(&self.vers_sid(t.compte.as_deref().unwrap_or("")), sid) {
                continue;
            }
            if t.actions.len() != 1 {
                continue;
            }
            let exe = t.actions[0].execute.as_deref().unwrap_or("").trim_matches('"').to_string();
            if !commence_par_disque(&exe) || !regles::programme(nom_fichier_dotnet(&exe)) {
                continue;
            }
            if self.dossier_demande(parent(&exe)).is_err() {
                continue;
            }
            let _ = self.enregistrer_tache_aide(&t.nom, &exe, sid);
        }
    }

    // =========================================================================================================
    // Programmes
    // =========================================================================================================

    /// Stop-Programme : ferme les programmes lancés depuis `dossier` (sous-dossiers compris), et seulement eux,
    /// trouvés par leur CHEMIN (jamais par leur nom), et seulement ceux de l'utilisateur de Mindset.
    fn arreter_programmes(&mut self, nom: &str, dossier: &str) -> Res<()> {
        if !regles::programme(nom) {
            return Err("Nom de programme refusé.".into());
        }
        if dossier.is_empty() {
            return Err("Dossier refusé.".into());
        }
        let dans = format!(r"{}\", chemin_complet(dossier)?.trim_end_matches('\\'));
        let moi = self.sys.pid();
        let session = self.sys.session();
        let sid = self.p.sid.clone();
        let liste: Vec<Processus> = self
            .sys
            .processus()
            .into_iter()
            .filter(|p| {
                p.id != moi && p.chemin.as_deref().is_some_and(|c| !c.is_empty() && apres_debut(c, &dans).is_some())
            })
            .filter(|p| {
                if sid.is_empty() {
                    p.session == session
                } else {
                    self.sys.proprietaire_processus(p.id).is_some_and(|s| egal(&s, &sid))
                }
            })
            .collect();
        if liste.is_empty() {
            return Ok(());
        }
        for p in &liste {
            self.sys.arreter(p);
        }
        self.sys.pause(800);
        Ok(())
    }

    /// Get-CommandeDesinstallation : le désinstalleur autonome s'il est là, sinon Mindset.exe -Desinstaller.
    fn commande_desinstallation(&self, dossier: &str) -> String {
        let d = joindre(dossier, NOM_DESINSTALLEUR);
        if self.existe(&d) {
            format!("\"{d}\"")
        } else {
            format!("\"{}\" -Desinstaller", joindre(dossier, "Mindset.exe"))
        }
    }

    // =========================================================================================================
    // La demande passée par la tâche
    // =========================================================================================================

    /// Lit la demande (par la tâche). Tout ce qu'elle contient est revérifié ensuite ; l'utilisateur est toujours
    /// celui de la tâche. Rien n'est effacé ni écrit dans le dossier de l'utilisateur. Une demande déjà reçue (même
    /// numéro) n'est pas refaite.
    fn lire_demande(&mut self) -> Suite {
        let j = self.lire_fichier_demande();
        let j = match j {
            Err(Suite::Arreter) => return Suite::Arreter,
            Err(Suite::Continuer) => None,
            Ok(j) => j,
        };
        // (le texte de l'erreur n'est pas recopié : il pourrait citer le contenu d'un fichier qui n'est pas une
        // demande)
        let Some(j) = j.filter(vrai_ps) else {
            self.ecrire_resultat(false, "Demande illisible.");
            return Suite::Arreter;
        };
        let objet = j.as_object();
        let lire = |n: &str| objet.and_then(|o| champ(o, n));
        let id = lire("Id").map(texte_ps).unwrap_or_default();
        if !id_valable(&id) {
            return Suite::Arreter;
        }
        if self.sys.registre_lire(CLE_INSTALLATION, VALEUR_RECU).is_some_and(|r| egal(&r, &id)) {
            return Suite::Arreter;
        }
        self.id_demande = id.clone();
        // Accusé de réception : Mindset sait que la tâche a pris sa demande (sinon, il passe par la demande de
        // Windows)
        if self.sys.registre_creer(CLE_INSTALLATION).is_ok() {
            let _ = self.sys.registre_ecrire(CLE_INSTALLATION, VALEUR_RECU, &ValeurRegistre::Texte(id));
        }
        let action = lire("Action").map(texte_ps).unwrap_or_default();
        let action = ACTIONS_PAR_TACHE.iter().find(|a| egal(a, &action)).and_then(|a| Action::lire(a));
        let Some(action) = action else {
            self.ecrire_resultat(false, "Demande refusée.");
            return Suite::Arreter;
        };
        self.p.action = action;
        for n in CHAMPS_TEXTE {
            if let Some(Value::String(v)) = lire(n) {
                self.p.poser_texte(n, v);
            }
        }
        if let Some(v) = lire("AttendrePid").filter(|v| vrai_ps(v)) {
            match entier_ps(v) {
                Some(n) => self.p.attendre_pid = n,
                None => {
                    self.ecrire_resultat(false, "Demande illisible.");
                    return Suite::Arreter;
                }
            }
        }
        if lire("Cache").map(texte_ps).as_deref() == Some("1") {
            self.p.cache = true;
        }
        if self.p.sid.is_empty() {
            // L'ancienne tâche (sous le compte de l'utilisateur, avec les droits les plus élevés) : elle ne fait plus
            // qu'une chose, se remplacer par la tâche SYSTEM. L'utilisateur est celui pour qui elle a été créée.
            if self.p.action != Action::Taches {
                self.ecrire_resultat(false, "Ancienne tâche d'installation : elle doit d'abord être remplacée.");
                return Suite::Arreter;
            }
            let compte = self.sys.tache(DOSSIER_TACHES, TACHE_INSTALLATION).and_then(|t| t.compte).unwrap_or_default();
            let sid = self.vers_sid(&compte);
            if !sid_valable(&sid) || !egal(&sid, &self.sys.sid_courant()) {
                self.ecrire_resultat(false, "Utilisateur inconnu.");
                return Suite::Arreter;
            }
            self.p.sid = sid;
        } else if !sid_valable(&self.p.sid) {
            self.ecrire_resultat(false, "Utilisateur inconnu.");
            return Suite::Arreter;
        }
        Suite::Continuer
    }

    /// Le fichier de la demande : absent, trop gros ou derrière un lien, il est ignoré sans un mot (`Arreter`) ;
    /// `Ok(None)` : illisible.
    fn lire_fichier_demande(&self) -> Result<Option<Value>, Suite> {
        let f = self.p.demande.clone();
        if f.is_empty() {
            return Err(Suite::Arreter);
        }
        // (un chemin que Windows refuse : la demande est illisible)
        match self.sans_lien(&f) {
            Ok(true) => {}
            Ok(false) => return Err(Suite::Arreter),
            Err(_) => return Ok(None),
        }
        match std::fs::metadata(self.sys.reel(&f)) {
            Ok(m) if m.is_file() && m.len() <= protocole::TAILLE_MAX_DEMANDE => {}
            _ => return Err(Suite::Arreter),
        }
        Ok(self.lire_texte(&f).ok().and_then(|t| lire_json(&t)))
    }

    // =========================================================================================================
    // Le travail
    // =========================================================================================================

    fn travail(&mut self) {
        if let Err(e) = self.travail_ou_erreur() {
            self.ecrire_resultat(false, &e);
        }
    }

    fn travail_ou_erreur(&mut self) -> Res<()> {
        if self.par_tache {
            // (mise à jour de Mindset : il s'est déjà fermé, il est relancé même si rien n'est fait)
            if let Err(e) = self.initialiser_racine_tache() {
                if self.p.action == Action::MindsetMaj {
                    self.sys.lancer_tache(&format!("{DOSSIER_TACHES}{TACHE_DEMARRAGE}"));
                }
                return Err(e);
            }
        }
        // (avant tout le reste : les versions gardées ci-dessous suivent la même liste)
        self.choisir_liste();
        if self.par_tache {
            // À chaque demande : les versions déjà installées sont gardées, et les parties administrateur des applis
            // de cet utilisateur encore sous son compte sont refaites en SYSTEM
            self.garder_versions_installees();
            let sid = self.p.sid.clone();
            self.refaire_taches_aide(&sid);
        }
        match self.p.action {
            Action::Appli => self.appli(),
            Action::Mindset => self.mindset(),
            Action::MindsetMaj => {
                self.mindset_maj();
                Ok(())
            }
            Action::Taches => self.taches(),
            Action::Supprimer => self.supprimer(),
            Action::Demande => Ok(()),
        }
    }

    /// Action appli.
    fn appli(&mut self) -> Res<()> {
        let app = self.appli_connue(&self.p.appli.clone())?;
        let destination = self.p.destination.clone();
        let dest = self.dossier_demande(&destination)?;
        if !egal(feuille(&dest), &app.nom) {
            return Err(format!("Dossier refusé : {destination}"));
        }
        if self.p.dossier_zip.contains(['\\', '/', ':', '*', '?', '"', '<', '>', '|']) {
            return Err("Nom de dossier refusé.".into());
        }
        if self.p.dossier_zip.is_empty() {
            self.p.dossier_zip = app.dossiers_zip.first().cloned().unwrap_or_default();
        }
        if !app.dossiers_zip.iter().any(|d| egal(d, &self.p.dossier_zip)) {
            return Err("Nom de dossier refusé.".into());
        }
        // Tout est vérifié AVANT d'arrêter quoi que ce soit : noms, tâche d'aide, ancienne copie, puis la signature
        for n in [&self.p.exe, &self.p.exe_aide] {
            if !n.is_empty() && !regles::programme(n) {
                return Err("Nom de programme refusé.".into());
            }
        }
        if !self.p.tache_aide.is_empty() && !regles::tache_aide(&self.p.tache_aide) {
            return Err("Nom de tâche refusé.".into());
        }
        if !self.p.exe.is_empty() && !egal(&self.p.exe, &app.exe) {
            return Err("Nom de programme refusé.".into());
        }
        // (sa partie administrateur : créée si la demande la prévoit, et seulement celle de apps.json)
        if (!self.p.tache_aide.is_empty() || !self.p.exe_aide.is_empty())
            && (self.p.tache_aide != app.tache_aide || !egal(&self.p.exe_aide, &app.exe_aide))
        {
            return Err("Partie administrateur refusée : ce n'est pas celle de apps.json.".into());
        }
        let exe = app.exe.clone();
        self.telechargement(&self.p.zip)?;
        self.telechargement(&self.p.signature)?;
        let octets = self.lire_octets(&self.p.zip)?;
        let sig = self.lire_octets(&self.p.signature)?;
        // Prise en charge : l'ancienne copie est le programme <Exe> d'un dossier, donné par son chemin complet
        let ancien = self.p.ancien_exe.clone();
        if !ancien.is_empty() {
            let ok = regles::chemin_ancienne_copie(&ancien)
                && chemin_complet(&ancien).is_ok_and(|c| egal(&c, &ancien))
                && egal(nom_fichier_dotnet(&ancien), &exe)
                && self.est_fichier(&ancien);
            if !ok {
                return Err("Ancienne copie refusée.".into());
            }
        }
        let cles = joindre(&joindre(&self.dossier_exe, "fichiers"), "cles-publiques");
        let cles_reel = self.sys.reel(&cles);
        if !verifier_signature(&octets, &sig, &cles_reel) {
            return Err("La signature du fichier téléchargé est invalide : rien n'a été installé.".into());
        }
        // Jamais en dessous de la plus haute version déjà installée sur ce PC (même supprimée depuis) : refusé avant
        // d'arrêter quoi que ce soit
        let gardee = self.version_gardee(&app.id);
        let dans_zip = version_zip(&octets, &self.p.dossier_zip);
        if !gardee.is_empty() && !dans_zip.is_empty() && plus_recente(&gardee, &dans_zip) {
            return Err(format!(
                "Version {dans_zip} refusée : la version {gardee}, plus récente, a déjà été installée sur ce PC."
            ));
        }
        // Mindset a demandé confirmation avant de fermer l'appli : tout ce qui tourne depuis son dossier, rien
        // d'autre
        self.arreter_programmes(&exe, &dest)?;
        let minimale = self.version_gardee(&app.id);
        let version_mindset = version_dossier(&self.sys.reel(&self.dossier_exe));
        let dest_reel = self.sys.reel(&dest);
        let dossier_zip = self.p.dossier_zip.clone();
        paquet::installer(&paquet::Demande {
            zip: &octets,
            signature: &sig,
            cles: &cles_reel,
            destination: &dest_reel,
            dossier_zip: &dossier_zip,
            exe: &exe,
            version_minimale: Some(minimale.as_str()).filter(|m| !m.is_empty()),
            appli: Some(&app.id),
            version_mindset: Some(version_mindset.as_str()).filter(|v| !v.is_empty()),
        })
        .map_err(|e| e.to_string())?;
        let installe = dest;
        let v = version_dossier(&self.sys.reel(&installe));
        let _ = self.garder_version(&app.id, &v);
        // Prise en charge : les tâches planifiées de l'utilisateur qui lançaient l'ancienne copie lancent désormais
        // la nouvelle. Seulement les siennes (jamais celles du système, d'un autre compte, de Windows dans
        // \Microsoft\ ni de Mindset dans \Mindset\), et toutes leurs actions sont gardées.
        if !ancien.is_empty() && sid_valable(&self.p.sid) {
            let nouveau = joindre(&installe, &exe);
            let sid = self.p.sid.clone();
            for t in self.sys.taches(None) {
                if apres_debut(&t.dossier, r"\Microsoft\").is_some() || apres_debut(&t.dossier, r"\Mindset\").is_some()
                {
                    continue;
                }
                if !egal(&self.vers_sid(t.compte.as_deref().unwrap_or("")), &sid) {
                    continue;
                }
                let mut actions = t.actions.clone();
                let mut change = false;
                for a in &mut actions {
                    if a.execute.as_deref().is_some_and(|x| egal(x.trim_matches('"'), &ancien)) {
                        a.execute = Some(format!("\"{nouveau}\""));
                        change = true;
                    }
                }
                if change {
                    self.sys.modifier_actions(&t.dossier, &t.nom, &actions)?;
                }
            }
        }
        // (une version de l'appli sans programme d'aide s'installe quand même, sans tâche)
        if !self.p.tache_aide.is_empty() && !self.p.exe_aide.is_empty() {
            let exe_aide = joindre(&installe, &self.p.exe_aide);
            if self.existe(&exe_aide) {
                let (nom, sid) = (self.p.tache_aide.clone(), self.p.sid.clone());
                self.enregistrer_tache_aide(&nom, &exe_aide, &sid)?;
            }
        }
        self.ecrire_resultat(true, &installe);
        Ok(())
    }

    /// Initialize-RacineDisque : X:\Mindset, droits posés explicitement, sans hériter de ceux du disque. Rend
    /// X:\Mindset\Programmes.
    fn initialiser_racine_disque(&mut self, lettre: &str, sid: &str) -> Res<String> {
        self.disque_fixe(lettre)?;
        if !sid_valable(sid) {
            return Err("Utilisateur inconnu.".into());
        }
        let racine = format!(r"{}:\{}", lettre.to_ascii_uppercase(), chemins::RACINE_DISQUE);
        let programmes = joindre(&racine, chemins::PROGRAMMES_DISQUE);
        let donnees = joindre(&racine, chemins::DONNEES_DISQUE);
        for d in [&racine, &programmes, &donnees] {
            self.creer_dossier(d)?;
        }
        self.sys.poser_droits_racine(&racine)?;
        // Tout ce qui est dessous reprend ces droits (même un dossier qui existait déjà avec d'autres droits)
        self.sys.reprendre_droits_herites(&programmes);
        self.sys.reprendre_droits_herites(&donnees);
        self.proprietaire_admins(&programmes);
        self.sys.ajouter_droit_modifier(&donnees, sid)?;
        Ok(programmes)
    }

    /// Action mindset : installe Mindset lui-même (copie de -Source), et l'inscrit dans « Applications installées ».
    fn mindset(&mut self) -> Res<()> {
        let disque = self.p.disque.clone();
        let sid = self.p.sid.clone();
        let programmes = if disque.is_empty() {
            joindre(&self.sys.dossier_programmes(), chemins::DOSSIER_PROGRAMMES)
        } else {
            self.initialiser_racine_disque(&disque, &sid)?
        };
        let dest = self.dossier_mindset(&joindre(&programmes, chemins::DOSSIER_MINDSET))?;
        let src = chemin_complet(self.p.source.trim_end_matches('\\'))?;
        if !self.existe(&joindre(&src, "Mindset.exe")) || !self.existe(&joindre(&src, r"fichiers\Mindset.ps1")) {
            return Err(format!("Ce dossier ne contient pas Mindset : {}", self.p.source));
        }
        // Préparé à côté puis échangé, comme une appli
        let tmp = format!("{dest}.nouveau-{}", suffixe());
        self.creer_dossier(&tmp)?;
        self.copier_fichier(&joindre(&src, "Mindset.exe"), &tmp)?;
        self.copier_dossier(&joindre(&src, "fichiers"), &tmp)?;
        for f in ["LISEZMOI.txt", NOM_DESINSTALLEUR, NOM_EXE] {
            let x = joindre(&src, f);
            if self.existe(&x) {
                self.copier_fichier(&x, &tmp)?;
            }
        }
        if self.existe(&dest) {
            let ancien = format!("{dest}.ancien-{}", suffixe());
            self.renommer(&dest, &ancien)?;
            self.renommer(&tmp, &dest)?;
            let _ = self.supprimer_tout(&ancien);
        } else {
            self.renommer(&tmp, &dest)?;
        }
        // (le dossier des programmes appartient aux Administrateurs : la tâche le vérifie à chaque demande)
        if disque.is_empty() {
            self.proprietaire_admins(&programmes);
        }
        // « Applications installées » de Windows : Mindset s'y désinstalle comme un vrai programme
        let exe = joindre(&dest, "Mindset.exe");
        self.sys.registre_creer(CLE_DESINSTALL)?;
        let valeurs = [
            ("DisplayName", ValeurRegistre::Texte("Mindset".into())),
            ("DisplayVersion", ValeurRegistre::Texte(self.p.version.clone())),
            ("Publisher", ValeurRegistre::Texte("Jordan Jacquot".into())),
            ("InstallLocation", ValeurRegistre::Texte(dest.clone())),
            ("DisplayIcon", ValeurRegistre::Texte(format!("\"{exe}\",0"))),
            ("UninstallString", ValeurRegistre::Texte(self.commande_desinstallation(&dest))),
            ("NoModify", ValeurRegistre::Nombre(1)),
            ("NoRepair", ValeurRegistre::Nombre(1)),
        ];
        for (nom, v) in &valeurs {
            self.sys.registre_ecrire(CLE_DESINSTALL, nom, v)?;
        }
        if let Err(e) = self.enregistrer_taches_mindset(&dest, &sid) {
            self.ecrire_resultat(true, &format!("{dest}|sans-taches : {e}"));
            return Ok(());
        }
        self.ecrire_resultat(true, &dest);
        Ok(())
    }

    /// Action mindset-maj : on attend que Mindset soit fermé, on installe le zip signé (vérifié ici), puis on le
    /// relance sans les droits administrateur, dans tous les cas (la nouvelle version, ou l'ancienne si la mise à
    /// jour a échoué).
    fn mindset_maj(&mut self) {
        let mut relance = joindre(&self.dossier_exe, "Mindset.exe");
        let r = self.mindset_maj_travail(&mut relance);
        if let Err(e) = r {
            self.ecrire_resultat(false, &e);
        }
        // Relancé par sa tâche de démarrage (sous le compte de l'utilisateur, sans droits) ; par la tâche SYSTEM,
        // jamais autrement (lancé d'ici, il tournerait en SYSTEM). En lancement direct, par l'Explorateur si besoin.
        let mut fait = false;
        if self.p.cache || self.par_tache {
            fait = self.sys.lancer_tache(&format!("{DOSSIER_TACHES}{TACHE_DEMARRAGE}")) == 0;
        }
        if !fait && !self.par_tache {
            let p = chemin_complet(&relance).unwrap_or(relance);
            self.sys.lancer_par_explorateur(&p);
        }
    }

    fn mindset_maj_travail(&mut self, relance: &mut String) -> Res<()> {
        let destination = self.p.destination.clone();
        let dest = self.dossier_demande(&destination)?;
        if !egal(feuille(&dest), chemins::DOSSIER_MINDSET)
            || (self.par_tache && !egal(&dest, &self.dossier_mindset_tache))
        {
            return Err(format!("Dossier refusé : {destination}"));
        }
        *relance = joindre(&dest, "Mindset.exe");
        if self.p.attendre_pid != 0 {
            self.sys.attendre_fin(self.p.attendre_pid, 30);
        }
        self.sys.pause(500);
        self.telechargement(&self.p.zip)?;
        self.telechargement(&self.p.signature)?;
        let octets = self.lire_octets(&self.p.zip)?;
        let sig = self.lire_octets(&self.p.signature)?;
        let cles = self.sys.reel(&joindre(&joindre(&self.dossier_exe, "fichiers"), "cles-publiques"));
        let dest_reel = self.sys.reel(&dest);
        paquet::installer(&paquet::Demande {
            zip: &octets,
            signature: &sig,
            cles: &cles,
            destination: &dest_reel,
            dossier_zip: "Mindset",
            exe: "Mindset.exe",
            version_minimale: None,
            appli: Some("mindset"),
            version_mindset: None,
        })
        .map_err(|e| e.to_string())?;
        // L'installateur qui tourne est resté dans l'ancien dossier, mis de côté : il est retiré
        self.retirer_ancien_installateur(&dest);
        if !self.p.version.is_empty() {
            let _ = self.sys.registre_ecrire(
                CLE_DESINSTALL,
                "DisplayVersion",
                &ValeurRegistre::Texte(self.p.version.clone()),
            );
        }
        // (une installation d'avant le désinstalleur autonome passe à lui avec cette mise à jour)
        let commande = self.commande_desinstallation(&dest);
        let _ = self.sys.registre_ecrire(CLE_DESINSTALL, "UninstallString", &ValeurRegistre::Texte(commande));
        // Tâches à jour avec la nouvelle version (l'utilisateur est connu)
        if !self.p.sid.is_empty() {
            let sid = self.p.sid.clone();
            let _ = self.enregistrer_taches_mindset(&dest, &sid);
        }
        let v = self.p.version.clone();
        self.ecrire_resultat(true, &v);
        Ok(())
    }

    /// Action taches : les tâches planifiées de Mindset, sans réinstaller.
    fn taches(&mut self) -> Res<()> {
        let destination = self.p.destination.clone();
        let dest = self.dossier_demande(&destination)?;
        if !egal(feuille(&dest), chemins::DOSSIER_MINDSET)
            || (self.par_tache && !egal(&dest, &self.dossier_mindset_tache))
        {
            return Err(format!("Dossier refusé : {destination}"));
        }
        let sid = self.p.sid.clone();
        self.enregistrer_taches_mindset(&dest, &sid)?;
        self.ecrire_resultat(true, &dest);
        Ok(())
    }

    /// Action supprimer : une appli gérée, ou Mindset lui-même (chemin de secours).
    fn supprimer(&mut self) -> Res<()> {
        let dest = self.dossier_demande(&self.p.destination.clone())?;
        if self.p.attendre_pid != 0 {
            self.sys.attendre_fin(self.p.attendre_pid, 30);
        }
        if !self.p.exe.is_empty() {
            let exe = self.p.exe.clone();
            self.arreter_programmes(&exe, &dest)?;
        }
        if !egal(feuille(&dest), chemins::DOSSIER_MINDSET) {
            if self.existe(&dest) {
                self.supprimer_tout(&dest)?;
            }
        } else {
            // Mindset lui-même. Mindset est déjà fermé et ne lira pas la réponse : chaque étape est tentée, puis ce
            // qui n'a pas pu être retiré est dit à l'utilisateur.
            let mut restes: Vec<String> = Vec::new();
            if self.existe(&dest) {
                self.ecarter_installateur(&dest);
                if let Err(e) = self.supprimer_tout(&dest) {
                    restes.push(format!("le dossier {dest} ({e})"));
                }
            }
            self.retirer_taches_mindset();
            for t in self.sys.taches(Some(DOSSIER_TACHES)) {
                restes.push(format!("la tâche planifiée « {DOSSIER_TACHES}{} »", t.nom));
            }
            // (l'entrée « Applications installées » reste tant que le dossier est là ; par la tâche,
            // HKLM\SOFTWARE\Mindset reste aussi tant qu'il y a des restes : c'est là que Mindset les lira)
            let mut cles = Vec::new();
            if !(self.par_tache && !restes.is_empty()) {
                cles.push(CLE_MINDSET);
            }
            if !self.existe(&dest) {
                cles.push(CLE_DESINSTALL);
            }
            for c in cles {
                if self.sys.registre_existe(c) && self.sys.registre_supprimer(c).is_err() {
                    restes.push(format!(r"la clé du registre HKLM:\{c}"));
                }
            }
            if !restes.is_empty() {
                let texte = format!(
                    "Mindset n'a pas pu être retiré entièrement. Ce qui reste :\n\n- {}\n\nRedémarre l'ordinateur, puis relance la désinstallation de Mindset (Paramètres de Windows, « Applications installées »).",
                    restes.join("\n- ")
                );
                if self.par_tache {
                    // En SYSTEM, aucune fenêtre (personne ne la verrait) : Mindset l'affichera
                    let _ = self.sys.registre_ecrire(CLE_INSTALLATION, VALEUR_RESTES, &ValeurRegistre::Texte(texte));
                } else {
                    self.sys.fenetre(&texte, "Désinstaller Mindset");
                }
                self.ecrire_resultat(false, &format!("Il reste : {}", restes.join(" ; ")));
                return Ok(());
            }
            // (la réponse irait dans HKLM\SOFTWARE\Mindset, qui vient d'être retiré)
            self.id_demande.clear();
        }
        // Dossier des programmes vide : retiré aussi (les données, elles, restent)
        let base = parent(&dest).to_string();
        let vide = std::fs::read_dir(self.sys.reel(&base)).is_ok_and(|mut l| l.next().is_none());
        if self.existe(&base) && vide {
            std::fs::remove_dir(self.sys.reel(&base)).map_err(|e| format!("{base} : {e}"))?;
        }
        self.ecrire_resultat(true, &dest);
        Ok(())
    }

    // =========================================================================================================
    // L'exe lui-même, dans le dossier qu'il remplace ou retire
    // =========================================================================================================

    /// Un exe qui tourne ne peut pas être effacé, mais il peut être déplacé sur le même disque : il est mis dans le
    /// dossier temporaire de Windows (ou, sur un autre disque, dans `X:\Mindset`, protégé lui aussi), puis effacé au
    /// prochain démarrage de Windows. `dossier` : le dossier de Mindset qui le contenait.
    fn ecarter_exe(&mut self, exe: &str, dossier: &str) {
        let nom = format!("MindsetInstallateur-{}.ancien", suffixe());
        for d in [joindre(&self.sys.dossier_windows(), "Temp"), parent(parent(dossier)).to_string()] {
            if d.is_empty() {
                continue;
            }
            let cible = joindre(&d, &nom);
            if self.renommer(exe, &cible).is_ok() {
                self.sys.effacer_au_redemarrage(&cible);
                return;
            }
        }
    }

    /// Avant de retirer le dossier de Mindset : l'exe qui tourne, s'il est dans ce dossier, en est d'abord écarté.
    fn ecarter_installateur(&mut self, dossier: &str) {
        let exe = self.sys.exe_courant();
        if apres_debut(&exe, &format!(r"{}\", dossier.trim_end_matches('\\'))).is_none() || !self.est_fichier(&exe) {
            return;
        }
        self.ecarter_exe(&exe, dossier);
    }

    /// Après une mise à jour de Mindset : l'ancien dossier, mis de côté (`<dossier>.ancien-xxxx`) par l'installation,
    /// garde l'exe qui tourne. Il en est écarté, puis l'ancien dossier est retiré ; ce qui ne peut toujours pas l'être
    /// est effacé au prochain démarrage de Windows.
    fn retirer_ancien_installateur(&mut self, dossier: &str) {
        let dossier = dossier.trim_end_matches('\\');
        let debut = format!("{}.ancien-", feuille(dossier));
        let Ok(liste) = std::fs::read_dir(self.sys.reel(parent(dossier))) else { return };
        let anciens: Vec<String> = liste
            .flatten()
            .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| apres_debut(n, &debut).is_some())
            .map(|n| joindre(parent(dossier), &n))
            .collect();
        for ancien in anciens {
            let exe = joindre(&ancien, NOM_EXE);
            if self.est_fichier(&exe) {
                self.ecarter_exe(&exe, dossier);
            }
            let _ = self.supprimer_tout(&ancien);
            if !self.existe(&ancien) {
                continue;
            }
            // (les fichiers d'abord, puis les dossiers du plus profond au moins profond : Windows les efface dans
            // cet ordre)
            let mut restes = Vec::new();
            fn lister(d: &std::path::Path, texte: &str, r: &mut Vec<String>) {
                if let Ok(l) = std::fs::read_dir(d) {
                    for e in l.flatten() {
                        let t = joindre(texte, &e.file_name().to_string_lossy());
                        if e.file_type().is_ok_and(|f| f.is_dir()) {
                            lister(&e.path(), &t, r);
                        }
                        r.push(t);
                    }
                }
            }
            lister(&self.sys.reel(&ancien), &ancien, &mut restes);
            restes.push(ancien);
            for r in restes {
                self.sys.effacer_au_redemarrage(&r);
            }
        }
    }
}

/// Le dossier des programmes de Mindset dans Program Files (`Program Files\Mindset`, chemin complet).
fn programmes_mindset(sys: &dyn Systeme) -> Res<String> {
    chemin_complet(&joindre(&sys.dossier_programmes(), chemins::DOSSIER_PROGRAMMES))
}

/// Assert-DisqueFixe : le disque doit être un disque fixe NTFS.
fn disque_fixe(sys: &dyn Systeme, lettre: &str) -> Res<()> {
    let l = lettre.chars().next().map(|c| c.to_ascii_uppercase()).unwrap_or(' ');
    match sys.disque(l) {
        Some(d) if d.genre == 3 && egal(&d.systeme_fichiers, "NTFS") => Ok(()),
        _ => Err(format!(
            "Le disque {lettre}: n'est pas un disque fixe NTFS : Mindset ne peut pas y protéger ses programmes."
        )),
    }
}

/// Test-DossierMindset : un dossier directement dans Program Files\Mindset, ou dans X:\Mindset\Programmes sur un
/// autre disque fixe NTFS (jamais ailleurs, jamais plus profond). Rend le dossier ramené à sa vraie place (chemin
/// complet, sans barre finale) ; sinon le message de refus. (Public pour le corpus dossier-protege.json.)
pub fn dossier_mindset(sys: &dyn Systeme, dossier: &str) -> Res<String> {
    let d = chemin_complet(dossier.trim_end_matches('\\'))?;
    let pf = format!(r"{}\", programmes_mindset(sys)?);
    let mut bases = vec![pf.clone()];
    if let Some(reste) = d.get(1..)
        && d.as_bytes()[0].is_ascii_alphabetic()
        && apres_debut(reste, r":\Mindset\Programmes\").is_some()
    {
        bases.push(format!(r"{}:\Mindset\Programmes\", &d[..1]));
    }
    for base in &bases {
        if let Some(reste) = apres_debut(&d, base)
            && !reste.is_empty()
            && !reste.contains(['\\', '/'])
        {
            if !egal(base, &pf) {
                disque_fixe(sys, &base[..1])?;
            }
            return Ok(d);
        }
    }
    Err(format!("Dossier refusé : {dossier}"))
}

// =============================================================================================================
// Petits outils
// =============================================================================================================

/// Un fichier texte décodé comme `ReadAllText(…, UTF8)` : la marque UTF-8 ou UTF-16 du début est suivie.
fn texte_utf(o: &[u8]) -> String {
    if let Some(r) = o.strip_prefix(b"\xEF\xBB\xBF") {
        return String::from_utf8_lossy(r).into_owned();
    }
    let utf16 = |r: &[u8], le: bool| -> String {
        let u: Vec<u16> = r
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| if le { u16::from_le_bytes(*c) } else { u16::from_be_bytes(*c) })
            .collect();
        String::from_utf16_lossy(&u)
    };
    if let Some(r) = o.strip_prefix(b"\xFF\xFE") {
        return utf16(r, true);
    }
    if let Some(r) = o.strip_prefix(b"\xFE\xFF") {
        return utf16(r, false);
    }
    String::from_utf8_lossy(o).into_owned()
}

/// Un point d'analyse NTFS (lien symbolique, point de jonction...) : l'attribut ReparsePoint.
fn lien(m: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        m.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        m.file_type().is_symlink()
    }
}

/// `[IO.Path]::GetDirectoryName` : le dossier d'un chemin complet ; `None` pour une racine.
fn nom_dossier(chemin: &str) -> Option<String> {
    let c = chemin.trim_end_matches('\\');
    if c.len() <= 2 && c.ends_with(':') {
        return None;
    }
    // (un partage réseau « \\serveur\partage » est une racine)
    if let Some(r) = c.strip_prefix(r"\\")
        && r.matches('\\').count() <= 1
    {
        return None;
    }
    let i = chemin.rfind('\\')?;
    let p = &chemin[..i];
    if p.len() == 2 && p.ends_with(':') { Some(format!(r"{p}\")) } else { Some(p.to_string()) }
}

/// `[IO.Path]::GetFileName` : ce qui suit la dernière barre (ou les deux points d'un disque).
fn nom_fichier_dotnet(chemin: &str) -> &str {
    chemin.rfind(['\\', '/', ':']).map_or(chemin, |i| &chemin[i + 1..])
}

/// `-ireplace` d'un texte simple.
fn remplacer_sans_casse(texte: &str, motif: &str, par: &str) -> String {
    let mut r = String::new();
    let mut reste = texte;
    while !reste.is_empty() {
        if let Some(apres) = apres_debut(reste, motif) {
            r.push_str(par);
            reste = apres;
        } else {
            let c = reste.chars().next().unwrap_or(' ');
            r.push(c);
            reste = &reste[c.len_utf8()..];
        }
    }
    r
}

/// Huit caractères hexadécimaux au hasard (le suffixe des dossiers temporaires, comme un morceau de GUID).
fn suffixe() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    format!("{:08x}", h.finish() as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outils() {
        assert_eq!(nom_dossier(r"C:\a\b").as_deref(), Some(r"C:\a"));
        assert_eq!(nom_dossier(r"C:\a").as_deref(), Some(r"C:\"));
        assert_eq!(nom_dossier(r"C:\"), None);
        assert_eq!(nom_dossier(r"\\s\p"), None);
        assert_eq!(nom_dossier(r"\\s\p\x").as_deref(), Some(r"\\s\p"));
        assert_eq!(nom_fichier_dotnet(r"C:\a\Appli.exe"), "Appli.exe");
        assert_eq!(remplacer_sans_casse(r"%systemdrive%\Users\x", "%SystemDrive%", "C:"), r"C:\Users\x");
        assert_eq!(suffixe().len(), 8);
        assert_eq!(texte_utf(b"\xEF\xBB\xBF{}"), "{}");
    }
}
