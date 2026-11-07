# Captures « après » du bloc « écrans » : la page de Mindset en Rust (la CONSTRUCTION D'ESSAI de Mindset.exe, option
# cargo « essai »), scène par scène, avec l'état calculé par le bloc pour les mêmes données que les captures « avant »
# (tests\vitrine.rs, écrit dans D:\Outils\Rust\essais\ecrans\etats\). À lancer SEULEMENT sur un bureau Windows à part :
#
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '<ce fichier>' -Arguments "-Exe '<Mindset.exe d'essai>'" -Secondes 300
#
# La construction d'essai ne lit que son dossier d'essai, ne lance rien, n'ouvre rien. Chaque état est dessiné par
# window.ecrans.figer (actions.demande, { script }), immobile comme la version PowerShell en test, puis la fenêtre est
# enregistrée (capture.demande -> capture.png) dans D:\Outils\Rust\essais\ecrans\captures\apres-<scène>.png.
param([Parameter(Mandatory = $true)][string]$Exe)
$ErrorActionPreference = 'Stop'
$essais = 'D:\Outils\Rust\essais\ecrans'
$captures = Join-Path $essais 'captures'
$racine = Join-Path $essais 'apres\racine'
if (Test-Path -LiteralPath $racine) { Remove-Item -LiteralPath $racine -Recurse -Force }
New-Item -ItemType Directory -Force -Path $racine, $captures | Out-Null
$donnees = Join-Path $racine 'Donnees\Mindset'
$Exe = (Resolve-Path -LiteralPath $Exe).Path
if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Exe)) -notmatch 'MINDSET_ESSAI_DONNEES') { Write-Output "ÉCHEC : $Exe n'est pas la construction d'essai"; exit 1 }
$env:MINDSET_ESSAI_DONNEES = $racine
$env:MINDSET_ESSAI_NOM = "ecrans-$PID"
function Attendre([scriptblock]$Condition, [int]$Secondes) {
    $fin = (Get-Date).AddSeconds($Secondes)
    while ((Get-Date) -lt $fin) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 200 }
    $false
}
function Journal { $f = Join-Path $donnees 'journal.txt'; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { '' } }

$code = 0
$p = Start-Process -FilePath $Exe -WorkingDirectory $env:SystemRoot -PassThru
try {
    if (-not (Attendre { (Journal) -match 'Écran prêt' } 40)) { Write-Output 'ÉCHEC : la page ne s''est pas chargée'; exit 1 }
    Start-Sleep -Milliseconds 800
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $essais 'etats') -Filter '*.json' | Sort-Object Name)) {
        $nom = $f.BaseName
        $etat = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $ligne = ConvertTo-Json -Compress -InputObject @{ script = "window.ecrans && window.ecrans.figer($etat, true)" }
        [IO.File]::WriteAllText((Join-Path $donnees 'actions.demande'), $ligne, (New-Object Text.UTF8Encoding $false))
        [void](Attendre { -not (Test-Path -LiteralPath (Join-Path $donnees 'actions.demande')) } 10)
        Start-Sleep -Milliseconds 1500   # (les images, les polices, le dessin)
        $png = Join-Path $donnees 'capture.png'
        if (Test-Path -LiteralPath $png) { Remove-Item -LiteralPath $png -Force }
        [IO.File]::WriteAllText((Join-Path $donnees 'capture.demande'), '1')
        if (Attendre { Test-Path -LiteralPath $png } 15) {
            Start-Sleep -Milliseconds 300
            Copy-Item -LiteralPath $png -Destination (Join-Path $captures "apres-$nom.png") -Force
            Write-Output "OK : $(Join-Path $captures "apres-$nom.png")"
        } else { Write-Output "ÉCHEC : $nom, pas de capture"; $code = 1 }
    }
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}
Write-Output '--- journal ---'
Journal
exit $code
