//! Le seul module qui parle à Windows (et le seul où le code « unsafe » est permis). Il remplit le trait `Systeme`
//! avec les vrais appels ; les règles et les actions (la bibliothèque) n'en savent rien.
//!
//! Rien n'est lu chez l'utilisateur : ni variables d'environnement (les dossiers viennent de Windows), ni « dossiers
//! du shell ». Les programmes de Windows lancés (schtasks, icacls) reçoivent un environnement neuf, fait ici.

#![allow(unsafe_code)]

mod outils;
mod processus;
mod securite;
mod taches;

use std::os::windows::process::CommandExt;

use mindset_installateur::systeme::{
    ActionTache, Disque, Droits, NouvelleTache, Processus, Systeme, TacheVue, ValeurRegistre,
};
use outils::texte;
use windows::Win32::Storage::FileSystem::{
    GetDriveTypeW, GetVolumeInformationW, MOVEFILE_DELAY_UNTIL_REBOOT, MoveFileExW,
};
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoTaskMemFree, CoUninitialize};
use windows::Win32::System::LibraryLoader::{
    GetModuleFileNameW, LOAD_LIBRARY_SEARCH_SYSTEM32, SetDefaultDllDirectories,
};
use windows::Win32::System::SystemInformation::{GetSystemDirectoryW, GetSystemWindowsDirectoryW};
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::Shell::{FOLDERID_ProgramFiles, KF_FLAG_DEFAULT, SHGetKnownFolderPath};
use windows::Win32::UI::WindowsAndMessaging::{MB_ICONWARNING, MB_OK, MB_SETFOREGROUND, MessageBoxW};
use windows::core::{GUID, HSTRING, PCWSTR};
use windows_registry::LOCAL_MACHINE;

/// COM prêt pour ce processus tant que la valeur vit
pub struct Preparation {
    com: bool,
}

impl Drop for Preparation {
    fn drop(&mut self) {
        if self.com {
            // SAFETY : CoInitializeEx a réussi sur ce fil
            unsafe { CoUninitialize() };
        }
    }
}

/// Prépare le processus avant toute chose : les DLL ne sont cherchées que dans System32, le dossier courant devient
/// System32, et COM est prêt. Rend ce qui doit vivre jusqu'à la fin.
pub fn preparer_processus() -> Preparation {
    // SAFETY : réglages du processus, avant tout autre appel
    let com = unsafe {
        let _ = SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32);
        CoInitializeEx(None, COINIT_MULTITHREADED).is_ok()
    };
    let _ = std::env::set_current_dir(dossier_systeme());
    Preparation { com }
}

fn dossier_systeme() -> String {
    let mut b = vec![0u16; 1024];
    // SAFETY : tampon et taille cohérents
    let n = unsafe { GetSystemDirectoryW(Some(&mut b)) } as usize;
    String::from_utf16_lossy(&b[..n.min(b.len())]).trim_end_matches('\\').to_string()
}

/// Un dossier connu de Windows (Program Files...), lu par Windows et jamais dans les variables d'environnement
fn dossier_connu(id: &GUID) -> String {
    // SAFETY : texte rendu par Windows, libéré avec CoTaskMemFree
    unsafe {
        match SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None) {
            Ok(p) => {
                let s = p.to_string().unwrap_or_default();
                CoTaskMemFree(Some(p.0 as *const core::ffi::c_void));
                s
            }
            Err(_) => String::new(),
        }
    }
}

/// Le PC, tel que Windows le décrit
pub struct Windows {
    windows: String,
    systeme: String,
    programmes: String,
    exe: String,
    pid: u32,
}

impl Windows {
    pub fn new() -> Windows {
        let mut b = vec![0u16; 1024];
        let mut e = vec![0u16; 32768];
        // SAFETY : tampons et tailles cohérents
        let (windows, exe) = unsafe {
            let n = GetSystemWindowsDirectoryW(Some(&mut b)) as usize;
            let w = String::from_utf16_lossy(&b[..n.min(b.len())]);
            let n = GetModuleFileNameW(None, &mut e) as usize;
            (w, String::from_utf16_lossy(&e[..n.min(e.len())]))
        };
        Windows {
            windows: windows.trim_end_matches('\\').to_string(),
            systeme: dossier_systeme(),
            programmes: dossier_connu(&FOLDERID_ProgramFiles),
            exe,
            // SAFETY : simple lecture
            pid: unsafe { GetCurrentProcessId() },
        }
    }

    /// Un programme de System32 (schtasks, icacls), sans fenêtre, avec un environnement neuf ; rend son code de sortie
    fn lancer_systeme(&self, exe: &str, arguments: &[&str]) -> i32 {
        let w = &self.windows;
        let mut c = std::process::Command::new(format!(r"{}\{exe}", self.systeme));
        c.args(arguments)
            .env_clear()
            .env("SystemRoot", w)
            .env("windir", w)
            .env("SystemDrive", w.get(..2).unwrap_or("C:"))
            .env("ComSpec", format!(r"{}\cmd.exe", self.systeme))
            .env("PATH", format!(r"{0};{w};{0}\Wbem", self.systeme))
            .current_dir(&self.systeme)
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        c.status().ok().and_then(|s| s.code()).unwrap_or(-1)
    }
}

impl Systeme for Windows {
    fn dossier_windows(&self) -> String {
        self.windows.clone()
    }
    fn dossier_systeme(&self) -> String {
        self.systeme.clone()
    }
    fn dossier_programmes(&self) -> String {
        self.programmes.clone()
    }
    fn exe_courant(&self) -> String {
        self.exe.clone()
    }

    fn sid_courant(&self) -> String {
        securite::compte_courant()
    }
    fn sid_de_compte(&self, compte: &str) -> Option<String> {
        securite::sid_de_nom(compte)
    }
    fn compte_de_sid(&self, sid: &str) -> Option<String> {
        securite::nom_de_sid(sid)
    }
    fn profil_brut(&self, sid: &str) -> Option<String> {
        let k = LOCAL_MACHINE.open(format!(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{sid}")).ok()?;
        // (sans remplacer %SystemDrive% : c'est fait par l'installateur, avec les dossiers de Windows)
        k.get_hstring("ProfileImagePath").ok().map(|h| h.to_string_lossy())
    }

    fn disque(&self, lettre: char) -> Option<Disque> {
        let racine = HSTRING::from(format!(r"{lettre}:\"));
        let mut fs = [0u16; 64];
        // SAFETY : chemin et tampon cohérents
        unsafe {
            let genre = GetDriveTypeW(&racine);
            if genre <= 1 {
                return None; // DRIVE_UNKNOWN, DRIVE_NO_ROOT_DIR : pas de disque à cette lettre
            }
            let _ = GetVolumeInformationW(&racine, None, None, None, None, Some(&mut fs));
            Some(Disque { genre, systeme_fichiers: texte(&fs) })
        }
    }
    fn droits(&self, dossier: &str) -> Option<Droits> {
        securite::droits(dossier)
    }
    fn poser_droits_racine(&mut self, dossier: &str) -> Result<(), String> {
        // Administrateurs propriétaires ; administrateurs et système en contrôle total, utilisateurs en lecture
        // (ReadAndExecute), hérité par tout ce qui est dessous ; rien du disque
        securite::poser_sddl(dossier, "O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)")
    }
    fn reprendre_droits_herites(&mut self, dossier: &str) {
        let _ = self.lancer_systeme("icacls.exe", &[dossier, "/reset", "/T", "/C", "/Q"]);
    }
    fn poser_proprietaire_admins(&mut self, dossier: &str) -> Result<(), String> {
        securite::poser_proprietaire(dossier, "S-1-5-32-544")
    }
    fn ajouter_droit_modifier(&mut self, dossier: &str, sid: &str) -> Result<(), String> {
        // « Modify » : lire, écrire, supprimer, exécuter
        securite::ajouter_droit(dossier, sid, 0x0013_01BF)
    }

    fn registre_lire(&self, cle: &str, nom: &str) -> Option<String> {
        LOCAL_MACHINE.open(cle).ok()?.get_string(nom).ok()
    }
    fn registre_existe(&self, cle: &str) -> bool {
        LOCAL_MACHINE.open(cle).is_ok()
    }
    fn registre_creer(&mut self, cle: &str) -> Result<(), String> {
        LOCAL_MACHINE.create(cle).map(|_| ()).map_err(|e| outils::message(&e))
    }
    fn registre_ecrire(&mut self, cle: &str, nom: &str, valeur: &ValeurRegistre) -> Result<(), String> {
        // (la clé doit exister, comme Set-ItemProperty)
        let k = LOCAL_MACHINE.options().read().write().open(cle).map_err(|e| outils::message(&e))?;
        match valeur {
            ValeurRegistre::Texte(t) => k.set_string(nom, t),
            ValeurRegistre::Nombre(n) => k.set_u32(nom, *n),
        }
        .map_err(|e| outils::message(&e))
    }
    fn registre_supprimer(&mut self, cle: &str) -> Result<(), String> {
        LOCAL_MACHINE.remove_tree(cle).map_err(|e| outils::message(&e))
    }

    fn taches(&self, dossier: Option<&str>) -> Vec<TacheVue> {
        taches::taches(dossier)
    }
    fn tache(&self, dossier: &str, nom: &str) -> Option<TacheVue> {
        taches::tache(dossier, nom)
    }
    fn enregistrer_tache(&mut self, tache: &NouvelleTache) -> Result<(), String> {
        taches::enregistrer(tache)
    }
    fn droits_tache(&mut self, nom: &str, sddl: &str) -> Result<(), String> {
        taches::droits(nom, sddl)
    }
    fn retirer_tache(&mut self, dossier: &str, nom: &str) {
        taches::retirer(dossier, nom);
    }
    fn retirer_dossier_taches(&mut self, nom: &str) {
        taches::retirer_dossier(nom);
    }
    fn modifier_actions(&mut self, dossier: &str, nom: &str, actions: &[ActionTache]) -> Result<(), String> {
        taches::modifier_actions(dossier, nom, actions)
    }
    fn lancer_tache(&mut self, chemin: &str) -> i32 {
        self.lancer_systeme("schtasks.exe", &["/Run", "/TN", chemin])
    }

    fn pid(&self) -> u32 {
        self.pid
    }
    fn session(&self) -> u32 {
        processus::session(self.pid)
    }
    fn processus(&self) -> Vec<Processus> {
        processus::liste()
    }
    fn proprietaire_processus(&self, id: u32) -> Option<String> {
        processus::compte(id)
    }
    fn arreter(&mut self, p: &Processus) {
        processus::arreter(p.id);
    }
    fn attendre_fin(&mut self, pid: i32, secondes: u32) {
        if let Ok(pid) = u32::try_from(pid) {
            processus::attendre(pid, secondes.saturating_mul(1000));
        }
    }
    fn pause(&mut self, millisecondes: u64) {
        std::thread::sleep(std::time::Duration::from_millis(millisecondes));
    }
    fn lancer_par_explorateur(&mut self, programme: &str) {
        // (l'Explorateur déjà ouvert dans la session lance le programme avec les droits de l'utilisateur)
        let _ = std::process::Command::new(format!(r"{}\explorer.exe", self.windows))
            .raw_arg(format!("\"{programme}\""))
            .spawn();
    }
    fn fenetre(&mut self, texte: &str, titre: &str) {
        // SAFETY : textes valables pendant l'appel
        unsafe {
            let _ = MessageBoxW(
                None,
                &HSTRING::from(texte),
                &HSTRING::from(titre),
                MB_OK | MB_ICONWARNING | MB_SETFOREGROUND,
            );
        }
    }
    fn effacer_au_redemarrage(&mut self, chemin: &str) {
        // SAFETY : chemin valable pendant l'appel ; aucun nouveau nom (effacement)
        let _ = unsafe { MoveFileExW(&HSTRING::from(chemin), PCWSTR::null(), MOVEFILE_DELAY_UNTIL_REBOOT) };
    }
}
