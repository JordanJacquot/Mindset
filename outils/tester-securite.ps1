# Mindset : tests automatiques des parties sensibles (signature des zips, installation d'un zip, dossiers acceptés).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-securite.ps1
#
# Sans Pester (le PC n'a que Pester 3.4) : un petit Test-Cas qui compte les réussites et les échecs.
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub, .github\workflows\tests.yml).
#
# Tout se passe dans un dossier temporaire sous %TEMP%, supprimé à la fin : rien n'est écrit ailleurs, rien dans le
# registre, aucun droit administrateur, aucun réseau. Les clés de signature sont des clés de test créées à la volée :
# la vraie clé privée de la suite n'est jamais utilisée.

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# Aucun réseau : toute connexion passe par un relais qui n'existe pas (un test qui partirait sur Internet échoue ici)
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)

# ---------------------------------------------------------------------------------------------------------------
# Les fonctions testées, chargées depuis leurs fichiers
# ---------------------------------------------------------------------------------------------------------------
. (Join-Path $fichiers 'modules\signature.ps1')
. (Join-Path $fichiers 'modules\paquets.ps1')

# installer-admin.ps1 exécute du code dès son chargement : on n'en prend que les fonctions voulues (lues par l'analyseur).
# (Sa version PowerShell, gardée pour les tests : le mini-installateur livré est MindsetInstallateur.exe, jugé sur le même
# corpus par « cargo test » ; Mindset\fichiers\installer-admin.ps1 n'est plus qu'un relais vers lui.)
$texte = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'installer-admin-powershell.ps1'), [Text.Encoding]::UTF8)
$erreurs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($texte, [ref]$null, [ref]$erreurs)
if ($erreurs) { throw "installer-admin.ps1 illisible : $($erreurs[0].Message)" }
$voulues = @('Test-DossierMindset')
$defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $voulues }, $true))
if ($defs.Count -ne $voulues.Count) { throw 'installer-admin.ps1 : fonction Test-DossierMindset introuvable.' }
foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }
# (le dossier Program Files, que l'installateur demande à Windows, dans son bloc <dossiers-windows>)
$DossierProgrammes = [Environment]::GetFolderPath('ProgramFiles')

# Remplace la vérification du disque (qui interroge Windows) : on note les lettres demandées ; Z: est refusé
$script:DisquesVerifies = @()
function Assert-DisqueFixe([string]$Lettre) {
    $script:DisquesVerifies += $Lettre.ToUpper()
    if ($Lettre -eq 'Z') { throw "Le disque $($Lettre): n'est pas un disque fixe NTFS." }
}

# ---------------------------------------------------------------------------------------------------------------
# Le petit outil de test
# ---------------------------------------------------------------------------------------------------------------
$script:Reussis = 0
$script:Echoues = @()
$script:Connus = @()
# -Connu <explication> : un défaut déjà connu, signalé (CONNU) sans faire échouer les tests, en attendant sa correction
function Test-Cas([string]$Nom, [scriptblock]$Condition, [string]$Connu = '') {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
        if ($Connu) { Write-Host '         (ce défaut connu semble corrigé : retirer -Connu de ce cas)' -ForegroundColor Yellow }
    } elseif ($Connu) {
        $script:Connus += "$Nom : $Connu"
        Write-Host "  CONNU  $Nom ($Connu)" -ForegroundColor Yellow
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
    }
}
# Vrai si l'action est refusée (une erreur), et si le message contient $Motif quand il est donné
function Test-Refus([scriptblock]$Action, [string]$Motif = '') {
    try { $null = & $Action } catch { return (-not $Motif -or $_.Exception.Message -like "*$Motif*") }
    $false
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

# ---------------------------------------------------------------------------------------------------------------
# Préparation : dossier temporaire, clés de test, zips
# ---------------------------------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "mindset-tests-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
# (en nom long : sur GitHub, TEMP est en nom court « RUNNER~1 », qu'Install-Paquet rend en nom long)
$tmp = [IO.Path]::GetFullPath($tmp)
$appdataVrai = $env:APPDATA   # (détourné vers $tmp pour les tests des outils de clé, remis à la fin)
$sha256 = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')

# Une paire de clés RSA de test (en mémoire seulement), au même format XML que celle de outils\cle.ps1
function New-CleTest([int]$Taille) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider $Taille
    try { $rsa.PersistKeyInCsp = $false; @{ Privee = $rsa.ToXmlString($true); Publique = $rsa.ToXmlString($false) } }
    finally { $rsa.Dispose() }
}
# Signe comme outils\signer.ps1 : RSA, SHA-256, à partir de la clé privée en XML
function Get-SignatureTest([byte[]]$Donnees, [string]$XmlPrivee) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($XmlPrivee); , $rsa.SignData($Donnees, $sha256) }
    finally { $rsa.Dispose() }
}
function Save-Texte([string]$Nom, [string]$Contenu) {
    $f = Join-Path $tmp $Nom
    [IO.File]::WriteAllText($f, $Contenu, (New-Object Text.UTF8Encoding $false))
    $f
}
# Un zip construit en mémoire : $Entrees = [ordered]@{ 'nom/dans/le/zip' = 'contenu' }
function New-ZipTest($Entrees) {
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
# Le zip d'une appli « Appli » de test, dans la version voulue, avec des entrées en plus si besoin
function New-ZipAppli([string]$Version, $EnPlus = $null, [switch]$SansExe) {
    $e = [ordered]@{}
    if (-not $SansExe) { $e['Appli/Appli.exe'] = "programme $Version" }
    $e['Appli/fichiers/Appli.ps1'] = "# Appli de test`r`n`$AppVersion = '$Version'`r`n"
    $e['Appli/fichiers/modules/outil.ps1'] = '# module'
    if ($EnPlus) { foreach ($k in $EnPlus.Keys) { $e[$k] = $EnPlus[$k] } }
    New-ZipTest $e
}

try {
    Write-Host 'Mindset : tests de sécurité' -ForegroundColor Cyan
    Write-Host "Dossier de test : $tmp"
    $cle = New-CleTest 3072
    $autreCle = New-CleTest 3072
    $cleCourte = New-CleTest 2048
    $fPublique = Save-Texte 'cle-publique.xml' $cle.Publique
    $fAutrePublique = Save-Texte 'autre-cle-publique.xml' $autreCle.Publique
    $fPubliqueCourte = Save-Texte 'cle-courte.xml' $cleCourte.Publique
    $fPrivee = Save-Texte 'cle-privee-test.xml' $cle.Privee
    $fIllisible = Save-Texte 'cle-illisible.xml' '<RSAKeyValue><Modulus>pas une clé</Modulus>'

    # =============================================================================================================
    Write-Partie 'Test-Signature (modules\signature.ps1)'
    # =============================================================================================================
    $donnees = [Text.Encoding]::UTF8.GetBytes('Le contenu d''un zip à publier')
    $autres = [Text.Encoding]::UTF8.GetBytes('Un autre fichier')
    $sig = Get-SignatureTest $donnees $cle.Privee
    $modifie = [byte[]]$donnees.Clone(); $modifie[5] = $modifie[5] -bxor 1
    $sigModifiee = [byte[]]$sig.Clone(); $sigModifiee[10] = $sigModifiee[10] -bxor 1

    Test-Cas 'signature valide acceptée' { Test-Signature $donnees $sig $fPublique }
    Test-Cas 'signature d''un autre fichier refusée' { -not (Test-Signature $autres $sig $fPublique) }
    Test-Cas 'fichier modifié d''un octet refusé' { -not (Test-Signature $modifie $sig $fPublique) }
    Test-Cas 'signature modifiée d''un octet refusée' { -not (Test-Signature $donnees $sigModifiee $fPublique) }
    Test-Cas 'signature faite avec une autre clé refusée' { -not (Test-Signature $donnees $sig $fAutrePublique) }
    Test-Cas 'clé trop courte (2048 bits) refusée, même avec une signature juste' {
        $s = Get-SignatureTest $donnees $cleCourte.Privee
        (Test-Signature $donnees $s $fPubliqueCourte) -eq $false
    }
    Test-Cas 'clé privée donnée à la place de la clé publique refusée' { -not (Test-Signature $donnees $sig $fPrivee) }
    Test-Cas 'fichier de clé absent refusé' { -not (Test-Signature $donnees $sig (Join-Path $tmp 'absente.xml')) }
    Test-Cas 'fichier de clé illisible refusé (sans planter)' { -not (Test-Signature $donnees $sig $fIllisible) }
    Test-Cas 'signature vide refusée' { -not (Test-Signature $donnees ([byte[]]@()) $fPublique) }
    Test-Cas 'données vides refusées' { -not (Test-Signature ([byte[]]@()) $sig $fPublique) }
    Test-Cas 'les clés livrées avec Mindset (cles-publiques) sont publiques seulement et font au moins 3072 bits' {
        $livrees = @(Get-ChildItem -LiteralPath (Join-Path $fichiers 'cles-publiques') -File -Force | Where-Object { $_.Extension -eq '.xml' })
        $ok = $livrees.Count -ge 1
        foreach ($f in $livrees) {
            $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
            try { $rsa.FromXmlString([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)); if (-not $rsa.PublicOnly -or $rsa.KeySize -lt 3072) { $ok = $false } }
            catch { $ok = $false } finally { $rsa.Dispose() }
        }
        $ok
    }
    Test-Cas 'plus de clé unique cle-publique.xml à côté de la liste (une seule source de vérité)' { -not (Test-Path -LiteralPath (Join-Path $fichiers 'cle-publique.xml')) }

    # =============================================================================================================
    Write-Partie 'Liste de clés : changement de clé et retrait (issue #3)'
    # =============================================================================================================
    $cleB = New-CleTest 3072
    $sigB = Get-SignatureTest $donnees $cleB.Privee
    # Un dossier de clés de test : $Contenu = [ordered]@{ 'nom.xml' = 'XML' }
    function New-ListeTest([string]$Nom, $Contenu) {
        $d = Join-Path $tmp "listes\$Nom"
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        foreach ($k in $Contenu.Keys) { [IO.File]::WriteAllText((Join-Path $d $k), [string]$Contenu[$k], (New-Object Text.UTF8Encoding $false)) }
        $d
    }
    $listeAB = New-ListeTest 'AB' ([ordered]@{ 'a.xml' = $cle.Publique; 'b.xml' = $cleB.Publique })
    $listeA = New-ListeTest 'A' ([ordered]@{ 'a.xml' = $cle.Publique })

    Test-Cas 'signée avec la clé B, acceptée par un Mindset qui connaît A et B' { Test-Signature $donnees $sigB $listeAB }
    Test-Cas 'signée avec la clé A, toujours acceptée par un Mindset qui connaît A et B' { Test-Signature $donnees $sig $listeAB }
    Test-Cas 'clé B retirée de la liste : sa signature n''est plus acceptée' { -not (Test-Signature $donnees $sigB $listeA) }
    Test-Cas 'clé B retirée : la clé A reste acceptée' { Test-Signature $donnees $sig $listeA }
    Test-Cas 'liste vide : tout refusé' { -not (Test-Signature $donnees $sig (New-ListeTest 'vide' ([ordered]@{}))) }
    Test-Cas 'dossier de clés absent : tout refusé' { -not (Test-Signature $donnees $sig (Join-Path $tmp 'listes\absente')) }
    Test-Cas 'fichier de clé abîmé dans la liste : tout refusé, même une signature juste' {
        -not (Test-Signature $donnees $sig (New-ListeTest 'abimee' ([ordered]@{ 'a.xml' = $cle.Publique; 'b.xml' = '<RSAKeyValue><Modulus>pas une clé</Modulus>' })))
    }
    Test-Cas 'fichier de clé vide dans la liste : tout refusé' {
        -not (Test-Signature $donnees $sig (New-ListeTest 'fichier-vide' ([ordered]@{ 'a.xml' = $cle.Publique; 'b.xml' = '' })))
    }
    Test-Cas 'clé privée glissée dans la liste : tout refusé, même la signature de la clé publique voisine' {
        -not (Test-Signature $donnees $sig (New-ListeTest 'privee' ([ordered]@{ 'a.xml' = $cle.Publique; 'z.xml' = $cleB.Privee })))
    }
    Test-Cas 'clé privée glissée dans la liste : sa propre signature refusée aussi' {
        -not (Test-Signature $donnees $sigB (New-ListeTest 'privee-seule' ([ordered]@{ 'b.xml' = $cleB.Privee })))
    }
    Test-Cas 'clé trop courte (2048 bits) glissée dans la liste : tout refusé' {
        $s = Get-SignatureTest $donnees $cleCourte.Privee
        $l = New-ListeTest 'courte' ([ordered]@{ 'a.xml' = $cle.Publique; 'c.xml' = $cleCourte.Publique })
        -not (Test-Signature $donnees $sig $l) -and -not (Test-Signature $donnees $s $l)
    }
    Test-Cas 'clé privée cachée (fichier caché) dans la liste : tout refusé' {
        $l = New-ListeTest 'cachee' ([ordered]@{ 'a.xml' = $cle.Publique; 'cachee.xml' = $cleB.Privee })
        (Get-Item -LiteralPath (Join-Path $l 'cachee.xml')).Attributes = 'Hidden'
        -not (Test-Signature $donnees $sig $l)
    }
    Test-Cas 'autre fichier que .xml dans le dossier (LISEZMOI.txt, b.xml.ancien) : pas une clé, ignoré' {
        $l = New-ListeTest 'autres' ([ordered]@{ 'a.xml' = $cle.Publique; 'LISEZMOI.txt' = 'texte'; 'b.xml.ancien' = $cleB.Publique })
        (Test-Signature $donnees $sig $l) -and -not (Test-Signature $donnees $sigB $l)
    }
    Test-Cas 'signature d''une autre clé, absente de la liste : refusée' { -not (Test-Signature $donnees (Get-SignatureTest $donnees $autreCle.Privee) $listeAB) }
    Test-Cas 'liste de clés : fichier modifié d''un octet refusé' { -not (Test-Signature $modifie $sigB $listeAB) }
    # Une clé publique n'a aucun élément de clé privée, même vide ou sans P (.NET ne regarde que P), et a toujours
    # Modulus et Exponent : même règle que suite-commun (Rust), comparée par outils\banc-suite-commun.ps1
    $modulus = [regex]::Match($cle.Publique, '<Modulus>[^<]+</Modulus><Exponent>[^<]+</Exponent>').Value
    foreach ($cas in @(
            @{ Nom = 'élément D (sans P)'; Xml = "<RSAKeyValue>$modulus<D>AQAB</D></RSAKeyValue>" },
            @{ Nom = 'élément InverseQ vide'; Xml = "<RSAKeyValue>$modulus<InverseQ/></RSAKeyValue>" },
            @{ Nom = 'élément DQ avec préfixe, dans un sous-élément'; Xml = "<RSAKeyValue>$modulus<X><a:DQ>AQAB</a:DQ></X></RSAKeyValue>" },
            @{ Nom = 'élément D seul, sans Modulus ni Exponent'; Xml = '<RSAKeyValue><D>AQAB</D></RSAKeyValue>' })) {
        $x = $cas.Xml
        Test-Cas "clé « publique » avec $($cas.Nom) : tout refusé, même la signature de la clé voisine" {
            -not (Test-Signature $donnees $sig (New-ListeTest "privee-$([guid]::NewGuid().ToString('N').Substring(0, 6))" ([ordered]@{ 'a.xml' = $cle.Publique; 'b.xml' = $x })))
        }
    }
    Test-Cas 'la même clé, sans élément privé : acceptée (témoin)' { Test-Signature $donnees $sig (New-ListeTest 'temoin-modulus' ([ordered]@{ 'a.xml' = "<RSAKeyValue>$modulus</RSAKeyValue>" })) }

    # =============================================================================================================
    Write-Partie 'Install-Paquet (modules\paquets.ps1)'
    # =============================================================================================================
    $programmes = Join-Path $tmp 'Programmes'
    $dest = Join-Path $programmes 'Appli'
    function Install-Test([byte[]]$Zip, [byte[]]$Signature = $null, [string]$Exe = 'Appli.exe', [string]$FichierCle = $fPublique) {
        if ($null -eq $Signature) { $Signature = Get-SignatureTest $Zip $cle.Privee }
        Install-Paquet -Zip $Zip -Signature $Signature -ClePublique $FichierCle -Destination $dest -DossierZip 'Appli' -Exe $Exe
    }
    # Aucun reste « .nouveau-* » ou « .ancien-* » à côté de l'appli
    function Test-SansReste { -not @(Get-ChildItem -LiteralPath $programmes -Directory | Where-Object { $_.Name -like 'Appli.*' }).Count }
    # Aucun fichier « piege* » nulle part dans le dossier de test
    function Test-SansPiege { -not @(Get-ChildItem -LiteralPath $tmp -Recurse -Force -Filter 'piege*').Count }
    function Get-VersionInstallee { Get-VersionDossier $dest }

    $zip2 = New-ZipAppli '2.0.0'
    Test-Cas 'paquet valide installé' {
        $r = Install-Test $zip2
        ($r -eq $dest) -and (Test-Path -LiteralPath (Join-Path $dest 'Appli.exe')) -and (Test-Path -LiteralPath (Join-Path $dest 'fichiers\modules\outil.ps1')) -and ((Get-VersionInstallee) -eq '2.0.0') -and (Test-SansReste)
    }
    Test-Cas 'signature invalide (autre fichier) refusée, ancienne version intacte' {
        (Test-Refus { Install-Test (New-ZipAppli '2.1.0') (Get-SignatureTest $zip2 $cle.Privee) } 'signature') -and ((Get-VersionInstallee) -eq '2.0.0') -and (Test-SansReste)
    }
    Test-Cas 'zip modifié d''un octet après signature refusé' {
        $z = New-ZipAppli '2.1.0'; $s = Get-SignatureTest $z $cle.Privee
        $z[$z.Length - 3] = $z[$z.Length - 3] -bxor 1
        (Test-Refus { Install-Test $z $s } 'signature') -and ((Get-VersionInstallee) -eq '2.0.0') -and (Test-SansReste)
    }
    Test-Cas 'zip signé avec une autre clé refusé' {
        $z = New-ZipAppli '2.1.0'
        (Test-Refus { Install-Test $z (Get-SignatureTest $z $autreCle.Privee) } 'signature') -and ((Get-VersionInstallee) -eq '2.0.0')
    }
    Test-Cas 'signature vide refusée' { (Test-Refus { Install-Test (New-ZipAppli '2.1.0') ([byte[]]@(0)) } 'signature') -and ((Get-VersionInstallee) -eq '2.0.0') }

    # Chemins piégés dans le zip (zip-slip)
    foreach ($cas in @(
            @{ Nom = 'Appli/../../piege-1.txt'; Ou = 'avant le reste' },
            @{ Nom = 'Appli/sous/../../../piege-2.txt'; Ou = 'avec un sous dossier' },
            @{ Nom = 'Appli\..\..\piege-3.txt'; Ou = 'avec des barres inversées' },
            @{ Nom = 'Appli/..'; Ou = 'le dossier parent lui-même' })) {
        $n = $cas.Nom
        Test-Cas "zip-slip « $n » refusé, rien écrit hors de la destination" {
            $e = [ordered]@{}; $e[$n] = 'piege'
            (Test-Refus { Install-Test (New-ZipAppli '2.1.0' $e) } 'Chemin refusé') -and (Test-SansPiege) -and ((Get-VersionInstallee) -eq '2.0.0') -and (Test-SansReste)
        }
    }
    Test-Cas 'zip-slip placé après les fichiers normaux refusé, rien de gardé' {
        $z = New-ZipTest ([ordered]@{ 'Appli/Appli.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '2.1.0'"; 'Appli/../piege-4.txt' = 'piege' })
        (Test-Refus { Install-Test $z } 'Chemin refusé') -and (Test-SansPiege) -and ((Get-VersionInstallee) -eq '2.0.0') -and (Test-SansReste)
    }
    Test-Cas 'zip-slip vers le dossier déjà installé (Appli/../Appli/x) refusé' {
        $e = [ordered]@{ 'Appli/../Appli/piege-5.txt' = 'piege' }
        (Test-Refus { Install-Test (New-ZipAppli '2.1.0' $e) } 'Chemin refusé') -and (Test-SansPiege)
    }
    Test-Cas 'chemin absolu dans le dossier du zip (Appli/C:\...) refusé' {
        $e = [ordered]@{}; $e["Appli/$tmp\piege-6.txt"] = 'piege'
        (Test-Refus { Install-Test (New-ZipAppli '2.1.0' $e) }) -and (Test-SansPiege) -and ((Get-VersionInstallee) -eq '2.0.0') -and (Test-SansReste)
    }
    Test-Cas 'flux NTFS caché (Appli/Appli.exe:flux) refusé' {
        $e = [ordered]@{ 'Appli/Appli.exe:piege' = 'piege' }
        (Test-Refus { Install-Test (New-ZipAppli '2.1.0' $e) }) -and ((Get-VersionInstallee) -eq '2.0.0') -and (Test-SansReste)
    }
    Test-Cas 'entrées hors du dossier principal (../x, C:\x, \x, Autre/x) ignorées : jamais extraites' {
        $e = [ordered]@{}
        $e['../piege-7.txt'] = 'piege'; $e['..\piege-8.txt'] = 'piege'; $e["$tmp\piege-9.txt"] = 'piege'
        $e['/piege-10.txt'] = 'piege'; $e['Autre/piege-11.txt'] = 'piege'; $e['AppliPiege/piege-12.txt'] = 'piege'
        $null = Install-Test (New-ZipAppli '2.0.1' $e)
        (Test-SansPiege) -and ((Get-VersionInstallee) -eq '2.0.1') -and (Test-SansReste)
    }
    Test-Cas 'exe attendu manquant refusé, ancienne version intacte' {
        (Test-Refus { Install-Test (New-ZipAppli '2.1.0' -SansExe) } 'ne contient pas') -and ((Get-VersionInstallee) -eq '2.0.1') -and (Test-Path -LiteralPath (Join-Path $dest 'Appli.exe')) -and (Test-SansReste)
    }
    Test-Cas 'exe attendu ailleurs que dans le dossier principal refusé' {
        $z = New-ZipTest ([ordered]@{ 'Autre/Appli.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '2.1.0'" })
        (Test-Refus { Install-Test $z } 'ne contient pas') -and ((Get-VersionInstallee) -eq '2.0.1')
    }

    # Versions
    Test-Cas 'rétrogradation (1.9.0 sur 2.0.1) refusée, même signée' {
        (Test-Refus { Install-Test (New-ZipAppli '1.9.0') } 'refusée') -and ((Get-VersionInstallee) -eq '2.0.1') -and (Test-SansReste)
    }
    Test-Cas 'rétrogradation d''un seul chiffre (2.0.0 sur 2.0.1) refusée' {
        (Test-Refus { Install-Test (New-ZipAppli '2.0.0') } 'refusée') -and ((Get-VersionInstallee) -eq '2.0.1')
    }
    Test-Cas 'zip signé sans version lisible (pas de $AppVersion) refusé, version installée intacte' {
        $z = New-ZipTest ([ordered]@{ 'Appli/Appli.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = '# pas de version ici' })
        (Test-Refus { Install-Test $z } 'quelle version') -and ((Get-VersionInstallee) -eq '2.0.1') -and (Test-SansReste)
    }
    Test-Cas 'zip signé sans version lisible refusé aussi en première installation (rien de créé)' {
        $dest4 = Join-Path $tmp 'SansVersion\Appli'
        $z = New-ZipTest ([ordered]@{ 'Appli/Appli.exe' = 'x'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = 'deux'" })
        (Test-Refus { Install-Paquet -Zip $z -Signature (Get-SignatureTest $z $cle.Privee) -ClePublique $fPublique -Destination $dest4 -DossierZip 'Appli' -Exe 'Appli.exe' } 'quelle version') -and -not (Test-Path -LiteralPath $dest4)
    }
    Test-Cas 'même version (2.0.1) acceptée (réinstallation)' {
        $null = Install-Test (New-ZipAppli '2.0.1' ([ordered]@{ 'Appli/reinstalle.txt' = 'oui' }))
        ((Get-VersionInstallee) -eq '2.0.1') -and (Test-Path -LiteralPath (Join-Path $dest 'reinstalle.txt')) -and (Test-SansReste)
    }
    Test-Cas 'version plus récente (2.1.0) acceptée, anciens fichiers retirés' {
        $null = Install-Test (New-ZipAppli '2.1.0')
        ((Get-VersionInstallee) -eq '2.1.0') -and -not (Test-Path -LiteralPath (Join-Path $dest 'reinstalle.txt')) -and (Test-SansReste)
    }

    # Échange des dossiers
    Test-Cas 'restes d''une installation interrompue (.nouveau-*, .ancien-*) nettoyés' {
        New-Item -ItemType Directory -Force -Path "$dest.nouveau-deadbeef\fichiers", "$dest.ancien-deadbeef" | Out-Null
        $null = Install-Test (New-ZipAppli '2.1.1')
        ((Get-VersionInstallee) -eq '2.1.1') -and (Test-SansReste)
    }
    # Appli ouverte : son programme est verrouillé. « Aide.txt » est rangé avant « Appli.exe » dans l'ordre alphabétique.
    $null = Install-Test (New-ZipAppli '2.1.1' ([ordered]@{ 'Appli/Aide.txt' = 'aide' }))
    $verrou = [IO.File]::Open((Join-Path $dest 'Appli.exe'), 'Open', 'Read', 'Read')
    try { $refusVerrou = Test-Refus { Install-Test (New-ZipAppli '2.2.0') } 'encore ouverte' }
    finally { $verrou.Dispose() }
    Test-Cas 'appli encore ouverte (fichier verrouillé) : refus clair' { $refusVerrou }
    Test-Cas 'appli encore ouverte : la version installée reste complète' {
        ((Get-VersionInstallee) -eq '2.1.1') -and (Test-Path -LiteralPath (Join-Path $dest 'Aide.txt')) -and (Test-Path -LiteralPath (Join-Path $dest 'Appli.exe'))
    }
    Test-Cas 'après fermeture de l''appli, la mise à jour passe' {
        $null = Install-Test (New-ZipAppli '2.2.0')
        ((Get-VersionInstallee) -eq '2.2.0') -and (Test-SansReste)
    }
    Test-Cas 'première installation (aucun dossier existant) avec dossier parent créé' {
        $dest2 = Join-Path $tmp 'Neuf\Programmes\Appli'
        $z = New-ZipAppli '1.0.0'
        $r = Install-Paquet -Zip $z -Signature (Get-SignatureTest $z $cle.Privee) -ClePublique $fPublique -Destination "$dest2\" -DossierZip 'Appli\' -Exe 'Appli.exe'
        ($r -eq $dest2) -and ((Get-VersionDossier $dest2) -eq '1.0.0')
    }

    # Zips abîmés ou chiffrés (.NET les installait tels quels ; suite-commun, en Rust, les refuse : outils\banc-suite-commun.ps1)
    # Change, dans l'en-tête local et dans le répertoire central, les drapeaux, la taille annoncée ou le CRC d'une entrée
    function Edit-EntreeZip([byte[]]$Zip, [string]$Nom, [int]$Drapeaux = -1, [long]$Taille = -1, [long]$Crc = -1) {
        $z = [byte[]]$Zip.Clone(); $n = [Text.Encoding]::UTF8.GetBytes($Nom)
        # (local PK 0x04034b50 : drapeaux +6, taille +22, longueur du nom +26, nom +30 ; central PK 0x02014b50 : +8, +24, +28, +46)
        foreach ($t in @(@{ Sig = 0x04034b50; Drap = 6; Taille = 22; Long = 26; Nom = 30 }, @{ Sig = 0x02014b50; Drap = 8; Taille = 24; Long = 28; Nom = 46 })) {
            for ($i = 0; $i -le $z.Length - $t.Nom; $i++) {
                if ([BitConverter]::ToUInt32($z, $i) -ne $t.Sig -or [BitConverter]::ToUInt16($z, $i + $t.Long) -ne $n.Length -or $i + $t.Nom + $n.Length -gt $z.Length) { continue }
                if ([Text.Encoding]::UTF8.GetString($z, $i + $t.Nom, $n.Length) -cne $Nom) { continue }
                if ($Drapeaux -ge 0) { [Array]::Copy([BitConverter]::GetBytes([uint16]$Drapeaux), 0, $z, $i + $t.Drap, 2) }
                if ($Taille -ge 0) { [Array]::Copy([BitConverter]::GetBytes([uint32]$Taille), 0, $z, $i + $t.Taille, 4) }
                # (le CRC est 8 octets avant la taille non compressée)
                if ($Crc -ge 0) { [Array]::Copy([BitConverter]::GetBytes([uint32]$Crc), 0, $z, $i + $t.Taille - 8, 4) }
            }
        }
        , $z
    }
    $versionAvant = Get-VersionInstallee
    $gros = [ordered]@{ 'Appli/gros.txt' = ('abcdefghij' * 500) }
    Test-Cas 'entrée marquée chiffrée refusée, version installée intacte' {
        (Test-Refus { Install-Test (Edit-EntreeZip (New-ZipAppli '9.0.0') 'Appli/fichiers/modules/outil.ps1' -Drapeaux 1) } 'chiffré') -and ((Get-VersionInstallee) -eq $versionAvant) -and (Test-SansReste)
    }
    Test-Cas 'version.json de la racine marqué chiffré refusé' {
        $z = New-ZipAppli '9.0.0' ([ordered]@{ 'version.json' = '{ "version": "9.0.0" }' })
        (Test-Refus { Install-Test (Edit-EntreeZip $z 'version.json' -Drapeaux 1) } 'chiffré') -and ((Get-VersionInstallee) -eq $versionAvant) -and (Test-SansReste)
    }
    Test-Cas 'entrée chiffrée hors du dossier principal : ignorée comme les autres' {
        $z = Edit-EntreeZip (New-ZipAppli $versionAvant ([ordered]@{ 'Autre/chiffre.txt' = 'x' })) 'Autre/chiffre.txt' -Drapeaux 1
        ((Install-Test $z) -eq $dest) -and (Test-SansReste)
    }
    Test-Cas 'deflate qui donne plus que la taille annoncée refusé' {
        (Test-Refus { Install-Test (Edit-EntreeZip (New-ZipAppli '9.0.0' $gros) 'Appli/gros.txt' -Taille 100) } 'abîmé') -and ((Get-VersionInstallee) -eq $versionAvant) -and (Test-SansReste)
    }
    Test-Cas 'deflate abîmé (.NET n''en tirait rien, sans erreur) refusé' {
        $z = New-ZipAppli '9.0.0' $gros; $z[60] = $z[60] -bxor 0xFF
        (Test-Refus { Install-Test $z } 'abîmé') -and ((Get-VersionInstallee) -eq $versionAvant) -and (Test-SansReste)
    }
    Test-Cas 'deflate qui donne moins que la taille annoncée refusé (même avec le bon CRC)' {
        (Test-Refus { Install-Test (Edit-EntreeZip (New-ZipAppli '9.0.0' $gros) 'Appli/gros.txt' -Taille 10000) } 'abîmé') -and ((Get-VersionInstallee) -eq $versionAvant) -and (Test-SansReste)
    }
    Test-Cas 'CRC faux (bonne taille) refusé' {
        (Test-Refus { Install-Test (Edit-EntreeZip (New-ZipAppli '9.0.0' $gros) 'Appli/gros.txt' -Crc 12345) } 'abîmé') -and ((Get-VersionInstallee) -eq $versionAvant) -and (Test-SansReste)
    }
    Test-Cas 'zip intact, avec les mêmes contrôles : installé, contenu juste (témoin)' {
        $null = Install-Test (New-ZipAppli $versionAvant $gros)
        ([IO.File]::ReadAllText((Join-Path $dest 'gros.txt')) -ceq ('abcdefghij' * 500)) -and (Test-SansReste)
    }

    # Le nouveau dossier ne peut pas prendre sa place : un programme (comme un antivirus) garde un de ses fichiers ouvert,
    # ce qui empêche de renommer le dossier mais pas de l'effacer. Un fil à part attend que « Appli.exe » soit extrait
    # dans « Appli.nouveau-* » et l'ouvre ; les 300 fichiers extraits après lui laissent le temps de le prendre.
    Add-Type -TypeDefinition @'
public static class BloqueurTest {
    static System.Threading.Thread fil;
    static volatile bool fin;
    static System.IO.FileStream ouvert;
    public static volatile bool Pris;
    public static void Demarrer(string parent, string prefixe, string fichier) {
        Arreter(); fin = false; Pris = false;
        fil = new System.Threading.Thread(() => {
            var limite = System.DateTime.Now.AddSeconds(60);
            while (!fin && ouvert == null && System.DateTime.Now < limite) {
                try {
                    foreach (var d in System.IO.Directory.GetDirectories(parent, prefixe + "*")) {
                        try { ouvert = new System.IO.FileStream(System.IO.Path.Combine(d, fichier), System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete); Pris = true; break; } catch { }
                    }
                } catch { }
                System.Threading.Thread.Sleep(2);
            }
        });
        fil.IsBackground = true; fil.Start();
    }
    public static void Arreter() {
        fin = true;
        if (fil != null) { fil.Join(5000); fil = null; }
        if (ouvert != null) { ouvert.Dispose(); ouvert = null; }
    }
}
'@
    $remplissage = [ordered]@{}
    for ($i = 1; $i -le 300; $i++) { $remplissage["Appli/remplissage/fichier-$i.txt"] = "$i" }
    function Get-Empreintes([string]$Dossier) {
        @(Get-ChildItem -LiteralPath $Dossier -Recurse -File -Force | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($Dossier.Length))=$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join '|'
    }

    $avant = Get-Empreintes $dest
    [BloqueurTest]::Demarrer($programmes, 'Appli.nouveau-', 'Appli.exe')
    try { $refusMiseEnPlace = Test-Refus { Install-Test (New-ZipAppli '2.3.0' $remplissage) } 'La nouvelle version n''a pas pu être mise en place (fichiers bloqués) : réessaie dans un moment.' }
    finally { $prisMaj = [BloqueurTest]::Pris; [BloqueurTest]::Arreter() }
    Test-Cas 'mise à jour qui ne peut pas prendre la place de l''ancienne : refus clair' { $prisMaj -and $refusMiseEnPlace }
    Test-Cas 'l''ancienne version est remise, intacte et complète, sans reste à côté' {
        $prisMaj -and ((Get-VersionInstallee) -eq '2.2.0') -and ((Get-Empreintes $dest) -eq $avant) -and $avant -and (Test-SansReste)
    }
    Test-Cas 'ensuite, la mise à jour passe' {
        $null = Install-Test (New-ZipAppli '2.3.0')
        ((Get-VersionInstallee) -eq '2.3.0') -and (Test-SansReste)
    }

    $programmes3 = Join-Path $tmp 'Neuf3\Programmes'
    $dest3 = Join-Path $programmes3 'Appli'
    [BloqueurTest]::Demarrer($programmes3, 'Appli.nouveau-', 'Appli.exe')
    try {
        $z = New-ZipAppli '1.0.0' $remplissage
        $refusNeuf = Test-Refus { Install-Paquet -Zip $z -Signature (Get-SignatureTest $z $cle.Privee) -ClePublique $fPublique -Destination $dest3 -DossierZip 'Appli' -Exe 'Appli.exe' } 'L''appli n''a pas pu être mise en place (fichiers bloqués) : réessaie dans un moment.'
    } finally { $prisNeuf = [BloqueurTest]::Pris; [BloqueurTest]::Arreter() }
    Test-Cas 'première installation qui ne peut pas être mise en place : refus clair' { $prisNeuf -and $refusNeuf }
    Test-Cas 'première installation refusée : aucun reste (ni l''appli, ni dossier temporaire)' {
        $prisNeuf -and -not (Test-Path -LiteralPath $dest3) -and -not @(Get-ChildItem -LiteralPath $programmes3 -Force).Count
    }

    # Changement de clé de bout en bout : chaque version livre sa liste (fichiers\cles-publiques), et c'est la liste de
    # la version installée qui décide de la suivante. A = clé de tous les jours, S = clé de secours, B puis C = suivantes.
    $cleS = New-CleTest 3072
    $destR = Join-Path $tmp 'Rotation\Appli'
    $listeR = Join-Path $destR 'fichiers\cles-publiques'
    function New-ZipListe([string]$Version, $Cles) {
        $e = [ordered]@{}
        foreach ($k in $Cles.Keys) { $e["Appli/fichiers/cles-publiques/$k.xml"] = $Cles[$k].Publique }
        New-ZipAppli $Version $e
    }
    function Install-Rotation([byte[]]$Zip, $CleSignature, [string]$Liste = $listeR) {
        Install-Paquet -Zip $Zip -Signature (Get-SignatureTest $Zip $CleSignature.Privee) -ClePublique $Liste -Destination $destR -DossierZip 'Appli' -Exe 'Appli.exe'
    }
    $listeAS = New-ListeTest 'AS' ([ordered]@{ 'a.xml' = $cle.Publique; 's.xml' = $cleS.Publique })
    Test-Cas 'rotation : première installation (signée A, liste A + S) avec la liste du dossier' {
        $null = Install-Rotation (New-ZipListe '1.0.0' ([ordered]@{ a = $cle; s = $cleS })) $cle $listeAS
        ((Get-VersionDossier $destR) -eq '1.0.0') -and @(Get-ChildItem -LiteralPath $listeR -Filter '*.xml').Count -eq 2
    }
    Test-Cas 'rotation : signée avec B avant que B soit dans la liste installée, refusée' {
        (Test-Refus { Install-Rotation (New-ZipListe '1.1.0' ([ordered]@{ a = $cle; b = $cleB; s = $cleS })) $cleB } 'signature') -and ((Get-VersionDossier $destR) -eq '1.0.0')
    }
    Test-Cas 'rotation, étape 1 : version signée A qui ajoute B, acceptée' {
        $null = Install-Rotation (New-ZipListe '1.1.0' ([ordered]@{ a = $cle; b = $cleB; s = $cleS })) $cle
        (Get-VersionDossier $destR) -eq '1.1.0'
    }
    Test-Cas 'rotation, étape 2 : version signée B qui retire A, acceptée' {
        $null = Install-Rotation (New-ZipListe '1.2.0' ([ordered]@{ b = $cleB; s = $cleS })) $cleB
        ((Get-VersionDossier $destR) -eq '1.2.0') -and -not (Test-Path -LiteralPath (Join-Path $listeR 'a.xml'))
    }
    Test-Cas 'rotation : l''ancienne clé A, retirée, n''est plus acceptée' {
        (Test-Refus { Install-Rotation (New-ZipListe '1.3.0' ([ordered]@{ a = $cle; s = $cleS })) $cle } 'signature') -and ((Get-VersionDossier $destR) -eq '1.2.0')
    }
    Test-Cas 'révocation avec la clé de secours : version signée S qui retire B et ajoute C, acceptée' {
        $cleC = New-CleTest 3072
        $script:CleC = $cleC
        $null = Install-Rotation (New-ZipListe '1.3.0' ([ordered]@{ c = $cleC; s = $cleS })) $cleS
        (Get-VersionDossier $destR) -eq '1.3.0'
    }
    Test-Cas 'révocation : la clé B, retirée (volée), n''est plus acceptée' {
        (Test-Refus { Install-Rotation (New-ZipListe '9.9.9' ([ordered]@{ b = $cleB })) $cleB } 'signature') -and ((Get-VersionDossier $destR) -eq '1.3.0')
    }
    Test-Cas 'révocation : la nouvelle clé C est acceptée' {
        $null = Install-Rotation (New-ZipListe '1.4.0' ([ordered]@{ c = $script:CleC; s = $cleS })) $script:CleC
        (Get-VersionDossier $destR) -eq '1.4.0'
    }

    # Le reste de paquets.ps1 qui protège quelque chose
    Test-Cas 'téléchargement refusé hors de GitHub (sans aller sur Internet)' {
        $ok = $true
        foreach ($u in 'http://github.com/a/b.zip', 'https://exemple.com/b.zip', 'https://github.com.exemple.com/b.zip',
                       'https://github.com@exemple.com/b.zip', 'https://exemple.com/https://github.com/b.zip', 'file:///C:/Windows/win.ini', '') {
            if (-not (Test-Refus { Get-Octets $u } 'Adresse de téléchargement refusée')) { $ok = $false; Write-Host "    accepté : $u" }
        }
        $ok
    }

    # Get-Octets face à un faux serveur, sur ce PC seulement (localhost, port choisi par Windows) : plafond de taille,
    # délai global, redirections revérifiées. Pour ces cas seulement, l'adresse acceptée est celle du faux serveur.
    $ecoute = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $ecoute.Start()
    $port = $ecoute.LocalEndpoint.Port
    $serveur = [PowerShell]::Create()
    $null = $serveur.AddScript({
        param($Ecoute, $Port)
        while ($true) {
            try { $client = $Ecoute.AcceptTcpClient() } catch { return }
            try {
                $flux = $client.GetStream(); $lire = New-Object IO.StreamReader($flux, [Text.Encoding]::ASCII, $false, 1024, $true)
                $chemin = ($lire.ReadLine() -split ' ')[1]
                while ($lire.ReadLine()) {}
                function Send-Texte([string]$T) { $o = [Text.Encoding]::ASCII.GetBytes($T); $flux.Write($o, 0, $o.Length); $flux.Flush() }
                $corps = 'x' * 3000
                switch ($chemin) {
                    '/ok'      { Send-Texte "HTTP/1.1 200 OK`r`nContent-Length: 7`r`nConnection: close`r`n`r`nbonjour" }
                    '/gros'    { Send-Texte "HTTP/1.1 200 OK`r`nContent-Length: 3000`r`nConnection: close`r`n`r`n$corps" }
                    '/sanslong' { Send-Texte "HTTP/1.1 200 OK`r`nConnection: close`r`n`r`n$corps" }
                    '/lent'    { Send-Texte "HTTP/1.1 200 OK`r`nContent-Length: 20`r`nConnection: close`r`n`r`n"; for ($i = 0; $i -lt 20; $i++) { Send-Texte 'x'; Start-Sleep -Milliseconds 250 } }
                    '/saut'    { Send-Texte "HTTP/1.1 302 Found`r`nLocation: http://localhost:$Port/ok`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" }
                    '/relatif' { Send-Texte "HTTP/1.1 301 Moved`r`nLocation: /ok`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" }
                    '/dehors'  { Send-Texte "HTTP/1.1 302 Found`r`nLocation: https://exemple.com/piege.zip`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" }
                    '/boucle'  { Send-Texte "HTTP/1.1 302 Found`r`nLocation: /boucle`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" }
                    default    { Send-Texte "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" }
                }
            } catch {} finally { $client.Close() }
        }
    }).AddArgument($ecoute).AddArgument($port)
    $null = $serveur.BeginInvoke()
    $proxyAvant = [Net.WebRequest]::DefaultWebProxy; [Net.WebRequest]::DefaultWebProxy = $null
    $local = "http://localhost:$port"
    $adresseVraie = ${function:Test-AdresseTelechargement}
    function Test-AdresseTelechargement([string]$Url) { $Url -match "^http://localhost:$port/" }
    try {
        Test-Cas 'faux serveur : un petit fichier est bien téléchargé (le faux marche)' { [Text.Encoding]::ASCII.GetString((Get-Octets "$local/ok")) -eq 'bonjour' }
        Test-Cas 'téléchargement : une redirection vers une adresse acceptée est suivie (complète ou relative)' {
            $p = @{ Recu = 0; Total = 0 }
            ([Text.Encoding]::ASCII.GetString((Get-Octets "$local/saut" $p)) -eq 'bonjour') -and $p.Recu -eq 7 -and ([Text.Encoding]::ASCII.GetString((Get-Octets "$local/relatif")) -eq 'bonjour')
        }
        Test-Cas 'téléchargement : une redirection vers une adresse hors de GitHub est refusée (revérifiée à chaque saut)' { Test-Refus { Get-Octets "$local/dehors" } 'Adresse de téléchargement refusée : https://exemple.com/piege.zip' }
        Test-Cas 'téléchargement : une redirection sans fin s''arrête' { Test-Refus { Get-Octets "$local/boucle" } 'adresse en adresse' }
        Test-Cas 'téléchargement : un fichier annoncé plus gros que le plafond est refusé (avec ou sans barre de progression)' {
            (Test-Refus { Get-Octets "$local/gros" -MaxOctets 1000 } 'trop gros') -and (Test-Refus { Get-Octets "$local/gros" @{ Recu = 0; Total = 0 } -MaxOctets 1000 } 'trop gros') -and
                (Get-Octets "$local/gros" -MaxOctets 3000).Length -eq 3000
        }
        Test-Cas 'téléchargement : sans taille annoncée, il s''arrête dès que le plafond est dépassé' { Test-Refus { Get-Octets "$local/sanslong" -MaxOctets 1000 } 'trop gros' }
        Test-Cas 'téléchargement : un serveur qui traîne est abandonné après le délai global (pas après chaque morceau)' {
            $debut = Get-Date
            $refus = Test-Refus { Get-Octets "$local/lent" -DelaiSecondes 1 } 'pris plus de'
            $refus -and ((Get-Date) - $debut).TotalSeconds -lt 4
        }
        Test-Cas 'le plafond par défaut est de 200 Mo, et le délai global de 10 minutes' {
            $d = @{}; foreach ($x in @((Get-Command Get-Octets).ScriptBlock.Ast.Parameters)) { if ($x.DefaultValue) { $d[$x.Name.VariablePath.UserPath] = $x.DefaultValue.SafeGetValue() } }
            $d['MaxOctets'] -eq 200MB -and $d['DelaiSecondes'] -eq 600
        }
    } finally {
        Set-Item -Path function:Test-AdresseTelechargement -Value $adresseVraie
        [Net.WebRequest]::DefaultWebProxy = $proxyAvant
        $ecoute.Stop(); $serveur.Dispose()
    }
    Test-Cas 'téléchargement : l''adresse de GitHub est de nouveau la seule acceptée après ces cas' { -not (Test-AdresseTelechargement "$local/ok") -and (Test-AdresseTelechargement 'https://github.com/a/b.zip') }
    Test-Cas 'comparaison de versions : illisible = pas plus récente' {
        (Test-VersionPlusRecente '2.0.1' '2.0.0') -and -not (Test-VersionPlusRecente '2.0.0' '2.0.0') -and
        -not (Test-VersionPlusRecente 'abc' '1.0.0') -and -not (Test-VersionPlusRecente '' '1.0.0') -and -not (Test-VersionPlusRecente '1.0.0' '1.0.1')
    }

    # =============================================================================================================
    Write-Partie 'Contrat d''une appli : version.json dans le zip (paquets.ps1, docs\contrat-appli.md partie 10)'
    # =============================================================================================================
    # Un zip construit en mémoire, dont les contenus sont des textes (UTF-8) ou des octets
    function New-ZipOctets($Entrees) {
        $ms = New-Object IO.MemoryStream
        $za = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($k in $Entrees.Keys) {
                $flux = $za.CreateEntry($k).Open()
                # (pas de « $o = if ... » : un tableau vide y deviendrait $null)
                if ($Entrees[$k] -is [byte[]]) { [byte[]]$o = $Entrees[$k] } else { [byte[]]$o = [Text.Encoding]::UTF8.GetBytes([string]$Entrees[$k]) }
                try { $flux.Write($o, 0, $o.Length) } finally { $flux.Dispose() }
            }
        } finally { $za.Dispose() }
        , $ms.ToArray()
    }
    # Le zip d'une appli Rust de test (pas de script) : Appli.exe (son relais), Mindset.exe et version.json ($Json : le texte,
    # ou $null pour ne pas en mettre dans le dossier)
    function New-ZipRust($Json, $EnPlus = $null) {
        $e = [ordered]@{ 'Appli/Appli.exe' = 'relais'; 'Appli/Mindset.exe' = 'programme' }
        if ($null -ne $Json) { $e['Appli/version.json'] = $Json }
        if ($EnPlus) { foreach ($k in $EnPlus.Keys) { $e[$k] = $EnPlus[$k] } }
        New-ZipOctets $e
    }
    function Get-Json([string]$Version, [string]$Appli = 'appli', [string]$Min = '2.15.0') { "{ `"appli`": `"$Appli`", `"version`": `"$Version`", `"mindset_min`": `"$Min`" }" }
    $destR = Join-Path $tmp 'Contrat\Appli'
    function Install-Rust([byte[]]$Zip, [string]$Appli = 'appli', [string]$VersionMindset = '2.15.0', [string]$Dest = $destR, [string]$DossierZip = 'Appli') {
        Install-Paquet -Zip $Zip -Signature (Get-SignatureTest $Zip $cle.Privee) -ClePublique $fPublique -Destination $Dest -DossierZip $DossierZip -Exe 'Appli.exe' -Appli $Appli -VersionMindset $VersionMindset
    }
    function Get-VersionR { Get-VersionDossier $destR }
    function Test-SansResteR { -not @(Get-ChildItem -LiteralPath (Split-Path $destR -Parent) -Directory | Where-Object { $_.Name -like 'Appli.*' }).Count }

    Test-Cas 'version.json bon (sans script) : installé, version lue dans version.json, version.json gardé avec l''appli' {
        $r = Install-Rust (New-ZipRust (Get-Json '3.0.0'))
        ($r -eq $destR) -and ((Get-VersionR) -eq '3.0.0') -and (Test-Path -LiteralPath (Join-Path $destR 'version.json')) -and (Test-SansResteR)
    }
    Test-Cas 'version.json d''une autre appli : refusé avec un message clair, appli installée intacte' {
        (Test-Refus { Install-Rust (New-ZipRust (Get-Json '3.1.0' 'autre')) } 'Ce fichier contient l''appli autre et pas appli : rien n''a été installé.') -and ((Get-VersionR) -eq '3.0.0') -and (Test-SansResteR)
    }
    Test-Cas 'version.json : le nom de l''appli compte sans la casse (APPLI = appli)' { $null = Install-Rust (New-ZipRust (Get-Json '3.0.1' 'APPLI')); (Get-VersionR) -eq '3.0.1' }
    Test-Cas 'mindset_min plus récent que ce Mindset : « Mets d''abord Mindset à jour », rien installé' {
        (Test-Refus { Install-Rust (New-ZipRust (Get-Json '3.2.0' 'appli' '9.0.0')) } 'Mets d''abord Mindset à jour : cette version demande Mindset 9.0.0 ou plus récent.') -and ((Get-VersionR) -eq '3.0.1') -and (Test-SansResteR)
    }
    Test-Cas 'mindset_min égal à ce Mindset : accepté' { $null = Install-Rust (New-ZipRust (Get-Json '3.2.0' 'appli' '2.15.0')); (Get-VersionR) -eq '3.2.0' }
    Test-Cas 'version.json plus ancien que la version installée : refusé (pas de retour en arrière)' {
        (Test-Refus { Install-Rust (New-ZipRust (Get-Json '3.1.9')) } 'plus récente, est déjà installée') -and ((Get-VersionR) -eq '3.2.0')
    }
    foreach ($cas in @(
            @{ Nom = 'JSON cassé'; Json = '{ "appli": "appli", "version": "3.3.0"' },
            @{ Nom = 'version mal formée (« 3 »)'; Json = '{ "appli": "appli", "version": "3" }' },
            @{ Nom = 'version en lettres'; Json = '{ "appli": "appli", "version": "trois" }' },
            @{ Nom = 'version en nombre'; Json = '{ "appli": "appli", "version": 3.3 }' },
            @{ Nom = 'version absente'; Json = '{ "appli": "appli" }' },
            @{ Nom = '« Version » avec une majuscule seulement'; Json = '{ "appli": "appli", "Version": "3.3.0" }' },
            @{ Nom = 'appli qui n''est pas un texte'; Json = '{ "appli": 12, "version": "3.3.0" }' },
            @{ Nom = 'appli nulle'; Json = '{ "appli": null, "version": "3.3.0" }' },
            @{ Nom = 'mindset_min mal formé'; Json = '{ "appli": "appli", "version": "3.3.0", "mindset_min": "bientôt" }' },
            @{ Nom = 'un tableau au lieu d''un objet'; Json = '[ "3.3.0" ]' },
            @{ Nom = 'fichier vide'; Json = '' },
            @{ Nom = 'plus de 64 Ko'; Json = '{ "appli": "appli", "version": "3.3.0", "x": "' + ('a' * 66000) + '" }' })) {
        $j = $cas.Json
        Test-Cas "version.json illisible ($($cas.Nom)) : refusé, appli installée intacte" {
            (Test-Refus { Install-Rust (New-ZipRust $j) } 'ne dit pas quelle version') -and ((Get-VersionR) -eq '3.2.0') -and (Test-SansResteR)
        }
    }
    Test-Cas 'version.json en UTF-16 avec sa marque : lu' {
        $o = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes((Get-Json '3.3.0')))
        $null = Install-Rust (New-ZipRust $o); (Get-VersionR) -eq '3.3.0'
    }
    Test-Cas 'version.json en UTF-8 avec sa marque : lu' {
        $o = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes((Get-Json '3.3.1')))
        $null = Install-Rust (New-ZipRust $o); (Get-VersionR) -eq '3.3.1'
    }
    Test-Cas 'version.json seulement à la racine du zip : accepté, puis rangé avec l''appli' {
        $j = Get-Json '3.4.0'
        $null = Install-Rust (New-ZipRust $null ([ordered]@{ 'version.json' = $j }))
        ((Get-VersionR) -eq '3.4.0') -and ([IO.File]::ReadAllText((Join-Path $destR 'version.json')) -eq $j)
    }
    Test-Cas 'version.json à la racine et dans le dossier, identiques : accepté' { $j = Get-Json '3.5.0'; $null = Install-Rust (New-ZipRust $j ([ordered]@{ 'version.json' = $j })); (Get-VersionR) -eq '3.5.0' }
    Test-Cas 'version.json à la racine et dans le dossier, différents : refusé' {
        (Test-Refus { Install-Rust (New-ZipRust (Get-Json '3.6.0') ([ordered]@{ 'version.json' = (Get-Json '3.6.1') })) } 'ne dit pas quelle version') -and ((Get-VersionR) -eq '3.5.0') -and (Test-SansResteR)
    }
    Test-Cas '« Version.json » à la racine (autre casse) : pas lu, le zip sans version est refusé' {
        Test-Refus { Install-Rust (New-ZipRust $null ([ordered]@{ 'Version.json' = (Get-Json '3.7.0') })) } 'ne dit pas quelle version'
    }
    Test-Cas 'version.json et ancienne ligne $AppVersion d''accord : accepté' {
        $null = Install-Rust (New-ZipRust (Get-Json '3.7.0') ([ordered]@{ 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '3.7.0'" })); (Get-VersionR) -eq '3.7.0'
    }
    Test-Cas 'version.json et ancienne ligne $AppVersion en désaccord : refusé' {
        (Test-Refus { Install-Rust (New-ZipRust (Get-Json '3.8.0') ([ordered]@{ 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '3.8.1'" })) } 'ne dit pas quelle version') -and ((Get-VersionR) -eq '3.7.0')
    }
    Test-Cas 'sans -VersionMindset : mindset_min n''est pas regardé à l''installation (Mindset l''a regardé avant)' {
        $null = Install-Rust (New-ZipRust (Get-Json '3.9.0' 'appli' '9.0.0')) 'appli' ''; (Get-VersionR) -eq '3.9.0'
    }
    Test-Cas 'version installée avec un version.json abîmé : l''ancienne ligne $AppVersion prend le relais (retour en arrière refusé)' {
        $d = Join-Path $tmp 'Contrat-abime\Appli'
        New-Item -ItemType Directory -Force -Path (Join-Path $d 'fichiers') | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'version.json'), '{ cassé')
        [IO.File]::WriteAllText((Join-Path $d 'fichiers\Appli.ps1'), "`$AppVersion = '5.0.0'")
        ((Get-VersionDossier $d) -eq '5.0.0') -and (Test-Refus { Install-Rust (New-ZipRust (Get-Json '4.0.0')) 'appli' '2.15.0' $d } 'la version 5.0.0, plus récente, est déjà installée') -and
        ((Get-VersionDossier $d -Detail).Illisible -eq $true)
    }
    Test-Cas 'sans -Appli : l''appli attendue vient de apps.json (dossier « Nevermind » = nevermind), un zip d''Evermind est refusé' {
        $d = Join-Path $tmp 'Contrat-nevermind\Nevermind'
        $z = New-ZipOctets ([ordered]@{ 'Nevermind/Nevermind.exe' = 'x'; 'Nevermind/Mindset.exe' = 'x'; 'Nevermind/version.json' = (Get-Json '2.0.0' 'evermind') })
        $zb = New-ZipOctets ([ordered]@{ 'Nevermind/Nevermind.exe' = 'x'; 'Nevermind/Mindset.exe' = 'x'; 'Nevermind/version.json' = (Get-Json '2.0.0' 'nevermind') })
        (Test-Refus { Install-Paquet -Zip $z -Signature (Get-SignatureTest $z $cle.Privee) -ClePublique $fPublique -Destination $d -DossierZip 'Nevermind' -Exe 'Nevermind.exe' } 'contient l''appli evermind et pas nevermind') -and
        -not (Test-Path -LiteralPath $d) -and
        ((Install-Paquet -Zip $zb -Signature (Get-SignatureTest $zb $cle.Privee) -ClePublique $fPublique -Destination $d -DossierZip 'Nevermind' -Exe 'Nevermind.exe') -eq $d)
    }
    Test-Cas 'sans -Appli, dossier du zip inconnu de apps.json : pas de contrôle de l''appli (comme suite-commun sans appli)' {
        $d = Join-Path $tmp 'Contrat-inconnu\Appli'
        $z = New-ZipRust (Get-Json '1.0.0' 'nimporte')
        (Install-Paquet -Zip $z -Signature (Get-SignatureTest $z $cle.Privee) -ClePublique $fPublique -Destination $d -DossierZip 'Appli' -Exe 'Appli.exe') -eq $d
    }
    Test-Cas 'zip d''aujourd''hui (sans version.json) : installé comme avant, même avec -Appli et -VersionMindset' {
        $d = Join-Path $tmp 'Contrat-ps\Appli'
        $z = New-ZipAppli '1.2.3'
        ((Install-Rust $z 'autre' '0.1' $d) -eq $d) -and ((Get-VersionDossier $d) -eq '1.2.3') -and -not (Test-Path -LiteralPath (Join-Path $d 'version.json'))
    }

    # Get-VersionZip (installer-admin.ps1, avant de fermer l'appli) et Test-PaquetAppli (Mindset, avant de fermer l'appli)
    Test-Cas 'Get-VersionZip : la version de version.json' { (Get-VersionZip (New-ZipRust (Get-Json '6.0.0')) 'Appli') -eq '6.0.0' }
    Test-Cas 'Get-VersionZip : version.json à la racine seulement' { (Get-VersionZip (New-ZipRust $null ([ordered]@{ 'version.json' = (Get-Json '6.0.1') })) 'Appli') -eq '6.0.1' }
    Test-Cas 'Get-VersionZip : version.json illisible, ou deux différents : rien' {
        ((Get-VersionZip (New-ZipRust '{ cassé') 'Appli') -eq '') -and ((Get-VersionZip (New-ZipRust (Get-Json '6.0.2') ([ordered]@{ 'version.json' = (Get-Json '6.0.3') })) 'Appli') -eq '')
    }
    Test-Cas 'Get-VersionZip : zip d''aujourd''hui, la ligne $AppVersion comme avant' { (Get-VersionZip (New-ZipAppli '6.1.0') 'Appli') -eq '6.1.0' }
    Test-Cas 'Test-PaquetAppli : zip d''aujourd''hui, ou zip illisible : rien à dire' {
        $null = Test-PaquetAppli (New-ZipAppli '6.1.0') 'Appli' 'appli' '2.15.0'
        $null = Test-PaquetAppli ([Text.Encoding]::UTF8.GetBytes('pas un zip')) 'Appli' 'appli' '2.15.0'
        $null = Test-PaquetAppli (New-ZipRust (Get-Json '6.2.0')) 'Appli' 'appli' '2.15.0'
        $true
    }
    Test-Cas 'Test-PaquetAppli : autre appli, Mindset trop ancien, version.json illisible : refusés avant de fermer quoi que ce soit' {
        (Test-Refus { Test-PaquetAppli (New-ZipRust (Get-Json '6.2.0' 'autre')) 'Appli' 'appli' '2.15.0' } 'contient l''appli autre et pas appli') -and
        (Test-Refus { Test-PaquetAppli (New-ZipRust (Get-Json '6.2.0' 'appli' '2.16')) 'Appli' 'appli' '2.15.0' } 'Mets d''abord Mindset à jour') -and
        (Test-Refus { Test-PaquetAppli (New-ZipRust '{ "version": "6" }') 'Appli' 'appli' '2.15.0' } 'ne dit pas quelle version')
    }
    Test-Cas 'installations.ps1 : le téléchargement passe le zip à Test-PaquetAppli avec l''id de l''appli et la version de Mindset' {
        $t = [IO.File]::ReadAllText((Join-Path $fichiers 'modules\installations.ps1'), [Text.Encoding]::UTF8)
        $t -match 'Test-PaquetAppli \$zip \$dz \$p\.Id \$p\.VersionMindset' -and $t -match 'VersionMindset = \[string\]\$AppVersion'
    }

    # =============================================================================================================
    Write-Partie 'Contrat d''une appli : dossier reconnu, version installée (installations.ps1), apps.json (applis.ps1)'
    # =============================================================================================================
    $texteInst = [IO.File]::ReadAllText((Join-Path $fichiers 'modules\installations.ps1'), [Text.Encoding]::UTF8)
    $astInst = [System.Management.Automation.Language.Parser]::ParseInput($texteInst, [ref]$null, [ref]$null)
    foreach ($n in 'Get-ScriptAppli', 'Get-VersionDans', 'Test-DossierAppli') {
        . ([scriptblock]::Create($astInst.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true).Extent.Text))
    }
    $appliTest = [pscustomobject]@{ Id = 'appli'; Exe = 'Appli.exe'; Script = 'fichiers\Appli.ps1'; AncienScript = '' }
    function New-DossierTest([string]$Nom, $Fichiers) {
        $d = Join-Path $tmp "dossiers\$Nom"
        foreach ($k in $Fichiers.Keys) { $f = Join-Path $d $k; New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null; [IO.File]::WriteAllText($f, [string]$Fichiers[$k]) }
        $d
    }
    $dRust = New-DossierTest 'rust' ([ordered]@{ 'Appli.exe' = 'x'; 'Mindset.exe' = 'x'; 'version.json' = (Get-Json '1.4.0') })
    Test-Cas 'dossier d''une appli Rust (Appli.exe, Mindset.exe, version.json qui la nomme) : reconnu, version 1.4.0' { (Test-DossierAppli $dRust $appliTest) -and (Get-VersionDans $dRust $appliTest) -eq '1.4.0' }
    Test-Cas 'appli Rust sans Mindset.exe : pas reconnue' { -not (Test-DossierAppli (New-DossierTest 'sans-hote' ([ordered]@{ 'Appli.exe' = 'x'; 'version.json' = (Get-Json '1.4.0') })) $appliTest) }
    Test-Cas 'appli Rust dont version.json nomme une autre appli : pas reconnue, et sa version n''est pas lue' {
        $d = New-DossierTest 'autre' ([ordered]@{ 'Appli.exe' = 'x'; 'Mindset.exe' = 'x'; 'version.json' = (Get-Json '1.4.0' 'autre') })
        -not (Test-DossierAppli $d $appliTest) -and $null -eq (Get-VersionDans $d $appliTest)
    }
    Test-Cas 'appli Rust dont version.json ne dit pas quelle appli, ou est abîmé : pas reconnue' {
        -not (Test-DossierAppli (New-DossierTest 'sans-nom' ([ordered]@{ 'Appli.exe' = 'x'; 'Mindset.exe' = 'x'; 'version.json' = '{ "version": "1.4.0" }' })) $appliTest) -and
        -not (Test-DossierAppli (New-DossierTest 'abime' ([ordered]@{ 'Appli.exe' = 'x'; 'Mindset.exe' = 'x'; 'version.json' = '{ cassé' })) $appliTest)
    }
    Test-Cas 'appli Rust sans son programme Appli.exe : pas reconnue' { -not (Test-DossierAppli (New-DossierTest 'sans-exe' ([ordered]@{ 'Mindset.exe' = 'x'; 'version.json' = (Get-Json '1.4.0') })) $appliTest) }
    Test-Cas 'dossier d''aujourd''hui (Appli.exe et son script) : reconnu comme avant, version du script' {
        $d = New-DossierTest 'ps' ([ordered]@{ 'Appli.exe' = 'x'; 'fichiers\Appli.ps1' = "`$AppVersion = '1.0.7'" })
        (Test-DossierAppli $d $appliTest) -and (Get-VersionDans $d $appliTest) -eq '1.0.7'
    }
    Test-Cas 'appli qui passe de PowerShell à Rust (script et version.json) : version.json lu d''abord' {
        $d = New-DossierTest 'bascule' ([ordered]@{ 'Appli.exe' = 'x'; 'fichiers\Appli.ps1' = "`$AppVersion = '1.0.7'"; 'version.json' = (Get-Json '2.0.0') })
        (Test-DossierAppli $d $appliTest) -and (Get-VersionDans $d $appliTest) -eq '2.0.0'
    }

    # apps.json : Get-Applis lue dans applis.ps1 et lancée sur de faux apps.json
    $texteApplis = [IO.File]::ReadAllText((Join-Path $fichiers 'modules\applis.ps1'), [Text.Encoding]::UTF8)
    $astApplis = [System.Management.Automation.Language.Parser]::ParseInput($texteApplis, [ref]$null, [ref]$null)
    . ([scriptblock]::Create($astApplis.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-Applis' }, $true).Extent.Text))
    function Write-Log([string]$Texte) {}
    $vraies = [IO.File]::ReadAllText((Join-Path $fichiers 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $AppDir = $fichiers
    $lues = @(Get-Applis)
    Test-Cas 'les applis d''aujourd''hui (apps.json livré) sont toutes lues, de type powershell, champs inchangés' {
        $ok = $lues.Count -eq @($vraies).Count -and $lues.Count -eq 3
        foreach ($v in $vraies) {
            $l = $lues | Where-Object Id -eq $v.id
            $ok = $ok -and $l -and $l.Type -eq 'powershell' -and $l.Nom -eq $v.nom -and $l.Script -eq $v.script -and $l.Mutex -eq $v.mutex -and $l.Exe -eq $v.exe -and
                  $l.AfficherSignal -eq [string]$v.afficher_signal -and $l.CacheDepuis -eq [string]$v.cache_depuis -and $l.DossierZip -eq $v.dossier_zip
        }
        $ok
    }
    $AppDir = Join-Path $tmp 'faux-apps'
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    $modele = @($vraies | Where-Object id -eq 'evermind')[0]
    # Get-Applis sur un apps.json d'une seule entrée : celle d'Evermind, avec des champs changés ($Champs ; $null retire le champ)
    function Get-AppliVariante($Champs) {
        $c = $modele | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        foreach ($k in $Champs.Keys) {
            if ($null -eq $Champs[$k]) { $c.PSObject.Properties.Remove($k) } else { $c | Add-Member -NotePropertyName $k -NotePropertyValue $Champs[$k] -Force }
        }
        [IO.File]::WriteAllText((Join-Path $AppDir 'apps.json'), (ConvertTo-Json @($c) -Depth 4), (New-Object Text.UTF8Encoding $false))
        @(Get-Applis)
    }
    Test-Cas 'type « rust » sans script : acceptée, Type rust, Script vide' { $r = @(Get-AppliVariante @{ type = 'rust'; script = $null }); $r.Count -eq 1 -and $r[0].Type -eq 'rust' -and $r[0].Script -eq '' }
    Test-Cas 'type « powershell » écrit en toutes lettres : acceptée comme sans type' { $r = @(Get-AppliVariante @{ type = 'powershell' }); $r.Count -eq 1 -and $r[0].Type -eq 'powershell' }
    foreach ($cas in @(
            @{ Nom = 'type inconnu (« go »)'; Champs = @{ type = 'go' } },
            @{ Nom = 'type en majuscules (« Rust »)'; Champs = @{ type = 'Rust' } },
            @{ Nom = 'type vide'; Champs = @{ type = '' } },
            @{ Nom = 'type qui n''est pas un texte'; Champs = @{ type = 3 } },
            @{ Nom = 'type powershell sans script'; Champs = @{ script = $null } },
            @{ Nom = 'type rust avec un script piégé'; Champs = @{ type = 'rust'; script = '..\..\piege.ps1' } },
            @{ Nom = 'mutex hors de Local\'; Champs = @{ mutex = 'Global\Evermind-Instance' } },
            @{ Nom = 'mutex avec une espace'; Champs = @{ mutex = 'Local\Ever mind' } },
            @{ Nom = 'afficher_signal hors de Local\'; Champs = @{ afficher_signal = 'Evermind-Afficher' } },
            @{ Nom = 'afficher_signal avec une barre en plus'; Champs = @{ afficher_signal = 'Local\a\b' } },
            @{ Nom = 'cache_depuis qui n''est pas une version'; Champs = @{ cache_depuis = 'bientôt' } },
            @{ Nom = 'cache_depuis à 5 nombres'; Champs = @{ cache_depuis = '1.2.3.4.5' } })) {
        $champs = $cas.Champs
        Test-Cas "apps.json, $($cas.Nom) : l'appli est ignorée" { @(Get-AppliVariante $champs).Count -eq 0 }
    }
    Test-Cas 'apps.json : sans mutex, sans afficher_signal, sans cache_depuis, l''appli reste acceptée (champs facultatifs)' {
        @(Get-AppliVariante @{ mutex = $null; afficher_signal = $null; cache_depuis = $null }).Count -eq 1
    }

    # =============================================================================================================
    Write-Partie 'Contrat d''une appli : fenêtre trouvée pour l''accrochage (MSIntegration.Trouver, natif.cs)'
    # =============================================================================================================
    # Des fenêtres de premier niveau de ce processus, créées CACHÉES (jamais montrées) : une fenêtre WPF (classe
    # « HwndWrapper[...] »), une fenêtre Tauri (« Tauri Window »), un autre navigateur (« Chrome_WidgetWin_1 »), et une
    # fenêtre Tauri possédée par une autre (une alerte). Seules les deux premières sont des fenêtres d'appli.
    # (natif.cs compilé dans un espace de noms à part : ses autres classes, comme MSActivite, restent remplacées par des
    # fausses dans la suite de ces tests)
    $natif = [IO.File]::ReadAllText((Join-Path $fichiers 'modules\natif.cs'), [Text.Encoding]::UTF8)
    $finUsing = $natif.IndexOf("using System.Runtime.InteropServices;") + "using System.Runtime.InteropServices;".Length
    Add-Type -TypeDefinition ($natif.Substring(0, $finUsing) + "`nnamespace ContratTest {`n" + $natif.Substring($finUsing) + "`n}`n")
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FenetreCachee {
    delegate IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX { public uint cbSize, style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClassExW(ref WNDCLASSEX c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateWindowExW(uint ex, string classe, string titre, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string n);
    static readonly Proc proc = DefWindowProcW;
    // Une fenêtre de premier niveau sans WS_VISIBLE (jamais montrée) ; $Proprietaire : une fenêtre qui la possède
    public static IntPtr Creer(string classe, string titre, IntPtr proprietaire) {
        var c = new WNDCLASSEX(); c.cbSize = (uint)Marshal.SizeOf(c); c.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc);
        c.hInstance = GetModuleHandleW(null); c.lpszClassName = classe;
        RegisterClassExW(ref c);   // (déjà enregistrée : sans importance)
        return CreateWindowExW(0x80, classe, titre, 0x00C00000, -32000, -32000, 10, 10, proprietaire, IntPtr.Zero, c.hInstance, IntPtr.Zero);   // (WS_EX_TOOLWINDOW, WS_CAPTION, sans WS_VISIBLE)
    }
}
'@
    $titreTest = "Appli de test $([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $fenetres = @()
    try {
        $wpf = [FenetreCachee]::Creer('HwndWrapper[Test;;0f1e2d3c]', "$titreTest WPF", [IntPtr]::Zero)
        $tauri = [FenetreCachee]::Creer('Tauri Window', "$titreTest Tauri", [IntPtr]::Zero)
        $chrome = [FenetreCachee]::Creer('Chrome_WidgetWin_1', "$titreTest Chrome", [IntPtr]::Zero)
        $alerte = [FenetreCachee]::Creer('Tauri Window', "$titreTest Alerte", $tauri)
        $fenetres = @($alerte, $chrome, $tauri, $wpf)
        Test-Cas 'les fenêtres de test existent et ne sont pas montrées' { -not @($fenetres | Where-Object { $_ -eq [IntPtr]::Zero -or [FenetreCachee]::IsWindowVisible($_) }).Count }
        Test-Cas 'fenêtre WPF (HwndWrapper) trouvée, comme avant' { [ContratTest.MSIntegration]::Trouver($PID, "$titreTest WPF") -eq $wpf }
        Test-Cas 'fenêtre Tauri (« Tauri Window ») trouvée' { [ContratTest.MSIntegration]::Trouver($PID, "$titreTest Tauri") -eq $tauri }
        Test-Cas 'fenêtre d''une autre classe (Chrome_WidgetWin_1) jamais prise' { [ContratTest.MSIntegration]::Trouver($PID, "$titreTest Chrome") -eq [IntPtr]::Zero }
        Test-Cas 'fenêtre Tauri possédée par une autre (une alerte) jamais prise' { [ContratTest.MSIntegration]::Trouver($PID, "$titreTest Alerte") -eq [IntPtr]::Zero }
        Test-Cas 'titre presque pareil : rien' { [ContratTest.MSIntegration]::Trouver($PID, "$titreTest tauri") -eq [IntPtr]::Zero }
    } finally {
        foreach ($f in $fenetres) { if ($f -ne [IntPtr]::Zero) { [void][FenetreCachee]::DestroyWindow($f) } }
    }
    Test-Cas 'natif.cs : la seule condition de plus est la classe « Tauri Window » (exacte)' {
        $n = [IO.File]::ReadAllText((Join-Path $fichiers 'modules\natif.cs'), [Text.Encoding]::UTF8)
        $n.Contains('(c.ToString().StartsWith("HwndWrapper") || c.ToString() == "Tauri Window")')
    }

    # =============================================================================================================
    Write-Partie 'Test-DossierMindset (installer-admin.ps1)'
    # =============================================================================================================
    # Les cas sont dans le corpus commun cas\installateur\dossier-protege.json (format dans cas\LISEZMOI.md), qui servira
    # aussi à l'installateur en Rust. Au moins 20 cas : un cas retiré fait échouer le test.
    $valeursDossier = @{ '{programmes-mindset}' = [IO.Path]::GetFullPath((Join-Path $DossierProgrammes 'Mindset')); '{windows}' = [Environment]::GetFolderPath('Windows') }
    function Expand-Dossier([string]$T) {
        foreach ($k in $valeursDossier.Keys) { $T = $T.Replace($k, $valeursDossier[$k]) }
        if ($T -match '\{[a-z][a-z-]*\}') { throw "Valeur inconnue dans le corpus : $($Matches[0])" }
        $T
    }
    $corpusDossier = [IO.File]::ReadAllText((Join-Path $racine 'cas\installateur\dossier-protege.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $nDossier = @($corpusDossier.cas).Count
    $inconnus = @(@($corpusDossier.cas) | ForEach-Object { $_.attendu.PSObject.Properties.Name } | Where-Object { $_ -notin 'accepte', 'dossier', 'message', 'disque_verifie' })
    Test-Cas "dossier-protege.json : format 1, au moins 20 cas (trouvés : $nDossier), attendus connus" { $corpusDossier.format -eq 1 -and $nDossier -ge 20 -and -not $inconnus.Count }
    foreach ($cas in @($corpusDossier.cas)) {
        $c = $cas
        Test-Cas ([string]$c.nom) {
            $script:DisquesVerifies = @()
            $d = Expand-Dossier $c.entree.dossier
            $a = $c.attendu
            if ($a.accepte) {
                $vu = try { Test-DossierMindset $d } catch { $null }
                $vu -and $vu -eq (Expand-Dossier $a.dossier) -and (-not $a.disque_verifie -or $script:DisquesVerifies -contains [string]$a.disque_verifie)
            } else {
                Test-Refus { Test-DossierMindset $d } ([string]$a.message)
            }
        }
    }

    # =============================================================================================================
    Write-Partie 'Chercher les nouvelles versions : coupé, rien ne part tout seul vers GitHub (accueil.ps1, mindset.ps1)'
    # =============================================================================================================
    # Les fonctions de Mindset sont prises dans leurs fichiers (par l'analyseur : les modules exécutent du code au
    # chargement) ; ce qui touche le réseau ou Windows est remplacé par de faux qui comptent leurs appels.
    $modules = Join-Path $fichiers 'modules'
    $asts = @{}
    foreach ($m in @(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File)) {
        $e = $null
        $asts[$m.Name] = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($m.FullName, [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
        if ($e) { throw "$($m.Name) illisible : $($e[0].Message)" }
    }
    function Import-FonctionsMindset([string]$Fichier, [string[]]$Noms) {
        $d = @($asts[$Fichier].FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Noms }, $true))
        if ($d.Count -ne $Noms.Count) { throw "$Fichier : fonctions introuvables ($($Noms -join ', '))." }
        foreach ($x in $d) { . ([scriptblock]::Create($x.Extent.Text)) }
        # (définies dans la portée du script, comme celles de Mindset)
        foreach ($x in $d) { Set-Item -Path "function:script:$($x.Name)" -Value (Get-Item "function:$($x.Name)").ScriptBlock }
    }
    Import-FonctionsMindset 'accueil.ps1' @('Invoke-Actualiser', 'Update-InfoActualiser')
    Import-FonctionsMindset 'mindset.ps1' @('Test-VerifVersionsActive', 'Test-MajAutoActive', 'Test-MajAutoRecente', 'Invoke-MajAuto')

    # Les faux : réglages en mémoire, appels réseau comptés
    $script:ReglagesTest = @{}
    function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:ReglagesTest.ContainsKey($Nom)) { $script:ReglagesTest[$Nom] } else { $Defaut } }
    function Write-Log([string]$Texte) {}
    $script:AppelsReseau = New-Object Collections.Generic.List[string]
    function Update-Publications { $script:AppelsReseau.Add('Update-Publications') }
    function Start-VerifMajMindset { $script:AppelsReseau.Add('Start-VerifMajMindset') }
    function Get-Publication { $script:AppelsReseau.Add('Get-Publication') }
    function Start-InstallAppli($Appli) { $script:AppelsReseau.Add("Start-InstallAppli $($Appli.Id)") }
    function Start-MajMindset { $script:AppelsReseau.Add('Start-MajMindset') }
    function Test-TacheInstallation { $true }
    $script:OuverteTest = $false; $script:JeuTest = ''
    function Get-EtatCarte($Appli) { @{ MajDispo = $true; Occupe = $null; Ouverte = $script:OuverteTest; Pub = @{ Version = '9.9.9' } } }
    function Get-JeuEnCours { $script:JeuTest }
    if (-not ('MSActivite' -as [type])) {
        Add-Type -TypeDefinition 'public static class MSActivite { public static bool PleinEcranDevant() { return false; } public static uint SecondesInactif() { return 3600; } }'
    }
    $ui = @{ ActualiserInfo = [pscustomobject]@{ Text = '' } }
    $Applis = @([pscustomobject]@{ Id = 'appli'; Nom = 'Appli' })
    $MindsetAdmin = $false; $EnTest = $false; $Window = [pscustomobject]@{ IsVisible = $true; WindowState = 'Normal' }
    $sansReseau = $env:MINDSET_SANS_RESEAU; $env:MINDSET_SANS_RESEAU = $null
    function Reset-EtatActualiser([hashtable]$Reglages, [bool]$Bienvenue = $false) {
        $script:ReglagesTest = $Reglages; $script:AppelsReseau.Clear()
        $script:DernieresPublications = [datetime]::MinValue; $script:VerifieA = $null; $script:AttenteBienvenue = $Bienvenue
        $script:Occupe = @{}; $script:AttentesAdmin = New-Object Collections.ArrayList; $script:MajAuto = @{}; $script:MajAutoEssais = @{}
        $script:MajAutoDerniere = [datetime]::MinValue; $script:MajMindset = $null; $script:PageCourante = 'accueil'
        $script:OuverteTest = $false; $script:JeuTest = ''; $script:MajMindsetEnCours = $false
        $ui.ActualiserInfo.Text = ''
    }
    function Test-CasMajAuto([string]$Nom, [bool]$Ouverte, [string]$Jeu, [string]$Attendu) {
        Test-Cas $Nom {
            Reset-EtatActualiser @{ MajAuto = $true }
            $script:OuverteTest = $Ouverte; $script:JeuTest = $Jeu
            Invoke-MajAuto
            ($script:AppelsReseau -join ',') -eq $Attendu
        }
    }
    try {
        Test-Cas 'activé par défaut (aucun réglage enregistré)' { Reset-EtatActualiser @{}; Test-VerifVersionsActive }
        Test-Cas 'activé : la recherche tout seul (démarrage, toutes les heures, retour) interroge GitHub' {
            Reset-EtatActualiser @{}
            Invoke-Actualiser
            ($script:AppelsReseau -join ',') -eq 'Update-Publications,Start-VerifMajMindset'
        }
        Test-Cas 'coupé : la recherche tout seul ne lance aucun appel réseau, et l''accueil le dit' {
            Reset-EtatActualiser @{ VerifVersions = $false }
            Invoke-Actualiser; Invoke-Actualiser   # (démarrage, puis la minuterie de l'heure ou le retour depuis l'horloge)
            Update-InfoActualiser
            $script:AppelsReseau.Count -eq 0 -and $ui.ActualiserInfo.Text -eq 'Recherche automatique coupée'
        }
        Test-Cas 'coupé : « Actualiser » ou « Vérifier maintenant » (un clic) cherche quand même' {
            Reset-EtatActualiser @{ VerifVersions = $false }
            Invoke-Actualiser -Clic
            ($script:AppelsReseau -join ',') -eq 'Update-Publications,Start-VerifMajMindset' -and $ui.ActualiserInfo.Text -like 'Vérifié à *(recherche automatique coupée)'
        }
        Test-Cas 'activé, mais bandeau d''installation pas encore répondu : rien ne part tout seul' {
            Reset-EtatActualiser @{} $true
            Invoke-Actualiser
            $script:AppelsReseau.Count -eq 0
        }
        Test-Cas 'activé, mises à jour automatiques activées : une nouvelle version s''installe toute seule (le faux marche)' {
            Reset-EtatActualiser @{ MajAuto = $true }
            Invoke-MajAuto
            ($script:AppelsReseau -join ',') -eq 'Start-InstallAppli appli'
        }
        Test-Cas 'coupé : les mises à jour automatiques ne tournent pas, même activées' {
            Reset-EtatActualiser @{ VerifVersions = $false; MajAuto = $true }
            Invoke-MajAuto
            $script:MajMindset = @{ Version = '9.9.9' }; $Window.IsVisible = $false   # (et Mindset lui-même, caché)
            $script:MajAutoDerniere = [datetime]::MinValue
            Invoke-MajAuto
            $Window.IsVisible = $true
            $script:AppelsReseau.Count -eq 0
        }
        # Pendant une partie (Get-JeuEnCours : plein écran sur n'importe quel écran, manette, jeu ouvert en fenêtre),
        # même si le clavier et la souris ne bougent plus depuis une heure : rien ne se met à jour
        Test-CasMajAuto 'appli ouverte, personne au clavier, pas de jeu : mise à jour (le faux marche)' $true '' 'Start-InstallAppli appli'
        Test-CasMajAuto 'appli ouverte pendant un jeu (manette, autre écran, fenêtre) : pas de mise à jour' $true 'un jeu ouvert (JeuTest.exe)' ''
        Test-CasMajAuto 'appli fermée pendant un jeu : pas de mise à jour non plus' $false 'une manette utilisée il y a moins de 5 minutes' ''
        Test-Cas 'Mindset lui-même pendant un jeu : pas de mise à jour' {
            Reset-EtatActualiser @{ MajAuto = $true }
            $script:JeuTest = 'une fenêtre en plein écran (jeu ou vidéo)'
            $script:MajMindset = @{ Version = '9.9.9' }; $Window.IsVisible = $false
            $Applis = @()
            Invoke-MajAuto
            $Window.IsVisible = $true
            $script:AppelsReseau.Count -eq 0
        }
        Test-Cas 'Mindset lui-même, pas pendant qu''une version plus récente se télécharge (elle remplacera celle qui est prête)' {
            Reset-EtatActualiser @{ MajAuto = $true }
            $script:MajMindset = @{ Version = '9.9.9' }; $script:MajMindsetEnCours = $true; $Window.IsVisible = $false
            $Applis = @()
            Invoke-MajAuto
            $Window.IsVisible = $true
            $script:AppelsReseau.Count -eq 0
        }
        # Les réglages de test passent par des variables d'environnement : hors test, elles ne comptent pas
        Test-Cas 'MINDSET_SANS_RESEAU hors test (sans MINDSET_TEST) : ignorée, la recherche se fait quand même' {
            Reset-EtatActualiser @{}
            $env:MINDSET_SANS_RESEAU = '1'
            try { Invoke-Actualiser } finally { $env:MINDSET_SANS_RESEAU = $null }
            ($script:AppelsReseau -join ',') -eq 'Update-Publications,Start-VerifMajMindset'
        }
        Test-Cas 'MINDSET_SANS_RESEAU en test (MINDSET_TEST) : aucune recherche' {
            Reset-EtatActualiser @{}
            $EnTest = $true; $env:MINDSET_SANS_RESEAU = '1'
            try { Invoke-Actualiser } finally { $env:MINDSET_SANS_RESEAU = $null; $EnTest = $false }
            $script:AppelsReseau.Count -eq 0
        }
    } finally { $env:MINDSET_SANS_RESEAU = $sansReseau }

    # MINDSET_CAPTURE (capture puis fermeture), MINDSET_SANS_RESEAU et MINDSET_CONSOLE_DEV (outils de développement de la
    # console) : chaque lecture, hors de Start-Capture qui n'est appelée qu'ainsi, est gardée par « $EnTest -and ... »
    $astsGardes = @{ 'Mindset.ps1 (script principal)' = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $fichiers 'Mindset.ps1'), [Text.Encoding]::UTF8), [ref]$null, [ref]$null) }
    foreach ($k in $asts.Keys) { $astsGardes[$k] = $asts[$k] }
    foreach ($nomVar in 'MINDSET_CAPTURE', 'MINDSET_SANS_RESEAU', 'MINDSET_CONSOLE_DEV') {
        Test-Cas "$nomVar ne compte qu'en test (gardée par `$EnTest partout où elle est lue)" {
            $lues = 0; $libres = @()
            foreach ($k in $astsGardes.Keys) {
                foreach ($v in @($astsGardes[$k].FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq "env:$nomVar" }, $true))) {
                    $p = $v.Parent; $garde = $false; $fonction = ''
                    while ($p) {
                        if ($p -is [System.Management.Automation.Language.BinaryExpressionAst] -and $p.Operator -eq 'And' -and $p.Left.Extent.Text -eq '$EnTest') { $garde = $true }
                        # (ou dans le bloc d'un « if ($EnTest -and ...) { ... } »)
                        if ($p -is [System.Management.Automation.Language.StatementBlockAst] -and $p.Parent -is [System.Management.Automation.Language.IfStatementAst]) {
                            foreach ($cl in $p.Parent.Clauses) { if ($cl.Item2 -eq $p -and $cl.Item1.Extent.Text -match '^\$EnTest\s+-and\s') { $garde = $true } }
                        }
                        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -and -not $fonction) { $fonction = $p.Name }
                        $p = $p.Parent
                    }
                    if ($fonction -eq 'Start-Capture') { continue }
                    $lues++
                    if (-not $garde) { $libres += "$k ligne $($v.Extent.StartLineNumber)" }
                }
            }
            if ($libres.Count) { Write-Host "         lue sans garde : $($libres -join ', ')" -ForegroundColor Yellow }
            $lues -gt 0 -and $libres.Count -eq 0
        }
    }

    # Qui appelle quoi : les fonctions qui vont sur GitHub ne sont appelées que d'endroits connus. Une recherche ajoutée
    # ailleurs (une nouvelle minuterie, par exemple) passerait à côté du réglage : ce cas la signale.
    function Get-Appelants([string]$Commande) {
        $r = foreach ($k in $asts.Keys) {
            foreach ($c in @($asts[$k].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Commande }, $true))) {
                $p = $c.Parent; while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
                "$k`:$(if ($p) { $p.Name } else { '(hors fonction)' })"
            }
        }
        @($r | Sort-Object -Unique)
    }
    $attendus = [ordered]@{
        'Get-Publication'       = @('installations.ps1:Start-InstallAppli', 'installations.ps1:Update-Publications', 'mindset.ps1:Start-VerifMajMindset')
        'Get-Octets'            = @('installations.ps1:Start-InstallAppli', 'mindset.ps1:Start-VerifMajMindset')
        'Update-Publications'   = @('accueil.ps1:Invoke-Actualiser')
        'Start-VerifMajMindset' = @('accueil.ps1:Invoke-Actualiser')
    }
    foreach ($cmd in $attendus.Keys) {
        Test-Cas "$cmd n'est appelé que depuis $($attendus[$cmd] -join ', ')" {
            $trouves = Get-Appelants $cmd
            if (Compare-Object $trouves $attendus[$cmd]) { Write-Host "         appelé depuis : $($trouves -join ', ')" -ForegroundColor Yellow; return $false }
            $true
        }
    }
    # Start-InstallAppli : un geste de l'utilisateur (carte, console, confirmation) ou la mise à jour automatique (gardée
    # par le réglage, voir plus haut)
    Test-Cas 'Start-InstallAppli n''est appelé que par un geste de l''utilisateur ou Invoke-MajAuto' {
        $trouves = Get-Appelants 'Start-InstallAppli'
        $permis = @('accueil.ps1:Update-Carte', 'accueil.ps1:Confirm-MiseAJour', 'accueil.ps1:Confirm-PriseEnCharge', 'console.ps1:Receive-MessageConsole', 'mindset.ps1:Invoke-MajAuto')
        $hors = @($trouves | Where-Object { $_ -notin $permis })
        if ($hors.Count) { Write-Host "         aussi appelé depuis : $($hors -join ', ')" -ForegroundColor Yellow }
        $hors.Count -eq 0
    }

    # =============================================================================================================
    Write-Partie 'Outils de clé (outils\cle.ps1 et outils\signer.ps1), dans une copie sous %TEMP%'
    # =============================================================================================================
    # Une copie des outils dans un faux dépôt, et APPDATA détourné vers le dossier de test (pour ce processus seulement) :
    # la vraie clé privée, la vraie liste et le vrai mot de passe ne sont jamais touchés.
    $depot = Join-Path $tmp 'depot'
    New-Item -ItemType Directory -Force -Path (Join-Path $depot 'outils'), (Join-Path $depot 'Mindset\fichiers\modules') | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'cle.ps1'), (Join-Path $PSScriptRoot 'signer.ps1') -Destination (Join-Path $depot 'outils')
    Copy-Item -LiteralPath (Join-Path $fichiers 'modules\signature.ps1') -Destination (Join-Path $depot 'Mindset\fichiers\modules')
    $env:APPDATA = Join-Path $tmp 'AppData'
    $clesDepot = Join-Path $depot 'Mindset\fichiers\cles-publiques'
    $priveeTest = Join-Path $env:APPDATA 'Mindset-signature\cle-privee.mdp'
    $mdpTest = ConvertTo-SecureString 'mot de passe de test 123' -AsPlainText -Force
    $mdpFaux = ConvertTo-SecureString 'pas le bon mot de passe' -AsPlainText -Force
    # Garde-fou : jamais un outil de clé lancé si APPDATA n'est pas dans le dossier de test
    function Invoke-OutilCle([string]$Outil, [hashtable]$Params) {
        if (-not $env:APPDATA.StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase)) { throw 'APPDATA n''est pas détourné : test arrêté.' }
        & (Join-Path $depot "outils\$Outil") @Params
    }
    function Get-ListeDepot { @(Get-ChildItem -LiteralPath $clesDepot -Filter '*.xml' -File -ErrorAction SilentlyContinue) }
    $zipSigne = Join-Path $tmp 'a-signer.zip'
    [IO.File]::WriteAllBytes($zipSigne, (New-ZipAppli '3.0.0'))
    function Test-SigneParListe { (Test-Path -LiteralPath "$zipSigne.sig") -and (Test-Signature ([IO.File]::ReadAllBytes($zipSigne)) ([IO.File]::ReadAllBytes("$zipSigne.sig")) $clesDepot) }

    Test-Cas 'cle.ps1 crée la clé de tous les jours : privée chiffrée sous APPDATA, publique dans la liste' {
        $null = Invoke-OutilCle 'cle.ps1' @{ MotDePasse = $mdpTest }
        $l = Get-ListeDepot
        (Test-Path -LiteralPath $priveeTest) -and $l.Count -eq 1 -and $l[0].Name -like 'principale-*.xml' -and
            -not ([IO.File]::ReadAllText($l[0].FullName) -match '<P>|<D>') -and -not ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($priveeTest)) -match 'RSAKeyValue')
    }
    # (audit du 25/10, constat 9 : la session Windows ne suffit plus, il faut le mot de passe)
    Test-Cas 'clé de tous les jours : déchiffrée par la seule session Windows (DPAPI), elle reste illisible (il faut le mot de passe)' {
        Add-Type -AssemblyName System.Security
        $o = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($priveeTest), $null, 'CurrentUser')
        ([Text.Encoding]::ASCII.GetString($o, 0, 4) -eq 'MSK1') -and -not ([Text.Encoding]::UTF8.GetString($o) -match 'RSAKeyValue|<D>')
    }
    Test-Cas 'cle.ps1 refuse de créer une deuxième clé de tous les jours par dessus la première' { Test-Refus { Invoke-OutilCle 'cle.ps1' @{ MotDePasse = $mdpTest } } 'existe déjà' }
    Test-Cas 'cle.ps1 refuse un mot de passe trop court pour la clé de tous les jours' {
        $sauve = "$priveeTest.garde"; Move-Item -LiteralPath $priveeTest -Destination $sauve
        $court = ConvertTo-SecureString 'court' -AsPlainText -Force
        $refus = Test-Refus { Invoke-OutilCle 'cle.ps1' @{ MotDePasse = $court } } 'trop court'
        $rien = -not (Test-Path -LiteralPath $priveeTest) -and (Get-ListeDepot).Count -eq 1
        Move-Item -LiteralPath $sauve -Destination $priveeTest
        $refus -and $rien
    }
    $msk = Join-Path $tmp 'usb\secours.msk'
    New-Item -ItemType Directory -Force -Path (Split-Path $msk -Parent) | Out-Null
    Test-Cas 'cle.ps1 -Secours : clé de secours écrite seulement dans son fichier protégé, sa clé publique dans la liste' {
        $avant = @(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'Mindset-signature') -File).Count
        $null = Invoke-OutilCle 'cle.ps1' @{ Secours = $msk; MotDePasse = $mdpTest }
        $o = [IO.File]::ReadAllBytes($msk)
        $sec = @(Get-ListeDepot | Where-Object { $_.Name -like 'secours-*.xml' })
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        try { $rsa.FromXmlString([IO.File]::ReadAllText($sec[0].FullName)); $bonne = $rsa.PublicOnly -and $rsa.KeySize -ge 4096 } finally { $rsa.Dispose() }
        ([Text.Encoding]::ASCII.GetString($o, 0, 4) -eq 'MSK1') -and -not ([Text.Encoding]::UTF8.GetString($o) -match 'RSAKeyValue') -and
            $sec.Count -eq 1 -and $bonne -and (Get-ListeDepot).Count -eq 2 -and
            @(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'Mindset-signature') -File).Count -eq $avant
    }
    Test-Cas 'cle.ps1 -Secours n''écrase jamais une clé de secours existante' { Test-Refus { Invoke-OutilCle 'cle.ps1' @{ Secours = $msk; MotDePasse = $mdpTest } } 'existe déjà' }
    Test-Cas 'cle.ps1 -Secours refuse un mot de passe trop court' {
        $court = ConvertTo-SecureString 'court' -AsPlainText -Force
        (Test-Refus { Invoke-OutilCle 'cle.ps1' @{ Secours = (Join-Path $tmp 'usb\court.msk'); MotDePasse = $court } } 'trop court') -and -not (Test-Path -LiteralPath (Join-Path $tmp 'usb\court.msk'))
    }
    Test-Cas 'signer.ps1 sans le bon mot de passe : refusé, aucune signature écrite' {
        Remove-Item -LiteralPath "$zipSigne.sig" -ErrorAction SilentlyContinue
        (Test-Refus { Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpFaux } } 'Mot de passe incorrect') -and -not (Test-Path -LiteralPath "$zipSigne.sig")
    }
    Test-Cas 'signer.ps1 signe avec la clé de ce PC et son mot de passe, signature acceptée par la liste' {
        $null = Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpTest }
        Test-SigneParListe
    }
    Test-Cas 'signer.ps1 -Secours signe avec la clé de secours, signature acceptée par la liste' {
        Remove-Item -LiteralPath "$zipSigne.sig"
        $null = Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; Secours = $msk; MotDePasse = $mdpTest }
        $s = [IO.File]::ReadAllBytes("$zipSigne.sig")
        # (vérifiée par la clé de secours seule, pas par la clé de tous les jours)
        $seule = New-ListeTest 'secours-seule' ([ordered]@{ 's.xml' = [IO.File]::ReadAllText(@(Get-ListeDepot | Where-Object { $_.Name -like 'secours-*' })[0].FullName) })
        (Test-SigneParListe) -and (Test-Signature ([IO.File]::ReadAllBytes($zipSigne)) $s $seule)
    }
    Test-Cas 'signer.ps1 -Secours avec un faux mot de passe : refusé, aucune signature écrite' {
        Remove-Item -LiteralPath "$zipSigne.sig"
        (Test-Refus { Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; Secours = $msk; MotDePasse = $mdpFaux } } 'Mot de passe incorrect') -and -not (Test-Path -LiteralPath "$zipSigne.sig")
    }
    Test-Cas 'cle.ps1 -Liste montre les deux clés et celle de ce PC (sans demander le mot de passe)' {
        $t = (Invoke-OutilCle 'cle.ps1' @{ Liste = $true }) -join "`n"
        ($t -match 'principale-.*3072 bits, la clé de ce PC') -and ($t -match 'secours-.*4096 bits')
    }
    Test-Cas 'cle.ps1 -Retirer refuse de retirer la clé de ce PC' {
        $n = @(Get-ListeDepot | Where-Object { $_.Name -like 'principale-*' })[0].Name
        (Test-Refus { Invoke-OutilCle 'cle.ps1' @{ Retirer = $n } } 'clé de ce PC') -and (Get-ListeDepot).Count -eq 2
    }
    Test-Cas 'cle.ps1 -Nouvelle avec un faux mot de passe : refusé, aucune clé suivante' {
        (Test-Refus { Invoke-OutilCle 'cle.ps1' @{ Nouvelle = $true; MotDePasse = $mdpFaux } } 'Mot de passe incorrect') -and (Get-ListeDepot).Count -eq 2 -and
            -not (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Mindset-signature\cle-privee-suivante.mdp'))
    }
    Test-Cas 'cle.ps1 -Nouvelle (étape 1) : la clé suivante entre dans la liste, ce PC signe encore avec l''ancienne' {
        $null = Invoke-OutilCle 'cle.ps1' @{ Nouvelle = $true; MotDePasse = $mdpTest }
        $null = Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpTest }
        $script:AncienneSig = [IO.File]::ReadAllBytes("$zipSigne.sig")
        (Get-ListeDepot).Count -eq 3 -and (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Mindset-signature\cle-privee-suivante.mdp')) -and (Test-SigneParListe)
    }
    Test-Cas 'cle.ps1 -Basculer (étape 2, sans mot de passe) : l''ancienne clé quitte la liste, ce PC signe avec la nouvelle (même mot de passe)' {
        $null = Invoke-OutilCle 'cle.ps1' @{ Basculer = $true }
        $null = Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpTest }
        (Get-ListeDepot).Count -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Mindset-signature\cle-privee-suivante.mdp')) -and
            (Test-SigneParListe) -and -not (Test-Signature ([IO.File]::ReadAllBytes($zipSigne)) $script:AncienneSig $clesDepot)
    }
    Test-Cas 'cle.ps1 -Retirer retire la clé de secours (volée), puis refuse de retirer la dernière clé' {
        $s = @(Get-ListeDepot | Where-Object { $_.Name -like 'secours-*' })[0].Name
        $null = Invoke-OutilCle 'cle.ps1' @{ Retirer = $s }
        $reste = Get-ListeDepot
        Move-Item -LiteralPath $priveeTest -Destination "$priveeTest.copie"   # (sans clé sur ce PC, seule la règle « dernière clé » peut refuser)
        Move-Item -LiteralPath ([IO.Path]::ChangeExtension($priveeTest, '.pub')) -Destination ($priveeTest + '.pub-copie')
        $refus = Test-Refus { Invoke-OutilCle 'cle.ps1' @{ Retirer = $reste[0].Name } } 'dernière clé'
        $reste.Count -eq 1 -and $refus -and (Get-ListeDepot).Count -eq 1
    }
    Test-Cas 'signer.ps1 refuse de signer avec une clé retirée de la liste (la clé de secours retirée) : aucune signature écrite' {
        $null = Invoke-OutilCle 'cle.ps1' @{ Importer = $msk; MotDePasse = $mdpTest }
        Remove-Item -LiteralPath "$zipSigne.sig" -ErrorAction SilentlyContinue
        (Test-Refus { Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpTest } } 'aucune clé de la liste') -and -not (Test-Path -LiteralPath "$zipSigne.sig")
    }
    Test-Cas 'signer.ps1 refuse de signer si une clé privée est glissée dans la liste, puis signe une fois retirée' {
        Move-Item -LiteralPath "$priveeTest.copie" -Destination $priveeTest -Force   # (la clé de la liste revient sur ce PC)
        Move-Item -LiteralPath "$priveeTest.pub-copie" -Destination ([IO.Path]::ChangeExtension($priveeTest, '.pub')) -Force
        $f = Join-Path $clesDepot 'piege.xml'
        [IO.File]::WriteAllText($f, $cleB.Privee)
        $refus = (Test-Refus { Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpTest } } 'aucune clé de la liste') -and -not (Test-Path -LiteralPath "$zipSigne.sig")
        $liste = (Invoke-OutilCle 'cle.ps1' @{ Liste = $true }) -join "`n"
        Remove-Item -LiteralPath $f
        $null = Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpTest }
        $refus -and ($liste -match 'piege\.xml : ERREUR : clé PRIVÉE') -and (Test-SigneParListe)
    }

    # La clé d'avant (chiffrée seulement pour le compte Windows) : une clé JETABLE, posée comme l'ancien cle.ps1 la rangeait
    Test-Cas 'clé d''avant (session Windows seulement) : signer.ps1 refuse et dit de lancer -Convertir, aucune signature' {
        $d = Join-Path $env:APPDATA 'Mindset-signature'
        Get-ChildItem -LiteralPath $d -File | Remove-Item -Force
        $jetable = New-CleTest 3072
        [IO.File]::WriteAllBytes((Join-Path $d 'cle-privee.bin'), [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($jetable.Privee), $null, 'CurrentUser'))
        [IO.File]::WriteAllText((Join-Path $clesDepot 'principale-jetable.xml'), $jetable.Publique)
        $script:Jetable = $jetable
        Remove-Item -LiteralPath "$zipSigne.sig" -ErrorAction SilentlyContinue
        (Test-Refus { Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpTest } } '-Convertir') -and -not (Test-Path -LiteralPath "$zipSigne.sig")
    }
    Test-Cas 'cle.ps1 -Liste reconnaît encore la clé d''avant, et dit de la convertir' {
        $t = (Invoke-OutilCle 'cle.ps1' @{ Liste = $true }) -join "`n"
        ($t -match 'principale-jetable\.xml : 3072 bits, la clé de ce PC') -and ($t -match '-Convertir')
    }
    Test-Cas 'cle.ps1 -Convertir : la clé d''avant passe sous le mot de passe, l''ancien fichier est effacé' {
        $d = Join-Path $env:APPDATA 'Mindset-signature'
        $null = Invoke-OutilCle 'cle.ps1' @{ Convertir = $true; MotDePasse = $mdpTest }
        $o = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($priveeTest), $null, 'CurrentUser')
        -not (Test-Path -LiteralPath (Join-Path $d 'cle-privee.bin')) -and ([Text.Encoding]::ASCII.GetString($o, 0, 4) -eq 'MSK1') -and
            ((([xml][IO.File]::ReadAllText([IO.Path]::ChangeExtension($priveeTest, '.pub'))).RSAKeyValue.Modulus -eq ([xml]$script:Jetable.Publique).RSAKeyValue.Modulus))
    }
    Test-Cas 'après -Convertir : signer.ps1 refuse sans le bon mot de passe, puis signe avec (la même clé, acceptée par la liste)' {
        Remove-Item -LiteralPath "$zipSigne.sig" -ErrorAction SilentlyContinue
        $refus = (Test-Refus { Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpFaux } } 'Mot de passe incorrect') -and -not (Test-Path -LiteralPath "$zipSigne.sig")
        $null = Invoke-OutilCle 'signer.ps1' @{ Fichier = $zipSigne; MotDePasse = $mdpTest }
        $seule = New-ListeTest 'jetable-seule' ([ordered]@{ 'j.xml' = $script:Jetable.Publique })
        $refus -and (Test-SigneParListe) -and (Test-Signature ([IO.File]::ReadAllBytes($zipSigne)) ([IO.File]::ReadAllBytes("$zipSigne.sig")) $seule)
    }
    Test-Cas 'cle.ps1 -Convertir une seconde fois : refusé (déjà protégée)' { Test-Refus { Invoke-OutilCle 'cle.ps1' @{ Convertir = $true; MotDePasse = $mdpTest } } 'déjà protégée' }
    Test-Cas 'cle.ps1 -Exporter : demande le mot de passe de la clé (faux : refusé, rien écrit)' {
        $f = Join-Path $tmp 'usb\export.msk'
        (Test-Refus { Invoke-OutilCle 'cle.ps1' @{ Exporter = $f; MotDePasse = $mdpFaux } } 'Mot de passe incorrect') -and -not (Test-Path -LiteralPath $f)
    }
} finally {
    $env:APPDATA = $appdataVrai
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch { Write-Host "Dossier de test non supprimé : $tmp ($($_.Exception.Message))" -ForegroundColor Yellow }
}

$total = $script:Reussis + $script:Echoues.Count + $script:Connus.Count
Write-Host ''
if ($script:Connus.Count) {
    Write-Host "Défauts connus, à corriger ($($script:Connus.Count)) :" -ForegroundColor Yellow
    $script:Connus | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($script:Echoues.Count) {
    Write-Host "Résultat : $($script:Echoues.Count) échec(s) sur $total cas." -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Résultat : $($script:Reussis) cas réussis sur $total, aucun échec$(if ($script:Connus.Count) { " ($($script:Connus.Count) défaut(s) connu(s))" })." -ForegroundColor Green
exit 0
