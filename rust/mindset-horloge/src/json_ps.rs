//! La lecture d'un fichier JSON comme `ConvertFrom-Json` de Windows PowerShell 5.1, et la conversion `[string]` de ce
//! qu'il rend : c'est ainsi que Mindset 2.18 lisait `notification.demande` (zone.ps1:137-140).
//!
//! PowerShell 5.1 passe par le `JavaScriptSerializer` de .NET, plus souple que le JSON strict sur certains points
//! et plus exigeant sur d'autres. Tout ce qui suit a été relevé sur la vraie version PowerShell (les juges
//! `tests/juges/notifications.json`, exportés par `outils/exporter-juges-horloge.ps1`) :
//! - textes entre guillemets doubles ou simples, retours à la ligne et tabulations bruts permis ; échappements
//!   `\" \' \\ \/ \b \f \n \r \t \uXXXX` seulement (un autre : illisible) ;
//! - noms de champs sans guillemets permis (`{titre:"x"}`, `{1:"x"}`) ; un nom vide rend le fichier illisible ;
//!   deux noms qui ne diffèrent que par les majuscules aussi ; le même nom deux fois : le dernier gagne ;
//! - nombres : sans exposant, entier 32 bits, puis 64 bits, puis décimal .NET (le nombre de chiffres après la
//!   virgule est gardé : « 1.50 ») ; avec exposant (ou trop grand), nombre à virgule flottante (« 1E+30 ») ; `NaN`,
//!   `Infinity`, `-Infinity` permis ; `01`, `.5`, `+1`, `1.` permis ; `0x10`, `1e`, `-`, mot nu : illisible ;
//! - `true`, `false`, `null` en minuscules seulement ; ni commentaire ni virgule finale ;
//! - `"\/Date(<ms>)\/"` devient une date (écrite « MM/dd/yyyy HH:mm:ss », en temps universel).

/// Une valeur telle que PowerShell la tient après `ConvertFrom-Json`.
#[derive(Debug, Clone, PartialEq)]
pub enum Ps {
    Nul,
    Booleen(bool),
    /// Un nombre : son texte `[string]` et sa valeur (pour savoir s'il est « vrai »)
    Nombre(String, f64),
    Texte(String),
    /// Une date (`\/Date(..)\/`) : son texte `[string]`
    Date(String),
    Tableau(Vec<Ps>),
    /// Un objet : ses champs dans l'ordre (les noms sont uniques, sans tenir compte des majuscules)
    Objet(Vec<(String, Ps)>),
}

/// `$texte | ConvertFrom-Json` : `None` si PowerShell refuse le texte (ou s'il est vide : `$null`).
pub fn lire(texte: &str) -> Option<Ps> {
    let mut l = Lecteur { c: texte.chars().collect(), i: 0 };
    l.blancs();
    if l.fin() {
        return None;
    }
    let v = l.valeur(0)?;
    l.blancs();
    if !l.fin() {
        return None;
    }
    Some(v)
}

struct Lecteur {
    c: Vec<char>,
    i: usize,
}

impl Lecteur {
    fn fin(&self) -> bool {
        self.i >= self.c.len()
    }
    fn vu(&self) -> Option<char> {
        self.c.get(self.i).copied()
    }
    fn blancs(&mut self) {
        while self.vu().is_some_and(char::is_whitespace) {
            self.i += 1;
        }
    }

    fn valeur(&mut self, profondeur: usize) -> Option<Ps> {
        // (la limite du JavaScriptSerializer : 100 niveaux)
        if profondeur > 100 {
            return None;
        }
        self.blancs();
        match self.vu()? {
            '{' => self.objet(profondeur),
            '[' => self.tableau(profondeur),
            '"' | '\'' => {
                let (t, brut) = self.texte()?;
                Some(date(&brut).map(Ps::Date).unwrap_or(Ps::Texte(t)))
            }
            _ => self.simple(),
        }
    }

    fn objet(&mut self, profondeur: usize) -> Option<Ps> {
        self.i += 1;
        let mut champs: Vec<(String, Ps)> = Vec::new();
        self.blancs();
        if self.vu()? == '}' {
            self.i += 1;
            return Some(Ps::Objet(champs));
        }
        loop {
            self.blancs();
            let nom = match self.vu()? {
                '"' | '\'' => self.texte()?.0,
                _ => {
                    let debut = self.i;
                    while self.vu().is_some_and(jeton) {
                        self.i += 1;
                    }
                    self.c[debut..self.i].iter().collect()
                }
            };
            self.blancs();
            if self.vu()? != ':' {
                return None;
            }
            self.i += 1;
            let v = self.valeur(profondeur + 1)?;
            if nom.is_empty() {
                return None;
            }
            match champs.iter_mut().find(|(n, _)| *n == nom) {
                Some(c) => c.1 = v,
                None => champs.push((nom, v)),
            }
            self.blancs();
            match self.vu()? {
                ',' => self.i += 1,
                '}' => {
                    self.i += 1;
                    break;
                }
                _ => return None,
            }
        }
        // (deux noms qui ne diffèrent que par les majuscules : PowerShell refuse de les lire)
        for (k, (a, _)) in champs.iter().enumerate() {
            if champs[k + 1..].iter().any(|(b, _)| egal_sans_casse(a, b)) {
                return None;
            }
        }
        Some(Ps::Objet(champs))
    }

    fn tableau(&mut self, profondeur: usize) -> Option<Ps> {
        self.i += 1;
        let mut l = Vec::new();
        self.blancs();
        if self.vu()? == ']' {
            self.i += 1;
            return Some(Ps::Tableau(l));
        }
        loop {
            l.push(self.valeur(profondeur + 1)?);
            self.blancs();
            match self.vu()? {
                ',' => self.i += 1,
                ']' => {
                    self.i += 1;
                    return Some(Ps::Tableau(l));
                }
                _ => return None,
            }
        }
    }

    /// Un texte entre guillemets : (le texte, le texte brut tel qu'écrit dans le fichier, échappements compris).
    fn texte(&mut self) -> Option<(String, String)> {
        let q = self.vu()?;
        self.i += 1;
        let debut = self.i;
        let mut t = String::new();
        loop {
            let c = self.vu()?;
            self.i += 1;
            if c == q {
                break;
            }
            if c != '\\' {
                t.push(c);
                continue;
            }
            let e = self.vu()?;
            self.i += 1;
            match e {
                '"' | '\'' | '\\' | '/' => t.push(e),
                'b' => t.push('\u{8}'),
                'f' => t.push('\u{c}'),
                'n' => t.push('\n'),
                'r' => t.push('\r'),
                't' => t.push('\t'),
                'u' => {
                    let h: String = self.c.get(self.i..self.i + 4)?.iter().collect();
                    let n = u16::from_str_radix(&h, 16).ok().filter(|_| h.chars().all(|c| c.is_ascii_hexdigit()))?;
                    self.i += 4;
                    // (une moitié de paire seule devient « � », comme l'écriture en UTF-8 de .NET)
                    t.push(char::from_u32(u32::from(n)).unwrap_or('\u{FFFD}'));
                    if (0xD800..0xDC00).contains(&n) {
                        // une paire écrite en deux \u : recollée
                        if self.c.get(self.i) == Some(&'\\') && self.c.get(self.i + 1) == Some(&'u') {
                            let h2: String =
                                self.c.get(self.i + 2..self.i + 6).map(|x| x.iter().collect()).unwrap_or_default();
                            if let Ok(n2) = u16::from_str_radix(&h2, 16)
                                && (0xDC00..0xE000).contains(&n2)
                            {
                                t.pop();
                                t.push_str(&String::from_utf16_lossy(&[n, n2]));
                                self.i += 6;
                            }
                        }
                    }
                }
                _ => return None,
            }
        }
        let brut = self.c[debut..self.i - 1].iter().collect();
        Some((t, brut))
    }

    /// `true`, `false`, `null` ou un nombre (le reste : illisible).
    fn simple(&mut self) -> Option<Ps> {
        let debut = self.i;
        while self.vu().is_some_and(jeton) {
            self.i += 1;
        }
        let jeton: String = self.c[debut..self.i].iter().collect();
        match jeton.as_str() {
            "" => None,
            "null" => Some(Ps::Nul),
            "true" => Some(Ps::Booleen(true)),
            "false" => Some(Ps::Booleen(false)),
            _ => nombre(&jeton),
        }
    }
}

/// Un caractère d'un mot nu (nombre, `true`, nom de champ sans guillemets) : lettre, chiffre, `.`, `-`, `_` ou `+`
/// (JavaScriptObjectDeserializer.DeserializePrimitiveToken).
fn jeton(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '.' | '-' | '_' | '+')
}

fn egal_sans_casse(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}

/// `\/Date(<ms>)\/` (le texte brut) : la date, écrite comme `[string]` l'écrit (« 01/01/1970 00:00:00 »).
fn date(brut: &str) -> Option<String> {
    let ms: i64 = brut.strip_prefix(r"\/Date(")?.strip_suffix(r")\/")?.parse().ok()?;
    let s = ms.div_euclid(1000);
    let jours = s.div_euclid(86_400);
    let r = s.rem_euclid(86_400);
    let (a, m, j) = civil(jours);
    if !(1..=9999).contains(&a) {
        return None;
    }
    Some(format!("{m:02}/{j:02}/{a:04} {:02}:{:02}:{:02}", r / 3600, r % 3600 / 60, r % 60))
}

/// Le jour (année, mois, jour) à tant de jours du 1er janvier 1970.
fn civil(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let ere = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let j = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let a = yoe + ere * 400 + i64::from(m <= 2);
    (a, m, j)
}

// -------------------------------------------------------------------------------------------------------------------
// Les nombres (JavaScriptObjectDeserializer.DeserializePrimitiveObject)
// -------------------------------------------------------------------------------------------------------------------

fn nombre(jeton: &str) -> Option<Ps> {
    let exposant = jeton.contains(['e', 'E']);
    if !exposant {
        if !jeton.contains('.')
            && let Some(n) = entier(jeton)
        {
            return Some(Ps::Nombre(n.to_string(), n as f64));
        }
        if let Some((t, x)) = decimal(jeton) {
            return Some(Ps::Nombre(t, x));
        }
    }
    let x = flottant(jeton)?;
    Some(Ps::Nombre(texte_flottant(x), x))
}

/// `Int32.TryParse` puis `Int64.TryParse` (NumberStyles.Integer : un signe devant).
fn entier(t: &str) -> Option<i64> {
    let (moins, ch) = signe(t);
    if ch.is_empty() || !ch.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let v: i128 = ch.parse().ok()?;
    let v = if moins { -v } else { v };
    i64::try_from(v).ok()
}

fn signe(t: &str) -> (bool, &str) {
    match t.as_bytes().first() {
        Some(b'-') => (true, &t[1..]),
        Some(b'+') => (false, &t[1..]),
        _ => (false, t),
    }
}

/// Le plus grand décimal .NET : 2^96 - 1.
const DECIMAL_MAX: u128 = 79_228_162_514_264_337_593_543_950_335;

/// `decimal.TryParse` (NumberStyles.Number : un signe devant ou derrière, une virgule décimale) et son `[string]`.
fn decimal(t: &str) -> Option<(String, f64)> {
    let (mut moins, mut ch) = signe(t);
    if ch.len() == t.len() {
        if let Some(r) = t.strip_suffix('-') {
            moins = true;
            ch = r;
        } else if let Some(r) = t.strip_suffix('+') {
            ch = r;
        }
    }
    let (ent, frac) = match ch.split_once('.') {
        Some((a, b)) => (a, b),
        None => (ch, ""),
    };
    if (ent.is_empty() && frac.is_empty()) || !ent.bytes().chain(frac.bytes()).all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut chiffres: Vec<u8> = ent.bytes().chain(frac.bytes()).map(|b| b - b'0').collect();
    let mut echelle = frac.len();
    // (au plus 28 chiffres après la virgule, et une mantisse de 96 bits : arrondi par le chiffre suivant)
    loop {
        let premiers = chiffres.iter().take_while(|&&c| c == 0).count();
        let utiles = &chiffres[premiers.min(chiffres.len())..];
        let tient = utiles.len() <= 29 && valeur(utiles).is_some_and(|v| v <= DECIMAL_MAX);
        if echelle <= 28 && tient {
            break;
        }
        if echelle == 0 {
            return None;
        }
        let dernier = chiffres.pop().unwrap_or(0);
        echelle -= 1;
        if dernier >= 5 {
            arrondir_haut(&mut chiffres);
        }
    }
    let v = valeur(&chiffres).unwrap_or(0);
    let mut s = v.to_string();
    if s.len() <= echelle {
        s = format!("{}{s}", "0".repeat(echelle + 1 - s.len()));
    }
    let (a, b) = s.split_at(s.len() - echelle);
    let mut texte = if echelle > 0 { format!("{a}.{b}") } else { a.to_string() };
    if moins && v != 0 {
        texte.insert(0, '-');
    }
    let x: f64 = texte.parse().unwrap_or(0.0);
    Some((texte, x))
}

fn valeur(chiffres: &[u8]) -> Option<u128> {
    chiffres.iter().try_fold(0u128, |v, &c| v.checked_mul(10)?.checked_add(u128::from(c)))
}

fn arrondir_haut(chiffres: &mut Vec<u8>) {
    for c in chiffres.iter_mut().rev() {
        if *c == 9 {
            *c = 0;
        } else {
            *c += 1;
            return;
        }
    }
    chiffres.insert(0, 1);
}

/// `Double.TryParse` (NumberStyles.Float, culture invariante) : `NaN`, `Infinity`, `-Infinity` compris.
fn flottant(t: &str) -> Option<f64> {
    match t {
        "NaN" => return Some(f64::NAN),
        "Infinity" | "+Infinity" => return Some(f64::INFINITY),
        "-Infinity" => return Some(f64::NEG_INFINITY),
        _ => {}
    }
    let (_, ch) = signe(t);
    let (mantisse, exp) = match ch.find(['e', 'E']) {
        Some(p) => (&ch[..p], Some(&ch[p + 1..])),
        None => (ch, None),
    };
    let (a, b) = mantisse.split_once('.').unwrap_or((mantisse, ""));
    if (a.is_empty() && b.is_empty()) || !a.bytes().chain(b.bytes()).all(|c| c.is_ascii_digit()) {
        return None;
    }
    if let Some(e) = exp {
        let (_, ce) = signe(e);
        if ce.is_empty() || !ce.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
    }
    let normal = format!(
        "{}{}.{}{}",
        if t.starts_with('-') { "-" } else { "" },
        if a.is_empty() { "0" } else { a },
        if b.is_empty() { "0" } else { b },
        exp.map(|e| format!("e{e}")).unwrap_or_default()
    );
    // (trop grand pour un double, « 1e400 » : .NET Framework refuse le nombre, le fichier est illisible)
    normal.parse::<f64>().ok().filter(|x| x.is_finite())
}

/// `Double.ToString()` de .NET Framework (« G », 15 chiffres) : « 150 », « 0.002 », « 1E+30 », « 1.23456789012346E+29 ».
pub fn texte_flottant(x: f64) -> String {
    if x.is_nan() {
        return "NaN".into();
    }
    if x.is_infinite() {
        return if x > 0.0 { "Infinity".into() } else { "-Infinity".into() };
    }
    if x == 0.0 {
        return "0".into();
    }
    let e = format!("{:.14e}", x.abs());
    let (m, ex) = e.split_once('e').unwrap_or((&e, "0"));
    let ex: i32 = ex.parse().unwrap_or(0);
    let chiffres: String = m.chars().filter(char::is_ascii_digit).collect();
    let chiffres = chiffres.trim_end_matches('0');
    let chiffres = if chiffres.is_empty() { "0" } else { chiffres };
    let signe = if x < 0.0 { "-" } else { "" };
    if (-4..15).contains(&ex) {
        let n = chiffres.len() as i32;
        let t = if ex >= 0 {
            let ent = (ex + 1) as usize;
            if chiffres.len() <= ent {
                format!("{chiffres}{}", "0".repeat(ent - chiffres.len()))
            } else {
                format!("{}.{}", &chiffres[..ent], &chiffres[ent..])
            }
        } else {
            let _ = n;
            format!("0.{}{chiffres}", "0".repeat((-ex - 1) as usize))
        };
        format!("{signe}{t}")
    } else {
        let m =
            if chiffres.len() > 1 { format!("{}.{}", &chiffres[..1], &chiffres[1..]) } else { chiffres.to_string() };
        format!("{signe}{m}E{}{:02}", if ex < 0 { "-" } else { "+" }, ex.abs())
    }
}

// -------------------------------------------------------------------------------------------------------------------
// Ce que les fonctions de zone.ps1 font de la valeur
// -------------------------------------------------------------------------------------------------------------------

/// `$j.<nom>` : un champ d'un objet (sans tenir compte des majuscules), ou l'énumération des membres d'un tableau
/// (chaque objet donne son champ, absent : `$null` ; un champ qui est un tableau est déplié ; un tableau dans le
/// tableau est parcouru ; le reste ne donne rien). Un seul résultat : lui-même ; aucun : `$null`.
pub fn membre(v: &Ps, nom: &str) -> Ps {
    match v {
        Ps::Objet(c) => champ(c, nom),
        Ps::Tableau(_) => {
            let mut l = Vec::new();
            enumerer(v, nom, &mut l);
            match l.len() {
                0 => Ps::Nul,
                1 => l.remove(0),
                _ => Ps::Tableau(l),
            }
        }
        _ => Ps::Nul,
    }
}

fn champ(c: &[(String, Ps)], nom: &str) -> Ps {
    c.iter().find(|(n, _)| egal_sans_casse(n, nom)).map(|(_, v)| v.clone()).unwrap_or(Ps::Nul)
}

fn enumerer(v: &Ps, nom: &str, l: &mut Vec<Ps>) {
    let Ps::Tableau(t) = v else { return };
    for e in t {
        match e {
            Ps::Objet(c) => match champ(c, nom) {
                Ps::Tableau(x) => l.extend(x),
                x => l.push(x),
            },
            Ps::Tableau(_) => enumerer(e, nom, l),
            _ => {}
        }
    }
}

/// `[string]$x`
pub fn texte(v: &Ps) -> String {
    match v {
        Ps::Tableau(t) => t.iter().map(dans_tableau).collect::<Vec<_>>().join(" "),
        Ps::Objet(c) if c.is_empty() => String::new(),
        Ps::Objet(c) => {
            let champs: Vec<String> = c.iter().map(|(k, x)| format!("{k}={}", dans_tableau(x))).collect();
            format!("@{{{}}}", champs.join("; "))
        }
        _ => dans_tableau(v),
    }
}

/// Une valeur écrite à l'intérieur d'un tableau ou d'un objet : un tableau devient « System.Object[] », un objet
/// devient vide.
fn dans_tableau(v: &Ps) -> String {
    match v {
        Ps::Nul | Ps::Objet(_) => String::new(),
        Ps::Booleen(true) => "True".into(),
        Ps::Booleen(false) => "False".into(),
        Ps::Nombre(t, _) | Ps::Texte(t) | Ps::Date(t) => t.clone(),
        Ps::Tableau(_) => "System.Object[]".into(),
    }
}

/// Vrai au sens de PowerShell (`if ($j)`).
pub fn vrai(v: &Ps) -> bool {
    match v {
        Ps::Nul => false,
        Ps::Booleen(b) => *b,
        Ps::Nombre(_, x) => *x != 0.0,
        Ps::Texte(t) => !t.is_empty(),
        Ps::Date(_) | Ps::Objet(_) => true,
        Ps::Tableau(t) => match t.len() {
            0 => false,
            // (un seul élément qui est lui-même un tableau : vrai s'il n'est pas vide, LanguagePrimitives.IsTrue)
            1 => match &t[0] {
                Ps::Tableau(x) => !x.is_empty(),
                x => vrai(x),
            },
            _ => true,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titre(t: &str) -> Option<String> {
        lire(t).map(|v| texte(&membre(&v, "titre")))
    }

    #[test]
    fn nombres_comme_dotnet() {
        assert_eq!(titre(r#"{"titre":1.0}"#).unwrap(), "1.0");
        assert_eq!(titre(r#"{"titre":-12.50}"#).unwrap(), "-12.50");
        assert_eq!(titre(r#"{"titre":1.5e2}"#).unwrap(), "150");
        assert_eq!(titre(r#"{"titre":2E-3}"#).unwrap(), "0.002");
        assert_eq!(titre(r#"{"titre":1e30}"#).unwrap(), "1E+30");
        assert_eq!(titre(r#"{"titre":1e-30}"#).unwrap(), "1E-30");
        assert_eq!(titre(r#"{"titre":123456789012345678901234567890}"#).unwrap(), "1.23456789012346E+29");
        assert_eq!(
            titre(r#"{"titre":0.123456789012345678901234567890123}"#).unwrap(),
            "0.1234567890123456789012345679"
        );
        assert_eq!(titre(r#"{"titre":-0.0}"#).unwrap(), "0.0");
        assert_eq!(titre(r#"{"titre":5-}"#).unwrap(), "-5");
        assert_eq!(titre(r#"{"titre":1e}"#), None);
        assert_eq!(texte_flottant(1e15), "1E+15");
        assert_eq!(texte_flottant(1e14), "100000000000000");
        assert_eq!(texte_flottant(0.0001), "0.0001");
        assert_eq!(texte_flottant(0.00001), "1E-05");
    }

    #[test]
    fn souplesse_et_refus() {
        assert_eq!(titre("{'titre':'a\"b'}").unwrap(), "a\"b");
        assert_eq!(titre("{titre:\"Nu\"}").unwrap(), "Nu");
        assert_eq!(titre(r#"{"titre":"a","titre":"b"}"#).unwrap(), "b");
        assert_eq!(titre(r#"{"titre":"a","Titre":"b"}"#), None);
        assert_eq!(titre(r#"{"":"x"}"#), None);
        assert_eq!(titre(r#"{"titre":"V",}"#), None);
        assert_eq!(titre(r#"{"titre":"\/Date(0)\/"}"#).unwrap(), "01/01/1970 00:00:00");
        assert_eq!(titre(r#"{"titre":"😀"}"#).unwrap(), "😀");
        assert_eq!(titre(r#"[{"texte":"x"},{"texte":"y"}]"#).unwrap(), " ");
        assert_eq!(titre(r#"{"titre":{"a":null,"b":false,"c":1.50}}"#).unwrap(), "@{a=; b=False; c=1.50}");
        assert!(lire("").is_none() && lire("  ").is_none());
    }
}
