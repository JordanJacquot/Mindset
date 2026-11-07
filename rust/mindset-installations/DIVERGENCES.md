# Bloc « installations » : ce qui diffère de la version PowerShell

Référence : `Mindset/fichiers/modules/installations.ps1` (2.18.0), `taches.ps1`, `integration.ps1:258-273`,
`Mindset.ps1:139-156`. Tout le reste est porté à l'identique et jugé (`tests/juges/*.json`, exportés par
`outils/exporter-juges-installations.ps1`).

## Différences voulues

1. **La version à installer vient du bloc « publications ».** `Start-InstallAppli` redemandait la dernière version à
   GitHub (`Get-Publication`) dans son travail de fond. Les blocs ne dépendent pas les uns des autres et la question à
   GitHub est au bloc « publications » (architecture, bloc 3) : le bloc prend la version publiée connue
   (`publications[id]` du tableau commun : version, `url_zip`, `url_sig`). Si elle n'est pas encore connue (ou en
   erreur), il envoie `actualiser { clic: true }` et attend `publications-changees` (90 s au plus) ; une erreur de
   GitHub arrête l'installation avec « Échec : <erreur> », comme avant. Tous les contrôles restent dans le travail :
   adresse permise (`Test-AdresseTelechargement`, aussi sur l'adresse d'arrivée), signature, dossier du zip,
   version.json (`Test-PaquetAppli`). Preuve : tests `flux::version_pas_encore_connue_une_recherche_est_demandee`,
   `flux::version_non_signee_et_adresse_refusee`.
2. **`$EnTest` remplacé par les faux ports.** Ce que PowerShell ne faisait jamais en test (réparer les raccourcis et
   les démarrages au lancement, `Move-TachesDemarrage`, la remise en ordre des tâches, relancer une appli après son
   installation, fermer les applis en quittant, fermer les programmes d'aide avant une désinstallation) est fait
   quand `ctx.essai` est faux, ou par le bloc de test (`BlocInstallations::pour_essai`, tous les ports faux). La
   construction d'essai de Mindset (`ctx.essai`) n'a aucun poste Windows (`SansPoste`) : comme `$EnTest`.
3. **La demande de Windows lance `MindsetInstallateur.exe`** (à côté de Mindset.exe), en « runas » par
   `ShellExecuteExW`, fenêtre cachée, dossier de travail = dossier de Windows, avec `-Action <a> -Resultat "<f>"
   -<Nom> "<valeur>"` (guillemets et « \ » finaux doublés comme `Format-ArgumentAdmin`). Jamais `powershell.exe` ni
   `installer-admin.ps1`. **Le contrôle des variables COR_*, COMPlus_*, CORECLR_*, DOTNET_STARTUP_HOOKS,
   DOTNET_ADDITIONAL_DEPS, DOTNET_SHARED_STORE est gardé** (décision du bloc, point 7.4 de l'architecture) : le
   programme lancé n'est plus .NET, mais le refus ne coûte rien et reste prudent ; mêmes textes, jugés
   (`variables.json`).
4. **Une demande de Windows lancée vaut accusé de réception** pour un autre bloc : `admin-recu { id, direct: true }`.
   C'est ce que faisait `Start-MajMindsetDirecte` (Mindset se fermait dès le lancement) ; le bloc « lui-même » peut
   ainsi quitter, pour `mindset-maj`, dans les deux chemins.
5. **`Start-MajMindset` passe par la file** (une demande à la fois). Avant, elle déposait sa demande même si une autre
   attendait encore la tâche (`Send-DemandeInstallation` direct) : maintenant elle attend son tour.
6. **`Update-Trouvees` dans un travail de fond** (Téléchargements, Bureau et Documents sont parcourus) au lieu de
   figer la fenêtre ; le résultat est publié dans `trouvees` à sa fin.
7. **Dossiers demandés à Windows** (`SHGetKnownFolderPath`) : Bureau, menu Démarrer, Démarrage, Documents,
   `<profil>\Downloads`, et les dossiers que Mindset ne vide jamais (Windows, Program Files, Program Files (x86),
   ProgramData), au lieu des variables d'environnement `$env:windir`, `$env:ProgramFiles`... qu'un programme sans
   droits peut changer. System32 (schtasks.exe, robocopy.exe) aussi.
8. **Aucun lien n'est suivi en supprimant** : `Remove-AncienneCopie` ne descend pas dans un point de jonction (un lien
   compte pour un fichier qui reste, la copie n'est donc jamais supprimée en entier s'il y en a un) ;
   `Move-DonneesAppli` supprime l'ancien dossier sans suivre de lien (`Remove-Item -Recurse` de PowerShell 5.1 pouvait
   suivre une jonction). Plus sûr ; aucun cas normal ne change (juges `copie.json`).
9. **`Stop-Operation` et la mise à jour automatique** : `Complete-MajAuto`, `Set-EchecMajAuto`, `Add-HistoriqueMaj`
   et `$script:MajAutoEchecs` sont au bloc « lui-même » (architecture, bloc 5). Ce bloc envoie `operation-finie`
   avec, en plus des champs du contrat : `version`, `avant` (la version d'avant) et `historique` (`{ id, nom,
   version, auto, notes }` quand c'est une mise à jour plus récente : ce qu'il faut à `Add-HistoriqueMaj`, ou `null`).
   Le message de la carte d'une mise à jour automatique ratée (« La mise à jour automatique n'a pas pu se faire :
   <raison> Clique sur « Mettre à jour » pour réessayer. ») est fait ici, avec `Get-RaisonEchecMaj` porté (juges
   `raisons.json`). `Use-InstallationTrouvee` envoie aussi `operation-finie`, avec `quoi: "utilisation"`.
10. **La remise en ordre des tâches au démarrage** (`Start-RemplacementTache`, `Start-RemiseEnOrdreTaches`,
    parametres.ps1:515-526) est faite par ce bloc au premier tic (mêmes conditions : Mindset installé, sans les droits,
    tâche « ancienne », ou SYSTEM et `TachesRefaitesPour` différent de la version ou tâches d'avant). Le résultat du
    remplacement est publié dans `admin.remplacement` (`en_cours`, `ok`, `echec`) : le bloc « paramètres » y lit s'il
    doit remontrer son bandeau, sans envoyer lui-même de demande.
11. **Une désinstallation n'est pas lancée pendant une autre opération sur la même appli** (`Start-DesinstallAppli`
    ne le vérifiait pas ; les cartes n'offraient pas le bouton à ce moment-là).

## Différences subies (à décider ailleurs)

12. **Lancer une appli qui demande les droits** : `Systeme::lancer` du noyau passe par `CreateProcess`. Un exe dont le
    manifeste exige l'administrateur (seulement Nevermind avant 1.15, ouvert à la main par un Mindset sans droits)
    échoue (code 740, noté au journal) au lieu d'afficher la demande de Windows comme `Start-Process`. À trancher par
    le noyau (un `Lancer` « par l'Explorateur », ShellExecute).
13. **Noms d'entrées de zip qui ne sont pas en UTF-8** : lus en CP437 par la crate zip, en page 1252 par .NET. Les zips
    de la suite marquent leurs noms en UTF-8 ; sans effet aujourd'hui.
14. **Entrées « Run » de type REG_EXPAND_SZ** : lues telles quelles (PowerShell remplaçait les variables). Une copie
    lancée par `%USERPROFILE%\...` n'est pas reconnue par son entrée « Run » (elle l'est encore par ses raccourcis et
    par le parcours des dossiers).
15. **Le journal « <Appli> « géré » hors de ... »** revient à chaque relevé (2 s fenêtre montrée, 30 s cachée), comme
    les cartes de la version PowerShell, qui appelaient `Get-Installation` à chaque rafraîchissement.

## Rien à porter

- `taches.ps1` (`Start-Tache`, `New-Action`, `Pop-Action`) : remplacé par `Effet::Tache` ; les valeurs voyagent dans la
  fermeture ou dans l'id du travail (`telechargement:<id>:<ancienne copie>`, `donnees:<id>`, `trouvees`).
- Les conseils de désinstallation (contrat-appli.md, partie 9) : ils ne servent qu'à « Désinstaller Mindset »
  (`rust/desinstalleur`, déjà fait). Depuis Mindset, le désinstalleur d'une appli est lancé sans option : c'est lui qui
  pose la question et montre sa fin, comme avant.
