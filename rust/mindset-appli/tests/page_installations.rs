//! Audit du 08/11/2026 (M7) : une page compromise ne peut ni donner un chemin au bloc « installations », ni
//! désinstaller une appli sans la question. Tous les vrais blocs dans l'hôte, la page remplacée par des messages
//! (`MessagePage::Action`, comme `window.mindsetPont.envoyer`), un faux mini-installateur, un dossier d'essai.
//! Rien ne touche le vrai PC (contexte d'essai : ni raccourcis, ni registre, ni tâches).

use mindset_appli::hote::{Ecran, Hote};
use mindset_appli::pont::MessagePage;
use mindset_noyau::appli::Appli;
use mindset_noyau::{Vue, essai, partage};
use serde_json::{Value, json};
use std::path::Path;

#[derive(Default)]
struct Page;
impl Ecran for Page {
    fn etat(&mut self, _: Value) {}
    fn ordre(&mut self, _: Value) {}
}

fn poser_evermind(d: &Path) {
    std::fs::create_dir_all(d.join("fichiers")).unwrap();
    std::fs::write(d.join("Evermind.exe"), "exe").unwrap();
    std::fs::write(d.join("fichiers").join("Evermind.ps1"), "$AppVersion = '2.5.0'\n").unwrap();
}

fn page(h: &mut Hote, p: &mut Page, id: &str, valeur: Value) {
    let _ = h.recevoir(MessagePage::Action { id: id.into(), valeur, ecran: "accueil".into() }, p);
    let _ = h.minuterie(p);
}

#[test]
fn page_compromise_ni_chemin_ni_desinstallation_sans_question() {
    let (ctx, faux) = essai::contexte("page-installations");
    ctx.definir_vue(Vue { visible: true, reduite: false, page: "accueil".into() });
    let mut h = Hote::nouveau(mindset_appli::blocs(), ctx);
    let mut p = Page;
    let _ = h.demarrer();
    h.ctx.definir_applis(vec![Appli {
        id: "evermind".into(),
        genre: "powershell".into(),
        nom: "Evermind".into(),
        depot: "JordanJacquot/Evermind".into(),
        zip: "Evermind.zip".into(),
        dossier_zip: "Evermind".into(),
        exe: "Evermind.exe".into(),
        script: r"fichiers\Evermind.ps1".into(),
        ..Default::default()
    }]);
    let gere = h.ctx.dossiers.programmes.join("Evermind");
    poser_evermind(&gere);
    let piege = faux.racine.join(r"Piege\Evermind");
    poser_evermind(&piege);
    h.fenetre_prete();
    let _ = h.etat_initial();
    // (les installations sont relevées toutes les 2 s, fenêtre montrée)
    for _ in 0..30 {
        h.ctx.avancer(std::time::Duration::from_millis(100));
        let _ = h.minuterie(&mut p);
    }
    let avant = partage::installation(&h.ctx, "evermind").expect("Evermind installé par Mindset");
    assert!(avant.gere);

    // « Désinstaller » envoyé par la page : la question de la carte est posée côté Rust, rien n'est désinstallé
    page(&mut h, &mut p, "installations:desinstaller", json!("evermind"));
    let q = h.etat()["ecrans"]["confirmation"].clone();
    assert_eq!(q["titre"], "Désinstaller Evermind ?", "état : {q}");
    assert!(faux.installateur.deposees().is_empty() && faux.installateur.directs().is_empty());
    assert!(gere.join("Evermind.exe").exists());
    page(&mut h, &mut p, "ecrans:confirmation", json!({ "oui": false }));
    assert!(h.etat()["ecrans"]["confirmation"].is_null());
    assert!(faux.installateur.deposees().is_empty(), "« Annuler » : rien");

    // « Utiliser » avec un chemin donné par la page : refusé, Mindset garde sa copie
    page(&mut h, &mut p, "installations:utiliser", json!({ "id": "evermind", "dossier": piege.to_string_lossy() }));
    let i = partage::installation(&h.ctx, "evermind").unwrap();
    assert!(i.gere && i.dossier == avant.dossier, "{i:?}");

    // « Installer » avec une « ancienne copie » donnée par la page : rien n'est demandé au mini-installateur
    page(&mut h, &mut p, "installations:installer", json!({ "id": "evermind", "ancien": piege.to_string_lossy() }));
    assert!(faux.installateur.deposees().is_empty() && faux.installateur.directs().is_empty());
    assert!(piege.join("Evermind.exe").exists());

    let journal = faux.donnees.lignes();
    assert!(journal.iter().any(|l| l.contains("refusée (pas une copie trouvée par Mindset)")), "{journal:?}");
    assert!(journal.iter().any(|l| l.contains("refusée (copie inconnue de Mindset)")), "{journal:?}");
    let _ = std::fs::remove_dir_all(&faux.racine);
}
