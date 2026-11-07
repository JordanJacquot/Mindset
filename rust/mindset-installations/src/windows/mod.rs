//! Le seul module du bloc qui parle à Windows, et le seul où le code « unsafe » est permis (chaque bloc a son
//! commentaire SAFETY) : le vrai [`crate::poste::Poste`] et le vrai mini-installateur ([`installateur`]).
//!
//! - les raccourcis : `IShellLinkW` et leur identité (`System.AppUserModel.ID`, par `IPropertyStore`) ;
//! - les dossiers connus (`SHGetKnownFolderPath`, jamais les variables d'environnement) ;
//! - le registre : « Run » de l'utilisateur (lecture et retrait d'une entrée), `HKCU\Environment` et
//!   `HKLM\SOFTWARE\Mindset\Installation` en lecture seulement ;
//! - `schtasks.exe` (System32, demandé à Windows) et `robocopy.exe`, lancés sans fenêtre (CREATE_NO_WINDOW) ;
//! - la demande de Windows : `MindsetInstallateur.exe` en « runas » (`ShellExecuteExW`, fenêtre cachée).

#![allow(unsafe_code)]

pub mod installateur;

use std::os::windows::process::CommandExt;
use std::path::Path;

use windows::Win32::Foundation::{HANDLE, HLOCAL, LocalFree};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{
    GetTokenInformation, LookupAccountNameW, PSID, SID_NAME_USE, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows::Win32::Storage::FileSystem::GetLongPathNameW;
use windows::Win32::System::Com::StructuredStorage::{PROPVARIANT, PropVariantClear, PropVariantToString};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize,
    IPersistFile, STGM_READ,
};
use windows::Win32::System::SystemInformation::{GetSystemDirectoryW, GetWindowsDirectoryW};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows::Win32::System::Variant::VT_LPWSTR;
use windows::Win32::UI::Shell::PropertiesSystem::IPropertyStore;
use windows::Win32::UI::Shell::{
    FOLDERID_CommonPrograms, FOLDERID_Desktop, FOLDERID_Documents, FOLDERID_LocalAppData, FOLDERID_Profile,
    FOLDERID_ProgramData, FOLDERID_ProgramFiles, FOLDERID_ProgramFilesX86, FOLDERID_Programs, FOLDERID_PublicDesktop,
    FOLDERID_Startup, FOLDERID_Windows, IShellLinkW, KF_FLAG_DEFAULT, SHGetKnownFolderPath, SHStrDupW, ShellLink,
};
use windows::Win32::UI::WindowsAndMessaging::{ASFW_ANY, AllowSetForegroundWindow};
use windows::core::{GUID, HSTRING, Interface, PCWSTR, PWSTR};
use windows_registry::{CURRENT_USER, LOCAL_MACHINE};

use crate::poste::{NouveauRaccourci, Poste, Raccourci};

/// CREATE_NO_WINDOW : aucun programme lancé par le bloc n'ouvre de console.
pub const SANS_CONSOLE: u32 = 0x0800_0000;

/// `System.AppUserModel.ID` ({9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 5).
const PKEY_APPUSERMODEL_ID: windows::Win32::Foundation::PROPERTYKEY =
    windows::Win32::Foundation::PROPERTYKEY { fmtid: GUID::from_u128(0x9f4c2855_9f79_4b39_a8d0_e1d42de1d5f3), pid: 5 };

const CLE_RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

fn texte16(b: &[u16]) -> String {
    let n = b.iter().position(|c| *c == 0).unwrap_or(b.len());
    String::from_utf16_lossy(&b[..n])
}

/// COM prêt sur ce fil tant que la valeur vit.
struct Com(bool);
impl Com {
    fn pret() -> Com {
        // SAFETY : initialisation de COM pour ce fil, défaite par Drop si elle a réussi
        let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        Com(hr.is_ok())
    }
}
impl Drop for Com {
    fn drop(&mut self) {
        if self.0 {
            // SAFETY : CoInitializeEx a réussi sur ce fil
            unsafe { CoUninitialize() };
        }
    }
}

/// Un dossier connu de Windows, « » s'il ne se lit pas.
pub fn dossier_connu(id: &GUID) -> String {
    // SAFETY : texte rendu par Windows, libéré avec CoTaskMemFree juste après
    unsafe {
        match SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None) {
            Ok(p) => {
                let s = p.to_string().unwrap_or_default();
                CoTaskMemFree(Some(p.0.cast()));
                s
            }
            Err(_) => String::new(),
        }
    }
}

/// System32, demandé à Windows.
pub fn system32() -> String {
    let mut b = vec![0u16; 1024];
    // SAFETY : tampon et taille cohérents
    let n = unsafe { GetSystemDirectoryW(Some(&mut b)) } as usize;
    if n == 0 || n > b.len() { r"C:\Windows\System32".into() } else { texte16(&b[..n]) }
}

/// Le dossier de Windows, demandé à Windows.
pub fn dossier_windows() -> String {
    let mut b = vec![0u16; 1024];
    // SAFETY : tampon et taille cohérents
    let n = unsafe { GetWindowsDirectoryW(Some(&mut b)) } as usize;
    if n == 0 || n > b.len() { r"C:\Windows".into() } else { texte16(&b[..n]) }
}

/// Un programme de System32 lancé sans fenêtre : (code de sortie, sortie).
pub fn lancer_systeme(exe: &str, args: &[&str]) -> Option<(i32, Vec<u8>)> {
    let o = std::process::Command::new(Path::new(&system32()).join(exe))
        .args(args)
        .current_dir(system32())
        .creation_flags(SANS_CONSOLE)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    Some((o.status.code().unwrap_or(-1), o.stdout))
}

struct Poignee(HANDLE);
impl Drop for Poignee {
    fn drop(&mut self) {
        // SAFETY : handle ouvert par ce module, fermé une seule fois
        unsafe {
            let _ = windows::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

/// Le SID de l'utilisateur de ce processus.
pub fn mon_sid() -> String {
    let mut j = HANDLE::default();
    // SAFETY : jeton de ce processus, lu puis refermé ; tampon de la taille annoncée par Windows ; texte du SID libéré
    // par LocalFree
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
        sid_texte(u.User.Sid)
    }
}

/// # Safety
/// `sid` doit être un SID valable.
unsafe fn sid_texte(sid: PSID) -> String {
    let mut p = PWSTR::null();
    // SAFETY : SID valable (voir l'appelant) ; texte libéré par LocalFree
    unsafe {
        if ConvertSidToStringSidW(sid, &mut p).is_err() {
            return String::new();
        }
        let s = p.to_string().unwrap_or_default();
        let _ = LocalFree(Some(HLOCAL(p.0.cast())));
        s
    }
}

/// Un compte (« NT AUTHORITY\SYSTEM », « PC\Jordan ») en SID, comme `NTAccount.Translate` ; « » si inconnu.
pub fn compte_en_sid(compte: &str) -> String {
    if compte.starts_with("S-1-") {
        return compte.to_string();
    }
    let nom = HSTRING::from(compte);
    let (mut n_sid, mut n_dom) = (0u32, 0u32);
    let mut usage = SID_NAME_USE::default();
    // SAFETY : premier appel pour connaître les tailles, second avec des tampons de ces tailles
    unsafe {
        let _ = LookupAccountNameW(PCWSTR::null(), &nom, None, &mut n_sid, None, &mut n_dom, &mut usage);
        if n_sid == 0 {
            return String::new();
        }
        let mut sid = vec![0u64; (n_sid as usize).div_ceil(8)];
        let mut dom = vec![0u16; n_dom as usize + 1];
        if LookupAccountNameW(
            PCWSTR::null(),
            &nom,
            Some(PSID(sid.as_mut_ptr().cast())),
            &mut n_sid,
            Some(PWSTR(dom.as_mut_ptr())),
            &mut n_dom,
            &mut usage,
        )
        .is_err()
        {
            return String::new();
        }
        sid_texte(PSID(sid.as_mut_ptr().cast()))
    }
}

/// La forme longue d'un chemin (`GetLongPathNameW` : `C:\Users\RUNNER~1\x` devient `C:\Users\runneradmin\x`) ; le
/// chemin tel quel s'il n'existe pas ou ne se lit pas. Un raccourci peut garder un chemin court, et %TEMP% est parfois
/// court : comparer deux chemins sans les mettre sous cette forme ferait croire à un raccourci faux.
pub fn chemin_long(chemin: &str) -> String {
    if chemin.is_empty() || !chemin.contains('~') {
        return chemin.to_string();
    }
    let h = HSTRING::from(chemin);
    let mut b = vec![0u16; 32768];
    // SAFETY : tampon local de taille connue, chaîne terminée par zéro (HSTRING)
    let n = unsafe { GetLongPathNameW(&h, Some(&mut b)) } as usize;
    if n == 0 || n >= b.len() { chemin.to_string() } else { String::from_utf16_lossy(&b[..n]) }
}

/// L'icône d'un raccourci (« chemin,index ») avec son chemin sous la forme longue.
fn icone_longue(chemin: &str, index: i32) -> String {
    format!("{},{index}", chemin_long(chemin))
}

/// Lit un raccourci : sa cible, son icône (« chemin,index ») et son identité.
fn lire_lnk(lnk: &Path) -> Option<Raccourci> {
    let _com = Com::pret();
    // SAFETY : appels COM ordinaires sur des objets créés ici ; tampons locaux ; le PROPVARIANT lu est libéré
    unsafe {
        let l: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).ok()?;
        let f: IPersistFile = l.cast().ok()?;
        f.Load(&HSTRING::from(lnk.as_os_str()), STGM_READ).ok()?;
        let mut b = vec![0u16; 32768];
        l.GetPath(&mut b, std::ptr::null_mut(), 0).ok()?;
        let cible = chemin_long(&texte16(&b));
        let mut ib = vec![0u16; 32768];
        let mut index = 0i32;
        let icone = match l.GetIconLocation(&mut ib, &mut index) {
            Ok(()) => icone_longue(&texte16(&ib), index),
            Err(_) => String::new(),
        };
        let mut identite = String::new();
        if let Ok(ps) = l.cast::<IPropertyStore>()
            && let Ok(mut v) = ps.GetValue(&PKEY_APPUSERMODEL_ID)
        {
            let mut t = vec![0u16; 1024];
            if PropVariantToString(&v, &mut t).is_ok() {
                identite = texte16(&t);
            }
            let _ = PropVariantClear(&mut v);
        }
        Some(Raccourci { cible, icone, identite })
    }
}

/// Écrit un raccourci (`MSRaccourci.Ecrire`) : cible, dossier de travail, icône (index 0), description, identité.
fn ecrire_lnk(lnk: &Path, r: &NouveauRaccourci) -> Result<(), String> {
    let _com = Com::pret();
    let e = |x: windows::core::Error| x.message();
    // SAFETY : appels COM ordinaires sur des objets créés ici ; le PROPVARIANT (texte alloué par SHStrDupW) est
    // libéré par PropVariantClear
    unsafe {
        let l: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).map_err(e)?;
        l.SetPath(&HSTRING::from(r.cible.as_str())).map_err(e)?;
        l.SetWorkingDirectory(&HSTRING::from(r.dossier.as_str())).map_err(e)?;
        l.SetIconLocation(&HSTRING::from(r.icone.as_str()), 0).map_err(e)?;
        l.SetDescription(&HSTRING::from(r.description.as_str())).map_err(e)?;
        if !r.identite.is_empty() {
            let ps: IPropertyStore = l.cast().map_err(e)?;
            let mut v = PROPVARIANT::default();
            let texte = SHStrDupW(&HSTRING::from(r.identite.as_str())).map_err(e)?;
            (*v.Anonymous.Anonymous).vt = VT_LPWSTR;
            (*v.Anonymous.Anonymous).Anonymous.pwszVal = texte;
            let fait = ps.SetValue(&PKEY_APPUSERMODEL_ID, &v).and_then(|()| ps.Commit());
            let _ = PropVariantClear(&mut v);
            fait.map_err(e)?;
        }
        let f: IPersistFile = l.cast().map_err(e)?;
        f.Save(&HSTRING::from(lnk.as_os_str()), true).map_err(e)
    }
}

/// Le vrai poste.
#[derive(Debug, Default)]
pub struct PosteWindows;

impl PosteWindows {
    pub fn nouveau() -> PosteWindows {
        PosteWindows
    }
}

fn noms_valeurs(cle: &windows_registry::Key) -> Vec<String> {
    cle.values().map(|l| l.map(|(n, _)| n).collect()).unwrap_or_default()
}

impl Poste for PosteWindows {
    fn lieux_raccourcis(&self) -> Vec<String> {
        [&FOLDERID_Desktop, &FOLDERID_PublicDesktop, &FOLDERID_Programs, &FOLDERID_CommonPrograms, &FOLDERID_Startup]
            .iter()
            .map(|g| dossier_connu(g))
            .filter(|d| !d.is_empty() && Path::new(d).is_dir())
            .collect()
    }
    fn lieux_copies(&self) -> Vec<String> {
        let profil = dossier_connu(&FOLDERID_Profile);
        let telech = if profil.is_empty() { String::new() } else { format!(r"{profil}\Downloads") };
        vec![telech, dossier_connu(&FOLDERID_Desktop), dossier_connu(&FOLDERID_Documents)]
    }
    fn cible_raccourci(&self, lnk: &Path) -> Option<String> {
        lire_lnk(lnk).map(|r| r.cible)
    }
    fn lire_raccourci(&self, lnk: &Path) -> Option<Raccourci> {
        lire_lnk(lnk)
    }
    fn ecrire_raccourci(&self, lnk: &Path, r: &NouveauRaccourci) -> Result<(), String> {
        ecrire_lnk(lnk, r)
    }
    fn menu_applis(&self) -> Option<String> {
        let p = dossier_connu(&FOLDERID_Programs);
        (!p.is_empty()).then(|| format!(r"{p}\Mindset"))
    }
    fn entrees_run(&self) -> Result<Vec<(String, Option<String>)>, String> {
        let k = CURRENT_USER.open(CLE_RUN).map_err(|e| e.message())?;
        let l = k.values().map_err(|e| e.message())?;
        Ok(l.map(|(n, v)| {
            let texte = matches!(v.ty(), windows_registry::Type::String | windows_registry::Type::ExpandString)
                .then(|| String::try_from(v).ok())
                .flatten();
            (n, texte)
        })
        .collect())
    }
    fn retirer_run(&self, nom: &str) -> Result<(), String> {
        let k = CURRENT_USER.options().read().write().open(CLE_RUN).map_err(|e| e.message())?;
        k.remove_value(nom).map_err(|e| e.message())
    }
    fn tache_existe(&self, chemin: &str) -> bool {
        lancer_systeme("schtasks.exe", &["/Query", "/TN", chemin]).is_some_and(|(c, _)| c == 0)
    }
    fn retirer_tache(&self, chemin: &str) -> bool {
        lancer_systeme("schtasks.exe", &["/Delete", "/TN", chemin, "/F"]).is_some_and(|(c, _)| c == 0)
    }
    fn variables_processus(&self) -> Vec<String> {
        std::env::vars_os().map(|(k, _)| k.to_string_lossy().into_owned()).collect()
    }
    fn variables_compte(&self) -> Vec<String> {
        CURRENT_USER.open("Environment").map(|k| noms_valeurs(&k)).unwrap_or_default()
    }
    fn sid(&self) -> String {
        mon_sid()
    }
    fn dossiers_interdits(&self) -> Vec<String> {
        [&FOLDERID_Windows, &FOLDERID_ProgramFiles, &FOLDERID_ProgramFilesX86, &FOLDERID_ProgramData]
            .iter()
            .map(|g| dossier_connu(g))
            .filter(|d| !d.is_empty())
            .collect()
    }
    fn program_files(&self) -> String {
        dossier_connu(&FOLDERID_ProgramFiles)
    }
    fn localappdata(&self) -> String {
        dossier_connu(&FOLDERID_LocalAppData)
    }
    fn copier_dossier(&self, de: &Path, vers: &Path) -> Result<(), String> {
        let de = de.to_string_lossy();
        let vers = vers.to_string_lossy();
        let args =
            [&*de, &*vers, "/E", "/COPY:DAT", "/DCOPY:DAT", "/R:1", "/W:1", "/NFL", "/NDL", "/NP", "/NJH", "/NJS"];
        match lancer_systeme("robocopy.exe", &args) {
            Some((c, _)) if (0..8).contains(&c) => Ok(()),
            Some((c, _)) => Err(format!("robocopy : code {c}")),
            None => Err("robocopy n'a pas pu être lancé".into()),
        }
    }
    fn autoriser_premier_plan(&self) {
        // SAFETY : simple appel, sans pointeur
        unsafe {
            let _ = AllowSetForegroundWindow(ASFW_ANY);
        }
    }
    fn forme_longue(&self, chemin: &str) -> String {
        chemin_long(chemin)
    }
}

/// La valeur d'une clé de HKLM, en texte (« » si absente) ; seulement lue.
pub fn valeur_hklm(cle: &str, nom: &str) -> String {
    let Ok(k) = LOCAL_MACHINE.open(cle) else { return String::new() };
    let Ok(v) = k.get_value(nom) else { return String::new() };
    match v.ty() {
        windows_registry::Type::U32 => u32::try_from(v).map(|n| n.to_string()).unwrap_or_default(),
        windows_registry::Type::U64 => u64::try_from(v).map(|n| n.to_string()).unwrap_or_default(),
        windows_registry::Type::MultiString => Vec::<String>::try_from(v).map(|l| l.join(" ")).unwrap_or_default(),
        _ => String::try_from(v).unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Le nom court (8.3) d'un chemin qui existe (comme %TEMP% sur les machines de GitHub), ou le chemin tel quel.
    fn chemin_court(chemin: &str) -> String {
        let h = HSTRING::from(chemin);
        let mut b = vec![0u16; 32768];
        // SAFETY : tampon local de taille connue
        let n = unsafe { windows::Win32::Storage::FileSystem::GetShortPathNameW(&h, Some(&mut b)) } as usize;
        if n == 0 || n >= b.len() { chemin.to_string() } else { String::from_utf16_lossy(&b[..n]) }
    }

    /// Un vrai raccourci, écrit puis relu, dans un dossier d'essai (jamais le vrai Bureau ni le vrai menu Démarrer).
    /// Il est écrit avec le nom court du programme (cas de GitHub, où %TEMP% est court) : relu, cible et icône sont
    /// sous la forme longue, comparables au chemin long.
    #[test]
    fn raccourci_ecrit_puis_relu() {
        let d = mindset_noyau::dossier_essai("installations-lnk");
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("Dossier long Forêt")).unwrap();
        let hote = d.join("Dossier long Forêt").join("Mindset.exe");
        std::fs::write(&hote, "x").unwrap();
        let lnk = d.join("Café crème.lnk");
        let long = chemin_long(&hote.to_string_lossy());
        let court = chemin_court(&long);
        let r = NouveauRaccourci {
            cible: court.clone(),
            dossier: d.to_string_lossy().into_owned(),
            icone: court.clone(),
            description: "Essai".into(),
            identite: "JordanJacquot.EssaiForet".into(),
        };
        PosteWindows.ecrire_raccourci(&lnk, &r).unwrap();
        let l = PosteWindows.lire_raccourci(&lnk).unwrap();
        assert!(l.cible.eq_ignore_ascii_case(&long), "{l:?} / {long}");
        assert!(l.icone.eq_ignore_ascii_case(&format!("{long},0")), "{l:?} / {long}");
        assert_eq!(l.identite, "JordanJacquot.EssaiForet");
        assert_eq!(PosteWindows.cible_raccourci(&lnk).map(|c| c.to_lowercase()), Some(long.to_lowercase()));
        assert_eq!(PosteWindows.forme_longue(&court).to_lowercase(), long.to_lowercase(), "{court}");
        assert_eq!(chemin_long(r"C:\Dossier~Qui\N'existe~pas"), r"C:\Dossier~Qui\N'existe~pas");
        assert!(PosteWindows.lire_raccourci(&d.join("absent.lnk")).is_none());
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Lectures seulement : le compte de ce processus, un compte connu, une clé de HKLM qui n'existe pas.
    #[test]
    fn comptes_et_registre_en_lecture() {
        assert!(mon_sid().starts_with("S-1-5-"));
        assert_eq!(compte_en_sid(r"NT AUTHORITY\SYSTEM"), "S-1-5-18");
        assert_eq!(compte_en_sid("S-1-5-18"), "S-1-5-18");
        assert_eq!(compte_en_sid("Compte-Qui-N-Existe-Pas-Foret"), "");
        assert_eq!(valeur_hklm(r"SOFTWARE\MindsetEssaiInexistant", "Recu"), "");
        assert!(system32().to_lowercase().ends_with("system32"));
    }
}
