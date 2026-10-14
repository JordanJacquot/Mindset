# Mindset : Nevermind et Evermind affichés dans la fenêtre de Mindset (onglet de l'appli).
#
# La vraie fenêtre de l'appli devient une fenêtre enfant de la zone centrale (MSIntegration dans natif.cs) :
#   - l'appli ne tourne pas : Mindset la lance cachée (-Demarrage), attend sa fenêtre, puis l'accroche ;
#   - elle tourne déjà (près de l'horloge, ou dans sa fenêtre) : sa fenêtre est accrochée telle quelle ;
#   - elle se relance (nouveau thème) ou se ferme : Mindset le voit, et la raccroche quand elle revient ;
#   - Mindset se cache près de l'horloge : les applis se cachent avec lui ;
#   - Mindset quitte : chaque fenêtre est rendue telle qu'elle était, cachée, et l'appli continue près de l'horloge
#     (les rappels d'Evermind sonnent toujours).
# Une appli en administrateur (Nevermind) ne peut être accrochée que par un Mindset en administrateur : sinon, elle
# s'ouvre dans sa propre fenêtre.
# Chargé par Mindset.ps1 après accueil.ps1 (Show-Page, Open-Appli).

Add-Type -AssemblyName WindowsFormsIntegration

$script:Integrees = @{}   # id -> { Hote, Panneau, Fenetre, Styles, Etat }
$MindsetAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-Integration([string]$Id) {
    $i = $script:Integrees[$Id]
    if ($i) { return $i }
    # La place de l'appli : un panneau Windows Forms (il a un vrai handle de fenêtre, que la fenêtre de l'appli prend pour parent)
    $panneau = New-Object System.Windows.Forms.Panel
    $panneau.BackColor = [System.Drawing.Color]::Black
    $hote = New-Object System.Windows.Forms.Integration.WindowsFormsHost
    $hote.Child = $panneau; $hote.Visibility = 'Collapsed'
    [void]$ui.PageAppliHotes.Children.Add($hote)
    $i = @{ Id = $Id; Hote = $hote; Panneau = $panneau; Fenetre = [IntPtr]::Zero; Styles = $null; Etat = 'vide'; Depuis = Get-Date }
    $panneau.Tag = $Id
    $panneau.Add_Resize({ param($s) $x = $script:Integrees[$s.Tag]; if ($x -and $x.Fenetre -ne [IntPtr]::Zero) { [MSIntegration]::Redimensionner($x.Fenetre, $s.ClientSize.Width, $s.ClientSize.Height) } })
    $script:Integrees[$Id] = $i
    $i
}

# La fenêtre principale de l'appli si elle tourne (même cachée près de l'horloge)
function Find-FenetreAppli($Appli) {
    foreach ($p in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Appli.Exe)) -ErrorAction SilentlyContinue)) {
        $h = [MSIntegration]::Trouver($p.Id, $Appli.Nom)
        if ($h -ne [IntPtr]::Zero) { return $h }
    }
    [IntPtr]::Zero
}

# Onglet d'une appli ouvert : l'afficher ici (en la lançant si besoin)
function Show-AppliIntegree($Appli) {
    $i = Get-Integration $Appli.Id
    $inst = Get-Installation $Appli
    if (-not $inst) { Set-EtatPageAppli $Appli "$($Appli.Nom) n'est pas installé." 'Installe-le depuis l''accueil.' $false; return }
    # En test automatique, jamais les vraies applis : ni lancées, ni accrochées
    if ($EnTest -and -not $env:MINDSET_INTEGRATION_TEST) { Set-EtatPageAppli $Appli "$($Appli.Nom) s'affichera ici" '(test : les vraies applis ne sont pas lancées)' $false; return }
    if ($i.Fenetre -ne [IntPtr]::Zero -and [MSIntegration]::IsWindow($i.Fenetre)) { Update-HotesVisibles; return }
    # Réduite près de l'horloge, ou rendue à sa fenêtre : elle reste où elle est tant qu'on ne demande pas « Afficher ici »
    if ($i.Etat -eq 'cachee') { Set-EtatPageAppli $Appli "$($Appli.Nom) est réduit près de l'horloge" 'Il tourne toujours.' $false; Show-BoutonAfficherIci $Appli; return }
    if ($i.Etat -eq 'detachee') { Set-EtatPageAppli $Appli "$($Appli.Nom) est dans sa propre fenêtre" '' $false; Show-BoutonAfficherIci $Appli; return }
    if ($Appli.Admin -and -not $MindsetAdmin) {
        Set-EtatPageAppli $Appli "$($Appli.Nom) s'ouvre dans sa propre fenêtre" "Il tourne en administrateur : pour l'afficher ici, Mindset doit l'être aussi (prochaine étape)." $true
        return
    }
    $h = Find-FenetreAppli $Appli
    if ($h -ne [IntPtr]::Zero) { Connect-Fenetre $Appli $h; return }
    # Pas lancée : on la lance cachée, puis on attend sa fenêtre
    if ($i.Etat -ne 'lancement') {
        $i.Etat = 'lancement'; $i.Depuis = Get-Date
        Open-Appli $Appli -Demarrage
    }
    Set-EtatPageAppli $Appli "Ouverture de $($Appli.Nom)..." '' $false
    $script:IntegrationTimer.Start()
}

function Connect-Fenetre($Appli, [IntPtr]$Fenetre) {
    $i = Get-Integration $Appli.Id
    $i.Hote.Visibility = 'Visible'   # (le panneau doit exister à l'écran pour avoir sa taille)
    $i.Hote.UpdateLayout()
    $taille = $i.Panneau.ClientSize
    $styles = [MSIntegration]::Accrocher($Fenetre, $i.Panneau.Handle, [math]::Max(200, $taille.Width), [math]::Max(200, $taille.Height))
    if (-not $styles) {
        $i.Hote.Visibility = 'Collapsed'; $i.Etat = 'refus'
        Set-EtatPageAppli $Appli "$($Appli.Nom) n'a pas pu s'afficher ici" 'Windows a refusé de l''accrocher : il reste dans sa propre fenêtre.' $true
        Write-Log "Intégration de $($Appli.Nom) refusée par Windows"
        return
    }
    $i.Fenetre = $Fenetre; $i.Styles = $styles; $i.Etat = 'affiche'
    Write-Log "$($Appli.Nom) affiché dans Mindset"
    Update-HotesVisibles
    [MSIntegration]::Focus($Fenetre)
    $script:IntegrationTimer.Start()   # (surveille sa fermeture ou sa relance)
}

# Le texte de la page quand l'appli n'est pas (encore) affichée
function Set-EtatPageAppli($Appli, [string]$Titre, [string]$Texte, [bool]$BoutonFenetre) {
    if ($script:PageCourante -ne $Appli.Id) { return }
    $ui.PageAppliTitre.Text = $Titre
    $ui.PageAppliTitre.Foreground = Get-Brush $Appli.Couleur
    $ui.PageAppliTexte.Text = $Texte
    $ui.PageAppliTexte.Visibility = if ($Texte) { 'Visible' } else { 'Collapsed' }
    $ui.BtnPageAppliFenetre.Visibility = if ($BoutonFenetre) { 'Visible' } else { 'Collapsed' }
    $ui.BtnPageAppliFenetre.Tag = $Appli.Id
    $ui.BtnPageAppliIci.Visibility = 'Collapsed'
    $ui.PageAppliEtat.Text = ''
}
$ui.BtnPageAppliFenetre.Add_Click({ Open-Appli (Get-Appli $this.Tag) })

# Une seule appli visible : celle de l'onglet ouvert, et aucune quand une fenêtre de Mindset passe par-dessus
# (une fenêtre accrochée se dessine toujours au-dessus de Mindset : elle masquerait la question)
function Update-HotesVisibles {
    $dessus = $ui.Confirmation.Visibility -eq 'Visible' -or $ui.Fermeture.Visibility -eq 'Visible'
    foreach ($i in $script:Integrees.Values) {
        $voir = (-not $dessus) -and $script:PageCourante -eq $i.Id -and $i.Fenetre -ne [IntPtr]::Zero
        $i.Hote.Visibility = if ($voir) { 'Visible' } else { 'Collapsed' }
    }
    $affichee = $script:Integrees[$script:PageCourante]
    $montree = $affichee -and $affichee.Fenetre -ne [IntPtr]::Zero
    $ui.PageAppliMessage.Visibility = if ($montree) { 'Collapsed' } else { 'Visible' }
    $ui.PageAppliCadre.Visibility = if ($montree) { 'Visible' } else { 'Collapsed' }
    if ($montree) { $a = Get-Appli $affichee.Id; $ui.PageAppliNom.Text = $a.Nom; $ui.PageAppliNom.Foreground = Get-Brush $a.Couleur }
}

# Barre de l'appli : la fermer (sa propre règle s'applique : elle demande, se réduit ou quitte), ou la rendre à sa fenêtre
$ui.BtnAppliFermer.Add_Click({
    $i = $script:Integrees[$script:PageCourante]
    if ($i -and $i.Fenetre -ne [IntPtr]::Zero) { [MSIntegration]::Fermer($i.Fenetre) }
})
$ui.BtnAppliDetacher.Add_Click({
    $i = $script:Integrees[$script:PageCourante]
    if (-not $i -or $i.Fenetre -eq [IntPtr]::Zero) { return }
    [MSIntegration]::Detacher($i.Fenetre, $i.Styles[0], $i.Styles[1])
    $a = Get-Appli $i.Id
    $i.Fenetre = [IntPtr]::Zero; $i.Styles = $null; $i.Etat = 'detachee'
    Update-HotesVisibles
    Set-EtatPageAppli $a "$($a.Nom) est dans sa propre fenêtre" 'Clique sur « Afficher ici » pour le remettre dans Mindset.' $false
    Show-BoutonAfficherIci $a
})

# « Afficher ici » : l'appli (réduite près de l'horloge, ou dans sa fenêtre) revient dans Mindset
function Show-BoutonAfficherIci($Appli) {
    $ui.BtnPageAppliIci.Visibility = 'Visible'; $ui.BtnPageAppliIci.Tag = $Appli.Id
}
$ui.BtnPageAppliIci.Add_Click({
    $a = Get-Appli $this.Tag
    $ui.BtnPageAppliIci.Visibility = 'Collapsed'
    $i = Get-Integration $a.Id; $i.Etat = 'vide'
    Show-AppliIntegree $a
})

# Surveillance : fenêtre attendue (lancement, relance pour un thème), fenêtre fermée
$script:IntegrationTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:IntegrationTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:IntegrationTimer.Add_Tick({
    $attente = $false
    foreach ($i in @($script:Integrees.Values)) {
        $a = Get-Appli $i.Id
        if ($i.Fenetre -ne [IntPtr]::Zero -and -not [MSIntegration]::IsWindow($i.Fenetre)) {
            # Fermée, ou relancée (nouveau thème, mise à jour) : on attend la nouvelle fenêtre quelques secondes
            $i.Fenetre = [IntPtr]::Zero; $i.Styles = $null; $i.Etat = 'relance'; $i.Depuis = Get-Date
            Update-HotesVisibles
            Set-EtatPageAppli $a "$($a.Nom) se relance..." '' $false
        } elseif ($i.Fenetre -ne [IntPtr]::Zero -and -not [MSIntegration]::EstMontree($i.Fenetre)) {
            # Elle s'est cachée elle-même (réduite près de l'horloge, par sa croix) : rendue telle quelle, elle y reste
            [MSIntegration]::Liberer($i.Fenetre, $i.Styles[0], $i.Styles[1])
            $i.Fenetre = [IntPtr]::Zero; $i.Styles = $null; $i.Etat = 'cachee'
            Update-HotesVisibles
            Set-EtatPageAppli $a "$($a.Nom) est réduit près de l'horloge" 'Il tourne toujours.' $false
            Show-BoutonAfficherIci $a
        }
        if ($i.Etat -in 'lancement', 'relance') {
            $h = Find-FenetreAppli $a
            if ($h -ne [IntPtr]::Zero) { Connect-Fenetre $a $h; continue }
            if (((Get-Date) - $i.Depuis).TotalSeconds -gt 25) {
                $i.Etat = 'vide'
                Set-EtatPageAppli $a "$($a.Nom) est fermé" '' $false
                Show-BoutonAfficherIci $a
            } else { $attente = $true }
        }
    }
    if (-not $attente -and -not @($script:Integrees.Values | Where-Object { $_.Fenetre -ne [IntPtr]::Zero }).Count) { $script:IntegrationTimer.Stop() }
})

# Mindset quitte : chaque appli retrouve sa fenêtre, cachée près de l'horloge
function Disconnect-Applis {
    foreach ($i in $script:Integrees.Values) {
        if ($i.Fenetre -ne [IntPtr]::Zero -and $i.Styles) { try { [MSIntegration]::Liberer($i.Fenetre, $i.Styles[0], $i.Styles[1]) } catch {} }
        $i.Fenetre = [IntPtr]::Zero
    }
}
$Window.Add_Closed({ Disconnect-Applis })

# Une fenêtre de Mindset passe par-dessus (question, confirmation) : l'appli affichée s'efface le temps qu'elle s'en aille
$ui.Confirmation.Add_IsVisibleChanged({ Update-HotesVisibles })
$ui.Fermeture.Add_IsVisibleChanged({ Update-HotesVisibles })

# ---------------------------------------------------------------------------
# Quitter Mindset pour de bon : les applis se ferment aussi. Chacune reçoit une demande (« quitter.demande » dans son
# dossier de données, qu'elle surveille) et se ferme proprement, comme par son menu « Quitter ». Mindset.ps1 attend
# ensuite quelques secondes, et ferme lui-même une appli qui ne répond pas (si Windows le lui permet).
# ---------------------------------------------------------------------------
function Request-FermetureApplis {
    foreach ($a in $Applis) {
        if (-not (Test-AppliOuverte $a)) { continue }
        foreach ($d in @((Get-DossierDonnees $a), $a.Donnees) | Select-Object -Unique) {
            if ($d -and (Test-Path -LiteralPath $d)) { try { [IO.File]::WriteAllText((Join-Path $d 'quitter.demande'), [string]$PID) } catch {} }
        }
        Write-Log "Fermeture de $($a.Nom) demandée (Mindset quitte)"
    }
}
$Window.Add_Closed({ if ($script:FermerApplis) { Request-FermetureApplis } })
