# Bloc « paramètres » : les différences voulues avec la version PowerShell

Référence : `Mindset/fichiers/modules/parametres.ps1`, `themes.ps1`, `packs.ps1`, `Watch-ThemeSuite` (accueil.ps1),
version 2.18.0. Les juges (`tests/juges/*.json`, exportés par `outils/exporter-juges-parametres.ps1`) rejouent les
vraies fonctions ; chaque écart ci-dessous est écrit aussi dans le test qui le tolère.

1. **Couleurs d'un pack illisibles** : la lecture d'un pack est celle de `suite_commun::themes` (comme Mindcare). En
   plus de `Test-CouleursPack`, elle refuse des couleurs qui rendent le texte illisible (contraste du W3C) et un NH ou
   NS qui n'est pas un nombre (PowerShell s'arrêtait sur une erreur). Le pack garde alors son thème de base, comme
   pour des couleurs mal écrites, et la même ligne est notée au journal. Aucun cas des juges n'est touché.
2. **Dossier de pack en majuscules** (`packs\Beta`) : PowerShell le lisait (`-notmatch` ne tient pas compte des
   majuscules), mais `pack:Beta` écrit dans suite.json est refusé par toutes les applis de la suite : ce n'est plus
   un thème proposé. Un import crée toujours un id en minuscules. Juge « thèmes installés ».
3. **Un pack.json qui n'est pas un objet** (`5`, `[]`) : PowerShell en faisait un thème nommé comme son id ;
   suite-commun le refuse (thème illisible). L'import répond alors « Le réglage de ce thème pour Mindset
   (pack-mindset.json) est illisible. ».
4. **Messages de Windows** : le texte entre parenthèses d'une erreur du disque (« pas encore retiré (...) »,
   « Pack x illisible : ... ») est en mots simples (« fichier utilisé par un autre programme »...) au lieu du message
   de .NET. Un fichier qui n'est pas un zip : « Ce fichier n'est pas un zip lisible. ». Les juges comparent tout le
   reste de la ligne.
5. **Accents dans le nom d'un zip** : `Normalize(FormD)` est remplacé par une table des lettres accentuées latines
   (à, é, ç, ñ, ü, ŷ...). Les lettres sans décomposition (ø, æ, œ, ß) restent, et le nom est refusé, comme avant.
   300 noms tirés au hasard + 17 écrits : mêmes réponses.
6. **Page demandée** (afficher-page.txt) : `appli:Evermind` ouvre l'appli sous son vrai id (`evermind`), et
   `PARAMETRES:MAJ` ouvre l'onglet `maj` (PowerShell gardait les majuscules dans l'id).
7. **Consommation** : les dossiers WebView2 reconnus sont ceux de Mindset 3.0 (`<données>\WebView2-Tauri\`, toutes
   les applis Tauri) et l'ancien `<données>\WebView2\` ; plus `console-webview` (la console 3D de 2.18 n'existe plus).
   La mesure tourne dans un travail de fond (2 s, seulement onglet à l'écran, comme avant).
8. **Images des thèmes** (cartes et console) : au lieu d'un PNG redessiné en `data:` par WPF
   (`Get-ImageThemeConsole`), l'image du pack est servie telle quelle par `http://fichier.localhost/theme-<id>.<ext>`
   (`Effet::Exposer`) avec son nombre d'images, sa largeur et sa hauteur (`vignette`) : la page découpe la première
   image. Même règle qu'avant (mascotte, sinon logo ; une mascotte plus de deux fois plus large que haute laisse la
   place au logo).
9. **Importer un thème** : la fenêtre de Windows et l'import tournent dans un travail de fond (la fenêtre attend
   l'utilisateur sans bloquer les autres blocs).
10. **Mini-installateur** : le remplacement de l'ancienne tâche et la remise en ordre des tâches sont faits par le
    bloc « installations » (demande de l'intégration) ; ce bloc lit seulement `admin.tache` et `admin.remplacement`
    pour le bandeau (visible si la tâche manque, ou si le remplacement a échoué), et envoie `admin-demande`
    « taches » pour « Activer ». `Test-TachesAnciennes` (schtasks) n'est plus ici.
11. **AnimationsInfo** (« La console 3D ne peut pas s'afficher sur ce PC (...) ») : écrit seulement si le bloc
    « console » publie `console.possible = false` avec un champ `raison` (à ajouter par lui).
12. **État en plus** (champs ajoutés, aucun retiré) : `parametres.onglet`, `onglets`, `couleurs` (la palette Néon
    traduite, pour la page), `apparence.themes[].bord`, `police`, `vignette`, `maj.mindset.texte_page` (« X prête :
    voir l'accueil », le texte de la page WPF).
13. **Page HTML** : SemiBold d'interface.xaml est dessiné en épaisseur normale (400) : WPF ne sait pas prendre les
    épaisseurs de la police variable « Segoe UI Variable Text » (mesuré par le bloc horloge, vérifié sur les
    captures). Les cases et boutons ronds imitent ceux de Windows (thème Aero2).
