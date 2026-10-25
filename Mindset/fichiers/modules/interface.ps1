# Mindset : chargement de la fenêtre et aides pour l'interface.
# Chargé par Mindset.ps1, qui définit $AppDir et $ModulesDir.

# ---------------------------------------------------------------------------
# Fenêtre (décrite dans interface.xaml)
# ---------------------------------------------------------------------------
# Couleurs (et police) traduites dans le thème de la suite (themes.ps1) avant le chargement
[xml]$Xaml = Convert-ThemeXaml ([IO.File]::ReadAllText((Join-Path $ModulesDir 'interface.xaml'), [Text.Encoding]::UTF8))
try { $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml)) }
catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    Write-Log "Fenêtre impossible à charger : $($e.Message)"
    [Console]::Error.WriteLine("Fenêtre impossible à charger : $($e.Message)")
    if (-not $EnTest) { [System.Windows.MessageBox]::Show("Mindset n'a pas pu s'ouvrir :`n`n$($e.Message)`n`nRetélécharge Mindset et remplace tout le dossier.", 'Mindset', 'OK', 'Error') | Out-Null }
    exit 1
}
$ui = @{}
foreach ($node in $Xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $n = $node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    if ($n) { $ui[$n.Value] = $Window.FindName($n.Value) }
}
$ui.Version.Text = "version $AppVersion"

# Taille de la fenêtre selon l'écran : elle tient toujours dans la zone utile (l'écran sans la barre des tâches), même sur
# un portable réglé à 125 % ou 150 %, ou sur un écran 1366 x 768 (avant, le haut de la fenêtre, avec sa barre de titre et
# sa croix, sortait de l'écran, et le bas était coupé). La zone est en unités de la fenêtre (déjà divisée par l'échelle
# de Windows) ; la taille minimale descend avec, et la fenêtre reste centrée (CenterScreen, dans la zone utile).
function Get-TailleFenetre([double]$Largeur, [double]$Hauteur, [double]$MinLargeur, [double]$MinHauteur, [double]$ZoneLargeur, [double]$ZoneHauteur) {
    $l = [math]::Floor([math]::Min($Largeur, $ZoneLargeur)); $h = [math]::Floor([math]::Min($Hauteur, $ZoneHauteur))
    @{ Largeur = $l; Hauteur = $h; MinLargeur = [math]::Min($MinLargeur, $l); MinHauteur = [math]::Min($MinHauteur, $h) }
}
function Set-TailleFenetre {
    $zone = [System.Windows.SystemParameters]::WorkArea
    if ($EnTest -and $env:MINDSET_TEST_ECRAN -match '^(\d+)x(\d+)$') { $zone = New-Object System.Windows.Rect 0, 0, ([double]$Matches[1]), ([double]$Matches[2]) }   # (test : un autre écran, simulé)
    if ($zone.Width -lt 100 -or $zone.Height -lt 100) { return }   # (zone inconnue : la taille d'origine)
    $t = Get-TailleFenetre $Window.Width $Window.Height $Window.MinWidth $Window.MinHeight $zone.Width $zone.Height
    $Window.MinWidth = $t.MinLargeur; $Window.MinHeight = $t.MinHauteur
    $Window.Width = $t.Largeur; $Window.Height = $t.Hauteur
}
try { Set-TailleFenetre } catch { Write-Log "Taille de la fenêtre : $_" }

# Dossier de travail neutre (le dossier de Windows) : ni Mindset ni ce qu'il lance (applis, navigateur, relance) ne garde
# son dossier des programmes ou celui des téléchargements comme dossier de travail. Un dossier de travail ne peut être ni
# renommé ni supprimé tant que le programme tourne : une mise à jour ou une désinstallation échouerait.
function Set-DossierTravailNeutre {
    if (-not $env:SystemRoot -or -not (Test-Path -LiteralPath $env:SystemRoot)) { return }
    try { [Environment]::CurrentDirectory = $env:SystemRoot; Set-Location -LiteralPath $env:SystemRoot } catch {}
}
Set-DossierTravailNeutre

# Une couleur Néon, traduite dans le thème de la suite
function Get-Brush([string]$Hex) { [System.Windows.Media.BrushConverter]::new().ConvertFromString((ConvertTo-ThemeHex $Hex)) }

# Icône de la fenêtre (le M, la même que Mindset.exe). Chargée en mémoire pour ne pas bloquer le fichier
# (il doit pouvoir être remplacé par une mise à jour).
$IconPath = Join-Path $AppDir 'Mindset.ico'
if (Test-Path -LiteralPath $IconPath) {
    try {
        $frames = [System.Windows.Media.Imaging.BitmapDecoder]::Create((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($IconPath))), 'None', 'OnLoad').Frames
        $Window.Icon = $frames | Sort-Object PixelWidth | Where-Object { $_.PixelWidth -ge 32 } | Select-Object -First 1
    } catch { Write-Log "Icône : $_" }
}

# Commande qui relance Mindset (épingle de la barre des tâches) : Mindset.exe, ou PowerShell s'il manque
function Get-LaunchCommand {
    if (Test-Path -LiteralPath $AppExe) { "`"$AppExe`"" }
    else { "`"$(Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe')`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$MainScript`"" }
}

$Window.Add_SourceInitialized({
    # Barre de titre sombre, couleur du fond dans le thème (écrite en « 0xBBGGRR »)
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
    $fond = (ConvertTo-ThemeHex '#06050F').Substring(1)
    try { [MSNative]::SetDarkTitleBar($h, [Convert]::ToInt32($fond.Substring(4, 2) + $fond.Substring(2, 2) + $fond.Substring(0, 2), 16)) } catch {}
    # Dans la barre des tâches : l'icône de Mindset, et épinglé, il se relance par Mindset.exe avec son icône
    try { [MSNative]::SetWindowIdentity($h, $AppId, (Get-LaunchCommand), $IconPath, 'Mindset') }
    catch { Write-Log "Identité de la fenêtre : $_" }
})

# « Êtes-vous sûr ? » : $Oui est lancé seulement si on confirme
function Show-Confirmation([string]$Titre, [string]$Texte, [string]$Bouton, [scriptblock]$Oui) {
    $ui.ConfirmationTitre.Text = $Titre
    $ui.ConfirmationTexte.Text = $Texte
    $ui.BtnConfirmationOui.Content = $Bouton
    $script:ConfirmationAction = $Oui
    $ui.Confirmation.Visibility = 'Visible'
    [void]$ui.BtnConfirmationNon.Focus()   # Entrée par erreur = Annuler
}
function Close-Confirmation { $ui.Confirmation.Visibility = 'Collapsed'; $script:ConfirmationAction = $null }
$ui.BtnConfirmationNon.Add_Click({ Close-Confirmation })
$ui.BtnConfirmationOui.Add_Click({ $a = $script:ConfirmationAction; Close-Confirmation; if ($a) { & $a } })

# Quitter vraiment (thème, mise à jour, installation, menu « Quitter ») : sans la question de la croix (zone.ps1).
# -AvecApplis : quitter pour de bon, demandé par l'utilisateur : les applis se ferment aussi (Request-FermetureApplis).
# (Pas « -Applis » : pendant la fermeture, ce paramètre cachait la liste $Applis aux fonctions appelées, et aucune appli
# ne recevait sa demande de fermeture.)
# Sans : Mindset se relance ou se met à jour, les applis continuent.
function Exit-Mindset([switch]$AvecApplis) {
    $script:QuitterVraiment = $true
    if ($AvecApplis) { $script:FermerApplis = $true }
    $Window.Close()
}

# Relance de Mindset (nouveau thème) : la fenêtre se ferme, Mindset.ps1 relance après avoir libéré sa place
function Restart-Mindset {
    $script:Relancer = $true
    try { [IO.File]::WriteAllText((Join-Path $DataDir 'relance.marque'), [string]$PID) } catch {}   # (le nouveau Mindset ne rouvre pas les applis)
    Exit-Mindset
}

# Un nouveau lancement de Mindset ramène la fenêtre, même cachée près de l'horloge (voir Mindset.ps1)
if ($script:ShowSignal) {
    $script:ShowTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ShowTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:ShowTimer.Add_Tick({ try { if ($script:ShowSignal.WaitOne(0)) { Show-Fenetre; Open-PageDemandee } } catch { Write-ErreurImprevue $_.Exception } })
    $script:ShowTimer.Start()
}

# ---------------------------------------------------------------------------
# Filet contre les plantages : une erreur imprévue dans un clic ou une minuterie remontait jusqu'à la boucle de la
# fenêtre (Dispatcher.Run) et fermait Mindset sans un mot. Elle est notée au journal (message, script, ligne), Mindset
# continue, et un message simple s'affiche UNE fois (une bulle près de l'horloge : jamais une fenêtre qui passerait
# devant un jeu). Une erreur qui se répète (une minuterie) n'est notée que 3 fois. Les erreurs du démarrage, avant que la
# fenêtre ne tourne, ne passent pas par ici : elles restent visibles. (Les travaux de fond, Start-Tache, ont déjà leur
# propre filet : leur erreur revient à la fenêtre.)
# ---------------------------------------------------------------------------
$script:ErreursImprevues = @{}
$script:ErreurMontree = $false
function Write-ErreurImprevue($Exception) {
    $ou = ''; $pile = ''
    for ($y = $Exception; $y; $y = $y.InnerException) {
        if ($y -is [System.Management.Automation.IContainsErrorRecord] -and $y.ErrorRecord -and $y.ErrorRecord.InvocationInfo -and $y.ErrorRecord.InvocationInfo.ScriptName) {
            $ii = $y.ErrorRecord.InvocationInfo
            $ou = "$(Split-Path $ii.ScriptName -Leaf) ligne $($ii.ScriptLineNumber)"; $pile = [string]$y.ErrorRecord.ScriptStackTrace
            break
        }
    }
    $x = $Exception; while ($x.InnerException) { $x = $x.InnerException }
    $cle = "$($x.GetType().Name)|$($x.Message)|$ou"
    $n = 1 + [int]$script:ErreursImprevues[$cle]; $script:ErreursImprevues[$cle] = $n
    if ($n -le 3) {
        Write-Log "Erreur imprévue, Mindset continue : $($x.GetType().FullName) : $($x.Message)$(if ($ou) { " ($ou)" })$(if ($n -eq 3) { ' [elle se répète : plus notée]' })"
        if ($pile -and $n -eq 1) { Write-Log "  $($pile -replace "`r?`n", "`r`n  ")" }
    }
    # Une minuterie dont le travail a planté ne repart plus toute seule (WPF ne la réarme pas) : celles qui doivent tourner
    # sont relancées, une fois l'erreur passée (sinon l'accueil, les mises à jour ou la surveillance des applis s'arrêteraient)
    [void]$Window.Dispatcher.BeginInvoke([action]{ Restart-Minuteries })
    if (-not $script:ErreurMontree) {
        $script:ErreurMontree = $true
        [void]$Window.Dispatcher.BeginInvoke([action]{ Show-MessageErreurImprevue })
    }
}
function Restart-Minuteries {
    foreach ($v in @(Get-Variable -Scope Script -ErrorAction SilentlyContinue | Where-Object { $_.Value -is [System.Windows.Threading.DispatcherTimer] })) {
        try { if ($v.Value.IsEnabled) { $v.Value.Stop(); $v.Value.Start() } } catch {}
    }
}
function Show-MessageErreurImprevue {
    $titre = 'Un petit problème est survenu'
    $texte = 'Mindset continue. Si ça se répète, quitte Mindset (clic droit sur son icône près de l''horloge) puis rouvre-le.'
    Write-Log "Message montré : $titre. $texte"
    if ($EnTest) { return }
    try { if ($Window.IsVisible -and $script:Console.Pret) { Invoke-ScriptConsole "window.mindset.message($(ConvertTo-Json -InputObject $titre -Compress))" } } catch {}
    try { if ($script:IconeHorloge) { Show-BulleMindset 8000 $titre $texte ([System.Windows.Forms.ToolTipIcon]::Warning) } } catch {}
}
$Window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    try { Write-ErreurImprevue $e.Exception } catch {}
    $e.Handled = $true
})
# (test : une minuterie qui plante 5 fois de suite, pour vérifier que Mindset continue et ne prévient qu'une fois)
if ($EnTest -and $env:MINDSET_TEST_PLANTAGE) {
    $script:PlantageTest = 0
    $script:PlantageTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PlantageTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:PlantageTimer.Add_Tick({
        $script:PlantageTest++
        if ($script:PlantageTest -ge 5) { $this.Stop() }
        throw 'Plantage de test'
    })
    $script:PlantageTimer.Start()
}

$Window.Add_Closed({
    if ($script:IconeHorloge) { try { $script:IconeHorloge.Visible = $false; $script:IconeHorloge.Dispose() } catch {} }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

function New-Button([string]$Text, [string]$Style = 'BtnSecondary') {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = $Text
    $btn.Style = $Window.FindResource($Style)
    $btn
}

function New-Text([string]$Text, [double]$Size = 14, [string]$Couleur = '#ECEAF7', [string]$Poids = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Get-Brush $Couleur; $t.FontWeight = $Poids
    $t.TextWrapping = 'Wrap'
    $t
}

# ---------------------------------------------------------------------------
# Capture d'écran de la fenêtre (tests automatiques) : dessinée hors de l'écran, enregistrée, puis fermée
# ---------------------------------------------------------------------------
function Start-Capture([string]$Path) {
    $Window.WindowStartupLocation = 'Manual'
    $Window.Left = -10000; $Window.Top = 0; $Window.ShowActivated = $false
    if ($env:MINDSET_CONSOLE_CAPTURE) { return }   # (capture de la console 3D, hors écran aussi : c'est elle qui enregistre et ferme Mindset)
    $Window.Add_ContentRendered({
        $script:CaptureTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:CaptureTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:CaptureDebut = Get-Date
        $script:CaptureTimer.Add_Tick({
            # (on attend la fin des travaux de fond, téléchargements compris, 30 secondes au plus)
            if ($script:Taches.Count -and ((Get-Date) - $script:CaptureDebut).TotalSeconds -lt 30) { return }
            if ($env:MINDSET_CAPTURE_DELAI -and ((Get-Date) - $script:CaptureDebut).TotalSeconds -lt [double]$env:MINDSET_CAPTURE_DELAI) { return }   # (une page qui se met à jour : Consommation)
            $script:CaptureTimer.Stop()
            try {
                $root = $Window.Content
                $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$root.ActualWidth, [int]$root.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                $bmp.Render($root)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
                $fs = [IO.File]::Create($env:MINDSET_CAPTURE)
                try { $enc.Save($fs) } finally { $fs.Dispose() }
            } catch { [Console]::Error.WriteLine("Capture : $_") }
            Exit-Mindset
        })
        $script:CaptureTimer.Start()
    })
}
