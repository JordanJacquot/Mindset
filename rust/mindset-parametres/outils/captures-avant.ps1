# Mindset : les captures « avant » des Paramètres, avec la version PowerShell (WPF), un onglet après l'autre.
# À lancer SEULEMENT sur un bureau Windows à part :
#
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '<ce fichier>' -Secondes 400
#
# Mindset.ps1 en mode test (MINDSET_TEST, MINDSET_DONNEES : tout dans un dossier d'essai, aucun verrou ni signal de
# Mindset, aucune icône près de l'horloge, MINDSET_SANS_RESEAU : rien vers GitHub), Animations « aucune » (la page
# WPF des Paramètres, sans la console), capture puis fermeture (Start-Capture). Les images vont dans -Sortie.
param([string]$Sortie = 'D:\Outils\Rust\essais\parametres\captures')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scenario-captures.ps1')
$depot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$ps1 = Join-Path $depot 'Mindset\fichiers\Mindset.ps1'
$racine = 'D:\Outils\Rust\essais\parametres\avant'
New-Item -ItemType Directory -Force -Path $Sortie | Out-Null
$powershell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'

foreach ($onglet in $OngletsEssai) {
    $donnees = Join-Path $racine $onglet
    if (Test-Path -LiteralPath $donnees) { Remove-Item -LiteralPath $donnees -Recurse -Force }
    $data = Join-Path $donnees 'Mindset'
    Initialize-ScenarioEssai $data $donnees
    Write-TexteEssai (Join-Path $data 'reglages.json') '{ "Animations": "aucune" }'
    $image = Join-Path $Sortie "avant-$onglet.png"
    if (Test-Path -LiteralPath $image) { Remove-Item -LiteralPath $image -Force }
    $vars = @{ MINDSET_TEST = '1'; MINDSET_SANS_RESEAU = '1'; MINDSET_DONNEES = $donnees; MINDSET_PAGE = 'parametres'; MINDSET_ONGLET = $onglet
        MINDSET_CAPTURE = $image; MINDSET_CAPTURE_DELAI = $(if ($onglet -eq 'conso') { '5' } else { '2' }) }
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
    $p = Start-Process -FilePath $powershell -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$ps1`"" -WindowStyle Hidden -PassThru `
        -RedirectStandardError (Join-Path $donnees 'erreurs.txt') -RedirectStandardOutput (Join-Path $donnees 'sortie.txt')
    $fin = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $fin -and -not $p.HasExited) { Start-Sleep -Milliseconds 300 }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Write-Output "ÉCHEC : $onglet, Mindset ne s'est pas fermé (arrêté)" }
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
    if (Test-Path -LiteralPath $image) { Write-Output "OK : $image" } else { Write-Output "ÉCHEC : pas de capture pour $onglet"; Get-Content (Join-Path $donnees 'erreurs.txt') -ErrorAction SilentlyContinue | Select-Object -First 5 }
}
