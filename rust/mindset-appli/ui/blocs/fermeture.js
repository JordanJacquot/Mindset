// La question de la croix rouge (interface.xaml, la grille « Fermeture » ; zone.ps1:80-106), dessinée dans la zone
// #voile-fermeture de la coquille. À joindre aux scripts des écrans (le bloc horloge n'écrit pas le HTML) :
//   horlogeFermeture.installer(coquille, couleur)
//     coquille : window.coquille (surEtat, action)
//     couleur  : (facultatif) f('#00E5FF') -> la couleur dans le thème de la suite (ConvertTo-ThemeHex)
// L'état vient du bloc horloge : etat.fermeture = { visible, ouverture } ; à chaque nouvelle ouverture, « Ne plus me
// demander » est décoché et le bouton « Réduire près de l'horloge » prend le clavier (BtnFermetureReduire.Focus()).
// Les boutons envoient l'action « horloge:fermeture » { choix: 'reduire' | 'quitter' | 'annuler', souvenir }.
(() => {
  'use strict';
  const COCHE = '<svg viewBox="0 0 9.97498 9.09834" aria-hidden="true"><path fill="#212121" d="M9.97498,1.22334L4.6983,9.09834L4.52164,9.09834L0,5.19331L1.27664,3.52165L4.255,6.08833L8.33331,0L9.97498,1.22334Z"/></svg>';
  const HTML =
    '<div class="hf-panneau" role="dialog" aria-modal="true" aria-labelledby="hf-titre">' +
      '<p class="hf-titre" id="hf-titre">Fermer Mindset ?</p>' +
      '<p class="hf-texte">Réduit près de l\'horloge, Mindset et tes applis restent prêts : un clic sur son icône le rouvre. Quitter ferme aussi toutes tes applis (les rappels d\'Evermind, par exemple, ne sonneront plus jusqu\'à la réouverture).</p>' +
      '<label class="hf-case"><input type="checkbox" class="hf-souvenir"><span class="hf-boite">' + COCHE + '</span><span class="hf-etiquette">Ne plus me demander (modifiable dans Paramètres)</span></label>' +
      '<div class="hf-boutons">' +
        '<button type="button" class="hf-bouton hf-second" data-choix="annuler">Annuler</button>' +
        '<button type="button" class="hf-bouton hf-second" data-choix="quitter">Tout quitter</button>' +
        '<button type="button" class="hf-bouton" data-choix="reduire">Réduire près de l\'horloge</button>' +
      '</div>' +
    '</div>';

  // Les couleurs Néon de la question, et la variable CSS de chacune
  const COULEURS = {
    '#141030': ['--hf-panneau2'], '#2A2450': ['--hf-trait'], '#ECEAF7': ['--hf-texte'], '#A9A3C9': ['--hf-texte2'],
    '#00E5FF': ['--hf-cyan'], '#B04BFF': ['--hf-violet'], '#08060F': ['--hf-sur-accent'], '#F2EFFA': ['--hf-bouton2'],
  };
  function rgba(hex, a) {
    const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || ''));
    if (!m) return null;
    const n = parseInt(m[1], 16);
    return 'rgba(' + (n >> 16) + ', ' + ((n >> 8) & 255) + ', ' + (n & 255) + ', ' + a + ')';
  }

  // La largeur du panneau comme WPF : 500 au plus (ou la fenêtre), mais resserrée sur ce qu'il contient : la ligne la
  // plus longue du texte replié, le titre, la case à cocher, la rangée de boutons (un TextBlock replié ne demande que
  // la largeur de sa ligne la plus longue).
  function largeurDe(e) {
    const r = document.createRange();
    r.selectNodeContents(e);
    let max = 0;
    for (const x of r.getClientRects()) max = Math.max(max, x.width);
    return max;
  }
  function ajuster(zone) {
    const p = zone.querySelector('.hf-panneau');
    if (!p || zone.hidden) return;
    p.style.width = '';
    const boutons = [...zone.querySelectorAll('.hf-bouton')];
    const rangee = boutons.reduce((s, b) => s + b.getBoundingClientRect().width, 0) + 10 * Math.max(0, boutons.length - 1);
    const contenu = Math.max(
      largeurDe(zone.querySelector('.hf-titre')),
      largeurDe(zone.querySelector('.hf-texte')),
      zone.querySelector('.hf-case').getBoundingClientRect().width,
      rangee);
    const autour = p.offsetWidth - p.clientWidth + 56;   // (bordure et marges intérieures)
    p.style.width = Math.min(p.getBoundingClientRect().width, Math.ceil(contenu) + autour) + 'px';
  }

  function installer(coquille, couleur) {
    const zone = document.getElementById('voile-fermeture');
    if (!zone || !coquille) return;
    zone.innerHTML = HTML;
    if (typeof couleur === 'function') {
      for (const [hex, vars] of Object.entries(COULEURS)) {
        const c = couleur(hex);
        if (/^#[0-9a-f]{6}$/i.test(c || '')) for (const v of vars) zone.style.setProperty(v, c);
      }
      const fond = rgba(couleur('#06050F'), 0.7529);
      if (fond) zone.style.setProperty('--hf-voile', fond);
      const cyan = couleur('#00E5FF');
      for (const [v, a] of [['--hf-cyan-50', 0.502], ['--hf-cyan-60', 0.6], ['--hf-cyan-30', 0.3]]) {
        const x = rgba(cyan, a);
        if (x) zone.style.setProperty(v, x);
      }
    }
    const souvenir = zone.querySelector('.hf-souvenir');
    const reduire = zone.querySelector('[data-choix="reduire"]');
    let ouverture = -1;
    for (const b of zone.querySelectorAll('[data-choix]')) {
      b.addEventListener('click', () => {
        const choix = b.getAttribute('data-choix');
        // (comme WPF : la question se cache tout de suite, l'état du bloc suit)
        zone.hidden = true;
        coquille.action('horloge:fermeture', { choix, souvenir: !!souvenir.checked });
      });
    }
    coquille.surEtat((etat) => {
      const f = etat && etat.fermeture;
      const visible = !!(f && f.visible);
      if (visible && f.ouverture !== ouverture) {
        ouverture = f.ouverture;
        souvenir.checked = false;
        zone.hidden = false;
        try { reduire.focus({ preventScroll: true }); } catch (e) { /* (rien) */ }
      }
      zone.hidden = !visible;
      ajuster(zone);
    });
    window.addEventListener('resize', () => ajuster(zone));
  }

  window.horlogeFermeture = { installer, ajuster, HTML };
})();
