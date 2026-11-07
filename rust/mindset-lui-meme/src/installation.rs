//! Mindset s'installe sur le PC (mindset.ps1:9-91, parametres.ps1:178-199) : le bandeau de bienvenue (Mindset lancé
//! depuis le dossier téléchargé), le choix du disque, l'installation par le mini-installateur (action « mindset »,
//! une demande de Windows), ses raccourcis et son lancement avec Windows, puis le Mindset installé prend le relais.

use mindset_noyau::{Contexte, Effet, Effets, signaux};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};

use crate::pc::Raccourci;
use crate::regles::{self, DESCRIPTION_RACCOURCI, ID_APPLI};
use crate::{Demande, LuiMeme, TEXTE_BIENVENUE};

/// Le travail de fond qui retire la marque « téléchargé depuis Internet ».
pub const TACHE_DEBLOQUER: &str = "debloquer";

/// `Test-MindsetInstalle` : ce Mindset est celui du dossier des programmes.
pub fn installe(ctx: &Contexte) -> bool {
    suite_commun::chemins::egal(
        &ctx.dossiers.mindset.to_string_lossy(),
        &ctx.dossiers.mindset_installe().to_string_lossy(),
    )
}

/// `Test-MindsetDeveloppement` : un dossier de travail (dépôt Git) : pas de proposition d'installation.
pub fn developpement(ctx: &Contexte) -> bool {
    let m = ctx.dossiers.mindset.to_string_lossy().into_owned();
    let p = suite_commun::chemins::parent(&m);
    Path::new(&suite_commun::chemins::joindre(p, ".git")).exists()
}

/// Les données de la suite d'un Mindset installé dans `dossier` (`(Get-RacinesDepuis $Dossier).Donnees`).
pub fn donnees_depuis(dossier: &str, local_mindset: &Path) -> PathBuf {
    use suite_commun::chemins::{egal, feuille, joindre, parent};
    let p = parent(dossier);
    let m = parent(p);
    if egal(feuille(p), "Programmes") && !m.is_empty() && egal(feuille(m), "Mindset") {
        return PathBuf::from(joindre(m, "Donnees"));
    }
    local_mindset.to_path_buf()
}

impl LuiMeme {
    /// Au démarrage : le bandeau de bienvenue et ses disques, la marque « téléchargé depuis Internet » retirée.
    pub(crate) fn demarrer_installation(&mut self, ctx: &Contexte, effets: &mut Effets) {
        self.attente_bienvenue =
            if ctx.essai { self.en_essai.bienvenue } else { !installe(ctx) && !developpement(ctx) };
        self.bienvenue_texte = TEXTE_BIENVENUE.into();
        let pc = self.pc();
        self.disques = regles::disques(&pc.volumes(), &pc.disque_systeme());
        let d = &ctx.dossiers.disque;
        self.disque_coche = if self.disques.iter().any(|x| &x.lettre == d) { d.clone() } else { String::new() };
        if !ctx.essai {
            // Mindset.ps1:96 : retire la marque « téléchargé depuis Internet » (fichiers\), pour que Windows
            // n'avertisse plus aux lancements suivants
            let dossier = ctx.dossiers.fichiers.clone();
            effets.tache(TACHE_DEBLOQUER, move || {
                pc.debloquer(&dossier);
                Ok(Value::Null)
            });
        }
    }

    /// `Install-Mindset` : `disque` « » pour C: (Program Files), sinon la lettre du disque choisi (X:\Mindset).
    pub(crate) fn installer(&mut self, ctx: &Contexte, disque: &str, effets: &mut Effets) {
        if self.install_en_cours {
            return;
        }
        // (seulement un disque proposé : le choix de la page est vérifié)
        let disque = if self.disques.iter().any(|x| x.lettre == disque) { disque.to_string() } else { String::new() };
        self.install_en_cours = true;
        self.bienvenue_texte = "Installation (accepte la demande de Windows)...".into();
        let sid = self.pc().sid();
        let mut p = Map::new();
        let source = ctx.dossiers.mindset.to_string_lossy().into_owned();
        // (Invoke-Admin ne passe pas les valeurs vides)
        for (k, v) in [("Source", source), ("Version", ctx.version.clone()), ("Disque", disque), ("Sid", sid)] {
            if !v.is_empty() {
                p.insert(k.into(), Value::String(v));
            }
        }
        let id = Self::nouvel_id();
        self.demandes.insert(id.clone(), Demande::Installation);
        effets.ajouter(signaux::admin_demande(&id, "mindset", Value::Object(p), true, false));
    }

    /// La fin de `Install-Mindset` : `message` = le dossier installé, et « |sans-taches... » si ses tâches planifiées
    /// n'ont pas pu être créées.
    pub(crate) fn installation_finie(&mut self, ctx: &Contexte, ok: bool, message: &str, effets: &mut Effets) {
        self.install_en_cours = false;
        if !ok {
            self.bienvenue_texte = format!("Installation impossible : {message}");
            return;
        }
        let (dossier, sans_taches) = match message.split_once('|') {
            Some((d, s)) => (d.to_string(), s.to_string()),
            None => (message.to_string(), String::new()),
        };
        self.copier_reglage_verif(ctx, &dossier);
        let exe = suite_commun::chemins::joindre(&dossier, "Mindset.exe");
        let pc = self.pc();
        for l in pc.raccourcis_mindset() {
            let r = Raccourci {
                cible: exe.clone(),
                icone: exe.clone(),
                app_id: ID_APPLI.into(),
                dossier: dossier.clone(),
                description: DESCRIPTION_RACCOURCI.into(),
            };
            if let Err(e) = pc.ecrire_raccourci(&l, &r) {
                ctx.journal(&format!("Raccourci {} : {e}", l.display()));
            }
        }
        // Lancement avec Windows : par sa tâche planifiée (en administrateur), sinon par le registre (sans les droits)
        if !sans_taches.is_empty() {
            ctx.journal(&format!("Tâches planifiées : {sans_taches}"));
            if let Err(e) = pc.ecrire_run(&format!("\"{exe}\" -Demarrage")) {
                ctx.journal(&format!("Lancement avec Windows (registre) : {e}"));
            }
        } else if pc.run().is_some() {
            let _ = pc.retirer_run();
        }
        ctx.journal(&format!("Mindset {} installé dans {dossier}", ctx.version));
        // Le Mindset installé prend le relais ; celui-ci (dans le dossier téléchargé) se ferme
        effets.ajouter(Effet::LancerApres(PathBuf::from(&exe)));
        effets.ajouter(Effet::Quitter { avec_applis: false });
    }

    /// `Copy-ReglageVerif` : « Chercher les nouvelles versions » coupé dans le bandeau d'installation suit Mindset
    /// installé sur un autre disque, où sont alors ses réglages (X:\Mindset\Donnees\Mindset).
    pub fn copier_reglage_verif(&self, ctx: &Contexte, dossier: &str) {
        if Self::verif_active(ctx) {
            return;
        }
        let f = donnees_depuis(dossier, &ctx.dossiers.local_mindset).join("Mindset").join("reglages.json");
        if suite_commun::chemins::egal(&f.to_string_lossy(), &ctx.dossiers.reglages().to_string_lossy()) {
            return;
        }
        let d = ctx.donnees();
        let mut r = match d.lire_json(&f) {
            Ok(Some(Value::Object(m))) => m,
            Ok(_) => Map::new(),
            Err(e) => {
                ctx.journal(&format!(
                    "Réglage « Chercher les nouvelles versions » non repris dans {} : {e}",
                    f.display()
                ));
                return;
            }
        };
        r.insert("VerifVersions".into(), Value::Bool(false));
        if let Err(e) = d.ecrire_json(&f, &Value::Object(r)) {
            ctx.journal(&format!("Réglage « Chercher les nouvelles versions » non repris dans {} : {e}", f.display()));
        }
    }

    /// `Update-RaccourcisMindset` : ses raccourcis portent son identité dans la barre des tâches ; ceux d'avant (sans
    /// identité) sont réécrits, seulement s'ils lancent ce Mindset installé (un raccourci supprimé n'est pas recréé).
    pub(crate) fn mettre_a_jour_raccourcis(&self, ctx: &Contexte) {
        if !installe(ctx) {
            return;
        }
        let exe = ctx.dossiers.exe.to_string_lossy().into_owned();
        let dossier = suite_commun::chemins::parent(&exe).to_string();
        let pc = self.pc();
        for l in pc.raccourcis_mindset() {
            if !pc.existe(&l) {
                continue;
            }
            let r = match pc.lire_raccourci(&l) {
                Ok(r) => r,
                Err(e) => {
                    ctx.journal(&format!("Raccourci {} : {e}", l.display()));
                    continue;
                }
            };
            if !suite_commun::chemins::egal(&r.cible, &exe) || r.app_id == ID_APPLI {
                continue;
            }
            let n = Raccourci {
                cible: exe.clone(),
                icone: exe.clone(),
                app_id: ID_APPLI.into(),
                dossier: dossier.clone(),
                description: DESCRIPTION_RACCOURCI.into(),
            };
            match pc.ecrire_raccourci(&l, &n) {
                Ok(()) => ctx.journal(&format!("Raccourci {} : identité ajoutée", l.display())),
                Err(e) => ctx.journal(&format!("Raccourci {} : {e}", l.display())),
            }
        }
    }
}

/// La forme des disques dans l'état de la page (pour les tests).
pub fn disques_json(d: &[regles::Disque]) -> Value {
    json!(d.iter().map(|x| json!({ "lettre": x.lettre, "texte": x.texte, "libre": x.libre })).collect::<Vec<_>>())
}
