# Construit le dossier de Mindset prêt à partager, puis release\Mindset.zip.
# (Mindset doit être fermé : son .exe est remplacé.)
#
#   Mindset\
#     Mindset.exe                 <- à lancer
#     fichiers\Mindset.ps1        <- le point d'entrée
#     fichiers\apps.json          <- la liste des applis de la suite
#     fichiers\modules\           <- le code découpé par partie

$ErrorActionPreference = 'Stop'
$racine  = Split-Path $PSScriptRoot -Parent
$app     = Join-Path $racine 'Mindset'
$icones  = Join-Path $PSScriptRoot 'icones'
$csc     = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source  = Join-Path $PSScriptRoot 'lanceur.cs'
$manif   = Join-Path $PSScriptRoot 'lanceur.manifest'

# L'icône (le M glitché), pour Mindset.exe, la fenêtre, la barre des tâches et le raccourci
& (Join-Path $PSScriptRoot 'icone.ps1') -OutDir $icones | Out-Null
Copy-Item (Join-Path $icones 'Mindset.ico') (Join-Path $app 'fichiers\Mindset.ico') -Force

$exe = Join-Path $app 'Mindset.exe'
# Mindset.exe exécute le code lui même : il a besoin du moteur PowerShell de Windows
$sma = [psobject].Assembly.Location
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$(Join-Path $icones 'Mindset.ico')" "/win32manifest:$manif" /reference:System.Windows.Forms.dll "/reference:$sma" "/out:$exe" $source
if ($LASTEXITCODE) { throw "Échec de compilation de $exe" }

$release = Join-Path $racine 'release'
New-Item -ItemType Directory -Force -Path $release | Out-Null
$zip = Join-Path $release 'Mindset.zip'
Compress-Archive -Path $app -DestinationPath $zip -Force
"OK : $zip"
