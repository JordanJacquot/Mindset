#Requires -Version 5.1
<#
    Mindset 2.17.0
    Le portail de la suite : installe, met à jour et affiche ses applis (Nevermind, Evermind et les suivantes).

    La liste des applis est dans fichiers\apps.json, ou celle publiée en ligne si elle est plus récente (modules\liste.ps1).
    Les réglages et le journal sont dans %LOCALAPPDATA%\Mindset\Mindset.

    Mindset.ps1 -Demarrage     lancé avec Windows : démarre en arrière-plan les applis choisies et reste caché près de l'horloge
    Mindset.ps1 -Desinstaller  depuis « Applications installées » de Windows : lance le désinstalleur autonome
                               (Desinstaller Mindset.exe), ou sans lui, ouvre la désinstallation dans Mindset
#>
param([switch]$Demarrage, [switch]$Desinstaller)

$AppVersion = '2.17.0'
$UpdateRepo = 'JordanJacquot/Mindset'
$MainScript = $PSCommandPath
$AppExe = Join-Path (Split-Path $PSScriptRoot -Parent) 'Mindset.exe'   # le programme qui exécute ce script
$EstAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# Test automatique : rien n'est modifié sur le PC. Les variables de test (MINDSET_*) sont ignorées quand Mindset tourne en
# administrateur depuis son dossier protégé (Program Files\Mindset, X:\Mindset\Programmes, ou celui inscrit dans
# « Applications installées ») : un programme sans droits pourrait sinon y faire charger un script de son choix.
$CopieProtegee = $false
$dossierCopie = Split-Path $PSScriptRoot -Parent
try {
    $inscritHklm = [string](Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset' -ErrorAction Stop).InstallLocation
    $CopieProtegee = $inscritHklm -and $inscritHklm -ieq $dossierCopie
} catch {}
if ($dossierCopie.StartsWith([Environment]::GetFolderPath('ProgramFiles') + '\', [StringComparison]::OrdinalIgnoreCase) -or $dossierCopie -match '^[A-Za-z]:\\Mindset\\Programmes\\') { $CopieProtegee = $true }
$EnTest = [bool]$env:MINDSET_TEST -and -not ($EstAdmin -and $CopieProtegee)
if ($EnTest -and $env:MINDSET_VERSION) { $AppVersion = $env:MINDSET_VERSION }   # (test de la mise à jour de Mindset)

# « -Desinstaller » : le désinstalleur autonome (Desinstaller Mindset.exe, à côté de Mindset.exe) fait tout, Mindset ne
# s'ouvre pas. (Mindset.exe le lance déjà lui-même ; ceci sert quand ce script est lancé directement.)
$Desinstalleur = Join-Path (Split-Path $PSScriptRoot -Parent) 'Desinstaller Mindset.exe'
if ($Desinstaller -and -not $EnTest -and (Test-Path -LiteralPath $Desinstalleur)) {
    try { Start-Process -FilePath $Desinstalleur -WorkingDirectory $env:SystemRoot -ErrorAction Stop; exit } catch {}
}

# ---------------------------------------------------------------------------
# Mindset tourne sans les droits administrateur. Seul son mini-installateur (tâche « \Mindset\Mindset (installation) »)
# les a, pour installer les zips signés. La très vieille tâche « \Mindset\Mindset » (d'avant la 0.3, qui ouvrait Mindset
# en administrateur) n'est plus jamais lancée : la tâche SYSTEM la retire (paramètres.ps1, Start-RemiseEnOrdreTaches),
# sinon le bandeau des Paramètres propose de réactiver le mini-installateur (une demande de Windows), qui la retire aussi.
# Mindset ouvert en administrateur (Explorateur administrateur) se rouvre sans les droits, une fois, ci-dessous.
# ---------------------------------------------------------------------------
$MarqueCache = Join-Path $env:TEMP 'mindset-rouvrir-cache.marque'   # (rouvert par l'Explorateur, qui ne passe pas -Demarrage)
if (-not $EnTest -and -not $Demarrage -and (Test-Path -LiteralPath $MarqueCache)) {
    if (((Get-Date) - (Get-Item -LiteralPath $MarqueCache).LastWriteTime).TotalSeconds -lt 120) { $Demarrage = $true }
    Remove-Item -LiteralPath $MarqueCache -Force -ErrorAction SilentlyContinue
}
# Une fois en 2 minutes au plus : si l'Explorateur a lui-même les droits (contrôle de compte coupé, compte Administrateur
# intégré), il rouvre Mindset en administrateur ; Mindset reste alors ouvert tel quel au lieu de se relancer sans fin.
if (-not $EnTest -and $EstAdmin -and -not $Desinstaller) {
    $marqueAdmin = Join-Path $env:TEMP 'mindset-bascule-admin.marque'
    $recenteAdmin = (Test-Path -LiteralPath $marqueAdmin) -and ((Get-Date) - (Get-Item -LiteralPath $marqueAdmin).LastWriteTime).TotalSeconds -lt 120
    $inscrit = try { [string](Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset' -ErrorAction Stop).InstallLocation } catch { '' }
    if (-not $recenteAdmin -and $inscrit -and $inscrit -ieq (Split-Path $PSScriptRoot -Parent)) {
        try { [IO.File]::WriteAllText($marqueAdmin, '1') } catch {}
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rep = Join-Path $env:TEMP "mindset-taches-$PID.json"
        try {
            $p = Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe') -WorkingDirectory ([Environment]::GetFolderPath('Windows')) -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $PSScriptRoot 'installer-admin.ps1')`"", '-Action', 'taches', '-Destination', "`"$inscrit`"", '-Sid', $sid, '-Resultat', "`"$rep`"")
            [void]$p.WaitForExit(60000)
        } catch {}
        Remove-Item -LiteralPath $rep -Force -ErrorAction SilentlyContinue
        if ($Demarrage) { try { [IO.File]::WriteAllText($MarqueCache, '1') } catch {} }
        Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList "`"$AppExe`""
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
$missing = @(@('natif.cs', 'interface.xaml', 'liste.ps1') + @($msModules | ForEach-Object { "$_.ps1" }) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ModulesDir $_)) })
if (-not @(Get-ChildItem -LiteralPath (Join-Path $AppDir 'cles-publiques') -Filter '*.xml' -File -ErrorAction SilentlyContinue).Count) { $missing += 'cles-publiques' }
if ($missing) {
    [System.Windows.MessageBox]::Show("Des fichiers de Mindset sont manquants :`n`n$($missing -join ', ')`n`nRetélécharge Mindset et remplace tout le dossier.", 'Mindset', 'OK', 'Error') | Out-Null
    exit
}

# Les réglages d'abord : lancé par Windows alors que « Mindset se lance avec Windows » est coupé (Paramètres > Général),
# il s'arrête là, avant d'avoir créé la fenêtre ou l'icône près de l'horloge (sinon une icône morte y resterait).
# (la tâche « \Mindset\Mindset (démarrage) » reste : Mindset, sans les droits, ne peut pas la changer)
# Sauf juste après une mise à jour faite pendant qu'il était caché (« MajMindsetDemande » rempli) : le mini-installateur
# le relance par cette même tâche, et il doit revenir caché près de l'horloge (les notifications des applis y passent).
. (Join-Path $ModulesDir 'donnees.ps1')
# Relancé après une mise à jour demandée à l'écran : le mini-installateur passe toujours par la tâche de démarrage (qui
# donne -Demarrage, sans les droits, dans la session de l'utilisateur), mais Mindset revient avec sa fenêtre
if ($Demarrage -and (Get-Setting 'MajMindsetVisible' $false)) { Set-Setting 'MajMindsetVisible' $false; $Demarrage = $false }
if ($Demarrage -and -not (Get-LancerAvecWindows) -and -not (Get-Setting 'MajMindsetDemande' '')) { Write-Log 'Lancé avec Windows, mais « Mindset se lance avec Windows » est coupé : rien n''est ouvert'; exit }

# Fonctions natives (barre de titre sombre, identité dans la barre des tâches)
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ModulesDir 'natif.cs'), [Text.Encoding]::UTF8))
$AppId = 'JordanJacquot.Mindset'
try { [MSNative]::SetAppId($AppId) } catch {}

foreach ($msModule in $msModules -ne 'donnees') { . (Join-Path $ModulesDir "$msModule.ps1") }
# (test seulement : un script d'essai chargé après les modules, par exemple outils\essai-maj-console.ps1, qui remplace ce
# qui touche au PC par du faux : fausses applis, fausses mises à jour)
if ($EnTest -and $env:MINDSET_TEST_SCRIPT -and (Test-Path -LiteralPath $env:MINDSET_TEST_SCRIPT)) { . $env:MINDSET_TEST_SCRIPT }

# ---------------------------------------------------------------------------
# Lancement
# ---------------------------------------------------------------------------
Write-Log "Démarrage Mindset $AppVersion (PowerShell $($PSVersionTable.PSVersion))$(if ($Demarrage) { ', lancé avec Windows' })"
if ($EnTest -and $env:MINDSET_CAPTURE) { Start-Capture $env:MINDSET_CAPTURE }   # (test seulement : capture puis fermeture)
# Lancé avec Windows : il démarre les applis en arrière-plan et reste caché près de l'horloge (zone.ps1)
if ($Demarrage) { Start-Demarrage } else { $Window.Show(); Open-PageDemandee; Start-Demarrage }
if ($Desinstaller) { Show-Page 'parametres'; Confirm-DesinstallMindset }
[System.Windows.Threading.Dispatcher]::Run()

# Quitté pour de bon : les applis ont reçu leur demande de fermeture (integration.ps1) ; on leur laisse 6 secondes,
# puis on ferme celles qui tournent encore (une appli en administrateur ne peut l'être que par un Mindset administrateur)
if ($script:FermerApplis -and -not $EnTest) {   # (jamais en test : les vraies applis de l'utilisateur tournent peut-être)
    # Seulement les programmes lancés depuis le dossier où chaque appli est installée, trouvés par leur chemin (leur hôte
    # s'appelle Mindset.exe, comme Mindset : jamais par leur nom ; une copie de travail ou de test ailleurs n'est pas touchée)
    $aFermer = { @(foreach ($a in $Applis) { foreach ($p in @(Get-ProcessusAppli $a -Hote)) { [pscustomobject]@{ Appli = $a.Nom; P = $p } } }) }
    $limite = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $limite -and (& $aFermer).Count) { Start-Sleep -Milliseconds 300 }
    # Une ligne par appli (avant : une par processus, d'où des lignes en double)
    $fermes = @{}; $refuses = @{}
    foreach ($x in (& $aFermer)) {
        try { $x.P.Kill(); $fermes[$x.Appli] = 1 + [int]$fermes[$x.Appli] } catch { $refuses[$x.Appli] = 1 + [int]$refuses[$x.Appli] }
    }
    foreach ($n in $fermes.Keys) { Write-Log "$n ne répondait pas : fermé par Mindset$(if ($fermes[$n] -gt 1) { " ($($fermes[$n]) processus)" })" }
    foreach ($n in $refuses.Keys) { Write-Log "$n tourne encore (fermeture refusée par Windows)" }
}
if ($script:InstanceMutex) { try { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose() } catch {} }
if ($script:ShowSignal) { try { $script:ShowSignal.Dispose() } catch {} }

# Relance demandée (nouveau thème) : la place est libérée, puis un nouveau Mindset démarre
if ($script:Relancer) {
    if (Test-Path -LiteralPath $AppExe) { Start-Process -FilePath $AppExe }
    else { Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$MainScript`"" }
}

# Mindset vient d'être installé dans Program Files : le Mindset installé prend le relais
if ($script:LancerApres) { Start-Process -FilePath $script:LancerApres }

