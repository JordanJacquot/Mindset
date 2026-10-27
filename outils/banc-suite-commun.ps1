# Mindset : banc d'essai de la bibliothèque Rust « suite-commun » (passage en Rust, étape 0).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\banc-suite-commun.ps1 -Banc <banc-essai.exe>
#
# Les MÊMES fichiers (données, signatures, listes de clés, zips bons et piégés) sont passés :
#   - à la version PowerShell d'aujourd'hui (Test-Signature et Install-Paquet, chargés depuis Mindset\fichiers\modules) ;
#   - à la version Rust (rust\banc-essai, construit par « cargo build »).
# Les deux doivent répondre pareil dans 100 % des cas : même réponse (acceptée ou refusée), même message, et pour une
# installation, exactement les mêmes fichiers sur le disque après coup. Code de sortie 1 au moindre écart.
#
# Facultatif : -ZipReel et -SigReel (un vrai zip publié et sa signature) ajoutent un cas « bon » vérifié avec les vraies
# clés publiques de Mindset (la CI de GitHub télécharge la dernière version publiée de Mindset).
#
# Tout se passe dans un dossier temporaire sous %TEMP%, supprimé à la fin. Les clés de signature sont des clés de TEST
# créées à la volée : la vraie clé privée n'est jamais utilisée. Aucun droit administrateur, aucun réseau.

param(
    [Parameter(Mandatory = $true)][string]$Banc,
    [string]$ZipReel = '',
    [string]$SigReel = ''
)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)

. (Join-Path $fichiers 'modules\signature.ps1')
. (Join-Path $fichiers 'modules\paquets.ps1')

if (-not (Test-Path -LiteralPath $Banc -PathType Leaf)) { throw "Banc d'essai Rust introuvable : $Banc (lancer d'abord « cargo build » dans rust\)" }
$Banc = (Resolve-Path -LiteralPath $Banc).Path

$tmp = Join-Path $env:TEMP "banc-suite-commun-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = [IO.Path]::GetFullPath($tmp)
$utf8 = New-Object Text.UTF8Encoding $false

# ---------------------------------------------------------------------------------------------------------------
# Outils : clés de test, signatures, zips
# ---------------------------------------------------------------------------------------------------------------
function New-CleTest([int]$Taille) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider $Taille
    try { $rsa.PersistKeyInCsp = $false; @{ Privee = $rsa.ToXmlString($true); Publique = $rsa.ToXmlString($false); Parametres = $rsa.ExportParameters($false) } }
    finally { $rsa.Dispose() }
}
function Get-SignatureTest([byte[]]$Donnees, [string]$XmlPrivee, [string]$Hachage = 'SHA256') {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($XmlPrivee); , $rsa.SignData($Donnees, [System.Security.Cryptography.CryptoConfig]::MapNameToOID($Hachage)) }
    finally { $rsa.Dispose() }
}
# Un dossier de clés : $Contenu = [ordered]@{ 'nom.xml' = 'XML' (texte) ou des octets }
function New-Liste([string]$Nom, $Contenu) {
    $d = Join-Path $tmp "cles\$Nom"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    foreach ($k in $Contenu.Keys) {
        $v = $Contenu[$k]
        if ($v -is [byte[]]) { [IO.File]::WriteAllBytes((Join-Path $d $k), $v) } else { [IO.File]::WriteAllText((Join-Path $d $k), [string]$v, $utf8) }
    }
    $d
}
function New-FichierCle([string]$Nom, $Contenu) {
    $d = Join-Path $tmp 'cles'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $f = Join-Path $d $Nom
    if ($Contenu -is [byte[]]) { [IO.File]::WriteAllBytes($f, $Contenu) } else { [IO.File]::WriteAllText($f, [string]$Contenu, $utf8) }
    $f
}
# Un zip construit par .NET : $Entrees = [ordered]@{ 'nom/dans/le/zip' = 'contenu' (texte UTF-8) ou des octets }
function New-ZipTest($Entrees) {
    $ms = New-Object IO.MemoryStream
    $za = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($k in $Entrees.Keys) {
            $flux = $za.CreateEntry($k).Open()
            try {
                $v = $Entrees[$k]
                if ($v -is [byte[]]) { $o = $v } else { $o = [Text.Encoding]::UTF8.GetBytes([string]$v) }
                if ($o.Length) { $flux.Write($o, 0, $o.Length) }
            } finally { $flux.Dispose() }
        }
    } finally { $za.Dispose() }
    , $ms.ToArray()
}
function New-ZipAppli([string]$Version, $EnPlus = $null, [switch]$SansExe) {
    $e = [ordered]@{}
    if (-not $SansExe) { $e['Appli/Appli.exe'] = "programme $Version" }
    $e['Appli/fichiers/Appli.ps1'] = "# Appli de test`r`n`$AppVersion = '$Version'`r`n"
    $e['Appli/fichiers/modules/outil.ps1'] = '# module'
    if ($EnPlus) { foreach ($k in $EnPlus.Keys) { $e[$k] = $EnPlus[$k] } }
    New-ZipTest $e
}

# CRC-32 (pour les zips écrits à la main)
Add-Type -TypeDefinition @'
public static class Crc32Banc {
    public static uint Calculer(byte[] octets) {
        uint c = 0xFFFFFFFF;
        foreach (byte o in octets) {
            c ^= o;
            for (int k = 0; k < 8; k++) { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1; }
        }
        return c ^ 0xFFFFFFFF;
    }
}
'@
function Get-Crc32([byte[]]$Octets) { [Crc32Banc]::Calculer($Octets) }
# Un zip « stocké » (sans compression) écrit octet par octet, pour les cas que .NET ne sait pas fabriquer.
# Chaque entrée : @{ Nom = octets du nom ; Donnees = octets ; Drapeaux = 0 ; Extra = octets ; NomLocal = octets ;
# Crc = valeur forcée ; Methode = 0 }
function New-ZipBrut($Entrees) {
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $centraux = @()
    foreach ($e in $Entrees) {
        $nom = [byte[]]$e.Nom
        $nomLocal = if ($e.NomLocal) { [byte[]]$e.NomLocal } else { $nom }
        $donnees = [byte[]]$e.Donnees
        [byte[]]$extra = New-Object byte[] 0
        if ($e.Extra) { $extra = [byte[]]$e.Extra }
        $drap = [uint16]$(if ($e.Drapeaux) { $e.Drapeaux } else { 0 })
        $methode = [uint16]$(if ($e.Methode) { $e.Methode } else { 0 })
        [uint32]$crc = if ($null -ne $e.Crc) { $e.Crc } else { Get-Crc32 $donnees }
        $pos = [uint32]$ms.Position
        $bw.Write([uint32]0x04034b50); $bw.Write([uint16]20); $bw.Write([uint16]$drap); $bw.Write([uint16]$methode)
        $bw.Write([uint16]0); $bw.Write([uint16]0x21); $bw.Write([uint32]$crc); $bw.Write([uint32]$donnees.Length); $bw.Write([uint32]$donnees.Length)
        $bw.Write([uint16]$nomLocal.Length); $bw.Write([uint16]$extra.Length); $bw.Write([byte[]]$nomLocal); $bw.Write([byte[]]$extra); $bw.Write([byte[]]$donnees)
        $centraux += @{ Nom = $nom; Extra = $extra; Drap = $drap; Methode = $methode; Crc = $crc; Taille = $donnees.Length; Pos = $pos }
    }
    $debut = [uint32]$ms.Position
    foreach ($c in $centraux) {
        $bw.Write([uint32]0x02014b50); $bw.Write([uint16]20); $bw.Write([uint16]20); $bw.Write([uint16]$c.Drap); $bw.Write([uint16]$c.Methode)
        $bw.Write([uint16]0); $bw.Write([uint16]0x21); $bw.Write([uint32]$c.Crc); $bw.Write([uint32]$c.Taille); $bw.Write([uint32]$c.Taille)
        $bw.Write([uint16]$c.Nom.Length); $bw.Write([uint16]$c.Extra.Length); $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint16]0)
        $bw.Write([uint32]0); $bw.Write([uint32]$c.Pos); $bw.Write([byte[]]$c.Nom); $bw.Write([byte[]]$c.Extra)
    }
    $fin = [uint32]$ms.Position
    $bw.Write([uint32]0x06054b50); $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint16]$centraux.Count); $bw.Write([uint16]$centraux.Count)
    $bw.Write([uint32]($fin - $debut)); $bw.Write([uint32]$debut); $bw.Write([uint16]0)
    $bw.Flush()
    , $ms.ToArray()
}
function Get-Octets8([string]$Texte) { , [Text.Encoding]::UTF8.GetBytes($Texte) }
# Change la taille annoncée (non compressée) d'une entrée d'un zip, et son CRC si -Crc est donné, dans l'en-tête local et
# dans le répertoire central
function Set-TailleAnnoncee([byte[]]$Zip, [string]$Nom, [uint32]$Taille, [long]$Crc = -1) {
    $z = [byte[]]$Zip.Clone()
    $nomOctets = [Text.Encoding]::UTF8.GetBytes($Nom)
    $octetsTaille = [BitConverter]::GetBytes($Taille)
    # (en-tête local PK 0x04034b50 : taille à +22, longueur du nom à +26, nom à +30 ;
    #  répertoire central PK 0x02014b50 : taille à +24, longueur du nom à +28, nom à +46)
    foreach ($t in @(@{ Sig = 0x04034b50; Taille = 22; Longueur = 26; Nom = 30 }, @{ Sig = 0x02014b50; Taille = 24; Longueur = 28; Nom = 46 })) {
        for ($i = 0; $i -le $z.Length - $t.Nom; $i++) {
            if ([BitConverter]::ToUInt32($z, $i) -ne $t.Sig) { continue }
            $l = [BitConverter]::ToUInt16($z, $i + $t.Longueur)
            if ($l -ne $nomOctets.Length -or $i + $t.Nom + $l -gt $z.Length -or [Text.Encoding]::UTF8.GetString($z, $i + $t.Nom, $l) -cne $Nom) { continue }
            [Array]::Copy($octetsTaille, 0, $z, $i + $t.Taille, 4)
            # (le CRC est 8 octets avant la taille non compressée)
            if ($Crc -ge 0) { [Array]::Copy([BitConverter]::GetBytes([uint32]$Crc), 0, $z, $i + $t.Taille - 8, 4) }
        }
    }
    , $z
}
# Les entrées de base d'une appli de test, pour New-ZipBrut
function Get-EntreesBrutes([string]$Version) {
    @(
        @{ Nom = (Get-Octets8 'Appli/Appli.exe'); Donnees = (Get-Octets8 "programme $Version") },
        @{ Nom = (Get-Octets8 'Appli/fichiers/Appli.ps1'); Donnees = (Get-Octets8 "`$AppVersion = '$Version'`r`n") }
    )
}

# ---------------------------------------------------------------------------------------------------------------
# Les cas
# ---------------------------------------------------------------------------------------------------------------
$script:CasSignature = New-Object System.Collections.ArrayList
$script:CasInstall = New-Object System.Collections.ArrayList
$script:Numero = 0

# Un cas de signature : les données et la signature sont écrites dans des fichiers, relus par les deux versions
function Add-CasSignature([string]$Nom, [byte[]]$Donnees, [byte[]]$Signature, [string]$Cles) {
    $script:Numero++
    $d = Join-Path $tmp "signature\$($script:Numero)"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $fd = Join-Path $d 'donnees'; $fs = Join-Path $d 'sig'
    if ($null -eq $Donnees) { $Donnees = New-Object byte[] 0 }
    if ($null -eq $Signature) { $Signature = New-Object byte[] 0 }
    [IO.File]::WriteAllBytes($fd, $Donnees)
    [IO.File]::WriteAllBytes($fs, $Signature)
    $ps = [bool](Test-Signature ([IO.File]::ReadAllBytes($fd)) ([IO.File]::ReadAllBytes($fs)) $Cles)
    [void]$script:CasSignature.Add([pscustomobject]@{ id = "$($script:Numero)"; nom = $Nom; donnees = $fd; signature = $fs; cles = $Cles; ps = $ps })
}

# Ce que veut dire un message de Install-Paquet (pour comparer avec la catégorie rendue par Rust)
function Get-Categorie([string]$Message) {
    if ($Message -like 'La signature du fichier*') { 'signature' }
    elseif ($Message -like 'Chemin refusé dans le zip :*') { 'chemin' }
    elseif ($Message -like 'Le zip ne contient pas *') { 'exe' }
    elseif ($Message -like '*ne dit pas quelle version*') { 'version-illisible' }
    elseif ($Message -like 'Version * refusée : la version *, plus récente, est déjà installée.') { 'version-installee' }
    elseif ($Message -like 'Version * refusée : la version *, plus récente, a déjà été installée sur ce PC.') { 'version-minimale' }
    elseif ($Message -ceq 'Le zip est abîmé : rien n''a été installé.') { 'zip-abime' }
    elseif ($Message -ceq 'Le zip contient un fichier chiffré : rien n''a été installé.') { 'zip-chiffre' }
    elseif ($Message -like '*fichiers bloqués*' -or $Message -like '*encore ouverte*' -or $Message -like 'Des fichiers de Mindset étaient encore utilisés*') { 'bloque' }
    else { 'autre' }
}

# Une appli déjà installée (l'état de départ), écrite de la même façon des deux côtés
function Set-AppliInstallee([string]$Dossier, [string]$Version, $EnPlus = $null) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dossier 'fichiers') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Dossier 'Appli.exe'), "programme $Version", $utf8)
    [IO.File]::WriteAllText((Join-Path $Dossier 'fichiers\Appli.ps1'), "`$AppVersion = '$Version'`r`n", $utf8)
    if ($EnPlus) { foreach ($k in $EnPlus.Keys) { $f = Join-Path $Dossier $k; New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null; [IO.File]::WriteAllText($f, $EnPlus[$k], $utf8) } }
}

# Un cas d'installation. Chaque version a son propre dossier, préparé à l'identique : <cas>\ps et <cas>\rs.
#   -Avant { param($Base, $Dest) ... } : l'état de départ (une version déjà installée, des restes...)
#   -Verrou 'Appli.exe' : ce fichier de l'appli installée reste ouvert pendant l'installation (appli encore ouverte)
# La destination est rangée profondément (<base>\a\b\Programmes\Appli) : un zip-slip qui remonte de quelques dossiers
# reste dans <base> et se voit dans la comparaison des fichiers.
$script:Verrous = New-Object System.Collections.ArrayList
function Add-CasInstall([string]$Nom, [byte[]]$Zip, [byte[]]$Signature = $null, [string]$Cles = '', [scriptblock]$Avant = $null,
    [string]$DossierZip = 'Appli', [string]$Exe = 'Appli.exe', [string]$VersionMinimale = '', [string]$Verrou = '', [string]$FinDest = '') {
    $script:Numero++
    if (-not $Cles) { $Cles = $script:ListeTest }
    if ($null -eq $Signature) { $Signature = Get-SignatureTest $Zip $script:Cle.Privee }
    $d = Join-Path $tmp "installation\$($script:Numero)"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $fz = Join-Path $d 'paquet.zip'; $fs = Join-Path $d 'paquet.zip.sig'
    [IO.File]::WriteAllBytes($fz, $Zip); [IO.File]::WriteAllBytes($fs, $Signature)
    $cotes = @{}
    foreach ($cote in 'ps', 'rs') {
        $base = Join-Path $d $cote
        $dest = Join-Path $base 'a\b\Programmes\Appli'
        New-Item -ItemType Directory -Force -Path $base | Out-Null
        if ($Avant) { & $Avant $base $dest }
        if ($Verrou) { [void]$script:Verrous.Add([IO.File]::Open((Join-Path $dest $Verrou), 'Open', 'Read', 'Read')) }
        $cotes[$cote] = @{ Base = $base; Dest = "$dest$FinDest" }
    }
    # La version PowerShell, tout de suite
    $r = @{ ok = $false; categorie = ''; message = ''; retour = '' }
    try {
        $ret = Install-Paquet -Zip ([IO.File]::ReadAllBytes($fz)) -Signature ([IO.File]::ReadAllBytes($fs)) -ClePublique $Cles -Destination $cotes.ps.Dest -DossierZip $DossierZip -Exe $Exe -VersionMinimale $VersionMinimale
        $r.ok = $true; $r.retour = [string]$ret
    } catch { $r.message = $_.Exception.Message; $r.categorie = Get-Categorie $r.message }
    [void]$script:CasInstall.Add([pscustomobject]@{
            id = "$($script:Numero)"; nom = $Nom; zip = $fz; signature = $fs; cles = $Cles; destination = $cotes.rs.Dest
            dossier_zip = $DossierZip; exe = $Exe; version_minimale = $VersionMinimale
            basePs = $cotes.ps.Base; baseRs = $cotes.rs.Base; ps = $r
        })
}

$script:Sha = [Security.Cryptography.SHA256]::Create()
# Les fichiers d'un dossier, avec leur empreinte (les suffixes au hasard des dossiers temporaires sont effacés)
function Get-Arbre([string]$Base) {
    @(Get-ChildItem -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($Base.Length) -replace '\.(nouveau|ancien)-[0-9a-f]{8}', '.$1-*'
            if ($_.PSIsContainer) { "$rel\" }
            # (un fichier au nom réservé, « CON », n'est pas relu : Windows pourrait ouvrir la console)
            elseif ($_.BaseName -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)$') { "$rel=nom réservé" }
            else { "$rel=$(try { [BitConverter]::ToString($script:Sha.ComputeHash([IO.File]::ReadAllBytes($_.FullName))) } catch { 'illisible' })" }
        } | Sort-Object) -join "`n"
}

$code = 0
try {
    Write-Host 'Banc d''essai suite-commun : PowerShell et Rust sur les mêmes fichiers' -ForegroundColor Cyan
    Write-Host "Dossier de test : $tmp"

    # ===========================================================================================================
    # Clés de test
    # ===========================================================================================================
    $script:Cle = New-CleTest 3072
    $cle = $script:Cle
    $cleB = New-CleTest 3072
    $autreCle = New-CleTest 3072
    $cleCourte = New-CleTest 2048
    $cle4096 = New-CleTest 4096
    $script:ListeTest = New-Liste 'test' ([ordered]@{ 'a.xml' = $cle.Publique })
    $fPublique = New-FichierCle 'publique.xml' $cle.Publique
    $m = [Convert]::ToBase64String($cle.Parametres.Modulus)
    $ex = [Convert]::ToBase64String($cle.Parametres.Exponent)
    $mB = [Convert]::ToBase64String($cleB.Parametres.Modulus)

    # ===========================================================================================================
    # Signatures
    # ===========================================================================================================
    $donnees = [Text.Encoding]::UTF8.GetBytes('Le contenu d''un zip à publier')
    $autres = [Text.Encoding]::UTF8.GetBytes('Un autre fichier')
    $sig = Get-SignatureTest $donnees $cle.Privee
    $sigB = Get-SignatureTest $donnees $cleB.Privee
    $sig4096 = Get-SignatureTest $donnees $cle4096.Privee
    $modifie = [byte[]]$donnees.Clone(); $modifie[5] = $modifie[5] -bxor 1
    $sigModifiee = [byte[]]$sig.Clone(); $sigModifiee[10] = $sigModifiee[10] -bxor 1
    $listeAB = New-Liste 'AB' ([ordered]@{ 'a.xml' = $cle.Publique; 'b.xml' = $cleB.Publique })
    $listeA = New-Liste 'A' ([ordered]@{ 'a.xml' = $cle.Publique })
    $listeA4096 = New-Liste 'A-4096' ([ordered]@{ 'a.xml' = $cle.Publique; 'secours.xml' = $cle4096.Publique })
    $livrees = Join-Path $fichiers 'cles-publiques'

    # Les cas de tester-securite.ps1
    Add-CasSignature 'signature valide' $donnees $sig $fPublique
    Add-CasSignature 'signature d''un autre fichier' $autres $sig $fPublique
    Add-CasSignature 'fichier modifié d''un octet' $modifie $sig $fPublique
    Add-CasSignature 'signature modifiée d''un octet' $donnees $sigModifiee $fPublique
    Add-CasSignature 'signature d''une autre clé' $donnees $sig (New-FichierCle 'autre.xml' $autreCle.Publique)
    Add-CasSignature 'clé trop courte (2048 bits), signature juste' $donnees (Get-SignatureTest $donnees $cleCourte.Privee) (New-FichierCle 'courte.xml' $cleCourte.Publique)
    Add-CasSignature 'clé privée à la place de la publique' $donnees $sig (New-FichierCle 'privee.xml' $cle.Privee)
    Add-CasSignature 'fichier de clé absent' $donnees $sig (Join-Path $tmp 'cles\absente.xml')
    Add-CasSignature 'fichier de clé illisible' $donnees $sig (New-FichierCle 'illisible.xml' '<RSAKeyValue><Modulus>pas une clé</Modulus>')
    Add-CasSignature 'signature vide' $donnees ([byte[]]@()) $fPublique
    Add-CasSignature 'données vides' ([byte[]]@()) $sig $fPublique
    Add-CasSignature 'chemin des clés vide' $donnees $sig ''
    Add-CasSignature 'liste AB, signée B' $donnees $sigB $listeAB
    Add-CasSignature 'liste AB, signée A' $donnees $sig $listeAB
    Add-CasSignature 'liste A, signée B (retirée)' $donnees $sigB $listeA
    Add-CasSignature 'liste vide' $donnees $sig (New-Liste 'vide' ([ordered]@{}))
    Add-CasSignature 'dossier de clés absent' $donnees $sig (Join-Path $tmp 'cles\absent')
    Add-CasSignature 'clé abîmée dans la liste' $donnees $sig (New-Liste 'abimee' ([ordered]@{ 'a.xml' = $cle.Publique; 'b.xml' = '<RSAKeyValue><Modulus>pas une clé</Modulus>' }))
    Add-CasSignature 'fichier de clé vide dans la liste' $donnees $sig (New-Liste 'fichier-vide' ([ordered]@{ 'a.xml' = $cle.Publique; 'b.xml' = '' }))
    Add-CasSignature 'clé privée glissée dans la liste' $donnees $sig (New-Liste 'privee' ([ordered]@{ 'a.xml' = $cle.Publique; 'z.xml' = $cleB.Privee }))
    Add-CasSignature 'clé privée seule, sa signature' $donnees $sigB (New-Liste 'privee-seule' ([ordered]@{ 'b.xml' = $cleB.Privee }))
    $lc = New-Liste 'courte' ([ordered]@{ 'a.xml' = $cle.Publique; 'c.xml' = $cleCourte.Publique })
    Add-CasSignature 'clé courte glissée dans la liste, signée A' $donnees $sig $lc
    Add-CasSignature 'clé courte glissée dans la liste, signée par elle' $donnees (Get-SignatureTest $donnees $cleCourte.Privee) $lc
    $lh = New-Liste 'cachee' ([ordered]@{ 'a.xml' = $cle.Publique; 'cachee.xml' = $cleB.Privee })
    (Get-Item -LiteralPath (Join-Path $lh 'cachee.xml')).Attributes = 'Hidden'
    Add-CasSignature 'clé privée cachée dans la liste' $donnees $sig $lh
    $lo = New-Liste 'autres' ([ordered]@{ 'a.xml' = $cle.Publique; 'LISEZMOI.txt' = 'texte'; 'b.xml.ancien' = $cleB.Publique })
    Add-CasSignature 'autres fichiers ignorés, signée A' $donnees $sig $lo
    Add-CasSignature 'autres fichiers ignorés, signée B (b.xml.ancien)' $donnees $sigB $lo
    Add-CasSignature 'signature d''une clé absente de la liste' $donnees (Get-SignatureTest $donnees $autreCle.Privee) $listeAB
    Add-CasSignature 'liste AB, fichier modifié' $modifie $sigB $listeAB

    # Listes et clés anormales en plus
    Add-CasSignature 'clé de 4096 bits (comme la clé de secours), signée par elle' $donnees $sig4096 $listeA4096
    Add-CasSignature 'clés 3072 et 4096, signée 3072' $donnees $sig $listeA4096
    Add-CasSignature 'signature 4096 face à une seule clé 3072' $donnees $sig4096 $fPublique
    Add-CasSignature 'signature SHA-1 (et non SHA-256)' $donnees (Get-SignatureTest $donnees $cle.Privee 'SHA1') $fPublique
    Add-CasSignature 'signature d''un octet' $donnees ([byte[]]@(0)) $fPublique
    Add-CasSignature 'signature trop longue (un zéro devant)' $donnees ([byte[]](@(0) + $sig)) $fPublique
    Add-CasSignature 'signature trop courte (un octet en moins)' $donnees ([byte[]]$sig[1..($sig.Length - 1)]) $fPublique
    Add-CasSignature 'signature faite de zéros' $donnees (New-Object byte[] 384) $fPublique
    Add-CasSignature 'fichier de clé donné seul, extension .txt' $donnees $sig (New-FichierCle 'cle.txt' $cle.Publique)
    Add-CasSignature 'extension .XML en majuscules (clé privée) : lue, donc refusée' $donnees $sig (New-Liste 'majuscules' ([ordered]@{ 'a.xml' = $cle.Publique; 'B.XML' = $cleB.Privee }))
    Add-CasSignature 'fichier nommé « .xml » (clé privée) : lu, donc refusé' $donnees $sig (New-Liste 'point-xml' ([ordered]@{ 'a.xml' = $cle.Publique; '.xml' = $cleB.Privee }))
    $ld = New-Liste 'sous-dossier' ([ordered]@{ 'a.xml' = $cle.Publique })
    New-Item -ItemType Directory -Force -Path (Join-Path $ld 'dossier.xml') | Out-Null
    Add-CasSignature 'sous-dossier nommé .xml : ignoré' $donnees $sig $ld
    Add-CasSignature 'clé avec marque UTF-8 (BOM)' $donnees $sig (New-FichierCle 'bom.xml' ([byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes($cle.Publique))))
    Add-CasSignature 'clé en UTF-16 avec marque' $donnees $sig (New-FichierCle 'utf16.xml' ([byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($cle.Publique))))
    Add-CasSignature 'clé avec déclaration XML' $donnees $sig (New-FichierCle 'declaration.xml' "<?xml version=`"1.0`" encoding=`"utf-8`"?>`r`n$($cle.Publique)")
    Add-CasSignature 'clé avec commentaire' $donnees $sig (New-FichierCle 'commentaire.xml' "<RSAKeyValue><!-- clé de test --><Modulus>$m</Modulus><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'racine d''un autre nom' $donnees $sig (New-FichierCle 'racine.xml' "<Cle><Modulus>$m</Modulus><Exponent>$ex</Exponent></Cle>")
    Add-CasSignature 'Modulus rangé dans un sous-élément' $donnees $sig (New-FichierCle 'imbrique.xml' "<RSAKeyValue><X><Modulus>$m</Modulus></X><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'préfixe d''espace de noms (a:Modulus)' $donnees $sig (New-FichierCle 'prefixe.xml' "<RSAKeyValue><a:Modulus>$m</a:Modulus><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'base64 coupé par des espaces et des retours' $donnees $sig (New-FichierCle 'espaces.xml' "<RSAKeyValue><Modulus>`r`n  $($m.Substring(0, 10)) `t $($m.Substring(10))`n</Modulus><Exponent> $ex </Exponent></RSAKeyValue>")
    Add-CasSignature 'attributs sur les éléments' $donnees $sig (New-FichierCle 'attributs.xml' "<RSAKeyValue a=`"1`"><Modulus b='2'>$m</Modulus><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'texte après la clé' $donnees $sig (New-FichierCle 'texte-apres.xml' "$($cle.Publique) du texte")
    Add-CasSignature 'fermeture d''un autre nom' $donnees $sig (New-FichierCle 'fermeture.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent></Autre>")
    Add-CasSignature 'clé non fermée' $donnees $sig (New-FichierCle 'non-fermee.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent>")
    Add-CasSignature 'entité numérique dans le base64' $donnees $sig (New-FichierCle 'entite.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex&#x0A;</Exponent></RSAKeyValue>")
    Add-CasSignature 'nom en minuscules (modulus)' $donnees $sig (New-FichierCle 'casse.xml' "<RSAKeyValue><modulus>$m</modulus><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'base64 dans un CDATA' $donnees $sig (New-FichierCle 'cdata.xml' "<RSAKeyValue><Modulus><![CDATA[$m]]></Modulus><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'deux Modulus (le premier compte)' $donnees $sig (New-FichierCle 'deux-modulus.xml' "<RSAKeyValue><Modulus>$m</Modulus><Modulus>$mB</Modulus><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'Exponent absent' $donnees $sig (New-FichierCle 'sans-exposant.xml' "<RSAKeyValue><Modulus>$m</Modulus></RSAKeyValue>")
    Add-CasSignature 'exposant avec un zéro devant' $donnees $sig (New-FichierCle 'exposant-zero.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>AAEAAQ==</Exponent></RSAKeyValue>")
    Add-CasSignature 'exposant de 5 octets' $donnees $sig (New-FichierCle 'exposant-long.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>AQABAAE=</Exponent></RSAKeyValue>")
    Add-CasSignature 'exposant 3 (faux)' $donnees $sig (New-FichierCle 'exposant-3.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>Aw==</Exponent></RSAKeyValue>")
    Add-CasSignature 'module avec un zéro devant' $donnees $sig (New-FichierCle 'module-zero.xml' "<RSAKeyValue><Modulus>$([Convert]::ToBase64String([byte[]](@(0) + $cle.Parametres.Modulus)))</Modulus><Exponent>$ex</Exponent></RSAKeyValue>")
    $faux = [byte[]]$cle.Parametres.Modulus.Clone(); $faux[0] = 0x55
    $lf = New-Liste 'module-3071' ([ordered]@{ 'a.xml' = $cle.Publique; 'b.xml' = "<RSAKeyValue><Modulus>$([Convert]::ToBase64String($faux))</Modulus><Exponent>$ex</Exponent></RSAKeyValue>" })
    Add-CasSignature 'clé de 3071 bits (384 octets) à côté d''une bonne' $donnees $sig $lf
    Add-CasSignature 'élément D seul (sans P), à côté du module' $donnees $sig (New-FichierCle 'd-seul.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent><D>AQAB</D></RSAKeyValue>")
    Add-CasSignature 'élément D illisible' $donnees $sig (New-FichierCle 'd-illisible.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent><D>pas du base64</D></RSAKeyValue>")
    Add-CasSignature 'élément P vide' $donnees $sig (New-FichierCle 'p-vide.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent><P></P></RSAKeyValue>")
    Add-CasSignature 'élément P seul' $donnees $sig (New-FichierCle 'p-seul.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent><P>AQAB</P></RSAKeyValue>")
    # Aucun élément de clé privée, même vide ou sans P ; Modulus et Exponent obligatoires et lisibles
    Add-CasSignature 'élément D seul, sans Modulus ni Exponent' $donnees $sig (New-FichierCle 'd-sans-module.xml' "<RSAKeyValue><D>$m</D></RSAKeyValue>")
    Add-CasSignature 'élément D seul (sans P) dans une liste, à côté d''une bonne clé' $donnees $sig (New-Liste 'd-dans-liste' ([ordered]@{ 'a.xml' = $cle.Publique; 'd.xml' = "<RSAKeyValue><Modulus>$mB</Modulus><Exponent>$ex</Exponent><D>AQAB</D></RSAKeyValue>" }))
    Add-CasSignature 'élément InverseQ vide' $donnees $sig (New-FichierCle 'inverseq-vide.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent><InverseQ/></RSAKeyValue>")
    Add-CasSignature 'élément DQ avec préfixe (x:DQ)' $donnees $sig (New-FichierCle 'dq-prefixe.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent><x:DQ>AQAB</x:DQ></RSAKeyValue>")
    Add-CasSignature 'élément Q rangé dans un sous-élément' $donnees $sig (New-FichierCle 'q-imbrique.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent><X><Q>AQAB</Q></X></RSAKeyValue>")
    Add-CasSignature 'élément d en minuscules (pas un élément privé)' $donnees $sig (New-FichierCle 'd-minuscule.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>$ex</Exponent><d>AQAB</d></RSAKeyValue>")
    Add-CasSignature 'Modulus vide' $donnees $sig (New-FichierCle 'modulus-vide.xml' "<RSAKeyValue><Modulus></Modulus><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'Exponent vide' $donnees $sig (New-FichierCle 'exponent-vide.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent/></RSAKeyValue>")
    Add-CasSignature 'Modulus absent' $donnees $sig (New-FichierCle 'sans-modulus.xml' "<RSAKeyValue><Exponent>$ex</Exponent></RSAKeyValue>")
    Add-CasSignature 'Exponent illisible' $donnees $sig (New-FichierCle 'exponent-illisible.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>pas du base64</Exponent></RSAKeyValue>")
    Add-CasSignature 'module de 16392 bits' $donnees $sig (New-Liste 'module-geant' ([ordered]@{ 'a.xml' = $cle.Publique; 'g.xml' = "<RSAKeyValue><Modulus>$([Convert]::ToBase64String([byte[]]((1..2049) | ForEach-Object { 0xFF })))</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>" }))
    Add-CasSignature 'base64 sans le bon bourrage' $donnees $sig (New-FichierCle 'bourrage.xml' "<RSAKeyValue><Modulus>$m</Modulus><Exponent>AQA</Exponent></RSAKeyValue>")
    Add-CasSignature 'fichier de clé en octets invalides' $donnees $sig (New-FichierCle 'octets.xml' ([byte[]](0xFF, 0x00, 0xC3, 0x28, 0x3C)))
    Add-CasSignature 'les vraies clés publiques de Mindset, signature de test' $donnees $sig $livrees

    # Un vrai zip publié, si donné (la CI télécharge la dernière version de Mindset)
    if ($ZipReel -and $SigReel) {
        $zr = [IO.File]::ReadAllBytes($ZipReel); $sr = [IO.File]::ReadAllBytes($SigReel)
        Add-CasSignature 'vrai zip publié, vraies clés' $zr $sr $livrees
        $zr2 = [byte[]]$zr.Clone(); $zr2[100] = $zr2[100] -bxor 1
        Add-CasSignature 'vrai zip publié modifié d''un octet' $zr2 $sr $livrees
        Add-CasSignature 'vrai zip publié, clés de test' $zr $sr $listeAB
    }

    # ===========================================================================================================
    # Installations (les cas de tester-securite.ps1, puis des cas en plus)
    # ===========================================================================================================
    $v200 = { param($b, $d) Set-AppliInstallee $d '2.0.0' }
    $v201 = { param($b, $d) Set-AppliInstallee $d '2.0.1' }
    $zip2 = New-ZipAppli '2.0.0'
    Add-CasInstall 'paquet valide, première installation' $zip2
    Add-CasInstall 'paquet valide par-dessus 2.0.0 (même version)' $zip2 -Avant $v200
    Add-CasInstall 'signature d''un autre fichier' (New-ZipAppli '2.1.0') (Get-SignatureTest $zip2 $cle.Privee) -Avant $v200
    $z = New-ZipAppli '2.1.0'; $s = Get-SignatureTest $z $cle.Privee; $z[$z.Length - 3] = $z[$z.Length - 3] -bxor 1
    Add-CasInstall 'zip modifié d''un octet après signature' $z $s -Avant $v200
    $z = New-ZipAppli '2.1.0'
    Add-CasInstall 'zip signé avec une autre clé' $z (Get-SignatureTest $z $autreCle.Privee) -Avant $v200
    Add-CasInstall 'signature d''un seul octet' (New-ZipAppli '2.1.0') ([byte[]]@(0)) -Avant $v200
    Add-CasInstall 'liste de clés en dossier (A et B), signée B' $z (Get-SignatureTest $z $cleB.Privee) -Cles $listeAB -Avant $v200
    foreach ($n in 'Appli/../../piege-1.txt', 'Appli/sous/../../../piege-2.txt', 'Appli\..\..\piege-3.txt', 'Appli/..', 'Appli/../Appli/piege-5.txt') {
        $e = [ordered]@{}; $e[$n] = 'piege'
        Add-CasInstall "zip-slip « $n »" (New-ZipAppli '2.1.0' $e) -Avant $v200
    }
    Add-CasInstall 'zip-slip placé après les fichiers normaux' (New-ZipTest ([ordered]@{ 'Appli/Appli.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '2.1.0'"; 'Appli/../piege-4.txt' = 'piege' })) -Avant $v200
    $e = [ordered]@{}; $e["Appli/$tmp\piege-6.txt"] = 'piege'
    Add-CasInstall 'chemin absolu dans le dossier du zip' (New-ZipAppli '2.1.0' $e) -Avant $v200
    Add-CasInstall 'flux NTFS caché (Appli.exe:piege)' (New-ZipAppli '2.1.0' ([ordered]@{ 'Appli/Appli.exe:piege' = 'piege' })) -Avant $v200
    $e = [ordered]@{ '../piege-7.txt' = 'piege'; '..\piege-8.txt' = 'piege'; "$tmp\piege-9.txt" = 'piege'; '/piege-10.txt' = 'piege'; 'Autre/piege-11.txt' = 'piege'; 'AppliPiege/piege-12.txt' = 'piege' }
    Add-CasInstall 'entrées hors du dossier principal ignorées' (New-ZipAppli '2.0.1' $e) -Avant $v200
    Add-CasInstall 'exe attendu manquant' (New-ZipAppli '2.1.0' -SansExe) -Avant $v201
    Add-CasInstall 'exe attendu ailleurs que dans le dossier principal' (New-ZipTest ([ordered]@{ 'Autre/Appli.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '2.1.0'" })) -Avant $v201
    Add-CasInstall 'rétrogradation 1.9.0 sur 2.0.1' (New-ZipAppli '1.9.0') -Avant $v201
    Add-CasInstall 'rétrogradation 2.0.0 sur 2.0.1' (New-ZipAppli '2.0.0') -Avant $v201
    Add-CasInstall 'pas de $AppVersion' (New-ZipTest ([ordered]@{ 'Appli/Appli.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = '# pas de version ici' })) -Avant $v201
    Add-CasInstall 'version « deux », première installation' (New-ZipTest ([ordered]@{ 'Appli/Appli.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = 'deux'" }))
    Add-CasInstall 'même version, réinstallée' (New-ZipAppli '2.0.1' ([ordered]@{ 'Appli/reinstalle.txt' = 'oui' })) -Avant $v201
    Add-CasInstall 'version plus récente, anciens fichiers retirés' (New-ZipAppli '2.1.0') -Avant { param($b, $d) Set-AppliInstallee $d '2.0.1' ([ordered]@{ 'reinstalle.txt' = 'oui' }) }
    Add-CasInstall 'restes d''une installation interrompue nettoyés' (New-ZipAppli '2.1.1') -Avant {
        param($b, $d) Set-AppliInstallee $d '2.1.0'
        New-Item -ItemType Directory -Force -Path "$d.nouveau-deadbeef\fichiers", "$d.ancien-deadbeef", "$d.ANCIEN-0000aaaa" | Out-Null
        [IO.File]::WriteAllText("$d.nouveau-fichier", 'un fichier, pas un dossier : gardé')
    }
    Add-CasInstall 'appli encore ouverte (programme verrouillé)' (New-ZipAppli '2.2.0') -Avant { param($b, $d) Set-AppliInstallee $d '2.1.1' ([ordered]@{ 'Aide.txt' = 'aide' }) } -Verrou 'Appli.exe'
    Add-CasInstall 'Mindset encore ouvert (message de Mindset)' (New-ZipTest ([ordered]@{ 'Appli/Mindset.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '2.2.0'" })) -Exe 'Mindset.exe' -Avant {
        param($b, $d) Set-AppliInstallee $d '2.1.1'; [IO.File]::WriteAllText((Join-Path $d 'Mindset.exe'), 'x')
    } -Verrou 'Mindset.exe'
    Add-CasInstall 'barre finale à la destination et au dossier du zip' (New-ZipAppli '1.0.0') -DossierZip 'Appli\' -FinDest '\'
    Add-CasInstall 'version minimale plus récente' (New-ZipAppli '2.0.5') -VersionMinimale '2.1.0'
    Add-CasInstall 'version minimale égale' (New-ZipAppli '2.0.5') -VersionMinimale '2.0.5'
    Add-CasInstall 'version minimale illisible' (New-ZipAppli '2.0.5') -VersionMinimale 'abc'

    # Versions : lecture de la ligne $AppVersion
    function New-ZipScript($Script, [string]$Chemin = 'Appli/fichiers/Appli.ps1') {
        $e = [ordered]@{ 'Appli/Appli.exe' = 'x' }; $e[$Chemin] = $Script; New-ZipTest $e
    }
    $lignes39 = (1..39 | ForEach-Object { "# ligne $_" }) -join "`r`n"
    Add-CasInstall '$appversion en minuscules' (New-ZipScript "`$appversion = '3.0.0'") -Avant $v201
    Add-CasInstall 'version sur la ligne 40' (New-ZipScript "$lignes39`r`n`$AppVersion = '3.0.0'") -Avant $v201
    Add-CasInstall 'version sur la ligne 41' (New-ZipScript "$lignes39`r`n# 40`r`n`$AppVersion = '3.0.0'") -Avant $v201
    Add-CasInstall '« 2.1 » sur « 2.1.0 » (plus ancienne pour .NET)' (New-ZipScript "`$AppVersion = '2.1'") -Avant { param($b, $d) Set-AppliInstallee $d '2.1.0' }
    Add-CasInstall '« 2.1.0 » sur « 2.1 »' (New-ZipScript "`$AppVersion = '2.1.0'") -Avant { param($b, $d) Set-AppliInstallee $d '2.1' }
    Add-CasInstall 'version trop grande pour .NET (99999999999.0)' (New-ZipScript "`$AppVersion = '99999999999.0'") -Avant $v201
    Add-CasInstall 'version à 4 nombres' (New-ZipScript "`$AppVersion = '2.0.1.7'") -Avant $v201
    Add-CasInstall 'version à 5 nombres' (New-ZipScript "`$AppVersion = '2.0.1.7.1'") -Avant $v201
    Add-CasInstall 'version entre guillemets doubles' (New-ZipScript "`$AppVersion = `"3.0.0`"") -Avant $v201
    Add-CasInstall 'version dans un sous-dossier de fichiers' (New-ZipScript "`$AppVersion = '3.0.0'" 'Appli/fichiers/modules/Appli.ps1') -Avant $v201
    Add-CasInstall 'version dans un .txt' (New-ZipScript "`$AppVersion = '3.0.0'" 'Appli/fichiers/Appli.txt') -Avant $v201
    Add-CasInstall 'version dans un .PS1 en majuscules' (New-ZipScript "`$AppVersion = '3.0.0'" 'Appli/fichiers/Appli.PS1') -Avant $v201
    Add-CasInstall 'deux scripts, le second a la version' (New-ZipTest ([ordered]@{ 'Appli/Appli.exe' = 'x'; 'Appli/fichiers/a.ps1' = '# rien'; 'Appli/fichiers/b.ps1' = "`$AppVersion = '3.0.0'" })) -Avant $v201
    Add-CasInstall 'deux scripts, deux versions (le premier sur le disque gagne)' (New-ZipTest ([ordered]@{ 'Appli/Appli.exe' = 'x'; 'Appli/fichiers/b.ps1' = "`$AppVersion = '1.0.0'"; 'Appli/fichiers/a.ps1' = "`$AppVersion = '3.0.0'" })) -Avant $v201
    Add-CasInstall 'fins de ligne « \r » seules' (New-ZipScript "# x`r`$AppVersion = '3.0.0'`r") -Avant $v201
    Add-CasInstall 'fins de ligne « \n » seules' (New-ZipScript "# x`n`$AppVersion = '3.0.0'`n") -Avant $v201
    Add-CasInstall 'script en UTF-16 avec marque' (New-ZipScript ([byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("# x`r`n`$AppVersion = '3.0.0'")))) -Avant $v201
    Add-CasInstall 'espace insécable (UTF-8 avec marque)' (New-ZipScript ([byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("`$AppVersion$([char]0xA0)= '3.0.0'")))) -Avant $v201
    Add-CasInstall 'espace insécable (UTF-8 sans marque)' (New-ZipScript ([byte[]]([Text.Encoding]::UTF8.GetBytes("`$AppVersion$([char]0xA0)= '3.0.0'")))) -Avant $v201
    Add-CasInstall 'espace insécable (ANSI)' (New-ZipScript ([byte[]]([Text.Encoding]::GetEncoding(1252).GetBytes("`$AppVersion$([char]0xA0)= '3.0.0'")))) -Avant $v201
    Add-CasInstall 'tabulations autour du =' (New-ZipScript "`$AppVersion`t=`t'3.0.0'") -Avant $v201
    Add-CasInstall 'espace avant $AppVersion' (New-ZipScript " `$AppVersion = '3.0.0'") -Avant $v201
    Add-CasInstall 'appli installée sans version lisible' (New-ZipAppli '1.0.0') -Avant { param($b, $d) New-Item -ItemType Directory -Force -Path $d | Out-Null; [IO.File]::WriteAllText((Join-Path $d 'vieux.txt'), 'x') }
    Add-CasInstall 'appli installée : script caché avec une version plus haute' (New-ZipAppli '2.0.0') -Avant {
        param($b, $d) Set-AppliInstallee $d '1.0.0'; $f = Join-Path $d 'fichiers\0.ps1'; [IO.File]::WriteAllText($f, "`$AppVersion = '9.0.0'"); (Get-Item -LiteralPath $f).Attributes = 'Hidden'
    }
    Add-CasInstall 'version.json présent et cohérent (ignoré par PowerShell)' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/version.json' = '{ "appli": "appli", "version": "3.0.0", "mindset_min": "2.15.0" }' })) -Avant $v201

    # Chemins dans le zip
    Add-CasInstall 'chemin avec « . »' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/./point.txt' = 'x' }))
    Add-CasInstall 'chemin avec « sous/.. » qui reste dedans' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/sous/../dedans.txt' = 'x' }))
    Add-CasInstall 'double barre' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli//double.txt' = 'x' }))
    Add-CasInstall 'nom finissant par un point' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/point.txt.' = 'x' }))
    Add-CasInstall 'nom finissant par un espace' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/espace.txt ' = 'x' }))
    Add-CasInstall 'dossier finissant par un point' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/sous./y.txt' = 'x' }))
    Add-CasInstall 'segment « ... »' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/.../trois.txt' = 'x' }))
    # (.NET refuse d'écrire ces noms dans un zip : zips écrits à la main)
    foreach ($c in '<', '>', '|', '"', '?', '*', [string][char]7) {
        Add-CasInstall "caractère interdit « $c »" (New-ZipBrut (@(Get-EntreesBrutes '3.0.0') + @(@{ Nom = (Get-Octets8 "Appli/a$($c)b.txt"); Donnees = (Get-Octets8 'x') })))
    }
    Add-CasInstall 'nom réservé CON' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/CON' = 'x' }))
    Add-CasInstall 'nom réservé nul.txt' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/sous/nul.txt' = 'x' }))
    Add-CasInstall 'chemin très long (plus de 260 caractères)' (New-ZipAppli '3.0.0' ([ordered]@{ "Appli/$('d' * 120)/$('f' * 120).txt" = 'x' }))
    Add-CasInstall 'chemin long (près de 260 caractères)' (New-ZipAppli '3.0.0' ([ordered]@{ "Appli/$('e' * 60).txt" = 'x' }))
    Add-CasInstall 'dossier principal en majuscules dans le zip' (New-ZipTest ([ordered]@{ 'APPLI/Appli.exe' = 'x'; 'appli/fichiers/Appli.ps1' = "`$AppVersion = '3.0.0'" }))
    Add-CasInstall 'barres inversées dans tout le zip' (New-ZipTest ([ordered]@{ 'Appli\Appli.exe' = 'x'; 'Appli\fichiers\Appli.ps1' = "`$AppVersion = '3.0.0'" }))
    Add-CasInstall 'entrée « dossier » seule (non créée)' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/vide/' = '' }))
    $double = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    $double['Appli/Appli.exe'] = 'premier'; $double['Appli/fichiers/Appli.ps1'] = "`$AppVersion = '3.0.0'"; $double['appli/APPLI.EXE'] = 'second'
    Add-CasInstall 'entrée en double (la dernière gagne)' (New-ZipTest $double)
    Add-CasInstall 'exe qui est un dossier' (New-ZipTest ([ordered]@{ 'Appli/Appli.exe/x.txt' = 'x'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '3.0.0'" }))
    Add-CasInstall 'nom accentué (UTF-8 marqué)' (New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/fichiers/thème été.txt' = 'x' }))
    Add-CasInstall 'zip vide' (New-ZipTest ([ordered]@{}))
    Add-CasInstall 'pas un zip (octets au hasard)' ([byte[]](1..2000 | ForEach-Object { Get-Random -Maximum 256 }))
    $zt = New-ZipAppli '3.0.0'
    Add-CasInstall 'zip coupé en deux' ([byte[]]$zt[0..([int]($zt.Length / 2))])
    $za = New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/gros.txt' = ('abcdefghij' * 500) }); $za[60] = $za[60] -bxor 0xFF
    Add-CasInstall 'zip dont le contenu est abîmé (deflate)' $za
    $zg = New-ZipAppli '3.0.0' ([ordered]@{ 'Appli/gros.txt' = ('abcdefghij' * 500) })
    Add-CasInstall 'deflate plus long que la taille annoncée' (Set-TailleAnnoncee $zg 'Appli/gros.txt' 100)
    Add-CasInstall 'deflate plus court que la taille annoncée' (Set-TailleAnnoncee $zg 'Appli/gros.txt' 10000)
    Add-CasInstall 'deflate plus court que la taille annoncée, CRC faux' (Set-TailleAnnoncee $zg 'Appli/gros.txt' 10000 12345)
    Add-CasInstall 'deflate de la bonne taille, CRC faux' (Set-TailleAnnoncee $zg 'Appli/gros.txt' 5000 12345)
    Add-CasInstall 'version.json de la racine plus long que la taille annoncée' (Set-TailleAnnoncee (New-ZipAppli '3.0.0' ([ordered]@{ 'version.json' = "{ `"version`": `"3.0.0`" }$(' ' * 500)" })) 'version.json' 10)
    Add-CasInstall 'fichier hors du dossier principal plus long que la taille annoncée (ignoré)' (Set-TailleAnnoncee (New-ZipAppli '3.0.0' ([ordered]@{ 'Autre/gros.txt' = ('abcdefghij' * 500) })) 'Autre/gros.txt' 100)

    # Zips écrits à la main (ce que .NET ne fabrique pas)
    $cp = @(Get-EntreesBrutes '3.0.0')
    Add-CasInstall 'nom ANSI sans drapeau UTF-8 (è)' (New-ZipBrut ($cp + @(@{ Nom = [byte[]](Get-Octets8 'Appli/th') + [byte[]]@(0xE8) + [byte[]](Get-Octets8 'me.txt'); Donnees = (Get-Octets8 'x') })))
    Add-CasInstall 'octets UTF-8 sans drapeau UTF-8 (lus en ANSI)' (New-ZipBrut ($cp + @(@{ Nom = (Get-Octets8 'Appli/thème.txt'); Donnees = (Get-Octets8 'x') })))
    Add-CasInstall 'drapeau UTF-8 et octets invalides' (New-ZipBrut ($cp + @(@{ Nom = [byte[]](Get-Octets8 'Appli/x') + [byte[]]@(0xFF, 0xFE) + [byte[]](Get-Octets8 '.txt'); Donnees = (Get-Octets8 'x'); Drapeaux = 0x800 })))
    $nomCache = Get-Octets8 'Appli/innocent.txt'
    $piegeU = Get-Octets8 'Appli/../../piege-unicode.txt'
    $crcNom = Get-Crc32 $nomCache
    $extraU = [byte[]]@(0x75, 0x70) + [BitConverter]::GetBytes([uint16](5 + $piegeU.Length)) + [byte[]]@(1) + [BitConverter]::GetBytes([uint32]$crcNom) + $piegeU
    Add-CasInstall 'nom Unicode caché (champ 0x7075) qui remonte' (New-ZipBrut ($cp + @(@{ Nom = $nomCache; Donnees = (Get-Octets8 'x'); Extra = $extraU })))
    Add-CasInstall 'CRC faux' (New-ZipBrut ($cp + @(@{ Nom = (Get-Octets8 'Appli/crc.txt'); Donnees = (Get-Octets8 'contenu'); Crc = 12345 })))
    Add-CasInstall 'nom local différent du nom central' (New-ZipBrut ($cp + @(@{ Nom = (Get-Octets8 'Appli/central.txt'); NomLocal = (Get-Octets8 'Appli/../../local.txt'); Donnees = (Get-Octets8 'x') })))
    Add-CasInstall 'entrée marquée chiffrée' (New-ZipBrut ($cp + @(@{ Nom = (Get-Octets8 'Appli/chiffre.txt'); Donnees = (Get-Octets8 'x'); Drapeaux = 1 })))
    Add-CasInstall 'programme marqué chiffré (UTF-8 et chiffré)' (New-ZipBrut (@(@{ Nom = (Get-Octets8 'Appli/Appli.exe'); Donnees = (Get-Octets8 'programme'); Drapeaux = 0x801 }) + @($cp[1])))
    Add-CasInstall 'version.json de la racine marqué chiffré' (New-ZipBrut ($cp + @(@{ Nom = (Get-Octets8 'version.json'); Donnees = (Get-Octets8 '{ "version": "3.0.0" }'); Drapeaux = 1 })))
    Add-CasInstall 'entrée chiffrée hors du dossier principal (ignorée)' (New-ZipBrut ($cp + @(@{ Nom = (Get-Octets8 'Autre/chiffre.txt'); Donnees = (Get-Octets8 'x'); Drapeaux = 1 })))
    Add-CasInstall 'méthode de compression inconnue (bzip2)' (New-ZipBrut ($cp + @(@{ Nom = (Get-Octets8 'Appli/bzip.txt'); Donnees = (Get-Octets8 'x'); Methode = 12 })))
    Add-CasInstall 'zip brut sans piège (témoin)' (New-ZipBrut $cp)

    if ($ZipReel -and $SigReel) {
        Add-CasInstall 'vrai zip publié de Mindset' ([IO.File]::ReadAllBytes($ZipReel)) ([IO.File]::ReadAllBytes($SigReel)) -Cles $livrees -DossierZip 'Mindset' -Exe 'Mindset.exe'
    }

    # ===========================================================================================================
    # La version Rust, sur les mêmes fichiers
    # ===========================================================================================================
    $manifeste = Join-Path $tmp 'cas.json'
    $resultats = Join-Path $tmp 'resultats.json'
    $sortie = [ordered]@{
        signature    = @($script:CasSignature | ForEach-Object { [ordered]@{ id = $_.id; donnees = $_.donnees; signature = $_.signature; cles = $_.cles } })
        installation = @($script:CasInstall | ForEach-Object { [ordered]@{ id = $_.id; zip = $_.zip; signature = $_.signature; cles = $_.cles; destination = $_.destination; dossier_zip = $_.dossier_zip; exe = $_.exe; version_minimale = $_.version_minimale } })
    }
    [IO.File]::WriteAllText($manifeste, ($sortie | ConvertTo-Json -Depth 5), $utf8)
    $p = Start-Process -FilePath $Banc -ArgumentList "`"$manifeste`"", "`"$resultats`"" -NoNewWindow -Wait -PassThru
    foreach ($v in $script:Verrous) { $v.Dispose() }
    $script:Verrous.Clear()
    if ($p.ExitCode -ne 0) { throw "Le banc d'essai Rust a échoué (code $($p.ExitCode))." }
    $rust = [IO.File]::ReadAllText($resultats, [Text.Encoding]::UTF8) | ConvertFrom-Json

    # ===========================================================================================================
    # Comparaison
    # ===========================================================================================================
    $ecarts = @()
    $parId = @{}; foreach ($r in $rust.signature) { $parId[$r.id] = $r }
    Write-Host ''; Write-Host 'Signatures' -ForegroundColor Cyan
    foreach ($c in $script:CasSignature) {
        $r = $parId[$c.id]
        $pareil = $r -and ([bool]$r.resultat -eq $c.ps)
        $texte = "  $(if ($pareil) { 'PAREIL' } else { 'ÉCART ' })  [$(if ($c.ps) { 'acceptée' } else { 'refusée ' })] $($c.nom)"
        if (-not $pareil) { $texte += " (Rust : $(if ($r) { $r.resultat } else { 'pas de réponse' }))"; $ecarts += "signature : $($c.nom)" }
        Write-Host $texte -ForegroundColor $(if ($pareil) { 'Green' } else { 'Red' })
    }
    $parId = @{}; foreach ($r in $rust.installation) { $parId[$r.id] = $r }
    Write-Host ''; Write-Host 'Installations' -ForegroundColor Cyan
    foreach ($c in $script:CasInstall) {
        $r = $parId[$c.id]
        $motifs = @()
        if (-not $r) { $motifs += 'pas de réponse' }
        else {
            if ([bool]$r.ok -ne $c.ps.ok) { $motifs += "réponse (PowerShell : $(if ($c.ps.ok) { 'installé' } else { $c.ps.message }) ; Rust : $(if ($r.ok) { 'installé' } else { $r.message }))" }
            elseif (-not $c.ps.ok) {
                if ($r.categorie -ne $c.ps.categorie) { $motifs += "catégorie (PowerShell : $($c.ps.categorie), « $($c.ps.message) » ; Rust : $($r.categorie), « $($r.message) »)" }
                elseif ($c.ps.categorie -ne 'autre' -and $r.message -cne $c.ps.message) { $motifs += "message (PowerShell : « $($c.ps.message) » ; Rust : « $($r.message) »)" }
            } else {
                $retPs = $c.ps.retour.Substring($c.basePs.Length); $retRs = if ($r.retour.Length -ge $c.baseRs.Length) { $r.retour.Substring($c.baseRs.Length) } else { $r.retour }
                if ($retPs -ne $retRs) { $motifs += "dossier rendu (PowerShell : $retPs ; Rust : $retRs)" }
            }
            $aPs = Get-Arbre $c.basePs; $aRs = Get-Arbre $c.baseRs
            if ($aPs -cne $aRs) {
                $lp = @($aPs -split "`n"); $lr = @($aRs -split "`n")
                $motifs += "fichiers (seulement PowerShell : $((@($lp | Where-Object { $_ -cnotin $lr }) -join ', ')) ; seulement Rust : $((@($lr | Where-Object { $_ -cnotin $lp }) -join ', ')))"
            }
        }
        $pareil = -not $motifs.Count
        $etat = if ($c.ps.ok) { 'installé' } else { $c.ps.categorie }
        Write-Host "  $(if ($pareil) { 'PAREIL' } else { 'ÉCART ' })  [$etat] $($c.nom)" -ForegroundColor $(if ($pareil) { 'Green' } else { 'Red' })
        foreach ($mo in $motifs) { Write-Host "          $mo" -ForegroundColor Red }
        if (-not $pareil) { $ecarts += "installation : $($c.nom)" }
    }
    # Aucun fichier « piege » ne doit être sorti des dossiers des cas
    $sortis = @(Get-ChildItem -LiteralPath $tmp -Recurse -Force -Filter 'piege*' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\installation\\\d+\\(ps|rs)\\' -and $_.Name -ne 'paquet.zip' })
    if ($sortis.Count) { $ecarts += "fichiers piégés écrits hors des dossiers des cas : $(($sortis | ForEach-Object { $_.FullName }) -join ', ')" }

    $compares = @($script:CasInstall)
    $total = $script:CasSignature.Count + $compares.Count
    $acceptees = @($script:CasSignature | Where-Object { $_.ps }).Count
    $installes = @($compares | Where-Object { $_.ps.ok }).Count
    Write-Host ''
    Write-Host "$total cas comparés : $($script:CasSignature.Count) signatures ($acceptees acceptées), $($compares.Count) installations ($installes installées)."
    if ($ecarts.Count) {
        Write-Host "$($ecarts.Count) écart(s) entre PowerShell et Rust :" -ForegroundColor Red
        $ecarts | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        $code = 1
    } else {
        Write-Host "Réponses identiques : $total sur $total (100 %)." -ForegroundColor Green
    }
} finally {
    foreach ($v in $script:Verrous) { try { $v.Dispose() } catch {} }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    # (les chemins de plus de 260 caractères résistent à Remove-Item de Windows PowerShell)
    if (Test-Path -LiteralPath $tmp) { cmd /c rd /s /q "\\?\$tmp" 2>$null }
}
exit $code
