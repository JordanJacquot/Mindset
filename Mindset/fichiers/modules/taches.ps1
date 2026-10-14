# Mindset : travaux de fond (téléchargements, vérifications), pour ne jamais figer la fenêtre.
# Chargé par Mindset.ps1, qui définit $ModulesDir.
#
#   Start-Tache { $p = $args[0]; ... } @{ ... } { param($Resultat, $Erreur) ... }
# Le travail tourne à part, avec signature.ps1 et paquets.ps1 chargés ; la fin est appelée dans la fenêtre.

$script:Taches = New-Object System.Collections.ArrayList

function Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) {
    $prelude = ". '$((Join-Path $ModulesDir 'signature.ps1').Replace("'", "''"))'; . '$((Join-Path $ModulesDir 'paquets.ps1').Replace("'", "''"))'`n"
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($prelude + $Travail.ToString()).AddArgument($Parametres)
    [void]$script:Taches.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Fin = $Fin })
    if (-not $script:TachesTimer.IsEnabled) { $script:TachesTimer.Start() }
}

$script:TachesTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TachesTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:TachesTimer.Add_Tick({
    foreach ($t in @($script:Taches)) {
        if (-not $t.Handle.IsCompleted) { continue }
        [void]$script:Taches.Remove($t)
        $res = $null; $err = $null
        try {
            $res = @($t.PS.EndInvoke($t.Handle)) | Select-Object -Last 1
            if ($t.PS.Streams.Error.Count) { $err = $t.PS.Streams.Error[0].Exception.Message }
        } catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; $err = $e.Message }
        finally { $t.PS.Dispose() }
        try { & $t.Fin $res $err } catch { Write-Log "Fin de tâche : $_" }
    }
    if (-not $script:Taches.Count) { $script:TachesTimer.Stop() }
})
