# Temoin : l'appli témoin de la suite Mindset. Elle ne fait rien d'utile : elle respecte, point par point, le contrat
# entre Mindset et une appli (docs\contrat-appli.md), et outils\tester-contrat.ps1 vérifie avec elle, contre le vrai
# code de Mindset, chacun de ces points. Elle sert aussi de modèle au squelette des nouvelles applis.
#
# Lancée par son hôte Mindset.exe (temoin\lanceur.cs), qui lui donne son dossier de données (contrat, partie 8) :
#   Mindset.exe [-Demarrage]
#
#   Verrou         Local\Temoin-Instance, gardé jusqu'à la fin ; déjà pris : 5 s d'attente, puis demande d'affichage
#                  (afficher.demande) à celle qui tourne, et fin sans fenêtre (partie 3).
#   -Demarrage     la fenêtre est créée cachée, sans prendre le premier plan ; elle se montre d'elle-même, sans
#                  s'activer, une fois accrochée dans Mindset (parties 6 et 7).
#   Fenêtre        une seule, sans propriétaire, titre « Temoin » (le nom dans apps.json), jamais recréée. Accrochée :
#                  taille minimale à 0 ; décrochée : remise. Sa croix (WM_CLOSE) la range (cachée), jamais détruite.
#   Fichiers       dans le dossier des données : quitter.demande, afficher.demande (lus puis supprimés),
#                  notification.demande, etat.json (écrits à côté puis renommés) ; suite.json pour le thème (partie 5).
# Rien de ce qui est lu n'est exécuté. Rien n'est écrit dans le dossier des programmes.
param([switch]$Demarrage, [string]$DossierDonnees)

$AppVersion = '1.0.0'
$AppNom = 'Temoin'
$ErrorActionPreference = 'Stop'
if (-not $DossierDonnees) { exit }   # (lancé sans son hôte : il ne sait pas où ranger ses fichiers)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TemoinNatif
{
    [DllImport("shell32.dll", PreserveSig = false)] static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr apres, int x, int y, int l, int hh, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    // Son identité dans la barre des tâches, la même que celle du raccourci écrit par Mindset (JordanJacquot.<Nom>)
    public static void Identite(string id) { SetCurrentProcessExplicitAppUserModelID(id); }
    // Accrochée dans Mindset : style WS_CHILD, ou un parent
    public static bool Accrochee(IntPtr h) { return h != IntPtr.Zero && ((GetWindowLongPtr(h, -16).ToInt64() & 0x40000000) != 0 || GetParent(h) != IntPtr.Zero); }
    // Son propre drapeau « visible » (Mindset regarde celui-ci pour savoir si elle s'est rangée)
    public static bool Montree(IntPtr h) { return (GetWindowLongPtr(h, -16).ToInt64() & 0x10000000) != 0; }
    // Sa place dans son parent, pour la lui rendre après Show() (WPF la replacerait sinon)
    public static int[] Place(IntPtr h)
    {
        RECT r; if (!GetWindowRect(h, out r)) return null;
        POINT p = new POINT { X = r.Left, Y = r.Top };
        IntPtr parent = GetParent(h);
        if (parent != IntPtr.Zero) ScreenToClient(parent, ref p);
        return new int[] { p.X, p.Y, r.Right - r.Left, r.Bottom - r.Top };
    }
    public static void Placer(IntPtr h, int[] p) { if (p != null) SetWindowPos(h, IntPtr.Zero, p[0], p[1], p[2], p[3], 0x0014); }   // SWP_NOZORDER | SWP_NOACTIVATE
}
'@

New-Item -ItemType Directory -Force -Path $DossierDonnees | Out-Null
$Fichiers = @{
    Quitter      = Join-Path $DossierDonnees 'quitter.demande'
    Afficher     = Join-Path $DossierDonnees 'afficher.demande'
    Notification = Join-Path $DossierDonnees 'notification.demande'
    Etat         = Join-Path $DossierDonnees 'etat.json'
}
$SuiteFichier = Join-Path $env:LOCALAPPDATA 'Mindset\suite.json'   # (où que soit installée la suite, comme Mindset)

# Écrit un fichier à côté puis le renomme : Mindset ne lit jamais un fichier à moitié écrit (UTF-8 sans BOM)
function Save-Fichier([string]$Chemin, [string]$Texte) {
    $tmp = "$Chemin.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $Texte, (New-Object Text.UTF8Encoding $false))
    try { if ([IO.File]::Exists($Chemin)) { [IO.File]::Replace($tmp, $Chemin, [NullString]::Value) } else { [IO.File]::Move($tmp, $Chemin) } }
    catch { try { [IO.File]::Delete($tmp) } catch {}; throw }
}
# Son journal, dans le dossier des données (une erreur n'est notée qu'une fois)
$script:Notees = @{}
function Write-Journal([string]$Texte) {
    if ($script:Notees.ContainsKey($Texte)) { return }
    $script:Notees[$Texte] = $true
    try { [IO.File]::AppendAllText((Join-Path $DossierDonnees 'journal.txt'), "$((Get-Date).ToString('s')) $Texte`r`n", (New-Object Text.UTF8Encoding $false)) } catch {}
}
# Lit puis supprime une demande ; '' si aucune (1 Ko au plus : une demande plus grosse est jetée sans être lue)
function Receive-Demande([string]$Chemin) {
    if (-not [IO.File]::Exists($Chemin)) { return $null }
    $t = ''
    try { if ((New-Object IO.FileInfo $Chemin).Length -le 1KB) { $t = [IO.File]::ReadAllText($Chemin, [Text.Encoding]::UTF8).Trim() } } catch {}
    try { [IO.File]::Delete($Chemin) } catch {}
    $t
}

# ---------------------------------------------------------------------------
# Une seule à la fois (contrat, partie 3)
# ---------------------------------------------------------------------------
$cree = $false
$Verrou = New-Object System.Threading.Mutex($true, "Local\$AppNom-Instance", [ref]$cree)
if (-not $cree) {
    # Une version qui se ferme (mise à jour, relance) libère la place dans quelques secondes
    $libre = $false
    try { $libre = $Verrou.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $libre = $true }
    if (-not $libre) {
        # Elle tourne : sa fenêtre est ramenée par sa demande d'affichage, et ce lancement s'arrête là. (Un lancement caché
        # n'a rien à montrer.)
        if (-not $Demarrage) { try { Save-Fichier $Fichiers.Afficher ([string]$PID) } catch {} }
        exit
    }
}
# De vieilles demandes laissées pendant qu'elle était fermée ne comptent pas
foreach ($f in $Fichiers.Quitter, $Fichiers.Afficher) { try { [IO.File]::Delete($f) } catch {} }
try { [TemoinNatif]::Identite('JordanJacquot.' + ($AppNom -replace '[^A-Za-z0-9]', '')) } catch {}

# ---------------------------------------------------------------------------
# La fenêtre (parties 6 et 7)
# ---------------------------------------------------------------------------
$Fenetre = New-Object System.Windows.Window
$Fenetre.Title = $AppNom
$Fenetre.Width = 760; $Fenetre.Height = 520
$Fenetre.MinWidth = 640; $Fenetre.MinHeight = 480
$Fenetre.Background = [System.Windows.Media.Brushes]::Black
$Texte = New-Object System.Windows.Controls.TextBlock
$Texte.Text = "L'appli témoin de la suite Mindset.`nElle sert seulement aux essais."
$Texte.Foreground = [System.Windows.Media.Brushes]::White
$Texte.FontSize = 18; $Texte.Margin = '24'; $Texte.TextWrapping = 'Wrap'
$Fenetre.Content = $Texte
$script:Quitter = $false
# Sa croix, ou « Fermer » de Mindset (WM_CLOSE) : elle se range (cachée), elle ne quitte que par quitter.demande
$Fenetre.Add_Closing({ param($s, $e) if (-not $script:Quitter) { $e.Cancel = $true; $Fenetre.Hide() } })
$Fenetre.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvokeShutdown('Normal') })
function Get-Handle { (New-Object System.Windows.Interop.WindowInteropHelper $Fenetre).Handle }

function Stop-Temoin { $script:Quitter = $true; $Fenetre.Close() }

# Montrer sa fenêtre (demande d'affichage) : jamais quand elle est accrochée dans Mindset, qui l'affiche déjà
function Show-Temoin {
    if ($script:Accrochee) { return }
    $Fenetre.Show()
    if ($Fenetre.WindowState -eq 'Minimized') { $Fenetre.WindowState = 'Normal' }
    [void]$Fenetre.Activate()
}

# ---------------------------------------------------------------------------
# Accrochée dans Mindset (partie 7)
# ---------------------------------------------------------------------------
$script:Accrochee = $false
$script:TailleMin = @{ L = $Fenetre.MinWidth; H = $Fenetre.MinHeight }
function Update-Accrochage {
    $h = Get-Handle
    if ($h -eq [IntPtr]::Zero) { return }
    $dans = [TemoinNatif]::Accrochee($h)
    if ($dans -eq $script:Accrochee) { return }
    $script:Accrochee = $dans
    if ($dans) {
        $Fenetre.MinWidth = 0; $Fenetre.MinHeight = 0   # Mindset lui donne la place qu'il a
        if (-not $Fenetre.IsVisible) {
            # Lancée cachée : pour WPF elle n'a jamais été montrée ; elle se montre sans s'activer, là où Mindset l'a mise
            $place = [TemoinNatif]::Place($h)
            $Fenetre.ShowActivated = $false; $Fenetre.WindowStartupLocation = 'Manual'
            $Fenetre.Show()
            [TemoinNatif]::Placer($h, $place)
        }
    } else {
        $Fenetre.MinWidth = $script:TailleMin.L; $Fenetre.MinHeight = $script:TailleMin.H
        # Rendue cachée par Mindset (il quitte) : elle reste rangée
        if ($Fenetre.IsVisible -and -not [TemoinNatif]::Montree($h)) { $Fenetre.Hide() }
    }
}

# ---------------------------------------------------------------------------
# Les fichiers échangés avec Mindset (partie 5)
# ---------------------------------------------------------------------------
# Une bulle près de l'horloge, montrée par Mindset : une à la fois, 6 s d'écart au moins, abandonnée après 5 minutes
$script:Notifs = New-Object System.Collections.Generic.List[string]   # les numéros donnés par l'appli
$script:NotifDepuis = [datetime]::MinValue
function Send-Notification([string]$Titre, [string]$Texte) {
    if ([IO.File]::Exists($Fichiers.Notification) -or ((Get-Date) - $script:NotifDepuis).TotalSeconds -lt 6) { return $false }
    $id = -join ((1..12) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
    $script:Notifs.Add($id)
    Save-Fichier $Fichiers.Notification (ConvertTo-Json @{ titre = $Titre; texte = $Texte; id = $id } -Compress)
    $script:NotifDepuis = Get-Date
    $true
}

# afficher.demande : un numéro de processus (Mindset, ou un second lancement), ou « notif:<id> » après un clic sur une
# bulle (seulement pour un numéro que l'appli a donné elle-même)
$script:BulleOuverte = ''
function Receive-Afficher([string]$Demande) {
    if ($Demande -cmatch '^notif:([0-9a-f]{12})$') {
        if (-not $script:Notifs.Contains($Matches[1])) { return }
        $script:BulleOuverte = $Matches[1]
        Show-Temoin
    } elseif ($Demande -match '^\d{1,10}$') { Show-Temoin }
}

# suite.json : le thème de la suite, seulement un nom connu (n'importe quel programme peut écrire ce fichier)
$script:Theme = 'neon'
$script:SuiteDate = [datetime]::MinValue
function Update-Theme {
    $fi = New-Object IO.FileInfo $SuiteFichier
    if (-not $fi.Exists -or $fi.LastWriteTimeUtc -eq $script:SuiteDate) { return }
    $script:SuiteDate = $fi.LastWriteTimeUtc
    if ($fi.Length -gt 64KB) { return }
    try {
        $t = ([IO.File]::ReadAllText($fi.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).theme
        if ($t -is [string] -and ($t -cin 'neon', 'crepuscule', 'terminal', 'arcade', 'rubis' -or $t -cmatch '^pack:[a-z0-9-]{1,40}$')) { $script:Theme = $t }
    } catch {}
}

# etat.json : sa carte dans l'accueil de Mindset, au format commun, écrit seulement quand il change
$script:EtatEcrit = ''
function Update-Etat {
    $lignes = @(
        @{ Texte = "Thème : $($script:Theme)"; Etat = 'info' },
        @{ Texte = $(if ($script:Accrochee) { 'Affichée dans Mindset' } else { 'Pas affichée dans Mindset' }); Etat = 'ok' })
    if ($script:BulleOuverte) { $lignes += @{ Texte = "Bulle ouverte : $($script:BulleOuverte)"; Etat = 'ok' } }
    $texte = ConvertTo-Json ([ordered]@{ Titre = "Témoin $AppVersion"; Scores = @(@{ Nom = 'Contrat'; Valeur = 100 }); Lignes = $lignes }) -Depth 4
    if ($texte -ceq $script:EtatEcrit) { return }
    Save-Fichier $Fichiers.Etat $texte
    $script:EtatEcrit = $texte
}

# Toutes les demi-secondes : quitter.demande, afficher.demande, accrochage, thème, carte, bulle oubliée
$Minuterie = New-Object System.Windows.Threading.DispatcherTimer
$Minuterie.Interval = [TimeSpan]::FromMilliseconds(500)
$Minuterie.Add_Tick({
    try {
        if ($null -ne (Receive-Demande $Fichiers.Quitter)) { $Minuterie.Stop(); Stop-Temoin; return }
        Update-Accrochage
        $a = Receive-Demande $Fichiers.Afficher
        if ($a) { Receive-Afficher $a }
        Update-Theme
        Update-Etat
        if ([IO.File]::Exists($Fichiers.Notification) -and ((Get-Date) - $script:NotifDepuis).TotalMinutes -gt 5) { try { [IO.File]::Delete($Fichiers.Notification) } catch {} }
    } catch { Write-Journal "Minuterie : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))" }   # (relu au passage suivant)
})

# ---------------------------------------------------------------------------
# Lancement
# ---------------------------------------------------------------------------
if ($Demarrage) {
    # Cachée : la fenêtre existe quand même (Mindset la cherche par son titre pour l'accrocher)
    [void](New-Object System.Windows.Interop.WindowInteropHelper $Fenetre).EnsureHandle()
} else { $Fenetre.Show() }
Update-Theme
Update-Etat
[void](Send-Notification 'Témoin' 'Le témoin est prêt.')
$Minuterie.Start()
[System.Windows.Threading.Dispatcher]::Run()

$Minuterie.Stop()
try { $Verrou.ReleaseMutex(); $Verrou.Dispose() } catch {}
