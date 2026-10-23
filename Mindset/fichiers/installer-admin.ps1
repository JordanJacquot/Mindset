<#
    Mindset : ce qui se fait dans Program Files\Mindset, lancé en administrateur par Mindset (une demande de Windows).
    Program Files n'est modifiable que par un administrateur : un programme sans droits ne peut pas y glisser un
    fichier que Nevermind (ou Mindset plus tard) exécuterait ensuite en administrateur.

    -Action appli           installe une appli à partir de son zip signé (vérifié ici, sur le contenu lu en mémoire)
                            -Zip -Signature -Destination -DossierZip -Exe [-AncienExe] [-TacheAide <nom> -ExeAide <exe> -Sid <utilisateur>]
                            -TacheAide : crée la tâche « \Mindset\<nom> » qui lance -ExeAide (à côté de -Exe) en administrateur
                            pour l'utilisateur -Sid (la partie administrateur de l'appli, lancée sans demande de Windows)
    -Action mindset         installe Mindset lui-même : copie -Source dans Program Files\Mindset\Mindset, ou dans
                            X:\Mindset\Programmes\Mindset avec -Disque X -Sid <utilisateur> (crée X:\Mindset protégé),
                            et l'inscrit dans « Applications installées » de Windows (-Version)
    -Action mindset-maj     met Mindset à jour : attend la fin du processus -AttendrePid, installe -Zip/-Signature (vérifiés ici)
                            dans -Destination (…\Mindset), puis relance Mindset sans les droits administrateur
    -Action supprimer       supprime une appli gérée (-Destination, -Exe) ou Mindset lui-même (-Destination ...\Mindset)
                            après avoir attendu la fin du processus -AttendrePid. Pour Mindset lui-même, ce n'est que le
                            chemin de secours (sans « Desinstaller Mindset.exe ») : ce qui reste est affiché ici.
    -Action demande         lancé par la tâche « \Mindset\Mindset (installation) » (Mindset sans droits) : lit la demande
                            dans -Demande (fichier JSON écrit par Mindset : Id, Action parmi appli, mindset-maj, supprimer,
                            taches, et ses paramètres). Le fichier est modifiable sans droits : tout y est revérifié comme
                            pour un lancement direct, seuls les zips signés s'installent, et l'utilisateur est toujours
                            celui de la tâche. La réponse va dans HKLM:\SOFTWARE\Mindset\Installation (valeur Resultat,
                            JSON { id, ok, message }) : jamais dans un dossier modifiable sans droits.
    Sinon : -Resultat <fichier de réponse> (JSON { ok, message }).

    Seuls des dossiers directement dans Program Files\Mindset ou X:\Mindset\Programmes sont acceptés.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('appli', 'mindset', 'mindset-maj', 'taches', 'supprimer', 'demande')][string]$Action,
    [string]$Resultat, [string]$Demande,
    [string]$Zip, [string]$Signature, [string]$Destination, [string]$DossierZip, [string]$Exe, [string]$AncienExe,
    [string]$Source, [string]$Version, [int]$AttendrePid, [string]$TacheAide, [string]$ExeAide,
    [ValidatePattern('^[A-Za-z]?$')][string]$Disque, [string]$Sid, [switch]$Cache
)
$ErrorActionPreference = 'Stop'
$CleDesinstall = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset'

$CleInstallation = 'HKLM:\SOFTWARE\Mindset\Installation'   # réponse d'une demande passée par la tâche (écrite seulement ici)
$IdDemande = ''
function Write-Resultat([bool]$Ok, [string]$Message) {
    if ($IdDemande) {
        try {
            New-Item -Path $CleInstallation -Force | Out-Null
            Set-ItemProperty -Path $CleInstallation -Name 'Resultat' -Value (@{ id = $IdDemande; ok = $Ok; message = $Message } | ConvertTo-Json -Compress)
        } catch {}
        return
    }
    if ($Resultat) { try { [IO.File]::WriteAllText($Resultat, (@{ ok = $Ok; message = $Message } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {} }
}

# Dossier des données de Mindset (même règle que Get-RacinesDepuis dans modules\donnees.ps1) : la demande y est écrite
function Get-DonneesMindset([string]$DossierMindset) {
    $p = Split-Path $DossierMindset -Parent; $m = Split-Path $p -Parent
    if ((Split-Path $p -Leaf) -eq 'Programmes' -and $m -and (Split-Path $m -Leaf) -eq 'Mindset') { return (Join-Path $m 'Donnees\Mindset') }
    Join-Path $env:LOCALAPPDATA 'Mindset\Mindset'
}

# Un dossier directement dans les programmes de Mindset : Program Files\Mindset, ou X:\Mindset\Programmes sur un
# autre disque fixe (jamais ailleurs, jamais plus profond)
function Test-DossierMindset([string]$Dossier) {
    $d = [IO.Path]::GetFullPath($Dossier.TrimEnd('\'))
    $bases = @([IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Mindset')) + '\')
    if ($d -match '^([A-Za-z]):\\Mindset\\Programmes\\') { $bases += "$($Matches[1]):\Mindset\Programmes\" }
    foreach ($base in $bases) {
        if ($d.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and $d.Substring($base.Length) -and $d.Substring($base.Length) -notmatch '[\\/]') {
            if ($base -notlike "$env:ProgramFiles*") { Assert-DisqueFixe $base.Substring(0, 1) }
            return $d
        }
    }
    throw "Dossier refusé : $Dossier"
}

function Assert-DisqueFixe([string]$Lettre) {
    $v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Lettre.ToUpper()):'" -ErrorAction SilentlyContinue
    if (-not $v -or $v.DriveType -ne 3 -or $v.FileSystem -ne 'NTFS') { throw "Le disque $($Lettre): n'est pas un disque fixe NTFS : Mindset ne peut pas y protéger ses programmes." }
}

# X:\Mindset : droits posés explicitement, sans hériter de ceux du disque (qui varient d'un PC à l'autre).
#   X:\Mindset et Programmes : administrateurs et système en contrôle total, utilisateurs en lecture seule ;
#   Donnees : en plus, l'utilisateur de Mindset ($Sid) peut modifier (les applis y écrivent sans droits admin).
# L'utilisateur ne pouvant pas modifier X:\Mindset, il ne peut pas non plus renommer ou remplacer Programmes.
function Initialize-RacineDisque([string]$Lettre, [string]$Sid) {
    Assert-DisqueFixe $Lettre
    if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Utilisateur inconnu.' }
    $racine = "$($Lettre.ToUpper()):\Mindset"
    New-Item -ItemType Directory -Force -Path $racine, "$racine\Programmes", "$racine\Donnees" | Out-Null
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $systeme = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $utilisateurs = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $h = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'; $pr = [Security.AccessControl.PropagationFlags]::None
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    foreach ($r in @(@($admins, 'FullControl'), @($systeme, 'FullControl'), @($utilisateurs, 'ReadAndExecute'))) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($r[0], $r[1], $h, $pr, 'Allow')))
    }
    Set-Acl -LiteralPath $racine -AclObject $acl
    # Tout ce qui est dessous reprend ces droits (même un dossier qui existait déjà avec d'autres droits)
    icacls "$racine\Programmes" /reset /T /C /Q | Out-Null
    icacls "$racine\Donnees" /reset /T /C /Q | Out-Null
    $d = Get-Acl -LiteralPath "$racine\Donnees"
    $d.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($Sid)), 'Modify', $h, $pr, 'Allow')))
    Set-Acl -LiteralPath "$racine\Donnees" -AclObject $d
    "$racine\Programmes"
}

# Les tâches planifiées de Mindset, pour l'utilisateur $Sid seulement :
#   \Mindset\Mindset (démarrage)     à l'ouverture de session, Mindset.exe -Demarrage (caché près de l'horloge), SANS droits
#   \Mindset\Mindset (installation)  à la demande de Mindset, installer-admin.ps1 -Action demande : la seule partie de Mindset
#                                    en administrateur (installer, mettre à jour ou supprimer une appli ou Mindset)
# (L'ancienne « \Mindset\Mindset » ouvrait Mindset en administrateur : elle est retirée, Mindset s'ouvre directement.)
$TachesMindset = @('Mindset', 'Mindset (démarrage)', 'Mindset (installation)')
function Register-TachesMindset([string]$DossierMindset, [string]$Sid) {
    if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Utilisateur inconnu.' }
    $exe = Join-Path $DossierMindset 'Mindset.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Mindset.exe introuvable dans $DossierMindset" }
    $pr = New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
    $utilisateur = (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value
    Unregister-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset' -Confirm:$false -ErrorAction SilentlyContinue
    # Le mini-installateur : une demande à la fois (les suivantes attendent leur tour)
    $prAdmin = New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Highest
    $setAdmin = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(30)) -MultipleInstances Queue
    $script = Join-Path $DossierMindset 'fichiers\installer-admin.ps1'
    $fichier = Join-Path (Get-DonneesMindset $DossierMindset) 'installation.demande'
    $actI = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Action demande -Demande `"$fichier`"" -WorkingDirectory $env:SystemRoot
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset (installation)' -Action $actI -Principal $prAdmin -Settings $setAdmin -Description 'Installe et met à jour Mindset et ses applis (zips signés seulement), à la demande de Mindset.' -Force | Out-Null
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $utilisateur
    $trg.Delay = 'PT10S'   # laisse Windows finir d'ouvrir la session
    $actD = New-ScheduledTaskAction -Execute "`"$exe`"" -Argument '-Demarrage' -WorkingDirectory $DossierMindset
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset (démarrage)' -Action $actD -Trigger $trg -Principal $pr -Settings $set -Description 'Lance Mindset à l''ouverture de session, caché près de l''horloge.' -Force | Out-Null
}
function Unregister-TachesMindset {
    foreach ($t in $TachesMindset) { Unregister-ScheduledTask -TaskPath '\Mindset\' -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    # Et toutes les autres du dossier : celles des parties administrateur des applis (« \Mindset\Nevermind (aide) »)...
    foreach ($t in @(Get-ScheduledTask -TaskPath '\Mindset\' -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskPath '\Mindset\' -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    # ...puis le dossier « \Mindset\ » lui-même, devenu vide
    try { $s = New-Object -ComObject Schedule.Service; $s.Connect(); $s.GetFolder('\').DeleteFolder('Mindset', 0) } catch {}
}

# Le désinstalleur autonome (outils\desinstalleur.cs), livré à côté de Mindset.exe : c'est lui que lance « Applications
# installées ». Sans lui (une copie d'avant), Mindset.exe -Desinstaller.
$NomDesinstalleur = 'Desinstaller Mindset.exe'
function Get-CommandeDesinstallation([string]$DossierMindset) {
    $d = Join-Path $DossierMindset $NomDesinstalleur
    if (Test-Path -LiteralPath $d) { "`"$d`"" } else { "`"$(Join-Path $DossierMindset 'Mindset.exe')`" -Desinstaller" }
}

# La partie administrateur d'une appli (son programme d'aide), à la demande (l'appli lance la tâche quand elle en a besoin),
# pour l'utilisateur $Sid seulement, depuis le dossier protégé où l'appli vient d'être installée. Une seule à la fois.
# (\z et non $ : $ laisserait passer un retour à la ligne final)
$RegleTacheAide = '^[A-Za-z0-9 ]{1,40} \(aide\)\z'
$RegleProgramme = '^[^\\/:*?"<>|\x00-\x1f]+\.exe\z'

function Register-TacheAide([string]$Nom, [string]$ExeAide, [string]$Sid) {
    if ($Nom -cnotmatch $RegleTacheAide) { throw 'Nom de tâche refusé.' }
    if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Utilisateur inconnu.' }
    if (-not (Test-Path -LiteralPath $ExeAide)) { throw "Programme introuvable : $ExeAide" }
    $pr = New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $act = New-ScheduledTaskAction -Execute "`"$ExeAide`"" -WorkingDirectory (Split-Path $ExeAide -Parent)
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName $Nom -Action $act -Principal $pr -Settings $set -Description 'Partie administrateur de l''appli : ne fait que les actions de sa liste stricte, à la demande de l''appli.' -Force | Out-Null
}

# Ferme les programmes lancés depuis $Dossier (sous-dossiers compris), et seulement eux : trouvés par leur CHEMIN, jamais
# par leur nom (l'hôte de chaque appli s'appelle Mindset.exe, comme Mindset lui-même ; un nom ferait fermer en
# administrateur n'importe quel programme du même nom sur le PC). $Dossier est toujours un dossier déjà vérifié par
# Test-DossierMindset (directement dans le dossier protégé des programmes). $Nom ne sert qu'à valider la demande.
function Stop-Programme([string]$Nom, [string]$Dossier) {
    if ($Nom -notmatch $RegleProgramme) { throw 'Nom de programme refusé.' }
    if (-not $Dossier) { throw 'Dossier refusé.' }
    $dans = [IO.Path]::GetFullPath($Dossier).TrimEnd('\') + '\'
    $liste = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $c = try { [string]$_.Path } catch { '' }
        $_.Id -ne $PID -and $c -and $c.StartsWith($dans, [StringComparison]::OrdinalIgnoreCase)
    })
    if (-not $liste.Count) { return }
    $liste | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

# Demande passée par la tâche « \Mindset\Mindset (installation) » : lue, puis effacée. Tout ce qu'elle contient est
# revérifié plus bas (dossiers, noms, signature des zips) ; l'utilisateur est toujours celui de la tâche.
if ($Action -eq 'demande') {
    try {
        $fi = New-Object IO.FileInfo $Demande
        if (-not $fi.Exists -or $fi.Length -gt 16KB -or ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint)) { exit }
        $j = [IO.File]::ReadAllText($Demande, [Text.Encoding]::UTF8) | ConvertFrom-Json
        try { [IO.File]::Delete($Demande) } catch {}
        if ([string]$j.Id -notmatch '^[0-9a-f]{8,32}\z') { exit }
        $IdDemande = [string]$j.Id
        if ([string]$j.Action -notin 'appli', 'mindset-maj', 'supprimer', 'taches') { Write-Resultat $false 'Demande refusée.'; exit }
        $Action = [string]$j.Action
        foreach ($n in 'Zip', 'Signature', 'Destination', 'DossierZip', 'Exe', 'AncienExe', 'Version', 'TacheAide', 'ExeAide') {
            $v = $j.PSObject.Properties[$n]
            if ($v -and $v.Value -is [string]) { Set-Variable -Name $n -Value ([string]$v.Value) }
        }
        if ($j.AttendrePid) { $AttendrePid = [int]$j.AttendrePid }
        if ([string]$j.Cache -eq '1') { $Cache = [switch]$true }
        $Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    } catch { Write-Resultat $false "Demande illisible : $($_.Exception.Message)"; exit }
}

try {
    . (Join-Path $PSScriptRoot 'modules\signature.ps1')
    . (Join-Path $PSScriptRoot 'modules\paquets.ps1')

    switch ($Action) {
        'appli' {
            $dest = Test-DossierMindset $Destination
            if ($DossierZip -match '[\\/:*?"<>|]') { throw 'Nom de dossier refusé.' }
            $octets = [IO.File]::ReadAllBytes($Zip)
            $sig = [IO.File]::ReadAllBytes($Signature)
            # Tout est vérifié AVANT d'arrêter quoi que ce soit : noms, tâche d'aide, puis la signature du zip (sinon une
            # demande écrite sans droits ferait arrêter en administrateur n'importe quel programme, même avec un faux zip)
            foreach ($n in @($Exe, $ExeAide) | Where-Object { $_ }) { if ($n -notmatch $RegleProgramme) { throw 'Nom de programme refusé.' } }
            if ($TacheAide -and $TacheAide -cnotmatch $RegleTacheAide) { throw 'Nom de tâche refusé.' }
            if (-not (Test-Signature $octets $sig (Join-Path $PSScriptRoot 'cles-publiques'))) { throw 'La signature du fichier téléchargé est invalide : rien n''a été installé.' }
            # Mindset a demandé confirmation avant de fermer l'appli : tout ce qui tourne depuis son dossier (son hôte, l'ancien
            # <Appli>.exe, sa partie administrateur qui tient son programme ouvert), rien d'autre
            Stop-Programme $Exe $dest
            $installe = Install-Paquet -Zip $octets -Signature $sig -ClePublique (Join-Path $PSScriptRoot 'cles-publiques') -Destination $dest -DossierZip $DossierZip -Exe $Exe
            # Prise en charge : les tâches planifiées qui lançaient l'ancienne copie (en administrateur, que Mindset
            # sans droits ne peut pas modifier) lancent désormais la nouvelle
            if ($AncienExe) {
                $nouveau = Join-Path $installe $Exe
                foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
                    $act = @($t.Actions)[0]
                    if ($act -and ([string]$act.Execute).Trim('"') -ieq $AncienExe) {
                        $act.Execute = "`"$nouveau`""
                        Set-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Action $act | Out-Null
                    }
                }
            }
            # (une version de l'appli sans programme d'aide s'installe quand même, sans tâche)
            if ($TacheAide -and $ExeAide -and (Test-Path -LiteralPath (Join-Path $installe $ExeAide))) { Register-TacheAide $TacheAide (Join-Path $installe $ExeAide) $Sid }
            Write-Resultat $true $installe
        }
        'mindset' {
            # Disque choisi : C: (Program Files) par défaut, ou X:\Mindset
            $programmes = if ($Disque) { Initialize-RacineDisque $Disque $Sid } else { Join-Path $env:ProgramFiles 'Mindset' }
            $dest = Test-DossierMindset (Join-Path $programmes 'Mindset')
            $src = [IO.Path]::GetFullPath($Source.TrimEnd('\'))
            if (-not (Test-Path -LiteralPath (Join-Path $src 'Mindset.exe')) -or -not (Test-Path -LiteralPath (Join-Path $src 'fichiers\Mindset.ps1'))) { throw "Ce dossier ne contient pas Mindset : $Source" }
            # Préparé à côté puis échangé, comme une appli
            $tmp = "$dest.nouveau-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            Copy-Item -LiteralPath (Join-Path $src 'Mindset.exe') -Destination $tmp
            Copy-Item -LiteralPath (Join-Path $src 'fichiers') -Destination $tmp -Recurse
            foreach ($f in 'LISEZMOI.txt', $NomDesinstalleur) { if (Test-Path -LiteralPath (Join-Path $src $f)) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $tmp } }
            if (Test-Path -LiteralPath $dest) {
                $ancien = "$dest.ancien-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
                Move-Item -LiteralPath $dest -Destination $ancien
                Move-Item -LiteralPath $tmp -Destination $dest
                try { Remove-Item -LiteralPath $ancien -Recurse -Force } catch {}
            } else { Move-Item -LiteralPath $tmp -Destination $dest }
            # « Applications installées » de Windows : Mindset s'y désinstalle comme un vrai programme, par son désinstalleur
            # autonome (il marche même si le code de Mindset est abîmé ; sans lui, par Mindset.exe -Desinstaller)
            $exe = Join-Path $dest 'Mindset.exe'
            New-Item -Path $CleDesinstall -Force | Out-Null
            foreach ($p in @{ DisplayName = 'Mindset'; DisplayVersion = $Version; Publisher = 'Jordan Jacquot'; InstallLocation = $dest
                              DisplayIcon = "`"$exe`",0"; UninstallString = (Get-CommandeDesinstallation $dest); NoModify = 1; NoRepair = 1 }.GetEnumerator()) {
                if ($p.Value -is [int]) { New-ItemProperty -Path $CleDesinstall -Name $p.Key -Value $p.Value -PropertyType DWord -Force | Out-Null }
                else { New-ItemProperty -Path $CleDesinstall -Name $p.Key -Value ([string]$p.Value) -PropertyType String -Force | Out-Null }
            }
            try { Register-TachesMindset $dest $Sid } catch { Write-Resultat $true "$dest|sans-taches : $($_.Exception.Message)"; return }
            Write-Resultat $true $dest
        }
        'mindset-maj' {
            # Mise à jour de Mindset lui-même : on attend qu'il soit fermé, on installe le zip signé (vérifié ici),
            # puis on le relance sans les droits administrateur (par l'Explorateur, qui tourne avec ceux de l'utilisateur)
            $relance = Join-Path $PSScriptRoot '..\Mindset.exe'   # le Mindset qui a demandé la mise à jour
            try {
                $dest = Test-DossierMindset $Destination
                if ((Split-Path $dest -Leaf) -ne 'Mindset') { throw "Dossier refusé : $Destination" }
                $relance = Join-Path $dest 'Mindset.exe'
                if ($AttendrePid) { try { Wait-Process -Id $AttendrePid -Timeout 30 -ErrorAction Stop } catch {} }
                Start-Sleep -Milliseconds 500
                $octets = [IO.File]::ReadAllBytes($Zip)
                $sig = [IO.File]::ReadAllBytes($Signature)
                [void](Install-Paquet -Zip $octets -Signature $sig -ClePublique (Join-Path $PSScriptRoot 'cles-publiques') -Destination $dest -DossierZip 'Mindset' -Exe 'Mindset.exe')
                if ($Version) { Set-ItemProperty -Path $CleDesinstall -Name 'DisplayVersion' -Value $Version -ErrorAction SilentlyContinue }
                # (une installation d'avant le désinstalleur autonome passe à lui avec cette mise à jour)
                Set-ItemProperty -Path $CleDesinstall -Name 'UninstallString' -Value (Get-CommandeDesinstallation $dest) -ErrorAction SilentlyContinue
                # Tâches à jour avec la nouvelle version (demande passée par la tâche : l'utilisateur est connu)
                if ($Sid) { try { Register-TachesMindset $dest $Sid } catch {} }
                Write-Resultat $true $Version
            } catch { Write-Resultat $false $_.Exception.Message }
            finally {
                # Relancé dans tous les cas : la nouvelle version, ou l'ancienne si la mise à jour a échoué. Mise à jour
                # automatique (Mindset était caché) : par sa tâche de démarrage, qui le lance caché près de l'horloge
                $fait = $false
                if ($Cache) { $null = & "$env:SystemRoot\System32\schtasks.exe" /Run /TN '\Mindset\Mindset (démarrage)' 2>&1; $fait = ($LASTEXITCODE -eq 0) }
                if (-not $fait) { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$([IO.Path]::GetFullPath($relance))`"" }
            }
            return
        }
        'taches' {
            # Installation existante (Mindset 0.1.9 ou avant) : ses tâches planifiées, sans réinstaller
            $dest = Test-DossierMindset $Destination
            if ((Split-Path $dest -Leaf) -ne 'Mindset') { throw "Dossier refusé : $Destination" }
            Register-TachesMindset $dest $Sid
            Write-Resultat $true $dest
        }
        'supprimer' {
            $dest = Test-DossierMindset $Destination
            if ($AttendrePid) { try { Wait-Process -Id $AttendrePid -Timeout 30 -ErrorAction Stop } catch {} }
            if ($Exe) { Stop-Programme $Exe $dest }   # (seulement les programmes de ce dossier)
            if ((Split-Path $dest -Leaf) -ne 'Mindset') {
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            } else {
                # Mindset lui-même, sans son désinstalleur autonome (une copie d'avant lui). Mindset est déjà fermé et ne
                # lira pas la réponse : chaque étape est tentée, puis ce qui n'a pas pu être retiré est affiché ici.
                $restes = @()
                if (Test-Path -LiteralPath $dest) { try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop } catch { $restes += "le dossier $dest ($($_.Exception.Message))" } }
                Unregister-TachesMindset
                foreach ($t in @(Get-ScheduledTask -TaskPath '\Mindset\' -ErrorAction SilentlyContinue)) { $restes += "la tâche planifiée « \Mindset\$($t.TaskName) »" }
                # (l'entrée « Applications installées » reste tant que le dossier est là : elle sert à relancer la désinstallation)
                foreach ($c in @('HKLM:\SOFTWARE\Mindset') + @(if (-not (Test-Path -LiteralPath $dest)) { $CleDesinstall })) {
                    try { if (Test-Path -Path $c) { Remove-Item -Path $c -Recurse -Force -ErrorAction Stop } } catch { $restes += "la clé du registre $c" }
                }
                $IdDemande = ''   # (la réponse irait dans HKLM:\SOFTWARE\Mindset, qui vient d'être retiré)
                if ($restes) {
                    try {
                        Add-Type -AssemblyName System.Windows.Forms
                        [void][System.Windows.Forms.MessageBox]::Show("Mindset n'a pas pu être retiré entièrement. Ce qui reste :`n`n- $($restes -join "`n- ")`n`nRedémarre l'ordinateur, puis relance la désinstallation de Mindset (Paramètres de Windows, « Applications installées »).", 'Désinstaller Mindset', 'OK', 'Warning')
                    } catch {}
                    Write-Resultat $false "Il reste : $($restes -join ' ; ')"
                    return
                }
            }
            # Dossier des programmes vide : retiré aussi (les données, elles, restent)
            $base = Split-Path $dest -Parent
            if ((Test-Path -LiteralPath $base) -and -not @(Get-ChildItem -LiteralPath $base -Force).Count) { Remove-Item -LiteralPath $base -Force }
            Write-Resultat $true $dest
        }
    }
} catch {
    Write-Resultat $false $_.Exception.Message
}
