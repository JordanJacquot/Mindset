# Mindset : dossier de données, journal et réglages.
# Chargé par Mindset.ps1, qui définit $AppDir et $ModulesDir.

$DataDir = Join-Path $env:LOCALAPPDATA 'Mindset'
if ($EnTest -and $env:MINDSET_DONNEES) { $DataDir = $env:MINDSET_DONNEES }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
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
