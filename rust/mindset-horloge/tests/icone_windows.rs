//! La vraie icône près de l'horloge (Shell_NotifyIconW, son fil, sa fenêtre de messages), essayée SEULEMENT sur un
//! bureau Windows à part (`outils/essai-icone.ps1`, par sur-bureau.ps1) : là, il n'y a pas de barre des tâches,
//! rien ne peut apparaître sur l'écran. Ignoré par `cargo test` ; refusé partout ailleurs.
#![cfg(windows)]

use std::path::Path;
use std::time::{Duration, Instant};

use mindset_horloge::icone::{Choix, Dessin, Geste, Icone, Ligne};
use mindset_horloge::windows::{IconeWindows, bureau_a_part};

const WM_LBUTTONUP: u32 = 0x0202;
const WM_LBUTTONDBLCLK: u32 = 0x0203;
const NIN_BALLOONHIDE: u32 = 1027;
const NIN_BALLOONTIMEOUT: u32 = 1028;
const NIN_BALLOONUSERCLICK: u32 = 1029;

fn attendre(i: &IconeWindows, n: usize) -> Vec<Geste> {
    let debut = Instant::now();
    let mut l = Vec::new();
    while l.len() < n && debut.elapsed() < Duration::from_secs(5) {
        l.extend(i.gestes());
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(100));
    l.extend(i.gestes());
    l
}

#[test]
#[ignore = "seulement sur un bureau Windows à part (rust/mindset-horloge/outils/essai-icone.ps1)"]
fn icone_sur_un_bureau_a_part() {
    // (garde-fou : jamais sur le bureau de l'écran)
    assert!(
        std::env::var("MINDSET_ESSAI_ICONE").is_ok_and(|v| v == "1") && bureau_a_part(),
        "refusé : pas sur un bureau Windows à part"
    );
    let ico = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Mindset/fichiers/Mindset.ico");
    assert!(ico.is_file(), "{}", ico.display());
    for (essai, fichier) in [("Mindset.ico", ico.clone()), ("icône absente", ico.with_file_name("absente.ico"))] {
        let debut = Instant::now();
        let i = IconeWindows::creer(&fichier).expect("icône");
        println!("{essai} : créée en {} ms, prise par l'Explorateur : {}", debut.elapsed().as_millis(), i.ajoutee());
        assert!(i.fenetre_existe());
        assert!(!i.fenetre_montree(), "la fenêtre de messages ne doit jamais être montrée");
        assert!(!i.ajoutee(), "pas de barre des tâches sur un bureau à part");
        i.menu(&[
            Ligne::Choix { texte: "Ouvrir Mindset".into(), gras: true, choix: Choix::OuvrirMindset },
            Ligne::Separateur,
            Ligne::Choix {
                texte: "Tout quitter (Mindset et ses applis)".into(),
                gras: false,
                choix: Choix::ToutQuitter,
            },
        ]);
        i.bulle(4000, "Mindset reste ici", "Clique sur l'icône pour le rouvrir.", Dessin::Aucun);
        i.bulle(8000, &"t".repeat(80), &"x".repeat(300), Dessin::Attention);
        // Les gestes : un clic, la bulle cliquée, la bulle partie, la bulle fermée
        for m in [WM_LBUTTONUP, NIN_BALLOONUSERCLICK, NIN_BALLOONTIMEOUT, NIN_BALLOONHIDE] {
            i.simuler(m);
        }
        assert_eq!(attendre(&i, 4), [Geste::Clic, Geste::BulleCliquee, Geste::BulleFermee, Geste::BulleFermee]);
        // Un double clic : le relâchement qui suit n'est pas un clic (Windows Forms)
        for m in [WM_LBUTTONUP, WM_LBUTTONDBLCLK, WM_LBUTTONUP] {
            i.simuler(m);
        }
        assert_eq!(attendre(&i, 1), [Geste::Clic]);
        // Retirée : la fenêtre disparaît, le fil s'arrête
        let debut = Instant::now();
        i.retirer();
        println!("{essai} : retirée en {} ms", debut.elapsed().as_millis());
        assert!(!i.fenetre_existe());
        i.retirer();
        i.bulle(1000, "après", "rien", Dessin::Info);
        drop(i);
    }
    // Une icône jamais retirée à la main l'est quand le bloc la lâche (Drop)
    let i = IconeWindows::creer(&ico).expect("icône");
    let h = i.fenetre_existe();
    drop(i);
    assert!(h);
    println!("icône près de l'horloge : tout est bon");
}
