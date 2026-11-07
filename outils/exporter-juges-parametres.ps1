# Mindset : les juges du bloc « paramètres » de Mindset en Rust (rust\mindset-parametres).
#
#   & '.\outils\exporter-juges-parametres.ps1'      (depuis l'outil PowerShell, ou un PowerShell déjà ouvert)
#
# Les VRAIES fonctions de la version PowerShell (Mindset\fichiers\modules : packs.ps1, themes.ps1, parametres.ps1,
# mindset.ps1, installations.ps1, applis.ps1, paquets.ps1, accueil.ps1, donnees.ps1) sont prises telles quelles dans
# leurs fichiers (lecture de leur texte, rien d'autre n'est exécuté). Ce qui touche à la fenêtre, à Windows ou aux autres
# modules est remplacé par des faux qui notent ce qu'on leur demande. Chaque cas part de fichiers inventés (thèmes
# « Café crème », « Forêt »... jamais un thème perso) dans un dossier d'essai sous %TEMP%, supprimé à la fin.
#
# Sortie : rust\mindset-parametres\tests\juges\*.json (et zips\*.zip, les thèmes importés), que les tests Rust
# rejouent (tests\juges.rs). Rien n'est lu ni écrit ailleurs ; aucune fenêtre ne s'ouvre (WPF n'est chargé que pour
# lire des images, comme Get-ImageThemeConsole).

$ErrorActionPreference = 'Stop'
$racineDepot = Split-Path $PSScriptRoot -Parent
$modulesDir = Join-Path $racineDepot 'Mindset\fichiers\modules'
$sortie = Join-Path $racineDepot 'rust\mindset-parametres\tests\juges'
$dossierZips = Join-Path $sortie 'zips'
New-Item -ItemType Directory -Force -Path $dossierZips | Out-Null
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem, PresentationCore, WindowsBase, System.Drawing

$essai = Join-Path ([IO.Path]::GetTempPath()) "mindset-juges-parametres-$PID"
if (Test-Path -LiteralPath $essai) { Remove-Item -LiteralPath $essai -Recurse -Force }
New-Item -ItemType Directory -Force -Path $essai | Out-Null

# ---------------------------------------------------------------------------------------------------------------
# Les vraies fonctions
# ---------------------------------------------------------------------------------------------------------------
function Get-Ast([string]$Fichier) {
    $err = $null
    $a = [System.Management.Automation.Language.Parser]::ParseFile($Fichier, [ref]$null, [ref]$err)
    if ($err) { throw "Fichier illisible pour PowerShell : $Fichier" }
    $a
}
function Get-TexteFonction($Ast, [string]$Nom) {
    $f = $Ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Nom }, $true)
    if (-not $f) { throw "Fonction $Nom introuvable" }
    $f.Extent.Text
}
$asts = @{}
foreach ($m in 'packs', 'themes', 'parametres', 'mindset', 'installations', 'applis', 'paquets', 'accueil', 'donnees') { $asts[$m] = Get-Ast (Join-Path $modulesDir "$m.ps1") }
$aCharger = [ordered]@{
    packs = 'Get-PackAppliFichiers', 'Test-NomFichierPack', 'Test-CouleursPack', 'Get-ThemePack', 'Get-ThemePacks', 'Get-FormatImagePack', 'Read-DebutEntree', 'Import-PackSuite', 'Set-DossierPack', 'Complete-PacksEnAttente', 'Get-PacksARetirer', 'Set-PacksARetirer', 'Get-DossiersPackSuite', 'Remove-DossiersPack', 'Remove-PackSuite', 'Clear-PacksARetirer', 'Get-SheetFrames'
    themes = 'ConvertTo-Hsl', 'ConvertFrom-Hsl', 'ConvertTo-ThemeHex', 'Get-ThemeHello'
    parametres = 'Select-ThemeSuite', 'Confirm-SuppressionTheme', 'Remove-ThemeSuite', 'Format-MemoireConso', 'Format-ProcesseurConso', 'Measure-ConsoSuite', 'Get-NomAppareil', 'Format-VersionPubliee', 'Get-ApplisVersionsEssai', 'Get-HistoriqueMajAffiche', 'Open-PageDemandee', 'Get-ImageThemeConsole', 'Get-ThemesConsole', 'Update-AppareilsConsole', 'Get-ChoixSonConsole', 'Get-ApplisDemarrage', 'Get-EtatParametres', 'Invoke-ReglageConsole', 'Open-DossierProgrammes', 'Open-DossierDonnees', 'Invoke-VerifierMaj'
    mindset = 'Test-MajAutoActive', 'Test-VerifVersionsActive', 'Set-VerifVersions', 'ConvertTo-EntreeMaj', 'Read-HistoriqueMaj', 'Format-QuandMaj', 'Get-AppliMaj'
    installations = 'Get-VersionsEssaiAppli', 'Get-DemarrageAppli', 'Get-DossierDonnees'
    applis = 'Test-AppliAdmin'
    paquets = 'Test-VersionPlusRecente'
    accueil = 'Get-Appli', 'Watch-ThemeSuite'
    donnees = 'Get-Setting', 'Get-LancerAvecWindows', 'Set-LancerAvecWindows'
}
$textes = @(foreach ($m in $aCharger.Keys) { foreach ($n in $aCharger[$m]) { Get-TexteFonction $asts[$m] $n } })
foreach ($t in $textes) { . ([scriptblock]::Create($t)) }

# Les thèmes intégrés : l'affectation « $AppThemes = ... » de themes.ps1, rejouée à neuf pour chaque cas
$affectation = $asts['themes'].Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$AppThemes' }, $false)
$nouveauxThemes = [scriptblock]::Create($affectation.Right.Extent.Text)
# L'id d'un thème d'après son zip : la première ligne d'Import-PackSuite qui le calcule
$fImport = $asts['packs'].Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Import-PackSuite' }, $true)
$affId = $fImport.Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$id' }, $true)
$calculId = [scriptblock]::Create("param(`$Zip) $($affId.Right.Extent.Text)")

# ---------------------------------------------------------------------------------------------------------------
# Les faux (ce qui touche à la fenêtre, à Windows ou aux autres modules) : ils notent ce qu'on leur demande
# ---------------------------------------------------------------------------------------------------------------
if (-not ('MSAudio' -as [type])) {
    Add-Type -TypeDefinition @'
public static class MSAudio
{
    public static string[] M = new string[0], S = new string[0];
    public static string[] Micros() { return M; }
    public static string[] Sorties() { return S; }
}
public static class MSProcessus
{
    public class Partie { public string Nom; public int Nombre; public long Memoire; public double Processeur; }
    public static Partie[] Rendu = new Partie[0];
    public static string[] Noms, Dossiers, Marqueurs;
    public static string DossierMoi;
    public static Partie[] Mesurer(int moi, string nomMoi, string dossierMoi, string[] noms, string[] dossiers, string nomWebView, string[] marqueurs)
    { Noms = noms; Dossiers = dossiers; Marqueurs = marqueurs; DossierMoi = dossierMoi; return Rendu; }
}
'@
}
$script:Journal = New-Object Collections.Generic.List[string]
$script:Evenements = New-Object Collections.Generic.List[object]
function Write-Log($Message) { $script:Journal.Add(([string]$Message).Replace($script:Racine, '<racine>')) }
function Noter($E) { $script:Evenements.Add($E) }
function Set-Setting([string]$Nom, $Valeur) { $script:Settings[$Nom] = $Valeur }
function Read-JsonSur([string]$Fichier) { if (-not [IO.File]::Exists($Fichier)) { return $null }; try { [IO.File]::ReadAllText($Fichier, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null } }
function Get-Installation($Appli) { $i = $script:Insts[$Appli.Id]; if ($i) { @{ Dossier = $i.dossier; Gere = [bool]$i.gere; Version = $i.version } } else { $null } }
function Read-Installations { $r = @{}; foreach ($k in $script:Insts.Keys) { $r[$k] = @{ Dossier = $script:Insts[$k].dossier; Gere = [bool]$script:Insts[$k].gere } }; $r }
function Get-SuiteSon { @{ Micro = $script:Son.micro; Casque = $script:Son.casque } }
function Set-SuiteSon([string]$Quoi, [string]$Nom) { Noter ([ordered]@{ son = @($Quoi, $Nom) }) }
function Read-Suite { @{ theme = $script:SuiteTheme } }
function Set-SuiteTheme([string]$Id) { $script:SuiteTheme = $Id; Noter ([ordered]@{ theme_suite = $Id }) }
function Restart-Mindset { Noter ([ordered]@{ relancer = $true }) }
function Show-Confirmation($Titre, $Texte, $Bouton, $Action) { Noter ([ordered]@{ confirmation = [ordered]@{ titre = $Titre; texte = $Texte; bouton = $Bouton } }) }
function Show-Fenetre { Noter ([ordered]@{ fenetre = 'montrer' }) }
function Show-Page([string]$Id) { Noter ([ordered]@{ page = $Id }) }
function Open-AppliIci([string]$Id) { Noter ([ordered]@{ ouvrir_appli = $Id }) }
function Show-OngletParametres([string]$Id) { if (-not $OngletsParametres.Contains($Id)) { $Id = 'general' }; $script:OngletParametres = $Id; Noter ([ordered]@{ onglet = $Id }) }
function Update-ChoixThemes { [void]@(Get-ThemePacks) }
function Send-ParametresConsole {}
function Send-ImagesThemesConsole {}
function Update-ReglagesMaj {}
function Update-ReglageFermeture {}
function Update-VersionsEssaiParametres {}
function Update-ListeVersions {}
function Set-VersionsEssaiAppli([string]$Id, [bool]$Oui) { Noter ([ordered]@{ signal = 'versions-essai'; id = $Id; oui = $Oui }) }
function Open-PageConfidentialite([string]$Id) { Noter ([ordered]@{ signal = 'confidentialite'; id = $Id }) }
function Set-DemarrageAppli([string]$Id, [bool]$Oui) { Noter ([ordered]@{ signal = 'demarrage-appli'; id = $Id; oui = $Oui }) }
function Set-ReglageAnimations([string]$Choix) { Set-Setting 'Animations' $Choix; if ($Choix -eq 'aucune') { $script:Console.Possible = $false } }
function Import-ThemeSuite { Noter ([ordered]@{ importer = $true }) }
function Invoke-Actualiser([switch]$Clic) { Noter ([ordered]@{ signal = 'actualiser'; clic = [bool]$Clic }) }
function Start-MajMindset { Noter ([ordered]@{ signal = 'maj-mindset' }) }
function Confirm-DesinstallMindset { Noter ([ordered]@{ signal = 'desinstaller-mindset' }) }
function Open-DossierExplorateur([string]$Dossier) { Noter ([ordered]@{ ouvrir = $Dossier.Replace($script:Racine, '<racine>') }) }
function Test-ConsoVisible { $false }
function Get-Date { param([Parameter(ValueFromRemainingArguments = $true)]$Reste) if ($Reste) { Microsoft.PowerShell.Utility\Get-Date @Reste } else { $script:Maintenant } }

$AppVersion = '3.0.0'
$HistoriqueMajMax = 20
$NomAideConso = 'Programmes d''aide'
$NomWebViewConso = 'WebView2 de la suite'
$OngletsParametres = [ordered]@{ general = 'Général'; apparence = 'Apparence'; son = 'Son'; maj = 'Mises à jour'; conso = 'Consommation'; dossiers = 'Dossiers' }
$TexteVersionsEssai = 'Tu reçois aussi ses versions d''essai, avant tout le monde. Décoché, tu gardes ta version jusqu''à la prochaine version normale.'
$script:ConsoTimer = [pscustomobject]@{ IsEnabled = $true }

# Remet tout à zéro pour un cas : un dossier neuf (la même disposition que Dossiers::sous du noyau Rust)
$script:NumeroCas = 0
function Initialize-Cas($Applis = @()) {
    $script:NumeroCas++
    $script:Racine = Join-Path $essai ("cas{0:000}" -f $script:NumeroCas)
    New-Item -ItemType Directory -Force -Path $script:Racine | Out-Null
    $script:SuiteDir = Join-Path $script:Racine 'Donnees'
    $script:DataDir = Join-Path $script:SuiteDir 'Mindset'
    $script:RacineProgrammes = Join-Path $script:Racine 'Programmes'
    $script:AppDir = Join-Path $script:RacineProgrammes 'Mindset\fichiers'
    $script:MonDossier = Join-Path $script:RacineProgrammes 'Mindset'
    $script:SuiteFileDir = Join-Path $script:Racine 'Local\Mindset'
    $script:FichierPageDemandee = Join-Path $script:SuiteFileDir 'afficher-page.txt'
    New-Item -ItemType Directory -Force -Path $script:DataDir, $script:SuiteFileDir | Out-Null
    $script:PacksDir = Join-Path $script:DataDir 'packs'
    $script:PacksEnAttenteDir = Join-Path $script:DataDir 'packs-en-attente'
    $script:PacksAnciensDir = Join-Path $script:DataDir 'packs-anciens'
    $script:FichierPacksARetirer = Join-Path $script:DataDir 'packs-a-retirer.txt'
    $script:FichierHistoriqueMaj = Join-Path $script:DataDir 'mises-a-jour.json'
    $script:ConsoleWebviewCommun = Join-Path $script:SuiteDir 'WebView2-Tauri'
    $script:ConsoleWebviewPropre = $null
    $script:AppThemes = & $nouveauxThemes
    $script:ThemeCache = @{}
    $script:ThemeSetting = 'neon'; $script:ThemeId = 'neon'
    $script:Settings = @{}
    $script:Insts = @{}
    $script:Son = @{ micro = $null; casque = $null }
    $script:SuiteTheme = 'neon'
    $script:Occupe = @{}
    $script:Publications = @{}
    $script:MajMindset = $null; $script:MajMindsetEnCours = $false; $script:VerifieA = $null
    $script:ConsoEtat = $null; $script:ConsoPremiere = $true; $script:ConsoMesureNotee = $true
    $script:OngletParametres = 'general'
    $script:ThemesConsole = $null; $script:ImagesThemesConsole = @{}; $script:AppareilsConsole = $null
    $script:HistoriqueMaj = $null
    $script:Interrupteurs = @()
    $script:Console = @{ Possible = $true; Parametres = $true }
    $script:EnTest = $true
    $script:MindsetAdmin = $false
    $script:Maintenant = [datetime]'2026-11-07T20:00:00'
    $script:ui = @{
        ThemeInfo = [pscustomobject]@{ Text = '' }; AnimationsInfo = [pscustomobject]@{ Text = '' }; MajInfo = [pscustomobject]@{ Text = '' }
        DossiersTexte = [pscustomobject]@{ Text = '' }; ReduireHorloge = [pscustomobject]@{ IsChecked = $false }; ChoixAnimations = [pscustomobject]@{ Children = @() }
    }
    $script:Applis = @($Applis | ForEach-Object { [pscustomobject]$_ })
    $script:Journal.Clear(); $script:Evenements.Clear()
    [MSAudio]::M = @(); [MSAudio]::S = @(); [MSProcessus]::Rendu = @()
}

# Les fichiers d'un dossier : { chemin relatif, base64 } (pour les recréer) ou { chemin, taille } (pour comparer)
function Get-Arbre([string]$Dossier, [switch]$Contenu) {
    if (-not (Test-Path -LiteralPath $Dossier)) { return @() }
    $base = (Resolve-Path -LiteralPath $Dossier).Path.TrimEnd('\') + '\'
    @(Get-ChildItem -LiteralPath $Dossier -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length) -replace '\\packs-anciens\\[0-9a-f]{8}\\', '\packs-anciens\*\'
        if ($Contenu) { [ordered]@{ chemin = $rel; b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) } }
        else { [ordered]@{ chemin = $rel; taille = $_.Length } }
    })
}
function Set-Arbre($Fichiers) {
    foreach ($f in @($Fichiers | Where-Object { $_ })) {
        $p = Join-Path $script:Racine $f.chemin
        New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
        [IO.File]::WriteAllBytes($p, [Convert]::FromBase64String($f.b64))
    }
}
function Texte([string]$T) { [ordered]@{ chemin = ''; b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($T)) } }
function Fichier([string]$Chemin, $Octets) { [ordered]@{ chemin = $Chemin; b64 = [Convert]::ToBase64String([byte[]]$Octets) } }
function FichierTexte([string]$Chemin, [string]$T) { Fichier $Chemin ([Text.Encoding]::UTF8.GetBytes($T)) }

# Une vraie image PNG (largeur x hauteur), d'une couleur
function Get-Png([int]$L, [int]$H, [string]$Couleur = '#4CD964') {
    $b = New-Object System.Drawing.Bitmap $L, $H
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.Clear([System.Drawing.ColorTranslator]::FromHtml($Couleur)); $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
    , $ms.ToArray()
}
$png = Get-Png 64 64
$planche = Get-Png 128 32 '#E0B080'
$bande = Get-Png 300 40 '#3DDC84'
$faussePolice = [byte[]](0, 1, 0, 0) + [byte[]](1..60)

function Save-Juge([string]$Nom, $Objet) {
    $t = ConvertTo-Json -InputObject $Objet -Depth 30
    [IO.File]::WriteAllText((Join-Path $sortie "$Nom.json"), $t, (New-Object Text.UTF8Encoding $false))
    Write-Host "$Nom.json : $(@($Objet.cas).Count) cas"
}

$applisSuite = @(
    [ordered]@{ Id = 'nevermind'; Nom = 'Nevermind'; Couleur = '#00E5FF'; Rappels = $false; Admin = $true; SansDroitsDepuis = '2.0.0'; Donnees = '' }
    [ordered]@{ Id = 'evermind'; Nom = 'Evermind'; Couleur = '#B04BFF'; Rappels = $true; Admin = $false; SansDroitsDepuis = ''; Donnees = '' }
    [ordered]@{ Id = 'mindcare'; Nom = 'Mindcare'; Couleur = '#FF2EB5'; Rappels = $false; Admin = $false; SansDroitsDepuis = ''; Donnees = '' }
)

# Les packs inventés
$jsonForet = '{ "Name": "Forêt", "Desc": "Vert tendre et bois.", "Base": "terminal", "Hello": "{0}, promeneur !", "Mascotte": { "File": "mascotte.png", "Frames": 4, "Delay": 120 }, "Logo": "logo.png", "Colors": { "P": "#4CD964", "S": "#B6FF3B", "T": "#FFC83D", "NH": 140, "NS": 0.5, "Map": { "0C0920": "0A1A0E", "#06050F": "040C06" } }, "TabIcons": { "accueil": { "File": "logo.png", "Frames": 1, "Delay": 10 }, "Mal": { "File": "absent.png" } } }'
$jsonCafe = '{ "Name": "Café crème", "Desc": "Doux comme un matin.", "Base": "crepuscule", "Hello": "Pas de phrase", "Mascotte": { "File": "bande.png", "Frames": 1 }, "Logo": "logo.png", "Background": "logo.png", "BackgroundOpacity": 0.5, "BackgroundAlign": "bas-droite", "Font": "police.ttf", "FontScope": "tout" }'
$jsonSansImage = '{ "Name": "Neige", "Desc": "Tout blanc.", "Base": "rubis" }'
$jsonCouleursMal = '{ "Name": "Brume", "Base": "arcade", "Colors": { "P": "rouge", "S": "#B6FF3B", "T": "#FFC83D" } }'

# ===============================================================================================================
# 1. Les couleurs (ConvertTo-ThemeHex de Mindset), la phrase de l'en-tête
# ===============================================================================================================
$couleurs = @((Get-Content -LiteralPath (Join-Path $racineDepot 'rust\mindset-parametres\src\theme.rs') -Raw | Select-String -Pattern '"(#[0-9A-F]{6,8})"' -AllMatches).Matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$couleurs += '#3dDC84', '#80b04bff', '#123456', '#ABCDEF', '#FF000000', '#0F0', 'rouge', '#7A3CFF', '#2A2450'
$casThemes = @()
foreach ($t in 'neon', 'crepuscule', 'terminal', 'arcade', 'rubis', 'pack:foret', 'pack:brume') {
    Initialize-Cas
    $pk = $null
    if ($t -like 'pack:*') {
        $id = $t.Substring(5)
        $dir = Join-Path $script:PacksDir $id
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'pack.json'), $(if ($id -eq 'foret') { $jsonForet } else { $jsonCouleursMal }), (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllBytes((Join-Path $dir 'mascotte.png'), $planche); [IO.File]::WriteAllBytes((Join-Path $dir 'logo.png'), $png)
        $pk = Get-ThemePack $id
        $script:ThemeId = $pk.Base
    } else { $script:ThemeId = $t }
    $script:ThemePack = $pk
    $m = [ordered]@{}
    foreach ($c in $couleurs) { $m[$c] = ConvertTo-ThemeHex $c }
    $casThemes += [ordered]@{ theme = $t; pack = $(if ($pk) { [IO.File]::ReadAllText((Join-Path $pk.Dir 'pack.json')) } else { $null }); base = $script:ThemeId; bonjour = Get-ThemeHello; couleurs = $m }
}
Save-Juge 'themes' ([ordered]@{ cas = $casThemes })

# ===============================================================================================================
# 2. L'import d'un thème (Import-PackSuite)
# ===============================================================================================================
function New-Zip([string]$Nom, $Entrees) {
    $f = Join-Path $dossierZips $Nom
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    $za = [IO.Compression.ZipFile]::Open($f, 'Create')
    try {
        foreach ($e in $Entrees) {
            $x = $za.CreateEntry($e.n, [IO.Compression.CompressionLevel]::Optimal)
            if ($e.n.EndsWith("/")) { continue }
            $s = $x.Open(); try { $o = [byte[]]$e.o; $s.Write($o, 0, $o.Length) } finally { $s.Dispose() }
        }
    } finally { $za.Dispose() }
    $f
}
function Octets([string]$T) { , [Text.Encoding]::UTF8.GetBytes($T) }
function E([string]$N, $O) { [pscustomobject]@{ n = $N; o = $O } }
$gros = New-Object byte[] (31MB); [Array]::Copy($png, $gros, $png.Length)
$reglageNevermind = '{ "Name": "Forêt", "Base": "terminal" }'
$zipsCas = [ordered]@{
    'Thème-Forêt.zip' = @((E 'pack-mindset.json' (Octets $jsonForet)), (E 'pack-nevermind.json' (Octets $reglageNevermind)), (E 'mascotte.png' $planche), (E 'logo.png' $png))
    'Café crème.zip' = @((E 'pack-mindset.json' (Octets $jsonCafe)), (E 'pack-evermind.json' (Octets $jsonCafe)), (E 'pack-inconnue.json' (Octets '{}')), (E 'bande.png' $bande), (E 'logo.png' $png), (E 'police.ttf' $faussePolice))
    'theme-neige.zip' = @((E 'PACK-MINDSET.JSON' (Octets $jsonSansImage)))
    'Thème-seul.zip' = @((E 'pack.json' (Octets $jsonSansImage)), (E 'logo.png' $png))
    'Thème-rien.zip' = @((E 'logo.png' $png))
    'Thème-dossier.zip' = @((E 'images/' $null), (E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'images/logo.png' $png))
    'Thème-dossier-vide.zip' = @((E 'vide/' $null), (E 'pack-mindset.json' (Octets $jsonSansImage)))
    'Thème-texte.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'notes.txt' (Octets 'bonjour')))
    'Thème-fausse-image.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'logo.png' (Octets 'ceci n''est pas une image')))
    'Thème-courte.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'logo.gif' (Octets 'GIF8')))
    'Thème-couleurs.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'pack-evermind.json' (Octets $jsonCouleursMal)))
    'Thème-police.zip' = @((E 'pack-mindset.json' (Octets '{ "Name": "P", "Font": "../police.ttf" }')))
    'Thème-police-nombre.zip' = @((E 'pack-mindset.json' (Octets '{ "Name": "P", "Font": 12 }')))
    'Thème-police-nulle.zip' = @((E 'pack-mindset.json' (Octets '{ "Name": "P", "Font": null, "Colors": null }')))
    'Thème-illisible.zip' = @((E 'pack-mindset.json' (Octets '{ pas du json')), (E 'pack-evermind.json' (Octets '{ "Colors": "rouge" }')))
    'Thème-evermind-illisible.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'pack-evermind.json' (Octets '{ abîmé')))
    'Thème-doublon.zip' = @((E 'pack-mindset.json' (Octets '{ "Name": "A", "name": "B" }')))
    'Thème-lourd.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'gros.json' (New-Object byte[] (1MB + 1))))
    'Thème-très-lourd.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'a.png' $gros), (E 'b.png' $gros))
    'Thème-tableau.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'pack-evermind.json' (Octets '[1, 2]')), (E 'pack-nevermind.json' (Octets '0')))
    'Thème-Map.zip' = @((E 'pack-mindset.json' (Octets '{ "Name": "M", "Colors": { "P": "#112233", "S": "#112233", "T": "#112233", "Map": { "0C0920": 5 } } }')))
    'Thème_bas.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)))
    'Thème-.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)))
    'Été 2026 !.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'logo (1).png' $png))
    'Thème-nom..double.zip' = @((E 'pack-mindset.json' (Octets $jsonSansImage)), (E 'a..b.png' $png))
}
$cheminsZips = @{}
foreach ($n in $zipsCas.Keys) { $cheminsZips[$n] = New-Zip $n $zipsCas[$n] }

$casImport = @()
function Add-CasImport([string]$Nom, [string]$Zip, $Avant = @(), $Pris = @(), $ARetirer = $null, $Applis = $applisSuite) {
    Initialize-Cas $Applis
    Set-Arbre $Avant
    if ($null -ne $ARetirer) { [IO.File]::WriteAllText($script:FichierPacksARetirer, $ARetirer) }
    $tenus = @(foreach ($p in $Pris) { [IO.File]::Open((Join-Path $script:Racine $p), 'Open', 'Read', 'Read') })
    $r = $null
    try {
        try {
            $id = Import-PackSuite $cheminsZips[$Zip]
            $r = [ordered]@{ id = $id; remplace = [bool]$script:PackRemplace; attente = @($script:PackEnAttente) }
        } catch { $r = [ordered]@{ erreur = $_.Exception.Message } }
    } finally { foreach ($t in $tenus) { $t.Dispose() } }
    $script:casImport += [ordered]@{
        nom = $Nom; zip = "zips/$Zip"; applis = @($Applis | ForEach-Object { , @($_.Nom, $_.Id) }); avant = @($Avant); pris = @($Pris); a_retirer_avant = $ARetirer
        resultat = $r; apres = @(Get-Arbre $script:Racine); journal = $script:Journal.ToArray()
    }
}
foreach ($z in $zipsCas.Keys) { Add-CasImport "zip $z" $z }
$ancienForet = @((FichierTexte 'Donnees\Mindset\packs\foret\pack.json' '{ "Name": "Ancienne forêt" }'), (FichierTexte 'Donnees\Mindset\packs\foret\vieux.png' 'x'), (FichierTexte 'Donnees\Nevermind\packs\foret\pack.json' '{ "Name": "Ancienne" }'))
Add-CasImport 'remplace une version déjà là' 'Thème-Forêt.zip' $ancienForet
Add-CasImport 'ancienne version prise par une appli' 'Thème-Forêt.zip' $ancienForet @('Donnees\Nevermind\packs\foret\pack.json')
Add-CasImport 'import interrompu avant (.nouveau)' 'Thème-Forêt.zip' @((FichierTexte 'Donnees\Mindset\packs\foret.nouveau\reste.png' 'x'))
Add-CasImport 'une version attendait déjà' 'Thème-Forêt.zip' @((FichierTexte 'Donnees\Mindset\packs-en-attente\Nevermind\foret\pack.json' '{}'))
Add-CasImport 'réimporté après une suppression pas finie' 'Thème-Forêt.zip' $ancienForet @() "foret`r`n"
Add-CasImport 'sans applis' 'Café crème.zip' @() @() $null @()
Save-Juge 'import' ([ordered]@{ cas = $casImport })

# ===============================================================================================================
# 3. Supprimer un thème, et ce qui attendait (Remove-PackSuite, Clear-PacksARetirer, Complete-PacksEnAttente)
# ===============================================================================================================
$casSuppr = @()
function Add-CasSuppr([string]$Nom, [string]$Action, [string]$Id, $Avant, $Pris = @(), $ARetirer = $null) {
    Initialize-Cas $applisSuite
    Set-Arbre $Avant
    if ($null -ne $ARetirer) { [IO.File]::WriteAllText($script:FichierPacksARetirer, $ARetirer) }
    $tenus = @(foreach ($p in $Pris) { [IO.File]::Open((Join-Path $script:Racine $p), 'Open', 'Read', 'Read') })
    $r = $null
    try {
        switch ($Action) {
            'supprimer' { $r = [bool](Remove-PackSuite $Id) }
            'nettoyer' { Clear-PacksARetirer }
            'liste' { $r = @(Get-PacksARetirer) }
            'dossiers' { $r = @(Get-DossiersPackSuite $Id | ForEach-Object { $_.Replace($script:Racine, '<racine>') }) }
            'themes' { $r = @(Get-ThemePacks | ForEach-Object { $_.Id }) }
        }
    } finally { foreach ($t in $tenus) { $t.Dispose() } }
    $l = if (Test-Path -LiteralPath $script:FichierPacksARetirer) { [IO.File]::ReadAllText($script:FichierPacksARetirer) } else { $null }
    $script:casSuppr += [ordered]@{ nom = $Nom; action = $Action; id = $Id; applis = @($applisSuite | ForEach-Object { , @($_.Nom, $_.Id) }); avant = @($Avant); pris = @($Pris)
        a_retirer_avant = $ARetirer; resultat = $r; apres = @(Get-Arbre $script:Racine); a_retirer = $l; journal = $script:Journal.ToArray() }
}
$installe = @((FichierTexte 'Donnees\Mindset\packs\foret\pack.json' $jsonForet), (FichierTexte 'Donnees\Mindset\packs\foret\logo.png' 'x'), (FichierTexte 'Donnees\Nevermind\packs\foret\pack.json' '{}'),
    (FichierTexte 'Donnees\Evermind\packs\foret.nouveau\pack.json' '{}'), (FichierTexte 'Donnees\Mindset\packs-en-attente\Evermind\foret\pack.json' '{}'), (FichierTexte 'Donnees\Mindset\packs\neige\pack.json' $jsonSansImage))
Add-CasSuppr 'supprimer partout' 'supprimer' 'foret' $installe
Add-CasSuppr 'supprimer : un dossier pris' 'supprimer' 'foret' $installe @('Donnees\Nevermind\packs\foret\pack.json')
Add-CasSuppr 'supprimer : déjà dans la liste' 'supprimer' 'foret' $installe @() "neige`r`nforet`r`n"
Add-CasSuppr 'supprimer : id refusé' 'supprimer' 'Foret' $installe
Add-CasSuppr 'supprimer : id avec ..' 'supprimer' '..' $installe
Add-CasSuppr 'supprimer : absent' 'supprimer' 'absent' $installe
Add-CasSuppr 'nettoyer : rien' 'nettoyer' '' $installe
Add-CasSuppr 'nettoyer : un thème à retirer' 'nettoyer' '' $installe @() "foret`r`n  neige  `r`nMAL`r`n../x`r`nforet"
Add-CasSuppr 'nettoyer : encore pris' 'nettoyer' '' $installe @('Donnees\Mindset\packs\foret\logo.png') "foret`r`n"
$attentes = @((FichierTexte 'Donnees\Mindset\packs\neige\pack.json' '{ "Name": "Vieille neige" }'), (FichierTexte 'Donnees\Mindset\packs-en-attente\Mindset\neige\pack.json' $jsonSansImage),
    (FichierTexte 'Donnees\Mindset\packs-en-attente\Nevermind\foret\pack.json' '{}'), (FichierTexte 'Donnees\Mindset\packs-en-attente\Inconnue\foret\pack.json' '{}'),
    (FichierTexte 'Donnees\Mindset\packs-en-attente\Evermind\MAL\pack.json' '{}'), (FichierTexte 'Donnees\Mindset\packs-en-attente\Evermind\retire\pack.json' '{}'),
    (FichierTexte 'Donnees\Mindset\packs-anciens\0a1b2c3d\pack.json' '{}'))
Add-CasSuppr 'nettoyer : versions en attente' 'nettoyer' '' $attentes @() "retire`r`n"
Add-CasSuppr 'nettoyer : version en attente encore prise' 'nettoyer' '' $attentes @('Donnees\Mindset\packs\neige\pack.json')
Add-CasSuppr 'liste à retirer' 'liste' '' @() @() "b`r`na`r`n`r`nb`r`n  c  `r`nX`r`n"
Add-CasSuppr 'liste absente' 'liste' '' @()
Add-CasSuppr 'dossiers du pack' 'dossiers' 'foret' @()
Add-CasSuppr 'dossiers : id refusé' 'dossiers' 'a b' @()
$plusieurs = @((FichierTexte 'Donnees\Mindset\packs\zeta\pack.json' $jsonSansImage), (FichierTexte 'Donnees\Mindset\packs\alpha\pack.json' '{ "Name": "Alpha" }'), (FichierTexte 'Donnees\Mindset\packs\abime\pack.json' '{ abîmé'),
    (FichierTexte 'Donnees\Mindset\packs\vide\rien.txt' 'x'), (FichierTexte 'Donnees\Mindset\packs\retire\pack.json' '{}'), (FichierTexte 'Donnees\Mindset\packs\Beta\pack.json' '{}'))
Add-CasSuppr 'thèmes installés' 'themes' '' $plusieurs @() "retire`r`n"
Save-Juge 'suppression' ([ordered]@{ cas = $casSuppr })

# ===============================================================================================================
# 4. Ce que l'écran des Paramètres affiche (Get-EtatParametres)
# ===============================================================================================================
$casEtat = @()
function Add-CasEtat([string]$Nom, $E) {
    Initialize-Cas $(if ($E.applis) { $E.applis } else { $applisSuite })
    Set-Arbre @($E.fichiers)
    if ($E.reglages) { foreach ($k in @($E.reglages.Keys)) { $script:Settings[$k] = $E.reglages[$k] } }
    $script:Insts = $(if ($E.installations) { $E.installations } else { @{} })
    if ($E.publications) { foreach ($k in @($E.publications.Keys)) { $script:Publications[$k] = $E.publications[$k] } }
    if ($E.son) { $script:Son = $E.son }
    [MSAudio]::M = @($E.micros); [MSAudio]::S = @($E.sorties)
    if ($E.theme) { $script:ThemeSetting = $E.theme; $script:ThemeId = $(if ($E.theme -like 'pack:*') { $p = Get-ThemePack $E.theme.Substring(5); if ($p) { $p.Base } else { 'neon' } } else { $E.theme }) }
    $script:AppThemes = & $nouveauxThemes; $script:ThemeCache = @{}
    if ($E.theme -like 'pack:*') { [void](Get-ThemePack $E.theme.Substring(5)) }
    if ($E.maj_mindset) { $script:MajMindset = @{ Version = $E.maj_mindset } }
    $script:MajMindsetEnCours = [bool]$E.maj_en_cours
    if ($E.verifie_a) { $script:VerifieA = $script:Maintenant }
    $script:MindsetAdmin = [bool]$E.admin
    if ($E.onglet) { $script:OngletParametres = $E.onglet }
    $script:ui.ThemeInfo.Text = [string]$E.theme_info; $script:ui.MajInfo.Text = [string]$E.maj_info
    $script:ui.DossiersTexte.Text = "Les programmes sont dans $RacineProgrammes (protégé : seul un administrateur peut les modifier). Les données de Mindset et de chaque appli sont dans $SuiteDir, un dossier par appli."
    if ($E.parties) {
        [MSProcessus]::Rendu = @(foreach ($p in $E.parties) { $x = New-Object MSProcessus+Partie; $x.Nom = $p.nom; $x.Nombre = $p.nombre; $x.Memoire = $p.memoire; $x.Processeur = $p.processeur; $x })
        $script:ConsoPremiere = [bool]$E.premiere
        Measure-ConsoSuite
    }
    $json = (Get-EtatParametres).Replace($script:Racine.Replace('\', '\\'), '<racine>')
    $script:casEtat += [ordered]@{ nom = $Nom; entree = $E; sortie = $json; journal = $script:Journal.ToArray() }
}
$historique = '{ "historique": [ { "id": "evermind", "nom": "Evermind", "version": "1.4.0", "quand": "2026-11-07T00:16:00", "auto": true }, { "id": "mindset", "nom": "Mindset", "version": "2.18.0", "quand": "2026-11-06T21:05:00", "auto": false }, { "id": "ancienne", "nom": "Une appli retirée de la liste, au nom bien trop long pour tenir", "version": "0.9", "quand": "2026-10-18T09:30:00", "auto": "non" }, { "id": "Nevermind", "nom": "Nevermind", "version": "2.0.1", "quand": "2026-11-08T08:00:00", "auto": 0 }, { "id": "mal écrit", "version": "1.0.0", "quand": "2026-11-07T00:00:00" }, { "id": "x", "version": "1", "quand": "2026-11-07T00:00:00" }, { "id": "x", "version": "1.0", "quand": "2026-11-07 00:00:00" }, null ] }'
$packsDisque = @((FichierTexte 'Donnees\Mindset\packs\foret\pack.json' $jsonForet), (Fichier 'Donnees\Mindset\packs\foret\mascotte.png' $planche), (Fichier 'Donnees\Mindset\packs\foret\logo.png' $png),
    (FichierTexte 'Donnees\Mindset\packs\cafe-creme\pack.json' $jsonCafe), (Fichier 'Donnees\Mindset\packs\cafe-creme\bande.png' $bande), (Fichier 'Donnees\Mindset\packs\cafe-creme\logo.png' $png),
    (FichierTexte 'Donnees\Mindset\packs\neige\pack.json' $jsonSansImage), (FichierTexte 'Donnees\Mindset\packs\brume\pack.json' $jsonCouleursMal))
Add-CasEtat 'rien d''installé' @{ reglages = @{} }
Add-CasEtat 'tout réglé' @{
    reglages = @{ ReduireHorloge = $false; Fermeture = 'quitter'; LancerAvecWindows = $false; Animations = 'express'; MajAuto = $false; VerifVersions = $true; Demarrage = @('evermind', 'NEVERMIND'); VersionsEssai = @('mindcare', 'Evermind') }
    installations = @{ nevermind = @{ dossier = 'C:\P\Nevermind'; gere = $true; version = '2.0.1' }; evermind = @{ dossier = 'C:\P\Evermind'; gere = $true; version = '1.4.0' }; mindcare = @{ dossier = 'C:\P\Mindcare'; gere = $false; version = $null } }
    publications = @{ nevermind = @{ Version = '2.1.0'; Essai = $true }; evermind = @{ Version = '1.4.0' }; mindcare = @{ Erreur = 'HTTP 403' } }
    son = @{ micro = 'Micro du casque'; casque = 'Haut-parleurs (Realtek High Definition Audio)' }; micros = @('Micro du casque', 'Micro (Realtek(R) Audio Haute D', 'Micro du casque', ''); sorties = @('Haut-parleurs (Realtek High Def', 'Casque')
    theme = 'pack:foret'; theme_info = 'Une info'; maj_info = 'Vérifié à 19:58'; maj_mindset = '3.0.1'; fichiers = @($packsDisque + (FichierTexte 'Donnees\Mindset\mises-a-jour.json' $historique)); onglet = 'maj'
}
Add-CasEtat 'Nevermind encore administrateur' @{ installations = @{ nevermind = @{ dossier = 'C:\P\Nevermind'; gere = $true; version = '1.9.0' } }; publications = @{ nevermind = @{ Version = '1.9.0' } }; reglages = @{ VerifVersions = $false }; maj_en_cours = $true }
Add-CasEtat 'Mindset administrateur' @{ installations = @{ nevermind = @{ dossier = 'C:\P\Nevermind'; gere = $true; version = '1.9.0' }; evermind = @{ dossier = 'C:\P\Evermind'; gere = $false; version = '' } }; admin = $true; reglages = @{ VerifVersions = $false; Demarrage = 'evermind' }; publications = @{ evermind = @{ Version = '1.0.0' }; mindcare = @{ Version = '0.5.0' } } }
Add-CasEtat 'recherche coupée et vérifié' @{ reglages = @{ VerifVersions = $false; MajAuto = $true }; verifie_a = $true; son = @{ micro = 'Débranché depuis'; casque = '' }; micros = @('A', 'B') }
Add-CasEtat 'thème Café crème' @{ theme = 'pack:cafe-creme'; fichiers = $packsDisque; onglet = 'apparence' }
Add-CasEtat 'thème perso disparu' @{ theme = 'pack:absent'; fichiers = $packsDisque }
Add-CasEtat 'thème Terminal, thème à retirer' @{ theme = 'terminal'; fichiers = @($packsDisque + (FichierTexte 'Donnees\Mindset\packs-a-retirer.txt' "neige`r`n")) }
Add-CasEtat 'consommation' @{ onglet = 'conso'; parties = @(@{ nom = 'Mindset'; nombre = 3; memoire = 412MB; processeur = 1.25 }, @{ nom = 'Evermind'; nombre = 1; memoire = 1100MB; processeur = 12.5 }, @{ nom = 'Nevermind'; nombre = 0; memoire = 0; processeur = 0 }, @{ nom = 'WebView2 de la suite'; nombre = 6; memoire = 999MB; processeur = 0.04 }, @{ nom = 'Programmes d''aide'; nombre = 2; memoire = 5MB; processeur = 9.96 }); premiere = $false; installations = @{ evermind = @{ dossier = 'C:\P\Evermind'; gere = $true; version = '1.0.0' } } }
Add-CasEtat 'consommation, première mesure' @{ onglet = 'conso'; parties = @(@{ nom = 'Mindset'; nombre = 1; memoire = 1023999999; processeur = 50 }); premiere = $true }
Save-Juge 'etat' ([ordered]@{ cas = $casEtat })

# ===============================================================================================================
# 5. La mesure de la suite : ce qui est demandé à Windows (Measure-ConsoSuite)
# ===============================================================================================================
$casConso = @()
foreach ($c in @(
        @{ nom = 'rien d''installé'; installations = @{}; applis = $applisSuite; dossiers = @() }
        @{ nom = 'gérées, données adoptées'; installations = @{ nevermind = @{ dossier = 'C:\P\Nevermind'; gere = $true; version = '2.0.0' }; evermind = @{ dossier = 'C:\P\Evermind'; gere = $false; version = '1.0.0' } }; applis = $applisSuite; dossiers = @('Donnees\Nevermind', 'Donnees\Evermind') }
        @{ nom = 'anciens dossiers de données'; installations = @{ evermind = @{ dossier = 'D:\Evermind'; gere = $false; version = '1.0.0' } }; applis = @(@{ Id = 'evermind'; Nom = 'Evermind'; Couleur = '#B04BFF'; Donnees = 'C:\Users\x\AppData\Local\Evermind' }, @{ Id = 'nevermind'; Nom = 'Nevermind'; Couleur = '#00E5FF'; Donnees = 'C:\Users\x\AppData\Local\Nevermind' }, @{ Id = 'suite'; Nom = 'Suite'; Couleur = '#00E5FF'; Donnees = '<suite>\' }); dossiers = @() }
    )) {
    $applis = @($c.applis | ForEach-Object { $h = [ordered]@{}; foreach ($k in $_.Keys) { $h[$k] = $_[$k] }; $h })
    Initialize-Cas $applis
    foreach ($a in $script:Applis) { if ($a.Donnees -eq '<suite>\') { $a.Donnees = "$script:SuiteDir\" } }
    foreach ($d in $c.dossiers) { New-Item -ItemType Directory -Force -Path (Join-Path $script:Racine $d) | Out-Null }
    $script:Insts = $c.installations
    Measure-ConsoSuite
    $r = { param($l) @($l | ForEach-Object { $_.Replace($script:Racine, '<racine>') }) }
    $casConso += [ordered]@{ nom = $c.nom; applis = @($script:Applis | ForEach-Object { [ordered]@{ Id = $_.Id; Nom = $_.Nom; Donnees = $_.Donnees.Replace($script:Racine, '<racine>') } }); installations = $c.installations; dossiers = $c.dossiers
        noms = @([MSProcessus]::Noms); chemins = (& $r ([MSProcessus]::Dossiers)); moi = ([MSProcessus]::DossierMoi).Replace($script:Racine, '<racine>') }
}
Save-Juge 'conso' ([ordered]@{ cas = $casConso })

# ===============================================================================================================
# 6. Les gestes de l'écran des Paramètres (Invoke-ReglageConsole)
# ===============================================================================================================
$casGestes = @()
function Add-CasGestes([string]$Nom, $Gestes, $E = @{}) {
    Initialize-Cas $applisSuite
    Set-Arbre @($E.fichiers)
    $script:Insts = $(if ($E.installations) { $E.installations } else { @{ evermind = @{ dossier = 'C:\P\Evermind'; gere = $true; version = '1.0.0' }; nevermind = @{ dossier = 'C:\P\Nevermind'; gere = $true; version = '1.0.0' } } })
    if ($E.reglages) { foreach ($k in @($E.reglages.Keys)) { $script:Settings[$k] = $E.reglages[$k] } }
    if ($E.theme) { $script:ThemeSetting = $E.theme; $script:SuiteTheme = $E.theme }
    if ($null -ne $E.en_test) { $script:EnTest = [bool]$E.en_test }
    if ($E.occupe) { $script:Occupe = @{ evermind = 'Téléchargement...' } }
    $script:ThemesConsole = @(Get-ThemesConsole); $script:Journal.Clear()
    foreach ($g in $Gestes) { Invoke-ReglageConsole ([pscustomobject]$g) }
    $reglages = [ordered]@{}; foreach ($k in @($script:Settings.Keys | Sort-Object)) { $reglages[$k] = $script:Settings[$k] }
    try { $x = [ordered]@{ nom = $Nom; entree = $E; gestes = @($Gestes); evenements = $script:Evenements.ToArray(); reglages = $reglages; onglet = $script:OngletParametres
        info = $script:ui.ThemeInfo.Text; maj_info = $script:ui.MajInfo.Text; journal = $script:Journal.ToArray(); suite_theme = $script:SuiteTheme } } catch { [Console]::Error.WriteLine($_.Exception.ToString()); [Console]::Error.WriteLine($_.ScriptStackTrace); throw }; $script:casGestes += $x
}
Add-CasGestes 'interrupteurs' @(@{ quoi = 'reduire'; valeur = $false }, @{ quoi = 'windows'; valeur = 0 }, @{ quoi = 'majauto'; valeur = 'non' }, @{ quoi = 'verif'; valeur = $false }, @{ quoi = 'verif'; valeur = $true })
Add-CasGestes 'fermeture' @(@{ quoi = 'fermeture'; valeur = 'reduire' }, @{ quoi = 'fermeture'; valeur = 'autre' }, @{ quoi = 'fermeture'; valeur = 'QUITTER' })
Add-CasGestes 'onglets' @(@{ quoi = 'onglet'; valeur = 'son' }, @{ quoi = 'onglet'; valeur = 'inconnu' }, @{ quoi = 'onglet'; valeur = 'maj' })
Add-CasGestes 'versions d''essai' @(@{ quoi = 'essai'; id = 'evermind'; valeur = $true }, @{ quoi = 'essai'; id = 'Evermind'; valeur = $true }, @{ quoi = 'essai'; id = 'mindcare'; valeur = $true }, @{ quoi = 'essai'; id = 'nevermind'; valeur = 0 })
Add-CasGestes 'démarrage des applis' @(@{ quoi = 'demarrage'; id = 'EVERMIND'; valeur = $true }, @{ quoi = 'demarrage'; id = 'nevermind'; valeur = $true }, @{ quoi = 'demarrage'; id = 'mindcare'; valeur = $true })
Add-CasGestes 'démarrage, Mindset administrateur' @(@{ quoi = 'demarrage'; id = 'nevermind'; valeur = $true }) @{ installations = @{ nevermind = @{ dossier = 'C:\P\Nevermind'; gere = $true; version = '2.0.0' } } }
Add-CasGestes 'son' @(@{ quoi = 'micro'; valeur = 'Micro du casque' }, @{ quoi = 'casque'; valeur = '' }, @{ quoi = 'sonActualiser' })
Add-CasGestes 'boutons' @(@{ quoi = 'confidentialite' }, @{ quoi = 'verifier' }, @{ quoi = 'majMindset' }, @{ quoi = 'dossierProgrammes' }, @{ quoi = 'dossierDonnees' }, @{ quoi = 'desinstaller' }, @{ quoi = 'importer' }, @{ quoi = 'rien du tout' })
Add-CasGestes 'animations' @(@{ quoi = 'animations'; valeur = 'express' }, @{ quoi = 'animations'; valeur = 'vite' }, @{ quoi = 'animations'; valeur = 'aucune' })
Add-CasGestes 'thème (test)' @(@{ quoi = 'theme'; valeur = 'neon' }, @{ quoi = 'theme'; valeur = 'inconnu' }, @{ quoi = 'theme'; valeur = 'arcade' })
Add-CasGestes 'thème (relance)' @(@{ quoi = 'theme'; valeur = 'pack:foret' }) @{ en_test = $false; fichiers = $packsDisque }
Add-CasGestes 'thème pendant une installation' @(@{ quoi = 'theme'; valeur = 'rubis' }) @{ occupe = $true }
Add-CasGestes 'supprimer un thème : la question' @(@{ quoi = 'supprimerTheme'; valeur = 'pack:neige' }, @{ quoi = 'supprimerTheme'; valeur = 'pack:foret' }, @{ quoi = 'supprimerTheme'; valeur = 'pack:absent' }, @{ quoi = 'supprimerTheme'; valeur = 'neige' }) @{ theme = 'pack:foret'; fichiers = $packsDisque }
Save-Juge 'gestes' ([ordered]@{ cas = $casGestes })

# Supprimer pour de bon (Remove-ThemeSuite, après « Supprimer »)
$casRetrait = @()
foreach ($c in @(
        @{ nom = 'un thème qui n''est pas l''actuel'; id = 'neige'; theme = 'neon'; en_test = $true }
        @{ nom = 'le thème actuel'; id = 'foret'; theme = 'pack:foret'; en_test = $false }
        @{ nom = 'le thème actuel (test)'; id = 'foret'; theme = 'pack:foret'; en_test = $true }
        @{ nom = 'encore pris'; id = 'cafe-creme'; theme = 'neon'; en_test = $true; pris = @('Donnees\Mindset\packs\cafe-creme\logo.png') }
        @{ nom = 'pendant une installation'; id = 'neige'; theme = 'neon'; en_test = $true; occupe = $true }
        @{ nom = 'absent'; id = 'absent'; theme = 'neon'; en_test = $true }
    )) {
    Initialize-Cas $applisSuite
    Set-Arbre $packsDisque
    $script:ThemeSetting = $c.theme; $script:SuiteTheme = $c.theme; $script:EnTest = $c.en_test
    if ($c.occupe) { $script:Occupe = @{ evermind = 'Téléchargement...' } }
    $tenus = @(foreach ($p in @($c.pris)) { if ($p) { [IO.File]::Open((Join-Path $script:Racine $p), 'Open', 'Read', 'Read') } })
    try { Remove-ThemeSuite $c.id } finally { foreach ($t in $tenus) { $t.Dispose() } }
    $casRetrait += [ordered]@{ nom = $c.nom; id = $c.id; theme = $c.theme; en_test = $c.en_test; occupe = [bool]$c.occupe; pris = @($c.pris | Where-Object { $_ }); evenements = $script:Evenements.ToArray(); info = $script:ui.ThemeInfo.Text
        apres = @(Get-Arbre $script:Racine); suite_theme = $script:SuiteTheme; journal = $script:Journal.ToArray() }
}
Save-Juge 'retrait' ([ordered]@{ cas = $casRetrait; avant = $packsDisque })

# ===============================================================================================================
# 7. Une page demandée par une appli (Open-PageDemandee)
# ===============================================================================================================
$casPage = @()
foreach ($t in 'parametres', 'parametres:son', "  parametres:apparence`r`n", 'PARAMETRES:MAJ', 'parametres:', 'parametres:inconnu', 'parametres:conso:x', 'menu', 'Menu', 'appli:evermind', 'appli:Evermind', 'appli:absente', 'appli:', 'appli:a b', 'rien', '', $null) {
    Initialize-Cas $applisSuite
    if ($null -ne $t) { [IO.File]::WriteAllText($script:FichierPageDemandee, $t) }
    Open-PageDemandee
    $casPage += [ordered]@{ texte = $t; evenements = $script:Evenements.ToArray(); retire = -not (Test-Path -LiteralPath $script:FichierPageDemandee) }
}
Save-Juge 'page' ([ordered]@{ cas = $casPage })

# ===============================================================================================================
# 8. Le thème changé ailleurs (Watch-ThemeSuite)
# ===============================================================================================================
$casWatch = @()
foreach ($c in @(
        @{ nom = 'le même'; suite = 'neon'; actuel = 'neon' }
        @{ nom = 'changé'; suite = 'arcade'; actuel = 'neon' }
        @{ nom = 'changé, casse différente'; suite = 'NEON'; actuel = 'neon' }
        @{ nom = 'pendant une installation'; suite = 'arcade'; actuel = 'neon'; occupe = $true }
        @{ nom = 'déjà relancé il y a 30 s'; suite = 'arcade'; actuel = 'neon'; derniere = @{ Theme = 'arcade'; Quand = '2026-11-07T19:59:30' } }
        @{ nom = 'déjà relancé il y a 2 min'; suite = 'arcade'; actuel = 'neon'; derniere = @{ Theme = 'arcade'; Quand = '2026-11-07T19:58:00' } }
        @{ nom = 'relancé pour un autre'; suite = 'arcade'; actuel = 'neon'; derniere = @{ Theme = 'rubis'; Quand = '2026-11-07T19:59:59' } }
        @{ nom = 'rien dans suite.json'; suite = $null; actuel = 'neon' }
    )) {
    Initialize-Cas
    $script:EnTest = $false; $script:SuiteTheme = $c.suite; $script:ThemeSetting = $c.actuel
    if ($c.occupe) { $script:Occupe = @{ evermind = 'x' } }
    if ($c.derniere) { $script:Settings['DerniereRelanceTheme'] = [pscustomobject]$c.derniere }
    Watch-ThemeSuite
    $d = $script:Settings['DerniereRelanceTheme']
    $casWatch += [ordered]@{ nom = $c.nom; suite = $c.suite; actuel = $c.actuel; occupe = [bool]$c.occupe; derniere = $c.derniere; evenements = $script:Evenements.ToArray()
        derniere_apres = $(if ($d) { [ordered]@{ Theme = [string]$d.Theme; Quand = [string]$d.Quand } } else { $null }); journal = $script:Journal.ToArray() }
}
Save-Juge 'surveillance' ([ordered]@{ cas = $casWatch })

# ===============================================================================================================
# 9. Les petits textes
# ===============================================================================================================
Initialize-Cas $applisSuite
$memoires = @(0, 1, 524287, 524288, 1572864, 2621440, 999MB, 999.5MB, 999.6MB, (1000MB - 1), 1000MB, 1024MB, 1075MB, 1126MB, 1177MB, 1536MB, 10GB, 1.05GB, 1.25GB, 1.35GB, 123456789012)
$processeurs = @(0, 0.04, 0.05, 0.15, 0.25, 0.35, 1, 1.25, 2.25, 9.94, 9.95, 9.96, 9.99, 10, 10.5, 11.5, 12.5, 99.5, 100)
$appareils = @('Casque', '', 'Micro (Realtek(R) Audio Haute D', 'Haut-parleurs (Realtek High Def', 'Haut-parleurs (Realtek High Definition Audio)', 'Un nom de trente et une lettres!', 'Un nom de trente et une lettre ', 'Micro (USB Audio Device)  et x', '1234567890123456789012345678901(', 'Écouteurs (Bluetooth Mains Libr')
$entrees = @(
    @{ id = 'evermind'; nom = 'Evermind'; version = '1.4.0'; quand = '2026-11-07T00:16:00'; auto = $true }
    @{ id = 'Evermind'; version = '1.4'; quand = '2026-02-29T00:16:00' }
    @{ id = 'evermind'; version = '1.4.0.1.2'; quand = '2026-11-07T00:16:00' }
    @{ id = 'evermind'; version = '1'; quand = '2026-11-07T00:16:00' }
    @{ id = 'ever mind'; version = '1.0'; quand = '2026-11-07T00:16:00' }
    @{ id = 'a234567890123456789012345678901'; version = '1.0'; quand = '2026-11-07T00:16:00' }
    @{ id = 'evermind'; version = '1.0'; quand = '2026-11-07T24:00:00' }
    @{ id = 'evermind'; version = '1.0'; quand = '2024-02-29T23:59:59'; auto = 'false'; nom = 'Un nom beaucoup trop long pour tenir en trente lettres' }
    @{ id = 'evermind'; version = 'v1.0'; quand = '2026-11-07T00:16:00' }
    @{ id = 5; version = 1.5; quand = '2026-11-07T00:16:00' }
    @{ version = '1.0'; quand = '2026-11-07T00:16:00' }
)
$quands = @(@('2026-11-07T00:16:00', $true), @('2026-11-07T23:59:59', $false), @('2026-11-06T21:05:00', $true), @('2026-11-05T09:30:00', $true), @('2026-10-18T09:30:00', $false), @('2026-01-01T00:00:00', $true), @('2025-11-07T12:00:00', $true), @('2026-11-08T08:00:00', $true), @('2026-08-01T07:05:00', $false))
$idsZip = @('Thème-Forêt.zip', 'THÈME-forêt.zip', 'theme-a.zip', 'Thèmes-a.zip', 'Thème-Café crème.zip', 'Été 2026 !.zip', 'a_b.zip', 'Ça va.zip', 'Ø.zip', 'œuvre.zip', 'x.y.zip', '--a--.zip', 'Thème-.zip', 'Ñandú über straße.zip', 'MAJUSCULES.zip', '12345.zip')
$textesJ = [ordered]@{
    memoire = @(foreach ($m in $memoires) { , @([long]$m, (Format-MemoireConso ([long]$m))) })
    processeur = @(foreach ($p in $processeurs) { , @([double]$p, (Format-ProcesseurConso ([double]$p))) })
    appareils = @(foreach ($n in $appareils) { , @($n, (Get-NomAppareil $n)) })
    choix_son = @(
        foreach ($c in @(@(@('A', 'B'), ''), @(@('A', 'a', 'A'), 'a'), @(@('A', ''), 'Z'), @(@(), 'Haut-parleurs (Realtek High Def'), @(@('Casque'), 'casque'))) {
            [ordered]@{ noms = @($c[0]); choisi = $c[1]; attendu = @(Get-ChoixSonConsole $c[0] $c[1]) }
        })
    entrees = @(foreach ($e in $entrees) { [ordered]@{ x = $e; attendu = (ConvertTo-EntreeMaj ([pscustomobject]$e)) } })
    quand = @(foreach ($q in $quands) { [ordered]@{ quand = $q[0]; long = $q[1]; attendu = (Format-QuandMaj $q[0] -Long:$q[1]) } })
    ids_zip = @(foreach ($n in $idsZip) { , @($n, (& $calculId (Join-Path 'C:\x' $n))) })
    versions = @(foreach ($p in @(@{ Version = '1.0.0' }, @{ Version = '1.0.0'; Essai = $true }, @{ Version = '2.0'; Essai = 0 })) { [ordered]@{ p = $p; attendu = (Format-VersionPubliee $p) } })
}
Save-Juge 'textes' ([ordered]@{ memoire = $textesJ.memoire; processeur = $textesJ.processeur; appareils = $textesJ.appareils; choix_son = $textesJ.choix_son; entrees = $textesJ.entrees; quand = $textesJ.quand; ids_zip = $textesJ.ids_zip; versions = $textesJ.versions })


# ===============================================================================================================
# 10. Des cas tirés au hasard (graine fixe) : des entrées que personne n'a choisies
# ===============================================================================================================
$hasard = New-Object Random 20261107
function Tirer([string]$Lettres, [int]$Min, [int]$Max) { $n = $hasard.Next($Min, $Max + 1); if ($n -le 0) { return "" }; -join (1..$n | ForEach-Object { $Lettres[$hasard.Next($Lettres.Length)] }) }
$hex = '0123456789ABCDEFabcdef'
$couleursHasard = @(foreach ($i in 1..300) { '#' + (Tirer $hex $(if ($i % 3) { 6 } else { 8 }) $(if ($i % 3) { 6 } else { 8 })) })
$casThemesHasard = @()
foreach ($t in 'crepuscule', 'terminal', 'arcade', 'rubis', 'pack:foret') {
    Initialize-Cas
    if ($t -eq 'pack:foret') {
        $dir = Join-Path $script:PacksDir 'foret'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'pack.json'), $jsonForet, (New-Object Text.UTF8Encoding $false))
        $script:ThemeId = (Get-ThemePack 'foret').Base
    } else { $script:ThemeId = $t }
    $m = [ordered]@{}; foreach ($c in $couleursHasard) { $m[$c] = ConvertTo-ThemeHex $c }
    $casThemesHasard += [ordered]@{ theme = $t; pack = $(if ($t -eq 'pack:foret') { $jsonForet } else { $null }); couleurs = $m }
}
$lettresNom = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ()-_.éèàçÉôœ'
$lettresZip = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.éèàçÉÈôöüñœØ!,''+'
$hasardJ = [ordered]@{
    themes = $casThemesHasard
    memoire = @(foreach ($i in 1..200) { $o = [long]($hasard.NextDouble() * [math]::Pow(10, $hasard.Next(0, 11))); , @($o, (Format-MemoireConso $o)) })
    processeur = @(foreach ($i in 1..200) { $p = [math]::Round($hasard.NextDouble() * $(if ($i % 2) { 12 } else { 100 }), $hasard.Next(1, 4)); , @($p, (Format-ProcesseurConso $p)) })
    appareils = @(foreach ($i in 1..200) { $n = Tirer 'abcdeXYZ ()()-' 26 40; , @($n, (Get-NomAppareil $n)) })
    ids_zip = @(foreach ($i in 1..200) { $n = $(if ($i % 4 -eq 0) { 'Thème-' } elseif ($i % 4 -eq 1) { 'theme-' } else { '' }) + (Tirer $lettresZip 1 30) + '.zip'; , @($n, (& $calculId (Join-Path 'C:\x' $n))) })
    noms_fichiers = @(foreach ($i in 1..300) { $n = Tirer $lettresNom 0 85; , @($n, [bool](Test-NomFichierPack $n)) })
    entrees = @(foreach ($i in 1..150) {
            $x = [ordered]@{ id = (Tirer 'abcz09-A ' 0 33); version = (Tirer '0123456789..' 1 9); quand = ('{0:0000}-{1:00}-{2:00}T{3:00}:{4:00}:{5:00}' -f $hasard.Next(1, 3000), $hasard.Next(0, 14), $hasard.Next(0, 33), $hasard.Next(0, 26), $hasard.Next(0, 62), $hasard.Next(0, 62)); nom = (Tirer $lettresNom 0 40); auto = @($true, $false, 'non', 0, 1, '')[$hasard.Next(6)] }
            [ordered]@{ x = $x; attendu = (ConvertTo-EntreeMaj ([pscustomobject]$x)) } })
}
Save-Juge 'hasard' ([ordered]@{ themes = $hasardJ.themes; memoire = $hasardJ.memoire; processeur = $hasardJ.processeur; appareils = $hasardJ.appareils; ids_zip = $hasardJ.ids_zip; noms_fichiers = $hasardJ.noms_fichiers; entrees = $hasardJ.entrees })
Remove-Item -LiteralPath $essai -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Fini.'
