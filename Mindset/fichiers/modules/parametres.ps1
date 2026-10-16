# Mindset : page Paramètres (thème de la suite, démarrage avec Windows, dossiers, désinstallation).
# Chargé par Mindset.ps1 après accueil.ps1.

# Une carte de thème : $Cle est ce qui va dans suite.json (« neon », « pack:mario »), $Id le thème de couleurs
function New-ChoixTheme([string]$Cle, [string]$Id, [string]$Nom, [string]$Desc, $Pack) {
    $th = $AppThemes[$Id]
    $actuel = ($Cle -eq $ThemeSetting)
    $b = New-Button '' 'BtnSecondary'
    $b.Width = 220; $b.Height = 82; $b.Margin = '0,0,12,12'; $b.HorizontalContentAlignment = 'Stretch'; $b.VerticalContentAlignment = 'Stretch'; $b.Tag = $Cle
    # Aperçu dans ses propres couleurs (pas traduites par le thème actuel)
    $b.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString((ConvertTo-ThemeHex '#0C0920' $Id))
    $b.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($actuel) { $th.P } else { ConvertTo-ThemeHex '#2A2450' $Id }))
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Width = 178; $sp.HorizontalAlignment = 'Left'; $sp.VerticalAlignment = 'Center'   # même place pour tout, sur chaque carte
    # Ligne du haut toujours de la même hauteur : pastilles à gauche, mascotte (thème perso) dans un cadre fixe à droite
    $haut = New-Object System.Windows.Controls.DockPanel; $haut.Height = 34; $haut.Margin = '0,0,0,6'; $haut.LastChildFill = $false
    $l = New-Object System.Windows.Controls.StackPanel; $l.Orientation = 'Horizontal'; $l.VerticalAlignment = 'Center'
    foreach ($c in $th.P, $th.S, $th.T) {
        $r = New-Object System.Windows.Shapes.Ellipse; $r.Width = 14; $r.Height = 14; $r.Margin = '0,0,6,0'
        $r.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($c)
        [void]$l.Children.Add($r)
    }
    [void]$haut.Children.Add($l)
    # Thème personnalisé : sa mascotte (ou son logo) dans le coin de la carte
    $image = if ($Pack -and $Pack.Mascotte) { @($Pack.Mascotte.File, $Pack.Mascotte.Frames) } elseif ($Pack -and $Pack.Logo) { @($Pack.Logo, $Pack.LogoFrames) } else { $null }
    if ($image) {
        try {
            $im = New-Object System.Windows.Controls.Image
            $src = (Get-SheetFrames $image[0] $image[1])[0]
            # Une « mascotte » qui est en fait une bande de chargement (Dofus : un personnage entre deux portails, très
            # large) serait minuscule dans le cadre : le logo du pack la remplace
            if ($Pack.Mascotte -and $Pack.Logo -and $src.PixelWidth -gt 2 * $src.PixelHeight) { $src = (Get-SheetFrames $Pack.Logo $Pack.LogoFrames)[0] }
            $im.Source = $src; $im.Height = 34; $im.Width = 48; $im.Stretch = 'Uniform'
            $im.HorizontalAlignment = 'Right'; $im.VerticalAlignment = 'Center'
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($im, 'HighQuality')
            [System.Windows.Controls.DockPanel]::SetDock($im, 'Right')
            [void]$haut.Children.Add($im)
        } catch {}
    }
    [void]$sp.Children.Add($haut)
    $n = New-Object System.Windows.Controls.TextBlock
    $n.Text = $Nom + $(if ($actuel) { '  (actuel)' } else { '' }); $n.FontWeight = 'SemiBold'; $n.FontSize = 14; $n.TextTrimming = 'CharacterEllipsis'
    $n.Foreground = [System.Windows.Media.Brushes]::White
    if ($th.Font) { $n.FontFamily = $th.Font }
    [void]$sp.Children.Add($n)
    $b.ToolTip = $Nom
    $b.Content = $sp
    $b.Add_Click({
        $cle = $this.Tag
        if ($cle -eq $ThemeSetting) { return }
        if ($script:Occupe.Count) { $ui.ThemeInfo.Text = 'Une installation est en cours : réessaie quand elle sera finie.'; return }
        Set-SuiteTheme $cle
        if ($EnTest) { $ui.ThemeInfo.Text = "Thème « $cle » choisi (test : pas de relance)."; return }
        Restart-Mindset
    })
    [void]$ui.Themes.Children.Add($b)
}

# Les 5 thèmes de base, puis les thèmes personnalisés importés
function Update-ChoixThemes {
    $ui.Themes.Children.Clear()
    foreach ($id in @($AppThemes.Keys | Where-Object { -not $AppThemes[$_].Pack })) { New-ChoixTheme $id $id $AppThemes[$id].Name $AppThemes[$id].Desc $null }
    foreach ($pk in @(Get-ThemePacks)) { New-ChoixTheme "pack:$($pk.Id)" $pk.Base $pk.Name $pk.Desc $pk }
}
Update-ChoixThemes

# « Importer un thème » : un zip de la suite, installé pour Mindset, Nevermind et Evermind
$ui.BtnImporterTheme.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choisis le thème de la suite (.zip)'; $dlg.Filter = 'Thème de la suite (*.zip)|*.zip'
    foreach ($d in @('D:\Projets\Thème-Mindset', (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Thème-Mindset'))) { if (Test-Path -LiteralPath $d) { $dlg.InitialDirectory = $d; break } }
    if (-not $dlg.ShowDialog()) { return }
    try {
        $id = Import-PackSuite $dlg.FileName
        Update-ChoixThemes
        $ui.ThemeInfo.Text = "« $((Get-ThemePack $id).Name) » est importé pour Mindset, Nevermind et Evermind : clique dessus pour le choisir."
    } catch { $ui.ThemeInfo.Text = "Ce thème n'a pas pu être importé : $($_.Exception.Message)" }
})

# Démarrage avec Windows : le même interrupteur « S'ouvre avec Mindset » que sur les cartes de l'accueil, pour chaque
# appli que Mindset peut ouvrir (une version qui demande encore les droits administrateur : non). Refait à chaque
# affichage de l'onglet Général : une appli installée ou mise à jour entre-temps y apparaît sans rouvrir Mindset.
function Update-DemarragesParametres {
    $ui.Demarrages.Children.Clear()
    # D'abord Mindset lui-même : s'il se lance avec Windows, il ouvre avec lui les applis cochées en dessous
    $ligne = New-Object System.Windows.Controls.DockPanel
    $ligne.Margin = '0,0,0,14'; $ligne.Width = 520; $ligne.HorizontalAlignment = 'Left'
    $sw = New-Object System.Windows.Controls.CheckBox
    $sw.Style = $Window.FindResource('Switch'); $sw.VerticalAlignment = 'Center'
    $sw.IsChecked = Get-LancerAvecWindows
    $sw.Add_Click({ Set-LancerAvecWindows ([bool]$this.IsChecked) })
    [System.Windows.Controls.DockPanel]::SetDock($sw, 'Right')
    [void]$ligne.Children.Add($sw)
    $txt = New-Object System.Windows.Controls.StackPanel; $txt.VerticalAlignment = 'Center'; $txt.Margin = '0,0,16,0'
    [void]$txt.Children.Add((New-Text 'Mindset se lance avec Windows' 13 '#ECEAF7'))
    $aide = New-Text 'Caché près de l''horloge, il ouvre en même temps les applis cochées ci-dessous.' 11.5 '#6F6894'
    $aide.TextWrapping = 'Wrap'; $aide.Margin = '0,2,0,0'
    [void]$txt.Children.Add($aide)
    [void]$ligne.Children.Add($txt)
    [void]$ui.Demarrages.Children.Add($ligne)
    foreach ($a in $Applis | Where-Object { (Get-Installation $_) -and (-not (Test-AppliAdmin $_) -or $MindsetAdmin) }) {
        $ligne = New-Object System.Windows.Controls.DockPanel
        $ligne.Margin = '0,0,0,10'; $ligne.Width = 520; $ligne.HorizontalAlignment = 'Left'
        $sw = New-InterrupteurOuverture $a.Id
        [System.Windows.Controls.DockPanel]::SetDock($sw, 'Right')
        [void]$ligne.Children.Add($sw)
        $t = New-Text "$($a.Nom) s'ouvre avec Mindset" 13 '#ECEAF7'; $t.VerticalAlignment = 'Center'; $t.Margin = '0,0,16,0'
        [void]$ligne.Children.Add($t)
        [void]$ui.Demarrages.Children.Add($ligne)
    }
}
Update-DemarragesParametres

$ui.DossiersTexte.Text = "Les programmes sont dans $RacineProgrammes (protégé : seul un administrateur peut les modifier). Les données de Mindset et de chaque appli sont dans $SuiteDir, un dossier par appli."
$ui.BtnDossierProgrammes.Add_Click({ $d = $RacineProgrammes; if (-not (Test-Path -LiteralPath $d)) { $d = Split-Path $AppDir -Parent }; Start-Process explorer.exe "`"$d`"" })
$ui.BtnDossierDonnees.Add_Click({ Start-Process explorer.exe "`"$SuiteDir`"" })
$ui.BtnDesinstallerMindset.Add_Click({ Confirm-DesinstallMindset })

# Bandeau de bienvenue : Mindset lancé depuis le dossier téléchargé (pas installé, pas un dossier de travail)
$ui.Bienvenue.Visibility = if ((-not (Test-MindsetInstalle) -and -not (Test-MindsetDeveloppement) -and -not $EnTest) -or ($EnTest -and $env:MINDSET_BIENVENUE)) { 'Visible' } else { 'Collapsed' }
# Un bouton radio par disque : celui de l'installation existante (réinstallation), sinon C:
$disques = @(Get-DisquesInstallation)
$coche = if ($disques | Where-Object { $_.Lettre -eq $Racines.Disque }) { $Racines.Disque } else { '' }
foreach ($d in $disques) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.GroupName = 'Disque'; $rb.Tag = $d.Lettre; $rb.Margin = '0,2,0,2'; $rb.Foreground = Get-Brush '#ECEAF7'
    $rb.Content = "$($d.Texte)   ·   $($d.Libre)"
    if ($d.Lettre -eq $coche) { $rb.IsChecked = $true }
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

# ---------------------------------------------------------------------------
# Onglets : Général, Apparence, Son, Mises à jour, Dossiers
# ---------------------------------------------------------------------------
$OngletsParametres = [ordered]@{ general = 'Général'; apparence = 'Apparence'; son = 'Son'; maj = 'Mises à jour'; dossiers = 'Dossiers' }
$PanneauxParametres = @{ general = 'PanGeneral'; apparence = 'PanApparence'; son = 'PanSon'; maj = 'PanMaj'; dossiers = 'PanDossiers' }
$script:OngletParametres = 'general'

function Show-OngletParametres([string]$Id) {
    if (-not $OngletsParametres.Contains($Id)) { $Id = 'general' }
    $script:OngletParametres = $Id
    foreach ($b in $ui.OngletsParametres.Children) { $b.Style = $Window.FindResource($(if ($b.Tag -eq $Id) { 'BtnPrimary' } else { 'BtnSecondary' })) }
    foreach ($k in $PanneauxParametres.Keys) { $ui[$PanneauxParametres[$k]].Visibility = if ($k -eq $Id) { 'Visible' } else { 'Collapsed' } }
    if ($Id -eq 'general') { Update-DemarragesParametres }
    if ($Id -eq 'son') { Update-ChoixSon }
    if ($Id -eq 'maj') { Update-ListeVersions }
}
foreach ($k in $OngletsParametres.Keys) {
    $b = New-Button $OngletsParametres[$k] 'BtnSecondary'
    $b.Tag = $k; $b.Margin = '0,0,8,8'
    $b.Add_Click({ Show-OngletParametres $this.Tag })
    [void]$ui.OngletsParametres.Children.Add($b)
}

# ---------------------------------------------------------------------------
# Son : le micro et le casque de toute la suite (suite.json) ; Evermind les suit tout de suite
# ---------------------------------------------------------------------------
# Windows coupe les noms d'appareils à 31 lettres : « … » le montre au lieu d'une parenthèse qui ne se ferme pas
# (comme Evermind ; le nom gardé, lui, reste le nom coupé, celui que les applis retrouvent)
function Get-NomAppareil([string]$Nom) {
    if ($Nom.Length -ge 31 -and $Nom.Substring(0, 31) -match '\([^)]*$') { return $Nom.Substring(0, 31).TrimEnd() + '…)' + $Nom.Substring(31) }
    if ($Nom.Length -eq 31) { return $Nom.TrimEnd() + '…' }
    $Nom
}

# Une ligne cliquable : le nom de l'appareil, et « choisi » ou « choisir »
function New-LigneAppareil([string]$Quoi, [string]$Cle, [string]$Nom, [bool]$Choisi) {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 14; $b.Padding = '14,9'; $b.Margin = '0,0,0,6'; $b.BorderThickness = 1.5; $b.Cursor = 'Hand'
    $b.Tag = @{ Quoi = $Quoi; Cle = $Cle }
    $b.Background = Get-Brush $(if ($Choisi) { '#2600E5FF' } else { '#0FFFFFFF' })
    $b.BorderBrush = if ($Choisi) { $Window.FindResource('AccentBg') } else { Get-Brush '#1CFFFFFF' }
    $dp = New-Object System.Windows.Controls.DockPanel
    $etat = New-Text $(if ($Choisi) { '✓ choisi' } else { 'choisir' }) 13 $(if ($Choisi) { '#7FF4FF' } else { '#A6A1BC' })
    $etat.TextWrapping = 'NoWrap'; $etat.Margin = '12,0,0,0'; $etat.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($etat, 'Right')
    [void]$dp.Children.Add($etat)
    $n = New-Text (Get-NomAppareil $Nom) 14 '#FFFFFF'; $n.TextWrapping = 'NoWrap'; $n.TextTrimming = 'CharacterEllipsis'; $n.VerticalAlignment = 'Center'
    [void]$dp.Children.Add($n)
    $b.Child = $dp
    $b.Add_MouseLeftButtonUp({ param($s) Set-SuiteSon $s.Tag.Quoi $s.Tag.Cle; Update-ChoixSon })
    $b
}

function Update-ChoixSon {
    $son = Get-SuiteSon
    foreach ($c in @(@('micro', $ui.ChoixMicro, @([MSAudio]::Micros()), $son.Micro), @('casque', $ui.ChoixCasque, @([MSAudio]::Sorties()), $son.Casque))) {
        $quoi = $c[0]; $panneau = $c[1]; $noms = @($c[2]); $choisi = [string]$c[3]
        $panneau.Children.Clear()
        [void]$panneau.Children.Add((New-LigneAppareil $quoi '' 'Celui de Windows' (-not $choisi)))
        foreach ($n in $noms | Select-Object -Unique) { if ($n) { [void]$panneau.Children.Add((New-LigneAppareil $quoi $n $n ($n -eq $choisi))) } }
        if ($choisi -and $noms -notcontains $choisi) { [void]$panneau.Children.Add((New-LigneAppareil $quoi $choisi "$choisi (débranché)" $true)) }
    }
}
$ui.BtnSonActualiser.Add_Click({ Update-ChoixSon })

# ---------------------------------------------------------------------------
# Mises à jour : la version de Mindset et de chaque appli, et ce qui est publié
# ---------------------------------------------------------------------------
function New-LigneVersion([string]$Nom, [string]$Couleur, [string]$Installee, [string]$Etat, [string]$CouleurEtat) {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 14; $b.Padding = '16,10'; $b.Margin = '0,0,0,6'; $b.BorderThickness = 1
    $b.Background = $Window.FindResource('CardBg'); $b.BorderBrush = $Window.FindResource('CardBorder')
    $dp = New-Object System.Windows.Controls.DockPanel
    $e = New-Text $Etat 13 $CouleurEtat; $e.TextWrapping = 'NoWrap'; $e.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($e, 'Right')
    [void]$dp.Children.Add($e)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    [void]$sp.Children.Add((New-Text $Nom 15 $Couleur 'SemiBold'))
    $v = New-Text "   $Installee" 13 '#A6A1BC'; $v.VerticalAlignment = 'Center'
    [void]$sp.Children.Add($v)
    [void]$dp.Children.Add($sp)
    $b.Child = $dp
    $b
}

function Update-ListeVersions {
    $ui.ListeVersions.Children.Clear()
    $etatMindset = if ($script:MajMindset) { @("$($script:MajMindset.Version) prête : voir l'accueil", '#FFB020') } elseif ($script:MajMindsetEnCours) { @('recherche...', '#A6A1BC') } else { @('à jour', '#3DDC84') }
    [void]$ui.ListeVersions.Children.Add((New-LigneVersion 'Mindset' '#ECEAF7' "version $AppVersion" $etatMindset[0] $etatMindset[1]))
    foreach ($a in $Applis) {
        $i = Get-Installation $a; $p = $script:Publications[$a.Id]
        $inst = if ($i) { "version $(if ($i.Version) { $i.Version } else { '?' })" } else { 'pas installé' }
        $etat = if (-not $p) { @('pas encore vérifié', '#A6A1BC') } elseif ($p.Erreur) { @('GitHub injoignable', '#FF7A9C') }
                elseif ($i -and $i.Version -and (Test-VersionPlusRecente $p.Version $i.Version)) { @("$($p.Version) disponible", '#FFB020') }
                elseif ($i) { @('à jour', '#3DDC84') } else { @("dernière : $($p.Version)", '#A6A1BC') }
        [void]$ui.ListeVersions.Children.Add((New-LigneVersion $a.Nom $a.Couleur $inst $etat[0] $etat[1]))
    }
}
$ui.BtnVerifierMaj.Add_Click({
    Update-Publications; Start-VerifMajMindset
    $ui.MajInfo.Text = "Vérifié à $((Get-Date).ToString('HH:mm'))"
    $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromSeconds(4)
    $t.Add_Tick({ $this.Stop(); if ($script:OngletParametres -eq 'maj') { Update-ListeVersions } }); $t.Start()
})

# ---------------------------------------------------------------------------
# Une appli demande d'ouvrir un onglet des Paramètres (« Ouvrir les réglages de Mindset ») : elle écrit
# « parametres:son » ou « parametres:apparence » dans %LOCALAPPDATA%\Mindset\afficher-page.txt, puis lance Mindset
# ---------------------------------------------------------------------------
$FichierPageDemandee = Join-Path $SuiteFileDir 'afficher-page.txt'
function Open-PageDemandee {
    if (-not (Test-Path -LiteralPath $FichierPageDemandee)) { return }
    $t = ''; try { $t = ([IO.File]::ReadAllText($FichierPageDemandee)).Trim() } catch {}
    Remove-Item -LiteralPath $FichierPageDemandee -Force -ErrorAction SilentlyContinue
    # Une appli lancée à la main, ou qui demande à être montrée : elle s'ouvre ici, dans son onglet
    if ($t -match '^appli:([a-z0-9-]{1,30})$' -and (Get-Appli $Matches[1])) {
        $id = $Matches[1]
        Show-Fenetre
        Open-AppliIci $id
        return
    }
    if ($t -notmatch '^parametres(:(general|apparence|son|maj|dossiers))?$') { return }
    $onglet = if ($Matches[2]) { $Matches[2] } else { 'general' }
    Show-Fenetre
    Show-Page 'parametres'
    Show-OngletParametres $onglet
}

Show-OngletParametres $(if ($EnTest -and $env:MINDSET_ONGLET) { $env:MINDSET_ONGLET } else { 'general' })

# ---------------------------------------------------------------------------
# Le mini-installateur (tâche « \Mindset\Mindset (installation) », créée à l'installation de Mindset) : installer et
# mettre à jour sans demande de Windows. Une installation qui ne l'a pas : un bandeau propose de le créer (une dernière
# demande de Windows).
# ---------------------------------------------------------------------------
function Test-TacheMindset { $script:TacheInstallationOk = $null; Test-TacheInstallation }

function Enable-MindsetAdmin {
    $ui.AdminTexte.Text = 'Activation (accepte la demande de Windows)...'
    $ui.BtnActiverAdmin.IsEnabled = $false
    Invoke-Admin 'taches' @{ Destination = $DossierMindset; Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } {
        param($Ok, $Message)
        $ui.BtnActiverAdmin.IsEnabled = $true
        if (-not $Ok) { $ui.AdminTexte.Text = "Activation impossible : $Message"; return }
        # Le lancement avec Windows passe par la tâche (sans droits)
        Remove-ItemProperty -Path $CleRun -Name 'Mindset' -ErrorAction SilentlyContinue
        Write-Log 'Mini-installateur activé (tâches planifiées)'
        $script:TacheInstallationOk = $true
        $ui.AdminBandeau.Visibility = 'Collapsed'
    }
}

$ui.AdminBandeau.Visibility = if (((Test-MindsetInstalle) -and -not $EnTest -and -not (Test-TacheMindset)) -or ($EnTest -and $env:MINDSET_ADMIN_TEST)) { 'Visible' } else { 'Collapsed' }
$ui.BtnActiverAdmin.Add_Click({ Enable-MindsetAdmin })
