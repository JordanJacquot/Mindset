# Mindset : thèmes personnalisés (packs) de la suite, repris des packs de Nevermind et Evermind.
#
# Un pack de la suite est un zip (par exemple Thème-Mario.zip) avec ses images, sa police, et un fichier de réglage
# par appli : pack-mindset.json, pack-nevermind.json, pack-evermind.json (le même format que le pack.json de chaque appli).
# Importé dans Mindset (Paramètres, Apparence), il est installé pour chacune, dans son dossier de données :
#   <données de la suite>\Mindset\packs\<id>\     <données>\Nevermind\packs\<id>\     <données>\Evermind\packs\<id>\
# Choisi dans Mindset, il devient le thème de la suite (« pack:<id> » dans suite.json) : les applis gérées le prennent.
# Les packs restent sur le PC et ne passent jamais par GitHub (on peut y mettre ses propres images, pour un usage privé).
#
# pack-mindset.json :
#   Name, Desc        nom et description          Base       thème de couleurs (neon, crepuscule...), ou Colors { P, S, T, NH, NS, Map }
#   Hello             bonjour de l'en-tête (« {0} » = Bonjour ou Bonsoir)
#   Logo              image à la place du M (LogoFrames, LogoDelay : planche animée ; LogoGlow : lueur, il lévite)
#   Mascotte          personnage animé dans l'en-tête { File, Frames, Delay, Flip }
#   Footer            dessin animé en bas de la fenêtre { File, Frames, Delay, Height }
#   TabIcons          icônes des onglets de gauche { accueil, nevermind, evermind, parametres = { File, Frames, Delay } }
#   Background        image de fond sous un voile (BackgroundOpacity 0 à 1, BackgroundAlign « bas-droite »...)
#   Font, FontScope   police : sur les titres (« titres ») ou partout (« tout ») ; FontPixel false : police lisse
# Chargé par Mindset.ps1 avant themes.ps1 (qui choisit le thème) ; les visuels sont posés après la fenêtre.

$PacksDir = Join-Path $DataDir 'packs'
$PackAppliFichiers = [ordered]@{ Mindset = 'pack-mindset.json'; Nevermind = 'pack-nevermind.json'; Evermind = 'pack-evermind.json' }

# Un nom de fichier du pack : simple, sans dossier (rien ne peut sortir du dossier du pack)
function Test-NomFichierPack($Nom) { $Nom -is [string] -and $Nom -match '^[\w .()-]{1,80}$' -and $Nom -notmatch '\.\.' }

function Get-ThemePack([string]$Id) {
    if ($Id -notmatch '^[a-z0-9-]{1,40}$') { return $null }
    $dir = Join-Path $PacksDir $Id
    $f = Join-Path $dir 'pack.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { Write-Log "Pack $Id illisible : $_"; return $null }
    $fichier = { param($n) if ((Test-NomFichierPack $n) -and (Test-Path -LiteralPath (Join-Path $dir ([string]$n)))) { Join-Path $dir ([string]$n) } else { $null } }
    $p = @{ Id = $Id; Dir = $dir; Name = [string]$j.Name; Desc = [string]$j.Desc; Base = [string]$j.Base; Hello = [string]$j.Hello; Font = $null; FontScope = 'titres' }
    if (-not $p.Name) { $p.Name = $Id }
    $p.Logo = & $fichier $j.Logo
    $p.LogoFrames = [math]::Max(1, [int]$j.LogoFrames); $p.LogoDelay = [math]::Max(30, [int]$j.LogoDelay); $p.LogoGlow = [string]$j.LogoGlow
    $p.Mascotte = $null
    if ($j.Mascotte -and (& $fichier $j.Mascotte.File)) { $p.Mascotte = @{ File = (& $fichier $j.Mascotte.File); Frames = [math]::Max(1, [int]$j.Mascotte.Frames); Delay = [math]::Max(40, [int]$j.Mascotte.Delay); Flip = [bool]$j.Mascotte.Flip } }
    $p.Footer = $null
    if ($j.Footer -and (& $fichier $j.Footer.File)) { $p.Footer = @{ File = (& $fichier $j.Footer.File); Frames = [math]::Max(1, [int]$j.Footer.Frames); Delay = [math]::Max(40, [int]$j.Footer.Delay); Height = [math]::Min(48, [math]::Max(16, [int]$j.Footer.Height)) } }
    $p.TabIcons = @{}
    if ($j.TabIcons) {
        foreach ($pr in $j.TabIcons.PSObject.Properties) {
            $v = $pr.Value
            if ($pr.Name -match '^[a-z]+$' -and (& $fichier $v.File)) { $p.TabIcons[$pr.Name] = @{ File = (& $fichier $v.File); Frames = [math]::Max(1, [int]$v.Frames); Delay = [math]::Max(40, [int]$v.Delay); Glow = [string]$v.Glow } }
        }
    }
    $p.Background = & $fichier $j.Background
    $p.BackgroundOpacity = if ($j.BackgroundOpacity) { [math]::Min(1.0, [math]::Max(0.05, [double]$j.BackgroundOpacity)) } else { 0.35 }
    $al = ([string]$j.BackgroundAlign).ToLowerInvariant()
    $p.BackgroundAlignX = if ($al -match 'droite') { 'Right' } elseif ($al -match 'gauche') { 'Left' } else { 'Center' }
    $p.BackgroundAlignY = if ($al -match 'bas') { 'Bottom' } elseif ($al -match 'haut') { 'Top' } else { 'Center' }
    if (& $fichier $j.Font) { $p.Font = & $fichier $j.Font; if ([string]$j.FontScope -eq 'tout') { $p.FontScope = 'tout' } }
    $p.FontPixel = if ($null -ne $j.FontPixel) { [bool]$j.FontPixel } else { $true }
    # Couleurs propres au pack : un thème « pack-<id> » ajouté à la liste (jamais proposé comme thème de base)
    if ($j.Colors -and $j.Colors.P -and $j.Colors.S -and $j.Colors.T -and $AppThemes) {
        $map = @{}
        if ($j.Colors.Map) { foreach ($pr in $j.Colors.Map.PSObject.Properties) { $map[$pr.Name.TrimStart('#').ToUpper()] = ([string]$pr.Value).TrimStart('#').ToUpper() } }
        $key = "pack-$Id"
        $AppThemes[$key] = @{ Name = $p.Name; Desc = $p.Desc; P = [string]$j.Colors.P; S = [string]$j.Colors.S; T = [string]$j.Colors.T
            NH = $(if ($null -ne $j.Colors.NH) { [double]$j.Colors.NH } else { $null }); NS = $(if ($j.Colors.NS) { [double]$j.Colors.NS } else { 1.0 })
            Map = $map; Font = $null; Pack = $true }
        $p.Base = $key
    }
    if ($AppThemes -and -not $AppThemes.Contains($p.Base)) { $p.Base = 'neon' }
    $p
}

function Get-ThemePacks {
    if (-not (Test-Path -LiteralPath $PacksDir)) { return @() }
    @(Get-ChildItem -LiteralPath $PacksDir -Directory | ForEach-Object { Get-ThemePack $_.Name } | Where-Object { $_ })
}

# ---------------------------------------------------------------------------
# Importer un pack de la suite (zip) : vérifié, puis installé pour Mindset et pour chaque appli qu'il prévoit
# ---------------------------------------------------------------------------
function Import-PackSuite([string]$Zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $id = (([IO.Path]::GetFileNameWithoutExtension($Zip) -replace '^(?i)th[eè]me-', '').Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '' -replace '[^\w\-]', '-').ToLower().Trim('-')
    if ($id -notmatch '^[a-z0-9-]{1,40}$') { throw 'Le nom de ce fichier ne convient pas pour un thème (lettres, chiffres et tirets).' }
    $za = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entrees = @($za.Entries | Where-Object { $_.Name })
        if (-not ($entrees | Where-Object { $_.Name -eq 'pack-mindset.json' })) {
            if ($entrees | Where-Object { $_.Name -eq 'pack.json' }) { throw 'Ce zip est un thème pour une seule appli (Nevermind ou Evermind). Un thème de la suite contient pack-mindset.json, pack-nevermind.json et pack-evermind.json.' }
            throw 'Ce zip ne contient pas de thème de la suite (pack-mindset.json).'
        }
        $total = ($entrees | Measure-Object Length -Sum).Sum
        if ($total -gt 60MB) { throw 'Ce thème est trop lourd (plus de 60 Mo).' }
        # Seulement des fichiers simples (pas de dossier) aux extensions attendues
        foreach ($e in $entrees) {
            if ($e.FullName -ne $e.Name -or -not (Test-NomFichierPack $e.Name) -or $e.Name -notmatch '\.(png|jpe?g|gif|ttf|otf|json)$') { throw "Fichier inattendu dans le thème : $($e.FullName)" }
        }
        $installes = @()
        foreach ($appli in $PackAppliFichiers.Keys) {
            $reglage = $entrees | Where-Object { $_.Name -eq $PackAppliFichiers[$appli] } | Select-Object -First 1
            if (-not $reglage) { continue }
            $dest = if ($appli -eq 'Mindset') { Join-Path $PacksDir $id } else { Join-Path $SuiteDir "$appli\packs\$id" }
            $tmp = "$dest.nouveau"
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            foreach ($e in $entrees) {
                if ($e.Name -like 'pack-*.json') { continue }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $tmp $e.Name), $true)
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($reglage, (Join-Path $tmp 'pack.json'), $true)
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            Move-Item -LiteralPath $tmp -Destination $dest
            $installes += $appli
        }
    } finally { $za.Dispose() }
    if (-not (Get-ThemePack $id)) { throw 'Le réglage de ce thème pour Mindset (pack-mindset.json) est illisible.' }
    Write-Log "Thème de la suite importé : $id ($($installes -join ', '))"
    $id
}

# ---------------------------------------------------------------------------
# Visuels d'un pack (après le chargement de la fenêtre) : fond, mascotte, dessin du bas, icônes des onglets
# ---------------------------------------------------------------------------
# Planche PNG (images côte à côte) découpée en images prêtes à afficher
function Get-SheetFrames([string]$File, [int]$Count) {
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.UriSource = New-Object Uri $File; $bi.CacheOption = 'OnLoad'; $bi.EndInit(); $bi.Freeze()
    $fw = [int]($bi.PixelWidth / [math]::Max(1, $Count))
    @(for ($i = 0; $i -lt $Count; $i++) { $c = New-Object System.Windows.Media.Imaging.CroppedBitmap $bi, ([System.Windows.Int32Rect]::new($i * $fw, 0, $fw, $bi.PixelHeight)); $c.Freeze(); $c })
}

# Une image qui défile en boucle, seulement fenêtre visible (rien ne tourne quand Mindset est caché)
function Start-Defilement($Img, $Frames, [int]$Delay) {
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($Delay)
    $t.Tag = @{ Img = $Img; Frames = $Frames; Frame = 0 }
    $t.Add_Tick({ param($s) if (-not $Window.IsVisible -or $Window.WindowState -eq 'Minimized') { return }; $x = $s.Tag; $x.Frame = ($x.Frame + 1) % $x.Frames.Count; $x.Img.Source = $x.Frames[$x.Frame] })
    if ($Frames.Count -gt 1 -and -not $EnTest) { $t.Start() }
    $t
}

# Image fixe : elle sautille en boucle ; lévitation lumineuse si une couleur est donnée
function Start-Sautille($Img, [double]$Haut = 6, [string]$Lueur = '') {
    $mv = New-Object System.Windows.Media.TranslateTransform
    $grp = New-Object System.Windows.Media.TransformGroup
    if ($Img.RenderTransform -is [System.Windows.Media.ScaleTransform]) { $grp.Children.Add($Img.RenderTransform) }
    $grp.Children.Add($mv)
    $Img.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5); $Img.RenderTransform = $grp
    if ($Lueur) {
        $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
        $fx.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Lueur); $fx.ShadowDepth = 0; $fx.Opacity = 0.9; $fx.BlurRadius = 10
        $Img.Effect = $fx
    }
    if ($EnTest) { return }
    $ease = New-Object System.Windows.Media.Animation.SineEase; $ease.EasingMode = 'EaseInOut'
    $up = New-Object System.Windows.Media.Animation.DoubleAnimation 0, (-$Haut), ([System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($(if ($Lueur) { 900 } else { 320 }))))
    $up.AutoReverse = $true; $up.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever; $up.EasingFunction = $ease
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($up, 30)
    $mv.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $up)
}

# Police pixel partout : tailles « pixel exactes » (8, 12, 16 ou 24), nettes et sans débordement
function Get-PackFontSize([double]$Size) { if ($Size -lt 15) { 8 } elseif ($Size -lt 21) { 12 } elseif ($Size -lt 30) { 16 } else { 24 } }
function Update-TaillesPixel($Racine) {
    $pile = New-Object System.Collections.Stack
    $pile.Push($Racine)
    while ($pile.Count) {
        $el = $pile.Pop()
        if ($el -is [System.Windows.Controls.TextBlock] -or $el -is [System.Windows.Controls.Control]) {
            if ($el.FontSize -notin 8, 12, 16, 24) { $el.FontSize = Get-PackFontSize $el.FontSize }
        }
        if ($el -is [System.Windows.Media.Visual]) {
            $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
            for ($i = 0; $i -lt $n; $i++) { $pile.Push([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)) }
        }
    }
}

function Initialize-PackVisuels {
    if (-not $ThemePack) { return }
    $script:PackTimers = @()
    # Fond : l'image, puis un voile sombre qui garde le texte lisible
    if ($ThemePack.Background) {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit(); $bi.UriSource = New-Object Uri $ThemePack.Background; $bi.DecodePixelWidth = 1920; $bi.CacheOption = 'OnLoad'; $bi.EndInit(); $bi.Freeze()
        $brush = New-Object System.Windows.Media.ImageBrush $bi
        $brush.Stretch = 'UniformToFill'; $brush.AlignmentX = $ThemePack.BackgroundAlignX; $brush.AlignmentY = $ThemePack.BackgroundAlignY
        $img = New-Object System.Windows.Shapes.Rectangle; $img.Fill = $brush; $img.Opacity = $ThemePack.BackgroundOpacity
        [void]$ui.BackdropDeco.Children.Add($img)
        $voile = New-Object System.Windows.Shapes.Rectangle
        $vb = New-Object System.Windows.Media.LinearGradientBrush; $vb.StartPoint = [System.Windows.Point]::new(0, 0); $vb.EndPoint = [System.Windows.Point]::new(0, 1)
        foreach ($c in @(@('#99000000', 0), @('#33000000', 0.5), @('#AA000000', 1))) { [void]$vb.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.ColorConverter]::ConvertFromString($c[0]), $c[1])) }
        $voile.Fill = $vb
        [void]$ui.BackdropDeco.Children.Add($voile)
    }
    # Police pixel partout : les textes créés par le code passent aussi en tailles pixel (vérifié 3 fois par seconde au plus)
    if ($PackFont -and $ThemePack.FontScope -eq 'tout' -and $ThemePack.FontPixel) {
        $script:PixelAFaire = $true
        $Window.Add_LayoutUpdated({ $script:PixelAFaire = $true })
        $script:PixelTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:PixelTimer.Interval = [TimeSpan]::FromMilliseconds(350)
        $script:PixelTimer.Add_Tick({ if ($script:PixelAFaire -and $Window.IsVisible) { $script:PixelAFaire = $false; Update-TaillesPixel $Window } })
        $script:PixelTimer.Start()
        Update-TaillesPixel $Window
    }
    # Mascotte : le personnage du thème, animé dans l'en-tête
    if ($ThemePack.Mascotte) {
        $M = $ThemePack.Mascotte
        $frames = Get-SheetFrames $M.File $M.Frames
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $frames[0]; $img.Height = 64; $img.Stretch = 'Uniform'
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, $(if ($frames[0].PixelHeight -le 64) { 'NearestNeighbor' } else { 'HighQuality' }))
        if ($M.Flip) { $img.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5); $img.RenderTransform = New-Object System.Windows.Media.ScaleTransform -1, 1 }
        $ui.Mascotte.Child = $img; $ui.Mascotte.Visibility = 'Visible'
        if ($frames.Count -gt 1) { $script:PackTimers += Start-Defilement $img $frames $M.Delay } else { Start-Sautille $img 8 }
    }
    # Dessin animé en bas de la fenêtre
    if ($ThemePack.Footer) {
        $F = $ThemePack.Footer
        $frames = Get-SheetFrames $F.File $F.Frames
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $frames[0]; $img.Height = $F.Height; $img.Stretch = 'Uniform'
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, $(if ($F.Height -ge $frames[0].PixelHeight) { 'NearestNeighbor' } else { 'HighQuality' }))
        $ui.FooterArt.Child = $img; $ui.FooterArt.Visibility = 'Visible'
        $script:PackTimers += Start-Defilement $img $frames $F.Delay
    }
}

# Icône animée d'un onglet de gauche (à la place de sa pastille) : immobile, animée au survol
function New-IconeOnglet([string]$Id) {
    if (-not $ThemePack -or -not $ThemePack.TabIcons.ContainsKey($Id)) { return $null }
    $def = $ThemePack.TabIcons[$Id]
    try { $frames = Get-SheetFrames $def.File $def.Frames } catch { return $null }
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $frames[0]; $img.Height = 22; $img.Width = 22; $img.Stretch = 'Uniform'; $img.Margin = '0,-4,8,-4'; $img.VerticalAlignment = 'Center'
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($def.Delay)
    $t.Tag = @{ Img = $img; Frames = $frames; Frame = 0 }
    $t.Add_Tick({ param($s) $x = $s.Tag; $x.Frame = ($x.Frame + 1) % $x.Frames.Count; $x.Img.Source = $x.Frames[$x.Frame] })
    @{ Image = $img; Anim = $t }
}
