// La console 3D dans la page (bloc « console », mindset-console ; console.ps1 de la version PowerShell) :
//   - le cadre de console/scene.html dans #page-console, créé et retiré selon l'état console.cadre (New-VueConsole,
//     Remove-VueConsole) : un cadre retiré libère toute la 3D ;
//   - « Allumage de la console... » tant que la scène n'est pas prête (ConsoleAttente) ;
//   - l'accueil classique caché quand la console est à sa place (Update-PageConsole) ;
//   - l'état des applis, des mises à jour et des Paramètres donné à la scène quand il change (Send-EtatConsole,
//     Send-MajConsole, Send-ParametresConsole), et les ordres { kit: 'console', appel, args } (Invoke-ScriptConsole) ;
//   - les messages de la scène rendus en actions « console:<type> » (Receive-MessageConsole vérifie tout côté Rust) ;
//   - Échap hors de l'accueil : retour au menu en grand (action « menu »).
// Rien ici ne parle à Rust directement : tout passe par la coquille.
(() => {
  'use strict';
  const coq = window.coquille;
  const zone = document.getElementById('page-console');
  if (!coq || !zone) return;

  // Les ordres permis (les fonctions de window.mindset de scene.html que Mindset appelle)
  const ORDRES = ['pause', 'reprendre', 'message', 'jouerOuverture', 'jouerRetour', 'jouerMenu', 'jouerEjection',
    'appliPrete', 'avancee', 'vitesse'];
  const ONGLETS = ['general', 'apparence', 'son', 'maj', 'conso', 'dossiers'];

  let cadre = null;       // l'<iframe> de la scène
  let adresse = null;     // son adresse (console.cadre)
  let numero = null;      // son numéro (console.numero)
  let pret = false;       // la scène a dit « pret »
  let c = null;           // le dernier état « console »
  let envoi = null;       // console.envoi au dernier envoi (il change : tout est renvoyé)
  const envoyes = { etat: '', maj: '', reglages: '', images: '' };

  // « Allumage de la console... » (ConsoleAttente : Texte3, 14, au centre)
  const attente = document.createElement('div');
  attente.setAttribute('role', 'status');
  Object.assign(attente.style, { position: 'absolute', inset: '0', display: 'flex', alignItems: 'center',
    justifyContent: 'center', color: 'var(--texte3, #6F6894)', fontSize: '14px', pointerEvents: 'none', zIndex: '1' });   // (au-dessus du cadre qui se charge)
  zone.appendChild(attente);

  // Une fonction de la scène, seulement quand elle est prête (Invoke-ScriptConsole)
  function appeler(nom, args) {
    if (!pret || !cadre) return;
    let m = null;
    try { m = cadre.contentWindow && cadre.contentWindow.mindset; } catch (e) { m = null; }
    if (!m || typeof m[nom] !== 'function') return;
    try { m[nom](...(Array.isArray(args) ? args : [])); } catch (e) { /* (la scène note elle-même ses erreurs) */ }
  }

  function retirer() {
    if (cadre) { try { cadre.src = 'about:blank'; } catch (e) { /* rien */ } cadre.remove(); }
    cadre = null; adresse = null; numero = null; pret = false;
    envoyes.etat = envoyes.maj = envoyes.reglages = envoyes.images = '';
  }
  function creer(url, n) {
    const f = document.createElement('iframe');
    f.title = 'Console de Mindset';
    f.setAttribute('allow', 'autoplay');
    Object.assign(f.style, { position: 'absolute', inset: '0', width: '100%', height: '100%', border: '0',
      display: 'block', background: (c && c.fond) || '#07060D' });   // (pas d'éclair blanc à l'allumage)
    f.src = url;
    zone.appendChild(f);
    cadre = f; adresse = url; numero = n; pret = false;
  }

  // Les Paramètres dans l'écran de la console : l'état du bloc « paramètres » (Get-EtatParametres), et les images
  // des thèmes perso (Get-ImagesThemesConsole, champ images_themes)
  function etatParametres() {
    const p = coq.etat && coq.etat.parametres;
    if (!p || typeof p !== 'object') return null;
    const e = Object.assign({}, p);
    delete e.onglet; delete e.images_themes;
    return e;
  }
  function imagesThemes() {
    const p = coq.etat && coq.etat.parametres;
    return p && p.images_themes && typeof p.images_themes === 'object' ? p.images_themes : {};
  }

  // Ce que la scène doit savoir, seulement ce qui a changé (tout, si « force »)
  function envoyer(force) {
    if (!pret || !c) return;
    if (c.etat) { const j = JSON.stringify(c.etat); if (force || j !== envoyes.etat) { envoyes.etat = j; appeler('etat', [c.etat]); } }
    if (c.maj) { const j = JSON.stringify(c.maj); if (force || j !== envoyes.maj) { envoyes.maj = j; appeler('majAuto', [c.maj]); } }
    if (c.parametres) {
      const e = etatParametres();
      if (e) { const j = JSON.stringify(e); if (force || j !== envoyes.reglages) { envoyes.reglages = j; appeler('reglages', [e]); } }
      const im = imagesThemes(), ji = JSON.stringify(im);
      if (ji !== envoyes.images) { const avant = envoyes.images; envoyes.images = ji; if (avant) appeler('reglages', [null, null, false, im]); }
    }
  }

  coq.surEtat((etat) => {
    c = etat && etat.console && typeof etat.console === 'object' ? etat.console : null;
    const montrer = !!(c && c.visible);
    zone.hidden = !montrer;
    if (montrer) { const a = document.getElementById('page-accueil'); if (a) a.hidden = true; }
    const voulue = c && typeof c.cadre === 'string' && /^console\/scene\.html\?/.test(c.cadre) ? c.cadre : null;
    if (voulue !== adresse) { retirer(); if (voulue) creer(voulue, c.numero); }
    attente.textContent = (c && c.texte_attente) || '';
    attente.style.display = c && c.attente ? 'flex' : 'none';   // (style en ligne : l'attribut hidden ne suffirait pas)
    if (cadre) {
      cadre.style.visibility = c.masquee ? 'hidden' : 'visible';   // (une question de Mindset par-dessus : Update-ConsoleMasquee)
      cadre.style.background = c.fond || '#07060D';
      if (montrer && pret && !c.masquee && document.activeElement !== cadre) { try { cadre.focus(); } catch (e) { /* rien */ } }
    }
    const force = !!c && c.envoi !== envoi;
    if (c) envoi = c.envoi;
    envoyer(force);
  });

  coq.surOrdre('console', (o) => {
    if (o.appel === 'reglagesOuvrir') {
      // Les Paramètres s'ouvrent dans l'écran, sur leur onglet (tout de suite si la scène vient de s'allumer)
      const e = etatParametres(), im = imagesThemes();
      if (e) envoyes.reglages = JSON.stringify(e);
      envoyes.images = JSON.stringify(im);
      appeler('reglages', [e, ONGLETS.includes(o.onglet) ? o.onglet : 'general', !!o.instant, im]);
      return;
    }
    if (ORDRES.includes(o.appel)) appeler(o.appel, o.args);
  });

  // Les messages de la scène : seulement de son cadre, de cette page ; rendus tels quels au bloc (qui vérifie tout)
  window.addEventListener('message', (ev) => {
    if (!cadre || ev.source !== cadre.contentWindow || ev.origin !== location.origin) return;
    const m = ev.data;
    if (!m || typeof m !== 'object' || Array.isArray(m) || typeof m.type !== 'string' || !/^[a-zA-Z]{1,20}$/.test(m.type)) return;
    const valeur = {};
    for (const k of Object.keys(m)) if (k !== 'type') valeur[k] = m[k];
    if (m.type === 'pret') {
      pret = true;
      valeur.cadre = numero;
      attente.style.display = 'none';
      envoyer(true);   // (Send-EtatConsole -Force ; le bloc joue ensuite ce qui attendait)
      if (c && c.visible) { try { cadre.focus(); } catch (e) { /* rien */ } }
    }
    coq.action('console:' + m.type, valeur);
  });

  // Échap hors de l'accueil (une appli, son écran d'attente) : retour au menu en grand, sauf sous une question
  document.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Escape' || !c || !c.possible || c.masquee) return;
    const page = coq.etat && coq.etat._vue && coq.etat._vue.page;
    if (!page || page === 'accueil') return;
    ev.preventDefault();
    coq.action('menu', null);
  }, true);
})();
