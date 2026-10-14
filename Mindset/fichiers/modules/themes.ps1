# Mindset : thèmes de couleurs, les mêmes que Nevermind et Evermind (repris du themes.ps1 d'Evermind).
# Toute l'app est dessinée avec la palette Néon ; un thème « traduit » chaque couleur au chargement :
# les couleurs de la marque (cyan, violet, magenta) prennent celles du thème, les gris et les fonds prennent sa teinte.
# Les couleurs d'état (vert = bien, orange, rouge, bleu) ne changent jamais.
#
# Le thème de Mindset est celui de la suite (suite.ps1) : le changer change aussi celui des applis installées par Mindset.
# Chargé par Mindset.ps1 après suite.ps1, avant la lecture de la fenêtre (interface.ps1).

$AppThemes = [ordered]@{
    neon = @{ Name = 'Néon'; Desc = 'Cyan, violet et magenta sur fond de nuit.'
        P = '#00E5FF'; S = '#B04BFF'; T = '#FF2EB5'; Map = @{}; NH = $null; NS = 1.0; Font = $null }
    crepuscule = @{ Name = 'Crépuscule'; Desc = 'Orange, rose et or, comme un coucher de soleil.'
        P = '#FF8A3D'; S = '#FF3D7F'; T = '#FFC83D'; NH = 345; NS = 0.75
        Map = @{ '0C0920' = '1A0B12'; '06050F' = '0B0508'; '0B0820' = '170910'; '08060F' = '160806' }; Font = $null }
    terminal = @{ Name = 'Terminal'; Desc = 'Vert phosphore sur fond noir, tout en police de code.'
        P = '#33FF77'; S = '#B6FF3B'; T = '#00E0A0'; NH = 140; NS = 0.55
        Map = @{ '0C0920' = '030B06'; '06050F' = '000302'; '0B0820' = '020A05'; '08060F' = '001A08' }; Font = 'Cascadia Code, Consolas' }
    arcade = @{ Name = 'Arcade'; Desc = 'Jaune, rouge et bleu vifs sur fond bleu nuit, comme une vieille borne.'
        P = '#FBD000'; S = '#E52521'; T = '#1E88E5'; NH = 228; NS = 0.9
        Map = @{ '0C0920' = '0B1640'; '06050F' = '050A20'; '0B0820' = '0A1338'; '08060F' = '1A1000' }; Font = $null }
    rubis = @{ Name = 'Rubis'; Desc = 'Rouge vif, jaune et bleu sur un gris anthracite sobre.'
        P = '#FF3B3B'; S = '#FFDE00'; T = '#3B6FFF'; NH = 0; NS = 0.15
        Map = @{ '0C0920' = '17171D'; '06050F' = '0A0A0D'; '0B0820' = '141419'; '08060F' = '1A0606' }; Font = $null }
}

# Thème choisi : un thème de base, ou « pack:<id> », un thème personnalisé de la suite (packs.ps1)
$ThemeSetting = Get-SuiteTheme
if ($EnTest -and $env:MINDSET_THEME) { $ThemeSetting = $env:MINDSET_THEME }
$ThemePack = $null
$ThemeId = $ThemeSetting
if ($ThemeSetting -like 'pack:*') {
    $ThemePack = Get-ThemePack $ThemeSetting.Substring(5)
    $ThemeId = if ($ThemePack) { $ThemePack.Base } else { 'neon' }
    if (-not $ThemePack) { Write-Log "Thème personnalisé introuvable ($ThemeSetting) : Néon en attendant" }
}
if (-not $AppThemes.Contains($ThemeId)) { $ThemeId = 'neon' }
$Theme = $AppThemes[$ThemeId]

# Police du pack, utilisable partout comme un nom de police (« file:///dossier/#Nom, police de secours »)
$PackFont = $null
if ($ThemePack -and $ThemePack.Font) {
    try {
        $gt = New-Object System.Windows.Media.GlyphTypeface (New-Object Uri $ThemePack.Font)
        $PackFont = 'file:///' + ($ThemePack.Dir -replace '\\', '/') + '/#' + @($gt.FamilyNames.Values)[0]
    } catch { Write-Log "Police du pack illisible : $_" }
}

# Bonjour de l'en-tête de l'accueil (« {0} » = Bonjour ou Bonsoir)
function Get-ThemeHello { if ($ThemePack -and $ThemePack.Hello -and $ThemePack.Hello -match '\{0\}') { $ThemePack.Hello } else { '{0} !' } }

# Police du pack dans la fenêtre : les titres, ou toute l'app (FontScope « tout »), en tailles pixel si c'est une police pixel
function Add-PackFontXaml([string]$Text) {
    $spec = [Security.SecurityElement]::Escape("$PackFont, Segoe UI Variable Display, Segoe UI")
    $Text = $Text.Replace('Segoe UI Variable Display, Segoe UI', $spec)
    if ($ThemePack.FontScope -eq 'tout') {
        $Text = $Text.Replace('Segoe UI Variable Text, Segoe UI', $spec)
        if ($ThemePack.FontPixel) { $Text = [regex]::Replace($Text, '(<Window [^>]*?)FontFamily=', '$1TextOptions.TextRenderingMode="Aliased" FontFamily=', 1) }
    }
    $Text
}

# Attention : PowerShell ne distingue pas $R de $r, d'où des noms différents pour les valeurs 0 à 1
function ConvertTo-Hsl([int]$Red, [int]$Green, [int]$Blue) {
    $r = $Red / 255.0; $g = $Green / 255.0; $b = $Blue / 255.0
    $max = [math]::Max($r, [math]::Max($g, $b)); $min = [math]::Min($r, [math]::Min($g, $b))
    $l = ($max + $min) / 2
    if ($max -eq $min) { return @(0.0, 0.0, $l) }
    $d = $max - $min
    $s = if ($l -gt 0.5) { $d / (2 - $max - $min) } else { $d / ($max + $min) }
    $h = if ($max -eq $r) { (($g - $b) / $d) + $(if ($g -lt $b) { 6 } else { 0 }) } elseif ($max -eq $g) { (($b - $r) / $d) + 2 } else { (($r - $g) / $d) + 4 }
    @(($h * 60.0), $s, $l)
}

function ConvertFrom-Hsl([double]$H, [double]$S, [double]$L) {
    $H = (($H % 360) + 360) % 360
    $c = (1 - [math]::Abs(2 * $L - 1)) * $S
    $x = $c * (1 - [math]::Abs((($H / 60.0) % 2) - 1))
    $m = $L - $c / 2
    $rgb = switch ([int][math]::Floor($H / 60.0)) { 0 { @($c, $x, 0.0) } 1 { @($x, $c, 0.0) } 2 { @(0.0, $c, $x) } 3 { @(0.0, $x, $c) } 4 { @($x, 0.0, $c) } default { @($c, 0.0, $x) } }
    '{0:X2}{1:X2}{2:X2}' -f [int][math]::Round(255 * ($rgb[0] + $m)), [int][math]::Round(255 * ($rgb[1] + $m)), [int][math]::Round(255 * ($rgb[2] + $m))
}

# Couleur Néon (« #RRGGBB » ou « #AARRGGBB ») traduite dans un thème
$script:ThemeCache = @{}
function ConvertTo-ThemeHex([string]$Hex, [string]$Id = $ThemeId) {
    if ($Id -eq 'neon' -or -not $Hex -or $Hex[0] -ne '#' -or ($Hex.Length -ne 7 -and $Hex.Length -ne 9)) { return $Hex }
    $key = "$Id|$Hex"
    $hit = $script:ThemeCache[$key]
    if ($hit) { return $hit }
    $th = $AppThemes[$Id]
    $alpha = if ($Hex.Length -eq 9) { $Hex.Substring(1, 2) } else { '' }
    $rgb = $Hex.Substring($Hex.Length - 6).ToUpper()
    $out = $rgb
    if ($th.Map.ContainsKey($rgb)) { $out = $th.Map[$rgb] }
    elseif ($rgb -eq '00E5FF') { $out = $th.P.Substring(1) } elseif ($rgb -eq 'B04BFF') { $out = $th.S.Substring(1) } elseif ($rgb -eq 'FF2EB5') { $out = $th.T.Substring(1) }
    else {
        $r = [Convert]::ToInt32($rgb.Substring(0, 2), 16); $g = [Convert]::ToInt32($rgb.Substring(2, 2), 16); $b = [Convert]::ToInt32($rgb.Substring(4, 2), 16)
        $hsl = ConvertTo-Hsl $r $g $b
        $h = $hsl[0]; $s = $hsl[1]; $l = $hsl[2]
        $brand = $null
        if ($s -gt 0.5 -and $l -gt 0.2 -and $l -lt 0.92) {
            if ($h -ge 170 -and $h -lt 200) { $brand = $th.P } elseif ($h -ge 228 -and $h -lt 292) { $brand = $th.S } elseif ($h -ge 292 -and $h -lt 336) { $brand = $th.T }
        }
        if ($brand) {
            # Même clarté que la couleur d'origine (une variante claire reste claire), teinte et saturation du thème
            $bh = ConvertTo-Hsl ([Convert]::ToInt32($brand.Substring(1, 2), 16)) ([Convert]::ToInt32($brand.Substring(3, 2), 16)) ([Convert]::ToInt32($brand.Substring(5, 2), 16))
            $dl = $l - 0.5
            $out = if ([math]::Abs($dl) -lt 0.06) { $brand.Substring(1).ToUpper() } else { ConvertFrom-Hsl $bh[0] $bh[1] ([math]::Min(0.95, [math]::Max(0.05, $bh[2] + $dl))) }
        } elseif (($s -lt 0.35 -or $l -lt 0.16) -and $l -gt 0.015 -and $l -lt 0.97 -and $null -ne $th.NH) {
            # Gris et fonds : la teinte du thème, même clarté
            $out = ConvertFrom-Hsl $th.NH ([math]::Min(1.0, $s * $th.NS)) $l
        }
    }
    $res = "#$alpha$out"
    $script:ThemeCache[$key] = $res
    $res
}

# Une couleur de l'app, dans le thème choisi
function Get-Couleur([string]$Hex) { [System.Windows.Media.ColorConverter]::ConvertFromString((ConvertTo-ThemeHex $Hex)) }

# Texte de la fenêtre (interface.xaml) traduit avant d'être chargé : couleurs, et police du thème
function Convert-ThemeXaml([string]$Text, [string]$Id = $ThemeId) {
    if ($PackFont -and $Id -eq $ThemeId) { $Text = Add-PackFontXaml $Text }
    if ($Id -eq 'neon') { return $Text }
    $th = $AppThemes[$Id]
    $Text = [regex]::Replace($Text, '(?<![&\w])#([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6})(?![0-9A-Fa-f])', { param($m) ConvertTo-ThemeHex $m.Value $Id })
    if ($th.Font) { $Text = $Text.Replace('Segoe UI Variable Display, Segoe UI', $th.Font).Replace('Segoe UI Variable Text, Segoe UI', $th.Font) }
    $Text
}
