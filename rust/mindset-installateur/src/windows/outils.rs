//! Petits outils pour parler à Windows : textes en UTF-16, poignées et mémoires rendues toutes seules, SID en texte,
//! VARIANT de COM.

use windows::Win32::Foundation::{CloseHandle, HANDLE, HLOCAL, LocalFree};
use windows::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSidToSidW};
use windows::Win32::Security::PSID;
use windows::Win32::System::Variant::{VARIANT, VT_BSTR, VT_I4, VariantClear};
use windows::core::{BSTR, HSTRING, PWSTR};

/// Un texte Windows (UTF-16, terminé par un zéro) en texte Rust
pub fn texte(b: &[u16]) -> String {
    let n = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf16_lossy(&b[..n])
}

/// Une poignée de Windows, refermée quand elle n'est plus utilisée
pub struct Poignee(pub HANDLE);

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
pub struct MemoireLocale(pub *mut core::ffi::c_void);

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
pub fn message(e: &windows::core::Error) -> String {
    let m = e.message();
    let m = m.trim();
    if m.is_empty() { format!("erreur 0x{:08x}", e.code().0) } else { m.to_string() }
}

/// Un SID en texte (« S-1-5-18 »)
pub fn sid_texte(sid: PSID) -> Option<String> {
    let mut p = PWSTR::null();
    // SAFETY : `sid` est un SID valable ; le texte rendu est libéré par MemoireLocale
    unsafe {
        ConvertSidToStringSidW(sid, &mut p).ok()?;
        let _m = MemoireLocale(p.0.cast());
        p.to_string().ok()
    }
}

/// Un SID lu dans son texte, libéré quand il n'est plus utilisé
pub struct Sid {
    pub psid: PSID,
    _memoire: MemoireLocale,
}

pub fn sid_de_texte(texte: &str) -> Option<Sid> {
    let mut sid = PSID::default();
    // SAFETY : SID créé par Windows, rendu par MemoireLocale
    unsafe { ConvertStringSidToSidW(&HSTRING::from(texte), &mut sid).ok()? };
    Some(Sid { psid: sid, _memoire: MemoireLocale(sid.0) })
}

/// Un VARIANT de COM, vidé quand il n'est plus utilisé
pub struct Variant(pub VARIANT);

impl Variant {
    /// Vide (« pas de valeur »)
    pub fn vide() -> Variant {
        Variant(VARIANT::default())
    }

    /// Un texte
    pub fn texte(t: &str) -> Variant {
        let mut v = VARIANT::default();
        // SAFETY : écriture du type et de la valeur correspondante ; le BSTR est libéré par VariantClear
        unsafe {
            let a = &mut *v.Anonymous.Anonymous;
            a.vt = VT_BSTR;
            a.Anonymous.bstrVal = core::mem::ManuallyDrop::new(BSTR::from(t));
        }
        Variant(v)
    }

    /// Un nombre entier (index d'une collection)
    pub fn nombre(i: i32) -> Variant {
        let mut v = VARIANT::default();
        // SAFETY : écriture du type et de la valeur correspondante
        unsafe {
            let a = &mut *v.Anonymous.Anonymous;
            a.vt = VT_I4;
            a.Anonymous.lVal = i;
        }
        Variant(v)
    }
}

impl Drop for Variant {
    fn drop(&mut self) {
        // SAFETY : VARIANT rempli ici, vidé une seule fois
        unsafe {
            let _ = VariantClear(&mut self.0);
        }
    }
}
