# Les programmes en Rust de Mindset pour une publication (outils\publier.ps1, passage en Rust, plan 3.6) :
# MindsetInstallateur.exe (rust\mindset-installateur) et « Desinstaller Mindset.exe » (rust\desinstalleur), chacun
# seulement si son dossier est dans le commit publié. Ils ne sont jamais construits sur ce PC : ils viennent de la
# construction GitHub de CE commit (.github\workflows\release.yml, job « Programmes en Rust »), et chacun n'est accepté
# que si son attestation GitHub dit qu'il a été construit par ce dépôt, par release.yml, à partir de ce commit (vérifier
# seulement qu'une attestation existe ne suffit pas), s'il n'a besoin d'aucun runtime C à part
# (outils\verifier-imports.ps1) et, pour le désinstalleur, s'il porte le produit « Mindset » et la version de Mindset.ps1
# de ce commit. Sinon : erreur, et la publication est annulée avant le zip et la signature. Sans ça, la signature de
# Jordan couvrirait un exe qu'on aurait pu remplacer en route.
#
#   .\outils\exe-rust.ps1              une table nom -> chemin des exe vérifiés ; si GitHub ne les a pas encore construits
#                                      pour ce commit, le commit est envoyé et la construction lancée, puis attendue
#   .\outils\exe-rust.ps1 -Essai       rien n'est envoyé ni lancé : seulement une construction déjà faite pour ce commit
#   -Construction <numéro du run>      (essai) prendre les exe de ce run-là : ils ne sont acceptés que si leur
#                                      attestation est bien celle de ce commit (contre-épreuve : un autre commit est refusé)
param([switch]$Essai, [string]$Construction = '')
$ErrorActionPreference = 'Stop'
$Depot = 'JordanJacquot/Mindset'
$Workflow = '.github/workflows/release.yml'
$NomJob = 'Programmes en Rust'   # (début du nom du job dans release.yml)
$Artefact = 'Mindset-rust'
$racine = Split-Path $PSScriptRoot -Parent

# gh et git : seul leur code de sortie compte (leurs messages normaux passent par la sortie d'erreur)
function Invoke-Outil([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $s = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE) { throw "Publication annulée : $Exe $($Arguments -join ' ') a échoué ($(($s | Select-Object -Last 3) -join ' '))" }
    $s
}

$commit = ((Invoke-Outil git @('-C', $racine, 'rev-parse', 'HEAD')) -join '').Trim()
if ($commit -notmatch '^[0-9a-f]{40}$') { throw "Publication annulée : commit illisible ($commit)." }
# Ce que ce commit construit en Rust (son dossier dans le commit, pas seulement sur le disque)
function Test-DansCommit([string]$Chemin) {
    $ErrorActionPreference = 'Continue'
    & git -C $racine cat-file -e "$($commit):$Chemin" 2>$null
    $LASTEXITCODE -eq 0
}
$attendus = @(if (Test-DansCommit 'rust/mindset-installateur/Cargo.toml') { 'MindsetInstallateur.exe' }
              if (Test-DansCommit 'rust/desinstalleur/Cargo.toml') { 'Desinstaller Mindset.exe' })
if (-not $attendus.Count) { throw "Publication annulée : ni rust\mindset-installateur ni rust\desinstalleur dans le commit $commit." }
$noms = $attendus -join ' et '

# La version de Mindset.ps1 dans ce commit, en quatre nombres (celle que le désinstalleur doit porter)
$avant = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $texte = (Invoke-Outil git @('-C', $racine, 'show', "$($commit):Mindset/fichiers/Mindset.ps1")) -join "`n"
} finally { [Console]::OutputEncoding = $avant }
if ($texte -notmatch "(?m)^\`$AppVersion = '(\d+(\.\d+){1,3})'") { throw "Publication annulée : numéro de version introuvable dans Mindset.ps1 du commit $commit." }
$p = @($Matches[1].Split('.')); while ($p.Count -lt 4) { $p += '0' }
$version4 = $p -join '.'

# Les constructions GitHub de ce commit qui ont le job Rust : leur numéro, l'état et le résultat de ce job
function Find-Constructions {
    $runs = (Invoke-Outil gh @('run', 'list', '--repo', $Depot, '--workflow', 'release.yml', '--commit', $commit, '--limit', '20', '--json', 'databaseId,headSha,event,createdAt')) -join "`n" | ConvertFrom-Json
    foreach ($r in @($runs | Where-Object { $_.headSha -eq $commit -and $_.event -in 'push', 'workflow_dispatch' } | Sort-Object createdAt -Descending)) {
        $v = (Invoke-Outil gh @('run', 'view', [string]$r.databaseId, '--repo', $Depot, '--json', 'jobs,url')) -join "`n" | ConvertFrom-Json
        $j = @($v.jobs | Where-Object { [string]$_.name -like "$NomJob*" }) | Select-Object -First 1
        if ($j) { [pscustomobject]@{ Id = [string]$r.databaseId; Etat = [string]$j.status; Resultat = [string]$j.conclusion; Url = [string]$v.url } }
    }
}

if ($Construction) {
    if ($Construction -notmatch '^\d+$') { throw "Numéro de construction invalide : $Construction" }
    $bonne = [pscustomobject]@{ Id = $Construction; Url = "https://github.com/$Depot/actions/runs/$Construction" }
} else {
    $c = @(Find-Constructions)
    $bonne = @($c | Where-Object { $_.Resultat -eq 'success' }) | Select-Object -First 1
}
if (-not $bonne) {
    if (-not @($c | Where-Object { $_.Etat -ne 'completed' }).Count) {
        if ($Essai) { throw "Essai : GitHub n'a pas encore construit $noms (Rust) pour le commit $commit." }
        # Le commit sur GitHub, puis sa construction
        $branche = ((Invoke-Outil git @('-C', $racine, 'rev-parse', '--abbrev-ref', 'HEAD')) -join '').Trim()
        if ($branche -eq 'HEAD') { throw 'Publication annulée : aucune branche en cours (HEAD détaché).' }
        Write-Host "Envoi du commit sur GitHub et construction de $noms (Rust) par release.yml..."
        $null = Invoke-Outil git @('-C', $racine, 'push', 'origin', 'HEAD')
        $null = Invoke-Outil gh @('workflow', 'run', 'release.yml', '--repo', $Depot, '--ref', $branche)
    }
    # Attendre la fin du job Rust (40 minutes au plus)
    $limite = (Get-Date).AddMinutes(40)
    while (-not $bonne) {
        if ((Get-Date) -gt $limite) { throw "Publication annulée : GitHub n'a pas fini de construire $noms (Rust) pour le commit $commit en 40 minutes." }
        Start-Sleep -Seconds 15
        $c = @(Find-Constructions)
        $bonne = @($c | Where-Object { $_.Resultat -eq 'success' }) | Select-Object -First 1
        $ratee = @($c | Where-Object { $_.Etat -eq 'completed' -and $_.Resultat -ne 'success' }) | Select-Object -First 1
        if (-not $bonne -and $ratee -and -not @($c | Where-Object { $_.Etat -ne 'completed' }).Count) {
            throw "Publication annulée : la construction GitHub de $noms (Rust) a échoué ($($ratee.Resultat)) : $($ratee.Url)"
        }
    }
}

# Les exe de cette construction : exactement ceux attendus, chacun attesté (ce dépôt, release.yml, ce commit, source et
# fichier de construction), sans runtime C à part, et le désinstalleur avec la bonne fiche de version
$dossier = Join-Path ([IO.Path]::GetTempPath()) "mindset-rust-$PID"
if (Test-Path -LiteralPath $dossier) { Remove-Item -LiteralPath $dossier -Recurse -Force }
$null = Invoke-Outil gh @('run', 'download', $bonne.Id, '--repo', $Depot, '--name', $Artefact, '--dir', $dossier)
$recus = @(Get-ChildItem -LiteralPath $dossier -Recurse -File | ForEach-Object { $_.FullName.Substring($dossier.Length + 1) } | Sort-Object)
if (($recus -join '|') -ne (@($attendus | Sort-Object) -join '|')) {
    throw "Publication annulée : l'artefact $Artefact de la construction $($bonne.Url) contient « $($recus -join ', ') » au lieu de « $($attendus -join ', ') »."
}
$verifies = [ordered]@{}
foreach ($n in $attendus) {
    $f = Join-Path $dossier $n
    $ErrorActionPreference = 'Continue'
    $verif = @(& gh attestation verify $f --repo $Depot --signer-workflow "$Depot/$Workflow" --source-digest $commit --signer-digest $commit --deny-self-hosted-runners 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code) { throw "Publication annulée : $n téléchargé n'est pas attesté comme construit par $Workflow de $Depot à partir du commit $commit ($(($verif | Select-Object -Last 3) -join ' '))." }
    & (Join-Path $PSScriptRoot 'verifier-imports.ps1') -Fichiers $f | Out-Host
    if ($LASTEXITCODE) { throw "Publication annulée : $n a besoin d'un runtime C à installer à part." }
    $i = (Get-Item -LiteralPath $f).VersionInfo
    if ($n -eq 'Desinstaller Mindset.exe' -and ($i.ProductName -ne 'Mindset' -or $i.ProductVersion -ne $version4)) {
        throw "Publication annulée : $n porte le produit « $($i.ProductName) » en version « $($i.ProductVersion) » au lieu de « Mindset » en $version4."
    }
    Write-Host "$n (Rust) : construction $($bonne.Url), attestation vérifiée (dépôt, release.yml, commit $commit), SHA-256 $((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash)"
    $verifies[$n] = $f
}
$verifies
