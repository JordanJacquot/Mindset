# Mindset : le logo animé de l'en-tête, le même que ceux de Nevermind (le N) et d'Evermind (le E), avec un M.
# Le M blanc avec ses échos cyan et magenta « glitche » par moments, un anneau cyan vers violet tourne,
# une petite comète magenta tourne en sens inverse, un halo respire et une ligne de balayage descend.
# Même dessin que l'icône (outils\icone.ps1). Repris de modules\logo.ps1 d'Evermind.
# Chargé par Mindset.ps1 après interface.ps1 ($Window, $ui).

$LogoCyan = '#00E5FF'
$LogoMagenta = '#FF2EB5'

function Get-ArcGeometry([double]$C, [double]$R, [double]$Start, [double]$Sweep) {
    if ($Sweep -le 0.05) { return $null }
    $a1 = $Start * [math]::PI / 180
    $a2 = ($Start + $Sweep) * [math]::PI / 180
    $p1 = [System.Windows.Point]::new($C + $R * [math]::Cos($a1), $C + $R * [math]::Sin($a1))
    $p2 = [System.Windows.Point]::new($C + $R * [math]::Cos($a2), $C + $R * [math]::Sin($a2))
    $seg = [System.Windows.Media.ArcSegment]::new($p2, [System.Windows.Size]::new($R, $R), 0.0, ($Sweep -gt 180), [System.Windows.Media.SweepDirection]::Clockwise, $true)
    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = $p1
    [void]$fig.Segments.Add($seg)
    $geo = New-Object System.Windows.Media.PathGeometry
    [void]$geo.Figures.Add($fig)
    $geo
}

function New-Glow([string]$Hex, [double]$Blur = 16, [double]$Opacity = 0.55) {
    $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
    $fx.Color = (Get-Couleur $Hex)
    $fx.BlurRadius = $Blur; $fx.ShadowDepth = 0; $fx.Opacity = $Opacity
    $fx
}

function New-LinearBrush([string[]]$Hex, [double]$X1 = 0, [double]$Y1 = 0, [double]$X2 = 1, [double]$Y2 = 0) {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = [System.Windows.Point]::new($X1, $Y1); $b.EndPoint = [System.Windows.Point]::new($X2, $Y2)
    for ($i = 0; $i -lt $Hex.Count; $i++) {
        [void]$b.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Couleur $Hex[$i]), $i / [math]::Max(1, $Hex.Count - 1)))
    }
    $b
}

function New-LogoArc([double]$C, [double]$R, [double]$Start, [double]$Sweep, $Stroke, [double]$Thick) {
    $p = New-Object System.Windows.Shapes.Path
    $p.Data = Get-ArcGeometry $C $R $Start $Sweep
    $p.Stroke = $Stroke; $p.StrokeThickness = $Thick
    $p.StrokeStartLineCap = 'Round'; $p.StrokeEndLineCap = 'Round'
    $p
}

# Animation qui ne s'arrête jamais (30 images par seconde suffisent pour un logo qui tourne doucement)
function Start-LogoLoop($Target, $Property, [double]$From, [double]$To, [int]$Ms, [bool]$Reverse) {
    if ($EnTest -or -not [System.Windows.SystemParameters]::ClientAreaAnimation) { return }   # (animations coupées dans Windows : logo immobile)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = $From; $a.To = $To; $a.AutoReverse = $Reverse
    $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms))
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    if ($Reverse) { $e = New-Object System.Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e }
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, 30)
    $Target.BeginAnimation($Property, $a)
}

# ---------------------------------------------------------------------------
# Le M : un trait épais aux bouts arrondis (deux jambes et le V du milieu), comme le N de Nevermind et le E d'Evermind
# ---------------------------------------------------------------------------
function Get-MindsetM([double]$Size) {
    $x = $Size * 0.22; $y = $Size * 0.22; $w = $Size * 0.56; $h = $Size * 0.56
    $p = [System.Windows.Media.Geometry]::Parse("M $x,$($y + $h) L $x,$y L $($x + $w / 2),$($y + $h * 0.6) L $($x + $w),$y L $($x + $w),$($y + $h)")
    $pen = New-Object System.Windows.Media.Pen ([System.Windows.Media.Brushes]::Black), ($Size * 0.15)
    $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
    $wide = $p.GetWidenedPathGeometry($pen)
    $g = [System.Windows.Media.Geometry]::Combine($wide, $wide, 'Union', $null)
    $g.Freeze()
    $g
}

function New-LogoGeoPath($Geo, [string]$Hex) {
    $p = New-Object System.Windows.Shapes.Path
    $p.Data = $Geo; $p.Fill = Get-Brush $Hex
    $p.RenderTransform = New-Object System.Windows.Media.TranslateTransform 0, 0
    $p
}

# Le M animable : { Root, Cyan, Mag, Base, Pieces (tranches), Size, Rest (décalages au repos) }
function New-MindsetMark([double]$Size) {
    $n = Get-MindsetM $Size
    $root = New-Object System.Windows.Controls.Grid
    $root.Width = $Size; $root.Height = $Size
    $cyan = New-LogoGeoPath $n $LogoCyan; $cyan.Opacity = 0.92
    $mag = New-LogoGeoPath $n $LogoMagenta; $mag.Opacity = 0.92
    # Le M blanc privé de ses deux tranches, et les tranches à part pour pouvoir les décaler
    $bands = @(@(0.36, 0.07), @(0.63, 0.05))
    $bandGeo = New-Object System.Windows.Media.GeometryGroup
    foreach ($b in $bands) { $bandGeo.Children.Add((New-Object System.Windows.Media.RectangleGeometry ([System.Windows.Rect]::new(-$Size, $Size * $b[0], 3 * $Size, $Size * $b[1])))) }
    $base = New-LogoGeoPath ([System.Windows.Media.Geometry]::Combine($n, $bandGeo, 'Exclude', $null)) '#FFFFFF'
    $pieces = foreach ($b in $bands) {
        $r = New-Object System.Windows.Media.RectangleGeometry ([System.Windows.Rect]::new(-$Size, $Size * $b[0], 3 * $Size, $Size * $b[1]))
        New-LogoGeoPath ([System.Windows.Media.Geometry]::Combine($n, $r, 'Intersect', $null)) '#FFFFFF'
    }
    foreach ($e in @($cyan, $mag, $base) + @($pieces)) { [void]$root.Children.Add($e) }
    $m = @{ Root = $root; Cyan = $cyan; Mag = $mag; Base = $base; Pieces = @($pieces); Size = $Size; Rest = @(-0.035, 0.035, 0.05, -0.04) }
    Set-LogoPose $m $m.Rest
    $m
}

function Set-LogoPose($M, [double[]]$Pose) {
    $s = $M.Size
    $M.Cyan.RenderTransform.X = $Pose[0] * $s
    $M.Mag.RenderTransform.X = $Pose[1] * $s
    $M.Pieces[0].RenderTransform.X = $Pose[2] * $s
    $M.Pieces[1].RenderTransform.X = $Pose[3] * $s
}

# Un « saut » de quelques centaines de millisecondes : décalages au hasard, puis retour au repos
function Start-LogoGlitch($Mark, [int]$Ms = 300) {
    if (-not $Mark -or $Mark.Busy) { return }
    $Mark.Busy = $true
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(45)
    $t.Tag = @{ Mark = $Mark; Until = [DateTime]::Now.AddMilliseconds($Ms); Rnd = (New-Object Random) }
    $t.Add_Tick({
        param($s, $e)
        $x = $s.Tag; $r = $x.Rnd
        if ([DateTime]::Now -gt $x.Until) {
            $s.Stop()
            Set-LogoPose $x.Mark $x.Mark.Rest
            $x.Mark.Base.RenderTransform.X = 0
            $x.Mark.Busy = $false
            return
        }
        $j = { param($a) ($r.NextDouble() * 2 - 1) * $a }
        Set-LogoPose $x.Mark @((& $j 0.09), (& $j 0.09), (& $j 0.14), (& $j 0.14))
        $x.Mark.Base.RenderTransform.X = (& $j 0.03) * $x.Mark.Size
    })
    $t.Start()
}

# ---------------------------------------------------------------------------
# Le logo complet, dans un carré de côté $S : halo, anneaux, comète, M et balayage, tout en boucle
# ---------------------------------------------------------------------------
function Start-LogoAnime($Hote, [double]$S = 84) {
    $Hote.Children.Clear()
    $k = $S / 260.0          # mêmes proportions que l'écran de chargement de Nevermind (260 px)
    $C = $S / 2
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $S; $cv.Height = $S

    # Halo qui respire derrière le logo
    $halo = New-Object System.Windows.Shapes.Ellipse
    $halo.Width = 220 * $k; $halo.Height = 220 * $k
    $rb = New-Object System.Windows.Media.RadialGradientBrush
    [void]$rb.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Couleur '#5500E5FF'), 0))
    [void]$rb.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Couleur '#22FF2EB5'), 0.6))
    [void]$rb.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Couleur '#00FF2EB5'), 1))
    $halo.Fill = $rb
    $halo.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
    $hs = New-Object System.Windows.Media.ScaleTransform 1, 1
    $halo.RenderTransform = $hs
    [System.Windows.Controls.Canvas]::SetLeft($halo, 20 * $k); [System.Windows.Controls.Canvas]::SetTop($halo, 20 * $k)
    [void]$cv.Children.Add($halo)
    Start-LogoLoop $hs ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 0.85 1.1 1600 $true
    Start-LogoLoop $hs ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 0.85 1.1 1600 $true

    # Anneau de fond, et l'anneau cyan vers violet qui tourne
    $epais = [math]::Max(2.0, 6 * $k)
    [void]$cv.Children.Add((New-LogoArc $C (112 * $k) -90 359.9 (Get-Brush '#16FFFFFF') $epais))
    $tour = New-Object System.Windows.Controls.Canvas
    $tour.Width = $S; $tour.Height = $S
    $rot = New-Object System.Windows.Media.RotateTransform 0, $C, $C
    $tour.RenderTransform = $rot
    $arc = New-LogoArc $C (112 * $k) -90 250 (New-LinearBrush @($LogoCyan, '#B04BFF', $LogoMagenta) 0 0 1 1) $epais
    $arc.Effect = New-Glow $LogoCyan (14 * $k + 4) 0.7
    [void]$tour.Children.Add($arc)
    [void]$cv.Children.Add($tour)
    Start-LogoLoop $rot ([System.Windows.Media.RotateTransform]::AngleProperty) 0 360 3200 $false

    # Petite comète magenta qui tourne en sens inverse, plus loin
    $com = New-Object System.Windows.Controls.Canvas
    $com.Width = $S; $com.Height = $S
    $rot2 = New-Object System.Windows.Media.RotateTransform 0, $C, $C
    $com.RenderTransform = $rot2
    $col = (Get-Couleur $LogoMagenta)
    $cb = New-Object System.Windows.Media.LinearGradientBrush
    $cb.StartPoint = [System.Windows.Point]::new(0, 1); $cb.EndPoint = [System.Windows.Point]::new(1, 0)
    [void]$cb.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0, $col.R, $col.G, $col.B), 0))
    [void]$cb.GradientStops.Add([System.Windows.Media.GradientStop]::new($col, 1))
    [void]$com.Children.Add((New-LogoArc $C (124 * $k) 0 60 $cb ([math]::Max(1.2, 2 * $k))))
    [void]$cv.Children.Add($com)
    Start-LogoLoop $rot2 ([System.Windows.Media.RotateTransform]::AngleProperty) 360 0 2600 $false

    # Le M, au centre
    $mark = New-MindsetMark (128 * $k)
    [System.Windows.Controls.Canvas]::SetLeft($mark.Root, $C - 64 * $k); [System.Windows.Controls.Canvas]::SetTop($mark.Root, $C - 64 * $k)
    [void]$cv.Children.Add($mark.Root)

    # Ligne de balayage qui descend en boucle (dans le cercle)
    $scanHost = New-Object System.Windows.Controls.Canvas
    $scanHost.Width = $S; $scanHost.Height = $S
    $scanHost.Clip = New-Object System.Windows.Media.EllipseGeometry ([System.Windows.Point]::new($C, $C)), (106 * $k), (106 * $k)
    $scan = New-Object System.Windows.Shapes.Rectangle
    $scan.Width = $S; $scan.Height = [math]::Max(1.5, 3 * $k)
    $scan.Fill = New-LinearBrush @('#0000E5FF', '#9900E5FF', '#0000E5FF') 0 0 1 0
    $st = New-Object System.Windows.Media.TranslateTransform 0, -10
    $scan.RenderTransform = $st
    [void]$scanHost.Children.Add($scan)
    [void]$cv.Children.Add($scanHost)
    Start-LogoLoop $st ([System.Windows.Media.TranslateTransform]::YProperty) (20 * $k) (240 * $k) 2200 $false

    [void]$Hote.Children.Add($cv)
    $script:LogoMarque = $mark

    # Petits sauts réguliers du M, comme pendant le chargement de Nevermind ; un de plus au survol.
    # Seulement quand la fenêtre est au premier plan (derrière un jeu, Mindset ne travaille pas pour rien).
    if ($EnTest) { return }
    $script:LogoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:LogoTimer.Interval = [TimeSpan]::FromMilliseconds(1300)
    $script:LogoTimer.Add_Tick({ if ($Window.IsActive -and $Window.WindowState -ne 'Minimized') { Start-LogoGlitch $script:LogoMarque 260 } })
    $script:LogoTimer.Start()
    $Hote.Add_MouseEnter({ Start-LogoGlitch $script:LogoMarque 420 })
}

Start-LogoAnime $ui.LogoHote
