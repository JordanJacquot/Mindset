//! Les petites règles du bloc, sans rien d'autre que le disque : ce qu'un dossier contient (installations.ps1:51-85),
//! les arguments de la demande de Windows (326-354), les entrées « Run » d'une appli (127-133), les dossiers que
//! Mindset accepte de vider (705-722), les messages, et la raison simple d'un échec de mise à jour (mindset.ps1:535).

use mindset_noyau::Appli;
use std::path::Path;
use suite_commun::chemins;

/// `Join-Path` sur des textes.
pub fn joindre(a: &str, b: &str) -> String {
    chemins::joindre(a, b)
}

/// Un fichier (`Test-Path -PathType Leaf`).
pub fn est_fichier(c: &str) -> bool {
    !c.is_empty() && Path::new(c).is_file()
}

/// Existe (`Test-Path`), fichier ou dossier.
pub fn existe(c: &str) -> bool {
    !c.is_empty() && Path::new(c).exists()
}

/// `Get-ScriptAppli` : le script principal de l'appli dans ce dossier, sous son nom d'aujourd'hui ou sous son ancien
/// nom ; `None` si aucun.
pub fn script_appli(dossier: &str, appli: &Appli) -> Option<String> {
    if dossier.is_empty() {
        return None;
    }
    for s in [&appli.script, &appli.ancien_script] {
        if s.is_empty() {
            continue;
        }
        let f = joindre(dossier, s);
        if est_fichier(&f) {
            return Some(f);
        }
    }
    None
}

/// `(?m)^\$AppVersion\s*=\s*'([\d.]+)'` (sans tenir compte des majuscules, comme `-match`) : la première version
/// trouvée.
pub fn version_de_script(texte: &str) -> Option<String> {
    let mut debut = 0;
    loop {
        let ligne = &texte[debut..];
        if let Some(reste) = chemins::apres_debut(ligne, "$AppVersion") {
            let r = reste.trim_start_matches(char::is_whitespace);
            if let Some(r) = r.strip_prefix('=') {
                let r = r.trim_start_matches(char::is_whitespace);
                if let Some(r) = r.strip_prefix('\'') {
                    let n = r.find(|c: char| !(c.is_ascii_digit() || c == '.')).unwrap_or(r.len());
                    if n > 0 && r[n..].starts_with('\'') {
                        return Some(r[..n].to_string());
                    }
                }
            }
        }
        debut += texte[debut..].find('\n')? + 1;
    }
}

/// `Read-VersionJson` d'un fichier du disque.
fn info_version_json(fichier: &str) -> Option<suite_commun::paquet::InfoVersion> {
    let o = std::fs::read(fichier).ok()?;
    suite_commun::paquet::lire_version_json(&o)
}

/// `Get-VersionDans` : la version installée dans un dossier (son version.json d'abord, lisible et de cette appli,
/// sinon la ligne `$AppVersion` de son script), `None` si introuvable.
pub fn version_dans(dossier: &str, appli: &Appli) -> Option<String> {
    if !dossier.is_empty() {
        let j = joindre(dossier, "version.json");
        if est_fichier(&j)
            && let Some(i) = info_version_json(&j)
        {
            let a = i.appli.as_deref().unwrap_or("");
            if a.is_empty() || a.eq_ignore_ascii_case(&appli.id) {
                return Some(i.version);
            }
        }
    }
    let f = script_appli(dossier, appli)?;
    let o = std::fs::read(&f).ok()?;
    version_de_script(&suite_commun::json_sur::texte_du_fichier(&o))
}

/// `Test-DossierAppli` : ce dossier contient-il l'appli ? Son programme et son script (appli PowerShell), ou son hôte
/// Mindset.exe et un version.json lisible qui la nomme (appli Rust).
pub fn dossier_appli(dossier: &str, appli: &Appli) -> bool {
    if dossier.is_empty() || !existe(&joindre(dossier, &appli.exe)) {
        return false;
    }
    if script_appli(dossier, appli).is_some() {
        return true;
    }
    let j = joindre(dossier, "version.json");
    if !est_fichier(&joindre(dossier, "Mindset.exe")) || !est_fichier(&j) {
        return false;
    }
    info_version_json(&j)
        .is_some_and(|i| i.appli.as_deref().is_some_and(|a| !a.is_empty() && a.eq_ignore_ascii_case(&appli.id)))
}

/// `Format-ArgumentAdmin` : un argument entre guillemets, les « \ » qui le finissent doublés. Un guillemet est refusé.
pub fn argument_admin(valeur: &str) -> Result<String, String> {
    if valeur.contains('"') {
        return Err(format!("Valeur refusée (guillemet) : {valeur}"));
    }
    let sans = valeur.trim_end_matches('\\');
    let barres = valeur.len() - sans.len();
    Ok(format!("\"{sans}{}\"", "\\".repeat(barres * 2)))
}

/// Une variable qui ferait charger du code au programme lancé en administrateur (`Get-RefusVariablesAdmin`).
pub fn variable_dangereuse(nom: &str) -> bool {
    let haut = nom.to_ascii_uppercase();
    haut.starts_with("COR_")
        || haut.starts_with("COMPLUS_")
        || haut.starts_with("CORECLR_")
        || ["DOTNET_STARTUP_HOOKS", "DOTNET_ADDITIONAL_DEPS", "DOTNET_SHARED_STORE"].contains(&haut.as_str())
}

/// `Get-RefusVariablesAdmin` sans le journal : les variables trouvées (triées, sans doublon comme `Sort-Object
/// -Unique`, qui ne tient pas compte des majuscules), et le message à montrer ; `None` si tout va bien.
pub fn refus_variables(noms: &[String]) -> Option<(String, String)> {
    let mut t: Vec<&String> = noms.iter().filter(|n| variable_dangereuse(n)).collect();
    t.sort_by_key(|n| n.to_lowercase());
    t.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
    if t.is_empty() {
        return None;
    }
    let liste = t.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", ");
    Some((
        format!("Demande de Windows pas lancée, par prudence : variable d'environnement {liste}"),
        format!(
            "un réglage inhabituel de Windows ({liste}) pourrait détourner l'installation, alors Mindset n'a rien lancé. Demande de l'aide à la personne qui s'occupe de ton PC."
        ),
    ))
}

/// `'^"?([^"]*\\' + [regex]::Escape($Exe) + ')"?'` (sans tenir compte des majuscules) : le programme que lance une
/// entrée « Run », s'il s'agit de cet exe.
pub fn cible_run(valeur: &str, exe: &str) -> Option<String> {
    let v = valeur.strip_prefix('"').unwrap_or(valeur);
    let sans_guillemet = &v[..v.find('"').unwrap_or(v.len())];
    let motif = format!("\\{exe}");
    let bas = sans_guillemet.to_lowercase();
    let mbas = motif.to_lowercase();
    // (le plus long début sans guillemet qui finit par « \<exe> »)
    if bas.len() != sans_guillemet.len() || mbas.len() != motif.len() {
        // des lettres qui changent de taille en minuscules : comparaison caractère par caractère
        let c: Vec<char> = sans_guillemet.chars().collect();
        let m: Vec<char> = motif.chars().collect();
        for fin in (m.len()..=c.len()).rev() {
            let bout: String = c[fin - m.len()..fin].iter().collect();
            if chemins::egal(&bout, &motif) {
                return Some(c[..fin].iter().collect());
            }
        }
        return None;
    }
    let i = bas.rfind(&mbas)?;
    Some(sans_guillemet[..i + motif.len()].to_string())
}

/// `-like "$interdit\*"` ou `-ieq` : le chemin est ce dossier ou dedans.
pub fn dans_ou_egal(chemin: &str, dossier: &str) -> bool {
    if dossier.is_empty() {
        return false;
    }
    chemins::egal(chemin, dossier) || chemins::apres_debut(chemin, &format!("{dossier}\\")).is_some()
}

/// `-like "$dossier\*"` : dedans (pas le dossier lui-même).
pub fn dedans(chemin: &str, dossier: &str) -> bool {
    !dossier.is_empty() && chemins::apres_debut(chemin, &format!("{}\\", dossier.trim_end_matches('\\'))).is_some()
}

/// Un lien (point de jonction, lien symbolique) : l'attribut ReparsePoint.
#[cfg(windows)]
pub fn est_lien(p: &Path) -> Option<bool> {
    use std::os::windows::fs::MetadataExt;
    std::fs::symlink_metadata(p).ok().map(|m| m.file_attributes() & 0x400 != 0)
}
#[cfg(not(windows))]
pub fn est_lien(p: &Path) -> Option<bool> {
    std::fs::symlink_metadata(p).ok().map(|m| m.file_type().is_symlink())
}

/// `Test-DossierSur` : un dossier que Mindset accepte de vider (ni dossier de Windows ou des programmes, ni lien sur
/// lui ou un de ses parents ; un dossier qui n'existe pas n'est pas sûr).
pub fn dossier_sur(dossier: &str, interdits: &[String]) -> bool {
    let Ok(d) = chemins::chemin_complet(dossier.trim_end_matches('\\')) else { return false };
    for i in interdits {
        if !i.is_empty() && dans_ou_egal(&d, i) {
            return false;
        }
    }
    let mut x = d.as_str();
    while !x.is_empty() && x.chars().count() > 3 {
        match est_lien(Path::new(x)) {
            Some(false) => {}
            _ => return false,
        }
        x = chemins::parent(x);
    }
    true
}

/// `Test-DossierTravail` : un dépôt Git dans la copie ou dans son dossier parent.
pub fn dossier_travail(dossier: &str) -> bool {
    !dossier.is_empty()
        && (existe(&joindre(dossier, ".git")) || {
            let p = chemins::parent(dossier);
            !p.is_empty() && existe(&joindre(p, ".git"))
        })
}

/// Le message de `Remove-Doublons` pour `n` raccourcis retirés.
pub fn message_doublons(n: usize, nom: &str) -> Option<String> {
    if n == 0 {
        return None;
    }
    let s = if n > 1 { "s" } else { "" };
    Some(format!("{n} raccourci{s} direct{s} retiré{s} : {nom} s'ouvre maintenant depuis Mindset."))
}

/// « de Mindcare », « d'Evermind » (`Format-DeNom`).
pub fn de_nom(nom: &str) -> String {
    let premiere = nom.chars().next().map(|c| c.to_lowercase().collect::<String>()).unwrap_or_default();
    if ["a", "e", "i", "o", "u", "y", "é", "è", "ê", "h"].contains(&premiere.as_str()) {
        format!("d'{nom}")
    } else {
        format!("de {nom}")
    }
}

fn caractere_de_mot(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Un nombre seul (`\b403\b`) dans le texte.
fn nombre_seul(texte: &str, n: &str) -> bool {
    let mut depuis = 0;
    while let Some(i) = texte[depuis..].find(n) {
        let a = depuis + i;
        let b = a + n.len();
        let avant = texte[..a].chars().next_back().is_none_or(|c| !caractere_de_mot(c));
        let apres = texte[b..].chars().next().is_none_or(|c| !caractere_de_mot(c));
        if avant && apres {
            return true;
        }
        depuis = a + 1;
        while !texte.is_char_boundary(depuis) {
            depuis += 1;
        }
    }
    false
}

/// Les `n` premières unités UTF-16 d'un texte (`Substring(0, n)` de .NET).
pub fn debut_utf16(texte: &str, n: usize) -> String {
    let mut compte = 0;
    let mut r = String::new();
    for c in texte.chars() {
        compte += c.len_utf16();
        if compte > n {
            break;
        }
        r.push(c);
    }
    r
}

/// `Get-RaisonEchecMaj` : pourquoi une mise à jour a raté, en mots simples.
pub fn raison_echec_maj(nom: &str, message: &str) -> String {
    let m = retirer_echec(message);
    let m = m.trim();
    let bas = m.to_lowercase();
    let a = |l: &[&str]| l.iter().any(|x| bas.contains(&x.to_lowercase()));
    if a(&["encore ouvert", "fichiers sont utilisés", "being used", "utilisé par un autre"]) {
        return format!("{nom} était encore ouvert et n'a pas pu être fermé.");
    }
    if a(&["signature"]) {
        return "Le fichier téléchargé n'a pas passé la vérification de sécurité : rien n'a été changé.".into();
    }
    if a(&["ne répond pas"]) {
        return "L'outil d'installation de Mindset n'a pas répondu.".into();
    }
    if a(&[
        "connexion",
        "réseau",
        "internet",
        "délai",
        "timedout",
        "timed out",
        "timeout",
        "time out",
        "résoudre",
        "remote",
        "distant",
    ]) || ["403", "404", "429", "500", "502", "503"].iter().any(|n| nombre_seul(&bas, n))
    {
        return "Internet a coupé pendant le téléchargement.".into();
    }
    if a(&["espace disque", "disque plein", "not enough space", "place sur le disque"]) {
        return "Il n'y a plus assez de place sur le disque.".into();
    }
    if m.is_empty() {
        return "Une erreur inconnue l'a arrêtée.".into();
    }
    let mut m = m.to_string();
    if m.encode_utf16().count() > 140 {
        m = debut_utf16(&m, 137) + "...";
    }
    let fin = m.strip_suffix('\n').unwrap_or(&m);
    if !fin.ends_with(['.', '!', '?']) {
        m.push('.');
    }
    m
}

/// `-replace '^\s*Échec\s*:\s*', ''` (sans tenir compte des majuscules).
fn retirer_echec(message: &str) -> String {
    let t = message.trim_start_matches(char::is_whitespace);
    if let Some(r) = chemins::apres_debut(t, "Échec") {
        let r2 = r.trim_start_matches(char::is_whitespace);
        if let Some(r3) = r2.strip_prefix(':') {
            return r3.trim_start_matches(char::is_whitespace).to_string();
        }
    }
    message.to_string()
}

/// `"{0:N1}" -f $x` en français : une décimale, la virgule, les milliers séparés par une espace insécable.
pub fn nombre_n1(x: f64) -> String {
    let t = format!("{:.1}", (x.abs() * 10.0).round() / 10.0);
    let (ent, dec) = t.split_once('.').unwrap_or((&t, "0"));
    let mut groupes = String::new();
    for (i, c) in ent.chars().enumerate() {
        if i > 0 && (ent.len() - i) % 3 == 0 {
            groupes.push('\u{a0}');
        }
        groupes.push(c);
    }
    let signe = if x < 0.0 && t != "0.0" { "-" } else { "" };
    format!("{signe}{groupes},{dec}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_admin() {
        assert_eq!(argument_admin(r"E:\").unwrap(), r#""E:\\""#);
        assert_eq!(argument_admin(r"C:\a b").unwrap(), r#""C:\a b""#);
        assert_eq!(argument_admin(r"C:\x\\").unwrap(), r#""C:\x\\\\""#);
        assert!(argument_admin("a\"b").is_err());
    }

    #[test]
    fn entrees_run() {
        assert_eq!(
            cible_run(r#""C:\A\Evermind.exe" -Demarrage"#, "Evermind.exe").as_deref(),
            Some(r"C:\A\Evermind.exe")
        );
        assert_eq!(cible_run(r"C:\A\evermind.EXE", "Evermind.exe").as_deref(), Some(r"C:\A\evermind.EXE"));
        assert_eq!(cible_run(r"Evermind.exe", "Evermind.exe"), None);
        assert_eq!(cible_run(r"C:\A\Evermind.exe2", "Evermind.exe").as_deref(), Some(r"C:\A\Evermind.exe"));
    }

    #[test]
    fn nombres() {
        assert_eq!(nombre_n1(0.0), "0,0");
        assert_eq!(nombre_n1(1.25), "1,3");
        assert_eq!(nombre_n1(1234.56), "1\u{a0}234,6");
    }

    #[test]
    fn versions_de_script() {
        assert_eq!(version_de_script("x\n$AppVersion = '1.2.3'\n").as_deref(), Some("1.2.3"));
        assert_eq!(version_de_script("$appversion='2.0'").as_deref(), Some("2.0"));
        assert_eq!(version_de_script(" $AppVersion = '1.2.3'"), None);
        assert_eq!(version_de_script("$AppVersion = \"1.2.3\""), None);
    }
}
