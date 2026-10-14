# Mindset : le fichier commun de la suite, %LOCALAPPDATA%\Mindset\suite.json.
#
#   theme    le thème de la suite (neon, crepuscule, terminal, arcade, rubis)
#   micro    le micro de la suite (son nom, comme Windows le donne, coupé à 31 lettres) ; "" = celui de Windows
#   casque   la sortie audio de la suite (casque, haut-parleurs), pareil ; "" = celle de Windows
#   applis   { id = dossier } : les applis installées ou prises en charge par Mindset
# Ces réglages communs ne se règlent que dans Mindset (Paramètres) : les applis gérées les suivent.
#
# Nevermind et Evermind le lisent : s'ils sont dans « applis » (leur dossier), ils prennent le thème de la suite
# et se relancent quand il change ; s'ils changent de thème eux-mêmes, ils l'écrivent ici et tout le monde suit.
# Sécurité : n'importe quel programme de l'utilisateur peut modifier ce fichier. Chacun n'y accepte qu'un nom de
# thème connu, et un dossier n'y sert qu'à comparer avec le sien, jamais à lancer quoi que ce soit.
# Chargé par Mindset.ps1 après donnees.ps1.

$SuiteFile = Join-Path $SuiteFileDir 'suite.json'   # toujours dans %LOCALAPPDATA%\Mindset, où que soit installée la suite
$ThemesSuite = @('neon', 'crepuscule', 'terminal', 'arcade', 'rubis')
# Un thème de la suite : un des 5 thèmes de base, ou « pack:<id> », un thème personnalisé importé dans Mindset (packs.ps1)
function Test-ThemeSuite($T) { $T -is [string] -and ($T -in $ThemesSuite -or $T -match '^pack:[a-z0-9-]{1,40}$') }

# Un nom d'appareil audio : une chaîne courte et sans caractère de contrôle (il ne sert qu'à être comparé)
function Test-NomAppareil($Nom) { $Nom -is [string] -and $Nom.Length -le 64 -and $Nom -notmatch '[\x00-\x1F]' }

function Read-Suite {
    $s = @{ theme = $null; micro = $null; casque = $null; applis = @{} }
    if (-not (Test-Path -LiteralPath $SuiteFile)) { return $s }
    try {
        $j = [IO.File]::ReadAllText($SuiteFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if (Test-ThemeSuite $j.theme) { $s.theme = [string]$j.theme }
        if ($null -ne $j.micro -and (Test-NomAppareil $j.micro)) { $s.micro = [string]$j.micro }
        if ($null -ne $j.casque -and (Test-NomAppareil $j.casque)) { $s.casque = [string]$j.casque }
        if ($j.applis) { foreach ($p in $j.applis.PSObject.Properties) { if ($p.Name -match '^[a-z0-9-]+$' -and $p.Value -is [string]) { $s.applis[$p.Name] = $p.Value } } }
    } catch { Write-Log "suite.json illisible : $_" }
    $s
}

function Write-Suite($Suite) {
    if ($EnTest -and -not $env:MINDSET_DONNEES) { return }
    $o = [ordered]@{ theme = $Suite.theme }
    if ($null -ne $Suite.micro) { $o.micro = $Suite.micro }
    if ($null -ne $Suite.casque) { $o.casque = $Suite.casque }
    $o.applis = $Suite.applis; $o.modifie = (Get-Date).ToString('s')
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
    if (-not (Test-ThemeSuite $Id)) { return }
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

# Micro et casque de la suite ; tant qu'ils n'ont jamais été choisis dans Mindset, ceux d'Evermind (s'il est installé)
function Get-SuiteSon {
    $s = Read-Suite
    $r = @{ Micro = $s.micro; Casque = $s.casque }
    if ($null -eq $r.Micro -or $null -eq $r.Casque) {
        foreach ($f in "$SuiteDir\Evermind\reglages.json", "$env:LOCALAPPDATA\Evermind\reglages.json") {
            try {
                $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($null -eq $r.Micro -and (Test-NomAppareil ([string]$j.Micro))) { $r.Micro = [string]$j.Micro }
                if ($null -eq $r.Casque -and (Test-NomAppareil ([string]$j.Casque))) { $r.Casque = [string]$j.Casque }
                break
            } catch {}
        }
    }
    if ($null -eq $r.Micro) { $r.Micro = '' }
    if ($null -eq $r.Casque) { $r.Casque = '' }
    $r
}

# $Quoi : 'micro' ou 'casque' ; $Nom : le nom de l'appareil, '' pour celui de Windows
function Set-SuiteSon([string]$Quoi, [string]$Nom) {
    if ($Quoi -notin 'micro', 'casque' -or -not (Test-NomAppareil $Nom)) { return }
    $s = Read-Suite; $s[$Quoi] = $Nom
    # (le premier choix fixe aussi l'autre, pour que les applis ne retombent pas sur leur ancien réglage)
    $son = Get-SuiteSon
    if ($null -eq $s.micro) { $s.micro = $son.Micro }
    if ($null -eq $s.casque) { $s.casque = $son.Casque }
    if (-not $s.theme) { $s.theme = Get-SuiteTheme }
    Write-Suite $s
    Write-Log "Son de la suite : $Quoi = « $Nom »"
}
