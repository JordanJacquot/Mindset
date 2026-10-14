# La clé de signature de la suite (Mindset, Nevermind, Evermind).
#
#   .\outils\cle.ps1                         crée la clé (une seule fois)
#   .\outils\cle.ps1 -Exporter D:\cle.msk    copie de secours protégée par un mot de passe (à garder sur une clé USB)
#   .\outils\cle.ps1 -Importer D:\cle.msk    remet la clé sur ce PC (nouveau PC, Windows réinstallé)
#
# La clé privée reste sur ce PC, chiffrée pour ton compte Windows, hors de tout dépôt :
#   %APPDATA%\Mindset-signature\cle-privee.bin
# La clé publique va dans Mindset\fichiers\cle-publique.xml (publiée avec Mindset, elle ne permet que de vérifier).
#
# Sans la clé privée, plus aucune version ne peut être signée : garde une copie de secours.
# Si elle est volée, crée-en une nouvelle (-Remplacer) et publie un Mindset avec la nouvelle clé publique.

param([string]$Exporter, [string]$Importer, [switch]$Remplacer)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$dossier = Join-Path $env:APPDATA 'Mindset-signature'
$privee  = Join-Path $dossier 'cle-privee.bin'
$publique = Join-Path (Split-Path $PSScriptRoot -Parent) 'Mindset\fichiers\cle-publique.xml'
$utf8 = New-Object Text.UTF8Encoding $false

function Save-Privee([string]$Xml) {
    New-Item -ItemType Directory -Force -Path $dossier | Out-Null
    $chiffre = [Security.Cryptography.ProtectedData]::Protect($utf8.GetBytes($Xml), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($privee, $chiffre)
}

function Get-CleMotDePasse([securestring]$Mdp, [byte[]]$Sel) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Mdp)
    try { $clair = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($clair, $Sel, 300000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $kdf.GetBytes(32) } finally { $kdf.Dispose() }
}

if ($Exporter) {
    if (-not (Test-Path -LiteralPath $privee)) { throw 'Pas de clé sur ce PC.' }
    $xml = $utf8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($privee), $null, 'CurrentUser'))
    $m1 = Read-Host 'Mot de passe de la copie de secours (12 caractères ou plus)' -AsSecureString
    $m2 = Read-Host 'Encore une fois' -AsSecureString
    $t1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($m1))
    $t2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($m2))
    if ($t1 -ne $t2) { throw 'Les deux mots de passe sont différents.' }
    if ($t1.Length -lt 12) { throw 'Mot de passe trop court (12 caractères ou plus).' }
    $sel = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($sel); $rng.GetBytes($iv); $rng.Dispose()
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = Get-CleMotDePasse $m1 $sel; $aes.IV = $iv
    $clair = $utf8.GetBytes($xml)
    $chiffre = $aes.CreateEncryptor().TransformFinalBlock($clair, 0, $clair.Length); $aes.Dispose()
    [IO.File]::WriteAllBytes($Exporter, [byte[]]($utf8.GetBytes('MSK1') + $sel + $iv + $chiffre))
    "Copie de secours écrite : $Exporter (garde-la hors de ce PC, et n'oublie pas son mot de passe)"
    return
}

if ($Importer) {
    if ((Test-Path -LiteralPath $privee) -and -not $Remplacer) { throw 'Une clé existe déjà sur ce PC (ajoute -Remplacer pour l''écraser).' }
    $o = [IO.File]::ReadAllBytes($Importer)
    if ($utf8.GetString($o, 0, 4) -ne 'MSK1') { throw 'Ce fichier n''est pas une copie de secours de la clé.' }
    $m = Read-Host 'Mot de passe de la copie de secours' -AsSecureString
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = Get-CleMotDePasse $m ([byte[]]$o[4..19]); $aes.IV = [byte[]]$o[20..35]
    try { $clair = $aes.CreateDecryptor().TransformFinalBlock($o, 36, $o.Length - 36) } catch { throw 'Mot de passe incorrect.' } finally { $aes.Dispose() }
    Save-Privee $utf8.GetString($clair)
    'Clé remise sur ce PC.'
    return
}

if ((Test-Path -LiteralPath $privee) -and -not $Remplacer) { throw "Une clé existe déjà ($privee). Ajoute -Remplacer pour en créer une nouvelle (les versions signées avec l'ancienne ne seront plus acceptées)." }
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
try {
    $rsa.PersistKeyInCsp = $false
    Save-Privee $rsa.ToXmlString($true)
    [IO.File]::WriteAllText($publique, $rsa.ToXmlString($false), $utf8)
} finally { $rsa.Dispose() }
"Clé créée. Privée : $privee (ne la partage jamais). Publique : $publique"
'Pense à faire une copie de secours : .\outils\cle.ps1 -Exporter <fichier sur une clé USB>'
