# Construit l'appli témoin (docs\contrat-appli.md) dans <Sortie>\Temoin\, le dossier de son zip (dossier_zip) :
#
#   Temoin\
#     Mindset.exe                 <- l'hôte : fait tourner fichiers\Temoin.ps1 (contrat, partie 4)
#     Temoin.exe                  <- le programme <exe> de apps.json : un relais vers Mindset.exe
#     Désinstaller Temoin.exe     <- le désinstalleur par appli (partie 9)
#     version.json                <- écrit ici depuis la ligne $AppVersion de Temoin.ps1, seule source (partie 10)
#     fichiers\Temoin.ps1         <- l'appli
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\temoin\construire.ps1 -Sortie <dossier>
#
# Rien n'est publié : le témoin ne sert qu'aux tests (outils\tester-contrat.ps1). Rien n'est lancé ici.
param([Parameter(Mandatory)][string]$Sortie)

$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source = Join-Path $PSScriptRoot 'lanceur.cs'
$manif = Join-Path $PSScriptRoot 'lanceur.manifest'
$script = Join-Path $PSScriptRoot 'Temoin\fichiers\Temoin.ps1'
# La première version de Mindset qui accueille une appli de ce contrat (version.json, champ « type »)
$MindsetMin = '2.15.0'

# La version : la ligne $AppVersion de Temoin.ps1, et nulle part ailleurs
$version = ''
foreach ($l in [IO.File]::ReadAllLines($script, [Text.Encoding]::UTF8)) { if ($l -match "^\`$AppVersion\s*=\s*'(\d+(\.\d+){1,3})'") { $version = $Matches[1]; break } }
if (-not $version) { throw "Temoin.ps1 : ligne `$AppVersion introuvable" }
$version4 = (@($version.Split('.')) + @('0', '0', '0'))[0..3] -join '.'

$dest = Join-Path $Sortie 'Temoin'
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $dest 'fichiers') | Out-Null
Copy-Item -LiteralPath $script -Destination (Join-Path $dest 'fichiers\Temoin.ps1')

# Le numéro de version des trois programmes (Propriétés, Détails), dans un petit fichier à part
$infos = Join-Path ([IO.Path]::GetTempPath()) "temoin-version-$([guid]::NewGuid().ToString('N')).cs"
[IO.File]::WriteAllText($infos, "[assembly: System.Reflection.AssemblyVersion(`"$version4`")]`r`n[assembly: System.Reflection.AssemblyFileVersion(`"$version4`")]`r`n")
try {
    $sma = [psobject].Assembly.Location   # (l'hôte fait tourner le script : il a besoin du moteur PowerShell de Windows)
    foreach ($p in @(
            @{ Sortie = 'Mindset.exe'; Symbole = $null; References = @("/reference:$sma") },
            @{ Sortie = 'Temoin.exe'; Symbole = 'RELAIS'; References = @() },
            @{ Sortie = 'Désinstaller Temoin.exe'; Symbole = 'DESINSTALLER'; References = @() })) {
        $arguments = @('/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', "/win32manifest:$manif", '/reference:System.Windows.Forms.dll') + $p.References
        if ($p.Symbole) { $arguments += "/define:$($p.Symbole)" }
        $arguments += @("/out:$(Join-Path $dest $p.Sortie)", $source, $infos)
        $sortieCsc = & $csc @arguments
        if ($LASTEXITCODE) { $sortieCsc | Write-Host; throw "Échec de compilation de $($p.Sortie)" }
    }
} finally { Remove-Item -LiteralPath $infos -Force -ErrorAction SilentlyContinue }

# version.json, dans le dossier du zip à côté de Temoin.exe (UTF-8 sans BOM)
$json = "{ `"appli`": `"temoin`", `"version`": `"$version`", `"mindset_min`": `"$MindsetMin`" }"
[IO.File]::WriteAllText((Join-Path $dest 'version.json'), $json, (New-Object Text.UTF8Encoding $false))
$dest
