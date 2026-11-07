# Captures du bloc « écrans » : met côte à côte (et l'une sur l'autre, en différence) la capture « avant » (WPF) et la
# capture « après » (page Rust, sans le cadre de la fenêtre), pour chaque scène. Aucune fenêtre : seulement des images.
#
#   & '.\comparer-captures.ps1' [-Scene accueil-neon] [-Points '300,20;600,400']
#
# Écrit D:\Outils\Rust\essais\ecrans\captures\comparaison-<scène>.png (avant à gauche, après à droite, la différence
# en dessous) et, pour chaque point demandé, les deux couleurs.
param([string]$Scene = '', [string]$Points = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$captures = 'D:\Outils\Rust\essais\ecrans\captures'

# Le cadre de la fenêtre Tauri (barre de titre, bords) : le contenu est le grand rectangle sous la barre
function Get-Contenu($Img) {
    # (le bord gauche : la première colonne qui n'est plus celle du cadre, à mi-hauteur ; la barre de titre : 31 pixels à
    # 100 %, mesurée par la ligne où la couleur change sous le haut de la fenêtre)
    $mi = [int]($Img.Height / 2)
    $g = 0; $ref = $Img.GetPixel(0, $mi)
    while ($g -lt 40 -and $Img.GetPixel($g, $mi).ToArgb() -eq $ref.ToArgb()) { $g++ }
    $h = 1; $ref2 = $Img.GetPixel([int]($Img.Width / 2), 2)
    while ($h -lt 80 -and $Img.GetPixel([int]($Img.Width / 2), $h).ToArgb() -eq $ref2.ToArgb()) { $h++ }
    [System.Drawing.Rectangle]::new($g, $h, $Img.Width - 2 * $g, $Img.Height - $h - $g)
}

$scenes = if ($Scene) { @($Scene) } else { @(Get-ChildItem -LiteralPath $captures -Filter 'avant-*.png' | ForEach-Object { $_.BaseName.Substring(6) }) }
foreach ($s in $scenes) {
    $fa = Join-Path $captures "avant-$s.png"; $fb = Join-Path $captures "apres-$s.png"
    if (-not (Test-Path -LiteralPath $fa) -or -not (Test-Path -LiteralPath $fb)) { Write-Output "$s : une des deux captures manque"; continue }
    $a = [System.Drawing.Bitmap]::FromFile($fa); $b0 = [System.Drawing.Bitmap]::FromFile($fb)
    try {
        $r = Get-Contenu $b0
        $b = $b0.Clone($r, $b0.PixelFormat)
        $l = [math]::Max($a.Width, $b.Width); $ht = [math]::Max($a.Height, $b.Height)
        $sortie = New-Object System.Drawing.Bitmap ($l * 2 + 10), ($ht * 2 + 10)
        $gr = [System.Drawing.Graphics]::FromImage($sortie)
        $gr.Clear([System.Drawing.Color]::Black)
        $gr.DrawImage($a, 0, 0, $a.Width, $a.Height); $gr.DrawImage($b, $l + 10, 0, $b.Width, $b.Height)
        # La différence, au même endroit (coin haut gauche), sur la partie commune
        $lc = [math]::Min($a.Width, $b.Width); $hc = [math]::Min($a.Height, $b.Height)
        $diff = New-Object System.Drawing.Bitmap $lc, $hc
        $ecart = 0.0
        for ($y = 0; $y -lt $hc; $y += 1) {
            for ($x = 0; $x -lt $lc; $x += 1) {
                $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y)
                $d = [math]::Abs($p.R - $q.R) + [math]::Abs($p.G - $q.G) + [math]::Abs($p.B - $q.B)
                $ecart += $d
                $v = [math]::Min(255, $d * 2)
                $diff.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($v, $v, $v))
            }
        }
        $gr.DrawImage($diff, 0, $ht + 10, $lc, $hc)
        $gr.Dispose()
        $f = Join-Path $captures "comparaison-$s.png"
        $sortie.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Output ("{0} : avant {1} x {2}, après {3} x {4} (contenu à {5},{6}), écart moyen {7:N1} / 765 -> {8}" -f $s, $a.Width, $a.Height, $b.Width, $b.Height, $r.X, $r.Y, ($ecart / ($lc * $hc)), $f)
        foreach ($pt in ($Points -split ';' | Where-Object { $_ })) {
            $x, $y = $pt -split ',' | ForEach-Object { [int]$_ }
            $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y)
            Write-Output ("   ({0},{1}) avant #{2:X2}{3:X2}{4:X2}  après #{5:X2}{6:X2}{7:X2}" -f $x, $y, $p.R, $p.G, $p.B, $q.R, $q.G, $q.B)
        }
        $diff.Dispose(); $sortie.Dispose(); $b.Dispose()
    } finally { $a.Dispose(); $b0.Dispose() }
}
