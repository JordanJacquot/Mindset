//! La mise à jour de Mindset lui-même (mindset.ps1:181-336) : la nouvelle version téléchargée et sa signature
//! vérifiée en arrière-plan, puis un bandeau la propose ; un clic (ou la mise à jour automatique) : Mindset demande au
//! mini-installateur de l'installer (`mindset-maj`), se ferme à son accusé de réception, et le mini-installateur le
//! relance par sa tâche de démarrage. Au redémarrage, le résultat (HKLM `Resultat`, ou le fichier de la demande de
//! Windows) est dit par le bandeau.
//!
//! La publication de Mindset (`Get-Publication 'JordanJacquot/Mindset' 'Mindset.zip'`) est cherchée par le bloc
//! « publications » (`publications.mindset` du tableau commun) : ce bloc la lit quand il reçoit `verifier-mindset` ou
//! `publications-changees`, puis télécharge et vérifie le zip lui-même.

use mindset_noyau::installateur::Direct;
use mindset_noyau::reseau::{DemandeHttp, Reseau};
use mindset_noyau::{Contexte, Effet, Effets, Progres, partage, signaux};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use suite_commun::protocole_installateur::{texte_ps, vrai_ps};

use crate::regles::champ_ps;
use crate::{Demande, LuiMeme, MajPrete, historique, installation};

/// Le travail de fond du téléchargement de la nouvelle version.
pub const TACHE_VERIF: &str = "verif-mindset";
/// La recherche abandonnée si le bloc « publications » ne répond pas dans ce délai.
pub const ATTENTE_PUBLICATION_MS: u64 = 120_000;

/// L'avancée du téléchargement de la nouvelle version (`$script:ProgresMindset` : Version, Recu, Total).
#[derive(Debug, Default)]
pub struct ProgresMindset {
    version: Mutex<String>,
    pub progres: Progres,
}

impl ProgresMindset {
    /// La version qui se télécharge (« » : la recherche n'est pas finie).
    pub fn version(&self) -> String {
        self.version.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
    fn poser_version(&self, v: &str) {
        *self.version.lock().unwrap_or_else(|e| e.into_inner()) = v.to_string();
    }
}

/// `$FichierMajMindset` : la réponse d'une mise à jour faite par la demande de Windows.
pub fn fichier_maj(ctx: &Contexte) -> PathBuf {
    ctx.dossiers.telechargements().join("maj-mindset.json")
}

/// Un fichier téléchargé (`Get-Octets`) : une réponse qui n'est pas un succès est une erreur, comme
/// `HttpWebRequest.GetResponse`.
fn octets(reseau: &dyn Reseau, url: &str, progres: Option<&Progres>) -> Result<Vec<u8>, String> {
    let r = reseau.demander(&DemandeHttp::get(url), progres)?;
    if !(200..300).contains(&r.statut) {
        return Err(format!("Le serveur distant a retourné une erreur : ({}).", r.statut));
    }
    Ok(r.corps)
}

/// Ce que fait le travail de fond de `Start-VerifMajMindset` : rend `{ AJour }` ou `{ Version, Zip, Sig, Notes }`.
pub fn telecharger(
    publication: &Value,
    deja: &str,
    reseau: &dyn Reseau,
    progres: &ProgresMindset,
    cles: &Path,
    dossier: &Path,
) -> Result<Value, String> {
    let erreur = texte_ps(&champ_ps(publication, "erreur"));
    if !erreur.is_empty() {
        return Err(erreur);
    }
    let version = texte_ps(&champ_ps(publication, "version"));
    if !suite_commun::version::plus_recente(&version, deja) {
        return Ok(json!({ "AJour": true }));
    }
    let url_sig = texte_ps(&champ_ps(publication, "url_sig"));
    if url_sig.is_empty() {
        return Err(format!("la version {version} n'est pas signée"));
    }
    progres.poser_version(&version);
    let zip = octets(reseau, &texte_ps(&champ_ps(publication, "url_zip")), Some(&progres.progres))?;
    let sig = octets(reseau, &url_sig, None)?;
    if !suite_commun::signature::verifier_signature(&zip, &sig, cles) {
        return Err(format!("la signature de la version {version} est invalide"));
    }
    let fz = dossier.join("mindset.zip.nouveau");
    let fs = dossier.join("mindset.zip.nouveau.sig");
    std::fs::write(&fz, &zip).map_err(|e| e.to_string())?;
    std::fs::write(&fs, &sig).map_err(|e| e.to_string())?;
    Ok(json!({ "Version": version, "Zip": fz.to_string_lossy(), "Sig": fs.to_string_lossy(),
        "Notes": texte_ps(&champ_ps(publication, "notes")) }))
}

impl LuiMeme {
    /// `Start-VerifMajMindset` : la recherche commence ; elle attend la publication de Mindset.
    pub(crate) fn verifier_maj(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let permis = installation::installe(ctx) && (!ctx.essai || self.en_essai.maj);
        if !permis || self.maj_en_cours {
            return;
        }
        self.maj_en_cours = true;
        let _ = std::fs::create_dir_all(ctx.dossiers.telechargements());
        self.progres = Some(Arc::new(ProgresMindset::default()));
        self.attente_publication = Some(Self::ms(ctx));
        // (la publication est peut-être déjà là : seulement si sa question à GitHub n'est plus en route ; sinon celle
        // qui est là est celle de la recherche d'avant, et c'est `publications-changees { id: "mindset" }` qui suivra)
        let en_route = ctx
            .lu(partage::RECHERCHE)
            .and_then(|r| r.get("mindset_en_cours").and_then(Value::as_bool))
            .unwrap_or(false);
        if !en_route && partage::publication(ctx, "mindset").is_some() {
            self.publication_recue(ctx, effets);
        }
    }

    /// La publication de Mindset est arrivée (ou a changé) : le téléchargement part en arrière-plan.
    pub(crate) fn publication_recue(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let Some(p) = partage::publication(ctx, "mindset") else { return };
        let nouvelle = self.publication_vue.as_ref() != Some(&p);
        if self.attente_publication.is_none() {
            // (pas de recherche en cours : une nouvelle publication de Mindset en lance une, comme
            // Invoke-Actualiser appelle Start-VerifMajMindset après Update-Publications)
            if !nouvelle || self.maj_en_cours {
                return;
            }
            self.verifier_maj(ctx, effets);
            return;
        }
        self.attente_publication = None;
        self.publication_vue = Some(p.clone());
        let deja = match &self.maj_prete {
            Some(m) if suite_commun::version::plus_recente(&m.version, &ctx.version) => m.version.clone(),
            _ => ctx.version.clone(),
        };
        let progres = Arc::clone(self.progres.get_or_insert_with(|| Arc::new(ProgresMindset::default())));
        let reseau = ctx.reseau();
        let cles = ctx.dossiers.fichiers.join("cles-publiques");
        let dossier = ctx.dossiers.telechargements();
        effets.tache(TACHE_VERIF, move || telecharger(&p, &deja, reseau.as_ref(), &progres, &cles, &dossier));
    }

    /// La recherche attend la publication depuis trop longtemps : elle s'arrête (le bloc « publications » ne l'a
    /// pas donnée), la suivante pourra partir.
    pub(crate) fn suivre_recherche(&mut self, ctx: &Contexte) {
        if let Some(t) = self.attente_publication
            && Self::ms(ctx).saturating_sub(t) >= ATTENTE_PUBLICATION_MS
        {
            self.attente_publication = None;
            self.maj_en_cours = false;
            self.progres = None;
            ctx.journal("Mise à jour de Mindset : pas de réponse pour la dernière version");
        }
    }

    /// La fin du travail de `Start-VerifMajMindset`.
    pub(crate) fn verif_finie(&mut self, ctx: &Contexte, resultat: Result<Value, String>) {
        self.maj_en_cours = false;
        self.progres = None;
        let r = match resultat {
            Err(e) => {
                ctx.journal(&format!("Mise à jour de Mindset : {e}"));
                return;
            }
            Ok(r) => r,
        };
        let version = texte_ps(&champ_ps(&r, "Version"));
        if version.is_empty() {
            return;
        }
        // Le zip vérifié prend la place de celui d'avant (une version plus ancienne, prête mais pas installée)
        let fz = ctx.dossiers.telechargements().join("mindset.zip");
        let fs = ctx.dossiers.telechargements().join("mindset.zip.sig");
        let zip = texte_ps(&champ_ps(&r, "Zip"));
        let sig = texte_ps(&champ_ps(&r, "Sig"));
        let deplacer = std::fs::rename(&zip, &fz).and_then(|_| std::fs::rename(&sig, &fs));
        if let Err(e) = deplacer {
            ctx.journal(&format!(
                "Mise à jour de Mindset : le zip de la version {version} n'a pas pu remplacer l'ancien ({e})"
            ));
            for f in [&zip, &sig] {
                let _ = std::fs::remove_file(f);
            }
            return;
        }
        if let Some(avant) = &self.maj_prete {
            ctx.journal(&format!("Mindset {} était prêt, remplacé par la {version}, plus récente", avant.version));
        }
        self.maj_prete = Some(MajPrete {
            version: version.clone(),
            zip: fz.to_string_lossy().into_owned(),
            sig: fs.to_string_lossy().into_owned(),
            notes: texte_ps(&champ_ps(&r, "Notes")),
        });
        ctx.journal(&format!("Mindset {version} téléchargé et vérifié, prêt à installer"));
        self.bandeau.titre = format!("Mindset {version} est prêt");
        self.bandeau.texte = "La nouvelle version est téléchargée et sa signature vérifiée. Mindset va se fermer, se mettre à jour et se rouvrir tout seul.".into();
        self.bandeau.bouton_maj = true;
        self.bandeau.bouton_fermer = "Plus tard";
        self.bandeau.visible = true;
    }

    /// `Confirm-MajMindsetConsole` : « Mettre à jour » sur la carte de la console, une question d'abord.
    pub(crate) fn confirmer_maj(&mut self, effets: &mut Effets) {
        let Some(m) = &self.maj_prete else { return };
        effets.ajouter(signaux::confirmation(
            "Mettre à jour Mindset ?",
            &format!(
                "Mindset va se fermer, se mettre à jour (version {}) puis se rouvrir tout seul. Tes applis restent ouvertes.",
                m.version
            ),
            "Mettre à jour",
            crate::actions::MAJ_OUI,
            Value::Null,
        ));
    }

    /// `Start-MajMindset` : `auto` (mise à jour automatique : jamais de demande de Windows), `cache` (faite pendant que
    /// Mindset est caché : il revient caché).
    pub fn lancer_maj(&mut self, ctx: &Contexte, cache: bool, auto: bool, effets: &mut Effets) {
        let en_auto = auto || cache;
        let occupe = partage::une_occupation(ctx);
        if occupe {
            // (même sans version prête, comme la version PowerShell : le texte du bandeau le dit)
            self.bandeau.texte = "Une installation est en cours : réessaie quand elle sera finie.".into();
            return;
        }
        let Some(m) = self.maj_prete.clone() else { return };
        if self.maj_envoyee {
            return;
        }
        if !en_auto {
            self.echecs.remove("mindset");
        }
        let _ = std::fs::remove_file(fichier_maj(ctx));
        historique::attendre_mindset(ctx, &m.version, en_auto, &m.notes);
        // Demandée à l'écran : Mindset revient avec sa fenêtre (le mini-installateur le relance par sa tâche de
        // démarrage, qui le lancerait sinon caché près de l'horloge)
        ctx.ecrire_reglage("MajMindsetVisible", Value::Bool(!cache));
        // Par la file du bloc « installations » (une demande à la fois). Par la tâche du mini-installateur : les champs
        // de Start-MajMindset (Id, Action, Zip, Signature, Destination, Version, AttendrePid, Cache) ; Mindset ne se
        // ferme qu'à son accusé de réception. Sans elle (Mindset administrateur, tâche absente) : la demande de
        // Windows (Start-MajMindsetDirecte : sans Id ni Cache, avec Sid, sa réponse dans maj-mindset.json).
        let par_tache = !ctx.lancement.admin && Self::tache_systeme(ctx);
        let destination = ctx.dossiers.mindset_installe().to_string_lossy().into_owned();
        if !par_tache {
            for v in [&m.zip, &m.sig, &destination] {
                if v.contains('"') {
                    self.bandeau.texte = format!("Mise à jour impossible : Valeur refusée (guillemet) : {v}");
                    return;
                }
            }
        }
        let id = Self::nouvel_id();
        let mut p = Map::new();
        if par_tache {
            p.insert("Id".into(), json!(id));
        }
        p.insert("Zip".into(), json!(m.zip));
        p.insert("Signature".into(), json!(m.sig));
        p.insert("Destination".into(), json!(destination));
        p.insert("Version".into(), json!(m.version));
        p.insert("AttendrePid".into(), json!(ctx.pid().to_string()));
        if par_tache && cache {
            p.insert("Cache".into(), json!("1"));
        }
        if !par_tache {
            p.insert("Sid".into(), json!(self.pc().sid()));
        }
        self.maj_envoyee = true;
        self.demandes.insert(id.clone(), Demande::Maj { version: m.version.clone(), auto: en_auto, recu: false });
        effets.signal(
            signaux::ADMIN_DEMANDE,
            json!({ "id": id, "action": "mindset-maj", "parametres": Value::Object(p), "repli": !en_auto,
                "auto": en_auto, "resultat": fichier_maj(ctx).to_string_lossy() }),
        );
    }

    /// `Test-TacheInstallation` : la tâche SYSTEM du mini-installateur est là (d'après le bloc « installations »).
    pub(crate) fn tache_systeme(ctx: &Contexte) -> bool {
        ctx.lu(partage::ADMIN).is_some_and(|a| a.get("tache").and_then(Value::as_str) == Some("systeme"))
    }

    /// `Start-MajMindsetDirecte` : par la demande normale de Windows (MindsetInstallateur.exe en administrateur) ; il
    /// attend la fermeture de Mindset, installe, puis le relance.
    pub fn lancer_maj_directe(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let Some(m) = self.maj_prete.clone() else { return };
        let destination = ctx.dossiers.mindset_installe().to_string_lossy().into_owned();
        for v in [&m.zip, &m.sig, &destination] {
            if v.contains('"') {
                self.bandeau.texte = format!("Mise à jour impossible : Valeur refusée (guillemet) : {v}");
                return;
            }
        }
        let d = Direct {
            action: "mindset-maj".into(),
            parametres: vec![
                ("Zip".into(), m.zip.clone()),
                ("Signature".into(), m.sig.clone()),
                ("Destination".into(), destination),
                ("Version".into(), m.version.clone()),
                ("AttendrePid".into(), ctx.pid().to_string()),
                ("Sid".into(), self.pc().sid()),
            ],
            resultat: fichier_maj(ctx),
        };
        if ctx.installateur().lancer_direct(&d).is_err() {
            self.bandeau.texte =
                "Mise à jour annulée : l'autorisation de Windows a été refusée. Tu peux réessayer.".into();
            return;
        }
        ctx.journal(&format!("Mise à jour vers Mindset {} lancée", m.version));
        effets.ajouter(Effet::Quitter { avec_applis: false });
    }

    /// L'accusé de réception d'une demande de ce bloc.
    pub(crate) fn admin_recu(&mut self, ctx: &Contexte, id: &str, direct: bool, effets: &mut Effets) {
        let Some(Demande::Maj { version, recu, .. }) = self.demandes.get_mut(id) else { return };
        if *recu {
            return;
        }
        *recu = true;
        // (par la tâche : sa réponse sera dans HKLM, reconnue à ce numéro ; en direct : dans maj-mindset.json)
        if !direct {
            ctx.ecrire_reglage("MajMindsetDemande", Value::String(id.to_string()));
        }
        ctx.journal(&format!("Mise à jour vers Mindset {version} lancée"));
        effets.ajouter(Effet::Quitter { avec_applis: false });
    }

    /// La réponse à une demande de ce bloc.
    pub(crate) fn admin_fini(
        &mut self,
        ctx: &Contexte,
        id: &str,
        ok: bool,
        message: &str,
        donnees: &Value,
        effets: &mut Effets,
    ) {
        let Some(d) = self.demandes.remove(id) else { return };
        match d {
            Demande::Installation => self.installation_finie(ctx, ok, message, effets),
            Demande::Suppression => {
                if !ok {
                    ctx.journal(&format!("Désinstallation de Mindset : {message}"));
                    self.desinstall_echec = Some(message.to_string());
                }
            }
            Demande::Maj { version, auto, recu } => {
                self.maj_envoyee = false;
                // Pas d'accusé de réception (tâche absente, refusée, muette) : le repli (Skip-TacheInstallation), la
                // demande de Windows, sauf pour une mise à jour automatique (personne pour y répondre)
                let sans_tache = donnees.get("sans_tache").is_some_and(vrai_ps)
                    || (!ok && !recu && message.starts_with("la tâche d'installation ne répond pas"));
                if sans_tache {
                    if auto {
                        self.echec_auto(
                            ctx,
                            "mindset",
                            "Mindset",
                            &version,
                            "la tâche d'installation ne répond pas",
                            effets,
                        );
                    } else {
                        self.lancer_maj_directe(ctx, effets);
                    }
                    return;
                }
                if !ok {
                    self.bandeau.texte = format!("Mise à jour impossible : {message}");
                    if auto {
                        self.echec_auto(ctx, "mindset", "Mindset", &version, message, effets);
                    }
                }
            }
        }
    }

    /// `Show-ResultatMajMindset` : au démarrage, le résultat de la mise à jour (et ce qu'une désinstallation a
    /// laissé).
    pub fn resultat_maj(&mut self, ctx: &Contexte) {
        historique::resoudre_mindset(ctx);
        ctx.ecrire_reglage("MajMindsetVisible", Value::Bool(false));
        self.restes_desinstallation(ctx);
        let inst = ctx.installateur();
        let mut r: Option<Value> = None;
        // Mise à jour faite par le mini-installateur : sa réponse dans le registre, reconnue à son numéro
        let id = ctx.reglage_texte("MajMindsetDemande", "");
        if !id.is_empty() {
            ctx.ecrire_reglage("MajMindsetDemande", Value::String(String::new()));
            r = serde_json::from_str::<Value>(&inst.valeur("Resultat")).ok().filter(vrai_ps);
            if r.as_ref().is_some_and(|x| !suite_commun::chemins::egal(&texte_ps(&champ_ps(x, "id")), &id)) {
                r = None;
            }
            // (le mini-installateur ne l'efface pas : c'est à Mindset de le faire)
            inst.retirer_demande();
        }
        let f = fichier_maj(ctx);
        let r = match r {
            Some(r) => r,
            None => {
                let Ok(o) = std::fs::read(&f) else { return };
                let t = suite_commun::json_sur::texte_du_fichier(&o);
                // (un fichier vide : ConvertFrom-Json ne rend rien, sans erreur)
                let v = if suite_commun::json_sur::texte_vide(&t) {
                    Value::Null
                } else {
                    let Ok(v) = serde_json::from_str::<Value>(&t) else { return };
                    v
                };
                let _ = std::fs::remove_file(&f);
                v
            }
        };
        for n in ["mindset.zip", "mindset.zip.sig", "mindset.zip.nouveau", "mindset.zip.nouveau.sig"] {
            let _ = std::fs::remove_file(ctx.dossiers.telechargements().join(n));
        }
        self.bandeau.bouton_maj = false;
        self.bandeau.bouton_fermer = "OK";
        let ok = vrai_ps(&champ_ps(&r, "ok"));
        let message = texte_ps(&champ_ps(&r, "message"));
        if ok {
            self.bandeau.titre = format!("Mindset est à jour (version {})", ctx.version);
            self.bandeau.texte = "La mise à jour s'est bien passée.".into();
        } else {
            self.bandeau.titre = "La mise à jour de Mindset n'a pas pu se faire".into();
            self.bandeau.texte = format!("{message} Mindset garde sa version actuelle et réessaiera plus tard.");
        }
        ctx.journal(&format!(
            "Résultat de la mise à jour de Mindset : {}",
            if ok { "réussie".to_string() } else { message }
        ));
        self.bandeau.visible = true;
    }

    /// `Show-RestesDesinstallation` : une désinstallation faite par le mini-installateur et pas allée au bout.
    pub(crate) fn restes_desinstallation(&mut self, ctx: &Contexte) {
        let t = ctx.installateur().valeur("Restes");
        if t.is_empty() {
            return;
        }
        ctx.journal(&format!("Désinstallation de Mindset pas finie : {t}"));
        self.bandeau.titre = "Mindset n'a pas pu être désinstallé entièrement".into();
        self.bandeau.texte = t;
        self.bandeau.bouton_maj = false;
        self.bandeau.bouton_fermer = "OK";
        self.bandeau.visible = true;
    }
}
