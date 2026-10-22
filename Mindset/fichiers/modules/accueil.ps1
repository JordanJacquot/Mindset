# Mindset : les onglets de gauche, l'accueil et ses cartes (une par appli de apps.json).
# Chargé par Mindset.ps1, après interface.ps1 ($Window, $ui), applis.ps1 ($Applis) et installations.ps1.

$script:Onglets = @{}      # id -> bouton de l'onglet
$script:Cartes = @{}       # id -> contenu de la carte
$script:CartesCle = @{}    # id -> état affiché (la carte n'est redessinée que s'il change)
$script:Trouvees = @{}     # id -> copie trouvée sur le PC (cherchée au démarrage et après chaque opération)
$script:PageCourante = 'accueil'

function Get-Appli([string]$Id) { $Applis | Where-Object Id -eq $Id | Select-Object -First 1 }

# Bonjour selon l'heure, dans la phrase du thème personnalisé s'il en a une (« {0} » = Bonjour ou Bonsoir)
function Update-Greeting {
    $h = (Get-Date).Hour
    $ui.Greeting.Text = (Get-ThemeHello) -f $(if ($h -ge 18 -or $h -lt 5) { 'Bonsoir' } else { 'Bonjour' })
}

# Icône d'un onglet dans les thèmes de base (20 x 20) : une petite maison pour l'accueil, une roue crantée pour les
# paramètres, et pour une appli son logo (l'anneau dégradé et sa lettre, comme sur l'écran « Ouvrir »)
function New-IconeBase([string]$Id, [string]$Couleur) {
    $S = 20.0
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $S; $cv.Height = $S; $cv.Margin = '0,0,10,0'; $cv.VerticalAlignment = 'Center'
    $p = New-Object System.Windows.Shapes.Path
    switch ($Id) {
        'accueil' {
            # Toit, murs et porte, au trait
            $p.Data = [System.Windows.Media.Geometry]::Parse('M 2.5,10 L 10,3 L 17.5,10 M 4.8,8.2 L 4.8,17 L 15.2,17 L 15.2,8.2 M 8.3,17 L 8.3,12.3 L 11.7,12.3 L 11.7,17')
            $p.Stroke = Get-Brush $Couleur; $p.StrokeThickness = 1.7
            $p.StrokeLineJoin = 'Round'; $p.StrokeStartLineCap = 'Round'; $p.StrokeEndLineCap = 'Round'
        }
        'parametres' {
            # Roue crantée : 8 dents autour d'un anneau, trou au centre
            $pts = New-Object System.Collections.Generic.List[string]
            for ($k = 0; $k -lt 8; $k++) {
                foreach ($a in @(@(-15.0, 6.6), @(-8.0, 9.4), @(8.0, 9.4), @(15.0, 6.6))) {
                    $ang = ($k * 45 + $a[0]) * [math]::PI / 180
                    $pts.Add(('{0},{1}' -f ([math]::Round(10 + $a[1] * [math]::Cos($ang), 2)).ToString([Globalization.CultureInfo]::InvariantCulture), ([math]::Round(10 + $a[1] * [math]::Sin($ang), 2)).ToString([Globalization.CultureInfo]::InvariantCulture)))
                }
            }
            $roue = [System.Windows.Media.Geometry]::Parse("M $($pts[0]) L $(($pts | Select-Object -Skip 1) -join ' ') Z")
            $trou = New-Object System.Windows.Media.EllipseGeometry ([System.Windows.Point]::new(10, 10)), 2.8, 2.8
            $p.Data = [System.Windows.Media.Geometry]::Combine($roue, $trou, 'Exclude', $null)
            $p.Fill = Get-Brush $Couleur
        }
        default {
            # Logo de l'appli : anneau cyan vers magenta et sa lettre au centre
            $anneau = New-Object System.Windows.Shapes.Ellipse
            $anneau.Width = $S - 1; $anneau.Height = $S - 1; $anneau.StrokeThickness = 1.6
            $anneau.Stroke = New-LinearBrush @($LogoCyan, '#B04BFF', $LogoMagenta) 0 0 1 1
            [System.Windows.Controls.Canvas]::SetLeft($anneau, 0.5); [System.Windows.Controls.Canvas]::SetTop($anneau, 0.5)
            [void]$cv.Children.Add($anneau)
            $p.Data = Get-LettreAppli $Id $S
            $p.Fill = Get-Brush '#ECEAF7'
            $p.RenderTransform = New-Object System.Windows.Media.ScaleTransform 0.72, 0.72, ($S / 2), ($S / 2)
        }
    }
    [void]$cv.Children.Add($p)
    $cv
}

function New-Onglet([string]$Id, [string]$Texte, [string]$Couleur, $Panneau = $ui.Onglets) {
    $b = New-Button '' 'Onglet'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    # Icône du thème de base, ou l'icône animée du thème personnalisé (immobile, animée au survol)
    $icone = New-IconeOnglet $Id
    if ($icone) {
        [void]$sp.Children.Add($icone.Image)
        $b.Resources['Anim'] = $icone.Anim
        $b.Add_MouseEnter({ param($s) $a = $s.Resources['Anim']; if ($a.Tag.Frames.Count -gt 1) { $a.Start() } })
        $b.Add_MouseLeave({ param($s) $a = $s.Resources['Anim']; $a.Stop(); $a.Tag.Frame = 0; $a.Tag.Img.Source = $a.Tag.Frames[0] })
    } else {
        [void]$sp.Children.Add((New-IconeBase $Id $Couleur))
    }
    [void]$sp.Children.Add((New-Text $Texte 14 '#A9A3C9'))
    $b.Content = $sp
    $b.Tag = $Id
    $b.Add_Click({ Show-Page $this.Tag })
    [void]$Panneau.Children.Add($b)
    $script:Onglets[$Id] = $b
}

function Show-Page([string]$Id) {
    # Avec la console 3D, les Paramètres s'ouvrent dans son écran (console.ps1, chargé après) : la page d'avant reste cachée
    if ($Id -eq 'parametres' -and $script:Console.Possible -and (Get-Command Open-ParametresConsole -ErrorAction SilentlyContinue)) { Open-ParametresConsole; return }
    $script:PageCourante = $Id
    foreach ($k in $script:Onglets.Keys) {
        $b = $script:Onglets[$k]; $on = ($k -eq $Id)
        $b.Background = if ($on) { Get-Brush '#141030' } else { [System.Windows.Media.Brushes]::Transparent }
        $b.Content.Children[1].Foreground = Get-Brush $(if ($on) { '#ECEAF7' } else { '#A9A3C9' })
    }
    $ui.PageAccueil.Visibility = if ($Id -eq 'accueil') { 'Visible' } else { 'Collapsed' }
    $ui.PageParametres.Visibility = if ($Id -eq 'parametres') { 'Visible' } else { 'Collapsed' }
    # (Paramètres sur l'onglet Général : les interrupteurs « S'ouvre avec Mindset » à jour ; parametres.ps1, chargé après)
    if ($Id -eq 'parametres' -and $script:OngletParametres -eq 'general' -and (Get-Command Update-DemarragesParametres -ErrorAction SilentlyContinue)) { Update-DemarragesParametres }
    $ui.PageAppli.Visibility = if ($Id -in @('accueil', 'parametres')) { 'Collapsed' } else { 'Visible' }
    # L'accueil en console 3D quand elle peut s'afficher (console.ps1, chargé en dernier)
    if (Get-Command Update-PageConsole -ErrorAction SilentlyContinue) { Update-PageConsole }
    # Onglet d'une appli : elle s'affiche ici, dans Mindset (integration.ps1, chargé après ce module)
    if (Get-Command Update-HotesVisibles -ErrorAction SilentlyContinue) {
        Update-HotesVisibles
        if ($ui.PageAppli.Visibility -eq 'Visible') { Show-AppliIntegree (Get-Appli $Id) }
    }
}

# ---------------------------------------------------------------------------
# Cartes
# ---------------------------------------------------------------------------
function New-Carte($Appli) {
    $carte = New-Object System.Windows.Controls.Border
    # Carte en verre, comme celles de Nevermind et Evermind
    $carte.Width = 380; $carte.Margin = '0,0,18,18'; $carte.Padding = '24,20'
    $carte.CornerRadius = 22; $carte.BorderThickness = 1
    $carte.Background = $Window.FindResource('CardBg'); $carte.BorderBrush = $Window.FindResource('CardBorder')
    $sp = New-Object System.Windows.Controls.StackPanel
    $carte.Child = $sp
    [void]$ui.Cartes.Children.Add($carte)
    $script:Cartes[$Appli.Id] = $sp
}

function New-Pastille([string]$Texte, [string]$Couleur) {
    $p = New-Object System.Windows.Controls.Border
    $p.CornerRadius = 10; $p.BorderThickness = 1; $p.Padding = '9,2'; $p.Margin = '0,0,6,0'
    $p.BorderBrush = Get-Brush $Couleur
    $p.Child = New-Text $Texte 11 $Couleur
    $p
}

function New-Action([string]$Texte, [string]$Style, [string]$Id, [scriptblock]$Clic) {
    $b = New-Button $Texte $Style
    $b.Tag = $Id; $b.Margin = '0,0,8,0'
    $b.Add_Click($Clic)
    $b
}

# ---------------------------------------------------------------------------
# Cartes vivantes : le résumé que chaque appli gérée écrit dans son dossier de données (etat.json).
#   Nevermind : { Score, Protection, AFaire, Urgent, NbAFaire }    Evermind : { Prochains : [ { Id, Titre, Quand, Journee } ] }
#   Toute autre appli (format commun) : { Titre, Scores : [ { Nom, Valeur 0 à 100 } ] (2 au plus),
#                                         Lignes : [ { Texte, Etat : ok | info | attention | urgent } ] (3 au plus) }
# Seulement lu pour afficher du texte et des nombres, jamais exécuté ni ouvert : 32 Ko au plus, textes coupés à
# 80 caractères, identifiants de rendez-vous de 32 chiffres hexadécimaux. Relu quand le fichier change.
# ---------------------------------------------------------------------------
$script:EtatsApplis = @{}
function Get-EtatAppli($Appli) {
    $d = Get-DossierDonnees $Appli
    if (-not $d) { return $null }
    $fi = New-Object IO.FileInfo (Join-Path $d 'etat.json')
    if (-not $fi.Exists -or $fi.Length -gt 32KB) { return $null }
    $c = $script:EtatsApplis[$Appli.Id]
    if ($c -and $c.Date -eq $fi.LastWriteTimeUtc) { return $c.Etat }
    $e = $null
    try {
        $j = [IO.File]::ReadAllText($fi.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $txt = { param($v) $s = ([string]$v -replace '\p{Cc}', ' ').Trim(); if ($s.Length -gt 80) { $s.Substring(0, 80) } else { $s } }
        $pct = { param($v) $x = 0; if ($null -ne $v -and [int]::TryParse([string]$v, [ref]$x) -and $x -ge 0 -and $x -le 100) { $x } else { $null } }
        if ($Appli.Id -eq 'nevermind') {
            $e = @{ Score = (& $pct $j.Score); Protection = (& $pct $j.Protection); AFaire = (& $txt $j.AFaire); Urgent = ($j.Urgent -eq $true) }
        } elseif ($Appli.Id -eq 'evermind') {
            $ic = [Globalization.CultureInfo]::InvariantCulture
            $e = @{ Prochains = @(foreach ($p in @($j.Prochains | Select-Object -First 10)) {
                $q = [datetime]::MinValue
                if ([string]$p.Id -cmatch '^[0-9a-f]{32}$' -and [datetime]::TryParseExact([string]$p.Quand, 's', $ic, 'None', [ref]$q)) {
                    @{ Id = [string]$p.Id; Titre = (& $txt $p.Titre); Quand = $q; Journee = ($p.Journee -eq $true) }
                }
            }) }
        } else {
            $etats = @('ok', 'info', 'attention', 'urgent')
            $e = @{ Titre = (& $txt $j.Titre)
                Scores = @(foreach ($s in @($j.Scores | Select-Object -First 2)) { $v = & $pct $s.Valeur; if ($null -ne $v -and $s.Nom) { @{ Nom = (& $txt $s.Nom); Valeur = $v } } })
                Lignes = @(foreach ($l in @($j.Lignes | Select-Object -First 3)) { if ($l.Texte) { @{ Texte = (& $txt $l.Texte); Etat = $(if ([string]$l.Etat -in $etats) { [string]$l.Etat } else { 'info' }) } } }) }
        }
    } catch { $e = $null }
    $script:EtatsApplis[$Appli.Id] = @{ Date = $fi.LastWriteTimeUtc; Etat = $e }
    $e
}

# Les 3 prochains rendez-vous encore à venir (ceux d'aujourd'hui sans heure restent toute la journée)
function Get-ProchainsRdv($Etat) {
    $now = Get-Date
    @($Etat.Prochains | Where-Object { if ($_.Journee) { $_.Quand.Date -ge $now.Date } else { $_.Quand -ge $now } } | Select-Object -First 3)
}

function Format-QuandRdv($R) {
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $j = ($R.Quand.Date - (Get-Date).Date).Days
    $jour = if ($j -eq 0) { "Aujourd'hui" } elseif ($j -eq 1) { 'Demain' } elseif ($j -lt 7) { $fr.TextInfo.ToTitleCase($R.Quand.ToString('dddd', $fr)) } else { $R.Quand.ToString('d MMM', $fr) }
    if ($R.Journee) { $jour } else { "$jour $($R.Quand.ToString('HH:mm'))" }
}

# Une ligne cliquable de la carte (survol éclairé)
function New-LigneVivante($Contenu, [scriptblock]$Clic, $Tag) {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 10; $b.Padding = '10,7'; $b.Margin = '0,0,0,4'; $b.Cursor = 'Hand'; $b.Tag = $Tag
    $b.Background = Get-Brush '#0DFFFFFF'
    $b.Child = $Contenu
    $b.Add_MouseEnter({ $this.Background = Get-Brush '#1CFFFFFF' })
    $b.Add_MouseLeave({ $this.Background = Get-Brush '#0DFFFFFF' })
    $b.Add_MouseLeftButtonUp($Clic)
    $b
}

# Petite jauge néon d'un score sur 100 (comme les anneaux de l'accueil de Nevermind) : l'anneau se remplit à l'affichage,
# le score au centre, son nom en dessous
function New-JaugeScore([string]$Nom, [int]$Valeur, [string]$C1, [string]$C2) {
    $S = 74.0; $C = $S / 2; $R = 30.0
    $p = New-Object System.Windows.Controls.StackPanel; $p.Margin = '0,0,22,10'
    $g = New-Object System.Windows.Controls.Grid; $g.Width = $S; $g.Height = $S
    $cv = New-Object System.Windows.Controls.Canvas; $cv.Width = $S; $cv.Height = $S
    [void]$cv.Children.Add((New-LogoArc $C $R -90 359.9 (Get-Brush '#1AFFFFFF') 6))
    $arc = New-LogoArc $C $R -90 0.1 (New-LinearBrush @($C1, $C2) 0 0 1 1) 6
    $arc.Effect = New-Glow $C1 10 0.6
    [void]$cv.Children.Add($arc)
    [void]$g.Children.Add($cv)
    $n = New-Text "$Valeur" 19 '#FFFFFF' 'SemiBold'; $n.HorizontalAlignment = 'Center'; $n.VerticalAlignment = 'Center'
    [void]$g.Children.Add($n)
    [void]$p.Children.Add($g)
    $l = New-Text $Nom 11.5 '#A9A3C9'; $l.HorizontalAlignment = 'Center'; $l.Margin = '0,4,0,0'
    [void]$p.Children.Add($l)
    # Remplissage en 0,7 s (ralenti à la fin) ; tout de suite plein en test ou si les animations de Windows sont coupées
    $fin = [math]::Max(0.1, [math]::Min(359.9, 3.6 * $Valeur))
    if ($EnTest -or -not [System.Windows.SystemParameters]::ClientAreaAnimation) { $arc.Data = Get-ArcGeometry $C $R -90 $fin; return $p }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(16)
    $t.Tag = @{ Arc = $arc; C = $C; R = $R; Fin = $fin; Debut = Get-Date }
    $t.Add_Tick({
        param($s)
        $x = $s.Tag; $k = [math]::Min(1.0, ((Get-Date) - $x.Debut).TotalMilliseconds / 700)
        $x.Arc.Data = Get-ArcGeometry $x.C $x.R -90 ([math]::Max(0.1, $x.Fin * (1 - [math]::Pow(1 - $k, 3))))
        if ($k -ge 1) { $s.Stop() }
    })
    $t.Start()
    $p
}

# Le résumé d'une appli sur sa carte (rien si elle n'a encore rien écrit)
function Add-ResumeCarte($Sp, $Appli, $Etat) {
    if (-not $Etat) { return }
    $box = New-Object System.Windows.Controls.StackPanel
    $box.Margin = '0,0,0,6'
    if ($Appli.Id -eq 'nevermind') {
        $scores = New-Object System.Windows.Controls.WrapPanel
        foreach ($s in @(@('Optimisation', $Etat.Score, '#00E5FF', '#7A7BFF'), @('Protection', $Etat.Protection, '#FF2EB5', '#B04BFF'))) {
            if ($null -ne $s[1]) { [void]$scores.Children.Add((New-JaugeScore $s[0] $s[1] $s[2] $s[3])) }
        }
        [void]$box.Children.Add($scores)
        $t = if ($Etat.AFaire) { "À faire : $($Etat.AFaire)" } else { 'Rien à corriger : ton PC est prêt pour jouer.' }
        $l = New-Text $t 12.5 $(if ($Etat.Urgent) { '#FFB020' } elseif ($Etat.AFaire) { '#ECEAF7' } else { '#3DDC84' }); $l.TextWrapping = 'Wrap'
        [void]$box.Children.Add((New-LigneVivante $l { Open-AppliIci 'nevermind' } $null))
    } elseif ($Appli.Id -eq 'evermind') {
        [void]$box.Children.Add((New-Text 'Prochains rendez-vous' 11.5 '#A9A3C9'))
        $rdv = Get-ProchainsRdv $Etat
        if (-not $rdv.Count) { $v = New-Text 'Rien de prévu pour le moment.' 12.5 '#6F6894'; $v.Margin = '0,6,0,0'; [void]$box.Children.Add($v) }
        else {
            $box.Children[0].Margin = '0,0,0,6'
            foreach ($r in $rdv) {
                $dp = New-Object System.Windows.Controls.DockPanel
                $q = New-Text (Format-QuandRdv $r) 12 $Appli.Couleur 'SemiBold'; $q.Width = 118
                [void]$dp.Children.Add($q)
                $ti = New-Text $r.Titre 12.5 '#ECEAF7'; $ti.TextTrimming = 'CharacterEllipsis'
                [void]$dp.Children.Add($ti)
                [void]$box.Children.Add((New-LigneVivante $dp { Open-RdvEvermind $this.Tag } $r))
            }
        }
    } else {
        # Format commun : un petit titre, des jauges, puis des lignes ; un clic ouvre l'appli dans son onglet
        if ($Etat.Titre) { $t = New-Text $Etat.Titre 11.5 '#A9A3C9'; $t.Margin = '0,0,0,6'; [void]$box.Children.Add($t) }
        if ($Etat.Scores.Count) {
            $scores = New-Object System.Windows.Controls.WrapPanel
            $paires = @(@('#00E5FF', '#7A7BFF'), @('#FF2EB5', '#B04BFF'))
            for ($k = 0; $k -lt $Etat.Scores.Count; $k++) { [void]$scores.Children.Add((New-JaugeScore $Etat.Scores[$k].Nom $Etat.Scores[$k].Valeur $paires[$k][0] $paires[$k][1])) }
            [void]$box.Children.Add($scores)
        }
        $couleurs = @{ ok = '#3DDC84'; info = '#ECEAF7'; attention = '#FFB020'; urgent = '#FF5C7A' }
        foreach ($l in $Etat.Lignes) {
            $tl = New-Text $l.Texte 12.5 $couleurs[$l.Etat]; $tl.TextWrapping = 'Wrap'
            [void]$box.Children.Add((New-LigneVivante $tl { Open-AppliIci $this.Tag } $Appli.Id))
        }
    }
    [void]$Sp.Children.Add($box)
}

# Clic sur un rendez-vous : Evermind s'ouvre dans son onglet, sur la fiche de ce rendez-vous
function Open-RdvEvermind($R) {
    $a = Get-Appli 'evermind'
    $d = Get-DossierDonnees $a
    if ($d -and $R.Id -cmatch '^[0-9a-f]{32}$') {
        try { [IO.File]::WriteAllText((Join-Path $d 'afficher-rdv.demande'), "$($R.Id)|$($R.Quand.ToString('s', [Globalization.CultureInfo]::InvariantCulture))") } catch {}
    }
    Open-AppliIci 'evermind'
}

# Ce que la carte doit montrer, résumé en une clé : la carte n'est redessinée que si elle change
function Get-EtatCarte($Appli) {
    $inst = Get-Installation $Appli
    $pub = $script:Publications[$Appli.Id]
    @{
        Inst    = $inst
        Pub     = $pub
        Ouverte = (Test-AppliOuverte $Appli)
        Trouvee = $script:Trouvees[$Appli.Id]
        Occupe  = $script:Occupe[$Appli.Id]
        Message = $script:Messages[$Appli.Id]
        MajDispo = [bool]($inst -and $inst.Gere -and $pub -and $pub.Version -and (Test-VersionPlusRecente $pub.Version $inst.Version))
        Resume  = $(if ($inst -and $inst.Gere) { Get-EtatAppli $Appli })
    }
}

function Update-Carte($Appli) {
    $e = Get-EtatCarte $Appli
    $resume = if ($e.Resume) {
        if ($Appli.Id -eq 'evermind') { ((Get-ProchainsRdv $e.Resume | ForEach-Object { "$($_.Id)$($_.Quand)$($_.Titre)" }) -join ',') + "|$((Get-Date).Date)" }
        elseif ($Appli.Id -eq 'nevermind') { "$($e.Resume.Score)/$($e.Resume.Protection)/$($e.Resume.AFaire)/$($e.Resume.Urgent)" }
        else { ConvertTo-Json -InputObject $e.Resume -Depth 4 -Compress }
    }
    $cle = "$($e.Inst.Dossier)|$($e.Inst.Gere)|$($e.Inst.Version)|$($e.Pub.Version)|$($e.Pub.Erreur)|$($e.Ouverte)|$($e.Trouvee)|$($e.Occupe)|$($e.Message)|$($e.MajDispo)|$resume"
    if ($script:CartesCle[$Appli.Id] -eq $cle) { return }
    $script:CartesCle[$Appli.Id] = $cle
    $sp = $script:Cartes[$Appli.Id]
    $sp.Children.Clear()

    [void]$sp.Children.Add((New-Text $Appli.Nom 20 $Appli.Couleur 'SemiBold'))
    $d = New-Text $Appli.Description 13 '#A9A3C9'; $d.Margin = '0,4,0,12'
    [void]$sp.Children.Add($d)

    # Pastilles : installée (version) ou non, ouverte ou non, mise à jour disponible
    $pastilles = New-Object System.Windows.Controls.WrapPanel
    $pastilles.Margin = '0,0,0,12'
    if ($e.Inst) {
        [void]$pastilles.Children.Add((New-Pastille "Version $(if ($e.Inst.Version) { $e.Inst.Version } else { '?' })" '#A9A3C9'))
        [void]$pastilles.Children.Add($(if ($e.Ouverte) { New-Pastille 'Ouvert' '#3DDC84' } else { New-Pastille 'Fermé' '#6F6894' }))
        if ($e.MajDispo) { [void]$pastilles.Children.Add((New-Pastille "Nouvelle version $($e.Pub.Version)" '#FFB020')) }
    } else {
        [void]$pastilles.Children.Add($(if ($e.Trouvee) { New-Pastille 'Trouvé sur ce PC' '#FFB020' } else { New-Pastille 'Pas installé' '#6F6894' }))
    }
    [void]$sp.Children.Add($pastilles)
    Add-ResumeCarte $sp $Appli $e.Resume

    if ($e.Inst -and -not $e.Inst.Gere) { [void]$sp.Children.Add((New-Text "Copie de $($e.Inst.Dossier), non gérée par Mindset." 12 '#6F6894')) }
    if (-not $e.Inst -and $e.Trouvee) { [void]$sp.Children.Add((New-Text "Une copie existe déjà dans $($e.Trouvee). Prends-la en charge pour continuer à l'utiliser : tes réglages et tes données sont gardés." 12 '#A9A3C9')) }

    # Boutons : ce qu'on peut faire dans cette situation
    $actions = New-Object System.Windows.Controls.WrapPanel
    $actions.Margin = '0,10,0,0'
    if ($e.Occupe) {
        [void]$sp.Children.Add((New-Text $e.Occupe 13 '#00E5FF'))
    } elseif (-not $e.Inst -and $e.Trouvee) {
        [void]$actions.Children.Add((New-Action 'Prendre en charge' 'BtnPrimary' $Appli.Id { Confirm-PriseEnCharge (Get-Appli $this.Tag) }))
        # Hors de Mindset, les applis ne s'ouvrent plus : seule une copie de travail (Git) peut servir telle quelle
        if (Test-DossierTravail $e.Trouvee) {
            [void]$actions.Children.Add((New-Action 'Utiliser telle quelle' 'BtnSecondary' $Appli.Id { $a = Get-Appli $this.Tag; Use-InstallationTrouvee $a $script:Trouvees[$a.Id] }))
        }
    } elseif (-not $e.Inst) {
        [void]$actions.Children.Add((New-Action 'Installer' 'BtnPrimary' $Appli.Id { Start-InstallAppli (Get-Appli $this.Tag) }))
        # Ses données existent mais aucune copie trouvée : elle est peut-être dans un dossier inhabituel
        if (Test-Path -LiteralPath $Appli.Donnees) {
            [void]$sp.Children.Add((New-Text "Tu avais déjà $($Appli.Nom) ? Montre son dossier pour qu'il soit pris en charge (sinon il resterait en double)." 12 '#A9A3C9'))
            [void]$actions.Children.Add((New-Action 'Choisir son dossier' 'BtnSecondary' $Appli.Id { Select-DossierAppli (Get-Appli $this.Tag) }))
        }
    } else {
        if ($e.MajDispo) { [void]$actions.Children.Add((New-Action 'Mettre à jour' 'BtnPrimary' $Appli.Id { Confirm-MiseAJour (Get-Appli $this.Tag) })) }
        [void]$actions.Children.Add((New-Action 'Ouvrir' $(if ($e.MajDispo) { 'BtnSecondary' } else { 'BtnPrimary' }) $Appli.Id { Open-AppliIci $this.Tag }))
        if ($e.Inst.Gere) { [void]$actions.Children.Add((New-Action 'Désinstaller' 'BtnSecondary' $Appli.Id { Confirm-Desinstallation (Get-Appli $this.Tag) })) }
        else { [void]$actions.Children.Add((New-Action 'Prendre en charge' 'BtnSecondary' $Appli.Id { $a = Get-Appli $this.Tag; Confirm-PriseEnCharge $a (Get-Installation $a).Dossier })) }
    }
    if ($actions.Children.Count) { [void]$sp.Children.Add($actions) }

    # « S'ouvre avec Mindset » : l'appli démarre en arrière-plan à l'ouverture de Mindset (et donc avec Windows)
    if ($e.Inst -and $e.Inst.Gere -and -not $e.Occupe -and (-not (Test-AppliAdmin $Appli $e.Inst) -or $MindsetAdmin)) {
        $ligne = New-Object System.Windows.Controls.DockPanel
        $ligne.Margin = '0,16,0,0'; $ligne.LastChildFill = $true
        $sw = New-InterrupteurOuverture $Appli.Id
        [System.Windows.Controls.DockPanel]::SetDock($sw, 'Right')
        [void]$ligne.Children.Add($sw)
        $txt = New-Object System.Windows.Controls.StackPanel
        $txt.VerticalAlignment = 'Center'
        [void]$txt.Children.Add((New-Text "S'ouvre avec Mindset" 13 '#ECEAF7'))
        $aide = if ($Appli.Id -eq 'evermind') { 'En arrière-plan : ses rappels sonnent même avant que tu ouvres son onglet.' } else { 'En arrière-plan, prêt dans son onglet.' }
        $a2 = New-Text $aide 11.5 '#6F6894'; $a2.TextWrapping = 'Wrap'; $a2.Margin = '0,2,12,0'
        [void]$txt.Children.Add($a2)
        [void]$ligne.Children.Add($txt)
        [void]$sp.Children.Add($ligne)
    }

    if ($e.Message -and -not $e.Occupe) { $m = New-Text $e.Message 12 '#A9A3C9'; $m.Margin = '0,12,0,0'; [void]$sp.Children.Add($m) }
    elseif ($e.Pub.Erreur -and -not $e.Inst) { $m = New-Text $e.Pub.Erreur 12 '#6F6894'; $m.Margin = '0,12,0,0'; [void]$sp.Children.Add($m) }
}

# Interrupteur « S'ouvre avec Mindset » d'une appli ; tous ceux de la même appli (carte, Paramètres) restent d'accord
$script:Interrupteurs = New-Object System.Collections.ArrayList
function New-InterrupteurOuverture([string]$Id) {
    $sw = New-Object System.Windows.Controls.CheckBox
    $sw.Style = $Window.FindResource('Switch'); $sw.Tag = $Id; $sw.VerticalAlignment = 'Center'
    $sw.IsChecked = Get-DemarrageAppli $Id
    $sw.Add_Click({
        $oui = [bool]$this.IsChecked
        Set-DemarrageAppli $this.Tag $oui
        foreach ($x in $script:Interrupteurs) { if ($x -ne $this -and $x.Tag -eq $this.Tag) { $x.IsChecked = $oui } }
    })
    [void]$script:Interrupteurs.Add($sw)
    $sw
}

function Update-Cartes {
    foreach ($a in $Applis) { Update-Carte $a }
}

function Update-Trouvees {
    foreach ($a in $Applis) { $script:Trouvees[$a.Id] = if (Get-Installation $a) { $null } else { Find-InstallationExistante $a } }
}

# ---------------------------------------------------------------------------
# Confirmations
# ---------------------------------------------------------------------------
function Confirm-MiseAJour($Appli) {
    $pub = $script:Publications[$Appli.Id]
    if (Test-AppliOuverte $Appli) {
        Show-Confirmation "Mettre à jour $($Appli.Nom) ?" "$($Appli.Nom) va être fermé le temps de la mise à jour (version $($pub.Version)). Ses réglages et ses données sont gardés." 'Fermer et mettre à jour' ([scriptblock]::Create("Start-InstallAppli (Get-Appli '$($Appli.Id)')"))
    } else { Start-InstallAppli $Appli }
}

function Confirm-PriseEnCharge($Appli, [string]$Dossier) {
    if (-not $Dossier) { $Dossier = $script:Trouvees[$Appli.Id] }
    if (-not $Dossier) { return }
    $ou = Get-DossierGere $Appli
    $txt = "Mindset installe la dernière version signée de $($Appli.Nom) dans $ou. Ses raccourcis directs et son lancement au démarrage sont retirés : il s'ouvrira depuis Mindset. Ses réglages et ses données sont gardés (ils rejoignent $SuiteDir\$($Appli.Nom))."
    $txt += if (Test-DossierTravail $Dossier) { "`n`n$Dossier est un dossier de travail : il est gardé tel quel." }
            else { "`n`nL'ancienne copie ($Dossier) est ensuite supprimée (seulement les fichiers de $($Appli.Nom))." }
    if (Test-AppliOuverte $Appli) { $txt += " $($Appli.Nom) va être fermé pendant l'opération." }
    Show-Confirmation "Prendre en charge $($Appli.Nom) ?" $txt 'Prendre en charge' ([scriptblock]::Create("Start-InstallAppli (Get-Appli '$($Appli.Id)') '$($Dossier -replace "'", "''")'"))
}

function Select-DossierAppli($Appli) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Le dossier de $($Appli.Nom) (celui qui contient $($Appli.Exe))"
    if ($dlg.ShowDialog() -ne 'OK') { return }
    if (-not (Test-DossierAppli $dlg.SelectedPath $Appli)) { Stop-Operation $Appli "Ce dossier ne contient pas $($Appli.Nom) ($($Appli.Exe) et $($Appli.Script))."; return }
    Confirm-PriseEnCharge $Appli $dlg.SelectedPath
}

function Confirm-Desinstallation($Appli) {
    $txt = if ($Appli.Desinstalleur) { "Le désinstalleur de $($Appli.Nom) va s'ouvrir : il remet comme avant les réglages de Windows qu'il a modifiés, puis supprime ses fichiers." }
           else { "$($Appli.Nom) va être fermé et ses fichiers supprimés (une demande de Windows). Ses données (réglages, rendez-vous) sont gardées : une réinstallation les retrouve." }
    Show-Confirmation "Désinstaller $($Appli.Nom) ?" $txt 'Désinstaller' ([scriptblock]::Create("Start-DesinstallAppli (Get-Appli '$($Appli.Id)')"))
}

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------
New-Onglet 'accueil' 'Accueil' '#ECEAF7'
foreach ($a in $Applis) { New-Onglet $a.Id $a.Nom $a.Couleur; New-Carte $a }
New-Onglet 'parametres' 'Paramètres' '#6F6894' $ui.OngletsBas
Update-Greeting
Update-Trouvees
Update-Cartes
Show-Page $(if ($EnTest -and $env:MINDSET_PAGE) { $env:MINDSET_PAGE } else { 'accueil' })
# ---------------------------------------------------------------------------
# Chercher les nouvelles versions (Mindset et ses applis) : au démarrage, toutes les heures, en rouvrant Mindset depuis
# l'horloge (si la dernière fois date de plus de 15 minutes), et avec « Actualiser » sur l'accueil. Les bandeaux et les
# cartes se mettent à jour d'eux-mêmes quand les réponses arrivent : plus besoin de fermer Mindset pour les voir.
# GitHub accepte 60 questions par heure : une recherche en pose une par appli, plus une pour Mindset.
# ---------------------------------------------------------------------------
$script:DernieresPublications = [datetime]::MinValue
function Invoke-Actualiser([switch]$Clic) {
    if ($env:MINDSET_SANS_RESEAU) { return }
    if ($Clic -and ((Get-Date) - $script:DernieresPublications).TotalSeconds -lt 20) { return }   # (clics répétés)
    $script:DernieresPublications = Get-Date
    Update-Publications
    Start-VerifMajMindset
    $ui.ActualiserInfo.Text = "Vérifié à $((Get-Date).ToString('HH:mm'))"
    if ($Clic) { Write-Log 'Actualiser : recherche des nouvelles versions' }
}
$ui.BtnActualiser.Add_Click({ Invoke-Actualiser -Clic })
Invoke-Actualiser

# État des applis relu toutes les 2 secondes ; versions publiées toutes les heures ; thème de la suite surveillé
$script:EtatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EtatTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:EtatTimer.Add_Tick({
    Update-Cartes; Update-Greeting
    if (((Get-Date) - $script:DernieresPublications).TotalHours -ge 1) { Invoke-Actualiser }
    try { Invoke-MajAuto } catch { Write-Log "Mise à jour automatique : $_" }
    # Thème de la suite changé ailleurs : Mindset le prend aussi (sauf pendant une opération). Comparé au thème choisi
    # (« pack:dofus »), pas à ses couleurs (« pack-dofus ») ; et jamais deux relances pour le même thème en une minute,
    # pour qu'un thème qui ne se charge pas ne fasse pas tourner Mindset en boucle.
    $t = (Read-Suite).theme
    if ($t -and $t -ne $ThemeSetting -and -not $script:Occupe.Count -and -not $EnTest) {
        $r = Get-Setting 'DerniereRelanceTheme' $null
        if ($r -and [string]$r.Theme -eq $t -and ((Get-Date) - [datetime][string]$r.Quand).TotalSeconds -lt 60) {
            if (-not $script:BoucleThemeNotee) { Write-Log "Thème de la suite $t : déjà relancé il y a moins d'une minute, pas de nouvelle relance"; $script:BoucleThemeNotee = $true }
        } else {
            Set-Setting 'DerniereRelanceTheme' ([ordered]@{ Theme = $t; Quand = (Get-Date).ToString('s') })
            Write-Log "Thème de la suite changé ailleurs : $t"
            Restart-Mindset
        }
    }
})
$script:EtatTimer.Start()
