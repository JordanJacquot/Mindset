# Bloc « liste » : les différences voulues avec la version PowerShell

La référence est Mindset 2.18.0 (`Mindset/fichiers/modules/liste.ps1`, `applis.ps1`). Tout le reste est à
l'identique, prouvé par les juges (`tests/juges/*.json`, exportés par `outils/exporter-juges-liste.ps1` depuis les
vraies fonctions PowerShell, et rejoués par `tests/juges.rs`).

## 1. Un défaut corrigé : une liste gardée n'était jamais remplacée

`Add-ListeEnLigne` écrit la signature puis la liste à côté (`.tmp`), puis appelle
`[IO.File]::Replace($tmp, $x[0], $null)` quand le fichier existe déjà. PowerShell change ce `$null` en chaîne vide
pour un paramètre texte de .NET, et `Replace` échoue :

> Exception lors de l'appel de « Replace » avec « 3 » argument(s) : « Le chemin d'accès n'a pas une forme conforme. »

Conséquence chez les utilisateurs d'aujourd'hui : une fois une liste en ligne gardée (ou seulement sa signature),
aucune liste plus récente ne la remplace jamais (refus noté au journal toutes les 6 heures, et un
`apps-en-ligne.json.sig.tmp` laissé dans le dossier des données). La version Rust remplace le fichier (`rename`).

Preuve : l'export joue chaque cas deux fois, tel quel puis avec ce seul appel corrigé (`[NullString]::Value`). Le juge
est la version corrigée ; la réponse d'aujourd'hui est gardée dans `divergence_ps`. 12 cas la montrent (6 dans
`listes.json`, 6 dans `hasard.json`), tous avec ce message, et le test
`seule_divergence_le_remplacement_de_la_liste_gardee` vérifie qu'il n'y a aucune autre différence. À corriger aussi
dans la version PowerShell si une 2.18.x doit encore sortir (même remplacement dans `liste.ps1`).

Aussi : si le renommage échoue, le `.tmp` est effacé (la version PowerShell le laissait).

## 2. Les messages qui viennent de .NET

Les textes de Mindset sont repris mot pour mot. Ceux que .NET écrit lui-même ne peuvent pas l'être :
- apps.json illisible : `apps.json illisible : <message>` au journal ; le début est le même, le message après les
  deux-points est celui de Rust (fichier introuvable, « JSON abîmé ») au lieu de celui de .NET ;
- l'écriture de la liste gardée impossible (disque plein, fichier pris) : le message d'erreur de Windows vu par Rust ;
- le téléchargement : `le serveur a répondu 404 pour <adresse>`, ou le message du réseau (bloc publications), au lieu
  du texte de `WebException` (« Le serveur distant a retourné une erreur : (404) Introuvable. »).

## 3. La lecture d'une entrée : des cas extrêmes

- `\d` de .NET accepte tous les chiffres d'Unicode (arabes, devanagari...) dans `cache_depuis` et
  `sans_droits_depuis` : la version Rust n'accepte que 0 à 9 (plus stricte : une telle version n'existe pas).
- `\w` de .NET (lettres, chiffres décimaux, marques, traits de liaison) est rendu par `char::is_alphanumeric` de Rust
  et les traits de liaison : quelques caractères très rares (chiffres en exposant comme « ² ») sont pris par Rust
  dans un dépôt, un script ou un verrou, refusés par .NET. Aucune liste réelle n'en contient.
- `logo_epaisseur` à « NaN » : .NET donnait une épaisseur « NaN » ; Rust prend l'épaisseur par défaut (12).
- `ConvertFrom-Json` de PowerShell 5.1 accepte quelques écritures qui ne sont pas du JSON (guillemets simples...) ;
  Rust les refuse (apps.json : illisible ; liste en ligne : « JSON abîmé », donc refusée). Les listes signées sont
  écrites par `outils\publier-liste.ps1` avec `ConvertTo-Json` : du JSON normal.
- Un nombre écrit à la place d'un texte (`"cache_depuis": 1.50`) : PowerShell garde « 1.50 », Rust écrit « 1.5 ».

## 4. Le reste

- Les 6 heures entre deux recherches (et le réessai dans une heure) sont comptées sur le temps écoulé depuis le
  lancement de Mindset (`ctx.ecoule()`), pas sur l'heure du PC : changer l'heure de Windows n'y fait rien.
- `MINDSET_LISTE_URL` (une liste lue dans un fichier, en test) n'existe plus : les tests ont le faux GitHub du noyau.
- En essai (`ctx.essai`), `%LOCALAPPDATA%` dans le dossier de données d'une appli est le dossier d'essai, et les
  autres variables sont inconnues : jamais les vraies données d'une appli (la version PowerShell en test prenait les
  vraies variables).
- La liste vide parce qu'apps.json est illisible est publiée comme `{ "source": "apps.json", "numero": null }`.
- Le relevé des applis ouvertes (`ouvertes`) est fait une première fois dès `demarrer`, puis à chaque `tic` (la
  version PowerShell appelait `Test-AppliOuverte` à chaque besoin). Pendant `demarrer`, les installations ne sont pas
  encore connues (le bloc installations démarre après) : seuls les verrous comptent jusqu'au premier `tic`.
- `BlocListe` a maintenant un état (l'heure de la prochaine recherche). L'hôte écrit `Box::new(mindset_liste::BlocListe)`
  dans `blocs()` : une constante du même nom que le type le garde valable (à l'intégration, `BlocListe::default()`
  est plus clair).
