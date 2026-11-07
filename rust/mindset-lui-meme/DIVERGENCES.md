# Bloc « Mindset lui-même » : les différences avec la version PowerShell

La référence est `Mindset/fichiers/modules/mindset.ps1` et le début de `Mindset/fichiers/Mindset.ps1` (2.18.0). Tout ce
qui n'est pas listé ici se comporte pareil, prouvé par les juges (`tests/juges/*.json`, exportés par
`outils/exporter-juges-lui-meme.ps1` depuis les vraies fonctions PowerShell, rejoués par `tests/juges.rs`).

## Un défaut corrigé

1. **`Complete-MajAuto` plantait quand les notes de la version sont vides.** `(... | Select-Object -First 1) -replace
   ...` rend un tableau vide quand aucune ligne n'est remplie, et `.Trim()` sur ce tableau lève « [System.Object[]] ne
   contient pas de méthode nommée « Trim » ». Preuve : les cas du juge `bulles.json` qui ont un champ `erreur`
   (notes vides, faites d'espaces ou absentes). Conséquence en 2.18 : une mise à jour automatique réussie sans notes
   ne montrait pas sa bulle, et `Stop-Operation` s'arrêtait avant le message de la carte et la relance de l'appli.
   Ici : la bulle part, avec son texte par défaut (« Mise à jour faite toute seule. »). Le test le vérifie.

## Ce qui change parce que Mindset n'est plus en PowerShell

2. **La bascule administrateur** (Mindset.ps1:54-72) refait les tâches avec `MindsetInstallateur.exe -Action taches
   -Destination <inscrit> -Sid <sid> -Resultat <%TEMP%\mindset-taches-<pid>.json>` (le mini-installateur Rust, à
   côté de Mindset.exe) au lieu de `powershell.exe installer-admin.ps1 -Action taches`. Même attente (60 s), même
   relance par `explorer.exe "<Mindset.exe>"`, mêmes marques de 2 minutes. Juge : `bascule.json`.
3. **La mise à jour par la demande de Windows** (`Start-MajMindsetDirecte`) passe, comme celle par la tâche, par
   la file du bloc « installations » (signal `admin-demande`, `resultat` = `telechargements\maj-mindset.json`), qui
   lance `MindsetInstallateur.exe` en « runas » au lieu de `powershell.exe installer-admin.ps1`. Mêmes paramètres
   que 2.18, dans le même ordre : sans `Id` ni `Cache` (le mini-installateur les refuse en direct), avec `Sid`.
   Mindset se ferme dès qu'elle est lancée (`admin-recu { direct: true }`), sans écrire `MajMindsetDemande` (la
   réponse est dans le fichier), comme avant. Par la tâche : `Id` (l'id du bloc), `Zip`, `Signature`,
   `Destination`, `Version`, `AttendrePid`, `Cache` : exactement le contenu de 2.18. `repli` est vrai pour une mise
   à jour demandée à l'écran, faux en automatique. Le refus pour les variables `COR_*`, `COMPlus_*`, `DOTNET_*`
   (`Get-RefusVariablesAdmin`) visait le PowerShell administrateur (.NET) ; il est au port du bloc
   « installations » s'il le garde.
4. **Le mode test de Mindset.ps1** (`MINDSET_TEST` ignoré en administrateur dans une copie protégée, lignes 20-31)
   n'existe plus : la version Rust n'a pas de variables de test, la construction d'essai est un autre programme.
   En essai (`ctx.essai`), le bloc fait comme `$EnTest` : pas de mise à jour automatique, pas de recherche de
   Mindset, pas d'applis lancées, pas de désinstalleur lancé, pas de bandeau de bienvenue ; les variables
   `MINDSET_BIENVENUE`, `MINDSET_MAJ_TEST`, `MINDSET_MAJAUTO_TEST` les permettent comme avant.

## Ce qui change parce que Mindset est découpé en blocs

5. **La publication de Mindset** (`Get-Publication 'JordanJacquot/Mindset' 'Mindset.zip'`) n'est plus cherchée par
   ce bloc : c'est le bloc « publications » qui la met dans `publications.mindset` du tableau commun. Ce bloc la lit
   à `verifier-mindset` (et à `publications-changees` quand elle a changé), puis télécharge et vérifie le zip
   lui-même, comme avant. La pause de 30 minutes après une réponse 403 ou 429 de GitHub
   (`$script:DernieresPublications`) est au bloc « publications ». Si aucune publication n'arrive en 2 minutes, la
   recherche s'arrête (avant, `Get-Publication` était dans la même tâche et finissait toujours) : la suivante pourra
   partir.
6. **L'historique des mises à jour** est relu à chaque fois au lieu d'être gardé en mémoire après la première
   lecture : le bloc « installations » peut y ajouter une entrée de son côté. Même contenu, mêmes règles (juge
   `historique.json`).
7. **`Show-BulleMajAuto`** : « la console est prête » (`$script:Console.Pret`) devient « la console est possible »
   (`console.possible` du tableau commun) ; à l'écran avec la console : `message-console`, sinon la bulle près de
   l'horloge (`bulle`, 6 s, icône info).
8. **`Get-EtatCarte`** (pour `Invoke-MajAuto`) : « ouverte » vient du relevé du bloc « liste » (`ouvertes`, relu toutes
   les 1,5 s) au lieu d'un `Test-AppliOuverte` à l'instant.
9. **`Start-Demarrage`** : ce bloc fait les raccourcis de Mindset, la marque `relance.marque` et le lancement des
   applis « S'ouvre avec Mindset » (signal `lancer-appli { demarrage: true }`). `Update-RaccourcisApplis`,
   `Repair-DemarrageApplis` et `Move-TachesDemarrage` sont au bloc « installations ». Il est fait au premier `tic`
   (la fenêtre existe), comme après `$Window.Show()`.
10. **Les trois fins de `Send-DemandeInstallation`** (`Recu`, `Fin`, `Repli`) : `admin-recu` fait le `Recu`
    (`MajMindsetDemande` par la tâche, journal, Mindset se ferme), `admin-fini` fait la `Fin` ; une réponse « la
    tâche d'installation ne répond pas » sans accusé de réception (ou `sans_tache: true`) fait le `Repli` d'une
    mise à jour automatique : l'échec, sans demande de Windows. Juge : `maj-mindset.json`.

## Petites différences assumées

11. **Les disques** sont écrits au format fr-FR (« 1 500 Go libres », espace fine insécable U+202F, arrondi loin de
    zéro), celui des utilisateurs de Mindset ; avant, c'était la culture du PC.
12. **Le disque choisi** dans le bandeau de bienvenue est vérifié : seulement un disque proposé, sinon C:.
13. **L'id d'une demande** est fait de 32 chiffres hexadécimaux tirés au hasard (`RandomState`), au lieu d'un GUID :
    même forme, vérifiée par le mini-installateur.
14. **`MajMindsetDemande`** au lancement (Mindset.ps1:120) est lu comme PowerShell : vrai ou faux au sens de
    `-not (Get-Setting ...)` (0 et « » sont faux). Juge : `lancement.json`.

## Ce dont ce bloc a besoin des autres (à l'intégration)

- **Hôte** (`mindset-appli`) :
  - la marque « rouvert caché » (Mindset.ps1:47-51) rend Mindset « lancé avec Windows » : `avant_tout` la lit et
    `mindset_lui_meme::demarrage_force()` le dit. Fait à l'intégration (07/11) : l'hôte met alors
    `Lancement::demarrage` à vrai pour tous les blocs et ne montre jamais la fenêtre (programme.rs) ;
  - relancé avec `-Demarrage` après une mise à jour demandée à l'écran (`MajMindsetVisible`), le bloc demande
    `Effet::Fenetre(Montrer)` : la fenêtre est créée cachée puis montrée. Même résultat, sans changer l'hôte ;
  - le journal : l'hôte écrit « Démarrage Mindset 3.0.0 (Rust), lancé avec Windows » AVANT `demarrer`. Quand
    « Mindset se lance avec Windows » est coupé, la version PowerShell s'arrêtait avant cette ligne
    (`tester-maj-demarrage.ps1` vérifie qu'elle n'y est pas). Fait à l'intégration (07/11) : la ligne est
    écrite après les `demarrer`, pas du tout si un bloc a demandé de quitter, sans « lancé avec Windows » si un
    bloc montre la fenêtre (`Hote::ligne_demarrage`, tests/integration.rs de mindset-appli).
- **Bloc « installations »** (branche rust-complet-installations, relue en lecture seule) : il fait déjà
  `admin { tache, en_cours }`, `operation-finie` avec `historique { id, nom, version, auto, notes }`, `admin-recu`
  (aussi `{ direct: true }` quand la demande de Windows est lancée), le repli selon `repli`, `resultat`, et le
  message de la carte (`raison_echec_maj` recopiée). À savoir à l'intégration : il donne à la demande un `Id` à lui,
  remplacé par le paramètre `Id` que ce bloc passe (il doit le rester : c'est par cet Id que `Resultat` est reconnu
  au redémarrage) ; `relance.marque` est effacée par ce bloc seulement, à son premier `tic` : le bloc
  « installations » la lit au sien, qui passe avant (ordre de `blocs()`) ; à garder ainsi à l'intégration.
- **Bloc « publications »** : `publications.mindset` (`version`, `url_zip`, `url_sig`, `notes`, ou `erreur`), et le
  signal `verifier-mindset` dans `Invoke-Actualiser` (seulement si « Chercher les nouvelles versions » est activé et
  le bandeau de bienvenue fermé : `mindset.bienvenue`).
- **Blocs « console », « paramètres », « écrans »** : les formes publiées par ce bloc, avec des champs en plus :
  - `mindset` : `{ installe, developpement, bienvenue, maj, derniere_maj, historique, verif, auto }` ; chaque entrée de
    l'historique a `appli { id, nom, couleur }` (`Get-AppliMaj`), `quand_texte` et `quand_long` (`Format-QuandMaj`,
    « aujourd'hui » en minuscule : la page des Paramètres met la majuscule) ;
  - `maj-auto` : `{ en_cours, echecs { version, raison, reessai }, jeu, jeu_nom, attentes, essais { version, nombre,
    reessai } }` (`reessai` : `Get-MajAutoReessai` brut ; la console le passe à -1 si les mises à jour automatiques
    ne sont pas possibles, comme `Get-EtatMajConsole`) ;
  - « Mettre à jour » sur la carte de la console : signal `maj-mindset { confirmer: true }` (la question
    `Confirm-MajMindsetConsole`) ; « Désinstaller Mindset » : `desinstaller-mindset` ; le lien « En savoir plus »
    du bandeau de bienvenue : action `lui-meme:confidentialite` (« ») ou signal `confidentialite`.
- **Chaîne** : le zip 3.0 doit avoir `MindsetInstallateur.exe` et `Desinstaller Mindset.exe` à côté de
  `Mindset.exe`, et `fichiers\cles-publiques` (signature de la mise à jour).
