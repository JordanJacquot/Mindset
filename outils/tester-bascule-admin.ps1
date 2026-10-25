# Mindset : Mindset ouvert en administrateur ne se relance pas sans fin (Mindset.ps1, bascule « en administrateur »).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-bascule-admin.ps1
#   (-Fichiers <dossier> : tester une autre copie de Mindset\fichiers, par exemple l'ancienne version, pour la contre-épreuve)
#
# Mindset installé, ouvert en administrateur, refait ses tâches (installer-admin.ps1 -Action taches) puis se relance sans
# les droits par l'Explorateur. Mais si l'Explorateur a lui-même les droits (contrôle de compte coupé, compte
# Administrateur intégré, comme sur la machine de GitHub), le Mindset relancé est encore administrateur : sans garde, il
# recommençait sans fin. On vérifie, avec le vrai bloc de Mindset.ps1 et un faux Windows (faux Start-Process, faux
# registre, dossier temporaire de test) :
#   1. premier lancement en administrateur : tâches refaites et relance par l'Explorateur (comme avant) ;
#   2. relancé en administrateur dans les 2 minutes : plus de nouvelle relance, Mindset reste ouvert ;
#   3. plus de 2 minutes après : la bascule se refait (une fois).
# Rien sur le vrai PC : aucun programme lancé, aucun registre lu ni écrit.
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).
param([string]$Fichiers)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = if ($Fichiers) { (Resolve-Path -LiteralPath $Fichiers).Path } else { Join-Path $racine 'Mindset\fichiers' }

$script:Reussis = 0
$script:Echoues = @()
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) { $script:Reussis++; Write-Host "  OK     $Nom" -ForegroundColor Green }
    else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
        $script:Lancements | ForEach-Object { Write-Host "           | $_" -ForegroundColor DarkGray }
    }
}

# Le bloc de Mindset.ps1 qui fait la bascule en administrateur (le « if » sur $EstAdmin sans -not)
$e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $fichiers 'Mindset.ps1'), [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
$bloc = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -match '\$EstAdmin' -and $_.Clauses[0].Item1.Extent.Text -notmatch '-not \$EstAdmin'
}) | Select-Object -First 1
if (-not $bloc) { Write-Host 'Bloc de la bascule en administrateur introuvable dans Mindset.ps1.' -ForegroundColor Red; exit 1 }
# (exit fermerait ce test : il devient return ; $PSScriptRoot devient le faux dossier de Mindset)
$texte = $bloc.Extent.Text -replace '(?m)\bexit\b', 'return' -replace '\$PSScriptRoot', '$FauxScriptRoot'

# Le faux PC
$tmp = Join-Path $env:TEMP "mindset-tests-bascule-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$FauxScriptRoot = Join-Path $tmp 'Mindset\fichiers'
$inscritTest = Split-Path $FauxScriptRoot -Parent
$AppExe = Join-Path $inscritTest 'Mindset.exe'
$MarqueCache = Join-Path $tmp 'mindset-rouvrir-cache.marque'
$EnTest = $false; $EstAdmin = $true; $Desinstaller = $false; $Demarrage = $false
$script:Lancements = New-Object Collections.Generic.List[string]
function Get-ItemProperty { param($Path, [string]$ErrorAction) [pscustomobject]@{ InstallLocation = $inscritTest } }
function Start-Process {
    param([string]$FilePath, $ArgumentList, [string]$WorkingDirectory, [string]$WindowStyle, [switch]$PassThru)
    $script:Lancements.Add("$(Split-Path $FilePath -Leaf) $(@($ArgumentList) -join ' ')")
    if ($PassThru) { $o = [pscustomobject]@{}; $o | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }; $o }
}
$tempAvant = $env:TEMP
$script:Relances = 0
function Invoke-Bloc {
    $script:Lancements.Clear()
    $env:TEMP = $tmp
    try { . ([scriptblock]::Create($texte)) } finally { $env:TEMP = $tempAvant }
    $script:Relances = @($script:Lancements | Where-Object { $_ -like 'explorer.exe*' }).Count
}

Write-Host ''
Write-Host 'Mindset ouvert en administrateur par un Explorateur administrateur' -ForegroundColor Cyan
try {
    Invoke-Bloc
    Test-Cas 'premier lancement en administrateur : tâches refaites, puis relance par l''Explorateur' {
        @($script:Lancements | Where-Object { $_ -like 'powershell.exe*-Action taches*' }).Count -eq 1 -and $script:Relances -eq 1
    }
    Invoke-Bloc
    Test-Cas 'relancé encore en administrateur dans les 2 minutes : ni nouvelle relance, ni tâches refaites (pas de boucle)' {
        $script:Lancements.Count -eq 0
    }
    Invoke-Bloc
    Test-Cas 'troisième lancement juste après : toujours rien (la boucle ne repart pas)' { $script:Lancements.Count -eq 0 }
    # Plus de 2 minutes après : la bascule se refait, une fois
    foreach ($m in @(Get-ChildItem -LiteralPath $tmp -Filter '*.marque' -File)) { $m.LastWriteTime = (Get-Date).AddMinutes(-5) }
    Invoke-Bloc
    Test-Cas 'plus de 2 minutes après : la bascule se refait une fois' { $script:Relances -eq 1 }
} finally {
    $env:TEMP = $tempAvant
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Echoues.Count) { Write-Host "$($script:Echoues.Count) cas en échec, $($script:Reussis) réussis." -ForegroundColor Red; exit 1 }
Write-Host "Tous les cas sont réussis ($($script:Reussis))." -ForegroundColor Green
