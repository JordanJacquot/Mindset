//! Comptes (SID, noms) et droits des dossiers : ce que faisaient NTAccount.Translate, Get-Acl et Set-Acl.

use super::outils::{MemoireLocale, Sid, sid_de_texte, sid_texte, texte};
use mindset_installateur::systeme::{Droits, RegleAcces};
use windows::Win32::Foundation::{HANDLE, WIN32_ERROR};
use windows::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, EXPLICIT_ACCESS_W, GRANT_ACCESS, GetNamedSecurityInfoW,
    NO_MULTIPLE_TRUSTEE, SDDL_REVISION_1, SE_FILE_OBJECT, SetEntriesInAclW, SetNamedSecurityInfoW, TRUSTEE_IS_SID,
    TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
};
use windows::Win32::Security::{
    ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, GetAce, GetSecurityDescriptorDacl, GetSecurityDescriptorOwner,
    GetTokenInformation, LookupAccountNameW, LookupAccountSidW, OWNER_SECURITY_INFORMATION,
    PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, SID_NAME_USE, SUB_CONTAINERS_AND_OBJECTS_INHERIT,
    TOKEN_QUERY, TOKEN_USER, TokenUser, UNPROTECTED_DACL_SECURITY_INFORMATION,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows::core::{BOOL, HSTRING, PCWSTR, PWSTR};

/// Le compte (SID) d'un jeton
pub fn compte_du_jeton(jeton: HANDLE) -> Option<String> {
    let mut n = 0u32;
    // SAFETY : premier appel pour la taille, second avec un tampon aligné de cette taille, qui contient un
    // TOKEN_USER rempli par Windows
    unsafe {
        let _ = GetTokenInformation(jeton, TokenUser, None, 0, &mut n);
        if n == 0 {
            return None;
        }
        let mut b = vec![0u64; (n as usize).div_ceil(8)];
        GetTokenInformation(jeton, TokenUser, Some(b.as_mut_ptr().cast()), n, &mut n).ok()?;
        let u = &*(b.as_ptr() as *const TOKEN_USER);
        sid_texte(u.User.Sid)
    }
}

/// Le compte sous lequel tourne ce programme
pub fn compte_courant() -> String {
    let mut j = HANDLE::default();
    // SAFETY : jeton de ce processus, en lecture, refermé par Poignee
    unsafe {
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut j).is_err() {
            return String::new();
        }
        let j = super::outils::Poignee(j);
        compte_du_jeton(j.0).unwrap_or_default()
    }
}

/// Le SID d'un nom de compte (« SYSTEM », « PC\Élodie »), comme NTAccount.Translate
pub fn sid_de_nom(nom: &str) -> Option<String> {
    let n = HSTRING::from(nom);
    let mut taille_sid = 0u32;
    let mut taille_domaine = 0u32;
    let mut usage = SID_NAME_USE::default();
    // SAFETY : premier appel pour les tailles, second avec des tampons de ces tailles
    unsafe {
        let _ = LookupAccountNameW(PCWSTR::null(), &n, None, &mut taille_sid, None, &mut taille_domaine, &mut usage);
        if taille_sid == 0 {
            return None;
        }
        let mut sid = vec![0u64; (taille_sid as usize).div_ceil(8)];
        let mut domaine = vec![0u16; taille_domaine as usize + 1];
        LookupAccountNameW(
            PCWSTR::null(),
            &n,
            Some(PSID(sid.as_mut_ptr().cast())),
            &mut taille_sid,
            Some(PWSTR(domaine.as_mut_ptr())),
            &mut taille_domaine,
            &mut usage,
        )
        .ok()?;
        sid_texte(PSID(sid.as_mut_ptr().cast()))
    }
}

/// Le nom d'un compte (« PC\Élodie »), comme SecurityIdentifier.Translate([NTAccount])
pub fn nom_de_sid(sid: &str) -> Option<String> {
    let s = sid_de_texte(sid)?;
    let mut n = 0u32;
    let mut d = 0u32;
    let mut usage = SID_NAME_USE::default();
    // SAFETY : premier appel pour les tailles, second avec des tampons de ces tailles
    unsafe {
        let _ = LookupAccountSidW(PCWSTR::null(), s.psid, None, &mut n, None, &mut d, &mut usage);
        if n == 0 {
            return None;
        }
        let mut nom = vec![0u16; n as usize + 1];
        let mut domaine = vec![0u16; d as usize + 1];
        LookupAccountSidW(
            PCWSTR::null(),
            s.psid,
            Some(PWSTR(nom.as_mut_ptr())),
            &mut n,
            Some(PWSTR(domaine.as_mut_ptr())),
            &mut d,
            &mut usage,
        )
        .ok()?;
        let (nom, domaine) = (texte(&nom), texte(&domaine));
        Some(if domaine.is_empty() { nom } else { format!("{domaine}\\{nom}") })
    }
}

/// Les droits d'un dossier : son propriétaire et les entrées de sa liste d'accès
pub fn droits(dossier: &str) -> Option<Droits> {
    let mut proprietaire = PSID::default();
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let mut sd = PSECURITY_DESCRIPTOR::default();
    // SAFETY : descripteur rendu par Windows (libéré par MemoireLocale) ; le propriétaire et la liste pointent dedans
    unsafe {
        let r = GetNamedSecurityInfoW(
            &HSTRING::from(dossier),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            Some(&mut proprietaire),
            None,
            Some(&mut dacl),
            None,
            &mut sd,
        );
        if r != WIN32_ERROR(0) {
            return None;
        }
        let _m = MemoireLocale(sd.0);
        let mut regles = Vec::new();
        if !dacl.is_null() {
            for i in 0..u32::from((*dacl).AceCount) {
                let mut ace: *mut core::ffi::c_void = std::ptr::null_mut();
                if GetAce(dacl, i, &mut ace).is_err() || ace.is_null() {
                    continue;
                }
                let h = &*(ace as *const ACE_HEADER);
                // ACCESS_ALLOWED_ACE (0) et ACCESS_DENIED_ACE (1) : en-tête, droits, puis le SID
                if h.AceType > 1 {
                    continue;
                }
                let masque = *((ace as *const u8).add(4) as *const u32);
                let sid = PSID((ace as *mut u8).add(8).cast());
                regles.push(RegleAcces {
                    sid: sid_texte(sid).unwrap_or_default(),
                    autorise: h.AceType == 0,
                    herite_seulement: h.AceFlags & 0x08 != 0,
                    masque,
                });
            }
        }
        Some(Droits { proprietaire: sid_texte(proprietaire), regles })
    }
}

/// Pose un descripteur (en SDDL) sur un dossier : propriétaire et liste d'accès protégée (sans hériter du parent)
pub fn poser_sddl(dossier: &str, sddl: &str) -> Result<(), String> {
    let mut sd = PSECURITY_DESCRIPTOR::default();
    // SAFETY : descripteur créé par Windows et libéré par MemoireLocale ; propriétaire et liste lus dedans
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(&HSTRING::from(sddl), SDDL_REVISION_1, &mut sd, None)
            .map_err(|e| e.message())?;
        let _m = MemoireLocale(sd.0);
        let mut proprietaire = PSID::default();
        let mut defaut = BOOL::default();
        GetSecurityDescriptorOwner(sd, &mut proprietaire, &mut defaut).map_err(|e| e.message())?;
        let mut present = BOOL::default();
        let mut dacl: *mut ACL = std::ptr::null_mut();
        GetSecurityDescriptorDacl(sd, &mut present, &mut dacl, &mut defaut).map_err(|e| e.message())?;
        let r = SetNamedSecurityInfoW(
            &HSTRING::from(dossier),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            Some(proprietaire),
            None,
            Some(dacl),
            None,
        );
        if r.0 != 0 {
            return Err(format!("Droits non posés sur {dossier} (erreur {})", r.0));
        }
    }
    Ok(())
}

/// Le dossier appartient désormais à ce compte (SID)
pub fn poser_proprietaire(dossier: &str, sid: &str) -> Result<(), String> {
    let s: Sid = sid_de_texte(sid).ok_or("Compte inconnu.")?;
    // SAFETY : SID valable tant que `s` vit
    let r = unsafe {
        SetNamedSecurityInfoW(
            &HSTRING::from(dossier),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            Some(s.psid),
            None,
            None,
            None,
        )
    };
    if r.0 != 0 {
        return Err(format!("Propriétaire non posé sur {dossier} (erreur {})", r.0));
    }
    Ok(())
}

/// Ajoute à la liste d'accès d'un dossier un droit pour un compte (hérité par tout ce qu'il contient)
pub fn ajouter_droit(dossier: &str, sid: &str, masque: u32) -> Result<(), String> {
    let s: Sid = sid_de_texte(sid).ok_or("Compte inconnu.")?;
    let mut ancienne: *mut ACL = std::ptr::null_mut();
    let mut sd = PSECURITY_DESCRIPTOR::default();
    // SAFETY : descripteur rendu par Windows (libéré par MemoireLocale) ; nouvelle liste créée par Windows (libérée
    // aussi) ; le SID vit tant que `s` vit
    unsafe {
        let r = GetNamedSecurityInfoW(
            &HSTRING::from(dossier),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(&mut ancienne),
            None,
            &mut sd,
        );
        if r.0 != 0 {
            return Err(format!("Droits illisibles sur {dossier} (erreur {})", r.0));
        }
        let _m = MemoireLocale(sd.0);
        let entree = EXPLICIT_ACCESS_W {
            grfAccessPermissions: masque,
            grfAccessMode: GRANT_ACCESS,
            grfInheritance: SUB_CONTAINERS_AND_OBJECTS_INHERIT,
            Trustee: TRUSTEE_W {
                pMultipleTrustee: std::ptr::null_mut(),
                MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_UNKNOWN,
                ptstrName: PWSTR(s.psid.0.cast()),
            },
        };
        let mut nouvelle: *mut ACL = std::ptr::null_mut();
        let r = SetEntriesInAclW(Some(&[entree]), Some(ancienne), &mut nouvelle);
        if r.0 != 0 {
            return Err(format!("Droits non préparés (erreur {})", r.0));
        }
        let _n = MemoireLocale(nouvelle.cast());
        let r = SetNamedSecurityInfoW(
            &HSTRING::from(dossier),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | UNPROTECTED_DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(nouvelle),
            None,
        );
        if r.0 != 0 {
            return Err(format!("Droits non posés sur {dossier} (erreur {})", r.0));
        }
    }
    Ok(())
}
