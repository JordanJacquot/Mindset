//! Desinstaller Mindset.exe : retire Mindset du PC, avec les applis qu'il a installées, ses tâches planifiées, ses
//! traces dans le registre, ses raccourcis et (si on le demande) ses données. Remplace outils\desinstalleur.cs, avec le
//! même comportement pour l'utilisateur (mêmes textes, mêmes étapes, même bilan).
//!
//! Il ne dépend ni de Mindset.exe ni du code PowerShell de Mindset : il marche même si fichiers\Mindset.ps1 est supprimé
//! ou abîmé. Il est livré à côté de Mindset.exe, et « Applications installées » de Windows le lance (UninstallString).
//!
//! Déroulement : lancé sans les droits, il se relance en administrateur (une demande de Windows) en passant
//! l'utilisateur (-Sid). En administrateur, il se copie dans un dossier temporaire protégé et s'y relance (-Copie) : un
//! programme qui tourne ne peut pas supprimer son propre fichier, et il doit vider le dossier des programmes où il est.
//! Les options sont décrites dans options.rs.

#![windows_subsystem = "windows"]
#![deny(unsafe_op_in_unsafe_fn)]

mod bilan;
mod fin;
mod lieux;
mod options;
mod os;
mod systeme;
mod texte;
mod travail;

use std::path::Path;
use std::sync::{Arc, Mutex};

use bilan::Bilan;
use lieux::Lieux;
use options::Options;
use os::Icone;
use systeme::Systeme;
use texte::{citer, t};
use travail::Travail;

fn main() {
    os::proteger_chargement();
    std::process::exit(lancer());
}

/// Les emplacements et le système : les vrais, ou ceux d'un faux environnement (construction d'essai seulement)
fn lieux_et_systeme(o: &Options) -> Result<(Lieux, os::Windows), String> {
    #[cfg(feature = "essai")]
    if let Some(f) = &o.test {
        return Ok((Lieux::de_test(Path::new(f))?, os::systeme_de_test()));
    }
    Ok(os::lieux_reels(o.sid.as_deref()))
}

fn lancer() -> i32 {
    let args: Vec<String> = std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned()).collect();
    let o = Options::lire(&args);
    let (lieux, sys) = match lieux_et_systeme(&o) {
        Ok(x) => x,
        Err(e) => {
            if !o.silencieux {
                os::message_ecran(&format!("La désinstallation ne peut pas démarrer :\n\n{e}"), Icone::Erreur);
            }
            return 1;
        }
    };
    let moi = t(&texte::complet(Path::new(&os::mon_exe())));

    // 1. Les droits administrateur (jamais en test) : une demande de Windows, puis ce programme se relance
    if !lieux.test && !os::est_admin() {
        let mut a = String::new();
        if o.nettoyer {
            a.push_str("-Nettoyer ");
        }
        if o.supprimer_donnees {
            a.push_str("-SupprimerDonnees ");
        }
        if o.silencieux {
            a.push_str("-Silencieux ");
        }
        a.push_str("-Sid ");
        a.push_str(&os::mon_sid());
        return match os::relancer_admin(&moi, &a) {
            Ok(()) => 0,
            Err((code, m)) => {
                if !o.silencieux {
                    let texte = if code == 1223 {
                        "La désinstallation est annulée : Windows a besoin de ton accord pour retirer Mindset.\n\nRelance-la et réponds « Oui » à la question de Windows.".to_string()
                    } else {
                        format!("La désinstallation ne peut pas démarrer : {m}")
                    };
                    os::message_ecran(&texte, Icone::Information);
                }
                2
            }
        };
    }

    // 2. La copie temporaire : c'est elle qui travaille (ce fichier-ci doit pouvoir être supprimé)
    let mut original = o.original.clone();
    if !o.copie {
        match copier_et_relancer(&lieux, &moi, &args) {
            Ok(()) => return 0,
            Err(_) => original = Some(moi.clone()), // (copie impossible : on travaille d'ici, ce fichier restera)
        }
    }
    if o.attendre_pid > 0 {
        os::attendre_processus(o.attendre_pid, 30_000);
    }

    let bilan = Bilan {
        journal: Some(os::journal_vers(texte::complet(&lieux.temp).join("Mindset-desinstallation.txt"))),
        ..Bilan::default()
    };
    bilan.journal(&format!(
        "Désinstallation de Mindset{}{}",
        if o.nettoyer { " (nettoyage de secours)" } else { "" },
        if lieux.test { " [test]" } else { "" }
    ));
    // (le système vit jusqu'à la fin du programme : le travail peut aller sur le fil de la fenêtre)
    let sys: &'static dyn Systeme = Box::leak(Box::new(sys));
    let mut travail = Travail::nouveau(sys, lieux, bilan, original.as_deref());
    let rapport = o.rapport.clone().unwrap_or_default();
    let code;
    if o.nettoyer || (o.silencieux && o.essai_fenetre < 0) {
        if let Err(p) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| travail.executer(o.supprimer_donnees)))
        {
            let m = p.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| p.downcast_ref::<String>().cloned());
            travail.bilan.reste(format!(
                "La désinstallation s'est arrêtée à cause d'une erreur : {}",
                m.unwrap_or_else(|| "erreur inconnue".into())
            ));
        }
        let ok = travail.bilan.restes.is_empty();
        code = if ok { 0 } else { 1 };
        let texte = fin::texte_bilan(&travail);
        fin::ecrire_rapport(&rapport, &fin::rapport(&travail, None, o.supprimer_donnees, &texte));
        if !o.silencieux {
            os::message_ecran(&texte, if ok { Icone::Information } else { Icone::Avertissement });
        }
    } else {
        let partage = Arc::new(Mutex::new(travail));
        let r = os::fenetre::afficher(Arc::clone(&partage), o.essai_fenetre);
        let travail = partage.lock().unwrap_or_else(|p| p.into_inner());
        match r {
            Ok(f) => {
                code = if f.annule {
                    2
                } else if travail.bilan.restes.is_empty() {
                    0
                } else {
                    1
                };
                let (donnees, texte) =
                    if f.annule { (false, "(annulé)".to_string()) } else { (f.donnees_demandees, f.texte_affiche) };
                fin::ecrire_rapport(&rapport, &fin::rapport(&travail, Some(&f.vu), donnees, &texte));
            }
            Err(e) => {
                if !o.silencieux {
                    os::message_ecran(&format!("La désinstallation ne peut pas démarrer :\n\n{e}"), Icone::Erreur);
                }
                code = 1;
            }
        }
    }

    // La copie temporaire se supprime une fois finie (par l'invite de commandes, quelques secondes après)
    if o.copie {
        os::supprimer_copie(&moi);
    }
    code
}

/// Se copie dans un dossier temporaire neuf (protégé, sauf en test) et s'y relance avec les mêmes options
fn copier_et_relancer(lieux: &Lieux, moi: &str, args: &[String]) -> Result<(), String> {
    let dossier = texte::complet(&lieux.temp).join(format!("Mindset-desinstallation-{}", os::hasard()));
    os::creer_dossier(&dossier, !lieux.test)?;
    let nom = Path::new(moi).file_name().ok_or("nom du programme inconnu")?;
    let copie = dossier.join(nom);
    std::fs::copy(moi, &copie).map_err(|e| e.to_string())?;
    let mut a = String::new();
    for x in args {
        a.push_str(&citer(x));
        a.push(' ');
    }
    a.push_str(&format!("-Copie -Original {} -AttendrePid {}", citer(moi), os::mon_pid()));
    os::lancer(&t(&copie), &a)
}
