# Le corpus de cas

Les cas qui jugent les parties sensibles de la suite, écrits en données : une entrée, et ce qui est attendu. Les mêmes
fichiers sont passés à la version PowerShell d'aujourd'hui (par les tests de `outils\`) et le seront à la version Rust
(par `cargo test`, au travers d'une couche « Windows » remplaçable). Ainsi, les deux versions passent exactement les
mêmes cas (plan Rust, 3.5).

- `cas\installateur\` (ce dépôt) : l'installateur de Mindset et le côté Mindset de son protocole. Depuis l'étape 2,
  l'installateur livré est `MindsetInstallateur.exe` (`rust\mindset-installateur`, jugé par `cargo test`, qui lit
  lui-même ce dossier : `tests\corpus.rs`) ; sa version PowerShell d'avant reste jugée sur les mêmes cas
  (`outils\installer-admin-powershell.ps1`, par `tester-installer.ps1`).
- `cas\aide\` (dépôt Nevermind) : l'Aide de Nevermind. Même format.

## Le format (commun à cas\aide et cas\installateur)

Un fichier par sujet, en UTF-8, un objet JSON :

| Champ | Sens |
|---|---|
| `format` | 1. Changé seulement si un champ change de sens. |
| `sujet` | Ce que le fichier vérifie, en une phrase. |
| `regle` | Où est la règle dans le code PowerShell d'aujourd'hui (fichier, fonction, arguments). |
| `attendu` | Le sens des champs de `attendu` dans les cas. |
| `valeurs` | Facultatif. Les valeurs écrites `{nom}` dans les cas, remplacées partout (textes, noms de champs, au milieu d'un chemin), avec ce qu'elles valent sur le PC d'essai. Une `{valeur}` inconnue fait échouer le test. |
| `champs`, `note` | Facultatifs. Explications. |
| `base` et `fusion` | Facultatifs. Une base commune (par exemple `base.demande`) que chaque cas complète : un champ du cas remplace celui de la base (la valeur entière), un champ à `null` le retire. `fusion` le redit en une phrase. |
| `cas` | La liste des cas. |

Un cas :

| Champ | Sens |
|---|---|
| `nom` | Texte court, unique dans le fichier ; c'est le nom montré par le test. |
| `entree` | Tout ce qui est donné à la règle. |
| `attendu` | Le résultat attendu. Un champ inconnu fait échouer le test (une faute de frappe ne passe pas en silence). |
| `besoin` | Facultatif. Ce qu'il faut sur le PC d'essai ; sinon le cas est sauté et compté à part. |
| `origine` | Facultatif. D'où vient le cas (constat d'audit, revue). |

Règles :
- chaque test qui lit le corpus vérifie un nombre minimum de cas par fichier : un cas retiré, ou un fichier vidé, le
  fait échouer. Ajouter un cas : l'écrire dans le fichier, puis monter le minimum dans le test ;
- chaque fichier du dossier doit être lu par un test (sinon le test échoue) ;
- aucun chemin du vrai PC : seulement des `{valeurs}` ou des chemins inventés ;
- ce qui ne s'écrit pas en données reste dans le test (voir plus bas).

## cas\installateur

| Fichier | Lu par | Cas | Ce qu'il juge |
|---|---|---|---|
| `demande.json` | `tester-installer.ps1` et `cargo test` | 31 | La demande lue par la tâche SYSTEM : taille, numéro, action, paramètres ignorés, dossier venu de la tâche |
| `appli.json` | `tester-installer.ps1` et `cargo test` | 66 | Installer une appli : dossier, noms, appli et partie administrateur venues de apps.json, versions |
| `mindset.json` | `tester-installer.ps1` et `cargo test` | 16 | Installer Mindset (lancement direct) |
| `mindset-maj.json` | `tester-installer.ps1` et `cargo test` | 9 | Mettre Mindset à jour, et le relancer |
| `taches.json` | `tester-installer.ps1` et `cargo test` | 11 | Les tâches de Mindset, les tâches d'aide d'avant refaites en SYSTEM |
| `supprimer.json` | `tester-installer.ps1` et `cargo test` | 11 | Supprimer une appli ou Mindset |
| `systeme.json` | `tester-installer.ps1` et `cargo test` | 12 | En SYSTEM, rien ne vient de l'utilisateur ; accusé de réception |
| `ancienne-tache.json` | `tester-installer.ps1` et `cargo test` | 5 | L'ancienne tâche (Mindset 2.9.0 et avant) ne sert qu'à se remplacer |
| `prise-en-charge.json` | `tester-installer.ps1` et `cargo test` | 9 | Les tâches qui lançaient une ancienne copie de l'appli |
| `programmes.json` | `tester-installer.ps1` et `cargo test` | 6 | Les programmes fermés : par leur chemin, ceux de l'utilisateur |
| `dossier-protege.json` | `tester-securite.ps1` et `cargo test` | 20 | Les dossiers acceptés (Test-DossierMindset) |
| `cote-mindset-tache.json` | `tester-mini-installateur.ps1` | 5 | Côté Mindset : quelle tâche d'installation est utilisée |
| `cote-mindset-variables.json` | `tester-mini-installateur.ps1` | 9 | Côté Mindset : variables lues par .NET, pas de demande de Windows |
| `cote-mindset-arguments.json` | `tester-mini-installateur.ps1` | 3 | Côté Mindset : une valeur passée par la demande de Windows arrive telle quelle |
| `cote-mindset-taches-anciennes.json` | `tester-mini-installateur.ps1` | 4 | Côté Mindset : les tâches d'avant vues au démarrage |

Les fichiers `dossier-protege.json` et `cote-mindset-*.json` ont leurs propres champs, décrits dans leur en-tête
(`attendu`, `champs`). Les dix premiers suivent le schéma ci-dessous.

### Le schéma des cas de l'installateur (tester-installer.ps1)

Le faux PC, remis à zéro avant chaque cas : Program Files de test avec Mindset 1.0.0 (`{pm}\Mindset`) et une appli
1.0.0 (`{pm}\Appli`, programme `Appli.exe`, partie administrateur `Aide.exe` et sa tâche « Appli (aide) ») ; la version
gardée de l'appli (HKLM, `Versions\appli`) à 1.0.0 ; un dossier `{tmp}\victime` hors de Mindset ; un faux disque fixe
NTFS `{x}:` vide et un faux disque amovible `{xa}:` ; des zips signés par une clé de test dans le dossier
`telechargements` de l'utilisateur. Son apps.json : `appli` (dossier du zip `Appli`, ancien `AncienAppli`, partie
administrateur), `autre` (sans partie administrateur), `piege` (un nom piégé, `..\Mindset`).

`entree` :

| Champ | Sens |
|---|---|
| `lancement` | `tache` : comme la tâche SYSTEM (`-Action demande -Sid <utilisateur> -Demande <fichier>`) ; `ancienne-tache` : pareil sans `-Sid` ; `direct` : comme la demande de Windows, la demande est passée en paramètres. |
| `demande` | La demande (un objet). Par la tâche, elle est écrite dans un fichier `.demande` en JSON et porte un `Id` neuf (`{id}`) sauf si le cas en donne un, ou le retire avec `null`. |
| `demande_texte` | À la place de `demande` : le texte exact du fichier (une demande illisible). |
| `demande_absente` | Vrai : le fichier de demande n'existe pas. |
| `taille` | Le fichier est complété par des espaces jusqu'à cette taille exacte, en octets. |
| `sid` | Le `-Sid` passé par la tâche (par défaut `{sid}`, l'utilisateur du test ; `null` : aucun). |
| `sans_resultat` | Vrai : pas de fichier de réponse `-Resultat` (comme la vraie tâche). |
| `contexte` | L'état du faux PC propre au cas (ci-dessous). |

`entree.contexte` :

| Champ | Sens |
|---|---|
| `fichiers` | Fichiers créés avant le cas : chemin -> contenu. |
| `copier` | Fichiers copiés avant le cas : source -> destination. |
| `retirer` | Fichiers ou dossiers retirés avant le cas. |
| `version_gardee` | La version de l'appli gardée dans HKLM (`null` : aucune). |
| `racine` | Les droits du dossier des programmes : absent, il est protégé ; `ouverte` : modifiable par les utilisateurs ; `proprietaire` : il appartient à l'utilisateur. |
| `aide_ancienne` | Vrai : des tâches d'aide d'avant (Mindset 2.10.0) existent, sous le compte de l'utilisateur, d'un autre compte, vers un programme hors du dossier protégé, et déjà en SYSTEM. |
| `taches_restantes` | Vrai : une tâche de Mindset ne part pas quand on la retire. |
| `demarrage_ko` | Vrai : la tâche de démarrage de Mindset ne se lance pas. |
| `sid_tache` | L'utilisateur de l'ancienne tâche « \Mindset\Mindset (installation) ». |
| `recu` | L'accusé de réception déjà écrit dans HKLM (une demande déjà reçue). |

`attendu` (chaque champ est vérifié s'il est présent) :

| Champ | Sens |
|---|---|
| `reponse` | `ok` (`ok = true`), `refus` (`ok = false`) ou `aucune` (ni dans le registre, ni dans un fichier : la demande est ignorée sans un mot). |
| `message` | Un texte, ou une liste de textes, présents dans le message de la réponse. |
| `message_exact` | Le message entier. |
| `message_absent` | Un texte qui ne doit pas être dans le message. |
| `id_rendu` | Vrai : la réponse porte le numéro de la demande. |
| `registre` | Vrai : la réponse est écrite dans HKLM (par la tâche) ; faux : elle ne l'est pas. |
| `rien_fait` | Vrai : aucun fichier créé, modifié ou retiré, et aucune action sur Windows, sauf celles de `actions_permises` (motifs avec `*`). |
| `actions` / `actions_absentes` | Textes présents (ou absents) dans les actions faites sur Windows (journal du faux PC : tâches, registre, droits, programmes arrêtés ou lancés, fenêtres). |
| `actions_absentes_motif` | Expressions régulières qu'aucune action ne doit suivre. |
| `taches_creees` | Tâches créées comme il faut : « Mindset (installation) » et les parties administrateur « ... (aide) » en SYSTEM, avec `-Sid <utilisateur>` dans leurs arguments, et lui seul peut les lancer ; « Mindset (démarrage) » sous le compte de l'utilisateur. |
| `sans_tache` | Vrai : aucune tâche touchée. |
| `versions` | Dossier -> version installée (lue dans `fichiers\<Nom>.ps1`). |
| `existe` / `absent` | Fichiers ou dossiers présents (ou absents) après le cas. |
| `version_gardee` | La version de l'appli gardée dans HKLM après le cas. |
| `erreur` | Vrai : l'installateur s'arrête sur une erreur (paramètres refusés dès le départ). |
| `arrets` | La liste exacte des programmes fermés (leur chemin). |
| `nb_arrets` | Le nombre de programmes fermés. |
| `arrets_absents` | Textes qu'aucun programme fermé ne doit avoir dans son chemin (et aucun chemin vide). |
| `lignes` / `lignes_absentes` | Motifs (avec `*`) présents (ou absents) dans tout le journal. |
| `taches_modifiees` | La liste exacte des tâches réécrites (ligne du journal « tâche modifiée »). |
| `demande_gardee` | Vrai : le fichier de demande est toujours là (l'installateur ne l'efface jamais). |
| `avant` | Deux lignes du journal : la première (exacte) avant la seconde (motif). |

Valeurs : `{tmp}` (le faux PC), `{pf}` (son Program Files), `{pm}` (son Program Files\Mindset), `{x}` et `{xa}` (les
lettres des faux disques), `{zip-appli}`, `{zip-mindset}` (zips signés, 2.0.0), `{sig-fausse}` (signature d'un autre
fichier), `{src-ok}`, `{src-sans-exe}`, `{src-sans-script}` (dossiers source de Mindset), `{sid}`, `{sid-autre}`,
`{programme-installation}` et `{arguments-installation}` (ce que lance la tâche d'installation : powershell.exe de System32 et
`-NoProfile -NonInteractive` pour la version PowerShell, MindsetInstallateur.exe du dossier de Mindset et `-Action demande -Sid`
pour la version Rust), `{ancienne}` (programme d'une ancienne copie de l'appli), `{id}` (numéro
neuf, le même dans tout le cas).

Pour la version Rust : le faux PC est la couche « Windows » de test (journal des mêmes actions), et ces champs se
vérifient de la même façon sur son journal.

## Ce qui reste dans les tests (pas en données)

- `tester-installer.ps1`, 9 cas : la demande par un lien symbolique (un vrai lien sur le disque) ; Register-TacheAide
  seule (programme introuvable) ; trois lectures du texte d'installer-admin.ps1 (dossiers demandés à Windows, aucune
  variable d'environnement, premières lignes) ; deux essais de faux modules en tête de PSModulePath ; deux essais avec
  de vrais programmes lancés puis fermés.
- `tester-mini-installateur.ps1`, 34 cas : les enchaînements dans le temps (tâche muette, accusé, repli sur la demande
  de Windows, mise à jour de Mindset), le remplacement de l'ancienne tâche, la remise en ordre des tâches, la table des
  valeurs (code fabriqué) et les lectures du texte des modules.
- `tester-securite.ps1` : tout le reste (signature, Install-Paquet, téléchargement, mises à jour automatiques, outils de
  clé) ; la signature et l'installation des zips auront leur propre banc d'essai PowerShell contre Rust (étape 0).
