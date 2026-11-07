//! Des cas jamais vus : données tirées au hasard (graine affichée en cas d'échec), comparées à une règle écrite
//! autrement (les règles de Windows pour la ligne de commande, l'expression de PowerShell pour « Run »), ou à ce qui
//! doit toujours être vrai (une ancienne copie ne perd jamais un fichier qui n'est pas à l'appli).

use mindset_installations::poste::FauxPoste;
use mindset_installations::{copies, installations, regles};
use mindset_noyau::Appli;
use std::collections::BTreeMap;
use std::io::Write;

struct Hasard(u64);

impl Hasard {
    fn nouveau(graine: u64) -> Hasard {
        Hasard(graine.max(1))
    }
    fn suivant(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn jusqua(&mut self, n: usize) -> usize {
        (self.suivant() % n as u64) as usize
    }
    fn choisir<'a>(&mut self, l: &[&'a str]) -> &'a str {
        l[self.jusqua(l.len())]
    }
}

fn graines() -> Vec<u64> {
    let t =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(7);
    vec![1, 2, 3, 42, 2026, 0x5eed, t]
}

/// Les règles de Windows (`CommandLineToArgvW`) pour lire une ligne de commande, écrites ici sans regarder le code
/// du bloc.
fn lire_ligne(l: &str) -> Vec<String> {
    let c: Vec<char> = l.chars().collect();
    let mut r = Vec::new();
    let mut i = 0;
    while i < c.len() {
        while i < c.len() && (c[i] == ' ' || c[i] == '\t') {
            i += 1;
        }
        if i >= c.len() {
            break;
        }
        let mut a = String::new();
        let mut entre = false;
        while i < c.len() {
            if c[i] == '\\' {
                let mut n = 0;
                while i < c.len() && c[i] == '\\' {
                    n += 1;
                    i += 1;
                }
                if i < c.len() && c[i] == '"' {
                    a.extend(std::iter::repeat_n('\\', n / 2));
                    if n % 2 == 1 {
                        a.push('"');
                        i += 1;
                    }
                } else {
                    a.extend(std::iter::repeat_n('\\', n));
                }
                continue;
            }
            if c[i] == '"' {
                entre = !entre;
                i += 1;
                continue;
            }
            if !entre && (c[i] == ' ' || c[i] == '\t') {
                break;
            }
            a.push(c[i]);
            i += 1;
        }
        r.push(a);
    }
    r
}

#[test]
fn arguments_relus_comme_windows() {
    let morceaux = ["C:", "\\", "\\\\", "Program Files", "Mindset", "é", "’", "$x", " ", "a", "E:\\", "Forêt", "'"];
    for g in graines() {
        let mut h = Hasard::nouveau(g);
        for _ in 0..400 {
            let n = 1 + h.jusqua(6);
            let v: String = (0..n).map(|_| h.choisir(&morceaux)).collect();
            let a = regles::argument_admin(&v).unwrap();
            let ligne = format!("-Action appli -Destination {a} -Exe {}", regles::argument_admin("x.exe").unwrap());
            let lu = lire_ligne(&ligne);
            assert_eq!(lu, vec!["-Action", "appli", "-Destination", &v, "-Exe", "x.exe"], "graine {g} : {v:?} -> {a}");
        }
    }
}

/// `'^"?([^"]*\\' + Escape($Exe) + ')"?'` de PowerShell, essayé comme le ferait le moteur : le guillemet d'abord
/// pris, puis pas pris ; la partie sans guillemet la plus longue d'abord.
fn run_reference(v: &str, exe: &str) -> Option<String> {
    let c: Vec<char> = v.chars().collect();
    let motif: Vec<char> = format!("\\{exe}").chars().collect();
    let egal = |a: char, b: char| a.to_lowercase().eq(b.to_lowercase());
    for debut in [usize::from(c.first() == Some(&'"')), 0] {
        if debut > c.len() {
            continue;
        }
        let mut fin_max = debut;
        while fin_max < c.len() && c[fin_max] != '"' {
            fin_max += 1;
        }
        for fin in (debut..=fin_max).rev() {
            if fin < debut + motif.len() {
                break;
            }
            let bout = &c[fin - motif.len()..fin];
            if bout.iter().zip(motif.iter()).all(|(a, b)| egal(*a, *b)) {
                return Some(c[debut..fin].iter().collect());
            }
        }
        if debut == 0 {
            break;
        }
    }
    None
}

#[test]
fn entrees_run_comme_l_expression_de_powershell() {
    let morceaux = ["\"", "C:\\", "\\", "Evermind.exe", "EVERMIND.EXE", "x", " -Demarrage", "Mon", ".exe", "é", "/min"];
    for g in graines() {
        let mut h = Hasard::nouveau(g);
        for _ in 0..800 {
            let n = 1 + h.jusqua(7);
            let v: String = (0..n).map(|_| h.choisir(&morceaux)).collect();
            assert_eq!(regles::cible_run(&v, "Evermind.exe"), run_reference(&v, "Evermind.exe"), "graine {g} : {v:?}");
        }
    }
}

#[test]
fn raisons_toujours_une_phrase() {
    let morceaux = ["Échec", " : ", "réseau", "x", "!", "?", ".", "\n", "403", "4031", "signature", "é", "ouvert", " "];
    for g in graines() {
        let mut h = Hasard::nouveau(g);
        for _ in 0..500 {
            let n = h.jusqua(40);
            let m: String = (0..n).map(|_| h.choisir(&morceaux)).collect();
            let r = regles::raison_echec_maj("CaféCrème", &m);
            assert!(!r.is_empty(), "graine {g} : {m:?}");
            let sans = r.strip_suffix('\n').unwrap_or(&r);
            assert!(sans.ends_with(['.', '!', '?']), "graine {g} : {m:?} -> {r:?}");
            assert!(r.encode_utf16().count() <= 141, "graine {g} : trop long ({r:?})");
        }
    }
}

fn zip_de(noms: &[String]) -> Vec<u8> {
    let mut z = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    for n in noms {
        z.start_file(n.as_str(), o).unwrap();
        z.write_all(b"x").unwrap();
    }
    z.finish().unwrap().into_inner()
}

#[test]
fn une_ancienne_copie_ne_perd_jamais_ce_qui_n_est_pas_a_l_appli() {
    let noms = ["a.txt", "Evermind.exe", "fichiers", "modules", "x.ps1", "Café.txt", "notes", "b.dll"];
    for (k, g) in graines().into_iter().enumerate() {
        let mut h = Hasard::nouveau(g);
        for essai in 0..12 {
            let (ctx, faux) = mindset_noyau::essai::contexte(&format!("hasard-copie-{k}-{essai}"));
            let poste = FauxPoste::nouveau(&faux.racine);
            let d = faux.racine.join(r"Ancienne\Evermind");
            std::fs::create_dir_all(&d).unwrap();
            let mut fichiers = BTreeMap::new();
            for _ in 0..1 + h.jusqua(12) {
                let profondeur = h.jusqua(3);
                let mut rel: Vec<&str> = (0..profondeur).map(|_| h.choisir(&noms)).collect();
                rel.push(h.choisir(&noms));
                let rel = rel.join("\\");
                let p = d.join(&rel);
                if p.exists() || p.ancestors().skip(1).any(|a| a.is_file()) {
                    continue;
                }
                std::fs::create_dir_all(p.parent().unwrap()).unwrap();
                if std::fs::write(&p, "x").is_ok() {
                    // (« livré » : dans le zip, sous Evermind\)
                    fichiers.insert(rel, h.jusqua(2) == 0);
                }
            }
            let mut entrees: Vec<String> = fichiers
                .iter()
                .filter(|(_, l)| **l)
                .map(|(r, _)| format!("Evermind/{}", r.replace('\\', "/")))
                .collect();
            entrees.push("Evermind/jamais-la.txt".into());
            entrees.push("Autre/a.txt".into());
            let zip = faux.racine.join("e.zip");
            std::fs::write(&zip, zip_de(&entrees)).unwrap();
            let a = Appli { nom: "Evermind".into(), dossier_zip: "Evermind".into(), ..Default::default() };
            let m = copies::retirer_ancienne_copie(
                &ctx,
                &poste,
                &a,
                &d.to_string_lossy(),
                &zip.to_string_lossy(),
                "Evermind",
            );
            for (rel, livre) in &fichiers {
                assert_eq!(d.join(rel).exists(), !livre, "graine {g} : {rel} (livré : {livre}) ; {m}");
            }
            if fichiers.values().all(|l| *l) {
                assert!(!d.exists(), "graine {g} : tout était livré : {m}");
                assert!(m.ends_with("a été supprimée."), "{m}");
            } else {
                assert!(m.contains("a été vidée de Evermind ;"), "graine {g} : {m}");
            }
            let _ = std::fs::remove_dir_all(&faux.racine);
        }
    }
}

#[test]
fn versions_lues_dans_le_script() {
    for g in graines() {
        let mut h = Hasard::nouveau(g);
        for _ in 0..300 {
            let n = 1 + h.jusqua(4);
            let v: Vec<String> = (0..n).map(|_| h.jusqua(300).to_string()).collect();
            let v = v.join(".");
            let avant = ["", "# Evermind\r\n", "x = 1\n", "\n\n"][h.jusqua(4)];
            let espaces = [" ", "", "\t", "  "][h.jusqua(4)];
            let t = format!("{avant}$AppVersion{espaces}={espaces}'{v}'\r\n$Autre = '9.9.9'");
            assert_eq!(regles::version_de_script(&t).as_deref(), Some(v.as_str()), "graine {g} : {t:?}");
        }
    }
}

#[test]
fn installations_json_suit_chaque_ecriture() {
    for (k, g) in graines().into_iter().enumerate() {
        let mut h = Hasard::nouveau(g);
        let (ctx, faux) = mindset_noyau::essai::contexte(&format!("hasard-installations-{k}"));
        let mut modele: BTreeMap<String, (String, bool)> = BTreeMap::new();
        let ids = ["evermind", "nevermind", "mindcare", "cafe-creme", "foret"];
        for _ in 0..60 {
            let id = h.choisir(&ids);
            if h.jusqua(3) == 0 {
                installations::enregistrer(&ctx, id, None, false);
                modele.remove(id);
            } else {
                let d = format!(r"C:\Essai\{}\{}", h.jusqua(5), id);
                let gere = h.jusqua(2) == 0;
                installations::enregistrer(&ctx, id, Some(&d), gere);
                modele.insert(id.into(), (d, gere));
            }
            let lu: BTreeMap<String, (String, bool)> =
                installations::lire(&ctx, false).unwrap().into_iter().map(|(k, e)| (k, (e.dossier, e.gere))).collect();
            assert_eq!(lu, modele, "graine {g}");
        }
        let _ = std::fs::remove_dir_all(&faux.racine);
    }
}
