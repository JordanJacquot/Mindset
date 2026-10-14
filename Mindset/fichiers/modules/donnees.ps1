# Mindset : dossiers de données, journal et réglages.
# Chargé par Mindset.ps1, qui définit $AppDir et $ModulesDir.
#
#   %LOCALAPPDATA%\Mindset\             les données de la suite
#     suite.json                        commun à Mindset et aux applis (thème, applis gérées) : suite.ps1
#     Mindset\                          celles de Mindset (journal, réglages, installations, téléchargements)
#     Nevermind\, Evermind\             celles des applis gérées par Mindset (elles s'y installent elles-mêmes)

$SuiteDir = Join-Path $env:LOCALAPPDATA 'Mindset'
if ($EnTest -and $env:MINDSET_DONNEES) { $SuiteDir = $env:MINDSET_DONNEES }
$DataDir = Join-Path $SuiteDir 'Mindset'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Premières versions : les fichiers de Mindset étaient à la racine
foreach ($n in 'journal.txt', 'reglages.json', 'installations.json') {
    $a = Join-Path $SuiteDir $n
    if ((Test-Path -LiteralPath $a) -and -not (Test-Path -LiteralPath (Join-Path $DataDir $n))) { try { Move-Item -LiteralPath $a -Destination $DataDir } catch {} }
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
