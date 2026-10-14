# Mindset : chargement de la fenêtre et aides pour l'interface.
# Chargé par Mindset.ps1, qui définit $AppDir et $ModulesDir.

# ---------------------------------------------------------------------------
# Fenêtre (décrite dans interface.xaml)
# ---------------------------------------------------------------------------
[xml]$Xaml = [IO.File]::ReadAllText((Join-Path $ModulesDir 'interface.xaml'), [Text.Encoding]::UTF8)
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

function Get-Brush([string]$Hex) { [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

$Window.Add_SourceInitialized({
    # Barre de titre sombre, couleur du fond (#06050F écrit en « 0xBBGGRR »)
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
    try { [MSNative]::SetDarkTitleBar($h, 0x0F0506) } catch {}
})

# Un nouveau lancement de Mindset ramène la fenêtre (voir Mindset.ps1)
if ($script:ShowSignal) {
    $script:ShowTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ShowTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:ShowTimer.Add_Tick({
        if ($script:ShowSignal.WaitOne(0)) {
            if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
            $Window.Show(); [void]$Window.Activate()
        }
    })
    $script:ShowTimer.Start()
}

$Window.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

# Logo : l'anneau cyan vers violet tourne doucement, comme chez Nevermind et Evermind
if ([System.Windows.SystemParameters]::ClientAreaAnimation) {   # animations coupées dans Windows : logo immobile
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 360, [TimeSpan]::FromSeconds(8))
    $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.LogoRotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
}

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
        $script:CaptureTimer.Add_Tick({
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
            $Window.Close()
        })
        $script:CaptureTimer.Start()
    })
}
