# Contrat entre Mindset et une appli de la suite

Ce document dit tout ce dont Mindset dépend chez une appli de la suite, et ce que l'appli doit faire en retour. Il sert
de référence pour écrire une appli en Rust (plan de passage en Rust, 3.4) et pour l'« appli témoin » qui vérifiera ce
contrat dans les tests.

Il est établi en lisant le code du 26/10/2026 : Mindset 2.14.0 (`Mindset/fichiers/Mindset.ps1:14`) et Nevermind 1.14.2
(`Nevermind: Nevermind/fichiers/Nevermind.ps1:16`). Mis à jour le 27/10/2026 avec l'étape 2 (champ `type`, contrôles
d'apps.json, `version.json`, fenêtre Tauri : parties 1, 2, 7 et 10, marquées **Existe (étape 2)**).

**Vérifié par l'appli témoin.** `temoin\` est une toute petite appli (PowerShell, hôte `Mindset.exe`, relais, désinstalleur,
`version.json`) qui respecte chaque partie de ce contrat ; `outils/tester-contrat.ps1` la construit, l'installe et la
pilote avec le vrai code de Mindset, partie par partie, puis vérifie qu'un témoin cassé exprès (verrou, titre de la
fenêtre, `quitter.demande`, taille minimale, croix, `version.json`) fait échouer le test. Lancé par la CI
(`.github/workflows/tests.yml`) ; la partie 9 (désinstalleur) ne tourne que sur GitHub. Son entrée apps.json :
`temoin/entree-apps.json`.

Comment lire ce document :
- les chemins sont relatifs à la racine du dépôt Mindset ; ceux qui commencent par « Nevermind: » sont relatifs à la
  racine du dépôt Nevermind ;
- **Existe** : ce que fait le code aujourd'hui ;
- **À venir (étape 2)** : ce qui change dans Mindset avant la première appli Rust ;
- **Appli Rust** : ce que l'appli devra faire.

---

## 1. L'entrée dans apps.json

**Existe.** `Mindset/fichiers/apps.json` est livré avec Mindset : une appli n'existe pour Mindset que si elle y figure
(`Mindset/fichiers/modules/applis.ps1:4-5`). Mindset le lit dans `Get-Applis` (`applis.ps1:7-83`) et ignore toute
entrée qui ne passe pas les contrôles (`applis.ps1:18` pour le type, `:37` pour le reste).

| Champ | Obligatoire | Contrôle | Ligne |
|---|---|---|---|
| `id` | oui | `^[a-z0-9-]+$` | `applis.ps1:14`, `:19` |
| `type` | non | `powershell` (la valeur quand il est absent) ou `rust`, avec cette casse ; sinon l'entrée est ignorée | `applis.ps1:15-18` |
| `nom` | oui | non vide ; aussi le nom du dossier de l'appli et le titre de sa fenêtre | `applis.ps1:19` |
| `couleur` | oui | `#RRGGBB` | `applis.ps1:19` |
| `depot` | oui | `propriétaire/dépôt` GitHub | `applis.ps1:20` |
| `zip`, `dossier_zip` | oui | nom de fichier simple | `applis.ps1:20` |
| `exe` | oui | nom de fichier `.exe` | `applis.ps1:21` |
| `script` | oui pour `powershell`, non pour `rust` | `^[\w\\.-]+\.ps1$`, sans `..` (contrôlé aussi pour `rust` s'il est là) | `applis.ps1:22` |
| `mutex` | en pratique | `^Local\\[\w.-]+$` s'il est là (même règle que `ancien_mutex`) | `applis.ps1:24` |
| `afficher_fichier` | non | nom de fichier simple | `applis.ps1:28` |
| `afficher_signal` | non | `^Local\\[\w.-]+$` s'il est là | `applis.ps1:25` |
| `desinstalleur` | non | nom de fichier `.exe` | `applis.ps1:27` |
| `donnees` | en pratique | variables d'environnement développées, aucun autre contrôle | `applis.ps1:71` |
| `admin`, `sans_droits_depuis` | non | version `\d+(\.\d+){1,3}` | `applis.ps1:30`, `74` |
| `aide`, `aide_exe` | non | `<Nom> (aide)` et nom `.exe` | `applis.ps1:29` |
| `cache_depuis` | non | version `\d+(\.\d+){1,3}` s'il est là | `applis.ps1:26` |
| `rappels`, `presentation`, `description`, `confidentialite`, `logo`, `logo_epaisseur` | non | voir les lignes | `applis.ps1:38-47`, `73` |
| `ancien_*` | non | mêmes contrôles que les champs actuels | `applis.ps1:33-36` |

L'objet rendu par `Get-Applis` a une propriété `Type` (`applis.ps1:50`). Les trois entrées d'aujourd'hui n'ont pas de
`type` : elles sont lues exactement comme avant (vérifié par `outils/tester-securite.ps1`, partie « Contrat d'une
appli : ... apps.json »).

Le mini-installateur relit apps.json de son côté, à côté de lui dans le dossier protégé, jamais dans la demande
(`Mindset/fichiers/installer-admin.ps1:213-229`) : il vérifie `nom` (et refuse « Mindset », ligne 221), `exe`,
`dossier_zip` et la partie administrateur, mais **pas** `script` ni `type`. Le désinstalleur de Mindset lit `nom`,
`exe` et `desinstalleur` (voir partie 9).

**Ce qui rejetait une appli sans script, et ce qui a changé à l'étape 2.** Trois endroits :
1. `applis.ps1` : `script` n'est plus obligatoire pour `"type": "rust"` (`applis.ps1:22`) ;
2. `Test-DossierAppli` (`installations.ps1:78-85`) : le script, **ou** `Mindset.exe` et un `version.json` qui nomme
   l'appli (partie 2) ;
3. `Install-Paquet` (`paquets.ps1:306`) : la version vient de `version.json` d'abord (partie 10), la ligne `$AppVersion`
   n'est plus qu'un secours.

**Appli Rust.** Son entrée a `"type": "rust"`, un `mutex` `Local\<Nom>-Instance`, un `afficher_fichier` (sinon
Mindset ne lit pas ses notifications, partie 5), `donnees` (son ancien dossier, ou celui de la suite), et
`desinstalleur` seulement si elle change des réglages de Windows (partie 9). Une appli qui passe de PowerShell à Rust
peut garder son entrée sans `type` pendant la bascule : son dossier Rust est reconnu quand même (partie 2), mais son
entrée doit alors garder `script` (le nom de l'ancien script) tant qu'elle n'a pas `"type": "rust"`.

---

## 2. Test-DossierAppli : « ce dossier contient-il l'appli ? »

**Existe (étape 2).** `installations.ps1:78-85` : il faut le programme `exe`, **et**
- soit le script (`script` ou `ancien_script`, `Get-ScriptAppli`, `installations.ps1:53-60`) : les applis d'aujourd'hui,
  rien n'a changé pour elles ;
- soit `Mindset.exe` **et** un `version.json` lisible dont `appli` est l'`id` de l'entrée (sans tenir compte de la
  casse) : une appli Rust. Un `version.json` sans `appli`, abîmé ou d'une autre appli ne suffit pas.

Ces deux formes sont acceptées quel que soit `type` : pendant la bascule d'une appli de PowerShell à Rust, le dossier
installé peut être de l'une ou de l'autre forme pour la même entrée.

`Get-VersionDans` (`installations.ps1:64-74`), la version installée : `version.json` d'abord (lisible, et `appli` absent
ou égal à l'`id`), sinon la ligne `$AppVersion` du script.

Il sert partout où Mindset décide qu'une appli est installée :
- `Get-Installation` (`installations.ps1:88-104`) : l'installation notée dans installations.json (une installation
  « gérée » n'est crue que dans le dossier protégé), puis la copie gérée oubliée ;
- la recherche d'une copie déjà présente sur le PC (`installations.ps1:153`) ;
- « utiliser cette copie » (`installations.ps1:902`) ; « choisir le dossier » dit ce qui manque, avec `version.json`
  quand l'entrée n'a pas de script (`Mindset/fichiers/modules/accueil.ps1:466`).

Ailleurs, la présence du seul `exe` compte : le zip doit le contenir (`paquets.ps1`, `Install-Paquet`), et la
désinstallation est finie quand il a disparu (`installations.ps1:891`, et le désinstalleur de Mindset, partie 9).

**Appli Rust.** Son dossier contient au moins `Mindset.exe` (son programme), `<exe>` (voir partie 4) et `version.json`
(avec son `appli`).

---

## 3. Le verrou Local\\<Appli>-Instance et Test-AppliOuverte

**Existe.** Le nom vient de `mutex` dans apps.json (`apps.json:14`, `:40`, `:59`). `Test-AppliOuverte`
(`applis.ps1:111-120`) :
- essaie d'ouvrir le verrou (`Mutex.OpenExisting`) ; ouvert : l'appli tourne ;
- refus d'accès (le verrou d'une appli lancée en administrateur) : elle tourne aussi ;
- sinon, il cherche son programme par son chemin (`Get-ProcessusAppli -Hote`, `applis.ps1:90-95`).

Mindset s'en sert pour : ramener l'appli plutôt que la relancer (`installations.ps1:151`), demander sa fermeture
(`integration.ps1:268`, `installations.ps1:498`), et suivre son ouverture (`integration.ps1:85`, `:222`).

Côté appli, Nevermind prend son verrou et l'ancien (`Nevermind: Nevermind/fichiers/Nevermind.ps1:84-110`) : verrou
déjà tenu, il attend 5 s (une version qui se ferme après une mise à jour), puis abandonne.

**Appli Rust.**
- Créer le verrou nommé `Local\<Nom>-Instance` au démarrage (`CreateMutexW`) et le garder jusqu'à la fin du processus.
- Verrou déjà tenu : attendre quelques secondes (relance après une mise à jour), puis, s'il reste tenu, déposer la
  demande d'affichage (partie 5) et quitter sans ouvrir de fenêtre. Lancée avec `-Demarrage` (partie 6), elle quitte
  sans rien déposer : un lancement caché n'a rien à montrer, l'appli déjà ouverte reste comme elle est (décidé par
  Jordan le 29/10).
- Ne jamais garder le processus en vie sans fenêtre après « Quitter » (le bug du 18/10 : Mindset arrête un tel
  processus, `integration.ps1:51-63`).

---

## 4. L'hôte Mindset.exe et les relais

**Existe.**
- `outils/lanceur.cs` est le programme de **Mindset** : il fait tourner `fichiers\Mindset.ps1` dans son propre processus
  (`lanceur.cs:1-3`, `:26-27`), avec le titre « Mindset » (`lanceur.cs:14`), et passe `-Demarrage` au script
  (`lanceur.cs:69-75`).
- Chaque appli a son propre lanceur, compilé lui aussi sous le nom `Mindset.exe` dans **son** dossier : pour Nevermind,
  `Nevermind: outils/lanceur.cs:6-12` et `Nevermind: outils/construire.ps1:5-8`, `:60`. Le titre de l'assembly est
  « Mindset » pour le programme qui tourne (`Nevermind: outils/lanceur.cs:26-31`) : le Gestionnaire des tâches range
  toute la suite sur une seule ligne « Mindset ».
- Mindset ne cherche **jamais** une appli par le nom de son processus, toujours par son chemin
  (`applis.ps1:85-95`, `Mindset/fichiers/modules/natif.cs:642`), et jamais lui-même.
- Il lance `Mindset.exe` du dossier de l'appli, ou `<exe>` pour une ancienne version (`installations.ps1:163-166`).
- Pour que la barre des tâches montre le nom de l'appli, Mindset écrit un raccourci `Mindset\<Nom>.lnk` dans le menu
  Démarrer, vers `Mindset.exe` de l'appli, avec l'identité `JordanJacquot.<Nom>` (`installations.ps1:615-644`,
  `applis.ps1:43`). L'appli se donne la même identité (`Nevermind: Nevermind/fichiers/modules/evenements.ps1:19-25`).
- Le mini-installateur ferme tout ce qui tourne depuis le dossier de l'appli, par le chemin
  (`installer-admin.ps1:391-398`) ; Mindset qui quitte ferme les hôtes encore ouverts après 6 s
  (`Mindset/fichiers/Mindset.ps1:141-156`).

**Le relais.** `Nevermind.exe` est un petit relais : il lance `Mindset.exe` de **son** dossier avec les mêmes arguments,
puis se ferme (`Nevermind: outils/lanceur.cs:82-102`). Il reste pour les anciens Mindset, les anciens raccourcis et les
anciennes tâches.

**Appli Rust.**
- Son programme s'appelle `Mindset.exe`, dans son dossier, avec « Mindset » comme description dans les informations de
  version de l'exe (ce que le Gestionnaire des tâches affiche) : à confirmer avec l'essai jetable 1 de l'étape 0.
- Elle se donne l'identité `JordanJacquot.<Nom>` (sans espaces ni accents, `applis.ps1:43`).
- `<exe>` de apps.json : tant que Mindset s'appuie sur ce fichier (parties 2 et 9), l'appli le livre. Pour une appli
  Rust neuve, c'est un relais Rust minuscule (même règle que celui de Nevermind). Pour Nevermind en Rust (étape 6,
  morceau 5), `Nevermind.exe` reste un relais.
- Les programmes d'aide qu'elle lance depuis son dossier de **données** sont trouvés par leur chemin
  (`applis.ps1:97-105`) et fermés avant une désinstallation (`installations.ps1:818-825`).

---

## 5. Les fichiers échangés

Tous sont dans le dossier de données de l'appli (partie 8), sauf suite.json. Règle commune : l'appli ne fait
**rien** exécuter de ce qu'elle lit, supprime une demande dès qu'elle l'a lue, et écrit ses propres fichiers à côté puis
les renomme (Mindset ne lit jamais un fichier à moitié écrit).

| Fichier | Écrit par | Lu par | Contenu | Quand |
|---|---|---|---|---|
| `quitter.demande` | Mindset | l'appli | le numéro de processus de Mindset (texte) | Mindset quitte pour de bon ; avant une installation ou une mise à jour |
| `afficher.demande` (nom pris dans `afficher_fichier`) | Mindset, ou un second lancement de l'appli | l'appli | un numéro de processus, ou `notif:<12 hex>` | appli déjà ouverte à ramener ; clic sur une bulle |
| `afficher-rdv.demande` | Mindset | Evermind | `<id 32 hex>\|<date au format s>` | clic sur un rendez-vous de l'accueil |
| `notification.demande` | l'appli | Mindset | JSON `{ titre, texte, id }` | l'appli veut montrer une bulle |
| `etat.json` | l'appli | Mindset | le résumé de sa carte (JSON) | quand le résumé change |
| `suite.json` | Mindset (et l'appli pour le thème) | l'appli | thème, micro, casque, applis gérées | à chaque changement |

### quitter.demande
- **Mindset** : `Write-DemandeQuitter` (`integration.ps1:258-265`) l'écrit dans le dossier de données actuel et dans
  l'ancien ; quand Mindset quitte avec les applis (`integration.ps1:266-273`, choix fait dans
  `Mindset/fichiers/modules/interface.ps1:100`), et avant d'installer une mise à jour (`installations.ps1:496-500`).
  Il attend ensuite 6 s puis ferme ce qui tourne encore (`Mindset.ps1:141-156`).
- **Nevermind** : le regarde toutes les 600 ms (`Nevermind: Nevermind/fichiers/modules/evenements.ps1:90-96`,
  `:113-120`), le supprime, et quitte comme par « Quitter », sans question, en laissant 3,5 s à une action en cours
  (`evenements.ps1:44-56`).
- **Appli Rust** : même chose. Le regarder au moins toutes les secondes, quitter en moins de 6 s.

### afficher.demande, ou le signal
- Deux façons de ramener une appli ouverte (`installations.ps1:153-161`) : un signal nommé (`afficher_signal`,
  `Local\<Nom>-Afficher`, Evermind et Mindcare) ou ce fichier (`afficher_fichier`, Nevermind).
- **Mindset** écrit son numéro de processus (`installations.ps1:160`), ou `notif:<id>` après un clic sur une bulle
  (`Mindset/fichiers/modules/zone.ps1:157-167`, ligne 165).
- **Nevermind** l'écrit aussi quand on le relance alors qu'il tourne (`Nevermind: Nevermind/fichiers/Nevermind.ps1:280-290`)
  et le lit (`evenements.ps1:97-110`) : `notif:<id>` n'est accepté que pour un numéro qu'il a lui-même donné ; sinon
  il montre sa fenêtre, **sauf** s'il est affiché dans Mindset.
- **Appli Rust** : utiliser le fichier (`afficher_fichier`), pas seulement le signal, car seul le fichier transporte le
  clic sur une bulle.

### afficher-rdv.demande
- **Mindset** : `Open-RdvEvermind` (`Mindset/fichiers/modules/accueil.ps1:288-296`), seulement pour Evermind, avec un
  identifiant de 32 chiffres hexadécimaux vérifié (ligne 292).
- **Evermind** le lit : son code n'a pas été relu pour ce document (voir « Doutes »).
- **Appli Rust** : seulement Evermind en Rust (étape 5).

### notification.demande
- **L'appli** l'écrit : Nevermind, une bulle à la fois, au moins 6 s d'écart, écrite à côté puis renommée, abandonnée
  après 5 minutes (`Nevermind: Nevermind/fichiers/modules/assistance.ps1:387-425`).
- **Mindset** le lit toutes les 2 s (`zone.ps1:169-174`) dans `Watch-NotificationsApplis` (`zone.ps1:132-148`) :
  **seulement pour les applis qui ont `afficher_fichier`** (ligne 133), moins de 8 Ko, supprimé après lecture, titre
  coupé à 63 caractères, texte à 250, `id` accepté seulement s'il fait 12 chiffres hexadécimaux.
- **Appli Rust** : mêmes règles d'écriture que Nevermind. Pas d'icône à elle près de l'horloge quand Mindset la gère
  (`zone.ps1:126`).

### etat.json
- **Mindset** : `Get-EtatAppli` (`accueil.ps1:142-181`) : 32 Ko au plus, relu quand sa date change, textes nettoyés et
  coupés à 80 caractères, seulement affiché. Format de Nevermind (ligne 162-163), d'Evermind (164-171), et un **format
  commun** pour toute autre appli (172-177) :
  `{ "Titre": "...", "Scores": [ { "Nom": "...", "Valeur": 0..100 } ], "Lignes": [ { "Texte": "...", "Etat": "ok|info|attention|urgent" } ] }`,
  2 scores et 3 lignes au plus.
- **Nevermind** l'écrit en UTF-8 sans BOM, seulement quand il change (`Nevermind: Nevermind/fichiers/modules/navigation.ps1:62-78`).
- **Appli Rust** : le format commun (sauf Nevermind et Evermind, qui gardent le leur), UTF-8 sans BOM.

### suite.json
- Toujours `%LOCALAPPDATA%\Mindset\suite.json`, où que soit installée la suite (`Mindset/fichiers/modules/suite.ps1:15`,
  `Mindset/fichiers/modules/donnees.ps1:8-10`).
- **Mindset** l'écrit (`suite.ps1:41-52`) : `theme`, `micro`, `casque`, `applis` (`{ id: dossier }`), `modifie` ;
  écrit à côté puis remplacé, avec une copie `.bak`.
- **Les applis** le lisent : Nevermind pour trouver son dossier de données
  (`Nevermind: outils/lanceur.cs:52-69`) et suivre le thème toutes les 2,5 s, en ne regardant que la date du fichier,
  sans relance pendant une partie (`Nevermind: Nevermind/fichiers/modules/evenements.ps1:133-169`). Une appli peut y
  écrire le thème (`Nevermind: Nevermind/fichiers/modules/themes.ps1:164-166`).
- Sécurité (`suite.ps1:11-12`) : n'importe quel programme peut modifier ce fichier ; on n'y accepte qu'un thème connu,
  et un dossier n'y sert qu'à **comparer** avec le sien.
- **Appli Rust** : mêmes règles ; la lecture et l'écriture sûres viennent de `suite-commun`.

---

## 6. Le lancement caché -Demarrage

**Existe.** Mindset lance l'appli avec `-Demarrage` (`installations.ps1:171-175`) :
- au démarrage de Mindset, pour les applis « S'ouvre avec Mindset » (`Mindset/fichiers/modules/mindset.ps1:159-179`,
  ligne 177) ;
- pour l'afficher dans sa fenêtre, si sa version est au moins `cache_depuis` (`Start-AppliCachee`,
  `Mindset/fichiers/modules/integration.ps1:43-49`) ; sinon il la lance normalement ;
- après une mise à jour, si elle tournait (`installations.ps1:721`).

Un Mindset administrateur lance une appli sans droits avec le jeton de l'Explorateur (`natif.cs:157`,
`installations.ps1:171`). Si l'appli tourne déjà, `-Demarrage` ne fait rien (`installations.ps1:152`).

Côté Nevermind : `-Demarrage` est un paramètre du script (`Nevermind: Nevermind/fichiers/Nevermind.ps1:13`), transmis
par le lanceur (`Nevermind: outils/lanceur.cs:156-159`, `:184`) ; la fenêtre se prépare cachée
(`Nevermind.ps1:463`), puis se montre sans prendre la main quand Mindset l'accroche (`evenements.ps1:72-80`).

**Appli Rust.**
- Accepter `-Demarrage` (aussi `/Demarrage`, sans tenir compte des majuscules, comme le lanceur actuel).
- Créer quand même sa fenêtre principale, **cachée**, sans voler le premier plan, avec le verrou pris et les demandes
  surveillées.
- Se montrer d'elle-même (sans s'activer) dès qu'elle est accrochée.
- `cache_depuis` dans apps.json = sa première version Rust.

---

## 7. L'accrochage des fenêtres

**Existe, côté Mindset** (`Mindset/fichiers/modules/integration.ps1` et `MSIntegration` dans
`Mindset/fichiers/modules/natif.cs:33-137`) :
- **Trouver la fenêtre** : `Find-FenetreAppli` (`integration.ps1:35-41`) appelle `MSIntegration.Trouver(pid, Nom)` pour
  chaque hôte de l'appli (`natif.cs:61-74`). Il faut une fenêtre de premier niveau du processus :
  - **sans propriétaire** (`GW_OWNER` nul, `natif.cs:67`) : les alertes et menus sont écartés ;
  - **dont le titre est exactement `nom`** de apps.json ;
  - **dont la classe commence par `HwndWrapper`** (`natif.cs:70`) : c'est la classe des fenêtres **WPF**.
- **Accrocher** (`natif.cs:81-98`) : retire la barre de titre et la bordure, ajoute `WS_CHILD`, `SetParent` dans le
  panneau de Mindset, à la taille du panneau (au moins 200 x 200, `integration.ps1:102`). Refus de Windows : message
  « n'a pas pu s'afficher ici » (`integration.ps1:103-108`).
- **Taille** : Mindset redimensionne la fenêtre à chaque changement du panneau (`integration.ps1:29`, `natif.cs:100-103`).
- **Sa propre barre** : la propriété de fenêtre `Mindset.BarrePropre` (`natif.cs:111-113`) fait disparaître la barre de
  Mindset (`integration.ps1:146-152`), relue toutes les 400 ms (`integration.ps1:181-185`).
- **Fermer** : `WM_CLOSE` (`natif.cs:117-118`, `integration.ps1:154-158`) ; l'appli applique sa propre règle.
- **Surveillance** toutes les 400 ms (`integration.ps1:180-238`) : fenêtre détruite, c'est une fermeture ou une
  relance (190-195) ; fenêtre qui s'est cachée elle-même (`WS_VISIBLE` retiré), elle est rendue et reste près de
  l'horloge (196-201) ; attente d'une fenêtre : 15 s si le programme s'est arrêté, 60 s sinon (222-224) ; un hôte de
  plus d'une minute sans aucune fenêtre est arrêté puis relancé (212-219, `integration.ps1:51-63`).
- **Mindset quitte** : chaque fenêtre est rendue telle qu'elle était, **cachée** (`integration.ps1:240-247`,
  `natif.cs:127-136`).
- Une appli qui demande les droits administrateur ne s'affiche que dans un Mindset administrateur
  (`integration.ps1:77-80`).

**Existe, côté appli** (Nevermind) :
- savoir qu'elle est accrochée : `WS_CHILD` ou un parent (`Nevermind: Nevermind/fichiers/modules/natif.cs:2362-2367`),
  lu toutes les 600 ms (`Nevermind: Nevermind/fichiers/modules/evenements.ps1:58-87`) ;
- accrochée : **taille minimale à 0** (`evenements.ps1:69-71`), se montrer sans s'activer si elle était cachée
  (`evenements.ps1:72-80`), poser `Mindset.BarrePropre` si elle a sa barre (`evenements.ps1:67`,
  `Nevermind: Nevermind/fichiers/modules/natif.cs:2354-2359`) ;
- décrochée : taille minimale rendue (`evenements.ps1:82`), et se ranger si Mindset l'a cachée (`evenements.ps1:83-84`) ;
- accrochée, une demande d'affichage ne touche pas à sa fenêtre (`evenements.ps1:108-109`).

**Existe (étape 2).** `MSIntegration.Trouver` (`natif.cs:70`) accepte aussi une fenêtre de classe exactement
« Tauri Window » (la fenêtre principale d'une appli Tauri), en plus de `HwndWrapper*` : c'est la seule condition
ajoutée, celle qu'a validée l'essai jetable 1 de l'étape 0 (une fenêtre Tauri accrochée dans le Mindset actuel). Rien ne
change pour les fenêtres WPF d'aujourd'hui ; le titre exact et l'absence de propriétaire restent demandés pour les deux.
Vérifié par `outils/tester-securite.ps1` (partie « fenêtre trouvée pour l'accrochage ») sur des fenêtres jamais
montrées : une WPF et une Tauri trouvées, une `Chrome_WidgetWin_1` et une Tauri possédée par une autre écartées.

Reste à faire côté Mindset 3.0 (étape 4, plan « Résultats des essais de l'étape 0 ») : la veille de la page Tauri
cachée (`SetIsVisible`), et `WS_CLIPCHILDREN` / `WS_CLIPSIBLINGS` quand c'est Mindset en Tauri qui accroche une appli.

**Appli Rust.**
- Une seule fenêtre principale, créée au démarrage (même avec `-Demarrage`), **sans propriétaire**, titre = `nom`
  exactement, jamais recréée tant que l'appli tourne.
- Accepter `WS_CHILD` et `SetParent` venant de Mindset, sans se battre contre eux.
- Accrochée : taille minimale à 0 ; décrochée : la remettre.
- Traiter `WM_CLOSE` avec sa propre règle (demander, se ranger ou quitter).
- Poser `Mindset.BarrePropre` quand elle affiche sa propre barre.
- Se cacher elle-même (retirer `WS_VISIBLE`) pour « se ranger », jamais se détruire.

---

## 8. Le dossier des données

**Existe.**
- Les racines de la suite se déduisent de l'emplacement des programmes, jamais d'un fichier modifiable
  (`donnees.ps1:4-8`, `:15-21`) :
  - par défaut : programmes `C:\Program Files\Mindset\<Nom>`, données `%LOCALAPPDATA%\Mindset\<Nom>` ;
  - autre disque : programmes `X:\Mindset\Programmes\<Nom>`, données `X:\Mindset\Donnees\<Nom>`.
- `Get-DossierDonnees` (`installations.ps1:23-28`) : `<données de la suite>\<Nom>` si l'appli est gérée et que ce
  dossier existe, sinon `donnees` de apps.json (l'ancien dossier).
- Sur un autre disque, `Donnees` est modifiable par l'utilisateur de Mindset, `Programmes` non
  (`installer-admin.ps1:258-260`).
- C'est l'appli qui déplace ses anciennes données (`installations.ps1:6`). Nevermind calcule son dossier dans son
  lanceur (`Nevermind: outils/lanceur.cs:38-69`) : la règle des racines, et suite.json seulement pour vérifier que sa
  copie est celle de Mindset ; Mindset fait de même pour lui (`outils/lanceur.cs:107-148`).
- Mindset y lit aussi `reglages.json` ou `parametres.json` (valeur `DemarrageWindows`, `installations.ps1:750-763`).
- WebView2 : le dossier commun `<données de la suite>\WebView2`, un profil par appli (`Mindset/fichiers/modules/console.ps1:19`,
  `:70-83` ; `Nevermind: Nevermind/fichiers/modules/vue.ps1:44-50`) ; à la désinstallation sans données, Mindset retire
  le profil `WV2Profile_<nom en minuscules>` (`installations.ps1:856-862`). Voir `regles-tauri.md`.

**Appli Rust.** Calculer son dossier avec la même règle (fonction de `suite-commun`), depuis l'emplacement de son
propre exe ; y écrire tous ses fichiers ; déplacer elle-même ses anciennes données ; ne rien écrire dans son dossier
de programmes (il est protégé).

---

## 9. Le désinstalleur par appli

**Existe.**
- Champ `desinstalleur` (`applis.ps1:18`, `:60`) ; aujourd'hui seulement Nevermind (`apps.json:20`), qui remet les
  réglages de Windows comme avant.
- **Depuis Mindset** (`Start-DesinstallAppli`, `installations.ps1:815-843`) : il ferme les programmes d'aide lancés
  depuis les données, puis lance le désinstalleur **sans option** (c'est lui qui demande pour les données, ligne
  826-830) ; il attend jusqu'à 10 minutes que `exe` ait disparu (`installations.ps1:867-879`), puis regarde ce qui
  reste des données (`installations.ps1:845-865`). Sans désinstalleur, Mindset fait supprimer le dossier par le
  mini-installateur (`installations.ps1:837-842`).
- **Depuis « Désinstaller Mindset »** (`outils/desinstalleur.cs`) : chaque désinstalleur de apps.json est lancé avec
  `-GarderDonnees` ou `-SupprimerDonnees` (`desinstalleur.cs:15-18`, `:780-803`, ligne 790), dans le dossier de
  l'appli, 10 minutes au plus ; réussi si `exe` a disparu. Si apps.json manque, un `*sinstaller *.exe` trouvé dans le
  dossier d'une appli sert (`desinstalleur.cs:703-752`, ligne 742).
- Celui de Nevermind est son lanceur compilé avec le symbole `UNINSTALL` (`Nevermind: outils/construire.ps1:62`,
  `Nevermind: outils/lanceur.cs:149-166`).

**Existe (étape 2) : « Desinstaller Mindset.exe » en Rust** (`rust/desinstalleur`), même comportement pour
l'utilisateur que `desinstalleur.cs` (mêmes textes, mêmes étapes, même bilan, mêmes options), et ce que l'audit du 25/10
lui reprochait (constat 5) corrigé (`rust/desinstalleur/src/os/mod.rs`, `lieux_reels`) :
- Program Files vient de HKLM (`ProgramFilesDir`), sinon de Windows (KnownFolder), jamais de la variable
  `ProgramW6432` ;
- le Bureau, le menu Démarrer et `%LOCALAPPDATA%` (« Shell Folders » de l'utilisateur) ne sont acceptés que dans son
  dossier de profil, lu dans HKLM (`ProfileList`), et sans jonction ni lien symbolique en route ; sinon leur place
  habituelle dans ce profil ;
- la copie temporaire et le journal vont dans `<Windows>\Temp` (plus la variable TEMP), le dossier de la copie est
  créé directement protégé, et le journal n'est jamais écrit au travers d'un lien ;
- aucune variable d'environnement n'est lue.
Les options d'essai (`-Test`, `-EssaiFenetre`) n'existent que dans la construction d'essai (option cargo `essai`) :
l'exe livré ne les connaît pas. Juges : `cargo test -p desinstalleur` (faux Windows) et
`outils/tester-desinstallation.ps1`, qui passe les mêmes cas à la version C# et à la version Rust (sur GitHub). Tant
que la publication des exe construits sur GitHub (plan 3.6) n'est pas en place, `construire.ps1` livre encore la
version C#. Le contrat avec les désinstalleurs d'appli ne change pas (mêmes options, même attente, même critère).

**Appli Rust.** Seulement si elle change quelque chose dans Windows : `Désinstaller <Nom>.exe` dans son dossier, qui
- sans option, pose la question des données ; avec `-GarderDonnees` ou `-SupprimerDonnees`, ne la pose pas ; avec les
  deux, la pose ;
- remet Windows comme avant, puis supprime ses programmes (donc `exe` disparaît), et rend 0 ;
- ne dépend pas de l'appli elle-même (il marche si elle est abîmée).

Sinon, pas de champ `desinstalleur` : Mindset supprime le dossier et garde les données.

---

## 10. version.json

**Avant l'étape 2 : la version était lue dans le script.** La ligne `$AppVersion = 'x.y.z'` (dans les 40 premières
lignes d'un `fichiers\*.ps1`) était lue à trois endroits : la version installée (`Get-VersionDans`), la version d'un
zip avant de fermer l'appli (`Get-VersionZip`, appelée par `installer-admin.ps1:498-499`), la version d'un dossier
(`Get-VersionDossier`, pour refuser un retour en arrière et pour la plus haute version gardée dans HKLM,
`installer-admin.ps1:246-256`, `:504`). Ces lectures restent, **en secours**.

La version **publiée** vient du nom de la version sur GitHub (`paquets.ps1:25`, `:41`) : rien ne change là.

**Existe (étape 2).** Le fichier, couvert par la signature du zip comme tout le reste :

```json
{ "appli": "nevermind", "version": "2.0.0", "mindset_min": "2.15.0" }
```

**Où il est rangé : `<dossier_zip>\version.json`** (décision de l'étape 2, point relevé en 4 bis du plan). La
construction d'une appli l'écrit dans le dossier principal de son zip, à côté de `<exe>`, et pas à la racine du zip.
Pourquoi :
- `Install-Paquet` (PowerShell) et `suite-commun` (Rust) n'extraient que `<dossier_zip>\` : le fichier arrive tel quel
  dans le dossier installé, sans étape de plus ;
- la version installée se lit alors dans le dossier : `Get-VersionDans`, le refus d'un retour en arrière et la plus
  haute version gardée dans HKLM (`installer-admin.ps1`, qui appelle `Get-VersionDossier`) marchent sans rien changer à
  l'installateur ;
- un Mindset d'avant 2.15 l'ignore (il ne connaît que `$AppVersion`), comme il ignorerait un fichier à la racine.

Pour suivre `suite-commun` (`rust/suite-commun/src/paquet.rs`, `extraire` et `installer_verifie`), Mindset accepte
aussi un `version.json` à la **racine** du zip (nom exact, avec cette casse) : il est rangé dans le dossier installé ;
s'il y en a un dans le dossier principal aussi, les deux doivent être identiques à l'octet près.

**La lecture** (`Read-VersionJson`, `paquets.ps1:144`, comme `lire_version_json` de `suite-commun`) : 64 Ko au plus ;
marque d'encodage suivie (UTF-8, UTF-16, UTF-32), sinon UTF-8 ; un objet JSON (noms des champs avec leur casse) ;
`version` obligatoire, `^\d+(\.\d+){1,3}$` en chiffres ASCII ; `appli` et `mindset_min` facultatifs mais des textes
s'ils sont là, `mindset_min` au format d'une version. Sinon le fichier est **illisible**.

**Où il est lu, toujours en premier :**
1. **l'installation** (`Install-Paquet`, `paquets.ps1:306`, contrôles aux lignes 322-390), dans cet ordre, les mêmes
   que `suite-commun` avec les mêmes messages mot pour mot :
   - illisible, ou les deux fichiers différents : « Le fichier téléchargé ne dit pas quelle version il contient : rien
     n'a été installé. » ;
   - ligne `$AppVersion` encore présente et différente de `version` : même refus ;
   - `appli` différent de l'appli attendue (sans tenir compte de la casse) : « Ce fichier contient l'appli X et pas
     Y : rien n'a été installé. » L'appli attendue vient du paramètre `-Appli`, sinon de apps.json par le dossier du
     zip (`Get-AppliDuDossierZip`, `paquets.ps1:201` : c'est le cas avec `installer-admin.ps1` d'aujourd'hui, qui ne
     passe pas l'appli) ; inconnue : pas ce contrôle (le programme attendu dans `<dossier_zip>\` reste vérifié) ;
   - `mindset_min` plus récent que le Mindset qui installe (paramètre `-VersionMindset`) : « Mets d'abord Mindset à
     jour : cette version demande Mindset X ou plus récent. » ;
   - puis les contrôles d'avant (retour en arrière, plus haute version gardée). La version installée se lit dans son
     `version.json`, et s'il est abîmé, dans `$AppVersion` (un fichier abîmé chez l'utilisateur ne bloque pas).
2. **avant de fermer l'appli**, côté Mindset : la tâche de téléchargement (`installations.ps1:488`) passe le zip à
   `Test-PaquetAppli` (`paquets.ps1:217`) avec l'`id` de l'appli et la version de Mindset : autre appli, Mindset trop
   ancien ou fichier illisible s'affichent sur la carte (« Échec : ... ») sans rien avoir fermé ni demandé à
   l'installateur. C'est là que l'utilisateur voit « Mets d'abord Mindset à jour ».
3. **la version d'un zip** (`Get-VersionZip`, `paquets.ps1:229`, pour `installer-admin.ps1`) : celle de son
   `version.json` (illisible, ou deux différents : aucune), sinon `$AppVersion` comme avant ;
4. **la version d'un dossier** (`Get-VersionDossier`, `paquets.ps1:262`) et **la version installée**
   (`Get-VersionDans`, `installations.ps1:64`) : `version.json`, sinon `$AppVersion`.

Un zip sans `version.json` (toutes les applis d'aujourd'hui) s'installe exactement comme avant : vérifié par le banc
d'essai PowerShell / Rust (161 cas sur 161 identiques) et par `outils/tester-securite.ps1` (partie « Contrat d'une
appli : version.json dans le zip », avec ses cas bons, faux et illisibles).

Un Mindset d'avant 2.15 ne connaît pas ce fichier : il refuse un zip sans script (« ne dit pas quelle version ») et
installe un zip qui a encore sa ligne `$AppVersion`. Sans gravité : Mindset 2.15 sort avant toute appli Rust.

**Appli Rust.** Livrer `<dossier_zip>\version.json` dans son zip, écrit par sa construction à partir de sa version
(une seule source), avec `appli` = son `id` dans apps.json et `mindset_min` = la première version de Mindset qui
l'accueille (au moins 2.15.0). Si elle garde une ligne `$AppVersion` (pendant la bascule), la même version.

---

## Qui mesure quoi

Partage fixé par le plan (3.7) : les mesures qui demandent les droits administrateur vivent dans l'**Aide** de
Nevermind (en SYSTEM), celles qui n'en demandent pas vivent dans l'**appli**. Établi en lisant le code de Nevermind.

### Dans l'Aide (SYSTEM) : passent en Rust à l'étape 1b

| Mesure | Actions du canal | Où, aujourd'hui | Côté appli |
|---|---|---|---|
| Trace réseau ETW (fournisseur Kernel-Network, UDP compris) | `flux.demarrer`, `flux.veiller`, `flux.lire`, `flux.arreter` | `Nevermind: Nevermind/fichiers/modules/aide-actions.ps1:964-989` ; classe `NetFlow` (`StartTraceW`...), `Nevermind: Nevermind/fichiers/modules/natif.cs:1733-1934`, chargée dans l'Aide par `Initialize-AideNatif` (`aide-actions.ps1:42-46`) | `Nevermind: Nevermind/fichiers/modules/aide-client.ps1:355-374`, `Nevermind: Nevermind/fichiers/modules/lag.ps1:28` |
| FPS par PresentMon (relais des lignes) | `fps.demarrer`, `fps.veiller`, `fps.lire`, `fps.arreter` | `aide-actions.ps1:919-954` ; classe `AideFps`, `Nevermind: Nevermind/fichiers/NevermindAide.ps1:139-144` et suite ; PresentMon vérifié signé par Intel avant d'être lancé (`aide-actions.ps1:260-264`) | `FrameMon.StartRemote`, lecture toutes les 250 ms (`natif.cs:783-815`) ; veille avant le jeu (`aide-client.ps1:322-337`) |
| Compteurs TCP (octets par connexion) | `trafic.tcp` | `aide-actions.ps1:956-962` ; classe `TrafficMon` (`SetPerTcpConnectionEStats`), `natif.cs:1473-1690` | `Get-TrafficTcp`, `aide-client.ps1:340-353` |

À l'étape 1b, ces trois mesures passent dans `NevermindAide.exe` en Rust, avec les **mêmes actions et les mêmes
réponses** sur le canal : l'appli PowerShell ne voit pas la différence. Point d'attention : l'appli garde aujourd'hui un
repli local quand l'Aide ne répond pas (`aide-client.ps1:350-352` pour les compteurs, `:363` pour la trace). Ces
replis demandent les droits administrateur (`natif.cs:1734`, `:1541`), que Nevermind n'a plus depuis la 1.0.115
(`apps.json:23`) : à retirer à l'étape 1b plutôt qu'à porter.

### Dans l'appli (sans droits) : passent en Rust au morceau 1 de l'étape 6

| Mesure | Où, aujourd'hui |
|---|---|
| Overlay des FPS (compteur par-dessus le jeu) | `Show-FpsOverlay`, `Nevermind: Nevermind/fichiers/modules/jeu.ps1:509-621` (ligne 605) ; fenêtre traversée par la souris, sans focus, `OGNative.MakeOverlay`, `natif.cs:722-729` ; chiffres calculés dans l'appli à partir des lignes relayées par l'Aide (`FrameMon.Live`, `natif.cs:1145-1157`) |
| Souris | `MouseHook`, `natif.cs:2176-2289` : écoute globale des boutons de la souris sur un fil à part, utilisée par `Nevermind: Nevermind/fichiers/modules/organizer.ps1:196-208` |
| Latence | ping des cibles, `Measure-Latency`, `Nevermind: Nevermind/fichiers/modules/onglets.ps1:540` ; latence en charge, `OGNative.LoadedLatency`, `natif.cs:378-381`, appelée par `Nevermind: Nevermind/fichiers/modules/tests.ps1:52` |

Au morceau 1 de l'étape 6, ces mesures passent dans le moteur Rust de Nevermind, appelé par la DLL du pont (plan 3.7),
sans droits. Le calcul des FPS (`FrameMon`) suit l'overlay : l'Aide ne fait que relayer les lignes de PresentMon.
La mesure de lag en continu (`LagMon`, `natif.cs:1936-1937`) relève du réseau, donc du morceau 2.

---

## Doutes et points à trancher

- **Second lancement avec `-Demarrage`, appli déjà ouverte** : **réglé le 29/10**, l'appli ne dépose pas de demande
  d'affichage et rien ne s'affiche (partie 3).
- **Croix (`WM_CLOSE`) du squelette nouvelle-appli** : **réglé le 29/10**, elle quitte, comme aujourd'hui (c'est aussi le
  bouton « Fermer » de la barre de Mindset). La croix rouge de Mindset garde sa question Réduire / Quitter.
- **Fenêtre Tauri et `HwndWrapper`** : **réglé à l'étape 2**, classe « Tauri Window » acceptée (partie 7).
- **Où mettre `version.json`** : **réglé à l'étape 2**, `<dossier_zip>\version.json` (partie 10) ; celui de la racine
  du zip est accepté aussi, comme `suite-commun`.
- **Appli qui passe de PowerShell à Rust** (Mindcare, Evermind, Nevermind) : **réglé à l'étape 2** pour Mindset 2.15 :
  les deux formes de dossier sont reconnues pour la même entrée, quel que soit `type` (partie 2), et `version.json` est
  lu d'abord, `$AppVersion` en secours (partie 10). Reste à faire au moment de chaque bascule : passer l'entrée à
  `"type": "rust"` (ou garder `script` tant qu'elle ne l'a pas).
- **`installer-admin.ps1` ne passe ni l'appli ni la version de Mindset à `Install-Paquet`** : l'appli est déduite de
  apps.json par le dossier du zip, et `mindset_min` n'est contrôlé que par Mindset avant de fermer l'appli
  (`Test-PaquetAppli`). Le futur `MindsetInstallateur.exe` (Rust, `suite-commun`) devra donner `appli` et
  `version_mindset` (ce dernier lu dans le `Mindset.ps1` du dossier protégé) à `Demande`.
- **`exe` pour une appli Rust** : garder un relais `<Nom>.exe` ou faire pointer `exe` sur `Mindset.exe` ; le second
  oblige à revoir les parties 2 et 9 et la recherche des copies (`installations.ps1:121-141`). Proposition : garder le
  relais.
- **Libellé dans le Gestionnaire des tâches** pour un exe Rust : la description des informations de version doit
  valoir « Mindset » ; à confirmer par l'essai jetable 1.
- **afficher-rdv.demande** : la lecture côté Evermind n'a pas été relue (dépôt Evermind non ouvert pour ce document).
- **« Souris » et « latence »** : le plan les range dans l'appli. Le seul code de souris trouvé est `MouseHook`, qui sert
  de raccourci plus que de mesure ; pour la latence, `Measure-Latency` et `LoadedLatency` sont des tests réseau, qui
  pourraient aller au morceau 2 (réseau) plutôt qu'au morceau 1. À confirmer avec Jordan.
