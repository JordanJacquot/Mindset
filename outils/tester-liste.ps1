# Mindset : tests de la liste des applis en ligne (modules\liste.ps1, applis.ps1, paquets.ps1, outils\publier-liste.ps1).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-liste.ps1
#
# Une liste en ligne n'est prise que si tout est bon (signée par une clé livrée, 256 Ko au plus, bien formée, pour ce
# Mindset, numéro plus grand que celui livré et que celui gardé) ; une entrée refusée est ignorée, le reste est pris ; la
# liste gardée est revérifiée à chaque lecture ; sans liste, c'est apps.json livré. Get-Applis et Get-AppliDuDossierZip
# passent par elle, et publier-liste.ps1 la construit, la signe, la vérifie et l'envoie.
#
# Tout se passe dans un dossier temporaire sous %TEMP%, supprimé à la fin : une copie des fichiers de Mindset avec une clé
# de TEST créée ici (la vraie clé privée n'est jamais lue), un faux dossier de données (jamais celui du PC). Aucun réseau
# (toute connexion passe par un relais qui n'existe pas), rien dans le registre, aucun droit administrateur.
# publier-liste.ps1 tourne dans un faux dépôt, avec de faux git et gh : rien n'est commité, envoyé ni publié.
#
# Contre-épreuve : chaque cas est rejoué avec la vérification qu'il couvre retirée (une copie changée de liste.ps1, ou de
# publier-liste.ps1) : il doit alors échouer. Un cas qui passe encore sans elle ne prouve rien.
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub, .github\workflows\tests.yml).

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiersVrais = Join-Path $racine 'Mindset\fichiers'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# Aucun réseau : toute connexion passe par un relais qui n'existe pas (un test qui partirait sur Internet échoue ici)
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)

# ---------------------------------------------------------------------------------------------------------------
# Le petit outil de test (comme tester-securite.ps1), avec la contre-épreuve
# ---------------------------------------------------------------------------------------------------------------
$script:Reussis = 0
$script:Echoues = @()
$script:Cas = New-Object Collections.Generic.List[object]
function Test-Condition([scriptblock]$Condition) {
    try { $r = @(& $Condition) } catch { return $false }
    $r.Count -and $r[-1] -is [bool] -and $r[-1]
}
function Write-Resultat([bool]$Ok, [string]$Nom) {
    if ($Ok) { $script:Reussis++; Write-Host "  OK     $Nom" -ForegroundColor Green }
    else { $script:Echoues += $Nom; Write-Host "  ÉCHEC  $Nom" -ForegroundColor Red }
}
# -Retrait : ce qu'il faut changer pour retirer la vérification couverte (@(@('dans', 'texte', 'devient'), ...) ; 'dans' :
# 'liste' pour modules\liste.ps1, 'publier' pour outils\publier-liste.ps1). Sans -Retrait : un cas sans contre-épreuve.
function Test-Cas([string]$Nom, [scriptblock]$Condition, [object[]]$Retrait = @()) {
    Write-Resultat (Test-Condition $Condition) $Nom
    if ($Retrait.Count) { $script:Cas.Add(@{ Nom = $Nom; Condition = $Condition; Retrait = $Retrait }) }
}
# Vrai si l'action est refusée (une erreur), et si le message contient $Motif quand il est donné
function Test-Refus([scriptblock]$Action, [string]$Motif = '') {
    try { $null = & $Action } catch { return (-not $Motif -or $_.Exception.Message -like "*$Motif*") }
    $false
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

# ---------------------------------------------------------------------------------------------------------------
# Préparation : une copie de Mindset avec une clé de test, un faux dossier de données
# ---------------------------------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "mindset-tests-liste-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = [IO.Path]::GetFullPath($tmp)
$appdataVrai = $env:APPDATA   # (détourné vers $tmp pour publier-liste.ps1, remis à la fin)
$utf8 = New-Object Text.UTF8Encoding $false
$sha256 = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')

function New-CleTest {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 3072
    try { $rsa.PersistKeyInCsp = $false; @{ Privee = $rsa.ToXmlString($true); Publique = $rsa.ToXmlString($false) } }
    finally { $rsa.Dispose() }
}
function Get-SignatureTest([byte[]]$Donnees, [string]$XmlPrivee) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($XmlPrivee); , $rsa.SignData($Donnees, $sha256) }
    finally { $rsa.Dispose() }
}
function New-ZipTest($Entrees) {
    $ms = New-Object IO.MemoryStream
    $za = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($k in $Entrees.Keys) {
            $flux = $za.CreateEntry($k).Open()
            try { $o = $utf8.GetBytes([string]$Entrees[$k]); $flux.Write($o, 0, $o.Length) } finally { $flux.Dispose() }
        }
    } finally { $za.Dispose() }
    , $ms.ToArray()
}

try {
    Write-Host 'Mindset : tests de la liste des applis en ligne' -ForegroundColor Cyan
    Write-Host "Dossier de test : $tmp"

    # La copie de Mindset : apps.json livré (le vrai), son numéro 3, la clé publique de TEST seule, les modules testés
    $mindset = Join-Path $tmp 'Mindset'
    $fichiers = Join-Path $mindset 'fichiers'
    $modules = Join-Path $fichiers 'modules'
    New-Item -ItemType Directory -Force -Path $modules, (Join-Path $fichiers 'cles-publiques') | Out-Null
    foreach ($m in 'signature.ps1', 'paquets.ps1', 'liste.ps1') { Copy-Item -LiteralPath (Join-Path $fichiersVrais "modules\$m") -Destination $modules }
    Copy-Item -LiteralPath (Join-Path $fichiersVrais 'apps.json') -Destination $fichiers
    [IO.File]::WriteAllText((Join-Path $fichiers 'apps-liste.txt'), "3`r`n", $utf8)
    # (la version de ce Mindset, lue dans ses fichiers quand Mindset ne tourne pas : installateur)
    [IO.File]::WriteAllText((Join-Path $fichiers 'Mindset.ps1'), "# Mindset de test`r`n`$AppVersion = '2.16.0'`r`n", $utf8)
    $cle = New-CleTest
    $autreCle = New-CleTest
    [IO.File]::WriteAllText((Join-Path $fichiers 'cles-publiques\test.xml'), $cle.Publique, $utf8)
    # Le faux dossier des données de Mindset, où la liste en ligne est gardée
    $donnees = Join-Path $tmp 'donnees\Mindset'
    $gardee = Join-Path $donnees 'apps-en-ligne.json'

    # Les fonctions testées : signature.ps1, paquets.ps1 (depuis la copie : Get-AppliDuDossierZip lit la liste à côté de
    # son dossier modules) et liste.ps1 (son texte, rechargé tel quel ou changé pour la contre-épreuve)
    . (Join-Path $modules 'signature.ps1')
    . (Join-Path $modules 'paquets.ps1')
    $texteListe = [IO.File]::ReadAllText((Join-Path $modules 'liste.ps1'), [Text.Encoding]::UTF8)
    . ([scriptblock]::Create($texteListe))
    # Get-Applis, Update-ListeEnLigne et Receive-ListeEnLigne lues dans le vrai applis.ps1 (qui fait autre chose à son chargement)
    $astApplis = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $fichiersVrais 'modules\applis.ps1'), [Text.Encoding]::UTF8), [ref]$null, [ref]$null)
    foreach ($n in 'Get-Applis', 'Update-ListeEnLigne', 'Receive-ListeEnLigne') {
        . ([scriptblock]::Create($astApplis.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true).Extent.Text))
    }
    $script:Journal = New-Object Collections.Generic.List[string]
    function Write-Log([string]$Texte) { $script:Journal.Add($Texte) }

    # Les listes de test : les applis livrées, plus une nouvelle (une appli Rust que Mindset ne connaît pas encore)
    $vraies = @([IO.File]::ReadAllText((Join-Path $fichiersVrais 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json | ForEach-Object { $_ })
    $nouvelle = [pscustomobject][ordered]@{ id = 'nouvelle'; type = 'rust'; nom = 'Nouvelle'; couleur = '#12AB34'; description = 'Une appli de test'
        depot = 'JordanJacquot/Nouvelle'; zip = 'Nouvelle.zip'; dossier_zip = 'Nouvelle'; exe = 'Nouvelle.exe'; mutex = 'Local\Nouvelle-Instance' }
    $applisListe = @($vraies) + $nouvelle
    # Les octets d'une liste : -Brut (un texte tel quel), ou l'objet { liste, mindset_min, applis } écrit en JSON
    function New-Liste([long]$Numero = 4, [string]$Min = '2.16.0', $Applis = $applisListe, [string]$Brut = '') {
        $t = if ($Brut) { $Brut } else { ConvertTo-Json -InputObject ([ordered]@{ liste = $Numero; mindset_min = $Min; applis = @($Applis) }) -Depth 6 }
        , $utf8.GetBytes($t)
    }
    function Get-Sig([byte[]]$Json, [string]$Privee = $cle.Privee) { , (Get-SignatureTest $Json $Privee) }
    # Une liste signée proposée à Mindset (comme après un téléchargement), pour un Mindset 2.16.0
    function Add-Liste([byte[]]$Json, $Sig = $null) {
        if ($null -eq $Sig) { $Sig = Get-Sig $Json }
        Add-ListeEnLigne $Json ([byte[]]$Sig) $fichiers $gardee '2.16.0'
    }
    function Get-Liste { Get-EntreesApplis $fichiers $gardee '2.16.0' }
    function Get-Ids($Entrees) { @($Entrees | ForEach-Object { [string]$_.id }) -join ',' }
    function Reset-Gardee { if (Test-Path -LiteralPath $donnees) { Remove-Item -LiteralPath $donnees -Recurse -Force } }
    $idsLivres = Get-Ids $vraies
    $idsListe = Get-Ids $applisListe

    # =============================================================================================================
    Write-Partie 'Une liste en ligne bonne : prise et gardée'
    # =============================================================================================================
    Test-Cas 'bonne liste (n° 4, signée, pour Mindset 2.16.0) : prise, gardée (liste et signature), puis lue avec la nouvelle appli' {
        Reset-Gardee
        $j = New-Liste; $l = Add-Liste $j
        $g = Get-Liste
        $l.Numero -eq 4 -and (Test-Path -LiteralPath $gardee) -and (Test-Path -LiteralPath "$gardee.sig") -and
            $g.Source -eq 'en-ligne' -and $g.Numero -eq 4 -and (Get-Ids $g.Entrees) -eq $idsListe -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($gardee)) -ceq [Convert]::ToBase64String($j)
    } @(, @('liste', '[IO.File]::WriteAllBytes($tmp, [byte[]]$x[1])', '$null = $tmp'))
    Test-Cas 'mindset_min égal à la version de ce Mindset, et marque d''encodage UTF-8 en tête : prise' {
        Reset-Gardee
        $j = [byte[]](@(0xEF, 0xBB, 0xBF) + (New-Liste))
        (Add-Liste $j).Numero -eq 4
    }
    Test-Cas 'sans liste gardée : apps.json livré, avec son numéro (3)' {
        Reset-Gardee
        $g = Get-Liste
        $g.Source -eq 'livree' -and $g.Numero -eq 3 -and (Get-Ids $g.Entrees) -eq $idsLivres
    } @(, @('liste', 'if (-not $Fichier -or -not [IO.File]::Exists($Fichier)) { return $null }', 'if (-not $Fichier) { return $null }; if (-not [IO.File]::Exists($Fichier)) { return @{ Numero = 9; Entrees = @() } }'))

    # =============================================================================================================
    Write-Partie 'Refus : la signature'
    # =============================================================================================================
    $retraitSignature = @(, @('liste', "if (-not (Test-Signature `$Json `$Signature (Join-Path `$DossierFichiers 'cles-publiques'))) { throw 'signature invalide' }", ''))
    Test-Cas 'signée par une autre clé : refusée, rien de gardé' {
        Reset-Gardee
        $j = New-Liste
        (Test-Refus { Add-Liste $j (Get-Sig $j $autreCle.Privee) } 'signature invalide') -and -not (Test-Path -LiteralPath $gardee)
    } $retraitSignature
    Test-Cas 'téléchargée sans signature (.sig absent : vide) : refusée, rien de gardé' {
        Reset-Gardee
        (Test-Refus { Add-Liste (New-Liste) ([byte[]]@()) } 'signature invalide') -and -not (Test-Path -LiteralPath $gardee)
    } $retraitSignature
    Test-Cas 'liste gardée dont le .sig a disparu : refusée à la lecture, apps.json livré pris' {
        Reset-Gardee
        $null = Add-Liste (New-Liste)
        Remove-Item -LiteralPath "$gardee.sig"
        $g = Get-Liste
        $g.Source -eq 'livree' -and (Get-Ids $g.Entrees) -eq $idsLivres
    } @(@('liste', ' -or (New-Object IO.FileInfo "$Fichier.sig").Length -gt 64KB', ''), @('liste', '$sig = [IO.File]::ReadAllBytes("$Fichier.sig")', '$sig = $null'), $retraitSignature[0])
    Test-Cas 'liste gardée modifiée après coup (une couleur changée sur le disque) : refusée à la lecture, apps.json livré pris' {
        Reset-Gardee
        $null = Add-Liste (New-Liste)
        $t = [IO.File]::ReadAllText($gardee, [Text.Encoding]::UTF8).Replace('#12AB34', '#FF0000')
        [IO.File]::WriteAllText($gardee, $t, $utf8)
        $g = Get-Liste
        $g.Source -eq 'livree' -and (Get-Ids $g.Entrees) -eq $idsLivres -and ($script:Journal -join "`n") -match 'gardée refusée \(signature invalide\)'
    } $retraitSignature

    # =============================================================================================================
    Write-Partie 'Refus : le numéro (jamais de retour en arrière)'
    # =============================================================================================================
    $retraitNumero = @(, @('liste', 'if ($numero -le $NumeroMin) { throw "liste n° $numero trop ancienne (il faut un numéro plus grand que $NumeroMin)" }', ''))
    Test-Cas 'même numéro que la liste gardée (n° 4, contenu différent) : pas prise, la liste gardée reste telle quelle' {
        Reset-Gardee
        $j = New-Liste; $null = Add-Liste $j
        $r = Add-Liste (New-Liste 4 '2.16.0' $vraies)
        $null -eq $r -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($gardee)) -ceq [Convert]::ToBase64String($j)
    } @(, @('liste', 'if ($l.Numero -eq $min) { return $null }', ''))
    Test-Cas 'numéro plus petit que celui de la liste gardée (n° 4 après la n° 5) : refusée, la n° 5 reste' {
        Reset-Gardee
        $null = Add-Liste (New-Liste 5)
        (Test-Refus { Add-Liste (New-Liste 4) } 'trop ancienne') -and (Get-Liste).Numero -eq 5
    } $retraitNumero
    Test-Cas 'numéro pas plus grand que celui livré (apps-liste.txt = 3) : la n° 3 laissée de côté, la n° 2 refusée, rien de gardé' {
        Reset-Gardee
        $r = Add-Liste (New-Liste 3)
        $null -eq $r -and (Test-Refus { Add-Liste (New-Liste 2) } 'trop ancienne') -and -not (Test-Path -LiteralPath $gardee)
    } $retraitNumero
    Test-Cas 'liste gardée devenue trop ancienne (Mindset mis à jour, livré avec la n° 10) : refusée à la lecture, apps.json livré pris' {
        Reset-Gardee
        $null = Add-Liste (New-Liste)
        [IO.File]::WriteAllText((Join-Path $fichiers 'apps-liste.txt'), '10', $utf8)
        try { $g = Get-Liste } finally { [IO.File]::WriteAllText((Join-Path $fichiers 'apps-liste.txt'), "3`r`n", $utf8) }
        $g.Source -eq 'livree' -and $g.Numero -eq 10
    } $retraitNumero
    Test-Cas 'numéro livré absent ou illisible (apps-liste.txt) : aucune liste en ligne prise' {
        Reset-Gardee
        [IO.File]::WriteAllText((Join-Path $fichiers 'apps-liste.txt'), 'trois', $utf8)
        try { $refus = Test-Refus { Add-Liste (New-Liste) } 'apps-liste.txt' } finally { [IO.File]::WriteAllText((Join-Path $fichiers 'apps-liste.txt'), "3`r`n", $utf8) }
        $refus -and -not (Test-Path -LiteralPath $gardee)
    } @(, @('liste', "    `$min = Get-NumeroListeLivree `$DossierFichiers`r`n    if (`$min -lt 0) { throw 'numéro de la liste livrée (apps-liste.txt) illisible' }", "    `$min = Get-NumeroListeLivree `$DossierFichiers"))

    # =============================================================================================================
    Write-Partie 'Refus : pour un Mindset plus récent, forme, taille'
    # =============================================================================================================
    Test-Cas 'mindset_min plus récent que ce Mindset (2.17.0 pour un 2.16.0) : refusée (notée comme liste pour un Mindset plus récent)' {
        Reset-Gardee
        (Test-Refus { Add-Liste (New-Liste 4 '2.17.0') } 'pour un Mindset plus récent') -and -not (Test-Path -LiteralPath $gardee)
    } @(, @('liste', '    if ([version]$min -gt $ce) {', '    if ($false) {'))
    Test-Cas 'JSON abîmé (bien signé) : refusée, rien de gardé' {
        Reset-Gardee
        (Test-Refus { Add-Liste (New-Liste -Brut '{ "liste": 5, "mindset_min": "2.16.0", "applis": [ { "id": ') } 'JSON abîmé') -and -not (Test-Path -LiteralPath $gardee)
    } @(, @('liste', "} catch { throw 'liste illisible (JSON abîmé)' }", '} catch { $j = $null }'))
    Test-Cas 'pas un objet JSON (un tableau d''applis seul) : refusée' {
        Reset-Gardee
        Test-Refus { Add-Liste (New-Liste -Brut (ConvertTo-Json -InputObject @($applisListe) -Depth 6)) } 'pas un objet'
    } @(, @('liste', "    if (`$j -isnot [Management.Automation.PSCustomObject]) { throw 'liste illisible (pas un objet JSON)' }`r`n", ''))
    Test-Cas 'champ « Liste » en majuscules (les noms comptent avec leur casse) : refusée' {
        Reset-Gardee
        $t = [Text.Encoding]::UTF8.GetString((New-Liste)).Replace('"liste"', '"Liste"')
        Test-Refus { Add-Liste (New-Liste -Brut $t) } 'champ « liste » absent'
    } @(, @('liste', '$noms -cnotcontains $n', '$noms -notcontains $n'))
    Test-Cas '« liste » qui n''est pas un entier (le texte "5", ou 0) : refusée' {
        Reset-Gardee
        $t = [Text.Encoding]::UTF8.GetString((New-Liste 5)) -replace '"liste":\s*5', '"liste": "5"'
        (Test-Refus { Add-Liste (New-Liste -Brut $t) } 'doit être un entier') -and (Test-Refus { Add-Liste (New-Liste 0) } 'doit être un entier')
    } @(, @('liste', "    if ((`$numero -isnot [int] -and `$numero -isnot [long]) -or `$numero -lt 1) { throw 'liste illisible (« liste » doit être un entier, 1 ou plus)' }", ''))
    Test-Cas 'mindset_min qui n''est pas une version x.y.z (« 2.16 ») : refusée' {
        Reset-Gardee
        Test-Refus { Add-Liste (New-Liste 4 '2.16') } 'version x.y.z'
    } @(, @('liste', "    if (`$min -isnot [string] -or `$min -cnotmatch '^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}\z') { throw 'liste illisible (« mindset_min » doit être une version x.y.z)' }", ''))
    Test-Cas '« applis » vide : refusée (une liste ne vide jamais Mindset)' {
        Reset-Gardee
        Test-Refus { Add-Liste (New-Liste -Brut '{ "liste": 4, "mindset_min": "2.16.0", "applis": [] }') } 'tableau non vide'
    } @(, @('liste', "    if (`$applis -isnot [array] -or -not `$applis.Count) { throw 'liste illisible (« applis » doit être un tableau non vide)' }", ''))
    $gros = [pscustomobject]@{} ; foreach ($p in $nouvelle.PSObject.Properties) { $gros | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    $gros.description = 'x' * 300KB
    Test-Cas 'trop grosse (plus de 256 Ko, bien signée et bien formée) : refusée, rien de gardé' {
        Reset-Gardee
        (Test-Refus { Add-Liste (New-Liste 4 '2.16.0' (@($vraies) + $gros)) } 'trop grosse') -and -not (Test-Path -LiteralPath $gardee)
    } @(, @('liste', 'if (-not $Json -or $Json.Length -gt $TailleMaxListe) {', 'if (-not $Json) {'))
    Test-Cas 'liste gardée trop grosse sur le disque (remplacée par une plus grosse, bien signée) : refusée à la lecture, jamais chargée' {
        Reset-Gardee
        $null = Add-Liste (New-Liste)
        $j = New-Liste 5 '2.16.0' (@($vraies) + $gros)
        [IO.File]::WriteAllBytes($gardee, $j); [IO.File]::WriteAllBytes("$gardee.sig", (Get-Sig $j))
        (Get-Liste).Source -eq 'livree'
    } @(@('liste', '    if ((New-Object IO.FileInfo $Fichier).Length -gt $TailleMaxListe -or ', '    if ('), @('liste', 'if (-not $Json -or $Json.Length -gt $TailleMaxListe) {', 'if (-not $Json) {'))

    # =============================================================================================================
    Write-Partie 'Les entrées : mêmes contrôles que apps.json, une entrée refusée est ignorée'
    # =============================================================================================================
    $mauvaise = [pscustomobject]@{ id = 'Pas Bon!'; nom = 'Piege'; couleur = '#000000'; depot = 'a/b'; zip = 'P.zip'; dossier_zip = 'P'; exe = 'P.exe'; type = 'rust' }
    $piegee = [pscustomobject]@{ id = 'piege'; nom = 'Piege'; couleur = '#000000'; depot = 'a/b'; zip = 'P.zip'; dossier_zip = 'P'; exe = 'P.exe'; script = '..\..\piege.ps1' }
    Test-Cas 'entrées mal formées (id avec espace, script qui sort du dossier, pas un objet) ignorées, la liste et les autres applis sont prises' {
        Reset-Gardee
        $l = Add-Liste (New-Liste 4 '2.16.0' (@($vraies) + $mauvaise + $nouvelle + $piegee + 'texte'))
        $l.Numero -eq 4 -and (Get-Ids $l.Entrees) -eq $idsListe -and (Get-Ids (Get-Liste).Entrees) -eq $idsListe
    } @(, @('liste', "        if (-not `$a) { continue }`r`n        if (-not `$vus.Add", "        if (-not `$vus.Add"))
    Test-Cas 'id en double : la première entrée compte, la seconde est ignorée' {
        Reset-Gardee
        $double = [pscustomobject]@{ id = 'nouvelle'; type = 'rust'; nom = 'Doublon'; couleur = '#000000'; depot = 'a/b'; zip = 'D.zip'; dossier_zip = 'D'; exe = 'D.exe' }
        $l = Add-Liste (New-Liste 4 '2.16.0' ($applisListe + $double))
        (Get-Ids $l.Entrees) -eq $idsListe -and @($l.Entrees | Where-Object { $_.id -eq 'nouvelle' })[0].nom -eq 'Nouvelle'
    } @(, @('liste', '        if (-not $vus.Add($a.Id)) { Write-JournalListe "liste en ligne : appli ignorée ($($a.Id), déjà dans la liste)"; continue }', '        $null = $vus.Add($a.Id)'))
    Test-Cas 'aucune entrée valable : refusée (la liste ne vide jamais Mindset)' {
        Reset-Gardee
        (Test-Refus { Add-Liste (New-Liste 4 '2.16.0' @($mauvaise, $piegee)) } 'aucune appli valable') -and -not (Test-Path -LiteralPath $gardee)
    } @(, @('liste', "    if (-not `$entrees.Count) { throw 'aucune appli valable dans la liste' }", ''))

    # =============================================================================================================
    Write-Partie 'Ce qui lit la liste : Get-Applis (applis.ps1), Get-AppliDuDossierZip et Install-Paquet (paquets.ps1)'
    # =============================================================================================================
    $retraitGardee = @(, @('liste', '    if ($ListeGardee) {', '    if ($false) {'))
    Test-Cas 'Get-Applis : la nouvelle appli de la liste en ligne gardée y apparaît (type rust, nom, couleur), avec les autres' {
        Reset-Gardee
        $null = Add-Liste (New-Liste)
        $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = '2.16.0'
        $a = @(Get-Applis)
        $n = $a | Where-Object Id -eq 'nouvelle'
        $a.Count -eq 4 -and $n.Type -eq 'rust' -and $n.Nom -eq 'Nouvelle' -and $n.Couleur -eq '#12AB34' -and $n.DossierZip -eq 'Nouvelle'
    } $retraitGardee
    Test-Cas 'Get-Applis sans liste gardée : les applis de apps.json livré, sans la nouvelle' {
        Reset-Gardee
        $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = '2.16.0'
        $a = @(Get-Applis)
        $a.Count -eq @($vraies).Count -and -not ($a | Where-Object Id -eq 'nouvelle')
    }
    Test-Cas 'Get-Applis : une liste gardée pour un Mindset plus récent (ce Mindset est en 2.15.0) n''est pas prise' {
        Reset-Gardee
        $null = Add-Liste (New-Liste)
        $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = '2.15.0'
        -not (@(Get-Applis) | Where-Object Id -eq 'nouvelle')
    } @(, @('liste', '    if ([version]$min -gt $ce) {', '    if ($false) {'))
    Test-Cas 'Get-AppliDuDossierZip : trouve la nouvelle appli par le dossier de son zip (version de Mindset donnée, ou lue dans ses fichiers)' {
        Reset-Gardee
        $null = Add-Liste (New-Liste)
        $ListeGardee = $gardee
        $AppVersion = '2.16.0'; $a = Get-AppliDuDossierZip 'Nouvelle'
        $AppVersion = $null; $b = Get-AppliDuDossierZip 'Nouvelle'
        $a -eq 'nouvelle' -and $b -eq 'nouvelle' -and (Get-AppliDuDossierZip 'Evermind') -eq 'evermind'
    } $retraitGardee
    Test-Cas 'Get-AppliDuDossierZip sans liste gardée : ne connaît pas la nouvelle appli, connaît celles de apps.json' {
        Reset-Gardee
        $ListeGardee = $gardee; $AppVersion = '2.16.0'
        (Get-AppliDuDossierZip 'Nouvelle') -eq '' -and (Get-AppliDuDossierZip 'Evermind') -eq 'evermind'
    }
    $zipEvermind = New-ZipTest ([ordered]@{ 'Nouvelle/Nouvelle.exe' = 'x'; 'Nouvelle/Mindset.exe' = 'x'; 'Nouvelle/version.json' = '{ "version": "1.0.0", "appli": "evermind" }' })
    $zipNouvelle = New-ZipTest ([ordered]@{ 'Nouvelle/Nouvelle.exe' = 'x'; 'Nouvelle/Mindset.exe' = 'x'; 'Nouvelle/version.json' = '{ "version": "1.0.0", "appli": "nouvelle" }' })
    Test-Cas 'Install-Paquet sans -Appli (installateur) : le zip de la nouvelle appli qui contient une autre appli est refusé, le bon est installé' {
        Reset-Gardee
        $null = Add-Liste (New-Liste)
        $ListeGardee = $gardee; $AppVersion = '2.16.0'
        $d = Join-Path $tmp "programmes-$([guid]::NewGuid().ToString('N').Substring(0, 6))\Nouvelle"
        $cles = Join-Path $fichiers 'cles-publiques'
        (Test-Refus { Install-Paquet -Zip $zipEvermind -Signature (Get-Sig $zipEvermind) -ClePublique $cles -Destination $d -DossierZip 'Nouvelle' -Exe 'Nouvelle.exe' } 'contient l''appli evermind et pas nouvelle') -and
            -not (Test-Path -LiteralPath $d) -and
            ((Install-Paquet -Zip $zipNouvelle -Signature (Get-Sig $zipNouvelle) -ClePublique $cles -Destination $d -DossierZip 'Nouvelle' -Exe 'Nouvelle.exe') -eq $d)
    } $retraitGardee

    # =============================================================================================================
    Write-Partie 'Le téléchargement dans Mindset (applis.ps1) et l''installateur'
    # =============================================================================================================
    # Un faux Start-Tache (taches.ps1) : le travail tourne ici, tout de suite, SEULEMENT s'il lit un fichier de ce PC ;
    # l'adresse de GitHub n'est jamais essayée (notée, puis réponse « pas de réseau »)
    $script:Taches = New-Object Collections.Generic.List[object]
    function Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) {
        $script:Taches.Add($Parametres.Clone())
        if (-not $Parametres.Fichier) { & $Fin $null 'pas de réseau pendant les tests'; return }
        $r = $null; $e = $null
        try { $r = & $Travail $Parametres } catch { $e = $_.Exception.Message }
        & $Fin $r $e
    }
    $texteApplis = [IO.File]::ReadAllText((Join-Path $fichiersVrais 'modules\applis.ps1'), [Text.Encoding]::UTF8)
    if ($texteApplis -match '(?m)^\$UrlListeEnLigne = "([^"]+)"') { $UrlListeEnLigne = $Matches[1].Replace('$NomListeEnLigne', $NomListeEnLigne) }
    $publiee = Join-Path $tmp 'publiee\apps-en-ligne.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $publiee -Parent) | Out-Null
    $jPubliee = New-Liste 6
    [IO.File]::WriteAllBytes($publiee, $jPubliee); [IO.File]::WriteAllBytes("$publiee.sig", (Get-Sig $jPubliee))
    $envAvant = $env:MINDSET_LISTE_URL
    Test-Cas 'l''adresse de la liste : la version « liste-applis » du dépôt de Mindset, sans l''API' {
        $UrlListeEnLigne -ceq 'https://github.com/JordanJacquot/Mindset/releases/download/liste-applis/apps-en-ligne.json'
    }
    Test-Cas 'en test (MINDSET_LISTE_URL) : lue dans ce fichier, vérifiée, gardée, notée « prise au prochain démarrage »' {
        Reset-Gardee; $script:Taches.Clear(); $script:Journal.Clear()
        $script:DerniereListe = [datetime]::MinValue
        $EnTest = $true; $env:MINDSET_LISTE_URL = $publiee; $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = '2.16.0'
        try { Update-ListeEnLigne } finally { $env:MINDSET_LISTE_URL = $envAvant }
        $script:Taches.Count -eq 1 -and (Get-Liste).Numero -eq 6 -and ($script:Journal -join "`n") -match 'n° 6 gardée \(4 applis\) : elle sera prise au prochain démarrage'
    }
    Test-Cas 'pas plus d''une fois en 6 heures' {
        $script:Taches.Clear()
        $EnTest = $true; $env:MINDSET_LISTE_URL = $publiee; $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = '2.16.0'
        try { Update-ListeEnLigne } finally { $env:MINDSET_LISTE_URL = $envAvant }
        $script:Taches.Count -eq 0
    }
    Test-Cas 'hors test, MINDSET_LISTE_URL est ignorée : l''adresse de GitHub (jamais essayée ici), échec noté, réessai dans une heure' {
        Reset-Gardee; $script:Taches.Clear(); $script:Journal.Clear()
        $script:DerniereListe = [datetime]::MinValue
        $EnTest = $false; $env:MINDSET_LISTE_URL = $publiee; $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = '2.16.0'
        try { Update-ListeEnLigne } finally { $env:MINDSET_LISTE_URL = $envAvant }
        $script:Taches.Count -eq 1 -and $script:Taches[0].Fichier -eq '' -and $script:Taches[0].Url -eq $UrlListeEnLigne -and -not (Test-Path -LiteralPath $gardee) -and
            ($script:Journal -join "`n") -match 'pas téléchargée' -and [math]::Round(((Get-Date) - $script:DerniereListe).TotalHours) -eq 5
    }
    Test-Cas 'liste téléchargée refusée (autre clé) : notée au journal, rien de gardé' {
        Reset-Gardee; $script:Journal.Clear()
        $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = '2.16.0'
        Receive-ListeEnLigne @{ Json = $jPubliee; Sig = (Get-Sig $jPubliee $autreCle.Privee) } $null
        -not (Test-Path -LiteralPath $gardee) -and ($script:Journal -join "`n") -match 'refusée : signature invalide'
    } $retraitSignature
    Test-Cas 'sans dossier de données à part en test : aucune liste lue ni cherchée (jamais celle du vrai PC)' {
        $t = $texteApplis
        ($t -match [regex]::Escape('$ListeGardee = if ($DataDir -and (-not $EnTest -or $env:MINDSET_DONNEES)) { Join-Path $DataDir $NomListeEnLigne } else { '''' }')) -and
            ($t -match [regex]::Escape('if (-not $ListeGardee -or ((Get-Date) - $script:DerniereListe).TotalHours -lt 6) { return }'))
    }
    Test-Cas 'Mindset donne la liste gardée à l''installateur (-Liste), et le relais la lui passe telle quelle' {
        $inst = [IO.File]::ReadAllText((Join-Path $fichiersVrais 'modules\installations.ps1'), [Text.Encoding]::UTF8)
        $relais = [IO.File]::ReadAllText((Join-Path $fichiersVrais 'installer-admin.ps1'), [Text.Encoding]::UTF8)
        ($inst -match [regex]::Escape('if ($ListeGardee -and [IO.File]::Exists($ListeGardee)) { $p.Liste = $ListeGardee }')) -and
            ($relais -match [regex]::Escape('[switch]$Cache, [string]$Liste')) -and ($relais -match [regex]::Escape("'Disque', 'Sid', 'Liste') {"))
    }
    Test-Cas 'la liste en ligne est cherchée avec les nouvelles versions (Invoke-Actualiser), donc jamais si la recherche est coupée' {
        $acc = [IO.File]::ReadAllText((Join-Path $fichiersVrais 'modules\accueil.ps1'), [Text.Encoding]::UTF8)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($acc, [ref]$null, [ref]$null)
        $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Invoke-Actualiser' }, $true).Extent.Text
        $f -match 'Test-VerifVersionsActive' -and $f -match '\bUpdate-ListeEnLigne\b'
    }

    # =============================================================================================================
    Write-Partie 'publier-liste.ps1, dans un faux dépôt (faux git et gh : rien n''est envoyé)'
    # =============================================================================================================
    # Le faux dépôt : les outils de clé et de publication, apps.json (avec la nouvelle appli), son numéro 3, les modules.
    # APPDATA détourné vers le dossier de test : la clé de signature créée par cle.ps1 est une clé de TEST.
    $depot = Join-Path $tmp 'depot'
    $fDepot = Join-Path $depot 'Mindset\fichiers'
    New-Item -ItemType Directory -Force -Path (Join-Path $depot 'outils'), (Join-Path $fDepot 'modules') | Out-Null
    foreach ($o in 'cle.ps1', 'signer.ps1', 'publier-liste.ps1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $o) -Destination (Join-Path $depot 'outils') }
    foreach ($m in 'signature.ps1', 'liste.ps1') { Copy-Item -LiteralPath (Join-Path $fichiersVrais "modules\$m") -Destination (Join-Path $fDepot 'modules') }
    $texteAppsDepot = ConvertTo-Json -InputObject @($applisListe) -Depth 6
    function Reset-Depot([string]$Apps = $texteAppsDepot, [string]$Numero = '3') {
        [IO.File]::WriteAllText((Join-Path $fDepot 'apps.json'), $Apps, $utf8)
        [IO.File]::WriteAllText((Join-Path $fDepot 'apps-liste.txt'), "$Numero`r`n", $utf8)
        Remove-Item -LiteralPath (Join-Path $depot 'release') -Recurse -Force -ErrorAction SilentlyContinue
    }
    Reset-Depot
    $env:APPDATA = Join-Path $tmp 'AppData'
    $mdpTest = ConvertTo-SecureString 'mot de passe de test 123' -AsPlainText -Force
    $mdpFaux = ConvertTo-SecureString 'pas le bon mot de passe' -AsPlainText -Force
    # Garde-fou : jamais un outil de clé ou de publication lancé si APPDATA n'est pas dans le dossier de test
    function Invoke-OutilDepot([string]$Outil, [hashtable]$Params) {
        if (-not $env:APPDATA.StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase)) { throw 'APPDATA n''est pas détourné : test arrêté.' }
        & (Join-Path $depot "outils\$Outil") @Params
    }
    $null = Invoke-OutilDepot 'cle.ps1' @{ MotDePasse = $mdpTest }
    # Les faux git et gh (des fonctions : elles passent devant les vrais programmes) : chaque appel est noté. La version
    # « liste-applis » de GitHub est un dossier du test ; $global:TListePrerelease dit si elle est en préversion.
    $global:TListeAppels = New-Object Collections.Generic.List[string]
    $global:TListePub = Join-Path $tmp 'github-liste-applis'
    $global:TListePrerelease = $true
    function global:git { $global:TListeAppels.Add("git $($args -join ' ')"); $global:LASTEXITCODE = 0 }
    function global:gh {
        $global:TListeAppels.Add("gh $($args -join ' ')")
        $global:LASTEXITCODE = 0
        $a = @($args | ForEach-Object { [string]$_ })
        if ($a[0] -ne 'release' -or $a[2] -ne 'liste-applis') { $global:LASTEXITCODE = 1; return }
        switch ($a[1]) {
            'view' { if (-not (Test-Path -LiteralPath $global:TListePub)) { $global:LASTEXITCODE = 1; return }; if ($global:TListePrerelease) { 'true' } else { 'false' } }
            'create' { New-Item -ItemType Directory -Force -Path $global:TListePub | Out-Null; $global:TListePrerelease = $a -contains '--prerelease' }
            'edit' { if ($a -contains '--prerelease') { $global:TListePrerelease = $true } }
            'upload' { foreach ($f in $a[3..($a.Count - 1)] | Where-Object { $_ -notlike '--*' }) { Copy-Item -LiteralPath $f -Destination $global:TListePub -Force } }
            'download' {
                $d = $a[[array]::IndexOf($a, '-D') + 1]
                $voulus = @(for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -eq '-p') { $a[$i + 1] } })
                foreach ($v in $voulus) { $f = Join-Path $global:TListePub $v; if (-not (Test-Path -LiteralPath $f)) { $global:LASTEXITCODE = 1; return }; Copy-Item -LiteralPath $f -Destination $d -Force }
            }
        }
    }
    function Get-Publiee { Join-Path $depot 'release\apps-en-ligne.json' }
    function Test-AcceptePar([string]$Fichier, [long]$Numero) {
        # (acceptée par Mindset avec les clés du faux dépôt, comme le vrai Mindset le fera avec les vraies)
        try { $l = Read-ListeEnLigne ([IO.File]::ReadAllBytes($Fichier)) ([IO.File]::ReadAllBytes("$Fichier.sig")) $fDepot '2.16.0' ($Numero - 1) } catch { return $false }
        $l.Numero -eq $Numero -and (Get-Ids $l.Entrees) -eq $idsListe
    }
    function Get-NumeroDepot { [IO.File]::ReadAllText((Join-Path $fDepot 'apps-liste.txt')).Trim() }

    Test-Cas 'essai (-Essai) : liste n° 4 construite et signée dans release\, acceptée par Mindset ; rien d''envoyé, apps-liste.txt inchangé' {
        Reset-Depot; $global:TListeAppels.Clear()
        $null = Invoke-OutilDepot 'publier-liste.ps1' @{ Essai = $true; MotDePasse = $mdpTest }
        (Test-AcceptePar (Get-Publiee) 4) -and $global:TListeAppels.Count -eq 0 -and (Get-NumeroDepot) -eq '3'
    }
    Test-Cas 'première publication : n° 4, apps-liste.txt à 4, commit et push de apps.json et apps-liste.txt, version créée en préversion, envoyée puis relue' {
        Reset-Depot; $global:TListeAppels.Clear()
        if (Test-Path -LiteralPath $global:TListePub) { Remove-Item -LiteralPath $global:TListePub -Recurse -Force }
        $null = Invoke-OutilDepot 'publier-liste.ps1' @{ MotDePasse = $mdpTest }
        $a = $global:TListeAppels -join "`n"
        (Test-AcceptePar (Join-Path $global:TListePub 'apps-en-ligne.json') 4) -and (Get-NumeroDepot) -eq '4' -and $global:TListePrerelease -and
            $a -match 'git add -- Mindset/fichiers/apps.json Mindset/fichiers/apps-liste.txt' -and $a -match 'git commit .*-- Mindset/fichiers/apps.json Mindset/fichiers/apps-liste.txt' -and
            $a -match 'git push' -and $a -match 'gh release create liste-applis --prerelease' -and $a -match 'gh release upload liste-applis .* --clobber' -and
            $a -match 'gh release download liste-applis -p apps-en-ligne.json -p apps-en-ligne.json.sig'
    } @(, @('publier', "'release', 'create', `$tag, '--prerelease',", "'release', 'create', `$tag,"))
    Test-Cas 'publication suivante : n° 5 (plus grand que celle en ligne, même si apps-liste.txt est resté à 3), pas de nouvelle version créée' {
        Reset-Depot; $global:TListeAppels.Clear()
        $null = Invoke-OutilDepot 'publier-liste.ps1' @{ MotDePasse = $mdpTest }
        (Test-AcceptePar (Join-Path $global:TListePub 'apps-en-ligne.json') 5) -and (Get-NumeroDepot) -eq '5' -and -not ($global:TListeAppels -match 'release create')
    } @(, @('publier', '$numero = [math]::Max($livre, $enLigne) + 1', '$numero = $livre + 1'))
    Test-Cas 'version « liste-applis » qui n''est plus en préversion : remise en préversion (jamais « la dernière version » de Mindset)' {
        Reset-Depot $texteAppsDepot '5'; $global:TListeAppels.Clear(); $global:TListePrerelease = $false
        $null = Invoke-OutilDepot 'publier-liste.ps1' @{ MotDePasse = $mdpTest }
        $global:TListePrerelease -and ($global:TListeAppels -match 'gh release edit liste-applis --prerelease')
    } @(, @('publier', "    } elseif (`$pre -ne 'true') {", "    } elseif (`$false) {"))
    Test-Cas 'apps.json avec une appli refusée par Mindset : rien de signé ni d''envoyé, apps-liste.txt inchangé' {
        Reset-Depot (ConvertTo-Json -InputObject (@($applisListe) + $mauvaise) -Depth 6); $global:TListeAppels.Clear()
        $refus = Test-Refus { Invoke-OutilDepot 'publier-liste.ps1' @{ MotDePasse = $mdpTest } } 'corrige apps.json'
        $refus -and -not (Test-Path -LiteralPath "$(Get-Publiee).sig") -and -not ($global:TListeAppels -match '^git|upload') -and (Get-NumeroDepot) -eq '3'
    } @(, @('publier', "    throw 'Rien n''a été publié : corrige apps.json (voir ci-dessus).'", "    Write-Host 'corrige apps.json'"))
    Test-Cas 'apps.json avec un logo pas compris (Mindset l''ignorerait) ou un tiret long : rien n''est publié' {
        $logo = [pscustomobject]@{} ; foreach ($p in $nouvelle.PSObject.Properties) { $logo | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        $logo | Add-Member -NotePropertyName logo -NotePropertyValue 'C 1 2 3'
        Reset-Depot (ConvertTo-Json -InputObject (@($vraies) + $logo) -Depth 6); $global:TListeAppels.Clear()
        $r1 = Test-Refus { Invoke-OutilDepot 'publier-liste.ps1' @{ MotDePasse = $mdpTest } } 'corrige apps.json'
        Reset-Depot ($texteAppsDepot.Replace('Une appli de test', "Une appli $([char]0x2014) de test")); $global:TListeAppels.Clear()
        $r2 = Test-Refus { Invoke-OutilDepot 'publier-liste.ps1' @{ MotDePasse = $mdpTest } } 'corrige apps.json'
        $r1 -and $r2 -and -not ($global:TListeAppels -match '^git|upload')
    } @(, @('publier', "    throw 'Rien n''a été publié : corrige apps.json (voir ci-dessus).'", "    Write-Host 'corrige apps.json'"))
    Test-Cas 'mauvais mot de passe : rien de signé ni d''envoyé, apps-liste.txt inchangé' {
        Reset-Depot; $global:TListeAppels.Clear()
        (Test-Refus { Invoke-OutilDepot 'publier-liste.ps1' @{ MotDePasse = $mdpFaux } } 'Mot de passe incorrect') -and -not ($global:TListeAppels -match '^git|upload') -and (Get-NumeroDepot) -eq '3'
    }
    Test-Cas 'liste différente une fois relue sur GitHub : signalé (« relance »)' {
        Reset-Depot; $global:TListeAppels.Clear()
        # (le faux GitHub abîme ce qu'on lui envoie)
        ${function:global:TListeGhVrai} = ${function:global:gh}
        function global:gh { TListeGhVrai @args; if ($args[1] -eq 'upload') { [IO.File]::AppendAllText((Join-Path $global:TListePub 'apps-en-ligne.json'), ' ') } }
        try { $refus = Test-Refus { Invoke-OutilDepot 'publier-liste.ps1' @{ MotDePasse = $mdpTest } } 'pas celle qui vient d''être envoyée' }
        finally { ${function:global:gh} = ${function:global:TListeGhVrai} }
        $refus
    } @(, @('publier', "        throw 'La liste en ligne n''est pas celle qui vient d''être envoyée : relance outils\publier-liste.ps1.'", '        $null = 0'))

    # =============================================================================================================
    Write-Partie 'Contre-épreuve : chaque vérification retirée, le cas qui la couvre doit échouer'
    # =============================================================================================================
    $textePublier = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'publier-liste.ps1'), [Text.Encoding]::UTF8)
    $copiePublier = Join-Path $depot 'outils\publier-liste.ps1'
    foreach ($c in $script:Cas) {
        $tl = $texteListe; $tp = $textePublier; $introuvable = @()
        foreach ($r in $c.Retrait) {
            if ($r[0] -eq 'liste') { if (-not $tl.Contains($r[1])) { $introuvable += $r[1] }; $tl = $tl.Replace($r[1], $r[2]) }
            else { if (-not $tp.Contains($r[1])) { $introuvable += $r[1] }; $tp = $tp.Replace($r[1], $r[2]) }
        }
        $ok = $false
        if (-not $introuvable.Count) {
            . ([scriptblock]::Create($tl))
            [IO.File]::WriteAllText($copiePublier, $tp, (New-Object Text.UTF8Encoding $true))
            $global:TListePrerelease = $true; $script:DerniereListe = [datetime]::MinValue
            try { $ok = -not (Test-Condition $c.Condition) }
            finally {
                . ([scriptblock]::Create($texteListe))
                [IO.File]::WriteAllText($copiePublier, $textePublier, (New-Object Text.UTF8Encoding $true))
            }
        } else { Write-Host "         texte à retirer introuvable : $($introuvable -join ' | ')" -ForegroundColor Yellow }
        Write-Resultat $ok "sans la vérification : « $($c.Nom) » échoue"
    }
} finally {
    $env:APPDATA = $appdataVrai
    Remove-Item -Path function:global:git, function:global:gh, function:global:TListeGhVrai -ErrorAction SilentlyContinue
    Remove-Variable -Name TListeAppels, TListePrerelease, TListePub -Scope Global -ErrorAction SilentlyContinue
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch { Write-Host "Dossier de test non supprimé : $tmp ($($_.Exception.Message))" -ForegroundColor Yellow }
}

$total = $script:Reussis + $script:Echoues.Count
Write-Host ''
if ($script:Echoues.Count) {
    Write-Host "Résultat : $($script:Echoues.Count) échec(s) sur $total cas." -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Résultat : $($script:Reussis) cas réussis sur $total, aucun échec." -ForegroundColor Green
exit 0
