//! Les images de la console : le logo tiré de l'icône d'une appli installée (`Get-LogoConsole`, console.ps1:354) et
//! la mascotte animée ou non d'un thème perso (`Test-ImageAnimee`, console.ps1:182).

use std::path::{Path, PathBuf};

/// Une icône plus grosse n'est pas lue (`$ico.Length -gt 2MB`).
pub const ICONE_MAX: u64 = 2 * 1024 * 1024;

fn u16_le(b: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?))
}

fn u32_le(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?))
}

/// La plus grande image PNG d'une icône (.ico), telle quelle ; `None` si l'icône n'en a pas (la console dessine
/// alors la première lettre du nom) ou si elle est abîmée (comme le `catch` de la version PowerShell, qui rend
/// `$null` dès qu'une lecture dépasse la fin du fichier).
pub fn png_de_icone(b: &[u8]) -> Option<Vec<u8>> {
    let n = u16_le(b, 4)? as usize;
    let mut meilleur: Option<(u32, usize, usize)> = None;
    for k in 0..n {
        let o = 6 + 16 * k;
        let w = match *b.get(o)? {
            0 => 256,
            x => u32::from(x),
        };
        let lg = u32_le(b, o + 8)? as usize;
        let dp = u32_le(b, o + 12)? as usize;
        let png = dp as u64 + lg as u64 <= b.len() as u64 && b.get(dp) == Some(&0x89);
        if png && meilleur.is_none_or(|(mw, _, _)| w > mw) {
            meilleur = Some((w, lg, dp));
        }
    }
    let (_, lg, dp) = meilleur?;
    Some(b[dp..dp + lg].to_vec())
}

/// La première icône (.ico) du dossier `fichiers` d'une appli installée, dans l'ordre des noms (comme
/// `Get-ChildItem -Filter '*.ico'`, sans les majuscules), si elle n'est pas trop grosse.
pub fn icone_appli(dossier: &Path) -> Option<PathBuf> {
    let mut l: Vec<(String, PathBuf)> = std::fs::read_dir(dossier.join("fichiers"))
        .ok()?
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .filter_map(|e| {
            let nom = e.file_name().to_string_lossy().to_string();
            nom.to_lowercase().ends_with(".ico").then(|| (nom.to_lowercase(), e.path()))
        })
        .collect();
    l.sort();
    let f = l.into_iter().next()?.1;
    (std::fs::metadata(&f).ok()?.len() <= ICONE_MAX).then_some(f)
}

/// Le format d'une image d'après ses premiers octets (`Get-FormatImagePack`, packs.ps1:128).
fn format(b: &[u8]) -> Option<&'static str> {
    suite_commun::fichier_pack::type_image(b).map(|t| t.trim_start_matches("image/"))
}

fn trouver(b: &[u8], motif: &[u8], depuis: usize) -> Option<usize> {
    b.get(depuis..)?.windows(motif.len()).position(|w| w == motif).map(|i| i + depuis)
}

/// `Test-ImageAnimee` sur des octets : un GIF à plusieurs images (deux blocs « Graphic Control Extension »), un WebP
/// animé (VP8X avec l'animation), un PNG animé (acTL avant les images).
pub fn image_animee(b: &[u8]) -> bool {
    match format(b) {
        Some("gif") => {
            let gce = [0x21, 0xF9, 0x04];
            trouver(b, &gce, 0).is_some_and(|i| trouver(b, &gce, i + 3).is_some())
        }
        Some("webp") => b.len() >= 16 && &b[12..16] == b"VP8X" && b.get(20).is_some_and(|x| x & 0x02 != 0),
        Some("png") => match (trouver(b, b"acTL", 0), trouver(b, b"IDAT", 0)) {
            (Some(a), Some(d)) => a < d,
            (Some(_), None) => true,
            _ => false,
        },
        _ => false,
    }
}

/// `Test-ImageAnimee` sur un fichier (illisible : non).
pub fn fichier_anime(f: &Path) -> bool {
    std::fs::read(f).is_ok_and(|b| image_animee(&b))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn icone(images: &[(u8, &[u8])]) -> Vec<u8> {
        let mut b = vec![0, 0, 1, 0];
        b.extend((images.len() as u16).to_le_bytes());
        let mut dp = 6 + 16 * images.len();
        let mut donnees = Vec::new();
        for (w, d) in images {
            b.extend([*w, *w, 0, 0, 1, 0, 32, 0]);
            b.extend((d.len() as u32).to_le_bytes());
            b.extend((dp as u32).to_le_bytes());
            dp += d.len();
            donnees.extend_from_slice(d);
        }
        b.extend(donnees);
        b
    }

    #[test]
    fn la_plus_grande_image_png() {
        let petit: &[u8] = &[0x89, b'P', b'N', b'G', 1];
        let grand: &[u8] = &[0x89, b'P', b'N', b'G', 2, 2];
        let bmp: &[u8] = &[0x28, 0, 0, 0];
        assert_eq!(png_de_icone(&icone(&[(32, petit), (0, grand), (64, bmp)])), Some(grand.to_vec()));
        assert_eq!(png_de_icone(&icone(&[(48, bmp)])), None);
        assert_eq!(png_de_icone(&[0, 0, 1]), None);
        let mut coupe = icone(&[(32, petit)]);
        coupe.truncate(10);
        assert_eq!(png_de_icone(&coupe), None);
    }

    #[test]
    fn animee() {
        let mut gif = b"GIF89a......".to_vec();
        gif.extend([0x21, 0xF9, 0x04, 0, 0x21, 0xF9, 0x04]);
        assert!(image_animee(&gif));
        assert!(!image_animee(&gif[..15]));
        let mut webp = b"RIFF\0\0\0\0WEBPVP8X".to_vec();
        webp.extend([0, 0, 0, 0, 0x02]);
        assert!(image_animee(&webp));
        webp[20] = 0;
        assert!(!image_animee(&webp));
        let png = [&[0x89, b'P', b'N', b'G', 0, 0, 0, 0, 0, 0, 0, 0][..], b"acTL....IDAT"].concat();
        assert!(image_animee(&png));
        let png2 = [&[0x89, b'P', b'N', b'G', 0, 0, 0, 0, 0, 0, 0, 0][..], b"IDAT....acTL"].concat();
        assert!(!image_animee(&png2));
    }
}
