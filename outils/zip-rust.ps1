# Mindset en Rust : fait Mindset.zip à partir du dossier assemblé par outils\construire-rust.ps1, au même format que les
# zips d'avant (Compress-Archive du dossier « Mindset » : celui qu'attend l'installateur de 2.18, avec Mindset.exe
# dedans), puis le vérifie (outils\verifier-zip-rust.ps1). Utilisé par la construction GitHub (.github\workflows\
# release.yml et tests.yml) ; sur le PC, seulement pour un essai : le zip publié vient toujours de GitHub.
#
#   & '.\outils\zip-rust.ps1' -Dossier <sortie>\Mindset -Zip <dossier>\Mindset.zip [-Ci]
#
# Le zip déjà là est remplacé. Code de sortie 1 (et le zip effacé) si la vérification échoue. -Ci : voir
# outils\verifier-zip-rust.ps1 (tests de GitHub entre deux publications seulement).
param(
    [Parameter(Mandatory = $true)][string]$Dossier,
    [Parameter(Mandatory = $true)][string]$Zip,
    [switch]$Ci
)
$ErrorActionPreference = 'Stop'
$Dossier = [IO.Path]::GetFullPath($Dossier).TrimEnd('\')
$Zip = [IO.Path]::GetFullPath($Zip)
if ((Split-Path $Dossier -Leaf) -cne 'Mindset') { throw "Le dossier à zipper doit s'appeler Mindset : $Dossier" }
if (-not (Test-Path -LiteralPath (Join-Path $Dossier 'Mindset.exe') -PathType Leaf)) { throw "Mindset.exe introuvable dans $Dossier" }
if (Test-Path -LiteralPath (Join-Path $Dossier 'fichiers\Mindset.ps1')) { throw "$Dossier est le dossier de la version PowerShell (fichiers\Mindset.ps1) : son zip se fait avec outils\construire.ps1." }
New-Item -ItemType Directory -Force -Path (Split-Path $Zip -Parent) | Out-Null
Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
Compress-Archive -LiteralPath $Dossier -DestinationPath $Zip -Force
& (Join-Path $PSScriptRoot 'verifier-zip-rust.ps1') -Zip $Zip -Ci:$Ci
if ($LASTEXITCODE) { Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue; exit 1 }
exit 0
