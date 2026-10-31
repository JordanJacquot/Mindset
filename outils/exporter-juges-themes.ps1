# Mindset : juges des thèmes pour la bibliothèque Rust « suite-commun » (module themes).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\exporter-juges-themes.ps1 [-Mindcare <dépôt Mindcare>]
#
# Prépare des suite.json et des packs de thème (inventés : « essai-bleu »...) dans un dossier temporaire, les passe aux
# VRAIES fonctions PowerShell, et écrit leurs réponses dans rust\suite-commun\juges\themes.json, que les tests Rust
# rejouent (themes\tests.rs, juges_powershell) :
#   - Read-Suite, Test-SuitePrise, Get-CheminNormal (Mindcare, modules\mindset.ps1) : le thème lu dans suite.json ;
#   - Get-ThemePack, Test-CouleursPack, Test-NomFichierPack (Mindset, modules\packs.ps1) : le pack et ses couleurs
#     vérifiées (constat 7 de l'audit du 25/10), cherché comme le fait Mindcare : son dossier, puis celui de Mindset ;
#   - Get-ThemePack de Mindcare (modules\themes.ps1) : l'image de chargement (Loader) et la vignette de la mascotte,
#     que Mindset ne lit pas ;
#   - $AppThemes, ConvertTo-Hsl, ConvertFrom-Hsl, ConvertTo-ThemeHex (Mindcare, modules\themes.ps1) : les couleurs.
# Les fonctions sont prises telles quelles dans les fichiers (lecture de leur texte, rien d'autre n'est exécuté).
# Le choix du thème (le haut de themes.ps1 de Mindcare, hors fonction) est recopié ici, ligne pour ligne.
#
# Les cas où la bibliothèque est volontairement plus stricte (lisibilité, liens, extensions, NH mal écrit...) ne sont
# pas ici : ils sont dans les tests Rust, avec leur raison.
#
# Tout se passe dans un dossier temporaire sous %TEMP%, supprimé à la fin. Rien n'est lu ni écrit ailleurs.

param([string]$Mindcare = '')

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
if (-not $Mindcare) { $Mindcare = Join-Path (Split-Path $racine -Parent) 'Mindcare' }
$modulesMindcare = Join-Path $Mindcare 'Mindcare\fichiers\modules'
$modulesMindset = Join-Path $racine 'Mindset\fichiers\modules'
foreach ($f in (Join-Path $modulesMindcare 'mindset.ps1'), (Join-Path $modulesMindcare 'themes.ps1'), (Join-Path $modulesMindset 'packs.ps1')) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Introuvable : $f (donner le dépôt Mindcare avec -Mindcare)" }
}
$sortie = Join-Path $racine 'rust\suite-commun\juges\themes.json'

# ---------------------------------------------------------------------------------------------------------------
# Les vraies fonctions, prises dans leur fichier
# ---------------------------------------------------------------------------------------------------------------
function Get-Ast([string]$Fichier) {
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Fichier, [ref]$null, [ref]$err)
    if ($err) { throw "Fichier illisible pour PowerShell : $Fichier" }
    $ast
}
function Get-TexteFonction($Ast, [string]$Nom, [string]$NouveauNom = '') {
    $f = $Ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Nom }, $true)
    if (-not $f) { throw "Fonction $Nom introuvable" }
    $t = $f.Extent.Text
    if ($NouveauNom) { $t = $t -replace "^function $Nom\b", "function $NouveauNom" }
    $t
}
$astMindsetPs1 = Get-Ast (Join-Path $modulesMindcare 'mindset.ps1')
$astThemes = Get-Ast (Join-Path $modulesMindcare 'themes.ps1')
$astPacks = Get-Ast (Join-Path $modulesMindset 'packs.ps1')

$textes = @(
    (Get-TexteFonction $astMindsetPs1 'Get-CheminNormal'), (Get-TexteFonction $astMindsetPs1 'Test-SuitePrise'), (Get-TexteFonction $astMindsetPs1 'Read-Suite'),
    (Get-TexteFonction $astThemes 'ConvertTo-Hsl'), (Get-TexteFonction $astThemes 'ConvertFrom-Hsl'), (Get-TexteFonction $astThemes 'ConvertTo-ThemeHex'),
    (Get-TexteFonction $astThemes 'Get-ThemePack' 'Get-ThemePackMindcare'),
    (Get-TexteFonction $astPacks 'Test-NomFichierPack'), (Get-TexteFonction $astPacks 'Test-CouleursPack'), (Get-TexteFonction $astPacks 'Get-ThemePack')
)
foreach ($t in $textes) { . ([scriptblock]::Create($t)) }

# Les thèmes intégrés : l'affectation « $AppThemes = ... » de themes.ps1 (Mindcare), rejouée à neuf pour chaque cas
$affectation = $astThemes.Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$AppThemes' }, $false)
if (-not $affectation) { throw '$AppThemes introuvable dans themes.ps1' }
$nouveauxThemes = [scriptblock]::Create($affectation.Right.Extent.Text)
$ThemesSuite = @('neon', 'crepuscule', 'terminal', 'arcade', 'rubis')
$AppId = 'mindcare'
$script:Journal = @()
function Write-Log($Message) { $script:Journal += [string]$Message }

# ---------------------------------------------------------------------------------------------------------------
# Les cas : des fichiers (chemin relatif au dossier du cas => contenu texte)
# ---------------------------------------------------------------------------------------------------------------
$images = @{}
foreach ($n in 'logo.png', 'fond.png', 'mascotte.png', 'bas.png', 'charge.png', 'police.ttf', 'tuile-pc.png', 'tuile-perf.webp',
    'console-fond.webp', 'console-logo.gif', 'console-mascotte.png', 'roue.gif', 'note.txt') { $images[$n] = 'image' }

function Get-FichiersPack([string]$Dossier, [string]$Json, [switch]$SansImages) {
    $f = [ordered]@{ "$Dossier/pack.json" = $Json }
    if (-not $SansImages) { foreach ($n in $images.Keys | Sort-Object) { $f["$Dossier/$n"] = $images[$n] } }
    $f
}
$mc = 'donnees/Mindcare/packs'
$ms = 'donnees/Mindset/packs'
$suiteMindset = { param($t) '{"theme":' + $t + ',"micro":"","casque":"","applis":{"mindcare":"D:\\Mindset\\Programmes\\Mindcare"},"modifie":"2026-10-31T10:00:00"}' }

$bleu = @'
{"Name":"Essai bleu","Desc":"Un thème d'essai","Base":"arcade","Hello":"{0}, voyageur !",
 "Colors":{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","NH":210,"NS":0.8,"Map":{"#0C0920":"0a1a2b","06050f":"#050B14"}},
 "Logo":"logo.png","LogoFrames":4,"LogoDelay":10,"LogoGlow":"#FF00FF",
 "Mascotte":{"File":"mascotte.png","Frames":2.5,"Delay":"100","Flip":true,"Vignette":1},
 "Loader":{"File":"charge.png","Frames":8,"Delay":20},
 "Footer":{"File":"bas.png","Frames":3,"Delay":50,"Height":100},
 "Background":"fond.png","BackgroundOpacity":"0.5","BackgroundAlign":"Bas-Droite",
 "Font":"police.ttf","FontScope":"tout","FontPixel":false,
 "Console":{"Tuiles":{"pc":"tuile-pc.png","perf":"tuile-perf.webp","jeux":"note.txt","Mal-Nom":"tuile-pc.png","Jeu":"absente.png"},
   "Mascotte":"console-mascotte.png","Chargement":{"File":"roue.gif","Effet":"tourne"},"Fond":"console-fond.webp","FondOpacite":2,"Logo":"console-logo.gif"}}
'@
$vert = '{"Name":"Essai vert","Base":"crepuscule","Colors":{},"Logo":"logo.png","Background":"fond.png","BackgroundAlign":"haut gauche","BackgroundOpacity":0,"Footer":{"File":"bas.png","Height":3,"Delay":0},"Console":{"Chargement":"roue.gif","Mascotte":"note.txt"}}'
$chemins = '{"Name":"Essai chemins","Logo":"../secret.png","Background":"..\\secret.png","Font":"sous/police.ttf","Mascotte":{"File":"C:\\Windows\\win.ini"},"Footer":{"File":"absent.png"},"Loader":{"File":"sous\\charge.png"},"Console":{"Fond":"..\\secret.png","Logo":"logo.png:x","Tuiles":{"pc":"../tuile-pc.png"}}}'
$cas = [ordered]@{
    'suite.json absent' = [ordered]@{}
    'suite.json vide' = [ordered]@{ 'suite.json' = '' }
    'suite.json abîmé' = [ordered]@{ 'suite.json' = '{"theme": "arc' }
    'suite.json sans thème' = [ordered]@{ 'suite.json' = '{"applis":{}}' }
    'thème intégré' = [ordered]@{ 'suite.json' = (& $suiteMindset '"crepuscule"') }
    'thème intégré en majuscules' = [ordered]@{ 'suite.json' = (& $suiteMindset '"TERMINAL"') }
    'thème intégré, avec marque UTF-8' = [ordered]@{ 'suite.json' = ([char]0xFEFF + '{"theme":"rubis"}') }
    'thème arcade' = [ordered]@{ 'suite.json' = '{"theme":"arcade"}' }
    'thème néon' = [ordered]@{ 'suite.json' = '{"theme":"neon"}' }
    'thème inconnu' = [ordered]@{ 'suite.json' = '{"theme":"sombre"}' }
    'thème qui est un nombre' = [ordered]@{ 'suite.json' = '{"theme":42}' }
    'pack en majuscules' = [ordered]@{ 'suite.json' = '{"theme":"pack:Essai-Bleu"}' } + (Get-FichiersPack "$mc/Essai-Bleu" $bleu)
    'pack au nom trop long' = [ordered]@{ 'suite.json' = '{"theme":"pack:' + ('a' * 41) + '"}' }
    'pack qui sort du dossier' = [ordered]@{ 'suite.json' = '{"theme":"pack:../essai"}'; 'donnees/Mindcare/essai/pack.json' = '{"Base":"arcade"}' }
    'pack absent' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-absent"}' }
    'pack complet' = [ordered]@{ 'suite.json' = (& $suiteMindset '"pack:essai-bleu"') } + (Get-FichiersPack "$mc/essai-bleu" $bleu)
    'pack complet, avec marque UTF-8' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-bleu"}' } + (Get-FichiersPack "$mc/essai-bleu" ([char]0xFEFF + $bleu))
    'pack sans couleurs, base et images' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-vert"}' } + (Get-FichiersPack "$mc/essai-vert" $vert)
    'pack seulement chez Mindset' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-bleu"}' } + (Get-FichiersPack "$ms/essai-bleu" $bleu)
    'pack chez les deux : celui de l''appli' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-bleu"}' } + (Get-FichiersPack "$ms/essai-bleu" $bleu) + (Get-FichiersPack "$mc/essai-bleu" $vert -SansImages)
    'pack abîmé chez l''appli, bon chez Mindset' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-bleu"}'; "$mc/essai-bleu/pack.json" = '{ pas du json'; "$mc/essai-bleu/logo.png" = 'image' } + (Get-FichiersPack "$ms/essai-bleu" $bleu)
    'pack abîmé partout' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-bleu"}'; "$mc/essai-bleu/pack.json" = '{"Name": '; "$ms/essai-bleu/pack.json" = '{"Base": "arcade"' }
    'pack.json vide' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-vide"}'; "$mc/essai-vide/pack.json" = '{}' }
    'couleur mal écrite (red), base rubis' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-rouge"}' } + (Get-FichiersPack "$mc/essai-rouge" '{"Base":"rubis","Logo":"logo.png","Colors":{"P":"red","S":"#7C4DFF","T":"#FF4081"}}')
    'couleur courte (#0F0)' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-court"}' } + (Get-FichiersPack "$mc/essai-court" '{"Base":"terminal","Colors":{"P":"#0F0","S":"#7C4DFF","T":"#FF4081"}}')
    'couleur piégée (guillemets et balise)' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-piege"}' } + (Get-FichiersPack "$mc/essai-piege" '{"Name":"Essai piège","Logo":"logo.png","Colors":{"P":"#00E5FF\" Foo=\"<Bar/>","S":"#7C4DFF","T":"#FF4081"}}')
    'couleur P vide (null)' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-pnull"}' } + (Get-FichiersPack "$mc/essai-pnull" '{"Base":"arcade","Colors":{"P":null,"S":"#7C4DFF","T":"#FF4081"}}')
    'Map à la clé mal écrite' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-map"}' } + (Get-FichiersPack "$mc/essai-map" '{"Colors":{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":{"#0C092G":"000000"}}}')
    'Map à la valeur piégée' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-map"}' } + (Get-FichiersPack "$mc/essai-map" '{"Base":"crepuscule","Colors":{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":{"0C0920":"000000\"/>"}}}')
    'Map en tableau' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-map"}' } + (Get-FichiersPack "$mc/essai-map" '{"Colors":{"P":"#4FC3F7","S":"#7C4DFF","T":"#FF4081","Map":["0C0920"]}}')
    'Colors en texte' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-texte"}' } + (Get-FichiersPack "$mc/essai-texte" '{"Base":"rubis","Colors":"bleu"}')
    'Colors incomplètes (P seule)' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-partiel"}' } + (Get-FichiersPack "$mc/essai-partiel" '{"Base":"arcade","Colors":{"P":"#4FC3F7"}}')
    'NH en texte, NS à 0, sans Map' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-orange"}' } + (Get-FichiersPack "$mc/essai-orange" '{"Name":"Essai orange","Colors":{"P":"#FFA040","S":"#FF6F61","T":"#FFD54F","NH":"25","NS":0}}')
    'couleurs sans teinte (NH absente)' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-gris"}' } + (Get-FichiersPack "$mc/essai-gris" '{"Colors":{"P":"#80DEEA","S":"#B39DDB","T":"#F48FB1","Map":{"0B0820":"101018"}}}')
    'base en majuscules' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-base"}' } + (Get-FichiersPack "$mc/essai-base" '{"Base":"Crepuscule"}')
    'clés en double (majuscules) : abîmé pour PowerShell' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-double"}' } + (Get-FichiersPack "$mc/essai-double" '{"Base":"arcade","Console":{"Tuiles":{"pc":"tuile-pc.png","PC":"tuile-pc.png"}}}') + (Get-FichiersPack "$ms/essai-double" '{"Base":"rubis"}' -SansImages)
    'base inconnue' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-base"}' } + (Get-FichiersPack "$mc/essai-base" '{"Base":"sombre","Hello":"Salut {1}"}')
    'chemins d''images qui sortent du dossier' = [ordered]@{ 'suite.json' = '{"theme":"pack:essai-chemins"}'; "$mc/secret.png" = 'image'; "$mc/essai-chemins/sous/police.ttf" = 'police'; "$mc/essai-chemins/sous/charge.png" = 'image' } + (Get-FichiersPack "$mc/essai-chemins" $chemins)
}

# Les couleurs traduites dans chaque cas : celles du kit, puis d'autres de l'appli (alpha devant, comme en XAML)
$essayees = @('#00E5FF', '#B04BFF', '#FF2EB5', '#06050F', '#0C0920', '#ECEAF7', '#A9A3C9', '#6F6894', '#2A2450', '#3DDC84',
    '#FFB020', '#FF5C7A', '#0B0820', '#08060F', '#8000E5FF', '#66FFFFFF', '#C9C4DD', '#1E1A3A', '#7A5CFF', '#FF8A00', '#12101F',
    '#00B8D4', '#E0F7FF', '#00e5ff', '#D946EF', '#5B3FD9', '#000000', '#FFFFFF', '#33FFFFFF', '#FF000000', '#12345', 'rouge')

# ---------------------------------------------------------------------------------------------------------------
# Les réponses de PowerShell
# ---------------------------------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "juges-themes-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = [IO.Path]::GetFullPath($tmp)
$utf8 = New-Object Text.UTF8Encoding $false
$resultats = @()
try {
    $n = 0
    foreach ($nom in $cas.Keys) {
        $n++
        $dossierCas = Join-Path $tmp "cas$n"
        New-Item -ItemType Directory -Force -Path $dossierCas | Out-Null
        foreach ($chemin in $cas[$nom].Keys) {
            $f = Join-Path $dossierCas ($chemin -replace '/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null
            [IO.File]::WriteAllText($f, [string]$cas[$nom][$chemin], $utf8)
        }
        $relatif = { param($p) if ($p) { $p.Substring($dossierCas.Length + 1) -replace '\\', '/' } else { $null } }
        $feuille = { param($p) if ($p) { Split-Path $p -Leaf } else { $null } }

        # suite.json, lu comme Mindcare (un seul essai : aucun fichier n'est pris ici)
        $SuiteFile = Join-Path $dossierCas 'suite.json'
        $suite = Read-Suite 1
        # Le choix du thème, comme le haut de themes.ps1 de Mindcare (copie gérée par Mindset ; sans thème dans
        # suite.json, la bibliothèque prend Néon)
        $AppThemes = & $nouveauxThemes
        $script:ThemeCache = @{}
        $ThemeSetting = if ($suite.Theme) { $suite.Theme } else { 'neon' }
        $ThemePack = $null
        $ThemeId = $ThemeSetting
        $racines = @((Join-Path $dossierCas 'donnees\Mindcare\packs'), (Join-Path $dossierCas 'donnees\Mindset\packs'))
        if ($ThemeSetting -like 'pack:*') {
            # Comme Get-ThemePack de Mindcare : le réglage de l'appli, puis celui de Mindset (avec le contrôle des
            # couleurs de Mindset)
            foreach ($PacksDir in $racines) { $ThemePack = Get-ThemePack $ThemeSetting.Substring(5); if ($ThemePack) { break } }
            $ThemeId = if ($ThemePack) { $ThemePack.Base } else { 'neon' }
        }
        if (-not $ThemeId -or -not $AppThemes.Contains($ThemeId)) { $ThemeId = 'neon' }
        $theme = $AppThemes[$ThemeId]
        $traductions = @(foreach ($c in $essayees) { ConvertTo-ThemeHex $c $ThemeId })

        $pack = $null
        if ($ThemePack) {
            $p = $ThemePack
            # (Loader et vignette : lus par Get-ThemePack de Mindcare, dans un tableau de thèmes à part)
            $DataDir = Join-Path $dossierCas 'donnees\Mindcare'
            $pmc = & { $AppThemes = & $nouveauxThemes; Get-ThemePackMindcare $p.Id }
            $planche = { param($x) if ($x) { [ordered]@{ fichier = (& $feuille $x.File); images = $x.Frames; delai = $x.Delay } } else { $null } }
            $pack = [ordered]@{
                id = $p.Id; dossier = (& $relatif $p.Dir); nom = $p.Name; description = $p.Desc; bonjour = $p.Hello
                logo = $(if ($p.Logo) { [ordered]@{ fichier = (& $feuille $p.Logo); images = $p.LogoFrames; delai = $p.LogoDelay } } else { $null })
                logo_lueur = $p.LogoGlow
                mascotte = $(if ($p.Mascotte) { $m = & $planche $p.Mascotte; $m.miroir = $p.Mascotte.Flip; $m } else { $null })
                mascotte_vignette = $(if ($pmc.Mascotte) { $pmc.Mascotte.Vignette } else { $false })
                chargement = (& $planche $pmc.Loader)
                bas = $(if ($p.Footer) { $b = & $planche $p.Footer; $b.hauteur = $p.Footer.Height; $b } else { $null })
                fond = $(if ($p.Background) { [ordered]@{ fichier = (& $feuille $p.Background); opacite = $p.BackgroundOpacity; x = $p.BackgroundAlignX; y = $p.BackgroundAlignY } } else { $null })
                police = $(if ($p.Font) { [ordered]@{ fichier = (& $feuille $p.Font); partout = ($p.FontScope -eq 'tout') } } else { $null })
                pixel = $p.FontPixel
                console = $null
            }
            if ($pmc.Dir -ne $p.Dir) { throw "$nom : Mindcare et Mindset ne prennent pas le même dossier ($($pmc.Dir), $($p.Dir))" }
            if ($p.Console) {
                $c = $p.Console
                $tuiles = [ordered]@{}
                foreach ($k in $c.Tuiles.Keys | Sort-Object) { $tuiles[$k] = & $feuille $c.Tuiles[$k] }
                $pack.console = [ordered]@{
                    tuiles = $tuiles; mascotte = (& $feuille $c.Mascotte); fond = (& $feuille $c.Fond); fond_opacite = $c.FondOpacite; logo = (& $feuille $c.Logo)
                    chargement = $(if ($c.Chargement) { [ordered]@{ fichier = (& $feuille $c.Chargement.File); effet = $c.Chargement.Effet } } else { $null })
                }
            }
        }
        $resultats += [ordered]@{
            nom = $nom
            fichiers = $cas[$nom]
            attendu = [ordered]@{ choix = $suite.Theme; theme = $ThemeId; P = $theme.P; S = $theme.S; T = $theme.T; traductions = $traductions; pack = $pack }
        }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$json = [ordered]@{
    description = 'Juges des thèmes, écrits par outils\exporter-juges-themes.ps1 depuis les vraies fonctions PowerShell (Mindcare et Mindset). Ne pas modifier à la main.'
    couleurs_essayees = $essayees
    cas = $resultats
} | ConvertTo-Json -Depth 12
New-Item -ItemType Directory -Force -Path (Split-Path $sortie -Parent) | Out-Null
[IO.File]::WriteAllText($sortie, $json, $utf8)
Write-Output "$($resultats.Count) cas écrits dans $sortie"
