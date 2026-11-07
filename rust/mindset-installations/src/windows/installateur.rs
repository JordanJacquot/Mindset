//! Le vrai mini-installateur (le port `Installateur` du noyau) : `Get-EtatTacheInstallation` (schtasks.exe /Query
//! /XML, sans fenêtre), `Send-DemandeInstallation` (installation.demande puis schtasks.exe /Run),
//! `Remove-DemandeInstallation`, `Get-ValeurInstallation` (HKLM, en lecture), la demande de Windows
//! (MindsetInstallateur.exe en « runas », fenêtre cachée, jamais powershell.exe) et `Test-TachesAnciennes`.

use std::path::PathBuf;
use std::sync::Mutex;

use mindset_noyau::donnees::Dossiers;
use mindset_noyau::installateur::{Direct, EtatTache, Installateur};
use serde_json::Value;
use suite_commun::protocole_installateur::{CLE_INSTALLATION, DOSSIER_TACHES, FICHIER_DEMANDE, TACHE_INSTALLATION};
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::System::Threading::WaitForSingleObject;
use windows::Win32::UI::Shell::{SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW};
use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;
use windows::core::{HSTRING, PCWSTR};

use super::{compte_en_sid, dossier_windows, lancer_systeme, mon_sid, valeur_hklm};
use crate::regles::argument_admin;

/// Le texte rendu par schtasks.exe (UTF-16 s'il commence par sa marque, sinon UTF-8, sinon octet par octet).
fn texte_sortie(o: &[u8]) -> String {
    if o.len() >= 2 && o[0] == 0xFF && o[1] == 0xFE {
        let u: Vec<u16> = o[2..].as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect();
        return String::from_utf16_lossy(&u);
    }
    match std::str::from_utf8(o) {
        Ok(s) => s.to_string(),
        Err(_) => o.iter().map(|b| *b as char).collect(),
    }
}

/// Le texte entre `<balise>` et `</balise>` (la première), entités XML remplacées.
pub fn balise(xml: &str, nom: &str) -> String {
    let debut = format!("<{nom}>");
    let fin = format!("</{nom}>");
    let Some(i) = xml.find(&debut) else { return String::new() };
    let reste = &xml[i + debut.len()..];
    let Some(j) = reste.find(&fin) else { return String::new() };
    reste[..j]
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

/// La règle de `Get-EtatTacheInstallation` sur ce que dit la tâche : son compte (déjà en SID) et ses arguments.
pub fn etat_selon(compte: &str, arguments: &str, moi: &str) -> EtatTache {
    let bas = arguments.to_lowercase();
    let sid = format!("-sid {}", moi.to_lowercase());
    let avec_sid = bas.match_indices(&sid).any(|(i, _)| {
        let apres = &arguments[i + sid.len()..];
        apres.is_empty() || apres.starts_with(char::is_whitespace)
    });
    if compte == "S-1-5-18" && avec_sid {
        return EtatTache::Systeme;
    }
    if !moi.is_empty() && compte == moi && bas.contains("-action demande") && !bas.contains("-sid ") {
        return EtatTache::Ancienne;
    }
    EtatTache::Absente
}

/// Le vrai mini-installateur.
pub struct InstallateurWindows {
    demande: PathBuf,
    installateur: PathBuf,
    directs: Mutex<Vec<Option<isize>>>,
}

impl InstallateurWindows {
    pub fn nouveau(dossiers: &Dossiers) -> InstallateurWindows {
        InstallateurWindows {
            demande: dossiers.donnees.join(FICHIER_DEMANDE),
            installateur: dossiers.mindset.join("MindsetInstallateur.exe"),
            directs: Mutex::new(Vec::new()),
        }
    }

    /// `schtasks /Query /TN <tâche> /XML` : (compte en SID, arguments), `None` si absente ou illisible.
    fn lire_tache(&self, tache: &str) -> Option<(String, String)> {
        let (code, sortie) = lancer_systeme("schtasks.exe", &["/Query", "/TN", tache, "/XML"])?;
        if code != 0 || sortie.is_empty() {
            return None;
        }
        let xml = texte_sortie(&sortie);
        let compte = balise(&xml, "UserId");
        let compte = if !compte.is_empty() && !compte.starts_with("S-1-") { compte_en_sid(&compte) } else { compte };
        Some((compte, balise(&xml, "Arguments")))
    }
}

fn verrou<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Installateur for InstallateurWindows {
    fn etat_tache(&self) -> EtatTache {
        let Some((compte, arguments)) = self.lire_tache(&format!("{DOSSIER_TACHES}{TACHE_INSTALLATION}")) else {
            return EtatTache::Absente;
        };
        etat_selon(&compte, &arguments, &mon_sid())
    }

    fn deposer(&self, demande: &Value) -> Result<(), String> {
        let texte = serde_json::to_string(demande).map_err(|e| e.to_string())?;
        if let Err(e) = std::fs::write(&self.demande, texte) {
            self.retirer_demande();
            return Err(e.to_string());
        }
        let tache = format!("{DOSSIER_TACHES}{TACHE_INSTALLATION}");
        match lancer_systeme("schtasks.exe", &["/Run", "/TN", &tache]) {
            Some((0, _)) => Ok(()),
            r => {
                self.retirer_demande();
                let code = r.map_or(-1, |(c, _)| c);
                Err(format!("la tâche d'installation n'a pas démarré (code {code})"))
            }
        }
    }

    fn retirer_demande(&self) {
        let _ = std::fs::remove_file(&self.demande);
    }

    fn valeur(&self, nom: &str) -> String {
        valeur_hklm(CLE_INSTALLATION, nom)
    }

    fn lancer_direct(&self, d: &Direct) -> Result<u32, String> {
        let refus = || "l'autorisation de Windows a été refusée.".to_string();
        let mut ligne = format!("-Action {} -Resultat {}", d.action, argument_admin(&d.resultat.to_string_lossy())?);
        for (k, v) in &d.parametres {
            if v.is_empty() {
                continue;
            }
            ligne.push_str(&format!(" -{k} {}", argument_admin(v)?));
        }
        let fichier = HSTRING::from(self.installateur.as_os_str());
        let parametres = HSTRING::from(ligne.as_str());
        let dossier = HSTRING::from(dossier_windows().as_str());
        let verbe = HSTRING::from("runas");
        let mut info = SHELLEXECUTEINFOW {
            cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
            fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC,
            lpVerb: PCWSTR(verbe.as_ptr()),
            lpFile: PCWSTR(fichier.as_ptr()),
            lpParameters: PCWSTR(parametres.as_ptr()),
            lpDirectory: PCWSTR(dossier.as_ptr()),
            nShow: SW_HIDE.0,
            ..Default::default()
        };
        // SAFETY : structure remplie ici, textes vivants pendant l'appel ; le handle du programme est gardé, fermé
        // par direct_fini
        unsafe { ShellExecuteExW(&mut info) }.map_err(|_| refus())?;
        let mut l = verrou(&self.directs);
        l.push((!info.hProcess.is_invalid()).then_some(info.hProcess.0 as isize));
        Ok((l.len() - 1) as u32)
    }

    fn direct_fini(&self, numero: u32) -> bool {
        let mut l = verrou(&self.directs);
        let Some(place) = l.get_mut(numero as usize) else { return true };
        let Some(h) = *place else { return true };
        let h = HANDLE(h as *mut core::ffi::c_void);
        // SAFETY : handle gardé par lancer_direct, fermé une seule fois (ici, quand le programme est fini)
        unsafe {
            if WaitForSingleObject(h, 0) == WAIT_OBJECT_0 {
                let _ = CloseHandle(h);
                *place = None;
                return true;
            }
        }
        false
    }

    fn compte_tache(&self, nom: &str) -> Option<String> {
        self.lire_tache(&format!("{DOSSIER_TACHES}{nom}")).map(|(c, _)| c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn regle_de_la_tache() {
        let moi = "S-1-5-21-1-2-3-1001";
        let a = format!(r#"-NoProfile -File "x" -Action demande -Sid {moi} -Demande "y""#);
        assert_eq!(etat_selon("S-1-5-18", &a, moi), EtatTache::Systeme);
        assert_eq!(etat_selon("S-1-5-18", &format!("-Sid {moi}"), moi), EtatTache::Systeme);
        assert_eq!(etat_selon("S-1-5-18", &format!("-Sid {moi}0"), moi), EtatTache::Absente, "un autre compte");
        assert_eq!(etat_selon(moi, "-Action demande -Demande x", moi), EtatTache::Ancienne);
        assert_eq!(etat_selon(moi, &a, moi), EtatTache::Absente);
        assert_eq!(etat_selon("S-1-5-21-9", "-Action demande", moi), EtatTache::Absente);
        assert_eq!(
            balise("<a><UserId>S-1-5-18</UserId><Arguments>-x &quot;y&quot;</Arguments>", "Arguments"),
            "-x \"y\""
        );
    }
}
