# Mindset : page Paramètres (thème de la suite).
# Chargé par Mindset.ps1 après accueil.ps1.

function New-ChoixTheme([string]$Id) {
    $th = $AppThemes[$Id]
    $actuel = ($Id -eq $ThemeId)
    $b = New-Button '' 'BtnSecondary'
    $b.Width = 220; $b.Margin = '0,0,12,12'; $b.HorizontalContentAlignment = 'Left'; $b.Tag = $Id
    # Aperçu dans ses propres couleurs (pas traduites par le thème actuel)
    $b.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((ConvertTo-ThemeHex '#0C0920' $Id))
    $b.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($actuel) { $th.P } else { ConvertTo-ThemeHex '#2A2450' $Id }))
    $sp = New-Object System.Windows.Controls.StackPanel
    $l = New-Object System.Windows.Controls.StackPanel; $l.Orientation = 'Horizontal'; $l.Margin = '0,2,0,8'
    foreach ($c in $th.P, $th.S, $th.T) {
        $r = New-Object System.Windows.Shapes.Ellipse; $r.Width = 14; $r.Height = 14; $r.Margin = '0,0,6,0'
        $r.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($c)
        [void]$l.Children.Add($r)
    }
    [void]$sp.Children.Add($l)
    $n = New-Object System.Windows.Controls.TextBlock
    $n.Text = $th.Name + $(if ($actuel) { '  (actuel)' } else { '' }); $n.FontWeight = 'SemiBold'; $n.FontSize = 14
    $n.Foreground = [System.Windows.Media.Brushes]::White
    if ($th.Font) { $n.FontFamily = $th.Font }
    [void]$sp.Children.Add($n)
    $dsc = New-Object System.Windows.Controls.TextBlock
    $dsc.Text = $th.Desc; $dsc.TextWrapping = 'Wrap'; $dsc.FontSize = 12; $dsc.FontWeight = 'Normal'; $dsc.Margin = '0,3,0,2'
    $dsc.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString((ConvertTo-ThemeHex '#A9A3C9' $Id))
    [void]$sp.Children.Add($dsc)
    $b.Content = $sp
    $b.Add_Click({
        $id = $this.Tag
        if ($id -eq $ThemeId) { return }
        if ($script:Occupe.Count) { $ui.ThemeInfo.Text = 'Une installation est en cours : réessaie quand elle sera finie.'; return }
        Set-SuiteTheme $id
        if ($EnTest) { $ui.ThemeInfo.Text = "Thème « $id » choisi (test : pas de relance)."; return }
        Restart-Mindset
    })
    [void]$ui.Themes.Children.Add($b)
}

foreach ($id in $AppThemes.Keys) { New-ChoixTheme $id }
