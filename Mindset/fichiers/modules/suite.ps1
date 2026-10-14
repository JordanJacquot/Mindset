# Mindset : le fichier commun de la suite, %LOCALAPPDATA%\Mindset\suite.json.
#
#   theme    le thème de la suite (neon, crepuscule, terminal, arcade, rubis)
#   applis   { id = dossier } : les applis installées ou prises en charge par Mindset
#
# Nevermind et Evermind le lisent : s'ils sont dans « applis » (leur dossier), ils prennent le thème de la suite
# et se relancent quand il change ; s'ils changent de thème eux-mêmes, ils l'écrivent ici et tout le monde suit.
# Sécurité : n'importe quel programme de l'utilisateur peut modifier ce fichier. Chacun n'y accepte qu'un nom de
# thème connu, et un dossier n'y sert qu'à comparer avec le sien, jamais à lancer quoi que ce soit.
# Chargé par Mindset.ps1 après donnees.ps1.

$SuiteFile = Join-Path $SuiteFileDir 'suite.json'   # toujours dans %LOCALAPPDATA%\Mindset, où que soit installée la suite
$ThemesSuite = @('neon', 'crepuscule', 'terminal', 'arcade', 'rubis')

function Read-Suite {
    $s = @{ theme = $null; applis = @{} }
    if (-not (Test-Path -LiteralPath $SuiteFile)) { return $s }
    try {
        $j = [IO.File]::ReadAllText($SuiteFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($j.theme -in $ThemesSuite) { $s.theme = [string]$j.theme }
        if ($j.applis) { foreach ($p in $j.applis.PSObject.Properties) { if ($p.Name -match '^[a-z0-9-]+$' -and $p.Value -is [string]) { $s.applis[$p.Name] = $p.Value } } }
    } catch { Write-Log "suite.json illisible : $_" }
    $s
}

function Write-Suite($Suite) {
    if ($EnTest -and -not $env:MINDSET_DONNEES) { return }
    $o = [ordered]@{ theme = $Suite.theme; applis = $Suite.applis; modifie = (Get-Date).ToString('s') }
    # Écrit à côté puis remplacé d'un coup : une appli qui lit au même moment ne voit jamais un fichier à moitié écrit
    $tmp = "$SuiteFile.tmp"
    [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $SuiteFile -Force
}

# Thème de la suite ; au tout premier lancement, celui d'Evermind (ou de Nevermind) s'il est déjà installé
function Get-SuiteTheme {
    $s = Read-Suite
    if ($s.theme) { return $s.theme }
    foreach ($f in "$SuiteDir\Evermind\reglages.json", "$env:LOCALAPPDATA\Evermind\reglages.json", "$SuiteDir\Nevermind\parametres.json", "$env:LOCALAPPDATA\OptiGame\parametres.json") {
        try {
            $t = [string]([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json).Theme
            if ($t -in $ThemesSuite) { return $t }
        } catch {}
    }
    'neon'
}

function Set-SuiteTheme([string]$Id) {
    if ($Id -notin $ThemesSuite) { return }
    $s = Read-Suite; $s.theme = $Id; Write-Suite $s
    Write-Log "Thème de la suite : $Id"
}

# Appli installée ou prise en charge par Mindset (son dossier), ou retirée ($null)
function Set-SuiteAppli([string]$Id, [string]$Dossier) {
    $s = Read-Suite
    if ($Dossier) { $s.applis[$Id] = $Dossier } else { $s.applis.Remove($Id) }
    if (-not $s.theme) { $s.theme = Get-SuiteTheme }
    Write-Suite $s
}
