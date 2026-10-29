# Publie la liste des applis en ligne : une nouvelle appli arrive dans Mindset (2.16 et après) chez tout le monde, sans
# publier de nouvelle version de Mindset.
#
#   .\outils\publier-liste.ps1
#   .\outils\publier-liste.ps1 -MindsetMin 2.17.0     une liste qui demande un Mindset plus récent (les autres l'ignorent)
#   .\outils\publier-liste.ps1 -Essai                 tout sauf l'envoi : ni commit, ni push, rien sur GitHub
#
# 1. part de Mindset\fichiers\apps.json (la liste de référence, que le skill nouvelle-appli complète) ;
# 2. vérifie chaque appli avec les contrôles de Mindset (modules\liste.ps1, ConvertTo-Appli) : au moindre problème, rien
#    n'est publié ;
# 3. son numéro : celui de Mindset\fichiers\apps-liste.txt plus un (et plus grand que celui de la liste déjà en ligne) ;
#    apps-en-ligne.json est construit dans release\ (« mindset_min » : 2.16.0 par défaut) ;
# 4. la signe avec outils\signer.ps1 (ton mot de passe est demandé, il n'est écrit nulle part) ;
# 5. vérifie la signature et la liste comme Mindset le fera (Read-ListeEnLigne) ;
# 6. écrit le numéro dans apps-liste.txt, puis commit et push de apps.json et apps-liste.txt (la prochaine version de
#    Mindset livre ainsi la même liste, avec le même numéro) ;
# 7. sur GitHub : la version « liste-applis », créée en préversion si elle n'existe pas (et remise en préversion si besoin :
#    /releases/latest, qui sert aux mises à jour de Mindset, ne doit jamais la voir), les deux fichiers envoyés
#    (--clobber), puis retéléchargés et revérifiés.
# -MotDePasse (une SecureString, jamais un texte) sert aux tests : sans lui, signer.ps1 le demande.

param([string]$MindsetMin = '2.16.0', [switch]$Essai, [securestring]$MotDePasse)
$ErrorActionPreference = 'Stop'
$racine   = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'
$apps     = Join-Path $fichiers 'apps.json'
$numeroTxt = Join-Path $fichiers 'apps-liste.txt'
$sortie   = Join-Path $racine 'release'
$tag      = 'liste-applis'
. (Join-Path $fichiers 'modules\signature.ps1')
. (Join-Path $fichiers 'modules\liste.ps1')
$liste    = Join-Path $sortie $NomListeEnLigne

if ($MindsetMin -notmatch '^\d+\.\d+\.\d+$') { throw "Version de Mindset invalide : $MindsetMin (exemple : 2.16.0)" }

# Un programme (git, gh) : seul son code de sortie compte (ses avertissements ne sont pas des échecs)
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE) { throw "Échec : $Exe $($Arguments -join ' ')" }
}

# 1 et 2. La liste de référence, vérifiée appli par appli. Ce que les contrôles de Mindset noteraient dans son journal
# (appli ignorée, logo ou page de confidentialité pas acceptés) est ici un problème : rien n'est publié.
$script:Problemes = New-Object Collections.Generic.List[string]
function Write-Log([string]$Texte) { $script:Problemes.Add($Texte) }
$texteApps = [IO.File]::ReadAllText($apps, [Text.Encoding]::UTF8).Trim()
if ($texteApps -match '[\u2013\u2014]') { $script:Problemes.Add('apps.json contient un tiret long : remplace-le par un tiret simple ou une virgule') }
$entrees = $null
try { $entrees = $texteApps | ConvertFrom-Json -ErrorAction Stop } catch { $script:Problemes.Add("apps.json illisible : $($_.Exception.Message)") }
if ($entrees -isnot [array] -or -not $entrees.Count) { $script:Problemes.Add('apps.json doit être un tableau d''applis, avec au moins une appli') }
$ids = @{}
foreach ($e in @($entrees | Where-Object { $_ })) {
    $a = ConvertTo-Appli $e
    if (-not $a) { continue }
    if ($ids.ContainsKey($a.Id)) { $script:Problemes.Add("apps.json : l'appli $($a.Id) est là deux fois") }
    $ids[$a.Id] = $true
}
if ($script:Problemes.Count) {
    $script:Problemes | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw 'Rien n''a été publié : corrige apps.json (voir ci-dessus).'
}
Write-Host "apps.json : $($ids.Count) applis, toutes acceptées par Mindset."

# 3. Son numéro : plus grand que celui livré avec Mindset et que celui de la liste déjà en ligne (s'il y en a une)
$livre = Get-NumeroListeLivree $fichiers
if ($livre -lt 0) { throw 'Mindset\fichiers\apps-liste.txt est absent ou illisible (il doit contenir un nombre).' }
$enLigne = 0
if (-not $Essai) {
    $dl = Join-Path $env:TEMP "mindset-liste-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    try {
        $ErrorActionPreference = 'Continue'   # (« pas de version liste-applis » est une réponse normale la première fois)
        $null = & gh release download $tag -p $NomListeEnLigne -D $dl --clobber 2>&1
        $ok = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = 'Stop'
        if ($ok -and (Test-Path -LiteralPath (Join-Path $dl $NomListeEnLigne))) {
            try { $n = ([IO.File]::ReadAllText((Join-Path $dl $NomListeEnLigne), [Text.Encoding]::UTF8) | ConvertFrom-Json).liste; if ($n -is [int] -or $n -is [long]) { $enLigne = [long]$n } } catch {}
        }
    } finally { $ErrorActionPreference = 'Stop'; Remove-Item -LiteralPath $dl -Recurse -Force -ErrorAction SilentlyContinue }
}
$numero = [math]::Max($livre, $enLigne) + 1
$json = "{`r`n  `"liste`": $numero,`r`n  `"mindset_min`": `"$MindsetMin`",`r`n  `"applis`": $texteApps`r`n}`r`n"
$octets = (New-Object Text.UTF8Encoding $false).GetBytes($json)
if ($octets.Length -gt $TailleMaxListe) { throw "La liste fait $([math]::Round($octets.Length / 1KB)) Ko : Mindset n'en accepte pas plus de $($TailleMaxListe / 1KB) Ko." }
New-Item -ItemType Directory -Force -Path $sortie | Out-Null
Remove-Item -LiteralPath "$liste.sig" -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllBytes($liste, $octets)
Write-Host "Liste n° $numero construite (pour Mindset $MindsetMin ou plus récent)."

# 4. Signée avec la clé de la suite (le mot de passe est demandé par signer.ps1)
$p = @{ Fichier = $liste }
if ($MotDePasse) { $p.MotDePasse = $MotDePasse }
& (Join-Path $PSScriptRoot 'signer.ps1') @p
if (-not (Test-Path -LiteralPath "$liste.sig")) { throw 'Rien n''a été publié : la signature manque.' }

# 5. Vérifiée comme Mindset le fera : signature, forme, numéro, chaque appli
$sig = [IO.File]::ReadAllBytes("$liste.sig")
function Assert-ListeBonne([byte[]]$Json, [byte[]]$Sig, [string]$Debut) {
    $script:Problemes.Clear()
    try { $l = Read-ListeEnLigne $Json $Sig $fichiers $MindsetMin ($numero - 1) }
    catch { throw "$Debut : Mindset refuserait cette liste ($($_.Exception.Message))." }
    if ($l.Numero -ne $numero -or @($l.Entrees).Count -ne $ids.Count -or $script:Problemes.Count) { throw "$Debut : Mindset ne prendrait pas toutes les applis de cette liste." }
}
Assert-ListeBonne $octets $sig 'Rien n''a été publié'
Write-Host 'Signature et liste vérifiées comme Mindset le fera.'

if ($Essai) {
    Write-Host "Essai : rien n'est envoyé. La liste et sa signature sont dans $sortie (apps-liste.txt n'est pas changé)." -ForegroundColor Yellow
    return
}

# 6. Le numéro gardé dans le dépôt, avec apps.json : la prochaine version de Mindset livre la même liste
[IO.File]::WriteAllText($numeroTxt, "$numero`r`n", (New-Object Text.UTF8Encoding $false))
Push-Location $racine
try {
    Invoke-Native git @('add', '--', 'Mindset/fichiers/apps.json', 'Mindset/fichiers/apps-liste.txt') | Out-Null
    Invoke-Native git @('commit', '-q', '-m', "Liste des applis n° $numero", '--', 'Mindset/fichiers/apps.json', 'Mindset/fichiers/apps-liste.txt') | Out-Null
    Invoke-Native git @('push') | Out-Null

    # 7. Sur GitHub, en préversion seulement (jamais « la dernière version » de Mindset)
    $ErrorActionPreference = 'Continue'
    $pre = "$(& gh release view $tag --json isPrerelease -q .isPrerelease 2>$null)".Trim()
    $existe = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    if (-not $existe) {
        Invoke-Native gh @('release', 'create', $tag, '--prerelease', '--title', 'Liste des applis', '--notes', 'La liste des applis de la suite, lue par Mindset (2.16 et après). Ce n''est pas une version de Mindset.') | Out-Null
    } elseif ($pre -ne 'true') {
        Invoke-Native gh @('release', 'edit', $tag, '--prerelease') | Out-Null
    }
    Invoke-Native gh @('release', 'upload', $tag, $liste, "$liste.sig", '--clobber') | Out-Null
} finally { Pop-Location }

# Retéléchargée et revérifiée : c'est ce que Mindset va lire
$dl = Join-Path $env:TEMP "mindset-liste-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $dl | Out-Null
try {
    Invoke-Native gh @('release', 'download', $tag, '-p', $NomListeEnLigne, '-p', "$NomListeEnLigne.sig", '-D', $dl, '--clobber') | Out-Null
    $relu = [IO.File]::ReadAllBytes((Join-Path $dl $NomListeEnLigne)); $reluSig = [IO.File]::ReadAllBytes((Join-Path $dl "$NomListeEnLigne.sig"))
    if ([Convert]::ToBase64String($relu) -cne [Convert]::ToBase64String($octets) -or [Convert]::ToBase64String($reluSig) -cne [Convert]::ToBase64String($sig)) {
        throw 'La liste en ligne n''est pas celle qui vient d''être envoyée : relance outils\publier-liste.ps1.'
    }
    Assert-ListeBonne $relu $reluSig 'La liste relue sur GitHub ne va pas, relance outils\publier-liste.ps1'
} finally { Remove-Item -LiteralPath $dl -Recurse -Force -ErrorAction SilentlyContinue }
"Liste des applis n° $numero publiée : chaque Mindset la télécharge dans les 6 heures, et la prend à son démarrage suivant."
