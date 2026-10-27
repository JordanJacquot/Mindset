//! Lecture minimale d'une clé au format XML de .NET (`<RSAKeyValue><Modulus>...</Modulus>...`).
//!
//! On imite l'analyseur de .NET utilisé par `RSA.FromXmlString` (System.Security.Util.Parser), qui est tolérant :
//! - le nom de l'élément racine n'est pas vérifié ;
//! - une balise fermante ferme l'élément ouvert, quel que soit son nom ;
//! - ce qui suit la fermeture de la racine est ignoré ;
//! - les déclarations (`<?...?>`), commentaires (`<!--...-->`) et `<!...>` sont sautés ;
//! - seules les entités `&lt; &gt; &amp; &quot; &apos;` sont décodées.
//!
//! Un fichier qui s'arrête avant la fermeture de la racine (ou vide) est refusé, comme avec .NET. Le banc d'essai
//! compare ces règles à .NET sur des clés normales et abîmées.

/// Un élément XML : son nom, son texte (s'il n'est pas vide) et ses enfants.
pub struct Element {
    nom: String,
    texte: Option<String>,
    enfants: Vec<Element>,
}

impl Element {
    /// Le texte du premier élément (lui-même, puis ses enfants dans l'ordre) dont le nom local est `nom`
    /// (« Modulus » ou « x:Modulus »). Comme `SecurityElement.SearchForTextOfLocalName`.
    pub fn chercher_texte(&self, nom: &str) -> Option<&str> {
        let local = self.nom == nom || self.nom.strip_suffix(nom).is_some_and(|d| d.ends_with(':'));
        if local {
            return self.texte.as_deref();
        }
        self.enfants.iter().find_map(|e| e.chercher_texte(nom))
    }

    /// Vrai si cet élément ou un de ses descendants a le nom local `nom`, même vide.
    pub fn contient(&self, nom: &str) -> bool {
        let local = self.nom == nom || self.nom.strip_suffix(nom).is_some_and(|d| d.ends_with(':'));
        local || self.enfants.iter().any(|e| e.contient(nom))
    }
}

/// Lit le premier élément du texte. `None` si le texte est vide ou s'arrête avant sa fermeture.
pub fn lire(texte: &str) -> Option<Element> {
    let mut l = Lecteur { t: texte, i: 0 };
    loop {
        l.sauter_espaces();
        if l.reste().starts_with("<?") || l.reste().starts_with("<!") {
            l.sauter_special()?;
        } else if l.reste().starts_with('<') {
            return l.element();
        } else {
            return None;
        }
    }
}

struct Lecteur<'a> {
    t: &'a str,
    i: usize,
}

impl Lecteur<'_> {
    fn reste(&self) -> &str {
        &self.t[self.i..]
    }

    fn sauter_espaces(&mut self) {
        let r = self.reste();
        self.i += r.len() - r.trim_start().len();
    }

    /// Saute jusqu'après `fin` ; `None` si `fin` n'est jamais trouvé.
    fn sauter_jusqua(&mut self, fin: &str) -> Option<()> {
        let p = self.reste().find(fin)?;
        self.i += p + fin.len();
        Some(())
    }

    /// `<?...?>`, `<!--...-->` ou `<!...>`
    fn sauter_special(&mut self) -> Option<()> {
        if self.reste().starts_with("<?") {
            self.sauter_jusqua("?>")
        } else if self.reste().starts_with("<!--") {
            self.sauter_jusqua("-->")
        } else {
            self.sauter_jusqua(">")
        }
    }

    /// Un élément, à partir de son « < ».
    fn element(&mut self) -> Option<Element> {
        self.i += 1;
        let r = self.reste();
        let fin_nom = r.find(|c: char| c.is_whitespace() || c == '/' || c == '>')?;
        let nom = r[..fin_nom].to_string();
        if nom.is_empty() {
            return None;
        }
        self.i += fin_nom;
        // Les attributs sont ignorés (en tenant compte des guillemets)
        let mut guillemet: Option<char> = None;
        let mut vide = false;
        loop {
            let c = self.reste().chars().next()?;
            self.i += c.len_utf8();
            match (guillemet, c) {
                (Some(g), c) if c == g => guillemet = None,
                (Some(_), _) => {}
                (None, '"' | '\'') => guillemet = Some(c),
                (None, '>') => break,
                (None, '/') if self.reste().starts_with('>') => {
                    self.i += 1;
                    vide = true;
                    break;
                }
                _ => {}
            }
        }
        let mut el = Element { nom, texte: None, enfants: Vec::new() };
        if vide {
            return Some(el);
        }
        let mut texte = String::new();
        loop {
            let r = self.reste();
            let p = r.find('<')?;
            texte.push_str(&r[..p]);
            self.i += p;
            if self.reste().starts_with("</") {
                self.sauter_jusqua(">")?;
                break;
            } else if self.reste().starts_with("<?") || self.reste().starts_with("<!") {
                self.sauter_special()?;
            } else {
                el.enfants.push(self.element()?);
            }
        }
        let texte = texte.trim();
        if !texte.is_empty() {
            el.texte = Some(
                texte
                    .replace("&lt;", "<")
                    .replace("&gt;", ">")
                    .replace("&quot;", "\"")
                    .replace("&apos;", "'")
                    .replace("&amp;", "&"),
            );
        }
        Some(el)
    }
}

#[cfg(test)]
mod tests {
    use super::lire;

    #[test]
    fn cle_normale() {
        let e = lire("<RSAKeyValue><Modulus>AQAB</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>").unwrap();
        assert_eq!(e.chercher_texte("Modulus"), Some("AQAB"));
        assert_eq!(e.chercher_texte("D"), None);
    }

    #[test]
    fn tolerances_de_dotnet() {
        let e = lire(
            "<?xml version=\"1.0\"?>\r\n<Cle a='1'><!-- x --><X><a:Modulus>AA</a:Modulus></X><D></D></Autre> reste",
        )
        .unwrap();
        assert_eq!(e.chercher_texte("Modulus"), Some("AA"));
        assert_eq!(e.chercher_texte("D"), None);
        assert!(e.contient("D") && e.contient("Modulus") && !e.contient("P"));
        assert!(lire("").is_none());
        assert!(lire("<RSAKeyValue><Modulus>AA</Modulus>").is_none());
        assert!(lire("pas du xml").is_none());
    }
}
