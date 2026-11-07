// La coquille de la page de Mindset : elle reçoit l'état et les ordres de l'appli (par ipc.js), les donne aux scripts
// des blocs, et envoie leurs gestes. Rien ici ne parle à Rust directement (règle 1) : tout passe par window.mindsetPont.
//
// Pour les scripts des blocs (ecrans/ecrans.js, console/console.js) :
//   coquille.surEtat(f)            f(etat) à chaque nouvel état (l'objet complet : les clés de chaque bloc, plus _vue)
//   coquille.surOrdre(kit, f)      f(ordre) pour chaque ordre { kit: '<kit>', ... } de l'appli
//   coquille.action(id, valeur)    un geste vers les blocs (id « bloc:quoi », valeur JSON simple)
//   coquille.etat                  le dernier état reçu
//   coquille.montrerPage(id)       la section de la page centrale à montrer (par défaut : selon _vue.page)
//
// La coquille envoie elle-même, à chaque changement, la place de la zone où s'affiche une appli accrochée :
// l'action « accrochage:zone » { x, y, largeur, hauteur, visible } en pixels de l'écran (déjà multipliés par
// l'échelle de Windows), comptés depuis le coin haut gauche de l'intérieur de la fenêtre.
(() => {
  'use strict';
  const pont = window.mindsetPont;
  const surEtat = [];
  const surOrdre = new Map();
  let etat = null;

  function envoyer(m) { if (pont) pont.envoyer(m); }

  function action(id, valeur, ecran) {
    envoyer({ type: 'action', id: String(id), valeur: valeur === undefined ? null : valeur, ecran: ecran || pageMontree() });
  }

  function pageMontree() {
    const p = etat && etat._vue && typeof etat._vue.page === 'string' ? etat._vue.page : 'accueil';
    return /^[\w:.-]{1,60}$/.test(p) ? p : 'accueil';
  }

  // Par défaut, la section qui suit la page de Mindset ; le bloc « écrans » peut tout décider lui-même.
  function montrerPage(id) {
    const sections = { accueil: 'page-accueil', parametres: 'page-parametres' };
    const voulue = sections[id] || 'page-appli';
    for (const s of document.querySelectorAll('#page-centrale > .page')) {
      if (s.id === 'page-console') continue;   // (la console décide elle-même : console/console.js)
      s.hidden = s.id !== voulue;
    }
    zone();
  }

  // La zone de l'appli accrochée (integration.ps1 : le panneau Windows Forms de la page de l'appli)
  let derniereZone = '';
  function zone() {
    const z = document.getElementById('zone-appli');
    if (!z) return;
    const r = z.getBoundingClientRect();
    const e = window.devicePixelRatio || 1;
    const visible = !!(z.offsetParent && r.width > 0 && r.height > 0);
    const v = { x: Math.round(r.left * e), y: Math.round(r.top * e), largeur: Math.round(r.width * e), hauteur: Math.round(r.height * e), visible };
    const cle = JSON.stringify(v);
    if (cle === derniereZone) return;
    derniereZone = cle;
    action('accrochage:zone', v);
  }

  function recevoir(m) {
    if (m && typeof m.kit === 'string') {
      for (const f of surOrdre.get(m.kit) || []) f(m);
      return;
    }
    etat = m;
    if (!coquille.pageManuelle) montrerPage(pageMontree());
    for (const f of surEtat) f(m);
  }

  const coquille = {
    surEtat(f) { if (typeof f === 'function') { surEtat.push(f); if (etat) f(etat); } },
    surOrdre(kit, f) {
      if (typeof kit !== 'string' || typeof f !== 'function') return;
      if (!surOrdre.has(kit)) surOrdre.set(kit, []);
      surOrdre.get(kit).push(f);
    },
    action,
    montrerPage,
    zone,
    // (vrai : le bloc « écrans » montre lui-même les sections de la page centrale)
    pageManuelle: false,
    get etat() { return etat; },
  };
  window.coquille = coquille;

  window.addEventListener('error', (e) => envoyer({ type: 'erreur', texte: String(e.message || e).slice(0, 300) }));
  window.addEventListener('unhandledrejection', (e) => envoyer({ type: 'erreur', texte: String(e.reason || e).slice(0, 300) }));
  window.addEventListener('resize', zone);
  if (window.ResizeObserver) {
    const z = document.getElementById('zone-appli');
    if (z) new ResizeObserver(zone).observe(z);
  }
  // (aucun menu du clic droit, aucun glisser-déposer de fichier dans la page)
  document.addEventListener('contextmenu', (e) => e.preventDefault());
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', (e) => e.preventDefault());

  if (pont) pont.ecouter(recevoir);
  window.addEventListener('DOMContentLoaded', () => { envoyer({ type: 'pret' }); zone(); });
})();
