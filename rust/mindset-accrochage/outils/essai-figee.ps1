# Essai RÉEL de l'audit M3 (une appli accrochée qui se fige bloque-t-elle Mindset ?), à lancer SEULEMENT sur un
# bureau Windows à part :
#
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '<ce fichier>' -Arguments "-Essai '<essai_figee.exe>'" -Secondes 200 -Sortie '<fichier>'
#
# essai_figee.exe (examples\essai_figee.rs) refuse lui-même de tourner sur le bureau de l'écran. Il lance sa fausse
# appli (lui-même, « appli »), sans console, sur ce bureau. À la fin, tout ce qui a été lancé est arrêté par son
# numéro de processus.
param([Parameter(Mandatory = $true)][string]$Essai)
$ErrorActionPreference = 'Stop'
$Essai = (Resolve-Path -LiteralPath $Essai).Path
$psi = New-Object Diagnostics.ProcessStartInfo $Essai
$psi.Arguments = 'mesure'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WorkingDirectory = $env:SystemRoot
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [Text.Encoding]::UTF8
$p = [Diagnostics.Process]::Start($psi)
try {
    $sortie = $p.StandardOutput.ReadToEndAsync()
    $erreurs = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(170000)) { Write-Output "ÉCHEC : l'essai a dépassé 170 s" }
    Write-Output $sortie.Result.TrimEnd()
    if ($erreurs.Result) { Write-Output "Erreurs : $($erreurs.Result.TrimEnd())" }
    Write-Output "Code de sortie : $($p.ExitCode)"
    exit $p.ExitCode
} finally {
    if (-not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {} }
}
