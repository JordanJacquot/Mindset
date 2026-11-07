//! Les copies d'une appli sur le PC et ce qui les lance (installations.ps1:106-156, 648-753, 894-944) :
//! raccourcis directs, entrées « Run », copie trouvée, raccourci du menu Démarrer, ancienne copie prise en charge,
//! dossiers de données laissés par une désinstallation.

use mindset_noyau::{Appli, Contexte};
use std::path::{Path, PathBuf};
use suite_commun::chemins;

use crate::installations::{installation, suite_dir};
use crate::poste::{NouveauRaccourci, Poste};
use crate::regles::{dedans, dossier_appli, dossier_sur, dossier_travail, est_fichier, est_lien, existe, joindre};

/// Un raccourci qui lance l'appli.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RaccourciAppli {
    pub lien: String,
    pub cible: String,
}

/// Les fichiers d'un dossier dont le nom correspond (sans tenir compte des majuscules), sous-dossiers compris
/// jusqu'à `profondeur` niveaux (`Get-ChildItem -Recurse -Depth n`). Les liens ne sont pas suivis.
pub fn fichiers_nommes(dossier: &Path, profondeur: usize, garder: &dyn Fn(&str) -> bool, max: usize) -> Vec<PathBuf> {
    let mut r = Vec::new();
    fn parcourir(d: &Path, reste: usize, garder: &dyn Fn(&str) -> bool, max: usize, r: &mut Vec<PathBuf>) {
        let Ok(l) = std::fs::read_dir(d) else { return };
        let mut entrees: Vec<_> = l.flatten().collect();
        entrees.sort_by_key(|e| e.file_name().to_string_lossy().to_lowercase());
        let mut dossiers = Vec::new();
        for e in entrees {
            if r.len() >= max {
                return;
            }
            let Ok(t) = e.file_type() else { continue };
            let nom = e.file_name().to_string_lossy().into_owned();
            if t.is_file() && garder(&nom) {
                r.push(e.path());
            } else if t.is_dir() && est_lien(&e.path()) == Some(false) {
                dossiers.push(e.path());
            }
        }
        if reste == 0 {
            return;
        }
        for s in dossiers {
            parcourir(&s, reste - 1, garder, max, r);
        }
    }
    parcourir(dossier, profondeur, garder, max, &mut r);
    r
}

fn texte(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// `Get-RaccourcisAppli` : les raccourcis (.lnk) qui lancent cette appli, quelle que soit la copie.
pub fn raccourcis_appli(poste: &dyn Poste, appli: &Appli) -> Vec<RaccourciAppli> {
    let mut r = Vec::new();
    for l in poste.lieux_raccourcis() {
        let lnk = |n: &str| n.to_lowercase().ends_with(".lnk");
        for f in fichiers_nommes(Path::new(&l), 2, &lnk, usize::MAX) {
            let Some(t) = poste.cible_raccourci(&f) else { continue };
            if !t.is_empty() && chemins::egal(chemins::feuille(&t), &appli.exe) {
                r.push(RaccourciAppli { lien: texte(&f), cible: t });
            }
        }
    }
    r
}

/// Une entrée « Run » de l'utilisateur qui lance l'appli.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DemarrageRun {
    pub nom: String,
    pub cible: String,
}

/// `Get-DemarragesAppli` : les entrées « Run » de l'utilisateur qui lancent cette appli (sauf celles qui
/// commencent par « PS », des propriétés de PowerShell).
pub fn demarrages_appli(poste: &dyn Poste, appli: &Appli) -> Vec<DemarrageRun> {
    let Ok(l) = poste.entrees_run() else { return Vec::new() };
    l.into_iter()
        .filter(|(n, _)| !chemins::apres_debut(n, "PS").is_some())
        .filter_map(|(n, v)| Some(DemarrageRun { cible: crate::regles::cible_run(&v?, &appli.exe)?, nom: n }))
        .collect()
}

/// `Find-InstallationExistante` : une copie déjà présente (raccourcis, démarrage, programme ouvert, puis
/// Téléchargements, Bureau et Documents), jamais le dossier géré ni celui de Mindset.
pub fn installation_existante(ctx: &Contexte, poste: &dyn Poste, appli: &Appli) -> Option<String> {
    let mon = texte(&ctx.dossiers.mindset);
    let programmes = texte(&ctx.dossiers.programmes);
    trouver(poste, appli, &mon, &programmes, &ctx.systeme().processus())
}

/// `Find-InstallationExistante` sans le contexte (pour un travail de fond) : `mon` est le dossier de Mindset,
/// `programmes` la racine des programmes, `processus` le relevé des programmes qui tournent.
pub fn trouver(
    poste: &dyn Poste,
    appli: &Appli,
    mon: &str,
    programmes: &str,
    processus: &[mindset_noyau::systeme::Processus],
) -> Option<String> {
    let mut candidats: Vec<String> = Vec::new();
    for r in raccourcis_appli(poste, appli) {
        candidats.push(chemins::parent(&r.cible).to_string());
    }
    for r in demarrages_appli(poste, appli) {
        candidats.push(chemins::parent(&r.cible).to_string());
    }
    for c in mindset_noyau::systeme::chemins_nommes(processus, &[appli.exe.as_str(), "Mindset.exe"]) {
        let d = chemins::parent(&c).to_string();
        if !chemins::egal(&d, mon) {
            candidats.push(d);
        }
    }
    for l in poste.lieux_copies() {
        if l.is_empty() || !existe(&l) {
            continue;
        }
        let exe = appli.exe.clone();
        let garder = move |n: &str| chemins::egal(n, &exe);
        for f in fichiers_nommes(Path::new(&l), 3, &garder, 5) {
            candidats.push(chemins::parent(&texte(&f)).to_string());
        }
    }
    let gere = joindre(programmes, &appli.nom);
    let mut vus: Vec<String> = Vec::new();
    for c in candidats {
        // (`Select-Object -Unique` tient compte des majuscules)
        if vus.contains(&c) {
            continue;
        }
        vus.push(c.clone());
        if !chemins::egal(&c, &gere) && dossier_appli(&c, appli) {
            return Some(c);
        }
    }
    None
}

/// `Remove-Doublons` : les raccourcis directs et les entrées « Run » de l'appli sont retirés ; le message, s'il y a
/// eu des raccourcis.
pub fn retirer_doublons(ctx: &Contexte, poste: &dyn Poste, appli: &Appli) -> Option<String> {
    let mut n = 0;
    for r in raccourcis_appli(poste, appli) {
        if std::fs::remove_file(&r.lien).is_ok() {
            n += 1;
        } else {
            ctx.journal(&format!("Raccourci non retiré : {}", r.lien));
        }
    }
    for d in demarrages_appli(poste, appli) {
        let _ = poste.retirer_run(&d.nom);
    }
    crate::regles::message_doublons(n, &appli.nom)
}

/// `Get-RaccourciMenu` : `<menu Démarrer>\Mindset\<Nom>.lnk`.
pub fn raccourci_menu(poste: &dyn Poste, appli: &Appli) -> Option<String> {
    let m = poste.menu_applis()?;
    if m.is_empty() { None } else { Some(joindre(&m, &format!("{}.lnk", appli.nom))) }
}

/// Deux chemins du même fichier, l'un court (`RUNNER~1`) et l'autre long, sont égaux (`-ieq` après les avoir mis sous
/// la forme longue).
fn meme_chemin(poste: &dyn Poste, a: &str, b: &str) -> bool {
    chemins::egal(a, b) || chemins::egal(&poste.forme_longue(a), &poste.forme_longue(b))
}

/// `Update-RaccourciAppli` : le raccourci du menu Démarrer d'une appli gérée qui a son hôte Mindset.exe (son nom dans
/// la barre des tâches) ; retiré sinon. `occupee` : une opération est en cours (voir `Get-Installation`).
pub fn maj_raccourci_appli(ctx: &Contexte, poste: &dyn Poste, appli: &Appli, occupee: bool) {
    let Some(lien) = raccourci_menu(poste, appli) else { return };
    let inst = installation(ctx, appli, occupee);
    let hote = match &inst {
        Some(i) if i.gere => joindre(&i.dossier, "Mindset.exe"),
        _ => String::new(),
    };
    if hote.is_empty() || !est_fichier(&hote) {
        retirer_raccourci_appli(ctx, poste, appli);
        return;
    }
    let Some(inst) = inst else { return };
    // Déjà juste (même programme, même icône, même identité) : il n'est pas réécrit
    if existe(&lien)
        && let Some(l) = poste.lire_raccourci(Path::new(&lien))
        && meme_chemin(poste, &l.cible, &hote)
        && l.icone.rsplit_once(',').is_some_and(|(c, i)| i == "0" && meme_chemin(poste, c, &hote))
        && l.identite == appli.app_id
    {
        return;
    }
    let menu = poste.menu_applis().unwrap_or_default();
    let r = (|| -> Result<(), String> {
        std::fs::create_dir_all(&menu).map_err(|e| e.to_string())?;
        if existe(&lien) {
            std::fs::remove_file(&lien).map_err(|e| e.to_string())?;
        }
        poste.ecrire_raccourci(
            Path::new(&lien),
            &NouveauRaccourci {
                cible: hote.clone(),
                dossier: inst.dossier.clone(),
                icone: hote.clone(),
                description: appli.description.clone(),
                identite: appli.app_id.clone(),
            },
        )
    })();
    match r {
        Ok(()) => ctx.journal(&format!("Raccourci de {} dans le menu Démarrer : {lien}", appli.nom)),
        Err(e) => ctx.journal(&format!("Raccourci de {} dans le menu Démarrer : {e}", appli.nom)),
    }
}

/// `Remove-RaccourciAppli` : le raccourci du menu Démarrer est retiré, et le dossier Mindset du menu s'il est vide.
pub fn retirer_raccourci_appli(ctx: &Contexte, poste: &dyn Poste, appli: &Appli) {
    let Some(lien) = raccourci_menu(poste, appli) else { return };
    if existe(&lien) {
        match std::fs::remove_file(&lien) {
            Ok(()) => ctx.journal(&format!("Raccourci de {} retiré du menu Démarrer", appli.nom)),
            Err(e) => ctx.journal(&format!("Raccourci {lien} pas retiré : {e}")),
        }
    }
    let menu = poste.menu_applis().unwrap_or_default();
    if existe(&menu) && std::fs::read_dir(&menu).is_ok_and(|mut l| l.next().is_none()) {
        let _ = std::fs::remove_dir(&menu);
    }
}

/// Les fichiers d'un zip livrés avec l'appli : ceux rangés dans son dossier `dossier_zip`, chemins relatifs.
pub fn fichiers_livres(zip: &Path, dossier_zip: &str) -> Result<Vec<String>, String> {
    let o = std::fs::read(zip).map_err(|e| e.to_string())?;
    let archive = zip::ZipArchive::new(std::io::Cursor::new(o)).map_err(|e| e.to_string())?;
    let prefixe = format!("{}\\", dossier_zip.trim_end_matches('\\'));
    let mut r = Vec::new();
    for nom in archive.file_names().flatten() {
        let n = nom.replace('/', "\\");
        if n.ends_with('\\') {
            continue;
        }
        if let Some(rel) = chemins::apres_debut(&n, &prefixe) {
            r.push(rel.to_string());
        }
    }
    Ok(r)
}

/// Les fichiers qui restent dans un dossier (sous-dossiers compris, cachés aussi ; un lien compte pour un reste et
/// n'est jamais suivi).
fn fichiers_restants(d: &Path) -> usize {
    let Ok(l) = std::fs::read_dir(d) else { return 0 };
    let mut n = 0;
    for e in l.flatten() {
        let p = e.path();
        if est_lien(&p) == Some(true) {
            n += 1;
        } else if p.is_dir() {
            n += fichiers_restants(&p);
        } else {
            n += 1;
        }
    }
    n
}

/// Les sous-dossiers (pas les liens), sous-dossiers compris.
fn sous_dossiers(d: &Path, r: &mut Vec<PathBuf>) {
    let Ok(l) = std::fs::read_dir(d) else { return };
    for e in l.flatten() {
        let p = e.path();
        if est_lien(&p) == Some(false) && p.is_dir() {
            r.push(p.clone());
            sous_dossiers(&p, r);
        }
    }
}

/// `Remove-AncienneCopie` : seuls les fichiers livrés avec l'appli (et son ancien script) sont supprimés, puis les
/// dossiers devenus vides. Jamais un dossier de travail, jamais dans les programmes de Mindset. Le message.
pub fn retirer_ancienne_copie(
    ctx: &Contexte,
    poste: &dyn Poste,
    appli: &Appli,
    dossier: &str,
    zip: &str,
    dossier_zip: &str,
) -> String {
    let dossier_zip = if dossier_zip.is_empty() { appli.dossier_zip.as_str() } else { dossier_zip };
    let Ok(d) = chemins::chemin_complet(dossier.trim_end_matches('\\')) else {
        return format!(
            "L'ancienne copie ({dossier}) n'a pas été supprimée (dossier protégé ou lien vers un autre dossier)."
        );
    };
    let programmes = chemins::chemin_complet(&ctx.dossiers.programmes.to_string_lossy()).unwrap_or_default();
    let pf = chemins::chemin_complet(&joindre(&poste.program_files(), "Mindset")).unwrap_or_default();
    if dedans(&d, &programmes) || dedans(&d, &pf) {
        return String::new();
    }
    if !dossier_sur(&d, &poste.dossiers_interdits()) {
        return format!(
            "L'ancienne copie ({d}) n'a pas été supprimée (dossier protégé ou lien vers un autre dossier)."
        );
    }
    if dossier_travail(&d) {
        return format!("L'ancienne copie ({d}) est un dossier de travail : elle est gardée telle quelle.");
    }
    let mut livres = match fichiers_livres(Path::new(zip), dossier_zip) {
        Ok(l) => l,
        Err(_) => return format!("L'ancienne copie ({d}) n'a pas été supprimée (contenu du zip illisible)."),
    };
    if !appli.ancien_script.is_empty() {
        livres.push(appli.ancien_script.clone());
    }
    let dedans_d = format!("{d}\\");
    for rel in livres {
        let Ok(f) = chemins::chemin_complet(&joindre(&d, &rel)) else { continue };
        if chemins::apres_debut(&f, &dedans_d).is_some() && est_fichier(&f) {
            let _ = std::fs::remove_file(&f);
        }
    }
    let mut sd = Vec::new();
    sous_dossiers(Path::new(&d), &mut sd);
    sd.sort_by_key(|p| std::cmp::Reverse(p.to_string_lossy().encode_utf16().count()));
    for s in sd {
        if std::fs::read_dir(&s).is_ok_and(|mut l| l.next().is_none()) {
            let _ = std::fs::remove_dir(&s);
        }
    }
    let reste = fichiers_restants(Path::new(&d));
    if reste == 0 {
        let _ = std::fs::remove_dir_all(&d);
        return format!("L'ancienne copie ({d}) a été supprimée.");
    }
    let (s, v, n) = if reste > 1 { ("s", "saient", "nt") } else { ("", "sait", "") };
    format!(
        "L'ancienne copie ({d}) a été vidée de {} ; {reste} fichier{s} qui n'en fai{v} pas partie y reste{n}.",
        appli.nom
    )
}

/// Supprime un dossier, dossier par dossier : un lien (point de jonction, lien symbolique) est retiré seul, sans
/// jamais toucher à ce qu'il vise ; un fichier en lecture seule est d'abord remis en écriture (`Remove-DossierSansLiens`).
pub fn supprimer_sans_liens(d: &Path) -> std::io::Result<()> {
    if est_lien(d) == Some(true) {
        return std::fs::remove_dir(d);
    }
    for e in std::fs::read_dir(d)? {
        let p = e?.path();
        let m = std::fs::symlink_metadata(&p)?;
        let lien = est_lien(&p) == Some(true);
        if est_dossier(&m) {
            // (un lien vers un dossier : retiré seul, au début de l'appel)
            supprimer_sans_liens(&p)?;
            continue;
        }
        let mut perm = m.permissions();
        if perm.readonly() && !lien {
            #[allow(clippy::permissions_set_readonly_false)]
            perm.set_readonly(false);
            let _ = std::fs::set_permissions(&p, perm);
        }
        std::fs::remove_file(&p)?;
    }
    std::fs::remove_dir(d)
}

/// Un dossier, ou un lien vers un dossier (l'attribut « dossier », sans suivre le lien).
fn est_dossier(m: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        m.file_attributes() & 0x10 != 0
    }
    #[cfg(not(windows))]
    {
        m.is_dir()
    }
}

/// Le nom d'appli que WebView2-Tauri accepte (`^[A-Za-z][A-Za-z0-9-]{0,39}$`).
pub fn nom_tauri(nom: &str) -> bool {
    let mut c = nom.chars();
    c.next().is_some_and(|p| p.is_ascii_alphabetic())
        && nom.len() <= 40
        && c.all(|x| x.is_ascii_alphanumeric() || x == '-')
}

/// La partie « disque » de `Complete-Desinstallation` : les données sont-elles gardées ? Gardées : rien d'autre.
/// Supprimées : le profil WebView2 commun de l'appli, son dossier WebView2-Tauri (et WebView2-Tauri s'il est vide).
pub fn nettoyer_desinstallation(ctx: &Contexte, appli: &Appli) -> (bool, String) {
    let suite = suite_dir(ctx);
    let donnees = joindre(&suite, &appli.nom);
    let gardees = Path::new(&donnees).is_dir() && std::fs::read_dir(&donnees).is_ok_and(|mut l| l.next().is_some());
    ctx.journal(&format!("{} désinstallé (données {})", appli.nom, if gardees { "gardées" } else { "supprimées" }));
    if !gardees {
        let profil = joindre(&suite, &format!(r"WebView2\EBWebView\WV2Profile_{}", appli.nom.to_lowercase()));
        if Path::new(&profil).is_dir() {
            match std::fs::remove_dir_all(&profil) {
                Ok(()) => ctx.journal(&format!("Profil WebView2 de {} retiré", appli.nom)),
                Err(e) => ctx.journal(&format!("Profil WebView2 de {} pas retiré ({e})", appli.nom)),
            }
        }
        let tauri = joindre(&suite, "WebView2-Tauri");
        if nom_tauri(&appli.nom) && Path::new(&tauri).is_dir() && est_lien(Path::new(&tauri)) == Some(false) {
            let dt = joindre(&tauri, &appli.nom);
            if Path::new(&dt).is_dir() {
                match supprimer_sans_liens(Path::new(&dt)) {
                    Ok(()) => ctx.journal(&format!("Dossier WebView2 de {} (WebView2-Tauri) retiré", appli.nom)),
                    Err(e) => {
                        ctx.journal(&format!("Dossier WebView2 de {} (WebView2-Tauri) pas retiré ({e})", appli.nom))
                    }
                }
            }
            if std::fs::read_dir(&tauri).is_ok_and(|mut l| l.next().is_none()) {
                let _ = std::fs::remove_dir(&tauri);
            }
        }
    }
    let message = if gardees {
        format!(
            "{} est désinstallé. Ses données sont gardées dans {donnees} : une réinstallation les retrouve.",
            appli.nom
        )
    } else {
        format!("{} est désinstallé, avec ses données (réglages, journal, sauvegarde).", appli.nom)
    };
    (gardees, message)
}

/// `Write-DemandeQuitter` (integration.ps1:258-265) : `quitter.demande` (le numéro de Mindset) dans ses dossiers de
/// données. En essai, jamais hors du dossier d'essai.
pub fn ecrire_demande_quitter(ctx: &Contexte, appli: &Appli) {
    let mut ds = vec![crate::installations::dossier_donnees(ctx, appli), appli.donnees.clone()];
    ds.dedup();
    let racine_essai = ctx.dossiers.programmes.parent().map(texte).unwrap_or_default();
    for d in ds {
        if d.is_empty() || !existe(&d) {
            continue;
        }
        if ctx.essai {
            let complet = chemins::chemin_complet(&d).unwrap_or_default();
            if racine_essai.is_empty() || chemins::apres_debut(&complet, &racine_essai).is_none() {
                continue;
            }
        }
        let _ = std::fs::write(joindre(&d, "quitter.demande"), ctx.pid().to_string());
    }
}

/// `Get-ProcessusDonneesAppli` (applis.ps1:86-92) : les programmes d'aide lancés depuis ses dossiers de données
/// (jamais toutes les données de la suite, jamais Mindset).
pub fn processus_donnees(ctx: &Contexte, appli: &Appli) -> Vec<u32> {
    let mut ds = vec![crate::installations::dossier_donnees(ctx, appli), appli.donnees.clone()];
    ds.retain(|d| !d.is_empty());
    ds.dedup();
    let suite = suite_dir(ctx);
    let tous = ctx.systeme().processus();
    let mon = texte(&ctx.dossiers.mindset);
    let mut r = Vec::new();
    for d in ds {
        if !suite.is_empty() && chemins::egal(d.trim_end_matches('\\'), suite.trim_end_matches('\\')) {
            continue;
        }
        for p in mindset_noyau::systeme::dans_dossier(&tous, &d, None, ctx.pid(), &mon) {
            if !r.contains(&p) {
                r.push(p);
            }
        }
    }
    r
}
