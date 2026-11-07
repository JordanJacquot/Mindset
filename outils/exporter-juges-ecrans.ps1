# Mindset : juges du bloc « écrans » pour Mindset en Rust (rust\mindset-ecrans\tests\juges\*.json).
#
#   & '.\outils\exporter-juges-ecrans.ps1'       (sur un bureau Windows à part : il crée la fenêtre WPF, sans jamais la montrer)
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '.\outils\exporter-juges-ecrans.ps1' -Secondes 300
#
# Les VRAIES fonctions de l'accueil (accueil.ps1 : Update-Carte et tout ce qu'elle appelle, Get-EtatAppli,
# Get-ProchainsRdv, Format-QuandRdv, Update-Greeting, Confirm-MiseAJour, Confirm-PriseEnCharge, Confirm-Desinstallation,
# Get-PhraseReseauAppli, Get-LienReseauAppli), de interface.ps1 (New-Text, New-Button, Get-Brush), de themes.ps1
# (ConvertTo-ThemeHex et ses aides, la table des thèmes) et de logo.ps1 (les dégradés des jauges) sont prises telles
# quelles dans leurs fichiers (par l'analyseur de PowerShell) ; seul ce qui touche au PC est remplacé par du faux
# (installations, applis ouvertes, dossiers trouvés, l'heure : le 07/11/2026 à 20 h, comme les contextes d'essai Rust).
#
# Pour chaque cas, la carte dessinée par Update-Carte est relue dans la fenêtre WPF (jamais montrée) et écrite sous une
# forme simple (la même que celle que le bloc Rust envoie à la page) : chaque élément de la carte dans l'ordre, ses
# textes, tailles, couleurs, marges, ses boutons et leur style. Les chemins d'essai sont remplacés par « {RACINE} ».
#
# Tout se passe dans un dossier temporaire sous %TEMP%, supprimé à la fin. Rien n'est lu ni écrit ailleurs (le dossier
# de données des applis est remplacé par un dossier d'essai).

$ErrorActionPreference = 'Stop'
$racineDepot = Split-Path $PSScriptRoot -Parent
$modules = Join-Path $racineDepot 'Mindset\fichiers\modules'
$sortie = Join-Path $racineDepot 'rust\mindset-ecrans\tests\juges'
New-Item -ItemType Directory -Force -Path $sortie | Out-Null
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$R = Join-Path $env:TEMP "mindset-juges-ecrans-$PID"
if (Test-Path -LiteralPath $R) { Remove-Item -LiteralPath $R -Recurse -Force }
New-Item -ItemType Directory -Force -Path $R | Out-Null
$R = (Get-Item -LiteralPath $R).FullName
# (attention : PowerShell ne distingue pas $R de $r, aucune autre variable ne s'appelle ainsi)
function Get-SansRacine([string]$t) { $t.Replace($R, '{RACINE}') }

# ---------------------------------------------------------------------------------------------------------------
# Les vraies fonctions, prises dans leur fichier
# ---------------------------------------------------------------------------------------------------------------
$asts = @{}
foreach ($n in 'accueil', 'interface', 'themes', 'logo', 'applis', 'paquets') {
    $e = $null
    $asts[$n] = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $modules "$n.ps1"), [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
    if ($e) { throw "$n.ps1 illisible : $($e[0].Message)" }
}
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    foreach ($n in $Noms) {
        $f = $asts[$Fichier].Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true)
        if (-not $f) { throw "Fonction $n introuvable dans $Fichier.ps1" }
        . ([scriptblock]::Create($f.Extent.Text))
        Set-Item -Path "function:script:$n" -Value (Get-Item "function:$n").ScriptBlock
    }
}
Import-Fonctions 'themes' @('ConvertTo-Hsl', 'ConvertFrom-Hsl', 'ConvertTo-ThemeHex', 'Get-Couleur', 'Convert-ThemeXaml', 'Get-ThemeHello')
Import-Fonctions 'interface' @('Get-Brush', 'New-Button', 'New-Text')
Import-Fonctions 'logo' @('Get-ArcGeometry', 'New-Glow', 'New-LinearBrush', 'New-LogoArc')
Import-Fonctions 'applis' @('Test-AppliAdmin')
Import-Fonctions 'paquets' @('Test-VersionPlusRecente')
Import-Fonctions 'accueil' @('Get-Appli', 'Update-Greeting', 'New-Carte', 'New-Pastille', 'New-BoutonAction', 'Get-EtatAppli', 'Get-ProchainsRdv',
    'Format-QuandRdv', 'New-LigneVivante', 'New-JaugeScore', 'Add-ResumeCarte', 'Get-EtatCarte', 'Update-Carte', 'New-InterrupteurOuverture',
    'Get-PhraseReseauAppli', 'Get-LienReseauAppli', 'New-PhraseReseau', 'Confirm-MiseAJour', 'Confirm-PriseEnCharge', 'Confirm-Desinstallation')
# La table des thèmes (le haut de themes.ps1, hors fonction), telle quelle
$def = $asts['themes'].Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$AppThemes' }, $true)
. ([scriptblock]::Create($def.Extent.Text))
$LogoCyan = '#00E5FF'; $LogoMagenta = '#FF2EB5'
$EnTest = $true
$PackFont = $null; $ThemePack = $null

# ---------------------------------------------------------------------------------------------------------------
# Le faux PC
# ---------------------------------------------------------------------------------------------------------------
$script:Maintenant = [datetime]'2026-11-07T20:00:00'
function Get-Date { $script:Maintenant }
$RacineProgrammes = Join-Path $R 'Programmes'
$SuiteDir = Join-Path $R 'Donnees'
$MindsetAdmin = $false
$script:Inst = @{}; $script:Ouvertes = @{}; $script:Travail = @{}; $script:Demarrages = @{}
$script:Publications = @{}; $script:Trouvees = @{}; $script:Occupe = @{}; $script:Messages = @{}
$script:Cartes = @{}; $script:CartesCle = @{}; $script:EtatsApplis = @{}; $script:Interrupteurs = New-Object System.Collections.ArrayList
function Get-Installation($Appli) { $script:Inst[$Appli.Id] }
function Test-AppliOuverte($Appli) { [bool]$script:Ouvertes[$Appli.Id] }
function Get-DossierGere($Appli) { Join-Path $RacineProgrammes $Appli.Nom }
function Get-DossierDonnees($Appli) {
    $inst = $script:Inst[$Appli.Id]
    $suite = Join-Path $SuiteDir $Appli.Nom
    if ($inst -and $inst.Gere -and (Test-Path -LiteralPath $suite)) { $suite } else { $Appli.Donnees }
}
function Test-DossierTravail([string]$Dossier) { $Dossier -and ((Test-Path -LiteralPath (Join-Path $Dossier '.git')) -or (Test-Path -LiteralPath (Join-Path (Split-Path $Dossier -Parent) '.git'))) }
function Get-DemarrageAppli([string]$Id) { [bool]$script:Demarrages[$Id] }
function Set-DemarrageAppli { }
function Open-AppliIci { }
function Open-PageConfidentialite { }
function Start-InstallAppli { }
$script:Confirmation = $null
function Show-Confirmation([string]$Titre, [string]$Texte, [string]$Bouton, [scriptblock]$Oui) { $script:Confirmation = [ordered]@{ titre = $Titre; texte = $Texte; bouton = $Bouton; valeur = $script:DerniereValeur } }
function New-Action([hashtable]$Valeurs, [scriptblock]$Code) { $script:DerniereValeur = $Valeurs; { } }

# La fenêtre (jamais montrée : seulement ses ressources, les styles des boutons et des cartes)
function Open-Fenetre([string]$Theme) {
    $script:ThemeId = $Theme; $script:Theme = $AppThemes[$Theme]; $script:ThemeCache = @{}
    [xml]$x = Convert-ThemeXaml ([IO.File]::ReadAllText((Join-Path $modules 'interface.xaml'), [Text.Encoding]::UTF8)) $Theme
    $script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $script:ui = @{}
    foreach ($node in $x.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $n = $node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
        if ($n) { $script:ui[$n.Value] = $script:Window.FindName($n.Value) }
    }
}

# Les applis d'essai : les trois de apps.json, et une inventée (sans logo ni page de confidentialité)
$Applis = @(
    [pscustomobject]@{ Id = 'nevermind'; Nom = 'Nevermind'; Couleur = '#00E5FF'; Description = 'Analyse et optimisation gaming'; Exe = 'Nevermind.exe'; Script = 'fichiers\Nevermind.ps1'
        Desinstalleur = 'Désinstaller Nevermind.exe'; Admin = $true; SansDroitsDepuis = '1.0.115'; Rappels = $false; Confidentialite = 'https://github.com/JordanJacquot/Nevermind/blob/main/CODE_SIGNING.md'; Donnees = '' }
    [pscustomobject]@{ Id = 'evermind'; Nom = 'Evermind'; Couleur = '#B04BFF'; Description = "L'agenda qui se souvient de tout pour toi"; Exe = 'Evermind.exe'; Script = 'fichiers\Evermind.ps1'
        Desinstalleur = ''; Admin = $false; SansDroitsDepuis = ''; Rappels = $true; Confidentialite = 'https://github.com/JordanJacquot/Evermind/blob/main/CODE_SIGNING.md'; Donnees = '' }
    [pscustomobject]@{ Id = 'mindcare'; Nom = 'Mindcare'; Couleur = '#FF8A00'; Description = 'Trouve pourquoi ton PC est en panne, en répondant à quelques questions simples.'; Exe = 'Mindcare.exe'; Script = 'fichiers\Mindcare.ps1'
        Desinstalleur = ''; Admin = $false; SansDroitsDepuis = ''; Rappels = $false; Confidentialite = 'https://github.com/JordanJacquot/Mindcare/blob/main/CODE_SIGNING.md'; Donnees = '' }
    [pscustomobject]@{ Id = 'zephyr'; Nom = 'Zéphyr'; Couleur = '#3DDC84'; Description = 'Une appli inventée pour les essais'; Exe = 'Zephyr.exe'; Script = ''
        Desinstalleur = ''; Admin = $false; SansDroitsDepuis = ''; Rappels = $false; Confidentialite = ''; Donnees = '' }
)

# ---------------------------------------------------------------------------------------------------------------
# La carte dessinée, relue
# ---------------------------------------------------------------------------------------------------------------
function Get-Hex($Brush) { $c = $Brush.Color.ToString(); if ($c.StartsWith('#FF')) { '#' + $c.Substring(3) } else { $c } }
function Get-Marge($El) { $m = $El.Margin.ToString(); if ($m -eq '0,0,0,0') { $null } else { $m } }
function Get-TexteEl($t) {
    $o = [ordered]@{ t = 'texte'; texte = (Get-SansRacine $t.Text); taille = $t.FontSize; couleur = (Get-Hex $t.Foreground); poids = $t.FontWeight.ToString() }
    $m = Get-Marge $t; if ($m) { $o.marge = $m }
    $o
}
function Get-Jauges($Wrap) {
    @(foreach ($j in $Wrap.Children) {
        $g = $j.Children[0]; $arc = $g.Children[0].Children[1]
        [ordered]@{ nom = $j.Children[1].Text; valeur = [int]$g.Children[1].Text; c1 = (Get-Hex ([System.Windows.Media.SolidColorBrush]::new($arc.Stroke.GradientStops[0].Color))); c2 = (Get-Hex ([System.Windows.Media.SolidColorBrush]::new($arc.Stroke.GradientStops[1].Color))) }
    })
}
function Get-Ligne($b) { $t = $b.Child; [ordered]@{ texte = $t.Text; couleur = (Get-Hex $t.Foreground) } }
function Get-Resume($Box, $Appli) {
    $o = [ordered]@{ t = 'resume' }
    $enf = @($Box.Children)
    if ($Appli.Id -eq 'nevermind') {
        $o.genre = 'nevermind'; $o.scores = @(Get-Jauges $enf[0]); $o.ligne = Get-Ligne $enf[1]
    } elseif ($Appli.Id -eq 'evermind') {
        $o.genre = 'evermind'
        $o.rdv = @(foreach ($b in ($enf | Select-Object -Skip 1)) {
            if ($b -is [System.Windows.Controls.TextBlock]) { continue }
            $q = $b.Child.Children[0]; $ti = $b.Child.Children[1]
            [ordered]@{ quand = $q.Text; titre = $ti.Text; id = $b.Tag.Id; moment = $b.Tag.Quand.ToString('s') }
        })
        if (-not $o.rdv.Count) { $o.vide = $enf[1].Text }
    } else {
        $o.genre = 'commun'; $o.titre = $null; $o.scores = @(); $o.lignes = @()
        foreach ($x in $enf) {
            if ($x -is [System.Windows.Controls.TextBlock]) { $o.titre = $x.Text }
            elseif ($x -is [System.Windows.Controls.WrapPanel]) { $o.scores = @(Get-Jauges $x) }
            else { $o.lignes += Get-Ligne $x }
        }
    }
    $o
}
function Get-Carte($Appli) {
    $sp = $script:Cartes[$Appli.Id]
    @(foreach ($el in $sp.Children) {
        if ($el -is [System.Windows.Controls.TextBlock]) {
            $lien = @($el.Inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] })
            if ($lien.Count) {
                $run = @($el.Inlines)[0]
                $o = [ordered]@{ t = 'reseau'; texte = $run.Text; lien = $lien[0].Inlines.FirstInline.Text; taille = $el.FontSize; couleur = (Get-Hex $el.Foreground); lien_couleur = (Get-Hex $lien[0].Foreground); marge = (Get-Marge $el) }
                $o
            } else { Get-TexteEl $el }
        } elseif ($el -is [System.Windows.Controls.WrapPanel]) {
            $marge = Get-Marge $el
            if (@($el.Children | Where-Object { $_ -is [System.Windows.Controls.Button] }).Count) {
                $quoi = @{ 'Installer' = 'installer'; 'Mettre à jour' = 'maj'; 'Ouvrir' = 'ouvrir'; 'Désinstaller' = 'desinstaller'; 'Prendre en charge' = 'prendre'; 'Choisir son dossier' = 'choisir'; 'Utiliser telle quelle' = 'utiliser' }
                [ordered]@{ t = 'boutons'; marge = $marge; liste = @(foreach ($b in $el.Children) {
                    [ordered]@{ texte = [string]$b.Content; style = $(if ($b.Style -eq $Window.FindResource('BtnPrimary')) { 'primaire' } else { 'secondaire' }); quoi = $quoi[[string]$b.Content] }
                }) }
            } else {
                [ordered]@{ t = 'pastilles'; marge = $marge; liste = @(foreach ($p in $el.Children) { [ordered]@{ texte = $p.Child.Text; couleur = (Get-Hex $p.BorderBrush) } }) }
            }
        } elseif ($el -is [System.Windows.Controls.DockPanel]) {
            $sw = $el.Children[0]; $tx = $el.Children[1]
            [ordered]@{ t = 'interrupteur'; oui = [bool]$sw.IsChecked; texte = $tx.Children[0].Text; aide = $tx.Children[1].Text; marge = (Get-Marge $el) }
        } elseif ($el -is [System.Windows.Controls.StackPanel]) { Get-Resume $el $Appli }
        else { [ordered]@{ t = "inconnu:$($el.GetType().Name)" } }
    })
}

# Un cas : l'état de l'appli, puis sa carte
function Invoke-Cas([hashtable]$C) {
    $a = $Applis | Where-Object Id -eq $C.appli
    foreach ($t in 'Inst', 'Ouvertes', 'Demarrages', 'Publications', 'Trouvees', 'Occupe', 'Messages', 'CartesCle', 'EtatsApplis') { Set-Variable -Scope Script -Name $t -Value @{} }
    $dossierCas = Join-Path $R "cas-$($script:NumeroCas)"; $script:NumeroCas++
    $a.Donnees = Join-Path $dossierCas 'anciennes-donnees'
    # (les données de la suite de cette appli : celles du cas précédent sont retirées)
    $suiteAppli = Join-Path $SuiteDir $a.Nom
    if (Test-Path -LiteralPath $suiteAppli) { Remove-Item -LiteralPath $suiteAppli -Recurse -Force }
    if ($C.donnees_existe) { New-Item -ItemType Directory -Force -Path $a.Donnees | Out-Null }
    if ($C.inst) {
        $d = if ($C.inst.gere) { Get-DossierGere $a } else { $C.inst.dossier.Replace('{RACINE}', $R) }
        $script:Inst[$a.Id] = @{ Dossier = $d; Gere = [bool]$C.inst.gere; Version = $C.inst.version }
    }
    if ($null -ne $C.etat) {
        $ed = if ($C.inst -and $C.inst.gere) { Join-Path $SuiteDir $a.Nom } else { $a.Donnees }
        New-Item -ItemType Directory -Force -Path $ed | Out-Null
        [IO.File]::WriteAllText((Join-Path $ed 'etat.json'), [string]$C.etat, (New-Object Text.UTF8Encoding $false))
    }
    if ($C.pub) { $script:Publications[$a.Id] = @{ Version = $C.pub.version; Erreur = $C.pub.erreur } }
    if ($C.ouverte) { $script:Ouvertes[$a.Id] = $true }
    if ($C.trouvee) {
        $t = $C.trouvee.Replace('{RACINE}', $R)
        if ($C.travail -and $t.StartsWith($R)) {   # (jamais hors du dossier d'essai)
            New-Item -ItemType Directory -Force -Path (Join-Path $t '.git') | Out-Null
        } elseif ($t.StartsWith($R) -and (Test-Path -LiteralPath (Join-Path $t '.git'))) { Remove-Item -LiteralPath (Join-Path $t '.git') -Recurse -Force }   # (celui d'un cas précédent)
        $script:Trouvees[$a.Id] = $t
    }
    if ($C.occupe) { $script:Occupe[$a.Id] = $C.occupe }
    if ($C.message) { $script:Messages[$a.Id] = $C.message }
    if ($C.demarrage) { $script:Demarrages[$a.Id] = $true }
    $script:MindsetAdmin = [bool]$C.admin
    $script:ui.Cartes.Children.Clear()
    New-Carte $a
    Update-Carte $a
    $res = [ordered]@{ nom = $C.nom; theme = $script:ThemeId; entree = $C; carte = @(Get-Carte $a) }
    # (la question posée par un bouton : mettre à jour, prendre en charge, désinstaller)
    $script:Confirmation = $null
    $q = [ordered]@{}
    if ($C.inst -and $C.pub) { $script:Confirmation = $null; Confirm-MiseAJour $a; $q.maj = $script:Confirmation }
    if ($script:Trouvees[$a.Id] -or ($C.inst -and -not $C.inst.gere)) {
        $script:Confirmation = $null
        $dos = if ($C.inst -and -not $C.inst.gere) { $script:Inst[$a.Id].Dossier } else { '' }
        Confirm-PriseEnCharge $a $dos; $q.prendre = $script:Confirmation
    }
    if ($C.inst) { $script:Confirmation = $null; Confirm-Desinstallation $a; $q.desinstaller = $script:Confirmation }
    foreach ($k in @($q.Keys)) { if ($q[$k]) { $q[$k].texte = Get-SansRacine $q[$k].texte; $q[$k].titre = Get-SansRacine $q[$k].titre; if ($q[$k].valeur -and $q[$k].valeur.Dossier) { $q[$k].valeur.Dossier = Get-SansRacine $q[$k].valeur.Dossier } } }
    $res.questions = $q
    $res
}

# ---------------------------------------------------------------------------------------------------------------
# Les cas des cartes
# ---------------------------------------------------------------------------------------------------------------
$G = { param($v) @{ gere = $true; version = $v } }
$rdv = { param($id, $quand, $titre, $journee) [ordered]@{ Id = $id; Titre = $titre; Quand = $quand; Journee = $journee } }

$ids = @(); for ($i = 1; $i -le 12; $i++) { $ids += ('{0}{1}' -f ('a' * 31), ('0123456789abcdef'[$i])) }
$cas = @(
    @{ nom = 'pas installé'; appli = 'nevermind' }
    @{ nom = 'pas installé, evermind'; appli = 'evermind' }
    @{ nom = 'pas installé, mindcare'; appli = 'mindcare' }
    @{ nom = 'pas installé, appli sans page de confidentialité'; appli = 'zephyr' }
    @{ nom = 'pas installé, ses anciennes données existent'; appli = 'evermind'; donnees_existe = $true }
    @{ nom = 'pas installé, erreur de publication'; appli = 'mindcare'; pub = @{ erreur = 'GitHub ne répond pas : réessaie plus tard.' } }
    @{ nom = 'pas installé, message après une opération'; appli = 'mindcare'; message = 'Installation impossible : le téléchargement a échoué.'; pub = @{ erreur = 'cachée par le message' } }
    @{ nom = 'trouvé sur le PC'; appli = 'nevermind'; trouvee = 'D:\Jeux\Nevermind' }
    @{ nom = 'trouvé sur le PC, dossier de travail'; appli = 'evermind'; trouvee = '{RACINE}\travail\Evermind'; travail = $true }
    @{ nom = 'trouvé sur le PC, données existantes aussi'; appli = 'mindcare'; trouvee = 'D:\Outils\Mindcare-copie'; donnees_existe = $true }
    @{ nom = 'occupé, pas installé'; appli = 'mindcare'; occupe = 'Téléchargement... 40 %' }
    @{ nom = 'occupé, installé'; appli = 'evermind'; inst = (& $G '1.4.0'); occupe = 'Mise à jour...'; message = 'caché pendant une opération' }
    @{ nom = 'installé, fermé'; appli = 'evermind'; inst = (& $G '1.4.0') }
    @{ nom = 'installé, ouvert, démarre avec Mindset'; appli = 'evermind'; inst = (& $G '1.4.0'); ouverte = $true; demarrage = $true }
    @{ nom = 'installé, version inconnue'; appli = 'mindcare'; inst = (& $G $null) }
    @{ nom = 'installé, nouvelle version'; appli = 'mindcare'; inst = (& $G '0.3.0'); pub = @{ version = '0.4.1' } }
    @{ nom = 'installé ouvert, nouvelle version'; appli = 'evermind'; inst = (& $G '1.4.0'); pub = @{ version = '1.10.0' }; ouverte = $true }
    @{ nom = 'installé, même version publiée'; appli = 'evermind'; inst = (& $G '1.4.0'); pub = @{ version = '1.4.0' } }
    @{ nom = 'installé, publication plus ancienne'; appli = 'evermind'; inst = (& $G '1.4.0'); pub = @{ version = '1.3.9' } }
    @{ nom = 'installé, erreur de publication (pas montrée)'; appli = 'mindcare'; inst = (& $G '0.3.0'); pub = @{ erreur = 'GitHub ne répond pas.' } }
    @{ nom = 'installé, message'; appli = 'mindcare'; inst = (& $G '0.3.0'); message = 'Mindcare est à jour (version 0.3.0).' }
    @{ nom = 'copie non gérée'; appli = 'evermind'; inst = @{ gere = $false; dossier = 'D:\Applis\Evermind'; version = '1.2.0' } }
    @{ nom = 'copie non gérée, nouvelle version'; appli = 'mindcare'; inst = @{ gere = $false; dossier = 'D:\Applis\Mindcare'; version = '0.1.0' }; pub = @{ version = '0.2.0' } }
    @{ nom = 'nevermind en administrateur, Mindset sans les droits'; appli = 'nevermind'; inst = (& $G '1.0.100') }
    @{ nom = 'nevermind en administrateur, Mindset avec les droits'; appli = 'nevermind'; inst = (& $G '1.0.100'); admin = $true }
    @{ nom = 'nevermind sans droits depuis 1.0.115'; appli = 'nevermind'; inst = (& $G '1.0.115'); demarrage = $true }
    @{ nom = 'nevermind, version inconnue : droits supposés'; appli = 'nevermind'; inst = (& $G $null) }
    @{ nom = 'nevermind, scores et à faire'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = '{"Score":82,"Protection":64,"AFaire":"Mettre à jour le pilote graphique","Urgent":false,"NbAFaire":1}' }
    @{ nom = 'nevermind, urgent'; appli = 'nevermind'; inst = (& $G '2.0.1'); ouverte = $true; etat = '{"Score":"45","Protection":12,"AFaire":"Antivirus coupé","Urgent":true}' }
    @{ nom = 'nevermind, rien à corriger'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = '{"Score":100,"Protection":100,"AFaire":"","Urgent":false}' }
    @{ nom = 'nevermind, valeurs hors limites'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = '{"Score":101,"Protection":-3,"AFaire":null}' }
    @{ nom = 'nevermind, valeurs bizarres'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = '{"Score":75.0,"Protection":"  33 ","AFaire":"   ","Urgent":"true"}' }
    @{ nom = 'nevermind, décimales et vrai'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = '{"Score":75.5,"Protection":true,"AFaire":"Trop long : ' + ('x' * 100) + '","Urgent":1}' }
    @{ nom = 'nevermind, une seule jauge'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = '{"Protection":50,"AFaire":"Ligne\tavec\u0001des\ncontrôles"}' }
    @{ nom = 'nevermind, json abîmé'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = '{"Score":82,' }
    @{ nom = 'nevermind, json vide'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = '' }
    @{ nom = 'nevermind, fichier trop gros'; appli = 'nevermind'; inst = (& $G '2.0.1'); etat = ('{"Score":82,"AFaire":"' + ('y' * 33000) + '"}') }
    @{ nom = 'nevermind, copie non gérée : pas de résumé'; appli = 'nevermind'; inst = @{ gere = $false; dossier = 'D:\Jeux\Nevermind'; version = '2.0.1' }; etat = '{"Score":82}' }
    @{ nom = 'evermind, rien de prévu'; appli = 'evermind'; inst = (& $G '1.4.0'); etat = '{"Prochains":[]}' }
    @{ nom = 'evermind, sans prochains'; appli = 'evermind'; inst = (& $G '1.4.0'); etat = '{}' }
    @{ nom = 'evermind, rendez-vous'; appli = 'evermind'; inst = (& $G '1.4.0'); etat = (ConvertTo-Json -Depth 4 -Compress @{ Prochains = @(
        (& $rdv $ids[0] '2026-11-07T19:30:00' 'Passé il y a une demi-heure' $false),
        (& $rdv $ids[1] '2026-11-07T00:00:00' 'Toute la journée aujourd''hui' $true),
        (& $rdv $ids[2] '2026-11-07T21:15:00' 'Appeler maman' $false),
        (& $rdv $ids[3] '2026-11-08T09:00:00' 'Dentiste' $false),
        (& $rdv $ids[4] '2026-11-11T00:00:00' 'Férié' $true)) }) }
    @{ nom = 'evermind, jours de la semaine et plus loin'; appli = 'evermind'; inst = (& $G '1.4.0'); etat = (ConvertTo-Json -Depth 4 -Compress @{ Prochains = @(
        (& $rdv $ids[5] '2026-11-10T18:00:00' 'Mardi soir' $false),
        (& $rdv $ids[6] '2026-11-13T08:05:00' 'Vendredi matin' $false),
        (& $rdv $ids[7] '2026-11-14T12:00:00' 'Une semaine plus tard' $false)) }) }
    @{ nom = 'evermind, plus loin encore'; appli = 'evermind'; inst = (& $G '1.4.0'); etat = (ConvertTo-Json -Depth 4 -Compress @{ Prochains = @(
        (& $rdv $ids[8] '2026-12-25T00:00:00' 'Noël' $true),
        (& $rdv $ids[9] '2027-02-03T14:30:00' 'Février' $false),
        (& $rdv $ids[10] '2027-08-15T10:00:00' 'Août' $false)) }) }
    @{ nom = 'evermind, rendez-vous refusés'; appli = 'evermind'; inst = (& $G '1.4.0'); etat = (ConvertTo-Json -Depth 4 -Compress @{ Prochains = @(
        (& $rdv ('A' * 32) '2026-11-08T09:00:00' 'Id en majuscules' $false),
        (& $rdv ('a' * 31) '2026-11-08T09:00:00' 'Id trop court' $false),
        (& $rdv $ids[0] '08/11/2026 09:00' 'Date mal écrite' $false),
        (& $rdv $ids[1] '2026-11-08T09:00:00Z' 'Date avec Z' $false),
        (& $rdv $ids[2] '2026-11-09T07:00:00' ('Titre très long ' * 8) 'true'),
        @{ Id = $ids[3]; Quand = '2026-11-09T08:00:00' }) }) }
    @{ nom = 'evermind, onze rendez-vous : les dix premiers lus'; appli = 'evermind'; inst = (& $G '1.4.0'); etat = (ConvertTo-Json -Depth 4 -Compress @{ Prochains = @(
        (& $rdv $ids[0] '2026-11-01T09:00:00' 'a' $false), (& $rdv $ids[1] '2026-11-01T09:00:00' 'b' $false), (& $rdv $ids[2] '2026-11-01T09:00:00' 'c' $false),
        (& $rdv $ids[3] '2026-11-01T09:00:00' 'd' $false), (& $rdv $ids[4] '2026-11-01T09:00:00' 'e' $false), (& $rdv $ids[5] '2026-11-01T09:00:00' 'f' $false),
        (& $rdv $ids[6] '2026-11-01T09:00:00' 'g' $false), (& $rdv $ids[7] '2026-11-01T09:00:00' 'h' $false), (& $rdv $ids[8] '2026-11-01T09:00:00' 'i' $false),
        (& $rdv $ids[9] '2026-11-01T09:00:00' 'j' $false), (& $rdv $ids[10] '2026-11-20T09:00:00' 'Le onzième' $false)) }) }
    @{ nom = 'commun, complet'; appli = 'mindcare'; inst = (& $G '0.3.0'); etat = '{"Titre":"Dernière enquête","Scores":[{"Nom":"Santé","Valeur":72},{"Nom":"Disque","Valeur":"30"},{"Nom":"Trop","Valeur":10}],"Lignes":[{"Texte":"Tout va bien","Etat":"ok"},{"Texte":"À surveiller","Etat":"ATTENTION"},{"Texte":"Urgent !","Etat":"urgent"},{"Texte":"Quatrième","Etat":"info"}]}' }
    @{ nom = 'commun, valeurs refusées'; appli = 'mindcare'; inst = (& $G '0.3.0'); etat = '{"Titre":"","Scores":[{"Nom":"","Valeur":50},{"Nom":"Sans valeur"},{"Nom":"Ok","Valeur":0}],"Lignes":[{"Texte":"","Etat":"ok"},{"Texte":"Etat inconnu","Etat":"rouge"},{"Texte":"Sans etat"}]}' }
    @{ nom = 'commun, objets au lieu de listes'; appli = 'zephyr'; inst = (& $G '1.0.0'); etat = '{"Titre":"Un seul","Scores":{"Nom":"Seul","Valeur":"99"},"Lignes":{"Texte":"Une seule ligne","Etat":"info"}}' }
    @{ nom = 'commun, rien'; appli = 'zephyr'; inst = (& $G '1.0.0'); etat = '{"Autre":1}' }
    @{ nom = 'commun, accents et caractères spéciaux'; appli = 'mindcare'; inst = (& $G '0.3.0'); etat = '{"Titre":"Été « chaud » & <balises>","Lignes":[{"Texte":"Ça marche : 100 % ✓","Etat":"ok"}]}' }
)

function Write-Juge([string]$Nom, $Valeur) {
    $f = Join-Path $sortie "$Nom.json"
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $Valeur -Depth 12), (New-Object Text.UTF8Encoding $false))
    Write-Output "  $f"
}

try {
    $script:NumeroCas = 0
    Write-Output 'Juges du bloc « écrans » :'
    Open-Fenetre 'neon'
    Write-Juge 'cartes' @(foreach ($c in $cas) { Invoke-Cas $c })
    # Les mêmes cartes, couleurs traduites dans un autre thème (Crépuscule, Terminal : les gris et la marque changent)
    Open-Fenetre 'crepuscule'
    Write-Juge 'cartes-crepuscule' @(foreach ($c in $cas | Select-Object -First 30) { Invoke-Cas $c })
    Open-Fenetre 'terminal'
    Write-Juge 'cartes-terminal' @(foreach ($c in $cas | Select-Object -Skip 26 -First 24) { Invoke-Cas $c })

    # Des cas tirés au hasard (graine fixe : toujours les mêmes), jamais écrits un par un : chaque champ de la carte
    # et du résumé pris dans une liste de valeurs, bonnes ou mauvaises ; moitié en Néon, moitié en Rubis
    $alea = New-Object Random 20261107
    $un = { param($l) $l[$alea.Next($l.Count)] }
    $valeurs = @(0, 1, 50, 99, 100, 101, -5, '42', ' 7 ', '7.5', 12.0, 33.3, $true, $null, 'abc', @(60))
    $textes = @('', ' ', 'Court', 'Avec « guillemets » & <balises>', ('Long ' * 30), "Tab`tet`nretour", 'Été 2026 ✓', $null, 7)
    $hasard = @(for ($i = 0; $i -lt 80; $i++) {
        $c = @{ nom = "hasard $i"; appli = (& $un @('nevermind', 'evermind', 'mindcare', 'zephyr')) }
        switch ($alea.Next(5)) {
            0 { }
            1 { $c.inst = @{ gere = $true; version = (& $un @('1.0.100', '1.0.115', '2.0.1', '0.3.0', $null, '1.4.0', '10.0')) } }
            2 { $c.inst = @{ gere = $true; version = (& $un @('1.0.100', '2.0.1', '1.4.0')) } }
            3 { $c.inst = @{ gere = $false; dossier = (& $un @('D:\Applis\Copie', '{RACINE}\ailleurs\Copie')); version = (& $un @('1.0.0', $null)) } }
            4 { $c.trouvee = (& $un @('D:\Jeux\Trouve', '{RACINE}\travail\Trouve')); $c.travail = ($alea.Next(2) -eq 1) -and $c.trouvee.StartsWith('{RACINE}') }
        }
        if ($alea.Next(3) -eq 0) { $c.pub = if ($alea.Next(2)) { @{ version = (& $un @('0.4.0', '1.10.0', '2.0.2', '1.0.115', '9.9.9')) } } else { @{ erreur = 'GitHub ne répond pas.' } } }
        if ($alea.Next(2)) { $c.ouverte = $true }
        if ($alea.Next(6) -eq 0) { $c.occupe = (& $un @('Téléchargement... 12 %', 'Désinstallation...', 'Installation...')) }
        if ($alea.Next(5) -eq 0) { $c.message = (& $un @('Mise à jour faite.', 'Installation impossible : disque plein.')) }
        if ($alea.Next(2)) { $c.demarrage = $true }
        if ($alea.Next(4) -eq 0) { $c.admin = $true }
        if ($alea.Next(4) -eq 0) { $c.donnees_existe = $true }
        if ($c.inst -and $alea.Next(4)) {
            $o = [ordered]@{}
            switch ($c.appli) {
                'nevermind' { foreach ($k in 'Score', 'Protection', 'AFaire', 'Urgent') { if ($alea.Next(4)) { $o[$k] = if ($k -eq 'AFaire') { & $un $textes } elseif ($k -eq 'Urgent') { & $un @($true, $false, 'true', 1, 0, $null) } else { & $un $valeurs } } } }
                'evermind' {
                    $o.Prochains = @(for ($k = 0; $k -lt $alea.Next(7); $k++) {
                        $q = $script:Maintenant.AddMinutes($alea.Next(-3000, 20000))
                        [ordered]@{ Id = $(if ($alea.Next(6)) { ('{0:x8}' -f $alea.Next()) * 4 } else { 'pas-un-id' }); Titre = (& $un $textes)
                            Quand = $(if ($alea.Next(8)) { $q.ToString('s') } else { $q.ToString('dd/MM/yyyy HH:mm') }); Journee = (& $un @($true, $false, 'True', $null)) }
                    })
                }
                default {
                    if ($alea.Next(2)) { $o.Titre = & $un $textes }
                    if ($alea.Next(3)) { $o.Scores = @(for ($k = 0; $k -lt $alea.Next(4); $k++) { [ordered]@{ Nom = (& $un $textes); Valeur = (& $un $valeurs) } }) }
                    if ($alea.Next(3)) { $o.Lignes = @(for ($k = 0; $k -lt $alea.Next(5); $k++) { [ordered]@{ Texte = (& $un $textes); Etat = (& $un @('ok', 'info', 'attention', 'urgent', 'URGENT', 'autre', $null)) } }) }
                }
            }
            $c.etat = ConvertTo-Json -InputObject $o -Depth 5 -Compress
        }
        $c
    })
    $sortieHasard = @(foreach ($c in $hasard | Select-Object -First 40) { Invoke-Cas $c })
    Open-Fenetre 'rubis'
    $sortieHasard += @(foreach ($c in $hasard | Select-Object -Skip 40) { Invoke-Cas $c })
    Write-Juge 'cartes-hasard' $sortieHasard

    # Le bonjour, selon l'heure et la phrase du thème personnalisé
    Open-Fenetre 'neon'
    $bonjours = @()
    foreach ($hello in @($null, '{0}, prêt à jouer ?', 'Coucou', '{0} {0} !')) {
        foreach ($heure in 0, 4, 5, 12, 17, 18, 23) {
            $script:Maintenant = [datetime]::new(2026, 11, 7, $heure, 30, 0)
            $ThemePack = if ($null -ne $hello) { @{ Hello = $hello } } else { $null }
            Update-Greeting
            $bonjours += [ordered]@{ heure = $heure; hello = $hello; texte = $ui.Greeting.Text }
        }
    }
    $ThemePack = $null
    $script:Maintenant = [datetime]'2026-11-07T20:00:00'
    Write-Juge 'bonjour' $bonjours

    # Les dates des rendez-vous (Format-QuandRdv), autour de plusieurs jours
    $quands = @()
    foreach ($m in '2026-11-07T20:00:00', '2026-12-30T08:00:00', '2027-02-27T23:59:00') {
        $script:Maintenant = [datetime]$m
        for ($j = 0; $j -le 9; $j++) {
            foreach ($journee in $false, $true) {
                $q = $script:Maintenant.Date.AddDays($j).AddHours(7).AddMinutes(5 * $j)
                $quands += [ordered]@{ maintenant = $m; quand = $q.ToString('s'); journee = $journee; texte = (Format-QuandRdv @{ Quand = $q; Journee = $journee }) }
            }
        }
        foreach ($mois in 1..12) {
            $q = [datetime]::new(2027, $mois, 3, 9, 0, 0)
            $quands += [ordered]@{ maintenant = $m; quand = $q.ToString('s'); journee = $false; texte = (Format-QuandRdv @{ Quand = $q; Journee = $false }) }
        }
    }
    $script:Maintenant = [datetime]'2026-11-07T20:00:00'
    Write-Juge 'quand-rdv' $quands

    # Ce qui part sur Internet (carte, console, prise en charge)
    Write-Juge 'reseau' @(foreach ($a in $Applis) { [ordered]@{ id = $a.Id; phrase = (Get-PhraseReseauAppli $a); lien = (Get-LienReseauAppli $a) } })
    Write-Output 'Fini.'
} catch { Write-Output "ERREUR : $($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)`n$($_.ScriptStackTrace)"; exit 1 } finally {
    Remove-Item -LiteralPath $R -Recurse -Force -ErrorAction SilentlyContinue
}
