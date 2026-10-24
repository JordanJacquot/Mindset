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
$ConsoleWebviewCommun = Join-Path $SuiteDir 'WebView2'          # le dossier WebView2 de toute la suite (profil « Mindset »)
$ConsoleWebviewPropre = Join-Path $DataDir 'console-webview'    # filet de sécurité : l'ancien dossier propre à Mindset
if ($EnTest -and $env:MINDSET_WEBVIEW_COMMUN) { $ConsoleWebviewCommun = $env:MINDSET_WEBVIEW_COMMUN }   # (test du filet : un dossier commun impossible)
$script:Console = @{ Possible = $false; Vue = $null; Pret = $false; DerniereAppli = $null; AJouer = $null; EtatEnvoye = ''; QuitteeA = $null
    EnFente = $null; Ejecter = $null; Attente = $null; AttenteDepuis = $null; Parametres = $false; ParametresEnvoyes = ''; MajEnvoye = '' }

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
# Peut-on écrire dans ce dossier de données WebView2 ? (créé s'il manque ; un petit fichier témoin écrit puis effacé
# dans le dossier et dans son EBWebView s'il existe, là où WebView2 écrit). $null si oui, sinon la raison.
function Test-DossierWebviewEcrivable([string]$Dossier) {
    try {
        [void][IO.Directory]::CreateDirectory($Dossier)
        foreach ($d in @($Dossier, (Join-Path $Dossier 'EBWebView'))) {
            if (-not [IO.Directory]::Exists($d)) { continue }
            $t = Join-Path $d "ecriture-$PID.tmp"
            [IO.File]::WriteAllText($t, '1')
            [IO.File]::Delete($t)
        }
        $null
    } catch { $_.Exception.Message }
}
function New-VueConsole([string]$VueDepart = 'menu') {
    if ($script:Console.Vue -or -not $script:Console.Possible) { return }
    $ui.ConsoleAttente.Visibility = 'Visible'
    $vue = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $vue.DefaultBackgroundColor = [System.Drawing.ColorTranslator]::FromHtml((ConvertTo-ThemeHex '#07060D'))   # (pas d'éclair blanc à l'allumage)
    # Un seul WebView2 pour la suite : le dossier commun (WebView2 dans les données de la suite), partagé avec Nevermind,
    # avec un profil à Mindset (stockages séparés). Les options d'environnement doivent rester les MÊMES que chez Nevermind
    # (aujourd'hui aucune) : sinon WebView2 refuse de partager. Filet : si la création échoue avec ce dossier (options
    # différentes, ancienne version de Nevermind ouverte, dossier illisible), l'ancien dossier propre à Mindset
    # (console-webview) prend le relais jusqu'à la fermeture de Mindset : la console ne reste jamais vide.
    $cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    # Le dossier commun doit pouvoir s'écrire AVANT d'être donné à WebView2 : sinon le moteur affiche lui-même une boîte
    # d'erreur (« ne peut pas lire et écrire dans son répertoire de données ») avant que le filet ne prenne le relais
    if (-not $script:Console.DossierPropre) {
        $refus = Test-DossierWebviewEcrivable $ConsoleWebviewCommun
        if ($refus) { $script:Console.DossierPropre = $true; Write-Log "Console 3D : dossier WebView2 commun de la suite pas utilisable ($refus), dossier console-webview utilisé" }
    }
    if ($script:Console.DossierPropre) { $cp.UserDataFolder = $ConsoleWebviewPropre }
    else { $cp.UserDataFolder = $ConsoleWebviewCommun; $cp.ProfileName = 'Mindset' }
    $vue.CreationProperties = $cp
    $vue.Tag = $VueDepart
    $vue.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) {
            if (-not $script:Console.DossierPropre) {
                $script:Console.DossierPropre = $true
                Write-Log "Console 3D : WebView2 commun de la suite refusé ($($e.InitializationException.Message)), retour au dossier console-webview"
                $depart = [string]$s.Tag
                [void]$Window.Dispatcher.BeginInvoke([action]{ Remove-VueConsole; New-VueConsole $depart }, [System.Windows.Threading.DispatcherPriority]::Background)
                return
            }
            Stop-Console "initialisation refusée ($($e.InitializationException.Message))"; return
        }
        Write-Log "Console 3D : WebView2 dans $(if ($script:Console.DossierPropre) { 'son propre dossier (console-webview)' } else { 'le dossier commun de la suite' })"
        try {
            $c = $s.CoreWebView2
            $r = $c.Settings
            $r.AreDevToolsEnabled = [bool]$env:MINDSET_CONSOLE_DEV; $r.AreDefaultContextMenusEnabled = $false; $r.IsZoomControlEnabled = $false
            $r.AreBrowserAcceleratorKeysEnabled = $false; $r.IsStatusBarEnabled = $false; $r.IsPasswordAutosaveEnabled = $false; $r.IsGeneralAutofillEnabled = $false
            $c.SetVirtualHostNameToFolderMapping('mindset.local', $ConsoleDir, [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Deny)
            # Les logos tirés des applis installées (dossier de données) : servis par Mindset lui-même, une image PNG au nom
            # vérifié, avec l'autorisation qu'exige le navigateur pour les dessiner sur l'écran de la console
            $c.AddWebResourceRequestedFilter('https://applogos.mindset.local/*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
            $c.AddWebResourceRequestedFilter('https://theme.mindset.local/*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
            $c.Add_WebResourceRequested({
                param($s2, $e2)
                $u = [uri]$e2.Request.Uri
                if ($u.Host -eq 'theme.mindset.local') { $e2.Response = Get-ReponseThemeConsole $s2 $u; return }   # (les images du thème perso)
                $nom = [IO.Path]::GetFileName($u.AbsolutePath)
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
            $th = Get-ThemeConsole
            # (les couleurs du thème de la suite valent pour tous les thèmes, de base ou perso ; les images, seulement un pack avec un bloc Console)
            $suite = "&couleurs=$([uri]::EscapeDataString((Get-CouleursConsole)))" + $(if ($th) { "&theme=$([uri]::EscapeDataString($th))" } else { '' })
            $decor = if ($EnTest -and $env:MINDSET_TEST_DECOR -match '^(jour|soir|nuit)$') { "&decor=$($Matches[1])" } else { '' }   # (test : le décor, quelle que soit l'heure)
            $c.Navigate("https://mindset.local/scene.html?vue=$VueDepart&animations=$(if ($anim -eq 'express') { 'express' } else { 'completes' })$suite$decor")
        } catch { Stop-Console "réglage impossible ($($_.Exception.Message))" }
    })
    $ui.PageConsole.Children.Add($vue) | Out-Null
    $script:Console.Vue = $vue; $script:Console.Pret = $false; $script:Console.EtatEnvoye = ''; $script:Console.MajEnvoye = ''
    # (WebView2 ne démarre qu'une fois la boucle d'affichage de Mindset lancée : la fenêtre, elle, s'affiche juste avant)
    [void]$Window.Dispatcher.BeginInvoke([action]{
        if (-not $script:Console.Vue) { return }
        try { [void]$script:Console.Vue.EnsureCoreWebView2Async() }
        catch {
            if ($script:Console.DossierPropre) { Stop-Console "démarrage impossible ($($_.Exception.Message))"; return }
            $script:Console.DossierPropre = $true   # (le filet : l'ancien dossier propre à Mindset)
            Write-Log "Console 3D : WebView2 commun de la suite impossible ($($_.Exception.Message)), retour au dossier console-webview"
            $depart = [string]$script:Console.Vue.Tag
            Remove-VueConsole; New-VueConsole $depart
        }
    }, [System.Windows.Threading.DispatcherPriority]::Background)
}

# Le thème de la suite dans la console : ses couleurs pour tous les thèmes ; ses images et sa police seulement pour un thème
# perso qui a un bloc « Console » (packs.ps1).
#   - ses couleurs : chaque couleur Néon de la scène (toutes celles écrites dans scene.html), traduite dans le thème,
#     seulement celles qui changent, en JSON ({ "00E5FF": "#FF8A3D", ... }) ; les icônes restent les mêmes ;
#   - ses images (fond de l'écran en grand, mascotte du menu, image de chargement, logo) et sa police : servies en
#     lecture seule depuis le dossier du pack (https://theme.mindset.local/<nom>), seulement les fichiers nommés ici.
function Get-CouleursConsole {
    $t = [ordered]@{}
    $html = [IO.File]::ReadAllText((Join-Path $ConsoleDir 'scene.html'), [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($html, '#([0-9A-Fa-f]{6})\b')) {
        $h = $m.Groups[1].Value.ToUpper()
        $v = (ConvertTo-ThemeHex "#$h").ToUpper()
        if ($v -ne "#$h" -and -not $t.Contains($h)) { $t[$h] = $v }
    }
    $t | ConvertTo-Json -Compress
}
$script:FichiersThemeConsole = @{}; $script:ImagesAnimees = @{}
function Get-ThemeConsole {
    $script:FichiersThemeConsole = @{}
    if (-not $ThemePack -or -not $ThemePack.Console) { return $null }
    $c = $ThemePack.Console
    $url = { param($f) if (-not $f) { return '' }; $n = [IO.Path]::GetFileName($f); $script:FichiersThemeConsole[$n] = $f; "https://theme.mindset.local/$([uri]::EscapeDataString($n))" }
    $t = [ordered]@{
        fond = (& $url $c.Fond); opacite = [double]$c.FondOpacite
        mascotte = (& $url $c.Mascotte); mascotteAnimee = (Test-ImageAnimee $c.Mascotte)
        chargement = $(if ($c.Chargement) { & $url $c.Chargement.File } else { '' }); effet = $(if ($c.Chargement) { [string]$c.Chargement.Effet } else { '' })
        # Console.Logo (animé possible) avant Logo ; une planche animée : le logo de Mindset reste
        logo = $(if ($c.Logo) { & $url $c.Logo } elseif ($ThemePack.Logo -and $ThemePack.LogoFrames -le 1) { & $url $ThemePack.Logo } else { '' })
        police = $(if ($ThemePack.Font) { & $url $ThemePack.Font } else { '' })
    }
    $t | ConvertTo-Json -Compress
}
# Une image animée (GIF à plusieurs images, WebP ou PNG animé) ? La mascotte fixe flotte, une animée reste en place
function Test-ImageAnimee([string]$Fichier) {
    if (-not $Fichier) { return $false }
    if ($script:ImagesAnimees.ContainsKey($Fichier)) { return $script:ImagesAnimees[$Fichier] }
    $oui = $false
    try {
        $b = [IO.File]::ReadAllBytes($Fichier)
        $s = [Text.Encoding]::GetEncoding(28591).GetString($b)
        $format = Get-FormatImagePack $b
        if ($format -eq 'gif') { $gce = [string][char]0x21 + [char]0xF9 + [char]0x04; $i = $s.IndexOf($gce, [StringComparison]::Ordinal); $oui = $i -ge 0 -and $s.IndexOf($gce, $i + 3, [StringComparison]::Ordinal) -ge 0 }
        elseif ($format -eq 'webp') { $oui = $s.Substring(12, 4) -eq 'VP8X' -and [bool]($b[20] -band 0x02) }
        elseif ($format -eq 'png') { $a = $s.IndexOf('acTL', [StringComparison]::Ordinal); $d = $s.IndexOf('IDAT', [StringComparison]::Ordinal); $oui = $a -ge 0 -and ($d -lt 0 -or $a -lt $d) }
    } catch {}
    $script:ImagesAnimees[$Fichier] = $oui
    $oui
}
# Un fichier du thème demandé par la scène : seulement ceux de Get-ThemeConsole, avec son type et l'autorisation
# qu'exige le navigateur pour le dessiner (écran de la console) ou s'en servir comme police
function Get-ReponseThemeConsole($Vue, [uri]$Uri) {
    $f = $null
    try { $f = $script:FichiersThemeConsole[[uri]::UnescapeDataString($Uri.AbsolutePath.TrimStart('/'))] } catch {}
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { return $Vue.Environment.CreateWebResourceResponse($null, 404, 'Not Found', '') }
    $b = [IO.File]::ReadAllBytes($f)
    $type = if ($f -match '\.ttf$') { 'font/ttf' } elseif ($f -match '\.otf$') { 'font/otf' } else { switch (Get-FormatImagePack $b) { 'png' { 'image/png' } 'jpeg' { 'image/jpeg' } 'gif' { 'image/gif' } 'webp' { 'image/webp' } default { $null } } }
    if (-not $type) { return $Vue.Environment.CreateWebResourceResponse($null, 404, 'Not Found', '') }
    $flux = New-Object IO.MemoryStream (, $b)
    $Vue.Environment.CreateWebResourceResponse($flux, 200, 'OK', "Content-Type: $type`r`nAccess-Control-Allow-Origin: https://mindset.local`r`nCache-Control: max-age=3600")
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
        # Ce que la scène joue en revenant : d'une appli qui tourne encore (sa maison, Échap, le bouton Menu de Mindset) :
        # le menu en grand, dans l'écran (comme un clic sur l'écran), l'appli reste en pause ; d'une appli fermée : la
        # caméra ressort de l'écran et sa cartouche ressort de la fente. Les Paramètres demandés : ils s'ouvrent ensuite
        # dans l'écran (Open-ParametresConsole), sur leur onglet.
        $depuis = $script:Console.DerniereAppli
        $js = if ($depuis -and $script:Console.Ejecter) { "window.mindset.jouerRetour('$depuis', true)" }
              elseif ($depuis) { "window.mindset.jouerMenu('$depuis')" } else { $null }
        $script:Console.Ejecter = $null; $script:Console.DerniereAppli = $null
        if ($script:Console.Parametres) {
            $onglet = if ($OngletsParametres.Contains([string]$script:OngletParametres)) { $script:OngletParametres } else { 'general' }
            $etat = Get-EtatParametres; $script:Console.ParametresEnvoyes = $etat
            $r = "window.mindset.reglages($etat, '$onglet', $(if ($script:Console.Vue) { 'false' } else { 'true' }), $(Get-ImagesThemesConsole))"
            $js = if ($js) { "$js; $r" } else { $r }
        }
        if (-not $script:Console.Vue) {
            $script:Console.AJouer = $js   # (joué quand la scène est prête)
            New-VueConsole $(if ($depuis) { 'dedans' } else { 'menu' })
        } elseif (-not $script:Console.Pret) {
            if ($js) { $script:Console.AJouer = $js }   # (la scène se charge encore : joué quand elle sera prête, sinon perdu)
        } else {
            Invoke-ScriptConsole 'window.mindset.reprendre()'
            if ($js) { Invoke-ScriptConsole $js }
            Send-EtatConsole -Force
        }
        try { [void]$script:Console.Vue.Focus() } catch {}
    } else {
        if (-not $accueil) { $script:Console.Parametres = $false }   # (une appli affichée : les Paramètres sont quittés)
        if ($script:Console.Vue) {
            # Une autre page : pause tout de suite, fermeture au bout d'une minute (ConsoleTimer)
            Invoke-ScriptConsole 'window.mindset.pause()'
            if (-not $script:Console.QuitteeA) { $script:Console.QuitteeA = Get-Date }
        }
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
            desc = $(if ($a.Presentation) { $a.Presentation } else { $a.Description })
            reseau = $(if (-not $e.Inst) { Get-PhraseReseauAppli $a } else { '' }); lien = $(if (-not $e.Inst) { Get-LienReseauAppli $a } else { '' })   # (avant de l'installer : ce qui part sur Internet)
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
    if ($Force -or $json -ne $script:Console.EtatEnvoye) { $script:Console.EtatEnvoye = $json; Invoke-ScriptConsole "window.mindset.etat($json)" }
    try { Send-MajConsole -Force:$Force } catch { Write-Log "Console 3D : état des mises à jour non envoyé ($_)" }   # (après : les logos des applis sont connus)
}

# ---------------------------------------------------------------------------
# Les mises à jour, visibles dans la console (window.mindset.majAuto, la carte dans la poutre du haut de la scène) :
#   - la pastille « Mise à jour automatique » : le réglage MajAuto (le même que Paramètres > Mises à jour) ; grisée si
#     « Chercher les nouvelles versions » est coupé (elles ne peuvent pas tourner) ;
#   - ce qui se passe, par ordre d'importance : un téléchargement (avec son %) ou une installation, d'une appli ou de
#     Mindset lui-même (la carte suit celle en cours) ; une recherche des nouvelles versions ; une version disponible,
#     « prête » avec son bouton si les mises à jour automatiques ne la feront pas (pastille décochée, ou essai raté il
#     y a moins de 6 heures), sinon « en attente » avec la raison (un jeu, une appli dont on se sert, Mindset à l'écran,
#     ou dans un instant) ; la recherche coupée ; sinon tout est à jour ;
#   - la dernière mise à jour faite, pendant 12 heures (mindset.ps1, Get-DerniereMaj), avec ses nouveautés.
# Envoyé avec l'état des applis (toutes les 1,5 s, seulement s'il a changé), et tout de suite après un geste.
# ---------------------------------------------------------------------------
function Get-EtatMajConsole {
    $verif = [bool](Test-VerifVersionsActive)
    $auto = [bool](Test-MajAutoActive)
    $autoPossible = $auto -and $verif -and -not $MindsetAdmin -and (Test-TacheInstallation)
    $infos = { param($Id, $Nom, $Couleur, $Version) [ordered]@{ id = $Id; nom = $Nom; c = (ConvertTo-ThemeHex $Couleur); version = [string]$Version } }
    $phase = ''; $appli = $null; $progres = 0.0; $raison = ''
    # 1. Ce qui se télécharge ou s'installe (pas une désinstallation : ni téléchargement, ni installation en cours)
    $occupees = @($Applis | Where-Object { $script:Occupe[$_.Id] -and ($script:Progres[$_.Id] -or $script:EnCours[$_.Id]) })
    $a = @($occupees | Where-Object { $script:Progres[$_.Id] }) + $occupees | Select-Object -First 1   # (d'abord celle qui télécharge)
    if ($a) {
        $pr = $script:Progres[$a.Id]; $c = $script:EnCours[$a.Id]; $pub = $script:Publications[$a.Id]
        $v = if ($c -and $c.Version) { $c.Version } elseif ($pub -and $pub.Version) { $pub.Version } else { [string]$script:MajAuto[$a.Id] }
        $appli = & $infos $a.Id $a.Nom $a.Couleur $v
        if ($pr) { $phase = 'telechargement'; if ($pr.Total -gt 0) { $progres = [math]::Min(1.0, [double]$pr.Recu / $pr.Total) } }
        else { $phase = 'installation'; $progres = 1.0 }
    } elseif ($script:MajMindsetEnCours -and $script:ProgresMindset -and $script:ProgresMindset.Version) {
        # Mindset lui-même : sa nouvelle version se télécharge (elle sera ensuite « prête »)
        $pr = $script:ProgresMindset
        $appli = & $infos 'mindset' 'Mindset' '#ECEAF7' $pr.Version
        $phase = 'telechargement'; if ($pr.Total -gt 0) { $progres = [math]::Min(1.0, [double]$pr.Recu / $pr.Total) }
    }
    # 2. Une recherche en cours (une question à GitHub sans réponse depuis moins de 2 minutes ; au moins 2 secondes)
    if (-not $phase) {
        $enRecherche = @($script:Recherches.Values | Where-Object { ((Get-Date) - $_).TotalMinutes -lt 2 }).Count -or ($script:MajMindsetEnCours -and -not ($script:ProgresMindset -and $script:ProgresMindset.Version))
        if ($enRecherche -or ((Get-Date) - $script:RechercheDepuis).TotalSeconds -lt 2) { $phase = 'recherche' }
    }
    # 3. Une version disponible : prête (c'est à toi de lancer) ou en attente (elle se fera toute seule)
    if (-not $phase) {
        $dispo = @(foreach ($x in $Applis) {
            $e = Get-EtatCarte $x
            if ($e.MajDispo -and -not $e.Occupe) { @{ Id = $x.Id; Nom = $x.Nom; Couleur = $x.Couleur; Version = [string]$e.Pub.Version } }
        })
        $m = $script:MajMindset
        if ($m -and (Test-VersionPlusRecente ([string]$m.Version) $AppVersion)) { $dispo += @{ Id = 'mindset'; Nom = 'Mindset'; Couleur = '#ECEAF7'; Version = [string]$m.Version } }
        $d = $dispo | Select-Object -First 1
        if ($d) {
            $appli = & $infos $d.Id $d.Nom $d.Couleur $d.Version
            if (-not $autoPossible -or (Test-MajAutoRecente $d.Id $d.Version)) { $phase = 'prete' }
            else {
                $phase = 'attente'
                $raison = if ($script:MajAutoJeu) { 'jeu' } elseif ($d.Id -eq 'mindset') { 'veille' } elseif ($script:MajAutoAttentes[$d.Id]) { $script:MajAutoAttentes[$d.Id] } else { 'bientot' }
            }
        }
    }
    if (-not $phase) { $phase = if ($verif) { 'ajour' } else { 'coupee' } }
    # La dernière mise à jour faite (12 heures), et ses nouveautés
    $fait = $null; $f = Get-DerniereMaj
    if ($f) { $x = Get-AppliMaj $f.id $f.nom; $fait = & $infos $x.Id $x.Nom $x.Couleur $f.version; $fait.quand = Format-QuandMaj $f.quand; $fait.auto = [bool]$f.auto; $fait.notes = [string]$f.notes }
    ConvertTo-Json -InputObject ([ordered]@{ auto = $auto; verif = $verif; phase = $phase; raison = $raison; appli = $appli
        progres = [math]::Round($progres, 3); fait = $fait }) -Depth 4 -Compress
}
function Send-MajConsole([switch]$Force) {
    if (-not $script:Console.Vue -or -not $script:Console.Pret) { return }
    $json = Get-EtatMajConsole
    if (-not $Force -and $json -eq $script:Console.MajEnvoye) { return }
    $script:Console.MajEnvoye = $json
    Invoke-ScriptConsole "window.mindset.majAuto($json)"
}
# Un clic sur la pastille : le réglage change (le même que Paramètres > Mises à jour, qui suit). Recherche coupée : la
# pastille ne peut pas tourner à vide, elle ne change pas (la carte propose les réglages).
function Set-MajAutoConsole([bool]$Oui) {
    if (Test-VerifVersionsActive) {
        Set-Setting 'MajAuto' $Oui
        Write-Log "Mises à jour automatiques : $(if ($Oui) { 'oui' } else { 'non' }) (pastille de la console)"
        Update-ReglagesMaj
    }
    Send-MajConsole -Force
    Send-ParametresConsole -Force
}
# « Mettre à jour » sur la carte, pour Mindset lui-même : il se ferme le temps de la mise à jour, une question d'abord
function Confirm-MajMindsetConsole {
    Show-Confirmation 'Mettre à jour Mindset ?' "Mindset va se fermer, se mettre à jour (version $($script:MajMindset.Version)) puis se rouvrir tout seul. Tes applis restent ouvertes." 'Mettre à jour' { Start-MajMindset }
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
        if ($script:Console.AJouer) { Invoke-ScriptConsole $script:Console.AJouer; $script:Console.AJouer = $null }
        Write-Log 'Console 3D prête'
        if ($EnTest -and $env:MINDSET_CONSOLE_CAPTURE) { Start-CaptureConsole $env:MINDSET_CONSOLE_CAPTURE }
        return
    }
    if ($type -eq 'erreur') { Write-Log "Console 3D : erreur du script ($(([string]$m.texte) -replace '\s+', ' '))"; return }
    if ($type -eq 'reglage') { if ($script:Console.Parametres) { Invoke-ReglageConsole $m }; return }   # (parametres.ps1)
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
                $script:Console.Lancee = -not (Test-AppliOuverte $a); $script:Console.DureeAttendue = $null   # (lancée par ce clic : sa durée d'ouverture est retenue)
                if ($script:Console.Lancee) { Start-AppliCachee $a }
                $script:Console.Attente = $a.Id; $script:Console.AttenteDepuis = Get-Date
                Invoke-ScriptConsole "window.mindset.jouerOuverture('$($a.Id)')"
                $script:ConsoleAttenteTimer.Start()
            }
        }
        'installer'  { if ($a -and -not (Get-Installation $a)) { if ($script:Trouvees[$a.Id]) { Confirm-PriseEnCharge $a } else { Start-InstallAppli $a } } }
        'maj'        { if ($a) { Confirm-MiseAJour $a } elseif ($id -eq 'mindset' -and $script:MajMindset) { Confirm-MajMindsetConsole } }
        'confidentialite' { if ($a) { Open-PageConfidentialite $a.Id } }   # (la page de l'appli, ou celle de Mindset)
        'fermer'     { if ($a) { Stop-AppliConsole $a } }
        'parametres' { $script:OngletParametres = 'general'; Show-Page 'parametres' }   # (tuile du menu en grand ou bouton rond : dans l'écran)
        'parametresFermes' { $script:Console.Parametres = $false }   # (retour au menu en grand, sur la tuile Paramètres)
        'actualiser' {
            $avant = $script:DernieresPublications
            Invoke-Actualiser -Clic
            $t = if ($script:DernieresPublications -ne $avant) { 'Recherche des nouvelles versions...' } else { 'Tout vient d''être vérifié' }   # (clics répétés : Invoke-Actualiser)
            Invoke-ScriptConsole "window.mindset.message($(ConvertTo-Json -InputObject $t -Compress))"
        }
        'majAuto'    { Set-MajAutoConsole ([bool]$m.valeur) }   # (la pastille « Mise à jour automatique »)
        'majReglages' { Show-OngletParametres 'maj'; Show-Page 'parametres' }   # (recherche coupée : les réglages des mises à jour)
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
    if ($script:Console.Parametres -and $script:PageCourante -eq 'accueil') { try { Send-ParametresConsole } catch { Write-Log "Console 3D : Paramètres non envoyés ($_)" } }
})
if ($script:Console.Possible) { $script:ConsoleTimer.Start() }

# La barre de chargement d'une appli, sur l'écran de la console : même avancée que la jauge de chargement.ps1 (90 % à
# la durée de sa dernière ouverture, retenue à chaque fois, puis elle s'approche doucement de 99 %) ; sa fenêtre prête,
# la barre va au bout et l'appli prend la place de la console
function Get-AvanceeOuverture($Appli, [double]$Ecoule) {
    if (-not $script:Console.DureeAttendue) {
        $d = [double](Get-Setting "Ouverture-$($Appli.Id)" $script:JaugeDureesDefaut[$Appli.Id])
        $script:Console.DureeAttendue = if ($d -ge 1) { $d } else { 8.0 }
    }
    $k = [math]::Max(0.0, $Ecoule / $script:Console.DureeAttendue)
    $v = if ($k -lt 1) { 0.9 * (1 - [math]::Pow(1 - $k, 2)) } else { 0.9 + 0.09 * (1 - [math]::Exp(-($k - 1))) }
    [math]::Round($v, 3)
}

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
    if (-not $prete) { Invoke-ScriptConsole "window.mindset.avancee('$id', $((Get-AvanceeOuverture $a $ecoule).ToString([Globalization.CultureInfo]::InvariantCulture)))" }
    if ($prete -or $ecoule -gt 60 -or ($ecoule -gt 15 -and -not (Test-AppliOuverte $a))) {
        $script:Console.Attente = $null; $script:ConsoleAttenteTimer.Stop()
        if ($prete -and $script:Console.Lancee) { Save-DureeOuverture $a $script:Console.AttenteDepuis }   # (chargement.ps1)
        Invoke-ScriptConsole "window.mindset.appliPrete('$id')"
        if (-not $prete) { Write-Log "Console 3D : $($a.Nom) pas prête après $([int]$ecoule) s, affichée quand même" }
    }
})

# ---------------------------------------------------------------------------
# Les Paramètres de Mindset, dans l'écran de la console (comme le menu en grand) : la tuile Paramètres, le bouton rond,
# et toute autre demande (Show-Page 'parametres', afficher-page.txt « parametres:son »...) les y ouvrent. Retour (flèche,
# Échap, B) ramène au menu en grand, sur la tuile Paramètres. Ce que l'écran affiche et ce qu'il demande : parametres.ps1.
# ---------------------------------------------------------------------------
function Open-ParametresConsole {
    $script:Console.Parametres = $true
    $script:ThemesConsole = $null   # (relus à chaque ouverture, comme la page d'avant : un thème importé ou un micro branché y est)
    if ($script:OngletParametres -eq 'son') { Update-AppareilsConsole }
    if ($script:PageCourante -ne 'accueil') { Show-Page 'accueil' } else { Update-PageConsole }   # (Update-PageConsole les ouvre)
}
# L'état des réglages, renvoyé quand il change (après un geste, une recherche de versions, un appareil branché...)
function Send-ParametresConsole([switch]$Force) {
    if (-not $script:Console.Parametres -or -not $script:Console.Vue -or -not $script:Console.Pret) { return }
    $json = Get-EtatParametres
    if (-not $Force -and $json -eq $script:Console.ParametresEnvoyes) { return }
    $script:Console.ParametresEnvoyes = $json
    Invoke-ScriptConsole "window.mindset.reglages($json)"
}
function Send-ImagesThemesConsole { if ($script:Console.Parametres) { Invoke-ScriptConsole "window.mindset.reglages(null, null, false, $(Get-ImagesThemesConsole))" } }

# Le bouton Menu (la maison), dans la barre de l'appli, sur son écran d'attente et dans les Paramètres : retour au menu
# en grand dans l'écran de la console (Update-PageConsole ; une appli affichée reste ouverte, en pause). Échap fait pareil,
# comme la maison d'une appli (« menu » dans afficher-page.txt, Open-PageDemandee).
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
        # La console à l'écran (le réglage vient de ses Paramètres) : elle change de vitesse sans s'éteindre ; sinon elle
        # est recréée à la nouvelle vitesse au retour sur l'accueil
        if ($script:Console.Vue -and $script:Console.Pret -and $script:PageCourante -eq 'accueil') { Invoke-ScriptConsole "window.mindset.vitesse('$Choix')"; return }
        Remove-VueConsole 'réglage Animations changé'
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
