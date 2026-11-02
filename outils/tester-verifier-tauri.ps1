# Mindset : teste outils\verifier-tauri.ps1 sur les projets d'essai de outils\essais-tauri.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-verifier-tauri.ps1
#
#   - « propre » : un projet Tauri qui suit les 8 règles de docs\regles-tauri.md. Il doit passer (code 0, aucun
#     problème) ;
#   - « casse-<règle>-<quoi> » : le même projet, cassé exprès sur une seule règle. Le dossier ne contient que les
#     fichiers qui changent (et retirer.txt : les fichiers à enlever). Chacun doit échouer (code 1), avec au moins un
#     problème, et seulement sur sa règle (« Règle <n> » ou « Configuration »).
# Chaque projet est assemblé dans un dossier d'essai sous %TEMP%, effacé à la fin. Rien n'est lancé ni construit.
# Code de sortie 1 au premier écart (tests GitHub, .github\workflows\tests.yml).

$ErrorActionPreference = 'Stop'
$verifier = Join-Path $PSScriptRoot 'verifier-tauri.ps1'
$essais = Join-Path $PSScriptRoot 'essais-tauri'
$propre = Join-Path $essais 'propre'
$temp = Join-Path ([IO.Path]::GetTempPath()) "essais-tauri-$PID"
$ecarts = New-Object Collections.Generic.List[string]

# Assemble un projet d'essai : propre, puis les fichiers du cas par dessus, puis ceux de retirer.txt enlevés
function New-ProjetEssai([string]$Nom, [string]$Cas) {
    $d = Join-Path $temp $Nom
    Copy-Item -LiteralPath $propre -Destination $d -Recurse
    if ($Cas) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Cas -Recurse -File | Where-Object { $_.Name -ne 'retirer.txt' })) {
            $cible = Join-Path $d $f.FullName.Substring($Cas.Length).TrimStart('\')
            [void][IO.Directory]::CreateDirectory((Split-Path $cible -Parent))
            Copy-Item -LiteralPath $f.FullName -Destination $cible -Force
        }
        $retirer = Join-Path $Cas 'retirer.txt'
        if (Test-Path -LiteralPath $retirer) {
            foreach ($r in @([IO.File]::ReadAllLines($retirer) | Where-Object { $_.Trim() })) { Remove-Item -LiteralPath (Join-Path $d $r.Trim()) -Recurse -Force }
        }
    }
    $d
}
function Invoke-Verifier([string]$Dossier) {
    $sortie = @(& $verifier -Projet $Dossier)
    @{ Code = $LASTEXITCODE; Sortie = $sortie; Problemes = @($sortie | Where-Object { $_ -match '^(Règle \d|Configuration) : ' }) }
}

if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
[void][IO.Directory]::CreateDirectory($temp)
try {
    # Le projet propre passe
    $r = Invoke-Verifier (New-ProjetEssai 'propre' $null)
    if ($r.Code -ne 0 -or $r.Problemes.Count) { $ecarts.Add("propre : refusé (code $($r.Code)) : $($r.Sortie -join ' | ')") }
    else { Write-Host 'propre : accepté' }

    # Chaque projet cassé échoue, sur sa règle seulement
    $cas = @(Get-ChildItem -LiteralPath $essais -Directory | Where-Object { $_.Name -like 'casse-*' } | Sort-Object Name)
    if ($cas.Count -lt 8) { $ecarts.Add("seulement $($cas.Count) projets cassés trouvés") }
    $regles = @{}
    foreach ($c in $cas) {
        if ($c.Name -notmatch '^casse-(\d|config)-') { $ecarts.Add("$($c.Name) : nom sans règle (casse-<règle>-<quoi>)"); continue }
        $regle = $Matches[1]
        $regles[$regle] = $true
        $attendu = if ($regle -eq 'config') { 'Configuration : ' } else { "Règle $regle : " }
        $r = Invoke-Verifier (New-ProjetEssai $c.Name $c.FullName)
        $autres = @($r.Problemes | Where-Object { -not $_.StartsWith($attendu) })
        if ($r.Code -ne 1) { $ecarts.Add("$($c.Name) : accepté (code $($r.Code)) alors qu'il est cassé exprès") }
        elseif (-not $r.Problemes.Count) { $ecarts.Add("$($c.Name) : refusé sans problème nommé : $($r.Sortie -join ' | ')") }
        elseif ($autres.Count) { $ecarts.Add("$($c.Name) : refusé aussi sur une autre règle : $($autres -join ' | ')") }
        else { Write-Host "$($c.Name) : refusé ($($r.Problemes[0]))" }
    }
    foreach ($n in @('config', '1', '2', '3', '4', '5', '6', '7', '8')) {
        if (-not $regles.ContainsKey($n)) { $ecarts.Add("aucun projet cassé pour la règle $n") }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($ecarts.Count) {
    $ecarts | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "$($ecarts.Count) écart(s)." -ForegroundColor Red
    exit 1
}
Write-Host "Vérificateur Tauri : le projet propre passe, les $($cas.Count) projets cassés échouent chacun sur sa règle." -ForegroundColor Green
exit 0
