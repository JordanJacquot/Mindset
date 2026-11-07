// Mindset : la page des Paramètres (bloc « paramètres »), à l'identique de PageParametres d'interface.xaml et de ce
// que parametres.ps1 y ajoutait (onglets, interrupteurs, cartes des thèmes, appareils, versions, consommation).
// Elle dessine le panneau de l'onglet actif dans #parametres-panneaux (le titre, les onglets et le bouton Menu
// sont au bloc « écrans ») à partir de l'état « parametres » (Get-EtatParametres, plus « onglet » et « couleurs »)
// et envoie les gestes « parametres:reglage » { quoi, valeur, id } (les mêmes « quoi » que ReglageConsole de
// parametres.ps1).
// Elle ne parle à Rust que par window.coquille (règle 1 de regles-tauri.md).
(() => {
  'use strict';
  const co = window.coquille;
  const page = document.getElementById('page-parametres');
  const panneaux = document.getElementById('parametres-panneaux');
  if (!co || !page || !panneaux) return;
  page.classList.add('pm-page');

  // ---------------------------------------------------------------------------------------------------------------
  // Les couleurs : la palette Néon traduite dans le thème de la suite (Convert-ThemeXaml)
  // ---------------------------------------------------------------------------------------------------------------
  let table = {};
  const rgba = (h, a) => {
    if (!/^#([0-9a-f]{6}|[0-9a-f]{8})$/i.test(h)) return h;
    let al = 1;
    if (h.length === 9) { al = parseInt(h.slice(1, 3), 16) / 255; h = '#' + h.slice(3); }
    if (a !== undefined) al = a;
    const r = parseInt(h.slice(1, 3), 16), g = parseInt(h.slice(3, 5), 16), b = parseInt(h.slice(5, 7), 16);
    return al >= 1 ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${Math.round(al * 10000) / 10000})`;
  };
  const brut = (hex) => (typeof hex === 'string' && table[hex.toUpperCase()]) || hex;
  const c = (hex) => rgba(brut(hex));
  const VARIABLES = {
    texte: '#ECEAF7', texte2: '#A9A3C9', texte3: '#6F6894', gris: '#A6A1BC', cyan: '#00E5FF', violet: '#B04BFF',
    clair: '#7FF4FF', noir: '#08060F', 'b-fond': '#16FFFFFF', 'b-texte': '#F2EFFA', 'b-bord': '#26FFFFFF',
    survol: '#8000E5FF', carte1: '#17FFFFFF', carte2: '#08FFFFFF', cbord1: '#40FFFFFF', cbord2: '#0AFFFFFF',
    choisi: '#2600E5FF', ligne: '#0FFFFFFF', 'l-bord': '#1CFFFFFF', piste: '#2EFFFFFF', 'p-bord': '#3A4355',
    'p-on': '#00D9F5', bouton: '#EEEBF7', reflet: '#38FFFFFF', ombre: '#40000000',
  };
  const TONS = { attention: '#FFB020', urgent: '#FF7A9C', ok: '#3DDC84', '': '#A6A1BC' };
  function poserCouleurs() {
    for (const [k, v] of Object.entries(VARIABLES)) page.style.setProperty('--pm-' + k, c(v));
    page.style.setProperty('--pm-halo6', rgba(brut('#00E5FF'), 0.6));
    page.style.setProperty('--pm-halo3', rgba(brut('#00E5FF'), 0.3));
  }

  // (un texte vide garde la hauteur d'une ligne, comme un TextBlock vide de WPF)
  const info = (t) => (t ? e(t) : '&#8203;');
  const e = (t) => String(t ?? '').replace(/[&<>"']/g, (x) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[x]));
  const att = (o) => Object.entries(o).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => ` data-${k}="${e(v)}"`).join('');

  // ---------------------------------------------------------------------------------------------------------------
  // Les petits morceaux (New-Button, New-Text, CheckBox, RadioButton, Switch...)
  // ---------------------------------------------------------------------------------------------------------------
  const bouton = (texte, primaire, d, classe = '') =>
    `<button class="pm-bouton ${primaire ? 'pm-primaire' : 'pm-secondaire'} ${classe}"${att(d)}>${e(texte)}</button>`;
  const caseACocher = (texte, oui, d, actif = true, style = '') =>
    `<div class="pm-case${oui ? ' pm-oui' : ''}${actif ? '' : ' pm-gris-case'}"${actif ? att(d) : ''} style="${style}"><span class="pm-boite"></span><span>${e(texte)}</span></div>`;
  const rond = (texte, oui, d) =>
    `<div class="pm-rond pm-choix${oui ? ' pm-oui' : ''}"${att(d)}><span class="pm-boite"></span><span>${e(texte)}</span></div>`;
  const inter = (oui, d) => `<span class="pm-inter${oui ? ' pm-oui' : ''}"${att(d)}></span>`;

  // ---------------------------------------------------------------------------------------------------------------
  // Les panneaux
  // ---------------------------------------------------------------------------------------------------------------
  function general(p) {
    const g = p.general || {};
    const fermeture = [['demander', 'Me demander à chaque fois'], ['reduire', "Réduire près de l'horloge"], ['quitter', 'Tout quitter (Mindset et ses applis)']];
    let h = `<div class="pm-h">Réduire et fermer</div>
      <div class="pm-t2 pm-mb10">Caché près de l'horloge, Mindset continue de veiller sur tes applis : un clic sur son icône le rouvre.</div>
      ${caseACocher("Réduire Mindset près de l'horloge (au lieu de la barre des tâches)", !!g.reduire, { quoi: 'reduire', type: 'case' }, true, 'margin-bottom:10px')}
      <div class="pm-sb">Quand je clique sur la croix :</div>
      <div>${fermeture.map(([k, t]) => rond(t, String(g.fermeture || '').toLowerCase() === k, { quoi: 'fermeture', valeur: k, type: 'rond' })).join('')}</div>
      <div class="pm-h pm-loin">Démarrage avec Windows</div>
      <div class="pm-t2 pm-mb10">Choisis si Mindset se lance avec Windows (caché près de l'horloge), et quelles applis s'ouvrent avec lui : elles démarrent en arrière-plan à chaque ouverture de Mindset (le même réglage que sur leur carte de l'accueil).</div>
      <div class="pm-demarrage pm-mindset"><div class="pm-txt"><div>Mindset se lance avec Windows</div><div class="pm-aide">Caché près de l'horloge, il ouvre en même temps les applis cochées ci-dessous.</div></div>${inter(!!g.windows, { quoi: 'windows', type: 'inter' })}</div>`;
    for (const a of g.applis || []) {
      h += `<div class="pm-demarrage"><div class="pm-txt">${e(a.nom)} s'ouvre avec Mindset${a.note ? ' (sinon ses rappels ne sonnent pas)' : ''}</div>${inter(!!a.oui, { quoi: 'demarrage', id: a.id, type: 'inter' })}</div>`;
    }
    return h;
  }

  function vignette(v) {
    if (!v || !v.adresse) return '';
    // La première image de la planche, dans un cadre de 48 x 34 (Stretch Uniform)
    const n = Math.max(1, v.images || 1);
    const lf = Math.floor((v.largeur || 1) / n), hf = v.hauteur || 1;
    const k = Math.min(48 / lf, 34 / hf);
    const l = Math.round(lf * k), ht = Math.round(hf * k);
    return `<span style="width:${l}px;height:${ht}px;background-image:url('${e(v.adresse)}');background-size:${Math.round(v.largeur * k)}px ${ht}px;background-position:0 0;image-rendering:auto"></span>`;
  }

  function apparence(p) {
    const a = p.apparence || {};
    const actuel = a.actuel || 'neon';
    let cartes = '';
    for (const t of a.themes || []) {
      const est = t.cle === actuel;
      const cs = t.couleurs || [];
      // (aperçu dans ses propres couleurs : pas traduites par le thème actuel)
      cartes += `<div class="pm-carte" title="${e(t.nom)}" style="background:${rgba(t.fond)} padding-box;border-color:${rgba(est ? cs[0] : t.bord || '#2A2450')}"${att({ quoi: 'theme', valeur: t.cle, type: 'bouton' })}>
        <div class="pm-carte-corps"><div class="pm-carte-haut"><div class="pm-pastilles">${cs.map((x) => `<i style="background:${rgba(x)}"></i>`).join('')}</div>
        ${t.image ? `<div class="pm-vignette">${vignette(t.vignette)}</div>` : ''}</div>
        <div class="pm-carte-nom"${t.police ? ` style="font-family:${e(t.police)}"` : ''}>${e(t.nom)}${est ? '  (actuel)' : ''}</div></div></div>`;
    }
    const anims = [['completes', 'Complètes : la console et toutes ses animations'], ['express', 'Express : la console, avec des animations plus rapides'], ['aucune', "Aucune : l'accueil classique, sans 3D"]];
    return `<div class="pm-h">Thème de la suite</div>
      <div class="pm-t2 pm-mb14">Le même pour Mindset et toutes ses applis : le changer ici relance chaque appli ouverte avec ce thème.</div>
      <div class="pm-themes">${cartes}</div>
      <div class="pm-t3" style="margin-top:6px">${info(a.info)}</div>
      <div>${bouton('Importer un thème (.zip)', false, { quoi: 'importer', type: 'bouton' }, 'pm-gauche')}</div>
      <div class="pm-t3" style="margin-top:8px">Un thème personnalisé de la suite (images, police, personnage) s'installe pour Mindset et toutes ses applis. Il reste sur ce PC.</div>
      <div class="pm-h pm-loin">Animations</div>
      <div class="pm-t2 pm-mb10">L'accueil de Mindset est une console en 3D : chaque appli est une cartouche qu'on y insère.</div>
      <div>${anims.map(([k, t]) => rond(t, String(a.animations || 'completes').toLowerCase() === k, { quoi: 'animations', valeur: k, type: 'rond' })).join('')}</div>
      <div class="pm-t3" style="margin-top:6px">${info(a.animInfo)}</div>`;
  }

  function appareils(quoi, liste) {
    return (liste || []).map((x) => `<div class="pm-appareil${x.oui ? ' pm-oui' : ''}"${att({ quoi, valeur: x.cle, type: 'bouton' })}><span class="pm-nom">${e(x.nom)}</span><span class="pm-etat">${x.oui ? '✓ choisi' : 'choisir'}</span></div>`).join('');
  }

  function son(p) {
    const s = p.son || {};
    return `<div class="pm-h">Micro</div>
      <div class="pm-t2 pm-mb10">Celui qu'Evermind écoute (dictée, « OK Evermind »). Débranché, c'est celui de Windows qui sert en attendant.</div>
      <div>${appareils('micro', s.micros)}</div>
      <div class="pm-h pm-loin24">Casque ou haut-parleurs</div>
      <div class="pm-t2 pm-mb10">Là où Evermind te parle et sonne tes rappels.</div>
      <div>${appareils('casque', s.casques)}</div>
      <div style="margin-top:14px">${bouton('Actualiser la liste', false, { quoi: 'sonActualiser', type: 'bouton' })}</div>`;
  }

  const version = (nom, couleur, installee, etat, couleurEtat) =>
    `<div class="pm-version"><div class="pm-gauche-v"><span class="pm-nom-v" style="color:${c(couleur)}">${e(nom)}</span><span class="pm-num">   ${e(installee)}</span></div><span class="pm-etat" style="color:${c(couleurEtat)}">${e(etat)}</span></div>`;

  function maj(p) {
    const m = p.maj || {};
    const verif = !!m.verif;
    let liste = version('Mindset', '#ECEAF7', `version ${p.version || ''}`, (m.mindset || {}).texte_page || (m.mindset || {}).texte || '', TONS[(m.mindset || {}).ton || ''] || TONS['']);
    for (const a of m.applis || []) liste += `<div class="pm-version"><div class="pm-gauche-v"><span class="pm-nom-v" style="color:${rgba(a.couleur)}">${e(a.nom)}</span><span class="pm-num">   ${e(a.version)}</span></div><span class="pm-etat" style="color:${c(TONS[a.ton] || TONS[''])}">${e(a.texte)}</span></div>`;
    liste += '<div class="pm-h pm-histo">Dernières mises à jour</div>';
    const h = m.historique || [];
    if (!h.length) liste += `<div class="pm-gris">Aucune mise à jour pour l'instant.</div>`;
    for (const x of h) liste += `<div class="pm-version"><div class="pm-gauche-v"><span class="pm-nom-v" style="color:${rgba(x.couleur)}">${e(x.nom)}</span><span class="pm-num">   version ${e(x.version)}</span></div><span class="pm-etat" style="color:${c(x.auto ? '#7FF4FF' : '#A6A1BC')}">${e(x.quand)} · ${x.auto ? 'automatique' : 'faite par toi'}</span></div>`;
    let essais = '';
    if (!(m.essai || []).length) essais = `<div class="pm-gris">Aucune appli installée pour l'instant.</div>`;
    for (const a of m.essai || []) essais += caseACocher(`Recevoir les versions d'essai de ${a.nom}`, !!a.oui, { quoi: 'essai', id: a.id, type: 'case' }) + `<div class="pm-essai">${e(m.essaiNote)}</div>`;
    return `<div class="pm-h">Versions</div>
      <div class="pm-t2 pm-mb12">${verif ? "Mindset cherche les nouvelles versions au démarrage puis toutes les heures. Elles sont signées : une version qui ne l'est pas n'est jamais installée." : "Mindset ne cherche plus les nouvelles versions tout seul : clique sur « Vérifier maintenant » quand tu veux. Elles sont signées : une version qui ne l'est pas n'est jamais installée."}</div>
      ${caseACocher('Chercher les nouvelles versions (sur GitHub, au démarrage puis toutes les heures)', verif, { quoi: 'verif', type: 'case' }, true, 'margin-bottom:8px')}
      ${caseACocher("Mises à jour automatiques (les nouvelles versions s'installent toutes seules, jamais pendant un jeu)", verif && !!m.auto, { quoi: 'majauto', type: 'case' }, verif, 'margin-bottom:4px')}
      <div class="pm-t3 pm-mb12">${info(verif ? '' : 'Les mises à jour automatiques ne peuvent pas tourner tant que la recherche des nouvelles versions est coupée.')}</div>
      <div>${liste}</div>
      <div class="pm-ligne-boutons" style="margin-top:14px">${bouton('Vérifier maintenant', true, { quoi: 'verifier', type: 'bouton' })}<span class="pm-t3" style="margin-left:14px">${info(m.info)}</span></div>
      <div class="pm-h pm-loin24">Versions d'essai</div>
      <div class="pm-t2 pm-mb10">Une version d'essai arrive avant les autres, pour la tester. Elle peut avoir des petits défauts. Elle est signée et vérifiée comme les autres.</div>
      <div>${essais}</div>`;
  }

  function conso(p) {
    const x = p.conso;
    let h = `<div class="pm-h">Ce que consomme la suite</div>
      <div class="pm-t2 pm-mb12">Mindset et ses applis, comme dans le Gestionnaire des tâches de Windows. Mis à jour toutes les 2 secondes.</div>`;
    if (!x) return h + '<div class="pm-total"></div><div class="pm-t2" style="margin-bottom:16px"></div>';
    h += `<div class="pm-total">Mémoire utilisée par la suite : ${e(x.memoire)}</div>
      <div class="pm-t2" style="margin-bottom:16px">Processeur : ${e(x.processeur)} de l'ordinateur</div>`;
    for (const l of x.lignes || []) h += `<div class="pm-conso"><div class="pm-txt"><div class="pm-nom-c">${e(l.nom)}</div><div class="pm-aide" style="margin-top:0">${e(l.detail)}</div></div><span class="pm-chiffres">${e(l.memoire)}   ·   ${e(l.processeur)}</span></div>`;
    return h;
  }

  function dossiers(p) {
    return `<div class="pm-h">Dossiers</div>
      <div class="pm-t2 pm-mb10">${e((p.dossiers || {}).texte)}</div>
      <div class="pm-ligne-boutons">${bouton('Ouvrir le dossier des programmes', false, { quoi: 'dossierProgrammes', type: 'bouton' })}${bouton('Ouvrir le dossier des données', false, { quoi: 'dossierDonnees', type: 'bouton' })}</div>
      <div class="pm-h pm-loin">Désinstaller Mindset</div>
      <div class="pm-t2 pm-mb10">Retire Mindset et les applis qu'il a installées. Tu pourras choisir de garder tes données.</div>
      <div>${bouton('Désinstaller Mindset', false, { quoi: 'desinstaller', type: 'bouton' })}</div>`;
  }

  const PANNEAUX = { general, apparence, son, maj, conso, dossiers };

  // ---------------------------------------------------------------------------------------------------------------
  // Le dessin (refait seulement si l'état a changé ; le défilement est gardé)
  // ---------------------------------------------------------------------------------------------------------------
  let dernier = '';
  function dessiner(etat) {
    const p = etat && etat.parametres;
    if (!p) return;
    const cle = JSON.stringify(p);
    if (cle === dernier) return;
    dernier = cle;
    table = p.couleurs || {};
    poserCouleurs();
    const onglet = PANNEAUX[p.onglet] ? p.onglet : 'general';
    // (le titre, la phrase, les onglets et le bouton Menu sont dessinés par le bloc « écrans » ; ici, le panneau seul,
    // dans la zone qui défile, qui garde sa position tant que l'onglet ne change pas)
    const defile = panneaux.closest('.parametres-defile') || panneaux;
    const haut = page.dataset.onglet === onglet ? defile.scrollTop : 0;
    page.dataset.onglet = onglet;
    panneaux.innerHTML = `<div class="pm-panneau">${PANNEAUX[onglet](p)}</div>`;
    defile.scrollTop = haut;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Les gestes
  // ---------------------------------------------------------------------------------------------------------------
  page.addEventListener('click', (ev) => {
    const x = ev.target.closest('[data-type]');
    if (!x || !page.contains(x)) return;
    const d = x.dataset;
    const m = { quoi: d.quoi };
    if (d.type === 'case' || d.type === 'inter') {
      const oui = !x.classList.contains('pm-oui');
      x.classList.toggle('pm-oui', oui);   // (tout de suite à l'écran, l'état confirme ensuite)
      m.valeur = oui;
    } else if (d.type === 'rond') {
      m.valeur = d.valeur;
    } else if (d.valeur !== undefined) {
      m.valeur = d.valeur;
    }
    if (d.id !== undefined) m.id = d.id;
    co.action('parametres:reglage', m);
  });

  co.surEtat(dessiner);
})();
