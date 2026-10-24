# Mindset : la jauge de chargement d'une appli, le temps qu'elle s'ouvre dans son onglet.
# La même que l'écran de chargement de Nevermind :
#   thème de base   la lettre de l'appli (le N de Nevermind, le E d'Evermind) qui « glitche » au centre d'un anneau
#                   qui se remplit (cyan vers magenta), avec un halo qui respire, une comète et une ligne de balayage
#   thème perso     le personnage du thème (« Loader » du pack, celui de l'écran de chargement de Nevermind) au-dessus
#                   d'une barre qui se remplit ; il court avec elle, ou reste au milieu (Static)
# Mindset ne sait pas où en est l'appli : la jauge avance selon la durée de sa dernière ouverture (retenue à chaque
# fois), ralentit vers la fin, et l'appli prend sa place dès que sa fenêtre est accrochée.
# Chargé par Mindset.ps1 après logo.ps1, avant integration.ps1.

$script:Jauge = $null
$script:JaugeDureesDefaut = @{ nevermind = 20.0; evermind = 10.0 }

# Une lettre de la police, centrée dans un carré de $Size (pour une appli qui n'a pas encore sa lettre dessinée)
function Get-LettreTexte([string]$Lettre, [double]$Size) {
    $tf = New-Object System.Windows.Media.Typeface ((New-Object System.Windows.Media.FontFamily 'Segoe UI')), ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Black), ([System.Windows.FontStretches]::Normal)
    $ft = New-Object System.Windows.Media.FormattedText $Lettre, ([Globalization.CultureInfo]::InvariantCulture), ([System.Windows.FlowDirection]::LeftToRight), $tf, ($Size * 0.66), ([System.Windows.Media.Brushes]::Black), 1.0
    $g = $ft.BuildGeometry((New-Object System.Windows.Point 0, 0))
    $b = $g.Bounds
    $g.Transform = New-Object System.Windows.Media.TranslateTransform ((($Size - $b.Width) / 2) - $b.X), ((($Size - $b.Height) / 2) - $b.Y)
    $g = $g.GetFlattenedPathGeometry()
    $g.Freeze()
    $g
}

# La lettre de l'appli, au même dessin que son logo (un trait épais aux bouts arrondis)
function Get-LettreAppli([string]$Id, [double]$Size) {
    switch ($Id) {
        'nevermind' {
            $x = $Size * 0.22; $y = $Size * 0.2; $w = $Size * 0.56; $h = $Size * 0.6; $ep = 0.19
            $d = "M $x,$($y + $h) L $x,$y L $($x + $w),$($y + $h) L $($x + $w),$y"
        }
        'evermind' {
            $x = $Size * 0.27; $y = $Size * 0.2; $w = $Size * 0.46; $h = $Size * 0.6; $ep = 0.17
            $d = "M $($x + $w),$y L $x,$y L $x,$($y + $h) L $($x + $w),$($y + $h) M $x,$($y + $h / 2) L $($x + $w * 0.82),$($y + $h / 2)"
        }
        default {
            # Une autre appli de apps.json : son logo (champ « logo », un tracé sur une grille de 100), sinon la première
            # lettre de son nom, en très gras ; sinon le M de Mindset
            $a = Get-Appli $Id
            if ($a -and $a.Logo) {
                $k = $Size / 100
                $d = [regex]::Replace($a.Logo, '\d+(\.\d+)?', { param($m) ([double]::Parse($m.Value, [Globalization.CultureInfo]::InvariantCulture) * $k).ToString([Globalization.CultureInfo]::InvariantCulture) })
                $ep = $a.LogoEpaisseur
            } else {
                if ($a -and $a.Nom) { return (Get-LettreTexte $a.Nom.Substring(0, 1).ToUpperInvariant() $Size) }
                return (Get-MindsetM $Size)
            }
        }
    }
    $pen = New-Object System.Windows.Media.Pen ([System.Windows.Media.Brushes]::Black), ($Size * $ep)
    $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
    $wide = [System.Windows.Media.Geometry]::Parse($d).GetWidenedPathGeometry($pen)
    $g = [System.Windows.Media.Geometry]::Combine($wide, $wide, 'Union', $null)
    $g.Freeze()
    $g
}

# Le personnage de chargement du thème perso : dans le réglage de Mindset du pack, sinon dans celui de Nevermind
# (les packs de la suite le déclarent pour Nevermind ; son image est aussi dans le dossier du pack de Mindset)
function Get-JaugePack {
    if (-not $ThemePack) { return $null }
    if ($script:JaugePackLue) { return $script:JaugePack }
    $script:JaugePackLue = $true; $script:JaugePack = $null
    foreach ($f in @((Join-Path $ThemePack.Dir 'pack.json'), (Join-Path $SuiteDir "Nevermind\packs\$($ThemePack.Id)\pack.json"))) {
        try { $L = ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json).Loader } catch { continue }
        if (-not $L -or -not (Test-NomFichierPack $L.File)) { continue }
        $img = @((Join-Path $ThemePack.Dir ([string]$L.File)), (Join-Path (Split-Path $f) ([string]$L.File))) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $img) { continue }
        $script:JaugePack = @{ File = $img; Frames = [math]::Max(1, [int]$L.Frames); Delay = [math]::Max(30, [int]$L.Delay); Flip = [bool]$L.Flip
            Static = [bool]$L.Static; Height = [double]$L.Height; Gap = [math]::Max(0, [int]$L.Gap) }
        break
    }
    $script:JaugePack
}

# Animation en boucle de la jauge, notée pour être arrêtée avec elle
function Start-JaugeBoucle($Cible, $Propriete, [double]$De, [double]$A, [int]$Ms, [bool]$Retour) {
    if ($EnTest -or -not [System.Windows.SystemParameters]::ClientAreaAnimation) { return }
    $an = New-Object System.Windows.Media.Animation.DoubleAnimation
    $an.From = $De; $an.To = $A; $an.AutoReverse = $Retour
    $an.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms))
    $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    if ($Retour) { $e = New-Object System.Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $an.EasingFunction = $e }
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($an, 30)
    # (par une horloge, arrêtée puis retirée avec la jauge : un simple BeginAnimation(..., $null) laissait WPF compter le
    # temps, et Mindset prenait du processeur en continu après chaque ouverture d'appli)
    $h = $an.CreateClock()
    $Cible.ApplyAnimationClock($Propriete, $h)
    [void]$script:Jauge.Boucles.Add(@{ T = $Cible; P = $Propriete; H = $h })
}

function New-JaugeTexte([double]$Taille) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = '0 %'; $t.FontSize = $Taille; $t.FontWeight = 'Bold'; $t.Foreground = Get-Brush '#FFFFFF'; $t.TextAlignment = 'Center'
    $t.FontFamily = New-Object System.Windows.Media.FontFamily $(if ($PackFont) { "$PackFont, Cascadia Code, Consolas" } else { 'Cascadia Code, Consolas' })
    $t
}

# Anneau de Nevermind, avec la lettre de l'appli
function New-JaugeAnneau($Hote, [string]$Id, [bool]$Plein = $false) {
    $S = 260.0; $C = 130.0
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $S; $cv.Height = $S
    # Halo qui respire
    $halo = New-Object System.Windows.Shapes.Ellipse
    $halo.Width = 220; $halo.Height = 220
    $rb = New-Object System.Windows.Media.RadialGradientBrush
    foreach ($arret in @(@('#4000E5FF', 0), @('#1AFF2EB5', 0.6), @('#00FF2EB5', 1))) { [void]$rb.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Couleur $arret[0]), $arret[1])) }
    $halo.Fill = $rb
    $halo.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
    $hs = New-Object System.Windows.Media.ScaleTransform 1, 1
    $halo.RenderTransform = $hs
    [System.Windows.Controls.Canvas]::SetLeft($halo, 20); [System.Windows.Controls.Canvas]::SetTop($halo, 20)
    [void]$cv.Children.Add($halo)
    Start-JaugeBoucle $hs ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 0.85 1.1 1600 $true
    Start-JaugeBoucle $hs ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 0.85 1.1 1600 $true
    # Anneau de fond et anneau de progression
    [void]$cv.Children.Add((New-LogoArc $C 112 -90 359.9 (Get-Brush '#16FFFFFF') 6))
    $arc = New-LogoArc $C 112 -90 $(if ($Plein) { 359.9 } else { 0.1 }) (New-LinearBrush @($LogoCyan, $LogoMagenta) 0 0 1 1) 6
    $arc.Effect = New-Glow $LogoCyan 14 0.7
    [void]$cv.Children.Add($arc)
    # Comète magenta qui tourne en sens inverse
    $com = New-Object System.Windows.Controls.Canvas
    $com.Width = $S; $com.Height = $S
    $rot = New-Object System.Windows.Media.RotateTransform 0, $C, $C
    $com.RenderTransform = $rot
    $col = Get-Couleur $LogoMagenta
    $cb = New-Object System.Windows.Media.LinearGradientBrush
    $cb.StartPoint = [System.Windows.Point]::new(0, 1); $cb.EndPoint = [System.Windows.Point]::new(1, 0)
    [void]$cb.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0, $col.R, $col.G, $col.B), 0))
    [void]$cb.GradientStops.Add([System.Windows.Media.GradientStop]::new($col, 1))
    [void]$com.Children.Add((New-LogoArc $C 124 0 60 $cb 2))
    [void]$cv.Children.Add($com)
    Start-JaugeBoucle $rot ([System.Windows.Media.RotateTransform]::AngleProperty) 360 0 2600 $false
    # Au centre : l'icône de l'appli dans le thème perso (celle de son onglet), sinon sa lettre
    $mark = $null
    $icone = if ($Plein -and $ThemePack -and $ThemePack.TabIcons.ContainsKey($Id)) { $ThemePack.TabIcons[$Id] } else { $null }
    if ($icone) {
        try {
            $frames = Get-SheetFrames $icone.File $icone.Frames
            $img = New-Object System.Windows.Controls.Image
            $img.Width = 112; $img.Height = 112; $img.Stretch = 'Uniform'; $img.Source = $frames[0]
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, $(if ($frames[0].PixelHeight -le 56) { 'NearestNeighbor' } else { 'HighQuality' }))
            $mv = New-Object System.Windows.Media.TranslateTransform; $img.RenderTransform = $mv
            [System.Windows.Controls.Canvas]::SetLeft($img, $C - 56); [System.Windows.Controls.Canvas]::SetTop($img, $C - 56)
            [void]$cv.Children.Add($img)
            Start-JaugeBoucle $mv ([System.Windows.Media.TranslateTransform]::YProperty) 0 -6 900 $true   # (il lévite doucement)
            if ($frames.Count -gt 1 -and -not $EnTest) {
                $ti = New-Object System.Windows.Threading.DispatcherTimer
                $ti.Interval = [TimeSpan]::FromMilliseconds($icone.Delay)
                $ti.Tag = @{ Img = $img; Frames = $frames; Frame = 0 }
                $ti.Add_Tick({ param($s) $x = $s.Tag; $x.Frame = ($x.Frame + 1) % $x.Frames.Count; $x.Img.Source = $x.Frames[$x.Frame] })
                $ti.Start()
                [void]$script:Jauge.Timers.Add($ti)
            }
        } catch { $icone = $null }
    }
    if (-not $icone) {
        $mark = New-MindsetMark 128 (Get-LettreAppli $Id 128)
        [System.Windows.Controls.Canvas]::SetLeft($mark.Root, $C - 64); [System.Windows.Controls.Canvas]::SetTop($mark.Root, $C - $(if ($Plein) { 64 } else { 72 }))
        [void]$cv.Children.Add($mark.Root)
    }
    # Pourcentage sous la lettre (pas sur l'écran « Ouvrir » : l'anneau y est plein)
    $txt = New-JaugeTexte 18
    if ($Plein) { $txt.Visibility = 'Collapsed' }
    $txt.Width = $S
    [System.Windows.Controls.Canvas]::SetTop($txt, $C + 58)
    [void]$cv.Children.Add($txt)
    # Ligne de balayage
    $scanHote = New-Object System.Windows.Controls.Canvas
    $scanHote.Width = $S; $scanHote.Height = $S
    $scanHote.Clip = New-Object System.Windows.Media.EllipseGeometry ([System.Windows.Point]::new($C, $C)), 106, 106
    $scan = New-Object System.Windows.Shapes.Rectangle
    $scan.Width = $S; $scan.Height = 3
    $scan.Fill = New-LinearBrush @('#0000E5FF', '#8000E5FF', '#0000E5FF') 0 0 1 0
    $st = New-Object System.Windows.Media.TranslateTransform 0, -10
    $scan.RenderTransform = $st
    [void]$scanHote.Children.Add($scan)
    [void]$cv.Children.Add($scanHote)
    Start-JaugeBoucle $st ([System.Windows.Media.TranslateTransform]::YProperty) 20 240 2200 $false
    [void]$Hote.Children.Add($cv)
    $script:Jauge.Arc = $arc; $script:Jauge.Texte = $txt; $script:Jauge.Marque = $mark
    # Petits sauts réguliers de la lettre
    if (-not $EnTest) {
        $gt = New-Object System.Windows.Threading.DispatcherTimer
        $gt.Interval = [TimeSpan]::FromMilliseconds(1300)
        $gt.Add_Tick({ if ($script:Jauge -and $script:Jauge.Marque) { Start-LogoGlitch $script:Jauge.Marque 260 } })
        $gt.Start()
        [void]$script:Jauge.Timers.Add($gt)
    }
}

# Personnage du thème perso au-dessus d'une barre
function New-JaugePersonnage($Hote, $L) {
    $frames = Get-SheetFrames $L.File $L.Frames
    $fw = $frames[0].PixelWidth; $fh = $frames[0].PixelHeight
    $W = 400.0; $barY = 168.0 + $L.Gap
    $sh = if ($L.Height -gt 0) { $L.Height } else { 120.0 }; $sw = $sh * $fw / $fh
    if ($sw -gt $W) { $sw = $W; $sh = $sw * $fh / $fw }
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $W; $cv.Height = 210 + $L.Gap
    $ombre = New-Object System.Windows.Shapes.Ellipse
    $ombre.Width = $sw * 0.6; $ombre.Height = 8; $ombre.Fill = Get-Brush '#55000000'
    [System.Windows.Controls.Canvas]::SetTop($ombre, $barY - 7)
    if ($L.Static) { $ombre.Visibility = 'Collapsed' }
    [void]$cv.Children.Add($ombre)
    $img = New-Object System.Windows.Controls.Image
    $img.Width = $sw; $img.Height = $sh; $img.Source = $frames[0]
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, $(if ($sh -ge $fh) { 'NearestNeighbor' } else { 'HighQuality' }))
    if ($L.Flip) { $img.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5); $img.RenderTransform = New-Object System.Windows.Media.ScaleTransform -1, 1 }
    [System.Windows.Controls.Canvas]::SetTop($img, $barY - $sh + 4 - $L.Gap)
    [void]$cv.Children.Add($img)
    # Image fixe : le personnage sautille, son ombre rétrécit à chaque saut
    if ($L.Frames -le 1) {
        $hop = New-Object System.Windows.Media.TranslateTransform
        $grp = New-Object System.Windows.Media.TransformGroup
        if ($img.RenderTransform -is [System.Windows.Media.ScaleTransform]) { $grp.Children.Add($img.RenderTransform) }
        $grp.Children.Add($hop)
        $img.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5); $img.RenderTransform = $grp
        Start-JaugeBoucle $hop ([System.Windows.Media.TranslateTransform]::YProperty) 0 -22 260 $true
        $shs = New-Object System.Windows.Media.ScaleTransform 1, 1; $ombre.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5); $ombre.RenderTransform = $shs
        Start-JaugeBoucle $shs ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1 0.6 260 $true
    }
    # Barre : piste translucide et remplissage aux couleurs du thème
    $piste = New-Object System.Windows.Controls.Border
    $piste.Width = $W; $piste.Height = 14; $piste.CornerRadius = 7
    $piste.Background = Get-Brush '#1EFFFFFF'; $piste.BorderBrush = Get-Brush '#26FFFFFF'; $piste.BorderThickness = 1
    [System.Windows.Controls.Canvas]::SetTop($piste, $barY)
    [void]$cv.Children.Add($piste)
    $rempli = New-Object System.Windows.Controls.Border
    $rempli.Width = 14; $rempli.Height = 14; $rempli.CornerRadius = 7
    $rempli.Background = $Window.FindResource('AccentBg')
    $rempli.Effect = New-Glow '#00E5FF' 14 0.7
    [System.Windows.Controls.Canvas]::SetTop($rempli, $barY)
    [void]$cv.Children.Add($rempli)
    $txt = New-JaugeTexte 15
    $txt.Width = $W
    [System.Windows.Controls.Canvas]::SetTop($txt, $barY + 22)
    [void]$cv.Children.Add($txt)
    [void]$Hote.Children.Add($cv)
    $script:Jauge.Perso = @{ Img = $img; Ombre = $ombre; Rempli = $rempli; W = $W; LargeurPerso = $sw; Static = $L.Static; Frames = $frames; Frame = 0 }
    $script:Jauge.Texte = $txt
    # Les images de la course défilent en boucle
    if ($frames.Count -gt 1 -and -not $EnTest) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds($L.Delay)
        $t.Add_Tick({ $P = $script:Jauge.Perso; if ($P) { $P.Frame = ($P.Frame + 1) % $P.Frames.Count; $P.Img.Source = $P.Frames[$P.Frame] } })
        $t.Start()
        [void]$script:Jauge.Timers.Add($t)
    }
}

# Affiche la jauge de l'appli sur sa page (si elle y est déjà, elle continue d'avancer)
function Show-JaugeAppli($Appli, [string]$Texte) {
    if ($script:PageCourante -ne $Appli.Id) { return }
    $ui.PageAppliTitre.Text = $Appli.Nom
    $ui.PageAppliTitre.Foreground = Get-Brush $Appli.Couleur
    $ui.PageAppliTexte.Text = $Texte
    $ui.PageAppliTexte.Visibility = 'Visible'
    $ui.BtnPageAppliIci.Visibility = 'Collapsed'
    $ui.PageAppliEtat.Text = ''
    if ($script:Jauge -and $script:Jauge.Id -eq $Appli.Id -and -not $script:Jauge.Ecran) { return }
    Stop-JaugeAppli
    $i = Get-Integration $Appli.Id
    $script:Jauge = @{ Id = $Appli.Id; Depuis = $i.Depuis; Boucles = (New-Object System.Collections.ArrayList); Timers = (New-Object System.Collections.ArrayList)
        Duree = [double](Get-Setting "Ouverture-$($Appli.Id)" $script:JaugeDureesDefaut[$Appli.Id]) }
    if (-not $script:Jauge.Duree -or $script:Jauge.Duree -lt 2) { $script:Jauge.Duree = 10.0 }
    $hote = $ui.PageAppliJauge
    $hote.Children.Clear()
    $L = Get-JaugePack
    $fait = $false
    if ($L) { try { New-JaugePersonnage $hote $L; $fait = $true } catch { Write-Log "Jauge du thème : $_"; $hote.Children.Clear(); $script:Jauge.Perso = $null } }
    if (-not $fait) { New-JaugeAnneau $hote $Appli.Id }
    $hote.Visibility = 'Visible'
    Update-JaugeAppli
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(60)
    $t.Add_Tick({ if ($Window.IsVisible) { Update-JaugeAppli } })
    $t.Start()
    [void]$script:Jauge.Timers.Add($t)
}

# Progression : 90 % à la durée habituelle (en ralentissant), puis elle s'approche doucement de 99 %
function Update-JaugeAppli {
    $J = $script:Jauge
    if (-not $J -or $J.Ecran) { return }
    $t = ((Get-Date) - $J.Depuis).TotalSeconds
    $k = [math]::Max(0.0, $t / $J.Duree)
    $v = if ($k -lt 1) { 90 * (1 - [math]::Pow(1 - $k, 2)) } else { 90 + 9 * (1 - [math]::Exp(-($k - 1))) }
    $J.Texte.Text = '{0:N0} %' -f $v
    if ($J.Arc) { $J.Arc.Data = Get-ArcGeometry 130 112 -90 ([math]::Max(0.1, [math]::Min(359.9, 3.6 * $v))) }
    if ($J.Perso) {
        $P = $J.Perso
        $w = [math]::Max(14.0, $P.W * $v / 100)
        $P.Rempli.Width = $w
        $x = if ($P.Static) { ($P.W - $P.LargeurPerso) / 2 } else { [math]::Max(0.0, [math]::Min($P.W - $P.LargeurPerso, $w - $P.LargeurPerso * 0.7)) }
        [System.Windows.Controls.Canvas]::SetLeft($P.Img, $x)
        [System.Windows.Controls.Canvas]::SetLeft($P.Ombre, $x + $P.LargeurPerso * 0.2)
    }
}

function Stop-JaugeAppli {
    $J = $script:Jauge
    if (-not $J) { return }
    $script:Jauge = $null
    foreach ($t in $J.Timers) { $t.Stop() }
    foreach ($b in $J.Boucles) { try { $b.H.Controller.Stop(); $b.H.Controller.Remove(); $b.T.ApplyAnimationClock($b.P, $null) } catch {} }
    $ui.PageAppliJauge.Children.Clear()
    $ui.PageAppliJauge.Visibility = 'Collapsed'
}

# L'appli lancée par Mindset s'est affichée : la durée de son ouverture sert à la prochaine jauge
function Save-DureeOuverture($Appli, [datetime]$Depuis) {
    $s = ((Get-Date) - $Depuis).TotalSeconds
    if ($s -ge 1 -and $s -le 120) { Set-Setting "Ouverture-$($Appli.Id)" ([math]::Round($s, 1)) }
}

# Écran de l'appli fermée, réduite ou dans sa propre fenêtre : son logo (l'anneau plein, comme la jauge finie), son nom,
# ce qui se passe, et « Ouvrir » qui la remet dans Mindset
function Show-EcranOuvrir($Appli, [string]$Texte) {
    if ($script:PageCourante -ne $Appli.Id) { return }
    Stop-JaugeAppli
    $ui.PageAppliTitre.Text = $Appli.Nom
    $ui.PageAppliTitre.Foreground = Get-Brush $Appli.Couleur
    $ui.PageAppliTexte.Text = $Texte
    $ui.PageAppliTexte.Visibility = 'Visible'
    $ui.BtnPageAppliIci.Content = "Ouvrir $($Appli.Nom)"
    $ui.BtnPageAppliIci.Tag = $Appli.Id
    $ui.BtnPageAppliIci.Visibility = 'Visible'
    $ui.PageAppliEtat.Text = ''
    $script:Jauge = @{ Id = $Appli.Id; Ecran = $true; Boucles = (New-Object System.Collections.ArrayList); Timers = (New-Object System.Collections.ArrayList) }
    $hote = $ui.PageAppliJauge
    $hote.Children.Clear()
    New-JaugeAnneau $hote $Appli.Id $true
    $hote.Visibility = 'Visible'
}