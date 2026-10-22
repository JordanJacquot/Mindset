# Mindset : vérification des signatures des zips (Nevermind, Evermind, Mindcare, Mindset lui-même).
#
# Chaque zip publié est accompagné d'un fichier <zip>.sig : sa signature RSA (SHA-256), faite avec la clé privée
# de Jordan (outils\signer.ps1), qui ne quitte jamais son PC. Mindset vérifie avec les clés publiques livrées avec lui
# (fichiers\cles-publiques\*.xml). Un zip sans signature valide n'est jamais installé, même s'il vient bien de GitHub :
# quelqu'un qui volerait l'accès au compte GitHub ne pourrait pas faire installer un faux zip.
#
# Une liste de clés, et pas une seule : la clé de tous les jours, la clé de secours (gardée hors ligne) et, pendant un
# changement de clé, la suivante. Une signature est bonne si UNE des clés de la liste la vérifie. Une version de Mindset
# peut ajouter ou retirer une clé (voir outils\cle.ps1 et le README).
# La liste est lue en entier avant de vérifier : une liste vide, un fichier abîmé, une clé privée glissée dans la liste
# ou une clé trop courte (moins de 3072 bits), et tout est refusé (une liste anormale n'est jamais à moitié crue).
#
# Autonome (pas de fenêtre, pas d'autre module) : aussi chargé par installer-admin.ps1, lancé en administrateur.
# Les applis ont la même fonction dans leur propre code (Nevermind : mises-a-jour.ps1, Evermind : maj.ps1).

# $ClePublique : le dossier des clés (cles-publiques), ou un seul fichier de clé
function Test-Signature([byte[]]$Donnees, [byte[]]$Signature, [string]$ClePublique) {
    if (-not $Donnees -or -not $Signature -or -not $ClePublique) { return $false }
    if (Test-Path -LiteralPath $ClePublique -PathType Container) {
        $fichiers = @(Get-ChildItem -LiteralPath $ClePublique -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.xml' } | ForEach-Object { $_.FullName })
    } elseif (Test-Path -LiteralPath $ClePublique -PathType Leaf) { $fichiers = @($ClePublique) }
    else { return $false }
    if (-not $fichiers.Count) { return $false }
    $cles = @()
    try {
        foreach ($f in $fichiers) {
            $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
            $cles += $rsa
            $rsa.FromXmlString([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8))
            if ($rsa.KeySize -lt 3072 -or -not $rsa.PublicOnly) { return $false }
        }
        foreach ($rsa in $cles) {
            if ($rsa.VerifyData($Donnees, [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'), $Signature)) { return $true }
        }
        $false
    } catch { $false }
    finally { foreach ($rsa in $cles) { $rsa.Dispose() } }
}
