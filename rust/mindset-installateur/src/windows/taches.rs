//! Tâches planifiées, par l'interface COM du Planificateur de tâches (ce que faisaient Get-ScheduledTask,
//! Register-ScheduledTask, Set-ScheduledTask, Unregister-ScheduledTask et l'objet Schedule.Service).

use super::outils::{Variant, message};
use mindset_installateur::systeme::{ActionTache, CompteTache, Instances, NouvelleTache, TacheVue};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows::Win32::System::TaskScheduler::{
    IExecAction, IRegisteredTask, ITaskFolder, ITaskService, TASK_CREATE_OR_UPDATE, TASK_ENUM_HIDDEN,
    TASK_LOGON_INTERACTIVE_TOKEN, TASK_LOGON_SERVICE_ACCOUNT, TASK_LOGON_TYPE, TASK_UPDATE, TaskScheduler,
};
use windows::core::{BSTR, Interface};

/// Le Planificateur, connecté
fn service() -> Result<ITaskService, String> {
    // SAFETY : création d'un objet COM du système, puis connexion à ce PC
    unsafe {
        let s: ITaskService = CoCreateInstance(&TaskScheduler, None, CLSCTX_INPROC_SERVER).map_err(|e| message(&e))?;
        let v = Variant::vide();
        s.Connect(&v.0, &v.0, &v.0, &v.0).map_err(|e| message(&e))?;
        Ok(s)
    }
}

/// Un dossier de tâches (« \ », « \Mindset\ »)
fn dossier(chemin: &str) -> Result<ITaskFolder, String> {
    let s = service()?;
    let c = if chemin == "\\" { chemin } else { chemin.trim_end_matches('\\') };
    // SAFETY : appel COM ordinaire
    unsafe { s.GetFolder(&BSTR::from(c)) }.map_err(|e| message(&e))
}

/// Ce qu'on lit d'une tâche
fn vue(t: &IRegisteredTask, dossier_tache: &str) -> Option<TacheVue> {
    // SAFETY : appels COM ordinaires ; une valeur illisible reste vide
    unsafe {
        let def = t.Definition().ok()?;
        let mut compte = BSTR::new();
        if let Ok(p) = def.Principal() {
            let _ = p.UserId(&mut compte);
        }
        let mut actions = Vec::new();
        if let Ok(a) = def.Actions() {
            let mut n = 0i32;
            let _ = a.Count(&mut n);
            for i in 1..=n {
                let Ok(x) = a.get_Item(i) else { continue };
                match x.cast::<IExecAction>() {
                    Ok(e) => {
                        let (mut exe, mut args) = (BSTR::new(), BSTR::new());
                        let _ = e.Path(&mut exe);
                        let _ = e.Arguments(&mut args);
                        actions.push(ActionTache { execute: Some(exe.to_string()), arguments: args.to_string() });
                    }
                    Err(_) => actions.push(ActionTache { execute: None, arguments: String::new() }),
                }
            }
        }
        let compte = compte.to_string();
        Some(TacheVue {
            dossier: dossier_tache.to_string(),
            nom: t.Name().map(|b| b.to_string()).unwrap_or_default(),
            compte: (!compte.is_empty()).then_some(compte),
            actions,
        })
    }
}

/// Les tâches d'un dossier, et de ses sous-dossiers si `tous`
fn lister(f: &ITaskFolder, r: &mut Vec<TacheVue>, tous: bool, profondeur: u32) {
    // SAFETY : appels COM ordinaires ; erreurs : la tâche ou le dossier est sauté
    unsafe {
        let chemin = f.Path().map(|b| b.to_string()).unwrap_or_default();
        let dossier_tache = if chemin == "\\" { chemin.clone() } else { format!("{chemin}\\") };
        if let Ok(taches) = f.GetTasks(TASK_ENUM_HIDDEN.0) {
            let n = taches.Count().unwrap_or(0);
            for i in 1..=n {
                let Ok(t) = taches.get_Item(&Variant::nombre(i).0) else { continue };
                if let Some(v) = vue(&t, &dossier_tache) {
                    r.push(v);
                }
            }
        }
        if !tous || profondeur > 16 {
            return;
        }
        if let Ok(sous) = f.GetFolders(0) {
            let n = sous.Count().unwrap_or(0);
            for i in 1..=n {
                if let Ok(s) = sous.get_Item(&Variant::nombre(i).0) {
                    lister(&s, r, true, profondeur + 1);
                }
            }
        }
    }
}

/// Les tâches d'un dossier (sans ses sous-dossiers), ou de tout le PC
pub fn taches(chemin: Option<&str>) -> Vec<TacheVue> {
    let mut r = Vec::new();
    match chemin {
        Some(c) => {
            if let Ok(f) = dossier(c) {
                lister(&f, &mut r, false, 0);
            }
        }
        None => {
            if let Ok(f) = dossier("\\") {
                lister(&f, &mut r, true, 0);
            }
        }
    }
    r
}

/// Une tâche
pub fn tache(chemin: &str, nom: &str) -> Option<TacheVue> {
    let f = dossier(chemin).ok()?;
    // SAFETY : appel COM ordinaire
    let t = unsafe { f.GetTask(&BSTR::from(nom)) }.ok()?;
    let d = if chemin.ends_with('\\') { chemin.to_string() } else { format!("{chemin}\\") };
    vue(&t, &d)
}

/// Un texte mis dans du XML
fn xml(t: &str) -> String {
    t.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

/// La définition d'une tâche, en XML (le format du Planificateur), avec les mêmes réglages que
/// New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ...
/// -MultipleInstances ...
pub fn xml_tache(t: &NouvelleTache) -> String {
    let declencheur = match &t.ouverture_session {
        Some(u) => format!(
            "<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{}</UserId><Delay>PT10S</Delay></LogonTrigger></Triggers>",
            xml(u)
        ),
        None => String::new(),
    };
    let principal = match &t.compte {
        CompteTache::Systeme => "<UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel>".to_string(),
        CompteTache::Utilisateur(sid) => {
            format!(
                "<UserId>{}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel>",
                xml(sid)
            )
        }
    };
    let instances = match t.instances {
        Instances::Parallele => "Parallel",
        Instances::File => "Queue",
        Instances::IgnorerNouvelle => "IgnoreNew",
    };
    let duree = match t.duree_max_minutes {
        Some(m) => format!("PT{m}M"),
        None => "PT0S".to_string(),
    };
    format!(
        concat!(
            "<?xml version=\"1.0\" encoding=\"UTF-16\"?>",
            "<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">",
            "<RegistrationInfo><Description>{description}</Description></RegistrationInfo>",
            "{declencheur}",
            "<Principals><Principal id=\"Author\">{principal}</Principal></Principals>",
            "<Settings>",
            "<MultipleInstancesPolicy>{instances}</MultipleInstancesPolicy>",
            "<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>",
            "<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>",
            "<ExecutionTimeLimit>{duree}</ExecutionTimeLimit>",
            "<Enabled>true</Enabled>",
            "</Settings>",
            "<Actions Context=\"Author\"><Exec><Command>{commande}</Command><Arguments>{arguments}</Arguments>",
            "<WorkingDirectory>{dossier}</WorkingDirectory></Exec></Actions>",
            "</Task>"
        ),
        description = xml(&t.description),
        declencheur = declencheur,
        principal = principal,
        instances = instances,
        duree = duree,
        commande = xml(&t.execute),
        arguments = xml(&t.arguments),
        dossier = xml(&t.dossier_travail),
    )
}

/// Le dossier \Mindset, créé s'il n'existe pas
fn dossier_mindset() -> Result<ITaskFolder, String> {
    if let Ok(f) = dossier(r"\Mindset") {
        return Ok(f);
    }
    let racine = dossier("\\")?;
    let v = Variant::vide();
    // SAFETY : appel COM ordinaire
    unsafe { racine.CreateFolder(&BSTR::from("Mindset"), &v.0) }.map_err(|e| message(&e))
}

/// Crée ou remplace une tâche de \Mindset\
pub fn enregistrer(t: &NouvelleTache) -> Result<(), String> {
    let f = dossier_mindset()?;
    let (compte, connexion): (String, TASK_LOGON_TYPE) = match &t.compte {
        CompteTache::Systeme => ("S-1-5-18".into(), TASK_LOGON_SERVICE_ACCOUNT),
        CompteTache::Utilisateur(sid) => (sid.clone(), TASK_LOGON_INTERACTIVE_TOKEN),
    };
    let (u, vide) = (Variant::texte(&compte), Variant::vide());
    // SAFETY : appel COM ordinaire
    unsafe {
        f.RegisterTask(
            &BSTR::from(t.nom.as_str()),
            &BSTR::from(xml_tache(t)),
            TASK_CREATE_OR_UPDATE.0,
            &u.0,
            &vide.0,
            connexion,
            &vide.0,
        )
    }
    .map(|_| ())
    .map_err(|e| message(&e))
}

/// Qui peut lire et lancer une tâche de \Mindset\
pub fn droits(nom: &str, sddl: &str) -> Result<(), String> {
    let f = dossier(r"\Mindset")?;
    // SAFETY : appels COM ordinaires
    unsafe {
        let t = f.GetTask(&BSTR::from(nom)).map_err(|e| message(&e))?;
        t.SetSecurityDescriptor(&BSTR::from(sddl), 0).map_err(|e| message(&e))
    }
}

/// Retire une tâche (rien si elle n'existe pas)
pub fn retirer(chemin: &str, nom: &str) {
    if let Ok(f) = dossier(chemin) {
        // SAFETY : appel COM ordinaire
        let _ = unsafe { f.DeleteTask(&BSTR::from(nom), 0) };
    }
}

/// Retire un dossier de tâches de la racine (vide)
pub fn retirer_dossier(nom: &str) {
    if let Ok(f) = dossier("\\") {
        // SAFETY : appel COM ordinaire
        let _ = unsafe { f.DeleteFolder(&BSTR::from(nom), 0) };
    }
}

/// Remplace les programmes lancés par les actions d'une tâche (même nombre d'actions, dans l'ordre)
pub fn modifier_actions(chemin: &str, nom: &str, actions: &[ActionTache]) -> Result<(), String> {
    let f = dossier(chemin)?;
    // SAFETY : appels COM ordinaires
    unsafe {
        let t = f.GetTask(&BSTR::from(nom)).map_err(|e| message(&e))?;
        let def = t.Definition().map_err(|e| message(&e))?;
        let liste = def.Actions().map_err(|e| message(&e))?;
        for (i, a) in actions.iter().enumerate() {
            let Some(exe) = &a.execute else { continue };
            let x = liste.get_Item(i as i32 + 1).map_err(|e| message(&e))?;
            if let Ok(e) = x.cast::<IExecAction>() {
                let mut avant = BSTR::new();
                let _ = e.Path(&mut avant);
                if avant != exe.as_str() {
                    e.SetPath(&BSTR::from(exe.as_str())).map_err(|e| message(&e))?;
                }
            }
        }
        let mut connexion = TASK_LOGON_TYPE::default();
        let mut compte = BSTR::new();
        if let Ok(p) = def.Principal() {
            let _ = p.LogonType(&mut connexion);
            let _ = p.UserId(&mut compte);
        }
        let (u, vide) = (Variant::texte(&compte.to_string()), Variant::vide());
        f.RegisterTaskDefinition(&BSTR::from(nom), &def, TASK_UPDATE.0, &u.0, &vide.0, connexion, &vide.0)
            .map(|_| ())
            .map_err(|e| message(&e))
    }
}
