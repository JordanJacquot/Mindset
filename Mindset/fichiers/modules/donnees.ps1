# Mindset : où sont les programmes et les données, journal et réglages.
# Chargé par Mindset.ps1, qui définit $AppDir et $ModulesDir.
#
# Mindset s'installe sur le disque choisi à l'installation :
#   par défaut   programmes  C:\Program Files\Mindset\<Appli>      données  %LOCALAPPDATA%\Mindset\<Appli>
#   autre disque programmes  X:\Mindset\Programmes\<Appli>        données  X:\Mindset\Donnees\<Appli>
# L'emplacement se déduit toujours de celui du programme (protégé : seul un administrateur peut y écrire), jamais
# d'un fichier modifiable. suite.json (thème, applis gérées) reste toujours dans %LOCALAPPDATA%\Mindset.

$SuiteFileDir = Join-Path $env:LOCALAPPDATA 'Mindset'

# Racines d'une installation dont on connaît le dossier du programme Mindset (…\Mindset)
function Get-RacinesDepuis([string]$DossierMindset) {
    $p = Split-Path $DossierMindset -Parent; $m = Split-Path $p -Parent
    if ((Split-Path $p -Leaf) -eq 'Programmes' -and $m -and (Split-Path $m -Leaf) -eq 'Mindset') {
        return @{ Programmes = $p; Donnees = (Join-Path $m 'Donnees'); Disque = $m.Substring(0, 1).ToUpper() }
    }
    @{ Programmes = (Join-Path $env:ProgramFiles 'Mindset'); Donnees = $SuiteFileDir; Disque = '' }
}

# Ce Mindset est-il installé ? Sinon (lancé depuis le dossier téléchargé), celui inscrit dans « Applications
# installées » (écrit en administrateur) donne les racines ; sans installation, les racines par défaut.
$MonDossier = Split-Path $AppDir -Parent
$Racines = Get-RacinesDepuis $MonDossier
if ((Split-Path $MonDossier -Leaf) -ne 'Mindset' -or (Join-Path $Racines.Programmes 'Mindset') -ine $MonDossier) {
    $Racines = Get-RacinesDepuis 'C:\_\Mindset'   # (défaut)
    try {
        $inscrit = [string](Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset' -ErrorAction Stop).InstallLocation
        if ($inscrit -and (Test-Path -LiteralPath (Join-Path $inscrit 'Mindset.exe'))) { $Racines = Get-RacinesDepuis $inscrit }
    } catch {}
}
$RacineProgrammes = $Racines.Programmes
$SuiteDir = $Racines.Donnees
if ($EnTest -and $env:MINDSET_DONNEES) { $SuiteDir = $env:MINDSET_DONNEES; $SuiteFileDir = $env:MINDSET_DONNEES }
$DataDir = Join-Path $SuiteDir 'Mindset'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Premières versions : les fichiers de Mindset étaient à la racine de %LOCALAPPDATA%\Mindset
foreach ($n in 'journal.txt', 'reglages.json', 'installations.json') {
    foreach ($a in (Join-Path $SuiteFileDir $n), (Join-Path $SuiteFileDir "Mindset\$n")) {
        $b = Join-Path $DataDir $n
        if ($a -ine $b -and (Test-Path -LiteralPath $a) -and -not (Test-Path -LiteralPath $b)) { try { Move-Item -LiteralPath $a -Destination $DataDir } catch {} }
    }
}

$LogFile = Join-Path $DataDir 'journal.txt'
$SettingsFile = Join-Path $DataDir 'reglages.json'

function Write-Log([string]$Texte) {
    try { [IO.File]::AppendAllText($LogFile, "$((Get-Date).ToString('s')) $Texte`r`n", (New-Object Text.UTF8Encoding $false)) } catch {}
}

# Réglages : un simple fichier JSON, relu au démarrage
$script:Settings = @{}
if (Test-Path -LiteralPath $SettingsFile) {
    try {
        $j = [IO.File]::ReadAllText($SettingsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $script:Settings[$p.Name] = $p.Value }
    } catch { Write-Log "Réglages illisibles, valeurs par défaut : $_" }
}

function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Settings.ContainsKey($Nom)) { $script:Settings[$Nom] } else { $Defaut } }

function Set-Setting([string]$Nom, $Valeur) {
    $script:Settings[$Nom] = $Valeur
    if ($EnTest) { return }
    try { [IO.File]::WriteAllText($SettingsFile, ($script:Settings | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
    catch { Write-Log "Réglages non enregistrés : $_" }
}
