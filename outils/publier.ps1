# Publie une nouvelle version de Mindset sur GitHub (Mindset.zip et sa signature Mindset.zip.sig).
#
#   .\outils\publier.ps1 -Version 0.1.0 -Notes "Ce qui change dans cette version"
#
# Avant de publier : syntaxe de tous les .ps1, fenêtre (interface.xaml), tirets cadratins, capture de test.
# Le zip est signé avec la clé de la suite (outils\signer.ps1) : sans clé sur ce PC, rien n'est publié.
# Avec les programmes en Rust (rust\mindset-installateur, rust\desinstalleur), MindsetInstallateur.exe et le
# désinstalleur viennent de la construction GitHub du commit publié, attestation vérifiée (outils\exe-rust.ps1).
#
# Mindset en Rust (3.0 et après : rust\mindset-appli ; contenu du zip : outils\contenu-rust.ps1) :
#   .\outils\publier.ps1 -Rust -Version 3.0.0 -Notes "..."     publie Mindset en Rust pour tout le monde (décision de
#                                                             Jordan du 07/11 : pas de version d'essai)
#   .\outils\publier.ps1 -Rust -Essai [-ZipLocal <zip>]         essai à blanc : rien n'est modifié, envoyé ni publié
#
# -Rust : le zip n'est JAMAIS construit sur ce PC. Le numéro de version est écrit (outils\version-rust.ps1 :
# rust\mindset-appli\Cargo.toml et Cargo.lock, $AppVersion de Mindset.ps1 que prennent MindsetInstallateur.exe et le
# désinstalleur), commité et envoyé ; GitHub construit alors Mindset en Rust à partir de ce commit (release.yml, genre
# rust : cargo build --release --locked, cargo deny, règles Tauri, zip vérifié, attestation), après ses tests (tests.yml :
# tests PowerShell et Rust, zip vérifié, mise à jour 2.18 -> 3.0 -> 3.0.1 sans rien perdre ; sans elle, rien n'est
# publié). outils\zip-rust-github.ps1 récupère ce zip et vérifie son attestation (ce dépôt, release.yml, ce commit) ;
# outils\verifier-zip-rust.ps1 revérifie son contenu (fichiers exacts, version.json, fiches de version, pas de
# construction d'essai, aucun runtime C à part). Ensuite seulement : signature, tag, Release. Le numéro doit être plus
# grand que la dernière version PowerShell (Mindset ne revient jamais en arrière). Pour revenir en arrière : une version
# PowerShell normale plus haute.
#
# -Essai avec -Rust : les mêmes vérifications, sans rien écrire dans le dépôt ni rien envoyer sur GitHub. Le zip est celui
# que GitHub a déjà construit pour le commit en cours (seulement lu), ou -ZipLocal <Mindset.zip> (un zip fait sur ce PC
# par outils\zip-rust.ps1, sans attestation : seulement pour un essai). Il est signé avec une clé jetable.

param(
    [string]$Version = '',
    [string]$Notes = '',
    [switch]$Rust,
    [switch]$Essai,
    [string]$ZipLocal = '',
    [switch]$SansTest
)
$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$app    = Join-Path $racine 'Mindset'
$ps1    = Join-Path $app 'fichiers\Mindset.ps1'
$zip    = Join-Path $racine 'release\Mindset.zip'
$utf8   = New-Object Text.UTF8Encoding($true)

if ($Rust) {
    . (Join-Path $PSScriptRoot 'contenu-rust.ps1')
    if (-not (Get-VersionMindsetRust $racine)) { throw 'Mindset en Rust introuvable : rust\mindset-appli\Cargo.toml.' }
    if ($Essai -and -not $Version) { $Version = Get-VersionMindsetRust $racine }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Numéro de version invalide : $Version (exemple : 3.0.0)" }
    # Plus grand que la dernière version PowerShell (Mindset.ps1 et les tags) : Mindset ne revient jamais à une version
    # plus ancienne que celle installée
    if (-not $Essai) {
        $versionPs = Get-VersionMindsetPs $racine
        $ErrorActionPreference = 'Continue'   # (git : seule sa réponse compte)
        $tags = @(& git -C $racine tag --list 'v*' 2>$null | ForEach-Object { if ("$_" -match '^v(\d+(\.\d+){1,3})$') { [version]$Matches[1] } } | Sort-Object -Descending)
        $ErrorActionPreference = 'Stop'
        $plusHaute = @(@($versionPs | Where-Object { $_ } | ForEach-Object { [version]$_ }) + $tags | Sort-Object -Descending)[0]
        if ($plusHaute -and [version]$Version -le $plusHaute) { throw "Mindset en Rust doit avoir un numéro plus grand que la dernière version ($plusHaute)." }
    }
} else {
    if ($Essai -or $ZipLocal -or $SansTest) { throw '-Essai, -ZipLocal et -SansTest ne vont qu''avec -Rust.' }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Numéro de version invalide : $Version (exemple : 0.1.0)" }
}
if ($ZipLocal -and -not $Essai) { throw '-ZipLocal ne sert qu''à un essai (-Rust -Essai) : une vraie publication prend toujours le zip construit par GitHub.' }

# Un numéro déjà publié ne doit jamais être réutilisé
if (-not $Essai) {
    Push-Location $racine
    try {
        $ErrorActionPreference = 'Continue'   # « introuvable » est la réponse attendue ici
        git rev-parse -q --verify "refs/tags/v$Version" 2>$null | Out-Null; $tagExiste = ($LASTEXITCODE -eq 0)
        gh release view "v$Version" 2>$null | Out-Null; $releaseExiste = ($LASTEXITCODE -eq 0)
    } finally { Pop-Location; $ErrorActionPreference = 'Stop' }
    if ($tagExiste -or $releaseExiste) { throw "La version $Version existe déjà. Choisis un numéro plus grand." }
}

# Vérifications
$problemes = @()
foreach ($f in Get-ChildItem -LiteralPath $racine -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\(\.git|_test|release|target[^\\]*)\\' }) {
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
    foreach ($e in $err) { $problemes += "Syntaxe : $($f.Name) ligne $($e.Extent.StartLineNumber) : $($e.Message)" }
}
try { [void][xml][IO.File]::ReadAllText((Join-Path $app 'fichiers\modules\interface.xaml'), [Text.Encoding]::UTF8) } catch { $problemes += "interface.xaml : $($_.Exception.Message)" }
$tirets = Get-ChildItem -LiteralPath $racine -Recurse -File -Include '*.ps1', '*.cs', '*.xaml', '*.txt', '*.md', '*.json' |
    Where-Object { $_.Extension -in '.ps1', '.cs', '.xaml', '.txt', '.md', '.json' -and $_.FullName -notmatch '\\(\.git|_test|release|target[^\\]*)\\' } |
    Select-String -Pattern '[\u2013\u2014]'
# (l'extension revérifiée : avec -LiteralPath, Windows PowerShell 5.1 ignore -Include pour les fichiers de la racine ;
# chez Nevermind, le zip de la publication d'avant annulait la suivante)
foreach ($t in $tirets) { $problemes += "Tiret cadratin : $($t.Path) ligne $($t.LineNumber)" }
if ($problemes) { $problemes | ForEach-Object { Write-Host $_ -ForegroundColor Red }; throw 'Publication annulée : corrige les points ci dessus.' }

# Un programme (git, gh) : seul son code de sortie compte. Ses avertissements (« LF will be replaced by CRLF »...) ne
# sont pas des échecs : sans « Continue », PowerShell les prenait pour des erreurs et arrêtait la publication.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE) { throw "Échec : $Exe $($Arguments -join ' ')" }
}

# Mindset en Rust : tout se passe ici, puis le script s'arrête (la suite est la publication de la version PowerShell)
if ($Rust) {
    $zipRust = Join-Path $racine 'release\Mindset-rust.zip'
    New-Item -ItemType Directory -Force -Path (Split-Path $zipRust -Parent) | Out-Null
    $titre = "Mindset $Version"
    # Les fichiers où outils\version-rust.ps1 écrit le numéro
    $siensRust = @('rust/mindset-appli/Cargo.toml', 'rust/Cargo.lock', 'Mindset/fichiers/Mindset.ps1')
    # 1. Tout est commité : la version publiée est celle de git (GitHub construit le commit, pas ce dossier). Une
    # publication arrêtée en route laisse seulement le numéro dans ces fichiers : remis comme dans git.
    if (-not $Essai) {
        $avant = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); $sale = @(& git -C $racine -c core.quotepath=false status --porcelain 2>$null | Where-Object { $_ }) }
        finally { [Console]::OutputEncoding = $avant }
        if ($sale.Count -and -not @($sale | Where-Object { $_ -notmatch '^(M |MM| M) ' -or $siensRust -notcontains $_.Substring(3).Trim('"') }).Count) {
            Invoke-Native 'git' (@('-C', $racine, 'reset', '-q', '--') + $siensRust) | Out-Null
            Invoke-Native 'git' (@('-C', $racine, 'checkout', '--') + $siensRust) | Out-Null
            Write-Host 'Le numéro de version laissé par une publication arrêtée en route est remis comme dans git.'
            $sale = @()
        }
        if ($sale.Count) { throw "Publication annulée : des fichiers ne sont pas commités ($(($sale | Select-Object -First 5) -join ' ; ')). Commite-les d'abord : la version publiée est celle de git." }

        # 2. Le numéro de version, commité tout de suite et envoyé : GitHub construit ce commit. Une tentative arrêtée plus
        # loin laisse ce commit ; la suivante avec le même numéro n'a rien de nouveau à commiter et reprend la même
        # construction.
        & (Join-Path $PSScriptRoot 'version-rust.ps1') -Version $Version
        if ((Get-VersionMindsetRust $racine) -cne $Version -or (Get-VersionMindsetPs $racine) -cne $Version) { throw 'Publication annulée : le numéro de version n''a pas pu être écrit partout.' }
        $chemins = @($siensRust | ForEach-Object { Join-Path $racine ($_ -replace '/', '\') })
        & git -C $racine diff --quiet -- @chemins
        if ($LASTEXITCODE) {
            Invoke-Native git (@('-C', $racine, 'add', '--') + $chemins) | Out-Null
            Invoke-Native git @('-C', $racine, 'commit', '-m', "Mindset $Version (Rust)", '-m', $(if ($Notes) { $Notes } else { "Version $Version" })) | Out-Null
        }
        Invoke-Native git @('-C', $racine, 'push', 'origin', 'HEAD') | Out-Null
    } elseif ((Get-VersionMindsetRust $racine) -cne $Version) {
        throw "Essai : -Version $Version, mais le Cargo.toml de mindset-appli dit $(Get-VersionMindsetRust $racine) (l'essai ne modifie rien : laisse -Version vide)."
    }

    # 3. Le zip construit et attesté par GitHub pour ce commit (ou, en essai seulement, un zip fait sur ce PC)
    if ($ZipLocal) {
        Write-Host "Essai : zip fait sur ce PC ($ZipLocal), sans attestation. Une vraie publication prend celui de GitHub." -ForegroundColor Yellow
        $source = (Resolve-Path -LiteralPath $ZipLocal).Path
    } else {
        $source = & (Join-Path $PSScriptRoot 'zip-rust-github.ps1') -Essai:$Essai -SansTest:$SansTest
        $source = @($source | Where-Object { $_ }) | Select-Object -Last 1
        if (-not $source) {
            if ($Essai) { Write-Host 'Essai arrêté : aucun zip construit par GitHub pour ce commit (ou passe -ZipLocal).' -ForegroundColor Yellow; return }
            throw 'Publication annulée : pas de zip construit par GitHub.'
        }
    }
    # (jamais l'ancien zip ni l'ancienne signature)
    Remove-Item -LiteralPath $zipRust, "$zipRust.sig" -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $source -Destination $zipRust

    # 4. Son contenu revérifié ici (fichiers exacts, version.json, fiches de version, pas de construction d'essai, aucun
    # runtime C à part), sans l'option -Ci : tout doit être à ce numéro, MindsetInstallateur.exe et le désinstalleur compris
    & (Join-Path $PSScriptRoot 'verifier-zip-rust.ps1') -Zip $zipRust -Version $Version
    if ($LASTEXITCODE) { throw 'Publication annulée : le zip de Mindset en Rust n''est pas conforme.' }

    # 5. La signature (en essai : une clé jetable, jamais la vraie)
    if ($Essai) {
        $cleEssai = New-Object Security.Cryptography.RSACryptoServiceProvider(3072); $cleEssai.PersistKeyInCsp = $false
        try { [IO.File]::WriteAllBytes("$zipRust.sig", $cleEssai.SignData([IO.File]::ReadAllBytes($zipRust), [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))) }
        finally { $cleEssai.Dispose() }
    } else { & (Join-Path $PSScriptRoot 'signer.ps1') -Fichier $zipRust }
    if (-not (Test-Path -LiteralPath "$zipRust.sig")) { throw 'Publication annulée : le zip n''a pas pu être signé.' }

    if (-not $Notes) { $Notes = "Mindset $Version" }
    if ($Essai) {
        Write-Host "Essai fini : $zipRust (Mindset $Version en Rust, signé avec une clé jetable). Rien n'est publié." -ForegroundColor Green
        Write-Host "Une vraie publication ferait : tag v$Version, envoi, puis gh release create v$Version Mindset.zip Mindset.zip.sig --title `"$titre`" --latest."
        return
    }

    # 6. Tag et Release, pour tout le monde (le numéro est déjà commité et envoyé, à l'étape 2). Les fichiers publiés
    # s'appellent Mindset.zip et Mindset.zip.sig : c'est ce nom que cherchent tous les Mindset (Get-Publication).
    $publie = Join-Path ([IO.Path]::GetTempPath()) "mindset-publier-$PID"
    if (Test-Path -LiteralPath $publie) { Remove-Item -LiteralPath $publie -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $publie | Out-Null
    Copy-Item -LiteralPath $zipRust -Destination (Join-Path $publie 'Mindset.zip')
    Copy-Item -LiteralPath "$zipRust.sig" -Destination (Join-Path $publie 'Mindset.zip.sig')
    Push-Location $racine
    try {
        Invoke-Native git @('tag', "v$Version")
        Invoke-Native git @('push', 'origin', "v$Version")
        Invoke-Native gh @('release', 'create', "v$Version", (Join-Path $publie 'Mindset.zip'), (Join-Path $publie 'Mindset.zip.sig'), '--title', $titre, '--notes', $Notes, '--latest')
    } finally { Pop-Location }
    "Mindset $Version (Rust) publié pour tout le monde."
    return
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
