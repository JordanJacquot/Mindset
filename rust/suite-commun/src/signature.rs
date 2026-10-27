//! Vérification des signatures des zips, comme `Test-Signature` (Mindset\fichiers\modules\signature.ps1).
//!
//! Chaque zip publié est accompagné de `<zip>.sig` : sa signature RSA PKCS#1 v1.5 avec SHA-256, faite par
//! outils\signer.ps1 avec la clé privée de Jordan. On vérifie avec les clés publiques livrées avec Mindset
//! (fichiers\cles-publiques\*.xml, au format XML de .NET). Rien ne change pour la clé ni pour signer.ps1.
//!
//! Mêmes règles que la version PowerShell :
//! - la liste des clés est lue EN ENTIER avant de vérifier quoi que ce soit ;
//! - liste vide, fichier abîmé, clé privée glissée dans la liste ou clé de moins de 3072 bits : tout est refusé
//!   (une liste anormale n'est jamais à moitié crue) ;
//! - une signature est bonne si UNE des clés de la liste la vérifie.

use std::path::Path;

use ring::signature::{RSA_PKCS1_2048_8192_SHA256, RsaPublicKeyComponents};

use crate::texte::{SansMarque, decoder_fichier};
use crate::{base64, xml};

/// Taille minimale d'une clé, en bits.
pub const TAILLE_MINIMALE: usize = 3072;

/// Une clé publique RSA lue dans un fichier XML.
#[derive(Debug, Clone)]
pub struct ClePublique {
    /// Le module (n), tel qu'écrit dans le fichier
    pub module: Vec<u8>,
    /// L'exposant (e), tel qu'écrit dans le fichier
    pub exposant: Vec<u8>,
}

impl ClePublique {
    /// La taille de la clé comme .NET la compte : la longueur du module en octets, fois 8.
    pub fn taille(&self) -> usize {
        self.module.len() * 8
    }

    /// Vrai si cette clé vérifie la signature de `donnees` (RSA PKCS#1 v1.5, SHA-256).
    pub fn verifier(&self, donnees: &[u8], signature: &[u8]) -> bool {
        // (ring refuse les zéros en tête de l'exposant, que .NET accepte ; ceux du module, .NET les compte dans la
        // taille de la clé mais ne vérifie alors plus rien : ring refuse aussi)
        let debut = self.exposant.iter().position(|&o| o != 0).unwrap_or(self.exposant.len());
        let cle = RsaPublicKeyComponents { n: &self.module[..], e: &self.exposant[debut..] };
        cle.verify(&RSA_PKCS1_2048_8192_SHA256, donnees, signature).is_ok()
    }
}

/// Lit une clé publique au format XML de .NET (`RSA.FromXmlString`). `None` si le fichier est abîmé, si c'est une
/// clé privée, ou si la clé fait moins de 3072 bits.
pub fn lire_cle(texte: &str) -> Option<ClePublique> {
    let racine = xml::lire(texte)?;
    // Modulus et Exponent sont obligatoires ; .NET enlève tous les espaces avant de décoder
    let decoder = |nom: &str| -> Option<Option<Vec<u8>>> {
        match racine.chercher_texte(nom) {
            None => Some(None),
            Some(t) => {
                let sans_espaces: String = t.chars().filter(|c| !c.is_whitespace()).collect();
                base64::decoder(&sans_espaces).map(Some)
            }
        }
    };
    let module = decoder("Modulus")??;
    let exposant = decoder("Exponent")??;
    // Aucun élément de clé privée, même vide ou incomplet : plus strict que .NET, qui ne regarde que P (une clé avec
    // D seul y passait pour publique). Même règle dans Test-Signature (PowerShell).
    if ["P", "Q", "DP", "DQ", "InverseQ", "D"].iter().any(|nom| racine.contient(nom)) {
        return None;
    }
    // Limites de Windows (CryptoAPI) : exposant de 4 octets au plus, module de 16384 bits au plus
    if module.is_empty() || exposant.is_empty() || exposant.len() > 4 || module.len() > 2048 {
        return None;
    }
    let cle = ClePublique { module, exposant };
    if cle.taille() < TAILLE_MINIMALE {
        return None;
    }
    Some(cle)
}

/// Les clés d'une liste : un dossier (tous ses fichiers .xml, cachés compris) ou un seul fichier.
/// `None` si la liste est vide, absente, ou si UN fichier n'est pas une bonne clé publique.
pub fn lire_liste(chemin: &Path) -> Option<Vec<ClePublique>> {
    let fichiers: Vec<std::path::PathBuf> = if chemin.is_dir() {
        let mut f = Vec::new();
        for entree in std::fs::read_dir(chemin).ok()? {
            let entree = entree.ok()?;
            let nom = entree.file_name().to_string_lossy().into_owned();
            if entree.file_type().ok()?.is_file() && extension_dotnet(&nom).eq_ignore_ascii_case(".xml") {
                f.push(entree.path());
            }
        }
        f
    } else if chemin.is_file() {
        vec![chemin.to_path_buf()]
    } else {
        return None;
    };
    if fichiers.is_empty() {
        return None;
    }
    let mut cles = Vec::new();
    for f in fichiers {
        let octets = std::fs::read(&f).ok()?;
        cles.push(lire_cle(&decoder_fichier(&octets, SansMarque::Utf8))?);
    }
    Some(cles)
}

/// L'extension d'un nom de fichier comme `FileInfo.Extension` de .NET : depuis le dernier point (« .xml » pour un
/// fichier nommé « .xml »), vide si le nom finit par un point ou n'en a pas.
fn extension_dotnet(nom: &str) -> &str {
    match nom.rfind('.') {
        Some(i) if i + 1 < nom.len() => &nom[i..],
        _ => "",
    }
}

/// Vrai si `signature` est une signature valide de `donnees` par une des clés de `cles` (un dossier de clés ou un
/// fichier). Comme `Test-Signature` : données, signature ou chemin vides, liste anormale : faux.
pub fn verifier_signature(donnees: &[u8], signature: &[u8], cles: &Path) -> bool {
    if donnees.is_empty() || signature.is_empty() || cles.as_os_str().is_empty() {
        return false;
    }
    match lire_liste(cles) {
        Some(liste) => liste.iter().any(|c| c.verifier(donnees, signature)),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension() {
        assert_eq!(extension_dotnet("a.xml"), ".xml");
        assert_eq!(extension_dotnet(".xml"), ".xml");
        assert_eq!(extension_dotnet("b.xml.ancien"), ".ancien");
        assert_eq!(extension_dotnet("a."), "");
        assert_eq!(extension_dotnet("LISEZMOI"), "");
    }

    #[test]
    fn cle_privee_ou_courte_refusee() {
        let m = "A".repeat(512); // 384 octets
        let pub_ok = format!("<RSAKeyValue><Modulus>{m}</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>");
        assert_eq!(lire_cle(&pub_ok).map(|c| c.taille()), Some(3072));
        let privee = format!("<RSAKeyValue><Modulus>{m}</Modulus><Exponent>AQAB</Exponent><P>AQAB</P></RSAKeyValue>");
        assert!(lire_cle(&privee).is_none());
        let d_illisible = format!("<RSAKeyValue><Modulus>{m}</Modulus><Exponent>AQAB</Exponent><D>?</D></RSAKeyValue>");
        assert!(lire_cle(&d_illisible).is_none());
        // Un élément privé, quel qu'il soit, même vide ou sans P : refusé
        for prive in ["<D>AQAB</D>", "<P></P>", "<InverseQ/>", "<x:DQ>AQAB</x:DQ>", "<X><Q>AQAB</Q></X>"] {
            let cle = format!("<RSAKeyValue><Modulus>{m}</Modulus><Exponent>AQAB</Exponent>{prive}</RSAKeyValue>");
            assert!(lire_cle(&cle).is_none(), "{prive}");
        }
        // Modulus et Exponent obligatoires et lisibles
        for sans in [
            "<RSAKeyValue><D>AQAB</D></RSAKeyValue>".to_string(),
            "<RSAKeyValue><Exponent>AQAB</Exponent></RSAKeyValue>".to_string(),
            format!("<RSAKeyValue><Modulus>{m}</Modulus></RSAKeyValue>"),
            format!("<RSAKeyValue><Modulus>{m}</Modulus><Exponent></Exponent></RSAKeyValue>"),
            format!("<RSAKeyValue><Modulus>{m}</Modulus><Exponent>pas du base64</Exponent></RSAKeyValue>"),
        ] {
            assert!(lire_cle(&sans).is_none(), "{sans}");
        }
        let courte =
            format!("<RSAKeyValue><Modulus>{}</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>", "A".repeat(340));
        assert!(lire_cle(&courte).is_none());
        let exposant_long = format!("<RSAKeyValue><Modulus>{m}</Modulus><Exponent>AQABAAE=</Exponent></RSAKeyValue>");
        assert!(lire_cle(&exposant_long).is_none());
    }
}
