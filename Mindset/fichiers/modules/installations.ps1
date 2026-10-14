# Mindset : où sont les applis, et ce qu'on peut en faire (installer, mettre à jour, prendre en charge, ouvrir, désinstaller).
# Chargé par Mindset.ps1 après applis.ps1 et taches.ps1.
#
# Deux sortes d'installations :
#   gérée     installée par Mindset depuis un zip signé, dans son dossier à lui :
#               Program Files\Mindset\<Appli>        pour une appli qui tourne en administrateur (Nevermind)
#               %LOCALAPPDATA%\Programs\Mindset\<Appli>  pour les autres (Evermind se met ainsi à jour lui-même)
#             Mindset la met à jour, peut la désinstaller, et elle suit le thème de la suite.
#   trouvée   une copie déjà présente sur le PC (téléchargée avant Mindset, ou un dossier de travail).
#             Mindset l'ouvre, mais ne la modifie et ne la supprime jamais.
#             « Prendre en charge » installe une copie gérée à la place et y fait pointer raccourcis et démarrage.

$InstallFile = Join-Path $DataDir 'installations.json'
$TelechargementsDir = Join-Path $DataDir 'telechargements'
$ClePublique = Join-Path $AppDir 'cle-publique.xml'
$script:Publications = @{}   # id -> dernière version publiée (ou erreur)
$script:Occupe = @{}         # id -> texte de l'opération en cours

function Get-DossierGere($Appli) {
    if ($Appli.Admin) { Join-Path $env:ProgramFiles "Mindset\$($Appli.Nom)" }
    else { Join-Path $env:LOCALAPPDATA "Programs\Mindset\$($Appli.Nom)" }
}

function Read-Installations {
    $r = @{}
    if (Test-Path -LiteralPath $InstallFile) {
        try {
            $j = [IO.File]::ReadAllText($InstallFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $r[$p.Name] = @{ Dossier = [string]$p.Value.dossier; Gere = [bool]$p.Value.gere } }
        } catch { Write-Log "installations.json illisible : $_" }
    }
    $r
}

function Save-Installation([string]$Id, [string]$Dossier, [bool]$Gere) {
    $r = Read-Installations
    if ($Dossier) { $r[$Id] = @{ Dossier = $Dossier; Gere = $Gere } } else { $r.Remove($Id) }
    $o = [ordered]@{}; foreach ($k in $r.Keys) { $o[$k] = @{ dossier = $r[$k].Dossier; gere = $r[$k].Gere } }
    if (-not $EnTest) { [IO.File]::WriteAllText($InstallFile, ($o | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false)) }
}

function Get-VersionDans([string]$Dossier, $Appli) {
    $f = Join-Path $Dossier $Appli.Script
    try { if ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) -match "(?m)^\`$AppVersion\s*=\s*'([\d.]+)'") { return $Matches[1] } } catch {}
    $null
}

function Test-DossierAppli([string]$Dossier, $Appli) {
    $Dossier -and (Test-Path -LiteralPath (Join-Path $Dossier $Appli.Exe)) -and (Test-Path -LiteralPath (Join-Path $Dossier $Appli.Script))
}

# L'installation connue d'une appli : @{ Dossier; Gere; Version } ou $null
function Get-Installation($Appli) {
    $r = (Read-Installations)[$Appli.Id]
    if ($r -and (Test-DossierAppli $r.Dossier $Appli)) {
        return @{ Dossier = $r.Dossier; Gere = $r.Gere; Version = (Get-VersionDans $r.Dossier $Appli) }
    }
    if ($r) { Save-Installation $Appli.Id $null $false; if ($r.Gere) { Set-SuiteAppli $Appli.Id $null } }
    # Copie gérée présente mais oubliée (installations.json effacé)
    $g = Get-DossierGere $Appli
    if (Test-DossierAppli $g $Appli) { Save-Installation $Appli.Id $g $true; return @{ Dossier = $g; Gere = $true; Version = (Get-VersionDans $g $Appli) } }
    $null
}

# Copie déjà présente sur le PC : raccourcis (Bureau, menu Démarrer), lancement au démarrage, programme ouvert
function Find-InstallationExistante($Appli) {
    $candidats = New-Object System.Collections.Generic.List[string]
    $sh = New-Object -ComObject WScript.Shell
    $lieux = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'),
               [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('Startup'))
    foreach ($l in $lieux) {
        if (-not $l -or -not (Test-Path -LiteralPath $l)) { continue }
        foreach ($lnk in @(Get-ChildItem -LiteralPath $l -Filter *.lnk -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
            try { $t = $sh.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
            if ($t -and [IO.Path]::GetFileName($t) -ieq $Appli.Exe) { $candidats.Add((Split-Path $t -Parent)) }
        }
    }
    try {
        $run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop
        foreach ($p in $run.PSObject.Properties) {
            if ($p.Value -is [string] -and $p.Value -match '^"?([^"]+\\' + [regex]::Escape($Appli.Exe) + ')"?') { $candidats.Add((Split-Path $Matches[1] -Parent)) }
        }
    } catch {}
    foreach ($pr in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Appli.Exe)) -ErrorAction SilentlyContinue)) {
        try { if ($pr.Path) { $candidats.Add((Split-Path $pr.Path -Parent)) } } catch {}   # (illisible si elle tourne en administrateur)
    }
    $gere = Get-DossierGere $Appli
    foreach ($c in $candidats | Select-Object -Unique) {
        if ($c -ine $gere -and (Test-DossierAppli $c $Appli)) { return $c }
    }
    $null
}

# ---------------------------------------------------------------------------
# Ouvrir : lancer l'appli, ou ramener sa fenêtre si elle tourne déjà
# ---------------------------------------------------------------------------
function Open-Appli($Appli) {
    $inst = Get-Installation $Appli
    if (-not $inst) { return }
    if (Test-AppliOuverte $Appli) {
        # Chaque appli a sa façon d'être réveillée : un fichier qu'elle surveille (Nevermind) ou un signal (Evermind).
        # Relancer son .exe marcherait aussi, mais pour Nevermind cela redemanderait l'autorisation de Windows.
        try { [void][MSNative]::AllowSetForegroundWindow(-1) } catch {}
        if ($Appli.AfficherSignal) {
            try { $ev = [System.Threading.EventWaitHandle]::OpenExisting($Appli.AfficherSignal); [void]$ev.Set(); $ev.Dispose(); return } catch {}
        }
        if ($Appli.AfficherFichier) {
            try { New-Item -ItemType Directory -Force -Path (Split-Path $Appli.AfficherFichier) | Out-Null; [IO.File]::WriteAllText($Appli.AfficherFichier, [string]$PID); return } catch {}
        }
    }
    try { Start-Process -FilePath (Join-Path $inst.Dossier $Appli.Exe) -WorkingDirectory $inst.Dossier -ErrorAction Stop }
    catch { Write-Log "Lancement de $($Appli.Nom) : $($_.Exception.Message)" }   # (par exemple : autorisation de Windows refusée)
}

# ---------------------------------------------------------------------------
# Versions publiées (au démarrage, puis toutes les 6 heures)
# ---------------------------------------------------------------------------
function Update-Publications {
    foreach ($a in $Applis) {
        Start-Tache { $p = $args[0]; Get-Publication $p.Depot $p.Zip } @{ Depot = $a.Depot; Zip = $a.Zip } ([scriptblock]::Create(@"
            param(`$Resultat, `$Erreur)
            `$script:Publications['$($a.Id)'] = if (`$Erreur) { @{ Erreur = `$Erreur } } else { `$Resultat }
            Update-Cartes
"@))
    }
}

# ---------------------------------------------------------------------------
# Installer, mettre à jour, prendre en charge
# ---------------------------------------------------------------------------
# $AncienDossier : copie trouvée qu'on prend en charge (ses raccourcis et son démarrage pointeront vers la nouvelle)
function Start-InstallAppli($Appli, [string]$AncienDossier) {
    if ($script:Occupe[$Appli.Id]) { return }
    $script:Occupe[$Appli.Id] = 'Téléchargement...'
    Update-Cartes
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    $params = @{ Depot = $Appli.Depot; Zip = $Appli.Zip; Cle = $ClePublique; Dossier = $TelechargementsDir; Id = $Appli.Id }
    Start-Tache {
        $p = $args[0]
        $pub = Get-Publication $p.Depot $p.Zip
        if ($pub.Erreur) { throw $pub.Erreur }
        if (-not $pub.UrlSig) { throw "La version $($pub.Version) n'est pas signée : Mindset ne l'installera pas. Il faut publier sa signature ($($p.Zip).sig)." }
        $zip = Get-Octets $pub.UrlZip
        $sig = Get-Octets $pub.UrlSig
        if (-not (Test-Signature $zip $sig $p.Cle)) { throw 'La signature du fichier téléchargé est invalide : rien n''a été installé.' }
        $fz = Join-Path $p.Dossier "$($p.Id).zip"; $fs = "$fz.sig"
        [IO.File]::WriteAllBytes($fz, $zip); [IO.File]::WriteAllBytes($fs, $sig)
        @{ Version = $pub.Version; Zip = $fz; Sig = $fs }
    } $params ([scriptblock]::Create(@"
        param(`$Resultat, `$Erreur)
        Complete-Telechargement (`$Applis | Where-Object Id -eq '$($Appli.Id)') `$Resultat `$Erreur '$($AncienDossier -replace "'", "''")'
"@))
}

function Complete-Telechargement($Appli, $Resultat, $Erreur, [string]$AncienDossier) {
    if ($Erreur -or -not $Resultat) { Stop-Operation $Appli "Échec : $Erreur"; return }
    $dest = Get-DossierGere $Appli
    $ancienExe = if ($AncienDossier) { Join-Path $AncienDossier $Appli.Exe } else { '' }
    if ($Appli.Admin) {
        # Program Files : une demande de Windows, puis installer-admin.ps1 vérifie et installe en administrateur
        $script:Occupe[$Appli.Id] = 'Installation (accepte la demande de Windows)...'
        Update-Cartes
        $rep = Join-Path $TelechargementsDir "$($Appli.Id).resultat.json"
        Remove-Item -LiteralPath $rep -Force -ErrorAction SilentlyContinue
        $argsAdmin = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $AppDir 'installer-admin.ps1')`"",
            '-Zip', "`"$($Resultat.Zip)`"", '-Signature', "`"$($Resultat.Sig)`"", '-Destination', "`"$dest`"",
            '-DossierZip', "`"$($Appli.DossierZip)`"", '-Exe', "`"$($Appli.Exe)`"", '-Resultat', "`"$rep`"")
        if ($ancienExe) { $argsAdmin += @('-AncienExe', "`"$ancienExe`"") }
        try { $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argsAdmin -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop }
        catch { Stop-Operation $Appli 'Installation annulée : l''autorisation de Windows a été refusée.'; return }
        $script:AttenteAdmin = @{ Appli = $Appli; Process = $proc; Reponse = $rep; Ancien = $AncienDossier; Version = $Resultat.Version; Debut = Get-Date }
        $script:AdminTimer.Start()
    } else {
        $script:Occupe[$Appli.Id] = 'Installation...'
        Update-Cartes
        # L'appli tourne avec les mêmes droits que Mindset : on peut la fermer (confirmation demandée avant)
        Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Appli.Exe)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $params = @{ Zip = $Resultat.Zip; Sig = $Resultat.Sig; Cle = $ClePublique; Dest = $dest; DossierZip = $Appli.DossierZip; Exe = $Appli.Exe }
        Start-Tache {
            $p = $args[0]
            Start-Sleep -Milliseconds 800
            Install-Paquet -Zip ([IO.File]::ReadAllBytes($p.Zip)) -Signature ([IO.File]::ReadAllBytes($p.Sig)) -ClePublique $p.Cle -Destination $p.Dest -DossierZip $p.DossierZip -Exe $p.Exe
        } $params ([scriptblock]::Create(@"
            param(`$Resultat, `$Erreur)
            `$a = `$Applis | Where-Object Id -eq '$($Appli.Id)'
            if (`$Erreur) { Stop-Operation `$a "Échec : `$Erreur" } else { Complete-Installation `$a `$Resultat '$($AncienDossier -replace "'", "''")' '$($Resultat.Version)' }
"@))
    }
}

# Fin de l'installation en administrateur : installer-admin.ps1 a écrit sa réponse
$script:AdminTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:AdminTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:AdminTimer.Add_Tick({
    $w = $script:AttenteAdmin
    if (-not $w) { $script:AdminTimer.Stop(); return }
    $fini = $false; try { $fini = $w.Process.HasExited } catch {}
    if (-not $fini -and ((Get-Date) - $w.Debut).TotalMinutes -lt 5) { return }
    $script:AdminTimer.Stop(); $script:AttenteAdmin = $null
    $r = $null
    try { $r = [IO.File]::ReadAllText($w.Reponse, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
    if ($r -and $r.ok) { Complete-Installation $w.Appli ([string]$r.message) $w.Ancien $w.Version }
    elseif ($r) { Stop-Operation $w.Appli "Échec : $($r.message)" }
    else { Stop-Operation $w.Appli 'Échec : l''installation en administrateur n''a pas répondu.' }
})

function Complete-Installation($Appli, [string]$Dossier, [string]$AncienDossier, [string]$Version) {
    Save-Installation $Appli.Id $Dossier $true
    Set-SuiteAppli $Appli.Id $Dossier
    if ($AncienDossier) { Move-Raccourcis $Appli $AncienDossier $Dossier }
    foreach ($f in @(Get-ChildItem -LiteralPath $TelechargementsDir -Filter "$($Appli.Id).*" -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    Write-Log "$($Appli.Nom) $Version installé dans $Dossier$(if ($AncienDossier) { " (pris en charge depuis $AncienDossier)" })"
    $msg = "$($Appli.Nom) $Version est installé."
    if ($AncienDossier) { $msg += " L'ancienne copie ($AncienDossier) n'est plus utilisée : tu peux la supprimer si ce n'est pas un dossier de travail." }
    Stop-Operation $Appli $msg
}

# Prise en charge : raccourcis et lancement au démarrage (utilisateur) passent de l'ancienne copie à la nouvelle
function Move-Raccourcis($Appli, [string]$Ancien, [string]$Nouveau) {
    $ancienExe = Join-Path $Ancien $Appli.Exe; $nouvelExe = Join-Path $Nouveau $Appli.Exe
    $sh = New-Object -ComObject WScript.Shell
    foreach ($l in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup'))) {
        foreach ($lnk in @(Get-ChildItem -LiteralPath $l -Filter *.lnk -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
            try {
                $s = $sh.CreateShortcut($lnk.FullName)
                if ($s.TargetPath -ieq $ancienExe) {
                    $s.TargetPath = $nouvelExe; $s.WorkingDirectory = $Nouveau
                    if ($s.IconLocation -like "$Ancien\*") { $s.IconLocation = $s.IconLocation.Replace($Ancien, $Nouveau) }
                    $s.Save()
                }
            } catch { Write-Log "Raccourci $($lnk.Name) : $_" }
        }
    }
    try {
        $cle = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $run = Get-ItemProperty $cle -ErrorAction Stop
        foreach ($p in $run.PSObject.Properties) {
            if ($p.Value -is [string] -and $p.Value.Trim('"') -ieq $ancienExe) { Set-ItemProperty -Path $cle -Name $p.Name -Value "`"$nouvelExe`"" }
        }
    } catch {}
}

function Stop-Operation($Appli, [string]$Message) {
    $script:Occupe.Remove($Appli.Id)
    $script:Messages[$Appli.Id] = $Message
    Update-Cartes
}

# ---------------------------------------------------------------------------
# Désinstaller (seulement une installation gérée : jamais une copie trouvée sur le PC)
# ---------------------------------------------------------------------------
function Start-DesinstallAppli($Appli) {
    $inst = Get-Installation $Appli
    if (-not $inst -or -not $inst.Gere -or $inst.Dossier -ine (Get-DossierGere $Appli)) { return }
    if ($Appli.Desinstalleur) {
        # Nevermind a son propre désinstalleur : il remet les réglages de Windows comme avant, puis supprime ses fichiers
        $d = Join-Path $inst.Dossier $Appli.Desinstalleur
        try { Start-Process -FilePath $d -WorkingDirectory $inst.Dossier -ErrorAction Stop } catch { Stop-Operation $Appli 'Désinstallation annulée.'; return }
        $script:Occupe[$Appli.Id] = 'Désinstallation (suis les étapes de son désinstalleur)...'
        $script:AttenteDesinstall = @{ Appli = $Appli; Dossier = $inst.Dossier; Debut = Get-Date }
        $script:DesinstallTimer.Start()
        Update-Cartes
        return
    }
    Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Appli.Exe)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
    $exe = Join-Path $inst.Dossier $Appli.Exe
    try { Remove-Item -LiteralPath $inst.Dossier -Recurse -Force -ErrorAction Stop }
    catch { Stop-Operation $Appli "Désinstallation incomplète : $($_.Exception.Message)"; return }
    # Raccourcis et lancement au démarrage qui pointaient vers elle
    try {
        $cle = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $run = Get-ItemProperty $cle -ErrorAction Stop
        foreach ($p in $run.PSObject.Properties) { if ($p.Value -is [string] -and $p.Value.Trim('"') -ieq $exe) { Remove-ItemProperty -Path $cle -Name $p.Name } }
    } catch {}
    $sh = New-Object -ComObject WScript.Shell
    foreach ($l in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        foreach ($lnk in @(Get-ChildItem -LiteralPath $l -Filter *.lnk -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
            try { if ($sh.CreateShortcut($lnk.FullName).TargetPath -ieq $exe) { Remove-Item -LiteralPath $lnk.FullName -Force } } catch {}
        }
    }
    Save-Installation $Appli.Id $null $false
    Set-SuiteAppli $Appli.Id $null
    Write-Log "$($Appli.Nom) désinstallé ($($inst.Dossier))"
    Stop-Operation $Appli "$($Appli.Nom) est désinstallé. Ses données (réglages, rendez-vous) sont gardées dans $($Appli.Donnees)."
}

$script:DesinstallTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DesinstallTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:DesinstallTimer.Add_Tick({
    $w = $script:AttenteDesinstall
    if (-not $w) { $script:DesinstallTimer.Stop(); return }
    if (-not (Test-Path -LiteralPath (Join-Path $w.Dossier $w.Appli.Exe))) {
        $script:DesinstallTimer.Stop(); $script:AttenteDesinstall = $null
        Save-Installation $w.Appli.Id $null $false
        Set-SuiteAppli $w.Appli.Id $null
        Write-Log "$($w.Appli.Nom) désinstallé par son désinstalleur"
        Stop-Operation $w.Appli "$($w.Appli.Nom) est désinstallé."
    } elseif (((Get-Date) - $w.Debut).TotalMinutes -gt 10) {
        $script:DesinstallTimer.Stop(); $script:AttenteDesinstall = $null
        Stop-Operation $w.Appli 'Désinstallation annulée ou pas terminée.'
    }
})

# Utiliser une copie trouvée telle quelle (Mindset l'ouvre, sans la gérer)
function Use-InstallationTrouvee($Appli, [string]$Dossier) {
    if (-not (Test-DossierAppli $Dossier $Appli)) { return }
    Save-Installation $Appli.Id $Dossier $false
    Stop-Operation $Appli "Mindset ouvrira la copie de $Dossier. Elle se met à jour toute seule et garde son propre thème."
}

$script:Messages = @{}   # id -> dernier message affiché sur la carte
