# Mindset en Rust : vérifie le zip à publier (Mindset.zip), sans rien lancer. Utilisé par la construction GitHub
# (.github\workflows\release.yml, job « Mindset en Rust »), par outils\zip-rust.ps1 et par outils\publier.ps1 -Rust,
# juste avant la signature.
#
#   & '.\outils\verifier-zip-rust.ps1' -Zip <Mindset.zip> [-Version 3.0.0] [-Ci]
#
# Le zip doit être exactement ce que décrit outils\contenu-rust.ps1 :
#   - exactement un dossier « Mindset » et dedans exactement Mindset.exe, MindsetInstallateur.exe, Desinstaller
#     Mindset.exe, version.json, LISEZMOI.txt, fichiers\ (apps.json, apps-liste.txt, Mindset.ico, installer-admin.ps1,
#     version.ps1, et les clés publiques du dépôt) : ni Mindset.ps1, ni modules, ni DLL, ni fichier en plus, ni
#     version.json à la racine du zip ;
#   - version.json en UTF-8 sans marque : appli « mindset », version celle du Cargo.toml de mindset-appli (ou -Version,
#     qui doit alors être la même) ;
#   - fichiers\version.ps1 exactement celui de contenu-rust.ps1 pour cette version (la ligne $AppVersion que lisent les
#     Mindset 2.14 et avant, et que l'installateur de 2.15 à 2.18 compare à version.json) ;
#   - les fichiers copiés et les clés identiques à ceux du dépôt (celui du dossier, ou celui de git : la copie de Jordan
#     peut avoir des fins de ligne CRLF que git n'a pas) ;
#   - fiches de version : Mindset.exe et MindsetInstallateur.exe décrivent « Mindset », le désinstalleur « Désinstaller
#     Mindset » ; produit « Mindset » pour les trois ; tous à la version de version.json ;
#   - aucun exe ne connaît la construction d'essai (outils\verifier-sans-essai.ps1) ;
#   - aucun runtime C à installer à part (outils\verifier-imports.ps1, lu dans la table des imports).
# -Ci (tests de GitHub entre deux publications seulement) : MindsetInstallateur.exe et le désinstalleur peuvent avoir la
# version de Mindset.ps1 quand outils\version-rust.ps1 ne l'a pas encore alignée (seulement signalé). Jamais pour une
# publication.
# Code de sortie 0 si tout va bien, 1 sinon (avec la liste des problèmes).
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [string]$Version = '',
    [switch]$Ci
)
$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'contenu-rust.ps1')
$attendus = @(Get-FichiersMindsetRust $racine | ForEach-Object { "Mindset\$_" })
$problemes = New-Object Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { Write-Host "Zip introuvable : $Zip"; exit 1 }
$Zip = (Resolve-Path -LiteralPath $Zip).Path

$cargo = Get-VersionMindsetRust $racine
if (-not $Version) { $Version = $cargo }
elseif ($Version -cne $cargo) { $problemes.Add("La version demandée ($Version) n'est pas celle du Cargo.toml de mindset-appli ($cargo).") }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$tmp = Join-Path ([IO.Path]::GetTempPath()) "mindset-zip-rust-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # Les entrées du zip (avec « \ » ou « / », comme l'installateur les lit)
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $noms = @($archive.Entries | ForEach-Object { $_.FullName.Replace('/', '\') })
        $fichiers = @($noms | Where-Object { -not $_.EndsWith('\') } | Sort-Object)
        $enTrop = @($fichiers | Where-Object { $attendus -cnotcontains $_ })
        $absents = @($attendus | Where-Object { $fichiers -cnotcontains $_ })
        if ($enTrop.Count) { $problemes.Add("Fichiers en trop dans le zip : $($enTrop -join ', ')") }
        if ($absents.Count) { $problemes.Add("Fichiers absents du zip : $($absents -join ', ')") }
        if (@($noms | Where-Object { -not $_.StartsWith('Mindset\', [StringComparison]::Ordinal) }).Count) { $problemes.Add('Le zip a autre chose que le dossier Mindset.') }
        foreach ($e in $archive.Entries) {
            $n = $e.FullName.Replace('/', '\')
            if ($attendus -cnotcontains $n) { continue }
            $dest = Join-Path $tmp $n
            New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
        }
    } finally { $archive.Dispose() }
    $d = Join-Path $tmp 'Mindset'

    # version.json
    $vj = Join-Path $d $MindsetRust.VersionJson
    if (Test-Path -LiteralPath $vj) {
        $o = [IO.File]::ReadAllBytes($vj)
        if ($o.Length -ge 3 -and $o[0] -eq 0xEF -and $o[1] -eq 0xBB -and $o[2] -eq 0xBF) { $problemes.Add('version.json a une marque UTF-8 (BOM).') }
        $j = $null
        try { $j = [Text.Encoding]::UTF8.GetString($o).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $problemes.Add("version.json illisible : $($_.Exception.Message)") }
        if ($j) {
            Write-Host "version.json : appli $($j.appli), version $($j.version)"
            if ($j.appli -cne 'mindset') { $problemes.Add("version.json : appli « $($j.appli) » au lieu de « mindset »") }
            if ($j.version -cne $Version) { $problemes.Add("version.json : version $($j.version) au lieu de $Version") }
        }
    }
    # fichiers\version.ps1 : exactement celui de cette version
    $vp = Join-Path $d $MindsetRust.VersionPs1
    if (Test-Path -LiteralPath $vp) {
        $attendu = @((New-Object Text.UTF8Encoding($true)).GetPreamble()) + @([Text.Encoding]::UTF8.GetBytes((Get-TexteVersionPs1 $Version)))
        $lu = [IO.File]::ReadAllBytes($vp)
        if (($lu -join ',') -ne ($attendu -join ',')) { $problemes.Add("fichiers\version.ps1 n'est pas celui de la version $Version (outils\contenu-rust.ps1)") }
    }

    # Les fichiers copiés et les clés : les mêmes que ceux du dépôt, octet pour octet. Le zip de GitHub a les fins de
    # ligne de git, un zip fait sur ce PC celles du dossier (git pour Windows peut y écrire des CRLF) : l'un ou l'autre
    # convient (leçon de Mindcare 0.91.0, refusé à tort le 04/11).
    $copies = [ordered]@{}
    foreach ($rel in $MindsetRust.Copies.Keys) { $copies[$rel] = $MindsetRust.Copies[$rel] }
    foreach ($c in @(Get-ChildItem -LiteralPath (Join-Path $racine $MindsetRust.Cles) -Filter '*.xml' -File)) { $copies["fichiers\cles-publiques\$($c.Name)"] = "$($MindsetRust.Cles)\$($c.Name)" }
    foreach ($rel in $copies.Keys) {
        $f = Join-Path $d $rel
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $source = $copies[$rel]
        $commeDossier = (Get-FileHash -LiteralPath (Join-Path $racine $source)).Hash -eq (Get-FileHash -LiteralPath $f).Hash
        $avantGit = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $dansGit = ((& git -C $racine rev-parse "HEAD:$($source.Replace('\', '/'))" 2>$null) -join '').Trim()
            $duZip = ((& git -C $racine hash-object --no-filters -- $f 2>$null) -join '').Trim()
        } finally { $ErrorActionPreference = $avantGit }
        $commeGit = $dansGit -match '^[0-9a-f]{40}$' -and $dansGit -eq $duZip
        if (-not ($commeDossier -or $commeGit)) { $problemes.Add("$rel du zip différent de $source (ni celui du dossier, ni celui de git)") }
    }

    # Les fiches de version des programmes, et la construction d'essai
    $v4 = ConvertTo-Version4 $Version
    $versionPs = Get-VersionMindsetPs $racine
    foreach ($nom in $MindsetRust.Programmes.Keys) {
        $f = Join-Path $d $nom
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $attendu = $MindsetRust.Programmes[$nom]
        $i = (Get-Item -LiteralPath $f).VersionInfo
        Write-Host "$nom : description « $($i.FileDescription) », produit « $($i.ProductName) », version $($i.ProductVersion), SHA-256 $((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash)"
        if ($i.FileDescription -cne $attendu.Description) { $problemes.Add("$nom : description « $($i.FileDescription) » au lieu de « $($attendu.Description) »") }
        if ($i.ProductName -cne $attendu.Produit) { $problemes.Add("$nom : produit « $($i.ProductName) » au lieu de « $($attendu.Produit) »") }
        $lue = ConvertTo-Version4 ([string]$i.ProductVersion)
        if ($lue -ne $v4) {
            if ($Ci -and $attendu.Bin -ne 'Mindset' -and $versionPs -and $lue -eq (ConvertTo-Version4 $versionPs)) {
                Write-Host "  (tests de GitHub : $nom a la version de Mindset.ps1, $versionPs ; outils\publier.ps1 -Rust l'aligne sur $Version)" -ForegroundColor Yellow
            } else { $problemes.Add("$nom : version $($i.ProductVersion) au lieu de $Version") }
        }
        & (Join-Path $PSScriptRoot 'verifier-sans-essai.ps1') -Exe $f | Out-Host
        if ($LASTEXITCODE) { $problemes.Add("$nom contient la construction d'essai") }
    }

    # Aucun runtime C à installer à part (lu dans la table des imports, sans rien lancer)
    $exes = @($MindsetRust.Programmes.Keys | ForEach-Object { Join-Path $d $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($exes.Count) {
        & (Join-Path $PSScriptRoot 'verifier-imports.ps1') -Fichiers $exes -Liste | Out-Host
        if ($LASTEXITCODE) { $problemes.Add('un programme du zip a besoin d''un runtime C à installer à part') }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($problemes.Count) {
    $problemes | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "Zip refusé : $Zip ($($problemes.Count) problème(s))." -ForegroundColor Red
    exit 1
}
Write-Host "Zip conforme : $Zip (Mindset $Version en Rust, SHA-256 $((Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash))." -ForegroundColor Green
exit 0
