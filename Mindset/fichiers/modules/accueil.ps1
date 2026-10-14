# Mindset : les onglets de gauche, l'accueil et ses cartes (une par appli de apps.json).
# Chargé par Mindset.ps1, après interface.ps1 ($Window, $ui) et applis.ps1 ($Applis).

$script:Onglets = @{}      # id -> bouton de l'onglet
$script:CartesEtat = @{}   # id -> pastille d'état de la carte
$script:PageCourante = 'accueil'

function Update-Greeting {
    $h = (Get-Date).Hour
    $ui.Greeting.Text = if ($h -ge 18 -or $h -lt 5) { 'Bonsoir !' } else { 'Bonjour !' }
}

function New-Onglet([string]$Id, [string]$Texte, [string]$Couleur) {
    $b = New-Button '' 'Onglet'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $pt = New-Object System.Windows.Shapes.Ellipse
    $pt.Width = 8; $pt.Height = 8; $pt.Fill = Get-Brush $Couleur; $pt.Margin = '0,0,10,0'; $pt.VerticalAlignment = 'Center'
    [void]$sp.Children.Add($pt)
    [void]$sp.Children.Add((New-Text $Texte 14 '#A9A3C9'))
    $b.Content = $sp
    $b.Tag = $Id
    $b.Add_Click({ Show-Page $this.Tag })
    [void]$ui.Onglets.Children.Add($b)
    $script:Onglets[$Id] = $b
}

function Show-Page([string]$Id) {
    $script:PageCourante = $Id
    foreach ($k in $script:Onglets.Keys) {
        $b = $script:Onglets[$k]; $on = ($k -eq $Id)
        $b.Background = if ($on) { Get-Brush '#141030' } else { [System.Windows.Media.Brushes]::Transparent }
        $b.Content.Children[1].Foreground = Get-Brush $(if ($on) { '#ECEAF7' } else { '#A9A3C9' })
    }
    $ui.PageAccueil.Visibility = if ($Id -eq 'accueil') { 'Visible' } else { 'Collapsed' }
    $ui.PageAppli.Visibility = if ($Id -eq 'accueil') { 'Collapsed' } else { 'Visible' }
    if ($Id -ne 'accueil') { Update-PageAppli }
}

function Update-PageAppli {
    $a = $Applis | Where-Object Id -eq $script:PageCourante | Select-Object -First 1
    if (-not $a) { return }
    $ui.PageAppliTitre.Text = $a.Nom
    $ui.PageAppliTitre.Foreground = Get-Brush $a.Couleur
    $ui.PageAppliTexte.Text = "$($a.Nom) s'affichera ici, directement dans Mindset. Pour l'instant, cette page est réservée : l'affichage intégré arrive avec la phase C du plan."
    $ui.PageAppliEtat.Text = if (Test-AppliOuverte $a) { "$($a.Nom) est ouvert en ce moment." } else { "$($a.Nom) est fermé." }
}

function New-Carte($Appli) {
    $carte = New-Object System.Windows.Controls.Border
    $carte.Width = 300; $carte.Margin = '0,0,16,16'; $carte.Padding = '18,16'
    $carte.CornerRadius = 10; $carte.BorderThickness = 1
    $carte.Background = Get-Brush '#06050F'; $carte.BorderBrush = Get-Brush '#2A2450'

    $sp = New-Object System.Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $Appli.Nom 20 $Appli.Couleur 'SemiBold'))
    $d = New-Text $Appli.Description 13 '#A9A3C9'; $d.Margin = '0,4,0,12'
    [void]$sp.Children.Add($d)

    # Pastille d'état : ouvert / fermé (pas installé, mises à jour : phase B)
    $etat = New-Object System.Windows.Controls.Border
    $etat.CornerRadius = 10; $etat.BorderThickness = 1; $etat.Padding = '9,2'; $etat.HorizontalAlignment = 'Left'; $etat.Margin = '0,0,0,14'
    $etat.Child = New-Text '' 11
    [void]$sp.Children.Add($etat)
    $script:CartesEtat[$Appli.Id] = $etat

    $btn = New-Button 'Afficher' 'BtnPrimary'
    $btn.Tag = $Appli.Id; $btn.HorizontalAlignment = 'Left'
    $btn.Add_Click({ Show-Page $this.Tag })
    [void]$sp.Children.Add($btn)

    $carte.Child = $sp
    [void]$ui.Cartes.Children.Add($carte)
}

function Update-Etats {
    foreach ($a in $Applis) {
        $p = $script:CartesEtat[$a.Id]; if (-not $p) { continue }
        $ouvert = Test-AppliOuverte $a
        $c = if ($ouvert) { '#3DDC84' } else { '#6F6894' }
        $p.BorderBrush = Get-Brush $c
        $p.Child.Foreground = Get-Brush $c
        $p.Child.Text = if ($ouvert) { 'Ouvert' } else { 'Fermé' }
    }
    if ($script:PageCourante -ne 'accueil') { Update-PageAppli }
}

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------
New-Onglet 'accueil' 'Accueil' '#ECEAF7'
foreach ($a in $Applis) { New-Onglet $a.Id $a.Nom $a.Couleur; New-Carte $a }
Update-Greeting
Update-Etats
Show-Page 'accueil'

# L'état des applis est relu toutes les 2 secondes (ouvrir ou fermer une appli met la carte à jour)
$script:EtatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EtatTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:EtatTimer.Add_Tick({ Update-Etats; Update-Greeting })
$script:EtatTimer.Start()
