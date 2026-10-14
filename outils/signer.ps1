# Signe un fichier (un zip à publier) avec la clé de la suite : écrit <fichier>.sig à côté.
#
#   & D:\Projets\Mindset\outils\signer.ps1 -Fichier .\OptiGame.zip
#
# Utilisé par les scripts de publication de Mindset, Nevermind et Evermind : le .sig est publié avec le zip,
# et Mindset refuse d'installer un zip dont la signature n'est pas bonne. La clé est créée par outils\cle.ps1.

param([Parameter(Mandatory = $true)][string]$Fichier)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$privee = Join-Path $env:APPDATA 'Mindset-signature\cle-privee.bin'
$publique = Join-Path (Split-Path $PSScriptRoot -Parent) 'Mindset\fichiers\cle-publique.xml'
if (-not (Test-Path -LiteralPath $privee)) { throw "Pas de clé de signature sur ce PC ($privee). Crée-la avec outils\cle.ps1, ou remets ta copie de secours (-Importer)." }

$Fichier = (Resolve-Path -LiteralPath $Fichier).Path
$donnees = [IO.File]::ReadAllBytes($Fichier)
$xml = (New-Object Text.UTF8Encoding $false).GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($privee), $null, 'CurrentUser'))
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
try {
    $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString($xml)
    $sig = $rsa.SignData($donnees, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
} finally { $rsa.Dispose() }

# Vérifiée tout de suite avec la clé publique livrée dans Mindset : une signature que Mindset refuserait n'est jamais écrite
$v = New-Object Security.Cryptography.RSACryptoServiceProvider
try { $v.FromXmlString([IO.File]::ReadAllText($publique)); $ok = $v.VerifyData($donnees, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'), $sig) } finally { $v.Dispose() }
if (-not $ok) { throw 'La signature ne correspond pas à la clé publique de Mindset (cle-publique.xml) : clé remplacée sans mettre Mindset à jour ?' }

[IO.File]::WriteAllBytes("$Fichier.sig", $sig)
"Signé : $Fichier.sig"
