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

## Sécurité des téléchargements

Chaque zip publié (Nevermind, Evermind, Mindset) est accompagné de `<zip>.sig`, sa signature RSA 3072 bits.
Mindset vérifie la signature avec `fichiers\cle-publique.xml` avant d'installer, extrait depuis la mémoire ce qu'il a
vérifié, et refuse tout fichier du zip qui sortirait de son dossier. Un zip non signé n'est jamais installé.

```powershell
.\outils\cle.ps1                          # crée la clé (une fois) ; la clé privée reste chiffrée dans %APPDATA%
.\outils\cle.ps1 -Exporter E:\cle.msk     # copie de secours protégée par un mot de passe
.\outils\signer.ps1 -Fichier .\Truc.zip   # écrit Truc.zip.sig, à publier avec le zip
```

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
