# Bloc « écrans » : différences avec la version PowerShell

Référence : `Mindset/fichiers/modules/interface.xaml`, `interface.ps1`, `accueil.ps1`, `chargement.ps1`, `logo.ps1`,
`packs.ps1` (partie dessin), `themes.ps1` (traduction des couleurs), version 2.18.0.
Preuves : juges `tests/juges/*.json` (exportés de la vraie fenêtre WPF par `outils/exporter-juges-ecrans.ps1`) et
captures avant / après dans `D:\Outils\Rust\essais\ecrans\captures\` (outils `outils/captures-avant.ps1`,
`outils/captures-apres.ps1`, `outils/comparer-captures.ps1`).

## Différences voulues (ou imposées par l'architecture)

1. **La boîte « choisir un dossier »** (`Select-DossierAppli`) : `IFileOpenDialog` avec `FOS_PICKFOLDERS` (la boîte
   moderne de Windows) au lieu de `System.Windows.Forms.FolderBrowserDialog` (l'ancienne boîte en arbre). Le texte
   « Le dossier de X (celui qui contient X.exe) » devient le titre de la boîte. Ouverte dans un travail de fond,
   posée sur la fenêtre de Mindset ; jamais en essai.
2. **Le message « ce dossier ne contient pas X »** (`Stop-Operation`, bloc installations en PowerShell) est gardé par
   ce bloc sur la carte (il ne peut pas écrire la clé `messages` du bloc installations) ; il s'efface au clic suivant
   sur la carte ou à la fin d'une opération sur cette appli.
3. **La question de la croix** est dessinée par ce bloc ; la page lui dit qu'elle est montrée
   (`ecrans:voile-fermeture`) pour que `voile` (l'appli accrochée s'efface) la compte, comme `Update-HotesVisibles`.
4. **Les textes d'etat.json** sont coupés à 80 unités UTF-16 comme `Substring(0, 80)` ; si la coupe tombe au milieu
   d'un caractère hors du plan de base (un émoji), le demi-caractère devient « � » au lieu d'un demi-caractère
   invalide.
5. **Un objet JSON là où un texte est attendu** dans etat.json : texte vide (PowerShell écrivait « @{...} »).
6. **Un nombre écrit en notation scientifique** dans etat.json (« 7.5e1 ») : refusé comme un nombre à virgule.

## Écarts de rendu restants (captures comparées à l'œil et au pixel)

1. **Taille de la fenêtre** : la fenêtre Tauri fait 1340 x 930 À L'INTÉRIEUR (fenetre.rs, hôte), la fenêtre WPF
   1340 x 930 cadre compris (intérieur 1324 x 891). Tout est à la même place depuis le coin haut gauche, mais la
   page Rust avait 16 px de plus en largeur et 39 px en hauteur. Corrigé à l'intégration (07/11) : l'hôte compte la
   taille cadre compris comme WPF (fenetre.rs, `taille_interieure`) ; mesuré : 1340 x 930 cadre compris, 1324 x 891
   à l'intérieur, comme la 2.18.
2. **Le texte paraît un peu plus gras** dans les captures : même police et mêmes instances (Segoe UI Variable Text
   Semibold, vérifié par `GlyphTypeface`), mais la capture WPF (`RenderTargetBitmap`) est en niveaux de gris et
   celle de WebView2 en ClearType. À l'écran, les deux sont en ClearType.
3. **Thème Terminal** : WPF arrondit la largeur des lettres de Cascadia Code (`TextFormattingMode Display`) ; la
   page serre les lettres de 2 % pour garder la même place (sinon une pastille passait à la ligne). Il reste une
   coupure de ligne différente (« Aujourd'hui 07:15 » tient sur une ligne au lieu de deux).
4. **Les lueurs du fond** : mêmes couleurs à 1 à 5 unités près (mesuré), avec de légers paliers visibles dans les
   grands dégradés (WebView2 ne les lisse pas comme WPF).
5. **Les flous des lueurs** (`DropShadowEffect` en `drop-shadow`) : rayon ajusté à l'œil, pas au pixel.
6. **La barre de défilement** : celle de WebView2 (fine, sombre) au lieu de la barre claire de WPF.
7. **Les cases à cocher et boutons ronds** (bienvenue, croix) : dessinés en CSS au plus près du style de base de
   WPF (carré blanc et coche sombre, rond blanc et point sombre).
8. **La lettre en police** d'une appli sans tracé (`Get-LettreTexte`) : centrée par la ligne de base de la police
   (SVG), au lieu du cadre exact du glyphe ; un ou deux pixels d'écart possibles.
9. **Les captures de la version PowerShell en test** n'ont rien sur la page d'une appli pas installée
   (`MINDSET_PAGE=mindcare` : `Show-Page` y est appelé avant le chargement d'integration.ps1) ; le vrai Mindset y
   écrit « Mindcare n'est pas installé. », ce que fait la page Rust.

## Ce qui attend d'autres blocs (formes supposées, à confirmer à l'intégration)

- `pages_applis[id].jauge.depuis_ms` : lu comme un moment en millisecondes depuis 1970 s'il dépasse 10^12, sinon
  comme « il y a tant de millisecondes » à la réception de l'état.
- `bienvenue.coche` (facultatif) : la lettre du disque coché au départ (sinon celui à lettre vide, C:).
- `parametres.onglet` ou `onglet-parametres` : l'onglet actif des Paramètres ; les panneaux vont dans
  `#parametres-panneaux` (bloc paramètres).
- `theme.couleurs` (bloc paramètres) : prise en premier ; toute couleur absente est traduite ici par la même règle
  (`suite_commun::themes`), à partir de `theme.id` (ou de suite.json tant que `theme` n'est pas publié).
- Le dossier du thème personnalisé pour `http://pack.localhost/` (`Effet::DossierPack`) est donné par le bloc
  paramètres ; ce bloc ne sert lui-même (`Effet::Exposer`, nom `jauge-pack`) que le personnage de jauge trouvé
  seulement dans le pack de Nevermind.
