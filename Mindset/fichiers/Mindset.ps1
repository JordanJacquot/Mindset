#Requires -Version 5.1
<#
    Mindset 2.3.0
    Le portail de la suite : installe, met à jour et affiche ses applis (Nevermind, Evermind et les suivantes).

    La liste des applis est dans fichiers\apps.json. Les réglages et le journal sont dans %LOCALAPPDATA%\Mindset\Mindset.

    Mindset.ps1 -Demarrage     lancé avec Windows : démarre en arrière-plan les applis choisies et reste caché près de l'horloge
    Mindset.ps1 -Desinstaller  depuis « Applications installées » de Windows : ouvre la désinstallation de Mindset
#>
param([switch]$Demarrage, [switch]$Desinstaller)

$AppVersion = '2.3.0'
$UpdateRepo = 'JordanJacquot/Mindset'
$MainScript = $PSCommandPath
$AppExe = Join-Path (Split-Path $PSScriptRoot -Parent) 'Mindset.exe'   # le programme qui exécute ce script
$EnTest = [bool]$env:MINDSET_TEST      # test automatique : rien n'est modifié sur le PC
if ($EnTest -and $env:MINDSET_VERSION) { $AppVersion = $env:MINDSET_VERSION }   # (test de la mise à jour de Mindset)

# ---------------------------------------------------------------------------
# Mindset tourne sans les droits administrateur. Seul son mini-installateur (tâche « \Mindset\Mindset (installation) »)
# les a, pour installer les zips signés. Une installation d'avant la 0.3 (Mindset ouvert en administrateur par sa tâche
# « \Mindset\Mindset ») bascule une fois : tâches refaites (installer-admin.ps1 -Action taches), puis Mindset se rouvre
# sans les droits, par l'Explorateur. Seulement le Mindset du dossier inscrit dans « Applications installées ».
# ---------------------------------------------------------------------------
$EstAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$MarqueCache = Join-Path $env:TEMP 'mindset-rouvrir-cache.marque'   # (rouvert par l'Explorateur, qui ne passe pas -Demarrage)
if (-not $EnTest -and -not $Demarrage -and (Test-Path -LiteralPath $MarqueCache)) {
    if (((Get-Date) - (Get-Item -LiteralPath $MarqueCache).LastWriteTime).TotalSeconds -lt 120) { $Demarrage = $true }
    Remove-Item -LiteralPath $MarqueCache -Force -ErrorAction SilentlyContinue
}
# Ouvert sans droits alors que l'ancienne tâche « \Mindset\Mindset » existe encore : elle sert une dernière fois, pour la
# bascule ci-dessous (sans demande de Windows). Pas plus d'une tentative toutes les 2 minutes (si la bascule échouait).
if (-not $EnTest -and -not $EstAdmin -and -not $Desinstaller) {
    $marqueBascule = Join-Path $env:TEMP 'mindset-bascule.marque'
    $recente = (Test-Path -LiteralPath $marqueBascule) -and ((Get-Date) - (Get-Item -LiteralPath $marqueBascule).LastWriteTime).TotalSeconds -lt 120
    $inscrit = try { [string](Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset' -ErrorAction Stop).InstallLocation } catch { '' }
    if (-not $recente -and $inscrit -and $inscrit -ieq (Split-Path $PSScriptRoot -Parent)) {
        & "$env:SystemRoot\System32\schtasks.exe" /Query /TN '\Mindset\Mindset' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            try { [IO.File]::WriteAllText($marqueBascule, '1') } catch {}
            if ($Demarrage) { try { [IO.File]::WriteAllText($MarqueCache, '1') } catch {} }
            & "$env:SystemRoot\System32\schtasks.exe" /Run /TN '\Mindset\Mindset' 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { exit }
        }
    }
}
if (-not $EnTest -and $EstAdmin -and -not $Desinstaller) {
    $inscrit = try { [string](Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset' -ErrorAction Stop).InstallLocation } catch { '' }
    if ($inscrit -and $inscrit -ieq (Split-Path $PSScriptRoot -Parent)) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rep = Join-Path $env:TEMP "mindset-taches-$PID.json"
        try {
            $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $PSScriptRoot 'installer-admin.ps1')`"", '-Action', 'taches', '-Destination', "`"$inscrit`"", '-Sid', $sid, '-Resultat', "`"$rep`"")
            [void]$p.WaitForExit(60000)
        } catch {}
        Remove-Item -LiteralPath $rep -Force -ErrorAction SilentlyContinue
        if ($Demarrage) { try { [IO.File]::WriteAllText($MarqueCache, '1') } catch {} }
        Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$AppExe`""
        exit
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms

# ---------------------------------------------------------------------------
# Un seul Mindset à la fois : un nouveau lancement ramène simplement la fenêtre
# ---------------------------------------------------------------------------
if (-not $EnTest) {
    $created = $false
    $script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Local\Mindset-Instance', [ref]$created)
    $script:ShowSignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\Mindset-Afficher')
    if (-not $created) {
        if ($Demarrage) { exit }   # déjà ouvert : rien à faire au démarrage de Windows
        # Ce lancement vient d'un clic : il autorise la fenêtre déjà ouverte à passer devant
        try {
            Add-Type -Namespace MS -Name Fg -MemberDefinition '[DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);'
            [void][MS.Fg]::AllowSetForegroundWindow(-1)
        } catch {}
        [void]$script:ShowSignal.Set()
        exit
    }
}

# Retire la marque « téléchargé depuis Internet », pour que Windows n'avertisse plus aux lancements suivants
try { Get-ChildItem -LiteralPath $PSScriptRoot -File -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}

# ---------------------------------------------------------------------------
# Chargement des modules (dossier « modules » à côté de ce fichier)
# ---------------------------------------------------------------------------
$AppDir = $PSScriptRoot
$ModulesDir = Join-Path $AppDir 'modules'
$msModules = 'donnees', 'suite', 'packs', 'themes', 'signature', 'paquets', 'taches', 'applis', 'installations', 'mindset', 'interface', 'logo', 'chargement', 'accueil', 'integration', 'parametres', 'zone', 'console'
$missing = @(@('natif.cs', 'interface.xaml') + @($msModules | ForEach-Object { "$_.ps1" }) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ModulesDir $_)) })
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'cle-publique.xml'))) { $missing += 'cle-publique.xml' }
if ($missing) {
    [System.Windows.MessageBox]::Show("Des fichiers de Mindset sont manquants :`n`n$($missing -join ', ')`n`nRetélécharge Mindset et remplace tout le dossier.", 'Mindset', 'OK', 'Error') | Out-Null
    exit
}

# Les réglages d'abord : lancé par Windows alors que « Mindset se lance avec Windows » est coupé (Paramètres > Général),
# il s'arrête là, avant d'avoir créé la fenêtre ou l'icône près de l'horloge (sinon une icône morte y resterait).
# (la tâche « \Mindset\Mindset (démarrage) » reste : Mindset, sans les droits, ne peut pas la changer)
. (Join-Path $ModulesDir 'donnees.ps1')
if ($Demarrage -and -not (Get-LancerAvecWindows)) { Write-Log 'Lancé avec Windows, mais « Mindset se lance avec Windows » est coupé : rien n''est ouvert'; exit }

# Fonctions natives (barre de titre sombre, identité dans la barre des tâches)
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ModulesDir 'natif.cs'), [Text.Encoding]::UTF8))
$AppId = 'JordanJacquot.Mindset'
try { [MSNative]::SetAppId($AppId) } catch {}

foreach ($msModule in $msModules -ne 'donnees') { . (Join-Path $ModulesDir "$msModule.ps1") }

# ---------------------------------------------------------------------------
# Lancement
# ---------------------------------------------------------------------------
Write-Log "Démarrage Mindset $AppVersion (PowerShell $($PSVersionTable.PSVersion))$(if ($Demarrage) { ', lancé avec Windows' })"
if ($env:MINDSET_CAPTURE) { Start-Capture $env:MINDSET_CAPTURE }
# Lancé avec Windows : il démarre les applis en arrière-plan et reste caché près de l'horloge (zone.ps1)
if ($Demarrage) { Start-Demarrage } else { $Window.Show(); Open-PageDemandee; Start-Demarrage }
if ($Desinstaller) { Show-Page 'parametres'; Confirm-DesinstallMindset }
[System.Windows.Threading.Dispatcher]::Run()

# Quitté pour de bon : les applis ont reçu leur demande de fermeture (integration.ps1) ; on leur laisse 6 secondes,
# puis on ferme celles qui tournent encore (une appli en administrateur ne peut l'être que par un Mindset administrateur)
if ($script:FermerApplis -and -not $EnTest) {   # (jamais en test : les vraies applis de l'utilisateur tournent peut-être)
    $noms = @($Applis | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Exe) })
    # Seulement les programmes installés par Mindset (une copie de travail ou de test du même nom n'est pas touchée)
    $miens = @{}
    foreach ($a in $Applis) { $i = Get-Installation $a; if ($i) { $miens[(Join-Path $i.Dossier $a.Exe).ToLower()] = $a.Nom } }
    $aFermer = { @(Get-Process -Name $noms -ErrorAction SilentlyContinue | Where-Object { $c = try { [string]$_.Path } catch { '' }; -not $c -or $miens.ContainsKey($c.ToLower()) }) }
    $limite = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $limite -and (& $aFermer).Count) { Start-Sleep -Milliseconds 300 }
    # Une ligne par appli (avant : une par processus, d'où des lignes en double)
    $fermes = @{}; $refuses = @{}
    foreach ($p in (& $aFermer)) {
        try { $p.Kill(); $fermes[$p.ProcessName] = 1 + [int]$fermes[$p.ProcessName] } catch { $refuses[$p.ProcessName] = 1 + [int]$refuses[$p.ProcessName] }
    }
    foreach ($n in $fermes.Keys) { Write-Log "$n ne répondait pas : fermé par Mindset$(if ($fermes[$n] -gt 1) { " ($($fermes[$n]) processus)" })" }
    foreach ($n in $refuses.Keys) { Write-Log "$n tourne encore (fermeture refusée par Windows)" }
}
if ($script:InstanceMutex) { try { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose() } catch {} }
if ($script:ShowSignal) { try { $script:ShowSignal.Dispose() } catch {} }

# Relance demandée (nouveau thème) : la place est libérée, puis un nouveau Mindset démarre
if ($script:Relancer) {
    if (Test-Path -LiteralPath $AppExe) { Start-Process -FilePath $AppExe }
    else { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$MainScript`"" }
}

# Mindset vient d'être installé dans Program Files : le Mindset installé prend le relais
if ($script:LancerApres) { Start-Process -FilePath $script:LancerApres }

