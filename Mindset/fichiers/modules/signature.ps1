# Mindset : vérification des signatures des zips (Nevermind, Evermind, Mindset lui-même).
#
# Chaque zip publié est accompagné d'un fichier <zip>.sig : sa signature RSA (SHA-256), faite avec la clé privée
# de Jordan (outils\signer.ps1), qui ne quitte jamais son PC. Mindset vérifie avec la clé publique livrée avec lui
# (fichiers\cle-publique.xml). Un zip sans signature valide n'est jamais installé, même s'il vient bien de GitHub :
# quelqu'un qui volerait l'accès au compte GitHub ne pourrait pas faire installer un faux zip.
#
# Autonome (pas de fenêtre, pas d'autre module) : aussi chargé par installer-admin.ps1, lancé en administrateur.

function Test-Signature([byte[]]$Donnees, [byte[]]$Signature, [string]$ClePublique) {
    if (-not $Donnees -or -not $Signature -or -not (Test-Path -LiteralPath $ClePublique)) { return $false }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString([IO.File]::ReadAllText($ClePublique, [Text.Encoding]::UTF8))
        if ($rsa.KeySize -lt 3072 -or -not $rsa.PublicOnly) { return $false }
        $rsa.VerifyData($Donnees, [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'), $Signature)
    } catch { $false }
    finally { $rsa.Dispose() }
}
