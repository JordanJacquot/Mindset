//! Le seul module qui parle à Windows (et le seul où le code « unsafe » est permis). Il remplit le trait `Systeme` avec
//! les vrais appels, et donne à main.rs ce qu'il faut pour se relancer, se copier et montrer sa fenêtre.
//!
//! Ce que la version C# lisait chez l'utilisateur, et que celle-ci ne lit plus (audit du 25/10, constat 5) :
//! - Program Files venait de la variable ProgramW6432, que l'utilisateur peut changer (HKCU\Environment) : il vient
//!   maintenant de HKLM (ProgramFilesDir, que seul un administrateur peut changer), sinon de Windows lui-même ;
//! - le Bureau, le menu Démarrer et %LOCALAPPDATA% venaient des « Shell Folders » de l'utilisateur, qu'il peut faire
//!   pointer n'importe où : ils ne sont acceptés que DANS son dossier de profil (lu dans HKLM, ProfileList) et sans
//!   point de jonction ni lien symbolique en route ; sinon, leur place habituelle dans son profil ;
//! - le dossier temporaire venait de la variable TEMP : la copie et le journal vont dans <Windows>\Temp, et le dossier
//!   de la copie est créé directement protégé (aucun instant où un programme sans droits pourrait y glisser un fichier).
//!
//! Aucune variable d'environnement n'est lue.

#![allow(unsafe_code)]

pub mod fenetre;

use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::time::Duration;

use windows::Wdk::System::Threading::{NtQueryInformationProcess, PROCESSINFOCLASS};
use windows::Win32::Foundation::{CloseHandle, HANDLE, HLOCAL, LocalFree, WAIT_OBJECT_0};
use windows::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, ConvertStringSidToSidW,
    SDDL_REVISION_1,
};
use windows::Win32::Security::{
    CheckTokenMembership, GetTokenInformation, PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES, TOKEN_QUERY,
    TOKEN_USER, TokenUser,
};
use windows::Win32::Storage::FileSystem::{
    BY_HANDLE_FILE_INFORMATION, CreateDirectoryW, FILE_FLAG_OPEN_REPARSE_POINT, GetDriveTypeW,
    GetFileInformationByHandle, GetLogicalDrives, GetVolumeInformationW,
};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::LibraryLoader::{
    GetModuleFileNameW, LOAD_LIBRARY_SEARCH_SYSTEM32, SetDefaultDllDirectories,
};
use windows::Win32::System::SystemInformation::{GetLocalTime, GetSystemDirectoryW, GetSystemWindowsDirectoryW};
use windows::Win32::System::TaskScheduler::{
    IRegisteredTask, ITaskFolder, ITaskService, TASK_ENUM_HIDDEN, TASK_STATE_RUNNING, TaskScheduler,
};
use windows::Win32::System::Threading::{
    CREATE_NO_WINDOW, CreateProcessW, GetCurrentProcess, GetCurrentProcessId, GetExitCodeProcess, INFINITE,
    OpenProcess, OpenProcessToken, PROCESS_CREATION_FLAGS, PROCESS_INFORMATION, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE, QueryFullProcessImageNameW,
    STARTUPINFOW, TerminateProcess, WaitForSingleObject,
};
use windows::Win32::System::Variant::{VARIANT, VT_I4};
use windows::Win32::UI::Shell::{
    FOLDERID_ProgramFiles, KF_FLAG_DEFAULT, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW,
    SHGetKnownFolderPath, ShellExecuteExW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    MB_ICONERROR, MB_ICONINFORMATION, MB_ICONWARNING, MB_OK, MESSAGEBOX_STYLE, MessageBoxW, SW_SHOWNORMAL,
};
use windows::core::{BOOL, BSTR, HSTRING, PCWSTR, PWSTR};
use windows_registry::{CURRENT_USER, Key, LOCAL_MACHINE, USERS};

use crate::bilan::Journal;
use crate::lieux::Lieux;
use crate::systeme::{DossierTaches, ErreurTache, Fin, LectureTaches, Ruche, Systeme};
use crate::texte::{commence_par, egal, sans_barre, t};

// ---------------------------------------------------------------------------------------------------------------------
// Petits outils
// ---------------------------------------------------------------------------------------------------------------------

/// Un texte Windows (UTF-16, terminé par un zéro) en texte Rust
fn texte(b: &[u16]) -> String {
    let n = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf16_lossy(&b[..n])
}

/// Un texte Rust pour Windows (UTF-16 terminé par un zéro)
fn large(s: &str) -> Vec<u16> {
    s.encode_utf16().chain([0]).collect()
}

/// Une poignée de Windows, refermée quand elle n'est plus utilisée
struct Poignee(HANDLE);

impl Drop for Poignee {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            // SAFETY : la poignée nous appartient et n'est refermée qu'ici
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}

/// Une mémoire donnée par Windows (LocalAlloc), rendue quand elle n'est plus utilisée
struct MemoireLocale(*mut core::ffi::c_void);

impl Drop for MemoireLocale {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY : mémoire allouée par Windows avec LocalAlloc, rendue une seule fois
            unsafe {
                let _ = LocalFree(Some(HLOCAL(self.0)));
            }
        }
    }
}

/// Le message d'une erreur de Windows, en clair (dans la langue de Windows)
fn message(e: &windows::core::Error) -> String {
    let m = e.message();
    let m = m.trim();
    if m.is_empty() { format!("erreur 0x{:08x}", e.code().0) } else { m.to_string() }
}

/// Un dossier de Windows lu par une fonction « GetXxxDirectoryW »
fn dossier_windows(f: unsafe fn(Option<&mut [u16]>) -> u32) -> String {
    let mut b = vec![0u16; 520];
    // SAFETY : tampon et taille cohérents
    let n = unsafe { f(Some(&mut b)) } as usize;
    if n == 0 || n >= b.len() { String::new() } else { texte(&b[..n]) }
}

/// C:\Windows\System32 (jamais par une variable d'environnement)
pub fn dossier_systeme() -> String {
    // SAFETY : enveloppe d'une fonction de Windows qui écrit dans le tampon donné
    dossier_windows(|b| unsafe { GetSystemDirectoryW(b) })
}

/// C:\Windows
fn dossier_windows_racine() -> String {
    // SAFETY : enveloppe d'une fonction de Windows qui écrit dans le tampon donné
    dossier_windows(|b| unsafe { GetSystemWindowsDirectoryW(b) })
}

// ---------------------------------------------------------------------------------------------------------------------
// Ce processus
// ---------------------------------------------------------------------------------------------------------------------

/// Les DLL ne sont plus cherchées que dans System32 (jamais dans le dossier courant ni dans le PATH de l'utilisateur)
pub fn proteger_chargement() {
    // SAFETY : réglage du processus, sans pointeur
    unsafe {
        let _ = SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32);
    }
}

/// Le chemin complet de ce programme
pub fn mon_exe() -> String {
    let mut b = vec![0u16; 32768];
    // SAFETY : tampon et taille cohérents
    let n = unsafe { GetModuleFileNameW(None, &mut b) } as usize;
    texte(&b[..n.min(b.len())])
}

pub fn mon_pid() -> u32 {
    // SAFETY : simple lecture
    unsafe { GetCurrentProcessId() }
}

/// Le compte de ce processus (SID en texte)
pub fn mon_sid() -> String {
    let mut j = HANDLE::default();
    // SAFETY : jeton de ce processus, lu puis refermé ; tampon de la taille annoncée par Windows
    unsafe {
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut j).is_err() {
            return String::new();
        }
        let j = Poignee(j);
        let mut n = 0u32;
        let _ = GetTokenInformation(j.0, TokenUser, None, 0, &mut n);
        if n == 0 {
            return String::new();
        }
        let mut b = vec![0u64; (n as usize).div_ceil(8)];
        if GetTokenInformation(j.0, TokenUser, Some(b.as_mut_ptr().cast()), n, &mut n).is_err() {
            return String::new();
        }
        let u = &*(b.as_ptr() as *const TOKEN_USER);
        let mut p = PWSTR::null();
        if ConvertSidToStringSidW(u.User.Sid, &mut p).is_err() {
            return String::new();
        }
        let _m = MemoireLocale(p.0.cast());
        p.to_string().unwrap_or_default()
    }
}

/// Lancé avec les droits administrateur ? (membre actif du groupe Administrateurs, comme IsInRole de .NET)
pub fn est_admin() -> bool {
    let mut sid = PSID::default();
    // SAFETY : SID créé par Windows et rendu par MemoireLocale ; vérification sur le jeton de ce processus
    unsafe {
        if ConvertStringSidToSidW(&HSTRING::from("S-1-5-32-544"), &mut sid).is_err() {
            return false;
        }
        let _m = MemoireLocale(sid.0);
        let mut membre = BOOL::default();
        CheckTokenMembership(None, sid, &mut membre).is_ok() && membre.as_bool()
    }
}

/// Se relance en administrateur (une demande de Windows). Erreur : (code de Windows, message) ; 1223 = refusée.
pub fn relancer_admin(exe: &str, arguments: &str) -> Result<(), (u32, String)> {
    let verbe = large("runas");
    let fichier = large(exe);
    let args = large(arguments);
    let dossier = large(&dossier_systeme());
    let mut info = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOASYNC | SEE_MASK_NOCLOSEPROCESS,
        lpVerb: PCWSTR(verbe.as_ptr()),
        lpFile: PCWSTR(fichier.as_ptr()),
        lpParameters: PCWSTR(args.as_ptr()),
        lpDirectory: PCWSTR(dossier.as_ptr()),
        nShow: SW_SHOWNORMAL.0,
        ..Default::default()
    };
    // SAFETY : structure remplie avec des textes qui vivent jusqu'à la fin de l'appel ; la poignée rendue est refermée
    unsafe {
        match ShellExecuteExW(&mut info) {
            Ok(()) => {
                let _p = Poignee(info.hProcess);
                Ok(())
            }
            Err(e) => Err(((e.code().0 as u32) & 0xFFFF, message(&e))),
        }
    }
}

/// Lance un programme sans attendre (ligne de commande complète donnée par `arguments`)
fn creer_processus(
    exe: &str,
    arguments: &str,
    dossier: &str,
    drapeaux: PROCESS_CREATION_FLAGS,
) -> Result<Poignee, String> {
    let appli = large(exe);
    let mut ligne = large(&format!("{} {arguments}", crate::texte::citer(exe)));
    let d = large(dossier);
    let si = STARTUPINFOW { cb: size_of::<STARTUPINFOW>() as u32, ..Default::default() };
    let mut pi = PROCESS_INFORMATION::default();
    // SAFETY : textes terminés par un zéro qui vivent jusqu'à la fin de l'appel ; poignées rendues refermées
    unsafe {
        CreateProcessW(
            PCWSTR(appli.as_ptr()),
            Some(PWSTR(ligne.as_mut_ptr())),
            None,
            None,
            false,
            drapeaux,
            None,
            PCWSTR(d.as_ptr()),
            &si,
            &mut pi,
        )
        .map_err(|e| message(&e))?;
        let _fil = Poignee(pi.hThread);
        Ok(Poignee(pi.hProcess))
    }
}

/// Lance la copie temporaire (sans attendre)
pub fn lancer(exe: &str, arguments: &str) -> Result<(), String> {
    creer_processus(exe, arguments, &dossier_systeme(), PROCESS_CREATION_FLAGS(0)).map(|_| ())
}

/// Attend la fin d'un processus (`ms` au plus)
pub fn attendre_processus(pid: u32, ms: u32) {
    // SAFETY : poignée ouverte pour attendre seulement, refermée par Poignee
    unsafe {
        if let Ok(h) = OpenProcess(PROCESS_SYNCHRONIZE, false, pid) {
            let h = Poignee(h);
            let _ = WaitForSingleObject(h.0, ms);
        }
    }
}

/// Un dossier neuf. `protege` : Administrateurs et système seulement, sans hériter des droits du dossier parent, posés
/// dès sa création (un programme sans droits ne peut pas y glisser un fichier qu'une copie administrateur chargerait)
pub fn creer_dossier(d: &Path, protege: bool) -> Result<(), String> {
    if !protege {
        return std::fs::create_dir(d).map_err(|e| e.to_string());
    }
    let nom = large(&t(d));
    let mut sd = PSECURITY_DESCRIPTOR::default();
    // SAFETY : descripteur créé par Windows, rendu par MemoireLocale ; textes terminés par un zéro
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            &HSTRING::from("D:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)"),
            SDDL_REVISION_1,
            &mut sd,
            None,
        )
        .map_err(|e| message(&e))?;
        let _m = MemoireLocale(sd.0);
        let sa = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: sd.0,
            bInheritHandle: false.into(),
        };
        CreateDirectoryW(PCWSTR(nom.as_ptr()), Some(&sa)).map_err(|e| message(&e))
    }
}

/// La copie temporaire se supprime une fois finie (par l'invite de commandes, quelques secondes après)
pub fn supprimer_copie(copie: &str) {
    let Some(dossier) = Path::new(copie).parent() else { return };
    let nom = dossier.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if !commence_par(&nom, "Mindset-desinstallation-") {
        return;
    }
    let cmd = format!("{}\\cmd.exe", dossier_systeme());
    let args = format!("/c ping -n 4 127.0.0.1 >nul & rd /s /q {}", crate::texte::citer(&t(dossier)));
    let _ = creer_processus(&cmd, &args, &dossier_systeme(), CREATE_NO_WINDOW);
}

/// Huit chiffres hexadécimaux au hasard (le nom du dossier de la copie)
pub fn hasard() -> String {
    let g = windows::core::GUID::new().unwrap_or_default();
    format!("{:08x}", g.data1)
}

#[derive(Debug, Clone, Copy)]
pub enum Icone {
    Erreur,
    Information,
    Avertissement,
}

/// Un message à l'écran, avec le bouton OK
pub fn message_ecran(texte_message: &str, icone: Icone) {
    let style: MESSAGEBOX_STYLE = match icone {
        Icone::Erreur => MB_ICONERROR,
        Icone::Information => MB_ICONINFORMATION,
        Icone::Avertissement => MB_ICONWARNING,
    };
    // SAFETY : textes terminés par un zéro
    unsafe {
        MessageBoxW(None, &HSTRING::from(texte_message), &HSTRING::from("Désinstaller Mindset"), MB_OK | style);
    }
}

/// La date et l'heure locales au format « s » de .NET (2026-10-27T14:05:09)
fn maintenant() -> String {
    // SAFETY : simple lecture
    let s = unsafe { GetLocalTime() };
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}", s.wYear, s.wMonth, s.wDay, s.wHour, s.wMinute, s.wSecond)
}

/// Le journal : une ligne datée par appel, ajoutée au fichier. Jamais au travers d'un lien, ni dans un fichier qui a
/// plusieurs noms (lien « dur ») : sinon la ligne est simplement perdue (rien d'important n'est que dans le journal).
pub fn journal_vers(fichier: PathBuf) -> Journal {
    Box::new(move |ligne: &str| {
        let Ok(mut f) = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
            .open(&fichier)
        else {
            return;
        };
        let Ok(m) = f.metadata() else { return };
        if m.file_attributes() & 0x400 != 0 {
            return;
        }
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        // SAFETY : poignée du fichier ouvert juste au-dessus, structure de la bonne taille
        let ok = unsafe { GetFileInformationByHandle(HANDLE(f.as_raw_handle()), &mut info) }.is_ok();
        if !ok || info.nNumberOfLinks != 1 {
            return;
        }
        use std::io::Write;
        let _ = f.write_all(format!("{} {ligne}\r\n", maintenant()).as_bytes());
    })
}

// ---------------------------------------------------------------------------------------------------------------------
// Les vrais emplacements
// ---------------------------------------------------------------------------------------------------------------------

/// Un chemin local complet (« C:\... »), sans variable à développer ni « .. »
fn chemin_local(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 3
        && b[0].is_ascii_alphabetic()
        && b[1] == b':'
        && b[2] == b'\\'
        && !s.contains('%')
        && !s.split('\\').any(|m| m == "..")
}

/// Une valeur texte du registre (vide si absente ou illisible)
fn valeur(base: &Key, cle: &str, nom: &str) -> String {
    base.open(cle).and_then(|k| k.get_string(nom)).unwrap_or_default()
}

/// Program Files : HKLM (ProgramFilesDir, vue 64 bits : ce programme est en 64 bits), sinon Windows lui-même
fn program_files(lecteur: &str) -> PathBuf {
    let v = valeur(LOCAL_MACHINE, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion", "ProgramFilesDir");
    if chemin_local(&v) {
        return PathBuf::from(v);
    }
    // SAFETY : texte rendu par Windows, libéré avec CoTaskMemFree par windows::core
    let connu = unsafe { SHGetKnownFolderPath(&FOLDERID_ProgramFiles, KF_FLAG_DEFAULT, None) }
        .ok()
        .map(|p| {
            // SAFETY : texte terminé par un zéro rendu par Windows, libéré juste après
            let s = unsafe { p.to_string() }.unwrap_or_default();
            // SAFETY : mémoire donnée par SHGetKnownFolderPath
            unsafe { windows::Win32::System::Com::CoTaskMemFree(Some(p.0.cast())) };
            s
        })
        .unwrap_or_default();
    if chemin_local(&connu) { PathBuf::from(connu) } else { PathBuf::from(format!("{lecteur}\\Program Files")) }
}

/// Le dossier de profil d'un compte, lu dans HKLM (ProfileList : seul un administrateur peut le changer)
fn profil(sid: &str, lecteur: &str) -> Option<String> {
    let v = valeur(
        LOCAL_MACHINE,
        &format!("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\{sid}"),
        "ProfileImagePath",
    );
    // (REG_EXPAND_SZ : seul %SystemDrive% y est remplacé, par le disque de Windows)
    let v = remplacer_sans_casse(&v, "%SystemDrive%", lecteur);
    let v = sans_barre(&v).to_string();
    chemin_local(&v).then_some(v)
}

fn remplacer_sans_casse(s: &str, motif: &str, par: &str) -> String {
    match s.to_lowercase().find(&motif.to_lowercase()) {
        Some(i) if s.is_char_boundary(i) && s.is_char_boundary(i + motif.len()) => {
            format!("{}{par}{}", &s[..i], &s[i + motif.len()..])
        }
        _ => s.to_string(),
    }
}

/// Un dossier de l'utilisateur, accepté seulement dans son profil et sans lien (jonction, lien symbolique) en route
/// entre son profil et lui (les dossiers synchronisés de OneDrive restent acceptés : ce ne sont pas des liens)
pub fn dossier_dans_profil(chemin: &str, profil: &str) -> bool {
    if !chemin_local(chemin) || !(crate::texte::dans(chemin, profil) || egal(sans_barre(chemin), profil)) {
        return false;
    }
    let reste = &sans_barre(chemin)[profil.len().min(sans_barre(chemin).len())..];
    let mut courant = PathBuf::from(profil);
    for morceau in reste.split('\\').filter(|m| !m.is_empty()) {
        courant.push(morceau);
        match std::fs::symlink_metadata(&courant) {
            Ok(m) if m.file_type().is_symlink() => return false,
            Ok(_) => {}
            Err(_) => break, // (pas encore créé : rien à suivre au-delà)
        }
    }
    true
}

/// Les disques fixes prêts (« C:\ », « D:\ »...)
fn disques_fixes() -> Vec<PathBuf> {
    let mut r = Vec::new();
    // SAFETY : simple lecture
    let masque = unsafe { GetLogicalDrives() };
    for i in 0..26u8 {
        if masque & (1 << i) == 0 {
            continue;
        }
        let racine = format!("{}:\\", char::from(b'A' + i));
        let w = large(&racine);
        // SAFETY : texte terminé par un zéro ; volume interrogé sans tampon (seulement « prêt ou non »)
        unsafe {
            if GetDriveTypeW(PCWSTR(w.as_ptr())) == 3 /* DRIVE_FIXED */
                && GetVolumeInformationW(PCWSTR(w.as_ptr()), None, None, None, None, None).is_ok()
            {
                r.push(PathBuf::from(racine));
            }
        }
    }
    r
}

/// Les vrais emplacements, pour l'utilisateur `sid` (celui qui a lancé la désinstallation ; None : ce compte-ci)
pub fn lieux_reels(sid: Option<&str>) -> (Lieux, Windows) {
    let moi = mon_sid();
    let cible = sid.unwrap_or(&moi).to_string();
    let windir = dossier_windows_racine();
    let lecteur = if windir.len() >= 2 { windir[..2].to_string() } else { "C:".to_string() };
    let autre = !egal(&cible, &moi);
    // La ruche de l'utilisateur : la sienne s'il s'est relancé en administrateur avec un autre compte
    let utilisateur = if autre && USERS.open(&cible).is_ok() { Some(cible.clone()) } else { None };
    let sys = Windows { test: false, utilisateur };
    let mut l = Lieux {
        test: false,
        program_files: program_files(&lecteur),
        temp: PathBuf::from(format!("{}\\Temp", sans_barre(&windir))),
        disques: disques_fixes(),
        cle_desinstall: "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Mindset".into(),
        cle_mindset: "SOFTWARE\\Mindset".into(),
        cle_run: "Software\\Microsoft\\Windows\\CurrentVersion\\Run".into(),
        dossier_taches: "\\Mindset".into(),
        ..Lieux::default()
    };
    if let Some(p) = profil(&cible, &lecteur) {
        let dossiers = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders";
        let lu = |nom: &str| -> String {
            match &sys.utilisateur {
                Some(s) => USERS.open(s).map(|k| valeur(&k, dossiers, nom)).unwrap_or_default(),
                None => valeur(CURRENT_USER, dossiers, nom),
            }
        };
        let choisir = |nom: &str, defaut: &str| -> PathBuf {
            let v = lu(nom);
            if dossier_dans_profil(&v, &p) { PathBuf::from(v) } else { PathBuf::from(format!("{p}\\{defaut}")) }
        };
        l.local_app_data = Some(choisir("Local AppData", "AppData\\Local"));
        l.bureau = Some(choisir("Desktop", "Desktop"));
        l.menu = Some(choisir("Programs", "AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs"));
    }
    (l, sys)
}

/// Le système de test (construction d'essai) : le vrai Windows, mais le registre vient de HKCU\Software\MindsetTest-...
#[cfg(feature = "essai")]
pub fn systeme_de_test() -> Windows {
    Windows { test: true, utilisateur: None }
}

// ---------------------------------------------------------------------------------------------------------------------
// Le vrai Windows derrière le trait Systeme
// ---------------------------------------------------------------------------------------------------------------------

pub struct Windows {
    /// Faux environnement : les deux ruches sont HKCU (clé de test)
    test: bool,
    /// La ruche HKU\<sid> de l'utilisateur, s'il n'est pas ce compte-ci
    utilisateur: Option<String>,
}

/// Erreur de Windows « introuvable » (fichier ou chemin)
fn introuvable(e: &windows::core::Error) -> bool {
    matches!(e.code().0 as u32, 0x8007_0002 | 0x8007_0003)
}

impl Windows {
    fn avec_ruche<R>(&self, ruche: Ruche, f: impl FnOnce(&Key) -> R) -> Result<R, String> {
        if self.test {
            return Ok(f(CURRENT_USER));
        }
        match (ruche, &self.utilisateur) {
            (Ruche::Machine, _) => Ok(f(LOCAL_MACHINE)),
            (Ruche::Utilisateur, None) => Ok(f(CURRENT_USER)),
            (Ruche::Utilisateur, Some(s)) => USERS.open(s).map(|k| f(&k)).map_err(|e| message(&e)),
        }
    }
}

/// Un VARIANT nombre entier (index d'une collection)
fn index(i: i32) -> VARIANT {
    let mut v = VARIANT::default();
    // SAFETY : écriture du type et de la valeur correspondante
    unsafe {
        let a = &mut *v.Anonymous.Anonymous;
        a.vt = VT_I4;
        a.Anonymous.lVal = i;
    }
    v
}

/// Le Planificateur de tâches, connecté (COM prêt sur ce fil)
fn planificateur() -> Result<ITaskService, String> {
    // SAFETY : initialisation de COM pour ce fil (déjà faite : sans effet) puis création d'un objet du système
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let s: ITaskService = CoCreateInstance(&TaskScheduler, None, CLSCTX_INPROC_SERVER).map_err(|e| message(&e))?;
        let vide = VARIANT::default();
        s.Connect(&vide, &vide, &vide, &vide).map_err(|e| message(&e))?;
        Ok(s)
    }
}

fn dossier_de(s: &ITaskService, chemin: &str) -> windows::core::Result<ITaskFolder> {
    // SAFETY : appel COM ordinaire
    unsafe { s.GetFolder(&BSTR::from(chemin)) }
}

fn erreur_tache(e: &windows::core::Error) -> ErreurTache {
    ErreurTache { absent: introuvable(e), message: message(e) }
}

impl Systeme for Windows {
    fn mon_pid(&self) -> u32 {
        mon_pid()
    }

    fn processus(&self) -> Vec<(u32, String)> {
        let mut pids = Vec::new();
        // SAFETY : instantané refermé par Poignee ; structure initialisée avec sa taille
        unsafe {
            if let Ok(h) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) {
                let h = Poignee(h);
                let mut e = PROCESSENTRY32W { dwSize: size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
                let mut ok = Process32FirstW(h.0, &mut e).is_ok();
                while ok {
                    pids.push(e.th32ProcessID);
                    ok = Process32NextW(h.0, &mut e).is_ok();
                }
            }
        }
        pids.into_iter().filter(|&p| p > 4).filter_map(|p| chemin_processus(p).map(|c| (p, c))).collect()
    }

    fn ligne_commande(&self, pid: u32) -> Option<String> {
        // SAFETY : poignée refermée par Poignee ; tampon de la taille demandée par Windows, aligné, qui commence par
        // un UNICODE_STRING dont le texte est dans ce même tampon
        unsafe {
            let h = Poignee(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?);
            let classe = PROCESSINFOCLASS(60); // ProcessCommandLineInformation
            let mut requis = 0u32;
            let _ = NtQueryInformationProcess(h.0, classe, std::ptr::null_mut(), 0, &mut requis);
            if requis == 0 || requis > 1024 * 1024 {
                return None;
            }
            let mut b = vec![0u64; (requis as usize).div_ceil(8)];
            if NtQueryInformationProcess(h.0, classe, b.as_mut_ptr().cast(), requis, &mut requis).is_err() {
                return None;
            }
            let u = &*(b.as_ptr() as *const windows::Win32::Foundation::UNICODE_STRING);
            if u.Buffer.is_null() {
                return Some(String::new());
            }
            let n = usize::from(u.Length / 2);
            Some(String::from_utf16_lossy(std::slice::from_raw_parts(u.Buffer.0, n)))
        }
    }

    fn fermer(&self, pid: u32, attente: Duration) -> Result<(), String> {
        // SAFETY : poignée ouverte avec le droit de fermer et d'attendre, refermée par Poignee
        unsafe {
            let h = Poignee(OpenProcess(PROCESS_TERMINATE | PROCESS_SYNCHRONIZE, false, pid).map_err(|e| message(&e))?);
            TerminateProcess(h.0, u32::MAX).map_err(|e| message(&e))?;
            let _ = WaitForSingleObject(h.0, attente.as_millis().min(u128::from(INFINITE - 1)) as u32);
        }
        Ok(())
    }

    fn tourne_nomme(&self, nom: &str) -> bool {
        // SAFETY : instantané refermé par Poignee ; structure initialisée avec sa taille
        unsafe {
            let Ok(h) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return false };
            let h = Poignee(h);
            let mut e = PROCESSENTRY32W { dwSize: size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
            let mut ok = Process32FirstW(h.0, &mut e).is_ok();
            while ok {
                let n = texte(&e.szExeFile);
                let tige = n.strip_suffix(".exe").or_else(|| n.strip_suffix(".EXE")).unwrap_or(&n);
                if egal(tige, nom) {
                    return true;
                }
                ok = Process32NextW(h.0, &mut e).is_ok();
            }
        }
        false
    }

    fn lancer_et_attendre(&self, exe: &Path, argument: &str, dossier: &Path, limite: Duration) -> Result<Fin, String> {
        let h = creer_processus(&t(exe), argument, &t(dossier), PROCESS_CREATION_FLAGS(0))?;
        // SAFETY : poignée du processus lancé, à nous
        unsafe {
            if WaitForSingleObject(h.0, limite.as_millis().min(u128::from(INFINITE - 1)) as u32) != WAIT_OBJECT_0 {
                return Ok(Fin::TropLong);
            }
            let mut code = 0u32;
            GetExitCodeProcess(h.0, &mut code).map_err(|e| message(&e))?;
            Ok(Fin::Code(code as i32))
        }
    }

    fn nom_ruche(&self, ruche: Ruche) -> String {
        match (self.test, ruche, &self.utilisateur) {
            (true, _, _) => "HKEY_CURRENT_USER".into(),
            (false, Ruche::Machine, _) => "HKEY_LOCAL_MACHINE".into(),
            (false, Ruche::Utilisateur, None) => "HKEY_CURRENT_USER".into(),
            (false, Ruche::Utilisateur, Some(s)) => format!("HKEY_USERS\\{s}"),
        }
    }

    fn cle_existe(&self, ruche: Ruche, cle: &str) -> Result<bool, String> {
        self.avec_ruche(ruche, |b| match b.open(cle) {
            Ok(_) => Ok(true),
            Err(e) if introuvable(&e) => Ok(false),
            Err(e) => Err(message(&e)),
        })?
    }

    fn supprimer_cle(&self, ruche: Ruche, cle: &str) -> Result<(), String> {
        self.avec_ruche(ruche, |b| b.remove_tree(cle).map_err(|e| message(&e)))?
    }

    fn valeur_existe(&self, ruche: Ruche, cle: &str, nom: &str) -> Result<bool, String> {
        self.avec_ruche(ruche, |b| match b.open(cle) {
            Err(e) if introuvable(&e) => Ok(false),
            Err(e) => Err(message(&e)),
            Ok(k) => match k.get_type(nom) {
                Ok(_) => Ok(true),
                Err(e) if introuvable(&e) => Ok(false),
                Err(e) => Err(message(&e)),
            },
        })?
    }

    fn supprimer_valeur(&self, ruche: Ruche, cle: &str, nom: &str) -> Result<(), String> {
        self.avec_ruche(ruche, |b| {
            b.options().read().write().open(cle).and_then(|k| k.remove_value(nom)).map_err(|e| message(&e))
        })?
    }

    fn ecrire_texte_si_cle(&self, ruche: Ruche, cle: &str, nom: &str, valeur: &str) -> Result<(), String> {
        self.avec_ruche(ruche, |b| match b.options().read().write().open(cle) {
            Err(e) if introuvable(&e) => Ok(()),
            Err(e) => Err(message(&e)),
            Ok(k) => k.set_string(nom, valeur).map_err(|e| message(&e)),
        })?
    }

    fn dossier_taches(&self, chemin: &str) -> Result<Option<DossierTaches>, LectureTaches> {
        let s = planificateur().map_err(LectureTaches::Connexion)?;
        let f = match dossier_de(&s, chemin) {
            Ok(f) => f,
            Err(e) if introuvable(&e) => return Ok(None),
            Err(e) => return Err(LectureTaches::Erreur(message(&e))),
        };
        let mut r = DossierTaches::default();
        // SAFETY : appels COM ordinaires ; un élément illisible est passé
        unsafe {
            if let Ok(sous) = f.GetFolders(0) {
                for i in 1..=sous.Count().unwrap_or(0) {
                    if let Ok(x) = sous.get_Item(&index(i)) {
                        let n = x.Name().map(|b| b.to_string()).unwrap_or_default();
                        let p = x.Path().map(|b| b.to_string()).unwrap_or_default();
                        r.sous_dossiers.push((n, p));
                    }
                }
            }
            let taches = f.GetTasks(TASK_ENUM_HIDDEN.0).map_err(|e| LectureTaches::Erreur(message(&e)))?;
            for i in 1..=taches.Count().unwrap_or(0) {
                if let Ok(x) = taches.get_Item(&index(i)) {
                    let n = x.Name().map(|b| b.to_string()).unwrap_or_default();
                    let p = x.Path().map(|b| b.to_string()).unwrap_or_default();
                    r.taches.push((n, p));
                }
            }
        }
        Ok(Some(r))
    }

    fn arreter_tache(&self, chemin: &str) {
        let Ok(s) = planificateur() else { return };
        let (dossier, nom) = match chemin.rfind('\\') {
            Some(0) => ("\\", &chemin[1..]),
            Some(i) => (&chemin[..i], &chemin[i + 1..]),
            None => return,
        };
        // SAFETY : appels COM ordinaires
        unsafe {
            let Ok(f) = dossier_de(&s, dossier) else { return };
            let Ok(tache): windows::core::Result<IRegisteredTask> = f.GetTask(&BSTR::from(nom)) else { return };
            if tache.State().is_ok_and(|e| e == TASK_STATE_RUNNING) {
                let _ = tache.Stop(0);
            }
        }
    }

    fn supprimer_tache(&self, dossier: &str, nom: &str) -> Result<(), ErreurTache> {
        let s = planificateur().map_err(|m| ErreurTache { absent: false, message: m })?;
        let f = dossier_de(&s, dossier).map_err(|e| erreur_tache(&e))?;
        // SAFETY : appel COM ordinaire
        unsafe { f.DeleteTask(&BSTR::from(nom), 0) }.map_err(|e| erreur_tache(&e))
    }

    fn supprimer_dossier_taches(&self, parent: &str, nom: &str) -> Result<(), ErreurTache> {
        let s = planificateur().map_err(|m| ErreurTache { absent: false, message: m })?;
        let f = dossier_de(&s, parent).map_err(|e| erreur_tache(&e))?;
        // SAFETY : appel COM ordinaire
        unsafe { f.DeleteFolder(&BSTR::from(nom), 0) }.map_err(|e| erreur_tache(&e))
    }
}

/// Le chemin complet du programme d'un processus (None si Windows ne le dit pas)
fn chemin_processus(pid: u32) -> Option<String> {
    // SAFETY : poignée refermée par Poignee ; tampon et taille cohérents
    unsafe {
        let h = Poignee(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?);
        let mut b = vec![0u16; 32768];
        let mut n = b.len() as u32;
        QueryFullProcessImageNameW(h.0, PROCESS_NAME_WIN32, PWSTR(b.as_mut_ptr()), &mut n).ok()?;
        Some(String::from_utf16_lossy(&b[..n as usize]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chemins_locaux() {
        assert!(chemin_local("C:\\Program Files"));
        assert!(!chemin_local("%ProgramFiles%"));
        assert!(!chemin_local("\\\\serveur\\partage"));
        assert!(!chemin_local("C:\\Users\\x\\..\\..\\Windows"));
        assert!(!chemin_local("C:"));
        assert_eq!(remplacer_sans_casse("%SYSTEMDRIVE%\\Users\\x", "%SystemDrive%", "D:"), "D:\\Users\\x");
    }

    /// Les vrais emplacements de ce compte (lecture seule du registre : rien n'est changé, rien n'est lancé). Sur la
    /// machine de GitHub, ce test montre ce que valent ProfileList (%SystemDrive% ou non) et les « Shell Folders ».
    #[test]
    fn lieux_reels_de_ce_compte() {
        let moi = mon_sid();
        let windir = dossier_windows_racine();
        let brut = valeur(
            LOCAL_MACHINE,
            &format!(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{moi}"),
            "ProfileImagePath",
        );
        let (l, _) = lieux_reels(None);
        println!("ProfileImagePath brut : {brut}");
        println!("Program Files : {}", t(&l.program_files));
        println!(
            "LocalAppData : {:?}
Bureau : {:?}
Menu : {:?}",
            l.local_app_data, l.bureau, l.menu
        );
        println!(
            "Temp : {}
Disques : {:?}",
            t(&l.temp),
            l.disques
        );
        assert!(l.program_files.is_dir());
        assert!(l.temp.is_dir() && commence_par(&t(&l.temp), &windir));
        let p = profil(&moi, &windir[..2]).expect("profil lu dans ProfileList");
        for d in [&l.local_app_data, &l.bureau, &l.menu] {
            let d = t(d.as_ref().expect("dossier de l'utilisateur"));
            assert!(crate::texte::dans(&d, &p), "{d} hors de {p}");
        }
        assert!(l.local_app_data.as_ref().unwrap().is_dir());
        assert!(!l.disques.is_empty());
    }

    /// Un dossier du shell que l'utilisateur ferait pointer hors de son profil, ou au travers d'une jonction, est refusé
    #[test]
    fn dossiers_du_shell_seulement_dans_le_profil() {
        let base = std::env::temp_dir().join(format!("desinst-profil-{}", std::process::id()));
        let profil = base.join("Profil");
        let ailleurs = base.join("Ailleurs");
        std::fs::create_dir_all(profil.join("OneDrive").join("Bureau")).unwrap();
        std::fs::create_dir_all(&ailleurs).unwrap();
        let p = t(&profil);
        assert!(dossier_dans_profil(&format!("{p}\\Desktop"), &p)); // pas encore créé : accepté
        assert!(dossier_dans_profil(&format!("{p}\\OneDrive\\Bureau"), &p));
        assert!(!dossier_dans_profil(&t(&ailleurs), &p));
        assert!(!dossier_dans_profil(&format!("{p}\\..\\Ailleurs"), &p));
        assert!(!dossier_dans_profil(&format!("{p}x\\Desktop"), &p));
        assert!(!dossier_dans_profil("%USERPROFILE%\\Desktop", &p));
        // Une jonction dans le profil, vers un autre dossier : refusée, et tout ce qui est derrière aussi
        let jonction = profil.join("Lien");
        let sortie = std::process::Command::new(format!("{}\\cmd.exe", dossier_systeme()))
            .args(["/c", "mklink", "/J", &t(&jonction), &t(&ailleurs)])
            .output()
            .unwrap();
        assert!(sortie.status.success());
        assert!(!dossier_dans_profil(&t(&jonction), &p));
        assert!(!dossier_dans_profil(&format!("{}\\Desktop", t(&jonction)), &p));
        let _ = std::fs::remove_dir(&jonction);
        let _ = std::fs::remove_dir_all(&base);
    }
}
