//! Les thèmes personnalisés de la suite (packs), comme `modules\packs.ps1` : l'import d'un zip pour Mindset et pour
//! chaque appli de la liste (`Import-PackSuite`, `Set-DossierPack`), les nouvelles versions qui attendent le prochain
//! démarrage (`Complete-PacksEnAttente`), la suppression (`Remove-PackSuite`, `Remove-DossiersPack`,
//! `Get-DossiersPackSuite`) et la liste des thèmes à retirer plus tard (`Get-PacksARetirer`, `Set-PacksARetirer`,
//! `Clear-PacksARetirer`). La lecture d'un pack (`Get-ThemePack`) est celle de `suite_commun::themes` (voir
//! [`crate::theme`]).
//!
//! Les dossiers, comme la version PowerShell :
//! - `<données de Mindset>\packs\<id>` pour Mindset, `<données de la suite>\<Appli>\packs\<id>` pour chaque appli ;
//! - `<données de Mindset>\packs-en-attente\<Appli>\<id>` : une nouvelle version qui n'a pas pu remplacer l'ancienne
//!   (prise par une appli ouverte) ;
//! - `<données de Mindset>\packs-anciens\<8 hex>` : les anciennes versions échangées, avant leur suppression ;
//! - `<données de Mindset>\packs-a-retirer.txt` : les thèmes supprimés dont un dossier était encore pris.

use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

/// 60 Mo : le poids total d'un thème.
const TOTAL_MAX: u64 = 60 * 1024 * 1024;
const MO: u64 = 1024 * 1024;

/// `^[a-z0-9-]{1,40}$` en respectant la casse (`-cmatch`) : l'id d'un pack, le nom de son dossier.
pub fn id_valable(id: &str) -> bool {
    (1..=40).contains(&id.len()) && id.bytes().all(|o| o.is_ascii_lowercase() || o.is_ascii_digit() || o == b'-')
}

/// `\w` de .NET (lettres, chiffres décimaux, marques, ponctuation de liaison comme « _ »), à peu près.
fn mot(c: char) -> bool {
    c.is_alphabetic() || c.is_numeric() || c == '_' || c == '\u{203F}' || c == '\u{2040}'
}

/// `Test-NomFichierPack` : `^[\w .()-]{1,80}$` (sans tenir compte des majuscules) et pas de « .. ».
pub fn nom_fichier_valable(nom: &str) -> bool {
    let n = nom.chars().count();
    (1..=80).contains(&n) && !nom.contains("..") && nom.chars().all(|c| mot(c) || " .()-".contains(c))
}

/// Le texte de `ConvertFrom-Json` vu par `Test-NomFichierPack` (seulement une chaîne).
fn nom_fichier_valeur(v: &Value) -> bool {
    v.as_str().is_some_and(nom_fichier_valable)
}

/// `-eq` de PowerShell entre deux textes : sans tenir compte des majuscules.
pub fn egal(a: &str, b: &str) -> bool {
    a == b || a.to_lowercase() == b.to_lowercase()
}

/// La fin d'un nom de fichier, comme `-match '\.(png|...)$'` (sans tenir compte des majuscules).
fn extension_parmi(nom: &str, ext: &[&str]) -> bool {
    let bas = nom.to_lowercase();
    ext.iter().any(|e| bas.ends_with(&format!(".{e}")))
}

const EXT_IMAGES: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];
const EXT_POLICES: &[&str] = &["ttf", "otf"];

/// `Get-FormatImagePack` : le format d'une image d'après ses 12 premiers octets.
pub fn format_image(b: &[u8]) -> Option<&'static str> {
    if b.len() < 12 {
        return None;
    }
    if b[..4] == [0x89, 0x50, 0x4E, 0x47] {
        return Some("png");
    }
    if b[..3] == [0xFF, 0xD8, 0xFF] {
        return Some("jpeg");
    }
    if b.starts_with(b"GIF8") {
        return Some("gif");
    }
    if b.starts_with(b"RIFF") && &b[8..12] == b"WEBP" {
        return Some("webp");
    }
    None
}

/// Les lettres accentuées les plus courantes et leur lettre de base (`Normalize(FormD)` puis `\p{Mn}` retiré).
fn sans_accent(c: char) -> Option<char> {
    const TABLE: &[(&str, char)] = &[
        ("àáâãäåāăą", 'a'),
        ("ÀÁÂÃÄÅĀĂĄ", 'A'),
        ("çćĉċč", 'c'),
        ("ÇĆĈĊČ", 'C'),
        ("ďḍ", 'd'),
        ("ĎḌ", 'D'),
        ("èéêëēĕėęě", 'e'),
        ("ÈÉÊËĒĔĖĘĚ", 'E'),
        ("ĝğġģ", 'g'),
        ("ĜĞĠĢ", 'G'),
        ("ĥ", 'h'),
        ("Ĥ", 'H'),
        ("ìíîïĩīĭįİ", 'i'),
        ("ÌÍÎÏĨĪĬĮ", 'I'),
        ("ĵ", 'j'),
        ("Ĵ", 'J'),
        ("ķ", 'k'),
        ("Ķ", 'K'),
        ("ĺļľ", 'l'),
        ("ĹĻĽ", 'L'),
        ("ñńņň", 'n'),
        ("ÑŃŅŇ", 'N'),
        ("òóôõöōŏő", 'o'),
        ("ÒÓÔÕÖŌŎŐ", 'O'),
        ("ŕŗř", 'r'),
        ("ŔŖŘ", 'R'),
        ("śŝşš", 's'),
        ("ŚŜŞŠ", 'S'),
        ("ţť", 't'),
        ("ŢŤ", 'T'),
        ("ùúûüũūŭůűų", 'u'),
        ("ÙÚÛÜŨŪŬŮŰŲ", 'U'),
        ("ŵ", 'w'),
        ("Ŵ", 'W'),
        ("ýÿŷ", 'y'),
        ("ÝŶŸ", 'Y'),
        ("źżž", 'z'),
        ("ŹŻŽ", 'Z'),
    ];
    TABLE.iter().find(|(l, _)| l.contains(c)).map(|(_, b)| *b)
}

/// L'id d'un thème d'après le nom de son zip, comme `Import-PackSuite` : sans « Thème- » devant, sans accents, tout
/// ce qui n'est ni lettre, ni chiffre, ni « _ », ni « - » devient « - », en minuscules, sans « - » aux bouts.
pub fn id_depuis_zip(zip: &Path) -> String {
    let base = zip.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    // (^(?i)th[eè]me-)
    let mut reste = base.as_str();
    let debut: Vec<char> = reste.chars().take(6).collect();
    if debut.len() == 6
        && debut[0].eq_ignore_ascii_case(&'t')
        && debut[1].eq_ignore_ascii_case(&'h')
        && (debut[2].eq_ignore_ascii_case(&'e') || debut[2] == 'è' || debut[2] == 'È')
        && debut[3].eq_ignore_ascii_case(&'m')
        && debut[4].eq_ignore_ascii_case(&'e')
        && debut[5] == '-'
    {
        let n: usize = debut.iter().map(|c| c.len_utf8()).sum();
        reste = &reste[n..];
    }
    let mut s = String::new();
    for c in reste.chars() {
        // (les marques seules, U+0300 à U+036F, disparaissent comme \p{Mn})
        if ('\u{300}'..='\u{36F}').contains(&c) {
            continue;
        }
        let c = sans_accent(c).unwrap_or(c);
        s.push(if mot(c) || c == '-' { c } else { '-' });
    }
    s.to_lowercase().trim_matches('-').to_string()
}

/// Ce que le bloc sait des dossiers, et à qui noter.
pub struct Packs<'a> {
    /// `$PacksDir` : `<données de Mindset>\packs`
    pub packs: PathBuf,
    /// `$SuiteDir` : les données de la suite
    pub suite: PathBuf,
    /// `<données de Mindset>`
    pub donnees: PathBuf,
    /// Les applis de la liste : (Nom, Id), dans l'ordre
    pub applis: Vec<(String, String)>,
    pub journal: &'a dyn Fn(&str),
}

/// Ce que rend un import réussi.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Import {
    pub id: String,
    /// `$script:PackRemplace` : un thème du même nom était déjà installé
    pub remplace: bool,
    /// `$script:PackEnAttente` : les applis dont l'ancienne version était prise
    pub attente: Vec<String>,
    /// Les applis où il a été installé
    pub installes: Vec<String>,
}

impl Packs<'_> {
    pub fn en_attente(&self) -> PathBuf {
        self.donnees.join("packs-en-attente")
    }
    pub fn anciens(&self) -> PathBuf {
        self.donnees.join("packs-anciens")
    }
    pub fn fichier_a_retirer(&self) -> PathBuf {
        self.donnees.join("packs-a-retirer.txt")
    }

    fn noter(&self, t: &str) {
        (self.journal)(t)
    }

    /// `Get-PackAppliFichiers` : (nom de l'appli, fichier de réglage), Mindset d'abord.
    pub fn fichiers_applis(&self) -> Vec<(String, String)> {
        let mut f = vec![("Mindset".to_string(), "pack-mindset.json".to_string())];
        for (nom, id) in &self.applis {
            // ([ordered]@{} : une clé déjà là est remplacée sans changer de place)
            let fichier = format!("pack-{id}.json");
            match f.iter_mut().find(|(n, _)| egal(n, nom)) {
                Some(x) => x.1 = fichier,
                None => f.push((nom.clone(), fichier)),
            }
        }
        f
    }

    /// Le dossier du pack pour cette appli (« Mindset » ou le nom d'une appli).
    fn dossier_pour(&self, appli: &str, id: &str) -> PathBuf {
        if egal(appli, "Mindset") { self.packs.join(id) } else { self.suite.join(appli).join("packs").join(id) }
    }

    /// `Get-PacksARetirer`
    pub fn a_retirer(&self) -> Vec<String> {
        let Ok(o) = std::fs::read(self.fichier_a_retirer()) else { return Vec::new() };
        let t = suite_commun::json_sur::texte_du_fichier(&o);
        let mut l: Vec<String> = Vec::new();
        for ligne in t.split('\n') {
            let x = ligne.trim_end_matches('\r').trim();
            if id_valable(x) && !l.iter().any(|y| y == x) {
                l.push(x.to_string());
            }
        }
        l
    }

    /// `Set-PacksARetirer`
    pub fn ecrire_a_retirer(&self, ids: &[String]) {
        let mut l: Vec<&str> = Vec::new();
        for x in ids {
            if id_valable(x) && !l.contains(&x.as_str()) {
                l.push(x);
            }
        }
        let f = self.fichier_a_retirer();
        let r = if l.is_empty() {
            if f.exists() { std::fs::remove_file(&f) } else { Ok(()) }
        } else {
            let mut t = String::new();
            for x in l {
                t.push_str(x);
                t.push_str("\r\n");
            }
            std::fs::write(&f, t)
        };
        if let Err(e) = r {
            self.noter(&format!("Liste des thèmes à retirer : {e}"));
        }
    }

    /// `Set-DossierPack` : met `nouveau` à la place de `dest`. `Ok(false)` si l'ancien est pris (il reste entier, et
    /// `nouveau` n'a pas bougé).
    pub fn mettre_en_place(&self, nouveau: &Path, dest: &Path) -> std::io::Result<bool> {
        if !dest.exists() {
            std::fs::rename(nouveau, dest)?;
            return Ok(true);
        }
        std::fs::create_dir_all(self.anciens())?;
        let ancien = self.anciens().join(nom_ancien());
        let mut ok = false;
        for n in 0..3 {
            if std::fs::rename(dest, &ancien).is_ok() {
                ok = true;
                break;
            }
            if n < 2 {
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        }
        if !ok {
            return Ok(false);
        }
        if let Err(e) = std::fs::rename(nouveau, dest) {
            let _ = std::fs::rename(&ancien, dest);
            return Err(e);
        }
        let _ = std::fs::remove_dir_all(&ancien); // (sinon retiré au prochain démarrage)
        Ok(true)
    }

    /// `Complete-PacksEnAttente` : au démarrage, les nouvelles versions en attente sont mises en place, et les
    /// anciennes versions restées prises sont supprimées.
    pub fn terminer_attentes(&self) {
        for d in sous_dossiers(&self.anciens()) {
            let _ = std::fs::remove_dir_all(&d);
        }
        let attente = self.en_attente();
        if !attente.exists() {
            return;
        }
        let a_retirer = self.a_retirer();
        let fichiers = self.fichiers_applis();
        for a in sous_dossiers(&attente) {
            let nom_appli = feuille(&a);
            for p in sous_dossiers(&a) {
                let id = feuille(&p);
                let connue = fichiers.iter().any(|(n, _)| egal(n, &nom_appli));
                if !connue || !id_valable(&id) || a_retirer.iter().any(|x| egal(x, &id)) {
                    let _ = std::fs::remove_dir_all(&p);
                    continue;
                }
                let dest = self.dossier_pour(&nom_appli, &id);
                match self.mettre_en_place(&p, &dest) {
                    Ok(true) => self.noter(&format!("Thème {id} : nouvelle version mise en place pour {nom_appli}")),
                    Ok(false) => {}
                    Err(e) => self.noter(&format!(
                        "Thème {id} : nouvelle version pour {nom_appli} pas mise en place ({})",
                        message(&e)
                    )),
                }
            }
        }
    }

    /// `Get-DossiersPackSuite` : les dossiers du pack, chacun juste sous un dossier « packs ».
    pub fn dossiers_du_pack(&self, id: &str) -> Vec<PathBuf> {
        if !id_valable(id) {
            return Vec::new();
        }
        let mut l = Vec::new();
        for (appli, _) in self.fichiers_applis() {
            let racine =
                if egal(&appli, "Mindset") { self.packs.clone() } else { self.suite.join(&appli).join("packs") };
            if racine.file_name().is_some_and(|f| egal(&f.to_string_lossy(), "packs")) {
                l.push(racine.join(id));
            }
        }
        l
    }

    /// `Remove-DossiersPack` : vrai si tout est parti.
    pub fn retirer_dossiers(&self, id: &str) -> bool {
        let mut tout = true;
        for d in self.dossiers_du_pack(id) {
            let nouveau = PathBuf::from(format!("{}.nouveau", d.display()));
            for x in [d, nouveau] {
                if !x.exists() {
                    continue;
                }
                match std::fs::remove_dir_all(&x) {
                    Ok(()) => self.noter(&format!("Thème {id} retiré : {}", x.display())),
                    Err(e) => {
                        tout = false;
                        self.noter(&format!("Thème {id} : {} pas encore retiré ({})", x.display(), message(&e)));
                    }
                }
            }
        }
        let attente = self.en_attente();
        if id_valable(id) && attente.exists() {
            for a in sous_dossiers(&attente) {
                let x = a.join(id);
                if x.exists() && std::fs::remove_dir_all(&x).is_err() {
                    tout = false;
                }
            }
        }
        tout
    }

    /// `Remove-PackSuite`
    pub fn supprimer(&self, id: &str) -> bool {
        if !id_valable(id) {
            return false;
        }
        let ok = self.retirer_dossiers(id);
        let mut l: Vec<String> = self.a_retirer().into_iter().filter(|x| !egal(x, id)).collect();
        if !ok {
            l.push(id.to_string());
        }
        self.ecrire_a_retirer(&l);
        self.noter(&format!(
            "Thème de la suite supprimé : {id}{}",
            if ok { "" } else { " (des dossiers encore pris, retirés plus tard)" }
        ));
        ok
    }

    /// `Clear-PacksARetirer`
    pub fn nettoyer(&self) {
        self.terminer_attentes();
        let l = self.a_retirer();
        if l.is_empty() {
            return;
        }
        let reste: Vec<String> = l.into_iter().filter(|x| !self.retirer_dossiers(x)).collect();
        self.ecrire_a_retirer(&reste);
    }

    /// `Get-ThemePack <id>` existe-t-il (lisible, pour Mindset) ?
    fn pack_lisible(&self, id: &str) -> bool {
        crate::theme::pack(id, &self.packs, self.journal).is_some()
    }

    /// `Import-PackSuite` : le zip vérifié, puis installé pour Mindset et pour chaque appli qu'il prévoit. `Err` : le
    /// message pour l'utilisateur.
    pub fn importer(&self, zip: &Path) -> Result<Import, String> {
        let id = id_depuis_zip(zip);
        // (-notmatch '^[a-z0-9-]{1,40}$' : sans tenir compte des majuscules, mais l'id est déjà en minuscules)
        if !id_valable(&id) {
            return Err("Le nom de ce fichier ne convient pas pour un thème (lettres, chiffres et tirets).".into());
        }
        let remplace = self.pack_lisible(&id) && !self.a_retirer().iter().any(|x| egal(x, &id));
        let mut attente = Vec::new();
        let f = std::fs::File::open(zip).map_err(|e| format!("Ce fichier ne peut pas être lu ({}).", message(&e)))?;
        let mut za = zip::ZipArchive::new(f).map_err(|_| "Ce fichier n'est pas un zip lisible.".to_string())?;

        // Les entrées qui ont un nom (pas les dossiers) : (index, nom complet, nom, taille)
        let mut entrees: Vec<(usize, String, String, u64)> = Vec::new();
        for i in 0..za.len() {
            let e = za.by_index_raw(i).map_err(|_| "Ce fichier n'est pas un zip lisible.".to_string())?;
            let complet =
                e.name().map(|n| n.into_owned()).map_err(|_| "Ce fichier n'est pas un zip lisible.".to_string())?;
            let nom = complet.rsplit(['/', '\\']).next().unwrap_or("").to_string();
            if !nom.is_empty() {
                entrees.push((i, complet, nom, e.size()));
            }
        }
        if !entrees.iter().any(|e| egal(&e.2, "pack-mindset.json")) {
            if entrees.iter().any(|e| egal(&e.2, "pack.json")) {
                return Err("Ce zip est un thème pour une seule appli. Un thème de la suite contient pack-mindset.json, puis un réglage par appli (pack-nevermind.json...).".into());
            }
            return Err("Ce zip ne contient pas de thème de la suite (pack-mindset.json).".into());
        }
        let total: u64 = entrees.iter().map(|e| e.3).sum();
        if total > TOTAL_MAX {
            return Err("Ce thème est trop lourd (plus de 60 Mo).".into());
        }
        // Seulement des fichiers simples (pas de dossier) aux extensions attendues, chacun d'un poids raisonnable ; une
        // image est vraiment une image
        for (i, complet, nom, taille) in &entrees {
            let ext_ok = extension_parmi(nom, &["png", "jpg", "jpeg", "gif", "webp", "ttf", "otf", "json"]);
            if !egal(complet, nom) || !nom_fichier_valable(nom) || !ext_ok {
                return Err(format!("Fichier inattendu dans le thème : {complet}"));
            }
            let max = if extension_parmi(nom, &["json"]) {
                MO
            } else if extension_parmi(nom, EXT_POLICES) {
                10 * MO
            } else {
                15 * MO
            };
            if *taille > max {
                return Err(format!("Ce fichier du thème est trop lourd : {nom} (plus de {} Mo).", max / MO));
            }
            if extension_parmi(nom, EXT_IMAGES) && format_image(&debut(&mut za, *i)).is_none() {
                return Err(format!("Ce fichier du thème n'est pas une image : {nom}"));
            }
        }
        // Chaque réglage : ses couleurs bien écrites et sa police un simple nom de fichier du thème
        for (i, _, nom, _) in &entrees {
            if !like_pack_json(nom) {
                continue;
            }
            let texte = lire_texte(&mut za, *i);
            let Some(r) = lire_json_ps(&texte) else { continue };
            if !suite_commun::protocole_installateur::vrai_ps(&r) {
                continue;
            }
            let Value::Object(o) = &r else { continue };
            let police = champ(o, "Font");
            let police_mal = police.is_some_and(|p| !p.is_null() && !nom_fichier_valeur(p));
            if !couleurs_valables(champ(o, "Colors")) || police_mal {
                return Err(format!(
                    "Ce thème contient une couleur ou une police mal écrite ({nom}) : il n'a pas été importé."
                ));
            }
        }
        let mut installes = Vec::new();
        // Réimporté après une suppression pas finie : ce qui restait de l'ancien est retiré d'abord
        if self.a_retirer().iter().any(|x| egal(x, &id)) {
            let _ = self.retirer_dossiers(&id);
            let l: Vec<String> = self.a_retirer().into_iter().filter(|x| !egal(x, &id)).collect();
            self.ecrire_a_retirer(&l);
        }
        for (appli, fichier) in self.fichiers_applis() {
            let Some(reglage) = entrees.iter().find(|e| egal(&e.2, &fichier)).map(|e| e.0) else { continue };
            let dest = self.dossier_pour(&appli, &id);
            let tmp = PathBuf::from(format!("{}.nouveau", dest.display()));
            let r: std::io::Result<()> = (|| {
                if tmp.exists() {
                    std::fs::remove_dir_all(&tmp)?;
                }
                std::fs::create_dir_all(&tmp)?;
                for (i, _, nom, _) in &entrees {
                    if like_pack_json(nom) {
                        continue;
                    }
                    extraire(&mut za, *i, &tmp.join(nom))?;
                }
                extraire(&mut za, reglage, &tmp.join("pack.json"))?;
                let attente_d = self.en_attente().join(&appli).join(&id);
                if attente_d.exists() {
                    std::fs::remove_dir_all(&attente_d)?;
                }
                if self.mettre_en_place(&tmp, &dest)? {
                    installes.push(appli.clone());
                } else {
                    if let Some(p) = attente_d.parent() {
                        std::fs::create_dir_all(p)?;
                    }
                    std::fs::rename(&tmp, &attente_d)?;
                    attente.push(appli.clone());
                }
                Ok(())
            })();
            r.map_err(|e| message(&e))?;
        }
        if !self.pack_lisible(&id) {
            return Err("Le réglage de ce thème pour Mindset (pack-mindset.json) est illisible.".into());
        }
        let mut ligne = format!(
            "Thème de la suite {} : {id} ({})",
            if remplace { "mis à jour" } else { "importé" },
            installes.join(", ")
        );
        if !attente.is_empty() {
            ligne.push_str(&format!(
                " ; nouvelle version mise en place au prochain démarrage de Mindset pour {} (thème utilisé)",
                attente.join(", ")
            ));
        }
        self.noter(&ligne);
        Ok(Import { id, remplace, attente, installes })
    }
}

/// `-like 'pack-*.json'` (sans tenir compte des majuscules).
fn like_pack_json(nom: &str) -> bool {
    let b = nom.to_lowercase();
    b.starts_with("pack-") && b.ends_with(".json") && b.len() >= "pack-.json".len()
}

/// Une propriété d'un objet, sans tenir compte des majuscules (`$r.Colors`, `PSObject.Properties['Font']`).
fn champ<'a>(o: &'a Map<String, Value>, nom: &str) -> Option<&'a Value> {
    o.get(nom).or_else(|| o.iter().find(|(k, _)| egal(k, nom)).map(|(_, v)| v))
}

/// `^#[0-9A-Fa-f]{6}\z` (`-cmatch`)
fn couleur(v: &str) -> bool {
    v.len() == 7 && v.starts_with('#') && v[1..].bytes().all(|o| o.is_ascii_hexdigit())
}

/// `^#?[0-9A-Fa-f]{6}\z` (`-cmatch`)
fn couleur_map(v: &str) -> bool {
    let v = v.strip_prefix('#').unwrap_or(v);
    v.len() == 6 && v.bytes().all(|o| o.is_ascii_hexdigit())
}

/// `Test-CouleursPack` (`Colors` d'un réglage) : rien, ou P, S et T « #RRGGBB » et Map « RRGGBB » vers « RRGGBB ».
pub fn couleurs_valables(c: Option<&Value>) -> bool {
    let o = match c {
        None | Some(Value::Null) => return true,
        Some(Value::Object(o)) => o,
        Some(_) => return false,
    };
    for n in ["P", "S", "T"] {
        if let Some(v) = champ(o, n)
            && !v.as_str().is_some_and(couleur)
        {
            return false;
        }
    }
    match champ(o, "Map") {
        None | Some(Value::Null) => true,
        Some(Value::Object(m)) => m.iter().all(|(k, v)| couleur_map(k) && v.as_str().is_some_and(couleur_map)),
        Some(_) => false,
    }
}

/// Deux propriétés qui ne diffèrent que par les majuscules : `ConvertFrom-Json` de Windows PowerShell refuse tout le
/// texte.
fn cles_en_double(v: &Value) -> bool {
    match v {
        Value::Object(o) => {
            let mut vues = std::collections::BTreeSet::new();
            o.iter().any(|(k, x)| !vues.insert(k.to_lowercase()) || cles_en_double(x))
        }
        Value::Array(a) => a.iter().any(cles_en_double),
        _ => false,
    }
}

/// `ConvertFrom-Json` d'un texte (sans la marque UTF-8 devant) : `None` s'il est illisible.
fn lire_json_ps(texte: &str) -> Option<Value> {
    let t = texte.trim_start_matches('\u{FEFF}');
    let v: Value = serde_json::from_str(t).ok()?;
    if cles_en_double(&v) { None } else { Some(v) }
}

fn debut<R: Read + std::io::Seek>(za: &mut zip::ZipArchive<R>, i: usize) -> Vec<u8> {
    let mut b = Vec::new();
    if let Ok(e) = za.by_index(i) {
        let _ = e.take(12).read_to_end(&mut b);
    }
    b
}

fn lire_texte<R: Read + std::io::Seek>(za: &mut zip::ZipArchive<R>, i: usize) -> String {
    let mut b = Vec::new();
    if let Ok(mut e) = za.by_index(i) {
        let _ = e.read_to_end(&mut b);
    }
    suite_commun::json_sur::texte_du_fichier(&b)
}

fn extraire<R: Read + std::io::Seek>(za: &mut zip::ZipArchive<R>, i: usize, vers: &Path) -> std::io::Result<()> {
    let mut e = za.by_index(i).map_err(std::io::Error::other)?;
    let mut f = std::fs::File::create(vers)?;
    std::io::copy(&mut e, &mut f)?;
    Ok(())
}

fn sous_dossiers(d: &Path) -> Vec<PathBuf> {
    let Ok(l) = std::fs::read_dir(d) else { return Vec::new() };
    let mut v: Vec<PathBuf> =
        l.flatten().filter(|e| e.file_type().is_ok_and(|t| t.is_dir())).map(|e| e.path()).collect();
    v.sort_by_key(|p| feuille(p).to_uppercase());
    v
}

pub fn feuille(p: &Path) -> String {
    p.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Un nom de 8 chiffres hexadécimaux pour une ancienne version (`[guid]::NewGuid().ToString('N').Substring(0, 8)`).
fn nom_ancien() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    static COMPTEUR: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    let c = COMPTEUR.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("{:08x}", n.wrapping_mul(2_654_435_761) ^ std::process::id().rotate_left(16) ^ c.wrapping_mul(40_503))
}

/// Le message d'une erreur du disque, en mots simples.
pub fn message(e: &std::io::Error) -> String {
    match e.kind() {
        std::io::ErrorKind::PermissionDenied => "accès refusé, ou fichier utilisé par un autre programme".into(),
        std::io::ErrorKind::NotFound => "introuvable".into(),
        _ => match e.raw_os_error() {
            Some(32) | Some(33) => "fichier utilisé par un autre programme".into(),
            Some(145) => "le dossier n'est pas vide".into(),
            _ => e.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_du_zip() {
        assert_eq!(id_depuis_zip(Path::new(r"C:\x\Thème-Café crème.zip")), "cafe-creme");
        assert_eq!(id_depuis_zip(Path::new(r"C:\x\THEME-Forêt.zip")), "foret");
        assert_eq!(id_depuis_zip(Path::new(r"C:\x\--Été 2026--.zip")), "ete-2026");
        assert_eq!(id_depuis_zip(Path::new(r"C:\x\a_b.zip")), "a_b");
        assert!(!id_valable(&id_depuis_zip(Path::new(r"C:\x\a_b.zip"))));
        assert_eq!(id_depuis_zip(Path::new(r"C:\x\Thème-.zip")), "");
    }

    #[test]
    fn noms_et_couleurs() {
        assert!(nom_fichier_valable("logo (1).png"));
        assert!(!nom_fichier_valable("a..png"));
        assert!(!nom_fichier_valable("a/b.png"));
        assert!(couleurs_valables(None));
        assert!(couleurs_valables(Some(&serde_json::json!({ "P": "#112233" }))));
        assert!(!couleurs_valables(Some(&serde_json::json!({ "P": null }))));
        assert!(!couleurs_valables(Some(&serde_json::json!("rouge"))));
        assert!(couleurs_valables(Some(&serde_json::json!({ "Map": { "#0C0920": "1A0B12" } }))));
        assert!(!couleurs_valables(Some(&serde_json::json!({ "Map": { "0C0920": 5 } }))));
        assert_eq!(format_image(b"GIF89a......"), Some("gif"));
        assert_eq!(format_image(b"RIFF\0\0\0\0WEBP"), Some("webp"));
        assert_eq!(format_image(b"pas une image"), None);
    }
}
