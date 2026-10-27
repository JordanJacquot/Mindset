<#
    LA VERSION POWERSHELL DU MINI-INSTALLATEUR (Mindset 2.14.0), GARDÉE POUR LES TESTS SEULEMENT, JAMAIS LIVRÉE.
    Depuis l'étape 2 du passage en Rust, c'est MindsetInstallateur.exe qui fait ce travail, et
    Mindset\fichiers\installer-admin.ps1 n'est plus qu'un relais vers lui. Le corpus cas\installateur passe toujours
    à cette version-ci (outils\tester-installer.ps1) : les cas restent justes pour les deux versions (plan Rust, 3.5).
    À retirer à l'étape 7, avec le relais.

    Mindset : ce qui se fait dans Program Files\Mindset, lancé en administrateur par Mindset (une demande de Windows).
    Program Files n'est modifiable que par un administrateur : un programme sans droits ne peut pas y glisser un
    fichier que Nevermind (ou Mindset plus tard) exécuterait ensuite en administrateur.

    -Action appli           installe une appli à partir de son zip signé (vérifié ici, sur le contenu lu en mémoire)
                            -Appli <id> -Zip -Signature -Destination [-DossierZip -Exe] [-AncienExe] [-Sid <utilisateur>]
                            L'appli est une de apps.json (lu à côté de ce script, dans le dossier protégé) : son dossier
                            (<programmes>\<nom>), le dossier de son zip, son programme et sa partie administrateur viennent
                            de là, jamais de la demande (une valeur de la demande qui n'est pas celle de apps.json est refusée).
                            Sa partie administrateur (aide, aide_exe) : la tâche « \Mindset\<aide> » qui lance <aide_exe>
                            en SYSTEM pour l'utilisateur -Sid (lancée sans demande de Windows).
                            La plus haute version installée de chaque appli est gardée dans HKLM:\SOFTWARE\Mindset\Versions
                            (écrite seulement ici) : une version plus ancienne est refusée, même après une suppression.
    -Action mindset         installe Mindset lui-même : copie -Source dans Program Files\Mindset\Mindset, ou dans
                            X:\Mindset\Programmes\Mindset avec -Disque X -Sid <utilisateur> (crée X:\Mindset protégé),
                            et l'inscrit dans « Applications installées » de Windows (-Version)
    -Action mindset-maj     met Mindset à jour : attend la fin du processus -AttendrePid, installe -Zip/-Signature (vérifiés ici)
                            dans -Destination (…\Mindset), puis relance Mindset sans les droits administrateur
    -Action supprimer       supprime une appli gérée (-Destination, -Exe) ou Mindset lui-même (-Destination ...\Mindset)
                            après avoir attendu la fin du processus -AttendrePid. Pour Mindset lui-même, ce n'est que le
                            chemin de secours (sans « Desinstaller Mindset.exe ») : ce qui reste est affiché ici.
    -Action demande         lancé par la tâche « \Mindset\Mindset (installation) » (Mindset sans droits), en SYSTEM :
                            -Sid (l'utilisateur, inscrit dans la tâche par l'administrateur qui l'a créée) et -Demande
                            (le fichier JSON écrit par Mindset : Id, Action parmi appli, mindset-maj, supprimer, taches, et
                            ses paramètres). Le fichier est modifiable sans droits : tout y est revérifié comme pour un
                            lancement direct, seuls les zips signés de son dossier telechargements s'installent, et
                            l'utilisateur est toujours celui de la tâche. Le dossier des programmes est celui d'où la
                            tâche lance ce script (protégé, choisi par l'administrateur qui l'a inscrite), jamais celui de
                            la demande : taches et mindset-maj visent ce Mindset-là, appli et supprimer un dossier
                            directement à côté de lui. Accusé de réception (valeur Recu, l'Id) puis
                            réponse (valeur Resultat, JSON { id, ok, message }) dans HKLM:\SOFTWARE\Mindset\Installation :
                            jamais dans un dossier modifiable sans droits. Aucune fenêtre (personne ne la verrait).
                            Sans -Sid : l'ancienne tâche (« avec les droits les plus élevés », sous le compte de
                            l'utilisateur, jusqu'à Mindset 2.9.0). Elle ne sert plus qu'à une chose : se remplacer par la
                            tâche SYSTEM (Action taches).
    Sinon : -Resultat <fichier de réponse> (JSON { ok, message }).

    Seuls des dossiers directement dans Program Files\Mindset ou X:\Mindset\Programmes sont acceptés.

    En administrateur, rien ne vient de l'utilisateur : ni ses modules PowerShell (Documents\WindowsPowerShell\Modules,
    en tête de PSModulePath), ni ses variables d'environnement (windir, ProgramFiles, LOCALAPPDATA... dans HKCU\Environment).
    Les dossiers de Windows sont demandés à Windows, et les modules sont chargés par leur chemin dans System32.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('appli', 'mindset', 'mindset-maj', 'taches', 'supprimer', 'demande')][string]$Action,
    [string]$Resultat, [string]$Demande,
    [string]$Zip, [string]$Signature, [string]$Destination, [string]$DossierZip, [string]$Exe, [string]$AncienExe,
    [string]$Source, [string]$Version, [int]$AttendrePid, [string]$TacheAide, [string]$ExeAide, [string]$Appli,
    [ValidatePattern('^[A-Za-z]?$')][string]$Disque, [string]$Sid, [switch]$Cache
)
$ErrorActionPreference = 'Stop'
# Avant toute autre commande : les modules de Windows seulement, chargés par leur chemin (le chargement automatique
# prendrait le premier module du même nom trouvé dans PSModulePath, qui commence par le dossier Documents de l'utilisateur)
$env:PSModulePath = [Environment]::GetFolderPath('System') + '\WindowsPowerShell\v1.0\Modules'
$PSModuleAutoLoadingPreference = 'None'
foreach ($m in 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'CimCmdlets', 'ScheduledTasks') {
    Import-Module -Name ($env:PSModulePath + '\' + $m) -ErrorAction Stop
}
# <dossiers-windows> Les dossiers et programmes de Windows, demandés à Windows (jamais aux variables d'environnement, que
# l'utilisateur peut changer). (outils\tester-installer.ps1 remplace ce bloc par ceux de son faux PC.)
$DossierWindows = [Environment]::GetFolderPath('Windows')
$DossierSysteme = [Environment]::GetFolderPath('System')
$DossierProgrammes = [Environment]::GetFolderPath('ProgramFiles')
$PowerShellExe = Join-Path $DossierSysteme 'WindowsPowerShell\v1.0\powershell.exe'
$Schtasks = Join-Path $DossierSysteme 'schtasks.exe'
$Icacls = Join-Path $DossierSysteme 'icacls.exe'
$Explorer = Join-Path $DossierWindows 'explorer.exe'
$CleProfils = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
# </dossiers-windows>
$CleDesinstall ='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset'

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

$SidValide = '^S-1-5-21-\d+-\d+-\d+-\d+\z'
# Le dossier de l'utilisateur $Sid (C:\Users\<nom>), lu dans HKLM (ProfileList), jamais dans ses variables ni dans ses
# « dossiers du shell » (HKCU), qu'il peut rediriger. %SystemDrive% et %SystemRoot% sont remplacés ici, par Windows.
function Get-ProfilUtilisateur([string]$Sid) {
    if ($Sid -notmatch $SidValide) { throw 'Utilisateur inconnu.' }
    $p = ''
    try { $p = [string](Get-Item -LiteralPath "$CleProfils\$Sid" -ErrorAction Stop).GetValue('ProfileImagePath', '', 'DoNotExpandEnvironmentNames') } catch {}
    $p = $p -ireplace '%SystemDrive%', $DossierWindows.Substring(0, 2) -ireplace '%SystemRoot%|%windir%', $DossierWindows
    if ($p -notmatch '^[A-Za-z]:\\[^%"*?<>|]+$') { throw 'Le dossier de cet utilisateur est introuvable.' }
    $p.TrimEnd('\')
}

# Dossier des données de Mindset de l'utilisateur $Sid (même règle que Get-RacinesDepuis dans modules\donnees.ps1) : la
# demande y est écrite, et les zips téléchargés y sont rangés (telechargements)
function Get-DonneesMindset([string]$DossierMindset, [string]$Sid) {
    $p = Split-Path $DossierMindset -Parent; $m = Split-Path $p -Parent
    if ((Split-Path $p -Leaf) -eq 'Programmes' -and $m -and (Split-Path $m -Leaf) -eq 'Mindset') { return (Join-Path $m 'Donnees\Mindset') }
    Join-Path (Get-ProfilUtilisateur $Sid) 'AppData\Local\Mindset\Mindset'
}

# Un chemin sans lien (point de jonction, lien symbolique) sur lui ni sur un de ses dossiers parents : en administrateur,
# on ne lit rien, dans un dossier de l'utilisateur, qui renverrait ailleurs que là où il semble être
function Test-SansLien([string]$Chemin) {
    $x = [IO.Path]::GetFullPath($Chemin)
    while ($x -and $x.Length -gt 3) {
        try { if ([IO.File]::GetAttributes($x) -band [IO.FileAttributes]::ReparsePoint) { return $false } } catch { return $false }
        $x = [IO.Path]::GetDirectoryName($x)
    }
    $true
}

# Demande passée par la tâche : le zip et sa signature ne sont lus que dans le dossier telechargements de l'utilisateur
# (à côté de la demande, là où Mindset les range), jamais ailleurs sur le PC
function Assert-Telechargement([string]$Fichier) {
    if (-not $ParTache) { return }
    $dossier = Join-Path (Split-Path $Demande -Parent) 'telechargements'
    $f = ''
    try { if ($Fichier -match '^[A-Za-z]:\\') { $f = [IO.Path]::GetFullPath($Fichier) } } catch {}
    if (-not $f -or [IO.Path]::GetDirectoryName($f) -ine $dossier -or -not (Test-SansLien $f)) { throw "Fichier refusé (il doit être dans $dossier) : $Fichier" }
}

# Un compte (nom ou SID, comme les tâches planifiées le donnent) en SID ; '' si inconnu
function ConvertTo-Sid([string]$Compte) {
    if (-not $Compte) { return '' }
    if ($Compte -match '^S-1-[\d-]+$') { return $Compte }
    try { (New-Object Security.Principal.NTAccount($Compte)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
}

# Un dossier directement dans les programmes de Mindset : Program Files\Mindset, ou X:\Mindset\Programmes sur un
# autre disque fixe (jamais ailleurs, jamais plus profond)
function Test-DossierMindset([string]$Dossier) {
    $d = [IO.Path]::GetFullPath($Dossier.TrimEnd('\'))
    $pf = [IO.Path]::GetFullPath((Join-Path $DossierProgrammes 'Mindset')) + '\'
    $bases = @($pf)
    if ($d -match '^([A-Za-z]):\\Mindset\\Programmes\\') { $bases += "$($Matches[1]):\Mindset\Programmes\" }
    foreach ($base in $bases) {
        if ($d.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and $d.Substring($base.Length) -and $d.Substring($base.Length) -notmatch '[\\/]') {
            if ($base -ne $pf) { Assert-DisqueFixe $base.Substring(0, 1) }
            return $d
        }
    }
    throw "Dossier refusé : $Dossier"
}

function Assert-DisqueFixe([string]$Lettre) {
    $v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Lettre.ToUpper()):'" -ErrorAction SilentlyContinue
    if (-not $v -or $v.DriveType -ne 3 -or $v.FileSystem -ne 'NTFS') { throw "Le disque $($Lettre): n'est pas un disque fixe NTFS : Mindset ne peut pas y protéger ses programmes." }
}

# Un dossier que seuls les administrateurs peuvent changer : il appartient aux Administrateurs, à SYSTEM ou à
# TrustedInstaller, et personne d'autre n'y a un droit d'écriture (ni l'utilisateur, ni « Utilisateurs », ni « Tout le
# monde »). (Un dossier créé sans droits, par exemple C:\Mindset\Programmes, appartient à celui qui l'a créé.)
$ComptesAdmin = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
function Test-DossierProtege([string]$Dossier) {
    try {
        $acl = Get-Acl -LiteralPath $Dossier
        $proprietaire = $acl.GetOwner([Security.Principal.SecurityIdentifier])
        if (-not $proprietaire -or $proprietaire.Value -notin $ComptesAdmin) { return $false }
        # (écrire, ajouter, supprimer, changer les droits ou le propriétaire ; et les droits « génériques » tout et écriture)
        $ecriture = [int64][Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership' -bor 0x50000000
        foreach ($r in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
            if ([string]$r.AccessControlType -ne 'Allow' -or ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
            if ($r.IdentityReference.Value -in $ComptesAdmin) { continue }
            if ([int64]$r.FileSystemRights -band $ecriture) { return $false }
        }
        return $true
    } catch { return $false }
}

# Le dossier $Dossier appartient aux Administrateurs (s'il n'appartient pas déjà à un compte d'administration) : posé par
# l'installation de Mindset, que Test-DossierProtege vérifie ensuite à chaque demande
function Set-ProprietaireAdmins([string]$Dossier) {
    try {
        $a = Get-Acl -LiteralPath $Dossier
        $p = $a.GetOwner([Security.Principal.SecurityIdentifier])
        if ($p -and $p.Value -in $ComptesAdmin) { return }
        $a.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $Dossier -AclObject $a
    } catch {}
}

# Par la tâche : le dossier de Mindset est celui d'où la tâche lance ce script, et le dossier des programmes celui qui le
# contient (Program Files\Mindset ou X:\Mindset\Programmes). L'administrateur qui a inscrit la tâche l'a choisi ; une
# demande ne peut pas le changer. Il doit être protégé (Test-DossierProtege), sans lien sur son chemin.
$DossierMindsetTache = ''; $RacineTache = ''
function Initialize-RacineTache {
    $mindset = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
    $racine = Split-Path $mindset -Parent
    $pf = [IO.Path]::GetFullPath((Join-Path $DossierProgrammes 'Mindset')).TrimEnd('\')
    $ok = (Split-Path $mindset -Leaf) -eq 'Mindset' -and ($racine -ieq $pf -or $racine -match '^[A-Za-z]:\\Mindset\\Programmes\z')
    if ($ok -and $racine -ine $pf) { Assert-DisqueFixe $racine.Substring(0, 1) }
    if (-not $ok -or -not (Test-SansLien $mindset) -or -not (Test-DossierProtege $racine)) {
        throw "Mindset n'est pas installé dans un dossier protégé ($racine) : rien n'a été fait."
    }
    $script:DossierMindsetTache = $mindset; $script:RacineTache = $racine
}
# Par la tâche : un dossier directement dans le dossier des programmes de la tâche (Mindset compris), sans lien
function Get-DossierTache([string]$Dossier) {
    $d = ''
    try { if ($Dossier -match '^[A-Za-z]:\\') { $d = [IO.Path]::GetFullPath($Dossier.TrimEnd('\')) } } catch {}
    if (-not $d -or (Split-Path $d -Parent) -ine $RacineTache -or ([IO.Directory]::Exists($d) -and -not (Test-SansLien $d))) { throw "Dossier refusé : $Dossier" }
    $d
}

# Une appli de apps.json, lu à côté de ce script (dans le dossier protégé de Mindset), jamais dans la demande : son nom
# (celui de son dossier), le dossier de son zip (aujourd'hui, ou sous son ancien nom), son programme, sa partie
# administrateur. Vérifiés comme Mindset le fait (modules\applis.ps1).
function Get-AppliConnue([string]$Id) {
    if ($Id -cnotmatch '^[a-z0-9-]{1,40}\z') { throw 'Appli inconnue.' }
    $liste = $null
    try { $liste = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
    $nomFichier = '^[^\\/:*?"<>|\x00-\x1f]+\z'
    foreach ($a in $liste) {
        if ([string]$a.id -cne $Id) { continue }
        $nom = [string]$a.nom; $exe = [string]$a.exe
        $ok = $nom -match '^[\w][\w .-]{0,39}\z' -and $nom -notmatch '\.\z' -and $nom -ine 'Mindset' -and $exe -match $RegleProgramme -and [string]$a.dossier_zip -match $nomFichier
        if ($a.ancien_dossier_zip) { $ok = $ok -and [string]$a.ancien_dossier_zip -match $nomFichier }
        if ($a.aide) { $ok = $ok -and [string]$a.aide -cmatch $RegleTacheAide -and [string]$a.aide_exe -match $RegleProgramme }
        if (-not $ok) { break }
        return [pscustomobject]@{ Id = $Id; Nom = $nom; Exe = $exe; DossiersZip = @(@([string]$a.dossier_zip, [string]$a.ancien_dossier_zip) | Where-Object { $_ })
                                  TacheAide = $(if ($a.aide) { [string]$a.aide } else { '' }); ExeAide = $(if ($a.aide) { [string]$a.aide_exe } else { '' }) }
    }
    throw 'Appli inconnue.'
}

# La plus haute version installée de chaque appli (par son id), dans HKLM (écrit seulement ici) : elle reste après une
# suppression de l'appli, et une version plus ancienne est refusée
$CleVersions = 'HKLM:\SOFTWARE\Mindset\Versions'
function Get-VersionGardee([string]$Id) {
    try { [string](Get-ItemProperty -Path $CleVersions -Name $Id -ErrorAction Stop).$Id } catch { '' }
}
function Save-VersionGardee([string]$Id, [string]$Version) {
    if ($Version -notmatch '^\d+(\.\d+){1,3}\z') { return }
    $avant = Get-VersionGardee $Id
    if ($avant -and -not (Test-VersionPlusRecente $Version $avant)) { return }
    if (-not (Test-Path -Path $CleVersions)) { New-Item -Path $CleVersions -Force | Out-Null }
    Set-ItemProperty -Path $CleVersions -Name $Id -Value $Version
}
# Par la tâche, à chaque demande : les versions des applis déjà installées dans le dossier des programmes sont gardées
# (une appli installée avant que Mindset ne les garde est protégée elle aussi)
function Save-VersionsInstallees {
    $liste = $null
    try { $liste = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
    foreach ($a in $liste) {
        try {
            $x = Get-AppliConnue ([string]$a.id)
            $d = Join-Path $RacineTache $x.Nom
            if ([IO.Directory]::Exists($d) -and (Test-SansLien $d)) { Save-VersionGardee $x.Id (Get-VersionDossier $d) }
        } catch {}
    }
}

# X:\Mindset : droits posés explicitement, sans hériter de ceux du disque (qui varient d'un PC à l'autre).
#   X:\Mindset et Programmes : administrateurs et système en contrôle total, utilisateurs en lecture seule ;
#   Donnees : en plus, l'utilisateur de Mindset ($Sid) peut modifier (les applis y écrivent sans droits admin).
# L'utilisateur ne pouvant pas modifier X:\Mindset, il ne peut pas non plus renommer ou remplacer Programmes.
function Initialize-RacineDisque([string]$Lettre, [string]$Sid) {
    Assert-DisqueFixe $Lettre
    if ($Sid -notmatch $SidValide) { throw 'Utilisateur inconnu.' }
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
    & $Icacls "$racine\Programmes" /reset /T /C /Q | Out-Null
    & $Icacls "$racine\Donnees" /reset /T /C /Q | Out-Null
    Set-ProprietaireAdmins "$racine\Programmes"
    $d = Get-Acl -LiteralPath "$racine\Donnees"
    $d.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($Sid)), 'Modify', $h, $pr, 'Allow')))
    Set-Acl -LiteralPath "$racine\Donnees" -AclObject $d
    "$racine\Programmes"
}

# Les tâches planifiées de Mindset, pour l'utilisateur $Sid seulement :
#   \Mindset\Mindset (démarrage)     à l'ouverture de session, Mindset.exe -Demarrage (caché près de l'horloge), SANS droits
#   \Mindset\Mindset (installation)  à la demande de Mindset, installer-admin.ps1 -Action demande -Sid <utilisateur> : la
#                                    seule partie de Mindset en administrateur (installer, mettre à jour ou supprimer une
#                                    appli ou Mindset). En SYSTEM : elle ne reprend rien de l'utilisateur (ni ses variables
#                                    d'environnement, ni ses modules). Seul cet utilisateur (et les administrateurs) peut la
#                                    lancer et la lire. Elle remplace l'ancienne, du même nom, qui tournait « avec les droits
#                                    les plus élevés » sous le compte de l'utilisateur (jusqu'à Mindset 2.9.0).
# (L'ancienne « \Mindset\Mindset » ouvrait Mindset en administrateur : elle est retirée, Mindset s'ouvre directement.)
$TachesMindset = @('Mindset', 'Mindset (démarrage)', 'Mindset (installation)')
function Register-TachesMindset([string]$DossierMindset, [string]$Sid) {
    if ($Sid -notmatch $SidValide) { throw 'Utilisateur inconnu.' }
    $exe = Join-Path $DossierMindset 'Mindset.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Mindset.exe introuvable dans $DossierMindset" }
    $pr = New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
    $utilisateur = (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value
    Unregister-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset' -Confirm:$false -ErrorAction SilentlyContinue
    # Le mini-installateur, en SYSTEM : une demande à la fois (les suivantes attendent leur tour). L'utilisateur est inscrit
    # ici, par l'administrateur, dans ses arguments : c'est le seul pour qui il travaille.
    $prAdmin = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $setAdmin = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(30)) -MultipleInstances Queue
    $script = Join-Path $DossierMindset 'fichiers\installer-admin.ps1'
    $fichier = Join-Path (Get-DonneesMindset $DossierMindset $Sid) 'installation.demande'
    $actI = New-ScheduledTaskAction -Execute $PowerShellExe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Action demande -Sid $Sid -Demande `"$fichier`"" -WorkingDirectory $DossierSysteme
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset (installation)' -Action $actI -Principal $prAdmin -Settings $setAdmin -Description 'Installe et met à jour Mindset et ses applis (zips signés seulement), à la demande de Mindset.' -Force | Out-Null
    Set-DroitsTache 'Mindset (installation)' $Sid
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $utilisateur
    $trg.Delay = 'PT10S'   # laisse Windows finir d'ouvrir la session
    $actD = New-ScheduledTaskAction -Execute "`"$exe`"" -Argument '-Demarrage' -WorkingDirectory $DossierMindset
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset (démarrage)' -Action $actD -Trigger $trg -Principal $pr -Settings $set -Description 'Lance Mindset à l''ouverture de session, caché près de l''horloge.' -Force | Out-Null
    # Les parties administrateur des applis de cet utilisateur encore sous son compte : refaites en SYSTEM
    Update-TachesAide $Sid
}
# Qui peut lancer et lire une tâche SYSTEM de Mindset : le système et les administrateurs (tout), l'utilisateur $Sid
# (lire, lancer), personne d'autre
function Set-DroitsTache([string]$Nom, [string]$Sid) {
    $planificateur = New-Object -ComObject Schedule.Service
    $planificateur.Connect()
    $planificateur.GetFolder('\Mindset').GetTask($Nom).SetSecurityDescriptor("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;$Sid)", 0)
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
# En SYSTEM, comme la tâche d'installation : elle ne reprend rien de l'utilisateur (ni ses variables d'environnement, ni
# ses modules). L'utilisateur est inscrit ici, par l'administrateur, dans ses arguments (-Sid <utilisateur>) : c'est le
# seul pour qui l'aide travaille, et le seul (avec les administrateurs) qui peut lire et lancer la tâche. Elle remplace
# l'ancienne, du même nom, qui tournait « avec les droits les plus élevés » sous son compte (jusqu'à Mindset 2.10.0).
# (\z et non $ : $ laisserait passer un retour à la ligne final)
$RegleTacheAide = '^[A-Za-z0-9 ]{1,40} \(aide\)\z'
$RegleProgramme = '^[^\\/:*?"<>|\x00-\x1f]+\.exe\z'

function Register-TacheAide([string]$Nom, [string]$ExeAide, [string]$Sid) {
    if ($Nom -cnotmatch $RegleTacheAide) { throw 'Nom de tâche refusé.' }
    if ($Sid -notmatch $SidValide) { throw 'Utilisateur inconnu.' }
    if (-not (Test-Path -LiteralPath $ExeAide)) { throw "Programme introuvable : $ExeAide" }
    $pr = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $act = New-ScheduledTaskAction -Execute "`"$ExeAide`"" -Argument "-Sid $Sid" -WorkingDirectory (Split-Path $ExeAide -Parent)
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName $Nom -Action $act -Principal $pr -Settings $set -Description 'Partie administrateur de l''appli : ne fait que les actions de sa liste stricte, à la demande de l''appli.' -Force | Out-Null
    Set-DroitsTache $Nom $Sid
}

# Les tâches d'aide de l'utilisateur $Sid encore sous son compte « avec les droits les plus élevés » (créées par Mindset
# 2.10.0 ou avant) : refaites en SYSTEM pour lui, vers le même programme s'il est bien dans le dossier protégé d'une appli.
# Celles d'un autre compte, déjà en SYSTEM, ou vers un programme ailleurs ne sont pas touchées.
function Update-TachesAide([string]$Sid) {
    foreach ($t in @(Get-ScheduledTask -TaskPath '\Mindset\' -ErrorAction SilentlyContinue)) {
        try {
            if ([string]$t.TaskName -cnotmatch $RegleTacheAide) { continue }
            if ((ConvertTo-Sid ([string]$t.Principal.UserId)) -ne $Sid) { continue }
            $a = @($t.Actions)
            if ($a.Count -ne 1) { continue }
            $exe = ([string]$a[0].Execute).Trim('"')
            if ($exe -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetFileName($exe) -notmatch $RegleProgramme) { continue }
            # (refusé hors du dossier protégé des programmes : par la tâche, celui de la tâche)
            if ($ParTache) { $null = Get-DossierTache (Split-Path $exe -Parent) } else { $null = Test-DossierMindset (Split-Path $exe -Parent) }
            Register-TacheAide ([string]$t.TaskName) $exe $Sid
        } catch {}
    }
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
    # Seulement ceux de l'utilisateur de Mindset : en SYSTEM (ou en administrateur), Windows montre aussi les programmes des
    # autres comptes ouverts sur le PC, qui peuvent utiliser la même copie (X:\Mindset, Program Files\Mindset)
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $liste = @($liste | Where-Object {
        if ($Sid) {
            $proprietaire = ''
            try { $proprietaire = [string](Invoke-CimMethod -InputObject (Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$_.Id)") -MethodName GetOwnerSid -ErrorAction Stop).Sid } catch {}
            $proprietaire -eq $Sid
        } else { $_.SessionId -eq $session }   # (lancement direct sans utilisateur : celui qui a accepté la demande de Windows, dans sa session)
    })
    if (-not $liste.Count) { return }
    $liste | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

# Demande passée par la tâche « \Mindset\Mindset (installation) ». Tout ce qu'elle contient est revérifié plus bas
# (dossiers, noms, zips du dossier telechargements et leur signature) ; l'utilisateur est toujours celui de la tâche.
# Rien n'est effacé ni écrit dans le dossier de l'utilisateur (c'est Mindset qui efface sa demande) : en SYSTEM, un lien
# glissé dans ce dossier ferait effacer n'importe quel fichier du PC. Une demande déjà reçue (même Id) n'est pas refaite.
$ParTache = ($Action -eq 'demande')
if ($ParTache) {
    $j = $null
    try {
        if (-not $Demande -or -not (Test-SansLien $Demande)) { exit }
        $fi = New-Object IO.FileInfo $Demande
        if (-not $fi.Exists -or $fi.Length -gt 16KB) { exit }
        $j = [IO.File]::ReadAllText($Demande, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { $j = $null }
    # (le texte de l'erreur n'est pas recopié : il pourrait citer le contenu d'un fichier qui n'est pas une demande)
    if (-not $j) { Write-Resultat $false 'Demande illisible.'; exit }
    try {
        if ([string]$j.Id -notmatch '^[0-9a-f]{8,32}\z') { exit }
        $recu = ''
        try { $recu = [string](Get-ItemProperty -Path $CleInstallation -Name 'Recu' -ErrorAction Stop).Recu } catch {}
        if ($recu -eq [string]$j.Id) { exit }
        $IdDemande = [string]$j.Id
        # Accusé de réception : Mindset sait que la tâche a pris sa demande (sinon, il passe par la demande de Windows)
        try { New-Item -Path $CleInstallation -Force | Out-Null; Set-ItemProperty -Path $CleInstallation -Name 'Recu' -Value $IdDemande } catch {}
        if ([string]$j.Action -notin 'appli', 'mindset-maj', 'supprimer', 'taches') { Write-Resultat $false 'Demande refusée.'; exit }
        $Action = [string]$j.Action
        foreach ($n in 'Zip', 'Signature', 'Destination', 'DossierZip', 'Exe', 'AncienExe', 'Version', 'TacheAide', 'ExeAide', 'Appli') {
            $v = $j.PSObject.Properties[$n]
            if ($v -and $v.Value -is [string]) { Set-Variable -Name $n -Value ([string]$v.Value) }
        }
        if ($j.AttendrePid) { $AttendrePid = [int]$j.AttendrePid }
        if ([string]$j.Cache -eq '1') { $Cache = [switch]$true }
    } catch { Write-Resultat $false 'Demande illisible.'; exit }
    if (-not $Sid) {
        # L'ancienne tâche (sous le compte de l'utilisateur, avec les droits les plus élevés) : elle ne fait plus qu'une
        # chose, se remplacer par la tâche SYSTEM. L'utilisateur est celui pour qui elle a été créée.
        if ($Action -ne 'taches') { Write-Resultat $false 'Ancienne tâche d''installation : elle doit d''abord être remplacée.'; exit }
        try { $Sid = ConvertTo-Sid ([string](Get-ScheduledTask -TaskPath '\Mindset\' -TaskName 'Mindset (installation)' -ErrorAction Stop).Principal.UserId) } catch { $Sid = '' }
        if ($Sid -notmatch $SidValide -or $Sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { Write-Resultat $false 'Utilisateur inconnu.'; exit }
    } elseif ($Sid -notmatch $SidValide) { Write-Resultat $false 'Utilisateur inconnu.'; exit }
}

try {
    . (Join-Path $PSScriptRoot 'modules\signature.ps1')
    . (Join-Path $PSScriptRoot 'modules\paquets.ps1')
    if ($ParTache) {
        # (mise à jour de Mindset : il s'est déjà fermé, il est relancé même si rien n'est fait)
        try { Initialize-RacineTache } catch { if ($Action -eq 'mindset-maj') { $null = & $Schtasks /Run /TN '\Mindset\Mindset (démarrage)' 2>&1 }; throw }
        # À chaque demande : les versions déjà installées sont gardées, et les parties administrateur des applis de cet
        # utilisateur encore sous son compte (créées par Mindset 2.11.0 ou avant, qu'une mise à jour directe de Mindset
        # laisse en place) sont refaites en SYSTEM
        try { Save-VersionsInstallees } catch {}
        try { Update-TachesAide $Sid } catch {}
    }

    switch ($Action) {
        'appli' {
            # L'appli : une de apps.json. Son dossier, le dossier de son zip, son programme et sa partie administrateur
            # viennent de là (une demande qui en donne d'autres est refusée)
            $app = Get-AppliConnue $Appli
            $dest = if ($ParTache) { Get-DossierTache $Destination } else { Test-DossierMindset $Destination }
            if ((Split-Path $dest -Leaf) -ine $app.Nom) { throw "Dossier refusé : $Destination" }
            if ($DossierZip -match '[\\/:*?"<>|]') { throw 'Nom de dossier refusé.' }
            if (-not $DossierZip) { $DossierZip = $app.DossiersZip[0] }
            if ($app.DossiersZip -notcontains $DossierZip) { throw 'Nom de dossier refusé.' }
            # Tout est vérifié AVANT d'arrêter quoi que ce soit : noms, tâche d'aide, ancienne copie, puis la signature du zip
            # (sinon une demande écrite sans droits ferait arrêter en administrateur n'importe quel programme, même avec un faux zip)
            foreach ($n in @($Exe, $ExeAide) | Where-Object { $_ }) { if ($n -notmatch $RegleProgramme) { throw 'Nom de programme refusé.' } }
            if ($TacheAide -and $TacheAide -cnotmatch $RegleTacheAide) { throw 'Nom de tâche refusé.' }
            if ($Exe -and $Exe -ine $app.Exe) { throw 'Nom de programme refusé.' }
            # (sa partie administrateur : créée si la demande la prévoit, et seulement celle de apps.json)
            if (($TacheAide -or $ExeAide) -and ($TacheAide -cne $app.TacheAide -or $ExeAide -ine $app.ExeAide)) { throw 'Partie administrateur refusée : ce n''est pas celle de apps.json.' }
            $Exe = $app.Exe
            Assert-Telechargement $Zip; Assert-Telechargement $Signature
            $octets = [IO.File]::ReadAllBytes($Zip)
            $sig = [IO.File]::ReadAllBytes($Signature)
            # Prise en charge : l'ancienne copie est le programme <Exe> d'un dossier, donné par son chemin complet, et il existe
            if ($AncienExe) {
                $ok = $false
                try { $ok = $AncienExe -match '^[A-Za-z]:\\[^"*?<>|]+\z' -and [IO.Path]::GetFullPath($AncienExe) -ieq $AncienExe -and [IO.Path]::GetFileName($AncienExe) -ieq $Exe -and (Test-Path -LiteralPath $AncienExe -PathType Leaf) } catch {}
                if (-not $ok) { throw 'Ancienne copie refusée.' }
            }
            if (-not (Test-Signature $octets $sig (Join-Path $PSScriptRoot 'cles-publiques'))) { throw 'La signature du fichier téléchargé est invalide : rien n''a été installé.' }
            # Jamais en dessous de la plus haute version déjà installée sur ce PC (même supprimée depuis) : refusé avant
            # d'arrêter quoi que ce soit (Install-Paquet le revérifie sur ce qu'il extrait)
            $gardee = Get-VersionGardee $app.Id; $dansZip = Get-VersionZip $octets $DossierZip
            if ($gardee -and $dansZip -and (Test-VersionPlusRecente $gardee $dansZip)) { throw "Version $dansZip refusée : la version $gardee, plus récente, a déjà été installée sur ce PC." }
            # Mindset a demandé confirmation avant de fermer l'appli : tout ce qui tourne depuis son dossier (son hôte, l'ancien
            # <Appli>.exe, sa partie administrateur qui tient son programme ouvert), rien d'autre
            Stop-Programme $Exe $dest
            $installe = Install-Paquet -Zip $octets -Signature $sig -ClePublique (Join-Path $PSScriptRoot 'cles-publiques') -Destination $dest -DossierZip $DossierZip -Exe $Exe -VersionMinimale (Get-VersionGardee $app.Id)
            try { Save-VersionGardee $app.Id (Get-VersionDossier $installe) } catch {}
            # Prise en charge : les tâches planifiées de l'utilisateur qui lançaient l'ancienne copie (en administrateur, que
            # Mindset sans droits ne peut pas modifier) lancent désormais la nouvelle. Seulement les siennes (jamais celles du
            # système, d'un autre compte, de Windows dans \Microsoft\ ni de Mindset dans \Mindset\), et toutes leurs actions
            # sont gardées (seule celle qui lançait l'ancienne copie change).
            if ($AncienExe -and $Sid -match $SidValide) {
                $nouveau = Join-Path $installe $Exe
                foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
                    if ([string]$t.TaskPath -like '\Microsoft\*' -or [string]$t.TaskPath -like '\Mindset\*') { continue }
                    if ((ConvertTo-Sid ([string]$t.Principal.UserId)) -ne $Sid) { continue }
                    $actions = @($t.Actions); $change = $false
                    foreach ($act in $actions) {
                        if ($act -and $act.PSObject.Properties['Execute'] -and ([string]$act.Execute).Trim('"') -ieq $AncienExe) { $act.Execute = "`"$nouveau`""; $change = $true }
                    }
                    if ($change) { Set-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Action $actions | Out-Null }
                }
            }
            # (une version de l'appli sans programme d'aide s'installe quand même, sans tâche)
            if ($TacheAide -and $ExeAide -and (Test-Path -LiteralPath (Join-Path $installe $ExeAide))) { Register-TacheAide $TacheAide (Join-Path $installe $ExeAide) $Sid }
            Write-Resultat $true $installe
        }
        'mindset' {
            # Disque choisi : C: (Program Files) par défaut, ou X:\Mindset
            $programmes = if ($Disque) { Initialize-RacineDisque $Disque $Sid } else { Join-Path $DossierProgrammes 'Mindset' }
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
            # (le dossier des programmes appartient aux Administrateurs : la tâche le vérifie à chaque demande)
            if (-not $Disque) { Set-ProprietaireAdmins $programmes }
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
                # (par la tâche : exactement le Mindset de la tâche)
                $dest = if ($ParTache) { Get-DossierTache $Destination } else { Test-DossierMindset $Destination }
                if ((Split-Path $dest -Leaf) -ne 'Mindset' -or ($ParTache -and $dest -ine $DossierMindsetTache)) { throw "Dossier refusé : $Destination" }
                $relance = Join-Path $dest 'Mindset.exe'
                if ($AttendrePid) { try { Wait-Process -Id $AttendrePid -Timeout 30 -ErrorAction Stop } catch {} }
                Start-Sleep -Milliseconds 500
                Assert-Telechargement $Zip; Assert-Telechargement $Signature
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
                # Relancé dans tous les cas : la nouvelle version, ou l'ancienne si la mise à jour a échoué, toujours sans
                # les droits administrateur. Par sa tâche de démarrage (sous le compte de l'utilisateur, sans droits) : caché
                # près de l'horloge, ou avec sa fenêtre si la mise à jour a été demandée à l'écran (Mindset l'a noté dans
                # ses réglages). Par la tâche SYSTEM, jamais autrement (lancé d'ici, il tournerait en SYSTEM, hors de la
                # session de l'utilisateur). En lancement direct (la demande de Windows), par l'Explorateur si besoin.
                $fait = $false
                if ($Cache -or $ParTache) { $null = & $Schtasks /Run /TN '\Mindset\Mindset (démarrage)' 2>&1; $fait = ($LASTEXITCODE -eq 0) }
                if (-not $fait -and -not $ParTache) { Start-Process -FilePath $Explorer -ArgumentList "`"$([IO.Path]::GetFullPath($relance))`"" }
            }
            return
        }
        'taches' {
            # Installation existante (Mindset 0.1.9 ou avant) : ses tâches planifiées, sans réinstaller (par la tâche :
            # exactement le Mindset de la tâche)
            $dest = if ($ParTache) { Get-DossierTache $Destination } else { Test-DossierMindset $Destination }
            if ((Split-Path $dest -Leaf) -ne 'Mindset' -or ($ParTache -and $dest -ine $DossierMindsetTache)) { throw "Dossier refusé : $Destination" }
            Register-TachesMindset $dest $Sid
            Write-Resultat $true $dest
        }
        'supprimer' {
            # (par la tâche : un dossier directement à côté du Mindset de la tâche, ou ce Mindset lui-même)
            $dest = if ($ParTache) { Get-DossierTache $Destination } else { Test-DossierMindset $Destination }
            if ($AttendrePid) { try { Wait-Process -Id $AttendrePid -Timeout 30 -ErrorAction Stop } catch {} }
            if ($Exe) { Stop-Programme $Exe $dest }   # (seulement les programmes de ce dossier)
            if ((Split-Path $dest -Leaf) -ne 'Mindset') {
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            } else {
                # Mindset lui-même, sans son désinstalleur autonome (une copie d'avant lui). Mindset est déjà fermé et ne
                # lira pas la réponse : chaque étape est tentée, puis ce qui n'a pas pu être retiré est dit à l'utilisateur.
                $restes = @()
                if (Test-Path -LiteralPath $dest) { try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop } catch { $restes += "le dossier $dest ($($_.Exception.Message))" } }
                Unregister-TachesMindset
                foreach ($t in @(Get-ScheduledTask -TaskPath '\Mindset\' -ErrorAction SilentlyContinue)) { $restes += "la tâche planifiée « \Mindset\$($t.TaskName) »" }
                # (l'entrée « Applications installées » reste tant que le dossier est là : elle sert à relancer la désinstallation ;
                # par la tâche, HKLM:\SOFTWARE\Mindset reste aussi tant qu'il y a des restes : c'est là que Mindset les lira)
                $cles = @(if (-not ($ParTache -and $restes)) { 'HKLM:\SOFTWARE\Mindset' }) + @(if (-not (Test-Path -LiteralPath $dest)) { $CleDesinstall })
                foreach ($c in $cles) {
                    try { if (Test-Path -Path $c) { Remove-Item -Path $c -Recurse -Force -ErrorAction Stop } } catch { $restes += "la clé du registre $c" }
                }
                if ($restes) {
                    $texte = "Mindset n'a pas pu être retiré entièrement. Ce qui reste :`n`n- $($restes -join "`n- ")`n`nRedémarre l'ordinateur, puis relance la désinstallation de Mindset (Paramètres de Windows, « Applications installées »)."
                    if ($ParTache) {
                        # En SYSTEM, aucune fenêtre (personne ne la verrait, et elle bloquerait la tâche) : Mindset l'affichera
                        try { Set-ItemProperty -Path $CleInstallation -Name 'Restes' -Value $texte } catch {}
                    } else {
                        try {
                            Add-Type -AssemblyName System.Windows.Forms
                            [void][System.Windows.Forms.MessageBox]::Show($texte, 'Désinstaller Mindset', 'OK', 'Warning')
                        } catch {}
                    }
                    Write-Resultat $false "Il reste : $($restes -join ' ; ')"
                    return
                }
                $IdDemande = ''   # (la réponse irait dans HKLM:\SOFTWARE\Mindset, qui vient d'être retiré)
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
