# Mindset : tests des journaux et des restes sur le disque.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-journaux.ps1
#
# On vérifie que :
#   1. Mindset.exe (outils\lanceur.cs, compilé à la volée) note ses erreurs dans le journal des données de son installation
#      (X:\Mindset\Donnees\Mindset sur un autre disque), comme le code de Mindset, et plus dans %LOCALAPPDATA% ; les lignes
#      déjà écrites au mauvais endroit rejoignent le vrai journal ;
#   2. l'ancien dossier console-webview est supprimé au démarrage s'il n'a pas servi depuis 14 jours, jamais s'il sert
#      encore ou si un WebView2 le tient ouvert ;
#   3. réimporter un thème déjà installé ne l'abîme jamais : si une appli ouverte tient un de ses fichiers, l'ancienne
#      version reste entière, et la nouvelle est mise en place au prochain démarrage de Mindset ;
#   4. une appli fermée depuis elle-même n'écrit plus « ne s'est pas affiché après 60 s » dans le journal ; une vraie
#      relance ratée, oui.
# Tout se passe dans un faux PC sous %TEMP% (faux dossier d'installation, faux %LOCALAPPDATA%, fausses applis), supprimé à la
# fin : aucune vraie donnée, aucune vraie appli, aucun droit administrateur, aucun réseau.
# -Racine : le dépôt à tester (par défaut celui-ci ; une autre copie sert de contre-épreuve).
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub, .github\workflows\tests.yml).

param([string]$Racine = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$modules = Join-Path $Racine 'Mindset\fichiers\modules'
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

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

$tmp = Join-Path $env:TEMP "mindset-journaux-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName   # (en nom long : sur GitHub, TEMP est en nom court)
$utf8 = New-Object Text.UTF8Encoding $false
function Get-Brut([string]$Fichier) { [IO.File]::ReadAllText($Fichier, [Text.Encoding]::UTF8) }
function Set-Brut([string]$Fichier, [string]$Texte) { New-Item -ItemType Directory -Force -Path (Split-Path $Fichier -Parent) | Out-Null; [IO.File]::WriteAllText($Fichier, $Texte, $utf8) }
# Vieillit un dossier (fichiers et sous-dossiers) de $Jours jours
function Set-Vieux([string]$Dossier, [int]$Jours) {
    $t = (Get-Date).AddDays(-$Jours)
    foreach ($f in [IO.Directory]::GetFiles($Dossier, '*', 'AllDirectories')) { [IO.File]::SetLastWriteTime($f, $t) }
    foreach ($d in @([IO.Directory]::GetDirectories($Dossier, '*', 'AllDirectories')) + $Dossier) { [IO.Directory]::SetLastWriteTime($d, $t) }
}
# Un faux dossier WebView2 (quelques fichiers comme ceux de console-webview)
function New-FauxWebview([string]$Dossier) {
    Set-Brut (Join-Path $Dossier 'EBWebView\Local State') '{}'
    Set-Brut (Join-Path $Dossier 'EBWebView\Default\Preferences') '{}'
    Set-Brut (Join-Path $Dossier 'EBWebView\ShaderCache\data_1') 'x'
}

$ancienDonnees = $env:MINDSET_DONNEES
$ouverts = @()
$lances = @()
try {
    # Le faux PC : Mindset installé sur un autre disque (<tmp>\Mindset\Programmes\Mindset), ses données à côté
    $prog = Join-Path $tmp 'Mindset\Programmes\Mindset'
    $donnees = Join-Path $tmp 'Mindset\Donnees\Mindset'
    $local = Join-Path $tmp 'LocalAppData'
    New-Item -ItemType Directory -Force -Path (Join-Path $prog 'fichiers'), $donnees, $local | Out-Null

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '1. Journal des plantages de Mindset.exe au bon endroit'
    # ---------------------------------------------------------------------------------------------------------------
    $exe = Join-Path $prog 'Mindset.exe'
    $sma = [psobject].Assembly.Location
    $sortie = & $csc /nologo /target:winexe /platform:anycpu /reference:System.Windows.Forms.dll "/reference:$sma" "/out:$exe" (Join-Path $Racine 'outils\lanceur.cs')
    if ($LASTEXITCODE) { throw "Compilation de lanceur.cs impossible : $sortie" }
    $type = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe)).GetType('Lanceur')
    $prive = [Reflection.BindingFlags]'NonPublic, Static'
    $mDisque = $type.GetMethod('DonneesSurAutreDisque', $prive)
    $mDonnees = $type.GetMethod('DossierDonnees', $prive)
    Test-Cas 'Mindset.exe déduit son dossier de données de son emplacement' { $null -ne $mDisque -and $null -ne $mDonnees }

    # Même règle que Get-RacinesDepuis (modules\donnees.ps1), sur des dossiers jamais vus
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $modules 'donnees.ps1'), [ref]$null, [ref]$null)
    $f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RacinesDepuis' }, $true)
    $SuiteFileDir = Join-Path $local 'Mindset'
    . ([scriptblock]::Create($f.Extent.Text))
    $ecarts = @()
    if ($mDisque) {
        # (lecteur C: seulement : Join-Path, dans Get-RacinesDepuis, refuse un lecteur absent du PC)
        foreach ($d in 'C:\Mindset\Programmes\Mindset', 'c:\mindset\programmes\Mindset\', 'C:\Jeux\Mindset\Programmes\Mindset', 'C:\Mindset\Programmes\Autre',
                       'C:\Program Files\Mindset\Mindset', 'C:\Programmes\Mindset', 'C:\Mindset\Mindset', 'C:\Mindset\Programmes\Mindset\Mindset', "$prog") {
            $ps = (Get-RacinesDepuis $d.TrimEnd('\'))
            $attendu = if ($ps.Disque) { Join-Path $ps.Donnees 'Mindset' } else { $null }
            $cs = $mDisque.Invoke($null, @([string]$d))
            if ([string]$cs -ine [string]$attendu) { $ecarts += "$d : $cs au lieu de $attendu" }
        }
    }
    Test-Cas 'Même règle que le code de Mindset, sur 9 dossiers (autre disque, Program Files, noms proches)' { $mDisque -and -not $ecarts.Count }
    $ecarts | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
    Test-Cas 'Installé sur un autre disque : le journal va dans ses données, pas dans %LOCALAPPDATA%' { $mDonnees -and [string]$mDonnees.Invoke($null, @("$prog\")) -ieq $donnees }

    # En vrai : une erreur dans le code (faux Mindset.ps1) est notée par Mindset.exe dans le journal du faux PC.
    # (Seulement si le lanceur sait trouver ce dossier : sinon il écrirait dans le vrai %LOCALAPPDATA%.)
    $journal = Join-Path $donnees 'journal.txt'
    $vraiJournal = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Mindset\Mindset\journal.txt'
    $vraiAvant = if (Test-Path -LiteralPath $vraiJournal) { (Get-Item -LiteralPath $vraiJournal).Length } else { -1 }
    if ($mDonnees) {
        Set-Brut (Join-Path $prog 'fichiers\Mindset.ps1') "Write-Error 'essai du journal des plantages'"
        $p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
        $lances += $p
        if (-not $p.WaitForExit(60000)) { $p.Kill() }
    }
    Test-Cas 'Une erreur de Mindset.exe est notée dans le journal de son installation' { (Test-Path -LiteralPath $journal) -and (Get-Brut $journal) -match 'Erreurs : essai du journal des plantages' }
    Test-Cas 'Rien d''écrit dans le vrai %LOCALAPPDATA%\Mindset' { $vraiAvant -eq $(if (Test-Path -LiteralPath $vraiJournal) { (Get-Item -LiteralPath $vraiJournal).Length } else { -1 }) }

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '2. Démarrage : anciennes lignes reprises, ancien dossier console-webview supprimé'
    # ---------------------------------------------------------------------------------------------------------------
    # Ce qu'une ancienne version a laissé : des plantages notés dans %LOCALAPPDATA%\Mindset\Mindset\journal.txt
    Set-Brut (Join-Path $local 'Mindset\Mindset\journal.txt') "2026-10-01T10:00:00 Arrêt inattendu : essai d'un ancien plantage`r`n"
    New-FauxWebview (Join-Path $donnees 'console-webview'); Set-Vieux (Join-Path $donnees 'console-webview') 20
    New-Item -ItemType Directory -Force -Path (Join-Path $donnees 'console-logos') | Out-Null
    # Trois autres dossiers de données : console-webview qui sert encore, un tenu ouvert par un WebView2, un reste à finir
    $recent = Join-Path $tmp 'recent'; New-FauxWebview (Join-Path $recent 'console-webview'); Set-Vieux (Join-Path $recent 'console-webview') 20
    [IO.File]::SetLastWriteTime((Join-Path $recent 'console-webview\EBWebView\Local State'), (Get-Date).AddDays(-2))
    $pris = Join-Path $tmp 'pris'; New-FauxWebview (Join-Path $pris 'console-webview'); Set-Vieux (Join-Path $pris 'console-webview') 20
    $reste = Join-Path $tmp 'reste'; New-FauxWebview (Join-Path $reste 'console-webview.a-supprimer')
    $flux = [IO.File]::Open((Join-Path $pris 'console-webview\EBWebView\Local State'), 'Open', 'ReadWrite', 'ReadWrite')
    $ouverts += $flux
    # Le démarrage de Mindset (modules\donnees.ps1) dans un autre PowerShell, avec le faux %LOCALAPPDATA%
    $enfant = Join-Path $tmp 'demarrage.ps1'
    Set-Brut $enfant @'
param($Modules, $AppDir, $Local, [string]$Autres)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = $Local
$EnTest = $false
. (Join-Path $Modules 'donnees.ps1')
if (Get-Command Clear-RestesDisque -ErrorAction SilentlyContinue) { foreach ($d in $Autres -split '\|') { Clear-RestesDisque $d } }
'@
    $sortie = & powershell -NoProfile -ExecutionPolicy Bypass -File $enfant -Modules $modules -AppDir (Join-Path $prog 'fichiers') -Local $local -Autres "$recent|$pris|$reste"
    if ($LASTEXITCODE) { Write-Host "         $sortie" -ForegroundColor Yellow }
    $flux.Dispose()
    $t = Get-Brut $journal
    Test-Cas 'Les plantages notés au mauvais endroit rejoignent le vrai journal' { $t -match 'Arrêt inattendu : essai d''un ancien plantage' -and $t -match 'Erreurs : essai du journal' }
    Test-Cas 'L''ancien fichier est supprimé (pas repris deux fois)' { -not (Test-Path -LiteralPath (Join-Path $local 'Mindset\Mindset\journal.txt')) }
    Test-Cas 'console-webview pas servi depuis 20 jours : supprimé, sans rien laisser' { -not (Test-Path -LiteralPath (Join-Path $donnees 'console-webview')) -and -not (Test-Path -LiteralPath (Join-Path $donnees 'console-webview.a-supprimer')) }
    Test-Cas 'Les autres dossiers des données ne bougent pas' { (Test-Path -LiteralPath (Join-Path $donnees 'console-logos')) -and (Test-Path -LiteralPath $journal) }
    Test-Cas 'console-webview qui a servi il y a 2 jours : gardé' { Test-Path -LiteralPath (Join-Path $recent 'console-webview\EBWebView\Default\Preferences') }
    Test-Cas 'console-webview tenu ouvert par un WebView2 : gardé entier' { @([IO.Directory]::GetFiles((Join-Path $pris 'console-webview'), '*', 'AllDirectories')).Count -eq 3 }
    Test-Cas 'Un reste d''une suppression pas finie : retiré au démarrage suivant' { -not (Test-Path -LiteralPath (Join-Path $reste 'console-webview.a-supprimer')) }

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '3. Réimporter un thème déjà installé, même pris par une appli ouverte'
    # ---------------------------------------------------------------------------------------------------------------
    $EnTest = $true
    $env:MINDSET_DONNEES = Join-Path $tmp 'suite'
    $AppDir = Join-Path $prog 'fichiers'
    . (Join-Path $modules 'donnees.ps1')
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $modules 'packs.ps1'), [ref]$null, [ref]$null)
    foreach ($x in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))) { . ([scriptblock]::Create($x.Extent.Text)) }
    $PacksDir = Join-Path $DataDir 'packs'
    $FichierPacksARetirer = Join-Path $DataDir 'packs-a-retirer.txt'
    $PacksEnAttenteDir = Join-Path $DataDir 'packs-en-attente'
    $PacksAnciensDir = Join-Path $DataDir 'packs-anciens'
    $script:Applis = @(@{ Id = 'nevermind'; Nom = 'Nevermind' }, @{ Id = 'evermind'; Nom = 'Evermind' })
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    # Un thème de la suite (zip) : un réglage par appli, une police, une image ; $Version change le nom affiché
    function New-ZipTheme([string]$Fichier, [string]$Version) {
        if (Test-Path -LiteralPath $Fichier) { Remove-Item -LiteralPath $Fichier -Force }
        $z = [IO.Compression.ZipFile]::Open($Fichier, 'Create')
        try {
            $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 1, 2, 3)
            $contenus = [ordered]@{
                'pack-mindset.json' = $utf8.GetBytes("{ `"Name`": `"Essai $Version`", `"Base`": `"neon`" }")
                'pack-nevermind.json' = $utf8.GetBytes("{ `"Name`": `"Essai $Version`" }")
                'pack-evermind.json' = $utf8.GetBytes("{ `"Name`": `"Essai $Version`" }")
                'police.ttf' = $utf8.GetBytes("police $Version"); 'fond.png' = $png }
            foreach ($n in $contenus.Keys) { $s = $z.CreateEntry($n).Open(); try { $s.Write($contenus[$n], 0, $contenus[$n].Length) } finally { $s.Dispose() } }
        } finally { $z.Dispose() }
    }
    $zip = Join-Path $tmp 'Thème-essai.zip'
    $nev = Join-Path $SuiteDir 'Nevermind\packs\essai'
    $eve = Join-Path $SuiteDir 'Evermind\packs\essai'
    $nomDe = { param($d) try { (Get-Brut (Join-Path $d 'pack.json') | ConvertFrom-Json).Name } catch { $null } }
    New-ZipTheme $zip '1'
    $id = Import-PackSuite $zip
    Test-Cas 'Thème importé pour Mindset et chaque appli' { $id -eq 'essai' -and (& $nomDe $nev) -eq 'Essai 1' -and (& $nomDe $eve) -eq 'Essai 1' -and (& $nomDe (Join-Path $PacksDir 'essai')) -eq 'Essai 1' }

    # Nevermind, ouvert, tient la police du thème (comme une police chargée) ; on réimporte une nouvelle version
    New-ZipTheme $zip '2'
    $flux = [IO.File]::Open((Join-Path $nev 'police.ttf'), 'Open', 'Read', 'ReadWrite')
    $ouverts += $flux
    $erreur = $null
    try { [void](Import-PackSuite $zip) } catch { $erreur = $_.Exception.Message }
    $fichiersNev = @(if (Test-Path -LiteralPath $nev) { [IO.Directory]::GetFiles($nev) | ForEach-Object { Split-Path $_ -Leaf } })
    Test-Cas 'Réimport pendant qu''une appli tient un fichier : pas d''erreur affichée' { -not $erreur }
    if ($erreur) { Write-Host "         $erreur" -ForegroundColor Yellow }
    Test-Cas 'Le thème de l''appli ouverte reste entier (ses 3 fichiers, son ancien réglage)' { $fichiersNev.Count -eq 3 -and (& $nomDe $nev) -eq 'Essai 1' }
    Test-Cas 'Les autres reçoivent tout de suite la nouvelle version' { (& $nomDe $eve) -eq 'Essai 2' -and (& $nomDe (Join-Path $PacksDir 'essai')) -eq 'Essai 2' }
    Test-Cas 'L''appli qui le tient est signalée, sa nouvelle version attend le prochain démarrage' { @($script:PackEnAttente) -contains 'Nevermind' -and (& $nomDe (Join-Path $DataDir 'packs-en-attente\Nevermind\essai')) -eq 'Essai 2' }
    # Encore une version, toujours pris : seule la dernière attend
    New-ZipTheme $zip '3'
    try { [void](Import-PackSuite $zip) } catch { $erreur = $_.Exception.Message }
    Test-Cas 'Réimporté encore une fois : c''est la dernière version qui attend' { -not $erreur -and (& $nomDe (Join-Path $DataDir 'packs-en-attente\Nevermind\essai')) -eq 'Essai 3' -and (& $nomDe $nev) -eq 'Essai 1' }
    # Prochain démarrage, Nevermind fermé
    $flux.Dispose()
    Clear-PacksARetirer
    Test-Cas 'Au démarrage suivant : la nouvelle version est en place, plus rien n''attend' { (& $nomDe $nev) -eq 'Essai 3' -and -not @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'packs-en-attente') -Recurse -File -ErrorAction SilentlyContinue).Count }
    Test-Cas 'Aucune ancienne version ne reste sur le disque' { -not @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'packs-anciens') -Recurse -ErrorAction SilentlyContinue).Count -and -not (Test-Path -LiteralPath "$nev.nouveau") }

    # Une appli qui tient un fichier en permettant sa suppression (Windows refuse quand même de renommer son dossier) :
    # jamais abîmé non plus, et la nouvelle version est en place au démarrage suivant
    New-ZipTheme $zip '4'
    $flux = [IO.File]::Open((Join-Path $eve 'police.ttf'), 'Open', 'Read', 'ReadWrite, Delete')
    $ouverts += $flux
    $erreur = $null
    try { [void](Import-PackSuite $zip) } catch { $erreur = $_.Exception.Message }
    $nomEve = & $nomDe $eve
    Test-Cas 'Fichier tenu mais supprimable : thème entier (ancienne ou nouvelle version), sans erreur' { -not $erreur -and $nomEve -in 'Essai 3', 'Essai 4' -and @([IO.Directory]::GetFiles($eve)).Count -eq 3 }
    $flux.Dispose()
    Clear-PacksARetirer
    Test-Cas 'Puis la nouvelle version est en place, et aucune ancienne ne reste' { (& $nomDe $eve) -eq 'Essai 4' -and -not @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'packs-anciens') -Recurse -ErrorAction SilentlyContinue).Count }

    # Supprimé pendant qu'une version attend : elle ne revient pas au démarrage suivant
    New-ZipTheme $zip '5'
    $flux = [IO.File]::Open((Join-Path $nev 'police.ttf'), 'Open', 'Read', 'ReadWrite')
    $ouverts += $flux
    try { [void](Import-PackSuite $zip) } catch {}
    $supprime = Remove-PackSuite 'essai'
    $flux.Dispose()
    Clear-PacksARetirer
    Test-Cas 'Thème supprimé pendant qu''une version attend : rien ne revient au démarrage suivant' { -not $supprime -and -not (Test-Path -LiteralPath $nev) -and -not (Test-Path -LiteralPath $eve) -and -not (Test-Path -LiteralPath (Join-Path $PacksDir 'essai')) -and -not @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'packs-en-attente') -Recurse -File -ErrorAction SilentlyContinue).Count }

    # ---------------------------------------------------------------------------------------------------------------
    Write-Partie '4. Plus de fausse ligne « ne s''est pas affiché » quand une appli est fermée'
    # ---------------------------------------------------------------------------------------------------------------
    # La surveillance de integration.ps1 (le minuteur), avec une fausse appli : rien n'est lancé ni accroché
    Add-Type -TypeDefinition @'
using System;
public static class MSIntegration {
    public static bool Ouverte = true;
    public static bool IsWindow(IntPtr h) { return Ouverte; }
    public static bool EstMontree(IntPtr h) { return true; }
    public static void Liberer(IntPtr h, object a, object b) { }
}
'@
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $modules 'integration.ps1'), [ref]$null, [ref]$null)
    $m = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Add_Tick' -and $n.Expression.Extent.Text -eq '$script:IntegrationTimer' }, $true)
    $tick = $m.Arguments[0].ScriptBlock.GetScriptBlock()
    $script:Lignes = @()
    function Write-Log([string]$Texte) { $script:Lignes += $Texte }
    function Write-ErreurImprevue($E) { $script:Lignes += "ERREUR $($E.Message)" }
    function Update-BarreAppli {}
    function Update-HotesVisibles {}
    function Get-Appli([string]$Id) { @{ Id = $Id; Nom = 'Nevermind' } }
    function Show-EcranOuvrir($Appli, [string]$Texte) { $script:Jauge = @{ Id = $Appli.Id; Ecran = $true } }
    function Show-JaugeAppli($Appli, [string]$Texte) { $script:Jauge = @{ Id = $Appli.Id; Ecran = $false } }
    function Find-FenetreAppli($Appli) { $script:FauxFenetre }
    function Connect-Fenetre($Appli, $H) { $script:Connectee = $true; $script:Integrees[$Appli.Id].Etat = 'affiche'; $script:Integrees[$Appli.Id].Fenetre = $H }
    function Test-NouveauProcessus($Appli, $I) { $script:FauxNouveau }
    function Test-AppliOuverte($Appli) { $script:FauxNouveau }
    function Stop-AppliBloquee($Appli) { 0 }
    function Start-AppliCachee($Appli) {}
    $script:IntegrationTimer = New-Object psobject | Add-Member -MemberType ScriptMethod -Name Stop -Value {} -PassThru
    # L'appli est affichée, puis sa fenêtre part ; $Nouveau : un nouveau programme démarre (relance) ; $Quitte : l'utilisateur
    # quitte la page (la console ramène au menu, la jauge est effacée) ; puis $Secondes passent
    function Test-Fermeture([bool]$Nouveau, [bool]$Quitte, [int]$Secondes, [bool]$FenetreRevient = $false) {
        $script:Lignes = @(); $script:Connectee = $false; $script:FauxFenetre = [IntPtr]::Zero; $script:FauxNouveau = $false; $script:Jauge = $null
        $script:Integrees = @{ nevermind = @{ Id = 'nevermind'; Fenetre = [IntPtr]1; Styles = @(0, 0); Etat = 'affiche'; Depuis = (Get-Date); Pid = 1 } }
        [MSIntegration]::Ouverte = $false
        & $tick
        $i = $script:Integrees['nevermind']
        $script:FauxNouveau = $Nouveau
        & $tick
        if ($Quitte) { $script:Jauge = $null }
        if ($FenetreRevient) { $script:FauxFenetre = [IntPtr]2 }
        $i.Depuis = (Get-Date).AddSeconds(-$Secondes)
        & $tick
        @{ Etat = $i.Etat; Echec = [bool]@($script:Lignes | Where-Object { $_ -match "ne s'est pas affiché" }).Count; Erreur = [bool]@($script:Lignes | Where-Object { $_ -match '^ERREUR' }).Count }
    }
    $r = Test-Fermeture $false $true 61
    Test-Cas 'Fermée depuis elle-même, puis retour au menu : aucune ligne au journal après 60 s' { $r.Etat -eq 'vide' -and -not $r.Echec -and -not $r.Erreur }
    $r = Test-Fermeture $false $false 61
    Test-Cas 'Fermée, page restée ouverte : aucune ligne non plus' { $r.Etat -eq 'vide' -and -not $r.Echec -and -not $r.Erreur }
    $r = Test-Fermeture $false $true 30
    Test-Cas 'Avant 60 s, Mindset attend toujours son retour (une mise à jour la relance)' { $r.Etat -eq 'relance' -and -not $r.Echec }
    $r = Test-Fermeture $true $false 61
    Test-Cas 'Vraie relance (nouveau programme) sans fenêtre après 60 s : notée au journal' { $r.Etat -eq 'vide' -and $r.Echec -and -not $r.Erreur }
    $r = Test-Fermeture $true $true 61
    Test-Cas 'Vraie relance ratée, même après un retour au menu : notée aussi' { $r.Etat -eq 'vide' -and $r.Echec }
    $r = Test-Fermeture $true $true 20 $true
    Test-Cas 'Relance dont la fenêtre revient : raccrochée, rien au journal' { $script:Connectee -and $r.Etat -eq 'affiche' -and -not $r.Echec }
    # Lancement (pas une relance) dont le programme s'arrête : toujours noté après 15 s
    $script:Lignes = @(); $script:FauxNouveau = $false; $script:FauxFenetre = [IntPtr]::Zero
    $script:Integrees = @{ nevermind = @{ Id = 'nevermind'; Fenetre = [IntPtr]::Zero; Styles = $null; Etat = 'lancement'; Depuis = (Get-Date).AddSeconds(-16); Debloquee = $true } }
    & $tick
    Test-Cas 'Un lancement raté reste noté au journal' { $script:Integrees['nevermind'].Etat -eq 'vide' -and @($script:Lignes | Where-Object { $_ -match "ne s'est pas affiché après 16 s" }).Count -eq 1 }
} finally {
    foreach ($o in $ouverts) { try { $o.Dispose() } catch {} }
    foreach ($p in $lances) { try { if (-not $p.HasExited) { $p.Kill() } } catch {} }
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
