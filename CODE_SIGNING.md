# Code signing policy

*Version française plus bas : [Politique de signature du code](#politique-de-signature-du-code).*

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

> **Status:** the application to SignPath Foundation is in progress. Until it is accepted, the releases are not
> Authenticode signed, and the notes of each [Release](../../releases) give the SHA-256 of `Mindset.zip`.

## What is signed

- `Mindset.exe`, the uninstaller `Desinstaller Mindset.exe` and the PowerShell scripts (`.ps1`) of Mindset, all built from this repository.
- Files from other authors are never signed with this certificate: the Microsoft WebView2 libraries
  (`fichiers\lib\webview2`, already signed by Microsoft Corporation) and Three.js (JavaScript, MIT license).

## How a release is built and signed

1. The version is tagged in this repository (`v<version>`).
2. The [Release workflow](.github/workflows/release.yml) builds `Mindset.exe` on a GitHub hosted runner, from the
   tagged source only, and uploads the `Mindset` folder as a workflow artifact.
3. The workflow sends a signing request to SignPath. SignPath checks that the artifact comes from this workflow and
   this repository. **Every signing request is approved manually** by an approver (see below).
4. The maintainer downloads the signed `Mindset.zip` produced by the workflow, adds the detached RSA signature
   `Mindset.zip.sig` (Mindset uses it to verify updates; it does not change any file inside the zip) and publishes
   the Release.

## Team and roles

| Role | Members |
|---|---|
| Committers and reviewers | [Jordan Jacquot](https://github.com/JordanJacquot) |
| Approvers | [Jordan Jacquot](https://github.com/JordanJacquot) |

- Committers can change the code of this repository. Changes proposed by anyone else (pull requests) are reviewed
  by a committer before they are merged.
- Every signing request is approved by an approver.
- All team members use multi-factor authentication on GitHub and on SignPath.

## Privacy policy

Mindset has no account, no advertising, no telemetry and no statistics. It does not send any personal data.
It connects to the network only for the following, and only to GitHub:

| What | When | What is sent | Can it be turned off? |
|---|---|---|---|
| Check for new versions of Mindset and of the apps of the suite (Nevermind, Evermind, Mindcare): `api.github.com`, or `github.com` if the API refuses | By itself: when Mindset starts, every hour while it runs (even hidden near the clock) and when it is reopened after more than 15 minutes, only while "Chercher les nouvelles versions" is on. On request: with the "Actualiser" and "Vérifier maintenant" buttons | A standard HTTPS request (your IP address, user agent `Mindset`) for the latest public release of each repository | Yes: Paramètres > Mises à jour > "Chercher les nouvelles versions" (on by default), or in the installation banner of Mindset. When it is off, Mindset only checks when you press "Actualiser" or "Vérifier maintenant", and automatic updates do not run |
| Download of a new version (zip and `.sig`): `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com` | When you install or update an app, or automatically when "Mises à jour automatiques" is on (on by default, and only while "Chercher les nouvelles versions" is on too) | A standard HTTPS request for the file | Yes: Paramètres > Mises à jour > "Mises à jour automatiques" (or "Chercher les nouvelles versions", which stops them too). Installing or updating by hand stays possible |

Shown at installation: the installation banner of Mindset says in one sentence what is sent, links to this page and has a "Chercher les nouvelles versions" box to turn the check off before installing (while this banner is shown, Mindset does not check by itself). Before an app is installed, its card says the same and links to the app's own privacy policy when it has one.

GitHub's privacy statement: <https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement>.

Third party component: Mindset shows its window with Microsoft Edge WebView2, a component of Windows. Mindset only
displays its own local pages in it (navigation to any other address is refused). The WebView2 Runtime is covered by
the Microsoft privacy statement: <https://privacy.microsoft.com/privacystatement>.

The apps installed by Mindset (Nevermind, Evermind, Mindcare) have their own privacy policy, in their own repository.

## System changes and uninstallation

- Installing Mindset asks Windows for administrator rights once. It installs Mindset (in `Program Files\Mindset` on
  C:, or `X:\Mindset` on another drive), creates its shortcuts, registers it in Windows' installed apps, and creates
  scheduled tasks in the `\Mindset\` folder (start with Windows, and the small installer that only installs signed
  zips).
- Mindset can be uninstalled from Paramètres ("Désinstaller Mindset") or from Windows' installed apps. Its data
  stays in its data folder, so that a new installation finds it again.

---

# Politique de signature du code

Signature gratuite du code fournie par [SignPath.io](https://about.signpath.io), certificat de la
[SignPath Foundation](https://signpath.org).

> **Où on en est :** la demande auprès de la SignPath Foundation est en cours. En attendant, les versions ne sont pas
> signées (Authenticode), et les notes de chaque [version publiée](../../releases) donnent l'empreinte SHA-256 de
> `Mindset.zip`.

## Ce qui est signé

- `Mindset.exe`, le désinstalleur `Desinstaller Mindset.exe` et les scripts PowerShell (`.ps1`) de Mindset, tous construits depuis ce dépôt.
- Les fichiers d'autres auteurs ne sont jamais signés avec ce certificat : les bibliothèques WebView2 de Microsoft
  (`fichiers\lib\webview2`, déjà signées par Microsoft Corporation) et Three.js (JavaScript, licence MIT).

## Comment une version est construite et signée

1. La version reçoit son étiquette dans ce dépôt (`v<version>`).
2. Le [workflow Release](.github/workflows/release.yml) construit `Mindset.exe` sur une machine de GitHub, seulement
   depuis le code de cette étiquette, et dépose le dossier `Mindset` comme artefact.
3. Le workflow envoie une demande de signature à SignPath, qui vérifie que l'artefact vient bien de ce workflow et de
   ce dépôt. **Chaque demande est approuvée à la main** par un approbateur (voir plus bas).
4. Le responsable récupère le `Mindset.zip` signé construit par le workflow, ajoute la signature RSA séparée
   `Mindset.zip.sig` (Mindset s'en sert pour vérifier les mises à jour ; elle ne change aucun fichier du zip) et
   publie la version.

## Équipe et rôles

| Rôle | Membres |
|---|---|
| Auteurs et relecteurs | [Jordan Jacquot](https://github.com/JordanJacquot) |
| Approbateurs | [Jordan Jacquot](https://github.com/JordanJacquot) |

- Les auteurs peuvent modifier le code de ce dépôt. Les changements proposés par quelqu'un d'autre (pull requests)
  sont relus par un auteur avant d'être acceptés.
- Chaque demande de signature est approuvée par un approbateur.
- Tous les membres de l'équipe utilisent la double authentification sur GitHub et sur SignPath.

## Confidentialité

Mindset n'a ni compte, ni publicité, ni télémétrie, ni statistiques. Il n'envoie aucune donnée personnelle.
Il se connecte au réseau seulement pour ce qui suit, et seulement à GitHub :

| Quoi | Quand | Ce qui est envoyé | Peut-on le couper ? |
|---|---|---|---|
| Recherche des nouvelles versions de Mindset et des applis de la suite (Nevermind, Evermind, Mindcare) : `api.github.com`, ou `github.com` si l'API refuse | Tout seul : au démarrage de Mindset, toutes les heures tant qu'il tourne (même caché près de l'horloge) et quand on le rouvre après plus de 15 minutes, seulement si « Chercher les nouvelles versions » est activé. À ta demande : avec les boutons « Actualiser » et « Vérifier maintenant » | Une demande HTTPS ordinaire (ton adresse IP, nom du programme `Mindset`) pour la dernière version publique de chaque dépôt | Oui : Paramètres > Mises à jour > « Chercher les nouvelles versions » (activé au départ), ou dans le bandeau d'installation de Mindset. Coupé, Mindset ne cherche que quand tu cliques sur « Actualiser » ou « Vérifier maintenant », et les mises à jour automatiques ne tournent plus |
| Téléchargement d'une nouvelle version (zip et `.sig`) : `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com` | Quand tu installes ou mets à jour une appli, ou tout seul si « Mises à jour automatiques » est activé (activé au départ, et seulement si « Chercher les nouvelles versions » l'est aussi) | Une demande HTTPS ordinaire pour le fichier | Oui : Paramètres > Mises à jour > « Mises à jour automatiques » (ou « Chercher les nouvelles versions », qui les arrête aussi). Installer ou mettre à jour à la main reste possible |

Affiché à l'installation : le bandeau d'installation de Mindset dit en une phrase ce qui est envoyé, renvoie à cette page et a une case « Chercher les nouvelles versions » pour couper la recherche avant d'installer (tant que ce bandeau est affiché, Mindset ne cherche rien tout seul). Avant l'installation d'une appli, sa carte dit la même chose et renvoie à la politique de confidentialité de l'appli quand elle en a une.

Déclaration de confidentialité de GitHub : <https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement>.

Composant d'un autre auteur : Mindset affiche sa fenêtre avec Microsoft Edge WebView2, un composant de Windows. Mindset
n'y montre que ses propres pages, enregistrées sur le PC (toute autre adresse est refusée). WebView2 relève de la
déclaration de confidentialité de Microsoft : <https://privacy.microsoft.com/privacystatement>.

Les applis installées par Mindset (Nevermind, Evermind, Mindcare) ont leur propre politique de confidentialité, dans
leur dépôt.

## Ce qui change sur le PC, et la désinstallation

- L'installation de Mindset demande une seule fois l'autorisation de Windows (droits administrateur). Elle installe
  Mindset (dans `Program Files\Mindset` sur C:, ou `X:\Mindset` sur un autre disque), crée ses raccourcis, l'inscrit
  dans les applications installées de Windows, et crée des tâches planifiées dans le dossier `\Mindset\` (lancement
  avec Windows, et le mini-installateur qui n'installe que des zips signés).
- Mindset se désinstalle depuis Paramètres (« Désinstaller Mindset ») ou depuis les applications installées de
  Windows. Ses données restent dans son dossier de données : une réinstallation les retrouve.
