//! Les paramètres de la ligne de commande, lus comme Windows PowerShell liait ceux d'installer-admin.ps1 : mêmes
//! noms (sans tenir compte des majuscules), `-Action` obligatoire et choisie dans la liste, `-Disque` d'une lettre au
//! plus, `-AttendrePid` un nombre entier, `-Cache` sans valeur. Tout autre écart (paramètre inconnu, donné deux fois,
//! sans valeur, valeur sans nom) arrête l'installateur avant qu'il ne fasse quoi que ce soit, sans réponse : comme
//! PowerShell, qui refusait de lancer le script.

use suite_commun::protocole_installateur::entier_ps_texte;

/// Ce qu'on demande à l'installateur.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Appli,
    Mindset,
    MindsetMaj,
    Taches,
    Supprimer,
    Demande,
}

impl Action {
    /// Le nom d'une action (sans tenir compte des majuscules), comme `ValidateSet`.
    pub fn lire(nom: &str) -> Option<Action> {
        Some(match nom.to_ascii_lowercase().as_str() {
            "appli" => Action::Appli,
            "mindset" => Action::Mindset,
            "mindset-maj" => Action::MindsetMaj,
            "taches" => Action::Taches,
            "supprimer" => Action::Supprimer,
            "demande" => Action::Demande,
            _ => return None,
        })
    }
}

/// Les paramètres (un texte absent vaut « », comme un paramètre `[string]` de PowerShell non donné).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parametres {
    pub action: Action,
    pub resultat: String,
    pub demande: String,
    pub zip: String,
    pub signature: String,
    pub destination: String,
    pub dossier_zip: String,
    pub exe: String,
    pub ancien_exe: String,
    pub source: String,
    pub version: String,
    pub attendre_pid: i32,
    pub tache_aide: String,
    pub exe_aide: String,
    pub appli: String,
    pub disque: String,
    pub sid: String,
    pub cache: bool,
}

/// Les noms des paramètres texte, dans l'ordre d'installer-admin.ps1.
const TEXTES: [&str; 16] = [
    "Resultat",
    "Demande",
    "Zip",
    "Signature",
    "Destination",
    "DossierZip",
    "Exe",
    "AncienExe",
    "Source",
    "Version",
    "TacheAide",
    "ExeAide",
    "Appli",
    "Disque",
    "Sid",
    "AttendrePid",
];

impl Parametres {
    /// Le champ texte qui porte ce nom (déjà vérifié).
    fn texte_mut(&mut self, nom: &str) -> Option<&mut String> {
        Some(match nom {
            "Resultat" => &mut self.resultat,
            "Demande" => &mut self.demande,
            "Zip" => &mut self.zip,
            "Signature" => &mut self.signature,
            "Destination" => &mut self.destination,
            "DossierZip" => &mut self.dossier_zip,
            "Exe" => &mut self.exe,
            "AncienExe" => &mut self.ancien_exe,
            "Source" => &mut self.source,
            "Version" => &mut self.version,
            "TacheAide" => &mut self.tache_aide,
            "ExeAide" => &mut self.exe_aide,
            "Appli" => &mut self.appli,
            "Disque" => &mut self.disque,
            "Sid" => &mut self.sid,
            _ => return None,
        })
    }

    /// Le champ texte d'une demande (`Zip`, `Destination`...), pour la lecture d'une demande par la tâche.
    pub fn poser_texte(&mut self, nom: &str, valeur: &str) {
        if let Some(c) = self.texte_mut(nom) {
            *c = valeur.to_string();
        }
    }
}

/// Un nom de paramètre : « -Nom » ou « -Nom:valeur ».
fn nom_parametre(arg: &str) -> Option<(&str, Option<&str>)> {
    let reste = arg.strip_prefix('-')?;
    if !reste.chars().next().is_some_and(|c| c.is_alphabetic() || c == '_') {
        return None;
    }
    Some(match reste.find(':') {
        Some(i) => (&reste[..i], Some(&reste[i + 1..])),
        None => (reste, None),
    })
}

/// Lit la ligne de commande (sans le nom du programme).
pub fn lire(args: &[String]) -> Result<Parametres, String> {
    let mut p = Parametres {
        action: Action::Demande,
        resultat: String::new(),
        demande: String::new(),
        zip: String::new(),
        signature: String::new(),
        destination: String::new(),
        dossier_zip: String::new(),
        exe: String::new(),
        ancien_exe: String::new(),
        source: String::new(),
        version: String::new(),
        attendre_pid: 0,
        tache_aide: String::new(),
        exe_aide: String::new(),
        appli: String::new(),
        disque: String::new(),
        sid: String::new(),
        cache: false,
    };
    let mut action = None;
    let mut vus: Vec<&'static str> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let Some((nom, colle)) = nom_parametre(&args[i]) else {
            return Err(format!("Paramètre sans nom : {}", args[i]));
        };
        i += 1;
        let connu = if nom.eq_ignore_ascii_case("Action") {
            "Action"
        } else if nom.eq_ignore_ascii_case("Cache") {
            "Cache"
        } else {
            TEXTES
                .iter()
                .copied()
                .find(|t| t.eq_ignore_ascii_case(nom))
                .ok_or_else(|| format!("Paramètre inconnu : -{nom}"))?
        };
        if vus.contains(&connu) {
            return Err(format!("Paramètre donné deux fois : -{connu}"));
        }
        vus.push(connu);
        if connu == "Cache" {
            p.cache = match colle.map(str::to_ascii_lowercase).as_deref() {
                None | Some("$true") | Some("true") => true,
                Some("$false") | Some("false") => false,
                Some(_) => return Err("Valeur refusée pour -Cache".into()),
            };
            continue;
        }
        let valeur = match colle {
            Some(v) => v.to_string(),
            None => {
                let v = args
                    .get(i)
                    .filter(|v| nom_parametre(v).is_none())
                    .ok_or_else(|| format!("Valeur absente pour -{connu}"))?;
                i += 1;
                v.clone()
            }
        };
        match connu {
            "Action" => action = Some(Action::lire(&valeur).ok_or_else(|| format!("Action refusée : {valeur}"))?),
            "AttendrePid" => {
                p.attendre_pid = entier_ps_texte(&valeur).ok_or_else(|| format!("Nombre refusé : {valeur}"))?
            }
            "Disque" => {
                let ok = valeur.is_empty()
                    || (valeur.chars().count() == 1 && valeur.chars().all(|c| c.is_ascii_alphabetic()));
                if !ok {
                    return Err(format!("Disque refusé : {valeur}"));
                }
                p.disque = valeur;
            }
            autre => p.poser_texte(autre, &valeur),
        }
    }
    p.action = action.ok_or("Paramètre -Action absent")?;
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(l: &[&str]) -> Vec<String> {
        l.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn comme_powershell() {
        let p = lire(&a(&["-action", "Demande", "-SID", "S-1-5-21-1-2-3-4", "-Demande", r"C:\x\installation.demande"]))
            .unwrap();
        assert_eq!(p.action, Action::Demande);
        assert_eq!(p.sid, "S-1-5-21-1-2-3-4");
        let p = lire(&a(&["-Action", "appli", "-Cache", "-AttendrePid", "12", "-Sid", ""])).unwrap();
        assert!(p.cache && p.attendre_pid == 12 && p.sid.is_empty());
        assert!(lire(&a(&["-Action", "formater"])).is_err());
        assert!(lire(&a(&["-Action", "mindset", "-Disque", "QQ"])).is_err());
        assert!(lire(&a(&["-Action", "mindset", "-Disque", "X:"])).is_err());
        assert!(lire(&a(&["-Action", "mindset", "-Disque", "x"])).is_ok());
        assert!(lire(&a(&["-Action", "mindset", "-Inconnu", "1"])).is_err());
        assert!(lire(&a(&["-Action", "mindset", "-Zip", "a", "-zip", "b"])).is_err());
        assert!(lire(&a(&["-Action", "mindset", "-Zip"])).is_err());
        assert!(lire(&a(&["-Action", "mindset", "valeur"])).is_err());
        assert!(lire(&a(&["-Action", "taches", "-AttendrePid", "abc"])).is_err());
        assert!(lire(&a(&["-Zip", "a"])).is_err());
    }
}
