# Publie une nouvelle version de Mindset sur GitHub (Mindset.zip et sa signature Mindset.zip.sig).
#
#   .\outils\publier.ps1 -Version 0.1.0 -Notes "Ce qui change dans cette version"
#
# Avant de publier : syntaxe de tous les .ps1, fenêtre (interface.xaml), tirets cadratins, capture de test.
# Le zip est signé avec la clé de la suite (outils\signer.ps1) : sans clé sur ce PC, rien n'est publié.
# Avec les programmes en Rust (rust\mindset-installateur, rust\desinstalleur), MindsetInstallateur.exe et le
# désinstalleur viennent de la construction GitHub du commit publié, attestation vérifiée (outils\exe-rust.ps1).

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Notes = ''
)
$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$app    = Join-Path $racine 'Mindset'
$ps1    = Join-Path $app 'fichiers\Mindset.ps1'
$zip    = Join-Path $racine 'release\Mindset.zip'
$utf8   = New-Object Text.UTF8Encoding($true)

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Numéro de version invalide : $Version (exemple : 0.1.0)" }

# Un numéro déjà publié ne doit jamais être réutilisé
Push-Location $racine
try {
    $ErrorActionPreference = 'Continue'   # « introuvable » est la réponse attendue ici
    git rev-parse -q --verify "refs/tags/v$Version" 2>$null | Out-Null; $tagExiste = ($LASTEXITCODE -eq 0)
    gh release view "v$Version" 2>$null | Out-Null; $releaseExiste = ($LASTEXITCODE -eq 0)
} finally { Pop-Location; $ErrorActionPreference = 'Stop' }
if ($tagExiste -or $releaseExiste) { throw "La version $Version existe déjà. Choisis un numéro plus grand." }

# Vérifications
$problemes = @()
foreach ($f in Get-ChildItem -LiteralPath $racine -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\(\.git|_test|release)\\' }) {
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
    foreach ($e in $err) { $problemes += "Syntaxe : $($f.Name) ligne $($e.Extent.StartLineNumber) : $($e.Message)" }
}
try { [void][xml][IO.File]::ReadAllText((Join-Path $app 'fichiers\modules\interface.xaml'), [Text.Encoding]::UTF8) } catch { $problemes += "interface.xaml : $($_.Exception.Message)" }
$tirets = Get-ChildItem -LiteralPath $racine -Recurse -File -Include '*.ps1', '*.cs', '*.xaml', '*.txt', '*.md', '*.json' |
    Where-Object { $_.FullName -notmatch '\\(\.git|_test|release)\\' } | Select-String -Pattern '[\u2013\u2014]'
foreach ($t in $tirets) { $problemes += "Tiret cadratin : $($t.Path) ligne $($t.LineNumber)" }
if ($problemes) { $problemes | ForEach-Object { Write-Host $_ -ForegroundColor Red }; throw 'Publication annulée : corrige les points ci dessus.' }

# Un programme (git, gh) : seul son code de sortie compte. Ses avertissements (« LF will be replaced by CRLF »...) ne
# sont pas des échecs : sans « Continue », PowerShell les prenait pour des erreurs et arrêtait la publication.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE) { throw "Échec : $Exe $($Arguments -join ' ')" }
}

# Les programmes en Rust (passage en Rust, plan 3.6) : MindsetInstallateur.exe quand rust\mindset-installateur existe,
# le désinstalleur quand rust\desinstalleur existe. Ils ne sont jamais construits sur ce PC : ils viennent de la
# construction GitHub (release.yml) du commit publié, et leur attestation est vérifiée (bon dépôt, bon fichier de
# construction, ce commit) avant de prendre leur place dans le dossier ; sinon, rien n'est publié (outils\exe-rust.ps1).
# Le commit publié doit donc contenir tout ce qui part dans le zip : rien de pas commité, et le numéro de version est
# commité et envoyé AVANT la construction (GitHub construit ce commit-là).
# Sans rust\mindset-installateur ni rust\desinstalleur, rien de tout ça : la publication reste la même.
$rust = (Test-Path -LiteralPath (Join-Path $racine 'rust\mindset-installateur\Cargo.toml')) -or (Test-Path -LiteralPath (Join-Path $racine 'rust\desinstalleur\Cargo.toml'))
$siens = @('Mindset/fichiers/Mindset.ps1', 'outils/lanceur.cs')   # (les deux fichiers où le numéro de version est écrit)
function Get-NonCommites {
    $avant = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); @(& git -C $racine -c core.quotepath=false status --porcelain 2>$null | Where-Object { $_ }) }
    finally { [Console]::OutputEncoding = $avant }
}
if ($rust) {
    $sale = @(Get-NonCommites)
    # (une publication arrêtée en route avant son commit, par exemple un envoi raté, laisse seulement le numéro de
    # version écrit dans ces deux fichiers : on les remet comme dans git, ils sont réécrits juste après. Arrêtée après
    # son commit, par exemple un mot de passe mal tapé, elle ne laisse rien : le commit « Mindset X » est repris tel
    # quel, avec la construction GitHub déjà faite pour lui.)
    if ($sale.Count -and -not @($sale | Where-Object { $_ -notmatch '^(M |MM| M) ' -or $siens -notcontains $_.Substring(3).Trim('"') }).Count) {
        Invoke-Native 'git' @('-C', $racine, 'reset', '-q', '--', $siens[0], $siens[1]) | Out-Null
        Invoke-Native 'git' @('-C', $racine, 'checkout', '--', $siens[0], $siens[1]) | Out-Null
        Write-Host 'Le numéro de version laissé par une publication arrêtée en route est remis comme dans git.'
        $sale = @()
    }
    if ($sale.Count) { throw "Publication annulée : des fichiers ne sont pas commités ($(($sale | Select-Object -First 5) -join ' ; ')). Commite-les d'abord : la version publiée est celle de git." }
}

# 1. Numéro de version
$c = [IO.File]::ReadAllText($ps1, [Text.Encoding]::UTF8)
$c = [regex]::Replace($c, "(?m)^\`$AppVersion = '[^']*'", "`$AppVersion = '$Version'")
$c = [regex]::Replace($c, '(?m)^    Mindset [\d\.]+\r?$', "    Mindset $Version`r")
[IO.File]::WriteAllText($ps1, $c, $utf8)
$cs = Join-Path $PSScriptRoot 'lanceur.cs'
$l = [IO.File]::ReadAllText($cs, [Text.Encoding]::UTF8)
$l = [regex]::Replace($l, 'Assembly(File)?Version\("[\d\.]+"\)', { param($m) "Assembly$($m.Groups[1].Value)Version(`"$Version.0`")" })
[IO.File]::WriteAllText($cs, $l, $utf8)

# Avec les programmes en Rust : le numéro de version commité (s'il a changé) et envoyé, puis les exe construits par
# GitHub pour ce commit, attestation vérifiée (exe-rust.ps1 envoie le commit et lance la construction si besoin)
$exeRust = $null
if ($rust) {
    if (@(Get-NonCommites).Count) {
        Invoke-Native 'git' @('-C', $racine, 'add', '--', $siens[0], $siens[1]) | Out-Null
        Invoke-Native 'git' @('-C', $racine, 'commit', '-q', '-m', "Mindset $Version", '-m', $(if ($Notes) { $Notes } else { "Version $Version" })) | Out-Null
    }
    $exeRust = & (Join-Path $PSScriptRoot 'exe-rust.ps1')
    if (-not $exeRust -or -not $exeRust.Count) { throw 'Publication annulée : les programmes en Rust construits par GitHub manquent.' }
}

# 2. Construction (Mindset.exe, release\Mindset.zip), capture de test, puis signature
& (Join-Path $PSScriptRoot 'construire.ps1')
if ($rust) {
    # Les exe en Rust vérifiés à leur place (le désinstalleur remplace celui en C# de construire.ps1), puis le zip refait
    foreach ($n in @($exeRust.Keys)) { Copy-Item -LiteralPath $exeRust[$n] -Destination (Join-Path $app $n) -Force }
    Compress-Archive -Path $app -DestinationPath $zip -Force
    Write-Host "$(@($exeRust.Keys) -join ' et ') : construits par GitHub (Rust), attestation vérifiée." -ForegroundColor Green
    # (construire.ps1 ne doit avoir changé aucun fichier suivi : le zip est exactement le commit publié)
    $sale = @(Get-NonCommites)
    if ($sale.Count) { throw "Publication annulée : la construction a changé des fichiers suivis ($(($sale | Select-Object -First 5) -join ' ; '))." }
}
$capture = Join-Path $env:TEMP "mindset-publier-$Version.png"
$env:MINDSET_TEST = '1'; $env:MINDSET_SANS_RESEAU = '1'; $env:MINDSET_CAPTURE = $capture
$env:MINDSET_DONNEES = Join-Path $env:TEMP "mindset-publier-donnees"
try { $p = Start-Process (Join-Path $app 'Mindset.exe') -PassThru -Wait } finally { foreach ($v in 'MINDSET_TEST', 'MINDSET_SANS_RESEAU', 'MINDSET_CAPTURE', 'MINDSET_DONNEES') { Remove-Item "env:$v" -ErrorAction SilentlyContinue } }
if ($p.ExitCode -or -not (Test-Path -LiteralPath $capture)) { throw 'Publication annulée : Mindset ne s''ouvre pas (capture de test impossible).' }
Remove-Item -LiteralPath "$zip.sig" -Force -ErrorAction SilentlyContinue
& (Join-Path $PSScriptRoot 'signer.ps1') -Fichier $zip
if (-not (Test-Path -LiteralPath "$zip.sig")) { throw 'Publication annulée : signature absente.' }

# 3. Commit, tag, Release
Push-Location $racine
try {
    Invoke-Native git @('add', '-A')
    # (rien à commiter si le numéro de version était déjà le bon)
    if (git status --porcelain) { Invoke-Native git @('commit', '-m', "Mindset $Version", '-m', $(if ($Notes) { $Notes } else { "Version $Version" })) }
    Invoke-Native git @('tag', "v$Version")
    Invoke-Native git @('push')
    Invoke-Native git @('push', 'origin', "v$Version")
    Invoke-Native gh @('release', 'create', "v$Version", $zip, "$zip.sig", '--title', "Mindset $Version", '--notes', $Notes)
} finally { Pop-Location }
"Mindset $Version publié."
