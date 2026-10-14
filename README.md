# Mindset

Le portail de la suite : [Nevermind](https://github.com/JordanJacquot/Nevermind) et [Evermind](https://github.com/JordanJacquot/Evermind) au même endroit.
Depuis Mindset, tu installes, mets à jour et utilises chaque appli, directement dans sa fenêtre.

## État (0.1.0)

- Fenêtre aux couleurs de la suite (palette Néon), onglets à gauche : Accueil, puis une ligne par appli.
- Accueil : une carte par appli, avec son état (ouverte ou fermée), relu toutes les 2 secondes.
- Un seul Mindset à la fois : le relancer ramène sa fenêtre.

À venir, dans l'ordre du plan : installer et mettre à jour les applis, les lancer ou ramener leur fenêtre,
les afficher dans Mindset, puis les cartes vivantes (score de Nevermind, prochains rendez-vous d'Evermind).

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
