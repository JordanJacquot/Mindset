# Les clés de signature de la suite (Mindset, Nevermind, Evermind, Mindcare) et la liste des clés publiques.
#
#   .\outils\cle.ps1                           crée la clé de tous les jours (une seule fois)
#   .\outils\cle.ps1 -Exporter E:\cle.msk      copie de secours de cette clé, protégée par un mot de passe (sur une clé USB)
#   .\outils\cle.ps1 -Importer E:\cle.msk      remet la clé sur ce PC (nouveau PC, Windows réinstallé)
#   .\outils\cle.ps1 -Secours E:\secours.msk   crée la clé de SECOURS : sa partie privée ne va jamais sur ce PC (elle est
#                                              écrite seulement dans ce fichier, protégé par un mot de passe, à ranger
#                                              hors ligne) ; sa clé publique entre dans la liste
#   .\outils\cle.ps1 -Liste                    montre les clés de la liste
#   .\outils\cle.ps1 -Nouvelle                 changement de clé, étape 1 : prépare la clé suivante, l'ajoute à la liste
#   .\outils\cle.ps1 -Basculer                 changement de clé, étape 2 : signe avec la suivante, retire l'ancienne
#   .\outils\cle.ps1 -Retirer <nom.xml>        retire une clé de la liste (clé perdue ou volée)
#
# La clé privée de tous les jours reste sur ce PC, chiffrée pour ton compte Windows, hors de tout dépôt :
#   %APPDATA%\Mindset-signature\cle-privee.bin   (et cle-privee-suivante.bin pendant un changement de clé)
# Les clés publiques vont dans Mindset\fichiers\cles-publiques\ (publiées avec Mindset, elles ne permettent que de
# vérifier). Chaque appli en livre une copie identique (fichiers\cles-publiques), vérifiée par son publier.ps1.
# Une signature est acceptée si UNE des clés de la liste la vérifie. La procédure complète est dans le README.
#
# Sans clé privée, plus aucune version ne peut être signée : garde une copie de secours, et la clé de secours.
# -MotDePasse (une SecureString, jamais un texte) sert aux tests : sans lui, le mot de passe est demandé.

param([string]$Exporter, [string]$Importer, [switch]$Remplacer, [string]$Secours, [switch]$Liste, [switch]$Nouvelle,
      [switch]$Basculer, [string]$Retirer, [securestring]$MotDePasse)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$dossier  = Join-Path $env:APPDATA 'Mindset-signature'
$privee   = Join-Path $dossier 'cle-privee.bin'
$suivante = Join-Path $dossier 'cle-privee-suivante.bin'
$cles     = Join-Path (Split-Path $PSScriptRoot -Parent) 'Mindset\fichiers\cles-publiques'
$utf8 = New-Object Text.UTF8Encoding $false

function Save-Privee([string]$Xml, [string]$Fichier = $privee) {
    New-Item -ItemType Directory -Force -Path $dossier | Out-Null
    $chiffre = [Security.Cryptography.ProtectedData]::Protect($utf8.GetBytes($Xml), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($Fichier, $chiffre)
}
function Read-Privee([string]$Fichier = $privee) {
    $utf8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Fichier), $null, 'CurrentUser'))
}

function Get-TexteMotDePasse([securestring]$Mdp) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Mdp)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Get-CleMotDePasse([securestring]$Mdp, [byte[]]$Sel) {
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes((Get-TexteMotDePasse $Mdp), $Sel, 300000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $kdf.GetBytes(32) } finally { $kdf.Dispose() }
}
# Un nouveau mot de passe : demandé deux fois, 12 caractères ou plus
function Read-NouveauMotDePasse([string]$Pour) {
    if ($MotDePasse) { $m1 = $MotDePasse; $m2 = $MotDePasse }
    else {
        $m1 = Read-Host "Mot de passe $Pour (12 caractères ou plus)" -AsSecureString
        $m2 = Read-Host 'Encore une fois' -AsSecureString
    }
    $t1 = Get-TexteMotDePasse $m1; $t2 = Get-TexteMotDePasse $m2
    if ($t1 -ne $t2) { throw 'Les deux mots de passe sont différents.' }
    if ($t1.Length -lt 12) { throw 'Mot de passe trop court (12 caractères ou plus).' }
    $m1
}
# Fichier protégé par un mot de passe (.msk) : « MSK1 », sel, IV, puis la clé privée chiffrée (AES 256)
function Save-Msk([string]$Xml, [string]$Fichier, [securestring]$Mdp) {
    $sel = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($sel); $rng.GetBytes($iv); $rng.Dispose()
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = Get-CleMotDePasse $Mdp $sel; $aes.IV = $iv
    $clair = $utf8.GetBytes($Xml)
    $chiffre = $aes.CreateEncryptor().TransformFinalBlock($clair, 0, $clair.Length); $aes.Dispose()
    [IO.File]::WriteAllBytes($Fichier, [byte[]]($utf8.GetBytes('MSK1') + $sel + $iv + $chiffre))
}
function Read-Msk([string]$Fichier, [securestring]$Mdp) {
    $o = [IO.File]::ReadAllBytes($Fichier)
    if ($o.Length -lt 52 -or $utf8.GetString($o, 0, 4) -ne 'MSK1') { throw 'Ce fichier n''est pas une copie de secours de la clé.' }
    if (-not $Mdp) { $Mdp = Read-Host 'Mot de passe de la copie de secours' -AsSecureString }
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = Get-CleMotDePasse $Mdp ([byte[]]$o[4..19]); $aes.IV = [byte[]]$o[20..35]
    try { $clair = $aes.CreateDecryptor().TransformFinalBlock($o, 36, $o.Length - 36) } catch { throw 'Mot de passe incorrect.' } finally { $aes.Dispose() }
    $xml = $utf8.GetString($clair)
    if (-not $xml.StartsWith('<RSAKeyValue>')) { throw 'Mot de passe incorrect.' }
    $xml
}

# Une nouvelle paire de clés : @{ Privee; Publique } en XML
function New-Paire([int]$Taille) {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider($Taille)
    try { $rsa.PersistKeyInCsp = $false; @{ Privee = $rsa.ToXmlString($true); Publique = $rsa.ToXmlString($false) } }
    finally { $rsa.Dispose() }
}
# Range une clé publique dans la liste, sous le nom <genre>-<date>.xml (ou -2, -3... le même jour)
function Add-ClePublique([string]$Xml, [string]$Genre) {
    New-Item -ItemType Directory -Force -Path $cles | Out-Null
    $base = "$Genre-$(Get-Date -Format 'yyyy-MM-dd')"; $nom = "$base.xml"; $n = 2
    while (Test-Path -LiteralPath (Join-Path $cles $nom)) { $nom = "$base-$n.xml"; $n++ }
    $f = Join-Path $cles $nom
    [IO.File]::WriteAllText($f, $Xml, $utf8)
    $f
}
# Le « Modulus » d'une clé en XML : le même dans la clé privée et dans sa clé publique
function Get-Modulus([string]$Xml) { try { [string]([xml]$Xml).RSAKeyValue.Modulus } catch { '' } }
# Le fichier de la liste qui correspond à une clé privée ('' si aucun)
function Find-ClePublique([string]$XmlPrivee) {
    $m = Get-Modulus $XmlPrivee
    foreach ($f in @(Get-ChildItem -LiteralPath $cles -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
        if ($m -and (Get-Modulus ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))) -eq $m) { return $f.FullName }
    }
    ''
}

if ($Exporter) {
    if (-not (Test-Path -LiteralPath $privee)) { throw 'Pas de clé sur ce PC.' }
    $mdp = Read-NouveauMotDePasse 'de la copie de secours'
    Save-Msk (Read-Privee) $Exporter $mdp
    "Copie de secours écrite : $Exporter (garde-la hors de ce PC, et n'oublie pas son mot de passe)"
    return
}

if ($Importer) {
    if ((Test-Path -LiteralPath $privee) -and -not $Remplacer) { throw 'Une clé existe déjà sur ce PC (ajoute -Remplacer pour l''écraser).' }
    Save-Privee (Read-Msk $Importer $MotDePasse)
    'Clé remise sur ce PC.'
    return
}

if ($Secours) {
    # Créée en mémoire, écrite seulement chiffrée par son mot de passe : rien de sa partie privée ne reste sur ce PC.
    # Elle ne sert qu'à publier un changement de clé si la clé de tous les jours est perdue ou volée.
    if (Test-Path -LiteralPath $Secours) { throw "Le fichier $Secours existe déjà : choisis un autre nom (une clé de secours n'est jamais écrasée)." }
    $mdp = Read-NouveauMotDePasse 'de la clé de secours (long, noté sur papier et rangé à part)'
    $p = New-Paire 4096
    Save-Msk $p.Privee $Secours $mdp
    if ((Get-Modulus (Read-Msk $Secours $mdp)) -ne (Get-Modulus $p.Publique)) { Remove-Item -LiteralPath $Secours -Force; throw 'La clé de secours n''a pas pu être relue : rien n''a été ajouté.' }
    $f = Add-ClePublique $p.Publique 'secours'
    "Clé de secours écrite : $Secours. Sa clé publique est dans la liste : $f"
    'Copie ce fichier sur une deuxième clé USB, efface-le de tout disque de ce PC, et range les clés USB hors ligne.'
    'Ensuite : copie le dossier cles-publiques dans chaque appli, puis publie Mindset et les applis (voir le README).'
    return
}

if ($Liste) {
    $ici = if (Test-Path -LiteralPath $privee) { Get-Modulus (Read-Privee) } else { '' }
    $apres = if (Test-Path -LiteralPath $suivante) { Get-Modulus (Read-Privee $suivante) } else { '' }
    $fichiers = @(Get-ChildItem -LiteralPath $cles -Filter '*.xml' -File -ErrorAction SilentlyContinue)
    if (-not $fichiers.Count) { 'La liste est vide : plus rien ne serait accepté.' }
    foreach ($f in $fichiers) {
        $xml = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        try {
            $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($xml)
            $etat = if (-not $rsa.PublicOnly) { 'ERREUR : clé PRIVÉE, à retirer tout de suite' } elseif ($rsa.KeySize -lt 3072) { 'ERREUR : trop courte' } else { "$($rsa.KeySize) bits" }
        } catch { $etat = 'ERREUR : fichier abîmé' } finally { $rsa.Dispose() }
        $m = Get-Modulus $xml
        $role = if ($m -and $m -eq $ici) { ', la clé de ce PC (signe les versions)' } elseif ($m -and $m -eq $apres) { ', la clé suivante (sur ce PC)' } else { '' }
        "  $($f.Name) : $etat$role"
    }
    return
}

if ($Nouvelle) {
    if (Test-Path -LiteralPath $suivante) { throw "Une clé suivante est déjà prête ($suivante). Étape 2 : -Basculer." }
    if (-not (Test-Path -LiteralPath $privee)) { throw 'Pas de clé sur ce PC : crée-la simplement avec .\outils\cle.ps1.' }
    $p = New-Paire 3072
    Save-Privee $p.Privee $suivante
    $f = Add-ClePublique $p.Publique 'principale'
    "Clé suivante prête : $suivante. Sa clé publique est dans la liste : $f"
    'Étape 1 : copie le dossier cles-publiques dans chaque appli, puis publie Mindset et les applis (signées avec la clé actuelle).'
    'Étape 2, quand ces versions sont installées partout (quelques semaines) : .\outils\cle.ps1 -Basculer'
    return
}

if ($Basculer) {
    if (-not (Test-Path -LiteralPath $suivante)) { throw 'Pas de clé suivante sur ce PC : commence par -Nouvelle.' }
    $nouvelleXml = Read-Privee $suivante
    if (-not (Find-ClePublique $nouvelleXml)) { throw 'La clé suivante n''est pas dans la liste : rien n''a changé.' }
    $retiree = ''
    if (Test-Path -LiteralPath $privee) {
        $ancienne = Find-ClePublique (Read-Privee)
        if ($ancienne) { Remove-Item -LiteralPath $ancienne -Force; $retiree = Split-Path $ancienne -Leaf }
    }
    Save-Privee $nouvelleXml
    Remove-Item -LiteralPath $suivante -Force
    'Ce PC signe maintenant avec la nouvelle clé.'
    if ($retiree) { "L'ancienne clé est retirée de la liste ($retiree)." }
    'Copie le dossier cles-publiques dans chaque appli, publie Mindset et les applis, puis refais une copie de secours (-Exporter) : l''ancienne ne sert plus.'
    return
}

if ($Retirer) {
    $nom = Split-Path $Retirer -Leaf
    $f = Join-Path $cles $nom
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "La clé $nom n'est pas dans la liste ($cles)." }
    $restantes = @(Get-ChildItem -LiteralPath $cles -Filter '*.xml' -File | Where-Object { $_.Name -ne $nom })
    if (-not $restantes.Count) { throw 'C''est la dernière clé de la liste : sans clé, plus rien ne serait accepté.' }
    $m = Get-Modulus ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8))
    if ((Test-Path -LiteralPath $privee) -and $m -and $m -eq (Get-Modulus (Read-Privee))) {
        throw 'C''est la clé de ce PC : pour la changer, -Nouvelle puis -Basculer (voir le README).'
    }
    Remove-Item -LiteralPath $f -Force
    "Clé retirée de la liste : $nom"
    'Copie le dossier cles-publiques dans chaque appli, puis publie Mindset et les applis (voir le README).'
    return
}

if (Test-Path -LiteralPath $privee) { throw "Une clé existe déjà ($privee). Pour la changer : -Nouvelle puis -Basculer (voir le README)." }
$p = New-Paire 3072
Save-Privee $p.Privee
$f = Add-ClePublique $p.Publique 'principale'
"Clé créée. Privée : $privee (ne la partage jamais). Publique, ajoutée à la liste : $f"
'Pense à faire une copie de secours : .\outils\cle.ps1 -Exporter <fichier sur une clé USB>'
