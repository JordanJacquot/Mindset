//! Le seul module du bloc qui parle à Windows : la boîte « choisir un dossier » (`Select-DossierAppli`,
//! accueil.ps1:462-468, `System.Windows.Forms.FolderBrowserDialog`), par `IFileOpenDialog` avec `FOS_PICKFOLDERS`,
//! posée sur la fenêtre de Mindset. Jamais appelé en essai ni en test (le bloc s'arrête avant).
#![allow(unsafe_code)]

use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize,
};
use windows::Win32::UI::Shell::{
    FOS_FORCEFILESYSTEM, FOS_PICKFOLDERS, FileOpenDialog, IFileOpenDialog, SIGDN_FILESYSPATH,
};
use windows::core::HSTRING;

/// Le dossier choisi, `None` si l'utilisateur annule (ou si la boîte ne s'ouvre pas). `parent` : la fenêtre de
/// Mindset (la boîte reste devant elle). Appelé dans un travail de fond : le fil a son propre COM.
pub fn choisir_dossier(parent: Option<isize>, titre: &str) -> Option<String> {
    // SAFETY : COM est ouvert puis refermé sur ce fil ; la boîte et son résultat sont des objets COM comptés
    // (relâchés à la fin de la portée) ; le texte rendu par GetDisplayName est libéré par CoTaskMemFree, une fois,
    // après avoir été copié.
    unsafe {
        let init = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let r = (|| -> windows::core::Result<Option<String>> {
            let d: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;
            let o = d.GetOptions()?;
            d.SetOptions(o | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM)?;
            d.SetTitle(&HSTRING::from(titre))?;
            let h = parent.filter(|p| *p != 0).map(|p| HWND(p as *mut core::ffi::c_void));
            // (annulé : une erreur « annulé par l'utilisateur »)
            if d.Show(h).is_err() {
                return Ok(None);
            }
            let item = d.GetResult()?;
            let p = item.GetDisplayName(SIGDN_FILESYSPATH)?;
            let s = p.to_string().ok();
            CoTaskMemFree(Some(p.0 as *const core::ffi::c_void));
            Ok(s)
        })();
        if init.is_ok() {
            CoUninitialize();
        }
        r.ok().flatten().filter(|s| !s.is_empty())
    }
}
