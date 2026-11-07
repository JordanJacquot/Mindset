# Mindset en Rust : le zip 3.0 est-il accepté par l'installateur des Mindset d'avant, ceux qui l'installeront eux-mêmes ?
#
#   & '.\outils\tester-zip-anciens.ps1' -Zip <Mindset.zip en Rust>
#
# Jusqu'à 2.14 (avant le relais vers MindsetInstallateur.exe), une mise à jour de Mindset est installée par le code
# PowerShell de la version installée : Install-Paquet de SES modules (paquets.ps1, signature.ps1), avec -DossierZip
# Mindset -Exe Mindset.exe (installer-admin.ps1, action mindset-maj). Ce test reprend ces fonctions telles qu'elles sont
# dans git, à chaque version publiée qui les a (tags v*), et leur fait installer le zip donné, signé ici par une clé de
# TEST jetable (jamais la vraie), par-dessus une fausse installation de la version d'avant, dans un dossier d'essai sous
# %TEMP%. Rien d'autre n'est touché : ni registre, ni tâche, ni Program Files, ni réseau, rien n'est lancé.
#   - attendu : chaque version (0.3.0 à 2.18.0) installe le zip, et le dossier installé est exactement celui du zip ;
#   - contre-épreuve : le même zip SANS fichiers\version.ps1 est refusé par les versions 2.11 à 2.14 (« ne dit pas
#     quelle version » ; avant 2.11, la version du zip n'était pas contrôlée) : c'est la preuve que ce fichier est
#     nécessaire (outils\contenu-rust.ps1).
# Les versions 2.15 et après installent Mindset par MindsetInstallateur.exe (Rust) : jugé par cargo test
# (cas\installateur\rust-mindset.json) et, en vrai, par outils\tester-maj-rust.ps1 sur GitHub.
# Code de sortie 1 si un cas échoue. Il faut l'historique git complet (tags compris).
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$Zip = (Resolve-Path -LiteralPath $Zip).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) "mindset-zip-anciens-$PID"
$script:Echecs = @(); $script:Reussis = 0
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) { $script:Reussis++; Write-Host "  OK     $Nom" -ForegroundColor Green }
    else { $script:Echecs += $Nom; Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red }
}
function Get-TexteGit([string]$Ref, [string]$Chemin) {
    $avant = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); $t = @(& git -C $racine show "$($Ref):$Chemin" 2>$null); if ($LASTEXITCODE) { return $null }; $t -join "`n" }
    finally { [Console]::OutputEncoding = $avant }
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$tmp\cles", "$tmp\zips" | Out-Null
try {
    # La clé de TEST, et les deux zips signés avec elle : celui donné, et le même sans fichiers\version.ps1
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072); $rsa.PersistKeyInCsp = $false
    [IO.File]::WriteAllText("$tmp\cles\test.xml", $rsa.ToXmlString($false))
    $avec = "$tmp\zips\avec.zip"; Copy-Item -LiteralPath $Zip -Destination $avec
    $sans = "$tmp\zips\sans.zip"; Copy-Item -LiteralPath $Zip -Destination $sans
    $a = [IO.Compression.ZipFile]::Open($sans, 'Update')
    try { @($a.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq 'Mindset/fichiers/version.ps1' }) | ForEach-Object { $_.Delete() } } finally { $a.Dispose() }
    $sig = @{}
    foreach ($z in $avec, $sans) { $sig[$z] = $rsa.SignData([IO.File]::ReadAllBytes($z), [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')) }
    $rsa.Dispose()
    # Ce que le zip contient (pour comparer avec le dossier installé)
    $a = [IO.Compression.ZipFile]::OpenRead($avec)
    try { $contenu = @($a.Entries | ForEach-Object { $_.FullName.Replace('/', '\') } | Where-Object { $_.StartsWith('Mindset\') -and -not $_.EndsWith('\') } | ForEach-Object { $_.Substring(8) } | Sort-Object) } finally { $a.Dispose() }
    $versionZip = ''
    $a = [IO.Compression.ZipFile]::OpenRead($avec)
    # (Compress-Archive de Windows PowerShell 5.1 écrit les noms avec « \ »)
    try { $e = @($a.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq 'Mindset/version.json' })[0]; $s = New-Object IO.StreamReader($e.Open()); $versionZip = ($s.ReadToEnd() | ConvertFrom-Json).version; $s.Dispose() } finally { $a.Dispose() }
    Write-Host "Zip : $Zip (Mindset $versionZip, $($contenu.Count) fichiers)" -ForegroundColor Cyan

    $tags = @(& git -C $racine tag --list 'v*' | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Substring(1) })
    $vues = 0
    foreach ($tag in $tags) {
        $v = $tag.Substring(1)
        $paquets = Get-TexteGit $tag 'Mindset/fichiers/modules/paquets.ps1'
        $signature = Get-TexteGit $tag 'Mindset/fichiers/modules/signature.ps1'
        if (-not $paquets -or -not $signature -or $paquets -notmatch 'function Install-Paquet') { continue }
        $vues++
        # Chaque version dans son propre bloc : ses fonctions à elle, rien d'une autre version
        $essai = {
            param($Paquets, $Signature, $Version, $ZipOctets, $SigOctets, $Cles, $Dossier)
            $ErrorActionPreference = 'Stop'
            foreach ($t in $Signature, $Paquets) {
                $err = $null
                $ast = [Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$err)
                foreach ($f in @($ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))) { . ([scriptblock]::Create($f.Extent.Text)) }
            }
            # L'installation d'avant : Mindset $Version (son $AppVersion), comme chez l'utilisateur
            $dest = Join-Path $Dossier 'Mindset'
            New-Item -ItemType Directory -Force -Path "$dest\fichiers" | Out-Null
            [IO.File]::WriteAllText("$dest\fichiers\Mindset.ps1", "`$AppVersion = '$Version'`r`n", (New-Object Text.UTF8Encoding($true)))
            [IO.File]::WriteAllText("$dest\Mindset.exe", 'ancien')
            try { $r = Install-Paquet -Zip $ZipOctets -Signature $SigOctets -ClePublique $Cles -Destination $dest -DossierZip 'Mindset' -Exe 'Mindset.exe'; @{ Ok = $true; Dossier = [string]@($r)[-1] } }
            catch { @{ Ok = $false; Message = $_.Exception.Message } }
        }
        foreach ($cas in @(@{ Zip = $avec; Nom = 'avec' }, @{ Zip = $sans; Nom = 'sans' })) {
            $d = Join-Path $tmp "$v-$($cas.Nom)"
            # (la clé : le dossier depuis 2.0 ; un seul fichier avant, comme leur Mindset.ps1)
            $cles = if ($signature -match 'Get-ChildItem[^\r\n]*\$ClePublique') { "$tmp\cles" } else { "$tmp\cles\test.xml" }
            $r = & $essai $paquets $signature $v ([IO.File]::ReadAllBytes($cas.Zip)) $sig[$cas.Zip] $cles $d
            if ($cas.Nom -eq 'avec') {
                Test-Cas "Mindset $v installe le zip $versionZip (dossier installé = contenu du zip, sans Mindset.ps1)" {
                    if (-not $r.Ok) { throw $r.Message }
                    $inst = Join-Path $d 'Mindset'
                    $vus = @(Get-ChildItem -LiteralPath $inst -Recurse -File | ForEach-Object { $_.FullName.Substring($inst.Length + 1) } | Sort-Object)
                    if (($vus -join '|') -ne ($contenu -join '|')) { throw "installé : $($vus -join ', ')" }
                    $true
                }
            } elseif ([version]$v -lt [version]'2.15.0' -and $paquets -match 'ne dit pas quelle version') {
                # (de 2.11 à 2.14 : un zip sans version est refusé ; avant 2.11, il était accepté sans contrôle)
                Test-Cas "contre-épreuve : Mindset $v refuse le zip sans fichiers\version.ps1 (« ne dit pas quelle version »)" { -not $r.Ok -and $r.Message -match 'ne dit pas quelle version' }
            } else {
                $pourquoi = if ([version]$v -ge [version]'2.15.0') { "pour Mindset lui-même, c'est MindsetInstallateur.exe qui installe depuis 2.15" } else { 'cette version ne contrôlait pas encore la version du zip' }
                Write-Host "  (Mindset $v sans fichiers\version.ps1 : $(if ($r.Ok) { 'accepté' } else { "refusé, $($r.Message)" }) ; $pourquoi)" -ForegroundColor DarkGray
            }
        }
    }
    Test-Cas "toutes les versions publiées avec Install-Paquet sont essayées ($vues)" { $vues -ge 50 }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($script:Echecs.Count) { Write-Host "Zip 3.0 et installateurs d'avant : $($script:Echecs.Count) cas raté(s) sur $($script:Reussis + $script:Echecs.Count)." -ForegroundColor Red; exit 1 }
Write-Host "Zip 3.0 et installateurs d'avant : $($script:Reussis) cas sur $($script:Reussis), tout accepté." -ForegroundColor Green
exit 0
