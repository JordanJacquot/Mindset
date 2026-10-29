//! Le travail lui-même, étape par étape, comme la version C# (classe Travail de outils\desinstalleur.cs). Chaque étape
//! regarde d'abord ce qui existe : ce qui est déjà parti est passé.
//!
//! Ce qui est retiré :
//!   programmes        <Program Files>\Mindset (Mindset et ses applis) et X:\Mindset\Programmes sur chaque disque fixe
//!   applis            le désinstalleur de chaque appli qui en a un (champ « desinstalleur » de apps.json, et de la
//!                     liste des applis en ligne gardée par Mindset si elle est valable) est lancé d'abord, avec
//!                     -GarderDonnees ou -SupprimerDonnees ; s'il échoue, la désinstallation continue et le signale
//!   tâches            tout le dossier « \Mindset\ » du Planificateur (démarrage, installation, « <Appli> (aide) »...)
//!   registre          HKLM\SOFTWARE\Mindset, HKLM\...\Uninstall\Mindset, la valeur « Mindset » de HKCU\...\Run
//!   raccourcis        Mindset.lnk sur le Bureau et dans le menu Démarrer, et ceux des applis (dossier « Mindset »)
//!   données (option)  %LOCALAPPDATA%\Mindset et X:\Mindset\Donnees ; sinon seuls les téléchargements en cours partent
//!   X:\Mindset        retiré s'il est vide
//! Un élément qui ne part pas est affiché à la fin (« ce qui reste »). Dans ce cas, ce programme et l'entrée
//! « Applications installées » restent en place, pour pouvoir relancer la désinstallation.

use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use suite_commun::{chemins, liste_en_ligne};

use crate::bilan::Bilan;
use crate::lieux::Lieux;
use crate::systeme::{Fin, LectureTaches, Ruche, Systeme};
use crate::texte::{complet, contient, dans, egal, nom, nom_simple, sans_barre, t};

const LECTURE_SEULE: u32 = 0x1;
const DOSSIER: u32 = 0x10;
const LIEN: u32 = 0x400; // FILE_ATTRIBUTE_REPARSE_POINT (point de jonction, lien symbolique...)

/// Une appli de la suite qui a son propre désinstalleur (Nevermind)
#[derive(Debug, Clone)]
pub struct AppliGeree {
    pub nom: String,
    pub dossier: PathBuf,
    /// Son programme (None : trouvée sans apps.json, son programme est inconnu)
    pub exe: Option<String>,
    pub desinstalleur: String,
}

pub struct Travail<'a> {
    pub sys: &'a dyn Systeme,
    pub lieux: Lieux,
    pub bilan: Bilan,
    /// Ce programme, s'il est dans un dossier des programmes (il part en dernier, si tout le reste est parti)
    pub garder: Option<String>,
    pub donnees_gardees: Vec<String>,
    /// Les applis dont le désinstalleur a supprimé les données (malgré le choix de les garder)
    pub donnees_supprimees_par: Vec<String>,
    pub conseil_relance: String,
}

/// Attend un peu (le temps qu'un programme lâche ses fichiers)
fn pause(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

/// Les attributs d'un élément, sans suivre un lien (None : il n'existe pas)
fn attributs(p: &Path) -> Option<u32> {
    std::fs::symlink_metadata(p).ok().map(|m| m.file_attributes())
}

/// Retire l'attribut « lecture seule » d'un élément qui n'est pas un lien
fn ecriture_permise(p: &Path) {
    if let Ok(m) = std::fs::symlink_metadata(p)
        && m.file_attributes() & LIEN == 0
        && m.permissions().readonly()
    {
        let mut perm = m.permissions();
        #[allow(clippy::permissions_set_readonly_false)] // (Windows : seulement l'attribut « lecture seule »)
        perm.set_readonly(false);
        let _ = std::fs::set_permissions(p, perm);
    }
}

/// Le contenu d'un dossier, trié comme NTFS le rend (sans tenir compte des majuscules)
fn contenu(d: &Path) -> std::io::Result<Vec<PathBuf>> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(d)?.filter_map(|e| e.ok().map(|e| e.path())).collect();
    v.sort_by_key(|p| nom(&t(p)).to_uppercase());
    Ok(v)
}

/// Le dossier est-il vide ? (illisible : non)
fn vide(d: &Path) -> bool {
    std::fs::read_dir(d).is_ok_and(|mut e| e.next().is_none())
}

impl<'a> Travail<'a> {
    pub fn nouveau(sys: &'a dyn Systeme, lieux: Lieux, bilan: Bilan, original: Option<&str>) -> Travail<'a> {
        let mut garder = None;
        if let Some(o) = original.filter(|o| !o.is_empty()) {
            let g = t(&complet(Path::new(o)));
            if lieux.racines_programmes().iter().any(|r| dans(&g, &t(r))) {
                garder = Some(g);
            }
        }
        Travail {
            sys,
            lieux,
            bilan,
            garder,
            donnees_gardees: Vec::new(),
            donnees_supprimees_par: Vec::new(),
            conseil_relance: String::new(),
        }
    }

    pub fn executer(&mut self, supprimer_donnees: bool) {
        let programmes = self.lieux.racines_programmes();

        // 1. Mindset d'abord (il relancerait ses applis), puis le désinstalleur de chaque appli qui en a un, puis le reste
        self.bilan.etape("Fermeture de Mindset...");
        // (seulement le Mindset.exe du dossier de Mindset : l'hôte de chaque appli s'appelle aussi Mindset.exe, et son
        // désinstalleur la ferme lui-même, proprement)
        let dossiers_mindset: Vec<PathBuf> = programmes.iter().map(|r| r.join("Mindset")).collect();
        self.fermer_programmes(&dossiers_mindset, Some("Mindset.exe"));
        // Données à supprimer : les programmes d'aide lancés depuis les données (Evermind : voix\Mindset.exe...) les
        // tiendraient ouvertes ; fermés par leur chemin avant les désinstalleurs des applis
        if supprimer_donnees {
            let d = self.lieux.racines_donnees();
            self.fermer_programmes(&d, None);
        }
        for a in self.applis_avec_desinstalleur(&programmes) {
            self.lancer_desinstalleur(&a, supprimer_donnees);
        }
        self.bilan.etape("Fermeture des applis...");
        self.fermer_programmes(&programmes, None);

        // 2. Les tâches planifiées (tout le dossier « \Mindset\ »)
        self.bilan.etape("Retrait des tâches planifiées...");
        self.supprimer_taches();

        // 3. Le registre : HKLM\SOFTWARE\Mindset, et le lancement avec Windows
        self.bilan.etape("Nettoyage du registre...");
        let cle = self.lieux.cle_mindset.clone();
        self.supprimer_cle(Ruche::Machine, &cle);
        let run = self.lieux.cle_run.clone();
        match self.sys.valeur_existe(Ruche::Utilisateur, &run, "Mindset") {
            Ok(false) => {}
            Ok(true) => match self.sys.supprimer_valeur(Ruche::Utilisateur, &run, "Mindset") {
                Ok(()) => self.bilan.fait("Lancement avec Windows retiré".into()),
                Err(e) => self.bilan.reste(format!("Le lancement de Mindset avec Windows (registre : {e})")),
            },
            Err(e) => self.bilan.reste(format!("Le lancement de Mindset avec Windows (registre : {e})")),
        }

        // 4. Les raccourcis
        self.bilan.etape("Retrait des raccourcis...");
        for d in [self.lieux.bureau.clone(), self.lieux.menu.clone()].into_iter().flatten() {
            let l = d.join("Mindset.lnk");
            if l.is_file() {
                self.retirer_raccourci(&l);
            }
        }
        // Le dossier « Mindset » du menu Démarrer : les raccourcis des applis (leur nom dans la barre des tâches),
        // écrits par Mindset. Seuls les raccourcis partent ; le dossier aussi s'il est alors vide.
        if let Some(menu) = self.lieux.menu.clone() {
            let m = menu.join("Mindset");
            if m.is_dir() {
                for l in contenu(&m).unwrap_or_default() {
                    if l.is_file() && nom(&t(&l)).to_lowercase().ends_with(".lnk") {
                        self.retirer_raccourci(&l);
                    }
                }
                if vide(&m) {
                    let _ = std::fs::remove_dir(&m);
                }
            }
        }

        // 5. Les données : toutes si c'est demandé, sinon seulement les téléchargements en cours de Mindset
        self.bilan.etape(if supprimer_donnees { "Suppression des données..." } else { "Rangement des données..." });
        if supprimer_donnees {
            let d = self.lieux.racines_donnees();
            self.fermer_webview2(&d); // (le dossier WebView2 commun est dans les données)
        }
        for d in self.lieux.racines_donnees() {
            if supprimer_donnees {
                self.supprimer_dossier(&d, &format!("Le dossier des données {}", t(&d)));
                continue;
            }
            let telechargements = d.join("Mindset").join("telechargements");
            self.supprimer_dossier(
                &telechargements,
                &format!("Les téléchargements de Mindset ({})", t(&telechargements)),
            );
            let demande = d.join("Mindset").join("installation.demande");
            if demande.is_file() {
                let _ = std::fs::remove_file(&demande);
            }
            self.donnees_gardees.push(t(&d));
        }

        // 6. Les programmes (sauf ce désinstalleur s'il est dedans : il part en dernier, si tout le reste est parti)
        self.bilan.etape("Suppression des programmes...");
        for r in &programmes {
            self.supprimer_dossier(r, &format!("Le dossier des programmes {}", t(r)));
        }

        // 7. Fin : ce désinstalleur et l'entrée « Applications installées » partent seulement si rien d'autre ne reste
        //    (sinon ils restent, pour relancer la désinstallation après un redémarrage)
        self.bilan.etape("Derniers rangements...");
        if let Some(g) = self.garder.clone()
            && Path::new(&g).is_file()
            && self.bilan.restes.is_empty()
        {
            if !supprimer_fichier(Path::new(&g)) {
                self.bilan.reste(format!("Le programme {g}"));
            } else {
                // Ses dossiers devenus vides, jusqu'au dossier des programmes compris
                for r in &programmes {
                    let r = t(r);
                    if !dans(&g, &r) {
                        continue;
                    }
                    let mut d = Path::new(&g).parent().map(Path::to_path_buf);
                    while let Some(x) = d {
                        let xt = t(&x);
                        if !(dans(&xt, &r) || egal(&xt, &r)) {
                            break;
                        }
                        self.supprimer_dossier(&x, &format!("Le dossier des programmes {xt}"));
                        d = x.parent().map(Path::to_path_buf);
                    }
                }
            }
        }
        // X:\Mindset : retiré s'il est vide (il garde Donnees si les données sont gardées)
        for disque in self.lieux.disques.clone() {
            let m = complet(&disque.join("Mindset"));
            if !m.is_dir() {
                continue;
            }
            let Ok(c) = contenu(&m) else { continue };
            if c.is_empty() {
                self.supprimer_dossier(&m, &format!("Le dossier {}", t(&m)));
            } else if supprimer_donnees && !m.join("Programmes").is_dir() && !m.join("Donnees").is_dir() {
                self.bilan.reste(format!(
                    "Le dossier {} (il contient d'autres fichiers, qui ne viennent pas de Mindset : regarde-les avant de le supprimer)",
                    t(&m)
                ));
            }
        }

        let desinstalleur_garde = self.garder.as_deref().is_some_and(|g| Path::new(g).is_file());
        if self.bilan.restes.is_empty() || !desinstalleur_garde {
            let cle = self.lieux.cle_desinstall.clone();
            self.supprimer_cle(Ruche::Machine, &cle);
            self.conseil_relance =
                "Redémarre l'ordinateur, puis relance ce programme (Desinstaller Mindset.exe) pour retirer le reste."
                    .into();
        } else {
            // L'entrée « Applications installées » reste, et lance ce désinstalleur (même celle d'une ancienne version)
            let g = self.garder.clone().unwrap_or_default();
            let _ = self.sys.ecrire_texte_si_cle(
                Ruche::Machine,
                &self.lieux.cle_desinstall,
                "UninstallString",
                &format!("\"{g}\""),
            );
            self.conseil_relance = "Redémarre l'ordinateur, puis relance la désinstallation de Mindset (Paramètres de Windows, « Applications installées ») pour retirer le reste.".into();
        }
    }

    fn retirer_raccourci(&mut self, l: &Path) {
        ecriture_permise(l);
        match std::fs::remove_file(l) {
            Ok(()) => self.bilan.fait(format!("Raccourci retiré : {}", t(l))),
            Err(e) => self.bilan.reste(format!("Le raccourci {} ({e})", t(l))),
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Programmes ouverts
    // ---------------------------------------------------------------------------------------------------------------

    /// Les WebView2 de la suite (msedgewebview2.exe dont la ligne de commande contient un dossier de données de la
    /// suite) tiennent leurs fichiers ouverts : avant de supprimer les données, on leur laisse 5 secondes pour s'arrêter
    /// d'eux-mêmes (leur appli est fermée), puis ils sont fermés. Trouvés par leur ligne de commande, jamais par leur
    /// seul nom (les WebView2 des autres programmes du PC ne sont pas touchés).
    fn fermer_webview2(&mut self, racines: &[PathBuf]) {
        let limite = Instant::now() + Duration::from_secs(5);
        loop {
            let mut restants = Vec::new();
            for (pid, c) in self.sys.processus() {
                if !egal(&nom(&c), "msedgewebview2.exe") {
                    continue;
                }
                let Some(cmd) = self.sys.ligne_commande(pid) else { continue };
                if racines.iter().any(|r| contient(&cmd, &format!("{}\\", sans_barre(&t(r))))) {
                    restants.push(pid);
                }
            }
            if restants.is_empty() {
                return;
            }
            if Instant::now() < limite {
                pause(300);
                continue;
            }
            for pid in restants {
                match self.sys.fermer(pid, Duration::from_secs(3)) {
                    Ok(()) => self.bilan.fait(format!("WebView2 de la suite fermé ({pid})")),
                    Err(e) => self.bilan.journal(&format!("WebView2 de la suite : fermeture impossible ({pid}) : {e}")),
                }
            }
            return;
        }
    }

    /// Ferme les programmes lancés depuis ces dossiers (seulement ceux-là : une copie de travail ou de test du même nom,
    /// ailleurs, n'est jamais touchée). `nom_seul` : seulement ce programme-là.
    fn fermer_programmes(&mut self, racines: &[PathBuf], nom_seul: Option<&str>) {
        let moi = self.sys.mon_pid();
        for (pid, c) in self.sys.processus() {
            if pid == moi {
                continue;
            }
            let c = t(&complet(Path::new(&c)));
            if nom_seul.is_some_and(|n| !egal(&nom(&c), n)) {
                continue;
            }
            if !racines.iter().any(|r| dans(&c, &t(r))) {
                continue;
            }
            match self.sys.fermer(pid, Duration::from_secs(5)) {
                Ok(()) => self.bilan.fait(format!("Programme fermé : {c}")),
                Err(e) => self.bilan.journal(&format!("Fermeture impossible ({pid}) : {e}")),
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Les applis qui ont leur propre désinstalleur : celles de apps.json (champ « desinstalleur »), et, si apps.json est
    // absent ou abîmé, un « ...sinstaller <Appli>.exe » trouvé dans le dossier d'une appli
    // ---------------------------------------------------------------------------------------------------------------
    pub fn applis_avec_desinstalleur(&mut self, racines: &[PathBuf]) -> Vec<AppliGeree> {
        let mut r: Vec<AppliGeree> = Vec::new();
        for racine in racines {
            let mut liste = Vec::new();
            let json = racine.join("Mindset").join("fichiers").join("apps.json");
            if json.is_file() {
                match lire_apps(&json) {
                    Ok(l) => liste = l,
                    Err(e) => self.bilan.journal(&format!("apps.json illisible dans {} : {e}", t(racine))),
                }
            }
            // En plus : la liste des applis en ligne gardée par ce Mindset (une appli ajoutée depuis sa version)
            liste.extend(self.liste_en_ligne(racine));
            for (nom_appli, exe, des) in liste {
                let dossier = racine.join(&nom_appli);
                if dossier.join(&des).is_file() && !r.iter().any(|x| egal(&t(&x.dossier), &t(&dossier))) {
                    r.push(AppliGeree { nom: nom_appli, dossier, exe: Some(exe), desinstalleur: des });
                }
            }
            for dossier in contenu(racine).unwrap_or_default() {
                let Some(a) = attributs(&dossier) else { continue };
                if a & DOSSIER == 0 || a & LIEN != 0 || egal(&nom(&t(&dossier)), "Mindset") {
                    continue;
                }
                if r.iter().any(|x| egal(&t(&x.dossier), &t(&dossier))) {
                    continue;
                }
                let trouve = contenu(&dossier).unwrap_or_default().into_iter().find(|f| {
                    let n = nom(&t(f)).to_lowercase();
                    f.is_file() && n.ends_with(".exe") && n[..n.len() - 4].contains("sinstaller ")
                });
                if let Some(f) = trouve {
                    r.push(AppliGeree {
                        nom: nom(&t(&dossier)),
                        dossier: dossier.clone(),
                        exe: None,
                        desinstalleur: nom(&t(&f)),
                    });
                }
            }
        }
        r
    }

    /// La liste des applis en ligne gardée par le Mindset de cette racine des programmes (Mindset 2.16), dans son
    /// dossier de données (`X:\Mindset\Donnees\Mindset`, ou `%LOCALAPPDATA%\Mindset\Mindset`) : seulement si elle
    /// passe toutes les règles (suite_commun::liste_en_ligne, avec les clés, le numéro livré et la version de ce
    /// Mindset), lue une seule fois. Ses applis qui ont un désinstalleur, contrôlées comme celles de apps.json.
    fn liste_en_ligne(&self, racine: &Path) -> Vec<(String, String, String)> {
        let mindset = racine.join("Mindset");
        let donnees = chemins::donnees_mindset(&t(&mindset), || Err(String::new()))
            .ok()
            .map(PathBuf::from)
            .or_else(|| self.lieux.local_app_data.as_ref().map(|l| l.join("Mindset").join("Mindset")));
        let Some(donnees) = donnees else { return Vec::new() };
        let f = donnees.join(liste_en_ligne::FICHIER);
        match liste_en_ligne::lire_et_accepter(&f, &mindset) {
            Ok(l) => {
                self.bilan.journal(&format!("Liste des applis en ligne {} prise ({})", l.numero, t(&f)));
                applis_avec_desinstalleur(&l.applis)
            }
            Err(liste_en_ligne::Refus::Absente) => Vec::new(),
            Err(e) => {
                self.bilan.journal(&format!("Liste des applis en ligne ignorée ({}) : {e}", t(&f)));
                Vec::new()
            }
        }
    }

    /// Les dossiers de données d'une appli qui ont quelque chose dedans (<racine des données>\<Appli>)
    fn dossiers_donnees_pleins(&self, a: &AppliGeree) -> Vec<String> {
        self.lieux
            .racines_donnees()
            .into_iter()
            .map(|r| r.join(&a.nom))
            .filter(|d| d.is_dir() && !vide(d))
            .map(|d| t(&d))
            .collect()
    }

    /// Lance le désinstalleur de l'appli et attend sa fin (10 minutes au plus). Il a réussi si le programme de l'appli
    /// n'est plus là (ou, sans programme connu, s'il a fini sans erreur). Sinon la désinstallation continue quand même.
    /// Il reçoit le choix de la case (-GarderDonnees ou -SupprimerDonnees) : il ne pose pas la question. Données à
    /// garder mais parties quand même (ancienne version de l'appli, qui ignore ce choix) : noté, pour que le bilan dise
    /// la vérité.
    fn lancer_desinstalleur(&mut self, a: &AppliGeree, supprimer_donnees: bool) {
        let exe_appli = a.exe.as_ref().map(|e| a.dossier.join(e));
        if exe_appli.as_ref().is_some_and(|e| !e.exists()) {
            return; // (déjà désinstallée : ses restes partent avec le dossier)
        }
        self.bilan.etape(&format!("Désinstallation de {} (suis les étapes de son désinstalleur)...", a.nom));
        let donnees_avant = if supprimer_donnees { Vec::new() } else { self.dossiers_donnees_pleins(a) };
        let debut = Instant::now();
        let limite = Duration::from_secs(600);
        let restes_windows = "ses fichiers sont retirés quand même, mais les réglages de Windows qu'il avait changés sont peut-être restés.";
        let option = if supprimer_donnees { "-SupprimerDonnees" } else { "-GarderDonnees" };
        let code = match self.sys.lancer_et_attendre(&a.dossier.join(&a.desinstalleur), option, &a.dossier, limite) {
            Err(e) => {
                self.bilan
                    .alerte(format!("Le désinstalleur de {} n'a pas pu se lancer ({e}) : {restes_windows}", a.nom));
                return;
            }
            Ok(Fin::TropLong) => {
                self.bilan.alerte(format!(
                    "Le désinstalleur de {} n'avait pas fini au bout de 10 minutes : {restes_windows}",
                    a.nom
                ));
                return;
            }
            Ok(Fin::Code(c)) => c,
        };
        let ok = match &exe_appli {
            Some(exe) => {
                // Il a pu se relancer depuis une copie (comme celui-ci) : on attend tant qu'un programme du même nom tourne
                let nom_proc = Path::new(&a.desinstalleur).file_stem().map(|s| s.to_string_lossy().into_owned());
                let mut grace = Instant::now() + Duration::from_secs(3);
                while exe.exists() && debut.elapsed() < limite {
                    if nom_proc.as_deref().is_some_and(|n| self.sys.tourne_nomme(n)) {
                        grace = Instant::now() + Duration::from_secs(3);
                    } else if Instant::now() > grace {
                        break;
                    }
                    pause(300);
                }
                !exe.exists()
            }
            None => code == 0,
        };
        if !donnees_avant.is_empty() {
            let encore = self.dossiers_donnees_pleins(a);
            if !donnees_avant.iter().all(|d| encore.iter().any(|x| egal(x, d))) {
                self.donnees_supprimees_par.push(a.nom.clone());
                self.bilan.fait(format!(
                    "Données de {} supprimées par son désinstalleur (malgré le choix de les garder)",
                    a.nom
                ));
            }
        }
        if ok {
            self.bilan.fait(format!("{} désinstallé par son désinstalleur", a.nom));
        } else {
            let detail = if code != 0 { format!(" : code {code}") } else { String::new() };
            self.bilan.alerte(format!(
                "Le désinstalleur de {} n'a pas fini (annulé, ou en erreur{detail}) : {restes_windows}",
                a.nom
            ));
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Tâches planifiées : tout le dossier (ses tâches, même cachées, et ses sous-dossiers), puis le dossier lui-même
    // ---------------------------------------------------------------------------------------------------------------
    fn supprimer_taches(&mut self) {
        let chemin = self.lieux.dossier_taches.clone();
        match self.sys.dossier_taches(&chemin) {
            Err(LectureTaches::Connexion(e)) => {
                self.bilan.reste(format!(
                    "Les tâches planifiées de Mindset (dossier « {chemin} » du Planificateur de tâches : {e})"
                ));
                return;
            }
            Err(LectureTaches::Erreur(e)) => {
                self.bilan.reste(format!("Les tâches planifiées de Mindset (dossier « {chemin} » : {e})"));
                return;
            }
            Ok(None) => return,
            Ok(Some(_)) => {}
        }
        if !self.vider_dossier_taches(&chemin, 0) {
            return;
        }
        match self.sys.supprimer_dossier_taches("\\", chemin.trim_start_matches('\\')) {
            Ok(()) => self.bilan.fait(format!("Dossier de tâches planifiées retiré : {chemin}")),
            Err(e) if e.absent => {}
            Err(e) => self.bilan.reste(format!("Le dossier « {chemin} » du Planificateur de tâches ({})", e.message)),
        }
    }

    fn vider_dossier_taches(&mut self, chemin: &str, profondeur: u32) -> bool {
        let contenu = match self.sys.dossier_taches(chemin) {
            Ok(Some(c)) => c,
            Ok(None) => return true,
            Err(LectureTaches::Connexion(e) | LectureTaches::Erreur(e)) => {
                self.bilan.reste(format!("Le dossier « {chemin} » du Planificateur de tâches ({e})"));
                return false;
            }
        };
        let mut tout = true;
        for (nom_sous, chemin_sous) in &contenu.sous_dossiers {
            if profondeur > 32 || !self.vider_dossier_taches(chemin_sous, profondeur + 1) {
                tout = false;
                continue;
            }
            match self.sys.supprimer_dossier_taches(chemin, nom_sous) {
                Ok(()) => {}
                Err(e) if e.absent => {}
                Err(e) => {
                    tout = false;
                    self.bilan
                        .reste(format!("Le dossier « {chemin_sous} » du Planificateur de tâches ({})", e.message));
                }
            }
        }
        for (nom_tache, chemin_tache) in &contenu.taches {
            self.sys.arreter_tache(chemin_tache);
            match self.sys.supprimer_tache(chemin, nom_tache) {
                Ok(()) => self.bilan.fait(format!("Tâche planifiée retirée : {chemin_tache}")),
                Err(e) if e.absent => {}
                Err(e) => {
                    tout = false;
                    self.bilan.reste(format!("La tâche planifiée « {chemin_tache} » ({})", e.message));
                }
            }
        }
        tout
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Registre et fichiers
    // ---------------------------------------------------------------------------------------------------------------
    fn supprimer_cle(&mut self, ruche: Ruche, cle: &str) {
        let nom_cle = format!("{}\\{cle}", self.sys.nom_ruche(ruche));
        let r = match self.sys.cle_existe(ruche, cle) {
            Ok(false) => return,
            Ok(true) => self.sys.supprimer_cle(ruche, cle),
            Err(e) => Err(e),
        };
        match r {
            Ok(()) => self.bilan.fait(format!("Clé du registre retirée : {nom_cle}")),
            Err(e) => self.bilan.reste(format!("La clé du registre {nom_cle} ({e})")),
        }
    }

    /// Supprime un dossier avec tout son contenu, en réessayant pendant 3 secondes (un programme qui vient d'être fermé
    /// libère ses fichiers un peu après). Un lien (point de jonction, lien symbolique) est retiré lui-même, sans jamais
    /// entrer dedans : ce vers quoi il pointe n'est pas touché. Ce désinstalleur (`garder`) est laissé à sa place.
    fn supprimer_dossier(&mut self, dossier: &Path, description: &str) {
        if !dossier.is_dir() {
            return;
        }
        let limite = Instant::now() + Duration::from_secs(3);
        let mut bloque;
        loop {
            bloque = None;
            self.supprimer_une_fois(dossier, &mut bloque);
            if bloque.is_none() || Instant::now() > limite {
                break;
            }
            pause(300);
        }
        match bloque {
            None => self.bilan.fait(format!("{description} : supprimé")),
            Some(b) => self.bilan.reste(format!("{description} (un fichier est peut-être encore ouvert : {b})")),
        }
    }

    /// `bloque` : le premier élément qui n'a pas pu être supprimé (None si tout est parti, à part ce désinstalleur)
    fn supprimer_une_fois(&self, d: &Path, bloque: &mut Option<String>) {
        let Some(a) = attributs(d) else { return };
        if a & LIEN != 0 {
            // Le lien lui-même, jamais ce vers quoi il pointe
            if std::fs::remove_dir(d).is_err() && bloque.is_none() {
                *bloque = Some(t(d));
            }
            return;
        }
        let Ok(entrees) = contenu(d) else {
            if bloque.is_none() {
                *bloque = Some(t(d));
            }
            return;
        };
        let mut garde = false;
        for e in entrees {
            let Some(ae) = attributs(&e) else { continue };
            if ae & DOSSIER != 0 {
                self.supprimer_une_fois(&e, bloque);
                if self.garder.as_deref().is_some_and(|g| dans(g, &t(&e))) && e.is_dir() {
                    garde = true;
                }
                continue;
            }
            if self.garder.as_deref().is_some_and(|g| egal(&t(&complet(&e)), g)) {
                garde = true;
                continue;
            }
            if ae & LECTURE_SEULE != 0 {
                ecriture_permise(&e);
            }
            if std::fs::remove_file(&e).is_err() && bloque.is_none() {
                *bloque = Some(t(&e));
            }
        }
        if garde || bloque.is_some() {
            return;
        }
        ecriture_permise(d);
        if std::fs::remove_dir(d).is_err() && bloque.is_none() {
            *bloque = Some(t(d));
        }
    }
}

/// Supprime un fichier, en réessayant pendant 3 secondes
fn supprimer_fichier(f: &Path) -> bool {
    let limite = Instant::now() + Duration::from_secs(3);
    loop {
        if !f.exists() {
            return true;
        }
        ecriture_permise(f);
        if std::fs::remove_file(f).is_ok() {
            return true;
        }
        if Instant::now() > limite {
            return false;
        }
        pause(300);
    }
}

/// Les applis de apps.json qui ont un désinstalleur : (nom, exe, désinstalleur), noms vérifiés
fn lire_apps(f: &Path) -> Result<Vec<(String, String, String)>, String> {
    let octets = std::fs::read(f).map_err(|e| e.to_string())?;
    let texte = String::from_utf8_lossy(octets.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&octets)).into_owned();
    let v: serde_json::Value = serde_json::from_str(&texte).map_err(|e| e.to_string())?;
    Ok(applis_avec_desinstalleur(v.as_array().map(Vec::as_slice).unwrap_or_default()))
}

/// Parmi des entrées de la forme de apps.json, celles qui ont un désinstalleur, noms vérifiés (les autres sont
/// ignorées)
fn applis_avec_desinstalleur(entrees: &[serde_json::Value]) -> Vec<(String, String, String)> {
    let mut r = Vec::new();
    for a in entrees {
        let champ = |c: &str| a.get(c).and_then(|x| x.as_str()).map(str::to_string);
        let (Some(n), Some(exe), Some(des)) = (champ("nom"), champ("exe"), champ("desinstalleur")) else { continue };
        if !nom_simple(&n)
            || n.contains("..")
            || !nom_simple(&exe)
            || !nom_simple(&des)
            || !des.to_lowercase().ends_with(".exe")
        {
            continue;
        }
        r.push((n, exe, des));
    }
    r
}

#[cfg(test)]
mod tests;
