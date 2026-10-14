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

function New-Onglet([string]$Id, [string]$Texte, [string]$Couleur, $Panneau = $ui.Onglets) {
    $b = New-Button '' 'Onglet'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    # Pastille de couleur, ou l'icône animée du thème personnalisé (immobile, animée au survol)
    $icone = New-IconeOnglet $Id
    if ($icone) {
        [void]$sp.Children.Add($icone.Image)
        $b.Resources['Anim'] = $icone.Anim
        $b.Add_MouseEnter({ param($s) $a = $s.Resources['Anim']; if ($a.Tag.Frames.Count -gt 1) { $a.Start() } })
        $b.Add_MouseLeave({ param($s) $a = $s.Resources['Anim']; $a.Stop(); $a.Tag.Frame = 0; $a.Tag.Img.Source = $a.Tag.Frames[0] })
    } else {
        $pt = New-Object System.Windows.Shapes.Ellipse
        $pt.Width = 8; $pt.Height = 8; $pt.Fill = Get-Brush $Couleur; $pt.Margin = '0,0,10,0'; $pt.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($pt)
    }
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

# Le résumé d'une appli sur sa carte (rien si elle n'a encore rien écrit)
function Add-ResumeCarte($Sp, $Appli, $Etat) {
    if (-not $Etat) { return }
    $box = New-Object System.Windows.Controls.StackPanel
    $box.Margin = '0,0,0,6'
    if ($Appli.Id -eq 'nevermind') {
        $scores = New-Object System.Windows.Controls.WrapPanel
        foreach ($s in @(@('Optimisation', $Etat.Score, '#00E5FF'), @('Protection', $Etat.Protection, '#FF2EB5'))) {
            if ($null -eq $s[1]) { continue }
            $p = New-Object System.Windows.Controls.StackPanel; $p.Margin = '0,0,26,8'
            $n = New-Object System.Windows.Controls.TextBlock
            [void]$n.Inlines.Add((New-Object System.Windows.Documents.Run "$($s[1])"))
            $r2 = New-Object System.Windows.Documents.Run ' /100'; $r2.FontSize = 12; $r2.Foreground = Get-Brush '#6F6894'; [void]$n.Inlines.Add($r2)
            $n.FontSize = 26; $n.FontWeight = 'SemiBold'; $n.Foreground = Get-Brush $s[2]
            [void]$p.Children.Add($n); [void]$p.Children.Add((New-Text $s[0] 11.5 '#A9A3C9'))
            [void]$scores.Children.Add($p)
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
    $resume = if ($e.Resume) { if ($Appli.Id -eq 'evermind') { ((Get-ProchainsRdv $e.Resume | ForEach-Object { "$($_.Id)$($_.Quand)$($_.Titre)" }) -join ',') + "|$((Get-Date).Date)" } else { "$($e.Resume.Score)/$($e.Resume.Protection)/$($e.Resume.AFaire)/$($e.Resume.Urgent)" } }
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
    if ($e.Inst -and $e.Inst.Gere -and -not $e.Occupe -and (-not $Appli.Admin -or $MindsetAdmin)) {
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
if (-not $env:MINDSET_SANS_RESEAU) { Update-Publications; Start-VerifMajMindset }

# État des applis relu toutes les 2 secondes ; versions publiées toutes les 6 heures ; thème de la suite surveillé
$script:DernieresPublications = Get-Date
$script:EtatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EtatTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:EtatTimer.Add_Tick({
    Update-Cartes; Update-Greeting
    if (((Get-Date) - $script:DernieresPublications).TotalHours -ge 6) { $script:DernieresPublications = Get-Date; Update-Publications; Start-VerifMajMindset }
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
