# La question de la croix rouge : la même image en WPF (la VRAIE grille « Fermeture » d'interface.xaml, ses styles
# compris, rendue sans fenêtre par RenderTargetBitmap) et en HTML (ui\fermeture.js et .css dans la coquille, rendus
# par Edge sans fenêtre, avec un profil d'essai à part), puis la comparaison des deux.
#
# À lancer SUR UN BUREAU WINDOWS À PART (rien ne doit pouvoir s'afficher sur l'écran) :
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script <ce fichier> -Arguments "-Sortie '<dossier>'" -Secondes 180
param([Parameter(Mandatory = $true)][string]$Sortie, [int]$Largeur = 1000, [int]$Hauteur = 640)
$ErrorActionPreference = 'Stop'
$crate = Split-Path $PSScriptRoot -Parent
$depot = Split-Path (Split-Path $crate -Parent) -Parent
New-Item -ItemType Directory -Force -Path $Sortie | Out-Null
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

# ---------------------------------------------------------------------------------------------------------------
# 1. WPF : la grille « Fermeture » et les ressources de la fenêtre, dans une grille de la taille voulue
# ---------------------------------------------------------------------------------------------------------------
[xml]$x = [IO.File]::ReadAllText((Join-Path $depot 'Mindset\fichiers\modules\interface.xaml'), [Text.Encoding]::UTF8)
$ns = New-Object Xml.XmlNamespaceManager $x.NameTable
$ns.AddNamespace('p', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$ressources = $x.SelectSingleNode('/p:Window/p:Window.Resources', $ns)
$fermeture = $x.SelectSingleNode("//p:Grid[@x:Name='Fermeture']", $ns)
$fermeture.SetAttribute('Visibility', 'Visible')
$fenetre = $x.DocumentElement
$texte = @"
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Width="$Largeur" Height="$Hauteur" Background="$($fenetre.Background)" UseLayoutRounding="True"
      TextElement.FontFamily="$($fenetre.FontFamily)" TextElement.FontSize="$($fenetre.FontSize)" TextElement.Foreground="$($fenetre.Foreground)"
      TextOptions.TextFormattingMode="Display">
  <Grid.Resources>$($ressources.InnerXml)</Grid.Resources>
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  $($fermeture.OuterXml)
</Grid>
"@
$racine = [Windows.Markup.XamlReader]::Parse($texte)
$racine.Measure((New-Object Windows.Size $Largeur, $Hauteur))
$racine.Arrange((New-Object Windows.Rect 0, 0, $Largeur, $Hauteur))
$racine.UpdateLayout()
$bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap $Largeur, $Hauteur, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
$bmp.Render($racine)
$enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
$wpf = Join-Path $Sortie 'question-wpf.png'
$fs = [IO.File]::Create($wpf); try { $enc.Save($fs) } finally { $fs.Dispose() }
# (les rectangles des éléments, pour comparer la mise en page)
function Get-Boite($e) { $p = $e.TransformToAncestor($racine).Transform((New-Object Windows.Point 0, 0)); '{0},{1} {2}x{3}' -f [math]::Round($p.X), [math]::Round($p.Y), [math]::Round($e.ActualWidth), [math]::Round($e.ActualHeight) }
$grille = $racine.Children[0]
$panneau = $grille.Child
if (-not $panneau) { $panneau = $grille.Children[0] }
$pile = $panneau.Child
$boites = [ordered]@{ panneau = (Get-Boite $panneau) }
$k = 0
foreach ($e in $pile.Children) {
    $k++
    if ($e -is [Windows.Controls.StackPanel]) { $j = 0; foreach ($b in $e.Children) { $j++; $boites["bouton$j"] = Get-Boite $b } }
    else { $boites["ligne$k"] = Get-Boite $e }
}
$boites | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Sortie 'boites-wpf.json') -Encoding UTF8

# ---------------------------------------------------------------------------------------------------------------
# 2. HTML : la coquille, la question, une fausse coquille qui donne l'état « question montrée »
# ---------------------------------------------------------------------------------------------------------------
$ui = Join-Path $depot 'rust\mindset-appli\ui'
$css = [IO.File]::ReadAllText((Join-Path $ui 'coquille.css'), [Text.Encoding]::UTF8) + "`n" + [IO.File]::ReadAllText((Join-Path $crate 'ui\fermeture.css'), [Text.Encoding]::UTF8)
$js = [IO.File]::ReadAllText((Join-Path $crate 'ui\fermeture.js'), [Text.Encoding]::UTF8)
$page = @"
<!doctype html><html lang="fr"><head><meta charset="utf-8"><style>$css
#fenetre { display: block; }</style></head><body>
<div id="fenetre"><div id="voile-fermeture" class="voile" hidden></div></div>
<script>$js</script>
<script>
  horlogeFermeture.installer({ surEtat(f) { f({ fermeture: { visible: true, ouverture: 1 } }); }, action() {} });
  document.activeElement && document.activeElement.blur();
  const boite = (e) => { const r = e.getBoundingClientRect(); return Math.round(r.left) + ',' + Math.round(r.top) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height); };
  const z = document.getElementById('voile-fermeture');
  const b = { panneau: boite(z.querySelector('.hf-panneau')), ligne1: boite(z.querySelector('.hf-titre')), ligne2: boite(z.querySelector('.hf-texte')), ligne3: boite(z.querySelector('.hf-case')) };
  z.querySelectorAll('.hf-bouton').forEach((x, i) => b['bouton' + (i + 1)] = boite(x));
  document.title = JSON.stringify(b);
</script></body></html>
"@
$html = Join-Path $Sortie 'question.html'
[IO.File]::WriteAllText($html, $page, (New-Object Text.UTF8Encoding $false))
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
$profil = Join-Path $env:TEMP "mindset-horloge-edge-$PID"
$web = Join-Path $Sortie 'question-html.png'
$adresse = ([Uri]$html).AbsoluteUri
$args1 = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions', "--user-data-dir=`"$profil`"", '--force-device-scale-factor=1', '--hide-scrollbars', "--window-size=$Largeur,$Hauteur", "--screenshot=`"$web`"", $adresse)
Start-Process -FilePath $edge -ArgumentList $args1 -WindowStyle Hidden -Wait -RedirectStandardOutput (Join-Path $Sortie 'edge.out.txt') -RedirectStandardError (Join-Path $Sortie 'edge.err.txt')
$args2 = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions', "--user-data-dir=`"$profil`"", '--force-device-scale-factor=1', "--window-size=$Largeur,$Hauteur", '--dump-dom', $adresse)
Start-Process -FilePath $edge -ArgumentList $args2 -WindowStyle Hidden -Wait -RedirectStandardOutput (Join-Path $Sortie 'dom.txt') -RedirectStandardError (Join-Path $Sortie 'edge2.err.txt')
Remove-Item -LiteralPath $profil -Recurse -Force -ErrorAction SilentlyContinue
$dom = [IO.File]::ReadAllText((Join-Path $Sortie 'dom.txt'))
if ($dom -match '<title>(.*?)</title>') { [Net.WebUtility]::HtmlDecode($Matches[1]) | Set-Content -LiteralPath (Join-Path $Sortie 'boites-html.json') -Encoding UTF8 }

# ---------------------------------------------------------------------------------------------------------------
# 3. La comparaison : les rectangles, et les pixels (part de pixels presque pareils, écart moyen)
# ---------------------------------------------------------------------------------------------------------------
"WPF  : $((Get-Content -Raw (Join-Path $Sortie 'boites-wpf.json')) -replace '\s+', ' ')"
"HTML : $(if (Test-Path (Join-Path $Sortie 'boites-html.json')) { Get-Content -Raw (Join-Path $Sortie 'boites-html.json') } else { '(pas de mesure)' })"
if (Test-Path -LiteralPath $web) {
    $a = New-Object Drawing.Bitmap $wpf
    $b = New-Object Drawing.Bitmap $web
    $n = 0; $pareils = 0; $somme = 0.0
    for ($y = 0; $y -lt [math]::Min($a.Height, $b.Height); $y += 2) {
        for ($xx = 0; $xx -lt [math]::Min($a.Width, $b.Width); $xx += 2) {
            $p = $a.GetPixel($xx, $y); $q = $b.GetPixel($xx, $y)
            $d = ([math]::Abs($p.R - $q.R) + [math]::Abs($p.G - $q.G) + [math]::Abs($p.B - $q.B)) / 3
            $n++; $somme += $d; if ($d -le 12) { $pareils++ }
        }
    }
    "Pixels presque pareils : $([math]::Round(100 * $pareils / $n, 2)) % ; écart moyen : $([math]::Round($somme / $n, 2)) sur 255 ($($a.Width)x$($a.Height) contre $($b.Width)x$($b.Height))"
    $a.Dispose(); $b.Dispose()
} else { 'Pas d''image HTML' }
