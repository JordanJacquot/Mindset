# Mindset : vérifications sans lancer Mindset (les mêmes que outils\publier.ps1 avant une publication, et quelques autres).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\verifier.ps1
#
#   - syntaxe de tous les .ps1 du dépôt ;
#   - la fenêtre (Mindset\fichiers\modules\interface.xaml) se lit ;
#   - aucun tiret long (U+2013, U+2014) dans les textes : .ps1, .cs, .xaml, .txt, .md, .bat, .html, .js, .json
#     (hors .git, release, _test et la bibliothèque console\three) ;
#   - chaque .ps1 est en UTF-8 avec BOM (sans BOM, Windows PowerShell lit mal les accents) ;
#   - le fichier LICENSE est présent.
# Code de sortie 1 s'il y a un problème (utilisé par la CI de GitHub, .github\workflows\tests.yml).

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$app = Join-Path $racine 'Mindset'
$exclus = '\\(\.git|_test|release|outils\\icones)\\|\\console\\three\\'
$problemes = New-Object Collections.Generic.List[string]
function Get-Relatif([string]$Chemin) { $Chemin.Substring($racine.Length).TrimStart('\') }

# Syntaxe et encodage des .ps1
$scripts = @(Get-ChildItem -LiteralPath $racine -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -notmatch $exclus })
foreach ($f in $scripts) {
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
    foreach ($e in $err) { $problemes.Add("Syntaxe : $(Get-Relatif $f.FullName) ligne $($e.Extent.StartLineNumber) : $($e.Message)") }
    $debut = New-Object byte[] 3
    $flux = [IO.File]::OpenRead($f.FullName)
    try { $lus = $flux.Read($debut, 0, 3) } finally { $flux.Dispose() }
    if ($lus -lt 3 -or $debut[0] -ne 0xEF -or $debut[1] -ne 0xBB -or $debut[2] -ne 0xBF) { $problemes.Add("Encodage : $(Get-Relatif $f.FullName) n'est pas en UTF-8 avec BOM") }
}

# La fenêtre
try { [void][xml][IO.File]::ReadAllText((Join-Path $app 'fichiers\modules\interface.xaml'), [Text.Encoding]::UTF8) }
catch { $problemes.Add("interface.xaml : $($_.Exception.Message)") }

# Tirets longs (lus en UTF-8 : un fichier sans BOM serait sinon mal lu)
$textes = @(Get-ChildItem -LiteralPath $racine -Recurse -File -Include '*.ps1', '*.cs', '*.xaml', '*.txt', '*.md', '*.bat', '*.html', '*.js', '*.json' |
        Where-Object { $_.FullName -notmatch $exclus })
foreach ($f in $textes) {
    $n = 0
    foreach ($l in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) {
        $n++
        if ($l -match '[\u2013\u2014]') { $problemes.Add("Tiret long : $(Get-Relatif $f.FullName) ligne $n") }
    }
}

# Licence
if (-not (Test-Path -LiteralPath (Join-Path $racine 'LICENSE'))) { $problemes.Add('LICENSE absent à la racine du dépôt') }

Write-Host "Vérifié : $($scripts.Count) scripts .ps1, $($textes.Count) fichiers texte, interface.xaml, LICENSE."
if ($problemes.Count) {
    $problemes | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "$($problemes.Count) problème(s) trouvé(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'Aucun problème.' -ForegroundColor Green
exit 0
