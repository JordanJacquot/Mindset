# Mindset : les onglets de gauche, l'accueil et ses cartes (une par appli de apps.json).
# Chargé par Mindset.ps1, après interface.ps1 ($Window, $ui), applis.ps1 ($Applis) et installations.ps1.

$script:Onglets = @{}      # id -> bouton de l'onglet
$script:Cartes = @{}       # id -> contenu de la carte
$script:CartesCle = @{}    # id -> état affiché (la carte n'est redessinée que s'il change)
$script:Trouvees = @{}     # id -> copie trouvée sur le PC (cherchée au démarrage et après chaque opération)
$script:PageCourante = 'accueil'

function Get-Appli([string]$Id) { $Applis | Where-Object Id -eq $Id | Select-Object -First 1 }

function Update-Greeting {
    $h = (Get-Date).Hour
    $ui.Greeting.Text = if ($h -ge 18 -or $h -lt 5) { 'Bonsoir !' } else { 'Bonjour !' }
}

function New-Onglet([string]$Id, [string]$Texte, [string]$Couleur, $Panneau = $ui.Onglets) {
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
    [void]$Panneau.Children.Add($b)
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
    $ui.PageParametres.Visibility = if ($Id -eq 'parametres') { 'Visible' } else { 'Collapsed' }
    $ui.PageAppli.Visibility = if ($Id -in @('accueil', 'parametres')) { 'Collapsed' } else { 'Visible' }
    if ($ui.PageAppli.Visibility -eq 'Visible') { Update-PageAppli }
}

function Update-PageAppli {
    $a = Get-Appli $script:PageCourante
    if (-not $a) { return }
    $ui.PageAppliTitre.Text = $a.Nom
    $ui.PageAppliTitre.Foreground = Get-Brush $a.Couleur
    $ui.PageAppliTexte.Text = "$($a.Nom) s'affichera ici, directement dans Mindset. Pour l'instant, cette page est réservée : l'affichage intégré arrive avec la phase C du plan. En attendant, « Ouvrir » sur l'accueil le lance dans sa fenêtre."
    $ui.PageAppliEtat.Text = if (Test-AppliOuverte $a) { "$($a.Nom) est ouvert en ce moment." } else { "$($a.Nom) est fermé." }
}

# ---------------------------------------------------------------------------
# Cartes
# ---------------------------------------------------------------------------
function New-Carte($Appli) {
    $carte = New-Object System.Windows.Controls.Border
    $carte.Width = 370; $carte.Margin = '0,0,16,16'; $carte.Padding = '18,16'
    $carte.CornerRadius = 10; $carte.BorderThickness = 1
    $carte.Background = Get-Brush '#06050F'; $carte.BorderBrush = Get-Brush '#2A2450'
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
    }
}

function Update-Carte($Appli) {
    $e = Get-EtatCarte $Appli
    $cle = "$($e.Inst.Dossier)|$($e.Inst.Gere)|$($e.Inst.Version)|$($e.Pub.Version)|$($e.Pub.Erreur)|$($e.Ouverte)|$($e.Trouvee)|$($e.Occupe)|$($e.Message)|$($e.MajDispo)"
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

    if ($e.Inst -and -not $e.Inst.Gere) { [void]$sp.Children.Add((New-Text "Copie de $($e.Inst.Dossier), non gérée par Mindset." 12 '#6F6894')) }
    if (-not $e.Inst -and $e.Trouvee) { [void]$sp.Children.Add((New-Text "Une copie existe déjà dans $($e.Trouvee)." 12 '#A9A3C9')) }

    # Boutons : ce qu'on peut faire dans cette situation
    $actions = New-Object System.Windows.Controls.WrapPanel
    $actions.Margin = '0,10,0,0'
    if ($e.Occupe) {
        [void]$sp.Children.Add((New-Text $e.Occupe 13 '#00E5FF'))
    } elseif (-not $e.Inst -and $e.Trouvee) {
        [void]$actions.Children.Add((New-Action 'Prendre en charge' 'BtnPrimary' $Appli.Id { Confirm-PriseEnCharge (Get-Appli $this.Tag) }))
        [void]$actions.Children.Add((New-Action 'Utiliser telle quelle' 'BtnSecondary' $Appli.Id { $a = Get-Appli $this.Tag; Use-InstallationTrouvee $a $script:Trouvees[$a.Id] }))
    } elseif (-not $e.Inst) {
        [void]$actions.Children.Add((New-Action 'Installer' 'BtnPrimary' $Appli.Id { Start-InstallAppli (Get-Appli $this.Tag) }))
        # Ses données existent mais aucune copie trouvée : elle est peut-être dans un dossier inhabituel
        if (Test-Path -LiteralPath $Appli.Donnees) {
            [void]$sp.Children.Add((New-Text "Tu avais déjà $($Appli.Nom) ? Montre son dossier pour qu'il soit pris en charge (sinon il resterait en double)." 12 '#A9A3C9'))
            [void]$actions.Children.Add((New-Action 'Choisir son dossier' 'BtnSecondary' $Appli.Id { Select-DossierAppli (Get-Appli $this.Tag) }))
        }
    } else {
        if ($e.MajDispo) { [void]$actions.Children.Add((New-Action 'Mettre à jour' 'BtnPrimary' $Appli.Id { Confirm-MiseAJour (Get-Appli $this.Tag) })) }
        [void]$actions.Children.Add((New-Action 'Ouvrir' $(if ($e.MajDispo) { 'BtnSecondary' } else { 'BtnPrimary' }) $Appli.Id { Open-Appli (Get-Appli $this.Tag) }))
        if ($e.Inst.Gere) { [void]$actions.Children.Add((New-Action 'Désinstaller' 'BtnSecondary' $Appli.Id { Confirm-Desinstallation (Get-Appli $this.Tag) })) }
        else { [void]$actions.Children.Add((New-Action 'Prendre en charge' 'BtnSecondary' $Appli.Id { $a = Get-Appli $this.Tag; Confirm-PriseEnCharge $a (Get-Installation $a).Dossier })) }
    }
    if ($actions.Children.Count) { [void]$sp.Children.Add($actions) }

    if ($e.Message -and -not $e.Occupe) { $m = New-Text $e.Message 12 '#A9A3C9'; $m.Margin = '0,12,0,0'; [void]$sp.Children.Add($m) }
    elseif ($e.Pub.Erreur -and -not $e.Inst) { $m = New-Text $e.Pub.Erreur 12 '#6F6894'; $m.Margin = '0,12,0,0'; [void]$sp.Children.Add($m) }
}

function Update-Cartes {
    foreach ($a in $Applis) { Update-Carte $a }
    if ($script:PageCourante -notin @('accueil', 'parametres')) { Update-PageAppli }
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
    $txt += if ((Test-Path -LiteralPath (Join-Path $Dossier '.git')) -or (Test-Path -LiteralPath (Join-Path (Split-Path $Dossier -Parent) '.git'))) { "`n`n$Dossier est un dossier de travail : il est gardé tel quel." }
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
if (-not $env:MINDSET_SANS_RESEAU) { Update-Publications }

# État des applis relu toutes les 2 secondes ; versions publiées toutes les 6 heures ; thème de la suite surveillé
$script:DernieresPublications = Get-Date
$script:EtatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EtatTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:EtatTimer.Add_Tick({
    Update-Cartes; Update-Greeting
    if (((Get-Date) - $script:DernieresPublications).TotalHours -ge 6) { $script:DernieresPublications = Get-Date; Update-Publications }
    # Thème changé depuis une appli : Mindset le prend aussi (sauf pendant une opération)
    $t = (Read-Suite).theme
    if ($t -and $t -ne $ThemeId -and -not $script:Occupe.Count -and -not $EnTest) { Write-Log "Thème de la suite changé ailleurs : $t"; Restart-Mindset }
})
$script:EtatTimer.Start()
