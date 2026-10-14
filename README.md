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

## État (0.1.0)

- Fenêtre aux couleurs de la suite, onglets à gauche : Accueil, une ligne par appli, Paramètres.
- Accueil : une carte par appli avec son état (pas installée, trouvée sur le PC, version, ouverte, mise à jour disponible)
  et les bons boutons : Installer, Mettre à jour, Ouvrir (ou ramener sa fenêtre), Désinstaller, Prendre en charge.
- Les applis installées par Mindset vont dans `Program Files\Mindset\` (Nevermind, qui tourne en administrateur)
  ou `%LOCALAPPDATA%\Programs\Mindset\` (Evermind).
- Une copie déjà présente sur le PC est reconnue : Mindset peut l'ouvrir telle quelle, ou la prendre en charge
  (installer une copie gérée et y faire pointer raccourcis et démarrage). Il ne modifie ni ne supprime jamais une copie
  qu'il n'a pas installée.
- Thème de la suite (Paramètres) : les 5 thèmes de Nevermind et Evermind, partagés par `%LOCALAPPDATA%\Mindset\suite.json`.

À venir : afficher les applis dans Mindset, puis les cartes vivantes (score de Nevermind, prochains rendez-vous d'Evermind).

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
