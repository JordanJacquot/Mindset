//! Programmes ouverts : liste avec leur chemin et leur session, leur compte, arrêt, attente de leur fin (ce que
//! faisaient Get-Process, Win32_Process.GetOwnerSid, Stop-Process et Wait-Process).

use super::outils::Poignee;
use super::securite::compte_du_jeton;
use mindset_installateur::systeme::Processus;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::Security::TOKEN_QUERY;
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows::Win32::System::Threading::{
    OpenProcess, OpenProcessToken, PROCESS_ACCESS_RIGHTS, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    PROCESS_SYNCHRONIZE, PROCESS_TERMINATE, QueryFullProcessImageNameW, TerminateProcess, WaitForSingleObject,
};
use windows::core::PWSTR;

fn ouvrir(pid: u32, acces: PROCESS_ACCESS_RIGHTS) -> Option<Poignee> {
    // SAFETY : simple ouverture, la poignée est refermée par Poignee
    unsafe { OpenProcess(acces, false, pid).ok().map(Poignee) }
}

/// Le chemin complet du programme d'un processus
fn chemin(pid: u32) -> Option<String> {
    let h = ouvrir(pid, PROCESS_QUERY_LIMITED_INFORMATION)?;
    let mut b = vec![0u16; 32768];
    let mut n = b.len() as u32;
    // SAFETY : tampon et taille cohérents
    unsafe { QueryFullProcessImageNameW(h.0, PROCESS_NAME_WIN32, PWSTR(b.as_mut_ptr()), &mut n) }.ok()?;
    Some(String::from_utf16_lossy(&b[..n as usize]))
}

/// La session Windows d'un processus
pub fn session(pid: u32) -> u32 {
    let mut s = u32::MAX;
    // SAFETY : simple lecture
    let _ = unsafe { ProcessIdToSessionId(pid, &mut s) };
    s
}

/// Les programmes ouverts sur le PC
pub fn liste() -> Vec<Processus> {
    let mut r = Vec::new();
    // SAFETY : instantané refermé par Poignee ; structure de la bonne taille
    unsafe {
        let Ok(h) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return r };
        let h = Poignee(h);
        let mut e = PROCESSENTRY32W { dwSize: size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        if Process32FirstW(h.0, &mut e).is_err() {
            return r;
        }
        loop {
            let pid = e.th32ProcessID;
            if pid != 0 {
                r.push(Processus { id: pid, chemin: chemin(pid), session: session(pid) });
            }
            if Process32NextW(h.0, &mut e).is_err() {
                break;
            }
        }
    }
    r
}

/// Le compte d'un processus (SID)
pub fn compte(pid: u32) -> Option<String> {
    let h = ouvrir(pid, PROCESS_QUERY_LIMITED_INFORMATION)?;
    let mut j = HANDLE::default();
    // SAFETY : lecture seule du jeton, refermé par Poignee
    unsafe { OpenProcessToken(h.0, TOKEN_QUERY, &mut j).ok()? };
    let j = Poignee(j);
    compte_du_jeton(j.0)
}

/// Ferme un programme d'un coup (Stop-Process -Force)
pub fn arreter(pid: u32) {
    if let Some(h) = ouvrir(pid, PROCESS_TERMINATE) {
        // SAFETY : poignée ouverte avec le droit de fermer
        let _ = unsafe { TerminateProcess(h.0, 1) };
    }
}

/// Attend la fin d'un programme, au plus `ms` millisecondes
pub fn attendre(pid: u32, ms: u32) {
    if let Some(h) = ouvrir(pid, PROCESS_SYNCHRONIZE) {
        // SAFETY : poignée ouverte avec le droit d'attendre
        let _ = unsafe { WaitForSingleObject(h.0, ms) };
    }
}
