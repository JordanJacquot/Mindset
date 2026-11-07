//! Le vrai Windows du bloc (le seul module où le code « unsafe » est permis) :
//!
//! - [`PcWindows`] : le [`PcLuiMeme`] du bloc : raccourcis (`IShellLinkW` + l'identité `PKEY_AppUserModel_ID`, comme
//!   `MSRaccourci` de natif.cs), `HKCU\...\Run`, disques (`GetLogicalDrives`, `GetDriveTypeW`,
//!   `GetVolumeInformationW`, `GetDiskFreeSpaceExW`, comme `Win32_LogicalDisk`), le compte (SID du jeton), l'activité
//!   (`MSActivite` : plein écran sur n'importe quel écran, manette XInput, `GetLastInputInfo`), la description d'un
//!   programme (`FileVersionInfo`), la marque « téléchargé depuis Internet » (le flux `Zone.Identifier`) ;
//! - [`BasculeWindows`] : ce que lit la bascule administrateur (HKLM en lecture seulement, %TEMP%, le dossier de
//!   Windows).
//!
//! Rien n'est lancé ici (les programmes passent par le port `Systeme` du noyau, sans fenêtre).

#![allow(unsafe_code)]

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;

use windows::Win32::Foundation::{HANDLE, HLOCAL, HWND, LPARAM, LocalFree, PROPERTYKEY, RECT};
use windows::Win32::Graphics::Dwm::{DWMWA_CLOAKED, DwmGetWindowAttribute};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MONITOR_DEFAULTTONULL, MONITORINFO, MonitorFromWindow};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows::Win32::Storage::FileSystem::{
    GetDiskFreeSpaceExW, GetDriveTypeW, GetFileVersionInfoSizeW, GetFileVersionInfoW, GetLogicalDrives,
    GetVolumeInformationW, VerQueryValueW,
};
use windows::Win32::System::Com::StructuredStorage::{PROPVARIANT, PropVariantClear};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemAlloc, CoUninitialize,
    IPersistFile, STGM_READ,
};
use windows::Win32::System::SystemInformation::{GetSystemWindowsDirectoryW, GetTickCount};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows::Win32::System::Variant::VT_LPWSTR;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
use windows::Win32::UI::Input::XboxController::{XINPUT_STATE, XInputGetState};
use windows::Win32::UI::Shell::PropertiesSystem::IPropertyStore;
use windows::Win32::UI::Shell::{
    FOLDERID_Desktop, FOLDERID_Programs, IShellLinkW, KF_FLAG_DEFAULT, SHGetKnownFolderPath, ShellLink,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GWL_EXSTYLE, GetClassNameW, GetDesktopWindow, GetShellWindow, GetWindowLongW, GetWindowRect, IsIconic,
    IsWindowVisible, IsZoomed,
};
use windows::core::{BOOL, GUID, HSTRING, Interface, PWSTR};

use crate::bascule::PcBascule;
use crate::pc::{PcLuiMeme, Raccourci};
use crate::regles::{self, Volume};

/// `PKEY_AppUserModel_ID` : {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 5
const CLE_APP_ID: PROPERTYKEY = PROPERTYKEY { fmtid: GUID::from_u128(0x9f4c2855_9f79_4b39_a8d0_e1d42de1d5f3), pid: 5 };
const CLE_RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const CLE_DESINSTALLATION: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset";

/// Un dossier connu de Windows (Bureau, menu Démarrer), « » s'il n'est pas lisible.
fn dossier_connu(id: &GUID) -> PathBuf {
    // SAFETY : la chaîne rendue par Windows est lue puis libérée par CoTaskMemFree (LocalFree pour ce cas : même tas)
    unsafe {
        match SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None) {
            Ok(p) => {
                let s = p.to_string().unwrap_or_default();
                windows::Win32::System::Com::CoTaskMemFree(Some(p.0 as *const _));
                PathBuf::from(s)
            }
            Err(_) => PathBuf::new(),
        }
    }
}

/// Le texte d'un tampon terminé par un zéro.
fn texte(b: &[u16]) -> String {
    let n = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf16_lossy(&b[..n])
}

/// COM ouvert pour ce fil le temps de `f`.
fn avec_com<R>(f: impl FnOnce() -> windows::core::Result<R>) -> Result<R, String> {
    // SAFETY : CoInitializeEx / CoUninitialize appariés sur ce fil
    unsafe {
        let init = CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_ok();
        let r = f().map_err(|e| e.message());
        if init {
            CoUninitialize();
        }
        r
    }
}

/// Le compte de ce processus (SID), « » s'il n'est pas lisible.
pub fn sid_courant() -> String {
    // SAFETY : jeton ouvert pour la lecture et refermé ; tampon de la taille demandée par Windows ; la chaîne du SID
    // est libérée par LocalFree
    unsafe {
        let mut jeton = HANDLE::default();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut jeton).is_err() {
            return String::new();
        }
        let mut n = 0u32;
        let _ = GetTokenInformation(jeton, TokenUser, None, 0, &mut n);
        let mut b = vec![0u8; n as usize];
        let r = GetTokenInformation(jeton, TokenUser, Some(b.as_mut_ptr() as *mut _), n, &mut n);
        let _ = windows::Win32::Foundation::CloseHandle(jeton);
        if r.is_err() || b.len() < size_of::<TOKEN_USER>() {
            return String::new();
        }
        let u = &*(b.as_ptr() as *const TOKEN_USER);
        let mut s = PWSTR::null();
        if ConvertSidToStringSidW(u.User.Sid, &mut s).is_err() {
            return String::new();
        }
        let t = s.to_string().unwrap_or_default();
        let _ = LocalFree(Some(HLOCAL(s.0 as *mut _)));
        t
    }
}

/// Le dossier de Windows (`GetSystemWindowsDirectoryW`, jamais une variable d'environnement).
pub fn dossier_windows() -> PathBuf {
    let mut b = [0u16; 520];
    // SAFETY : tampon de taille connue
    let n = unsafe { GetSystemWindowsDirectoryW(Some(&mut b)) } as usize;
    if n == 0 || n >= b.len() { PathBuf::from(r"C:\Windows") } else { PathBuf::from(texte(&b[..n])) }
}

// -----------------------------------------------------------------------------------------------------------------
// La manette (XInput)
// -----------------------------------------------------------------------------------------------------------------

struct Manettes {
    signatures: [i64; 4],
    derniere: Option<Instant>,
}

static MANETTES: Mutex<Manettes> = Mutex::new(Manettes { signatures: [-1; 4], derniere: None });

fn manettes() -> std::sync::MutexGuard<'static, Manettes> {
    MANETTES.lock().unwrap_or_else(|e| e.into_inner())
}

// -----------------------------------------------------------------------------------------------------------------
// Le plein écran
// -----------------------------------------------------------------------------------------------------------------

fn classe(h: HWND) -> String {
    let mut b = [0u16; 64];
    // SAFETY : tampon de taille connue
    let n = unsafe { GetClassNameW(h, &mut b) }.max(0) as usize;
    texte(&b[..n.min(b.len())])
}

/// `MSActivite.EstPleinEcran`
fn est_plein_ecran(h: HWND) -> bool {
    // SAFETY : fenêtres seulement lues (styles, rectangle, écran)
    unsafe {
        if h.0.is_null() || h == GetShellWindow() || h == GetDesktopWindow() {
            return false;
        }
        if !IsWindowVisible(h).as_bool() || IsIconic(h).as_bool() || IsZoomed(h).as_bool() {
            return false;
        }
        let ex = GetWindowLongW(h, GWL_EXSTYLE);
        if (ex & 0x80) != 0 || (ex & 0x20) != 0 || (ex & 0x0800_0000) != 0 {
            return false;
        }
        let mut cache = 0i32;
        if DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut cache as *mut i32 as *mut _, 4).is_ok() && cache != 0 {
            return false;
        }
        let c = classe(h);
        if ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow"]
            .contains(&c.as_str())
        {
            return false;
        }
        let mut r = RECT::default();
        if GetWindowRect(h, &mut r).is_err() {
            return false;
        }
        let m = MonitorFromWindow(h, MONITOR_DEFAULTTONULL);
        if m.0.is_null() {
            return false;
        }
        let mut mi = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        if !GetMonitorInfoW(m, &mut mi).as_bool() {
            return false;
        }
        let e = mi.rcMonitor;
        regles::couvre_ecran(r.left, r.top, r.right, r.bottom, e.left, e.top, e.right, e.bottom)
    }
}

unsafe extern "system" fn chaque_fenetre(h: HWND, p: LPARAM) -> BOOL {
    if est_plein_ecran(h) {
        // SAFETY : p est l'adresse du booléen de plein_ecran, vivant pendant EnumWindows
        unsafe { *(p.0 as *mut bool) = true };
        return BOOL(0);
    }
    BOOL(1)
}

// -----------------------------------------------------------------------------------------------------------------
// Le vrai Windows du bloc
// -----------------------------------------------------------------------------------------------------------------

/// Le vrai Windows du bloc.
#[derive(Debug, Default, Clone, Copy)]
pub struct PcWindows;

impl PcLuiMeme for PcWindows {
    fn raccourcis_mindset(&self) -> Vec<PathBuf> {
        vec![
            dossier_connu(&FOLDERID_Desktop).join("Mindset.lnk"),
            dossier_connu(&FOLDERID_Programs).join("Mindset.lnk"),
        ]
    }

    fn existe(&self, chemin: &Path) -> bool {
        chemin.exists()
    }

    fn lire_raccourci(&self, lien: &Path) -> Result<Raccourci, String> {
        avec_com(|| {
            // SAFETY : objets COM du système, tampons de taille connue, PROPVARIANT libérée
            unsafe {
                let l: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
                let f: IPersistFile = l.cast()?;
                f.Load(&HSTRING::from(lien.as_os_str()), STGM_READ)?;
                let mut cible = vec![0u16; 1024];
                l.GetPath(&mut cible, std::ptr::null_mut(), 4)?; // SLGP_RAWPATH
                let mut icone = vec![0u16; 1024];
                let mut index = 0i32;
                l.GetIconLocation(&mut icone, &mut index)?;
                let store: IPropertyStore = l.cast()?;
                let mut v = store.GetValue(&CLE_APP_ID)?;
                let a = &v.Anonymous.Anonymous;
                let app_id = if a.vt == VT_LPWSTR && !a.Anonymous.pwszVal.is_null() {
                    a.Anonymous.pwszVal.to_string().unwrap_or_default()
                } else {
                    String::new()
                };
                let _ = PropVariantClear(&mut v);
                Ok(Raccourci {
                    cible: texte(&cible),
                    icone: format!("{},{index}", texte(&icone)),
                    app_id,
                    ..Default::default()
                })
            }
        })
    }

    fn ecrire_raccourci(&self, lien: &Path, r: &Raccourci) -> Result<(), String> {
        avec_com(|| {
            // SAFETY : objets COM du système ; la chaîne de la PROPVARIANT est allouée par CoTaskMemAlloc et libérée
            // par PropVariantClear
            unsafe {
                let l: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
                l.SetPath(&HSTRING::from(r.cible.as_str()))?;
                l.SetArguments(&HSTRING::new())?;
                l.SetWorkingDirectory(&HSTRING::from(r.dossier.as_str()))?;
                let icone = if r.icone.is_empty() { r.cible.as_str() } else { r.icone.as_str() };
                l.SetIconLocation(&HSTRING::from(icone), 0)?;
                l.SetDescription(&HSTRING::from(r.description.as_str()))?;
                let store: IPropertyStore = l.cast()?;
                let w: Vec<u16> = r.app_id.encode_utf16().chain(std::iter::once(0)).collect();
                let p = CoTaskMemAlloc(w.len() * 2) as *mut u16;
                if p.is_null() {
                    return Err(windows::core::Error::from_hresult(windows::Win32::Foundation::E_OUTOFMEMORY));
                }
                std::ptr::copy_nonoverlapping(w.as_ptr(), p, w.len());
                let mut v = PROPVARIANT::default();
                (*v.Anonymous.Anonymous).vt = VT_LPWSTR;
                (*v.Anonymous.Anonymous).Anonymous.pwszVal = PWSTR(p);
                let e = store.SetValue(&CLE_APP_ID, &v).and_then(|_| store.Commit());
                let _ = PropVariantClear(&mut v);
                e?;
                let f: IPersistFile = l.cast()?;
                f.Save(&HSTRING::from(lien.as_os_str()), true)
            }
        })
    }

    fn retirer_fichier(&self, chemin: &Path) -> Result<(), String> {
        std::fs::remove_file(chemin).map_err(|e| e.to_string())
    }

    fn run(&self) -> Option<String> {
        windows_registry::CURRENT_USER.open(CLE_RUN).ok()?.get_string("Mindset").ok()
    }

    fn ecrire_run(&self, valeur: &str) -> Result<(), String> {
        let c = windows_registry::CURRENT_USER.create(CLE_RUN).map_err(|e| e.message())?;
        c.set_string("Mindset", valeur).map_err(|e| e.message())
    }

    fn retirer_run(&self) -> Result<(), String> {
        let c = windows_registry::CURRENT_USER.create(CLE_RUN).map_err(|e| e.message())?;
        c.remove_value("Mindset").map_err(|e| e.message())
    }

    fn volumes(&self) -> Vec<Volume> {
        let mut r = Vec::new();
        // SAFETY : lectures seules, tampons de taille connue
        unsafe {
            let masque = GetLogicalDrives();
            for i in 0..26u32 {
                if masque & (1 << i) == 0 {
                    continue;
                }
                let l = char::from(b'A' + i as u8);
                let racine = HSTRING::from(format!(r"{l}:\"));
                if GetDriveTypeW(&racine) != 3 {
                    continue;
                }
                let mut fs = [0u16; 64];
                let systeme = if GetVolumeInformationW(&racine, None, None, None, None, Some(&mut fs)).is_ok() {
                    texte(&fs)
                } else {
                    String::new()
                };
                let mut libre = 0u64;
                let ok = GetDiskFreeSpaceExW(&racine, None, None, Some(&mut libre)).is_ok();
                r.push(Volume { lettre: format!("{l}:"), systeme_fichiers: systeme, libre: ok.then_some(libre) });
            }
        }
        r
    }

    fn disque_systeme(&self) -> String {
        dossier_windows().to_string_lossy().chars().take(1).collect()
    }

    fn sid(&self) -> String {
        sid_courant()
    }

    fn plein_ecran(&self) -> bool {
        let mut trouve = false;
        // SAFETY : la fonction de rappel ne garde rien ; le booléen vit pendant l'appel
        unsafe {
            let _ = EnumWindows(Some(chaque_fenetre), LPARAM(&mut trouve as *mut bool as isize));
        }
        trouve
    }

    fn relever_manette(&self) {
        let mut m = manettes();
        for i in 0..4u32 {
            let mut s = XINPUT_STATE::default();
            // SAFETY : structure de la taille attendue
            let r = unsafe { XInputGetState(i, &mut s) };
            let g = s.Gamepad;
            let sig = regles::signature_manette(
                g.wButtons.0,
                g.bLeftTrigger,
                g.bRightTrigger,
                g.sThumbLX,
                g.sThumbLY,
                g.sThumbRX,
                g.sThumbRY,
            );
            if regles::noter_manette(&mut m.signatures, i as i32, r == 0, sig) {
                m.derniere = Some(Instant::now());
            }
        }
    }

    fn secondes_manette(&self) -> f64 {
        manettes().derniere.map_or(f64::MAX, |d| d.elapsed().as_secs_f64())
    }

    fn secondes_inactif(&self) -> Result<f64, String> {
        let mut l = LASTINPUTINFO { cbSize: size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
        // SAFETY : structure de la taille attendue
        unsafe {
            if !GetLastInputInfo(&mut l).as_bool() {
                return Ok(0.0);
            }
            Ok(GetTickCount().wrapping_sub(l.dwTime) as f64 / 1000.0)
        }
    }

    fn infos_programme(&self, chemin: &str) -> (Option<String>, Option<String>) {
        infos_version(chemin)
    }

    fn debloquer(&self, dossier: &Path) {
        let mut pile = vec![dossier.to_path_buf()];
        while let Some(d) = pile.pop() {
            let Ok(l) = std::fs::read_dir(&d) else { continue };
            for e in l.flatten() {
                let p = e.path();
                match e.file_type() {
                    Ok(t) if t.is_dir() => pile.push(p),
                    Ok(t) if t.is_file() => {
                        let _ = std::fs::remove_file(format!("{}:Zone.Identifier", p.display()));
                    }
                    _ => {}
                }
            }
        }
    }
}

/// Un texte des informations de version d'un programme.
fn champ_version(bloc: &[u8], chemin: &str) -> Option<String> {
    let mut p: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut n = 0u32;
    let h = HSTRING::from(chemin);
    // SAFETY : bloc rendu par GetFileVersionInfoW ; le texte trouvé est dans le bloc
    unsafe {
        if !VerQueryValueW(bloc.as_ptr() as *const _, &h, &mut p, &mut n).as_bool() || p.is_null() || n == 0 {
            return None;
        }
        Some(texte(std::slice::from_raw_parts(p as *const u16, n as usize)))
    }
}

/// `FileVersionInfo.FileDescription` et `ProductName` (la première langue du programme, puis l'anglais).
pub fn infos_version(exe: &str) -> (Option<String>, Option<String>) {
    let h = HSTRING::from(exe);
    // SAFETY : tampon de la taille demandée par Windows
    unsafe {
        let taille = GetFileVersionInfoSizeW(&h, None);
        if taille == 0 {
            return (None, None);
        }
        let mut bloc = vec![0u8; taille as usize];
        if GetFileVersionInfoW(&h, None, taille, bloc.as_mut_ptr() as *mut _).is_err() {
            return (None, None);
        }
        let mut p: *mut core::ffi::c_void = std::ptr::null_mut();
        let mut n = 0u32;
        let mut langues = Vec::new();
        let t = HSTRING::from(r"\VarFileInfo\Translation");
        if VerQueryValueW(bloc.as_ptr() as *const _, &t, &mut p, &mut n).as_bool() && !p.is_null() && n >= 4 {
            let s = std::slice::from_raw_parts(p as *const u16, (n / 2) as usize);
            if s.len() >= 2 {
                langues.push(format!("{:04x}{:04x}", s[0], s[1]));
            }
        }
        langues.push("040904b0".into());
        let lire =
            |champ: &str| langues.iter().find_map(|l| champ_version(&bloc, &format!(r"\StringFileInfo\{l}\{champ}")));
        (lire("FileDescription"), lire("ProductName"))
    }
}

/// Ce que lit la bascule administrateur.
#[derive(Debug, Default, Clone, Copy)]
pub struct BasculeWindows;

impl PcBascule for BasculeWindows {
    fn inscrit(&self) -> String {
        windows_registry::LOCAL_MACHINE
            .open(CLE_DESINSTALLATION)
            .and_then(|c| c.get_string("InstallLocation"))
            .unwrap_or_default()
    }
    fn temp(&self) -> PathBuf {
        std::env::temp_dir()
    }
    fn sid(&self) -> String {
        sid_courant()
    }
    fn windows(&self) -> PathBuf {
        dossier_windows()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Le vrai Windows en lecture seulement (disques, compte, activité, description d'un programme), et un raccourci
    /// écrit puis relu dans un dossier d'essai (jamais sur le Bureau ni dans le menu Démarrer).
    #[test]
    fn vrai_windows_en_lecture_et_raccourci_d_essai() {
        let pc = PcWindows;
        let v = pc.volumes();
        assert!(v.iter().any(|x| x.lettre == format!("{}:", pc.disque_systeme())), "{v:?}");
        assert!(pc.sid().starts_with("S-1-5-"));
        assert!(dossier_windows().join("explorer.exe").is_file());
        assert!(pc.secondes_inactif().is_ok());
        let _ = pc.plein_ecran();
        pc.relever_manette();
        let (d, p) = pc.infos_programme(&dossier_windows().join("explorer.exe").to_string_lossy());
        assert!(d.is_some() || p.is_some());
        let l = pc.raccourcis_mindset();
        assert!(l.iter().all(|x| x.ends_with("Mindset.lnk")) && l.len() == 2);
        let dossier = mindset_noyau::dossier_essai("lui-meme-raccourci");
        let _ = std::fs::remove_dir_all(&dossier);
        std::fs::create_dir_all(&dossier).unwrap();
        let lien = dossier.join("Essai.lnk");
        let exe = dossier_windows().join("explorer.exe").to_string_lossy().into_owned();
        let r = Raccourci {
            cible: exe.clone(),
            icone: exe.clone(),
            app_id: "JordanJacquot.MindsetEssai".into(),
            dossier: dossier.to_string_lossy().into(),
            description: "Essai".into(),
        };
        pc.ecrire_raccourci(&lien, &r).unwrap();
        let lu = pc.lire_raccourci(&lien).unwrap();
        assert!(suite_commun::chemins::egal(&lu.cible, &exe), "{lu:?}");
        assert_eq!(lu.app_id, "JordanJacquot.MindsetEssai");
        assert!(lu.icone.ends_with(",0"));
        pc.retirer_fichier(&lien).unwrap();
        let _ = std::fs::remove_dir_all(&dossier);
    }
}
