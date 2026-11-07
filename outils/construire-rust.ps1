# Mindset en Rust : construit ses programmes en Rust et assemble le dossier de Mindset prêt à zipper (le contenu est
# décrit dans outils\contenu-rust.ps1). Lancé par la CI de GitHub (.github\workflows\tests.yml et release.yml) ; sur le
# PC, seulement pour un essai : le zip publié vient toujours de GitHub (outils\zip-rust-github.ps1).
#
#   & '.\outils\construire-rust.ps1' -Sortie <dossier> [-HorsLigne] [-SansConstruire] [-Construits <dossier release>]
#
#   <dossier>\Mindset\   Mindset.exe, MindsetInstallateur.exe, Desinstaller Mindset.exe, version.json, LISEZMOI.txt,
#                        fichiers\ (apps.json, apps-liste.txt, cles-publiques\, Mindset.ico, installer-admin.ps1, version.ps1)
#
# Construction de publication seulement : cargo build --release --locked, sans aucune option (jamais l'option « essai »
# de mindset-appli ni du désinstalleur : règle 5 de docs\regles-tauri.md). Le dossier <dossier>\Mindset est vidé d'abord.
# Chaque programme est trouvé par son nom de programme cargo (cargo metadata), et doit être construit par la crate
# attendue ; un programme qui manque : erreur claire, rien n'est assemblé.
# -HorsLigne : cargo sans réseau (--offline), pour un essai sur le PC. -SansConstruire : seulement l'assemblage, avec les
# exe déjà construits. -Construits : le dossier « release » où les prendre (sans lui, celui de cargo metadata) ; avec
# -SansConstruire et -Construits, cargo n'est pas lancé du tout.
param(
    [Parameter(Mandatory = $true)][string]$Sortie,
    [switch]$HorsLigne,
    [switch]$SansConstruire,
    [string]$Construits = ''
)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$rust = Join-Path $racine 'rust'
. (Join-Path $PSScriptRoot 'contenu-rust.ps1')

$version = Get-VersionMindsetRust $racine
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Version de mindset-appli introuvable ou mal écrite : « $version » (rust\mindset-appli\Cargo.toml)." }
$versionPs = Get-VersionMindsetPs $racine
if ($versionPs -ne $version) {
    # (normal entre deux publications : outils\publier.ps1 -Rust écrit la même version aux deux endroits ; la
    # vérification du zip à publier, elle, la refuse)
    Write-Host "Attention : MindsetInstallateur.exe et le désinstalleur auront la version de Mindset.ps1 ($versionPs), pas celle de mindset-appli ($version). outils\version-rust.ps1 les aligne." -ForegroundColor Yellow
}

# cargo écrit ses messages normaux sur la sortie d'erreur : seul son code de sortie compte
function Invoke-Cargo([string[]]$Arguments, [switch]$Capturer) {
    $avant = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $rust
    try {
        if ($HorsLigne) { $Arguments += '--offline' }
        if ($Capturer) { $s = @(& cargo @Arguments 2>$null) } else { & cargo @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host }
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $avant
    }
    if ($code) { throw "cargo $($Arguments -join ' ') a échoué (code $code)." }
    if ($Capturer) { $s -join "`n" }
}

if ($SansConstruire -and $Construits) {
    $dossierConstruits = [IO.Path]::GetFullPath($Construits)
} else {
    # Quelle crate construit chaque programme, et le dossier où cargo range ce qu'il construit (CARGO_TARGET_DIR compris)
    $meta = Invoke-Cargo @('metadata', '--no-deps', '--format-version', '1', '--locked') -Capturer | ConvertFrom-Json
    $manque = @()
    foreach ($nom in $MindsetRust.Programmes.Keys) {
        $p = $MindsetRust.Programmes[$nom]
        $trouves = @($meta.packages | Where-Object { @($_.targets | Where-Object { $_.kind -contains 'bin' -and $_.name -ceq $p.Bin }).Count })
        if ($trouves.Count -ne 1) { $manque += "$nom (programme cargo « $($p.Bin) » de $($p.Paquet) : $(if ($trouves.Count) { "dans $($trouves.Count) crates" } else { 'aucune crate ne le construit' }))"; continue }
        if ($trouves[0].name -cne $p.Paquet) { $manque += "$nom (programme « $($p.Bin) » construit par $($trouves[0].name) au lieu de $($p.Paquet))"; continue }
        # Jamais la construction d'essai : l'option « essai » ne doit pas être dans les options par défaut
        if (@($trouves[0].features.default) -contains 'essai') { $manque += "$nom : l'option « essai » de $($trouves[0].name) est dans ses options par défaut"; continue }
    }
    if ($manque.Count) { throw "Mindset en Rust incomplet :`n  $($manque -join "`n  ")" }
    $dossierConstruits = if ($Construits) { [IO.Path]::GetFullPath($Construits) } else { Join-Path $meta.target_directory 'release' }
    if (-not $SansConstruire) {
        $construction = @('build', '--release', '--locked')
        foreach ($n in @($MindsetRust.Programmes.Values | ForEach-Object { $_.Paquet } | Sort-Object -Unique)) { $construction += @('-p', $n) }
        Invoke-Cargo $construction
    }
}

$dossier = Join-Path ([IO.Path]::GetFullPath($Sortie)) 'Mindset'
if (Test-Path -LiteralPath $dossier) { Remove-Item -LiteralPath $dossier -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $dossier 'fichiers\cles-publiques') | Out-Null
foreach ($nom in $MindsetRust.Programmes.Keys) {
    $chemin = Join-Path $dossierConstruits "$($MindsetRust.Programmes[$nom].Bin).exe"
    if (-not (Test-Path -LiteralPath $chemin -PathType Leaf)) { throw "$($MindsetRust.Programmes[$nom].Bin).exe introuvable dans $dossierConstruits : la construction ne l'a pas fait." }
    Copy-Item -LiteralPath $chemin -Destination (Join-Path $dossier $nom)
}

# version.json en UTF-8 sans marque (comme le lisent l'installateur et suite-commun) ; version.ps1 en UTF-8 avec marque
[IO.File]::WriteAllText((Join-Path $dossier $MindsetRust.VersionJson), (Get-TexteVersionJson $version), (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $dossier $MindsetRust.VersionPs1), (Get-TexteVersionPs1 $version), (New-Object Text.UTF8Encoding($true)))

foreach ($rel in $MindsetRust.Copies.Keys) {
    $source = Join-Path $racine $MindsetRust.Copies[$rel]
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Fichier à livrer absent : $($MindsetRust.Copies[$rel])" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $dossier $rel)
}
$cles = @(Get-ChildItem -LiteralPath (Join-Path $racine $MindsetRust.Cles) -Filter '*.xml' -File)
if (-not $cles.Count) { throw "Aucune clé publique dans $($MindsetRust.Cles)" }
foreach ($c in $cles) { Copy-Item -LiteralPath $c.FullName -Destination (Join-Path $dossier 'fichiers\cles-publiques') }

"OK : $dossier (Mindset $version en Rust)"
Get-ChildItem -LiteralPath $dossier -Recurse -File | ForEach-Object { "  $($_.FullName.Substring($dossier.Length + 1)) ($($_.Length) octets)" }
