# Règles Tauri de la suite

Ces règles valent pour toute appli de la suite écrite avec Tauri 2 (la première sera Mindcare, à l'étape 3 du plan de
passage en Rust). Elles reprennent le plan (3.1) et sont fixées **avant** l'étape 3. Chaque règle dit pourquoi, et
comment la vérifier : un test des tests GitHub doit **échouer** si elle n'est pas tenue.

Au 26/10/2026, ni Rust ni Tauri ne sont installés : aucune version n'est choisie ici. Les noms de réglages cités
(`tauri.conf.json`, `capabilities/*.json`, `Cargo.toml`) sont ceux de Tauri 2 ; ils sont **revérifiés sur la version
figée** au début de l'étape 3, et ce document est corrigé s'il le faut. Les chemins `Mindset/...` sont relatifs à la
racine du dépôt Mindset, ceux qui commencent par « Nevermind: » à celle du dépôt Nevermind.

Les vérifications sont regroupées dans un test de la suite (« vérifier Tauri »), écrit à l'étape 3 et lancé dans les
tests GitHub de chaque appli Tauri. Il lit les fichiers de configuration ; il ne lance rien sur le PC.

---

## 1. withGlobalTauri coupé

**Règle.** `app.withGlobalTauri` vaut `false` (ou est absent) dans `tauri.conf.json`. Les pages appellent Rust par
un seul petit module du kit (par exemple `ipc.js`), qui fait `invoke` vers les commandes de l'appli.

**Pourquoi.** Avec ce réglage, toute l'API de Tauri est posée sur `window.__TAURI__`, offerte à n'importe quel script
de la page. Sans lui, les appels passent par un seul fichier, court et facile à relire.

**Vérifier.**
- `tauri.conf.json` : le test échoue si `app.withGlobalTauri` vaut `true`.
- Les pages (`ui/**`) : le test échoue s'il trouve `__TAURI__` ailleurs que dans le module d'appel.

---

## 2. Des capabilities par fenêtre, avec seulement les commandes utiles

**Règle.**
- Un fichier `capabilities/<fenêtre>.json` par fenêtre, dont `windows` donne le **label exact** de cette fenêtre :
  jamais `"*"` ni un motif.
- `permissions` est une liste écrite à la main, permission par permission : seulement ce que la fenêtre utilise.
  Pas d'ensemble large sans relecture (par exemple un `...:default` qu'on n'a pas lu).
- Aucune capability `remote` : aucune adresse extérieure n'a accès aux commandes.
- Les commandes de l'appli (`#[tauri::command]`) sont, elles aussi, soumises aux permissions (manifeste de l'appli
  dans `build.rs`, à confirmer sur la version figée) : une fenêtre n'appelle que les commandes de sa liste.

**Pourquoi.** Une page compromise (un texte mal échappé, un fichier de thème piégé) ne peut appeler que ce que sa
fenêtre a le droit d'appeler. Une capability pour toutes les fenêtres annulerait ce cloisonnement.

**Vérifier.**
- Le test lit `capabilities/*.json` et échoue si `windows` contient `*` ou un motif, si une clé `remote` existe, si une
  permission n'est pas dans la liste blanche de la suite, ou si un label de fenêtre a zéro ou plusieurs fichiers.
- Il compare les commandes déclarées dans le code Rust à celles autorisées : une commande qui n'est autorisée nulle
  part, ou une permission vers une commande qui n'existe pas, fait échouer.

---

## 3. Une politique de contenu (CSP) stricte

**Règle.** `app.security.csp` est toujours rempli. CSP de départ :

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' http://pack.localhost data:; font-src 'self' http://pack.localhost; connect-src ipc: http://ipc.localhost; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'
```

- jamais `'unsafe-eval'` ; jamais `'unsafe-inline'` dans `script-src` ;
- aucune source distante (`http://` ou `https://` vers Internet, `*`, `https:`) : tout est rangé dans l'exe ;
- `http://pack.localhost` est le protocole des images de thème (règle 6) ; sous Windows, Tauri sert un protocole
  maison sous la forme `http://<nom>.localhost` (à confirmer sur la version figée, comme l'origine `ipc`) ;
- `data:` seulement pour les images, et retiré si le kit n'en a pas besoin ;
- si le kit pose des styles dans le HTML, `'unsafe-inline'` est toléré dans `style-src` seulement, jamais ailleurs ;
- `devCsp`, s'il existe, est la même ; `dangerousDisableAssetCspModification` est absent (Tauri ajoute lui-même
  l'empreinte de ses scripts à la CSP).

**Pourquoi.** Même si un texte est mal échappé quelque part, la page ne peut ni exécuter du code fabriqué, ni charger
un script venu d'ailleurs, ni envoyer des données sur Internet. C'est la même idée qu'aujourd'hui : la console de
Mindset refuse toute adresse autre que la sienne (`Mindset/fichiers/modules/console.ps1:120-122`).

**Vérifier.** Le test lit la CSP et échoue si elle est vide, si elle contient `unsafe-eval`, `unsafe-inline` dans
`script-src`, `*`, une adresse `http(s)://` autre que `*.localhost`, ou si `dangerousDisableAssetCspModification`
est présent.

---

## 4. Aucun plugin shell ni fs

**Règle.** Ni `tauri-plugin-shell`, ni `tauri-plugin-fs` (ni leurs pendants `@tauri-apps/plugin-shell`,
`@tauri-apps/plugin-fs`). Ce qui demande le disque, un programme ou un lien passe par une **commande Rust de l'appli**,
qui vérifie elle-même ce qu'on lui donne. Par exemple, ouvrir une page : seulement une adresse
`https://github.com/JordanJacquot/...`, comme le fait déjà Mindset (`Mindset/fichiers/modules/applis.ps1:35`).

**Pourquoi.** Ces plugins donnent à la page un accès général au disque ou au lancement de programmes. Une commande
précise ne peut faire que ce pour quoi elle est écrite.

**Vérifier.**
- `Cargo.toml` et `Cargo.lock` : le test échoue s'il y trouve `tauri-plugin-shell` ou `tauri-plugin-fs`. La liste
  blanche de `cargo deny` (plan 3.6) les interdit aussi.
- `package.json` s'il existe, et les pages : pas de `plugin-shell` ni `plugin-fs`.
- `capabilities/*.json` : aucune permission `shell:` ni `fs:`.

---

## 5. Outils de développement coupés en publication

**Règle.**
- La fonctionnalité `devtools` de la dépendance `tauri` est **absente** de `Cargo.toml`.
- Seul un exe construit en `--release` est livré : construction sur GitHub uniquement,
  `cargo build --release --locked`, exe vérifié par `publier.ps1` avant signature (plan 3.6). Un exe de debug a toujours
  ses outils de développement : il n'est jamais livré.
- Aucun appel à l'ouverture des outils de développement dans le code.
- Les réglages de WebView2 restent ceux de la suite : menu du clic droit, zoom, raccourcis du navigateur, saisie
  automatique coupés (`Mindset/fichiers/modules/console.ps1:102-103`,
  `Nevermind: Nevermind/fichiers/modules/vue.ps1:115-116`).
- Aucune variable d'environnement ni option cachée pour les rallumer dans l'exe livré (plan 3.5, point 3).
  Aujourd'hui, Mindset et Nevermind les rallument par une variable en test : cela ne passe pas en Rust.

**Pourquoi.** Les outils de développement permettent d'exécuter n'importe quel code dans la page, avec les droits de
ses commandes.

**Vérifier.**
- Le test échoue si `Cargo.toml` active `devtools` pour `tauri`, ou si le code appelle l'ouverture des outils.
- La construction de publication n'a qu'une commande `--release` ; `publier.ps1` refuse un exe qui ne vient pas de
  cette construction (attestation vérifiée, plan 3.6).

---

## 6. Images des packs lues seulement dans leur dossier

**Règle.**
- Pas d'« asset protocol » de Tauri : `app.security.assetProtocol.enable` est absent ou `false`, sans `scope`.
- Les images et polices d'un thème sont servies par un **protocole maison** (`pack`), écrit dans l'appli, qui :
  - n'accepte qu'un nom de fichier simple : pas de `\`, `/`, `..`, `:` ;
  - calcule le chemin canonique du dossier du pack et celui du fichier, et refuse si le fichier n'est pas
    **directement** dans ce dossier ;
  - refuse un lien ou une jonction (dossier ou fichier) ;
  - n'accepte que les types du thème (PNG, JPEG, GIF, WebP d'après les premiers octets, TTF, OTF), dans les limites de
    taille de l'import (`Mindset/fichiers/modules/packs.ps1:128-136`, `:160-167`) ;
  - lit en lecture seule, et répond « introuvable » à tout le reste.
- Le dossier d'un pack est celui que connaît la suite : sous un dossier `packs` de Mindset ou d'une appli, vérifié
  (`Mindset/fichiers/modules/packs.ps1:275-283`).

**Pourquoi.** Un thème vient d'un zip importé par l'utilisateur. Un protocole large donnerait à la page la lecture de
fichiers du PC. Aujourd'hui, Mindset ne sert que les fichiers nommés par le thème
(`Mindset/fichiers/modules/console.ps1:197-208`) ; Nevermind ouvre tout le dossier du pack
(`Nevermind: Nevermind/fichiers/modules/vue.ps1:122`). La règle Rust est la plus stricte des deux.

**Vérifier.**
- Le test échoue si `assetProtocol` est activé.
- Des tests `cargo test` de la fonction de lecture, sur un dossier d'essai : `..\`, chemin complet, jonction vers un
  autre dossier, lien vers un fichier, fichier à côté du pack, mauvaise extension, faux PNG, fichier trop lourd :
  refusés ; une image du pack : servie.

---

## 7. Un seul dossier de données WebView2 pour toute la suite

**Règle.**
- Dossier de données WebView2 : `<données de la suite>\WebView2`, c'est-à-dire `%LOCALAPPDATA%\Mindset\WebView2`, ou
  `X:\Mindset\Donnees\WebView2` sur un autre disque. Les racines suivent la règle de
  `Mindset/fichiers/modules/donnees.ps1:15-21` (fonction de `suite-commun`). **Jamais** le dossier par défaut de Tauri.
- Un profil par appli, au nom de l'appli (Mindset : `console.ps1:83` ; Nevermind : `Nevermind: Nevermind/fichiers/modules/vue.ps1:44-50`) :
  Mindset retire ce profil quand l'appli est désinstallée avec ses données
  (`Mindset/fichiers/modules/installations.ps1:856-862`).
- **Mêmes options d'environnement** que le reste de la suite, sinon WebView2 refuse de partager
  (`console.ps1:70-74`) : aujourd'hui, **aucune**. Tauri ajoute par défaut des arguments au navigateur sous Windows :
  il faut les fixer explicitement pour qu'ils soient identiques dans toute la suite (à vérifier sur la version figée).
- Avant de s'en servir : vérifier que le dossier s'écrit, sinon se replier sur un dossier à soi
  (`<données de l'appli>\ecran-webview`), comme Mindset et Nevermind (`console.ps1:51-64`, `:76-83` ;
  `Nevermind: Nevermind/fichiers/modules/vue.ps1:52-63`). L'écran ne reste jamais vide.
- Les fenêtres sont créées dans le code Rust (le dossier se calcule au lancement), pas dans `app.windows` de
  `tauri.conf.json`.

**Pourquoi.** Un seul processus navigateur partagé par toutes les applis : moins de mémoire (point mesuré à l'étape
0). Un dossier par défaut mettrait les données hors de la suite : ni nettoyées à la désinstallation, ni sur le disque
choisi.

**Vérifier.**
- Le test échoue si `app.windows` déclare une fenêtre, ou si le code crée une fenêtre sans passer par la fonction de
  `suite-commun` qui fixe le dossier, le profil et les options.
- L'appli témoin, lancée avec un dossier de données d'essai, doit créer `EBWebView` sous `<essai>\WebView2` et rien
  ailleurs (jamais dans le vrai `%LOCALAPPDATA%`).

---

## 8. Pas d'installeur ni de mise à jour Tauri

**Règle.** Mindset reste le **seul** installeur de la suite.
- `bundle.active` vaut `false` (ou la construction se fait sans paquet) : ni MSI, ni NSIS.
- Ni `tauri-plugin-updater`, ni `plugins.updater`, ni fichiers de mise à jour produits par Tauri.
- L'exe est mis dans le zip de l'appli par `publier.ps1`, avec `version.json` (voir `contrat-appli.md`, partie 10),
  signé par la clé de la suite.

**Pourquoi.** Mindset vérifie la signature de chaque zip, refuse les retours en arrière, installe dans le dossier
protégé et garde les versions dans HKLM (`Mindset/fichiers/modules/paquets.ps1:197-249`). Un second installeur ou une
mise à jour par Tauri contournerait tout cela, et l'utilisateur verrait deux façons d'installer.

**Vérifier.** Le test échoue si `bundle.active` vaut `true`, si `plugins.updater` existe, ou si `Cargo.toml`
ou `Cargo.lock` contient `tauri-plugin-updater`.

---

## Règles déjà appliquées en PowerShell, gardées en Rust

- **Navigation fermée** : seules les pages de l'appli s'affichent ; toute autre adresse et toute nouvelle fenêtre sont
  refusées (`Mindset/fichiers/modules/console.ps1:120-122`, `Nevermind: Nevermind/fichiers/modules/vue.ps1:123-125`).
- **Rien de ce qui vient d'un fichier ou d'une page n'est exécuté** : les fichiers échangés avec Mindset ne sont que
  lus et affichés (`contrat-appli.md`, partie 5).

---

## Récapitulatif

| Règle | Où regarder | Le test échoue si |
|---|---|---|
| 1. withGlobalTauri coupé | `tauri.conf.json`, pages | `withGlobalTauri` vrai ; `__TAURI__` hors du module d'appel |
| 2. Capabilities par fenêtre | `capabilities/*.json`, code Rust | `*` ou motif ; `remote` ; permission hors liste ; commande non autorisée |
| 3. CSP stricte | `tauri.conf.json` | CSP vide ; `unsafe-eval` ; source distante ; `dangerousDisableAssetCspModification` |
| 4. Ni shell ni fs | `Cargo.toml`, `Cargo.lock`, capabilities | un des deux plugins, ou une permission `shell:` / `fs:` |
| 5. Outils de développement coupés | `Cargo.toml`, code, construction | feature `devtools` ; ouverture des outils ; exe hors construction `--release` |
| 6. Images des packs | `tauri.conf.json`, `cargo test` | asset protocol activé ; un cas de chemin piégé servi |
| 7. WebView2 commun | code, appli témoin | fenêtre dans `app.windows` ; fenêtre sans la fonction commune ; dossier créé ailleurs |
| 8. Pas d'installeur ni de mise à jour Tauri | `tauri.conf.json`, `Cargo.toml` | `bundle.active` vrai ; updater présent |
