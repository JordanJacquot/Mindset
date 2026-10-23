# Mindset

Le portail de la suite : [Nevermind](https://github.com/JordanJacquot/Nevermind) et [Evermind](https://github.com/JordanJacquot/Evermind) au même endroit.
Depuis Mindset, tu installes, mets à jour et utilises chaque appli. C'est la seule façon de les installer.

## Télécharger

1. Va dans [Releases](../../releases/latest) et télécharge **Mindset.zip**.
2. Clic droit sur le zip > **Extraire tout**, puis double-clique sur **Mindset.exe**.
   Si Windows affiche « Windows a protégé votre ordinateur » : « Informations complémentaires » puis « Exécuter quand même ».
3. Choisis le disque, puis clique sur **Installer Mindset** (Windows demande l'autorisation) : Mindset s'installe,
   crée son raccourci et se lance avec Windows. Tu peux ensuite supprimer le dossier téléchargé.
   Sur C:, tout va dans `Program Files\Mindset` (programmes) et `%LOCALAPPDATA%\Mindset` (données) ; sur un autre
   disque, tout va dans `X:\Mindset` (`Programmes` et `Donnees`), pour garder de la place sur C:.
4. Dans Mindset, installe Nevermind et Evermind.

Tu avais déjà Nevermind ou Evermind ? Mindset les trouve et propose de les **prendre en charge** : tes réglages, tes
rendez-vous et tes sauvegardes sont gardés, l'ancienne copie et ses raccourcis sont retirés.

## Ce que fait Mindset

- **Une porte d'entrée unique** : Nevermind et Evermind s'installent, se mettent à jour et s'ouvrent depuis Mindset,
  et s'affichent directement dans sa fenêtre (un onglet par appli, à gauche).
- **Accueil vivant** : le score et le prochain « À faire » de Nevermind, tes trois prochains rendez-vous d'Evermind ;
  un clic ouvre l'appli au bon endroit.
- **Réglages communs** (Paramètres) : le thème de toute la suite (5 thèmes, et des thèmes personnalisés en .zip),
  le micro et le casque.
- **Discret** : Mindset se range près de l'horloge et se lance avec Windows ; sur chaque carte, l'interrupteur
  « S'ouvre avec Mindset » choisit les applis qui démarrent avec lui.
- **Mises à jour automatiques** de Mindset et des applis, toutes signées.
## Droits administrateur

Mindset, Nevermind et Evermind tournent **sans** les droits administrateur. Seules deux petites parties les ont, lancées
par des tâches planifiées créées à l'installation (une seule demande de Windows, à l'installation de Mindset) :

- **le mini-installateur de Mindset** (`installer-admin.ps1 -Action demande`) : il installe, met à jour ou supprime une
  appli ou Mindset, et rien d'autre ; il revérifie chaque demande et n'installe que des zips signés ;
- **Nevermind Aide** : les réglages de Windows que Nevermind modifie, ses lectures et ses mesures, selon une liste stricte
  (`modules\aide-actions.ps1` de Nevermind) qui refuse tout ce qui affaiblirait la sécurité du PC.

## Désinstaller Mindset

Dans Paramètres de Windows > Applications installées, choisis Mindset puis Désinstaller (ou, dans Mindset :
Paramètres > Désinstaller Mindset). Le désinstalleur retire Mindset et les applis qu'il a installées : programmes,
raccourcis, lancement avec Windows, tâches planifiées et traces dans le registre. Tes données (réglages, rendez-vous,
sauvegardes) sont gardées, sauf si tu coches « Supprimer aussi mes données ».

Nevermind remet d'abord comme avant les réglages de Windows qu'il avait changés, avec son propre désinstalleur : Mindset
lui passe ton choix (`-GarderDonnees` ou `-SupprimerDonnees`), il ne pose donc pas la question une deuxième fois. Même
quand tes données sont gardées, la sauvegarde de ces réglages part : ils viennent d'être remis comme avant, et une
réinstallation ne doit pas remettre des valeurs vieilles de plusieurs mois. Une ancienne version de Nevermind qui
supprime quand même ses données est repérée : le message de fin le dit.

Pour désinstaller une seule appli, utilise le bouton Désinstaller de sa carte dans Mindset. Le désinstalleur de
Nevermind te demande alors si tu gardes tes données (gardées si tu ne coches rien), et Mindset te dit à la fin ce qui a
été gardé. Les autres applis gardent toujours leurs données.

Il marche même si Mindset ne démarre plus. Si quelque chose n'a pas pu être retiré, il te le dit : redémarre
l'ordinateur, puis relance la désinstallation.

Nettoyage de secours (installation abîmée) : lance `Desinstaller Mindset.exe -Nettoyer` (ajoute `-SupprimerDonnees`
pour effacer aussi les données). Il peut être relancé sans risque.

## Sécurité des téléchargements

Chaque zip publié (Nevermind, Evermind, Mindcare, Mindset) est accompagné de `<zip>.sig`, sa signature RSA (SHA-256).
Mindset vérifie la signature avec la liste de clés publiques `fichiers\cles-publiques\*.xml` avant d'installer, extrait
depuis la mémoire ce qu'il a vérifié, et refuse tout fichier du zip qui sortirait de son dossier. Un zip non signé n'est
jamais installé. Une signature est acceptée si UNE des clés de la liste la vérifie ; une liste vide, un fichier abîmé, une
clé privée ou une clé de moins de 3072 bits dans la liste, et tout est refusé. Chaque appli livre une copie identique de
la liste (`fichiers\cles-publiques`, vérifiée par son `publier.ps1`) pour ses mises à jour autonomes.

Deux clés sont dans la liste :
- la **clé de tous les jours** (`principale-<date>.xml`) : sa partie privée reste sur le PC, chiffrée pour le compte
  Windows (`%APPDATA%\Mindset-signature`), avec une copie de secours `.msk` protégée par un mot de passe ;
- la **clé de secours** (`secours-<date>.xml`, 4096 bits) : sa partie privée n'est jamais sur le PC, seulement dans un
  fichier `.msk` protégé par un mot de passe, sur deux clés USB rangées hors ligne. Elle ne sert qu'à publier un
  changement de clé quand la clé de tous les jours est perdue ou volée.

```powershell
.\outils\cle.ps1                           # crée la clé de tous les jours (une fois)
.\outils\cle.ps1 -Exporter E:\cle.msk      # copie de secours de cette clé (mot de passe)
.\outils\cle.ps1 -Importer E:\cle.msk      # remet la clé sur un nouveau PC
.\outils\cle.ps1 -Secours E:\secours.msk   # crée la clé de secours (une fois)
.\outils\cle.ps1 -Liste                    # montre les clés de la liste
.\outils\signer.ps1 -Fichier .\Truc.zip    # écrit Truc.zip.sig, à publier avec le zip
```

Après chaque changement de la liste : copier `Mindset\fichiers\cles-publiques` dans `fichiers\` de chaque appli
(Nevermind : `OptiGame\fichiers`), puis publier Mindset et chaque appli (`publier.ps1` refuse une liste différente).

### Changer de clé (prévu, sans urgence)
1. `.\outils\cle.ps1 -Nouvelle` : la clé suivante est créée et ajoutée à la liste. Copier la liste, publier Mindset et
   les applis (encore signées avec l'ancienne clé : tout le monde les accepte).
2. Attendre que ces versions soient installées partout (quelques semaines).
3. `.\outils\cle.ps1 -Basculer` : le PC signe avec la nouvelle clé, l'ancienne quitte la liste. Copier la liste,
   publier Mindset et les applis, puis refaire une copie de secours (`-Exporter`).

### Clé de tous les jours perdue (disque mort, mot de passe de la copie oublié)
1. `.\outils\cle.ps1` crée une nouvelle clé (ajoutée à la liste), puis `.\outils\cle.ps1 -Retirer principale-<ancienne>.xml`.
2. Copier la liste, puis publier Mindset et chaque appli en signant avec la clé de secours :
   `$env:MINDSET_CLE_SECOURS = 'E:\secours.msk'`, les `publier.ps1` habituels (le mot de passe est demandé à chaque
   signature), puis `Remove-Item Env:MINDSET_CLE_SECOURS`.
3. `-Exporter` une copie de secours de la nouvelle clé.

### Clé de tous les jours volée (révocation)
1. Si le PC lui-même est touché (virus), repartir d'un Windows propre avant tout.
2. `.\outils\cle.ps1 -Nouvelle` puis `.\outils\cle.ps1 -Basculer` : la clé volée quitte la liste.
3. Le plus vite possible : copier la liste et publier Mindset et chaque appli signés avec la **clé de secours**
   (`MINDSET_CLE_SECOURS`, comme ci-dessus). Les PC ne connaissent pas encore la nouvelle clé, mais ils connaissent la
   clé de secours. Une fois cette version installée, la clé volée est refusée.
4. Changer le mot de passe GitHub et vérifier la double authentification.

Si c'est la clé de secours qui est perdue ou volée : `-Retirer secours-<date>.xml`, `-Secours` pour en créer une
nouvelle, puis publier normalement (signé avec la clé de tous les jours).

### Les limites, honnêtement
- Avec une clé volée, l'attaquant peut lui aussi signer une version qui livre SA liste (par exemple, seulement sa clé).
  Un PC qui installe sa version avant la nôtre est perdu : seule une réinstallation à la main le répare. La liste ne
  l'empêche pas ; elle permet d'arrêter les dégâts pour tous les PC qui reçoivent notre version d'abord.
- Ce qui réduit ce risque : la clé seule ne suffit pas, il faut aussi pouvoir publier sur les dépôts GitHub de Jordan
  (Mindset ne télécharge que depuis github.com, en HTTPS), d'où l'importance de la double authentification GitHub ; une
  version qui retire la clé volée, une fois installée, la rend inutile, et une version plus ancienne ne peut jamais être
  réinstallée ; la clé de secours hors ligne permet de publier la révocation même si le PC est perdu ou touché.
- La clé de secours est techniquement acceptée pour n'importe quelle version : « seulement pour un changement de clé »
  est une règle, pas une protection du code. C'est pour cela qu'elle reste hors ligne.
- Un PC resté éteint ou sans Internet pendant tout un changement de clé prévu (il n'a pas eu l'étape 1 avant l'étape 3)
  refusera les nouvelles versions : il faudra réinstaller à la main. D'où l'attente de quelques semaines.

## Code signing policy

Mindset.exe et les scripts de Mindset seront signés gratuitement par SignPath.io, avec un certificat de la SignPath
Foundation (demande en cours). Rôles et confidentialité : [Code signing policy](CODE_SIGNING.md).

## Construire

```powershell
.\outils\construire.ps1     # compile Mindset\Mindset.exe et crée release\Mindset.zip
```

## Organisation

```
Mindset\
  Mindset.exe               le programme (compilé depuis outils\lanceur.cs)
  fichiers\Mindset.ps1      le point d'entrée
  fichiers\apps.json        la liste des applis de la suite
  fichiers\modules\         le code, découpé par partie
outils\                     construction
```

Ajouter une appli à la suite : une entrée de plus dans `apps.json` (id, nom, couleur, dépôt GitHub, zip, exe,
mutex, dossier de données, besoin des droits administrateur).

Les réglages et le journal sont dans `%LOCALAPPDATA%\Mindset`.

## Licence

Mindset est sous licence MIT (voir le fichier `LICENSE`) : tu peux lire, réutiliser, modifier et redistribuer le code, en gardant la mention de licence. Les composants d'autres auteurs gardent leur propre licence : WebView2 (Microsoft) et Three.js (MIT), avec leurs fichiers de licence dans le dossier de l'appli.
