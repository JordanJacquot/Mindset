# Mindset : les juges du bloc « près de l'horloge » (rust\mindset-horloge), pris dans la version PowerShell.
#
#   & '.\outils\exporter-juges-horloge.ps1'      (depuis l'outil PowerShell, jamais depuis un autre programme)
#   & '.\outils\exporter-juges-horloge.ps1' -Grain 7      (seulement un lot de cas jamais vus, tirés au hasard)
#
# Les VRAIES fonctions de modules\zone.ps1 (Show-Fenetre, Hide-Fenetre, Update-MenuHorloge, Close-ChoixFermeture,
# Watch-NotificationsApplis, Show-BulleMindset, Open-BulleAppli) et ses gestionnaires (la réduction : Add_StateChanged,
# la croix : Add_Closing, les trois boutons de la question), reprises telles quelles par l'analyseur, avec
# Get-Setting (donnees.ps1), Get-DossierDonnees (installations.ps1) et Show-MessageErreurImprevue (interface.ps1).
# Autour d'elles, des faux : la fenêtre (FauxFenetre : montrer, cacher, réduite, remise en taille normale), l'icône
# (FausseIcone : ses bulles ; son menu est un vrai ContextMenuStrip jamais affiché), Exit-Mindset, Open-AppliConsole,
# Invoke-Actualiser, la liste des applis et leurs installations. Chaque cas est une suite de gestes (la croix, un
# bouton de la question, la réduction, un clic sur l'icône, un choix du menu, une bulle, des notifications d'applis...)
# et, après chaque geste, ce que Mindset a fait. Écrit dans rust\mindset-horloge\tests\juges\*.json.
#
# Rien du PC n'est touché : aucune fenêtre, aucune icône (la fausse icône n'appelle jamais Windows), les fichiers des
# notifications sont dans un dossier d'essai sous %TEMP%, effacé à la fin. Aucun réseau, aucun réglage de Windows.
param([int]$Grain = 0)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$modules = Join-Path $racine 'Mindset\fichiers\modules'
$sortie = Join-Path $racine 'rust\mindset-horloge\tests\juges'
New-Item -ItemType Directory -Force -Path $sortie | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ---------------------------------------------------------------------------------------------------------------
# Les fonctions de Mindset, reprises de leurs fichiers
# ---------------------------------------------------------------------------------------------------------------
function Get-Ast([string]$Fichier) {
    $e = $null
    $a = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $modules $Fichier), [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
    if ($e) { throw "$Fichier illisible : $($e[0].Message)" }
    $a
}
function Get-Fonction($Ast, [string]$Nom) {
    $x = @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Nom }, $true))
    if ($x.Count -ne 1) { throw "$Nom introuvable (ou en double)" }
    $x[0].Extent.Text
}
# Le bloc passé à « <objet>.<Add_xxx>({ ... }) » (un gestionnaire d'événement de zone.ps1)
function Get-Gestionnaire($Ast, [string]$Objet, [string]$Methode) {
    $x = @($Ast.FindAll({ param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq $Methode -and $n.Expression.Extent.Text -eq $Objet
    }, $true))
    if ($x.Count -ne 1) { throw "$Objet.$Methode introuvable (ou en double)" }
    $x[0].Arguments[0].ScriptBlock.GetScriptBlock().ToString()
}

$zone = Get-Ast 'zone.ps1'
$textes = @(
    (Get-Fonction $zone 'Show-Fenetre'), (Get-Fonction $zone 'Hide-Fenetre'), (Get-Fonction $zone 'Update-MenuHorloge'),
    (Get-Fonction $zone 'Close-ChoixFermeture'), (Get-Fonction $zone 'Update-ReglageFermeture'),
    (Get-Fonction $zone 'Watch-NotificationsApplis'), (Get-Fonction $zone 'Show-BulleMindset'), (Get-Fonction $zone 'Open-BulleAppli'),
    (Get-Fonction (Get-Ast 'donnees.ps1') 'Get-Setting'),
    (Get-Fonction (Get-Ast 'installations.ps1') 'Get-DossierDonnees'),
    (Get-Fonction (Get-Ast 'interface.ps1') 'Show-MessageErreurImprevue')
)
foreach ($t in $textes) { . ([scriptblock]::Create($t)) }
$GestionReduite = [scriptblock]::Create((Get-Gestionnaire $zone '$Window' 'Add_StateChanged'))
$GestionCroix = [scriptblock]::Create((Get-Gestionnaire $zone '$Window' 'Add_Closing'))
$GestionReduire = [scriptblock]::Create((Get-Gestionnaire $zone '$ui.BtnFermetureReduire' 'Add_Click'))
$GestionQuitter = [scriptblock]::Create((Get-Gestionnaire $zone '$ui.BtnFermetureQuitter' 'Add_Click'))
$GestionAnnuler = [scriptblock]::Create((Get-Gestionnaire $zone '$ui.BtnFermetureAnnuler' 'Add_Click'))

# ---------------------------------------------------------------------------------------------------------------
# Les faux
# ---------------------------------------------------------------------------------------------------------------
if (-not ('HorlogeJuges.FauxFenetre' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace HorlogeJuges {
    public static class Trace { public static List<string> Lignes = new List<string>(); }
    public class FauxDispatcher { public object BeginInvoke(Action a) { a(); return null; } }
    public class FauxFenetre {
        public bool IsVisible = true;
        public bool ShowInTaskbar = true;
        string etat = "Normal";
        public FauxDispatcher Dispatcher = new FauxDispatcher();
        public string WindowState {
            get { return etat; }
            set { if (value != etat) { etat = value; if (value == "Normal") Trace.Lignes.Add("normal"); } }
        }
        public void Reduire() { etat = "Minimized"; }
        public void Show() { IsVisible = true; Trace.Lignes.Add("montrer"); }
        public void Hide() { IsVisible = false; Trace.Lignes.Add("cacher"); }
        public bool Activate() { return true; }
    }
    public class FausseIcone {
        public System.Windows.Forms.ContextMenuStrip ContextMenuStrip = new System.Windows.Forms.ContextMenuStrip();
        public void ShowBalloonTip(int duree, string titre, string texte, System.Windows.Forms.ToolTipIcon icone) {
            Trace.Lignes.Add("bulle:" + duree + "|" + titre + "|" + texte + "|" + icone);
        }
    }
    public class Annulable { public bool Cancel; }
}
'@
}

function Write-Log([string]$Texte) { [void]$script:Journal.Add($Texte) }
function Set-Setting([string]$Nom, $Valeur) { $script:Settings[$Nom] = $Valeur; [void]$script:Ecrits.Add(@($Nom, $Valeur)) }
function Exit-Mindset([switch]$AvecApplis) {
    $script:QuitterVraiment = $true
    [HorlogeJuges.Trace]::Lignes.Add($(if ($AvecApplis) { 'quitter:avec' } else { 'quitter:sans' }))
}
function Open-AppliConsole([string]$Id) { [HorlogeJuges.Trace]::Lignes.Add("ouvrir:$Id") }
function Invoke-Actualiser { [HorlogeJuges.Trace]::Lignes.Add('actualiser') }
function Invoke-ScriptConsole([string]$Code) { }
function Get-Appli([string]$Id) { $Applis | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
function Get-Installation($Appli) { $script:Inst[$Appli.Id] }
function Read-Installations { $script:Inst }

$EnTest = $false   # (comme le vrai Mindset : les gestionnaires ne s'arrêtent pas au mode test)
$base = Join-Path $env:TEMP "mindset-juges-horloge-$PID"

# ---------------------------------------------------------------------------------------------------------------
# Un cas
# ---------------------------------------------------------------------------------------------------------------
function New-Liste { , (New-Object System.Collections.ArrayList) }

function Get-Menu {
    $l = New-Liste
    foreach ($i in $script:IconeHorloge.ContextMenuStrip.Items) {
        if ($i -is [System.Windows.Forms.ToolStripSeparator]) { [void]$l.Add([ordered]@{ separateur = $true }) }
        else { [void]$l.Add([ordered]@{ separateur = $false; texte = [string]$i.Text; gras = [bool]$i.Font.Bold; appli = $(if ($null -ne $i.Tag) { [string]$i.Tag } else { $null }) }) }
    }
    , $l
}

function Invoke-Cas($Cas) {
    $dossier = Join-Path $base ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dossier | Out-Null
    $script:SuiteDir = Join-Path $dossier 'suite'
    New-Item -ItemType Directory -Force -Path $script:SuiteDir | Out-Null
    [HorlogeJuges.Trace]::Lignes.Clear()
    $script:Journal = New-Liste
    $script:Ecrits = New-Liste
    $script:Settings = @{}
    $o = [string]$Cas.reglages_json | ConvertFrom-Json
    if ($null -ne $o) { foreach ($p in $o.PSObject.Properties) { $script:Settings[$p.Name] = $p.Value } }
    $script:QuitterVraiment = $false
    $script:BulleAppli = $null
    $script:Console = @{ Pret = $false }
    $script:DernieresPublications = if ($null -eq $Cas.derniere_minutes) { [datetime]::MinValue } else { (Get-Date).AddMinutes(-[double]$Cas.derniere_minutes) }
    $script:Window = New-Object HorlogeJuges.FauxFenetre
    $Window.IsVisible = [bool]$Cas.visible
    if ($Cas.minimisee) { $Window.Reduire() }
    $script:IconeHorloge = if ($Cas.icone) { New-Object HorlogeJuges.FausseIcone } else { $null }
    $focus = [pscustomobject]@{}; $focus | Add-Member ScriptMethod Focus { $true }
    $script:ui = @{
        Fermeture = [pscustomobject]@{ Visibility = 'Collapsed' }
        FermetureSouvenir = [pscustomobject]@{ IsChecked = $false }
        BtnFermetureReduire = $focus
        ChoixFermeture = [pscustomobject]@{ Children = @() }
    }
    # Les applis et leurs dossiers
    $script:Applis = @(foreach ($a in @($Cas.applis)) {
        [pscustomobject]@{ Id = [string]$a.id; Nom = [string]$a.nom; AfficherFichier = [string]$a.afficher; Donnees = (Join-Path $dossier ([string]$a.donnees)) }
    })
    $script:Inst = @{}
    if ($Cas.installations) { foreach ($p in $Cas.installations.PSObject.Properties) { $script:Inst[$p.Name] = @{ Dossier = 'X:\Programmes\' + $p.Name; Gere = [bool]$p.Value.gere } } }
    foreach ($n in @($Cas.dossiers_suite)) { if ($n) { New-Item -ItemType Directory -Force -Path (Join-Path $script:SuiteDir $n) | Out-Null } }
    foreach ($a in $script:Applis) { if (-not $a.Donnees.EndsWith('absent')) { New-Item -ItemType Directory -Force -Path $a.Donnees | Out-Null } }

    $etapes = New-Liste
    foreach ($pas in @($Cas.pas)) {
        [HorlogeJuges.Trace]::Lignes.Clear()
        $menu = $null
        switch ([string]$pas.quoi) {
            'croix' {
                $e = New-Object HorlogeJuges.Annulable
                & $GestionCroix $Window $e
                if (-not $e.Cancel) { [HorlogeJuges.Trace]::Lignes.Add('fermee') }
            }
            'reduire' { $Window.Reduire(); & $GestionReduite }
            'bouton' {
                $ui.FermetureSouvenir.IsChecked = [bool]$pas.souvenir
                switch ([string]$pas.choix) { 'reduire' { & $GestionReduire } 'quitter' { & $GestionQuitter } default { & $GestionAnnuler } }
            }
            'clic' { Show-Fenetre }
            'menu' { Update-MenuHorloge; $menu = Get-Menu }
            'menu-choix' {
                Update-MenuHorloge
                $items = @($script:IconeHorloge.ContextMenuStrip.Items | Where-Object { $_ -isnot [System.Windows.Forms.ToolStripSeparator] })
                $items[[int]$pas.n].PerformClick()
            }
            'notifications' {
                foreach ($f in @($pas.fichiers | Where-Object { $_ })) {
                    $a = Get-Appli ([string]$f.appli)
                    $d = if ($f.dossier -eq 'suite') { Join-Path $script:SuiteDir $a.Nom } else { $a.Donnees }
                    [IO.File]::WriteAllBytes((Join-Path $d 'notification.demande'), [Convert]::FromBase64String([string]$f.octets))
                }
                Watch-NotificationsApplis
            }
            'bulle-clic' { Open-BulleAppli }
            'bulle-fermee' { $script:BulleAppli = $null }
            'bulle' {
                $icone = switch ([string]$pas.icone) { 'attention' { [System.Windows.Forms.ToolTipIcon]::Warning } 'aucune' { [System.Windows.Forms.ToolTipIcon]::None } default { [System.Windows.Forms.ToolTipIcon]::Info } }
                Show-BulleMindset ([int]$pas.duree) ([string]$pas.titre) ([string]$pas.texte) $icone
            }
            'erreur' { Show-MessageErreurImprevue }
            'afficher' { Show-Fenetre }
            'veille' { Hide-Fenetre }
            'reglage' { $script:Settings[[string]$pas.nom] = ([string]$pas.valeur_json | ConvertFrom-Json) }
            default { throw "geste inconnu : $($pas.quoi)" }
        }
        $trace = New-Liste
        foreach ($l in [HorlogeJuges.Trace]::Lignes) { [void]$trace.Add($l) }
        $r = [ordered]@{
            trace = $trace
            question = $ui.Fermeture.Visibility -eq 'Visible'
            visible = [bool]$Window.IsVisible
            minimisee = $Window.WindowState -eq 'Minimized'
            bulle_appli = $(if ($script:BulleAppli) { [ordered]@{ appli = [string]$script:BulleAppli.Appli; id = [string]$script:BulleAppli.Id } } else { $null })
        }
        if ($null -ne $menu) { $r.menu = $menu }
        [void]$etapes.Add($r)
    }
    # Les fichiers à la fin : la notification restée (ou effacée), le fichier d'affichage écrit
    $fichiers = [ordered]@{}
    foreach ($a in $script:Applis) {
        foreach ($ou in @(@('suite', (Join-Path $script:SuiteDir $a.Nom)), @('donnees', $a.Donnees))) {
            foreach ($nom in @('notification.demande', $a.AfficherFichier)) {
                if (-not $nom) { continue }
                $f = Join-Path $ou[1] $nom
                $fichiers["$($a.Id)/$($ou[0])/$nom"] = $(if ([IO.File]::Exists($f)) { [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) } else { $null })
            }
        }
    }
    $ecrits = New-Liste
    foreach ($x in $script:Ecrits) { [void]$ecrits.Add([ordered]@{ nom = $x[0]; valeur = $x[1] }) }
    $journal = New-Liste
    foreach ($x in $script:Journal) { [void]$journal.Add($x) }
    Remove-Item -LiteralPath $dossier -Recurse -Force -ErrorAction SilentlyContinue
    $Cas | Add-Member -NotePropertyName etapes -NotePropertyValue $etapes -Force
    $Cas | Add-Member -NotePropertyName ecrits -NotePropertyValue $ecrits -Force
    $Cas | Add-Member -NotePropertyName journal -NotePropertyValue $journal -Force
    $Cas | Add-Member -NotePropertyName fichiers -NotePropertyValue $fichiers -Force
    $Cas
}

# Un cas : réglages (texte JSON), icône, fenêtre, applis, gestes
function C([string]$Nom, [string]$Reglages, [bool]$Icone, $Pas, [bool]$Visible = $true, [bool]$Minimisee = $false, $Derniere = 30, $Applis = @(), $Installations = $null, $Suite = @()) {
    $l = New-Liste; foreach ($p in @($Pas)) { [void]$l.Add($p) }
    $ap = New-Liste; foreach ($a in @($Applis)) { [void]$ap.Add($a) }
    $su = New-Liste; foreach ($s in @($Suite)) { [void]$su.Add($s) }
    [pscustomobject][ordered]@{
        nom = $Nom; reglages_json = $Reglages; icone = $Icone; visible = $Visible; minimisee = $Minimisee; derniere_minutes = $Derniere
        applis = $ap; installations = $Installations; dossiers_suite = $su; pas = $l
    }
}
function P([string]$Quoi, [hashtable]$Plus = @{}) { $h = [ordered]@{ quoi = $Quoi }; foreach ($k in $Plus.Keys) { $h[$k] = $Plus[$k] }; [pscustomobject]$h }
function B([string]$Texte) { [Convert]::ToBase64String((New-Object Text.UTF8Encoding $false).GetBytes($Texte)) }
function BO([byte[]]$Octets) { [Convert]::ToBase64String($Octets) }
function N([string]$Appli, [string]$Octets, [string]$Ou = 'donnees') { [pscustomobject][ordered]@{ appli = $Appli; dossier = $Ou; octets = $Octets } }

$nevermind = [pscustomobject][ordered]@{ id = 'nevermind'; nom = 'Nevermind'; afficher = 'afficher-page.txt'; donnees = 'anciennes\Nevermind' }
$evermind = [pscustomobject][ordered]@{ id = 'evermind'; nom = 'Evermind'; afficher = 'afficher.txt'; donnees = 'anciennes\Evermind' }
$mindcare = [pscustomobject][ordered]@{ id = 'mindcare'; nom = 'Mindcare'; afficher = ''; donnees = 'anciennes\Mindcare' }
$cafe = [pscustomobject][ordered]@{ id = 'cafe-creme'; nom = 'Café crème & Forêt'; afficher = 'afficher-page.txt'; donnees = 'anciennes\Café crème' }
$sansDossier = [pscustomobject][ordered]@{ id = 'foret'; nom = 'Forêt'; afficher = 'afficher-page.txt'; donnees = 'anciennes\absent' }

# ---------------------------------------------------------------------------------------------------------------
# -Grain <n> : seulement un lot de cas JAMAIS VUS (jamais-vus-<n>.json), tirés au hasard avec ce grain une fois le
# code Rust écrit : des contenus de notification.demande fabriqués au hasard (JSON presque juste, abîmé, nombres et
# textes étranges) et des suites de gestes au hasard.
# ---------------------------------------------------------------------------------------------------------------
if ($Grain) {
    $alea = New-Object System.Random $Grain
    $lettres = @('a', 'é', 'Z', ' ', '😀', '\n', '\t', 'é', '\x', '"', "'", '\\', '\/', ':', ',', '{', '}', '0', 'f', 'Ω')
    $nombres = @('0', '-0', '7', '-12', '2147483648', '9223372036854775808', '1.0', '1.50', '-0.0', '.5', '1.', '01', '+3', '1e3', '2E-3', '1.5e+2', '1e400', 'NaN', 'Infinity', '-Infinity', '0x1F', '1e', '-', '12345678901234567890123456789', '0.1234567890123456789012345678901', '5-', '1,5')
    $cles = @('"titre"', '"texte"', '"id"', '"Titre"', 'titre', "'texte'", '"ID"', '""', '"autre"', '1', '"titre "')
    $hexa = '0123456789abcdefABCDEF'
    function Get-Valeur([int]$Prof) {
        $r = $alea.Next(10)
        if ($Prof -gt 2) { $r = $alea.Next(6) }
        if ($r -le 2) {
            $q = if ($alea.Next(4) -eq 0) { "'" } else { '"' }
            $t = -join @(for ($k = 0; $k -lt $alea.Next(8); $k++) { $lettres[$alea.Next($lettres.Count)] })
            if ($alea.Next(3) -eq 0) { $t = -join @(for ($k = 0; $k -lt 12; $k++) { $hexa[$alea.Next($hexa.Length)] }) }
            return "$q$t$q"
        }
        if ($r -eq 3) { return $nombres[$alea.Next($nombres.Count)] }
        if ($r -eq 4) { return @('true', 'false', 'null', 'True', 'undefined')[$alea.Next(5)] }
        if ($r -eq 5) { return '"\/Date(' + $alea.Next(2000000000) + '000)\/"' }
        $n = $alea.Next(4)
        if ($r -le 8) {
            $champs = @(for ($k = 0; $k -lt $n; $k++) { $cles[$alea.Next($cles.Count)] + ':' + (Get-Valeur ($Prof + 1)) })
            return '{' + ($champs -join ',') + '}'
        }
        '[' + (@(for ($k = 0; $k -lt $n; $k++) { Get-Valeur ($Prof + 1) }) -join ',') + ']'
    }
    $jamais = New-Liste
    for ($i = 0; $i -lt 300; $i++) {
        $champs = @(@('"titre":' + (Get-Valeur 1), '"texte":' + (Get-Valeur 1), '"id":' + (Get-Valeur 1)) | Where-Object { $alea.Next(4) -ne 0 })
        $t = if ($alea.Next(6) -eq 0) { Get-Valeur 0 } else { '{' + ($champs -join ',') + '}' }
        if ($alea.Next(8) -eq 0) { $t = $t.Insert($alea.Next($t.Length + 1), @(',', ':', '}', '"', ' ', "`n")[$alea.Next(6)]) }
        if ($alea.Next(10) -eq 0 -and $t.Length -gt 1) { $t = $t.Remove($alea.Next($t.Length), 1) }
        $deux = Get-Valeur 0
        [void]$jamais.Add((C "jamais vu json $i : $t" '{}' $true @((P 'notifications' @{ fichiers = @((N 'nevermind' (B $t)), (N 'evermind' (B $deux))) }), (P 'bulle-clic')) -Visible ($alea.Next(2) -eq 0) -Applis @($nevermind, $evermind)))
    }
    for ($i = 0; $i -lt 120; $i++) {
        $f = @('', '"Fermeture":"reduire"', '"Fermeture":"QUITTER"', '"Fermeture":"demander"', '"Fermeture":["reduire"]', '"Fermeture":0')[$alea.Next(6)]
        $r = @('', '"ReduireHorloge":false', '"ReduireHorloge":"0"', '"ReduireHorloge":[]')[$alea.Next(4)]
        $b = @('', '"BulleHorlogeVue":true', '"BulleHorlogeVue":0')[$alea.Next(3)]
        $reg = '{' + ((@($f, $r, $b) | Where-Object { $_ }) -join ',') + '}'
        $applis = @(@($nevermind, $evermind, $mindcare, $cafe) | Where-Object { $alea.Next(2) -eq 0 })
        $inst = [pscustomobject]@{}
        foreach ($a in $applis) { if ($alea.Next(3) -ne 0) { $inst | Add-Member -NotePropertyName $a.id -NotePropertyValue ([pscustomobject]@{ gere = ($alea.Next(2) -eq 0) }) } }
        $icone = $alea.Next(6) -ne 0
        $pas = New-Liste
        $nb = 3 + $alea.Next(9)
        for ($k = 0; $k -lt $nb; $k++) {
            $g = if ($icone) { @('croix', 'bouton', 'bouton', 'reduire', 'clic', 'menu', 'menu-choix', 'notifications', 'bulle-clic', 'bulle-fermee', 'bulle', 'erreur', 'afficher', 'veille', 'reglage')[$alea.Next(15)] } else { @('croix', 'reduire', 'clic', 'erreur', 'afficher', 'veille', 'bouton')[$alea.Next(7)] }
            if ($g -eq 'bouton') { [void]$pas.Add((P 'bouton' @{ choix = @('reduire', 'quitter', 'annuler')[$alea.Next(3)]; souvenir = ($alea.Next(2) -eq 0) })) }
            elseif ($g -eq 'menu-choix') { [void]$pas.Add((P 'menu-choix' @{ n = $alea.Next(2 + @($applis | Where-Object { $inst.PSObject.Properties[$_.id] }).Count) })) }
            elseif ($g -eq 'notifications') {
                $fs = New-Liste
                foreach ($a in $applis) { if ($alea.Next(2) -eq 0) { [void]$fs.Add((N $a.id (B (Get-Valeur 0)))) } }
                [void]$pas.Add((P 'notifications' @{ fichiers = $fs }))
            }
            elseif ($g -eq 'bulle') { [void]$pas.Add((P 'bulle' @{ duree = 1000 * (1 + $alea.Next(9)); titre = @('Mise à jour', '', 'Forêt « 2 »')[$alea.Next(3)]; texte = @('Prêt.', ' ', 'Deux mots')[$alea.Next(3)]; icone = @('info', 'attention', 'aucune')[$alea.Next(3)] })) }
            elseif ($g -eq 'reglage') { [void]$pas.Add((P 'reglage' @{ nom = @('Fermeture', 'ReduireHorloge', 'BulleHorlogeVue')[$alea.Next(3)]; valeur_json = @('"reduire"', '"Quitter"', '"x"', 'true', 'false', '[]', '1')[$alea.Next(7)] })) }
            else { [void]$pas.Add((P $g)) }
        }
        [void]$jamais.Add((C "jamais vu gestes $i" $reg $icone $pas -Visible ($alea.Next(4) -ne 0) -Minimisee ($alea.Next(5) -eq 0) -Derniere (@($null, 1, 15, 99)[$alea.Next(4)]) -Applis $applis -Installations $inst))
    }
    $cas = New-Liste
    foreach ($c in $jamais) { [void]$cas.Add((Invoke-Cas $c)) }
    $json = ConvertTo-Json -InputObject ([ordered]@{ source = "Mindset/fichiers/modules/zone.ps1 (2.18.0), grain $Grain"; cas = $cas }) -Depth 30 -Compress
    [IO.File]::WriteAllText((Join-Path $sortie "jamais-vus-$Grain.json"), $json, (New-Object Text.UTF8Encoding $false))
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "jamais-vus-$Grain.json : $($cas.Count) cas"
    return
}

# ---------------------------------------------------------------------------------------------------------------
# Les cas écrits à la main
# ---------------------------------------------------------------------------------------------------------------
$fermeture = New-Liste
$valeursFermeture = [ordered]@{
    'absent' = '{}'; 'demander' = '{"Fermeture":"demander"}'; 'reduire' = '{"Fermeture":"reduire"}'; 'quitter' = '{"Fermeture":"quitter"}'
    'majuscules' = '{"Fermeture":"REDUIRE"}'; 'Quitter-majuscule' = '{"Fermeture":"Quitter"}'; 'espace' = '{"Fermeture":" reduire"}'; 'vide' = '{"Fermeture":""}'
    'null' = '{"Fermeture":null}'; 'nombre' = '{"Fermeture":1}'; 'vrai' = '{"Fermeture":true}'; 'tableau' = '{"Fermeture":["reduire"]}'
    'tableau2' = '{"Fermeture":["quitter","x"]}'; 'objet' = '{"Fermeture":{"a":1}}'; 'accent' = '{"Fermeture":"réduire"}'
}
$suites = [ordered]@{
    'croix' = @((P 'croix'))
    'croix-reduire' = @((P 'croix'), (P 'bouton' @{ choix = 'reduire'; souvenir = $false }))
    'croix-reduire-souvenir' = @((P 'croix'), (P 'bouton' @{ choix = 'reduire'; souvenir = $true }), (P 'clic'), (P 'croix'))
    'croix-quitter' = @((P 'croix'), (P 'bouton' @{ choix = 'quitter'; souvenir = $false }))
    'croix-quitter-souvenir' = @((P 'croix'), (P 'bouton' @{ choix = 'quitter'; souvenir = $true }))
    'croix-annuler' = @((P 'croix'), (P 'bouton' @{ choix = 'annuler'; souvenir = $true }), (P 'croix'), (P 'croix'))
}
foreach ($v in $valeursFermeture.Keys) {
    foreach ($s in $suites.Keys) {
        foreach ($icone in @($true, $false)) {
            [void]$fermeture.Add((C "fermeture $v, $s$(if (-not $icone) { ', sans icône' })" $valeursFermeture[$v] $icone $suites[$s]))
        }
    }
}
# La croix sur une fenêtre réduite (clic droit sur Mindset dans la barre des tâches, « Fermer la fenêtre »)
foreach ($v in @('absent', 'reduire', 'quitter')) {
    [void]$fermeture.Add((C "croix sur la fenêtre réduite, $v" $valeursFermeture[$v] $true @((P 'croix'), (P 'bouton' @{ choix = 'reduire'; souvenir = $false }), (P 'clic')) -Minimisee $true))
    [void]$fermeture.Add((C "croix sur la fenêtre réduite puis Annuler, $v" $valeursFermeture[$v] $true @((P 'croix'), (P 'bouton' @{ choix = 'annuler'; souvenir = $false })) -Minimisee $true))
}
# Le réglage changé entre deux croix (Paramètres)
[void]$fermeture.Add((C 'réglage changé dans Paramètres' '{}' $true @((P 'croix'), (P 'bouton' @{ choix = 'annuler'; souvenir = $false }), (P 'reglage' @{ nom = 'Fermeture'; valeur_json = '"reduire"' }), (P 'croix'), (P 'clic'), (P 'reglage' @{ nom = 'Fermeture'; valeur_json = '"quitter"' }), (P 'croix'))))

# La réduction et la bulle « Mindset reste ici » (la première fois)
$reduction = New-Liste
$valeursReduire = [ordered]@{
    'absent' = '{}'; 'vrai' = '{"ReduireHorloge":true}'; 'faux' = '{"ReduireHorloge":false}'; 'texte-false' = '{"ReduireHorloge":"false"}'
    'zero' = '{"ReduireHorloge":0}'; 'un' = '{"ReduireHorloge":1}'; 'vide' = '{"ReduireHorloge":""}'; 'null' = '{"ReduireHorloge":null}'
    'tableau-vide' = '{"ReduireHorloge":[]}'; 'tableau-faux' = '{"ReduireHorloge":[false]}'; 'tableau-vrai' = '{"ReduireHorloge":[true]}'
}
$valeursBulle = [ordered]@{ 'absente' = ''; 'faux' = ',"BulleHorlogeVue":false'; 'vrai' = ',"BulleHorlogeVue":true'; 'texte' = ',"BulleHorlogeVue":"x"'; 'zero' = ',"BulleHorlogeVue":0' }
foreach ($v in $valeursReduire.Keys) {
    foreach ($icone in @($true, $false)) {
        [void]$reduction.Add((C "réduire, ReduireHorloge $v$(if (-not $icone) { ', sans icône' })" $valeursReduire[$v] $icone @((P 'reduire'), (P 'clic'), (P 'reduire'), (P 'afficher'))))
    }
}
foreach ($b in $valeursBulle.Keys) {
    foreach ($icone in @($true, $false)) {
        $r = '{"Fermeture":"reduire"' + $valeursBulle[$b] + '}'
        [void]$reduction.Add((C "bulle de la première fois, BulleHorlogeVue $b$(if (-not $icone) { ', sans icône' })" $r $icone @((P 'croix'), (P 'clic'), (P 'croix'), (P 'veille'), (P 'afficher'), (P 'reduire'))))
    }
}
[void]$reduction.Add((C 'la console met Mindset en veille' '{}' $true @((P 'veille'), (P 'clic'), (P 'veille'))))
[void]$reduction.Add((C 'réduire avec la question ouverte' '{}' $true @((P 'croix'), (P 'reduire'), (P 'clic'), (P 'bouton' @{ choix = 'quitter'; souvenir = $false }))))

# Rouvrir : la recherche des nouvelles versions si la dernière date d'au moins 15 minutes (Mindset caché seulement)
$rouvrir = New-Liste
foreach ($d in @($null, 0, 5, 14, 15, 16, 60, 600)) {
    foreach ($vis in @($true, $false)) {
        $n = "rouvrir, dernière recherche $(if ($null -eq $d) { 'jamais' } else { "il y a $d min" }), $(if ($vis) { 'montrée' } else { 'cachée' })"
        [void]$rouvrir.Add((C $n '{}' $true @((P 'clic')) -Visible $vis -Derniere $d))
        [void]$rouvrir.Add((C "$n (autre lancement)" '{}' $true @((P 'afficher'), (P 'afficher')) -Visible $vis -Derniere $d))
        [void]$rouvrir.Add((C "$n (menu)" '{}' $true @((P 'menu-choix' @{ n = 0 })) -Visible $vis -Derniere $d))
    }
}
[void]$rouvrir.Add((C 'rouvrir une fenêtre cachée et réduite' '{}' $true @((P 'clic'), (P 'reduire')) -Visible $false -Minimisee $true))

# Le menu de l'icône
$menus = New-Liste
$listes = @(
    @{ n = 'aucune appli'; a = @(); i = $null },
    @{ n = 'aucune installée'; a = @($nevermind, $evermind); i = $null },
    @{ n = 'une installée'; a = @($nevermind, $evermind, $mindcare); i = [pscustomobject]@{ evermind = [pscustomobject]@{ gere = $true } } },
    @{ n = 'toutes installées'; a = @($nevermind, $evermind, $mindcare, $cafe); i = [pscustomobject]@{ nevermind = [pscustomobject]@{ gere = $true }; evermind = [pscustomobject]@{ gere = $false }; mindcare = [pscustomobject]@{ gere = $true }; 'cafe-creme' = [pscustomobject]@{ gere = $true } } },
    @{ n = 'installée hors de la liste'; a = @($mindcare); i = [pscustomobject]@{ nevermind = [pscustomobject]@{ gere = $true } } }
)
foreach ($l in $listes) {
    $pas = New-Liste
    [void]$pas.Add((P 'menu'))
    $nb = 1 + @($l.a | Where-Object { $l.i -and $l.i.PSObject.Properties[$_.id] }).Count + 1
    for ($k = 0; $k -lt $nb; $k++) { [void]$pas.Add((P 'menu-choix' @{ n = $k })) }
    [void]$menus.Add((C "menu, $($l.n)" '{}' $true $pas -Visible $false -Applis $l.a -Installations $l.i))
}

# Les notifications des applis
$notifs = New-Liste
$long = 'a' * 70
$bon = '{"titre":"Partie finie","texte":"Ton résumé est prêt.","id":"0123456789ab"}'
$contenus = [ordered]@{
    'bonne' = (B $bon)
    'sans titre' = (B '{"texte":"Rien","id":"0123456789ab"}')
    'titre vide' = (B '{"titre":"","texte":"x"}')
    'titre de 62' = (B ('{"titre":"' + ('é' * 62) + '"}'))
    'titre de 63' = (B ('{"titre":"' + ('é' * 63) + '"}'))
    'titre de 64' = (B ('{"titre":"' + ('é' * 64) + '"}'))
    'titre long' = (B ('{"titre":"' + $long + '"}'))
    'émoji coupé' = (B ('{"titre":"' + ('a' * 61) + '😀😀"}'))
    'texte de 250' = (B ('{"texte":"' + ('b' * 250) + '"}'))
    'texte de 251' = (B ('{"texte":"' + ('b' * 251) + '"}'))
    'texte long' = (B ('{"texte":"' + ('b' * 400) + '"}'))
    'texte émoji coupé' = (B ('{"texte":"' + ('b' * 248) + '😀😀"}'))
    'texte vide' = (B '{"titre":"T","texte":""}')
    'id majuscules' = (B '{"titre":"T","id":"0123456789AB"}')
    'id court' = (B '{"titre":"T","id":"0123456789a"}')
    'id long' = (B '{"titre":"T","id":"0123456789abc"}')
    'id retour à la ligne' = (B '{"titre":"T","id":"0123456789ab\n"}')
    'id deux retours' = (B '{"titre":"T","id":"0123456789ab\n\n"}')
    'id espace' = (B '{"titre":"T","id":"0123456789ab "}')
    'id nombre' = (B '{"titre":"T","id":123456789012}')
    'id pas hexa' = (B '{"titre":"T","id":"0123456789ag"}')
    'id tableau' = (B '{"titre":"T","id":["0123456789ab"]}')
    'Titre en majuscule' = (B '{"Titre":"Grand","TEXTE":"Petit","Id":"0123456789ab"}')
    'deux titres' = (B '{"titre":"a","Titre":"b"}')
    'titre nombre' = (B '{"titre":12,"texte":1.5}')
    'titre nombre à virgule' = (B '{"titre":1.0,"texte":1e3}')
    'titre vrai' = (B '{"titre":true,"texte":false}')
    'titre tableau' = (B '{"titre":["a","b"],"texte":[1,2]}')
    'titre objet' = (B '{"titre":{"a":1},"texte":null}')
    'abîmé' = (B '{"titre":"T",')
    'vide' = (B '')
    'espaces' = (B '   ')
    'null' = (B 'null')
    'faux' = (B 'false')
    'zéro' = (B '0')
    'texte seul' = (B '"bonjour"')
    'tableau vide' = (B '[]')
    'tableau' = (B '[{"titre":"Dans un tableau","id":"0123456789ab"}]')
    'deux objets' = (B '[{"titre":"a"},{"titre":"b"}]')
    'objet vide' = (B '{}')
    'guillemets simples' = (B "{'titre':'Simple'}")
    'clés sans guillemets' = (B '{titre:"Nu"}')
    'suite après' = (B '{"titre":"a"} x')
    'avec BOM' = (BO ([byte[]](0xEF, 0xBB, 0xBF) + (New-Object Text.UTF8Encoding $false).GetBytes($bon)))
    'UTF-16' = (BO ([byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($bon)))
    'octets invalides' = (BO ([byte[]](0x7B, 0x22, 0x74, 0x69, 0x74, 0x72, 0x65, 0x22, 0x3A, 0x22, 0xC3, 0x28, 0x22, 0x7D)))
    '8191 octets' = (B ('{"titre":"T","texte":"' + ('c' * (8191 - 24)) + '"}'))
    '8192 octets' = (B ('{"titre":"T","texte":"' + ('c' * (8192 - 24)) + '"}'))
    'échappements' = (B '{"titre":"Tab\tet \u00e9","texte":"ligne\nautre","id":"abcdef012345"}')
    'virgule finale' = (B '{"titre":"V",}')
    'virgule finale tableau' = (B '{"titre":["a","b",]}')
    'commentaire' = (B '{"titre":"C" /* note */}')
    'commentaire ligne' = (B "{`"titre`":`"C`" // note`n}")
    'zéro devant' = (B '{"titre":01}')
    'point devant' = (B '{"titre":.5}')
    'plus devant' = (B '{"titre":+1}')
    'moins' = (B '{"titre":-12.50}')
    'exposant' = (B '{"titre":1.5e2,"texte":2E-3}')
    'exposant négatif long' = (B '{"titre":1.0e1,"texte":123.456e-1}')
    'grand entier' = (B '{"titre":12345678901234567890,"texte":-2147483649}')
    'très grand' = (B '{"titre":1e30,"texte":123456789012345678901234567890}')
    'NaN' = (B '{"titre":NaN}')
    'vrai majuscule' = (B '{"titre":True}')
    'null majuscule' = (B '{"titre":Null}')
    'retour dans le texte' = (B "{`"titre`":`"a`nb`"}")
    'tab dans le texte' = (B "{`"titre`":`"a`tb`"}")
    'échappement inconnu' = (B '{"titre":"a\qb"}')
    'échappement x' = (B '{"titre":"\x41"}')
    'unicode court' = (B '{"titre":"\u41"}')
    'barre oblique' = (B '{"titre":"a\/b"}')
    'simples avec doubles' = (B "{'titre':'a`"b'}")
    'clé nombre' = (B '{1:"x","titre":"t"}')
    'clé vide' = (B '{"":"x","titre":"t"}')
    'espaces partout' = (B " `r`n`t{ `"titre`" : `"E`" } `r`n")
    'deux points en trop' = (B '{"titre"::"x"}')
    'sans virgule' = (B '{"titre":"a" "texte":"b"}')
    'imbriqué' = (B '{"titre":{"a":[1,{"b":2}],"c":"d"},"texte":[[1,2],[3]]}')
    'titre tableau vide' = (B '{"titre":[],"texte":[null]}')
    'titre tableau d''objets' = (B '{"titre":[{"a":1},{"b":true}]}')
    'objet avec null' = (B '{"titre":{"a":null,"b":false,"c":1.50}}')
    'objet dans objet' = (B '{"titre":{"a":{"b":2},"c":[true]}}')
    'même clé deux fois' = (B '{"titre":"a","titre":"b"}')
    'mot nu' = (B '{"titre":abc}')
    'Infinity' = (B '{"titre":Infinity,"texte":-Infinity}')
    'undefined' = (B '{"titre":undefined}')
    'date' = (B '{"titre":"\/Date(0)\/"}')
    'booléens en tableau' = (B '{"titre":[true,false,null,1.0]}')
    'tableau de tableau' = (B '[[{"titre":"Profond"}]]')
    'clé échappée' = (B '{"\u0074itre":"Echappée"}')
    'hexadécimal' = (B '{"titre":0x10}')
    'point final' = (B '{"titre":1.}')
    'moins zéro' = (B '{"titre":-0,"texte":-0.0}')
    'exposant seul' = (B '{"titre":1e}')
    'moins seul' = (B '{"titre":-}')
    'exposant plus' = (B '{"titre":1.5E+2}')
    'beaucoup de décimales' = (B '{"titre":0.123456789012345678901234567890123}')
    'petit nombre' = (B '{"titre":1e-30}')
    'tableau en titre dans tableau' = (B '[{"titre":["a","b"]},{"titre":"c"}]')
    'objets sans titre en tableau' = (B '[{"texte":"x"},{"texte":"y"}]')
    'tableau de textes' = (B '["a","b"]')
    'tableau avec un nombre' = (B '[5]')
    'tableau avec zéro' = (B '[0]')
    'clé simple valeur double' = (B "{'titre':`"Mixte`",texte:'deux'}")
    'trop grand' = (B '{"titre":"T","texte":1e400}')
    'trop petit' = (B '{"titre":1e-400}')
    'tableau dans tableau vide' = (B '[[]]')
    'tableau de faux' = (B '[[false]]')
    'tableau de tableau vide et objet' = (B '[[],{"titre":"x"}]')
    'objet vide en tableau' = (B '[{}]')
    'titre objet vide' = (B '{"titre":{},"texte":[{}]}')
    'objet vide dans objet' = (B '{"titre":{"a":{}}}')
}
foreach ($k in $contenus.Keys) {
    foreach ($icone in @($true, $false)) {
        [void]$notifs.Add((C "notification $k$(if (-not $icone) { ', sans icône' })" '{}' $icone @((P 'notifications' @{ fichiers = @((N 'nevermind' $contenus[$k])) }), (P 'bulle-clic'), (P 'bulle-clic')) -Visible $false -Applis @($nevermind, $evermind)))
    }
}
$deux = @((N 'nevermind' (B '{"titre":"Un","id":"aaaaaaaaaaaa"}')), (N 'evermind' (B '{"titre":"Deux","id":"bbbbbbbbbbbb"}')))
[void]$notifs.Add((C 'deux notifications d''un coup' '{}' $true @((P 'notifications' @{ fichiers = $deux }), (P 'bulle-clic')) -Applis @($nevermind, $evermind)))
[void]$notifs.Add((C 'bulle fermée avant le clic' '{}' $true @((P 'notifications' @{ fichiers = @((N 'nevermind' (B $bon))) }), (P 'bulle-fermee'), (P 'bulle-clic')) -Applis @($nevermind)))
[void]$notifs.Add((C 'bulle de Mindset après celle d''une appli' '{}' $true @((P 'notifications' @{ fichiers = @((N 'nevermind' (B $bon))) }), (P 'bulle' @{ duree = 6000; titre = 'Mise à jour'; texte = 'Evermind 1.2.0 est installé.'; icone = 'info' }), (P 'bulle-clic')) -Applis @($nevermind)))
[void]$notifs.Add((C 'appli sans fichier d''affichage' '{}' $true @((P 'notifications' @{ fichiers = @((N 'mindcare' (B $bon))) }), (P 'bulle-clic')) -Applis @($mindcare)))
[void]$notifs.Add((C 'appli gérée : dossier de la suite' '{}' $true @((P 'notifications' @{ fichiers = @((N 'nevermind' (B $bon) 'suite'), (N 'nevermind' (B '{"titre":"Ancien"}') 'donnees')) }), (P 'bulle-clic')) -Applis @($nevermind) -Installations ([pscustomobject]@{ nevermind = [pscustomobject]@{ gere = $true } }) -Suite @('Nevermind')))
[void]$notifs.Add((C 'appli gérée sans dossier de la suite' '{}' $true @((P 'notifications' @{ fichiers = @((N 'nevermind' (B $bon) 'donnees')) }), (P 'bulle-clic')) -Applis @($nevermind) -Installations ([pscustomobject]@{ nevermind = [pscustomobject]@{ gere = $true } })))
[void]$notifs.Add((C 'appli pas gérée : ancien dossier' '{}' $true @((P 'notifications' @{ fichiers = @((N 'nevermind' (B $bon) 'suite'), (N 'nevermind' (B '{"titre":"Ancien","id":"cccccccccccc"}') 'donnees')) }), (P 'bulle-clic')) -Applis @($nevermind) -Installations ([pscustomobject]@{ nevermind = [pscustomobject]@{ gere = $false } }) -Suite @('Nevermind')))
[void]$notifs.Add((C 'nom avec accents et &' '{}' $true @((P 'notifications' @{ fichiers = @((N 'cafe-creme' (B '{"texte":"Prêt","id":"dddddddddddd"}'))) }), (P 'bulle-clic'), (P 'menu')) -Applis @($cafe) -Installations ([pscustomobject]@{ 'cafe-creme' = [pscustomobject]@{ gere = $false } })))
[void]$notifs.Add((C 'dossier des données absent' '{}' $true @((P 'notifications'), (P 'bulle-clic')) -Applis @($sansDossier)))
[void]$notifs.Add((C 'pas de notification' '{}' $true @((P 'notifications'), (P 'bulle-clic')) -Applis @($nevermind, $evermind)))

# Les bulles de Mindset et le message d'erreur imprévue
$bulles = New-Liste
foreach ($icone in @($true, $false)) {
    $s = if ($icone) { '' } else { ', sans icône' }
    [void]$bulles.Add((C "erreur imprévue$s" '{}' $icone @((P 'erreur'), (P 'bulle-clic'))))
    [void]$bulles.Add((C "erreur imprévue, Mindset caché$s" '{}' $icone @((P 'erreur')) -Visible $false))
    foreach ($ic in @('info', 'attention', 'aucune')) {
        [void]$bulles.Add((C "bulle $ic$s" '{}' $icone @((P 'bulle' @{ duree = 4000; titre = 'Titre « ici »'; texte = 'Un texte, avec des accents : éàç.'; icone = $ic }))))
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Les cas pris au hasard (jamais écrits à la main) : réglages, gestes et notifications tirés d'un grain fixe
# ---------------------------------------------------------------------------------------------------------------
$hasard = New-Liste
$alea = New-Object System.Random 20261107
function Tirer($Liste) { $Liste[$alea.Next($Liste.Count)] }
$poolF = @($valeursFermeture.Values | ForEach-Object { $_.Substring(1, $_.Length - 2) })
$poolR = @('', ',"ReduireHorloge":true', ',"ReduireHorloge":false', ',"ReduireHorloge":0', ',"ReduireHorloge":"non"')
$poolB = @($valeursBulle.Values)
$poolN = @($contenus.Values)
$poolApplis = @($nevermind, $evermind, $mindcare, $cafe)
for ($i = 0; $i -lt 160; $i++) {
    $morceaux = @((Tirer $poolF), (Tirer $poolR).TrimStart(","), (Tirer $poolB).TrimStart(",")) | Where-Object { $_ }
    $reg = "{" + ($morceaux -join ",") + "}"
    $applis = @($poolApplis | Where-Object { $alea.Next(2) -eq 0 })
    $inst = [pscustomobject]@{}
    foreach ($a in $applis) { if ($alea.Next(2) -eq 0) { $inst | Add-Member -NotePropertyName $a.id -NotePropertyValue ([pscustomobject]@{ gere = ($alea.Next(2) -eq 0) }) } }
    $suite = @($applis | Where-Object { $alea.Next(2) -eq 0 } | ForEach-Object { $_.nom })
    $pas = New-Liste
    $n = 3 + $alea.Next(8)
    for ($k = 0; $k -lt $n; $k++) {
        $g = Tirer @('croix', 'croix', 'bouton', 'bouton', 'reduire', 'clic', 'menu', 'menu-choix', 'notifications', 'bulle-clic', 'bulle-fermee', 'bulle', 'erreur', 'afficher', 'veille', 'reglage')
        switch ($g) {
            'bouton' { [void]$pas.Add((P 'bouton' @{ choix = (Tirer @('reduire', 'quitter', 'annuler')); souvenir = ($alea.Next(2) -eq 0) })) }
            'menu-choix' {
                $nb = 2 + @($applis | Where-Object { $inst.PSObject.Properties[$_.id] }).Count
                [void]$pas.Add((P 'menu-choix' @{ n = $alea.Next($nb) }))
            }
            'notifications' {
                $fs = New-Liste
                foreach ($a in $applis) {
                    if ($alea.Next(3) -eq 0) { continue }
                    $ou = if ($suite -contains $a.nom -and $alea.Next(2) -eq 0) { 'suite' } else { 'donnees' }
                    [void]$fs.Add((N $a.id (Tirer $poolN) $ou))
                }
                [void]$pas.Add((P 'notifications' @{ fichiers = $fs }))
            }
            'bulle' { [void]$pas.Add((P 'bulle' @{ duree = (Tirer @(3000, 6000, 8000)); titre = (Tirer @('Mise à jour', 'Forêt', '')); texte = (Tirer @('Fini.', 'Un texte un peu plus long.', ' ')); icone = (Tirer @('info', 'attention', 'aucune')) })) }
            'reglage' { [void]$pas.Add((P 'reglage' @{ nom = (Tirer @('Fermeture', 'ReduireHorloge', 'BulleHorlogeVue')); valeur_json = (Tirer @('"reduire"', '"quitter"', '"demander"', 'true', 'false', 'null', '0')) })) }
            default { [void]$pas.Add((P $g)) }
        }
    }
    # (le menu n'existe qu'avec l'icône : les cas sans icône n'ont pas de menu)
    $icone = $alea.Next(5) -ne 0
    if (-not $icone) { $pas = New-Liste }
    if (-not $icone) {
        $n = 2 + $alea.Next(5)
        for ($k = 0; $k -lt $n; $k++) { [void]$pas.Add((P (Tirer @('croix', 'reduire', 'clic', 'erreur', 'afficher', 'veille')))) }
    }
    $derniere = Tirer @($null, 3, 20, 400)
    [void]$hasard.Add((C "hasard $i" $reg $icone $pas -Visible ($alea.Next(4) -ne 0) -Minimisee ($alea.Next(6) -eq 0) -Derniere $derniere -Applis $applis -Installations $inst -Suite $suite))
}

# ---------------------------------------------------------------------------------------------------------------
# Écriture
# ---------------------------------------------------------------------------------------------------------------
$utf8 = New-Object Text.UTF8Encoding $false
$total = 0
$tous = [ordered]@{ fermeture = $fermeture; reduction = $reduction; rouvrir = $rouvrir; menu = $menus; notifications = $notifs; bulles = $bulles; hasard = $hasard }
foreach ($fichier in $tous.GetEnumerator()) {
    $cas = New-Liste
    foreach ($c in $fichier.Value) { [void]$cas.Add((Invoke-Cas $c)) }
    $json = ConvertTo-Json -InputObject ([ordered]@{ source = 'Mindset/fichiers/modules/zone.ps1 (2.18.0)'; cas = $cas }) -Depth 30 -Compress
    [IO.File]::WriteAllText((Join-Path $sortie "$($fichier.Key).json"), $json, $utf8)
    $total += $cas.Count
    Write-Host "$($fichier.Key).json : $($cas.Count) cas"
}
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Juges écrits : $total cas dans $sortie"
