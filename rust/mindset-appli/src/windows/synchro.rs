//! Un seul Mindset à la fois (Mindset.ps1:80-98) : le verrou `Local\Mindset-Instance` et le signal
//! `Local\Mindset-Afficher` (automatique : il retombe dès qu'il est lu).
//!
//! - premier lancement : le verrou est créé et pris, le signal est créé ; Mindset le regarde toutes les 300 ms
//!   (interface.ps1:112-117) ;
//! - lancement suivant : le verrou existe déjà. Lancé avec Windows (`-Demarrage`) : rien à faire. Sinon : il autorise la
//!   fenêtre déjà ouverte à passer devant (`AllowSetForegroundWindow(-1)`), lève le signal, et s'en va.
//!
//! Les tests n'utilisent que des noms `Local\MindsetEssai-<pid>-...`, jamais ceux de Mindset.

use windows::Win32::Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, WAIT_OBJECT_0};
use windows::Win32::System::Threading::{
    CreateEventW, CreateMutexW, EVENT_MODIFY_STATE, OpenEventW, ReleaseMutex, SetEvent, WaitForSingleObject,
};
use windows::Win32::UI::WindowsAndMessaging::AllowSetForegroundWindow;
use windows::core::HSTRING;

use super::handle;

/// Le verrou et le signal de ce Mindset, gardés jusqu'à la fin (rendus et fermés quand ils sont lâchés).
#[derive(Debug)]
pub struct Instance {
    verrou: usize,
    signal: usize,
}

impl Drop for Instance {
    fn drop(&mut self) {
        // SAFETY : handles rendus par CreateMutexW et CreateEventW, gardés ici ; rendus puis fermés une seule fois
        unsafe {
            let _ = ReleaseMutex(handle(self.verrou));
            let _ = CloseHandle(handle(self.verrou));
            let _ = CloseHandle(handle(self.signal));
        }
    }
}

impl Instance {
    /// Le signal a-t-il été levé par un autre lancement depuis la dernière fois (`ShowSignal.WaitOne(0)`) ?
    pub fn signal_leve(&self) -> bool {
        // SAFETY : handle du signal gardé par cette instance ; attente nulle
        unsafe { WaitForSingleObject(handle(self.signal), 0) == WAIT_OBJECT_0 }
    }
}

/// Ce qu'a donné la prise du verrou.
#[derive(Debug)]
pub enum Prise {
    /// Le premier Mindset : à lui de tourner
    Premier(Instance),
    /// Un Mindset tourne déjà (le signal a été levé, sauf avec `-Demarrage`)
    DejaOuvert,
    /// Windows a refusé de créer le verrou ou le signal
    Refuse,
}

/// Prend le verrou `verrou` et crée le signal `signal` ; s'ils existent déjà, lève le signal (sauf `demarrage`).
pub fn prendre(verrou: &str, signal: &str, demarrage: bool) -> Prise {
    let nv = HSTRING::from(verrou);
    let ns = HSTRING::from(signal);
    // SAFETY : noms valides pendant les appels ; les handles sont gardés par Instance (fermés une fois) ou fermés ici ;
    // GetLastError lu juste après CreateMutexW
    unsafe {
        let Ok(m) = CreateMutexW(None, true, &nv) else { return Prise::Refuse };
        if GetLastError() == ERROR_ALREADY_EXISTS {
            let _ = CloseHandle(m);
            if !demarrage {
                // (ce lancement vient d'un clic : il autorise la fenêtre déjà ouverte à passer devant)
                let _ = AllowSetForegroundWindow(u32::MAX);
                if let Ok(e) = OpenEventW(EVENT_MODIFY_STATE, false, &ns) {
                    let _ = SetEvent(e);
                    let _ = CloseHandle(e);
                }
            }
            return Prise::DejaOuvert;
        }
        let Ok(e) = CreateEventW(None, false, false, &ns) else {
            let _ = ReleaseMutex(m);
            let _ = CloseHandle(m);
            return Prise::Refuse;
        };
        Prise::Premier(Instance { verrou: m.0 as usize, signal: e.0 as usize })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn noms() -> (String, String) {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let base = format!(r"Local\MindsetEssai-{}-{n}", std::process::id());
        assert!(!base.starts_with(r"Local\Mindset-"));
        (format!("{base}-Instance"), format!("{base}-Afficher"))
    }

    #[test]
    fn un_seul_a_la_fois_et_le_signal_ramene_le_premier() {
        let (v, s) = noms();
        let Prise::Premier(i) = prendre(&v, &s, false) else { panic!("premier") };
        assert!(!i.signal_leve());
        let (v2, s2) = (v.clone(), s.clone());
        // (un autre fil, comme un autre lancement : le verrou est déjà là)
        let r = std::thread::spawn(move || matches!(prendre(&v2, &s2, true), Prise::DejaOuvert)).join().unwrap();
        assert!(r);
        assert!(!i.signal_leve(), "avec -Demarrage, le signal n'est pas levé");
        let (v3, s3) = (v.clone(), s.clone());
        let r = std::thread::spawn(move || matches!(prendre(&v3, &s3, false), Prise::DejaOuvert)).join().unwrap();
        assert!(r);
        assert!(i.signal_leve(), "un clic ramène le premier");
        assert!(!i.signal_leve(), "automatique : retombé après lecture");
        drop(i);
        let Prise::Premier(_j) = prendre(&v, &s, false) else { panic!("rendu : un nouveau premier") };
    }
}
