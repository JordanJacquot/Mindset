# Mindset : le scénario commun des captures des Paramètres (avant : la version PowerShell ; après : la version Rust).
# Chargé par captures-avant.ps1 et captures-apres.ps1. Des thèmes inventés (« Forêt », « Café crème »), un historique,
# le choix du micro : les mêmes fichiers des deux côtés, chacun à sa place.

Add-Type -AssemblyName System.Drawing
function Get-PngEssai([int]$L, [int]$H, [string]$Couleur, [int]$Images = 1) {
    $b = New-Object System.Drawing.Bitmap $L, $H
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.Clear([System.Drawing.Color]::Transparent)
    $w = [int]($L / $Images)
    for ($i = 0; $i -lt $Images; $i++) {
        $pinceau = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Couleur))
        $g.FillEllipse($pinceau, $i * $w + 2 + $i * 2, 2, $w - 6, $H - 4); $pinceau.Dispose()
    }
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
    , $ms.ToArray()
}
function Write-TexteEssai([string]$Fichier, [string]$Texte) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Fichier -Parent) | Out-Null
    [IO.File]::WriteAllText($Fichier, $Texte, (New-Object Text.UTF8Encoding $false))
}
function Write-OctetsEssai([string]$Fichier, [byte[]]$Octets) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Fichier -Parent) | Out-Null
    [IO.File]::WriteAllBytes($Fichier, $Octets)
}

# Les fichiers de Mindset (packs, historique) dans $DataDir, suite.json dans $SuiteFileDir
function Initialize-ScenarioEssai([string]$DataDir, [string]$SuiteFileDir) {
    $packs = Join-Path $DataDir 'packs'
    Write-TexteEssai (Join-Path $packs 'foret\pack.json') '{ "Name": "Forêt", "Desc": "Vert tendre et bois.", "Base": "terminal", "Mascotte": { "File": "mascotte.png", "Frames": 4, "Delay": 120 }, "Logo": "logo.png", "Colors": { "P": "#4CD964", "S": "#B6FF3B", "T": "#FFC83D", "NH": 140, "NS": 0.5, "Map": { "0C0920": "0A1A0E", "06050F": "040C06" } } }'
    Write-OctetsEssai (Join-Path $packs 'foret\mascotte.png') (Get-PngEssai 128 32 '#4CD964' 4)
    Write-OctetsEssai (Join-Path $packs 'foret\logo.png') (Get-PngEssai 64 64 '#B6FF3B')
    Write-TexteEssai (Join-Path $packs 'cafe-creme\pack.json') '{ "Name": "Café crème", "Desc": "Doux comme un matin.", "Base": "crepuscule", "Mascotte": { "File": "bande.png", "Frames": 1 }, "Logo": "logo.png" }'
    Write-OctetsEssai (Join-Path $packs 'cafe-creme\bande.png') (Get-PngEssai 300 40 '#E0B080')
    Write-OctetsEssai (Join-Path $packs 'cafe-creme\logo.png') (Get-PngEssai 64 64 '#C08850')
    Write-TexteEssai (Join-Path $DataDir 'mises-a-jour.json') ('{ "historique": [ ' +
        '{ "id": "evermind", "nom": "Evermind", "version": "1.4.0", "quand": "' + (Get-Date).ToString('yyyy-MM-dd') + 'T00:16:00", "auto": true }, ' +
        '{ "id": "mindset", "nom": "Mindset", "version": "2.18.0", "quand": "' + (Get-Date).AddDays(-1).ToString('yyyy-MM-dd') + 'T21:05:00", "auto": false }, ' +
        '{ "id": "nevermind", "nom": "Nevermind", "version": "2.0.1", "quand": "2026-10-18T09:30:00", "auto": false } ] }')
    Write-TexteEssai (Join-Path $SuiteFileDir 'suite.json') '{ "theme": "neon", "micro": "Microphone (PRO X 2 LIGHTSPEED)", "casque": "" }'
}

$OngletsEssai = 'general', 'apparence', 'son', 'maj', 'conso', 'dossiers'
