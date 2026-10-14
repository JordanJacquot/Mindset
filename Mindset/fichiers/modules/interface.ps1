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
    else { "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$MainScript`"" }
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

# Quitter vraiment (thème, mise à jour, installation, menu « Quitter ») : sans la question de la croix (zone.ps1)
function Exit-Mindset {
    $script:QuitterVraiment = $true
    $Window.Close()
}

# Relance de Mindset (nouveau thème) : la fenêtre se ferme, Mindset.ps1 relance après avoir libéré sa place
function Restart-Mindset {
    $script:Relancer = $true
    Exit-Mindset
}

# Un nouveau lancement de Mindset ramène la fenêtre, même cachée près de l'horloge (voir Mindset.ps1)
if ($script:ShowSignal) {
    $script:ShowTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ShowTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:ShowTimer.Add_Tick({ if ($script:ShowSignal.WaitOne(0)) { Show-Fenetre; Open-PageDemandee } })
    $script:ShowTimer.Start()
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
    $Window.Add_ContentRendered({
        $script:CaptureTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:CaptureTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:CaptureDebut = Get-Date
        $script:CaptureTimer.Add_Tick({
            # (on attend la fin des travaux de fond, téléchargements compris, 30 secondes au plus)
            if ($script:Taches.Count -and ((Get-Date) - $script:CaptureDebut).TotalSeconds -lt 30) { return }
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
