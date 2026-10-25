# Essai sur la machine de GitHub (jamais sur un vrai PC) : le vrai téléchargement de Mindset (Get-Publication, Get-Octets,
# redirections de GitHub comprises) rapporte les vrais zips publiés des 4 applis, entiers : leur signature est valide avec
# les vraies clés publiques. Nevermind : Nevermind.zip, ou à défaut son ancien nom OptiGame.zip (version publiée avant le
# changement de nom), par l'API de GitHub et sans elle. Rien n'est installé ni gardé (tout reste en mémoire).
if ($env:GITHUB_ACTIONS -ne 'true') { Write-Host "Cet essai télécharge les vraies versions : il ne tourne que sur la machine de GitHub."; exit 2 }
$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$modules = Join-Path $racine 'Mindset\fichiers\modules'
$cles = Join-Path $racine 'Mindset\fichiers\cles-publiques'
function Write-Log([string]$Message) { Write-Host "  (journal) $Message" }
foreach ($m in 'signature', 'paquets') { . (Join-Path $modules "$m.ps1") }
$echecs = 0
foreach ($a in @(@('JordanJacquot/Mindset', 'Mindset.zip'), @('JordanJacquot/Nevermind', @('Nevermind.zip', 'OptiGame.zip')), @('JordanJacquot/Evermind', 'Evermind.zip'), @('JordanJacquot/Mindcare', 'Mindcare.zip'))) {
    try {
        $p = Get-Publication $a[0] $a[1]
        if ($p.Erreur) { throw $p.Erreur }
        $t = [Diagnostics.Stopwatch]::StartNew()
        $zip = Get-Octets $p.UrlZip
        $sig = Get-Octets $p.UrlSig
        $ok = Test-Signature $zip $sig $cles
        $txt = "$($p.Fichier) $($p.Version) : $([math]::Round($zip.Length / 1MB, 1)) Mo en $([math]::Round($t.Elapsed.TotalSeconds, 1)) s, signature $(if ($ok) { 'valide' } else { 'INVALIDE' })"
        if ($ok) { Write-Host "OK     $txt" } else { Write-Host "ÉCHEC  $txt"; $echecs++ }
    } catch { Write-Host "ÉCHEC  $(@($a[1])[0]) : $($_.Exception.Message)"; $echecs++ }
}
# Sans l'API (quand GitHub la refuse) : le même choix du nom, par la page des versions
$s = Get-PublicationSansApi 'JordanJacquot/Nevermind' @('Nevermind.zip', 'OptiGame.zip')
if ($s -and $s.UrlSig -and $s.UrlZip -like "*/$($s.Fichier)" -and $s.Fichier -in 'Nevermind.zip', 'OptiGame.zip') {
    $zip = Get-Octets $s.UrlZip; $sig = Get-Octets $s.UrlSig
    if (Test-Signature $zip $sig $cles) { Write-Host "OK     sans l'API : $($s.Fichier) $($s.Version), signature valide" } else { Write-Host "ÉCHEC  sans l'API : signature INVALIDE"; $echecs++ }
} else { Write-Host "ÉCHEC  sans l'API : $($s | ConvertTo-Json -Compress)"; $echecs++ }
if ($echecs) { Write-Host "$echecs échec(s)."; exit 1 }
Write-Host 'Les 4 vrais zips sont téléchargés entiers par le nouveau code.'
