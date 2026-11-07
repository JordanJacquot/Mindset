# mindset-console : différences voulues avec la version PowerShell

Chaque différence est voulue et dite ici, avec sa raison et sa preuve (règle du brief du 07/11/2026). La référence est
`Mindset/fichiers/modules/console.ps1` et `Mindset/fichiers/console/scene.html` (version 2.18.0). Les juges
(`tests/juges/*.json`, exportés par `outils/exporter-juges-console.ps1` depuis les vraies fonctions PowerShell) passent
tous ; les seules différences acceptées par `tests/juges.rs` sont celles de ce tableau.

## La correction voulue : au plus 60 images par seconde

| Version PowerShell | Version Rust | Pourquoi, et la preuve |
|---|---|---|
| La boucle 3D (`renderer.setAnimationLoop(image)`) est appelée à chaque rafraîchissement de l'écran ; au repos elle ne dessine que 30 images par seconde, mais pendant une animation (cartouche, zoom, menu, ouverture) ou quand la scène est « occupée », elle dessine à chaque rafraîchissement | `image(maintenant)` saute l'image si moins de 1/60 s s'est écoulée depuis la dernière (`PAS_IMAGE = 1000 / 60`, le même calcul que Nevermind 2.0.1, `nevermind-appli/ui/plasma.js`) ; le repos à 30 images par seconde ne change pas | l'écran de Jordan est à 360 Hz : sans limite, la 3D était redessinée 360 fois par seconde pendant chaque animation, pour le même rendu à l'oeil (mesuré sur Nevermind le 06/11/2026 : environ 150 % d'un cœur). Gardé par `tests/scene.rs` (`la_boucle_3d_est_limitee_a_60_images_par_seconde`), contre-épreuve faite (sans le saut, le test échoue) |
| Le carrousel du menu en grand (`requestAnimationFrame(boucleCarrousel)`) avance à chaque rafraîchissement de l'écran | il avance au plus 60 fois par seconde (même saut) | même raison. Effet visible : sur un écran à 360 Hz, le carrousel glissait 6 fois plus vite qu'à 60 Hz (la même fraction du chemin à chaque image) ; il glisse maintenant à la vitesse prévue, celle d'un écran à 60 Hz, quel que soit l'écran |
| Les 8 animations CSS sans fin `linear infinite` (anneau de chargement, rouages, bascules, barres « coule », chargement qui tourne) avancent en continu, donc à chaque rafraîchissement | elles avancent par pas, `steps(n)` avec n = 60 x la durée (au plus 60 pas par seconde) | le même mouvement à l'oeil, 6 fois moins de travail sur un écran à 360 Hz (comme `nevermind-appli/tests/animations.rs`). Gardé par `les_animations_sans_fin_avancent_par_pas`, contre-épreuve faite |

## Les changements permis par l'architecture (bloc 7), et seulement ceux-là

`tests/scene.rs` (`seulement_les_changements_permis`) refait scene.html à partir de celui de la version PowerShell avec
la liste exacte de ces changements : tout autre écart fait échouer le test.

| Version PowerShell | Version Rust | Pourquoi |
|---|---|---|
| `hote()` : `window.chrome.webview.postMessage(...)` | `window.parent.postMessage(..., 'http://tauri.localhost')` ; console.js ne prend que les messages de son cadre et de cette origine | règle 1 de regles-tauri.md : seul ipc.js parle à Rust ; la scène est un cadre de la page |
| Logos tirés des applis : `https://applogos.mindset.local/<id>.png` (servis par `WebResourceRequested`) | `http://fichier.localhost/console-logo-<id>.png` (servis par l'hôte, `Effet::Exposer`) | plus de WebView2 à part : le protocole `fichier` de l'hôte. Le nom porte « console-logo- » pour ne pas gêner les autres blocs |
| Images du thème perso : `https://theme.mindset.local/<nom>` (seulement les fichiers nommés par `Get-ThemeConsole`) | `http://pack.localhost/<nom>` (le protocole `pack` de l'hôte : seulement les images et polices du dossier du pack) | même raison ; `crossOrigin` est posé pour ces deux adresses (l'hôte répond avec `Access-Control-Allow-Origin`) |

## Ce qui n'a plus lieu d'être, ou qui passe ailleurs

| Version PowerShell | Version Rust | Pourquoi |
|---|---|---|
| `Test-ConsolePossible` : la console demande les DLL de WebView2, la scène sur le disque, WebView2 installé ; en test automatique elle est coupée | seulement le réglage « Animations : aucune » | la page de Mindset est déjà une WebView2 (Tauri) ; la scène est rangée dans l'exe. Le texte `AnimationsInfo` (« La console 3D ne peut pas s'afficher sur ce PC... ») ne peut donc plus apparaître |
| `Test-DossierWebviewEcrivable`, le dossier WebView2 commun avec Nevermind et son repli `console-webview` (console.ps1:51-147) | rien | une seule WebView2 pour toute la fenêtre (mindset-appli/DIVERGENCES.md) |
| `New-VueConsole` / `Remove-VueConsole` : un contrôle WebView2 créé puis détruit | le cadre `<iframe>` créé et retiré par console.js d'après l'état `console.cadre` ; son adresse porte en plus `&n=<numéro>` (le numéro du cadre, ignoré par la scène) | un cadre retiré libère toute sa 3D, comme la vue détruite ; le numéro fait qu'un nouveau cadre est toujours un nouveau chargement, et qu'un « pret » d'un ancien cadre est ignoré |
| `DefaultBackgroundColor` de la vue (`#07060D` dans le thème) | le fond du cadre (`console.fond`) | pas d'éclair blanc à l'allumage, pareil |
| `Invoke-ScriptConsole "window.mindset.etat($json)"`, `majAuto`, `reglages` (toutes les 1,5 s, seulement si le texte a changé ; `-Force` après un geste) | l'état part dans l'état de la page (`console.etat`, `console.maj`, et `parametres` du bloc paramètres) ; console.js le donne à la scène quand il a changé ; `console.envoi` augmente pour tout renvoyer (`-Force`) | l'hôte n'envoie l'état que s'il a changé : même économie, et la page rechargée retrouve tout. Les autres appels (`pause`, `reprendre`, `jouerOuverture`, `avancee`...) restent des ordres (`Effet::Ordre { kit: 'console', appel, args }`) |
| `Update-PageConsole` joue `window.mindset.reglages($etat, '<onglet>', instant, $images)` | l'ordre `reglagesOuvrir { onglet, instant }` : console.js y met l'état du bloc paramètres et ses images (`parametres.images_themes`) | l'état des Paramètres appartient au bloc paramètres |
| `Get-EtatParametres`, `Invoke-ReglageConsole`, `Get-ImagesThemesConsole`, `Update-AppareilsConsole` (parametres.ps1) | au bloc paramètres : la console lui passe chaque geste (`Effet::Action { id: "parametres:reglage" }`) | une clé, un bloc |
| `Confirm-MiseAJour`, `Confirm-PriseEnCharge`, `Start-InstallAppli` appelés par la console | `Effet::Action { id: "ecrans:carte", valeur: { id, quoi: maj \| prendre \| installer } }` : le bloc écrans pose la question, comme pour les cartes | architecture, bloc 7 |
| `Show-Page 'parametres'` avec la console : `Open-ParametresConsole`, la page reste celle d'avant | la page passe un instant à « parametres » (le signal `page` arrive à tous les blocs), puis la console demande `Effet::Page("accueil")` et ouvre les Paramètres dans son écran, dans le même tour (rien n'est dessiné entre les deux) | la page est changée par l'hôte avant que la console ne la voie |
| `Set-ReglageAnimations` écrit le réglage | le bloc paramètres l'écrit et envoie `reglage-change { nom: "Animations" }` ; la console fait le reste (s'éteint, se rallume, change de vitesse, et la page des Paramètres d'avant sur Apparence quand la 3D s'éteint) | le réglage appartient au bloc paramètres |
| `Receive-IncidentConsole` sur `ProcessFailed` de la vue de la console | même logique (`BlocConsole::incident`, juges `incidents.json`), atteinte par l'action `console:incident` (le genre en texte) | un processus de rendu arrêté touche maintenant toute la page (architecture 7.5) : l'hôte suit `ProcessFailed` de la page (intégration du 07/11, webview2.rs) : il rouvre la page si c'est le processus qui la dessine (arrêté ou qui ne répond plus), puis envoie `console:incident` avec le nom .NET du genre |
| `Start-CaptureConsole` (essai : `CapturePreviewAsync` de la vue) | rien | la capture de la fenêtre de l'hôte voit la 3D (essai : `capture.demande`) |
| `Get-AvanceeOuverture` : une durée d'ouverture illisible dans les réglages (« abc ») fait lever une erreur à chaque passage (la barre ne bouge plus) | la durée par défaut (8 s) | une erreur dans une minuterie n'a rien de voulu ; le juge `regles.json` note « erreur » pour ces cas et le test vérifie la valeur à 8 s |
| `Write-Log "Console 3D : WebView2 $v"` et les lignes du dossier WebView2 | plus écrites | plus de WebView2 propre à la console |

## Les lectures dans le tableau commun

Les variables `$script:` des autres modules sont lues dans le tableau commun (`mindset_noyau::partage`) ; deux formes
sont supposées et dites ici pour l'intégration :
- `maj-auto.essais` : `{ <id>: { version, quand (format s), nombre } }` (`$script:MajAutoEssais`), pour « prête » au lieu
  de « en attente » après un essai récent sans échec, et pour `reessai` (le champ `echecs.<id>.reessai` n'est pas lu : il
  est recalculé ici à l'heure du moment, comme `Get-MajAutoReessai`) ;
- `mindset.maj` : `prete` vrai = `$script:MajMindset` ; `en_cours` = `$script:MajMindsetEnCours` ; `progres` non nul
  (avec `version`) = le téléchargement de cette version (`$script:ProgresMindset`), nul pendant `en_cours` = la
  recherche.
- `occupations.<id>` : `progres` non nul = un téléchargement (`$script:Progres`) ; sinon `quoi = "installation"` = une
  installation (`$script:EnCours`, sa `version`).

## La mesure (07/11/2026, construction d'essai sur un bureau à part, écran à 350-360 images par seconde)

Processeur de Mindset.exe et de ses WebView2 (en % d'un cœur), 30 s chacune, trois essais par version, en alternance.
Sans appli installée (la liste est encore vide) ; « animations » : le menu en grand ouvert puis refermé toutes les 2,5 s.

| | au repos | pendant les animations | dont la page (renderer) en animation |
|---|---|---|---|
| sans la limite (avant) | 22,9 / 26,7 / 27,3 | 18,2 / 27,8 / 27,2 | 4,5 / 13,6 / 13,8 |
| avec la limite (après) | 29,0 / 20,8 / 25,1 | 30,7 / 16,5 / 18,4 | 12,0 / 3,9 / 4,2 |

Au repos : pas de différence nette (la scène dessinait déjà 30 images par seconde au repos ; les écarts viennent surtout
de la carte graphique, très variable). Pendant les animations : la page passe d'environ 13,7 % à environ 4 % sur deux
essais sur trois (le premier essai « après » est à part, à refaire), et le total de 27 % à 17-18 %. Mesure bruitée et
sans les applis : à refaire à l'intégration, avec la liste et les cartouches.
