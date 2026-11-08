# Bloc « accrochage » : ce qui diffère de la version PowerShell, et pourquoi

Référence : `Mindset/fichiers/modules/integration.ps1`, `MSIntegration` de `Mindset/fichiers/modules/natif.cs`, et les
états de `Mindset/fichiers/modules/chargement.ps1`. Tout le reste est fait à l'identique, et jugé sur les cas exportés
de la version PowerShell (`outils/exporter-juges-accrochage.ps1`, `tests/juges/accrochage.json`, `tests/juges.rs`).

## 1. La taille de la zone avant la toute première page d'appli

- **Avant** : le panneau Windows Forms avait déjà sa taille (la mise en page WPF est faite à l'avance) ; la première
  accroche se faisait directement à la taille de la zone.
- **Maintenant** : la coquille ne mesure `#zone-appli` que lorsqu'elle est montrée. Si une appli s'accroche avant que
  sa page ait été montrée une seule fois depuis le lancement, elle est accrochée à 200 x 200 (comme un panneau sans
  taille de la version PowerShell), puis redimensionnée dès que la zone arrive, dans le même passage. Ensuite la taille
  est connue : le bloc la garde, et la page d'une appli montrée la reprend tout de suite (signal `page`).
- **Preuve** : les juges acceptent ce cas et SEULEMENT lui (`normaliser` de `tests/juges.rs`, quand aucune zone n'a
  encore été envoyée au bloc) : « accrocher h 200x200 » suivi de « redimensionner h L x H » vaut « accrocher h L x H ».
  Sans effet visible : le panneau est posé sur la zone, la fenêtre de l'appli prend sa taille aussitôt.

## 2. L'ordre des fenêtres rendues quand Mindset quitte

- **Avant** : `Disconnect-Applis` parcourt `$script:Integrees.Values`, une table de hachage, sans ordre fixe.
- **Maintenant** : dans l'ordre où les applis ont été ouvertes. Les juges comparent l'ensemble des fenêtres rendues.

## 3. Une zone sans taille est ignorée

- **Avant** : WPF ne refaisait pas la mise en page quand Mindset était réduit dans la barre des tâches.
- **Maintenant** : la page peut envoyer une zone de 0 x 0 (Mindset réduit, ou la page de l'appli repliée) : elle est
  ignorée, l'appli garde sa place et sa taille (essai du 26/10 : « ignorer la taille 0 pendant la réduction »). C'est le
  signal `page` qui dit si la zone est à l'écran.

## 4. Une appli figée n'est pas accrochée tant qu'elle ne répond pas

- **Avant** : `Accrocher` appelait `SetWindowLongPtr` et `SetParent` sur la fenêtre de l'appli sans précaution : une
  appli figée bloquait Mindset.
- **Maintenant** : avant d'accrocher, un message vide (`SendMessageTimeout`, 1 s, `SMTO_ABORTIFHUNG`) ; sans réponse,
  l'appli n'est pas accrochée à ce passage (la surveillance réessaie 400 ms plus tard). Les tailles demandées à l'appli
  ne l'attendent pas (`SWP_ASYNCWINDOWPOS`) ; « Fermer » est posté (`PostMessage`), comme avant. Architecture 7.1.
- **Preuve** : `une_appli_figee_ou_sans_fenetre_de_mindset_attend` (src/tests.rs). Pas dans les juges : la version
  PowerShell n'a pas de cas « figée ».

## 5. Une fenêtre cachée en taille normale n'est plus montrée hors de Mindset pendant l'accroche

- **Avant** : `Accrocher` commençait par `ShowWindow(SW_RESTORE)`, qui MONTRE et ACTIVE une fenêtre cachée (une appli
  lancée avec `-Demarrage`) : elle pouvait passer un instant en fenêtre normale, et prendre la main, juste avant d'être
  accrochée. Refusée par Windows, elle restait même montrée hors de Mindset.
- **Maintenant** : `SW_RESTORE` seulement si elle est réduite ou agrandie (ce que voulait le commentaire : « ni
  réduite, ni agrandie »). Le reste est identique : `WS_VISIBLE` est posé par les nouveaux styles, et l'appli se montre
  d'elle-même une fois accrochée (contrat-appli.md, partie 7).
- **Preuve** : `accrochage_refuse_quand_le_panneau_n_existe_pas` (src/windows/tests.rs : refusée, ses styles d'avant
  sont remis, rien n'est montré) ; l'essai réel (Forêt, WPF, lancée cachée, se montre elle-même une fois accrochée).

## 6. L'arrêt d'un programme bloqué est un travail de fond

- **Avant** : `Stop-AppliBloquee` arrêtait le programme et attendait sa fin (jusqu'à 3 s) sur le fil de l'écran, puis
  relançait l'appli.
- **Maintenant** : la décision (quels programmes : plus d'une minute, sans fenêtre, dans son dossier) est prise sur le
  fil des blocs, l'arrêt et l'attente de 3 s se font dans un travail de fond, et la relance à sa fin (même journal).
  Différence : si Windows refuse TOUS les arrêts, la limite d'attente (15 ou 60 s) est vérifiée au passage suivant,
  400 ms plus tard, au lieu du même passage.
- **Preuve** : les juges (« un programme bloqué sans fenêtre : arrêté puis relancé », et les scénarios au hasard), où le
  travail de fond est rejoué tout de suite ; `un_arret_refuse_est_note_et_la_fin_rend_tout` (src/tests.rs).

## 7. Le panneau est une fenêtre de Mindset tenue par son propre fil

- **Avant** : un `Panel` Windows Forms dans un `WindowsFormsHost`, sur le fil de l'écran WPF.
- **Maintenant** : un panneau noir (classe « MindsetAccrochage ») dans la fenêtre Tauri, créé et tenu par un fil du
  bloc qui ne fait que tourner sa boucle de messages (le fil des blocs n'en a pas : une fenêtre sans boucle bloquerait le
  clavier de Mindset et de l'appli, que Windows relie). Mêmes règles : l'appli est l'enfant du panneau, cacher l'appli
  c'est cacher le panneau (son drapeau `WS_VISIBLE` à elle ne change pas, la surveillance le lit toujours), sa taille
  suit le panneau. En plus, à chaque fois qu'il est montré : `WS_CLIPCHILDREN` sur la fenêtre de Mindset,
  `WS_CLIPSIBLINGS` sur chacun de ses enfants directs (la page `WRY_WEBVIEW` comprise), le panneau devant, tout
  redessiné (le piège du 26/10 : sans cela, l'appli est dessinée SOUS la page). Le focus est donné par ce fil (relié à
  celui de l'appli), le panneau renvoie le focus qu'il reçoit à l'appli.
- **Preuve** : `accrocher_dans_le_panneau_par_dessus_la_page_puis_rendre` (src/windows/tests.rs, vraies fenêtres sur un
  bureau à part) et l'essai réel (`outils/essai-accrochage.ps1`), vérifié sur l'image de la fenêtre de Mindset.

## 8. Ce que le bloc publie en plus

- `accrochees` porte aussi `fenetre` (le numéro de la fenêtre accrochée, ou null) : la console en a besoin pour savoir
  si l'appli est prête (`$script:Integrees[$id].Fenetre` dans console.ps1:614-615).
- `pages_applis` donne l'état de la page de chaque appli : les textes ne changent que pour la page montrée (comme les
  éléments uniques de l'écran WPF), la jauge et l'écran « Ouvrir » ne vont qu'à la page de leur appli.

## 9. L'appli montrée qui se cache elle-même ramène Mindset à l'accueil

- **Avant** : l'appli de la page qui se cachait (sa croix : « Quitter » ou « Réduire ») était rendue, et sa page
  montrait l'écran « Nevermind est réduit près de l'horloge. » avec « Ouvrir Nevermind ». Jordan, le 08/11/2026 à
  19:53 : il ferme Nevermind par sa croix, répond « Quitter », et la place de Nevermind reste noire ; il doit tout
  quitter. Il veut que Mindset revienne tout de suite au menu (l'accueil, avec la console).
- **Maintenant** : au passage suivant de la surveillance (400 ms au plus), sa place est effacée, sa fenêtre lui est
  rendue sans l'attendre (une appli qui quitte ne traite plus ses messages : `liberer_sans_attendre`, que Mindset qui
  quitte attend encore, `ATTENTE_FIN`), et si c'était l'appli montrée, Mindset revient à l'accueil (journal :
  « Nevermind fermé ou réduit dans Mindset : retour à l'accueil »). Pareil quand la fenêtre de l'appli montrée disparaît
  (elle quitte sans se cacher d'abord) : l'accueil au lieu de l'écran « Nevermind est fermé. » ; si un nouveau
  programme de l'appli arrive (relance), sa fenêtre est raccrochée comme avant, sans être montrée. Pas pendant une
  opération de Mindset sur l'appli (une occupation : mise à jour, installation) : l'écran de sa page reste, comme
  avant. Une appli cachée ou fermée hors de sa page : comme avant. (Une relance pour un nouveau thème se fait depuis
  les Paramètres de Mindset : la page n'est pas celle de l'appli.)
- **Preuve** : `cachee_elle_meme_dans_sa_page_retour_a_l_accueil` (src/tests.rs),
  `mindset-appli/tests/fermeture_par_l_appli.rs` (tous les vrais blocs : accueil et console rallumée en moins d'une
  seconde ; échouait avant) et l'essai réel sur un bureau à part (Nevermind accroché, sa croix, « Quitter »). Les juges
  de la version PowerShell sont rejoués avec ce point coupé (`sans_retour_accueil`).

## Ce que la version PowerShell avait et qui n'est pas ici

- `Write-DemandeQuitter` et `Request-FermetureApplis` : au bloc « installations » (architecture, bloc 6). Le bloc envoie
  `demande-quitter` (fermer-appli d'une appli ouverte mais pas accrochée).
- Le dessin de la jauge et de l'écran « Ouvrir » (anneau, personnage du thème) : au bloc « écrans », avec
  `jauge.depuis_ms` et `jauge.duree_s` (la formule d'`Update-JaugeAppli` : 90 % à la durée habituelle en ralentissant,
  puis vers 99 %).
- `MSIntegration.Detacher` et `EstEnfantDe` : jamais appelés par la version PowerShell (seulement par ses tests).

## Limites connues (à l'intégration)

- **L'échelle** : la zone est en pixels de l'écran (la coquille multiplie par `devicePixelRatio`) ; le panneau et
  l'appli sont posés au pixel près. Une fenêtre enfant d'un autre programme ne reçoit pas `WM_DPICHANGED` : si Mindset
  passe sur un écran d'une autre échelle, l'appli garde son échelle à elle (comme avec Mindset 2.18).
- **WPF sur l'image d'un bureau à part** : le dessin de WPF (Evermind) ne se lit pas par `PrintWindow` une fois la
  fenêtre accrochée dans un autre programme, en rendu matériel comme logiciel, et c'est pareil avec le vrai
  `MSIntegration.Accrocher` de Mindset 2.18 (contre-essai fait). L'essai réel prouve pour WPF : trouvée, accrochée, à la
  taille, le focus, effacée sous le voile, redimensionnée, rendue cachée, et la page ne la recouvre pas ; la preuve
  visuelle « par-dessus la page » est faite par une fenêtre `HwndWrapper[...]` peinte par GDI (Café crème) et par
  Nevermind (Tauri). Reste à voir de ses yeux, sur le vrai écran, Evermind accroché dans Mindset 3.0 (comme le 26/10).
