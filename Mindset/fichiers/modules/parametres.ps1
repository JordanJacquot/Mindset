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
    $b.Add_Click({ Select-ThemeSuite $this.Tag })
    [void]$ui.Themes.Children.Add($b)
}

# Choisir le thème de la suite (carte d'un thème, ici ou dans l'écran de la console) : suite.json, puis Mindset se relance
function Select-ThemeSuite([string]$Cle) {
    if (-not $Cle -or $Cle -eq $ThemeSetting) { return }
    if ($script:Occupe.Count) { $ui.ThemeInfo.Text = 'Une installation est en cours : réessaie quand elle sera finie.'; return }
    Set-SuiteTheme $Cle
    if ($EnTest) { $ui.ThemeInfo.Text = "Thème « $Cle » choisi (test : pas de relance)."; return }
    Restart-Mindset
}

# Les thèmes supprimés dont un dossier était encore pris (une appli ouverte s'en servait) : retirés maintenant, puis
# une dernière fois 30 secondes plus tard (le temps que les applis relancées sur le nouveau thème les lâchent)
Clear-PacksARetirer
if (@(Get-PacksARetirer).Count) {
    $script:PacksARetirerTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PacksARetirerTimer.Interval = [TimeSpan]::FromSeconds(30)
    $script:PacksARetirerTimer.Add_Tick({ $this.Stop(); Clear-PacksARetirer })
    $script:PacksARetirerTimer.Start()
}

# Les 5 thèmes de base, puis les thèmes personnalisés importés
function Update-ChoixThemes {
    $ui.Themes.Children.Clear()
    foreach ($id in @($AppThemes.Keys | Where-Object { -not $AppThemes[$_].Pack })) { New-ChoixTheme $id $id $AppThemes[$id].Name $AppThemes[$id].Desc $null }
    foreach ($pk in @(Get-ThemePacks)) { New-ChoixTheme "pack:$($pk.Id)" $pk.Base $pk.Name $pk.Desc $pk }
}
Update-ChoixThemes

# « Importer un thème » : un zip de la suite, installé pour Mindset, Nevermind et Evermind
# (la fenêtre de Windows qui choisit le fichier : son chemin, ou rien si on annule)
function Select-FichierThemeSuite {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choisis le thème de la suite (.zip)'; $dlg.Filter = 'Thème de la suite (*.zip)|*.zip'
    foreach ($d in @('D:\Projets\Thème-Mindset', (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Thème-Mindset'))) { if (Test-Path -LiteralPath $d) { $dlg.InitialDirectory = $d; break } }
    if (-not $dlg.ShowDialog()) { return $null }
    $dlg.FileName
}
function Import-ThemeSuite {
    $f = Select-FichierThemeSuite
    if (-not $f) { return }
    try {
        $id = Import-PackSuite $f
        Update-ChoixThemes
        $script:ThemesConsole = $null   # (la liste des thèmes de l'écran de la console est refaite)
        $script:ImagesThemesConsole.Remove($id)   # (et l'image de sa carte, si c'est une nouvelle version)
        $nom = (Get-ThemePack $id).Name
        # Déjà installé : la nouvelle version remplace l'ancienne. Si c'est le thème actuel, rien n'est relancé : Mindset
        # et les applis ouvertes gardent l'ancienne version chargée jusqu'à leur prochaine ouverture.
        $ui.ThemeInfo.Text = if (-not $script:PackRemplace) { "Thème « $nom » ajouté pour Mindset et toutes ses applis : clique dessus pour le choisir." }
            elseif ((Read-Suite).theme -eq "pack:$id") { "Thème « $nom » mis à jour : la nouvelle version remplace l'ancienne. C'est le thème actuel : Mindset et les applis ouvertes la prendront à leur prochaine ouverture." }
            else { "Thème « $nom » mis à jour : la nouvelle version remplace l'ancienne." }
        # (une appli ouverte se servait de l'ancienne version : la nouvelle sera mise en place au prochain démarrage de Mindset)
        if (@($script:PackEnAttente).Count) { $ui.ThemeInfo.Text = "Thème « $nom » mis à jour. $(@($script:PackEnAttente) -join ' et ') s'en $(if (@($script:PackEnAttente).Count -gt 1) { 'servent' } else { 'sert' }) en ce moment : la nouvelle version sera prise au prochain démarrage de Mindset." }
    } catch { $ui.ThemeInfo.Text = "Ce thème n'a pas pu être importé : $($_.Exception.Message)" }
}
$ui.BtnImporterTheme.Add_Click({ Import-ThemeSuite })

# Supprimer un thème perso (bouton « Supprimer » de sa ligne, dans l'écran de la console) : après la question, il est
# retiré de Mindset et de toutes les applis. Le thème actuel : la suite repasse d'abord sur Néon (suite.json, comme un
# changement de thème : les applis ouvertes se relancent avec lui), et Mindset se relance.
function Confirm-SuppressionTheme([string]$Id) {
    $pk = Get-ThemePacks | Where-Object { $_.Id -ceq $Id } | Select-Object -First 1
    if (-not $pk) { return }
    $actuel = (Read-Suite).theme -eq "pack:$Id"
    $script:ThemeASupprimer = $Id
    Show-Confirmation "Supprimer le thème « $($pk.Name) » ?" ("Il sera retiré de Mindset et de toutes les applis." + $(if ($actuel) { " C'est le thème actuel : la suite repasse d'abord sur le thème $($AppThemes['neon'].Name), et Mindset se relance." } else { '' })) 'Supprimer' {
        $id = $script:ThemeASupprimer; $script:ThemeASupprimer = $null
        if ($id) { Remove-ThemeSuite $id }
    }
}
function Remove-ThemeSuite([string]$Id) {
    $pk = Get-ThemePacks | Where-Object { $_.Id -ceq $Id } | Select-Object -First 1
    if (-not $pk) { return }
    if ($script:Occupe.Count) { $ui.ThemeInfo.Text = 'Une installation est en cours : réessaie quand elle sera finie.'; return }
    $actuel = (Read-Suite).theme -eq "pack:$Id"
    if ($actuel) { Set-SuiteTheme 'neon' }   # (d'abord : plus aucune appli ne le cherche)
    $ok = Remove-PackSuite $Id
    $script:ImagesThemesConsole.Remove($Id); $script:ThemesConsole = $null
    Update-ChoixThemes
    $ui.ThemeInfo.Text = "Thème « $($pk.Name) » supprimé de Mindset et de toutes les applis." + $(if ($actuel) { " La suite repasse sur le thème $($AppThemes['neon'].Name)." } else { '' }) +
        $(if (-not $ok) { ' Une appli ouverte s''en sert encore : il finira d''être retiré au prochain démarrage de Mindset.' } else { '' })
    if ($actuel -and -not $EnTest) { Restart-Mindset; return }
    if (Get-Command Send-ParametresConsole -ErrorAction SilentlyContinue) { Send-ParametresConsole -Force; Send-ImagesThemesConsole }
}

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
        $t = New-Text "$($a.Nom) s'ouvre avec Mindset$(if ($a.Rappels) { ' (sinon ses rappels ne sonnent pas)' })" 13 '#ECEAF7'; $t.VerticalAlignment = 'Center'; $t.Margin = '0,0,16,0'
        [void]$ligne.Children.Add($t)
        [void]$ui.Demarrages.Children.Add($ligne)
    }
}
Update-DemarragesParametres

$ui.DossiersTexte.Text = "Les programmes sont dans $RacineProgrammes (protégé : seul un administrateur peut les modifier). Les données de Mindset et de chaque appli sont dans $SuiteDir, un dossier par appli."
function Open-DossierExplorateur([string]$Dossier) { Start-Process explorer.exe "`"$Dossier`"" }
function Open-DossierProgrammes { $d = $RacineProgrammes; if (-not (Test-Path -LiteralPath $d)) { $d = Split-Path $AppDir -Parent }; Open-DossierExplorateur $d }
function Open-DossierDonnees { Open-DossierExplorateur $SuiteDir }
$ui.BtnDossierProgrammes.Add_Click({ Open-DossierProgrammes })
$ui.BtnDossierDonnees.Add_Click({ Open-DossierDonnees })
$ui.BtnDesinstallerMindset.Add_Click({ Confirm-DesinstallMindset })

# Bandeau de bienvenue : Mindset lancé depuis le dossier téléchargé (pas installé, pas un dossier de travail)
$ui.Bienvenue.Visibility = if ($script:AttenteBienvenue) { 'Visible' } else { 'Collapsed' }   # (accueil.ps1)
# Ce qui part sur Internet : la recherche des nouvelles versions, qu'on peut couper ici avant d'installer. Tant que le
# bandeau est là, Mindset ne la lance pas tout seul (accueil.ps1, Invoke-Actualiser).
$ui.BienvenueVerif.IsChecked = Test-VerifVersionsActive
$ui.BienvenueVerif.Add_Click({ Set-VerifVersions ([bool]$this.IsChecked); Update-ReglagesMaj })
$ui.LienReseauBienvenue.Add_Click({ Open-PageConfidentialite '' })
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
$ui.BtnBienvenuePlusTard.Add_Click({ $ui.Bienvenue.Visibility = 'Collapsed'; $script:AttenteBienvenue = $false })

# Mise à jour de Mindset (mindset.ps1) : le bandeau de l'accueil
$ui.BtnMajMindset.Add_Click({ Start-MajMindset })
$ui.BtnMajFermer.Add_Click({ $ui.MajBandeau.Visibility = 'Collapsed' })
Show-ResultatMajMindset

# ---------------------------------------------------------------------------
# Consommation : ce que consomme toute la suite (mémoire et processeur), comme le Gestionnaire des tâches, et le détail :
# Mindset, chaque appli ouverte (ses programmes, trouvés par leur chemin), le WebView2 de la suite (les msedgewebview2.exe
# qui utilisent un dossier de données WebView2 de la suite) et les programmes d'aide lancés depuis les dossiers de la suite.
# Mesuré toutes les 2 secondes, SEULEMENT quand l'onglet est à l'écran (page Paramètres ou écran de la console) ; une
# mesure prend quelques millisecondes (MSProcessus.Mesurer, natif.cs : un seul relevé des processus de Windows).
# ---------------------------------------------------------------------------
$script:ConsoEtat = $null
$script:ConsoPremiere = $true
$NomAideConso = 'Programmes d''aide'
$NomWebViewConso = 'WebView2 de la suite'
function Format-MemoireConso([long]$Octets) {
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $mo = $Octets / 1MB
    if ($mo -lt 1000) { return "$([math]::Round($mo).ToString('0', $fr)) Mo" }
    "$([math]::Round($mo / 1024, 1).ToString('0.#', $fr)) Go"
}
function Format-ProcesseurConso([double]$Pourcent) {
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    if ($Pourcent -lt 10) { "$([math]::Round($Pourcent, 1).ToString('0.#', $fr)) %" } else { "$([math]::Round($Pourcent).ToString('0', $fr)) %" }
}
function Measure-ConsoSuite {
    $noms = New-Object Collections.Generic.List[string]; $dossiers = New-Object Collections.Generic.List[string]
    $marqueurs = New-Object Collections.Generic.List[string]
    foreach ($m in @($ConsoleWebviewCommun, (Join-Path $SuiteDir 'WebView2'), $ConsoleWebviewPropre)) { if ($m) { $marqueurs.Add($m.TrimEnd('\') + '\') } }
    # Chaque appli : son dossier des programmes ET son dossier de données (ses programmes d'aide y tournent, parfois sous le
    # nom Mindset.exe : Evermind voix\Mindset.exe...) ; puis le reste des dossiers de la suite. Mindset lui-même : seulement
    # ce processus et son propre dossier (MSProcessus.Mesurer), jamais un Mindset.exe d'ailleurs.
    foreach ($a in $Applis) {
        $i = Get-Installation $a
        if ($i -and $i.Dossier) { $noms.Add($a.Nom); $dossiers.Add($i.Dossier) }
        foreach ($d in @((Get-DossierDonnees $a), $a.Donnees) | Select-Object -Unique) {
            if (-not $d -or $d.TrimEnd('\') -ieq $SuiteDir.TrimEnd('\')) { continue }
            $noms.Add($(if ($i) { $a.Nom } else { $NomAideConso })); $dossiers.Add($d)
            $marqueurs.Add((Join-Path $d 'ecran-webview') + '\')   # (l'ancien dossier WebView2 de Nevermind)
        }
    }
    foreach ($d in @($SuiteDir, $RacineProgrammes)) { if ($d) { $noms.Add($NomAideConso); $dossiers.Add($d) } }
    $chrono = [Diagnostics.Stopwatch]::StartNew()
    $parties = [MSProcessus]::Mesurer($PID, 'Mindset', $MonDossier, $noms.ToArray(), $dossiers.ToArray(), $NomWebViewConso, $marqueurs.ToArray())
    $chrono.Stop()
    $premiere = $script:ConsoPremiere; $script:ConsoPremiere = $false
    if (-not $script:ConsoMesureNotee) { $script:ConsoMesureNotee = $true; Write-Log "Consommation de la suite mesurée en $($chrono.ElapsedMilliseconds) ms" }
    $memoire = 0L; $cpu = 0.0
    $lignes = @(foreach ($p in $parties) {
        if (-not $p.Nombre) { continue }
        $memoire += $p.Memoire; $cpu += $p.Processeur
        $detail = if ($p.Nom -eq 'Mindset') { 'le portail' } elseif ($p.Nom -eq $NomWebViewConso) { 'l''affichage de la console et des écrans' } elseif ($p.Nom -eq $NomAideConso) { 'lancés depuis les dossiers de la suite' } else { 'ouvert' }
        if ($p.Nombre -gt 1) { $detail = "$detail, $($p.Nombre) programmes" }
        [ordered]@{ nom = $p.Nom; detail = $detail; memoire = (Format-MemoireConso $p.Memoire); processeur = $(if ($premiere) { '...' } else { Format-ProcesseurConso $p.Processeur }) }
    })
    $script:ConsoEtat = [ordered]@{ memoire = (Format-MemoireConso $memoire); processeur = $(if ($premiere) { '...' } else { Format-ProcesseurConso $cpu }); lignes = $lignes }
}
# L'onglet est-il à l'écran ? (page Paramètres d'avant, ou Paramètres dans l'écran de la console)
function Test-ConsoVisible {
    $Window.IsVisible -and $Window.WindowState -ne 'Minimized' -and $script:OngletParametres -eq 'conso' -and
        ($script:PageCourante -eq 'parametres' -or ($script:Console.Parametres -and $script:PageCourante -eq 'accueil'))
}
function Update-ConsoPage {
    $e = $script:ConsoEtat
    if (-not $e) { return }
    $ui.ConsoTotal.Text = "Mémoire utilisée par la suite : $($e.memoire)"
    $ui.ConsoProcesseur.Text = "Processeur : $($e.processeur) de l'ordinateur"
    $ui.ConsoDetail.Children.Clear()
    foreach ($l in $e.lignes) {
        $ligne = New-Object System.Windows.Controls.DockPanel
        $ligne.Margin = '0,0,0,8'; $ligne.Width = 520; $ligne.HorizontalAlignment = 'Left'
        $chiffres = New-Text "$($l.memoire)   ·   $($l.processeur)" 13 '#ECEAF7'
        [System.Windows.Controls.DockPanel]::SetDock($chiffres, 'Right')
        [void]$ligne.Children.Add($chiffres)
        $txt = New-Object System.Windows.Controls.StackPanel; $txt.Margin = '0,0,16,0'
        [void]$txt.Children.Add((New-Text $l.nom 13 '#ECEAF7' 'SemiBold'))
        [void]$txt.Children.Add((New-Text $l.detail 11.5 '#6F6894'))
        [void]$ligne.Children.Add($txt)
        [void]$ui.ConsoDetail.Children.Add($ligne)
    }
}
$script:ConsoTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ConsoTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:ConsoTimer.Add_Tick({
    if (-not (Test-ConsoVisible)) { $script:ConsoTimer.Stop(); return }
    try { Measure-ConsoSuite } catch { Write-Log "Consommation non mesurée : $_"; return }
    if ($script:PageCourante -eq 'parametres') { Update-ConsoPage }
    elseif (Get-Command Send-ParametresConsole -ErrorAction SilentlyContinue) { Send-ParametresConsole }
})
# L'onglet s'affiche : une première mesure tout de suite (le processeur arrive à la suivante), puis toutes les 2 secondes
function Start-ConsoSuite {
    if ($script:ConsoTimer.IsEnabled) { return }
    $script:ConsoPremiere = $true
    try { Measure-ConsoSuite } catch { Write-Log "Consommation non mesurée : $_" }
    Update-ConsoPage
    $script:ConsoTimer.Start()
}
# (Mindset réaffiché, ou rouvert depuis la barre des tâches, sur cet onglet : les mesures reprennent)
$Window.Add_IsVisibleChanged({ if (Test-ConsoVisible) { Start-ConsoSuite } })
$Window.Add_StateChanged({ if (Test-ConsoVisible) { Start-ConsoSuite } })

# ---------------------------------------------------------------------------
# Onglets : Général, Apparence, Son, Mises à jour, Consommation, Dossiers
# ---------------------------------------------------------------------------
$OngletsParametres = [ordered]@{ general = 'Général'; apparence = 'Apparence'; son = 'Son'; maj = 'Mises à jour'; conso = 'Consommation'; dossiers = 'Dossiers' }
$PanneauxParametres = @{ general = 'PanGeneral'; apparence = 'PanApparence'; son = 'PanSon'; maj = 'PanMaj'; conso = 'PanConso'; dossiers = 'PanDossiers' }
$script:OngletParametres = 'general'

function Show-OngletParametres([string]$Id) {
    if (-not $OngletsParametres.Contains($Id)) { $Id = 'general' }
    $script:OngletParametres = $Id
    foreach ($b in $ui.OngletsParametres.Children) { $b.Style = $Window.FindResource($(if ($b.Tag -eq $Id) { 'BtnPrimary' } else { 'BtnSecondary' })) }
    foreach ($k in $PanneauxParametres.Keys) { $ui[$PanneauxParametres[$k]].Visibility = if ($k -eq $Id) { 'Visible' } else { 'Collapsed' } }
    if ($Id -eq 'general') { Update-DemarragesParametres }
    if ($Id -eq 'son') { Update-ChoixSon }
    if ($Id -eq 'maj') { Update-ListeVersions; Update-ReglagesMaj }
    if ($Id -eq 'conso') { Start-ConsoSuite }
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
    $etatMindset = if ($script:MajMindset) { @("$($script:MajMindset.Version) prête : voir l'accueil", '#FFB020') } elseif ($script:MajMindsetEnCours) { @('recherche...', '#A6A1BC') }
                   elseif (-not (Test-VerifVersionsActive) -and -not $script:VerifieA) { @('pas encore vérifié', '#A6A1BC') } else { @('à jour', '#3DDC84') }
    [void]$ui.ListeVersions.Children.Add((New-LigneVersion 'Mindset' '#ECEAF7' "version $AppVersion" $etatMindset[0] $etatMindset[1]))
    foreach ($a in $Applis) {
        $i = Get-Installation $a; $p = $script:Publications[$a.Id]
        $inst = if ($i) { "version $(if ($i.Version) { $i.Version } else { '?' })" } else { 'pas installé' }
        $etat = if (-not $p) { @('pas encore vérifié', '#A6A1BC') } elseif ($p.Erreur) { @('GitHub injoignable', '#FF7A9C') }
                elseif ($i -and $i.Version -and (Test-VersionPlusRecente $p.Version $i.Version)) { @("$($p.Version) disponible", '#FFB020') }
                elseif ($i) { @('à jour', '#3DDC84') } else { @("dernière : $($p.Version)", '#A6A1BC') }
        [void]$ui.ListeVersions.Children.Add((New-LigneVersion $a.Nom $a.Couleur $inst $etat[0] $etat[1]))
    }
    # Les dernières mises à jour (mindset.ps1, Read-HistoriqueMaj)
    $h = @(Get-HistoriqueMajAffiche)
    $t = New-Text 'Dernières mises à jour' 17 '#ECEAF7' 'SemiBold'; $t.Margin = '0,18,0,8'
    [void]$ui.ListeVersions.Children.Add($t)
    if (-not $h.Count) { [void]$ui.ListeVersions.Children.Add((New-Text 'Aucune mise à jour pour l''instant.' 13 '#A6A1BC')) }
    foreach ($e in $h) { [void]$ui.ListeVersions.Children.Add((New-LigneVersion $e.nom $e.brut "version $($e.version)" "$($e.quand) · $(if ($e.auto) { 'automatique' } else { 'faite par toi' })" $(if ($e.auto) { '#7FF4FF' } else { '#A6A1BC' }))) }
}
# L'historique tel qu'il s'affiche (ici et dans l'écran de la console) : nom, couleur, version, quand, automatique ou non
function Get-HistoriqueMajAffiche {
    foreach ($e in @((Read-HistoriqueMaj).Liste)) {
        $a = Get-AppliMaj $e.id $e.nom
        $q = Format-QuandMaj $e.quand -Long
        [ordered]@{ nom = $a.Nom; couleur = (ConvertTo-ThemeHex $a.Couleur); brut = $a.Couleur; version = $e.version; quand = $q.Substring(0, 1).ToUpper() + $q.Substring(1); auto = [bool]$e.auto }
    }
}
function Invoke-VerifierMaj {
    Invoke-Actualiser -Clic
    $ui.MajInfo.Text = "Vérifié à $((Get-Date).ToString('HH:mm'))"
    $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromSeconds(4)
    $t.Add_Tick({ $this.Stop(); if ($script:OngletParametres -eq 'maj') { Update-ListeVersions } }); $t.Start()
}
$ui.BtnVerifierMaj.Add_Click({ Invoke-VerifierMaj })

# « Chercher les nouvelles versions » et « Mises à jour automatiques » (cette page, sans la console) : coupée, la
# recherche emporte les mises à jour automatiques, dont l'interrupteur est grisé et expliqué
function Update-ReglagesMaj {
    $verif = Test-VerifVersionsActive
    $ui.VerifVersions.IsChecked = $verif
    $ui.MajAuto.IsChecked = $verif -and (Test-MajAutoActive)
    $ui.MajAuto.IsEnabled = $verif
    $ui.MajAutoNote.Text = if ($verif) { '' } else { 'Les mises à jour automatiques ne peuvent pas tourner tant que la recherche des nouvelles versions est coupée.' }
    $ui.MajTexteVersions.Text = if ($verif) { 'Mindset cherche les nouvelles versions au démarrage puis toutes les heures. Elles sont signées : une version qui ne l''est pas n''est jamais installée.' }
                                else { 'Mindset ne cherche plus les nouvelles versions tout seul : clique sur « Vérifier maintenant » quand tu veux. Elles sont signées : une version qui ne l''est pas n''est jamais installée.' }
    $ui.BienvenueVerif.IsChecked = $verif
}
$ui.VerifVersions.Add_Click({ Set-VerifVersions ([bool]$this.IsChecked); Update-ReglagesMaj })
$ui.MajAuto.Add_Click({ Set-Setting 'MajAuto' ([bool]$this.IsChecked); Write-Log "Mises à jour automatiques : $(if ([bool]$this.IsChecked) { 'oui' } else { 'non' })" })
Update-ReglagesMaj

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
    # Retour depuis l'accueil d'une appli (touche B ou Échap dans l'appli) : le menu, la console
    if ($t -eq 'menu') { Show-Fenetre; Show-Page 'accueil'; return }
    if ($t -notmatch '^parametres(:(general|apparence|son|maj|conso|dossiers))?$') { return }
    $onglet = if ($Matches[2]) { $Matches[2] } else { 'general' }
    Show-Fenetre
    Show-OngletParametres $onglet   # (d'abord l'onglet : avec la console, Show-Page les ouvre dans son écran sur cet onglet)
    Show-Page 'parametres'
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

# ---------------------------------------------------------------------------
# Les Paramètres dans l'écran de la console (console\scene.html, dans la DA des pages de Nevermind) : la page les
# dessine avec ce que Mindset lui envoie (Get-EtatParametres) et renvoie chaque geste (Invoke-ReglageConsole), qui
# appelle les mêmes fonctions que la page ci-dessus. Celle-ci reste derrière, cachée : elle ne sert plus que sans la
# console (pas de WebView2, ou Animations : aucune). Ses textes d'information (ThemeInfo, AnimationsInfo, MajInfo)
# sont repris tels quels.
# ---------------------------------------------------------------------------
$script:ThemesConsole = $null; $script:ImagesThemesConsole = @{}; $script:AppareilsConsole = $null

# L'image d'un thème perso sur sa carte (sa mascotte ou son logo, la première image) : en PNG dans le texte envoyé
function Get-ImageThemeConsole($Pack) {
    if (-not $Pack) { return '' }
    if ($script:ImagesThemesConsole.ContainsKey($Pack.Id)) { return $script:ImagesThemesConsole[$Pack.Id] }
    $url = ''
    try {
        $image = if ($Pack.Mascotte) { @($Pack.Mascotte.File, $Pack.Mascotte.Frames) } elseif ($Pack.Logo) { @($Pack.Logo, $Pack.LogoFrames) } else { $null }
        if ($image) {
            $src = (Get-SheetFrames $image[0] $image[1])[0]
            if ($Pack.Mascotte -and $Pack.Logo -and $src.PixelWidth -gt 2 * $src.PixelHeight) { $src = (Get-SheetFrames $Pack.Logo $Pack.LogoFrames)[0] }   # (comme sur la carte ci-dessus)
            $k = [math]::Min(1.0, 96.0 / [math]::Max(1, $src.PixelHeight))
            if ($k -lt 1) { $src = New-Object System.Windows.Media.Imaging.TransformedBitmap $src, (New-Object System.Windows.Media.ScaleTransform $k, $k) }
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($src))
            $ms = New-Object IO.MemoryStream; $enc.Save($ms)
            $url = 'data:image/png;base64,' + [Convert]::ToBase64String($ms.ToArray())
        }
    } catch {}
    $script:ImagesThemesConsole[$Pack.Id] = $url
    $url
}

# Les thèmes proposés (les mêmes que les cartes ci-dessus : ceux de base, puis les thèmes perso importés)
function Get-ThemesConsole {
    foreach ($id in @($AppThemes.Keys | Where-Object { -not $AppThemes[$_].Pack })) { $th = $AppThemes[$id]
        [ordered]@{ cle = $id; nom = [string]$th.Name; desc = [string]$th.Desc; fond = (ConvertTo-ThemeHex '#0C0920' $id); couleurs = @([string]$th.P, [string]$th.S, [string]$th.T); image = '' } }
    foreach ($pk in @(Get-ThemePacks)) { $th = $AppThemes[$pk.Base]
        [ordered]@{ cle = "pack:$($pk.Id)"; nom = [string]$pk.Name; desc = [string]$pk.Desc; fond = (ConvertTo-ThemeHex '#0C0920' $pk.Base); couleurs = @([string]$th.P, [string]$th.S, [string]$th.T); image = (Get-ImageThemeConsole $pk) } }
}

# Les micros et les sorties du PC (relus en ouvrant l'onglet Son et avec « Actualiser la liste », comme ci-dessus)
function Update-AppareilsConsole { $script:AppareilsConsole = @{ micro = @([MSAudio]::Micros()); casque = @([MSAudio]::Sorties()) } }
function Get-ChoixSonConsole($Noms, [string]$Choisi) {
    [ordered]@{ cle = ''; nom = 'Celui de Windows'; oui = (-not $Choisi) }
    foreach ($n in @($Noms) | Select-Object -Unique) { if ($n) { [ordered]@{ cle = [string]$n; nom = (Get-NomAppareil $n); oui = ($n -eq $Choisi) } } }
    if ($Choisi -and @($Noms) -notcontains $Choisi) { [ordered]@{ cle = $Choisi; nom = "$(Get-NomAppareil $Choisi) (débranché)"; oui = $true } }
}

# Les applis dont on règle le démarrage (les mêmes que dans l'onglet Général ci-dessus)
function Get-ApplisDemarrage { @($Applis | Where-Object { (Get-Installation $_) -and (-not (Test-AppliAdmin $_) -or $MindsetAdmin) }) }

# Tout ce que l'écran des Paramètres affiche, en JSON. Les images des thèmes perso partent à part (Get-ImagesThemesConsole) :
# ce texte-ci est refait toutes les 1,5 s tant que les Paramètres sont ouverts, il reste léger.
function Get-EtatParametres {
    if ($null -eq $script:ThemesConsole) { $script:ThemesConsole = @(Get-ThemesConsole) }
    if ($null -eq $script:AppareilsConsole) { Update-AppareilsConsole }
    if ($script:OngletParametres -eq 'conso' -and -not $script:ConsoTimer.IsEnabled -and (Test-ConsoVisible)) { Start-ConsoSuite }
    $son = Get-SuiteSon
    $verif = Test-VerifVersionsActive
    $etatMindset = if ($script:MajMindset) { @("$($script:MajMindset.Version) prête", 'attention') } elseif ($script:MajMindsetEnCours) { @('recherche...', '') }
                   elseif (-not $verif -and -not $script:VerifieA) { @('pas encore vérifié', '') } else { @('à jour', 'ok') }
    $etat = [ordered]@{
        version = $AppVersion
        general = [ordered]@{
            reduire = [bool](Get-Setting 'ReduireHorloge' $true); fermeture = [string](Get-Setting 'Fermeture' 'demander'); windows = [bool](Get-LancerAvecWindows)
            applis = @(foreach ($a in Get-ApplisDemarrage) { [ordered]@{ id = $a.Id; nom = $a.Nom; oui = [bool](Get-DemarrageAppli $a.Id); note = $(if ($a.Rappels) { 'Sinon ses rappels ne sonnent pas.' } else { '' }) } })
        }
        apparence = [ordered]@{
            actuel = [string]$ThemeSetting; info = [string]$ui.ThemeInfo.Text
            themes = @(foreach ($t in $script:ThemesConsole) { [ordered]@{ cle = $t.cle; nom = $t.nom; desc = $t.desc; fond = $t.fond; couleurs = $t.couleurs; image = [bool]$t.image } })
            animations = [string](Get-Setting 'Animations' 'completes'); animInfo = [string]$ui.AnimationsInfo.Text
        }
        son = [ordered]@{ micros = @(Get-ChoixSonConsole $script:AppareilsConsole.micro ([string]$son.Micro)); casques = @(Get-ChoixSonConsole $script:AppareilsConsole.casque ([string]$son.Casque)) }
        maj = [ordered]@{
            auto = [bool](Test-MajAutoActive); verif = [bool]$verif
            mindset = [ordered]@{ texte = $etatMindset[0]; ton = $etatMindset[1] }; prete = $(if ($script:MajMindset) { [string]$script:MajMindset.Version } else { '' }); info = [string]$ui.MajInfo.Text
            applis = @(foreach ($a in $Applis) {
                $i = Get-Installation $a; $p = $script:Publications[$a.Id]
                $inst = if ($i) { "version $(if ($i.Version) { $i.Version } else { '?' })" } else { 'pas installé' }
                $e = if (-not $p) { @('pas encore vérifié', '') } elseif ($p.Erreur) { @('GitHub injoignable', 'urgent') }
                     elseif ($i -and $i.Version -and (Test-VersionPlusRecente $p.Version $i.Version)) { @("$($p.Version) disponible", 'attention') }
                     elseif ($i) { @('à jour', 'ok') } else { @("dernière : $($p.Version)", '') }
                [ordered]@{ nom = $a.Nom; couleur = (ConvertTo-ThemeHex $a.Couleur); version = $inst; texte = $e[0]; ton = $e[1] } })
            historique = @(Get-HistoriqueMajAffiche)
        }
        dossiers = [ordered]@{ texte = [string]$ui.DossiersTexte.Text }
        conso = $script:ConsoEtat   # (mesuré seulement quand l'onglet Consommation est à l'écran)
    }
    ConvertTo-Json -InputObject $etat -Depth 6 -Compress
}
function Get-ImagesThemesConsole {
    if ($null -eq $script:ThemesConsole) { $script:ThemesConsole = @(Get-ThemesConsole) }
    $m = [ordered]@{}
    foreach ($t in $script:ThemesConsole) { if ($t.image) { $m[$t.cle] = $t.image } }
    ConvertTo-Json -InputObject $m -Compress
}

# Un geste dans l'écran des Paramètres : seulement des réglages connus, avec des valeurs vérifiées
function Invoke-ReglageConsole($M) {
    $quoi = [string]$M.quoi; $v = $M.valeur
    switch ($quoi) {
        'onglet'      { if ($OngletsParametres.Contains([string]$v)) { $script:OngletParametres = [string]$v; if ($v -eq 'son') { Update-AppareilsConsole } } }
        'reduire'     { Set-Setting 'ReduireHorloge' ([bool]$v); $ui.ReduireHorloge.IsChecked = [bool]$v }
        'fermeture'   { if ([string]$v -in 'demander', 'reduire', 'quitter') { Set-Setting 'Fermeture' ([string]$v); Update-ReglageFermeture } }
        'windows'     { Set-LancerAvecWindows ([bool]$v) }
        'majauto'     { Set-Setting 'MajAuto' ([bool]$v); Write-Log "Mises à jour automatiques : $(if ([bool]$v) { 'oui' } else { 'non' })"; Update-ReglagesMaj }
        'verif'       { Set-VerifVersions ([bool]$v); Update-ReglagesMaj }
        'confidentialite' { Open-PageConfidentialite '' }
        'demarrage'   {
            $a = Get-ApplisDemarrage | Where-Object { $_.Id -eq [string]$M.id } | Select-Object -First 1
            if ($a) { Set-DemarrageAppli $a.Id ([bool]$v); foreach ($x in $script:Interrupteurs) { if ($x.Tag -eq $a.Id) { $x.IsChecked = [bool]$v } } }
        }
        'theme'       { if ($script:ThemesConsole | Where-Object { $_.cle -eq [string]$v }) { Select-ThemeSuite ([string]$v) } }
        'importer'    { Import-ThemeSuite; Send-ImagesThemesConsole }
        'supprimerTheme' { if ([string]$v -cmatch '^pack:([a-z0-9-]{1,40})$') { Confirm-SuppressionTheme $Matches[1] } }   # (seulement un thème perso installé : vérifié là)
        'animations'  {
            if ([string]$v -notin 'completes', 'express', 'aucune') { return }
            Set-ReglageAnimations ([string]$v)
            foreach ($rb in $ui.ChoixAnimations.Children) { $rb.IsChecked = ($rb.Tag -eq [string](Get-Setting 'Animations' 'completes')) }
            # Sans 3D, plus de console : la page des Paramètres d'avant prend le relais, sur Apparence (pour revenir en arrière)
            if (-not $script:Console.Possible) { $script:Console.Parametres = $false; Show-OngletParametres 'apparence'; Show-Page 'parametres'; return }
        }
        { $_ -in 'micro', 'casque' } { Set-SuiteSon $quoi ([string]$v) }
        'sonActualiser'     { Update-AppareilsConsole }
        'verifier'          { Invoke-VerifierMaj }
        'majMindset'        { Start-MajMindset }
        'dossierProgrammes' { Open-DossierProgrammes }
        'dossierDonnees'    { Open-DossierDonnees }
        'desinstaller'      { Confirm-DesinstallMindset }
    }
    Send-ParametresConsole -Force
}
