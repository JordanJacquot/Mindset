//! Mindset en Rust, bloc « liste des applis » (modules\liste.ps1 en entier, et `Get-Applis`, `Update-ListeEnLigne`,
//! `Receive-ListeEnLigne`, `Get-ProcessusDonneesAppli` de modules\applis.ps1).
//!
//! - Au démarrage ([`Bloc::demarrer`]) : la liste des applis (`$Applis = @(Get-Applis)`) donnée au contexte, une fois
//!   (une nouvelle liste en ligne sert au prochain démarrage de Mindset : les cartes, les onglets et tout ce qui tient
//!   une appli ouverte sont faits au démarrage), et d'où elle vient dans le tableau commun (`liste`).
//! - Toutes les 1,5 s (30 s quand Mindset est caché ou réduit) : quelles applis sont ouvertes (`ouvertes`,
//!   `Test-AppliOuverte` de chacune).
//! - Sur le signal `verifier-liste` (envoyé par le bloc « publications » avec la recherche des nouvelles versions,
//!   donc jamais si elle est coupée) : la liste en ligne, au plus toutes les 6 heures, téléchargée en fond sans l'API
//!   de GitHub (256 Ko et 15 s au plus pour la liste, 64 Ko pour sa signature), puis vérifiée et gardée
//!   ([`liste::ajouter_en_ligne`]). Pas téléchargée : réessai dans une heure.
//!
//! La version PowerShell est la référence ; chaque règle est rejouée sur ses réponses (`tests/juges`, exportés par
//! `outils\exporter-juges-liste.ps1`). Les différences voulues sont dans `DIVERGENCES.md`.

use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Map, Value, json};

use mindset_noyau::appli::{Appli, appli_ouverte};
use mindset_noyau::contexte::Contexte;
use mindset_noyau::reseau::{DemandeHttp, Reseau};
use mindset_noyau::systeme::{Processus, dans_dossier};
use mindset_noyau::{Bloc, Effets, partage, signaux};

pub mod liste;
mod ps;

pub use liste::{Applis, Entrees, ListeLue, Source};

/// La liste en ligne : la version « liste-applis » du dépôt de Mindset (une préversion : `/releases/latest` ne la voit
/// jamais), téléchargée sans l'API de GitHub.
pub const URL_LISTE_EN_LIGNE: &str =
    "https://github.com/JordanJacquot/Mindset/releases/download/liste-applis/apps-en-ligne.json";
/// Au plus 256 Ko pour la liste, 64 Ko pour sa signature, 15 s pour chacune.
const MAX_LISTE: u64 = 256 * 1024;
const MAX_SIGNATURE: u64 = 64 * 1024;
const DELAI: Duration = Duration::from_secs(15);
/// Au plus une recherche toutes les 6 heures ; pas téléchargée : réessai dans une heure.
const ENTRE_DEUX: Duration = Duration::from_secs(6 * 3600);
const REESSAI: Duration = Duration::from_secs(3600);
/// Le relevé des applis ouvertes : 1,5 s, 30 s quand personne ne regarde Mindset.
const RELEVE: Duration = Duration::from_millis(1500);
const RELEVE_CACHE: Duration = Duration::from_secs(30);
/// L'id du travail de fond du téléchargement.
pub const TACHE: &str = "liste-en-ligne";

/// Le bloc « liste des applis ».
#[derive(Debug, Default)]
pub struct BlocListe {
    /// Le temps écoulé (depuis le lancement) à partir duquel une nouvelle recherche est permise
    /// (`$script:DerniereListe` + 6 h)
    prochaine_recherche: Duration,
}

/// La liste en ligne gardée : `<données de Mindset>\apps-en-ligne.json` (`$ListeGardee`).
pub fn chemin_liste_gardee(ctx: &Contexte) -> PathBuf {
    ctx.dossiers.donnees.join(liste::NOM_LISTE_EN_LIGNE)
}

/// Les variables d'environnement pour le dossier de données d'une appli (`%LOCALAPPDATA%\Evermind`) : celles du PC ;
/// en essai, `%LOCALAPPDATA%` est le dossier d'essai et les autres sont inconnues (jamais les vraies données).
fn variables(ctx: &Contexte) -> impl Fn(&str) -> Option<String> + '_ {
    move |nom: &str| {
        if ctx.essai {
            let local = ctx.dossiers.local_mindset.parent().map(|p| p.to_string_lossy().into_owned());
            return local.filter(|_| nom.eq_ignore_ascii_case("LOCALAPPDATA"));
        }
        ps::variable_du_pc(nom)
    }
}

/// `Get-Applis` avec les dossiers et la version de ce Mindset (et son journal).
pub fn applis_de(ctx: &Contexte) -> Applis {
    let gardee = chemin_liste_gardee(ctx);
    let mut journal = |t: &str| ctx.journal(t);
    liste::applis(&ctx.dossiers.fichiers, Some(&gardee), &ctx.version, &mut journal, &variables(ctx))
}

/// `Get-ProcessusDonneesAppli` (applis.ps1:86-92) : les programmes d'aide qu'une appli lance depuis son dossier de
/// DONNÉES (Evermind : voix\Mindset.exe, Mindcare : ia\...), trouvés par leur chemin ; jamais Mindset lui-même (ni ce
/// processus, ni un programme du dossier de Mindset), jamais toutes les données de la suite.
pub fn processus_donnees_appli(ctx: &Contexte, appli: &Appli) -> Vec<Processus> {
    // Get-DossierDonnees (installations.ps1:24-28) : <données de la suite>\<Nom> quand Mindset l'a installée et que ce
    // dossier existe, sinon son ancien dossier de données
    let suite = ctx.dossiers.donnees_suite.join(&appli.nom);
    let gere = partage::installation(ctx, &appli.id).is_some_and(|i| i.gere);
    let principal = if gere && suite.exists() { suite.to_string_lossy().into_owned() } else { appli.donnees.clone() };
    let mut dossiers: Vec<String> = Vec::new();
    for d in [principal, appli.donnees.clone()] {
        // (Select-Object -Unique : comparé exactement)
        if !d.is_empty() && !dossiers.contains(&d) {
            dossiers.push(d);
        }
    }
    let suite_dir = ctx.dossiers.donnees_suite.to_string_lossy().trim_end_matches('\\').to_string();
    let mien = ctx.dossiers.mindset.to_string_lossy();
    let tous = ctx.systeme().processus();
    let mut pids: Vec<u32> = Vec::new();
    for d in &dossiers {
        if !suite_dir.is_empty() && suite_commun::chemins::egal(d.trim_end_matches('\\'), &suite_dir) {
            continue;
        }
        pids.extend(dans_dossier(&tous, d, None, ctx.pid(), &mien));
    }
    // (un programme trouvé dans les deux dossiers compte deux fois, comme la version PowerShell)
    pids.iter().filter_map(|pid| tous.iter().find(|p| p.pid == *pid).cloned()).collect()
}

/// Un téléchargement de la liste ou de sa signature (`Get-Octets -MaxOctets .. -DelaiSecondes 15`).
fn telecharger(reseau: &dyn Reseau, adresse: &str, max: u64) -> Result<Vec<u8>, String> {
    let mut d = DemandeHttp::get(adresse);
    d.max_octets = max;
    d.delai = DELAI;
    let r = reseau.demander(&d, None)?;
    if !(200..300).contains(&r.statut) {
        return Err(format!("le serveur a répondu {} pour {adresse}", r.statut));
    }
    if r.corps.len() as u64 > max {
        return Err(format!("le fichier téléchargé est trop gros (plus de {} Ko)", max / 1024));
    }
    Ok(r.corps)
}

fn en_hexa(o: &[u8]) -> String {
    o.iter().map(|b| format!("{b:02x}")).collect()
}

fn depuis_hexa(t: &str) -> Option<Vec<u8>> {
    if !t.len().is_multiple_of(2) {
        return None;
    }
    (0..t.len()).step_by(2).map(|i| u8::from_str_radix(t.get(i..i + 2)?, 16).ok()).collect()
}

/// Le résultat d'un téléchargement de la liste en ligne, tel que le rend le travail de fond (les octets en
/// hexadécimal) : pour les tests qui jouent la fin d'un téléchargement.
pub fn resultat_telechargement(json: &[u8], signature: &[u8]) -> Value {
    json!({ "json": en_hexa(json), "sig": en_hexa(signature) })
}

impl BlocListe {
    /// Le relevé des applis ouvertes (`ouvertes`).
    fn relever(&self, ctx: &Contexte) {
        let mut ouvertes = Map::new();
        for a in ctx.applis().iter() {
            ouvertes.insert(a.id.clone(), Value::Bool(appli_ouverte(ctx, a)));
        }
        ctx.publier(partage::OUVERTES, Value::Object(ouvertes));
    }

    /// `Update-ListeEnLigne` : au plus toutes les 6 heures, le téléchargement en fond.
    fn chercher_liste(&mut self, ctx: &Contexte, effets: &mut Effets) {
        let maintenant = ctx.ecoule();
        if maintenant < self.prochaine_recherche {
            return;
        }
        self.prochaine_recherche = maintenant + ENTRE_DEUX;
        let reseau = ctx.reseau();
        effets.tache(TACHE, move || {
            let json = telecharger(reseau.as_ref(), URL_LISTE_EN_LIGNE, MAX_LISTE)?;
            let sig = telecharger(reseau.as_ref(), &format!("{URL_LISTE_EN_LIGNE}.sig"), MAX_SIGNATURE)?;
            Ok(resultat_telechargement(&json, &sig))
        });
    }

    /// `Receive-ListeEnLigne` : la liste téléchargée vérifiée puis gardée (elle sera prise au prochain démarrage).
    fn recevoir(&mut self, ctx: &Contexte, resultat: Result<Value, String>) {
        let erreur = match &resultat {
            Err(e) => Some(e.clone()),
            Ok(Value::Null) => Some(String::new()),
            Ok(_) => None,
        };
        if let Some(e) = erreur {
            // (réessai dans une heure)
            self.prochaine_recherche = ctx.ecoule() + REESSAI;
            ctx.journal(&format!("Liste des applis en ligne : pas téléchargée ({e})"));
            return;
        }
        let r = resultat.unwrap_or_default();
        let octets = |n: &str| r.get(n).and_then(Value::as_str).and_then(depuis_hexa).unwrap_or_default();
        let gardee = chemin_liste_gardee(ctx);
        let mut journal = |t: &str| ctx.journal(t);
        let l = liste::ajouter_en_ligne(
            &octets("json"),
            &octets("sig"),
            &ctx.dossiers.fichiers,
            &gardee,
            &ctx.version,
            &mut journal,
        );
        match l {
            Ok(Some(l)) => ctx.journal(&format!(
                "Liste des applis en ligne n° {} gardée ({} applis) : elle sera prise au prochain démarrage de Mindset",
                l.numero,
                l.entrees.len()
            )),
            Ok(None) => {}
            Err(e) => ctx.journal(&format!("Liste des applis en ligne refusée : {e} (on garde celle qu'on avait)")),
        }
    }
}

impl Bloc for BlocListe {
    fn nom(&self) -> &'static str {
        "liste"
    }

    fn demarrer(&mut self, ctx: &Contexte, _effets: &mut Effets) {
        let l = applis_de(ctx);
        let source = match l.source {
            Some(Source::EnLigne) => "en-ligne",
            _ => "apps.json",
        };
        let numero = if l.source.is_some() && l.numero >= 0 { json!(l.numero) } else { Value::Null };
        ctx.definir_applis(l.applis);
        ctx.publier(partage::LISTE, json!({ "source": source, "numero": numero }));
        self.relever(ctx);
    }

    fn tic(&mut self, ctx: &Contexte, _effets: &mut Effets) -> Option<Duration> {
        self.relever(ctx);
        Some(if ctx.vue().cachee() { RELEVE_CACHE } else { RELEVE })
    }

    fn signal(&mut self, ctx: &Contexte, nom: &str, _donnees: &Value, effets: &mut Effets) {
        if nom == signaux::VERIFIER_LISTE {
            self.chercher_liste(ctx, effets);
        }
    }

    fn tache_finie(&mut self, ctx: &Contexte, id: &str, resultat: Result<Value, String>, _effets: &mut Effets) {
        if id == TACHE {
            self.recevoir(ctx, resultat);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nom_du_bloc() {
        // (le nom est celui du tableau commun : mindset_noyau::partage::PROPRIETAIRES)
        assert_eq!(BlocListe::default().nom(), "liste");
    }

    #[test]
    fn hexa_aller_retour() {
        let o: Vec<u8> = (0..=255).collect();
        assert_eq!(depuis_hexa(&en_hexa(&o)), Some(o));
        assert_eq!(depuis_hexa("abc"), None);
        assert_eq!(depuis_hexa("zz"), None);
    }
}
