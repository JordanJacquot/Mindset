# Mindset : juges du bloc Rust « accrochage » (rust\mindset-accrochage).
#
#   & '.\outils\exporter-juges-accrochage.ps1'      (depuis l'outil PowerShell, appelé directement)
#
# Rejoue des scénarios inventés (des applis installées, des programmes qui démarrent, des fenêtres qui apparaissent, se
# cachent ou disparaissent, des clics, le temps qui passe) sur les VRAIES fonctions PowerShell de l'accrochage, et écrit
# ce qu'elles décident à chaque pas dans rust\mindset-accrochage\tests\juges\accrochage.json, que les tests Rust
# rejouent (tests\juges.rs) :
#   - integration.ps1 : Find-FenetreAppli, Start-AppliCachee, Stop-AppliBloquee, Show-AppliIntegree, Connect-Fenetre,
#     Set-EtatPageAppli, Update-HotesVisibles, Update-BarreAppli, Test-NouveauProcessus, Open-AppliIci,
#     Disconnect-Applis, la surveillance de 400 ms (Add_Tick), les clics BtnPageAppliIci et BtnAppliFermer ;
#   - chargement.ps1 : Show-JaugeAppli, Stop-JaugeAppli, Save-DureeOuverture, Show-EcranOuvrir, les durées par défaut ;
#   - applis.ps1 : Test-AppliAdmin ; paquets.ps1 : Test-VersionPlusRecente ; console.ps1 : Stop-AppliConsole.
# Les fonctions sont prises telles quelles dans leur fichier (lecture de leur texte). Ce qui touche Windows ou l'écran
# est remplacé par des faux : MSIntegration (des fenêtres inventées), les programmes (Get-ProcessusAppli,
# Test-AppliOuverte), le panneau Windows Forms (Get-Integration), les éléments de l'écran ($ui), l'heure (Get-Date),
# Open-Appli, Write-Log, les réglages. Show-Page est réduit à ce qui concerne l'accrochage (accueil.ps1:84-107).
#
# Rien n'est lancé, aucune fenêtre n'est créée ni touchée, rien n'est écrit ailleurs que dans le fichier des juges.

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$modules = Join-Path $racine 'Mindset\fichiers\modules'
$sortie = Join-Path $racine 'rust\mindset-accrochage\tests\juges\accrochage.json'

# ---------------------------------------------------------------------------------------------------------------
# Les vraies fonctions, prises dans leur fichier
# ---------------------------------------------------------------------------------------------------------------
function Get-Ast([string]$Fichier) {
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Fichier, [ref]$null, [ref]$err)
    if ($err) { throw "Fichier illisible pour PowerShell : $Fichier" }
    $ast
}
function Get-TexteFonction($Ast, [string]$Nom) {
    $f = $Ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Nom }, $true)
    if (-not $f) { throw "Fonction $Nom introuvable" }
    $f.Extent.Text
}
# Le bloc passé à <objet>.<Membre>(...) (Add_Tick, Add_Click), en fonction
function Get-TexteGestionnaire($Ast, [string]$Objet, [string]$Membre, [string]$Nom) {
    $m = $Ast.Find({ param($a) $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $a.Expression.Extent.Text -eq $Objet -and $a.Member.Extent.Text -eq $Membre }, $true)
    if (-not $m) { throw "$Objet.$Membre introuvable" }
    "function $Nom " + $m.Arguments[0].ScriptBlock.Extent.Text
}
$astIntegration = Get-Ast (Join-Path $modules 'integration.ps1')
$astChargement = Get-Ast (Join-Path $modules 'chargement.ps1')
$astApplis = Get-Ast (Join-Path $modules 'applis.ps1')
$astPaquets = Get-Ast (Join-Path $modules 'paquets.ps1')
$astConsole = Get-Ast (Join-Path $modules 'console.ps1')

$textes = @()
foreach ($n in 'Find-FenetreAppli', 'Start-AppliCachee', 'Stop-AppliBloquee', 'Show-AppliIntegree', 'Connect-Fenetre', 'Set-EtatPageAppli',
    'Update-HotesVisibles', 'Update-BarreAppli', 'Test-NouveauProcessus', 'Open-AppliIci', 'Disconnect-Applis') { $textes += Get-TexteFonction $astIntegration $n }
$textes += Get-TexteGestionnaire $astIntegration '$script:IntegrationTimer' 'Add_Tick' 'Invoke-Surveillance'
$textes += Get-TexteGestionnaire $astIntegration '$ui.BtnAppliFermer' 'Add_Click' 'Invoke-ClicFermer'
$textes += (Get-TexteGestionnaire $astIntegration '$ui.BtnPageAppliIci' 'Add_Click' 'Invoke-ClicIci').Replace('$this.Tag', '$ui.BtnPageAppliIci.Tag')
foreach ($n in 'Show-JaugeAppli', 'Stop-JaugeAppli', 'Save-DureeOuverture', 'Show-EcranOuvrir') { $textes += Get-TexteFonction $astChargement $n }
$textes += Get-TexteFonction $astApplis 'Test-AppliAdmin'
$textes += Get-TexteFonction $astPaquets 'Test-VersionPlusRecente'
$textes += Get-TexteFonction $astConsole 'Stop-AppliConsole'
$durees = $astChargement.Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$script:JaugeDureesDefaut' }, $false)
if (-not $durees) { throw '$script:JaugeDureesDefaut introuvable' }
$textes += $durees.Extent.Text
foreach ($t in $textes) { . ([scriptblock]::Create($t)) }

# ---------------------------------------------------------------------------------------------------------------
# Les faux
# ---------------------------------------------------------------------------------------------------------------
Add-Type -AssemblyName WindowsBase
if (-not ('MSIntegration' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
// Le faux de MSIntegration (natif.cs:36-137) : des fenêtres inventées, et ce qui leur a été fait. Les mêmes règles que
// le faux du bloc Rust (fenetres.rs, FauxFenetres).
public static class MSIntegration
{
    public class Fen { public int Pid; public string Titre, Classe; public bool Possedee, Visible, Barre, Refus; public long Parent; }
    public static List<long> Ordre = new List<long>();
    public static Dictionary<long, Fen> Fens = new Dictionary<long, Fen>();
    public static List<string> Appels = new List<string>();
    public static void Reset() { Ordre.Clear(); Fens.Clear(); Appels.Clear(); }
    public static void Creer(long h, int pid, string titre, string classe, bool possedee, bool visible)
    {
        Fens[h] = new Fen { Pid = pid, Titre = titre, Classe = classe, Possedee = possedee, Visible = visible };
        Ordre.Remove(h); Ordre.Add(h);
    }
    public static void Detruire(long h) { Fens.Remove(h); Ordre.Remove(h); }
    public static IntPtr Trouver(int pid, string titre)
    {
        foreach (long h in Ordre)
        {
            Fen f = Fens[h];
            if (f.Parent != 0 || f.Pid != pid || f.Possedee) continue;
            if (f.Titre == titre && (f.Classe.StartsWith("HwndWrapper") || f.Classe == "Tauri Window")) return new IntPtr(h);
        }
        return IntPtr.Zero;
    }
    public static int Processus(IntPtr h) { Fen f; return Fens.TryGetValue(h.ToInt64(), out f) ? f.Pid : 0; }
    public static bool IsWindow(IntPtr h) { return Fens.ContainsKey(h.ToInt64()); }
    public static long[] Accrocher(IntPtr fenetre, IntPtr parent, int largeur, int hauteur)
    {
        long h = fenetre.ToInt64();
        Appels.Add("accrocher " + h + " " + largeur + "x" + hauteur);
        Fen f; if (!Fens.TryGetValue(h, out f)) return null;
        if (f.Refus) { f.Refus = false; return null; }
        long[] avant = new long[] { f.Visible ? 0x16CF0000L : 0x06CF0000L, 0x00040100L };
        f.Parent = parent.ToInt64(); f.Visible = true;
        return avant;
    }
    public static void Redimensionner(IntPtr fenetre, int largeur, int hauteur) { Appels.Add("redimensionner " + fenetre.ToInt64() + " " + largeur + "x" + hauteur); }
    public static void Focus(IntPtr fenetre) { Appels.Add("focus " + fenetre.ToInt64()); }
    public static bool BarrePropre(IntPtr fenetre) { Fen f; return fenetre != IntPtr.Zero && Fens.TryGetValue(fenetre.ToInt64(), out f) && f.Barre; }
    public static bool EstMontree(IntPtr fenetre) { Fen f; return Fens.TryGetValue(fenetre.ToInt64(), out f) && f.Visible; }
    public static void Fermer(IntPtr fenetre) { Appels.Add("fermer " + fenetre.ToInt64()); }
    public static void Liberer(IntPtr fenetre, long style, long ex)
    {
        long h = fenetre.ToInt64();
        Appels.Add("liberer " + h);
        Fen f; if (Fens.TryGetValue(h, out f)) { f.Parent = 0; f.Visible = false; }
    }
}
'@
}

function New-Element([hashtable]$P) { [pscustomobject]$P }
function Reset-Ecran {
    $script:ui = @{
        PageAppliHotes = New-Element @{ Children = (New-Object System.Collections.ArrayList) }
        PageAppliTitre = New-Element @{ Text = ''; Foreground = '' }
        PageAppliTexte = New-Element @{ Text = ''; Visibility = 'Collapsed' }
        PageAppliEtat = New-Element @{ Text = '' }
        BtnPageAppliIci = New-Element @{ Visibility = 'Collapsed'; Content = ''; Tag = '' }
        PageAppliJauge = New-Element @{ Children = (New-Object System.Collections.ArrayList); Visibility = 'Collapsed' }
        PageAppliMessage = New-Element @{ Visibility = 'Visible' }
        PageAppliCadre = New-Element @{ Visibility = 'Collapsed' }
        BarreAppli = New-Element @{ Visibility = 'Visible' }
        Confirmation = New-Element @{ Visibility = 'Collapsed' }
        Fermeture = New-Element @{ Visibility = 'Collapsed' }
        PageAppli = New-Element @{ Visibility = 'Collapsed' }
        PageAccueil = New-Element @{ Visibility = 'Visible' }
        PageParametres = New-Element @{ Visibility = 'Collapsed' }
    }
}
$Window = New-Element @{ IsVisible = $true }
$EnTest = $false

function Get-Date { $script:Maintenant }
function Write-Log($Message) { [void]$script:Journal.Add([string]$Message) }
function Write-ErreurImprevue($e) { [void]$script:Journal.Add("ERREUR IMPRÉVUE : $e") }
function Get-Brush([string]$Hex) { $Hex.ToUpperInvariant() }
function Get-JaugePack { $null }
function New-JaugeAnneau { }
function Update-JaugeAppli { }
function Invoke-ScriptConsole { }
function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.Contains($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur }
function Get-Appli([string]$Id) { $script:Applis | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
function Get-Installation($Appli) { $script:Inst[$Appli.Id] }
function Open-Appli($Appli, [switch]$Demarrage) { [void]$script:Lances.Add([ordered]@{ id = $Appli.Id; demarrage = [bool]$Demarrage }) }
function Write-DemandeQuitter($Appli) { [void]$script:Demandes.Add($Appli.Id) }
function Get-ProcessusAppli($Appli, [switch]$Hote) {
    if (-not (Get-Installation $Appli)) { return @() }
    @($script:Processus | Where-Object { $_.Appli -eq $Appli.Id -and (-not $Hote -or $_.Nom -in @($Appli.Exe, 'Mindset.exe')) })
}
function Test-AppliOuverte($Appli) {
    foreach ($nom in @($Appli.Mutex, $Appli.AncienMutex) | Where-Object { $_ }) { if ($script:Verrous.Contains($nom)) { return $true } }
    [bool]@(Get-ProcessusAppli $Appli -Hote).Count
}
# Show-Page (accueil.ps1:84-107), réduit à ce qui touche l'accrochage
function Show-Page([string]$Id) {
    $script:PageCourante = $Id
    $ui.PageAccueil.Visibility = if ($Id -eq 'accueil') { 'Visible' } else { 'Collapsed' }
    $ui.PageParametres.Visibility = if ($Id -eq 'parametres') { 'Visible' } else { 'Collapsed' }
    $ui.PageAppli.Visibility = if ($Id -in @('accueil', 'parametres')) { 'Collapsed' } else { 'Visible' }
    Update-HotesVisibles
    if ($ui.PageAppli.Visibility -eq 'Visible') { Show-AppliIntegree (Get-Appli $Id) }
}

# Le panneau de l'appli (Get-Integration, integration.ps1:18-32) sans Windows Forms : sa taille suit la zone quand il est
# montré (le panneau d'une page repliée n'a pas de taille), et chaque changement redimensionne la fenêtre accrochée
# (son Add_Resize).
function Get-TailleZone {
    if ($ui.PageAppli.Visibility -eq 'Visible' -and $script:Zone.W -gt 0 -and $script:Zone.H -gt 0) { @($script:Zone.W, $script:Zone.H) } else { @(0, 0) }
}
function Update-TaillePanneau($i) {
    $t = Get-TailleZone
    $p = $i.Panneau
    if ($p.ClientSize.Width -eq $t[0] -and $p.ClientSize.Height -eq $t[1]) { return }
    $p.ClientSize = New-Element @{ Width = $t[0]; Height = $t[1] }
    if ($i.Fenetre -ne [IntPtr]::Zero -and $t[0] -gt 0) { [MSIntegration]::Redimensionner($i.Fenetre, $t[0], $t[1]) }
}
function Get-Integration([string]$Id) {
    $i = $script:Integrees[$Id]
    if ($i) { return $i }
    $panneau = New-Element @{ Tag = $Id; Handle = [IntPtr](9000 + $script:Integrees.Count); ClientSize = (New-Element @{ Width = 0; Height = 0 }) }
    $hote = New-Object psobject
    $hote | Add-Member NoteProperty Id $Id
    $hote | Add-Member NoteProperty V 'Collapsed'
    $hote | Add-Member ScriptProperty Visibility { $this.V } { param($v) $this.V = $v; if ($v -eq 'Visible') { Update-TaillePanneau $script:Integrees[$this.Id] } }
    $hote | Add-Member ScriptMethod UpdateLayout { }
    $i = @{ Id = $Id; Hote = $hote; Panneau = $panneau; Fenetre = [IntPtr]::Zero; Styles = $null; Etat = 'vide'; Depuis = Get-Date }
    $script:Integrees[$Id] = $i
    $i
}

# Les applis de la liste (la forme de ConvertTo-Appli)
$toutes = @{
    nevermind = @{ Id = 'nevermind'; Nom = 'Nevermind'; Couleur = '#00E5FF'; Exe = 'Nevermind.exe'; Mutex = 'Local\Nevermind-Instance'; AncienMutex = 'Local\OptiGame-Instance'; Admin = $true; SansDroitsDepuis = '1.0.115'; CacheDepuis = '1.0.105' }
    evermind = @{ Id = 'evermind'; Nom = 'Evermind'; Couleur = '#B04BFF'; Exe = 'Evermind.exe'; Mutex = 'Local\Evermind-Instance'; AncienMutex = ''; Admin = $false; SansDroitsDepuis = ''; CacheDepuis = '0.12.6' }
    mindcare = @{ Id = 'mindcare'; Nom = 'Mindcare'; Couleur = '#FF8A00'; Exe = 'Mindcare.exe'; Mutex = 'Local\Mindcare-Instance'; AncienMutex = ''; Admin = $false; SansDroitsDepuis = ''; CacheDepuis = '0.1.0' }
    'cafe-creme' = @{ Id = 'cafe-creme'; Nom = 'Café crème'; Couleur = '#aa5500'; Exe = 'CafeCreme.exe'; Mutex = 'Local\CafeCreme-Instance'; AncienMutex = ''; Admin = $false; SansDroitsDepuis = ''; CacheDepuis = '' }
}

# ---------------------------------------------------------------------------------------------------------------
# Un scénario : ses pas, et ce que la version PowerShell montre et fait après chacun
# ---------------------------------------------------------------------------------------------------------------
function Get-Instantane {
    $int = [ordered]@{}
    foreach ($k in @($script:Integrees.Keys | Sort-Object)) {
        $i = $script:Integrees[$k]
        $int[$k] = [ordered]@{
            etat = [string]$i.Etat
            fenetre = if ($i.Fenetre -ne [IntPtr]::Zero) { [long]$i.Fenetre } else { $null }
            pid = if ($null -ne $i.Pid) { [int]$i.Pid } else { $null }
            hote = ($i.Hote.Visibility -eq 'Visible')
        }
    }
    $appli = $script:PageCourante -notin @('accueil', 'parametres')
    $cadre = $ui.PageAppliCadre.Visibility -eq 'Visible'
    $ecran = $null
    if ($appli -and -not $cadre) {
        $j = $null
        if ($script:Jauge -and $script:Jauge.Id -eq $script:PageCourante) {
            $j = if ($script:Jauge.Ecran) { [ordered]@{ ecran = $true } } else {
                [ordered]@{ ecran = $false; depuis = [math]::Round(($script:Jauge.Depuis - $script:T0).TotalSeconds, 1); duree = [double]$script:Jauge.Duree }
            }
        }
        $ici = $ui.BtnPageAppliIci.Visibility -eq 'Visible'
        $ecran = [ordered]@{
            titre = [string]$ui.PageAppliTitre.Text
            couleur = [string]$ui.PageAppliTitre.Foreground
            texte = if ($ui.PageAppliTexte.Visibility -eq 'Visible') { [string]$ui.PageAppliTexte.Text } else { '' }
            bouton_ici = $ici
            bouton_texte = if ($ici) { [string]$ui.BtnPageAppliIci.Content } else { '' }
            jauge = $j
        }
    }
    $reg = [ordered]@{}
    foreach ($k in @($script:Reglages.Keys | Where-Object { $_ -like 'Ouverture-*' } | Sort-Object)) { $reg[$k] = $script:Reglages[$k] }
    $r = [ordered]@{
        page = $script:PageCourante
        integrees = $int
        ecran = $ecran
        cadre = if ($appli) { $cadre } else { $null }
        barre = if ($appli) { $ui.BarreAppli.Visibility -eq 'Visible' } else { $null }
        minuterie = [bool]$script:IntegrationTimer.Actif
        journal = @($script:Journal)
        appels = @([MSIntegration]::Appels)
        lances = @($script:Lances)
        arretes = @($script:Arretes)
        demandes = @($script:Demandes)
        reglages = $reg
    }
    $script:Journal.Clear(); [MSIntegration]::Appels.Clear(); $script:Lances.Clear(); $script:Arretes.Clear(); $script:Demandes.Clear()
    $r
}

function Add-Processus($p) {
    $o = New-Object psobject
    $o | Add-Member NoteProperty Id ([int]$p.pid)
    $o | Add-Member NoteProperty Appli ([string]$p.id)
    $o | Add-Member NoteProperty Nom ([string]$p.nom)
    if ($p.illisible) { $o | Add-Member ScriptProperty StartTime { throw 'Accès refusé.' } }
    else { $o | Add-Member NoteProperty StartTime ($script:Maintenant.AddSeconds(-[double]$p.age)) }
    $o | Add-Member ScriptMethod Kill { [void]$script:Arretes.Add($this.Id); $id = $this.Id; $script:Processus = @($script:Processus | Where-Object { $_.Id -ne $id }) }
    $o | Add-Member ScriptMethod WaitForExit { param($ms) $true }
    $script:Processus = @($script:Processus) + $o
}

function Invoke-Pas($p) {
    switch ($p.q) {
        'installer' { $script:Inst[$p.id] = @{ Dossier = "C:\Essai\Programmes\$($p.id)"; Gere = $true; Version = $p.version } }
        'desinstaller' { $script:Inst.Remove($p.id) }
        'processus' { Add-Processus $p }
        'fin_processus' { $id = [int]$p.pid; $script:Processus = @($script:Processus | Where-Object { $_.Id -ne $id }) }
        'verrou' { if ($p.tenu) { [void]$script:Verrous.Add($p.nom) } else { [void]$script:Verrous.Remove($p.nom) } }
        'fenetre' {
            $classe = if ($p.classe) { $p.classe } else { 'Tauri Window' }
            [MSIntegration]::Creer([long]$p.h, [int]$p.pid, [string]$p.titre, $classe, [bool]$p.possedee, [bool]$p.visible)
        }
        'detruire' { [MSIntegration]::Detruire([long]$p.h) }
        'cacher' { [MSIntegration]::Fens[[long]$p.h].Visible = $false }
        'barre' { [MSIntegration]::Fens[[long]$p.h].Barre = [bool]$p.oui }
        'refus' { [MSIntegration]::Fens[[long]$p.h].Refus = $true }
        'reglage' { $script:Reglages[$p.nom] = $p.valeur }
        'attendre' { $script:Maintenant = $script:Maintenant.AddSeconds([double]$p.s) }
        'tic' { $script:Maintenant = $script:Maintenant.AddSeconds(0.4); if ($script:IntegrationTimer.Actif) { Invoke-Surveillance } }
        'page' { Show-Page $p.id }
        'ouvrir' { Open-AppliIci $p.id }
        'ici' { Invoke-ClicIci }
        'fermer' { Invoke-ClicFermer }
        'fermer_appli' { Stop-AppliConsole (Get-Appli $p.id) }
        'voile' { $ui.Confirmation.Visibility = if ($p.visible) { 'Visible' } else { 'Collapsed' }; Update-HotesVisibles }
        'zone' {
            # (une zone sans taille : Mindset réduit dans la barre des tâches ; WPF ne refaisait pas la mise en page)
            if ([int]$p.largeur -le 0 -or [int]$p.hauteur -le 0) { break }
            $script:Zone = @{ W = [int]$p.largeur; H = [int]$p.hauteur }
            foreach ($i in @($script:Integrees.Values)) { if ($i.Hote.Visibility -eq 'Visible') { Update-TaillePanneau $i } }
        }
        'quitter' { Disconnect-Applis }
        default { throw "Pas inconnu : $($p.q)" }
    }
}

function Invoke-Scenario($S) {
    Reset-Ecran
    [MSIntegration]::Reset()
    $script:T0 = [datetime]'2026-11-07T20:00:00'
    $script:Maintenant = $script:T0
    $script:Integrees = @{}
    $script:Jauge = $null
    $script:PageCourante = 'accueil'
    $script:Zone = @{ W = 0; H = 0 }
    $script:Journal = New-Object System.Collections.ArrayList
    $script:Lances = New-Object System.Collections.ArrayList
    $script:Arretes = New-Object System.Collections.ArrayList
    $script:Demandes = New-Object System.Collections.ArrayList
    $script:Verrous = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:Processus = @()
    $script:Inst = @{}
    $script:Reglages = [ordered]@{}
    $script:Console = @{ EnFente = $null }
    $script:MindsetAdmin = [bool]$S.admin
    $script:Applis = @(foreach ($id in $S.applis) { [pscustomobject]$toutes[$id] })
    $t = New-Object psobject
    $t | Add-Member NoteProperty Actif $false
    $t | Add-Member ScriptMethod Start { $this.Actif = $true }
    $t | Add-Member ScriptMethod Stop { $this.Actif = $false }
    $script:IntegrationTimer = $t
    $attendu = New-Object System.Collections.ArrayList
    $pas = New-Object System.Collections.ArrayList
    if ($S.hasard) {
        # (des pas tirés au hasard, chacun choisi d'après l'état du moment : des cas que personne n'a écrits)
        $script:Hasard = New-Object System.Random ([int]$S.hasard)
        for ($k = 0; $k -lt [int]$S.longueur; $k++) {
            $p = New-PasHasard
            [void]$pas.Add($p)
            Invoke-Pas $p
            [void]$attendu.Add((Get-Instantane))
        }
        $p = P 'quitter'; [void]$pas.Add($p); Invoke-Pas $p; [void]$attendu.Add((Get-Instantane))
    } else {
        foreach ($p in $S.pas) {
            [void]$pas.Add($p)
            Invoke-Pas $p
            [void]$attendu.Add((Get-Instantane))
        }
    }
    [ordered]@{ nom = $S.nom; applis = @($script:Applis); admin = [bool]$S.admin; pas = @($pas); attendu = @($attendu) }
}

# Un pas au hasard, possible dans l'état du moment
function Get-AuHasard([object[]]$L) { $L[$script:Hasard.Next($L.Count)] }
function New-PasHasard {
    $r = $script:Hasard.Next(100)
    $ids = @($script:Applis | ForEach-Object { $_.Id })
    $fens = @([MSIntegration]::Ordre)
    if ($r -lt 18) { return P 'tic' }
    if ($r -lt 26) { return P 'attendre' @{ s = (Get-AuHasard @(0.5, 1.2, 3, 5.5, 6, 14.9, 16, 59.8, 61)) } }
    if ($r -lt 36) { return P 'page' @{ id = (Get-AuHasard (@('accueil', 'parametres') + $ids + $ids)) } }
    if ($r -lt 41) { return P 'ouvrir' @{ id = (Get-AuHasard $ids) } }
    if ($r -lt 46 -and $ui.BtnPageAppliIci.Visibility -eq 'Visible' -and $script:PageCourante -notin @('accueil', 'parametres')) { return P 'ici' }
    if ($r -lt 54) {
        $script:PidHasard = [int]$script:PidHasard + 1
        $id = Get-AuHasard $ids
        $a = Get-Appli $id
        $p = @{ pid = 700 + $script:PidHasard; id = $id; nom = (Get-AuHasard @('Mindset.exe', 'Mindset.exe', $a.Exe, 'aide.exe')); age = (Get-AuHasard @(0, 0, 8, 45, 75, 300)) }
        if ($script:Hasard.Next(12) -eq 0) { $p.illisible = $true; $p.Remove('age') }
        return P 'processus' $p
    }
    if ($r -lt 58 -and @($script:Processus).Count) { return P 'fin_processus' @{ pid = (Get-AuHasard @($script:Processus)).Id } }
    if ($r -lt 68 -and @($script:Processus).Count) {
        $script:FenHasard = [int]$script:FenHasard + 1
        $pr = Get-AuHasard @($script:Processus)
        $a = Get-Appli $pr.Appli
        $titre = if ($script:Hasard.Next(6) -eq 0) { "$($a.Nom) - essai".Replace(' - ', ' : ') } else { $a.Nom }
        $classe = Get-AuHasard @('Tauri Window', 'Tauri Window', 'HwndWrapper[Mindset.exe;;1]', 'Chrome_WidgetWin_1')
        return P 'fenetre' @{ h = 5000 + $script:FenHasard; pid = $pr.Id; titre = $titre; classe = $classe; visible = ($script:Hasard.Next(2) -eq 0); possedee = ($script:Hasard.Next(8) -eq 0) }
    }
    if ($r -lt 73 -and $fens.Count) { return P 'detruire' @{ h = (Get-AuHasard $fens) } }
    if ($r -lt 77 -and $fens.Count) { return P 'cacher' @{ h = (Get-AuHasard $fens) } }
    if ($r -lt 80 -and $fens.Count) { return P 'barre' @{ h = (Get-AuHasard $fens); oui = ($script:Hasard.Next(2) -eq 0) } }
    if ($r -lt 82 -and $fens.Count) { return P 'refus' @{ h = (Get-AuHasard $fens) } }
    if ($r -lt 85) { return P 'voile' @{ visible = ($ui.Confirmation.Visibility -ne 'Visible') } }
    if ($r -lt 88) { return P 'zone' @{ largeur = (Get-AuHasard @(0, 640, 900, 1100)); hauteur = (Get-AuHasard @(0, 480, 700, 760)) } }
    if ($r -lt 90) { return P 'fermer' }
    if ($r -lt 92) { return P 'fermer_appli' @{ id = (Get-AuHasard $ids) } }
    if ($r -lt 95) { $a = Get-Appli (Get-AuHasard $ids); return P 'verrou' @{ nom = $a.Mutex; tenu = -not $script:Verrous.Contains($a.Mutex) } }
    if ($r -lt 98) { return P 'installer' @{ id = (Get-AuHasard $ids); version = (Get-AuHasard @('0.1.0', '0.12.5', '1.0.110', '1.3.0', $null)) } }
    if ($r -lt 100) { return P 'desinstaller' @{ id = (Get-AuHasard $ids) } }
    P 'tic'
}

# ---------------------------------------------------------------------------------------------------------------
# Les scénarios
# ---------------------------------------------------------------------------------------------------------------
function P([string]$Q, [hashtable]$A = @{}) { $h = [ordered]@{ q = $Q }; foreach ($k in $A.Keys | Sort-Object) { $h[$k] = $A[$k] }; $h }
function Tics([int]$N) { @(1..$N | ForEach-Object { P 'tic' }) }
$z = P 'zone' @{ largeur = 1100; hauteur = 760 }
$nm = 'Local\Nevermind-Instance'

$scenarios = @(
    @{ nom = 'pas installée'; applis = @('nevermind', 'evermind'); pas = @($z, (P 'page' @{ id = 'evermind' }), (P 'page' @{ id = 'nevermind' }), (P 'page' @{ id = 'accueil' })) }
    @{ nom = 'fermée : écran Ouvrir, puis lancée cachée et accrochée'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'page' @{ id = 'evermind' }), (P 'ici')) + (Tics 3) + @(
        (P 'processus' @{ pid = 501; id = 'evermind'; nom = 'Mindset.exe'; age = 0 }), (P 'tic'),
        (P 'fenetre' @{ h = 1001; pid = 501; titre = 'Evermind'; classe = 'HwndWrapper[Mindset.exe;;9f]'; visible = $false }),
        (P 'attendre' @{ s = 2.1 }), (P 'tic'), (P 'tic'), (P 'barre' @{ h = 1001; oui = $true }), (P 'tic'), (P 'zone' @{ largeur = 900; hauteur = 700 }),
        (P 'page' @{ id = 'accueil' }), (P 'tic'), (P 'zone' @{ largeur = 1000; hauteur = 700 }), (P 'page' @{ id = 'evermind' }), (P 'quitter')) }
    @{ nom = 'version trop ancienne : lancée dans sa fenêtre'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '0.12.5' }), (P 'page' @{ id = 'evermind' }), (P 'ici'), (P 'tic')) }
    @{ nom = 'sans cache_depuis ni version'; applis = @('cafe-creme', 'mindcare'); pas = @(
        $z, (P 'installer' @{ id = 'cafe-creme'; version = '2.0.0' }), (P 'installer' @{ id = 'mindcare'; version = $null }),
        (P 'page' @{ id = 'cafe-creme' }), (P 'ici'), (P 'page' @{ id = 'mindcare' }), (P 'ici'), (P 'tic')) }
    @{ nom = 'déjà ouverte : accrochée tout de suite'; applis = @('mindcare'); pas = @(
        $z, (P 'installer' @{ id = 'mindcare'; version = '0.2.0' }), (P 'processus' @{ pid = 610; id = 'mindcare'; nom = 'Mindset.exe'; age = 300 }),
        (P 'fenetre' @{ h = 2001; pid = 610; titre = 'Mindcare'; visible = $true }), (P 'page' @{ id = 'mindcare' }), (P 'tic'), (P 'tic')) }
    @{ nom = 'droits administrateur demandés, Mindset sans droits'; applis = @('nevermind'); pas = @(
        $z, (P 'installer' @{ id = 'nevermind'; version = '1.0.110' }), (P 'page' @{ id = 'nevermind' }), (P 'installer' @{ id = 'nevermind'; version = '1.0.115' }), (P 'page' @{ id = 'accueil' }), (P 'page' @{ id = 'nevermind' }), (P 'ici')) }
    @{ nom = 'droits administrateur demandés, Mindset administrateur'; applis = @('nevermind'); admin = $true; pas = @(
        $z, (P 'installer' @{ id = 'nevermind'; version = '1.0.110' }), (P 'page' @{ id = 'nevermind' }), (P 'ici'), (P 'tic')) }
    @{ nom = 'Windows refuse'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'processus' @{ pid = 520; id = 'evermind'; nom = 'Mindset.exe'; age = 90 }),
        (P 'fenetre' @{ h = 3001; pid = 520; titre = 'Evermind'; classe = 'HwndWrapper[x]'; visible = $true }), (P 'refus' @{ h = 3001 }),
        (P 'page' @{ id = 'evermind' }), (P 'tic'), (P 'page' @{ id = 'accueil' }), (P 'page' @{ id = 'evermind' })) }
    @{ nom = 'fermée pendant l''affichage, sans relance'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'processus' @{ pid = 530; id = 'evermind'; nom = 'Mindset.exe'; age = 90 }),
        (P 'fenetre' @{ h = 3101; pid = 530; titre = 'Evermind'; classe = 'HwndWrapper[x]'; visible = $true }), (P 'page' @{ id = 'evermind' }),
        (P 'detruire' @{ h = 3101 }), (P 'fin_processus' @{ pid = 530 }), (P 'tic'), (P 'attendre' @{ s = 30 }), (P 'tic'), (P 'attendre' @{ s = 30 }), (P 'tic'), (P 'tic')) }
    @{ nom = 'relancée pour un thème, puis raccrochée'; applis = @('nevermind'); pas = @(
        $z, (P 'installer' @{ id = 'nevermind'; version = '1.2.0' }), (P 'processus' @{ pid = 540; id = 'nevermind'; nom = 'Mindset.exe'; age = 600 }),
        (P 'fenetre' @{ h = 3201; pid = 540; titre = 'Nevermind'; visible = $true }), (P 'page' @{ id = 'nevermind' }),
        (P 'detruire' @{ h = 3201 }), (P 'fin_processus' @{ pid = 540 }), (P 'tic'), (P 'attendre' @{ s = 1.5 }),
        (P 'processus' @{ pid = 541; id = 'nevermind'; nom = 'Mindset.exe'; age = 0 }), (P 'tic'), (P 'attendre' @{ s = 4 }), (P 'tic'),
        (P 'fenetre' @{ h = 3202; pid = 541; titre = 'Nevermind'; visible = $false }), (P 'tic'), (P 'tic')) }
    @{ nom = 'relancée sans jamais revenir'; applis = @('nevermind'); pas = @(
        $z, (P 'installer' @{ id = 'nevermind'; version = '1.2.0' }), (P 'processus' @{ pid = 550; id = 'nevermind'; nom = 'Mindset.exe'; age = 600 }),
        (P 'fenetre' @{ h = 3301; pid = 550; titre = 'Nevermind'; visible = $true }), (P 'page' @{ id = 'nevermind' }),
        (P 'detruire' @{ h = 3301 }), (P 'fin_processus' @{ pid = 550 }), (P 'processus' @{ pid = 551; id = 'nevermind'; nom = 'Mindset.exe'; age = 0 }),
        (P 'tic'), (P 'attendre' @{ s = 59.5 }), (P 'tic'), (P 'tic'), (P 'tic')) }
    @{ nom = 'relance vue en ouvrant sa page'; applis = @('nevermind'); pas = @(
        $z, (P 'installer' @{ id = 'nevermind'; version = '1.2.0' }), (P 'processus' @{ pid = 555; id = 'nevermind'; nom = 'Mindset.exe'; age = 600 }),
        (P 'fenetre' @{ h = 3351; pid = 555; titre = 'Nevermind'; visible = $true }), (P 'page' @{ id = 'nevermind' }), (P 'page' @{ id = 'accueil' }),
        (P 'detruire' @{ h = 3351 }), (P 'fin_processus' @{ pid = 555 }), (P 'tic'), (P 'processus' @{ pid = 556; id = 'nevermind'; nom = 'Mindset.exe'; age = 0 }),
        (P 'page' @{ id = 'nevermind' }), (P 'tic'), (P 'fenetre' @{ h = 3352; pid = 556; titre = 'Nevermind'; visible = $false }), (P 'tic')) }
    @{ nom = 'cachée par elle-même, puis rouverte'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'processus' @{ pid = 560; id = 'evermind'; nom = 'Mindset.exe'; age = 90 }),
        (P 'fenetre' @{ h = 3401; pid = 560; titre = 'Evermind'; classe = 'HwndWrapper[x]'; visible = $true }), (P 'page' @{ id = 'evermind' }),
        (P 'cacher' @{ h = 3401 }), (P 'tic'), (P 'tic'), (P 'ici'), (P 'tic')) }
    @{ nom = 'lancée, son programme ne démarre pas'; applis = @('mindcare'); pas = @(
        $z, (P 'installer' @{ id = 'mindcare'; version = '0.2.0' }), (P 'page' @{ id = 'mindcare' }), (P 'ici'), (P 'attendre' @{ s = 14.8 }), (P 'tic'), (P 'tic'), (P 'tic')) }
    @{ nom = 'lancée, son programme tourne sans fenêtre'; applis = @('nevermind'); admin = $true; pas = @(
        $z, (P 'installer' @{ id = 'nevermind'; version = '1.2.0' }), (P 'page' @{ id = 'nevermind' }), (P 'ici'), (P 'verrou' @{ nom = $nm; tenu = $true }),
        (P 'tic'), (P 'attendre' @{ s = 30 }), (P 'tic'), (P 'attendre' @{ s = 29.4 }), (P 'tic'), (P 'tic')) }
    @{ nom = 'un programme bloqué sans fenêtre : arrêté puis relancé'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'processus' @{ pid = 570; id = 'evermind'; nom = 'Mindset.exe'; age = 120 }),
        (P 'processus' @{ pid = 571; id = 'evermind'; nom = 'aide.exe'; age = 120 }),
        (P 'page' @{ id = 'evermind' }), (P 'tic'), (P 'attendre' @{ s = 5 }), (P 'tic'), (P 'tic'),
        (P 'processus' @{ pid = 572; id = 'evermind'; nom = 'Mindset.exe'; age = 0 }), (P 'fenetre' @{ h = 3501; pid = 572; titre = 'Evermind'; classe = 'HwndWrapper[y]'; visible = $false }), (P 'tic')) }
    @{ nom = 'un programme récent ou illisible n''est pas arrêté'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'processus' @{ pid = 580; id = 'evermind'; nom = 'Mindset.exe'; age = 20 }),
        (P 'processus' @{ pid = 581; id = 'evermind'; nom = 'Evermind.exe'; illisible = $true }),
        (P 'page' @{ id = 'evermind' }), (P 'attendre' @{ s = 5.5 }), (P 'tic'), (P 'attendre' @{ s = 54.5 }), (P 'tic'), (P 'tic')) }
    @{ nom = 'le voile efface l''appli'; applis = @('mindcare'); pas = @(
        $z, (P 'installer' @{ id = 'mindcare'; version = '0.2.0' }), (P 'processus' @{ pid = 590; id = 'mindcare'; nom = 'Mindset.exe'; age = 90 }),
        (P 'fenetre' @{ h = 3601; pid = 590; titre = 'Mindcare'; visible = $true }), (P 'page' @{ id = 'mindcare' }),
        (P 'voile' @{ visible = $true }), (P 'tic'), (P 'zone' @{ largeur = 800; hauteur = 600 }), (P 'voile' @{ visible = $false }), (P 'page' @{ id = 'accueil' }), (P 'voile' @{ visible = $true }), (P 'page' @{ id = 'mindcare' }), (P 'voile' @{ visible = $false })) }
    @{ nom = 'deux applis, une seule visible'; applis = @('evermind', 'mindcare'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'installer' @{ id = 'mindcare'; version = '0.2.0' }),
        (P 'processus' @{ pid = 600; id = 'evermind'; nom = 'Mindset.exe'; age = 90 }), (P 'fenetre' @{ h = 3701; pid = 600; titre = 'Evermind'; classe = 'HwndWrapper[x]'; visible = $true }),
        (P 'ouvrir' @{ id = 'evermind' }), (P 'ouvrir' @{ id = 'mindcare' }), (P 'tic'), (P 'page' @{ id = 'evermind' }),
        (P 'processus' @{ pid = 601; id = 'mindcare'; nom = 'Mindset.exe'; age = 0 }), (P 'fenetre' @{ h = 3702; pid = 601; titre = 'Mindcare'; visible = $false }),
        (P 'tic'), (P 'page' @{ id = 'mindcare' }), (P 'barre' @{ h = 3702; oui = $true }), (P 'tic'), (P 'page' @{ id = 'evermind' }), (P 'quitter')) }
    @{ nom = 'fermer : bouton de Mindset et console'; applis = @('evermind', 'mindcare'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'installer' @{ id = 'mindcare'; version = '0.2.0' }),
        (P 'fermer'), (P 'fermer_appli' @{ id = 'mindcare' }), (P 'processus' @{ pid = 620; id = 'mindcare'; nom = 'Mindset.exe'; age = 90 }),
        (P 'fermer_appli' @{ id = 'mindcare' }), (P 'processus' @{ pid = 621; id = 'evermind'; nom = 'Mindset.exe'; age = 90 }),
        (P 'fenetre' @{ h = 3801; pid = 621; titre = 'Evermind'; classe = 'HwndWrapper[x]'; visible = $true }), (P 'page' @{ id = 'evermind' }),
        (P 'fermer'), (P 'fermer_appli' @{ id = 'evermind' }), (P 'page' @{ id = 'mindcare' }), (P 'fermer')) }
    @{ nom = 'durées de la jauge'; applis = @('nevermind', 'evermind', 'mindcare', 'cafe-creme'); admin = $true; pas = @(
        $z, (P 'installer' @{ id = 'nevermind'; version = '1.2.0' }), (P 'installer' @{ id = 'evermind'; version = '1.3.0' }),
        (P 'installer' @{ id = 'mindcare'; version = '0.2.0' }), (P 'installer' @{ id = 'cafe-creme'; version = '1.0.0' }),
        (P 'ouvrir' @{ id = 'nevermind' }), (P 'ouvrir' @{ id = 'evermind' }), (P 'ouvrir' @{ id = 'mindcare' }), (P 'ouvrir' @{ id = 'cafe-creme' }),
        (P 'reglage' @{ nom = 'Ouverture-mindcare'; valeur = 1.5 }), (P 'reglage' @{ nom = 'Ouverture-evermind'; valeur = 7.3 }),
        (P 'reglage' @{ nom = 'Ouverture-nevermind'; valeur = '12.5' }), (P 'page' @{ id = 'accueil' }),
        (P 'page' @{ id = 'mindcare' }), (P 'page' @{ id = 'evermind' }), (P 'page' @{ id = 'nevermind' })) }
    @{ nom = 'durée retenue seulement entre 1 et 120 s'; applis = @('mindcare', 'evermind'); pas = @(
        $z, (P 'installer' @{ id = 'mindcare'; version = '0.2.0' }), (P 'installer' @{ id = 'evermind'; version = '1.3.0' }),
        (P 'ouvrir' @{ id = 'mindcare' }), (P 'processus' @{ pid = 630; id = 'mindcare'; nom = 'Mindset.exe'; age = 0 }),
        (P 'fenetre' @{ h = 3901; pid = 630; titre = 'Mindcare'; visible = $false }), (P 'tic'),
        (P 'ouvrir' @{ id = 'evermind' }), (P 'attendre' @{ s = 3.25 }), (P 'processus' @{ pid = 631; id = 'evermind'; nom = 'Mindset.exe'; age = 0 }),
        (P 'fenetre' @{ h = 3902; pid = 631; titre = 'Evermind'; classe = 'HwndWrapper[e]'; visible = $false }), (P 'tic')) }
    @{ nom = 'elle démarre toute seule'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'verrou' @{ nom = 'Local\Evermind-Instance'; tenu = $true }),
        (P 'page' @{ id = 'evermind' }), (P 'tic'), (P 'processus' @{ pid = 640; id = 'evermind'; nom = 'Mindset.exe'; age = 1 }),
        (P 'fenetre' @{ h = 4001; pid = 640; titre = 'Evermind'; classe = 'HwndWrapper[e]'; visible = $false }), (P 'tic')) }
    @{ nom = 'fenêtres qui ne sont pas la sienne'; applis = @('cafe-creme'); pas = @(
        $z, (P 'installer' @{ id = 'cafe-creme'; version = '1.0.0' }), (P 'processus' @{ pid = 650; id = 'cafe-creme'; nom = 'CafeCreme.exe'; age = 90 }),
        (P 'processus' @{ pid = 651; id = 'cafe-creme'; nom = 'aide.exe'; age = 90 }),
        (P 'fenetre' @{ h = 4101; pid = 650; titre = 'Café crème'; classe = 'Chrome_WidgetWin_1'; visible = $true }),
        (P 'fenetre' @{ h = 4102; pid = 650; titre = 'Café crème'; possedee = $true; visible = $true }),
        (P 'fenetre' @{ h = 4103; pid = 650; titre = 'Cafe creme'; visible = $true }),
        (P 'fenetre' @{ h = 4104; pid = 651; titre = 'Café crème'; visible = $true }),
        (P 'page' @{ id = 'cafe-creme' }), (P 'tic'),
        (P 'fenetre' @{ h = 4105; pid = 650; titre = 'Café crème'; classe = 'HwndWrapperX'; visible = $true }),
        (P 'fenetre' @{ h = 4106; pid = 650; titre = 'Café crème'; visible = $true }), (P 'tic')) }
    @{ nom = 'accrochée hors de sa page, puis montrée'; applis = @('mindcare'); pas = @(
        (P 'installer' @{ id = 'mindcare'; version = '0.2.0' }), (P 'page' @{ id = 'mindcare' }), (P 'ici'), (P 'page' @{ id = 'accueil' }),
        (P 'processus' @{ pid = 660; id = 'mindcare'; nom = 'Mindset.exe'; age = 0 }), (P 'fenetre' @{ h = 4201; pid = 660; titre = 'Mindcare'; visible = $false }),
        (P 'tic'), $z, (P 'page' @{ id = 'mindcare' }), (P 'page' @{ id = 'parametres' }), (P 'detruire' @{ h = 4201 }), (P 'quitter')) }
    @{ nom = 'désinstallée pendant l''attente'; applis = @('evermind'); pas = @(
        $z, (P 'installer' @{ id = 'evermind'; version = '1.3.0' }), (P 'ouvrir' @{ id = 'evermind' }), (P 'tic'),
        (P 'desinstaller' @{ id = 'evermind' }), (P 'attendre' @{ s = 6 }), (P 'tic'), (P 'attendre' @{ s = 10 }), (P 'tic'), (P 'page' @{ id = 'evermind' })) }
)

# Des scénarios tirés au hasard (graines fixes : les mêmes à chaque export), sur les quatre sortes d'applis
foreach ($g in 1..40) {
    $applis = @(@('evermind', 'mindcare'), @('nevermind', 'cafe-creme'), @('evermind', 'nevermind', 'mindcare'))[$g % 3]
    $scenarios += @{ nom = "au hasard $g"; applis = $applis; admin = ($g % 4 -eq 0); hasard = 1000 + $g; longueur = 60 }
}

$cas = @(foreach ($s in $scenarios) { Invoke-Scenario $s })
$json = ConvertTo-Json -InputObject ([ordered]@{
    source = 'Mindset/fichiers/modules : integration.ps1, chargement.ps1 (et Test-AppliAdmin, Test-VersionPlusRecente, Stop-AppliConsole)'
    scenarios = $cas
}) -Depth 30 -Compress
New-Item -ItemType Directory -Force -Path (Split-Path $sortie) | Out-Null
[IO.File]::WriteAllText($sortie, $json, (New-Object System.Text.UTF8Encoding $false))
$n = ($cas | ForEach-Object { $_.attendu.Count } | Measure-Object -Sum).Sum
Write-Output "Juges écrits : $($cas.Count) scénarios, $n pas, dans $sortie"
