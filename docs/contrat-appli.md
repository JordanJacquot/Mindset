# Contrat entre Mindset et une appli de la suite

Ce document dit tout ce dont Mindset dépend chez une appli de la suite, et ce que l'appli doit faire en retour. Il sert
de référence pour écrire une appli en Rust (plan de passage en Rust, 3.4) et pour l'« appli témoin » qui vérifiera ce
contrat dans les tests.

Il est établi en lisant le code du 26/10/2026 : Mindset 2.14.0 (`Mindset/fichiers/Mindset.ps1:14`) et Nevermind 1.14.2
(`Nevermind: Nevermind/fichiers/Nevermind.ps1:16`).

Comment lire ce document :
- les chemins sont relatifs à la racine du dépôt Mindset ; ceux qui commencent par « Nevermind: » sont relatifs à la
  racine du dépôt Nevermind ;
- **Existe** : ce que fait le code aujourd'hui ;
- **À venir (étape 2)** : ce qui change dans Mindset avant la première appli Rust ;
- **Appli Rust** : ce que l'appli devra faire.

---

## 1. L'entrée dans apps.json

**Existe.** `Mindset/fichiers/apps.json` est livré avec Mindset : une appli n'existe pour Mindset que si elle y figure
(`Mindset/fichiers/modules/applis.ps1:4-5`). Mindset le lit dans `Get-Applis` (`applis.ps1:7-73`) et ignore toute
entrée qui ne passe pas les contrôles (`applis.ps1:28`).

| Champ | Obligatoire | Contrôle | Ligne |
|---|---|---|---|
| `id` | oui | `^[a-z0-9-]+$` | `applis.ps1:14-15` |
| `nom` | oui | non vide ; aussi le nom du dossier de l'appli et le titre de sa fenêtre | `applis.ps1:15` |
| `couleur` | oui | `#RRGGBB` | `applis.ps1:15` |
| `depot` | oui | `propriétaire/dépôt` GitHub | `applis.ps1:16` |
| `zip`, `dossier_zip` | oui | nom de fichier simple | `applis.ps1:16` |
| `exe` | oui | nom de fichier `.exe` | `applis.ps1:17` |
| `script` | oui | `^[\w\\.-]+\.ps1$`, sans `..` | `applis.ps1:17` |
| `mutex` | en pratique | **aucun contrôle** (lu tel quel) | `applis.ps1:51` |
| `afficher_fichier` | non | nom de fichier simple | `applis.ps1:19` |
| `afficher_signal` | non | aucun contrôle | `applis.ps1:59` |
| `desinstalleur` | non | nom de fichier `.exe` | `applis.ps1:18` |
| `donnees` | en pratique | variables d'environnement développées, aucun autre contrôle | `applis.ps1:61` |
| `admin`, `sans_droits_depuis` | non | version `\d+(\.\d+){1,3}` | `applis.ps1:21`, `62-64` |
| `aide`, `aide_exe` | non | `<Nom> (aide)` et nom `.exe` | `applis.ps1:20` |
| `cache_depuis` | non | aucun contrôle (comparé comme une version) | `applis.ps1:67` |
| `rappels`, `presentation`, `description`, `confidentialite`, `logo`, `logo_epaisseur` | non | voir les lignes | `applis.ps1:31-38`, `63` |
| `ancien_*` | non | mêmes contrôles que les champs actuels | `applis.ps1:24-27` |

Le mini-installateur relit apps.json de son côté, à côté de lui dans le dossier protégé, jamais dans la demande
(`Mindset/fichiers/installer-admin.ps1:213-229`) : il vérifie `nom` (et refuse « Mindset », ligne 221), `exe`,
`dossier_zip` et la partie administrateur, mais **pas** `script`. Le désinstalleur de Mindset lit `nom`, `exe` et
`desinstalleur` (`outils/desinstalleur.cs:725-729`).

**Pourquoi une appli sans script est rejetée aujourd'hui.** À trois endroits :
1. `applis.ps1:17` : `$a.script -match '^[\w\\.-]+\.ps1$'` ; sans `script`, l'entrée est ignorée (`applis.ps1:28`,
   « appli ignorée ») ;
2. `Mindset/fichiers/modules/installations.ps1:69` : `Test-DossierAppli` exige le fichier `script` dans le dossier
   (voir partie 2) ;
3. `Mindset/fichiers/modules/paquets.ps1:237-241` : le zip est refusé s'il n'a pas de ligne `$AppVersion` dans un
   `fichiers\*.ps1` (« Le fichier téléchargé ne dit pas quelle version il contient », voir partie 10).

**À venir (étape 2).** Un champ `type` :
- `"powershell"` : le comportement d'aujourd'hui ; c'est la valeur quand le champ est absent ;
- `"rust"` : `script` n'est plus demandé ; la version vient de `version.json` (partie 10) ; `Test-DossierAppli` suit
  la partie 2.
- Toute autre valeur : l'entrée est ignorée, comme aujourd'hui une entrée mal formée.

Profiter de l'étape 2 pour contrôler aussi `mutex` (même règle que `ancien_mutex`, `^Local\\[\w.-]+$`,
`applis.ps1:27`), `afficher_signal` et `cache_depuis`.

**Appli Rust.** Son entrée a `"type": "rust"`, un `mutex` `Local\<Nom>-Instance`, un `afficher_fichier` (sinon
Mindset ne lit pas ses notifications, partie 5), `donnees` (son ancien dossier, ou celui de la suite), et
`desinstalleur` seulement si elle change des réglages de Windows (partie 9).

---

## 2. Test-DossierAppli : « ce dossier contient-il l'appli ? »

**Existe.** `installations.ps1:68-70` :

```powershell
$Dossier -and (Test-Path -LiteralPath (Join-Path $Dossier $Appli.Exe)) -and [bool](Get-ScriptAppli $Dossier $Appli)
```

Il faut donc le programme `exe` **et** le script (`script` ou `ancien_script`, `installations.ps1:53-60`). Il sert
partout où Mindset décide qu'une appli est installée :
- `Get-Installation` (`installations.ps1:73-89`) : l'installation notée dans installations.json (une installation
  « gérée » n'est crue que dans le dossier protégé, ligne 77), puis la copie gérée oubliée (ligne 87) ;
- la recherche d'une copie déjà présente sur le PC (`installations.ps1:138`) ;
- « utiliser cette copie » (`installations.ps1:883`).

Ailleurs, la présence du seul `exe` compte : le zip doit le contenir (`paquets.ps1:230-233`), et la désinstallation
est finie quand il a disparu (`installations.ps1:872`, `outils/desinstalleur.cs:783`).

**À venir (étape 2).** Pour `type: "rust"` : `exe` présent, `Mindset.exe` présent, et `version.json` lisible avec le
bon `appli` (partie 10). Pas de script.

**Appli Rust.** Son dossier contient au moins `Mindset.exe` (son programme), `<exe>` (voir partie 4) et `version.json`.

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
  demande d'affichage (partie 5) et quitter sans ouvrir de fenêtre.
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

**À venir (étape 2).** Le test `HwndWrapper` de `natif.cs:70` ne trouvera pas une fenêtre Tauri. Mindset doit
accepter une fenêtre d'appli Rust par un autre signe : par exemple une propriété de fenêtre posée par l'appli
(sur le modèle de `Mindset.BarrePropre`), en plus du titre et de l'absence de propriétaire. Le choix se fait avec
l'essai jetable 1 de l'étape 0 (fenêtre Tauri accrochée dans le Mindset actuel).

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

**À venir (étape 2).** `desinstalleur.cs` passe en Rust, en corrigeant ce que l'audit lui reprochait (par exemple
`ProgramW6432` lu dans l'environnement de l'utilisateur, `desinstalleur.cs:107`).

**Appli Rust.** Seulement si elle change quelque chose dans Windows : `Désinstaller <Nom>.exe` dans son dossier, qui
- sans option, pose la question des données ; avec `-GarderDonnees` ou `-SupprimerDonnees`, ne la pose pas ; avec les
  deux, la pose ;
- remet Windows comme avant, puis supprime ses programmes (donc `exe` disparaît), et rend 0 ;
- ne dépend pas de l'appli elle-même (il marche si elle est abîmée).

Sinon, pas de champ `desinstalleur` : Mindset supprime le dossier et garde les données.

---

## 10. version.json

**Existe : la version est lue dans le script.** La ligne `$AppVersion = 'x.y.z'` (dans les 40 premières lignes d'un
`fichiers\*.ps1`) est lue à trois endroits :
1. **la version installée** : `Get-VersionDans` (`installations.ps1:62-66`), qui sert à `cache_depuis`
   (`integration.ps1:47`) et `sans_droits_depuis` (`applis.ps1:77-83`) ;
2. **la version d'un zip, avant de fermer l'appli** : `Get-VersionZip` (`paquets.ps1:138-160`), appelée par
   `installer-admin.ps1:498-499` ;
3. **la version d'un dossier** : `Get-VersionDossier` (`paquets.ps1:166-175`), pour refuser un retour en arrière ou un
   zip sans version (`paquets.ps1:234-249`) et pour la plus haute version gardée dans HKLM
   (`installer-admin.ps1:246-256`, `:504`).

La version **publiée** vient du nom de la version sur GitHub (`paquets.ps1:25`, `:41`) : rien ne change là.

**À venir (étape 2).** Un fichier `version.json`, couvert par la signature du zip :

```json
{ "appli": "nevermind", "version": "2.0.0", "mindset_min": "2.15.0" }
```

- lu **en premier** aux trois endroits ci-dessus ; la ligne `$AppVersion` reste lue **en secours** (une appli
  PowerShell n'a pas besoin du fichier) ;
- `appli` doit être l'`id` de l'entrée : sinon le zip est refusé (il empêche d'installer une appli à la place d'une
  autre) ;
- `version` : `^\d+(\.\d+){1,3}$` ;
- `mindset_min` : si Mindset est plus ancien, le message « Mets d'abord Mindset à jour », au lieu d'un échec muet. Un
  Mindset d'avant 2.15 ne connaît pas ce fichier et refuse un zip sans script (« version illisible ») : sans gravité,
  Mindset 2.15 sort avant toute appli Rust.

**Appli Rust.** Livrer `version.json` dans son zip, écrit par sa construction à partir de sa version (une seule
source).

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

- **Fenêtre Tauri et `HwndWrapper`** (`natif.cs:70`) : le signe qui la remplace est à choisir avec l'essai jetable 1
  de l'étape 0.
- **Où mettre `version.json`** : le plan dit « à la racine du zip », mais `Install-Paquet` n'extrait que ce qui est
  sous `<dossier_zip>\` (`paquets.ps1:212-219`). Pour que la version installée soit lisible dans le dossier
  (`Get-VersionDans`), le plus simple est `<dossier_zip>\version.json`. À trancher à l'étape 2.
- **Appli qui passe de PowerShell à Rust** (Mindcare, Evermind, Nevermind) : pendant la bascule, le dossier installé
  est encore PowerShell et le zip publié est Rust. Mindset 2.15 doit accepter les deux formes pour la même entrée
  (version.json d'abord, script en secours), quel que soit `type`.
- **`exe` pour une appli Rust** : garder un relais `<Nom>.exe` ou faire pointer `exe` sur `Mindset.exe` ; le second
  oblige à revoir les parties 2 et 9 et la recherche des copies (`installations.ps1:121-141`). Proposition : garder le
  relais.
- **Libellé dans le Gestionnaire des tâches** pour un exe Rust : la description des informations de version doit
  valoir « Mindset » ; à confirmer par l'essai jetable 1.
- **afficher-rdv.demande** : la lecture côté Evermind n'a pas été relue (dépôt Evermind non ouvert pour ce document).
- **« Souris » et « latence »** : le plan les range dans l'appli. Le seul code de souris trouvé est `MouseHook`, qui sert
  de raccourci plus que de mesure ; pour la latence, `Measure-Latency` et `LoadedLatency` sont des tests réseau, qui
  pourraient aller au morceau 2 (réseau) plutôt qu'au morceau 1. À confirmer avec Jordan.
