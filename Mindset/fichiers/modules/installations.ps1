# Mindset : où sont les applis, et ce qu'on peut en faire (installer, mettre à jour, prendre en charge, ouvrir, désinstaller).
# Chargé par Mindset.ps1 après applis.ps1 et taches.ps1.
#
# Une appli gérée par Mindset :
#   programme   C:\Program Files\Mindset\<Appli>     (seul un administrateur peut y écrire : installer-admin.ps1)
#   données     %LOCALAPPDATA%\Mindset\<Appli>      (l'appli y déplace elle-même ses anciennes données)
#   aucun raccourci direct ni lancement au démarrage à elle : tout passe par Mindset.
# Une copie trouvée sur le PC (téléchargée avant Mindset, ou un dossier de travail) peut être ouverte telle quelle,
# ou prise en charge : Mindset installe une copie gérée, retire les raccourcis et démarrages de l'ancienne, puis
# supprime l'ancienne copie (seulement les fichiers livrés avec l'appli, jamais un dossier de travail).

$InstallFile = Join-Path $DataDir 'installations.json'
$TelechargementsDir = Join-Path $DataDir 'telechargements'
$ClePublique = Join-Path $AppDir 'cle-publique.xml'
$script:Publications = @{}   # id -> dernière version publiée (ou erreur)
$script:Occupe = @{}         # id -> texte de l'opération en cours
$script:Messages = @{}       # id -> dernier message affiché sur la carte
$script:EnCours = @{}        # id -> installation en cours (version, zip, ancienne copie)

function Get-DossierGere($Appli) { Join-Path $RacineProgrammes $Appli.Nom }

# Dossier de données d'une appli : celui de la suite si elle est gérée et l'a déjà adopté, sinon l'ancien
function Get-DossierDonnees($Appli) {
    $inst = (Read-Installations)[$Appli.Id]
    $suite = Join-Path $SuiteDir $Appli.Nom
    if ($inst -and $inst.Gere -and (Test-Path -LiteralPath $suite)) { $suite } else { $Appli.Donnees }
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
    # installations.json est modifiable par n'importe quel programme : une installation « gérée » n'est crue que dans le
    # dossier protégé des programmes (un Mindset administrateur ne lance jamais un programme qu'on aurait glissé ailleurs)
    if ($r -and $r.Gere -and $r.Dossier -ine (Get-DossierGere $Appli)) { Write-Log "installations.json : $($Appli.Nom) « géré » hors de $(Get-DossierGere $Appli), ignoré"; $r = $null }
    if ($r -and (Test-DossierAppli $r.Dossier $Appli)) {
        return @{ Dossier = $r.Dossier; Gere = $r.Gere; Version = (Get-VersionDans $r.Dossier $Appli) }
    }
    if ($r) { Save-Installation $Appli.Id $null $false; if ($r.Gere) { Set-SuiteAppli $Appli.Id $null } }
    # Copie gérée présente mais oubliée (installations.json effacé)
    $g = Get-DossierGere $Appli
    if (Test-DossierAppli $g $Appli) { Save-Installation $Appli.Id $g $true; Set-SuiteAppli $Appli.Id $g; return @{ Dossier = $g; Gere = $true; Version = (Get-VersionDans $g $Appli) } }
    $null
}

# ---------------------------------------------------------------------------
# Copies déjà présentes sur le PC
# ---------------------------------------------------------------------------
function Get-LieuxRaccourcis {
    @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'),
      [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('Startup')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}

# Raccourcis (.lnk) qui lancent cette appli, quelle que soit la copie
function Get-RaccourcisAppli($Appli) {
    $sh = New-Object -ComObject WScript.Shell
    foreach ($l in Get-LieuxRaccourcis) {
        foreach ($lnk in @(Get-ChildItem -LiteralPath $l -Filter *.lnk -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
            try { $t = $sh.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
            if ($t -and [IO.Path]::GetFileName($t) -ieq $Appli.Exe) { [pscustomobject]@{ Lien = $lnk.FullName; Cible = $t } }
        }
    }
}

# Entrées « lancer au démarrage » de l'utilisateur qui lancent cette appli
function Get-DemarragesAppli($Appli) {
    try { $run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop } catch { return }
    foreach ($p in $run.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        if ($p.Value -is [string] -and $p.Value -match ('^"?([^"]*\\' + [regex]::Escape($Appli.Exe) + ')"?')) { [pscustomobject]@{ Nom = $p.Name; Cible = $Matches[1] } }
    }
}

# Une copie déjà présente : raccourcis, démarrage, programme ouvert, puis Téléchargements, Bureau et Documents
function Find-InstallationExistante($Appli) {
    $candidats = New-Object System.Collections.Generic.List[string]
    foreach ($r in @(Get-RaccourcisAppli $Appli)) { $candidats.Add((Split-Path $r.Cible -Parent)) }
    foreach ($r in @(Get-DemarragesAppli $Appli)) { $candidats.Add((Split-Path $r.Cible -Parent)) }
    foreach ($pr in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Appli.Exe)) -ErrorAction SilentlyContinue)) {
        try { if ($pr.Path) { $candidats.Add((Split-Path $pr.Path -Parent)) } } catch {}   # (illisible si elle tourne en administrateur)
    }
    $telech = Join-Path $env:USERPROFILE 'Downloads'
    foreach ($l in @($telech, [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'))) {
        if (-not $l -or -not (Test-Path -LiteralPath $l)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $l -Filter $Appli.Exe -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 5)) { $candidats.Add($f.DirectoryName) }
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
function Open-Appli($Appli, [switch]$Demarrage) {
    $inst = Get-Installation $Appli
    if (-not $inst) { return }
    # En cours d'installation : pas maintenant (elle démarrerait avec les anciens fichiers) ; elle est relancée à la fin
    if ($script:Occupe[$Appli.Id]) { $script:ARelancer[$Appli.Id] = $true; return }
    if (Test-AppliOuverte $Appli) {
        if ($Demarrage) { return }
        # Chaque appli a sa façon d'être réveillée : un fichier qu'elle surveille (Nevermind) ou un signal (Evermind).
        # Relancer son .exe marcherait aussi, mais pour Nevermind cela redemanderait l'autorisation de Windows.
        try { [void][MSNative]::AllowSetForegroundWindow(-1) } catch {}
        if ($Appli.AfficherSignal) {
            try { $ev = [System.Threading.EventWaitHandle]::OpenExisting($Appli.AfficherSignal); [void]$ev.Set(); $ev.Dispose(); return } catch {}
        }
        if ($Appli.AfficherFichier) {
            try { $f = Join-Path (Get-DossierDonnees $Appli) $Appli.AfficherFichier; New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null; [IO.File]::WriteAllText($f, [string]$PID); return } catch {}
        }
    }
    $exe = Join-Path $inst.Dossier $Appli.Exe
    # Mindset administrateur : seule une appli administrateur installée par lui (dossier protégé) hérite de ses droits.
    # Les autres (Evermind, une copie de travail) sont lancées avec les droits de l'utilisateur.
    $avecDroits = (Test-AppliAdmin $Appli $inst) -and $inst.Gere -and $inst.Dossier -ieq (Get-DossierGere $Appli)
    try {
        if ($MindsetAdmin -and -not $avecDroits) { [void][MSLanceur]::SansAdmin($exe, $(if ($Demarrage) { '-Demarrage' } else { '' }), $inst.Dossier) }
        else {
            $p = @{ FilePath = $exe; WorkingDirectory = $inst.Dossier; ErrorAction = 'Stop' }
            if ($Demarrage) { $p.ArgumentList = '-Demarrage' }
            Start-Process @p
        }
    } catch { Write-Log "Lancement de $($Appli.Nom) : $($_.Exception.Message)" }   # (par exemple : autorisation de Windows refusée)
}

# ---------------------------------------------------------------------------
# Versions publiées (au démarrage, puis toutes les 6 heures)
# ---------------------------------------------------------------------------
function Update-Publications {
    foreach ($a in $Applis) {
        Start-Tache { $p = $args[0]; Get-Publication $p.Depot $p.Zip } @{ Depot = $a.Depot; Zip = $a.Zip } ([scriptblock]::Create(@"
            param(`$Resultat, `$Erreur)
            `$script:Publications['$($a.Id)'] = if (`$Erreur) { @{ Erreur = `$Erreur } } else { `$Resultat }
            # GitHub limite les questions (60 par heure et par connexion) : refusé, on réessaie dans 30 minutes, pas dans 6 heures
            if ("`$Erreur `$(`$Resultat.Erreur)" -match '403|429') { `$script:DernieresPublications = (Get-Date).AddHours(-5.5) }
            Update-Cartes
            if (`$script:OngletParametres -eq 'maj') { Update-ListeVersions }
"@))
    }
}

# ---------------------------------------------------------------------------
# installer-admin.ps1 : une demande de Windows, puis le travail en administrateur ; $Fin reçoit (ok, message)
# ---------------------------------------------------------------------------
$script:AttentesAdmin = New-Object System.Collections.ArrayList

# Le mini-installateur : la tâche « \Mindset\Mindset (installation) » (installer-admin.ps1 -Action demande), en
# administrateur sans demande de Windows. Mindset écrit sa demande dans installation.demande (une à la fois : les
# suivantes attendent) et lit la réponse dans HKLM:\SOFTWARE\Mindset\Installation (écrite seulement par l'installateur).
$TacheInstallation = '\Mindset\Mindset (installation)'
$FichierDemande = Join-Path $DataDir 'installation.demande'
$script:DemandesEnAttente = New-Object System.Collections.ArrayList
function Test-TacheInstallation {
    if ($null -eq $script:TacheInstallationOk) {
        & "$env:SystemRoot\System32\schtasks.exe" /Query /TN $TacheInstallation 2>$null | Out-Null
        $script:TacheInstallationOk = ($LASTEXITCODE -eq 0)
    }
    $script:TacheInstallationOk
}

function Send-DemandeInstallation($D) {
    try {
        [IO.File]::WriteAllText($FichierDemande, (ConvertTo-Json -InputObject $D.Contenu -Compress), (New-Object Text.UTF8Encoding $false))
        $null = & "$env:SystemRoot\System32\schtasks.exe" /Run /TN $TacheInstallation 2>&1
        if ($LASTEXITCODE -ne 0) { throw "la tâche d'installation n'a pas démarré (code $LASTEXITCODE)" }
    } catch { & $D.Fin $false $_.Exception.Message; return $false }
    $D.Debut = Get-Date
    [void]$script:AttentesAdmin.Add(@{ Process = $null; Id = $D.Contenu.Id; Fin = $D.Fin; Debut = $D.Debut })
    $script:AdminTimer.Start()
    $true
}

function Invoke-Admin([string]$Action, [hashtable]$Parametres, [scriptblock]$Fin) {
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    if (-not $MindsetAdmin -and $Action -ne 'mindset' -and (Test-TacheInstallation)) {
        $c = @{ Id = [guid]::NewGuid().ToString('N'); Action = $Action }
        foreach ($k in $Parametres.Keys) { if ($null -ne $Parametres[$k] -and "$($Parametres[$k])" -ne '') { $c[$k] = [string]$Parametres[$k] } }
        $d = @{ Contenu = $c; Fin = $Fin }
        if (@($script:AttentesAdmin | Where-Object { $_.Id }).Count) { [void]$script:DemandesEnAttente.Add($d); return }
        [void](Send-DemandeInstallation $d)
        return
    }
    $rep = Join-Path $TelechargementsDir "admin-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $AppDir 'installer-admin.ps1')`"", '-Action', $Action, '-Resultat', "`"$rep`"")
    foreach ($k in $Parametres.Keys) { if ($null -ne $Parametres[$k] -and "$($Parametres[$k])" -ne '') { $a += @("-$k", "`"$($Parametres[$k])`"") } }
    try { $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -Verb RunAs -WindowStyle Hidden -WorkingDirectory $env:SystemRoot -PassThru -ErrorAction Stop }
    catch { & $Fin $false 'l''autorisation de Windows a été refusée.'; return }
    [void]$script:AttentesAdmin.Add(@{ Process = $proc; Reponse = $rep; Fin = $Fin; Debut = Get-Date })
    $script:AdminTimer.Start()
}

$script:AdminTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:AdminTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:AdminTimer.Add_Tick({
    foreach ($w in @($script:AttentesAdmin)) {
        $r = $null
        if ($w.Id) {
            # Demande passée par la tâche : sa réponse, reconnue à son numéro
            try { $r = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Mindset\Installation' -Name Resultat -ErrorAction Stop).Resultat | ConvertFrom-Json } catch {}
            if ($r -and $r.id -ne $w.Id) { $r = $null }
            if (-not $r -and ((Get-Date) - $w.Debut).TotalMinutes -lt 10) { continue }
            [void]$script:AttentesAdmin.Remove($w)
            try { if ($r) { & $w.Fin ([bool]$r.ok) ([string]$r.message) } else { & $w.Fin $false 'pas de réponse du mini-installateur (opération interrompue ?).' } } catch { Write-Log "Fin d'opération admin : $_" }
            # Demande suivante
            if ($script:DemandesEnAttente.Count) { $s = $script:DemandesEnAttente[0]; $script:DemandesEnAttente.RemoveAt(0); [void](Send-DemandeInstallation $s) }
            continue
        }
        $fini = $false; try { $fini = $w.Process.HasExited } catch {}
        if (-not $fini -and ((Get-Date) - $w.Debut).TotalMinutes -lt 5) { continue }
        [void]$script:AttentesAdmin.Remove($w)
        try { $r = [IO.File]::ReadAllText($w.Reponse, [Text.Encoding]::UTF8) | ConvertFrom-Json; Remove-Item -LiteralPath $w.Reponse -Force } catch {}
        try {
            if ($r) { & $w.Fin ([bool]$r.ok) ([string]$r.message) } else { & $w.Fin $false 'pas de réponse (opération interrompue ?).' }
        } catch { Write-Log "Fin d'opération admin : $_" }
    }
    if (-not $script:AttentesAdmin.Count) { $script:AdminTimer.Stop() }
})

# ---------------------------------------------------------------------------
# Installer, mettre à jour, prendre en charge
# ---------------------------------------------------------------------------
# $AncienDossier : copie existante qu'on prend en charge
function Start-InstallAppli($Appli, [string]$AncienDossier) {
    if ($script:Occupe[$Appli.Id]) { return }
    # Ouverte, ou qui s'ouvre avec Mindset : relancée une fois installée (l'installation la ferme)
    $script:ARelancer[$Appli.Id] = [bool]((Test-AppliOuverte $Appli) -or (Get-DemarrageAppli $Appli.Id))
    $script:Occupe[$Appli.Id] = 'Téléchargement...'
    $script:Messages.Remove($Appli.Id)
    Update-Cartes
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    $params = @{ Depot = $Appli.Depot; Zip = $Appli.Zip; Cle = $ClePublique; Dossier = $TelechargementsDir; Id = $Appli.Id }
    Start-Tache {
        $p = $args[0]
        $pub = Get-Publication $p.Depot $p.Zip
        if ($pub.Erreur) { throw $pub.Erreur }
        if (-not $pub.UrlSig) { throw "La version $($pub.Version) n'est pas signée : Mindset ne l'installera pas." }
        $zip = Get-Octets $pub.UrlZip
        $sig = Get-Octets $pub.UrlSig
        if (-not (Test-Signature $zip $sig $p.Cle)) { throw 'La signature du fichier téléchargé est invalide : rien n''a été installé.' }
        $fz = Join-Path $p.Dossier "$($p.Id).zip"; $fs = "$fz.sig"
        [IO.File]::WriteAllBytes($fz, $zip); [IO.File]::WriteAllBytes($fs, $sig)
        @{ Version = $pub.Version; Zip = $fz; Sig = $fs }
    } $params ([scriptblock]::Create(@"
        param(`$Resultat, `$Erreur)
        Complete-Telechargement (Get-Appli '$($Appli.Id)') `$Resultat `$Erreur '$($AncienDossier -replace "'", "''")'
"@))
}

function Complete-Telechargement($Appli, $Resultat, $Erreur, [string]$AncienDossier) {
    if ($Erreur -or -not $Resultat) { Stop-Operation $Appli "Échec : $Erreur"; return }
    $script:Occupe[$Appli.Id] = $(if (-not $MindsetAdmin -and (Test-TacheInstallation)) { 'Installation...' } else { 'Installation (accepte la demande de Windows)...' })
    Update-Cartes
    $script:EnCours[$Appli.Id] = @{ Appli = $Appli; Ancien = $AncienDossier; Version = $Resultat.Version; Zip = $Resultat.Zip }
    $p = [ordered]@{ Zip = $Resultat.Zip; Signature = $Resultat.Sig; Destination = (Get-DossierGere $Appli); DossierZip = $Appli.DossierZip; Exe = $Appli.Exe }
    if ($AncienDossier) { $p.AncienExe = Join-Path $AncienDossier $Appli.Exe }
    # Appli avec une partie administrateur (Nevermind) : sa tâche planifiée est créée ou remise à jour à chaque installation
    if ($Appli.Aide) { $p.TacheAide = $Appli.Aide; $p.ExeAide = $Appli.AideExe; $p.Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    Invoke-Admin 'appli' $p ([scriptblock]::Create(@"
        param(`$Ok, `$Message)
        `$a = Get-Appli '$($Appli.Id)'
        if (`$Ok) { Complete-Installation `$a `$Message } else { Stop-Operation `$a "Échec : `$Message" }
"@))
}

function Complete-Installation($Appli, [string]$Dossier) {
    $c = $script:EnCours[$Appli.Id]; $script:EnCours.Remove($Appli.Id)
    $ancien = if ($c -and $c.Appli.Id -eq $Appli.Id) { $c.Ancien } else { '' }
    Save-Installation $Appli.Id $Dossier $true
    Set-SuiteAppli $Appli.Id $Dossier
    $notes = @(Remove-Doublons $Appli)
    if ($ancien) { $notes += Remove-AncienneCopie $Appli $ancien $c.Zip }
    foreach ($f in @(Get-ChildItem -LiteralPath $TelechargementsDir -Filter "$($Appli.Id).*" -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    Write-Log "$($Appli.Nom) $($c.Version) installé dans $Dossier$(if ($ancien) { " (pris en charge depuis $ancien)" })"
    $fin = (@("$($Appli.Nom) $($c.Version) est installé.") + $notes | Where-Object { $_ }) -join ' '
    Move-DonneesAppli $Appli $fin
}

# Les données d'avant (dossier de l'appli autonome, ou %LOCALAPPDATA%\Mindset si la suite était sur C:) rejoignent
# celles de la suite. Sur le même disque, l'appli renomme elle-même le dossier d'un bloc au lancement ; d'un disque à
# l'autre, Mindset copie, vérifie (nombre de fichiers et taille), puis supprime l'ancien, avant le premier lancement.
function Move-DonneesAppli($Appli, [string]$Message) {
    $dest = Join-Path $SuiteDir $Appli.Nom
    $src = @((Join-Path $env:LOCALAPPDATA "Mindset\$($Appli.Nom)"), $Appli.Donnees) | Where-Object { $_ -ine $dest -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ((Test-Path -LiteralPath $dest) -or -not $src -or ([IO.Path]::GetPathRoot($src) -ieq [IO.Path]::GetPathRoot($dest))) { Stop-Operation $Appli $Message; return }
    if (-not (Test-DossierSur $src)) { Write-Log "Données de $($Appli.Nom) : $src est un lien vers un autre dossier, pas déplacé"; Stop-Operation $Appli $Message; return }
    $taille = (Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $script:Occupe[$Appli.Id] = "Déplacement des données vers $dest ({0:N1} Go)..." -f ($taille / 1GB)
    Update-Cartes
    Start-Tache {
        $p = $args[0]
        $mesure = { param($d) $f = @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue); "$($f.Count)|$(($f | Measure-Object Length -Sum).Sum)" }
        New-Item -ItemType Directory -Force -Path (Split-Path $p.Dest) | Out-Null
        $tmp = "$($p.Dest).copie"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        robocopy $p.Src $tmp /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8 -or (& $mesure $p.Src) -ne (& $mesure $tmp)) {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            throw "la copie de $($p.Src) n'est pas complète : les données restent à leur place."
        }
        [IO.Directory]::Move($tmp, $p.Dest)   # (même disque : renommage d'un bloc, le dossier n'apparaît qu'une fois complet)
        try { Remove-Item -LiteralPath $p.Src -Recurse -Force -ErrorAction Stop; '' }
        catch { "L'ancien dossier $($p.Src) n'a pas pu être supprimé (un fichier est ouvert) : supprime-le plus tard." }
    } @{ Src = $src; Dest = $dest } ([scriptblock]::Create(@"
        param(`$Resultat, `$Erreur)
        `$a = Get-Appli '$($Appli.Id)'
        `$m = '$($Message -replace "'", "''")'
        if (`$Erreur) { Write-Log "Données de `$(`$a.Nom) : `$Erreur"; Stop-Operation `$a "`$m Attention : `$Erreur" }
        else { Write-Log "Données de `$(`$a.Nom) déplacées : $($src -replace "'", "''") -> $($dest -replace "'", "''")"; Stop-Operation `$a (("`$m Ses données sont maintenant dans $($dest -replace "'", "''"). `$Resultat").Trim()) }
"@))
}

# Plus aucun accès direct : raccourcis et lancement au démarrage de l'appli (toutes copies) sont retirés.
# Le lancement au démarrage d'une appli qui en a besoin (les rappels d'Evermind) est repris par Mindset.
function Remove-Doublons($Appli) {
    $n = 0
    foreach ($r in @(Get-RaccourcisAppli $Appli)) { try { Remove-Item -LiteralPath $r.Lien -Force -ErrorAction Stop; $n++ } catch { Write-Log "Raccourci non retiré : $($r.Lien)" } }
    $demarrage = @(Get-DemarragesAppli $Appli)
    foreach ($d in $demarrage) { try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $d.Nom -ErrorAction Stop } catch {} }
    # (son ancien lancement avec Windows n'est pas repris : l'interrupteur « S'ouvre avec Mindset » reste éteint, à chacun de l'allumer)
    if ($n) { "$n raccourci$(if ($n -gt 1) { 's' }) direct$(if ($n -gt 1) { 's' }) retiré$(if ($n -gt 1) { 's' }) : $($Appli.Nom) s'ouvre maintenant depuis Mindset." }
}

# Un dossier que Mindset (peut-être administrateur) accepte de vider : ni dossier de Windows ou de programmes, ni point de
# jonction ou lien symbolique (sur lui ou sur un de ses parents), qui pourrait renvoyer ailleurs que là où il semble être
function Test-DossierSur([string]$Dossier) {
    $d = [IO.Path]::GetFullPath($Dossier.TrimEnd('\'))
    foreach ($interdit in $env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) { if ($interdit -and ($d -ieq $interdit -or $d -like "$interdit\*")) { return $false } }
    $x = $d
    while ($x -and $x.Length -gt 3) {
        try { if ((Get-Item -LiteralPath $x -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false } } catch { return $false }
        $x = Split-Path $x -Parent
    }
    $true
}

# Dossier de travail (dépôt Git dans la copie ou son parent, comme D:\Projets\Evermind\Evermind) : Mindset ne le
# supprime jamais, et c'est la seule copie non gérée que les applis acceptent encore d'ouvrir sans Mindset
function Test-DossierTravail([string]$Dossier) {
    $Dossier -and ((Test-Path -LiteralPath (Join-Path $Dossier '.git')) -or (Test-Path -LiteralPath (Join-Path (Split-Path $Dossier -Parent) '.git')))
}

# L'ancienne copie, une fois prise en charge : seuls les fichiers livrés avec l'appli (ceux du zip) sont supprimés,
# puis les dossiers devenus vides. Jamais un dossier de travail (Git), jamais dans les programmes de Mindset.
function Remove-AncienneCopie($Appli, [string]$Dossier, [string]$Zip) {
    $d = [IO.Path]::GetFullPath($Dossier.TrimEnd('\'))
    if ($d -like "$([IO.Path]::GetFullPath($RacineProgrammes))\*" -or $d -like "$([IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Mindset')))\*") { return '' }
    if (-not (Test-DossierSur $d)) { return "L'ancienne copie ($d) n'a pas été supprimée (dossier protégé ou lien vers un autre dossier)." }
    if (Test-DossierTravail $d) {
        return "L'ancienne copie ($d) est un dossier de travail : elle est gardée telle quelle."
    }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::OpenRead($Zip)
        $prefixe = $Appli.DossierZip + '\'
        $livres = @($za.Entries | ForEach-Object { $_.FullName.Replace('/', '\') } | Where-Object { $_.StartsWith($prefixe, [StringComparison]::OrdinalIgnoreCase) -and -not $_.EndsWith('\') } | ForEach-Object { $_.Substring($prefixe.Length) })
        $za.Dispose()
    } catch { return "L'ancienne copie ($d) n'a pas été supprimée (contenu du zip illisible)." }
    foreach ($rel in $livres) {
        $f = [IO.Path]::GetFullPath((Join-Path $d $rel))
        if ($f.StartsWith("$d\", [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $f -PathType Leaf)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch {} }
    }
    foreach ($sd in @(Get-ChildItem -LiteralPath $d -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
        if (-not @(Get-ChildItem -LiteralPath $sd.FullName -Force -ErrorAction SilentlyContinue).Count) { Remove-Item -LiteralPath $sd.FullName -Force -ErrorAction SilentlyContinue }
    }
    $reste = @(Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue)
    if (-not $reste.Count) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; return "L'ancienne copie ($d) a été supprimée." }
    "L'ancienne copie ($d) a été vidée de $($Appli.Nom) ; $($reste.Count) fichier$(if ($reste.Count -gt 1) { 's' }) qui n'en fai$(if ($reste.Count -gt 1) { 'saient' } else { 'sait' }) pas partie y reste$(if ($reste.Count -gt 1) { 'nt' })."
}

function Stop-Operation($Appli, [string]$Message) {
    $script:Occupe.Remove($Appli.Id)
    $script:Messages[$Appli.Id] = $Message
    Update-Trouvees
    Update-Cartes
    # Fermée par l'installation (ou demandée pendant) : relancée, cachée, puis accrochée si son onglet est affiché
    if ($script:ARelancer[$Appli.Id]) {
        $script:ARelancer.Remove($Appli.Id)
        $i = Get-Installation $Appli
        if ($i -and $i.Gere -and -not $EnTest) {
            if ($script:PageCourante -eq $Appli.Id) { Open-AppliIci $Appli.Id } else { Open-Appli $Appli -Demarrage }
        }
    }
}
$script:ARelancer = @{}

# ---------------------------------------------------------------------------
# « S'ouvre avec Mindset » (interrupteur des cartes de l'accueil) : l'appli démarre en arrière-plan quand Mindset s'ouvre,
# donc aussi au démarrage de Windows (Mindset.exe -Demarrage), voir Start-Demarrage dans mindset.ps1
# ---------------------------------------------------------------------------
# Nevermind avait sa propre tâche de démarrage : un Mindset administrateur la retire (une seule règle, la sienne ;
# éteinte au départ, comme pour toute appli : à chacun de l'allumer)
$TachesDemarrageAppli = @{ nevermind = @('Nevermind (démarrage)', 'OptiGame (démarrage)', 'Nexo (démarrage)') }

function Get-DemarrageAppli([string]$Id) { $Id -in @(Get-Setting 'Demarrage' @()) }
function Set-DemarrageAppli([string]$Id, [bool]$Oui) {
    $l = @(@(Get-Setting 'Demarrage' @()) | Where-Object { $_ -ne $Id })
    if ($Oui) { $l += $Id }
    Set-Setting 'Demarrage' $l
    if ($MindsetAdmin) { Remove-TachesDemarrageAppli $Id }
}

function Remove-TachesDemarrageAppli([string]$Id) {
    foreach ($n in @($TachesDemarrageAppli[$Id] | Where-Object { $_ })) {
        & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN "\$n" /F 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "Tâche « $n » retirée : le démarrage de $Id se règle dans Mindset (S'ouvre avec Mindset)" }
    }
}

# Mindset administrateur : une appli gérée qui avait sa propre tâche de démarrage la perd ; son interrupteur
# « S'ouvre avec Mindset » n'est pas allumé pour autant (rien ne démarre sans que l'utilisateur l'ait choisi dans Mindset)
function Move-TachesDemarrage {
    if (-not $MindsetAdmin) { return }
    foreach ($id in @($TachesDemarrageAppli.Keys)) {
        $a = Get-Appli $id; $i = if ($a) { Get-Installation $a } else { $null }
        if ($i -and $i.Gere) { Remove-TachesDemarrageAppli $id }
    }
}

# ---------------------------------------------------------------------------
# Désinstaller (seulement une installation gérée : jamais une copie trouvée sur le PC)
# ---------------------------------------------------------------------------
function Start-DesinstallAppli($Appli) {
    $inst = Get-Installation $Appli
    if (-not $inst -or -not $inst.Gere -or $inst.Dossier -ine (Get-DossierGere $Appli)) { return }
    if ($Appli.Desinstalleur) {
        # Nevermind a son propre désinstalleur : il remet les réglages de Windows comme avant, puis supprime ses fichiers
        try { Start-Process -FilePath (Join-Path $inst.Dossier $Appli.Desinstalleur) -WorkingDirectory $inst.Dossier -ErrorAction Stop } catch { Stop-Operation $Appli 'Désinstallation annulée.'; return }
        $script:Occupe[$Appli.Id] = 'Désinstallation (suis les étapes de son désinstalleur)...'
        $script:AttenteDesinstall = @{ Appli = $Appli; Dossier = $inst.Dossier; Debut = Get-Date }
        $script:DesinstallTimer.Start()
        Update-Cartes
        return
    }
    $script:Occupe[$Appli.Id] = 'Désinstallation (accepte la demande de Windows)...'
    Update-Cartes
    Invoke-Admin 'supprimer' @{ Destination = $inst.Dossier; Exe = $Appli.Exe } ([scriptblock]::Create(@"
        param(`$Ok, `$Message)
        `$a = Get-Appli '$($Appli.Id)'
        if (`$Ok) { Complete-Desinstallation `$a } else { Stop-Operation `$a "Désinstallation impossible : `$Message" }
"@))
}

function Complete-Desinstallation($Appli) {
    Save-Installation $Appli.Id $null $false
    Set-SuiteAppli $Appli.Id $null
    Set-DemarrageAppli $Appli.Id $false
    Write-Log "$($Appli.Nom) désinstallé"
    Stop-Operation $Appli "$($Appli.Nom) est désinstallé. Ses données sont gardées dans $(Join-Path $SuiteDir $Appli.Nom) : une réinstallation les retrouve."
}

$script:DesinstallTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DesinstallTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:DesinstallTimer.Add_Tick({
    $w = $script:AttenteDesinstall
    if (-not $w) { $script:DesinstallTimer.Stop(); return }
    if (-not (Test-Path -LiteralPath (Join-Path $w.Dossier $w.Appli.Exe))) {
        $script:DesinstallTimer.Stop(); $script:AttenteDesinstall = $null
        Complete-Desinstallation $w.Appli
    } elseif (((Get-Date) - $w.Debut).TotalMinutes -gt 10) {
        $script:DesinstallTimer.Stop(); $script:AttenteDesinstall = $null
        Stop-Operation $w.Appli 'Désinstallation annulée ou pas terminée.'
    }
})

# Utiliser une copie trouvée telle quelle (Mindset l'ouvre, sans la gérer)
function Use-InstallationTrouvee($Appli, [string]$Dossier) {
    if (-not (Test-DossierAppli $Dossier $Appli)) { Stop-Operation $Appli "Ce dossier ne contient pas $($Appli.Nom)."; return }
    Save-Installation $Appli.Id $Dossier $false
    Stop-Operation $Appli "Mindset ouvrira la copie de $Dossier. Elle se met à jour toute seule et garde son propre thème."
}
