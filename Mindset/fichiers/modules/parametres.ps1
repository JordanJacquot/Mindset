# Mindset : page Paramètres (thème de la suite, démarrage avec Windows, dossiers, désinstallation).
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

# Démarrage avec Windows : une case par appli qui peut être lancée par Mindset (pas Nevermind, qui a besoin de l'admin)
foreach ($a in $Applis | Where-Object { -not $_.Admin }) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = "Démarrer $($a.Nom) en arrière-plan$(if ($a.Id -eq 'evermind') { ' (pour que les rappels sonnent)' })"
    $cb.Foreground = Get-Brush '#ECEAF7'; $cb.Margin = '0,0,0,8'; $cb.Tag = $a.Id
    $cb.IsChecked = Get-DemarrageAppli $a.Id
    $cb.Add_Click({ Set-DemarrageAppli $this.Tag ([bool]$this.IsChecked) })
    [void]$ui.Demarrages.Children.Add($cb)
}

$ui.DossiersTexte.Text = "Les programmes sont dans $RacineProgrammes (protégé : seul un administrateur peut les modifier). Les données de Mindset et de chaque appli sont dans $SuiteDir, un dossier par appli."
$ui.BtnDossierProgrammes.Add_Click({ $d = $RacineProgrammes; if (-not (Test-Path -LiteralPath $d)) { $d = Split-Path $AppDir -Parent }; Start-Process explorer.exe "`"$d`"" })
$ui.BtnDossierDonnees.Add_Click({ Start-Process explorer.exe "`"$SuiteDir`"" })
$ui.BtnDesinstallerMindset.Add_Click({ Confirm-DesinstallMindset })

# Bandeau de bienvenue : Mindset lancé depuis le dossier téléchargé (pas installé, pas un dossier de travail)
$ui.Bienvenue.Visibility = if ((-not (Test-MindsetInstalle) -and -not (Test-MindsetDeveloppement) -and -not $EnTest) -or ($EnTest -and $env:MINDSET_BIENVENUE)) { 'Visible' } else { 'Collapsed' }
# Un bouton radio par disque (C: d'abord, coché par défaut)
foreach ($d in @(Get-DisquesInstallation)) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.GroupName = 'Disque'; $rb.Tag = $d.Lettre; $rb.Margin = '0,2,0,2'; $rb.Foreground = Get-Brush '#ECEAF7'
    $rb.Content = "$($d.Texte)   ·   $($d.Libre)"
    if (-not $d.Lettre) { $rb.IsChecked = $true }
    [void]$ui.ChoixDisques.Children.Add($rb)
}
$ui.BtnInstallerMindset.Add_Click({
    $choix = @($ui.ChoixDisques.Children | Where-Object { $_.IsChecked }) | Select-Object -First 1
    Install-Mindset $(if ($choix) { [string]$choix.Tag } else { '' })
})
$ui.BtnBienvenuePlusTard.Add_Click({ $ui.Bienvenue.Visibility = 'Collapsed' })

# Mise à jour de Mindset (mindset.ps1) : le bandeau de l'accueil
$ui.BtnMajMindset.Add_Click({ Start-MajMindset })
$ui.BtnMajFermer.Add_Click({ $ui.MajBandeau.Visibility = 'Collapsed' })
Show-ResultatMajMindset
