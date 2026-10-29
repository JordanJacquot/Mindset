# Mindset : le changement de nom de Nevermind (ancien nom : OptiGame) essayé en vrai, sur la machine jetable de GitHub
# Actions (workflow .github\workflows\renommage-reel.yml, lancé à la main). Vraie installation dans Program Files par le
# vrai installer-admin.ps1 : JAMAIS sur un vrai PC, le script refuse de tourner hors de GitHub Actions.
#
#   1. Mindset NOUVEAU : la vraie version publiée de Nevermind (trouvée sous son nom d'aujourd'hui ou l'ancien) s'installe,
#      est reconnue, et vue ouverte quand elle tourne ; puis il la met à jour avec un zip renommé (Nevermind.zip, dossier
#      Nevermind, fichiers\Nevermind.ps1) : plus d'ancien script à côté, version lue.
#   2. Mindset 2.12.0 (VIEUX, sa vraie Release) : installe le dernier zip de compatibilité publié (le vrai OptiGame.zip
#      de Nevermind 1.15.4, Release figée : ensuite Nevermind ne publie plus que Nevermind.zip) et le reconnaît ;
#      Mindset NOUVEAU reconnaît cette installation et la met à jour avec la vraie version publiée (Nevermind.zip).
#      C'est le chemin d'un PC resté sur Mindset 2.12.0 : Mindset se met d'abord à jour, puis met Nevermind à jour.
# Le zip renommé de la partie 1 est fabriqué ici à partir du vrai zip publié, signé avec une clé RSA de TEST ajoutée aux
# clés publiques des copies d'essai seulement. Code de sortie 1 si un cas échoue.
param([string]$Reconnaitre, [string]$Dossier)

if ($env:GITHUB_ACTIONS -ne 'true') {
    Write-Host 'Refusé : cet essai installe Nevermind pour de vrai dans Program Files. Il ne tourne que sur la machine jetable de GitHub Actions.' -ForegroundColor Red
    exit 2
}
$ErrorActionPreference = 'Stop'

# Les fonctions de Mindset, lues dans ses fichiers
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($Fichier, [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
    foreach ($n in $Noms) {
        $x = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true)) | Select-Object -First 1
        if ($x) { . ([scriptblock]::Create($x.Extent.Text)); Set-Item -Path "function:script:$n" -Value (Get-Item "function:$n").ScriptBlock }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Lancé à part (un processus par version de Mindset, pour ne pas mélanger leur code) : ce que Mindset voit d'une
# installation de Nevermind avec SES fichiers (-Reconnaitre <fichiers>) : reconnue, version, ouverte
# ---------------------------------------------------------------------------------------------------------------------
if ($Reconnaitre) {
    function Write-Log { }
    $AppDir = $Reconnaitre
    . (Join-Path $Reconnaitre 'modules\applis.ps1')
    Import-Fonctions (Join-Path $Reconnaitre 'modules\installations.ps1') @('Get-ScriptAppli', 'Get-VersionDans', 'Test-DossierAppli')
    $n = $Applis | Where-Object Id -eq 'nevermind'
    function Get-Installation { @{ Dossier = $Dossier; Gere = $true; Version = '' } }
    $MonDossier = Join-Path $Reconnaitre '..'
    $ouverte = $false
    try { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $Reconnaitre 'modules\natif.cs'), [Text.Encoding]::UTF8)); $ouverte = [bool](Test-AppliOuverte $n) } catch { $ouverte = "erreur : $($_.Exception.Message)" }
    @{ Reconnue = [bool](Test-DossierAppli $Dossier $n); Version = [string](Get-VersionDans $Dossier $n); Ouverte = $ouverte } | ConvertTo-Json -Compress
    exit 0
}

$script:Reussis = 0
$script:Echoues = @()
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
    }
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }
function Write-Utf8([string]$Chemin, [string]$Texte) { New-Item -ItemType Directory -Force -Path (Split-Path $Chemin) | Out-Null; [IO.File]::WriteAllText($Chemin, $Texte, (New-Object Text.UTF8Encoding $true)) }

$Depot = Split-Path $PSScriptRoot -Parent
$Racine = 'C:\essai-renommage'
$PowerShellExe = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
$Dest = Join-Path $env:ProgramFiles 'Mindset\Nevermind'
$Neuf = Join-Path $Racine 'neuf\Mindset\fichiers'
$Vieux = Join-Path $Racine 'vieux\Mindset\fichiers'
$Paquets = Join-Path $Racine 'paquets'

# Ce que voit la version de Mindset dont voici les fichiers
function Get-Vue([string]$Fichiers, [string]$D = $Dest) {
    $sortie = & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Reconnaitre $Fichiers -Dossier $D
    $json = @($sortie) | Where-Object { $_ -like '{*' } | Select-Object -Last 1
    Write-Host "    vu par $(Split-Path (Split-Path (Split-Path $Fichiers)) -Leaf) : $json"
    $json | ConvertFrom-Json
}
# Le vrai installateur administrateur de cette version de Mindset (lancement direct : le runner est administrateur)
function Install-Nevermind([string]$Fichiers, [string]$Zip, [string]$DossierZip) {
    $res = Join-Path $Racine "resultat-$([guid]::NewGuid().ToString('N').Substring(0, 6)).json"
    # (l'appli de apps.json, exigée depuis l'audit du 25/10 comme Mindset la donne ; Mindset 2.12.0 ne connaît pas -Appli)
    $appli = if ($Fichiers -eq $Neuf) { @('-Appli', 'nevermind') } else { @() }
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Fichiers 'installer-admin.ps1') -Action appli @appli -Zip $Zip -Signature "$Zip.sig" -Destination $Dest -DossierZip $DossierZip -Exe 'Nevermind.exe' -Resultat $res | Out-Host
    $r = [IO.File]::ReadAllText($res, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Write-Host "    installateur ($DossierZip) : ok=$($r.ok) $($r.message)"
    $r
}
# (ses scripts principaux, sous le nom d'aujourd'hui ou l'ancien)
function Get-Scripts { @(Get-ChildItem -LiteralPath (Join-Path $Dest 'fichiers') -Filter *.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object Name | Where-Object { $_ -in 'Nevermind.ps1', 'OptiGame.ps1' } | Sort-Object) -join ',' }
function Remove-Nevermind {
    foreach ($p in @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and ([string]$_.ExecutablePath).StartsWith("$Dest\", [StringComparison]::OrdinalIgnoreCase) })) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
}

# =====================================================================================================================
Write-Partie '0. Préparation : clé de TEST, Mindset nouveau et Mindset 2.12.0, vrais zips de Nevermind, zip renommé'
# =====================================================================================================================
if (Test-Path -LiteralPath $Racine) { Remove-Item -LiteralPath $Racine -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Racine, $Paquets | Out-Null
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
try { $rsa.PersistKeyInCsp = $false; $Privee = $rsa.ToXmlString($true); $Publique = $rsa.ToXmlString($false) } finally { $rsa.Dispose() }
function New-Signature([string]$Zip) {
    $r = New-Object Security.Cryptography.RSACryptoServiceProvider
    try { $r.PersistKeyInCsp = $false; $r.FromXmlString($Privee); [IO.File]::WriteAllBytes("$Zip.sig", $r.SignData([IO.File]::ReadAllBytes($Zip), [Security.Cryptography.SHA256]::Create())) } finally { $r.Dispose() }
}
. (Join-Path $Depot 'Mindset\fichiers\modules\signature.ps1')
. (Join-Path $Depot 'Mindset\fichiers\modules\paquets.ps1')
function Write-Log([string]$T) { Write-Host "    (journal) $T" }

# Mindset nouveau : ce dépôt, clé de TEST ajoutée
New-Item -ItemType Directory -Force -Path (Split-Path $Neuf) | Out-Null
Copy-Item -LiteralPath (Join-Path $Depot 'Mindset\fichiers') -Destination (Split-Path $Neuf) -Recurse
# Depuis l'étape 2 du passage en Rust, installer-admin.ps1 n'est qu'un relais vers MindsetInstallateur.exe (construit
# par le workflow, donné par la variable MINDSET_INSTALLATEUR), posé à côté de Mindset.exe comme dans le vrai zip
if (-not $env:MINDSET_INSTALLATEUR -or -not (Test-Path -LiteralPath $env:MINDSET_INSTALLATEUR)) { throw 'MindsetInstallateur.exe absent : la variable MINDSET_INSTALLATEUR doit donner l''exe construit par le workflow.' }
Copy-Item -LiteralPath $env:MINDSET_INSTALLATEUR -Destination (Join-Path (Split-Path $Neuf) 'MindsetInstallateur.exe')
Write-Utf8 (Join-Path $Neuf 'cles-publiques\essai-test.xml') $Publique

# Mindset 2.12.0 : sa vraie Release (signée par la vraie clé), clé de TEST ajoutée
$rel = Join-Path $Racine 'release-mindset'
& gh release download v2.12.0 -R JordanJacquot/Mindset -p 'Mindset.zip*' -D $rel | Out-Host
Test-Cas 'Mindset 2.12.0 : vraie Release téléchargée, signée par la vraie clé' {
    Test-Signature ([IO.File]::ReadAllBytes("$rel\Mindset.zip")) ([IO.File]::ReadAllBytes("$rel\Mindset.zip.sig")) (Join-Path $Depot 'Mindset\fichiers\cles-publiques')
}
Expand-Archive -LiteralPath "$rel\Mindset.zip" -DestinationPath (Join-Path $Racine 'vieux') -Force
Write-Utf8 (Join-Path $Vieux 'cles-publiques\essai-test.xml') $Publique
Test-Cas 'Mindset 2.12.0 : il ne connaît Nevermind que sous OptiGame' {
    $a = ([IO.File]::ReadAllText((Join-Path $Vieux 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json) | Where-Object id -eq 'nevermind'
    (Select-String -LiteralPath (Join-Path $Vieux 'Mindset.ps1') -Pattern "^\`$AppVersion = '2\.12\.0'" -Quiet) -and $a.zip -eq 'OptiGame.zip' -and $a.script -eq 'fichiers\OptiGame.ps1'
}

# La vraie version publiée de Nevermind, trouvée par le NOUVEAU code (nom d'aujourd'hui, sinon l'ancien)
$pub = Get-Publication 'JordanJacquot/Nevermind' @('Nevermind.zip', 'OptiGame.zip')
Write-Host "    version publiée de Nevermind : $($pub.Version), fichier $($pub.Fichier)"
# (préfixe « vrai- » : depuis que Nevermind est publié sous Nevermind.zip, le zip fabriqué du même nom l'écrasait)
$vraiZip = Join-Path $Paquets "vrai-$($pub.Fichier)"
[IO.File]::WriteAllBytes($vraiZip, (Get-Octets $pub.UrlZip)); [IO.File]::WriteAllBytes("$vraiZip.sig", (Get-Octets $pub.UrlSig))
$VersionReelle = [string]$pub.Version
Test-Cas "Vraie version publiée de Nevermind ($($pub.Fichier) $VersionReelle) : Nevermind.zip, téléchargée, signature valide (vraie clé)" {
    -not $pub.Erreur -and $pub.Fichier -eq 'Nevermind.zip' -and (Test-Signature ([IO.File]::ReadAllBytes($vraiZip)) ([IO.File]::ReadAllBytes("$vraiZip.sig")) (Join-Path $Depot 'Mindset\fichiers\cles-publiques'))
}
$DossierReel = Get-DossierZip ([IO.File]::ReadAllBytes($vraiZip)) @('Nevermind', 'OptiGame') 'Nevermind.exe'
Write-Host "    dossier du vrai zip : $DossierReel"

# Le dernier zip de compatibilité publié (OptiGame.zip de Nevermind 1.15.4, Release figée), téléchargé tel quel
$CompatVersion = '1.15.4'
$compat = Join-Path $Racine 'release-compat'
& gh release download "v$CompatVersion" -R JordanJacquot/Nevermind -p 'OptiGame.zip*' -D $compat | Out-Host
$ZipCompat = Join-Path $compat 'OptiGame.zip'
Test-Cas "Zip de compatibilité (OptiGame.zip $CompatVersion) : téléchargé, signature valide pour Mindset 2.12.0 (vraie clé), dossier OptiGame" {
    (Test-Signature ([IO.File]::ReadAllBytes($ZipCompat)) ([IO.File]::ReadAllBytes("$ZipCompat.sig")) (Join-Path $Vieux 'cles-publiques')) -and
    (Get-DossierZip ([IO.File]::ReadAllBytes($ZipCompat)) @('Nevermind', 'OptiGame') 'Nevermind.exe') -ceq 'OptiGame'
}

# Le zip renommé fabriqué à partir du vrai (dossier Nevermind, version 9.0.0)
$x = Join-Path $Racine 'extrait'
Expand-Archive -LiteralPath $vraiZip -DestinationPath $x -Force
$base = Join-Path $x $DossierReel
$scriptReel = @(Get-ChildItem -LiteralPath (Join-Path $base 'fichiers') -Filter *.ps1 -File | Where-Object { Select-String -LiteralPath $_.FullName -Pattern "^\`$AppVersion\s*=" -Quiet }) | Select-Object -First 1
function New-ZipFabrique([string]$Nom, [string]$DossierZip, [string[]]$Scripts, [string]$Version) {
    $d = Join-Path $Racine "fabrique\$Nom"
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item -LiteralPath $base -Destination (Join-Path $d $DossierZip) -Recurse
    $f = Join-Path $d "$DossierZip\fichiers"
    $texte = [IO.File]::ReadAllText($scriptReel.FullName, [Text.Encoding]::UTF8) -replace "(?m)^\`$AppVersion\s*=\s*'[\d.]+'", "`$AppVersion = '$Version'"
    Remove-Item -LiteralPath (Join-Path $f $scriptReel.Name) -Force
    foreach ($s in $Scripts) { [IO.File]::WriteAllText((Join-Path $f $s), $texte, (New-Object Text.UTF8Encoding $true)) }
    $zip = Join-Path $Paquets $Nom
    Compress-Archive -Path (Join-Path $d $DossierZip) -DestinationPath $zip -Force
    New-Signature $zip
    $zip
}
$ZipRenomme = New-ZipFabrique 'Nevermind.zip' 'Nevermind' @('Nevermind.ps1') '9.0.0'
Test-Cas 'Zip fabriqué : son dossier Nevermind trouvé par le nouveau code' {
    (Get-DossierZip ([IO.File]::ReadAllBytes($ZipRenomme)) @('Nevermind', 'OptiGame') 'Nevermind.exe') -ceq 'Nevermind'
}

# =====================================================================================================================
Write-Partie '1. Mindset NOUVEAU : la vraie version publiée, puis la mise à jour vers la version renommée'
# =====================================================================================================================
Remove-Nevermind
$r = Install-Nevermind $Neuf $vraiZip $DossierReel
$v = Get-Vue $Neuf
Test-Cas "Vrai Nevermind $VersionReelle installé dans Program Files et reconnu par le nouveau Mindset" { $r.ok -and $v.Reconnue -and $v.Version -eq $VersionReelle -and -not $v.Ouverte }

# Ouvert : le vrai Nevermind lancé ; il tient son mutex (l'ancien, Local\OptiGame-Instance, pour une version d'avant le
# changement de nom). S'il ne démarre pas sur cette machine, un programme d'essai tient l'ancien mutex à sa place.
$mutexAncien = 'Local\OptiGame-Instance'; $mutexNeuf = 'Local\Nevermind-Instance'
function Test-Mutex([string]$Nom) { try { $m = [Threading.Mutex]::OpenExisting($Nom); $m.Dispose(); $true } catch { $_.Exception.InnerException -is [UnauthorizedAccessException] -or $_.Exception -is [UnauthorizedAccessException] } }
$lance = Start-Process -FilePath (Join-Path $Dest 'Nevermind.exe') -WorkingDirectory $Dest -PassThru
$limite = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $limite -and -not (Test-Mutex $mutexAncien) -and -not (Test-Mutex $mutexNeuf)) { Start-Sleep -Milliseconds 500 }
$tenant = $null
if (Test-Mutex $mutexAncien) { Write-Host "    le vrai Nevermind $VersionReelle tourne (mutex $mutexAncien)" }
elseif (Test-Mutex $mutexNeuf) { Write-Host "    le vrai Nevermind $VersionReelle tourne (mutex $mutexNeuf)" }
else {
    Write-Host "    le vrai Nevermind n'a pas pris de mutex en 90 s : un programme d'essai tient $mutexAncien à sa place"
    $tenant = Start-Process -FilePath $PowerShellExe -ArgumentList '-NoProfile', '-Command', "`$m = New-Object Threading.Mutex(`$true, '$mutexAncien'); Start-Sleep 600" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
}
$v = Get-Vue $Neuf
Test-Cas 'Ouvert : vu ouvert par le nouveau Mindset (son ancien mutex compte)' { $v.Ouverte -eq $true }
if ($tenant) { Stop-Process -Id $tenant.Id -Force -ErrorAction SilentlyContinue }

# Mise à jour par le nouveau Mindset avec le zip renommé, l'appli encore ouverte (l'installateur la ferme)
$dz = Get-DossierZip ([IO.File]::ReadAllBytes($ZipRenomme)) @('Nevermind', 'OptiGame') 'Nevermind.exe'
$r = Install-Nevermind $Neuf $ZipRenomme $dz
$v = Get-Vue $Neuf
Test-Cas 'Mise à jour vers la version renommée : installée, fichiers\Nevermind.ps1 seul (plus d''OptiGame.ps1), version 9.0.0' { $r.ok -and (Get-Scripts) -eq 'Nevermind.ps1' -and $v.Reconnue -and $v.Version -eq '9.0.0' }
Test-Cas 'Le vrai Nevermind ouvert a été fermé par l''installateur (plus aucun programme de son dossier)' { -not @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and ([string]$_.ExecutablePath).StartsWith($Dest, [StringComparison]::OrdinalIgnoreCase) }).Count }   # (ni de son dossier mis de côté)
$v = Get-Vue $Vieux
Test-Cas 'Contre-épreuve : Mindset 2.12.0 ne reconnaît pas cette installation renommée (il doit d''abord se mettre à jour)' { -not $v.Reconnue }

# =====================================================================================================================
Write-Partie "2. Mindset 2.12.0 (VIEUX) et le dernier zip de compatibilité (OptiGame.zip $CompatVersion)"
# =====================================================================================================================
# Première installation par le vieux Mindset, avec le vrai zip de compatibilité
Remove-Nevermind
$r = Install-Nevermind $Vieux $ZipCompat 'OptiGame'
$v = Get-Vue $Vieux
Test-Cas "Zip de compatibilité $CompatVersion : installé par Mindset 2.12.0 (fichiers\OptiGame.ps1 seul) et reconnu, version $CompatVersion" { $r.ok -and (Get-Scripts) -eq 'OptiGame.ps1' -and $v.Reconnue -and $v.Version -eq $CompatVersion }
# Le nouveau Mindset (celui vers lequel 2.12.0 se met à jour) reconnaît cette installation, puis la met à jour
$v = Get-Vue $Neuf
Test-Cas "Le nouveau Mindset reconnaît l'installation faite par 2.12.0, version $CompatVersion" { $v.Reconnue -and $v.Version -eq $CompatVersion }
$r = Install-Nevermind $Neuf $vraiZip $DossierReel
$v = Get-Vue $Neuf
Test-Cas "Puis il la met à jour avec la vraie version publiée ($($pub.Fichier) $VersionReelle) : fichiers\Nevermind.ps1 seul, version $VersionReelle" { $r.ok -and (Get-Scripts) -eq 'Nevermind.ps1' -and $v.Reconnue -and $v.Version -eq $VersionReelle }
Remove-Nevermind

Write-Host ''
if ($script:Echoues.Count) { Write-Host "$($script:Echoues.Count) échec(s), $script:Reussis réussi(s)." -ForegroundColor Red; exit 1 }
Write-Host "Tout est bon ($script:Reussis cas)." -ForegroundColor Green
