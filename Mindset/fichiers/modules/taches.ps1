# Mindset : travaux de fond (téléchargements, vérifications), pour ne jamais figer la fenêtre.
# Chargé par Mindset.ps1, qui définit $ModulesDir.
#
#   Start-Tache { $p = $args[0]; ... } @{ ... } { param($Resultat, $Erreur) ... }
# Le travail tourne à part, avec signature.ps1 et paquets.ps1 chargés ; la fin est appelée dans la fenêtre.

$script:Taches = New-Object System.Collections.ArrayList

# Le code appelé plus tard (fin d'une tâche de fond ou d'une opération en administrateur, bouton d'une confirmation) avec
# des valeurs (une appli, un dossier, un message) : les valeurs sont rangées ici sous une clé faite de chiffres et de
# lettres (un GUID), et seule cette clé va dans le code. Jamais de valeur recopiée dans du code : une apostrophe ’ ou un
# $ dans un nom de dossier le casserait, ou le changerait. Dans $Code, les valeurs sont dans $v ; $Parametres : les noms
# des paramètres reçus (par exemple 'Ok', 'Message'). Chaque entrée est retirée quand elle sert, et il n'en reste jamais
# plus de 200 (une confirmation annulée ne sert jamais : les plus anciennes partent).
$script:Actions = New-Object System.Collections.Specialized.OrderedDictionary
function New-Action([hashtable]$Valeurs, [scriptblock]$Code, [string[]]$Parametres = @()) {
    $cle = [guid]::NewGuid().ToString('N')
    $script:Actions[$cle] = $Valeurs
    while ($script:Actions.Count -gt 200) { $script:Actions.RemoveAt(0) }
    $params = if ($Parametres.Count) { 'param(' + (($Parametres | ForEach-Object { if ($_ -notmatch '^[A-Za-z]+$') { throw "Paramètre refusé : $_" }; "`$$_" }) -join ', ') + ')' } else { '' }
    [scriptblock]::Create("$params`n`$v = Pop-Action '$cle'`nif (`$null -eq `$v) { return }`n$($Code.ToString())")
}
function Pop-Action([string]$Cle) { $v = $script:Actions[$Cle]; $script:Actions.Remove($Cle); $v }

function Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) {
    # (chemins échappés pour toutes les apostrophes que PowerShell reconnaît, ’ comprise, pas seulement ')
    $echappe = { param($f) [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent((Join-Path $ModulesDir $f)) }
    $prelude = ". '$(& $echappe 'signature.ps1')'; . '$(& $echappe 'paquets.ps1')'`n"
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
