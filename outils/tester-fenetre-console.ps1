# Mindset : tests de la fenêtre et de la console 3D (lot 5).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-fenetre-console.ps1
#   (-Fichiers <dossier> : un autre Mindset\fichiers, par exemple une ancienne version, pour la contre-épreuve)
#
# On vérifie que :
#   1. la fenêtre tient dans l'écran : portable en 125 % ou 150 %, écran 1366 x 768 (écrans simulés, jamais l'écran du PC) ;
#   2. Mindset caché ne prend presque plus de processeur : état relu moins souvent, animations arrêtées (mesuré sur un
#      vrai Mindset de test, montré hors de l'écran puis caché) ;
#   3. Mindset ne garde pas son dossier des programmes comme dossier de travail, ni ce qu'il lance ; et le WebView2
#      commun, resté ouvert pour une autre appli, n'empêche pas de renommer le dossier de Mindset ;
#   4. un incident de WebView2 n'abandonne plus la console 3D : le processus de la carte graphique arrêté, elle continue ;
#      celui de la page arrêté, elle redémarre (vrai Mindset de test et son propre WebView2, hors de l'écran).
# Rien sur le vrai PC : données dans un dossier de test, fenêtres hors de l'écran, seuls les programmes lancés ici sont
# fermés (le WebView2 du Mindset de test a son propre dossier). Code de sortie 1 si un cas échoue (CI de GitHub).
param([string]$Fichiers = '')

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = if ($Fichiers) { (Resolve-Path -LiteralPath $Fichiers).Path } else { Join-Path $racine 'Mindset\fichiers' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

$script:Reussis = 0
$script:Echoues = @()
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
    }
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

$tmp = Join-Path $env:TEMP "mindset-fenetre-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName   # (en nom long : sur GitHub, TEMP est en nom court)
$script:Lances = New-Object System.Collections.ArrayList
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# Les fonctions de Mindset sont prises dans ses fichiers (par l'analyseur : les modules exécutent du code au chargement).
# Une fonction absente (ancienne version) n'est pas définie : les cas qui en ont besoin échouent.
$asts = @{}
foreach ($m in @(Get-ChildItem -LiteralPath (Join-Path $fichiers 'modules') -Filter '*.ps1' -File)) {
    $e = $null
    $asts[$m.Name] = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($m.FullName, [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
    if ($e) { throw "$($m.Name) illisible : $($e[0].Message)" }
}
function Get-TexteFonction([string]$Fichier, [string]$Nom) {
    $x = @($asts[$Fichier].FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Nom }, $true))
    if ($x.Count) { $x[0].Extent.Text } else { '' }
}
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    foreach ($n in $Noms) {
        $t = Get-TexteFonction $Fichier $n
        if (-not $t) { continue }
        . ([scriptblock]::Create($t))
        Set-Item -Path "function:script:$n" -Value (Get-Item "function:$n").ScriptBlock
    }
}

# Un Mindset de test : données à part, sans réseau, ses variables d'environnement à lui (copiées au lancement)
function Start-MindsetTest([hashtable]$Vars, [string[]]$Arguments = @()) {
    $tout = @{ MINDSET_TEST = '1'; MINDSET_SANS_RESEAU = '1' } + $Vars
    $avant = @{}
    foreach ($k in $tout.Keys) { $avant[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $tout[$k]) }
    try {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$(Join-Path $fichiers 'Mindset.ps1')`"") + $Arguments
        $p = Start-Process -FilePath $powershell -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Vars.MINDSET_DONNEES 'erreurs.txt')
        $null = $p.Handle   # (sans lui, Windows PowerShell ne donne pas le code de sortie)
        [void]$script:Lances.Add($p)
        $p
    } finally { foreach ($k in $tout.Keys) { [Environment]::SetEnvironmentVariable($k, $avant[$k]) } }
}
function Get-Journal([string]$Donnees) { try { [IO.File]::ReadAllText((Join-Path $Donnees 'Mindset\journal.txt'), [Text.Encoding]::UTF8) } catch { '' } }
function Wait-Fichier([string]$Fichier, [int]$Secondes, $Processus = $null) {
    $limite = (Get-Date).AddSeconds($Secondes)
    while (-not (Test-Path -LiteralPath $Fichier) -and (Get-Date) -lt $limite) {
        if ($Processus -and $Processus.HasExited) { break }
        Start-Sleep -Milliseconds 300
    }
    Test-Path -LiteralPath $Fichier
}

try {
    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '1. La fenêtre tient dans l''écran (écrans simulés)'
    # -------------------------------------------------------------------------------------------------------------
    Import-Fonctions 'interface.ps1' @('Get-TailleFenetre')
    # (zone utile en unités de la fenêtre : écran divisé par l'échelle de Windows, sans la barre des tâches de 48 pixels)
    $ecrans = @(
        @{ Nom = '1920 x 1080 à 125 %'; L = 1536; H = 826 }
        @{ Nom = '1920 x 1080 à 150 %'; L = 1280; H = 688 }
        @{ Nom = '1366 x 768 à 100 %'; L = 1366; H = 720 }
        @{ Nom = '1366 x 768 à 125 %'; L = 1092; H = 576 }
        @{ Nom = '1280 x 720 à 100 % (jamais vu)'; L = 1280; H = 672 }
        @{ Nom = '2560 x 1600 à 175 % (jamais vu)'; L = 1462; H = 886 }
        @{ Nom = '3840 x 2160 à 150 % (grand écran)'; L = 2560; H = 1408 }
    )
    foreach ($ec in $ecrans) {
        Test-Cas "$($ec.Nom) : la fenêtre et sa taille minimale tiennent dans l'écran" {
            $t = Get-TailleFenetre 1340 930 1000 640 $ec.L $ec.H
            $t.Largeur -le $ec.L -and $t.Hauteur -le $ec.H -and $t.MinLargeur -le $t.Largeur -and $t.MinHauteur -le $t.Hauteur -and
                $t.Largeur -eq [math]::Min(1340, $ec.L) -and $t.Hauteur -eq [math]::Min(930, $ec.H)
        }
    }
    Test-Cas 'Grand écran : la taille d''origine (1340 x 930) et sa taille minimale restent' {
        $t = Get-TailleFenetre 1340 930 1000 640 2560 1408
        $t.Largeur -eq 1340 -and $t.Hauteur -eq 930 -and $t.MinLargeur -eq 1000 -and $t.MinHauteur -eq 640
    }

    # Le vrai Mindset de test, sur deux écrans simulés en même temps (image de sa fenêtre : sa taille intérieure)
    $essais = @(
        @{ Ecran = '1092x576'; L = 1092; H = 576 }
        @{ Ecran = '2560x1408'; L = 2560; H = 1408 }
    )
    foreach ($x in $essais) {
        $x.Dossier = Join-Path $tmp "ecran-$($x.Ecran)"
        New-Item -ItemType Directory -Force -Path $x.Dossier | Out-Null
        $x.Image = Join-Path $x.Dossier 'capture.png'
        $x.P = Start-MindsetTest @{ MINDSET_DONNEES = $x.Dossier; MINDSET_CAPTURE = $x.Image; MINDSET_CAPTURE_DELAI = '1'; MINDSET_TEST_ECRAN = $x.Ecran }
    }
    foreach ($x in $essais) { if (-not $x.P.WaitForExit(90000)) { $x.P.Kill() } }
    function Get-TailleImage([string]$F) { $i = [System.Drawing.Image]::FromFile($F); try { @{ L = $i.Width; H = $i.Height } } finally { $i.Dispose() } }
    $petit = $essais[0]; $grand = $essais[1]
    Test-Cas 'Vrai Mindset, écran 1366 x 768 à 125 % : toute la fenêtre est dans l''écran' {
        $t = Get-TailleImage $petit.Image
        Write-Host "         (intérieur de la fenêtre : $($t.L) x $($t.H), écran $($petit.L) x $($petit.H))"
        $t.L -le $petit.L -and $t.H -le $petit.H -and $t.L -ge 900 -and $t.H -ge 480
    }
    Test-Cas 'Vrai Mindset, grand écran : la fenêtre garde sa taille' {
        $t = Get-TailleImage $grand.Image
        Write-Host "         (intérieur de la fenêtre : $($t.L) x $($t.H))"
        # (un PC de test à petit écran ne laisse pas une fenêtre dépasser son écran : on compare à ce qu'il permet)
        $maxL = [math]::Min(1300, [System.Windows.SystemParameters]::VirtualScreenWidth - 40)
        $maxH = [math]::Min(860, [System.Windows.SystemParameters]::VirtualScreenHeight - 40)
        $t.L -ge $maxL -and $t.L -le 1340 -and $t.H -ge $maxH -and $t.H -le 930
    }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '2. Mindset caché : presque plus de processeur'
    # -------------------------------------------------------------------------------------------------------------
    # Le rythme des minuteries, avec une fausse fenêtre
    Import-Fonctions 'accueil.ps1' @('Update-RythmeMinuteries')
    $script:RythmeCache = 30
    $script:EtatTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:EtatTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:ConsoleTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:ConsoleTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:CartesRelues = 0
    function Update-Cartes { $script:CartesRelues++ }
    function Update-Greeting { }
    function Write-ErreurImprevue($E) { }
    $Window = [pscustomobject]@{ IsVisible = $false; WindowState = 'Normal' }
    Test-Cas 'Caché près de l''horloge : état et console relus toutes les 30 secondes' {
        Update-RythmeMinuteries
        $script:EtatTimer.Interval.TotalSeconds -eq 30 -and $script:ConsoleTimer.Interval.TotalSeconds -eq 30
    }
    Test-Cas 'Réaffiché : les cartes tout de suite, puis toutes les 2 secondes (console : 1,5 s)' {
        $script:CartesRelues = 0; $Window.IsVisible = $true
        Update-RythmeMinuteries
        $script:CartesRelues -eq 1 -and $script:EtatTimer.Interval.TotalSeconds -eq 2 -and $script:ConsoleTimer.Interval.TotalMilliseconds -eq 1500
    }
    Test-Cas 'Réduit dans la barre des tâches : comme caché' {
        $Window.WindowState = 'Minimized'
        Update-RythmeMinuteries
        $script:EtatTimer.Interval.TotalSeconds -eq 30
    }
    Test-Cas 'Rien ne change si le rythme est déjà le bon (les cartes ne sont pas relues pour rien)' {
        $Window.WindowState = 'Normal'; Update-RythmeMinuteries; $script:CartesRelues = 0
        Update-RythmeMinuteries
        $script:CartesRelues -eq 0
    }
    Remove-Variable Window -Scope Script -ErrorAction SilentlyContinue

    # Le vrai Mindset de test : montré hors de l'écran avec ses animations (logo, jauge de chargement), puis caché
    $dossier = Join-Path $tmp 'processeur'
    New-Item -ItemType Directory -Force -Path $dossier | Out-Null
    $etat = Join-Path $dossier 'etat.json'
    $essai = Join-Path $dossier 'essai.ps1'
    [IO.File]::WriteAllText($essai, @'
# (chargé par Mindset de test après ses modules : ses animations comme chez l'utilisateur, montré hors de l'écran, puis caché)
$EnTest = $false
$ui.LogoHote.Children.Clear(); Start-LogoAnime $ui.LogoHote
$script:Jauge = @{ Boucles = (New-Object System.Collections.ArrayList); Timers = @() }
$script:EssaiRot = New-Object System.Windows.Media.RotateTransform
Start-JaugeBoucle $script:EssaiRot ([System.Windows.Media.RotateTransform]::AngleProperty) 0 360 1000 $false
$EnTest = $true
$Window.WindowStartupLocation = 'Manual'; $Window.Left = -10000; $Window.Top = 0; $Window.ShowActivated = $false; $Window.ShowInTaskbar = $false
$script:EssaiN = 0; $script:EssaiEtat = @{}
function Get-EssaiEtat {
    @{ Etat = $script:EtatTimer.Interval.TotalSeconds; Console = $script:ConsoleTimer.Interval.TotalSeconds
       Boucles = @($script:BouclesVisibles | Where-Object { $_.Tourne }).Count; Total = @($script:BouclesVisibles).Count
       LogoTimer = [bool]($script:LogoTimer -and $script:LogoTimer.IsEnabled) }
}
$script:EssaiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EssaiTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:EssaiTimer.Add_Tick({
    $script:EssaiN++
    if ($script:EssaiN -eq 2) { $script:EssaiEtat.Visible = Get-EssaiEtat; Stop-JaugeAppli; $Window.Hide() }
    if ($script:EssaiN -eq 4) {
        $this.Stop()
        $script:EssaiEtat.Cache = Get-EssaiEtat
        [IO.File]::WriteAllText($env:MINDSET_TEST_ETAT, ($script:EssaiEtat | ConvertTo-Json -Compress))
    }
})
$script:EssaiTimer.Start()
'@, (New-Object Text.UTF8Encoding $true))
    $p = Start-MindsetTest @{ MINDSET_DONNEES = $dossier; MINDSET_TEST_SCRIPT = $essai; MINDSET_TEST_ETAT = $etat }
    $pret = Wait-Fichier $etat 90 $p
    $e = if ($pret) { Get-Content -LiteralPath $etat -Raw | ConvertFrom-Json } else { $null }
    $ms = -1
    if ($pret -and -not $p.HasExited) {
        Start-Sleep -Seconds 3
        $p.Refresh(); $c0 = $p.TotalProcessorTime.TotalMilliseconds; $t0 = Get-Date
        Start-Sleep -Seconds 30
        $p.Refresh(); $ms = ($p.TotalProcessorTime.TotalMilliseconds - $c0) * 30 / ((Get-Date) - $t0).TotalSeconds
        Write-Host "         (Mindset caché : $([int]$ms) ms de processeur en 30 s ; avant la correction, environ 1000 ms)"
    }
    if (-not $p.HasExited) { $p.Kill() }
    Test-Cas 'Montré : les animations du logo tournent, état relu toutes les 2 secondes' { $e -and $e.Visible.Total -ge 5 -and $e.Visible.Boucles -eq $e.Visible.Total -and $e.Visible.Etat -eq 2 }
    Test-Cas 'Caché : plus aucune animation, minuterie du logo arrêtée, état relu toutes les 30 secondes' { $e -and $e.Cache.Boucles -eq 0 -and -not $e.Cache.LogoTimer -and $e.Cache.Etat -eq 30 -and $e.Cache.Console -eq 30 }
    Test-Cas 'Caché : moins de 300 ms de processeur en 30 secondes (1 % d''un cœur)' { $ms -ge 0 -and $ms -lt 300 }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '3. Dossier de travail : le dossier des programmes de Mindset reste libre'
    # -------------------------------------------------------------------------------------------------------------
    $fonction = Get-TexteFonction 'interface.ps1' 'Set-DossierTravailNeutre'
    function Test-Renommage([bool]$Neutre) {
        $d = Join-Path $tmp "travail-$Neutre"
        $prog = Join-Path $d 'Programmes'
        New-Item -ItemType Directory -Force -Path $prog | Out-Null
        $sortie = Join-Path $d 'pid.txt'
        $enfant = Join-Path $d 'enfant.ps1'
        # (le faux Mindset, lancé dans son dossier des programmes comme par un raccourci : il lance un programme, sans
        # lui donner de dossier de travail, comme Mindset lance une relance ou un navigateur)
        $suite = @'
$p = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" -ArgumentList '-n', '40', '127.0.0.1' -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText('SORTIE', [string]$p.Id)
Start-Sleep -Seconds 40
'@
        [IO.File]::WriteAllText($enfant, $fonction + "`r`n" + $(if ($Neutre) { "Set-DossierTravailNeutre`r`n" } else { '' }) + $suite.Replace('SORTIE', $sortie), (New-Object Text.UTF8Encoding $true))
        $p = Start-Process -FilePath $powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$enfant`"" -WorkingDirectory $prog -WindowStyle Hidden -PassThru
        [void]$script:Lances.Add($p)
        $ok = $false
        if (Wait-Fichier $sortie 30 $p) {
            try { [void]$script:Lances.Add((Get-Process -Id ([int](Get-Content -LiteralPath $sortie -Raw)))) } catch {}
            Start-Sleep -Milliseconds 500
            try { Rename-Item -LiteralPath $prog -NewName 'Programmes2' -ErrorAction Stop; $ok = $true } catch {}
        }
        foreach ($x in @($script:Lances)) { try { if (-not $x.HasExited) { $x.Kill() } } catch {} }
        $ok
    }
    Test-Cas 'La fonction existe (Mindset se place dans le dossier de Windows au démarrage)' { [bool]$fonction }
    Test-Cas 'Mindset et ce qu''il lance ne bloquent pas le renommage de son dossier (mise à jour)' { Test-Renommage $true }
    Test-Cas 'Témoin : sans cela, le renommage est refusé (dossier de travail pris)' { -not (Test-Renommage $false) }

    # Le WebView2 commun : lancé par un faux Mindset (dossier de travail et console dans son dossier des programmes), puis
    # partagé par une fausse autre appli ; le faux Mindset se ferme, le WebView2 continue pour l'autre appli
    $wv = Join-Path $fichiers 'lib\webview2'
    $webview2 = $false
    try {
        Add-Type -Path (Join-Path $wv 'Microsoft.Web.WebView2.Core.dll')
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($wv)
        $webview2 = [bool][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
    } catch {}
    if (-not $webview2) { Write-Host '  (WebView2 absent de ce PC : essai du WebView2 commun sauté)' -ForegroundColor Yellow }
    else {
        $d = Join-Path $tmp 'commun'
        $prog = Join-Path $d 'Programmes'
        New-Item -ItemType Directory -Force -Path (Join-Path $prog 'console') | Out-Null
        [IO.File]::WriteAllText((Join-Path $prog 'console\scene.html'), '<html><body>essai</body></html>')
        $partage = Join-Path $d 'partage.ps1'
        [IO.File]::WriteAllText($partage, @'
param([string]$Wv, [string]$Udf, [string]$Dossier, [string]$Profil, [int]$Secondes, [string]$Sortie)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path "$Wv\Microsoft.Web.WebView2.Core.dll"; Add-Type -Path "$Wv\Microsoft.Web.WebView2.Wpf.dll"
[Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($Wv)
$w = New-Object System.Windows.Window; $w.WindowStartupLocation = 'Manual'; $w.Left = -10000; $w.Top = 0; $w.Width = 300; $w.Height = 200; $w.ShowActivated = $false; $w.ShowInTaskbar = $false
$v = New-Object Microsoft.Web.WebView2.Wpf.WebView2
$cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties; $cp.UserDataFolder = $Udf; $cp.ProfileName = $Profil; $v.CreationProperties = $cp
$w.Content = $v
$v.Add_CoreWebView2InitializationCompleted({
    param($s, $e)
    if (-not $e.IsSuccess) { [IO.File]::WriteAllText($Sortie, 'echec'); $w.Close(); return }
    [IO.File]::WriteAllText($Sortie, [string]$s.CoreWebView2.BrowserProcessId)
    if ($Dossier) { $s.CoreWebView2.SetVirtualHostNameToFolderMapping('essai.local', (Join-Path $Dossier 'console'), 'Deny'); $s.CoreWebView2.Navigate('https://essai.local/scene.html') }
    else { $s.CoreWebView2.NavigateToString('<p>autre appli</p>') }
})
$t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromSeconds($Secondes); $t.Add_Tick({ $t.Stop(); $w.Close() }); $t.Start()
$w.Add_Loaded({ [void]$v.EnsureCoreWebView2Async() })
[void]$w.ShowDialog()
$v.Dispose()
'@, (New-Object Text.UTF8Encoding $true))
        $udf = Join-Path $d 'WebView2'
        $sa = Join-Path $d 'a.txt'; $sb = Join-Path $d 'b.txt'
        $a = Start-Process -FilePath $powershell -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$partage`"", '-Wv', "`"$wv`"", '-Udf', "`"$udf`"", '-Dossier', "`"$prog`"", '-Profil', 'Mindset', '-Secondes', '8', '-Sortie', "`"$sa`"" -WorkingDirectory $prog -WindowStyle Hidden -PassThru
        [void]$script:Lances.Add($a)
        [void](Wait-Fichier $sa 40 $a)
        $b = Start-Process -FilePath $powershell -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$partage`"", '-Wv', "`"$wv`"", '-Udf', "`"$udf`"", '-Profil', 'Autre', '-Secondes', '40', '-Sortie', "`"$sb`"" -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -PassThru
        [void]$script:Lances.Add($b)
        [void](Wait-Fichier $sb 40 $b)
        [void]$a.WaitForExit(40000)
        Start-Sleep -Seconds 2
        $navA = try { [int](Get-Content -LiteralPath $sa -Raw) } catch { 0 }
        $navB = try { [int](Get-Content -LiteralPath $sb -Raw) } catch { 0 }
        $vivant = $navA -and $navA -eq $navB -and [bool](Get-Process -Id $navA -ErrorAction SilentlyContinue)
        Test-Cas 'Le WebView2 lancé par le faux Mindset est partagé, et tourne encore pour l''autre appli après sa fermeture' { $vivant }
        Test-Cas 'Ce WebView2 n''empêche pas de renommer le dossier des programmes de Mindset (mise à jour)' {
            $ok = $false
            try { Rename-Item -LiteralPath $prog -NewName 'Programmes2' -ErrorAction Stop; $ok = $true } catch {}
            $vivant -and $ok
        }
        if (-not $b.HasExited) { $b.Kill() }   # (son WebView2, dans le dossier de test, s'arrête avec lui)
    }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '4. Un incident de WebView2 n''abandonne plus la console 3D'
    # -------------------------------------------------------------------------------------------------------------
    Import-Fonctions 'console.ps1' @('Get-ReactionIncidentConsole', 'Receive-IncidentConsole', 'Stop-Console', 'Resume-ConsoleArretee')
    $script:Journal = New-Object Collections.Generic.List[string]
    function Write-Log([string]$Texte) { $script:Journal.Add($Texte) }
    $script:Retirees = 0; $script:PagesMontrees = 0; $script:RaisonFausse = $null
    function Remove-VueConsole { $script:Retirees++ }
    function Update-PageConsole { $script:PagesMontrees++ }
    function Set-NavigationConsole { }
    function Test-ConsolePossible { $script:RaisonFausse }
    $script:ConsoleTimer = [pscustomobject]@{ Lancee = 0 } | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Lancee++ } -PassThru
    $Dispatcher = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name BeginInvoke -Value { param($Action) $Action.Invoke() } -PassThru
    $Window = [pscustomobject]@{ Dispatcher = $Dispatcher }
    function Reset-Console { $script:Console = @{ Possible = $true }; $script:Retirees = 0; $script:PagesMontrees = 0; $script:Journal.Clear() }

    foreach ($g in 'GpuProcessExited', 'UtilityProcessExited', 'FrameRenderProcessExited', 'UnknownProcessExited', 'SandboxHelperProcessExited') {
        Test-Cas "$g (WebView2 le relance tout seul) : la 3D continue" {
            Reset-Console
            Receive-IncidentConsole $g
            (Get-ReactionIncidentConsole $g) -eq 'continuer' -and $script:Console.Possible -and $script:Retirees -eq 0
        }
    }
    foreach ($g in 'RenderProcessExited', 'BrowserProcessExited', 'RenderProcessUnresponsive') {
        Test-Cas "$g : la 3D redémarre (retirée puis remontrée), sans passer à l'accueil classique" {
            Reset-Console
            Receive-IncidentConsole $g
            (Get-ReactionIncidentConsole $g) -eq 'recreer' -and $script:Console.Possible -and $script:Retirees -eq 1 -and $script:PagesMontrees -eq 1 -and
                -not ($script:Journal -match 'accueil classique')
        }
    }
    Test-Cas '3 incidents en 10 minutes : 3 redémarrages ; le 4e : l''accueil classique' {
        Reset-Console
        1..3 | ForEach-Object { Receive-IncidentConsole 'RenderProcessExited' }
        $trois = $script:Console.Possible -and $script:Retirees -eq 3
        Receive-IncidentConsole 'RenderProcessExited'
        $trois -and -not $script:Console.Possible -and $script:Console.ArreteeA -and ($script:Journal -match 'accueil classique')
    }
    Test-Cas 'Des incidents de plus de 10 minutes ne comptent plus' {
        Reset-Console
        $vieux = (Get-Date).AddMinutes(-11)
        $script:Console.Incidents = @($vieux, $vieux, $vieux)
        Receive-IncidentConsole 'RenderProcessExited'
        $script:Console.Possible -and @($script:Console.Incidents).Count -eq 1
    }
    Test-Cas 'Accueil classique après un échec : rouvert moins de 10 minutes après, pas de nouvel essai' {
        Reset-Console
        Stop-Console 'essai'
        Resume-ConsoleArretee
        -not $script:Console.Possible
    }
    Test-Cas 'Rouvert 10 minutes après ou plus : la 3D est réessayée (plus seulement au prochain démarrage)' {
        $script:Console.ArreteeA = (Get-Date).AddMinutes(-11); $avant = $script:ConsoleTimer.Lancee
        Resume-ConsoleArretee
        $script:Console.Possible -and -not $script:Console.ArreteeA -and $script:ConsoleTimer.Lancee -eq $avant + 1
    }
    Test-Cas 'Réessayée seulement si elle est possible (réglage Animations : aucune, WebView2 enlevé...)' {
        Reset-Console
        Stop-Console 'essai'
        $script:Console.ArreteeA = (Get-Date).AddMinutes(-11); $script:RaisonFausse = 'réglage Animations : aucune'
        Resume-ConsoleArretee
        $script:RaisonFausse = $null
        -not $script:Console.Possible
    }
    Remove-Variable Window -Scope Script -ErrorAction SilentlyContinue
    Remove-Item function:Write-Log -ErrorAction SilentlyContinue

    # Le vrai Mindset de test et sa console 3D (son propre WebView2, dans le dossier de test) : le processus de la carte
    # graphique, puis celui de la page, sont arrêtés
    if (-not $webview2) { Write-Host '  (WebView2 absent de ce PC : essai de la vraie console sauté)' -ForegroundColor Yellow }
    else {
        $dossier = Join-Path $tmp 'incident'
        New-Item -ItemType Directory -Force -Path $dossier | Out-Null
        $essai = Join-Path $dossier 'essai.ps1'
        [IO.File]::WriteAllText($essai, @'
# (chargé par Mindset de test après ses modules : arrête des processus de SON WebView2, celui du dossier de test)
$script:EssaiInc = @{ Etape = 'attente'; Depuis = Get-Date; Debut = Get-Date }
function Get-EssaiEnfants([string]$Genre) {
    $nav = $script:Console.Vue.CoreWebView2.BrowserProcessId
    @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$nav" | Where-Object { $_.CommandLine -like "*--type=$Genre*" -and $_.CommandLine -like "*$env:MINDSET_DONNEES*" })
}
$script:EssaiIncTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EssaiIncTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:EssaiIncTimer.Add_Tick({
    $e = $script:EssaiInc
    $ecoule = ((Get-Date) - $e.Depuis).TotalSeconds
    switch ($e.Etape) {
        'attente' {
            if ($script:Console.Vue -and $script:Console.Pret) {
                $e.Vue = $script:Console.Vue
                $gpu = @(Get-EssaiEnfants 'gpu-process')
                Write-Log "ESSAI carte graphique : $($gpu.Count) processus arrêté(s)"
                foreach ($x in $gpu) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
                $e.Etape = 'gpu'; $e.Depuis = Get-Date
            } elseif (((Get-Date) - $e.Debut).TotalSeconds -gt 90) { Write-Log 'ESSAI console jamais prête'; $this.Stop(); Exit-Mindset }
        }
        'gpu' {
            if ($ecoule -lt 5) { return }
            Write-Log "ESSAI après la carte graphique : même vue $([object]::ReferenceEquals($script:Console.Vue, $e.Vue)), possible $($script:Console.Possible)"
            $r = @(Get-EssaiEnfants 'renderer')
            Write-Log "ESSAI page : $($r.Count) processus arrêté(s)"
            foreach ($x in $r) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
            $e.Etape = 'rendu'; $e.Depuis = Get-Date
        }
        'rendu' {
            if ($script:Console.Vue -and $script:Console.Pret -and -not [object]::ReferenceEquals($script:Console.Vue, $e.Vue)) { Write-Log 'ESSAI 3D revenue'; $this.Stop(); Exit-Mindset }
            elseif ($ecoule -gt 45) { Write-Log "ESSAI 3D pas revenue (possible $($script:Console.Possible))"; $this.Stop(); Exit-Mindset }
        }
    }
})
$script:EssaiIncTimer.Start()
'@, (New-Object Text.UTF8Encoding $true))
        $p = Start-MindsetTest @{ MINDSET_DONNEES = $dossier; MINDSET_CONSOLE = '1'; MINDSET_CAPTURE = (Join-Path $dossier 'inutile.png'); MINDSET_CAPTURE_DELAI = '600'; MINDSET_TEST_SCRIPT = $essai }
        if (-not $p.WaitForExit(180000)) { $p.Kill() }
        $j = Get-Journal $dossier
        Write-Host "         ($((@($j -split "`r?`n" | Where-Object { $_ -match 'ESSAI|Console 3D :' }) | ForEach-Object { $_ -replace '^\S+\s+', '' }) -join ' / '))"
        Test-Cas 'Vraie console : elle s''allume' { $j -match 'Console 3D prête' -and $j -notmatch 'ESSAI console jamais prête' }
        Test-Cas 'Vraie console : processus de la carte graphique arrêté, la 3D continue (même vue)' {
            ($j -match 'ESSAI carte graphique : 0 processus') -or ($j -match 'ESSAI après la carte graphique : même vue True, possible True')
        }
        Test-Cas 'Vraie console : processus de la page arrêté, la 3D redémarre toute seule (pas d''accueil classique)' {
            $j -match 'ESSAI page : [1-9]' -and $j -match 'ESSAI 3D revenue' -and $j -notmatch 'accueil classique'
        }
    }
} finally {
    foreach ($x in @($script:Lances)) { try { if (-not $x.HasExited) { $x.Kill() } } catch {} }
    Start-Sleep -Seconds 2
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Echoues.Count) {
    Write-Host "$($script:Echoues.Count) cas en échec sur $($script:Reussis + $script:Echoues.Count)." -ForegroundColor Red
    exit 1
}
Write-Host "Tous les cas réussis ($($script:Reussis))." -ForegroundColor Green
