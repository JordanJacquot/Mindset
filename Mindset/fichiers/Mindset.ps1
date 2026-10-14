#Requires -Version 5.1
<#
    Mindset 0.1.2
    Le portail de la suite : installe, met à jour et affiche Nevermind et Evermind.

    La liste des applis est dans fichiers\apps.json. Les réglages et le journal sont dans %LOCALAPPDATA%\Mindset\Mindset.

    Mindset.ps1 -Demarrage     lancé avec Windows : démarre en arrière-plan les applis choisies, sans fenêtre, puis se ferme
    Mindset.ps1 -Desinstaller  depuis « Applications installées » de Windows : ouvre la désinstallation de Mindset
#>
param([switch]$Demarrage, [switch]$Desinstaller)

$AppVersion = '0.1.2'
$UpdateRepo = 'JordanJacquot/Mindset'
$MainScript = $PSCommandPath
$AppExe = Join-Path (Split-Path $PSScriptRoot -Parent) 'Mindset.exe'   # le programme qui exécute ce script
$EnTest = [bool]$env:MINDSET_TEST      # test automatique : rien n'est modifié sur le PC
if ($EnTest -and $env:MINDSET_VERSION) { $AppVersion = $env:MINDSET_VERSION }   # (test de la mise à jour de Mindset)

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
$msModules = 'donnees', 'suite', 'themes', 'signature', 'paquets', 'taches', 'applis', 'installations', 'mindset', 'interface', 'logo', 'accueil', 'parametres'
$missing = @(@('natif.cs', 'interface.xaml') + @($msModules | ForEach-Object { "$_.ps1" }) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ModulesDir $_)) })
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'cle-publique.xml'))) { $missing += 'cle-publique.xml' }
if ($missing) {
    [System.Windows.MessageBox]::Show("Des fichiers de Mindset sont manquants :`n`n$($missing -join ', ')`n`nRetélécharge Mindset et remplace tout le dossier.", 'Mindset', 'OK', 'Error') | Out-Null
    exit
}

# Fonctions natives (barre de titre sombre, identité dans la barre des tâches)
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ModulesDir 'natif.cs'), [Text.Encoding]::UTF8))
$AppId = 'JordanJacquot.Mindset'
try { [MSNative]::SetAppId($AppId) } catch {}

# Au démarrage de Windows, pas de fenêtre : seulement ce qu'il faut pour lancer les applis
if ($Demarrage) { $msModules = $msModules | Where-Object { $_ -notin 'interface', 'logo', 'accueil', 'parametres' } }
foreach ($msModule in $msModules) { . (Join-Path $ModulesDir "$msModule.ps1") }

# ---------------------------------------------------------------------------
# Lancement
# ---------------------------------------------------------------------------
Write-Log "Démarrage Mindset $AppVersion (PowerShell $($PSVersionTable.PSVersion))$(if ($Demarrage) { ', lancé avec Windows' })"
if ($Demarrage) {
    Start-Demarrage
    if ($script:InstanceMutex) { try { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose() } catch {} }
    exit
}
if ($env:MINDSET_CAPTURE) { Start-Capture $env:MINDSET_CAPTURE }
$Window.Show()
if ($Desinstaller) { Show-Page 'parametres'; Confirm-DesinstallMindset }
[System.Windows.Threading.Dispatcher]::Run()

if ($script:InstanceMutex) { try { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose() } catch {} }
if ($script:ShowSignal) { try { $script:ShowSignal.Dispose() } catch {} }

# Relance demandée (nouveau thème) : la place est libérée, puis un nouveau Mindset démarre
if ($script:Relancer) {
    if (Test-Path -LiteralPath $AppExe) { Start-Process -FilePath $AppExe }
    else { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$MainScript`"" }
}

# Mindset vient d'être installé dans Program Files : le Mindset installé prend le relais
if ($script:LancerApres) { Start-Process -FilePath $script:LancerApres }
