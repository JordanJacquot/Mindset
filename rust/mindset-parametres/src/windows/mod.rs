//! Le vrai Windows du bloc « paramètres » : la fenêtre « ouvrir un fichier » (IFileOpenDialog), les noms des micros
//! et des sorties (waveInGetDevCapsW, waveOutGetDevCapsW : rien n'est ouvert), la mesure de la suite (le relevé des
//! processus de NtQuerySystemInformation, comme `MSProcessus.Mesurer` de natif.cs), le SID du compte et la valeur
//! « Mindset » de la clé Run.
//!
//! Le seul endroit du bloc où le code « unsafe » est permis (appels à Windows), chacun expliqué.
#![allow(unsafe_code)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use windows::Wdk::System::SystemInformation::{NtQuerySystemInformation, SystemProcessInformation};
use windows::Wdk::System::Threading::{NtQueryInformationProcess, ProcessCommandLineInformation};
use windows::Win32::Foundation::{CloseHandle, HANDLE, HLOCAL, HWND, LocalFree};
use windows::Win32::Media::Audio::{
    WAVEINCAPSW, WAVEOUTCAPSW, waveInGetDevCapsW, waveInGetNumDevs, waveOutGetDevCapsW, waveOutGetNumDevs,
};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE, CoCreateInstance, CoInitializeEx,
    CoTaskMemFree, CoUninitialize,
};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE, RegCloseKey, RegDeleteValueW, RegOpenKeyExW,
};
use windows::Win32::System::SystemInformation::{GetSystemInfo, SYSTEM_INFO};
use windows::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    QueryFullProcessImageNameW,
};
use windows::Win32::UI::Shell::Common::COMDLG_FILTERSPEC;
use windows::Win32::UI::Shell::{
    FOLDERID_Desktop, FOS_FILEMUSTEXIST, FileOpenDialog, IFileOpenDialog, IShellItem, KF_FLAG_DEFAULT,
    SHCreateItemFromParsingName, SHGetKnownFolderPath, SIGDN_FILESYSPATH,
};
use windows::core::{HSTRING, PCWSTR, PWSTR};

use crate::plateforme::{DemandeMesure, Partie, Plateforme};

/// Une poignée refermée quand elle n'est plus utilisée.
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

/// Un processus du relevé.
struct Releve {
    pid: u32,
    nom: String,
    memoire: i64,
    temps: i64,
    creation: i64,
}

/// Ce que la mesure garde d'une fois sur l'autre (`MSProcessus` : chemins, lignes de commande, temps d'avant).
#[derive(Default)]
struct Memoire {
    chemins: HashMap<(u32, i64), Option<String>>,
    commandes: HashMap<(u32, i64), Option<String>>,
    temps_avant: HashMap<(u32, i64), i64>,
    horloge_avant: i64,
}

#[derive(Default)]
pub struct PlateformeWindows {
    memoire: Mutex<Memoire>,
}

/// COM ouvert sur ce fil (et refermé à la fin).
struct Com(bool);

impl Com {
    fn ouvrir() -> Com {
        // SAFETY : initialisation de COM pour ce fil, refermée par Drop si elle a réussi
        Com(unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) }.is_ok())
    }
}

impl Drop for Com {
    fn drop(&mut self) {
        if self.0 {
            // SAFETY : un CoInitializeEx réussi sur ce fil
            unsafe { CoUninitialize() };
        }
    }
}

fn texte_large(b: &[u16]) -> String {
    let fin = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf16_lossy(&b[..fin])
}

/// Le relevé de tous les processus, en un seul appel (`MSProcessus.Releve`).
fn releve() -> Vec<Releve> {
    const STATUS_INFO_LENGTH_MISMATCH: i32 = 0xC000_0004_u32 as i32;
    let mut taille = 512 * 1024usize;
    let mut b: Vec<u64>;
    let mut essais = 0;
    loop {
        b = vec![0u64; taille / 8];
        let mut rendu = 0u32;
        // SAFETY : tampon de la taille annoncée, aligné sur 8
        let st = unsafe {
            NtQuerySystemInformation(SystemProcessInformation, b.as_mut_ptr().cast(), (b.len() * 8) as u32, &mut rendu)
        };
        if st.0 == STATUS_INFO_LENGTH_MISMATCH && essais < 6 {
            essais += 1;
            taille = (taille * 2).max(rendu as usize + 64 * 1024);
            continue;
        }
        if st.0 != 0 {
            return Vec::new();
        }
        break;
    }
    let fin = b.len() * 8;
    let base = b.as_ptr() as *const u8;
    let lire = |o: usize, n: usize| -> &[u8] {
        // SAFETY : lecture dans le tampon rempli par Windows, bornes vérifiées avant chaque appel
        unsafe { std::slice::from_raw_parts(base.add(o), n) }
    };
    let u32_ = |o: usize| u32::from_le_bytes(lire(o, 4).try_into().unwrap_or([0; 4]));
    let u64_ = |o: usize| u64::from_le_bytes(lire(o, 8).try_into().unwrap_or([0; 8]));
    let mut l = Vec::new();
    let mut o = 0usize;
    while o + 96 <= fin {
        // Disposition 64 bits de SYSTEM_PROCESS_INFORMATION
        let suivant = u32_(o) as usize;
        let prive = u64_(o + 8) as i64;
        let creation = u64_(o + 32) as i64;
        let temps = u64_(o + 40) as i64 + u64_(o + 48) as i64;
        let longueur = usize::from(u16::from_le_bytes(lire(o + 56, 2).try_into().unwrap_or([0; 2])));
        let texte = u64_(o + 64) as usize;
        let pid = u64_(o + 80) as u32;
        if pid != 0 {
            let nom = if texte != 0 && longueur > 0 {
                // SAFETY : le nom pointe dans le tampon rempli par Windows
                String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(texte as *const u16, longueur / 2) })
            } else {
                String::new()
            };
            l.push(Releve { pid, nom, memoire: prive, temps, creation });
        }
        if suivant == 0 {
            break;
        }
        o += suivant;
    }
    l
}

fn ouvrir(pid: u32) -> Option<Poignee> {
    // SAFETY : ouverture avec le droit le plus faible, refermée par Poignee
    unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok().map(Poignee) }
}

/// Le chemin complet du programme d'un processus (`MSProcessus.Chemin`).
fn chemin(pid: u32) -> Option<String> {
    let h = ouvrir(pid)?;
    let mut b = vec![0u16; 1024];
    let mut n = b.len() as u32;
    // SAFETY : tampon et taille cohérents
    unsafe { QueryFullProcessImageNameW(h.0, PROCESS_NAME_WIN32, PWSTR(b.as_mut_ptr()), &mut n) }.ok()?;
    let c = String::from_utf16_lossy(&b[..n as usize]);
    Some(suite_commun::chemins::chemin_complet(&c).unwrap_or(c))
}

/// La ligne de commande d'un processus (`MSProcessus.LigneCommande`).
fn ligne_de_commande(pid: u32) -> Option<String> {
    let h = ouvrir(pid)?;
    let mut b = vec![0u64; 8192];
    let mut n = 0u32;
    // SAFETY : le tampon reçoit un UNICODE_STRING suivi de son texte
    let st = unsafe {
        NtQueryInformationProcess(
            h.0,
            ProcessCommandLineInformation,
            b.as_mut_ptr().cast(),
            (b.len() * 8) as u32,
            &mut n,
        )
    };
    if st.0 != 0 {
        return None;
    }
    // SAFETY : Windows a rempli un UNICODE_STRING au début du tampon, dont le texte est dans le même tampon
    unsafe {
        let longueur = *(b.as_ptr() as *const u16) as usize / 2;
        let texte = *((b.as_ptr() as *const u8).add(8) as *const *const u16);
        if texte.is_null() {
            return Some(String::new());
        }
        Some(String::from_utf16_lossy(std::slice::from_raw_parts(texte, longueur)))
    }
}

/// `Dossier` de natif.cs : le chemin complet terminé par « \ ».
fn dossier(d: &str) -> Option<String> {
    if d.is_empty() {
        return None;
    }
    let c = suite_commun::chemins::chemin_complet(d).ok()?;
    Some(format!("{}\\", c.trim_end_matches('\\')))
}

fn commence_par(c: &str, d: &str) -> bool {
    c.to_lowercase().starts_with(&d.to_lowercase())
}

fn processeurs() -> f64 {
    let mut s = SYSTEM_INFO::default();
    // SAFETY : simple lecture dans une structure à nous
    unsafe { GetSystemInfo(&mut s) };
    f64::from(s.dwNumberOfProcessors.max(1))
}

/// L'heure en centaines de nanosecondes (comme `DateTime.UtcNow.Ticks`, à une constante près).
fn horloge() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| (d.as_nanos() / 100) as i64).unwrap_or(0)
}

impl PlateformeWindows {
    fn mesurer_parties(&self, d: &DemandeMesure) -> Vec<Partie> {
        let mut parties: Vec<Partie> = Vec::new();
        let partie = |parties: &mut Vec<Partie>, n: &str| -> usize {
            match parties.iter().position(|p| p.nom == n) {
                Some(i) => i,
                None => {
                    parties.push(Partie { nom: n.to_string(), ..Default::default() });
                    parties.len() - 1
                }
            }
        };
        partie(&mut parties, &d.nom_moi);
        for n in &d.noms {
            partie(&mut parties, n);
        }
        partie(&mut parties, &d.nom_webview);
        let ds: Vec<Option<String>> = d.dossiers.iter().map(|x| dossier(x)).collect();
        let dm = dossier(&d.dossier_moi);

        let liste = releve();
        let h = horloge();
        let mut m = self.memoire.lock().unwrap_or_else(|e| e.into_inner());
        // (les processus terminés sont oubliés)
        let vivants: std::collections::HashSet<(u32, i64)> = liste.iter().map(|p| (p.pid, p.creation)).collect();
        m.chemins.retain(|k, _| vivants.contains(k));
        m.commandes.retain(|k, _| vivants.contains(k));
        let ecoule = if m.horloge_avant > 0 { (h - m.horloge_avant) as f64 * processeurs() } else { 0.0 };
        let mut temps = HashMap::new();
        for p in &liste {
            let k = (p.pid, p.creation);
            let nom = if p.pid == d.moi {
                Some(d.nom_moi.clone())
            } else if p.nom.eq_ignore_ascii_case("msedgewebview2.exe") {
                let c = m.commandes.entry(k).or_insert_with(|| ligne_de_commande(p.pid)).clone();
                c.filter(|c| {
                    let bas = c.to_lowercase();
                    d.marqueurs.iter().any(|x| !x.is_empty() && bas.contains(&x.to_lowercase()))
                })
                .map(|_| d.nom_webview.clone())
            } else {
                let c = m.chemins.entry(k).or_insert_with(|| chemin(p.pid)).clone();
                c.and_then(|c| {
                    if dm.as_ref().is_some_and(|x| commence_par(&c, x)) {
                        return Some(d.nom_moi.clone());
                    }
                    ds.iter().position(|x| x.as_ref().is_some_and(|x| commence_par(&c, x))).map(|i| d.noms[i].clone())
                })
            };
            let Some(nom) = nom else { continue };
            let i = partie(&mut parties, &nom);
            parties[i].nombre += 1;
            parties[i].memoire += p.memoire;
            temps.insert(k, p.temps);
            if ecoule > 0.0
                && let Some(&avant) = m.temps_avant.get(&k)
                && p.temps >= avant
            {
                parties[i].processeur += (p.temps - avant) as f64 / ecoule * 100.0;
            }
        }
        m.temps_avant = temps;
        m.horloge_avant = h;
        parties
    }
}

impl Plateforme for PlateformeWindows {
    fn choisir_zip(&self, parent: Option<isize>, dossier_initial: Option<PathBuf>) -> Option<PathBuf> {
        let _com = Com::ouvrir();
        // SAFETY : objets COM créés et utilisés sur ce fil, libérés à la fin de leur portée
        unsafe {
            let d: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER).ok()?;
            let _ = d.SetTitle(&HSTRING::from("Choisis le thème de la suite (.zip)"));
            let nom = HSTRING::from("Thème de la suite (*.zip)");
            let motif = HSTRING::from("*.zip");
            let filtres = [COMDLG_FILTERSPEC { pszName: PCWSTR(nom.as_ptr()), pszSpec: PCWSTR(motif.as_ptr()) }];
            let _ = d.SetFileTypes(&filtres);
            if let Ok(o) = d.GetOptions() {
                let _ = d.SetOptions(o | FOS_FILEMUSTEXIST);
            }
            if let Some(dossier) = dossier_initial {
                let h = HSTRING::from(dossier.as_os_str());
                if let Ok(it) = SHCreateItemFromParsingName::<_, _, IShellItem>(&h, None) {
                    let _ = d.SetFolder(&it);
                }
            }
            let fenetre = parent.map(|h| HWND(h as *mut core::ffi::c_void));
            d.Show(fenetre).ok()?;
            let it = d.GetResult().ok()?;
            let p = it.GetDisplayName(SIGDN_FILESYSPATH).ok()?;
            let t = p.to_string().ok();
            CoTaskMemFree(Some(p.0 as *const core::ffi::c_void));
            t.map(PathBuf::from)
        }
    }

    fn bureau(&self) -> Option<PathBuf> {
        // SAFETY : le texte rendu par Windows est libéré par CoTaskMemFree
        unsafe {
            let p = SHGetKnownFolderPath(&FOLDERID_Desktop, KF_FLAG_DEFAULT, None).ok()?;
            let t = p.to_string().ok();
            CoTaskMemFree(Some(p.0 as *const core::ffi::c_void));
            t.map(PathBuf::from)
        }
    }

    fn micros(&self) -> Vec<String> {
        // SAFETY : rend seulement un nombre
        let n = unsafe { waveInGetNumDevs() };
        (0..n)
            .map(|i| {
                let mut c = WAVEINCAPSW::default();
                // SAFETY : structure à nous, de la taille annoncée ; Windows n'y écrit que le nom (rien n'est ouvert)
                let r = unsafe { waveInGetDevCapsW(i as usize, &mut c, size_of::<WAVEINCAPSW>() as u32) };
                let nom = c.szPname;
                if r != 0 { String::new() } else { texte_large(&nom) }
            })
            .collect()
    }

    fn sorties(&self) -> Vec<String> {
        // SAFETY : rend seulement un nombre
        let n = unsafe { waveOutGetNumDevs() };
        (0..n)
            .map(|i| {
                let mut c = WAVEOUTCAPSW::default();
                // SAFETY : structure à nous, de la taille annoncée ; Windows n'y écrit que le nom (rien n'est ouvert)
                let r = unsafe { waveOutGetDevCapsW(i as usize, &mut c, size_of::<WAVEOUTCAPSW>() as u32) };
                let nom = c.szPname;
                if r != 0 { String::new() } else { texte_large(&nom) }
            })
            .collect()
    }

    fn mesurer(&self, d: &DemandeMesure) -> Vec<Partie> {
        self.mesurer_parties(d)
    }

    fn sid(&self) -> String {
        let mut j = HANDLE::default();
        // SAFETY : lecture seule du jeton de ce processus
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut j) }.is_err() {
            return String::new();
        }
        let j = Poignee(j);
        let mut n = 0u32;
        // SAFETY : premier appel pour la taille, second avec un tampon aligné de cette taille
        unsafe {
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
            let t = p.to_string().unwrap_or_default();
            let _ = LocalFree(Some(HLOCAL(p.0.cast())));
            t
        }
    }

    fn retirer_run(&self) {
        let mut k = HKEY::default();
        let cle = HSTRING::from(r"Software\Microsoft\Windows\CurrentVersion\Run");
        // SAFETY : ouverture d'une clé de l'utilisateur pour effacer une seule valeur, refermée aussitôt
        unsafe {
            if RegOpenKeyExW(HKEY_CURRENT_USER, &cle, None, KEY_SET_VALUE, &mut k).is_ok() {
                let _ = RegDeleteValueW(k, &HSTRING::from("Mindset"));
                let _ = RegCloseKey(k);
            }
        }
    }
}
