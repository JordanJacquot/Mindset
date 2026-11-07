# Essai de la vraie icône près de l'horloge du bloc « horloge » (rust\mindset-horloge\tests\icone_windows.rs), SUR UN
# BUREAU WINDOWS À PART : là, pas de barre des tâches, rien ne peut apparaître sur l'écran.
#
#   1. construire l'essai (depuis l'outil Bash) :
#        cargo test --offline -p mindset-horloge --test icone_windows --no-run
#   2. le lancer sur un bureau à part (depuis l'outil PowerShell) :
#        & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script <ce fichier> -Arguments "-Exe '<icone_windows-....exe>'" -Secondes 120
#
# Le test refuse de tourner ailleurs que sur un bureau à part (il le vérifie lui-même). Rien d'autre n'est lancé.
param([Parameter(Mandatory = $true)][string]$Exe)
$ErrorActionPreference = 'Stop'
$env:MINDSET_ESSAI_ICONE = '1'
& $Exe --ignored --exact icone_sur_un_bureau_a_part --nocapture --test-threads=1
exit $LASTEXITCODE
