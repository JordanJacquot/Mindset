# Signe un fichier (un zip à publier) avec la clé de la suite : écrit <fichier>.sig à côté.
#
#   & D:\Projets\Mindset\outils\signer.ps1 -Fichier .\OptiGame.zip
#   & D:\Projets\Mindset\outils\signer.ps1 -Fichier .\OptiGame.zip -Secours E:\secours.msk
#
# Utilisé par les scripts de publication de Mindset, Nevermind, Evermind et Mindcare : le .sig est publié avec le zip,
# et Mindset (comme les applis) refuse d'installer un zip dont la signature n'est pas bonne. Les clés sont créées par
# outils\cle.ps1.
#
# Sans -Secours : la clé de tous les jours, sur ce PC. Avec -Secours (ou la variable MINDSET_CLE_SECOURS, le temps d'une
# publication faite par les publier.ps1) : la clé de secours, lue dans son fichier protégé par un mot de passe et
# gardée en mémoire seulement. Elle ne sert qu'à publier un changement de clé (clé perdue ou volée : voir le README).

param([Parameter(Mandatory = $true)][string]$Fichier, [string]$Secours = $env:MINDSET_CLE_SECOURS, [securestring]$MotDePasse)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$privee = Join-Path $env:APPDATA 'Mindset-signature\cle-privee.bin'
$mindset = Join-Path (Split-Path $PSScriptRoot -Parent) 'Mindset\fichiers'
$cles = Join-Path $mindset 'cles-publiques'
$utf8 = New-Object Text.UTF8Encoding $false
. (Join-Path $mindset 'modules\signature.ps1')   # Test-Signature : la vérification que fait Mindset

if ($Secours) {
    # Le même format que les copies de secours de outils\cle.ps1 (« MSK1 », sel, IV, clé chiffrée en AES 256)
    if (-not (Test-Path -LiteralPath $Secours)) { throw "Clé de secours introuvable : $Secours (branche la clé USB)." }
    $o = [IO.File]::ReadAllBytes($Secours)
    if ($o.Length -lt 52 -or $utf8.GetString($o, 0, 4) -ne 'MSK1') { throw 'Ce fichier n''est pas une clé de secours.' }
    if (-not $MotDePasse) { $MotDePasse = Read-Host 'Mot de passe de la clé de secours' -AsSecureString }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($MotDePasse)
    try { $clair = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($clair, ([byte[]]$o[4..19]), 300000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $kdf.GetBytes(32); $aes.IV = [byte[]]$o[20..35]
        $xml = $utf8.GetString($aes.CreateDecryptor().TransformFinalBlock($o, 36, $o.Length - 36))
    } catch { throw 'Mot de passe incorrect.' } finally { $aes.Dispose(); $kdf.Dispose() }
    if (-not $xml.StartsWith('<RSAKeyValue>')) { throw 'Mot de passe incorrect.' }
} else {
    if (-not (Test-Path -LiteralPath $privee)) { throw "Pas de clé de signature sur ce PC ($privee). Crée-la avec outils\cle.ps1, ou remets ta copie de secours (-Importer)." }
    $xml = $utf8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($privee), $null, 'CurrentUser'))
}

$Fichier = (Resolve-Path -LiteralPath $Fichier).Path
$donnees = [IO.File]::ReadAllBytes($Fichier)
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
try {
    $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString($xml)
    $sig = $rsa.SignData($donnees, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
} finally { $rsa.Dispose() }

# Vérifiée tout de suite avec la liste des clés publiques de Mindset : une signature que Mindset refuserait n'est
# jamais écrite (clé retirée de la liste, liste abîmée, clé privée glissée dans la liste...)
if (-not (Test-Signature $donnees $sig $cles)) { throw 'La signature n''est acceptée par aucune clé de la liste de Mindset (cles-publiques) : clé retirée de la liste, ou liste abîmée ? (.\outils\cle.ps1 -Liste)' }

[IO.File]::WriteAllBytes("$Fichier.sig", $sig)
"Signé$(if ($Secours) { ' avec la clé de secours' }) : $Fichier.sig"
