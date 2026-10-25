# Mindset : tests du changement de nom de Nevermind (OptiGame est son ancien nom).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-renommage.ps1
#   (-Fichiers <dossier fichiers d'une autre version de Mindset> : contre-épreuve, les mêmes cas sur l'ancien code)
#
# Mindset accepte les nouveaux noms (Nevermind.zip, dossier Nevermind, fichiers\Nevermind.ps1, Local\Nevermind-Instance)
# et garde les anciens (OptiGame) pour les installations et les versions publiées d'avant :
#   - apps.json : les noms d'aujourd'hui, et les anciens dans les champs ancien_* (vérifiés comme les autres) ;
#   - version publiée : Nevermind.zip d'abord, sinon OptiGame.zip ;
#   - zip téléchargé : son dossier Nevermind ou OptiGame, celui qui contient le programme ;
#   - installation reconnue (et sa version lue) avec fichiers\Nevermind.ps1 ou fichiers\OptiGame.ps1 ;
#   - ouverte : son mutex d'aujourd'hui ou l'ancien ;
#   - une installation OptiGame mise à jour par un zip Nevermind : plus d'ancien script à côté du nouveau ;
#   - une ancienne copie OptiGame prise en charge : entièrement retirée (son ancien script compris).
# Rien sur le vrai PC : un dossier de test sous %TEMP%, des mutex au nom de test, aucun réseau.
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).
param([string]$Fichiers)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
if (-not $Fichiers) { $Fichiers = Join-Path $racine 'Mindset\fichiers' }
$modules = Join-Path $Fichiers 'modules'

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

# Les fonctions de Mindset, lues dans ses fichiers (une absente : le cas qui s'en sert échoue)
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $modules $Fichier), [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
    foreach ($n in $Noms) {
        $x = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true)) | Select-Object -First 1
        if ($x) { . ([scriptblock]::Create($x.Extent.Text)); Set-Item -Path "function:script:$n" -Value (Get-Item "function:$n").ScriptBlock }
    }
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function New-Zip([hashtable]$Entrees) {
    $ms = New-Object IO.MemoryStream
    $za = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($k in $Entrees.Keys) {
            $flux = $za.CreateEntry($k).Open()
            try { $o = [Text.Encoding]::UTF8.GetBytes([string]$Entrees[$k]); $flux.Write($o, 0, $o.Length) } finally { $flux.Dispose() }
        }
    } finally { $za.Dispose() }
    , $ms.ToArray()
}
function Save-Fichier([string]$Chemin, [string]$Texte) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Chemin -Parent) | Out-Null
    [IO.File]::WriteAllText($Chemin, $Texte, (New-Object Text.UTF8Encoding $true))
}
# Une installation d'essai de Nevermind : Nevermind.exe et son script principal sous le nom donné, en version $Version
function New-Installation([string]$Dossier, [string[]]$Scripts, [string[]]$Versions) {
    Save-Fichier (Join-Path $Dossier 'Nevermind.exe') 'programme'
    for ($i = 0; $i -lt $Scripts.Count; $i++) { Save-Fichier (Join-Path $Dossier $Scripts[$i]) "`$AppVersion = '$($Versions[$i])'`r`n" }
}

$tmp = Join-Path $env:TEMP "mindset-renommage-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName   # (en nom long : sur GitHub, TEMP est en nom court)
$tenus = New-Object Collections.ArrayList

try {
    $script:Journal = New-Object Collections.ArrayList
    function Write-Log([string]$T) { [void]$script:Journal.Add($T) }

    # -----------------------------------------------------------------------------------------------------------------
    Write-Partie 'apps.json : les noms d''aujourd''hui, et les anciens pour la compatibilité'
    # -----------------------------------------------------------------------------------------------------------------
    $AppDir = $Fichiers
    . (Join-Path $modules 'applis.ps1')
    $nevermind = $Applis | Where-Object Id -eq 'nevermind'
    Test-Cas 'Nevermind : Nevermind.zip, dossier Nevermind, fichiers\Nevermind.ps1, Local\Nevermind-Instance' {
        $nevermind.Zip -ceq 'Nevermind.zip' -and $nevermind.DossierZip -ceq 'Nevermind' -and $nevermind.Script -ceq 'fichiers\Nevermind.ps1' -and $nevermind.Mutex -ceq 'Local\Nevermind-Instance'
    }
    Test-Cas 'Ses anciens noms gardés : OptiGame.zip, dossier OptiGame, fichiers\OptiGame.ps1, Local\OptiGame-Instance' {
        $nevermind.AncienZip -ceq 'OptiGame.zip' -and $nevermind.AncienDossierZip -ceq 'OptiGame' -and $nevermind.AncienScript -ceq 'fichiers\OptiGame.ps1' -and $nevermind.AncienMutex -ceq 'Local\OptiGame-Instance'
    }
    Test-Cas 'Les autres applis n''ont pas d''ancien nom' { -not @($Applis | Where-Object { $_.Id -ne 'nevermind' -and ($_.AncienZip -or $_.AncienDossierZip -or $_.AncienScript -or $_.AncienMutex) }).Count }
    Test-Cas 'OptiGame n''apparaît dans apps.json que dans les champs de compatibilité (anciens noms, ancien dossier de données)' {
        $j = [IO.File]::ReadAllText((Join-Path $Fichiers 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        $restes = foreach ($a in $j) { foreach ($p in $a.PSObject.Properties) { if ([string]$p.Value -match 'OptiGame' -and $p.Name -notlike 'ancien_*' -and $p.Name -ne 'donnees') { $p.Name } } }
        -not @($restes).Count
    }
    # Un ancien nom mal formé : l'appli est ignorée, comme pour les autres champs
    $faux = Join-Path $tmp 'faux-apps'
    $j = [IO.File]::ReadAllText((Join-Path $Fichiers 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $bon = ($j | Where-Object id -eq 'nevermind')
    foreach ($cas in @(@{ Champ = 'ancien_script'; Valeur = '..\..\piege.ps1' }, @{ Champ = 'ancien_dossier_zip'; Valeur = 'a\b' }, @{ Champ = 'ancien_zip'; Valeur = 'c:\x.zip' }, @{ Champ = 'ancien_mutex'; Valeur = 'Global\x y' })) {
        $copie = $bon | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $copie | Add-Member -NotePropertyName $cas.Champ -NotePropertyValue $cas.Valeur -Force
        Save-Fichier (Join-Path $faux 'apps.json') (ConvertTo-Json @($copie) -Depth 4)
        Test-Cas "Un $($cas.Champ) mal formé ($($cas.Valeur)) : l'appli est ignorée" { $AppDir = $faux; -not @(Get-Applis).Count }
    }

    # -----------------------------------------------------------------------------------------------------------------
    Write-Partie 'Version publiée : Nevermind.zip d''abord, sinon OptiGame.zip (sans réseau)'
    # -----------------------------------------------------------------------------------------------------------------
    Import-Fonctions 'paquets.ps1' @('Get-Publication', 'Get-DossierZip', 'Install-Paquet', 'Move-DossierEssais', 'Get-VersionDossier', 'Test-VersionPlusRecente')
    . (Join-Path $modules 'signature.ps1')
    $script:Release = $null
    function Invoke-RestMethod { $script:Release }
    function Get-PublicationSansApi { $null }
    function New-Release([string[]]$Noms) {
        [pscustomobject]@{ tag_name = 'v1.12.0'; body = 'notes'; assets = @(foreach ($n in $Noms) { [pscustomobject]@{ name = $n; browser_download_url = "https://github.com/JordanJacquot/Nevermind/releases/download/v1.12.0/$n" } }) }
    }
    $noms = @($nevermind.Zip, $nevermind.AncienZip)
    $script:Release = New-Release 'Nevermind.zip', 'Nevermind.zip.sig', 'OptiGame.zip', 'OptiGame.zip.sig'
    Test-Cas 'Les deux zips publiés : Nevermind.zip (et sa signature) est pris' {
        $p = Get-Publication 'JordanJacquot/Nevermind' $noms
        $p.UrlZip -like '*/Nevermind.zip' -and $p.UrlSig -like '*/Nevermind.zip.sig' -and $p.Version -eq '1.12.0'
    }
    $script:Release = New-Release 'OptiGame.zip', 'OptiGame.zip.sig'
    Test-Cas 'Une version publiée avant le changement de nom (OptiGame.zip seulement) : OptiGame.zip et sa signature' {
        $p = Get-Publication 'JordanJacquot/Nevermind' $noms
        -not $p.Erreur -and $p.UrlZip -like '*/OptiGame.zip' -and $p.UrlSig -like '*/OptiGame.zip.sig'
    }
    $script:Release = New-Release 'Nevermind.zip', 'OptiGame.zip', 'OptiGame.zip.sig'
    Test-Cas 'Nevermind.zip sans signature : pas de mélange avec la signature de l''autre zip' {
        $p = Get-Publication 'JordanJacquot/Nevermind' $noms
        $p.UrlZip -like '*/Nevermind.zip' -and -not $p.UrlSig
    }
    $script:Release = New-Release 'Autre.zip'
    Test-Cas 'Aucun des deux : le message parle de Nevermind.zip' { (Get-Publication 'JordanJacquot/Nevermind' $noms).Erreur -like '*Nevermind.zip*' }
    $script:Release = New-Release 'Mindset.zip', 'Mindset.zip.sig'
    Test-Cas 'Un seul nom (Mindset.zip) : rien ne change' { (Get-Publication 'JordanJacquot/Mindset' 'Mindset.zip').UrlZip -like '*/Mindset.zip' }

    # -----------------------------------------------------------------------------------------------------------------
    Write-Partie 'Zip téléchargé : son dossier Nevermind ou OptiGame'
    # -----------------------------------------------------------------------------------------------------------------
    $dossiers = @($nevermind.DossierZip, $nevermind.AncienDossierZip)
    $zipNeuf = New-Zip @{ 'Nevermind/Nevermind.exe' = 'programme'; 'Nevermind/fichiers/Nevermind.ps1' = "`$AppVersion = '1.12.0'"; 'Nevermind/lisez-moi.txt' = 'x' }
    $zipAncien = New-Zip @{ 'OptiGame/Nevermind.exe' = 'programme'; 'OptiGame/fichiers/OptiGame.ps1' = "`$AppVersion = '1.11.0'" }
    Test-Cas 'Zip neuf : dossier Nevermind' { (Get-DossierZip $zipNeuf $dossiers 'Nevermind.exe') -ceq 'Nevermind' }
    Test-Cas 'Zip d''avant le changement de nom : dossier OptiGame' { (Get-DossierZip $zipAncien $dossiers 'Nevermind.exe') -ceq 'OptiGame' }
    Test-Cas 'Zip illisible : le nom d''aujourd''hui (l''installation dira ce qui manque)' { (Get-DossierZip ([Text.Encoding]::UTF8.GetBytes('pas un zip')) $dossiers 'Nevermind.exe') -ceq 'Nevermind' }

    # -----------------------------------------------------------------------------------------------------------------
    Write-Partie 'Installation reconnue sous les deux noms de script, version lue'
    # -----------------------------------------------------------------------------------------------------------------
    Import-Fonctions 'installations.ps1' @('Get-ScriptAppli', 'Get-VersionDans', 'Test-DossierAppli', 'Remove-AncienneCopie', 'Test-DossierSur', 'Test-DossierTravail', 'Complete-Telechargement')
    $dAncien = Join-Path $tmp 'inst\ancien'; New-Installation $dAncien @('fichiers\OptiGame.ps1') @('1.11.0')
    $dNeuf = Join-Path $tmp 'inst\neuf'; New-Installation $dNeuf @('fichiers\Nevermind.ps1') @('1.12.0')
    $dDeux = Join-Path $tmp 'inst\deux'; New-Installation $dDeux @('fichiers\OptiGame.ps1', 'fichiers\Nevermind.ps1') @('1.11.0', '1.12.0')
    $dRien = Join-Path $tmp 'inst\rien'; New-Installation $dRien @() @()
    Test-Cas 'Installation d''avant (fichiers\OptiGame.ps1) : reconnue, version 1.11.0' { (Test-DossierAppli $dAncien $nevermind) -and (Get-VersionDans $dAncien $nevermind) -eq '1.11.0' }
    Test-Cas 'Installation renommée (fichiers\Nevermind.ps1) : reconnue, version 1.12.0' { (Test-DossierAppli $dNeuf $nevermind) -and (Get-VersionDans $dNeuf $nevermind) -eq '1.12.0' }
    Test-Cas 'Les deux scripts : c''est fichiers\Nevermind.ps1 qui dit la version' { (Get-VersionDans $dDeux $nevermind) -eq '1.12.0' }
    Test-Cas 'Ni l''un ni l''autre : pas une installation de Nevermind' { -not (Test-DossierAppli $dRien $nevermind) }

    # -----------------------------------------------------------------------------------------------------------------
    Write-Partie 'Ouverte : son mutex d''aujourd''hui ou l''ancien (mutex au nom de test)'
    # -----------------------------------------------------------------------------------------------------------------
    function Get-Installation { $null }   # (aucun programme cherché par son chemin ici)
    $essai = [pscustomobject]@{ Id = 'nevermind'; Nom = 'Nevermind'; Exe = 'Nevermind.exe'; Mutex = "Local\MindsetTest-$([guid]::NewGuid().ToString('N'))"; AncienMutex = "Local\MindsetTest-$([guid]::NewGuid().ToString('N'))" }
    Test-Cas 'Aucun des deux mutex : fermée' { -not (Test-AppliOuverte $essai) }
    $m = New-Object Threading.Mutex($true, $essai.AncienMutex); [void]$tenus.Add($m)
    Test-Cas 'Une version d''avant ouverte (ancien mutex) : vue ouverte' { Test-AppliOuverte $essai }
    $m.ReleaseMutex(); $m.Dispose(); $tenus.Remove($m)
    $m = New-Object Threading.Mutex($true, $essai.Mutex); [void]$tenus.Add($m)
    Test-Cas 'La version renommée ouverte (nouveau mutex) : vue ouverte' { Test-AppliOuverte $essai }
    $m.ReleaseMutex(); $m.Dispose(); $tenus.Remove($m)
    Test-Cas 'Les deux relâchés : de nouveau fermée' { -not (Test-AppliOuverte $essai) }

    # -----------------------------------------------------------------------------------------------------------------
    Write-Partie 'Mise à jour d''une installation OptiGame par le zip Nevermind (vraie Install-Paquet, clé de test)'
    # -----------------------------------------------------------------------------------------------------------------
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
    try { $rsa.PersistKeyInCsp = $false; $privee = $rsa.ToXmlString($true); $fCle = Join-Path $tmp 'cle-test.xml'; Save-Fichier $fCle $rsa.ToXmlString($false) } finally { $rsa.Dispose() }
    function Get-Sig([byte[]]$Octets) {
        $r = New-Object Security.Cryptography.RSACryptoServiceProvider
        try { $r.PersistKeyInCsp = $false; $r.FromXmlString($privee); , $r.SignData($Octets, [Security.Cryptography.SHA256]::Create()) } finally { $r.Dispose() }
    }
    $dest = Join-Path $tmp 'Programmes\Nevermind'
    New-Installation $dest @('fichiers\OptiGame.ps1') @('1.11.0')
    $installe = try { Install-Paquet -Zip $zipNeuf -Signature (Get-Sig $zipNeuf) -ClePublique $fCle -Destination $dest -DossierZip (Get-DossierZip $zipNeuf $dossiers 'Nevermind.exe') -Exe 'Nevermind.exe' } catch { Write-Host "    ($($_.Exception.Message))"; $null }
    Test-Cas 'Installée : fichiers\Nevermind.ps1 en 1.12.0, et plus de fichiers\OptiGame.ps1 à côté' {
        $installe -ieq $dest -and (Test-Path -LiteralPath (Join-Path $dest 'fichiers\Nevermind.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $dest 'fichiers\OptiGame.ps1')) -and (Get-VersionDans $dest $nevermind) -eq '1.12.0'
    }
    Test-Cas 'Un seul script principal dans fichiers' { @(Get-ChildItem -LiteralPath (Join-Path $dest 'fichiers') -Filter *.ps1).Count -eq 1 }
    # Et un zip d'avant (OptiGame) installé là où rien n'est encore : il s'installe aussi
    $dest2 = Join-Path $tmp 'Programmes\Nevermind2'
    try { $null = Install-Paquet -Zip $zipAncien -Signature (Get-Sig $zipAncien) -ClePublique $fCle -Destination $dest2 -DossierZip (Get-DossierZip $zipAncien $dossiers 'Nevermind.exe') -Exe 'Nevermind.exe' } catch { Write-Host "    ($($_.Exception.Message))" }
    Test-Cas 'Un zip d''avant (dossier OptiGame) s''installe aussi, et l''installation est reconnue' { (Test-DossierAppli $dest2 $nevermind) -and (Get-VersionDans $dest2 $nevermind) -eq '1.11.0' }

    # -----------------------------------------------------------------------------------------------------------------
    Write-Partie 'Téléchargement : le dossier du zip passé à l''installateur'
    # -----------------------------------------------------------------------------------------------------------------
    $script:Occupe = @{}; $script:Progres = @{}; $script:EnCours = @{}
    function Get-DossierGere($Appli) { Join-Path $tmp "Programmes\$($Appli.Nom)" }
    function Get-DemarrageAppli { $true }
    function Test-AppliOuverte { $false }
    function Send-InstallationAppli { }
    function Stop-Operation($Appli, [string]$Message) { $script:Arret = $Message }
    $fz = Join-Path $tmp 'nevermind.zip'; [IO.File]::WriteAllBytes($fz, $zipAncien)
    Complete-Telechargement $nevermind @{ Version = '1.11.0'; Zip = $fz; Sig = "$fz.sig"; DossierZip = 'OptiGame' } $null ''
    Test-Cas 'Zip d''avant : l''installateur reçoit le dossier OptiGame' { [string]$script:EnCours['nevermind'].Parametres.DossierZip -ceq 'OptiGame' }
    $script:EnCours = @{}
    Complete-Telechargement $nevermind @{ Version = '1.12.0'; Zip = $fz; Sig = "$fz.sig"; DossierZip = 'Nevermind' } $null ''
    Test-Cas 'Zip neuf : l''installateur reçoit le dossier Nevermind' { [string]$script:EnCours['nevermind'].Parametres.DossierZip -ceq 'Nevermind' }

    # -----------------------------------------------------------------------------------------------------------------
    Write-Partie 'Prise en charge d''une ancienne copie OptiGame : entièrement retirée'
    # -----------------------------------------------------------------------------------------------------------------
    $RacineProgrammes = Join-Path $tmp 'Programmes'
    $copie = Join-Path $tmp 'Telechargements\OptiGame'
    New-Installation $copie @('fichiers\OptiGame.ps1') @('1.11.0')
    Save-Fichier (Join-Path $copie 'lisez-moi.txt') 'x'
    $fzn = Join-Path $tmp 'neuf.zip'; [IO.File]::WriteAllBytes($fzn, $zipNeuf)
    $msg = Remove-AncienneCopie $nevermind $copie $fzn 'Nevermind'
    Test-Cas 'L''ancienne copie (fichiers\OptiGame.ps1) est supprimée, rien n''en reste' { -not (Test-Path -LiteralPath $copie) -and $msg -like '*a été supprimée*' }
} finally {
    foreach ($m in @($tenus)) { try { $m.ReleaseMutex() } catch {}; try { $m.Dispose() } catch {} }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Echoues.Count) {
    Write-Host "$($script:Echoues.Count) échec(s), $script:Reussis réussi(s)." -ForegroundColor Red
    exit 1
}
Write-Host "Tout est bon ($script:Reussis cas)." -ForegroundColor Green
