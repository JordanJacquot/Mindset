# Mindset en Rust : écrit le numéro de version partout où un programme en Rust le prend, et nulle part ailleurs.
# Utilisé par outils\publier.ps1 -Rust.
#   - rust\mindset-appli\Cargo.toml (ligne « version = » de [package]) et sa ligne de rust\Cargo.lock (sinon
#     « cargo build --locked » refuse de construire) : Mindset.exe et version.json ;
#   - $AppVersion et l'en-tête de Mindset\fichiers\Mindset.ps1 : MindsetInstallateur.exe et « Desinstaller Mindset.exe »
#     (leur build.rs la lit là), et fichiers\version.ps1 du zip garde la même (outils\contenu-rust.ps1).
# Fins de ligne et encodage de chaque fichier gardés (Mindset.ps1 : UTF-8 avec marque ; les deux autres sans).
#
#   & '.\outils\version-rust.ps1' -Version 3.0.0 [-Racine <copie du dépôt>]
#
# -Racine (essais seulement) : une copie du dépôt où écrire, à la place de celui de ce script.
param([Parameter(Mandatory = $true)][string]$Version, [string]$Racine = '')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Numéro de version invalide : $Version (exemple : 3.0.0)" }
$racine = if ($Racine) { [IO.Path]::GetFullPath($Racine) } else { Split-Path $PSScriptRoot -Parent }
$cargoAppli = Join-Path $racine 'rust\mindset-appli\Cargo.toml'
$cargoLock = Join-Path $racine 'rust\Cargo.lock'
$ps1 = Join-Path $racine 'Mindset\fichiers\Mindset.ps1'
$sansBom = New-Object Text.UTF8Encoding($false)
$avecBom = New-Object Text.UTF8Encoding($true)

# Cargo.toml : la ligne « version = "..." » de la section [package] (les autres « version = » sont celles des
# bibliothèques)
$texte = [IO.File]::ReadAllText($cargoAppli, [Text.Encoding]::UTF8)
$lignes = [regex]::Split($texte, '(?<=\n)')
$section = ''; $fait = $false
for ($i = 0; $i -lt $lignes.Count; $i++) {
    $l = $lignes[$i].Trim()
    if ($l.StartsWith('[')) { $section = $l; continue }
    if ($section -eq '[package]' -and $l -match '^version\s*=\s*"[^"]*"\s*$') { $lignes[$i] = [regex]::Replace($lignes[$i], '"[^"]*"', "`"$Version`"", 1); $fait = $true; break }
}
if (-not $fait) { throw "Ligne « version » de [package] introuvable dans $cargoAppli" }
[IO.File]::WriteAllText($cargoAppli, ($lignes -join ''), $sansBom)

# Cargo.lock : l'entrée de mindset-appli seulement
$lock = [IO.File]::ReadAllText($cargoLock, [Text.Encoding]::UTF8)
$motif = '(?m)^(name = "mindset-appli"\r?\nversion = ")[^"]*(")'
if (-not [regex]::IsMatch($lock, $motif)) { throw "mindset-appli introuvable dans $cargoLock" }
[IO.File]::WriteAllText($cargoLock, [regex]::Replace($lock, $motif, "`${1}$Version`${2}"), $sansBom)

# Mindset.ps1 : $AppVersion et l'en-tête « Mindset x.y.z », comme outils\publier.ps1 (version PowerShell)
$c = [IO.File]::ReadAllText($ps1, [Text.Encoding]::UTF8)
if ($c -notmatch "(?m)^\`$AppVersion = '[^']*'") { throw "Ligne `$AppVersion introuvable dans $ps1" }
$c = [regex]::Replace($c, "(?m)^\`$AppVersion = '[^']*'", "`$AppVersion = '$Version'")
$c = [regex]::Replace($c, '(?m)^(    Mindset) [\d\.]+(\r?)$', "`$1 $Version`$2")
[IO.File]::WriteAllText($ps1, $c, $avecBom)

"Mindset en Rust : version $Version écrite dans rust\mindset-appli\Cargo.toml, rust\Cargo.lock et Mindset\fichiers\Mindset.ps1."
