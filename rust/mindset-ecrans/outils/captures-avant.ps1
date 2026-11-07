# Captures « avant » du bloc « écrans » : les écrans de la VERSION POWERSHELL (WPF), scène par scène, avec les données
# d'essai de vitrine.ps1. À lancer SEULEMENT sur un bureau Windows à part :
#
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '<ce fichier>' -Secondes 900
#
# Chaque scène : un Mindset PowerShell de test (MINDSET_TEST, données dans un dossier d'essai, sans réseau), qui dessine
# sa fenêtre hors de l'écran, l'enregistre (MINDSET_CAPTURE) et se ferme. Les images vont dans
# D:\Outils\Rust\essais\ecrans\captures\avant-<scène>.png ; l'heure de la vitrine dans maintenant.txt (la même pour les
# captures « après »).
param([string]$Fichiers = '')
$ErrorActionPreference = 'Stop'
$racineDepot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$mindset = if ($Fichiers) { $Fichiers } else { Join-Path $racineDepot 'Mindset\fichiers' }
$essais = 'D:\Outils\Rust\essais\ecrans'
$captures = Join-Path $essais 'captures'
New-Item -ItemType Directory -Force -Path $captures | Out-Null
[IO.File]::WriteAllText((Join-Path $essais 'maintenant.txt'), (Get-Date).ToString('s', [Globalization.CultureInfo]::InvariantCulture))
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$scenes = @(
    @{ Nom = 'accueil-neon' }
    @{ Nom = 'accueil-crepuscule'; MINDSET_THEME = 'crepuscule' }
    @{ Nom = 'accueil-terminal'; MINDSET_THEME = 'terminal' }
    @{ Nom = 'bienvenue'; MINDSET_BIENVENUE = '1'; MINDSET_VITRINE = 'bienvenue' }
    @{ Nom = 'bandeaux'; MINDSET_ADMIN_TEST = '1'; MINDSET_VITRINE = 'bandeaux' }
    @{ Nom = 'confirmation'; MINDSET_VITRINE = 'confirmation' }
    @{ Nom = 'fermeture'; MINDSET_FERMETURE = '1' }
    @{ Nom = 'jauge'; MINDSET_PAGE = 'nevermind'; MINDSET_JAUGE = '6' }
    @{ Nom = 'ecran-ouvrir'; MINDSET_PAGE = 'evermind'; MINDSET_ECRAN = '1' }
    @{ Nom = 'non-installe'; MINDSET_PAGE = 'mindcare' }
    @{ Nom = 'parametres'; MINDSET_PAGE = 'parametres' }
)
$code = 0
foreach ($sc in $scenes) {
    $dossier = Join-Path $essais "avant\$($sc.Nom)"
    if (Test-Path -LiteralPath $dossier) { Remove-Item -LiteralPath $dossier -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dossier | Out-Null
    $image = Join-Path $captures "avant-$($sc.Nom).png"
    if (Test-Path -LiteralPath $image) { Remove-Item -LiteralPath $image -Force }
    $vars = @{ MINDSET_TEST = '1'; MINDSET_SANS_RESEAU = '1'; MINDSET_DONNEES = $dossier; MINDSET_CAPTURE = $image; MINDSET_CAPTURE_DELAI = '2'
        MINDSET_TEST_SCRIPT = (Join-Path $PSScriptRoot 'vitrine.ps1'); MINDSET_VITRINE_DOSSIER = $essais; MINDSET_VERSION = '3.0.0'; MINDSET_VITRINE = '' }
    foreach ($k in $sc.Keys) { if ($k -ne 'Nom') { $vars[$k] = $sc[$k] } }
    $avant = @{}
    foreach ($k in $vars.Keys) { $avant[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try {
        $p = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$(Join-Path $mindset 'Mindset.ps1')`"") -PassThru -WindowStyle Hidden `
            -RedirectStandardError (Join-Path $dossier 'erreurs.txt') -RedirectStandardOutput (Join-Path $dossier 'sortie.txt')
        $null = $p.Handle
    } finally { foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $avant[$k]) } }
    if (-not $p.WaitForExit(90000)) { Stop-Process -Id $p.Id -Force; Write-Output "ÉCHEC : $($sc.Nom) (délai dépassé)"; $code = 1; continue }
    if (Test-Path -LiteralPath $image) { Write-Output "OK : $image" }
    else { Write-Output "ÉCHEC : $($sc.Nom), pas d'image ($([IO.File]::ReadAllText((Join-Path $dossier 'erreurs.txt'))))"; $code = 1 }
}
exit $code
