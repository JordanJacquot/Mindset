# Mindset : tests de l'écriture sûre des fichiers de données (réglages, installations, suite.json) : jamais perdus.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-donnees.ps1
#
# On vérifie que :
#   - un fichier s'écrit à côté puis remplace l'ancien d'un coup (l'ancien gardé dans .bak) ; une écriture interrompue ou
#     bloquée laisse l'ancien fichier entier ;
#   - un fichier abîmé est mis de côté (.abime-<date>), noté au journal, et repris de sa copie .bak ;
#   - un fichier qu'un autre programme empêche de lire n'est jamais remplacé par une liste vide ;
#   - un réglage coupé par l'utilisateur (« Chercher les nouvelles versions », mises à jour automatiques) ne se rallume
#     jamais tout seul, même si reglages.json est abîmé sans copie.
# Tout se passe dans un dossier temporaire sous %TEMP%, supprimé à la fin : rien n'est lu ni écrit dans les vraies
# données de Mindset, aucun droit administrateur, aucun réseau.
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub, .github\workflows\tests.yml).

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'
$modules = Join-Path $fichiers 'modules'

$script:Reussis = 0
$script:Echoues = @()
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
    }
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

$tmp = Join-Path $env:TEMP "mindset-donnees-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName
$ancienDonnees = $env:MINDSET_DONNEES
$utf8 = New-Object Text.UTF8Encoding $false
function Save-Brut([string]$Fichier, [string]$Texte) { [IO.File]::WriteAllText($Fichier, $Texte, $utf8) }
function Get-Brut([string]$Fichier) { [IO.File]::ReadAllText($Fichier, [Text.Encoding]::UTF8) }
# Ce que le journal a reçu depuis le dernier appel
$script:LuJournal = 0
function Get-JournalNouveau {
    $t = try { Get-Brut $LogFile } catch { '' }
    $n = $t.Substring([math]::Min($script:LuJournal, $t.Length)); $script:LuJournal = $t.Length; $n
}
# Vide un dossier de test de ses fichiers (sans toucher au journal)
function Clear-Fichiers([string]$Motif) { Get-ChildItem -Path (Join-Path $DataDir $Motif) -File -ErrorAction SilentlyContinue | Remove-Item -Force }

try {
    # Mindset de test : ses données dans $tmp (MINDSET_DONNEES), jamais dans le vrai %LOCALAPPDATA%\Mindset
    $EnTest = $true
    $env:MINDSET_DONNEES = $tmp
    $AppDir = Join-Path $tmp 'Programmes\Mindset\fichiers'
    . (Join-Path $modules 'donnees.ps1')
    . (Join-Path $modules 'suite.ps1')
    $asts = [System.Management.Automation.Language.Parser]::ParseInput((Get-Brut (Join-Path $modules 'installations.ps1')), [ref]$null, [ref]$null)
    foreach ($x in @($asts.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Read-Installations', 'Save-Installation' }, $true))) {
        . ([scriptblock]::Create($x.Extent.Text))
    }
    $InstallFile = Join-Path $DataDir 'installations.json'

    Write-Partie 'Préparation'
    Test-Cas 'Les données de test sont dans le dossier temporaire (jamais les vraies)' { $DataDir -eq (Join-Path $tmp 'Mindset') -and $SettingsFile -like "$tmp\*" -and $SuiteFile -like "$tmp\*" }

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '1. Écriture sûre'
    # ---------------------------------------------------------------------------------------------------------------
    $f = Join-Path $DataDir 'essai.json'
    Save-JsonSur $f '{ "n": 1 }'
    Test-Cas 'Première écriture : le fichier est là, sans copie ni fichier temporaire' { (Get-Brut $f) -match '"n": 1' -and -not (Test-Path "$f.bak") -and -not (Test-Path "$f.tmp") }
    Save-JsonSur $f '{ "n": 2 }'
    Test-Cas 'Écriture suivante : le nouveau remplace l''ancien, gardé dans .bak' { (Get-Brut $f) -match '"n": 2' -and (Get-Brut "$f.bak") -match '"n": 1' -and -not (Test-Path "$f.tmp") }

    # Coupure en pleine écriture : le fichier temporaire est resté à moitié écrit, le vrai n'a pas été touché
    Save-Brut "$f.tmp" '{ "n": 3, "coup'
    Test-Cas 'Écriture interrompue (coupure de courant) : l''ancien fichier est relu entier' { (Read-JsonSur $f).n -eq 2 }
    Save-JsonSur $f '{ "n": 4 }'
    Test-Cas 'Et l''écriture suivante passe quand même' { (Read-JsonSur $f).n -eq 4 -and -not (Test-Path "$f.tmp") }

    # Remplacement bloqué (le fichier ouvert par un autre programme) : une erreur, l'ancien reste entier, pas de .tmp
    $flux = [IO.File]::Open($f, 'Open', 'Read', 'Read')
    try { $refus = $false; try { Save-JsonSur $f '{ "n": 5 }' } catch { $refus = $true } } finally { $flux.Dispose() }
    Test-Cas 'Remplacement impossible : une erreur, l''ancien fichier reste entier, aucun fichier temporaire ne traîne' { $refus -and (Read-JsonSur $f).n -eq 4 -and -not (Test-Path "$f.tmp") }

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '2. Fichier abîmé'
    # ---------------------------------------------------------------------------------------------------------------
    $null = Get-JournalNouveau
    Save-JsonSur $f '{ "n": 6 }'   # (.bak : n = 4)
    Save-Brut $f '{ "n": 7, "coup'
    $j = Read-JsonSur $f
    $abimes = @(Get-ChildItem -Path "$f.abime-*")
    $journal = Get-JournalNouveau
    Test-Cas 'Fichier abîmé : repris de sa copie .bak' { $j.n -eq 4 }
    Test-Cas 'Le fichier abîmé est mis de côté (.abime-<date>), jamais effacé' { $abimes.Count -eq 1 -and (Get-Brut $abimes[0].FullName) -eq '{ "n": 7, "coup' }
    Test-Cas 'Le fichier est remis en place depuis sa copie' { (ConvertFrom-JsonObjet (Get-Brut $f)).n -eq 4 }
    Test-Cas 'C''est noté au journal' { $journal -match 'essai\.json abîmé \(illisible\) : mis de côté' -and $journal -match 'repris de sa copie' }

    foreach ($t in '', '   ', '[1, 2]', '"texte"', '{ "a": ') {
        Save-Brut $f $t; Save-Brut "$f.bak" '{ "n": 8 }'
        $j = Read-JsonSur $f
        if ($j.n -ne 8) { break }
    }
    Test-Cas 'Vide, coupé, ou autre chose qu''un objet : abîmé aussi' { $j.n -eq 8 }

    Clear-Fichiers 'essai.json*'
    Save-Brut $f '{ "n": 9'; Save-Brut "$f.bak" 'pas du json'
    $null = Get-JournalNouveau
    $j = Read-JsonSur $f
    $journal = Get-JournalNouveau
    Test-Cas 'Fichier et copie abîmés : rien (pas d''erreur), le texte abîmé est donné, et c''est noté' { $null -eq $j -and $script:JsonAbime -eq '{ "n": 9' -and $journal -match 'aucune copie lisible' -and -not (Test-Path $f) }
    Test-Cas 'Fichier absent : rien, sans rien noter d''abîmé' { Clear-Fichiers 'essai.json*'; $null -eq (Read-JsonSur $f) -and $null -eq $script:JsonAbime }

    # Fichier qu'un autre programme empêche de lire : une erreur (jamais « vide », qui ferait tout écraser)
    Save-JsonSur $f '{ "n": 10 }'
    $flux = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None')
    try { $refus = $false; try { $null = Read-JsonSur $f } catch { $refus = $true } } finally { $flux.Dispose() }
    Test-Cas 'Fichier pris par un autre programme : une erreur, et il n''est pas mis de côté comme abîmé' { $refus -and (Read-JsonSur $f).n -eq 10 -and -not @(Get-ChildItem -Path "$f.abime-*").Count }

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '3. installations.json et suite.json'
    # ---------------------------------------------------------------------------------------------------------------
    Save-Installation 'evermind' 'C:\Programmes\Evermind' $true
    Save-Installation 'nevermind' 'C:\Programmes\Nevermind' $true
    Save-Installation 'mindcare' 'C:\Programmes\Mindcare' $true
    $flux = [IO.File]::Open($InstallFile, 'Open', 'ReadWrite', 'None')
    try { Save-Installation 'evermind' $null $false; $pendant = Read-Installations } finally { $flux.Dispose() }
    $r = Read-Installations
    Test-Cas 'installations.json pris par un autre programme : pas réécrit avec une liste vide, rien de perdu' { $r.Count -eq 3 -and $r['evermind'].Gere -and $pendant.Count -eq 0 }
    Save-Brut $InstallFile '{ "evermind": { "dossier": "C:\\Prog'
    $r = Read-Installations
    Test-Cas 'installations.json abîmé : repris de sa copie (les applis installées ne sont pas oubliées)' { $r.Count -ge 2 -and $r['nevermind'].Dossier -eq 'C:\Programmes\Nevermind' }

    $s = Read-Suite; $s.theme = 'rubis'; $s.applis['evermind'] = 'C:\Programmes\Evermind'; Write-Suite $s
    $s = Read-Suite; $s.theme = 'neon'; Write-Suite $s
    Test-Cas 'suite.json : écrit d''un coup, l''ancien gardé dans suite.json.bak' { (Read-Suite).theme -eq 'neon' -and (ConvertFrom-JsonObjet (Get-Brut "$SuiteFile.bak")).theme -eq 'rubis' -and -not (Test-Path "$SuiteFile.tmp") }
    $flux = [IO.File]::Open($SuiteFile, 'Open', 'ReadWrite', 'None')
    try { $s = Read-Suite; $s.theme = 'arcade'; Write-Suite $s } finally { $flux.Dispose() }
    $s = Read-Suite
    Test-Cas 'suite.json pris par un autre programme : pas réécrit (la liste des applis est gardée)' { $s.theme -eq 'neon' -and $s.applis['evermind'] -eq 'C:\Programmes\Evermind' }
    Save-Brut $SuiteFile '{ "theme": "arc'
    $s = Read-Suite
    Test-Cas 'suite.json abîmé : repris de sa copie' { $s.theme -eq 'rubis' -and $s.applis['evermind'] -eq 'C:\Programmes\Evermind' }

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '4. Réglages : un réglage coupé reste coupé'
    # ---------------------------------------------------------------------------------------------------------------
    $EnTest = $false   # (Set-Setting écrit alors vraiment : dans le reglages.json de test)
    try {
        Clear-Fichiers 'reglages.json*'
        $script:Settings = @{}; $script:ReglagesChanges = @{}; $script:ReglagesIllisibles = $false
        Set-Setting 'VerifVersions' $false
        Set-Setting 'MajAuto' $false
        Set-Setting 'Fermeture' 'quitter'
        Set-Setting 'Animations' 'completes'
        Test-Cas 'Réglages écrits d''un coup, l''ancien gardé dans reglages.json.bak' { (ConvertFrom-JsonObjet (Get-Brut $SettingsFile)).Fermeture -eq 'quitter' -and (Test-Path "$SettingsFile.bak") -and -not (Test-Path "$SettingsFile.tmp") }

        Save-Brut $SettingsFile '{ "VerifVersions": false, "MajAuto": fa'
        $r = Read-Reglages
        Test-Cas 'reglages.json abîmé : repris de sa copie, « Chercher les nouvelles versions » et MajAuto restent coupés' { $r['VerifVersions'] -eq $false -and $r['MajAuto'] -eq $false -and $r['Fermeture'] -eq 'quitter' }

        # Fichier et copie abîmés : ce qui s'y lit encore est repris, le reste des réglages « prudents » reste coupé
        Clear-Fichiers 'reglages.json*'
        Save-Brut $SettingsFile "{`r`n  `"LancerAvecWindows`": false,`r`n  `"VerifVersions`": false,`r`n  `"Demarrage`": [ `"evermind`", `"mindcare`" ],`r`n  `"Fermeture`": `"reduire`",`r`n  `"Animations`": `"compl"
        $r = Read-Reglages
        Test-Cas 'reglages.json abîmé sans copie : ce qui s''y lit encore est repris (lancement avec Windows, applis au démarrage...)' { $r['LancerAvecWindows'] -eq $false -and $r['VerifVersions'] -eq $false -and @($r['Demarrage']).Count -eq 2 -and $r['Fermeture'] -eq 'reduire' -and -not $r.ContainsKey('Animations') }
        Test-Cas 'Et les mises à jour automatiques, illisibles, restent coupées par prudence (noté au journal)' { $r['MajAuto'] -eq $false -and (Get-JournalNouveau) -match 'Réglage MajAuto perdu : coupé par prudence' }

        Clear-Fichiers 'reglages.json*'
        Save-Brut $SettingsFile ''
        $r = Read-Reglages
        Test-Cas 'reglages.json vide sans copie : rien n''est rallumé (VerifVersions et MajAuto coupés)' { $r['VerifVersions'] -eq $false -and $r['MajAuto'] -eq $false }

        Clear-Fichiers 'reglages.json*'
        $r = Read-Reglages
        Test-Cas 'Pas encore de reglages.json (premier lancement) : valeurs par défaut, rien de coupé' { $r.Count -eq 0 -and -not $script:ReglagesRepris }

        # Au démarrage : les réglages repris d'un fichier abîmé sont écrits tout de suite (sinon, au lancement suivant, le
        # fichier abîmé étant mis de côté, les valeurs par défaut reviendraient)
        Save-Brut $SettingsFile '{ "VerifVersions": false, "ReduireHorl'
        $EnTest = $true
        . (Join-Path $modules 'donnees.ps1')
        $apres1 = Get-Setting 'VerifVersions' $true
        . (Join-Path $modules 'donnees.ps1')
        $apres2 = Get-Setting 'VerifVersions' $true
        $majAuto2 = Get-Setting 'MajAuto' $true
        $EnTest = $false
        Test-Cas 'Démarrage avec reglages.json abîmé : réglage coupé, et toujours coupé au lancement suivant' { $apres1 -eq $false -and $apres2 -eq $false -and $majAuto2 -eq $false }

        # reglages.json pris par un autre programme au démarrage : pas réécrit avec les valeurs par défaut
        Clear-Fichiers 'reglages.json*'
        $script:Settings = @{}; $script:ReglagesChanges = @{}
        Set-Setting 'VerifVersions' $false; Set-Setting 'Fermeture' 'quitter'
        $flux = [IO.File]::Open($SettingsFile, 'Open', 'ReadWrite', 'None')
        try {
            $script:Settings = Read-Reglages; $script:ReglagesChanges = @{}
            $illisible = $script:ReglagesIllisibles
            $verifPendant = Get-Setting 'VerifVersions' $true
            Set-Setting 'Animations' 'reduites'
        } finally { $flux.Dispose() }
        Test-Cas 'reglages.json illisible au démarrage : VerifVersions reste coupé, rien n''est écrit tant qu''il ne se lit pas' { $illisible -and $verifPendant -eq $false -and -not (ConvertFrom-JsonObjet (Get-Brut $SettingsFile)).PSObject.Properties['Animations'] }
        Set-Setting 'Animations' 'reduites'
        $j = ConvertFrom-JsonObjet (Get-Brut $SettingsFile)
        Test-Cas 'Dès qu''il se lit : relu, puis le changement est ajouté sans perdre les autres réglages' { $j.Animations -eq 'reduites' -and $j.VerifVersions -eq $false -and $j.Fermeture -eq 'quitter' -and -not $script:ReglagesIllisibles }
    } finally { $EnTest = $true }

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '5. Plus aucune écriture directe d''un fichier de données'
    # ---------------------------------------------------------------------------------------------------------------
    $directes = foreach ($m in Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File) {
        foreach ($l in (Get-Brut $m.FullName) -split "`r?`n") {
            if ($l -match 'WriteAllText\(\s*\$(SettingsFile|InstallFile|SuiteFile|FichierHistoriqueMaj)\b' -or $l -match 'Move-Item .*SuiteFile') { "$($m.Name) : $($l.Trim())" }
        }
    }
    Test-Cas 'reglages.json, installations.json, suite.json et l''historique ne passent que par Save-JsonSur' { -not @($directes).Count }
    if (@($directes).Count) { $directes | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow } }
} finally {
    $env:MINDSET_DONNEES = $ancienDonnees
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Echoues.Count) {
    Write-Host "$($script:Reussis) réussi(s), $($script:Echoues.Count) échoué(s) :" -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Tous les tests réussissent ($($script:Reussis))." -ForegroundColor Green
