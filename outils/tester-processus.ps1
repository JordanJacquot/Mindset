# Mindset : tests des programmes trouvés par leur CHEMIN, jamais par leur nom (modules\applis.ps1, MSProcessus de natif.cs).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-processus.ps1
#
# L'hôte de chaque appli s'appelle Mindset.exe, comme Mindset lui-même (pour que le Gestionnaire des tâches regroupe la
# suite sur une ligne). Ici, de vrais petits programmes d'essai (compilés à la volée) tournent depuis un faux dossier des
# programmes sous %TEMP% : Mindset, l'hôte Mindset.exe et l'ancien Nevermind.exe d'une appli, une appli au nom proche, une
# copie ailleurs, un programme d'aide dans les données, de faux msedgewebview2.exe. On vérifie que :
#   - une appli est trouvée par son dossier, quel que soit le nom de son hôte, et jamais Mindset avec elle ;
#   - « ouverte ou non » suit son dossier (une copie ailleurs, ou une appli au nom proche, ne compte pas) ;
#   - le relevé de consommation range chaque programme à sa place (Mindset, appli, WebView2 de la suite, aide) ;
#   - plus aucune recherche ni fermeture de processus par son nom dans le code de Mindset.
# Rien sur le vrai PC : seuls les programmes d'essai lancés ici sont fermés, et le dossier de test est retiré à la fin.
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'

$script:Reussis = 0
$script:Echoues = @()
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
    }
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

$tmp = Join-Path $env:TEMP "mindset-processus-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName   # (en nom long : sur GitHub, TEMP est en nom court)
$script:Lances = @()

try {
    Write-Partie 'Préparation'
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $fichiers 'modules\natif.cs'), [Text.Encoding]::UTF8))
    # Le programme d'essai : attend 10 minutes ; avec « occupe », fait travailler le processeur pendant 30 secondes
    $essai = Join-Path $tmp 'essai.exe'
    Add-Type -OutputType WindowsApplication -OutputAssembly $essai -TypeDefinition @'
static class Essai {
    static void Main(string[] a) {
        if (a.Length > 0 && a[0] == "occupe") { var f = System.DateTime.Now.AddSeconds(30); double x = 0; while (System.DateTime.Now < f) x += System.Math.Sqrt(x + 1); return; }
        System.Threading.Thread.Sleep(600000);
    }
}
'@
    Test-Cas 'Le programme d''essai se compile' { Test-Path -LiteralPath $essai }

    $prog = Join-Path $tmp 'Programmes'
    $donnees = Join-Path $tmp 'Donnees'
    function Start-Essai([string]$Chemin, [string]$Arguments = '') {
        New-Item -ItemType Directory -Force -Path (Split-Path $Chemin -Parent) | Out-Null
        if (-not (Test-Path -LiteralPath $Chemin)) { Copy-Item -LiteralPath $essai -Destination $Chemin }
        $p = if ($Arguments) { Start-Process -FilePath $Chemin -ArgumentList $Arguments -PassThru } else { Start-Process -FilePath $Chemin -PassThru }
        $script:Lances += $p
        $p
    }
    $Lot = @{
        Mindset       = Start-Essai "$prog\Mindset\Mindset.exe"
        HoteN         = Start-Essai "$prog\Nevermind\Mindset.exe"
        AncienN       = Start-Essai "$prog\Nevermind\Nevermind.exe"
        AideN         = Start-Essai "$prog\Nevermind\outils\aide.exe"
        Bis           = Start-Essai "$prog\NevermindBis\Nevermind.exe"
        Evermind      = Start-Essai "$prog\Evermind\Evermind.exe" 'occupe'
        Ailleurs      = Start-Essai "$tmp\ailleurs\Nevermind.exe"
        AilleursHote  = Start-Essai "$tmp\ailleurs\Mindset.exe"
        Llama         = Start-Essai "$donnees\Mindcare\modeles\llama-server.exe"
        VoixE         = Start-Essai "$donnees\Evermind\voix\Mindset.exe"
        WvSuite       = Start-Essai "$tmp\edge\msedgewebview2.exe" "--type=renderer `"--user-data-dir=$donnees\WebView2\EBWebView`""
        WvAncien      = Start-Essai "$tmp\edge\msedgewebview2.exe" "--type=gpu-process `"--user-data-dir=$donnees\Nevermind\ecran-webview\EBWebView`""
        WvAutre       = Start-Essai "$tmp\edge\msedgewebview2.exe" "--type=renderer `"--user-data-dir=$tmp\autre-programme\EBWebView`""
    }
    Start-Sleep -Milliseconds 800

    # Ce que Mindset.ps1 et ses modules définissent, pour un Mindset installé dans $prog\Mindset
    $MonDossier = "$prog\Mindset"
    $script:Installs = @{ nevermind = "$prog\Nevermind"; evermind = "$prog\Evermind" }
    function Get-Installation($Appli) { $d = $script:Installs[$Appli.Id]; if ($d) { @{ Dossier = $d; Gere = $true; Version = '1.0.0' } } }
    function Write-Log { }
    function Get-DossierDonnees($Appli) { Join-Path $donnees $Appli.Nom }
    $SuiteDir = $donnees
    $AppDir = $fichiers
    . (Join-Path $fichiers 'modules\applis.ps1')
    $nevermind = [pscustomobject]@{ Id = 'nevermind'; Nom = 'Nevermind'; Exe = 'Nevermind.exe'; Mutex = "Local\MindsetTest-$([guid]::NewGuid().ToString('N'))"; Donnees = '' }
    $evermind = [pscustomobject]@{ Id = 'evermind'; Nom = 'Evermind'; Exe = 'Evermind.exe'; Mutex = ''; Donnees = '' }
    $mindcare = [pscustomobject]@{ Id = 'mindcare'; Nom = 'Mindcare'; Exe = 'Mindcare.exe'; Mutex = ''; Donnees = '' }
    function Get-Ids($Liste) { @($Liste | ForEach-Object { $_.Id } | Sort-Object) -join ',' }
    function Get-IdsDe([string[]]$Noms) { @($Noms | ForEach-Object { $Lot[$_].Id } | Sort-Object) -join ',' }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Une appli trouvée par son dossier, quel que soit le nom de son hôte'
    # -------------------------------------------------------------------------------------------------------------
    Test-Cas 'Nevermind (-Hote) : son hôte Mindset.exe et l''ancien Nevermind.exe de son dossier, rien d''autre' {
        (Get-Ids (Get-ProcessusAppli $nevermind -Hote)) -eq (Get-IdsDe 'HoteN', 'AncienN')
    }
    Test-Cas 'Nevermind (tout son dossier) : avec son programme d''aide d''un sous-dossier' {
        (Get-Ids (Get-ProcessusAppli $nevermind)) -eq (Get-IdsDe 'HoteN', 'AncienN', 'AideN')
    }
    Test-Cas 'Jamais Mindset lui-même (Programmes\Mindset\Mindset.exe), ni ce processus' {
        $ids = @(Get-ProcessusAppli $nevermind) + @(Get-ProcessusAppli $evermind) | ForEach-Object Id
        $ids -notcontains $Lot.Mindset.Id -and $ids -notcontains $PID
    }
    Test-Cas 'Ni l''appli au nom proche (NevermindBis), ni les copies du même nom ailleurs' {
        $ids = @(Get-ProcessusAppli $nevermind) | ForEach-Object Id
        $ids -notcontains $Lot.Bis.Id -and $ids -notcontains $Lot.Ailleurs.Id -and $ids -notcontains $Lot.AilleursHote.Id
    }
    Test-Cas 'Une appli dont l''installation pointerait vers le dossier de Mindset : rien (Mindset n''est jamais pris pour une appli)' {
        $script:Installs['piege'] = "$prog\Mindset"
        $piege = [pscustomobject]@{ Id = 'piege'; Nom = 'Piege'; Exe = 'Mindset.exe'; Mutex = '' }
        @(Get-ProcessusAppli $piege).Count -eq 0 -and @(Get-ProcessusAppli $piege -Hote).Count -eq 0
    }
    Test-Cas 'Ses programmes d''aide lancés depuis ses données (voix\Mindset.exe d''Evermind) : trouvés par leur chemin, jamais pris pour Mindset' {
        (Get-Ids (Get-ProcessusDonneesAppli $evermind)) -eq (Get-IdsDe 'VoixE') -and @(Get-ProcessusAppli $evermind -Hote | ForEach-Object Id) -notcontains $Lot.VoixE.Id
    }
    Test-Cas 'Une appli pas installée : rien (même si un programme du même nom tourne ailleurs)' { @(Get-ProcessusAppli $mindcare).Count -eq 0 }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Ouverte ou non, par son dossier'
    # -------------------------------------------------------------------------------------------------------------
    Test-Cas 'Nevermind ouverte (son hôte Mindset.exe tourne dans son dossier, sans mutex)' { Test-AppliOuverte $nevermind }
    Test-Cas 'Evermind ouverte' { Test-AppliOuverte $evermind }
    $Lot.HoteN.Kill(); $Lot.AncienN.Kill(); [void]$Lot.HoteN.WaitForExit(3000); [void]$Lot.AncienN.WaitForExit(3000)
    Test-Cas 'Nevermind fermée : plus ouverte, alors que NevermindBis, la copie ailleurs, Mindset et son aide tournent encore' {
        -not (Test-AppliOuverte $nevermind) -and -not $Lot.Bis.HasExited -and -not $Lot.Ailleurs.HasExited -and -not $Lot.Mindset.HasExited -and -not $Lot.AideN.HasExited
    }
    $Lot.HoteN = Start-Essai "$prog\Nevermind\Mindset.exe"
    Start-Sleep -Milliseconds 400
    Test-Cas 'Fermer une appli (Kill de Get-ProcessusAppli -Hote, comme Mindset en quittant) ne ferme jamais Mindset' {
        $trouves = @(Get-ProcessusAppli $nevermind -Hote)
        foreach ($p in $trouves) { $p.Kill(); [void]$p.WaitForExit(3000) }
        Write-Host "         (trouvés : $(@($trouves | ForEach-Object Id) -join ', ') ; hôte lancé : $($Lot.HoteN.Id))" -ForegroundColor DarkGray
        $Lot.HoteN.WaitForExit(3000) -and -not $Lot.Mindset.HasExited -and -not (Test-AppliOuverte $nevermind)
    }
    Test-Cas 'Une copie déjà ouverte se retrouve par le chemin de son hôte (Find-InstallationExistante)' {
        $c = @([MSProcessus]::Chemins([string[]]@('Nevermind.exe', 'Mindset.exe')))
        $c -contains "$tmp\ailleurs\Mindset.exe" -and $c -contains "$tmp\ailleurs\Nevermind.exe"
    }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Consommation de la suite (Paramètres > Consommation)'
    # -------------------------------------------------------------------------------------------------------------
    $Lot.HoteN = Start-Essai "$prog\Nevermind\Mindset.exe"
    Start-Sleep -Milliseconds 400
    $noms = [string[]]@('Nevermind', 'Nevermind', 'Evermind', 'Evermind', 'Programmes d''aide', 'Programmes d''aide')
    $dossiers = [string[]]@("$prog\Nevermind", "$donnees\Nevermind", "$prog\Evermind", "$donnees\Evermind", $donnees, $prog)
    $marqueurs = [string[]]@("$donnees\WebView2\", "$donnees\Mindset\console-webview\", "$donnees\Nevermind\ecran-webview\")
    $chrono = [Diagnostics.Stopwatch]::StartNew()
    $m1 = [MSProcessus]::Mesurer($PID, 'Mindset', $MonDossier, $noms, $dossiers, 'WebView2 de la suite', $marqueurs)
    $t1 = $chrono.ElapsedMilliseconds
    Start-Sleep -Milliseconds 1500
    $chrono.Restart()
    $m = [MSProcessus]::Mesurer($PID, 'Mindset', $MonDossier, $noms, $dossiers, 'WebView2 de la suite', $marqueurs)
    $t2 = $chrono.ElapsedMilliseconds
    $parts = @{}; foreach ($x in $m) { $parts[$x.Nom] = $x }
    Write-Host "         (mesure : $t1 ms la première fois, $t2 ms ensuite)" -ForegroundColor DarkGray
    Test-Cas 'Mindset : ce processus et le Mindset.exe de son dossier (2 programmes)' { $parts['Mindset'].Nombre -eq 2 }
    Test-Cas 'Nevermind : son hôte Mindset.exe et son aide (2 programmes), jamais rangés avec Mindset' { $parts['Nevermind'].Nombre -eq 2 }
    Test-Cas 'Evermind : son programme (qui travaille : processeur au-dessus de 0) et son aide voix\Mindset.exe de ses données' { $parts['Evermind'].Nombre -eq 2 -and $parts['Evermind'].Processeur -gt 0 }
    Test-Cas 'WebView2 de la suite : le dossier commun et l''ancien ecran-webview, pas celui d''un autre programme' { $parts['WebView2 de la suite'].Nombre -eq 2 }
    Test-Cas 'Programmes d''aide : le serveur lancé depuis les données, et NevermindBis du dossier des programmes' { $parts['Programmes d''aide'].Nombre -eq 2 }
    Test-Cas 'La mémoire est comptée (chaque partie > 0)' { -not @($m | Where-Object { $_.Nombre -and $_.Memoire -le 0 }).Count }
    Test-Cas 'Une mesure est légère (moins de 100 ms une fois les chemins connus)' { $t2 -lt 100 }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Plus aucune recherche ni fermeture de processus par son nom dans le code de Mindset'
    # -------------------------------------------------------------------------------------------------------------
    $code = @(Get-ChildItem -LiteralPath $fichiers -Recurse -File -Include '*.ps1', '*.cs' | Where-Object { $_.FullName -notmatch '\\console\\three\\' })
    $trouves = @(foreach ($f in $code) {
        $n = 0
        foreach ($l in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) {
            $n++
            if ($l -match 'Get-Process\s+-Name|Get-Process\s+[''"$\w]|Stop-Process\s+-Name|GetProcessesByName|taskkill|\.ProcessName') { "$($f.Name) ligne $n" }
        }
    })
    if ($trouves.Count) { $trouves | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray } }
    Test-Cas 'Ni Get-Process -Name, ni Stop-Process -Name, ni GetProcessesByName, ni taskkill, ni ProcessName' { $trouves.Count -eq 0 }
    $admin = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'installer-admin-powershell.ps1'), [Text.Encoding]::UTF8)   # (version PowerShell ; l'exe Rust : corpus cas\installateur)
    Test-Cas 'Le mini-installateur ferme par dossier (Stop-Programme reçoit le dossier vérifié)' { $admin -match 'Stop-Programme \$Exe \$dest' -and $admin -notmatch 'Stop-Programme \$Exe\s*(#|$|\})' }
}
catch {
    $script:Echoues += "Arrêt inattendu : $($_.Exception.Message)"
    Write-Host "  ÉCHEC  Arrêt inattendu : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
}
finally {
    # Seuls les programmes d'essai lancés ici sont fermés, puis le dossier de test est retiré
    foreach ($p in $script:Lances) { try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(3000) } } catch {} }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$total = $script:Reussis + $script:Echoues.Count
if ($script:Echoues.Count) {
    Write-Host "$($script:Echoues.Count) échec(s) sur $total cas :" -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Les $total cas sont réussis." -ForegroundColor Green
exit 0
