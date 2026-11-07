# Bloc « près de l'horloge » : ce qui diffère de la version PowerShell (zone.ps1, 2.18.0)

Tout le reste fait exactement la même chose : c'est contrôlé par les juges exportés de la vraie version PowerShell
(`outils/exporter-juges-horloge.ps1` -> `tests/juges/*.json`, rejoués par `tests/juges.rs`). Chaque ligne ci-dessous
dit ce qui change, pourquoi, et la preuve.

## Voulu (un défaut corrigé, ou une précaution)

1. **Une appli sans dossier de données connu** (`Donnees` vide dans la liste) : elle est passée. PowerShell faisait
   `Join-Path '' 'notification.demande'`, qui lève une erreur (« Impossible de lier l'argument au paramètre « Path »,
   car il s'agit d'une chaîne vide », vérifié le 07/11) : tout le relevé de ce tour s'arrêtait, les applis suivantes
   comprises. En Rust, jamais de chemin relatif (il viserait le dossier courant). Aujourd'hui toutes les applis de
   apps.json ont un dossier de données : sans effet visible.
2. **L'icône remise après un redémarrage de l'Explorateur, même quand Mindset a les droits administrateur** :
   « TaskbarCreated » est permis par `ChangeWindowMessageFilterEx` (Windows filtre ce message venu de l'Explorateur
   vers un programme administrateur). Précaution, pas mesurée ici (rien n'est lancé en administrateur pendant
   l'essai) ; sans effet quand Mindset n'a pas les droits.
3. **L'icône est chargée à la taille des petites icônes de Windows** (`SM_CXSMICON`, depuis `fichiers\Mindset.ico`) :
   Windows Forms prenait l'image par défaut du fichier et la laissait réduire par l'Explorateur. Même dessin, plus net.

## Imposé par Rust ou par l'hôte (même résultat pour l'utilisateur)

4. **Le menu du clic droit est le menu natif de Windows** (`TrackPopupMenu`) au lieu du `ContextMenuStrip` de
   Windows Forms : mêmes lignes, même ordre, mêmes séparateurs, « Ouvrir Mindset » en gras (`SetMenuDefaultItem`),
   ouvert à la souris vers le haut et la gauche près d'une barre des tâches en bas à droite (comme `ShowInTaskbar`).
   Le dessin du menu est celui de Windows (celui de Windows Forms était le sien). Contrôlé par les juges (`menu.json` :
   les lignes, le gras, l'appli de chaque ligne, ce que fait chaque choix).
5. **La bulle « Mindset reste ici » vient du signal `fenetre`** (Mindset vient d'être caché), pas de `Hide-Fenetre`
   lui-même : ainsi elle vient aussi quand un autre bloc cache Mindset (la « veille » de la console, qui appelait
   `Hide-Fenetre`). Mindset déjà caché quand le bloc le cache : tout de suite (pas de signal). Seule différence, dans
   une situation impossible : la console met en veille un Mindset déjà caché (son bouton est dans la fenêtre) ;
   PowerShell remontrait la bulle, l'hôte Rust n'envoie pas de signal (rien ne change), donc pas de bulle. Les juges
   s'arrêtent sur cette situation quand c'est leur seule différence (10 cas sur 1 937, comptés par le test, au plus
   un sur dix par fichier).
6. **Les gestes sur l'icône arrivent au bloc toutes les 150 ms** (lus dans `tic`) au lieu d'aussitôt : un clic sur
   l'icône rouvre Mindset au plus 150 ms plus tard.
7. **Le fichier « notif:<id> » est écrit avant que l'appli soit montrée** : le bloc l'écrit pendant le clic sur la
   bulle, le bloc « accrochage » ouvre l'appli juste après (signal `ouvrir-appli`). PowerShell ouvrait l'appli puis
   écrivait. L'appli lit ce fichier quand Mindset la montre : même résultat.
8. **« gérée » (le dossier de la suite pour les données de l'appli) est lu dans le tableau commun `installations`**
   (`Get-Installation`, vérifiée par le bloc « installations ») au lieu de installations.json brut
   (`Read-Installations`). Différent seulement si installations.json dit « gérée » pour un dossier que
   `Get-Installation` refuse (alors PowerShell lisait quand même la notification dans le dossier de la suite).
9. **Le texte d'une erreur d'écriture au journal** (« Notification de <appli> : <erreur> ») vient de Windows en
   français, pas de .NET : le début de la ligne est le même (contrôlé par les juges, seul le début compte).

## La question de la croix en HTML (ui/fermeture.js, ui/fermeture.css)

Comparée à la VRAIE grille « Fermeture » d'interface.xaml, ses styles compris, rendue par WPF sans fenêtre, contre la
page rendue par Edge sans fenêtre (`outils/capture-question.ps1`, sur un bureau à part, 1000 x 640) : 97,4 % des
pixels presque pareils, écart moyen 2,1 sur 255 ; même position et même hauteur du panneau (234), mêmes retours à la
ligne du texte, mêmes couleurs.

10. **Le titre et les boutons sont en épaisseur normale** alors qu'interface.xaml dit « SemiBold » : avec la police
    variable « Segoe UI Variable Text », WPF ne sait pas prendre l'épaisseur demandée et dessine l'épaisseur normale
    (mesuré : WPF trouve SEGUIVAR.TTF pour cette police, et la capture montre un titre et des boutons fins ; avec
    600, la page était nettement plus grasse). Pour le même rendu, la page fait pareil. **À savoir pour tous les
    écrans** (bloc écrans) : partout où interface.xaml met « SemiBold » avec cette police, WPF dessine en normal.
11. **Quelques pixels d'écart de largeur** (le panneau 495 contre 491 en WPF, les boutons 83, 105 et 180 contre
    86, 110 et 188) : WPF est en mode d'affichage « Display », qui arrondit l'avance de chaque lettre au pixel ;
    Chromium ne le fait pas. Le panneau se resserre comme en WPF sur sa ligne la plus longue (fermeture.js).
12. **Le lissage du texte** : ClearType dans la page, gris dans la capture WPF (RenderTargetBitmap). Sans effet sur la
    mise en page.
