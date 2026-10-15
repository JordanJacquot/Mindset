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
                            après avoir attendu la fin du processus -AttendrePid
    Toujours : -Resultat <fichier de réponse> (JSON { ok, message }).

    Seuls des dossiers directement dans Program Files\Mindset ou X:\Mindset\Programmes sont acceptés.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('appli', 'mindset', 'mindset-maj', 'taches', 'supprimer')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Resultat,
    [string]$Zip, [string]$Signature, [string]$Destination, [string]$DossierZip, [string]$Exe, [string]$AncienExe,
    [string]$Source, [string]$Version, [int]$AttendrePid, [string]$TacheAide, [string]$ExeAide,
    [ValidatePattern('^[A-Za-z]?$')][string]$Disque, [string]$Sid
)
$ErrorActionPreference = 'Stop'
$CleDesinstall = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset'

function Write-Resultat([bool]$Ok, [string]$Message) {
    try { [IO.File]::WriteAllText($Resultat, (@{ ok = $Ok; message = $Message } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {}
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

# Les tâches planifiées de Mindset : il tourne en administrateur sans demande de Windows (pour accueillir Nevermind,
# installer et mettre à jour sans demande). Elles ne lancent que le Mindset.exe du dossier protégé, pour l'utilisateur $Sid.
#   \Mindset\Mindset              à la demande (le raccourci « Mindset » la lance)
#   \Mindset\Mindset (démarrage)  à l'ouverture de session, avec -Demarrage (caché près de l'horloge)
$TachesMindset = @('Mindset', 'Mindset (démarrage)')
function Register-TachesMindset([string]$DossierMindset, [string]$Sid) {
    if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Utilisateur inconnu.' }
    $exe = Join-Path $DossierMindset 'Mindset.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Mindset.exe introuvable dans $DossierMindset" }
    $pr = New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
    $utilisateur = (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value
    $act = New-ScheduledTaskAction -Execute "`"$exe`"" -WorkingDirectory $DossierMindset
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset' -Action $act -Principal $pr -Settings $set -Description 'Ouvre Mindset (le raccourci « Mindset » la lance).' -Force | Out-Null
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $utilisateur
    $trg.Delay = 'PT10S'   # laisse Windows finir d'ouvrir la session
    $actD = New-ScheduledTaskAction -Execute "`"$exe`"" -Argument '-Demarrage' -WorkingDirectory $DossierMindset
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset (démarrage)' -Action $actD -Trigger $trg -Principal $pr -Settings $set -Description 'Lance Mindset à l''ouverture de session, caché près de l''horloge.' -Force | Out-Null
}
function Unregister-TachesMindset {
    foreach ($t in $TachesMindset) { Unregister-ScheduledTask -TaskPath '\Mindset\' -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    # Et celles des parties administrateur des applis (« \Mindset\Nevermind (aide) »)
    foreach ($t in @(Get-ScheduledTask -TaskPath '\Mindset\' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like '* (aide)' })) {
        Unregister-ScheduledTask -TaskPath '\Mindset\' -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# La partie administrateur d'une appli (son programme d'aide), à la demande (l'appli lance la tâche quand elle en a besoin),
# pour l'utilisateur $Sid seulement, depuis le dossier protégé où l'appli vient d'être installée. Une seule à la fois.
function Register-TacheAide([string]$Nom, [string]$ExeAide, [string]$Sid) {
    if ($Nom -cnotmatch '^[A-Za-z0-9 ]{1,40} \(aide\)$') { throw 'Nom de tâche refusé.' }
    if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Utilisateur inconnu.' }
    if (-not (Test-Path -LiteralPath $ExeAide)) { throw "Programme introuvable : $ExeAide" }
    $pr = New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $act = New-ScheduledTaskAction -Execute "`"$ExeAide`"" -WorkingDirectory (Split-Path $ExeAide -Parent)
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName $Nom -Action $act -Principal $pr -Settings $set -Description 'Partie administrateur de l''appli : ne fait que les actions de sa liste stricte, à la demande de l''appli.' -Force | Out-Null
}

function Stop-Programme([string]$Nom) {
    if ($Nom -notmatch '^[^\\/:*?"<>|]+\.exe$') { throw 'Nom de programme refusé.' }
    Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Nom)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
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
            Stop-Programme $Exe   # Mindset a demandé confirmation avant de fermer l'appli
            if ($ExeAide) { Stop-Programme $ExeAide }   # sa partie administrateur tient son programme ouvert
            $installe = Install-Paquet -Zip $octets -Signature $sig -ClePublique (Join-Path $PSScriptRoot 'cle-publique.xml') -Destination $dest -DossierZip $DossierZip -Exe $Exe
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
            foreach ($f in 'LISEZMOI.txt') { if (Test-Path -LiteralPath (Join-Path $src $f)) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $tmp } }
            if (Test-Path -LiteralPath $dest) {
                $ancien = "$dest.ancien-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
                Move-Item -LiteralPath $dest -Destination $ancien
                Move-Item -LiteralPath $tmp -Destination $dest
                try { Remove-Item -LiteralPath $ancien -Recurse -Force } catch {}
            } else { Move-Item -LiteralPath $tmp -Destination $dest }
            # « Applications installées » de Windows : Mindset s'y désinstalle comme un vrai programme
            $exe = Join-Path $dest 'Mindset.exe'
            New-Item -Path $CleDesinstall -Force | Out-Null
            foreach ($p in @{ DisplayName = 'Mindset'; DisplayVersion = $Version; Publisher = 'Jordan Jacquot'; InstallLocation = $dest
                              DisplayIcon = "`"$exe`",0"; UninstallString = "`"$exe`" -Desinstaller"; NoModify = 1; NoRepair = 1 }.GetEnumerator()) {
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
                [void](Install-Paquet -Zip $octets -Signature $sig -ClePublique (Join-Path $PSScriptRoot 'cle-publique.xml') -Destination $dest -DossierZip 'Mindset' -Exe 'Mindset.exe')
                if ($Version) { Set-ItemProperty -Path $CleDesinstall -Name 'DisplayVersion' -Value $Version -ErrorAction SilentlyContinue }
                Write-Resultat $true $Version
            } catch { Write-Resultat $false $_.Exception.Message }
            finally {
                # Relancé dans tous les cas : la nouvelle version, ou l'ancienne si la mise à jour a échoué
                Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$([IO.Path]::GetFullPath($relance))`""
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
            if ($Exe) { Stop-Programme $Exe }
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            if ((Split-Path $dest -Leaf) -eq 'Mindset') { Remove-Item -Path $CleDesinstall -Recurse -Force -ErrorAction SilentlyContinue; Unregister-TachesMindset }
            # Dossier des programmes vide : retiré aussi (les données, elles, restent)
            $base = Split-Path $dest -Parent
            if ((Test-Path -LiteralPath $base) -and -not @(Get-ChildItem -LiteralPath $base -Force).Count) { Remove-Item -LiteralPath $base -Force }
            Write-Resultat $true $dest
        }
    }
} catch {
    Write-Resultat $false $_.Exception.Message
}
