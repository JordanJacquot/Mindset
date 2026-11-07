# Une fenêtre WPF d'essai pour l'accrochage (classe HwndWrapper[...], comme Evermind) : « Forêt », toute orange.
# Lancée par essai-accrochage.ps1, SEULEMENT sur un bureau Windows à part. Elle suit le contrat des applis
# (docs\contrat-appli.md, partie 7) : créée cachée (comme -Demarrage), elle se montre d'elle-même, sans prendre la main,
# quand Mindset l'accroche ; rendue par Mindset (cachée), elle se range. Elle s'en va au bout de -Secondes.
# (Le dessin de WPF ne se lit pas sur l'image d'une fenêtre accrochée dans un autre programme, même avec Mindset 2.18 :
# l'image prouve seulement que la page ne la recouvre pas. La preuve visuelle est faite par fenetre-gdi-essai.ps1.)
param([int]$Secondes = 150, [string]$Journal = '', [switch]$Montree)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EssaiWpf
{
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
}
'@
function Write-Journal([string]$t) { if ($Journal) { Add-Content -LiteralPath $Journal -Value "$(Get-Date -Format HH:mm:ss.fff) $t" -Encoding UTF8 } }
$w = New-Object System.Windows.Window
$w.Title = 'Forêt'
$w.Width = 640; $w.Height = 480; $w.Left = 40; $w.Top = 40
$w.WindowStartupLocation = 'Manual'
$w.ShowActivated = $false
# (pas de ShowInTaskbar = $false : WPF lui donnerait un propriétaire caché, et Mindset ne la prendrait pas, comme une alerte)
$w.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF8A00')
$t = New-Object System.Windows.Controls.TextBox
$t.Text = 'Forêt'; $t.FontSize = 40; $t.Margin = '40'; $t.Background = $w.Background; $t.BorderThickness = 0
$w.Content = $t
$h = (New-Object System.Windows.Interop.WindowInteropHelper $w).EnsureHandle()
# -Montree : elle tourne déjà dans sa fenêtre (sinon cachée, comme lancée avec -Demarrage)
if ($Montree) { $w.Show() }
$debut = Get-Date
$minuterie = New-Object System.Windows.Threading.DispatcherTimer
$minuterie.Interval = [TimeSpan]::FromMilliseconds(300)
$minuterie.Add_Tick({
    try {
        $style = [EssaiWpf]::GetWindowLong($h, -16)
        $accrochee = ([EssaiWpf]::GetParent($h) -ne [IntPtr]::Zero) -or (($style -band 0x40000000) -ne 0)
        if ($accrochee -and -not $w.IsVisible) { $w.Show(); Write-Journal "accrochée : montrée sans prendre la main (IsVisible $($w.IsVisible))" }
        if (-not $accrochee -and $w.IsVisible -and (($style -band 0x10000000) -eq 0)) { $w.Hide(); Write-Journal 'rendue cachée : rangée' }
    } catch { Write-Journal "ERREUR : $_" }
    if (((Get-Date) - $debut).TotalSeconds -gt $Secondes) { $minuterie.Stop(); $w.Close(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }
})
$minuterie.Start()
[System.Windows.Threading.Dispatcher]::Run()
