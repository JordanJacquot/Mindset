# Règles Tauri de la suite

Ces règles valent pour toute appli de la suite écrite avec Tauri 2 (la première sera Mindcare, à l'étape 3 du plan de
passage en Rust). Elles reprennent le plan (3.1) et sont fixées **avant** l'étape 3. Chaque règle dit pourquoi, et
comment la vérifier : un test des tests GitHub doit **échouer** si elle n'est pas tenue.

Versions figées : tauri 2.12.5, tauri-build 2.7.4, tauri-utils 2.10.2, tauri-runtime-wry 2.12.3, wry 0.57.1. Les
noms de réglages cités ici ont été **revérifiés le 02/11/2026 sur leurs sources** (registre de cargo du PC). À chaque
changement de version, ils sont revérifiés et ce document est corrigé s'il le faut. Les chemins `Mindset/...` sont
relatifs à la racine du dépôt Mindset, ceux qui commencent par « Nevermind: » à celle du dépôt Nevermind.

Les vérifications sont regroupées dans `outils/verifier-tauri.ps1 -Projet <dossier de l'appli>` (dépôt Mindset), lancé
dans les tests GitHub de Mindset (sur des projets d'essai, `outils/essais-tauri`) et de chaque appli Tauri (sur son
vrai projet). Il lit les fichiers (`tauri.conf.json`, `capabilities/`, `Cargo.toml`, `Cargo.lock`, `build.rs`, le code
Rust et les pages) ; il ne lance rien et ne construit rien. Code de sortie 0 si tout est bon, 1 sinon, avec une phrase
par problème.

**La configuration, un seul fichier.** Tauri lit `tauri.conf.json`, mais aussi `tauri.conf.json5`, `Tauri.toml` et,
sous Windows, `tauri.windows.conf.json` (ou `.json5`, `Tauri.windows.toml`), qu'il **fusionne** par dessus
(tauri-utils `config/parse.rs`). Seul `tauri.conf.json` est permis : le test échoue s'il trouve un des autres. Tauri
accepte aussi des noms avec tirets (`with-global-tauri`, `dev-csp`, `asset-protocol`...) : le test les lit comme les
noms normaux. La variable `TAURI_CONFIG`, lue à la construction, est elle aussi fusionnée : elle n'est jamais posée
dans les tests GitHub ni dans la construction de publication.

---

## 1. withGlobalTauri coupé

**Règle.** `app.withGlobalTauri` vaut `false` (ou est absent) dans `tauri.conf.json`. Les pages appellent Rust par
un seul petit module du kit (par exemple `ipc.js`), qui fait `invoke` vers les commandes de l'appli.

**Pourquoi.** Avec ce réglage, toute l'API de Tauri est posée sur `window.__TAURI__`, offerte à n'importe quel script
de la page. Sans lui, les appels passent par un seul fichier, court et facile à relire.

**Vérifier.**
- `tauri.conf.json` : le test échoue si `app.withGlobalTauri` vaut `true`.
- Les pages (le dossier `build.frontendDist`) : le test échoue s'il trouve `__TAURI` (donc aussi
  `__TAURI_INTERNALS__`, par où passe `invoke`), le mot `invoke`, `ipc.localhost` ou `chrome.webview` ailleurs que
  dans `ipc.js`.

---

## 2. Des capabilities par fenêtre, avec seulement les commandes utiles

**Règle.**
- Un fichier `capabilities/<fenêtre>.json` par fenêtre, dont `windows` donne le **label exact** de cette fenêtre :
  jamais `"*"` ni un motif.
- `permissions` est une liste écrite à la main, permission par permission : seulement ce que la fenêtre utilise.
  Pas d'ensemble large sans relecture (par exemple un `...:default` qu'on n'a pas lu).
- Aucune capability `remote` : aucune adresse extérieure n'a accès aux commandes.
- Les commandes de l'appli (`#[tauri::command]`) sont, elles aussi, soumises aux permissions, **seulement** si
  `build.rs` déclare le manifeste de l'appli : `tauri_build::Attributes::new().app_manifest(
  tauri_build::AppManifest::new().commands(&["ma_commande", ...]))`. Sans lui, Tauri laisse toute page locale appeler
  toutes les commandes (tauri `webview/mod.rs:2080`). La permission d'une commande s'écrit `allow-<commande>`, les
  `_` devenant des `-` (`ma_commande` donne `allow-ma-commande`, tauri-utils `acl/build.rs:308`).
- Les capabilities sont seulement des fichiers `.json` de `capabilities/`, une capability par fichier. Tauri lit aussi
  les sous-dossiers, les `.json5` et les `.toml` de ce dossier, et des capabilities écrites dans
  `app.security.capabilities` de `tauri.conf.json` : tout cela est refusé, pour qu'il n'y ait qu'un endroit à relire.
- Aucune permission de Tauri lui-même (`core:...`) pour l'instant : la liste blanche de la suite est vide, et une
  permission n'y entre qu'après relecture. Les `core:*:default` en particulier ouvrent plusieurs commandes d'un coup.
  Le canal (`tauri::ipc::Channel`) n'en demande pas (tauri `webview/mod.rs:2082`).

**Pourquoi.** Une page compromise (un texte mal échappé, un fichier de thème piégé) ne peut appeler que ce que sa
fenêtre a le droit d'appeler. Une capability pour toutes les fenêtres annulerait ce cloisonnement.

**Vérifier.**
- Le test lit `capabilities/` et échoue si `windows` est vide ou contient `*` ou un motif (`*`, `?`, `[`), si
  `webviews` est utilisé, si une clé `remote` existe, si `local` vaut `false`, si une permission n'est ni une
  `allow-<commande>` ni dans la liste blanche de la suite (vide), ou si un label de fenêtre a plusieurs fichiers.
- Il compare les commandes du code Rust (`#[tauri::command]`), celles du manifeste de `build.rs` et celles autorisées :
  pas de manifeste, une commande qui n'est autorisée nulle part, ou une permission vers une commande qui n'existe pas,
  fait échouer.

---

## 3. Une politique de contenu (CSP) stricte

**Règle.** `app.security.csp` est toujours rempli. CSP de départ :

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' http://pack.localhost data:; font-src 'self' http://pack.localhost; connect-src ipc: http://ipc.localhost; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'
```

- jamais `'unsafe-eval'` ; jamais `'unsafe-inline'` dans `script-src` ;
- aucune source distante (`http://` ou `https://` vers Internet, `*`, `https:`) : tout est rangé dans l'exe ;
- `http://pack.localhost` est le protocole des images de thème (règle 6) ; sous Windows, Tauri sert un protocole
  maison sous la forme `http://<nom>.localhost` (confirmé : tauri `protocol/mod.rs:30-35`, les pages elles-mêmes
  sont sur `http://tauri.localhost`, les appels sur `http://ipc.localhost`) ;
- `data:` seulement pour les images, et retiré si le kit n'en a pas besoin ;
- si le kit pose des styles dans le HTML, `'unsafe-inline'` est toléré dans `style-src` seulement, jamais ailleurs ;
- `devCsp`, s'il existe, est la même ; `dangerousDisableAssetCspModification` est absent (Tauri ajoute lui-même
  l'empreinte de ses scripts à la CSP).

**Pourquoi.** Même si un texte est mal échappé quelque part, la page ne peut ni exécuter du code fabriqué, ni charger
un script venu d'ailleurs, ni envoyer des données sur Internet. C'est la même idée qu'aujourd'hui : la console de
Mindset refuse toute adresse autre que la sienne (`Mindset/fichiers/modules/console.ps1:120-122`).

- pas d'adresse de développement (`build.devUrl`) : l'exe ne charge que ses pages (voir aussi `custom-protocol`,
  règle 5).

**Vérifier.** Le test lit la CSP (texte, ou groupe de directives comme Tauri le permet) et échoue si elle est vide,
sans `default-src 'none'`, si elle contient `unsafe-eval` (`wasm-unsafe-eval` compris), `unsafe-inline` ailleurs que
dans `style-src`, `*` ou un joker, `http:`, `https:`, `ws:` ou `wss:` seuls, `data:` ou `blob:` ailleurs que dans
`img-src`, une adresse autre que `http(s)://<nom>.localhost`, si `devCsp` existe et n'est pas la même, si
`dangerousDisableAssetCspModification` est présent, ou si `build.devUrl` existe.

---

## 4. Aucun plugin shell ni fs

**Règle.** Ni `tauri-plugin-shell`, ni `tauri-plugin-fs` (ni leurs pendants `@tauri-apps/plugin-shell`,
`@tauri-apps/plugin-fs`). Ce qui demande le disque, un programme ou un lien passe par une **commande Rust de l'appli**,
qui vérifie elle-même ce qu'on lui donne. Par exemple, ouvrir une page : seulement une adresse
`https://github.com/JordanJacquot/...`, comme le fait déjà Mindset (`Mindset/fichiers/modules/applis.ps1:35`).

**Pourquoi.** Ces plugins donnent à la page un accès général au disque ou au lancement de programmes. Une commande
précise ne peut faire que ce pour quoi elle est écrite.

Sont aussi interdits `tauri-plugin-single-instance` et `tauri-plugin-global-shortcut` : la suite a son propre verrou
(contrat, partie 3), et une appli ne capte aucun raccourci de tout Windows.

**Vérifier.**
- `Cargo.toml` et `Cargo.lock` : le test échoue s'il y trouve `tauri-plugin-shell`, `tauri-plugin-fs`,
  `tauri-plugin-single-instance` ou `tauri-plugin-global-shortcut` (et `tauri-plugin-updater`, règle 8). La liste
  blanche de `cargo deny` (plan 3.6) les interdit aussi.
- `package.json` s'il existe, et les pages : pas de `plugin-shell` ni `plugin-fs`.
- `capabilities/*.json` : aucune permission `shell:` ni `fs:`.

---

## 5. Outils de développement coupés en publication

**Règle.**
- La fonctionnalité `devtools` de la dépendance `tauri` est **absente** de `Cargo.toml` (ni dans `features`, ni par
  une option de l'appli comme `essai = ["tauri/devtools"]`).
- `tauri` est pris avec `default-features = false` : ses options par défaut comprennent `dynamic-acl` (permissions
  modifiables pendant que l'appli tourne), interdite. On liste à la main : `wry`, `compression`,
  `common-controls-v6`, `custom-protocol`.
- La fonctionnalité `custom-protocol` est **obligatoire** : sans elle, l'exe ne contient pas ses pages et cherche
  un serveur de développement (tauri `Cargo.toml`, `custom-protocol = ["tauri-macros/custom-protocol"]`). Elle est
  écrite en dur dans `Cargo.toml` (pas de construction par la CLI de Tauri, qui l'ajoute d'habitude).
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
- Le test échoue si un `Cargo.toml` du projet ou de son espace de travail active `devtools` ou `dynamic-acl` pour
  `tauri`, si `tauri` garde ses options par défaut, si `custom-protocol` manque, ou si le code appelle l'ouverture
  des outils (`open_devtools`, `.devtools(true)`).
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

La lecture est écrite une fois pour toutes dans `suite-commun` (`fichier_pack::lire`, et `nom_depuis_adresse` pour
le nom tiré de l'adresse) : le protocole `pack` de chaque appli l'appelle et répond « introuvable » à toute erreur. Les
polices y sont reconnues elles aussi à leurs premiers octets (TrueType ou OpenType), plus strict que PowerShell.

**Vérifier.**
- Le test échoue si `assetProtocol` est présent avec `enable` vrai ou un `scope`.
- Des tests `cargo test` de la fonction de lecture (`rust/suite-commun/src/fichier_pack/tests.rs`), sur un dossier
  d'essai : `..\`, chemin complet, jonction vers un autre dossier (pack, dossier `packs` ou fichier), lien vers un
  fichier, fichier à côté du pack, mauvaise extension, faux PNG, fichier trop lourd : refusés ; une image du pack :
  servie.

---

## 7. Un dossier WebView2 à part pour les applis Tauri, avec des options fixes

**Règle** (décisions du 26/10 et du 02/11/2026).
- Dossier de données WebView2 des applis Tauri : `<données de la suite>\WebView2-Tauri`, juste à côté de
  `<données de la suite>\WebView2` (celui de Mindset et Nevermind, `Mindset/fichiers/modules/console.ps1:19`),
  c'est-à-dire `%LOCALAPPDATA%\Mindset\WebView2-Tauri`, ou `X:\Mindset\Donnees\WebView2-Tauri` sur un autre disque.
  Les racines suivent la règle de `Mindset/fichiers/modules/donnees.ps1:15-21`. **Jamais** le dossier par défaut de
  Tauri, ni le dossier `WebView2` de Mindset.
- Pourquoi à part : wry (le moteur de fenêtres de Tauri) crée le navigateur avec des options à lui (arguments,
  langue de l'utilisateur, style des barres de défilement, extensions coupées : wry `webview2/mod.rs:297-360`). Mindset
  et Nevermind n'en donnent aucune. WebView2 refuse de partager un dossier entre des options différentes.
- Un dossier par appli : `WebView2-Tauri\<Nom>` (« Mindcare »). Tauri 2.12.5 ne permet pas de choisir un profil
  WebView2 (wry sait le faire, Tauri ne le transmet pas), et toutes les applis Tauri ont la même adresse
  (`http://tauri.localhost`) : dans un seul profil, leurs stockages seraient mélangés. Mindset retire ce dossier
  quand l'appli est désinstallée sans ses données (comme le profil d'aujourd'hui : `Complete-Desinstallation`,
  `Mindset/fichiers/modules/installations.ps1`, sans jamais suivre un lien ; `WebView2-Tauri` part aussi s'il est
  vide). « Désinstaller Mindset » avec la case « Supprimer aussi mes données » l'efface avec toutes les données de la
  suite, après avoir fermé son WebView2 ; case décochée, il reste. Tests : `outils/tester-desinstallation.ps1` et
  `cargo test -p desinstalleur` (`dossier_webview2_tauri_suit_le_choix_des_donnees`). Si une version de Tauri
  permet un jour de nommer le profil,
  les applis Tauri pourront partager un seul dossier, avec un profil chacune.
- **Mêmes options pour toutes les applis Tauri**, fixées par la suite et données explicitement
  (`additional_browser_args`) : `--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection`. Ce sont celles que
  wry ajoute de lui-même quand on ne lui en donne pas (wry `webview2/mod.rs:311`) ; les écrire nous-mêmes évite
  qu'une version de wry, la lecture automatique ou un proxy ne les change. Rien d'autre ne change les options :
  ni `browser_extensions_enabled`, ni `scroll_bar_style`, ni `proxy_url`.
- Le dossier, le nom et les options viennent de `suite-commun` (`webview::choisir_dossier`,
  `webview::OPTIONS_NAVIGATEUR`), jamais écrits à la main dans une appli.
- Avant de s'en servir : vérifier que le dossier s'écrit, sinon se replier sur un dossier à soi
  (`<données de l'appli>\ecran-webview`), comme Mindset et Nevermind (`console.ps1:51-64`, `:76-83` ;
  `Nevermind: Nevermind/fichiers/modules/vue.ps1:52-63`). `webview::choisir_dossier` fait les deux. L'écran ne
  reste jamais vide.
- Les fenêtres sont créées dans le code Rust (le dossier se calcule au lancement), pas dans `app.windows` de
  `tauri.conf.json`.

**Pourquoi.** Un dossier par défaut mettrait les données hors de la suite : ni nettoyées à la désinstallation, ni sur
le disque choisi. Des options fixées par la suite gardent toutes les applis Tauri pareilles, même quand une version de
wry change les siennes.

**Vérifier.**
- Le test échoue si `app.windows` déclare une fenêtre, ou si un fichier Rust crée une fenêtre
  (`WebviewWindowBuilder::new`) sans `data_directory`, `additional_browser_args`, `webview::OPTIONS_NAVIGATEUR` et
  `choisir_dossier` de `suite-commun`.
- Des tests `cargo test` de `suite-commun` (`webview.rs`) : chemins, noms d'appli refusés, options exactes, replis.
- L'appli lancée avec un dossier de données d'essai doit créer `EBWebView` sous
  `<essai>\WebView2-Tauri\<Nom>` et rien ailleurs (jamais dans le vrai `%LOCALAPPDATA%`).

---

## 8. Pas d'installeur ni de mise à jour Tauri

**Règle.** Mindset reste le **seul** installeur de la suite.
- `bundle.active` vaut `false` (ou la construction se fait sans paquet) : ni MSI, ni NSIS.
- Ni `tauri-plugin-updater`, ni `plugins.updater`, ni fichiers de mise à jour produits par Tauri.
- L'exe est mis dans le zip de l'appli par `publier.ps1`, avec `version.json` (voir `contrat-appli.md`, partie 10),
  signé par la clé de la suite.
- `productName` vaut `"Mindset"` : tauri-build écrit `productName` comme description de l'exe (ce qu'affiche le
  Gestionnaire des tâches), et le programme de chaque appli de la suite s'appelle `Mindset.exe` avec « Mindset »
  comme description (`contrat-appli.md`, partie 4).

**Pourquoi.** Mindset vérifie la signature de chaque zip, refuse les retours en arrière, installe dans le dossier
protégé et garde les versions dans HKLM (`Mindset/fichiers/modules/paquets.ps1:197-249`). Un second installeur ou une
mise à jour par Tauri contournerait tout cela, et l'utilisateur verrait deux façons d'installer.

**Vérifier.** Le test échoue si `bundle.active` vaut `true`, si `plugins.updater` existe, si `Cargo.toml`
ou `Cargo.lock` contient `tauri-plugin-updater`, ou si `productName` n'est pas exactement `Mindset`.

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
| 1. withGlobalTauri coupé | `tauri.conf.json`, pages | `withGlobalTauri` vrai ; `__TAURI`, `invoke` hors de `ipc.js` |
| 2. Capabilities par fenêtre | `capabilities/`, `build.rs`, code Rust | `*` ou motif ; `remote` ; permission hors liste ; pas de manifeste ; commande non autorisée |
| 3. CSP stricte | `tauri.conf.json` | CSP vide ; `unsafe-eval` ; source distante ; `devCsp` différente ; `dangerousDisableAssetCspModification` ; `devUrl` |
| 4. Ni shell ni fs | `Cargo.toml`, `Cargo.lock`, capabilities | un plugin interdit, ou une permission `shell:` / `fs:` |
| 5. Outils de développement coupés | `Cargo.toml`, code, construction | `devtools` ; `dynamic-acl` ; options par défaut ; pas de `custom-protocol` ; ouverture des outils ; exe hors construction `--release` |
| 6. Images des packs | `tauri.conf.json`, `cargo test` | asset protocol activé ; un cas de chemin piégé servi |
| 7. WebView2 à part, options fixes | code, `tauri.conf.json`, `cargo test` | fenêtre dans `app.windows` ; fenêtre sans les fonctions communes ; dossier créé ailleurs |
| 8. Pas d'installeur ni de mise à jour Tauri | `tauri.conf.json`, `Cargo.toml` | `bundle.active` vrai ; updater présent ; `productName` autre que `Mindset` |
| Configuration | dossier du projet | `tauri.windows.conf.json`, `tauri.conf.json5`, `Tauri.toml`... |
