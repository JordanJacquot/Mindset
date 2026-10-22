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

# installer-admin.ps1 exécute du code dès son chargement : on n'en prend que les fonctions voulues (lues par l'analyseur)
$texte = [IO.File]::ReadAllText((Join-Path $fichiers 'installer-admin.ps1'), [Text.Encoding]::UTF8)
$erreurs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($texte, [ref]$null, [ref]$erreurs)
if ($erreurs) { throw "installer-admin.ps1 illisible : $($erreurs[0].Message)" }
$voulues = @('Test-DossierMindset')
$defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $voulues }, $true))
if ($defs.Count -ne $voulues.Count) { throw 'installer-admin.ps1 : fonction Test-DossierMindset introuvable.' }
foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

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
    Test-Cas 'la clé livrée avec Mindset est publique seulement et fait au moins 3072 bits' {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        try { $rsa.FromXmlString([IO.File]::ReadAllText((Join-Path $fichiers 'cle-publique.xml'), [Text.Encoding]::UTF8)); $rsa.PublicOnly -and $rsa.KeySize -ge 3072 }
        finally { $rsa.Dispose() }
    }

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

    # Le reste de paquets.ps1 qui protège quelque chose
    Test-Cas 'téléchargement refusé hors de GitHub (sans aller sur Internet)' {
        $ok = $true
        foreach ($u in 'http://github.com/a/b.zip', 'https://exemple.com/b.zip', 'https://github.com.exemple.com/b.zip',
                       'https://github.com@exemple.com/b.zip', 'https://exemple.com/https://github.com/b.zip', 'file:///C:/Windows/win.ini', '') {
            if (-not (Test-Refus { Get-Octets $u } 'Adresse de téléchargement refusée')) { $ok = $false; Write-Host "    accepté : $u" }
        }
        $ok
    }
    Test-Cas 'comparaison de versions : illisible = pas plus récente' {
        (Test-VersionPlusRecente '2.0.1' '2.0.0') -and -not (Test-VersionPlusRecente '2.0.0' '2.0.0') -and
        -not (Test-VersionPlusRecente 'abc' '1.0.0') -and -not (Test-VersionPlusRecente '' '1.0.0') -and -not (Test-VersionPlusRecente '1.0.0' '1.0.1')
    }

    # =============================================================================================================
    Write-Partie 'Test-DossierMindset (installer-admin.ps1)'
    # =============================================================================================================
    $pf = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Mindset'))
    function Test-Accepte([string]$Dossier, [string]$Attendu) { try { (Test-DossierMindset $Dossier) -eq $Attendu } catch { $false } }

    Test-Cas 'Program Files\Mindset\Nevermind accepté' { Test-Accepte "$pf\Nevermind" "$pf\Nevermind" }
    Test-Cas 'Program Files\Mindset\Mindset\ (barre finale) accepté, sans la barre' { Test-Accepte "$pf\Mindset\" "$pf\Mindset" }
    Test-Cas 'Program Files\Mindset, sans sous dossier, refusé' { Test-Refus { Test-DossierMindset $pf } 'Dossier refusé' }
    Test-Cas 'dossier trop profond (Program Files\Mindset\Nevermind\fichiers) refusé' { Test-Refus { Test-DossierMindset "$pf\Nevermind\fichiers" } 'Dossier refusé' }
    Test-Cas 'remontée avec .. (Program Files\Mindset\..\Windows) refusée' { Test-Refus { Test-DossierMindset "$pf\..\Windows" } 'Dossier refusé' }
    Test-Cas 'remontée avec .. depuis un sous dossier (Mindset\Nevermind\..\..\Autre) refusée' { Test-Refus { Test-DossierMindset "$pf\Nevermind\..\..\Autre" } 'Dossier refusé' }
    Test-Cas 'un .. qui reste dedans est ramené à sa vraie place (Mindset\x\..\Evermind = Mindset\Evermind)' { Test-Accepte "$pf\x\..\Evermind" "$pf\Evermind" }
    Test-Cas 'nom proche (Program Files\MindsetPiege\X) refusé' { Test-Refus { Test-DossierMindset "$($pf)Piege\X" } 'Dossier refusé' }
    Test-Cas 'dossier système (C:\Windows\System32) refusé' { Test-Refus { Test-DossierMindset "$env:SystemRoot\System32" } 'Dossier refusé' }
    Test-Cas 'flux NTFS (Program Files\Mindset\X:flux) refusé' { Test-Refus { Test-DossierMindset "$pf\X:flux" } }
    Test-Cas 'chemin réseau (\\serveur\partage\Mindset\Programmes\X) refusé' { Test-Refus { Test-DossierMindset '\\serveur\partage\Mindset\Programmes\X' } }
    Test-Cas 'chemin long (\\?\...Program Files\Mindset\X) refusé' { Test-Refus { Test-DossierMindset "\\?\$pf\X" } }
    Test-Cas 'chemin relatif refusé' { Test-Refus { Test-DossierMindset 'Mindset\Programmes\X' } }
    $script:DisquesVerifies = @()
    Test-Cas 'autre disque : D:\Mindset\Programmes\Evermind accepté, après vérification du disque D:' {
        (Test-Accepte 'D:\Mindset\Programmes\Evermind' 'D:\Mindset\Programmes\Evermind') -and ($script:DisquesVerifies -contains 'D')
    }
    Test-Cas 'autre disque qui n''est pas un disque fixe NTFS (Z:) refusé' { Test-Refus { Test-DossierMindset 'Z:\Mindset\Programmes\Evermind' } 'disque fixe' }
    Test-Cas 'D:\Mindset\Programmes, sans sous dossier, refusé' { Test-Refus { Test-DossierMindset 'D:\Mindset\Programmes' } 'Dossier refusé' }
    Test-Cas 'D:\Mindset\Programmes\a\b (trop profond) refusé' { Test-Refus { Test-DossierMindset 'D:\Mindset\Programmes\a\b' } 'Dossier refusé' }
    Test-Cas 'D:\Mindset\Programmes\..\Donnees refusé' { Test-Refus { Test-DossierMindset 'D:\Mindset\Programmes\..\Donnees' } 'Dossier refusé' }
    Test-Cas 'D:\Mindset\Donnees\X (les données, pas les programmes) refusé' { Test-Refus { Test-DossierMindset 'D:\Mindset\Donnees\X' } 'Dossier refusé' }
    Test-Cas 'D:\Autre\Mindset\Programmes\X (pas à la racine du disque) refusé' { Test-Refus { Test-DossierMindset 'D:\Autre\Mindset\Programmes\X' } 'Dossier refusé' }
} finally {
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
