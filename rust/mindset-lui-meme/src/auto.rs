//! Les mises à jour automatiques (mindset.ps1:338-555) : vérifiées toutes les 30 secondes. Une appli fermée est mise à
//! jour dès que sa nouvelle version est connue ; une appli qui tourne quand personne ne touche au PC depuis 5 minutes ;
//! Mindset lui-même quand il est caché, ou à l'écran quand personne ne touche au PC depuis 5 minutes. Même pendant un
//! jeu (décision de Jordan du 07/11/2026), jamais pendant une autre installation, seulement par le mini-installateur. Une à la fois. Une version ratée est
//! réessayée 15 minutes plus tard, 3 fois au plus par session.

use mindset_noyau::appli::appli_admin;
use mindset_noyau::{Appli, Contexte, Effets, partage, signaux};
use serde_json::Value;
use std::path::Path;
use suite_commun::protocole_installateur::{texte_ps, vrai_ps};

use crate::regles::{self, Essai};
use crate::{Echec, LuiMeme, historique};

/// Les mises à jour automatiques ne passent pas plus souvent (`Invoke-MajAuto`).
pub const PASSAGE_MS: u64 = 30_000;
/// Personne au clavier ni à la souris depuis ce temps : une appli ouverte (ou Mindset à l'écran) peut être mise à
/// jour.
pub const INACTIF_S: f64 = 300.0;

/// Ce qu'une carte de l'accueil sait d'une appli pour sa mise à jour (`Get-EtatCarte`, la partie utile ici).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Carte {
    pub maj_dispo: bool,
    pub occupe: bool,
    pub ouverte: bool,
    pub version: String,
}

/// `Get-EtatCarte` (MajDispo, Occupe, Ouverte, Pub.Version), d'après le tableau commun.
pub fn carte(ctx: &Contexte, a: &Appli) -> Carte {
    let inst = partage::installation(ctx, &a.id);
    let publication = partage::publication(ctx, &a.id);
    let version = publication.as_ref().map(|p| texte_ps(&regles::champ_ps(p, "version"))).unwrap_or_default();
    let maj_dispo = inst.as_ref().is_some_and(|i| {
        i.gere
            && !version.is_empty()
            && suite_commun::version::plus_recente(&version, i.version.as_deref().unwrap_or(""))
    });
    Carte {
        maj_dispo,
        occupe: partage::occupation(ctx, &a.id).is_some_and(|t| !t.is_empty()),
        ouverte: partage::ouverte(ctx, &a.id),
        version,
    }
}

impl LuiMeme {
    /// `Test-MajAutoRecente`
    pub fn maj_auto_recente(&self, ctx: &Contexte, id: &str, version: &str) -> bool {
        regles::reessai(self.essais.get(id), version, Self::ms(ctx)).is_some()
    }

    fn ajouter_essai(&mut self, ctx: &Contexte, id: &str, version: &str) {
        let e: Essai = regles::essai_suivant(self.essais.get(id), version, Self::ms(ctx));
        self.essais.insert(id.to_string(), e);
        self.essais_quand.insert(id.to_string(), ctx.heure_iso());
    }

    /// `Invoke-MajAuto`, rappelé toutes les 2 secondes (30 caché) ; il ne passe pas plus d'une fois toutes les
    /// 30 secondes.
    pub(crate) fn passer_maj_auto(&mut self, ctx: &Contexte, effets: &mut Effets) {
        if ctx.essai && !self.en_essai.maj_auto {
            return;
        }
        if !Self::maj_auto_active(ctx) || !Self::verif_active(ctx) || ctx.lancement.admin || !Self::tache_systeme(ctx) {
            return;
        }
        let pc = self.pc();
        pc.relever_manette();
        let maintenant = Self::ms(ctx);
        if self.derniere_maj_auto.is_some_and(|d| maintenant.saturating_sub(d) < PASSAGE_MS) {
            return;
        }
        self.derniere_maj_auto = Some(maintenant);
        let attentes_admin =
            ctx.lu(partage::ADMIN).and_then(|a| a.get("en_cours").and_then(Value::as_u64)).unwrap_or(0) > 0;
        if partage::une_occupation(ctx) || attentes_admin || !self.maj_auto.is_empty() {
            return;
        }
        // Un jeu ouvert n'arrête plus rien (décision de Jordan du 07/11/2026 : « si tu as activé les mises à jour
        // automatiques, elles se font peu importe si tu as un jeu ouvert ou non »). Avant, le lanceur de League of
        // Legends, ouvert des jours, bloquait tout. Seule reste l'attente de 5 minutes sans clavier ni souris pour une
        // appli ouverte (ou Mindset à l'écran).
        self.jeu = String::new();
        self.jeu_note = None;
        let Ok(inactif) = pc.secondes_inactif() else { return };
        let vue = ctx.vue();
        let a_l_ecran = vue.visible && !vue.reduite;
        let mut attentes = std::collections::BTreeMap::new();
        for a in ctx.applis().iter() {
            let e = carte(ctx, a);
            if !e.maj_dispo || e.occupe {
                continue;
            }
            if self.maj_auto_recente(ctx, &a.id, &e.version) {
                continue;
            }
            // (on s'en sert peut-être : après 5 minutes sans clavier ni souris, elle est fermée, mise à jour et
            // relancée, comme Mindset lui-même ; sa page à l'écran ne compte plus, décision de Jordan du 30/10)
            if e.ouverte && inactif < INACTIF_S {
                attentes.insert(a.id.clone(), "utilise".to_string());
                continue;
            }
            self.attentes = attentes;
            self.ajouter_essai(ctx, &a.id, &e.version);
            self.maj_auto.insert(a.id.clone(), e.version.clone());
            ctx.journal(&format!(
                "Mise à jour automatique : {} {}{}",
                a.nom,
                e.version,
                if e.ouverte { " (elle tournait, relancée cachée)" } else { "" }
            ));
            effets.ajouter(signaux::installer(&a.id, None, true));
            return;
        }
        // Mindset lui-même : caché (près de l'horloge, ou réduit), ou à l'écran quand personne ne touche au PC depuis
        // 5 minutes ; il revient comme il était. (pas pendant qu'une version plus récente se télécharge)
        let m = self.maj_prete.clone();
        let attendre = m.is_some() && a_l_ecran && inactif < INACTIF_S;
        if attendre {
            attentes.insert("mindset".into(), "veille".into());
        }
        self.attentes = attentes;
        if let Some(m) = m
            && !attendre
            && !self.maj_en_cours
            && !self.maj_auto_recente(ctx, "mindset", &m.version)
        {
            self.ajouter_essai(ctx, "mindset", &m.version);
            ctx.journal(&format!(
                "Mise à jour automatique : Mindset {}{}",
                m.version,
                if a_l_ecran { " (à l'écran, personne au clavier depuis 5 minutes)" } else { "" }
            ));
            self.lancer_maj(ctx, !a_l_ecran, true, effets);
        }
    }

    /// La fin d'une installation (signal `operation-finie` du bloc « installations ») : la mise à jour automatique
    /// (`Complete-MajAuto`, appelé par `Stop-Operation`), et l'historique quand c'était une mise à jour (champ
    /// `historique: { version, notes }`, voir DIVERGENCES.md).
    pub(crate) fn operation_finie(&mut self, ctx: &Contexte, d: &Value, effets: &mut Effets) {
        let id = d.get("id").map(texte_ps).unwrap_or_default();
        let message = d.get("message").map(texte_ps).unwrap_or_default();
        let Some(a) = ctx.appli(&id) else { return };
        if let Some(h) = d.get("historique").filter(|h| vrai_ps(h)) {
            // (le bloc « installations » donne { id, nom, version, auto, notes } ; sans « auto », celui de ce bloc)
            let auto = h.get("auto").map_or(self.maj_auto.contains_key(&id), vrai_ps);
            let version = h.get("version").map(texte_ps).unwrap_or_default();
            let notes = h.get("notes").map(texte_ps).unwrap_or_default();
            historique::ajouter(ctx, &a.id, &a.nom, &version, auto, &notes);
        }
        if self.maj_auto.contains_key(&id) {
            self.fin_maj_auto(ctx, &a, &message, effets);
        }
    }

    /// `Complete-MajAuto` : la notification, ou la bulle de la console.
    pub(crate) fn fin_maj_auto(&mut self, ctx: &Contexte, a: &Appli, message: &str, effets: &mut Effets) {
        let v = self.maj_auto.remove(&a.id).unwrap_or_default();
        if !message.to_lowercase().contains("est installé") {
            self.echec_auto(ctx, &a.id, &a.nom, &v, message, effets);
            return;
        }
        self.echecs.remove(&a.id);
        let notes =
            partage::publication(ctx, &a.id).map(|p| texte_ps(&regles::champ_ps(&p, "notes"))).unwrap_or_default();
        let (titre, texte) = regles::bulle_reussie(&a.nom, &v, &notes);
        self.bulle_maj_auto(ctx, &titre, &texte, effets);
    }

    /// `Set-EchecMajAuto` : noté au journal, gardé pour la console (la raison et « Réessayer »), et dit tout de suite.
    pub(crate) fn echec_auto(
        &mut self,
        ctx: &Contexte,
        id: &str,
        nom: &str,
        version: &str,
        message: &str,
        effets: &mut Effets,
    ) {
        ctx.journal(&format!("Mise à jour automatique de {nom} {version} ratée : {message}"));
        let raison = regles::raison_echec_maj(nom, message);
        self.echecs.insert(id.to_string(), Echec { version: version.to_string(), raison: raison.clone() });
        let r = regles::reessai(self.essais.get(id), version, Self::ms(ctx));
        let (titre, texte) = regles::bulle_ratee(nom, &raison, r);
        self.bulle_maj_auto(ctx, &titre, &texte, effets);
    }

    /// `Show-BulleMajAuto` : la bulle de la console si Mindset est à l'écran avec sa console, sinon la bulle près de
    /// l'horloge.
    pub(crate) fn bulle_maj_auto(&self, ctx: &Contexte, titre: &str, texte: &str, effets: &mut Effets) {
        ctx.journal(&format!("Mise à jour automatique : {titre}"));
        let vue = ctx.vue();
        let console = ctx.lu(partage::CONSOLE).is_some_and(|c| c.get("possible").is_some_and(vrai_ps));
        if vue.visible && !vue.reduite && console {
            effets.ajouter(signaux::message_console(titre));
        } else {
            let t = if texte.is_empty() { "Mise à jour faite toute seule." } else { texte };
            effets.ajouter(signaux::bulle(titre, t, "info", 6000));
        }
    }

    /// `Get-JeuEnCours` : la raison, ou « ».
    pub fn jeu_en_cours(&mut self, ctx: &Contexte) -> String {
        let pc = self.pc();
        if pc.plein_ecran() {
            return regles::raison_jeu(true, f64::MAX, None);
        }
        if pc.secondes_manette() < 300.0 {
            return regles::raison_jeu(false, pc.secondes_manette(), None);
        }
        let chemins: Vec<String> = ctx.systeme().processus().into_iter().filter_map(|p| p.chemin).collect();
        let nevermind = self.jeux_nevermind(ctx);
        let jeux = regles::jeux_ouverts(&chemins, &nevermind);
        match jeux.first() {
            Some(j) => {
                let (description, produit) = pc.infos_programme(j);
                let n = regles::nom_programme(description.as_deref(), produit.as_deref(), j);
                regles::raison_jeu(false, f64::MAX, Some(&n))
            }
            None => String::new(),
        }
    }

    /// `Get-JeuxNevermind` : les jeux ajoutés à la main dans Nevermind (relus seulement si son fichier a changé).
    pub fn jeux_nevermind(&mut self, ctx: &Contexte) -> Vec<String> {
        let Some(a) = ctx.appli("nevermind") else { return Vec::new() };
        // Get-DossierDonnees : son dossier dans les données de la suite s'il est géré, sinon l'ancien
        let suite = ctx.dossiers.donnees_suite.join(&a.nom);
        let gere = partage::installation(ctx, &a.id).is_some_and(|i| i.gere);
        let premier = if gere && suite.is_dir() { suite.to_string_lossy().into_owned() } else { a.donnees.clone() };
        let mut dossiers: Vec<String> = Vec::new();
        for d in [premier, a.donnees.clone()] {
            if !d.is_empty() && !dossiers.iter().any(|x| x == &d) {
                dossiers.push(d);
            }
        }
        for d in dossiers {
            let f = Path::new(&d).join("parametres.json");
            let Ok(m) = std::fs::metadata(&f) else { continue };
            if !m.is_file() || m.len() > 4 * 1024 * 1024 {
                continue;
            }
            let cle = format!("{}|{:?}", f.display(), m.modified().ok());
            if self.jeux_nevermind.0 != cle {
                let lu = std::fs::read(&f)
                    .ok()
                    .and_then(|o| serde_json::from_str::<Value>(&suite_commun::json_sur::texte_du_fichier(&o)).ok());
                match lu {
                    Some(j) => self.jeux_nevermind = (cle, regles::jeux_nevermind(&j)),
                    None => {
                        self.jeux_nevermind.0 = String::new();
                        return Vec::new();
                    }
                }
            }
            return self.jeux_nevermind.1.clone();
        }
        Vec::new()
    }

    /// Les applis « administrateur » ne sont pas lancées par un Mindset sans les droits (`Start-Demarrage`).
    pub(crate) fn appli_admin(ctx: &Contexte, a: &Appli) -> bool {
        appli_admin(a, partage::installation(ctx, &a.id).as_ref())
    }
}
