//! Le seul module du noyau qui parle à Windows, et le seul où le code « unsafe » est permis (chaque bloc a son
//! commentaire SAFETY) : le vrai port [`crate::systeme::Systeme`].
//!
//! - les programmes qui tournent et leur chemin (`MSProcessus.Releve` et `CheminGarde`, natif.cs:527-605) : relevé
//!   de Windows (`CreateToolhelp32Snapshot`), chemin lu une fois par programme (`QueryFullProcessImageNameW`, gardé
//!   par numéro et heure de création, oublié quand le programme s'arrête) ;
//! - les verrous et signaux nommés (`OpenMutexW`, `OpenEventW` + `SetEvent`) ;
//! - lancer un programme (sans console), ou sans les droits avec le jeton de l'Explorateur (`MSLanceur.SansAdmin`,
//!   natif.cs:141-183) ; l'arrêter, attendre sa fin ;
//! - ouvrir par l'Explorateur ; savoir si Mindset a les droits administrateur.
//!
//! Rien ici n'écrit dans le registre ni ne touche aux fenêtres d'un autre programme.

#![allow(unsafe_code)]

use std::collections::HashMap;
use std::os::windows::process::CommandExt;
use std::path::Path;
use std::sync::Mutex;

use windows::Win32::Foundation::{CloseHandle, ERROR_ACCESS_DENIED, FILETIME, GetLastError, HANDLE, WAIT_OBJECT_0};
use windows::Win32::Security::{
    DuplicateTokenEx, GetTokenInformation, SecurityImpersonation, TOKEN_ACCESS_MASK, TOKEN_DUPLICATE, TOKEN_ELEVATION,
    TOKEN_QUERY, TokenElevation, TokenPrimary,
};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::Threading::{
    CREATE_PROCESS_LOGON_FLAGS, CreateProcessWithTokenW, EVENT_MODIFY_STATE, GetCurrentProcess, GetProcessTimes,
    OpenEventW, OpenMutexW, OpenProcess, OpenProcessToken, PROCESS_CREATION_FLAGS, PROCESS_INFORMATION,
    PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
    QueryFullProcessImageNameW, STARTUPINFOW, SYNCHRONIZATION_SYNCHRONIZE, SetEvent, TerminateProcess,
    WaitForSingleObject,
};
use windows::Win32::UI::WindowsAndMessaging::{GetShellWindow, GetWindowThreadProcessId};
use windows::core::{HSTRING, PWSTR};

use crate::contexte::verrou;
use crate::systeme::{Lancer, Processus, Systeme};

/// CREATE_NO_WINDOW : aucun programme lancé par Mindset n'ouvre de console (règle de la suite).
pub const SANS_CONSOLE: u32 = 0x0800_0000;
/// Le signal de Mindset lui-même : jamais levé par le port (seul un second lancement de Mindset le lève).
pub const SIGNAL_MINDSET: &str = r"Local\Mindset-Afficher";

struct Poignee(HANDLE);
impl Drop for Poignee {
    fn drop(&mut self) {
        // SAFETY : handle ouvert par ce module, fermé une seule fois (ici)
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

/// Le vrai Windows.
#[derive(Default)]
pub struct SystemeWindows {
    /// Le chemin de chaque programme déjà lu, par (numéro, création) : `None` si Windows a refusé
    chemins: Mutex<HashMap<(u32, u64), Option<String>>>,
}

impl SystemeWindows {
    pub fn nouveau() -> SystemeWindows {
        SystemeWindows::default()
    }
}

fn filetime(f: &FILETIME) -> u64 {
    (u64::from(f.dwHighDateTime) << 32) | u64::from(f.dwLowDateTime)
}

/// L'heure de création d'un programme (0 si Windows refuse) et son chemin (`None` si Windows refuse).
fn creation_et_chemin(pid: u32, chemin_voulu: bool) -> (u64, Option<String>) {
    // SAFETY : handle ouvert ici et fermé par Poignee ; les tampons vivent pendant les appels
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return (0, None) };
        let h = Poignee(h);
        let (mut c, mut e, mut k, mut u) =
            (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
        let creation = if GetProcessTimes(h.0, &mut c, &mut e, &mut k, &mut u).is_ok() { filetime(&c) } else { 0 };
        if !chemin_voulu {
            return (creation, None);
        }
        let mut tampon = vec![0u16; 1024];
        let mut n = tampon.len() as u32;
        let chemin = if QueryFullProcessImageNameW(h.0, PROCESS_NAME_WIN32, PWSTR(tampon.as_mut_ptr()), &mut n).is_ok()
        {
            let c = String::from_utf16_lossy(&tampon[..n as usize]);
            Some(suite_commun::chemins::chemin_complet(&c).unwrap_or(c))
        } else {
            None
        };
        (creation, chemin)
    }
}

/// Le relevé des programmes (numéro et nom de fichier).
fn releve() -> Vec<(u32, String)> {
    let mut r = Vec::new();
    // SAFETY : instantané ouvert ici et fermé par Poignee ; l'entrée est une variable locale de la bonne taille
    unsafe {
        let Ok(s) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return r };
        let s = Poignee(s);
        let mut e = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        if Process32FirstW(s.0, &mut e).is_err() {
            return r;
        }
        loop {
            if e.th32ProcessID != 0 {
                let fin = e.szExeFile.iter().position(|&c| c == 0).unwrap_or(e.szExeFile.len());
                r.push((e.th32ProcessID, String::from_utf16_lossy(&e.szExeFile[..fin])));
            }
            if Process32NextW(s.0, &mut e).is_err() {
                break;
            }
        }
    }
    r
}

/// Un argument de ligne de commande, entre guillemets s'il le faut (règles de `CommandLineToArgvW`).
pub fn argument(a: &str) -> String {
    if !a.is_empty() && !a.contains([' ', '\t', '"']) {
        return a.to_string();
    }
    let mut r = String::from('"');
    let mut barres = 0;
    for c in a.chars() {
        match c {
            '\\' => barres += 1,
            '"' => {
                r.extend(std::iter::repeat_n('\\', barres * 2 + 1));
                r.push('"');
                barres = 0;
            }
            _ => {
                r.extend(std::iter::repeat_n('\\', barres));
                r.push(c);
                barres = 0;
            }
        }
    }
    r.extend(std::iter::repeat_n('\\', barres * 2));
    r.push('"');
    r
}

/// `MSLanceur.SansAdmin` : lance avec le jeton de l'Explorateur (sans les droits administrateur).
fn lancer_sans_droits(exe: &Path, arguments: &[String], dossier: &Path) -> Result<u32, String> {
    let mut ligne = argument(&exe.to_string_lossy());
    for a in arguments {
        ligne.push(' ');
        ligne.push_str(&argument(a));
    }
    let mut ligne: Vec<u16> = ligne.encode_utf16().chain(std::iter::once(0)).collect();
    let exe_w = HSTRING::from(exe.as_os_str());
    let dossier_w = HSTRING::from(dossier.as_os_str());
    // SAFETY : handles ouverts ici et fermés par Poignee ; la ligne de commande est un tampon modifiable terminé par
    // zéro qui vit pendant l'appel ; STARTUPINFOW et PROCESS_INFORMATION sont des variables locales
    unsafe {
        let shell = GetShellWindow();
        if shell.0.is_null() {
            return Err("Explorateur introuvable".into());
        }
        let mut pid_shell = 0u32;
        GetWindowThreadProcessId(shell, Some(&mut pid_shell));
        let p = Poignee(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid_shell).map_err(|e| e.to_string())?);
        let mut jeton = HANDLE::default();
        OpenProcessToken(p.0, TOKEN_DUPLICATE, &mut jeton).map_err(|e| e.to_string())?;
        let jeton = Poignee(jeton);
        let mut primaire = HANDLE::default();
        DuplicateTokenEx(
            jeton.0,
            TOKEN_ACCESS_MASK(0x0200_0000),
            None,
            SecurityImpersonation,
            TokenPrimary,
            &mut primaire,
        )
        .map_err(|e| e.to_string())?;
        let primaire = Poignee(primaire);
        let si = STARTUPINFOW { cb: std::mem::size_of::<STARTUPINFOW>() as u32, ..Default::default() };
        let mut pi = PROCESS_INFORMATION::default();
        CreateProcessWithTokenW(
            primaire.0,
            CREATE_PROCESS_LOGON_FLAGS(0),
            &exe_w,
            Some(PWSTR(ligne.as_mut_ptr())),
            PROCESS_CREATION_FLAGS(0),
            None,
            &dossier_w,
            &si,
            &mut pi,
        )
        .map_err(|e| e.to_string())?;
        let _ = CloseHandle(pi.hThread);
        let _ = CloseHandle(pi.hProcess);
        Ok(pi.dwProcessId)
    }
}

impl Systeme for SystemeWindows {
    fn processus(&self) -> Vec<Processus> {
        let liste = releve();
        let mut garde = verrou(&self.chemins);
        let mut vivants = Vec::with_capacity(liste.len());
        let mut r = Vec::with_capacity(liste.len());
        for (pid, nom) in liste {
            let (creation, _) = creation_et_chemin(pid, false);
            let cle = (pid, creation);
            let chemin = match garde.get(&cle) {
                Some(c) => c.clone(),
                None => {
                    let c = creation_et_chemin(pid, true).1;
                    garde.insert(cle, c.clone());
                    c
                }
            };
            vivants.push(cle);
            r.push(Processus { pid, nom, chemin, creation });
        }
        // (les programmes arrêtés sont oubliés)
        garde.retain(|k, _| vivants.contains(k));
        r
    }

    fn verrou_existe(&self, nom: &str) -> bool {
        let nom = HSTRING::from(nom);
        // SAFETY : nom valide pendant l'appel ; le handle ouvert est fermé tout de suite ; GetLastError lu juste après
        unsafe {
            match OpenMutexW(SYNCHRONIZATION_SYNCHRONIZE, false, &nom) {
                Ok(h) => {
                    let _ = CloseHandle(h);
                    true
                }
                Err(_) => GetLastError() == ERROR_ACCESS_DENIED,
            }
        }
    }

    fn lever_signal(&self, nom: &str) -> bool {
        if nom.eq_ignore_ascii_case(SIGNAL_MINDSET) {
            return false;
        }
        let nom = HSTRING::from(nom);
        // SAFETY : nom valide pendant l'appel ; seul le droit de lever le signal est demandé ; handle fermé ici
        unsafe {
            let Ok(h) = OpenEventW(EVENT_MODIFY_STATE, false, &nom) else { return false };
            let h = Poignee(h);
            SetEvent(h.0).is_ok()
        }
    }

    fn lancer(&self, l: &Lancer) -> Result<u32, String> {
        if l.sans_droits && self.est_admin() {
            return lancer_sans_droits(&l.exe, &l.arguments, &l.dossier);
        }
        let mut c = std::process::Command::new(&l.exe);
        c.args(&l.arguments).current_dir(&l.dossier).creation_flags(SANS_CONSOLE);
        c.spawn().map(|e| e.id()).map_err(|e| e.to_string())
    }

    fn arreter(&self, pid: u32) -> Result<(), String> {
        // SAFETY : handle ouvert ici et fermé par Poignee
        unsafe {
            let h = Poignee(OpenProcess(PROCESS_TERMINATE, false, pid).map_err(|e| e.to_string())?);
            TerminateProcess(h.0, 1).map_err(|e| e.to_string())
        }
    }

    fn attendre_fin(&self, pid: u32, ms: u32) -> bool {
        // SAFETY : handle ouvert ici et fermé par Poignee
        unsafe {
            let Ok(h) = OpenProcess(PROCESS_SYNCHRONIZE, false, pid) else { return true };
            let h = Poignee(h);
            WaitForSingleObject(h.0, ms) == WAIT_OBJECT_0
        }
    }

    fn ouvrir(&self, cible: &str) -> Result<(), String> {
        let windows = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
        let explorateur = Path::new(&windows).join("explorer.exe");
        std::process::Command::new(explorateur)
            .arg(cible)
            .current_dir(Path::new(&windows))
            .creation_flags(SANS_CONSOLE)
            .spawn()
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    fn est_admin(&self) -> bool {
        // SAFETY : le jeton de ce processus, ouvert en lecture et fermé par Poignee ; TOKEN_ELEVATION est une variable
        // locale de la bonne taille
        unsafe {
            let mut j = HANDLE::default();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut j).is_err() {
                return false;
            }
            let j = Poignee(j);
            let mut e = TOKEN_ELEVATION::default();
            let mut n = 0u32;
            GetTokenInformation(
                j.0,
                TokenElevation,
                Some(&mut e as *mut TOKEN_ELEVATION as *mut core::ffi::c_void),
                std::mem::size_of::<TOKEN_ELEVATION>() as u32,
                &mut n,
            )
            .is_ok()
                && e.TokenIsElevated != 0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_comme_windows() {
        assert_eq!(argument("-Demarrage"), "-Demarrage");
        assert_eq!(argument(r"C:\Program Files\Mindset\x.exe"), r#""C:\Program Files\Mindset\x.exe""#);
        assert_eq!(argument(r"E:\"), r#"E:\"#);
        assert_eq!(argument(r"E:\ dossier\"), r#""E:\ dossier\\""#);
        assert_eq!(argument(r#"a"b"#), r#""a\"b""#);
        assert_eq!(argument(""), r#""""#);
    }

    #[test]
    fn ce_programme_se_trouve_lui_meme() {
        let s = SystemeWindows::nouveau();
        let moi = std::process::id();
        let l = s.processus();
        let p = l.iter().find(|p| p.pid == moi).expect("ce programme est dans le relevé");
        let exe = std::env::current_exe().unwrap();
        assert!(suite_commun::chemins::egal(p.chemin.as_deref().unwrap(), &exe.to_string_lossy()));
        assert!(p.creation > 0);
        // (relu : le chemin vient de ce qui est gardé)
        assert_eq!(s.processus().iter().find(|p| p.pid == moi).unwrap().chemin, p.chemin);
    }

    #[test]
    fn verrous_et_signaux_absents() {
        let s = SystemeWindows::nouveau();
        let n = format!(r"Local\MindsetEssai-{}-absent", std::process::id());
        assert!(!s.verrou_existe(&n));
        assert!(!s.lever_signal(&n));
        assert!(!s.lever_signal(SIGNAL_MINDSET), "jamais le signal de Mindset");
        assert!(s.attendre_fin(u32::MAX - 3, 10), "un programme qui n'existe pas est fini");
    }
}
