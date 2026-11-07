//! L'intégration : tous les vrais blocs de `blocs()` ensemble, dans l'hôte, avec les faux ports du noyau (aucun
//! réseau, aucun programme lancé, rien sur le vrai PC). Ce que les blocs ne pouvaient pas prouver chacun de son côté :
//! la ligne de démarrage, les noms échangés entre blocs (relevé de D:\Projets\_plans\integration-mindset-rust.md).

use mindset_appli::hote::{Demande, Ecran, Hote};
use mindset_appli::pont::MessagePage;
use mindset_noyau::essai::{self, Faux};
use mindset_noyau::{Contexte, Fenetre, Lancement};
use serde_json::{Value, json};

#[derive(Default)]
struct Page {
    etats: Vec<Value>,
    ordres: Vec<Value>,
}

impl Ecran for Page {
    fn etat(&mut self, e: Value) {
        self.etats.push(e);
    }
    fn ordre(&mut self, o: Value) {
        self.ordres.push(o);
    }
}

struct Monde {
    hote: Hote,
    faux: Faux,
    page: Page,
    au_depart: Vec<Demande>,
}

impl Drop for Monde {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.faux.racine);
    }
}

fn contexte(nom: &str, demarrage: bool) -> (Contexte, Faux) {
    essai::contexte_avec(nom, Lancement { demarrage, ..Default::default() })
}

impl Monde {
    fn demarrer(ctx: Contexte, faux: Faux) -> Monde {
        let mut hote = Hote::nouveau(mindset_appli::blocs(), ctx);
        hote.taches_directes = true;
        let au_depart = hote.demarrer();
        Monde { hote, faux, page: Page::default(), au_depart }
    }

    fn ligne(&self) -> Option<String> {
        Hote::ligne_demarrage("3.0.0", self.hote.ctx.lancement.demarrage, &self.au_depart)
    }

    /// La fenêtre est là : premier tic de chaque bloc.
    fn ouvrir(&mut self) -> Vec<Demande> {
        self.hote.fenetre_prete();
        let _ = self.hote.etat_initial();
        self.hote.minuterie(&mut self.page)
    }

    fn action(&mut self, id: &str, valeur: Value) -> Vec<Demande> {
        let m = MessagePage::Action { id: id.into(), valeur, ecran: String::new() };
        self.hote.recevoir(m, &mut self.page)
    }

    fn etat(&mut self) -> Value {
        self.hote.etat_initial()
    }
}

// -------------------------------------------------------------------------------------------------------------------
// La ligne « Démarrage Mindset » (Mindset.ps1:122-135, outils\tester-maj-demarrage.ps1)
// -------------------------------------------------------------------------------------------------------------------

#[test]
fn lance_avec_windows_mais_coupe_aucune_ligne_de_demarrage() {
    let (ctx, faux) = contexte("integration-demarrage-coupe", true);
    ctx.ecrire_reglage("LancerAvecWindows", json!(false));
    let m = Monde::demarrer(ctx, faux);
    assert!(m.au_depart.iter().any(|d| matches!(d, Demande::Fin { .. })), "{:?}", m.au_depart);
    assert_eq!(m.ligne(), None);
    let j = m.faux.donnees.lignes().join("\n");
    assert!(j.contains("rien n'est ouvert"), "{j}");
    assert!(!j.contains("Démarrage Mindset"), "{j}");
}

#[test]
fn lance_avec_windows_et_permis_la_ligne_le_dit() {
    let (ctx, faux) = contexte("integration-demarrage-permis", true);
    let m = Monde::demarrer(ctx, faux);
    assert_eq!(m.ligne().as_deref(), Some("Démarrage Mindset 3.0.0 (Rust), lancé avec Windows"));
    assert!(!m.au_depart.iter().any(|d| matches!(d, Demande::Fenetre(Fenetre::Montrer))));
}

#[test]
fn coupe_mais_mise_a_jour_attendue_mindset_revient_cache() {
    let (ctx, faux) = contexte("integration-demarrage-maj", true);
    ctx.ecrire_reglage("LancerAvecWindows", json!(false));
    ctx.ecrire_reglage("MajMindsetDemande", json!("0123456789abcdef0123456789abcdef"));
    let m = Monde::demarrer(ctx, faux);
    assert_eq!(m.ligne().as_deref(), Some("Démarrage Mindset 3.0.0 (Rust), lancé avec Windows"));
}

#[test]
fn relance_apres_une_mise_a_jour_demandee_a_l_ecran_avec_sa_fenetre() {
    let (ctx, faux) = contexte("integration-demarrage-visible", true);
    ctx.ecrire_reglage("MajMindsetVisible", json!(true));
    let m = Monde::demarrer(ctx, faux);
    assert!(m.au_depart.iter().any(|d| matches!(d, Demande::Fenetre(Fenetre::Montrer))));
    assert_eq!(m.ligne().as_deref(), Some("Démarrage Mindset 3.0.0 (Rust)"));
}

#[test]
fn ouvert_a_la_main() {
    let (ctx, faux) = contexte("integration-demarrage-main", false);
    ctx.ecrire_reglage("LancerAvecWindows", json!(false));
    let mut m = Monde::demarrer(ctx, faux);
    assert_eq!(m.ligne().as_deref(), Some("Démarrage Mindset 3.0.0 (Rust)"));
    // (et le premier tour de tous les blocs ensemble ne panique pas, l'état a les clés de chaque bloc)
    let _ = m.ouvrir();
    let e = m.etat();
    for k in ["_vue", "ecrans", "bienvenue", "maj_mindset", "admin_bandeau", "parametres", "pages_applis", "fermeture"]
    {
        assert!(
            e.get(k).is_some(),
            "clé {k} absente de l'état : {:?}",
            e.as_object().map(|o| o.keys().collect::<Vec<_>>())
        );
    }
    assert!(e.get("console").is_some());
    let _ = m.action("ecrans:onglet", json!("parametres"));
}

// -------------------------------------------------------------------------------------------------------------------
// Les noms échangés entre deux blocs (le relevé de cohérence)
// -------------------------------------------------------------------------------------------------------------------

#[test]
fn maj_auto_essais_ecrit_par_lui_meme_lu_par_la_console() {
    // `maj-auto.essais[id]` : lui-même l'écrit, la console en tire « nouvel essai dans X min » (Get-MajAutoReessai)
    let (ctx, faux) = contexte("integration-essais", false);
    let _menage = Menage(faux.racine.clone());
    ctx.avancer(std::time::Duration::from_secs(3600));
    let mut b = mindset_lui_meme::BlocLuiMeme::default();
    // (un essai il y a 5 minutes, depuis le lancement de Mindset)
    let il_y_a_5_min = ctx.ecoule().as_millis() as u64 - 5 * 60_000;
    b.poser_essai(
        "evermind",
        mindset_lui_meme::regles::Essai { version: "2.6.0".into(), quand_ms: il_y_a_5_min, nombre: 1 },
    );
    let v = b.valeur_maj_auto(&ctx);
    let e = &v["essais"]["evermind"];
    assert!(e["quand"].is_string(), "{v}");
    let r = mindset_console::calculs::maj_auto_reessai(Some(e), "2.6.0", &ctx.heure());
    assert_eq!(r, Some(10), "15 minutes après un essai : encore 10 ({e})");
    // (3 essais : plus d'essai tout seul)
    b.poser_essai(
        "evermind",
        mindset_lui_meme::regles::Essai { version: "2.6.0".into(), quand_ms: il_y_a_5_min, nombre: 3 },
    );
    let v = b.valeur_maj_auto(&ctx);
    assert_eq!(
        mindset_console::calculs::maj_auto_reessai(Some(&v["essais"]["evermind"]), "2.6.0", &ctx.heure()),
        Some(-1)
    );
}

#[test]
fn console_et_parametres_partagent_possible_et_raison() {
    // `console { possible, parametres, en_fente, raison }` : écrit par la console, lu par les écrans (navigation par
    // la console : ni en-tête ni onglets, Set-NavigationConsole) et les Paramètres (AnimationsInfo)
    let (ctx, faux) = contexte("integration-console", false);
    let mut m = Monde::demarrer(ctx, faux);
    let _ = m.ouvrir();
    let c = m.hote.ctx.lu("console").unwrap();
    assert_eq!(c["possible"], true, "{c}");
    assert!(c.get("raison").is_some(), "{c}");
    let e = m.etat();
    assert_eq!(e["ecrans"]["console"], true, "console possible : les écrans cachent en-tête et onglets");
    assert_eq!(e["parametres"]["apparence"]["animInfo"], "");
    // Animations : aucune, par les Paramètres : la console s'éteint, l'accueil classique a son en-tête et ses onglets
    let _ = m.action("parametres:reglage", json!({ "quoi": "animations", "valeur": "aucune" }));
    let _ = m.hote.minuterie(&mut m.page);
    assert_eq!(m.hote.ctx.lu("console").unwrap()["possible"], false);
    let e = m.etat();
    assert_eq!(e["ecrans"]["console"], false);
    assert_eq!(e["parametres"]["apparence"]["animInfo"], "", "« aucune » n'est pas une raison du PC");
}

#[test]
fn le_disque_coche_vient_de_lui_meme() {
    // `bienvenue.disques[].coche` : écrit par lui-même ; ecrans.js coche celui-là (et pas toujours le disque C:)
    let js =
        std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("ui/ecrans/ecrans.js")).unwrap();
    assert!(js.contains("(b.disques || []).some((x) => x.coche)"));
    assert!(js.contains("marque ? !!d.coche"));
}

struct Menage(std::path::PathBuf);
impl Drop for Menage {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn plus_de_constante_pour_creer_un_bloc() {
    // (les blocs ont un état : l'hôte les crée par `default()`, plus par une constante du nom du type)
    let rust = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let lib = std::fs::read_to_string(rust.join("mindset-appli/src/lib.rs")).unwrap();
    assert_eq!(lib.matches("::default()),").count(), 9, "les 9 blocs qui ont un état");
    for e in std::fs::read_dir(&rust).unwrap().flatten() {
        let f = e.path().join("src").join("lib.rs");
        if let Ok(t) = std::fs::read_to_string(&f) {
            assert!(!t.contains("pub const Bloc"), "{} garde une constante de bloc", f.display());
        }
    }
}
