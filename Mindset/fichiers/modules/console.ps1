# Mindset : la console 3D, l'accueil de Mindset (fichiers\console\scene.html, affichée par WebView2).
#
# La scène est une page locale, hors connexion (hôte virtuel https://mindset.local/ sur le dossier « console », toute
# autre navigation refusée). Elle ne fait rien d'elle-même : elle envoie à Mindset des actions connues (ouvrir, installer,
# mettre à jour, fermer...) avec l'identifiant d'une appli, que ce module vérifie avant d'appeler les fonctions habituelles
# de Mindset. Mindset lui envoie l'état des applis (window.mindset.etat).
#
# Économie (mesurée : la 3D seule ≈ 380 Mo et 2 % du processeur quand on la regarde) :
#   - Mindset caché près de l'horloge ou réduit : la 3D est fermée (plus rien, ni processeur, ni mémoire) ;
#   - une autre page de Mindset : la 3D est mise en pause, puis fermée au bout d'une minute ;
#   - elle se recrée en 2 à 3 secondes au retour (« Allumage de la console... » en attendant).
# Repli : sans WebView2, sans les fichiers de la console, réglage « Animations : aucune », ou si la 3D échoue, c'est
# l'accueil classique (les cartes), comme avant.
# Chargé par Mindset.ps1 en dernier (après accueil, integration, parametres et zone).

$ConsoleDir = Join-Path $AppDir 'console'
$LogosAppliDir = Join-Path $DataDir 'console-logos'   # logos tirés de l'icône d'une appli installée (pas livrés avec Mindset)
$Webview2Dir = Join-Path $AppDir 'lib\webview2'
$script:Console = @{ Possible = $false; Vue = $null; Pret = $false; DerniereAppli = $null; RetourAJouer = $null; EtatEnvoye = ''; QuitteeA = $null
    EnFente = $null; Ejecter = $null; Attente = $null; AttenteDepuis = $null }

# La 3D est-elle possible ici ? (une fois, au démarrage)
function Test-ConsolePossible {
    if ([string](Get-Setting 'Animations' 'completes') -eq 'aucune') { return 'réglage Animations : aucune' }
    if ($EnTest -and -not $env:MINDSET_CONSOLE) { return 'test automatique' }
    foreach ($f in 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll') { if (-not (Test-Path -LiteralPath (Join-Path $Webview2Dir $f))) { return "fichier manquant : $f" } }
    if (-not (Test-Path -LiteralPath (Join-Path $ConsoleDir 'scene.html'))) { return 'fichier manquant : console\scene.html' }
    try {
        if (-not $script:WebView2Charge) {   # (une seule fois : WebView2 refuse ensuite de changer de dossier)
            Add-Type -Path (Join-Path $Webview2Dir 'Microsoft.Web.WebView2.Core.dll')
            Add-Type -Path (Join-Path $Webview2Dir 'Microsoft.Web.WebView2.Wpf.dll')
            [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($Webview2Dir)
            $script:WebView2Charge = $true
        }
        $v = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
        if (-not $v) { return 'WebView2 absent de ce PC' }
        Write-Log "Console 3D : WebView2 $v"
    } catch { return "WebView2 indisponible ($($_.Exception.Message))" }
    $null
}
$raison = Test-ConsolePossible
$script:Console.Possible = -not $raison
if ($raison) { Write-Log "Console 3D désactivée : $raison (accueil classique)" }

# ---------------------------------------------------------------------------
# Créer et fermer la 3D
# ---------------------------------------------------------------------------
function New-VueConsole([string]$VueDepart = 'menu') {
    if ($script:Console.Vue -or -not $script:Console.Possible) { return }
    $ui.ConsoleAttente.Visibility = 'Visible'
    $vue = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $vue.DefaultBackgroundColor = [System.Drawing.ColorTranslator]::FromHtml((ConvertTo-ThemeHex '#07060D'))   # (pas d'éclair blanc à l'allumage)
    $cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    $cp.UserDataFolder = Join-Path $DataDir 'console-webview'
    $vue.CreationProperties = $cp
    $vue.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) { Stop-Console "initialisation refusée ($($e.InitializationException.Message))"; return }
        try {
            $c = $s.CoreWebView2
            $r = $c.Settings
            $r.AreDevToolsEnabled = [bool]$env:MINDSET_CONSOLE_DEV; $r.AreDefaultContextMenusEnabled = $false; $r.IsZoomControlEnabled = $false
            $r.AreBrowserAcceleratorKeysEnabled = $false; $r.IsStatusBarEnabled = $false; $r.IsPasswordAutosaveEnabled = $false; $r.IsGeneralAutofillEnabled = $false
            $c.SetVirtualHostNameToFolderMapping('mindset.local', $ConsoleDir, [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Deny)
            # Les logos tirés des applis installées (dossier de données) : servis par Mindset lui-même, une image PNG au nom
            # vérifié, avec l'autorisation qu'exige le navigateur pour les dessiner sur l'écran de la console
            $c.AddWebResourceRequestedFilter('https://applogos.mindset.local/*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
            $c.Add_WebResourceRequested({
                param($s2, $e2)
                $nom = [IO.Path]::GetFileName(([uri]$e2.Request.Uri).AbsolutePath)
                $f = Join-Path $LogosAppliDir $nom
                if ($nom -match '^[a-z0-9-]{1,30}\.png$' -and (Test-Path -LiteralPath $f)) {
                    $flux = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($f))
                    $e2.Response = $s2.Environment.CreateWebResourceResponse($flux, 200, 'OK', "Content-Type: image/png`r`nAccess-Control-Allow-Origin: https://mindset.local")
                } else { $e2.Response = $s2.Environment.CreateWebResourceResponse($null, 404, 'Not Found', '') }
            })
            # Seule la console s'affiche : toute autre adresse, et toute nouvelle fenêtre, est refusée
            $c.Add_NavigationStarting({ param($s2, $e2) if (-not $e2.Uri.StartsWith('https://mindset.local/')) { $e2.Cancel = $true; Write-Log "Console 3D : navigation refusée ($($e2.Uri))" } })
            $c.Add_NewWindowRequested({ param($s2, $e2) $e2.Handled = $true })
            $c.Add_WebMessageReceived({ param($s2, $e2) try { Receive-MessageConsole $e2.WebMessageAsJson } catch { Write-Log "Console 3D : message ignoré ($_)" } })
            $c.Add_ProcessFailed({ param($s2, $e2) Stop-Console "processus de la 3D arrêté ($($e2.ProcessFailedKind))" })
            $anim = [string](Get-Setting 'Animations' 'completes')
            $c.Navigate("https://mindset.local/scene.html?vue=$VueDepart&animations=$(if ($anim -eq 'express') { 'express' } else { 'completes' })&couleurs=$([uri]::EscapeDataString((Get-CouleursConsole)))")
        } catch { Stop-Console "réglage impossible ($($_.Exception.Message))" }
    })
    $ui.PageConsole.Children.Add($vue) | Out-Null
    $script:Console.Vue = $vue; $script:Console.Pret = $false; $script:Console.EtatEnvoye = ''
    # (WebView2 ne démarre qu'une fois la boucle d'affichage de Mindset lancée : la fenêtre, elle, s'affiche juste avant)
    [void]$Window.Dispatcher.BeginInvoke([action]{
        if (-not $script:Console.Vue) { return }
        try { [void]$script:Console.Vue.EnsureCoreWebView2Async() } catch { Stop-Console "démarrage impossible ($($_.Exception.Message))" }
    }, [System.Windows.Threading.DispatcherPriority]::Background)
}

# Les couleurs Néon de la scène, traduites dans le thème de la suite (themes.ps1, packs perso compris) : seulement
# celles qui changent, en JSON ({ "00E5FF": "#FF8A3D", ... }) ; la scène garde les autres
$CouleursScene = '07060D', '00E5FF', 'FF2EB5', 'B04BFF', '6A5CFF', '7A5BFF', '0B0A12', '17151F', '050409', '111018', '2C2840', '24212F',
    '1B1830', '0A0912', '100D22', '120E28', '05040C', 'A9A3C9', '1A1636', '141126', 'C9C4DD', '2B2648', '08060F', 'ECEAF7', '8FF4FF',
    'E8FDFF', '0C0920', '06050F', '0A0818'
function Get-CouleursConsole {
    $t = [ordered]@{}
    foreach ($h in $CouleursScene) { $v = (ConvertTo-ThemeHex "#$h").ToUpper(); if ($v -ne "#$h") { $t[$h] = $v } }
    $t | ConvertTo-Json -Compress
}

function Remove-VueConsole([string]$Pourquoi) {
    $vue = $script:Console.Vue
    if (-not $vue) { return }
    $script:Console.Vue = $null; $script:Console.Pret = $false
    try { $ui.PageConsole.Children.Remove($vue) } catch {}
    try { $vue.Dispose() } catch {}
    $ui.ConsoleAttente.Visibility = 'Visible'
    if ($Pourquoi) { Write-Log "Console 3D fermée ($Pourquoi)" }
}

# Un échec : la 3D est abandonnée jusqu'à la prochaine ouverture de Mindset, et l'accueil classique reprend
function Stop-Console([string]$Raison) {
    Write-Log "Console 3D : $Raison, accueil classique"
    $script:Console.Possible = $false
    Remove-VueConsole
    Set-NavigationConsole
    Update-PageConsole
}

# Avec la console, plus d'onglets : on navigue par la console et le bouton « Menu ». Sans elle, les onglets reviennent.
function Set-NavigationConsole {
    $avec = $script:Console.Possible
    $ui.BarreOnglets.Visibility = if ($avec) { 'Collapsed' } else { 'Visible' }
    $ui.EnTete.Visibility = if ($avec) { 'Collapsed' } else { 'Visible' }   # (le nom de Mindset est déjà sur l'écran de la console)
    $ui.ColonneOnglets.Width = if ($avec) { New-Object System.Windows.GridLength 0 } else { New-Object System.Windows.GridLength 210 }
    foreach ($b in $ui.BtnAppliMenu, $ui.BtnPageAppliMenu, $ui.BtnParametresMenu) { $b.Visibility = if ($avec) { 'Visible' } else { 'Collapsed' } }
}

# Ouvrir une appli sans passer par la console (menu de l'horloge, bulle de notification) : elle s'affiche tout de suite,
# et sa cartouche est mise dans la fente pour le retour au menu
function Open-AppliConsole([string]$Id) {
    if ($script:Console.Possible) { $script:Console.DerniereAppli = $Id; $script:Console.EnFente = $Id }
    Open-AppliIci $Id
}

function Invoke-ScriptConsole([string]$Code) {
    $vue = $script:Console.Vue
    if (-not $vue -or -not $script:Console.Pret) { return }
    try { [void]$vue.ExecuteScriptAsync($Code) } catch {}
}

# ---------------------------------------------------------------------------
# Quelle page montrer : la console à la place de l'accueil (appelé par Show-Page, accueil.ps1)
# ---------------------------------------------------------------------------
function Update-PageConsole {
    $accueil = $script:PageCourante -eq 'accueil'
    $avecConsole = $accueil -and $script:Console.Possible
    $ui.PageConsole.Visibility = if ($avecConsole) { 'Visible' } else { 'Collapsed' }
    if ($accueil) { $ui.PageAccueil.Visibility = if ($avecConsole) { 'Collapsed' } else { 'Visible' } }
    if (-not $script:Console.Possible) { return }
    if ($avecConsole -and $Window.IsVisible -and $Window.WindowState -ne 'Minimized') {
        $script:Console.QuitteeA = $null
        if (-not $script:Console.Vue) {
            # Retour d'une appli : la caméra repart de l'intérieur de l'écran, puis ressort jusqu'au menu
            $depuis = $script:Console.DerniereAppli
            $script:Console.RetourAJouer = $depuis
            New-VueConsole $(if ($depuis) { 'dedans' } else { 'menu' })
        } else {
            Invoke-ScriptConsole 'window.mindset.reprendre()'
            if ($script:Console.DerniereAppli) { Invoke-ScriptConsole "window.mindset.jouerRetour('$($script:Console.DerniereAppli)', $(if ($script:Console.Ejecter) { 'true' } else { 'false' }))"; $script:Console.Ejecter = $null }
            Send-EtatConsole -Force
        }
        $script:Console.DerniereAppli = $null
        try { [void]$script:Console.Vue.Focus() } catch {}
    } elseif ($script:Console.Vue) {
        # Une autre page : pause tout de suite, fermeture au bout d'une minute (ConsoleTimer)
        Invoke-ScriptConsole 'window.mindset.pause()'
        if (-not $script:Console.QuitteeA) { $script:Console.QuitteeA = Get-Date }
    }
}

# ---------------------------------------------------------------------------
# L'état des applis, envoyé à la scène quand il change
# ---------------------------------------------------------------------------
function Get-EtatConsole {
    $liste = foreach ($a in $Applis) {
        $e = Get-EtatCarte $a
        $logo = Get-LogoConsole $a $e.Inst
        $maj = if ($e.Occupe) {
                   $pr = $script:Progres[$a.Id]
                   if ($pr) { [ordered]@{ etat = 'telechargement'; progres = $(if ($pr.Total -gt 0) { [math]::Round([double]$pr.Recu / $pr.Total, 3) } else { 0 }) } }
                   else { [ordered]@{ etat = 'installation'; progres = 1 } }
               } elseif ($e.MajDispo) { [ordered]@{ etat = 'dispo'; progres = 0 } } else { $null }
        [ordered]@{ id = $a.Id; nom = $a.Nom; c1 = (ConvertTo-ThemeHex $a.Couleur); c2 = (ConvertTo-ThemeHex '#B04BFF'); logo = $logo; installee = [bool]$e.Inst
            etat = $(if ($e.Ouverte) { 'fond' } else { 'ferme' }); maj = $maj }
    }
    ConvertTo-Json -InputObject ([ordered]@{ applis = @($liste) }) -Depth 5 -Compress
}
# Le logo d'une appli sur la console : celui livré avec Mindset (console\logos), sinon tiré une fois de l'icône (.ico)
# de l'appli installée ; sans rien, la console dessine la première lettre de son nom
function Get-LogoConsole($Appli, $Inst) {
    if (Test-Path -LiteralPath (Join-Path $ConsoleDir "logos\$($Appli.Id).png")) { return "logos/$($Appli.Id).png" }
    $f = Join-Path $LogosAppliDir "$($Appli.Id).png"
    if (Test-Path -LiteralPath $f) { return "https://applogos.mindset.local/$($Appli.Id).png" }
    if (-not $Inst -or $script:Console["LogoEssaye-$($Appli.Id)"]) { return $null }
    $script:Console["LogoEssaye-$($Appli.Id)"] = $true
    try {
        $ico = Get-ChildItem -LiteralPath (Join-Path $Inst.Dossier 'fichiers') -Filter '*.ico' -File -ErrorAction Stop | Select-Object -First 1
        if (-not $ico -or $ico.Length -gt 2MB) { return $null }
        $b = [IO.File]::ReadAllBytes($ico.FullName); $n = [BitConverter]::ToUInt16($b, 4); $meilleur = $null
        for ($k = 0; $k -lt $n; $k++) {
            $o = 6 + 16 * $k; $w = if ($b[$o] -eq 0) { 256 } else { $b[$o] }
            $lg = [BitConverter]::ToUInt32($b, $o + 8); $dp = [BitConverter]::ToUInt32($b, $o + 12)
            if ($dp + $lg -le $b.Length -and $b[$dp] -eq 0x89 -and (-not $meilleur -or $w -gt $meilleur.W)) { $meilleur = @{ W = $w; Lg = $lg; Dp = $dp } }
        }
        if (-not $meilleur) { return $null }   # (une icône sans image PNG : la lettre)
        $png = New-Object byte[] $meilleur.Lg; [Array]::Copy($b, $meilleur.Dp, $png, 0, $meilleur.Lg)
        New-Item -ItemType Directory -Force -Path $LogosAppliDir | Out-Null
        [IO.File]::WriteAllBytes($f, $png)
        Write-Log "Console 3D : logo de $($Appli.Nom) tiré de son icône"
        "https://applogos.mindset.local/$($Appli.Id).png"
    } catch { $null }
}
function Send-EtatConsole([switch]$Force) {
    if (-not $script:Console.Vue -or -not $script:Console.Pret) { return }
    $json = Get-EtatConsole
    if (-not $Force -and $json -eq $script:Console.EtatEnvoye) { return }
    $script:Console.EtatEnvoye = $json
    Invoke-ScriptConsole "window.mindset.etat($json)"
}

# ---------------------------------------------------------------------------
# Ce que la scène demande : seulement des actions connues, sur une appli de apps.json
# ---------------------------------------------------------------------------
function Receive-MessageConsole([string]$Json) {
    if (-not $Json -or $Json.Length -gt 2000) { return }
    $m = $Json | ConvertFrom-Json
    $type = [string]$m.type
    if ($type -eq 'pret') {
        $script:Console.Pret = $true
        $ui.ConsoleAttente.Visibility = 'Collapsed'
        Send-EtatConsole -Force
        if ($script:Console.RetourAJouer) { Invoke-ScriptConsole "window.mindset.jouerRetour('$($script:Console.RetourAJouer)', $(if ($script:Console.Ejecter) { 'true' } else { 'false' }))"; $script:Console.RetourAJouer = $null; $script:Console.Ejecter = $null }
        Write-Log 'Console 3D prête'
        if ($EnTest -and $env:MINDSET_CONSOLE_CAPTURE) { Start-CaptureConsole $env:MINDSET_CONSOLE_CAPTURE }
        return
    }
    $id = [string]$m.id
    $a = if ($id -match '^[a-z0-9-]{1,30}$') { Get-Appli $id } else { $null }
    if ($type -eq 'afficher') {
        # Fin de la plongée dans l'écran : l'appli prend la place de la console
        if ($a) { $script:Console.DerniereAppli = $a.Id; $script:Console.EnFente = $a.Id; Open-AppliIci $a.Id }
        return
    }
    if ($type -ne 'action') { return }
    switch ([string]$m.action) {
        'ouvrir'     {
            if ($a -and (Get-Installation $a)) {
                if (-not (Test-AppliOuverte $a)) { Start-AppliCachee $a }
                $script:Console.Attente = $a.Id; $script:Console.AttenteDepuis = Get-Date
                Invoke-ScriptConsole "window.mindset.jouerOuverture('$($a.Id)')"
                $script:ConsoleAttenteTimer.Start()
            }
        }
        'installer'  { if ($a -and -not (Get-Installation $a)) { if ($script:Trouvees[$a.Id]) { Confirm-PriseEnCharge $a } else { Start-InstallAppli $a } } }
        'maj'        { if ($a) { Confirm-MiseAJour $a } }
        'fermer'     { if ($a) { Stop-AppliConsole $a } }
        'parametres' { Show-Page 'parametres' }
        'actualiser' { Invoke-Actualiser -Clic; Invoke-ScriptConsole "window.mindset.message('Recherche des nouvelles versions...')" }
        'majTout'    {
            $aMettre = @($Applis | Where-Object { (Get-EtatCarte $_).MajDispo })
            if ($aMettre.Count) { Confirm-MiseAJour $aMettre[0] } else { Invoke-ScriptConsole "window.mindset.message('Toutes tes applis sont à jour')" }
        }
        'veille'     { Hide-Fenetre }
    }
}

# Fermer une appli depuis la console : sa fenêtre affichée dans Mindset reçoit « Fermer », sinon sa demande de fermeture
function Stop-AppliConsole($Appli) {
    if ($script:Console.EnFente -eq $Appli.Id) { $script:Console.EnFente = $null }
    Invoke-ScriptConsole "window.mindset.jouerEjection('$($Appli.Id)')"
    $i = $script:Integrees[$Appli.Id]
    if ($i -and $i.Fenetre -ne [IntPtr]::Zero) { [MSIntegration]::Fermer($i.Fenetre); Write-Log "$($Appli.Nom) fermé depuis la console"; return }
    if (-not (Test-AppliOuverte $Appli)) { return }
    Write-DemandeQuitter $Appli
    Write-Log "Fermeture de $($Appli.Nom) demandée depuis la console"
}

# Test automatique : image de la 3D (WebView2 se dessine à part : la capture de la fenêtre WPF ne la voit pas), puis Mindset quitte
function Start-CaptureConsole([string]$Fichier) {
    $script:CaptureConsoleFichier = $Fichier   # (un paramètre de fonction n'est plus visible dans la minuterie)
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds([int]$(if ($env:MINDSET_CONSOLE_DELAI) { $env:MINDSET_CONSOLE_DELAI } else { 3000 }))
    $t.Add_Tick({
        param($s)
        if (-not $s.Tag) {
            $f = [IO.File]::Create($script:CaptureConsoleFichier)
            $s.Tag = @{ Flux = $f; Tache = $script:Console.Vue.CoreWebView2.CapturePreviewAsync([Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png, $f) }
            $s.Interval = [TimeSpan]::FromMilliseconds(200); return
        }
        if (-not $s.Tag.Tache.IsCompleted) { return }
        $s.Stop(); $s.Tag.Flux.Dispose()
        Write-Log "Console 3D : capture $(if ($s.Tag.Tache.IsFaulted) { 'ratée' } else { 'faite' })"
        if (-not $env:MINDSET_CONSOLE_RESTER) { Exit-Mindset }
    })
    $t.Start()
}

# ---------------------------------------------------------------------------
# Surveillance : état des applis (toutes les 1,5 s), fermeture de la 3D quand on ne la regarde plus
# ---------------------------------------------------------------------------
$script:ConsoleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ConsoleTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:ConsoleTimer.Add_Tick({
    $en = $script:Console.EnFente
    if ($en) {
        $a = Get-Appli $en
        if ($a -and -not (Test-AppliOuverte $a)) {
            $script:Console.EnFente = $null
            if ($script:PageCourante -eq $en) { $script:Console.Ejecter = $en; $script:Console.DerniereAppli = $en; Show-Page 'accueil' }
            else { Invoke-ScriptConsole "window.mindset.jouerEjection('$en')" }
        }
    }
    if (-not $script:Console.Vue) { return }
    if ($script:Console.QuitteeA -and ((Get-Date) - $script:Console.QuitteeA).TotalSeconds -ge 60) { Remove-VueConsole 'une minute sur une autre page'; $script:Console.QuitteeA = $null; return }
    try { Send-EtatConsole } catch { Write-Log "Console 3D : état non envoyé ($_)" }
})
if ($script:Console.Possible) { $script:ConsoleTimer.Start() }

# Pendant l'animation d'ouverture : sa fenêtre est-elle prête ? (déjà affichée dans Mindset, ou créée par l'appli qui
# démarre). Alors la console plonge dans l'écran. Une appli qui ne démarre pas : on plonge quand même (Mindset l'explique).
$script:ConsoleAttenteTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ConsoleAttenteTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:ConsoleAttenteTimer.Add_Tick({
    $id = $script:Console.Attente
    if (-not $id) { $script:ConsoleAttenteTimer.Stop(); return }
    $a = Get-Appli $id
    $i = $script:Integrees[$id]
    $prete = ($i -and $i.Fenetre -ne [IntPtr]::Zero -and [MSIntegration]::IsWindow($i.Fenetre)) -or ((Find-FenetreAppli $a) -ne [IntPtr]::Zero)
    $ecoule = ((Get-Date) - $script:Console.AttenteDepuis).TotalSeconds
    if ($prete -or $ecoule -gt 60 -or ($ecoule -gt 15 -and -not (Test-AppliOuverte $a))) {
        $script:Console.Attente = $null; $script:ConsoleAttenteTimer.Stop()
        Invoke-ScriptConsole "window.mindset.appliPrete('$id')"
        if (-not $prete) { Write-Log "Console 3D : $($a.Nom) pas prête après $([int]$ecoule) s, affichée quand même" }
    }
})

# Le bouton Menu (la maison), dans la barre de l'appli, sur son écran d'attente et dans les Paramètres : retour à la
# console (une appli affichée reste ouverte, en pause). Échap fait pareil.
foreach ($b in $ui.BtnAppliMenu, $ui.BtnPageAppliMenu, $ui.BtnParametresMenu) { $b.Add_Click({ Show-Page 'accueil' }) }
$Window.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -ne [System.Windows.Input.Key]::Escape -or -not $script:Console.Possible -or $script:PageCourante -eq 'accueil') { return }
    if ($ui.Confirmation.Visibility -eq 'Visible' -or $ui.Fermeture.Visibility -eq 'Visible') { return }
    $e.Handled = $true
    Show-Page 'accueil'
})
Set-NavigationConsole

# Paramètres > Apparence > Animations : complètes, express (plus rapides), ou aucune (l'accueil classique, sans 3D).
# Pris en compte tout de suite : la console s'éteint, se rallume, ou repart à la bonne vitesse au retour sur l'accueil.
function Set-ReglageAnimations([string]$Choix) {
    Set-Setting 'Animations' $Choix
    $ui.AnimationsInfo.Text = ''
    if ($Choix -eq 'aucune') {
        if (-not $script:Console.Possible) { return }
        $script:Console.Possible = $false
        $script:ConsoleTimer.Stop()
        Remove-VueConsole 'réglage Animations : aucune'
    } elseif (-not $script:Console.Possible) {
        $raison = Test-ConsolePossible
        if ($raison) { $ui.AnimationsInfo.Text = "La console 3D ne peut pas s'afficher sur ce PC ($raison) : l'accueil classique reste."; return }
        $script:Console.Possible = $true
        $script:ConsoleTimer.Start()
    } else {
        Remove-VueConsole 'réglage Animations changé'   # (recréée à la nouvelle vitesse au retour sur l'accueil)
        return
    }
    Set-NavigationConsole
    Update-PageConsole
}
foreach ($o in @(@('completes', 'Complètes : la console et toutes ses animations'), @('express', 'Express : la console, avec des animations plus rapides'), @('aucune', 'Aucune : l''accueil classique, sans 3D'))) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.GroupName = 'Animations'; $rb.Tag = $o[0]; $rb.Content = $o[1]; $rb.Margin = '0,2,0,2'; $rb.Foreground = Get-Brush '#ECEAF7'
    $rb.IsChecked = ([string](Get-Setting 'Animations' 'completes') -eq $o[0])
    $rb.Add_Checked({ param($s) if ([string](Get-Setting 'Animations' 'completes') -ne $s.Tag) { Set-ReglageAnimations $s.Tag } })
    [void]$ui.ChoixAnimations.Children.Add($rb)
}

# Mindset caché près de l'horloge ou réduit : la 3D est fermée ; réaffiché sur l'accueil : elle revient
$Window.Add_IsVisibleChanged({ if (-not $Window.IsVisible) { Remove-VueConsole 'Mindset caché' } elseif ($script:PageCourante -eq 'accueil') { Update-PageConsole } })
$Window.Add_StateChanged({ if ($Window.WindowState -eq 'Minimized') { Remove-VueConsole 'Mindset réduit' } elseif ($script:PageCourante -eq 'accueil') { Update-PageConsole } })
$Window.Add_Closed({ Remove-VueConsole })

# Une question de Mindset (confirmation, fermeture) passe par-dessus : la 3D s'efface le temps qu'elle s'en aille
# (une vue WebView2 se dessine toujours au-dessus du reste de la fenêtre)
function Update-ConsoleMasquee {
    if (-not $script:Console.Vue) { return }
    $dessus = $ui.Confirmation.Visibility -eq 'Visible' -or $ui.Fermeture.Visibility -eq 'Visible'
    $script:Console.Vue.Visibility = if ($dessus) { 'Hidden' } else { 'Visible' }
}
$ui.Confirmation.Add_IsVisibleChanged({ Update-ConsoleMasquee })
$ui.Fermeture.Add_IsVisibleChanged({ Update-ConsoleMasquee })

# La page d'arrivée est peut-être déjà l'accueil (Show-Page a été appelé avant ce module)
Update-PageConsole
