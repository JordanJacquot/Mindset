// Les écrans de Mindset (bloc « écrans », rust/mindset-ecrans) : interface.xaml et ce que dessinent accueil.ps1,
// chargement.ps1, logo.ps1 et packs.ps1, refaits à l'identique à partir de l'état envoyé par l'appli :
//   etat.ecrans          ce bloc : en-tête, onglets, cartes, questions, thème (couleurs, polices, pack)
//   etat.bienvenue, etat.maj_mindset   bloc « lui-même » : les bandeaux d'installation et de mise à jour de Mindset
//   etat.admin_bandeau   bloc « paramètres » : le bandeau du mini-installateur
//   etat.pages_applis    bloc « accrochage » : la page d'une appli (jauge, écran « Ouvrir », appli affichée)
//   etat.fermeture       bloc « horloge » : la question de la croix
//   etat.console         bloc « console » : la console 3D à la place de l'accueil (ni en-tête ni onglets)
// Les gestes partent par coquille.action (« ecrans:* » et ceux des autres blocs). Rien ici ne parle à Rust lui-même.
//
// Animations : comme WPF (30 images par seconde, SetDesiredFrameRate 30), par images (steps), jamais plus de 60 par
// seconde ; arrêtées quand on ne les voit pas, immobiles si Windows a coupé les animations.
(() => {
  'use strict';
  const C = window.coquille;
  if (!C) return;
  C.pageManuelle = true;

  const NS = 'http://www.w3.org/2000/svg';
  // (Windows a coupé les animations : tout reste immobile ; aussi pour les captures d'essai)
  let IMMOBILE = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  const $ = (id) => document.getElementById(id);
  let numero = 0, fige = false;
  const unique = (p) => `${p}${++numero}`;

  // Un élément HTML : h('div', { class: 'x', onclick: f }, enfant, 'texte'...)
  function h(tag, attrs, ...enfants) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else if (k === 'style' && typeof v === 'object') Object.assign(e.style, v);
      else e.setAttribute(k, v === true ? '' : String(v));
    }
    for (const x of enfants.flat()) if (x !== null && x !== undefined && x !== false) e.append(x instanceof Node ? x : String(x));
    return e;
  }
  // Un élément SVG
  function s(tag, attrs, ...enfants) {
    const e = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'style' && typeof v === 'object') Object.assign(e.style, v);
      else e.setAttribute(k, String(v));
    }
    for (const x of enfants.flat()) if (x) e.append(x);
    return e;
  }
  const bouton = (texte, style, clic, attrs) => h('button', Object.assign({ class: `bouton ${style}`, type: 'button', onclick: clic }, attrs || {}), texte);
  // (rien n'est envoyé pendant une capture d'essai : window.ecrans.figer)
  const act = (id, valeur) => { if (!fige) C.action(id, valeur === undefined ? null : valeur); };
  const urlPack = (f) => `http://pack.localhost/${encodeURIComponent(f)}`;
  const urlFichier = (f) => `http://fichier.localhost/${encodeURIComponent(f)}`;

  // ---------------------------------------------------------------------------------------------------------------
  // Les couleurs : une couleur Néon de la palette, traduite dans le thème (Get-Brush, Get-Couleur)
  // ---------------------------------------------------------------------------------------------------------------
  let palette = {};
  function coul(hex, alpha) {
    const h6 = String(hex).replace('#', '').toUpperCase();
    const brut = h6.length === 8 ? h6.slice(2) : h6;
    const a = alpha !== undefined ? alpha : (h6.length === 8 ? parseInt(h6.slice(0, 2), 16) / 255 : 1);
    const t = (palette[brut] || `#${brut}`).replace('#', '');
    const r = parseInt(t.slice(-6, -4), 16), g = parseInt(t.slice(-4, -2), 16), b = parseInt(t.slice(-2), 16);
    return a >= 1 ? `rgb(${r} ${g} ${b})` : `rgb(${r} ${g} ${b} / ${a.toFixed(3)})`;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Les boucles : une animation sans fin, image par image (30 par seconde), aller et retour en douceur (SineEase)
  // ---------------------------------------------------------------------------------------------------------------
  function boucle(el, valeur, de, a, ms, retour, debut) {
    if (IMMOBILE || !el.animate) { el.style.transform = valeur(debut !== undefined ? debut : de); return null; }
    const n = Math.max(2, Math.round(ms * 30 / 1000));
    const total = retour ? 2 * n : n;
    const images = [];
    for (let i = 0; i <= total; i++) {
      let p = retour ? (i <= n ? i / n : (2 * n - i) / n) : i / n;
      if (retour) p = (1 - Math.cos(Math.PI * p)) / 2;
      images.push({ transform: valeur(de + (a - de) * p) });
    }
    return el.animate(images, { duration: retour ? 2 * ms : ms, iterations: Infinity, easing: `steps(${total}, jump-end)` });
  }
  function origine(el, x, y) { el.style.transformBox = 'view-box'; el.style.transformOrigin = `${x}px ${y}px`; }

  // Un arc de cercle (Get-ArcGeometry), dans le sens des aiguilles d'une montre
  function arc(c, r, debut, angle) {
    if (angle <= 0.05) return '';
    const a1 = debut * Math.PI / 180, a2 = (debut + angle) * Math.PI / 180;
    const x1 = c + r * Math.cos(a1), y1 = c + r * Math.sin(a1), x2 = c + r * Math.cos(a2), y2 = c + r * Math.sin(a2);
    return `M ${x1.toFixed(3)},${y1.toFixed(3)} A ${r},${r} 0 ${angle > 180 ? 1 : 0} 1 ${x2.toFixed(3)},${y2.toFixed(3)}`;
  }
  // Un dégradé linéaire (New-LinearBrush) dans les <defs> : son id
  function degrade(defs, couleurs, x1, y1, x2, y2, opacites) {
    const id = unique('d');
    const g = s('linearGradient', { id, x1, y1, x2, y2 });
    couleurs.forEach((c, i) => g.append(s('stop', { offset: couleurs.length > 1 ? i / (couleurs.length - 1) : 0, 'stop-color': c, 'stop-opacity': opacites ? opacites[i] : 1 })));
    defs.append(g);
    return `url(#${id})`;
  }
  function radial(defs, arrets) {
    const id = unique('r');
    const g = s('radialGradient', { id, cx: 0.5, cy: 0.5, r: 0.5 });
    for (const [c, o, op] of arrets) g.append(s('stop', { offset: o, 'stop-color': c, 'stop-opacity': op }));
    defs.append(g);
    return `url(#${id})`;
  }
  const lueur = (hex, flou, op) => `drop-shadow(0 0 ${(flou / 3).toFixed(1)}px ${coul(hex, op)})`;

  // ---------------------------------------------------------------------------------------------------------------
  // La lettre animée (New-MindsetMark) : le trait blanc et ses échos cyan et magenta, deux tranches qui « glitchent »
  // ---------------------------------------------------------------------------------------------------------------
  function marque(defs, lettre, taille, x, y) {
    const g = s('g', { transform: `translate(${x} ${y}) scale(${taille / 100})` });
    const forme = (couleur) => {
      if (lettre && lettre.texte) {
        return s('text', { x: 50, y: 50, 'text-anchor': 'middle', 'dominant-baseline': 'central', 'font-family': 'Segoe UI', 'font-weight': 900, 'font-size': 66, fill: couleur }, document.createTextNode(lettre.texte));
      }
      const l = lettre && lettre.d ? lettre : { d: 'M 22,78 L 22,22 L 50,55.6 L 78,22 L 78,78', epaisseur: 15 };
      return s('path', { d: l.d, fill: 'none', stroke: couleur, 'stroke-width': l.epaisseur, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' });
    };
    const clip = (rects) => {
      const id = unique('c');
      const cp = s('clipPath', { id, clipPathUnits: 'userSpaceOnUse' });
      for (const [y0, hh] of rects) cp.append(s('rect', { x: -100, y: y0, width: 300, height: hh }));
      defs.append(cp);
      return `url(#${id})`;
    };
    const couche = (couleur, op, cl) => { const e = s('g', { opacity: op, 'clip-path': cl }); e.append(forme(couleur)); return e; };
    const cyan = couche(coul('#00E5FF'), 0.92), mag = couche(coul('#FF2EB5'), 0.92);
    const base = couche('#FFFFFF', 1, clip([[-100, 136], [43, 20], [68, 200]]));
    const p1 = couche('#FFFFFF', 1, clip([[36, 7]])), p2 = couche('#FFFFFF', 1, clip([[63, 5]]));
    g.append(cyan, mag, base, p1, p2);
    const m = { g, cyan, mag, base, p: [p1, p2], occupe: false };
    pose(m, [-0.035, 0.035, 0.05, -0.04], 0);
    return m;
  }
  function pose(m, p, b) {
    const t = (e, v) => e.setAttribute('transform', `translate(${(v * 100).toFixed(2)} 0)`);
    t(m.cyan, p[0]); t(m.mag, p[1]); t(m.p[0], p[2]); t(m.p[1], p[3]); t(m.base, b);
  }
  // Un « saut » (Start-LogoGlitch) : décalages au hasard toutes les 45 ms, puis retour au repos
  function glitch(m, ms) {
    if (!m || m.occupe || IMMOBILE) return;
    m.occupe = true;
    const fin = Date.now() + ms;
    const j = (a) => (Math.random() * 2 - 1) * a;
    const pas = () => {
      if (Date.now() > fin) { pose(m, [-0.035, 0.035, 0.05, -0.04], 0); m.occupe = false; return; }
      pose(m, [j(0.09), j(0.09), j(0.14), j(0.14)], j(0.03));
      setTimeout(pas, 45);
    };
    pas();
  }

  // ---------------------------------------------------------------------------------------------------------------
  // L'anneau (logo de l'en-tête : Start-LogoAnime ; jauge d'une appli : New-JaugeAnneau), dessiné sur S
  // ---------------------------------------------------------------------------------------------------------------
  function anneau(S, opts) {
    const k = S / 260, c = S / 2;
    const svg = s('svg', { viewBox: `0 0 ${S} ${S}`, width: S, height: S, class: 'jauge-svg' });
    const defs = s('defs');
    svg.append(defs);
    const anims = [];
    // Halo qui respire
    const halo = s('circle', { cx: c, cy: c, r: 110 * k, fill: radial(defs, opts.jauge
      ? [[coul('#00E5FF'), 0, 0.251], [coul('#FF2EB5'), 0.6, 0.102], [coul('#FF2EB5'), 1, 0]]
      : [[coul('#00E5FF'), 0, 0.333], [coul('#FF2EB5'), 0.6, 0.133], [coul('#FF2EB5'), 1, 0]]) });
    origine(halo, c, c);
    svg.append(halo);
    anims.push(boucle(halo, (v) => `scale(${v})`, 0.85, 1.1, 1600, true, 1));
    // Anneau de fond
    const ep = opts.jauge ? 6 : Math.max(2, 6 * k);
    svg.append(s('path', { d: arc(c, 112 * k, -90, 359.9), fill: 'none', stroke: 'rgb(255 255 255 / 0.086)', 'stroke-width': ep, 'stroke-linecap': 'round' }));
    let progres = null;
    if (opts.jauge) {
      // L'anneau qui se remplit
      progres = s('path', { d: arc(c, 112, -90, opts.plein ? 359.9 : 0.1), fill: 'none', stroke: degrade(defs, [coul('#00E5FF'), coul('#FF2EB5')], 0, 0, 1, 1), 'stroke-width': 6, 'stroke-linecap': 'round', style: { filter: lueur('#00E5FF', 14, 0.7) } });
      svg.append(progres);
    } else {
      // L'anneau cyan vers violet qui tourne
      const tour = s('g');
      origine(tour, c, c);
      tour.append(s('path', { d: arc(c, 112 * k, -90, 250), fill: 'none', stroke: degrade(defs, [coul('#00E5FF'), coul('#B04BFF'), coul('#FF2EB5')], 0, 0, 1, 1), 'stroke-width': ep, 'stroke-linecap': 'round', style: { filter: lueur('#00E5FF', 14 * k + 4, 0.7) } }));
      svg.append(tour);
      anims.push(boucle(tour, (v) => `rotate(${v}deg)`, 0, 360, 3200, false));
    }
    // La comète magenta qui tourne en sens inverse
    const com = s('g');
    origine(com, c, c);
    com.append(s('path', { d: arc(c, 124 * k, 0, 60), fill: 'none', stroke: degrade(defs, [coul('#FF2EB5'), coul('#FF2EB5')], 0, 1, 1, 0, [0, 1]), 'stroke-width': opts.jauge ? 2 : Math.max(1.2, 2 * k), 'stroke-linecap': 'round' }));
    svg.append(com);
    anims.push(boucle(com, (v) => `rotate(${v}deg)`, 360, 0, 2600, false));
    // Au centre : l'image du thème, ou la lettre
    let m = null, image = null;
    if (opts.image) {
      image = opts.image;
    } else if (!opts.sansLettre) {
      m = marque(defs, opts.lettre, 128 * k, c - 64 * k, c - (opts.jauge && !opts.plein ? 72 : 64) * k);
      svg.append(m.g);
    }
    // La ligne de balayage, dans le cercle
    const clipId = unique('c');
    const cp = s('clipPath', { id: clipId });
    cp.append(s('circle', { cx: c, cy: c, r: 106 * k }));
    defs.append(cp);
    const hote = s('g', { 'clip-path': `url(#${clipId})` });
    const hb = opts.jauge ? 3 : Math.max(1.5, 3 * k);
    const ligne = s('rect', { x: 0, y: 0, width: S, height: hb, fill: degrade(defs, [coul('#00E5FF'), coul('#00E5FF'), coul('#00E5FF')], 0, 0, 1, 0, [0, opts.jauge ? 0.502 : 0.6, 0]) });
    hote.append(ligne);
    svg.append(hote);
    anims.push(boucle(ligne, (v) => `translateY(${v}px)`, 20 * k, 240 * k, 2200, false, -10));
    return { svg, defs, anims: anims.filter(Boolean), marque: m, progres, image };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Les planches d'un thème personnalisé (Get-SheetFrames, Start-Defilement) : images côte à côte, une à la fois
  // ---------------------------------------------------------------------------------------------------------------
  function planche(src, images, delai, hauteur, opts) {
    const o = opts || {};
    const boite = h('div', { class: `planche${o.miroir ? ' miroir' : ''}` });
    boite.style.height = `${hauteur}px`;
    const img = h('img', { src, alt: '', draggable: 'false' });
    boite.append(img);
    const n = Math.max(1, images | 0);
    boite.anim = null;
    img.addEventListener('load', () => {
      const fl = Math.floor(img.naturalWidth / n), fh = img.naturalHeight || 1;
      let ht = hauteur, lg = ht * fl / fh;
      if (o.largeurMax && lg > o.largeurMax) { lg = o.largeurMax; ht = lg * fh / fl; }
      boite.style.width = `${lg}px`; boite.style.height = `${ht}px`;
      img.style.width = `${lg * img.naturalWidth / fl}px`;
      if (fh <= ht) boite.classList.add('net');
      if (n > 1 && !IMMOBILE && img.animate) {
        boite.anim = img.animate([{ transform: 'translateX(0)' }, { transform: `translateX(-${(n * fl / img.naturalWidth * 100).toFixed(4)}%)` }],
          { duration: n * Math.max(30, delai | 0), iterations: Infinity, easing: `steps(${n}, jump-end)` });
        if (o.arret) { boite.anim.pause(); boite.anim.currentTime = 0; }
      }
      if (o.pret) o.pret(lg, ht);
    });
    return boite;
  }
  // Image fixe : elle sautille (Start-Sautille), lévitation lumineuse si une couleur est donnée
  function sautille(el, haut, lueurHex) {
    if (lueurHex) el.style.filter = `drop-shadow(0 0 3.3px ${lueurHex})`;
    return boucle(el, (v) => `translateY(${v}px)`, 0, -haut, lueurHex ? 900 : 320, true, 0);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // L'état reçu, et ce qui est dessiné (chaque partie n'est redessinée que si elle change, comme $script:CartesCle)
  // ---------------------------------------------------------------------------------------------------------------
  const deja = {};
  function change(cle, valeur) {
    const t = JSON.stringify(valeur === undefined ? null : valeur);
    if (deja[cle] === t) return false;
    deja[cle] = t;
    return true;
  }
  let E = null, etatComplet = {}, page = 'accueil';

  function dessiner(etat) {
    etatComplet = etat || {};
    E = etatComplet.ecrans;
    if (!E) return;
    page = (etatComplet._vue && typeof etatComplet._vue.page === 'string' ? etatComplet._vue.page : E.page) || 'accueil';
    if (change('theme', E.theme)) poserTheme(E.theme);
    if (change('entete', [E.version, E.m, E.theme && E.theme.pack])) dessinerEntete();
    if (change('onglets', [E.onglets, E.onglets_bas, E.theme && E.theme.pack && E.theme.pack.onglets])) dessinerOnglets();
    dessinerBandeaux();
    dessinerAccueil();
    dessinerAppli();
    dessinerParametres();
    dessinerQuestions();
    naviguer();
    if (pixel) pixelAFaire = true;
  }

  // Le thème : les couleurs (variables CSS), les polices, la police du pack
  let pixel = false, pixelAFaire = false;
  function poserTheme(t) {
    if (!t) return;
    palette = t.palette || {};
    const r = document.documentElement.style;
    for (const [k, v] of Object.entries(palette)) {
      const x = String(v).replace('#', '');
      r.setProperty(`--c-${k}`, `${parseInt(x.slice(-6, -4), 16)} ${parseInt(x.slice(-4, -2), 16)} ${parseInt(x.slice(-2), 16)}`);
    }
    const pol = (l) => String(l || '').split(',').map((x) => `"${x.trim().replace(/"/g, '')}"`).join(', ');
    r.setProperty('--police-titres', pol(t.police_titres));
    r.setProperty('--police-texte', pol(t.police_texte));
    document.documentElement.dataset.theme = t.id || 'neon';
    let st = $('police-pack');
    const p = t.pack && t.pack.police;
    if (p && p.fichier) {
      if (!st) { st = h('style', { id: 'police-pack' }); document.head.append(st); }
      st.textContent = `@font-face { font-family: "MindsetPack"; src: url("${urlPack(p.fichier)}"); }`;
      pixel = !!(p.partout && p.pixel);
    } else if (st) { st.remove(); pixel = false; }
    // Le fond du thème : l'image, puis un voile sombre qui garde le texte lisible
    const fp = $('fond-pack');
    fp.replaceChildren();
    const f = t.pack && t.pack.fond;
    if (f && f.fichier) {
      const x = { gauche: 'left', droite: 'right' }[f.x] || 'center', y = { haut: 'top', bas: 'bottom' }[f.y] || 'center';
      fp.append(h('div', { class: 'image', style: { backgroundImage: `url("${urlPack(f.fichier)}")`, backgroundPosition: `${x} ${y}`, opacity: String(f.opacite) } }), h('div', { class: 'voile-pack' }));
    }
    // Le dessin animé du bas
    const pied = $('pied');
    pied.replaceChildren();
    const b = t.pack && t.pack.bas;
    if (b && b.fichier) pied.append(planche(urlPack(b.fichier), b.images, b.delai, b.hauteur));
  }

  // L'en-tête : logo animé (ou celui du thème), mascotte, version
  let logo = null, minuterieLogo = null;
  function dessinerEntete() {
    $('version').textContent = E.version || '';
    const hote = $('logo');
    if (logo) logo.anims.forEach((a) => a && a.cancel());
    hote.replaceChildren();
    clearTimeout(minuterieLogo);
    const pack = E.theme && E.theme.pack;
    logo = anneau(84, { sansLettre: !!(pack && pack.logo) });
    hote.append(logo.svg);
    if (pack && pack.logo) {
      // Le logo du thème à la place du M : il se secoue de temps en temps et au survol ; une planche joue un tour
      const L = pack.logo, t = 150 * 84 / 260;
      const boite = h('div', { class: 'pack-logo' });
      const img = L.images > 1
        ? planche(urlPack(L.fichier), L.images, L.delai, t, { arret: true })
        : h('img', { src: urlPack(L.fichier), alt: '', style: { width: `${t}px`, height: `${t}px`, objectFit: 'contain' } });
      Object.assign(img.style, { position: 'absolute', left: `${42 - t / 2}px`, top: `${42 - t / 2}px`, transformOrigin: '50% 85%' });
      boite.append(img);
      hote.append(boite);
      if (L.lueur) logo.anims.push(sautille(img, 3, L.lueur));
      const secoue = () => {
        if (img.anim) { img.anim.currentTime = 0; img.anim.play(); setTimeout(() => img.anim && img.anim.pause(), L.images * Math.max(30, L.delai)); return; }
        if (L.lueur || IMMOBILE || !img.animate) return;
        img.animate([{ transform: 'rotate(0deg)', offset: 0 }, { transform: 'rotate(-22deg)', offset: 110 / 580 }, { transform: 'rotate(18deg)', offset: 240 / 580 },
          { transform: 'rotate(-12deg)', offset: 360 / 580 }, { transform: 'rotate(6deg)', offset: 470 / 580 }, { transform: 'rotate(0deg)', offset: 1 }], { duration: 580 });
      };
      const prochain = () => { minuterieLogo = setTimeout(() => { if (visibleLogo()) secoue(); prochain(); }, 6000 + Math.random() * 7000); };
      minuterieLogo = setTimeout(() => { if (visibleLogo()) secoue(); prochain(); }, 7000);
      hote.onmouseenter = secoue;
    } else {
      const saut = () => { if (visibleLogo()) glitch(logo.marque, 260); minuterieLogo = setTimeout(saut, 1300); };
      minuterieLogo = setTimeout(saut, 1300);
      hote.onmouseenter = () => glitch(logo.marque, 420);
    }
    // La mascotte du thème
    const masc = $('mascotte');
    masc.replaceChildren();
    const M = pack && pack.mascotte;
    masc.hidden = !(M && M.fichier);
    if (M && M.fichier) {
      const p = planche(urlPack(M.fichier), M.images, M.delai, 64, { miroir: M.miroir });
      masc.append(p);
      if (!(M.images > 1)) sautille(p, 8);
    }
  }
  // (au premier plan, Mindset ni caché ni réduit, l'en-tête à l'écran)
  const visibleLogo = () => document.visibilityState === 'visible' && document.hasFocus() && !$('en-tete').hidden;

  // ---------------------------------------------------------------------------------------------------------------
  // Les onglets (New-Onglet, New-IconeBase, New-IconeOnglet)
  // ---------------------------------------------------------------------------------------------------------------
  function iconeBase(ic) {
    const svg = s('svg', { class: 'icone', viewBox: '0 0 20 20', width: 20, height: 20 });
    if (ic.genre === 'accueil') {
      svg.append(s('path', { d: ic.d, fill: 'none', stroke: ic.couleur, 'stroke-width': 1.7, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
    } else if (ic.genre === 'parametres') {
      svg.append(s('path', { d: ic.d, fill: ic.couleur, 'fill-rule': 'evenodd' }));
    } else {
      const defs = s('defs');
      svg.append(defs, s('circle', { cx: 10, cy: 10, r: 9.5 - 0.8, fill: 'none', stroke: degrade(defs, ic.anneau, 0, 0, 1, 1), 'stroke-width': 1.6 }));
      const g = s('g', { transform: 'translate(10 10) scale(0.72) translate(-10 -10) scale(0.2)' });
      const l = ic.lettre || {};
      if (l.texte) g.append(s('text', { x: 50, y: 50, 'text-anchor': 'middle', 'dominant-baseline': 'central', 'font-family': 'Segoe UI', 'font-weight': 900, 'font-size': 66, fill: ic.couleur }, document.createTextNode(l.texte)));
      else g.append(s('path', { d: l.d, fill: 'none', stroke: ic.couleur, 'stroke-width': l.epaisseur, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));
      svg.append(g);
    }
    return svg;
  }
  const boutonsOnglets = {};
  function dessinerOnglets() {
    const icones = (E.theme && E.theme.pack && E.theme.pack.onglets) || {};
    const faire = (liste, hote) => {
      hote.replaceChildren();
      for (const o of liste || []) {
        const b = h('button', { class: 'onglet', type: 'button', onclick: () => act('ecrans:onglet', o.id) });
        const ip = icones[o.id];
        if (ip && ip.fichier) {
          // Icône animée du thème : immobile, animée au survol
          const p = planche(urlPack(ip.fichier), ip.images, ip.delai, 22, { arret: true });
          p.classList.add('icone-pack');
          b.append(p);
          b.addEventListener('mouseenter', () => { if (p.anim) p.anim.play(); });
          b.addEventListener('mouseleave', () => { if (p.anim) { p.anim.pause(); p.anim.currentTime = 0; } });
        } else b.append(iconeBase(o.icone));
        b.append(h('span', { class: 'texte' }, o.texte));
        hote.append(b);
        boutonsOnglets[o.id] = b;
      }
    };
    faire(E.onglets, $('onglets'));
    faire(E.onglets_bas, $('onglets-bas'));
    deja.ongletActif = null;
  }
  function marquerOnglet() {
    if (!change('ongletActif', page)) return;
    for (const [id, b] of Object.entries(boutonsOnglets)) b.classList.toggle('actif', id === page);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Les bandeaux (Bienvenue, AdminBandeau, MajBandeau) : leurs textes viennent des blocs « lui-même » et « paramètres »
  // ---------------------------------------------------------------------------------------------------------------
  function caseACocher(texte, oui, clic, rond) {
    const c = h('div', { class: `case${rond ? ' rond' : ''}${oui ? ' oui' : ''}`, role: rond ? 'radio' : 'checkbox', 'aria-checked': String(!!oui), tabindex: 0 });
    c.append(h('span', { class: 'boite' }), h('span', {}, texte));
    c.addEventListener('click', () => clic(c));
    c.addEventListener('keydown', (e) => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); clic(c); } });
    return c;
  }
  function dessinerBandeaux() {
    const b = etatComplet.bienvenue, a = etatComplet.admin_bandeau, m = etatComplet.maj_mindset;
    if (!change('bandeaux', [b, a, m])) return;
    const hote = $('bandeaux');
    hote.replaceChildren();
    if (b && b.visible) {
      let disque = '';
      const disques = h('div', { class: 'disques' });
      const radios = [];
      for (const d of b.disques || []) {
        const r = caseACocher(`${d.texte}   ·   ${d.libre}`, false, (c) => { disque = d.lettre || ''; radios.forEach((x) => { x.classList.toggle('oui', x === c); x.setAttribute('aria-checked', String(x === c)); }); }, true);
        radios.push(r);
        if ((d.lettre || '') === (b.coche !== undefined ? (b.coche || '') : '') && !disques.querySelector('.oui')) { r.classList.add('oui'); disque = d.lettre || ''; }
        disques.append(r);
      }
      const verif = caseACocher('Chercher les nouvelles versions', b.verif !== false, (c) => { const oui = !c.classList.contains('oui'); c.classList.toggle('oui', oui); act('lui-meme:verif', { oui }); });
      hote.append(h('div', { class: 'bandeau bienvenue' },
        h('div', { class: 'textes' },
          h('div', { class: 'titre' }, 'Installer Mindset sur ce PC'),
          h('div', { class: 'texte' }, b.texte || "Mindset s'installe avec ses applis et leurs données sur le disque choisi, crée son raccourci sur le Bureau et dans le menu Démarrer, et se lance avec Windows. Tu pourras ensuite supprimer le dossier téléchargé."),
          h('div', { class: 'sous-titre' }, 'Ce qui part sur Internet'),
          h('div', { class: 'reseau' }, `${b.reseau || "Mindset vérifie sur GitHub s'il existe une nouvelle version de lui-même et de tes applis. Rien d'autre n'est envoyé. Tu peux couper cette vérification ici, ou plus tard dans les Paramètres."} `,
            h('span', { class: 'lien', onclick: () => act('ecrans:confidentialite', '') }, b.lien_reseau || 'En savoir plus')),
          verif,
          h('div', { class: 'sous-titre' }, 'Où installer Mindset et ses applis ?'),
          disques),
        h('div', { class: 'actions' },
          bouton('Plus tard', 'secondaire', () => act('lui-meme:plus-tard')),
          bouton('Installer Mindset', 'primaire', () => act('lui-meme:installer', { disque }), { disabled: !!b.en_cours }))));
    }
    if (a && a.visible) {
      hote.append(h('div', { class: 'bandeau admin' },
        h('div', { class: 'textes' },
          h('div', { class: 'titre' }, 'Installer sans demande de Windows'),
          h('div', { class: 'texte' }, a.texte || 'Mindset crée son mini-installateur : les installations et les mises à jour (seulement des fichiers signés) ne demanderont plus l\'autorisation. Une dernière demande de Windows.')),
        h('div', { class: 'actions' }, bouton('Activer', 'primaire', () => act('parametres:activer-admin'), { disabled: a.bouton_actif === false }))));
    }
    if (m && m.visible) {
      hote.append(h('div', { class: 'bandeau maj' },
        h('div', { class: 'textes' }, h('div', { class: 'titre' }, m.titre || ''), h('div', { class: 'texte' }, m.texte || '')),
        h('div', { class: 'actions' },
          bouton(m.bouton_fermer || 'OK', 'secondaire', () => act('lui-meme:maj-fermer')),
          m.bouton_maj ? bouton('Redémarrer et mettre à jour', 'primaire', () => act('lui-meme:maj')) : null)));
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // L'accueil et ses cartes (Update-Carte : chaque élément dans l'ordre, tel que le bloc l'envoie)
  // ---------------------------------------------------------------------------------------------------------------
  function texteEl(e) {
    const t = h('div', { class: 't' }, e.texte);
    Object.assign(t.style, { fontSize: `${e.taille}px`, color: e.couleur, fontWeight: e.poids === 'SemiBold' ? '600' : (e.poids === 'Bold' ? '700' : '400') });
    return t;
  }
  // (une marge WPF « gauche,haut,droite,bas » en CSS « haut droite bas gauche »)
  const marge = (m) => { if (!m) return ''; const [g, hh, d, b] = m.split(',').map(Number); return `${hh}px ${d}px ${b}px ${g}px`; };
  function jaugeScore(sc) {
    const S = 74, c = 37, R = 30;
    const svg = s('svg', { viewBox: `0 0 ${S} ${S}`, width: S, height: S });
    const defs = s('defs');
    svg.append(defs, s('path', { d: arc(c, R, -90, 359.9), fill: 'none', stroke: 'rgb(255 255 255 / 0.102)', 'stroke-width': 6, 'stroke-linecap': 'round' }));
    const p = s('path', { fill: 'none', stroke: degrade(defs, [sc.c1, sc.c2], 0, 0, 1, 1), 'stroke-width': 6, 'stroke-linecap': 'round', style: { filter: `drop-shadow(0 0 3.3px ${sc.c1}99)` } });
    svg.append(p);
    // Remplissage en 0,7 s, ralenti à la fin (60 images par seconde au plus) ; tout de suite plein sans animations
    const fin = Math.max(0.1, Math.min(359.9, 3.6 * sc.valeur));
    if (IMMOBILE) p.setAttribute('d', arc(c, R, -90, fin));
    else {
      const debut = performance.now();
      const pas = () => {
        const k = Math.min(1, (performance.now() - debut) / 700);
        p.setAttribute('d', arc(c, R, -90, Math.max(0.1, fin * (1 - Math.pow(1 - k, 3)))));
        if (k < 1) setTimeout(pas, 16);
      };
      pas();
    }
    return h('div', { class: 'jauge' }, h('div', { class: 'rond' }, svg, h('div', { class: 'valeur' }, String(sc.valeur))), h('div', { class: 'nom' }, sc.nom));
  }
  function ligneVivante(contenu, clic, classe) {
    return h('div', { class: `ligne-vivante${classe ? ` ${classe}` : ''}`, onclick: clic }, contenu);
  }
  function resume(e, carte) {
    const box = h('div', { class: 'resume' });
    const ouvrir = () => act('ecrans:carte', { id: carte.id, quoi: 'ouvrir' });
    if (e.genre === 'nevermind') {
      box.append(h('div', { class: 'jauges' }, (e.scores || []).map(jaugeScore)));
      box.append(ligneVivante(h('div', { class: 't', style: { color: e.ligne.couleur } }, e.ligne.texte), ouvrir));
    } else if (e.genre === 'evermind') {
      const ent = h('div', { class: 'entete t' }, 'Prochains rendez-vous');
      box.append(ent);
      if (!(e.rdv || []).length) box.append(h('div', { class: 't', style: { fontSize: '12.5px', color: coul('#6F6894'), marginTop: '6px' } }, e.vide || 'Rien de prévu pour le moment.'));
      else {
        ent.style.marginBottom = '6px';
        for (const r of e.rdv) {
          box.append(ligneVivante([h('div', { class: 'quand t', style: { color: carte.couleur } }, r.quand), h('div', { class: 'quoi t' }, r.titre)],
            () => act('ecrans:carte', { id: carte.id, quoi: 'rdv', rdv: r.id, moment: r.moment }), 'rdv'));
        }
      }
    } else {
      if (e.titre) box.append(h('div', { class: 'entete t', style: { marginBottom: '6px' } }, e.titre));
      if ((e.scores || []).length) box.append(h('div', { class: 'jauges' }, e.scores.map(jaugeScore)));
      for (const l of e.lignes || []) box.append(ligneVivante(h('div', { class: 't', style: { color: l.couleur } }, l.texte), ouvrir));
    }
    return box;
  }
  function dessinerCarte(carte) {
    const el = h('div', { class: 'carte', 'data-id': carte.id });
    for (const e of carte.elements || []) {
      switch (e.t) {
        case 'texte': { const t = texteEl(e); t.style.margin = marge(e.marge); el.append(t); break; }
        case 'pastilles':
          el.append(h('div', { class: 'rangee', style: { margin: marge(e.marge) } },
            e.liste.map((p) => h('div', { class: 'pastille', style: { borderColor: p.couleur, color: p.couleur } }, p.texte))));
          break;
        case 'boutons':
          el.append(h('div', { class: 'rangee', style: { margin: marge(e.marge) } },
            e.liste.map((b) => bouton(b.texte, b.style, () => act('ecrans:carte', { id: carte.id, quoi: b.quoi })))));
          break;
        case 'reseau':
          el.append(h('div', { class: 't reseau', style: { fontSize: `${e.taille}px`, color: e.couleur, margin: marge(e.marge) } }, e.texte,
            h('span', { class: 'lien', style: { color: e.lien_couleur }, onclick: () => act('ecrans:confidentialite', carte.id) }, e.lien)));
          break;
        case 'interrupteur': {
          const sw = h('button', { class: `interrupteur${e.oui ? ' oui' : ''}`, type: 'button', role: 'switch', 'aria-checked': String(!!e.oui) });
          sw.addEventListener('click', () => {
            const oui = !sw.classList.contains('oui');
            sw.classList.toggle('oui', oui); sw.setAttribute('aria-checked', String(oui));
            act('ecrans:interrupteur', { id: carte.id, oui });
          });
          el.append(h('div', { class: 'ligne-interrupteur', style: { margin: marge(e.marge) } },
            h('div', { class: 'textes' }, h('div', { class: 't', style: { fontSize: '13px', color: coul('#ECEAF7') } }, e.texte), h('div', { class: 't aide' }, e.aide)), sw));
          break;
        }
        case 'resume': el.append(resume(e, carte)); break;
        default: break;
      }
    }
    return el;
  }
  const cartesDessinees = {};
  function dessinerAccueil() {
    $('bonjour').textContent = E.bonjour || '';
    $('actualiser-info').textContent = E.actualiser || '';
    const hote = $('cartes');
    const ids = (E.cartes || []).map((c) => c.id);
    if (change('ordreCartes', ids)) { hote.replaceChildren(); for (const k of Object.keys(cartesDessinees)) delete cartesDessinees[k]; }
    for (const c of E.cartes || []) {
      const t = JSON.stringify(c);
      const avant = cartesDessinees[c.id];
      if (avant && avant.t === t) continue;
      const el = dessinerCarte(c);
      if (avant) avant.el.replaceWith(el); else hote.append(el);
      cartesDessinees[c.id] = { t, el };
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // La page d'une appli (Show-JaugeAppli, Update-JaugeAppli, Show-EcranOuvrir, Set-EtatPageAppli, Update-BarreAppli)
  // ---------------------------------------------------------------------------------------------------------------
  let jauge = null;
  function arreterJauge() {
    if (!jauge) return;
    clearInterval(jauge.minuterie); clearTimeout(jauge.glitch);
    for (const a of jauge.anims || []) if (a) a.cancel();
    jauge = null;
    $('appli-jauge').replaceChildren();
    $('appli-jauge').hidden = true;
  }
  // 90 % à la durée habituelle (en ralentissant), puis doucement vers 99 %
  function avancee(J) {
    const t = (Date.now() - J.depuis) / 1000;
    const k = Math.max(0, t / J.duree);
    return k < 1 ? 90 * (1 - Math.pow(1 - k, 2)) : 90 + 9 * (1 - Math.exp(-(k - 1)));
  }
  function montrerJauge(P, info, ecran) {
    const id = P.id;
    const cle = JSON.stringify([id, ecran, ecran ? null : [info.depuis_ms, info.duree_s]]);
    if (jauge && jauge.cle === cle) return;
    arreterJauge();
    const hote = $('appli-jauge');
    const pack = E.theme && E.theme.pack;
    const lettre = (E.lettres || {})[id];
    const J = { cle, anims: [] };
    if (!ecran) {
      const d = Number(info.depuis_ms) || 0;
      J.depuis = d > 1e12 ? d : Date.now() - Math.max(0, d);
      J.duree = Math.max(2, Number(info.duree_s) || 10);
    }
    const L = pack && pack.jauge;
    if (!ecran && L && L.fichier) {
      // Le personnage du thème au-dessus d'une barre qui se remplit (New-JaugePersonnage)
      const W = 400, barY = 168 + (L.ecart || 0), gap = L.ecart || 0;
      const zone = h('div', { style: { position: 'relative', width: `${W}px`, height: `${210 + gap}px` } });
      const ombre = h('div', { style: { position: 'absolute', height: '8px', borderRadius: '50%', background: 'rgb(0 0 0 / 0.333)', top: `${barY - 7}px` } });
      if (L.fixe) ombre.hidden = true;
      const src = L.expose ? urlFichier(L.fichier) : urlPack(L.fichier);
      const perso = planche(src, L.images, L.delai, L.hauteur > 0 ? L.hauteur : 120, { miroir: L.miroir, largeurMax: W, pret: (lg, ht) => {
        J.lp = lg; perso.style.top = `${barY - ht + 4 - gap}px`; ombre.style.width = `${lg * 0.6}px`;
        if (!(L.images > 1)) { J.anims.push(sautille(perso, 22)); J.anims.push(boucle(ombre, (v) => `scaleX(${v})`, 1, 0.6, 260, true, 1)); }
      } });
      perso.style.position = 'absolute';
      const piste = h('div', { style: { position: 'absolute', top: `${barY}px`, left: 0, width: `${W}px`, height: '14px', boxSizing: 'border-box', borderRadius: '7px', background: 'rgb(255 255 255 / 0.118)', border: '1px solid rgb(255 255 255 / 0.149)' } });
      const rempli = h('div', { style: { position: 'absolute', top: `${barY}px`, left: 0, width: '14px', height: '14px', borderRadius: '7px', background: `linear-gradient(90deg, ${coul('#00E5FF')}, ${coul('#B04BFF')})`, filter: lueur('#00E5FF', 14, 0.7) } });
      const pct = h('div', { class: 'jauge-pct', style: { position: 'absolute', left: 0, width: `${W}px`, top: `${barY + 22}px`, fontSize: '15px' } }, '0 %');
      zone.append(ombre, perso, piste, rempli, pct);
      hote.append(zone);
      J.maj = (v) => {
        const w = Math.max(14, W * v / 100);
        rempli.style.width = `${w}px`;
        const lp = J.lp || 0;
        const x = L.fixe ? (W - lp) / 2 : Math.max(0, Math.min(W - lp, w - lp * 0.7));
        perso.style.left = `${x}px`; ombre.style.left = `${x + lp * 0.2}px`;
        pct.textContent = `${Math.round(v)} %`;
      };
    } else {
      // L'anneau de Nevermind et la lettre de l'appli (ou, sur l'écran « Ouvrir », l'icône de son onglet du thème)
      const ic = ecran && pack && pack.onglets && pack.onglets[id];
      const a = anneau(260, { jauge: true, plein: ecran, lettre, sansLettre: !!ic });
      J.anims.push(...a.anims);
      const zone = h('div', { style: { position: 'relative', width: '260px', height: '260px' } }, a.svg);
      if (ic) {
        const p = planche(urlPack(ic.fichier), ic.images, ic.delai, 112);
        Object.assign(p.style, { position: 'absolute', left: '74px', top: '74px', width: '112px' });
        zone.append(p);
        J.anims.push(boucle(p, (v) => `translateY(${v}px)`, 0, -6, 900, true, 0));
      } else if (a.marque) {
        const saut = () => { if (document.visibilityState === 'visible') glitch(a.marque, 260); J.glitch = setTimeout(saut, 1300); };
        J.glitch = setTimeout(saut, 1300);
      }
      if (!ecran) {
        const pct = h('div', { class: 'jauge-pct', style: { position: 'absolute', left: 0, width: '260px', top: `${130 + 58}px`, fontSize: '18px' } }, '0 %');
        zone.append(pct);
        J.maj = (v) => { a.progres.setAttribute('d', arc(130, 112, -90, Math.max(0.1, Math.min(359.9, 3.6 * v)))); pct.textContent = `${Math.round(v)} %`; };
      }
      hote.append(zone);
    }
    hote.hidden = false;
    jauge = J;
    if (J.maj) {
      J.maj(avancee(J));
      // (toutes les 60 ms ; immobile pour une capture d'essai)
      if (!IMMOBILE) J.minuterie = setInterval(() => { if (document.visibilityState === 'visible') J.maj(avancee(J)); }, 60);
    }
  }
  function dessinerAppli() {
    const surAppli = page !== 'accueil' && page !== 'parametres';
    if (!surAppli) { arreterJauge(); deja.appli = null; return; }
    const P = Object.assign({ id: page }, E.appli || {}, ((etatComplet.pages_applis || {})[page]) || {});
    const console = !!E.console;
    if (!change('appli', [P, console, E.lettres && E.lettres[page], E.theme && E.theme.pack])) return;
    const montree = !!P.montree;
    $('appli-message').hidden = montree;
    $('appli-cadre').hidden = !montree;
    $('barre-appli').hidden = !!P.barre_propre;
    $('btn-barre-menu').hidden = !console;
    $('btn-appli-menu').hidden = !console;
    if (montree) { arreterJauge(); C.zone(); return; }
    const t = $('appli-titre');
    t.textContent = P.titre || P.nom || '';
    t.style.color = (E.appli && E.appli.id === page && E.appli.couleur) || P.couleur || '';
    $('appli-texte').textContent = P.texte || '';
    const ici = $('btn-appli-ici');
    ici.hidden = !P.bouton_ici;
    ici.textContent = P.bouton_texte || 'Afficher ici';
    $('appli-etat').textContent = '';
    if (P.jauge) montrerJauge(P, P.jauge, false);
    else if (P.ecran_ouvrir) montrerJauge(P, {}, true);
    else arreterJauge();
  }

  // Les Paramètres : la zone, le titre, les onglets (les panneaux sont au bloc « paramètres »)
  function dessinerParametres() {
    const p = E.parametres || {};
    const actif = (etatComplet.parametres && etatComplet.parametres.onglet) || p.actif || 'general';
    $('btn-parametres-menu').hidden = !E.console;
    if (!change('parametres', [p.onglets, actif])) return;
    const hote = $('onglets-parametres');
    hote.replaceChildren();
    for (const o of p.onglets || []) hote.append(bouton(o.texte, o.id === actif ? 'primaire' : 'secondaire', () => act('parametres:onglet', o.id)));
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Les questions : « Êtes-vous sûr ? » (Show-Confirmation) et la croix rouge (bloc « horloge »)
  // ---------------------------------------------------------------------------------------------------------------
  let fermetureVue = null;
  function dessinerQuestions() {
    const q = E.confirmation;
    if (change('confirmation', q)) {
      const v = $('voile-confirmation');
      v.replaceChildren();
      v.hidden = !q;
      if (q) {
        const non = bouton('Annuler', 'secondaire', () => { v.hidden = true; act('ecrans:confirmation', { oui: false }); });
        v.append(h('div', { class: 'question', role: 'dialog', 'aria-modal': 'true' },
          h('div', { class: 'titre' }, q.titre), h('div', { class: 'texte' }, q.texte),
          h('div', { class: 'boutons' }, non, bouton(q.bouton, 'primaire', () => { v.hidden = true; act('ecrans:confirmation', { oui: true }); }))));
        setTimeout(() => non.focus(), 0);   // (Entrée par erreur = Annuler)
      }
    }
    const f = !!(etatComplet.fermeture && etatComplet.fermeture.visible);
    if (f !== fermetureVue) {
      fermetureVue = f;
      const v = $('voile-fermeture');
      v.replaceChildren();
      v.hidden = !f;
      if (f) {
        let souvenir = false;
        const c = caseACocher('Ne plus me demander (modifiable dans Paramètres)', false, (x) => { souvenir = !souvenir; x.classList.toggle('oui', souvenir); });
        const choix = (quoi) => () => act('horloge:fermeture', { choix: quoi, souvenir });
        v.append(h('div', { class: 'question fermeture', role: 'dialog', 'aria-modal': 'true' },
          h('div', { class: 'titre' }, 'Fermer Mindset ?'),
          h('div', { class: 'texte' }, "Réduit près de l'horloge, Mindset et tes applis restent prêts : un clic sur son icône le rouvre. Quitter ferme aussi toutes tes applis (les rappels d'Evermind, par exemple, ne sonneront plus jusqu'à la réouverture)."),
          c,
          h('div', { class: 'boutons' }, bouton('Annuler', 'secondaire', choix('annuler')), bouton('Tout quitter', 'secondaire', choix('quitter')), bouton("Réduire près de l'horloge", 'primaire', choix('reduire')))));
      }
      act('ecrans:voile-fermeture', { visible: f });
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Quelle page montrer (Show-Page, Update-PageConsole, Set-NavigationConsole)
  // ---------------------------------------------------------------------------------------------------------------
  function naviguer() {
    const console = !!E.console;
    $('en-tete').hidden = console;
    $('corps').classList.toggle('sans-onglets', console);
    if (logo) for (const a of logo.anims) if (a) { if (console) a.pause(); else if (a.playState === 'paused') a.play(); }
    const accueil = page === 'accueil';
    $('page-console').hidden = !(accueil && console);
    $('page-accueil').hidden = !(accueil && !console);
    $('page-parametres').hidden = page !== 'parametres';
    $('page-appli').hidden = accueil || page === 'parametres';
    marquerOnglet();
    C.zone();
  }

  // Échap : retour au menu de la console, depuis une appli ou les Paramètres (sauf une question ouverte)
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || !E || !E.console || page === 'accueil') return;
    if (!$('voile-confirmation').hidden || !$('voile-fermeture').hidden) return;
    e.preventDefault();
    act('ecrans:menu');
  });
  $('btn-actualiser').addEventListener('click', () => act('ecrans:actualiser'));
  $('btn-appli-ici').addEventListener('click', () => { $('btn-appli-ici').hidden = true; act('accrochage:ouvrir-ici', page); });
  $('btn-appli-fermer').addEventListener('click', () => act('accrochage:fermer'));
  for (const id of ['btn-appli-menu', 'btn-barre-menu', 'btn-parametres-menu']) {
    const b = $(id);
    const svg = s('svg', { viewBox: '0 0 24 24', width: 18, height: 18 });
    const chemin = s('path', { d: 'M3,10.5 L12,3 L21,10.5 M5,9 L5,20 L10,20 L10,14 L14,14 L14,20 L19,20 L19,9', fill: 'none', stroke: 'rgb(var(--c-00E5FF))', 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' });
    svg.append(chemin);
    b.append(svg, h('span', { class: 'texte' }, 'Menu'));
    b.addEventListener('click', () => act('ecrans:menu'));
  }

  // Police pixel partout : toutes les tailles en tailles « pixel exactes » (8, 12, 16 ou 24), vérifiées 3 fois par
  // seconde au plus (Update-TaillesPixel)
  const taillePixel = (x) => (x < 15 ? 8 : x < 21 ? 12 : x < 30 ? 16 : 24);
  setInterval(() => {
    if (!pixel || !pixelAFaire || document.visibilityState !== 'visible') return;
    pixelAFaire = false;
    for (const el of document.querySelectorAll('#fenetre *')) {
      if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) continue;
      const t = parseFloat(getComputedStyle(el).fontSize);
      if (![8, 12, 16, 24].includes(t)) el.style.fontSize = `${taillePixel(t)}px`;
    }
  }, 350);

  C.surEtat((etat) => { if (!fige) dessiner(etat); });

  // Construction d'essai seulement (captures de l'appli : rust/mindset-ecrans/outils) : dessiner un état donné et ne
  // plus suivre celui de l'appli. Sans effet sur ce que fait Mindset (aucun geste n'est envoyé).
  window.ecrans = Object.freeze({
    figer(etat, immobile) {
      fige = true;
      if (immobile) IMMOBILE = true;
      for (const k of Object.keys(deja)) delete deja[k];
      fermetureVue = null;
      dessiner(etat);
    },
  });
})();
