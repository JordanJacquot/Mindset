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
    foreach ($p in @(Get-ProcessusAppli $Appli -Hote)) {   # (par son chemin : son hôte s'appelle Mindset.exe, comme Mindset)
        $h = [MSIntegration]::Trouver($p.Id, $Appli.Nom)
        if ($h -ne [IntPtr]::Zero) { return $h }
    }
    [IntPtr]::Zero
}

# Lancée cachée (-Demarrage), sans passer par sa propre fenêtre, si sa version sait se dessiner une fois accrochée ;
# sinon lancée normalement (une version plus ancienne lancée cachée resterait noire)
function Start-AppliCachee($Appli) {
    $inst = Get-Installation $Appli
    $cache = $Appli.CacheDepuis -and $inst.Version -and -not (Test-VersionPlusRecente $Appli.CacheDepuis $inst.Version)
    if ($cache) { Open-Appli $Appli -Demarrage } else { Open-Appli $Appli }
}

# Arrête les programmes de l'appli ouverts depuis plus d'une minute sans aucune fenêtre (même cachée près de l'horloge) :
# fermée, son processus ne s'est pas terminé. Seulement ceux du dossier où Mindset l'a installée. Rend le nombre arrêté.
function Stop-AppliBloquee($Appli) {
    $inst = Get-Installation $Appli
    if (-not $inst) { return 0 }
    $n = 0
    foreach ($p in @(Get-ProcessusAppli $Appli -Hote)) {   # (son programme principal, dans ce dossier : jamais Mindset)
        $age = try { ((Get-Date) - $p.StartTime).TotalSeconds } catch { 0 }
        if ($age -lt 60 -or [MSIntegration]::Trouver($p.Id, $Appli.Nom) -ne [IntPtr]::Zero) { continue }
        try { $p.Kill(); [void]$p.WaitForExit(3000); $n++ } catch { Write-Log "$($Appli.Nom) bloqué sans fenêtre, arrêt refusé par Windows : $_" }
    }
    $n
}

# Onglet d'une appli ouvert : elle s'affiche ici si elle tourne ; fermée, son écran « Ouvrir » attend un clic.
# -Lancer (bouton « Ouvrir », carte de l'accueil, menu de l'horloge) : elle est lancée si besoin.
function Show-AppliIntegree($Appli, [switch]$Lancer) {
    $i = Get-Integration $Appli.Id
    if ($EnTest -and $env:MINDSET_ECRAN) { Show-EcranOuvrir $Appli "$($Appli.Nom) est fermé."; return }   # (capture de l'écran « Ouvrir »)
    if ($EnTest -and $env:MINDSET_JAUGE) { $i.Depuis = (Get-Date).AddSeconds(-[double]$env:MINDSET_JAUGE); Show-JaugeAppli $Appli 'Ouverture...'; return }   # (capture de la jauge)
    $inst = Get-Installation $Appli
    if (-not $inst) { Set-EtatPageAppli $Appli "$($Appli.Nom) n'est pas installé." 'Installe-le depuis l''accueil.' $false; return }
    # En test automatique, jamais les vraies applis : ni lancées, ni accrochées
    if ($EnTest -and -not $env:MINDSET_INTEGRATION_TEST) { Set-EtatPageAppli $Appli "$($Appli.Nom) s'affichera ici" '(test : les vraies applis ne sont pas lancées)' $false; return }
    if ($i.Fenetre -ne [IntPtr]::Zero -and [MSIntegration]::IsWindow($i.Fenetre)) { Update-HotesVisibles; return }
    # (les applis ne s'ouvrent que dans Mindset : sans ses droits, Nevermind n'est pas lancé à côté)
    if ((Test-AppliAdmin $Appli $inst) -and -not $MindsetAdmin) {
        Set-EtatPageAppli $Appli "$($Appli.Nom) doit être mis à jour" "Cette version demande les droits administrateur. Mets-le à jour depuis sa carte de l'accueil : la nouvelle version n'en a plus besoin." $false
        return
    }
    # Elle tourne (réduite près de l'horloge, dans sa propre fenêtre) : elle revient ici directement
    $h = Find-FenetreAppli $Appli
    if ($h -ne [IntPtr]::Zero) { Connect-Fenetre $Appli $h; return }
    $enCours = $i.Etat -eq 'lancement' -or ($i.Etat -eq 'relance' -and (Test-NouveauProcessus $Appli $i))
    if (-not $enCours -and $i.Etat -ne 'relance' -and (Test-AppliOuverte $Appli)) { $i.Etat = 'lancement'; $i.Depuis = Get-Date; $i.Debloquee = $false; $enCours = $true }   # (elle démarre : sa fenêtre arrive)
    # Fermée, et rien ne demande de la lancer : son écran, avec « Ouvrir »
    if (-not $enCours -and -not $Lancer) { $i.Etat = 'vide'; Show-EcranOuvrir $Appli "$($Appli.Nom) est fermé."; return }
    # À lancer : cachée, puis on attend sa fenêtre
    if (-not $enCours) {
        $i.Etat = 'lancement'; $i.Depuis = Get-Date; $i.Debloquee = $false
        Start-AppliCachee $Appli
    }
    Show-JaugeAppli $Appli 'Ouverture...'
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
        Set-EtatPageAppli $Appli "$($Appli.Nom) n'a pas pu s'afficher ici" 'Windows a refusé de l''accrocher : quitte tout (icône près de l''horloge) puis rouvre Mindset.' $false
        Write-Log "Intégration de $($Appli.Nom) refusée par Windows"
        return
    }
    if ($i.Etat -eq 'lancement') { Save-DureeOuverture $Appli $i.Depuis }
    $i.Fenetre = $Fenetre; $i.Styles = $styles; $i.Etat = 'affiche'; $i.Pid = [MSIntegration]::Processus($Fenetre)
    Write-Log "$($Appli.Nom) affiché dans Mindset"
    Update-HotesVisibles
    [MSIntegration]::Focus($Fenetre)
    $script:IntegrationTimer.Start()   # (surveille sa fermeture ou sa relance)
}

# Le texte de la page quand l'appli n'est pas (encore) affichée
function Set-EtatPageAppli($Appli, [string]$Titre, [string]$Texte, [bool]$BoutonFenetre) {
    if ($script:PageCourante -ne $Appli.Id) { return }
    Stop-JaugeAppli
    $ui.PageAppliTitre.Text = $Titre
    $ui.PageAppliTitre.Foreground = Get-Brush $Appli.Couleur
    $ui.PageAppliTexte.Text = $Texte
    $ui.PageAppliTexte.Visibility = if ($Texte) { 'Visible' } else { 'Collapsed' }
    $ui.BtnPageAppliIci.Visibility = 'Collapsed'
    $ui.PageAppliEtat.Text = ''
}

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
    # La jauge ne reste que sur la page de l'appli qui s'ouvre, tant qu'elle n'est pas affichée
    if ($script:Jauge -and ($montree -or $script:Jauge.Id -ne $script:PageCourante)) { Stop-JaugeAppli }
    $ui.PageAppliMessage.Visibility = if ($montree) { 'Collapsed' } else { 'Visible' }
    $ui.PageAppliCadre.Visibility = if ($montree) { 'Visible' } else { 'Collapsed' }
    Update-BarreAppli
}

# Une seule barre : celle de Mindset (Menu, Fermer) s'efface quand l'appli affichée a la sienne
function Update-BarreAppli {
    $affichee = $script:Integrees[$script:PageCourante]
    $propre = $affichee -and [MSIntegration]::BarrePropre($affichee.Fenetre)
    $v = if ($propre) { 'Collapsed' } else { 'Visible' }
    if ($ui.BarreAppli.Visibility -ne $v) { $ui.BarreAppli.Visibility = $v }
}

# Barre de l'appli : la fermer (sa propre règle s'applique : elle demande, se réduit ou quitte)
$ui.BtnAppliFermer.Add_Click({
    $i = $script:Integrees[$script:PageCourante]
    if ($i -and $i.Fenetre -ne [IntPtr]::Zero) { [MSIntegration]::Fermer($i.Fenetre) }
})


# Un nouveau processus de l'appli (relance après un thème ou une mise à jour), pas celui dont la fenêtre vient de partir
function Test-NouveauProcessus($Appli, $i) {
    foreach ($p in @(Get-ProcessusAppli $Appli -Hote)) {
        if ($p.Id -eq $i.Pid) { continue }
        try { if ($p.StartTime -ge $i.Depuis.AddSeconds(-10)) { return $true } } catch {}
    }
    $false
}

# « Ouvrir » (écran de l'appli fermée ou réduite) : elle revient dans Mindset
$ui.BtnPageAppliIci.Add_Click({
    $a = Get-Appli $this.Tag
    $ui.BtnPageAppliIci.Visibility = 'Collapsed'
    Show-AppliIntegree $a -Lancer
})

# « Ouvrir » d'une carte de l'accueil ou du menu de l'horloge : son onglet, et elle est lancée
function Open-AppliIci([string]$Id) { Show-Page $Id; Show-AppliIntegree (Get-Appli $Id) -Lancer }

# Surveillance : fenêtre attendue (lancement, relance pour un thème), fenêtre fermée
$script:IntegrationTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:IntegrationTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:IntegrationTimer.Add_Tick({
    $attente = $false
    try { Update-BarreAppli } catch { Write-ErreurImprevue $_.Exception }   # (l'appli pose sa marque un peu après avoir été accrochée)
    foreach ($i in @($script:Integrees.Values)) {
        # (une appli qui pose problème n'empêche pas de surveiller les autres)
        try {
            $a = Get-Appli $i.Id
            if ($i.Fenetre -ne [IntPtr]::Zero -and -not [MSIntegration]::IsWindow($i.Fenetre)) {
                # Fermée (sa croix, son menu Quitter) ou relancée (mise à jour) : l'écran « Ouvrir », et si un nouveau
                # processus démarre, c'est une relance : la jauge, puis sa nouvelle fenêtre est raccrochée
                $i.Fenetre = [IntPtr]::Zero; $i.Styles = $null; $i.Etat = 'relance'; $i.Depuis = Get-Date
                Update-HotesVisibles
                Show-EcranOuvrir $a "$($a.Nom) est fermé."
            } elseif ($i.Fenetre -ne [IntPtr]::Zero -and -not [MSIntegration]::EstMontree($i.Fenetre)) {
                # Elle s'est cachée elle-même (réduite près de l'horloge, par sa croix) : rendue telle quelle, elle y reste
                [MSIntegration]::Liberer($i.Fenetre, $i.Styles[0], $i.Styles[1])
                $i.Fenetre = [IntPtr]::Zero; $i.Styles = $null; $i.Etat = 'cachee'
                Update-HotesVisibles
                Show-EcranOuvrir $a "$($a.Nom) est réduit près de l'horloge."
            }
            if ($i.Etat -in 'lancement', 'relance') {
                $h = Find-FenetreAppli $a
                if ($h -ne [IntPtr]::Zero) { Connect-Fenetre $a $h; continue }
                if ($i.Etat -eq 'relance' -and $script:Jauge -and $script:Jauge.Ecran -and $script:Jauge.Id -eq $a.Id -and (Test-NouveauProcessus $a $i)) { Show-JaugeAppli $a 'Relance...' }
                $ecoule = ((Get-Date) - $i.Depuis).TotalSeconds
                # Un programme de l'appli resté ouvert sans fenêtre (fermée, mais son processus ne s'est pas terminé) : la
                # fenêtre attendue ne viendra jamais, et un nouveau lancement caché s'arrête en le voyant. Il est arrêté, puis
                # l'appli est relancée (une fois par ouverture).
                if ($i.Etat -eq 'lancement' -and -not $i.Debloquee -and $ecoule -gt 5) {
                    $i.Debloquee = $true
                    if (Stop-AppliBloquee $a) {
                        $i.Depuis = Get-Date
                        Write-Log "$($a.Nom) restait ouvert sans fenêtre : arrêté par Mindset, puis relancé"
                        Start-AppliCachee $a
                        $attente = $true; continue
                    }
                }
                # (Nevermind met près de 20 s à démarrer : on lui laisse une minute ; arrêté pendant son démarrage, inutile d'attendre)
                $vivant = Test-AppliOuverte $a
                $limite = if ($i.Etat -eq 'lancement' -and -not $vivant) { 15 } else { 60 }
                if ($ecoule -gt $limite) {
                    $echec = $i.Etat -eq 'lancement' -or -not ($script:Jauge -and $script:Jauge.Ecran)
                    $i.Etat = 'vide'
                    if ($echec) {
                        Show-EcranOuvrir $a "$($a.Nom) n'a pas pu s'ouvrir."
                        Write-Log "$($a.Nom) ne s'est pas affiché après $([int]$ecoule) s ($(if ($vivant) { 'son programme tourne encore' } else { 'son programme s''est arrêté' }))"
                    }
                } else { $attente = $true }
            }
        } catch { Write-ErreurImprevue $_.Exception; $attente = $true }   # (surveillée encore au passage suivant)
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
function Write-DemandeQuitter($Appli) {
    foreach ($d in @((Get-DossierDonnees $Appli), $Appli.Donnees) | Select-Object -Unique) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        # (en test, jamais en dehors du dossier d'essai : les vraies applis de l'utilisateur tournent peut-être)
        if ($EnTest -and -not ($env:MINDSET_DONNEES -and ([IO.Path]::GetFullPath($d)).StartsWith([IO.Path]::GetFullPath($env:MINDSET_DONNEES), [StringComparison]::OrdinalIgnoreCase))) { continue }
        try { [IO.File]::WriteAllText((Join-Path $d 'quitter.demande'), [string]$PID) } catch {}
    }
}
function Request-FermetureApplis {
    foreach ($a in $script:Applis) {
        if (-not (Test-AppliOuverte $a)) { continue }
        Write-DemandeQuitter $a
        Write-Log "Fermeture de $($a.Nom) demandée (Mindset quitte)"
    }
}
$Window.Add_Closed({ if ($script:FermerApplis) { Request-FermetureApplis } })

# (capture de la jauge en test : la page de l'appli, ouverte avant ce module, est rouverte)
if ($EnTest -and ($env:MINDSET_JAUGE -or $env:MINDSET_ECRAN) -and $env:MINDSET_PAGE) { Show-Page $env:MINDSET_PAGE }
