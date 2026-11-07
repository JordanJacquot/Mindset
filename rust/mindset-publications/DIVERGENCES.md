# Bloc « publications » : différences voulues avec la version PowerShell

La référence est Mindset 2.18 (`Mindset/fichiers/modules` : paquets.ps1, signature.ps1, installations.ps1:196-229,
accueil.ps1:487-541, zone.ps1:11-19, mindset.ps1:196-244 et 360-369). Tout le reste est identique et vérifié par les
juges (`tests/juges/*.json`, exportés par `outils/exporter-juges-publications.ps1`, rejoués par `src/juges.rs`).

## Défauts corrigés

1. **Mindset lui-même refusé par GitHub (403 ou 429) : réessai dans 30 minutes, plus de boucle.**
   Version PowerShell : `$script:DernieresPublications = (Get-Date).AddHours(-5.5)` (mindset.ps1:220), commentée
   « réessai dans 30 minutes ». C'était vrai quand la recherche automatique tournait toutes les 6 heures ; aujourd'hui
   elle tourne toutes les heures (accueil.ps1:533, `TotalHours -ge 1`) : avec -5,5 h, la minuterie de 2 secondes
   relançait TOUTE la recherche (une question par appli + Mindset) au passage suivant, encore et encore tant que GitHub
   refusait, ce qui entretient justement le refus. Ici : -0,5 h, comme pour les applis (installations.ps1:207).
   Test : `bloc::tests::mindset_refuse_par_github_reessai_dans_30_minutes`.
   Conséquence à connaître : la version PowerShell appliquait aussi cette règle à une erreur du TÉLÉCHARGEMENT de
   Mindset (`$Erreur` de Start-VerifMajMindset, qui contient « 403 » aussi dans « la version 1.403.0 est invalide »).
   Le téléchargement est au bloc « lui-même » et ne peut pas reculer cette heure (aucun signal pour cela) : seule la
   question à GitHub, faite ici, compte.

## Organisation (même résultat pour l'utilisateur)

2. **La question pour Mindset lui-même est posée par ce bloc**, à chaque recherche, avec celles des applis
   (`publications["mindset"]`, `Get-Publication 'JordanJacquot/Mindset' 'Mindset.zip'`, sans canal d'essai comme
   avant). Le signal `verifier-mindset` part au même moment que `Start-VerifMajMindset` partait ; la réponse arrive par
   `publications-changees { id: "mindset" }`, et `recherche.mindset_en_cours` dit qu'elle est en route. Le bloc
   « lui-même » télécharge et vérifie (`telechargement::telecharger_signe` fait exactement ce travail, s'il veut s'en
   servir par le coordinateur ou une copie dans suite-commun).
3. **La recherche du démarrage part au premier `tic`** (juste après l'ouverture de la fenêtre) et non au chargement
   d'accueil.ps1 (juste avant) : c'est seulement là que le bandeau d'installation (`mindset.bienvenue`, du bloc
   « lui-même », démarré après celui-ci) est connu. Quelques millisecondes d'écart.
4. **Le retour depuis l'horloge** (`Show-Fenetre`, zone.ps1:14) : déclenché par le signal `fenetre` de l'hôte quand la
   fenêtre passe de cachée à montrée, quelle qu'en soit la cause (l'icône, un deuxième lancement). Même règle :
   15 minutes depuis la dernière recherche.
5. **Le bouton « Actualiser » de la console** : `actualiser { clic: true, console: true }` fait envoyer ici le
   `message-console` (« Recherche des nouvelles versions... » ou « Tout vient d'être vérifié »), que console.ps1:523-527
   envoyait lui-même. Champ ajouté au signal (permis : on ajoute, on ne retire pas).
6. **`recherche`** (tableau commun) a en plus `texte` (celui d'`Update-InfoActualiser`), `auto` (`VerifVersions`),
   `en_attente` (`{ id: moment }`, toutes les questions sans réponse) et `mindset_en_cours` ; `en_cours` ne garde que
   les questions de moins de 2 minutes (le filtre que console.ps1:424 faisait) ; `depuis` vaut `null` tant qu'aucune
   recherche n'est partie (`[datetime]::MinValue` dans la version PowerShell).
7. **`MINDSET_SANS_RESEAU`** (variable de test de la version PowerShell) n'existe plus : la construction d'essai de
   l'hôte ne branche aucun réseau, et les tests ont le faux GitHub.
8. **`BlocPublications`** est aussi une constante (le bloc neuf), pour que `Box::new(mindset_publications::BlocPublications)`
   de `blocs()` (mindset-appli, gelé) reste valable maintenant que le bloc a un état. À l'intégration, on peut écrire
   `BlocPublications::default()` et retirer la constante.

## Le réseau (le vrai port, WinHTTP au lieu de .NET)

9. **Seulement GitHub, en https** : le vrai réseau refuse toute adresse hors de `api.github.com`, `github.com`,
   `objects.githubusercontent.com` et `release-assets.githubusercontent.com` (port 443, sans « @ »), même après une
   redirection (`src/port.rs`). .NET suivait une redirection de l'API ou d'une page vers n'importe où (50 au plus) ;
   ici 10 au plus, chacune revérifiée. `Get-Octets` reste comme avant : il suit lui-même 5 redirections, revérifiées
   par `Test-AdresseTelechargement`.
10. **Une réponse de l'API, du flux ou d'une page de plus de 32 Mo est refusée** (la version PowerShell n'avait pas de
    plafond pour elles ; une liste de 30 versions fait quelques centaines de Ko). Les zips gardent 200 Mo et
    10 minutes.
11. **Les messages d'erreur** : pour une réponse 400 ou plus, le texte de .NET en français,
    « Le serveur distant a retourné une erreur : (404) Introuvable. » (raison écrite pour 400, 401, 403, 404, 429,
    500, 502, 503 ; sans raison pour les autres codes, là où .NET reprenait celle du serveur). Sans réponse du tout : le
    texte de .NET pour les erreurs courantes de WinHTTP (délai, nom introuvable, connexion impossible, connexion
    coupée, certificat), sinon celui de Windows. Ces textes ne servent qu'au journal, à « GitHub injoignable » (qui ne
    les lit pas) et à la règle 403/429, qui reste juste. Les juges utilisent la même table (Get-MessageHttp de
    l'exportation).
12. **Les textes reçus sont lus en UTF-8** (marque d'encodage retirée). `Invoke-RestMethod` de PowerShell 5.1 lisait
    en ISO-8859-1 une réponse sans « charset » ; GitHub en envoie toujours un (UTF-8).
13. **Une redirection relative** (`Location: /x`, `../x`) est résolue selon la RFC 3986 (schéma et hôte en
    minuscules, `.` et `..` retirés), sans le réencodage complet de `Uri.AbsoluteUri` ; l'adresse obtenue est de toute
    façon revérifiée.

## Cas qui n'arrivent pas avec GitHub (notés pour être complets)

14. **Chiffres non ASCII** dans un nom de version (« v١.٢ ») : .NET les prend pour des chiffres (`\d`) puis `[version]`
    lève une erreur (le travail échoue). Ici : seulement 0 à 9, la version est ignorée. Même chose pour un nombre plus
    grand que 2147483647 : la préversion est ignorée (`Get-Preversion`), et le flux atom entier ne donne rien
    (`Get-PreversionSansApi`, c'est alors la version normale) au lieu d'une erreur.
15. **`releases/latest` qui répondrait un tableau JSON** : PowerShell lirait les champs de chaque élément (énumération
    des membres) ; ici, aucun champ : « La dernière version publiée ne contient pas ... ».
16. **`&#xD800;`** (une moitié de caractère) dans des notes : .NET la garde telle quelle, une chaîne Rust ne le peut
    pas : U+FFFD. Des notes coupées à 4000 caractères au milieu d'un émoji : la moitié n'est pas gardée (3999).
17. **« İ » (I avec un point) dans une balise HTML** des notes (`<dİv>`) : .NET en français le lit comme « i », pas la
    bibliothèque `regex`. (Pour les adresses, `Test-AdresseTelechargement` fait comme .NET : İ vaut i, juge à l'appui.)
18. **Noms des fichiers d'une version comparés sans les majuscules** par `to_lowercase` (PowerShell : comparaison
    « linguistique » de .NET, qui confond aussi « é » et « e + accent combiné »). Identique pour des noms ASCII.
