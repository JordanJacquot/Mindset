# Mindset : tests automatiques des refus du mini-installateur, version PowerShell, et du relais qui passe la main à la
# version Rust.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-installer.ps1
#
# Depuis l'étape 2 du passage en Rust, le mini-installateur livré est MindsetInstallateur.exe (rust\mindset-installateur,
# jugé sur le même corpus par « cargo test ») et Mindset\fichiers\installer-admin.ps1 n'est plus qu'un relais vers lui.
# Ici :
#   - le corpus cas\installateur passe à la version PowerShell d'avant, gardée pour cela (outils\installer-admin-powershell.ps1) :
#     les cas restent justes pour les deux versions ;
#   - le relais est essayé à part : paramètres passés tels quels à un faux MindsetInstallateur.exe, tâches repointées,
#     refus quand l'exe n'est pas dans un dossier protégé, protections des premières lignes.
#
# installer-admin.ps1 tourne en administrateur, lancé par la tâche « \Mindset\Mindset (installation) » : il lit une
# demande écrite par Mindset sans droits, et revérifie tout. Ici, chaque refus est essayé pour de vrai : la demande est
# refusée, avec le bon message, et rien n'est fait. Chaque chemin a aussi au moins une demande valable, acceptée (un
# installateur qui refuserait tout ne passerait pas ces tests).
# Les cas sont écrits en données dans cas\installateur\*.json (format dans cas\LISEZMOI.md) : les mêmes serviront à
# l'installateur en Rust. Seuls restent ici ceux qui ne s'écrivent pas en données (lien sur le disque, texte du script,
# vrais programmes).
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).
#
# Aucun droit administrateur, rien sur le vrai PC :
#   - une copie d'installer-admin.ps1 (avec ses modules et une clé publique de test) tourne dans un autre PowerShell,
#     sous %TEMP%, avec Program Files et LOCALAPPDATA détournés vers le dossier de test ;
#   - tout ce qui agirait sur Windows est remplacé par de fausses fonctions qui notent ce qui aurait été fait dans un
#     journal : tâches planifiées, registre (HKLM), droits des dossiers (Set-Acl, icacls), disques, programmes arrêtés
#     ou lancés, objets COM, fenêtres ;
#   - les fausses fonctions refusent toute écriture hors du dossier de test ;
#   - « X:\Mindset » est un faux disque (lecteur PowerShell sur une lettre libre, vers un dossier de test) ;
#   - aucun réseau, et la vraie clé privée de la suite n'est jamais utilisée (clé de test créée à la volée).

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# Aucun réseau : toute connexion passe par un relais qui n'existe pas (un test qui partirait sur Internet échoue ici)
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)

# ---------------------------------------------------------------------------------------------------------------
# Le petit outil de test (le même que tester-securite.ps1)
# ---------------------------------------------------------------------------------------------------------------
$script:Reussis = 0
$script:Echoues = @()
$script:Connus = @()
# -Connu <explication> : un défaut déjà connu, signalé (CONNU) sans faire échouer les tests, en attendant sa correction
function Test-Cas([string]$Nom, [scriptblock]$Condition, [string]$Connu = '') {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
        if ($Connu) { Write-Host '         (ce défaut connu semble corrigé : retirer -Connu de ce cas)' -ForegroundColor Yellow }
    } elseif ($Connu) {
        $script:Connus += "$Nom : $Connu"
        Write-Host "  CONNU  $Nom ($Connu)" -ForegroundColor Yellow
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
        if ($script:Dernier) { $script:Dernier.Lignes | ForEach-Object { Write-Host "           | $_" -ForegroundColor DarkGray } }
    }
    $script:Dernier = $null
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

# ---------------------------------------------------------------------------------------------------------------
# Le lanceur : l'autre PowerShell où tourne la copie d'installer-admin.ps1, avec ses fausses fonctions
# ---------------------------------------------------------------------------------------------------------------
$texteLanceur = @'
param([string]$Script, [string]$Parametres, [string]$Journal, [string]$Dossier, [string]$Lettre, [string]$LettreAmovible, [switch]$VraisProgrammes,
      [string]$SidTache, [switch]$TachesRestantes, [switch]$DemarrageKo, [switch]$AideAncienne, [string]$Racine)
$global:TJournal = $Journal
$global:TRacine = $Racine   # (droits du dossier des programmes : '' protégé, 'ouverte' modifiable par les utilisateurs, 'proprietaire' à l'utilisateur)
$global:TAideAncienne = [bool]$AideAncienne
$global:TDossier = $Dossier
$global:TPermis = @(($Dossier.TrimEnd('\') + '\'), "$($Lettre):\")
$global:TLettre = $Lettre; $global:TLettreAmovible = $LettreAmovible
$global:TSidTache = $SidTache; $global:TTachesRestantes = [bool]$TachesRestantes; $global:TDemarrageKo = [bool]$DemarrageKo
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)
# Les variables d'environnement de l'utilisateur, piégées : l'installateur ne doit jamais s'en servir (Program Files et le
# dossier des données lui viennent de Windows). Une écriture vers le piège est refusée et notée. (SystemRoot et windir
# ne peuvent pas l'être ici : .NET ne trouverait plus ses propres fichiers. Le test qui lit le vrai installateur vérifie
# qu'aucune variable n'y est lue.)
foreach ($n in 'ProgramFiles', 'ProgramData', 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') { Set-Item -Path "env:$n" -Value "Z:\piege-variable-$n" }
# Le faux disque X: (une lettre libre sur ce PC)
New-PSDrive -Name $Lettre -PSProvider FileSystem -Root (Join-Path $Dossier 'disque') -Scope Global | Out-Null

function global:Add-Journal([string]$Ligne) { [IO.File]::AppendAllText($global:TJournal, "$Ligne`r`n", [Text.UTF8Encoding]::new($false)) }
function global:Get-TexteArgs($Liste) {
    (@($Liste) | ForEach-Object { if ($_ -is [pscustomobject] -and $_.PSObject.Properties['Texte']) { "($($_.Texte))" } else { "$_" } }) -join ' '
}
function global:Test-Registre([string]$Chemin) { $Chemin -match '^\s*(HKLM|HKCU|HKCR|HKU|Registry)[:\\]' }
# Écriture sur le disque : seulement dans le dossier de test ou sur le faux disque ; sinon notée et refusée
function global:Assert-Permis([string]$Chemin) {
    if (-not $Chemin) { return }
    $c = ''
    try { if ([IO.Path]::IsPathRooted($Chemin)) { $c = [IO.Path]::GetFullPath($Chemin) } } catch {}
    foreach ($p in $global:TPermis) { if ($c -and ($c + '\').StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return } }
    Add-Journal "INTERDIT écriture hors du dossier de test : $Chemin"
    throw "Écriture hors du dossier de test refusée : $Chemin"
}

# Fichiers : vrais, mais seulement dans le dossier de test. Registre : jamais, seulement noté.
function global:New-Item {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string]$ItemType, [switch]$Force)
    if (Test-Registre "$Path") {
        if ("$Path" -eq 'HKLM:\SOFTWARE\Mindset\Installation') { Add-Journal "REPONSE clé $Path" } else { Add-Journal "ACTION registre : création de $Path" }
        return
    }
    foreach ($p in $Path) { Assert-Permis $p }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function global:Set-ItemProperty {
    [CmdletBinding()] param([string]$Path, [string]$Name, [object]$Value)
    # (les versions gardées : dans des fichiers du test, relus par Get-ItemProperty)
    if ($Path -eq 'HKLM:\SOFTWARE\Mindset\Versions') { [IO.File]::WriteAllText((Join-Path $global:TDossier "versions\$Name.txt"), [string]$Value) }
    if ($Path -eq 'HKLM:\SOFTWARE\Mindset\Installation' -and $Name -eq 'Resultat') { Add-Journal "RESULTAT $Value"; return }
    # (l'accusé de réception : gardé dans un fichier du test, relu par Get-ItemProperty)
    if ($Path -eq 'HKLM:\SOFTWARE\Mindset\Installation' -and $Name -eq 'Recu') { Add-Journal "RECU $Value"; [IO.File]::WriteAllText((Join-Path $global:TDossier 'recu.txt'), [string]$Value); return }
    if ($Path -eq 'HKLM:\SOFTWARE\Mindset\Installation' -and $Name -eq 'Restes') { Add-Journal "RESTES $Value"; return }
    Add-Journal "ACTION registre : $Path\$Name = $Value"
}
function global:Get-ItemProperty {
    [CmdletBinding()] param([string]$Path, [string]$Name)
    if ($Path -eq 'HKLM:\SOFTWARE\Mindset\Installation' -and $Name -eq 'Recu' -and [IO.File]::Exists((Join-Path $global:TDossier 'recu.txt'))) {
        return [pscustomobject]@{ Recu = [IO.File]::ReadAllText((Join-Path $global:TDossier 'recu.txt')) }
    }
    if ($Path -eq 'HKLM:\SOFTWARE\Mindset\Versions' -and $Name -match '^[a-z0-9-]+$' -and [IO.File]::Exists((Join-Path $global:TDossier "versions\$Name.txt"))) {
        return [pscustomobject]@{ $Name = [IO.File]::ReadAllText((Join-Path $global:TDossier "versions\$Name.txt")) }
    }
    Add-Journal "LECTURE registre $Path $Name"
    throw "Valeur absente : $Path $Name"
}
# Le faux profil de chaque utilisateur (ProfileList) : <dossier de test>\Profils\<SID>, noté comme Windows le fait
# (%SystemDrive% au début quand il est sur le disque de Windows)
function global:Get-Item {
    [CmdletBinding()] param([string[]]$LiteralPath, [switch]$Force)
    if (Test-Registre "$LiteralPath") {
        Add-Journal "LECTURE registre $LiteralPath"
        if ("$LiteralPath" -match '\\ProfileList\\(S-1-5-21-[\d-]+)$') {
            $profil = Join-Path $global:TDossier "Profils\$($Matches[1])"
            $w = [Environment]::GetFolderPath('Windows')
            if ($profil.StartsWith($w.Substring(0, 2), [StringComparison]::OrdinalIgnoreCase)) { $profil = '%SystemDrive%' + $profil.Substring(2) }
            $o = [pscustomobject]@{ Profil = $profil }
            $o | Add-Member -MemberType ScriptMethod -Name GetValue -Value { param($Nom, $Defaut, $Options) if ($Nom -eq 'ProfileImagePath' -and "$Options" -eq 'DoNotExpandEnvironmentNames') { $this.Profil } else { $Defaut } }
            return $o
        }
        throw "Clé absente : $LiteralPath"
    }
    Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function global:New-ItemProperty {
    [CmdletBinding()] param([string]$Path, [string]$Name, [object]$Value, [string]$PropertyType, [switch]$Force)
    Add-Journal "ACTION registre : $Path\$Name = $Value"
}
function global:Remove-Item {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [switch]$Recurse, [switch]$Force)
    $tous = @(@($Path) + @($LiteralPath) | Where-Object { $_ })
    if (Test-Registre "$tous") { Add-Journal "ACTION registre : suppression de $tous"; return }
    foreach ($p in $tous) { Assert-Permis $p }
    Add-Journal "ACTION suppression de $tous"
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
function global:Test-Path {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Microsoft.PowerShell.Commands.TestPathType]$PathType = 'Any')
    if (Test-Registre "$Path$LiteralPath") { Add-Journal "LECTURE registre $Path$LiteralPath"; return $true }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function global:Copy-Item {
    [CmdletBinding()] param([string[]]$LiteralPath, [string]$Destination, [switch]$Recurse)
    Assert-Permis $Destination
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
function global:Move-Item {
    [CmdletBinding()] param([string[]]$LiteralPath, [string]$Destination)
    foreach ($p in @($LiteralPath) + $Destination) { Assert-Permis $p }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
}
# Droits des dossiers, disques
# (droits lus : ceux d'un dossier posé par l'installateur, propriétaire Administrateurs et utilisateurs en lecture ; -Racine
# ouverte : les utilisateurs peuvent y écrire ; -Racine proprietaire : il appartient à l'utilisateur, comme un dossier
# créé sans droits)
function global:Get-Acl {
    [CmdletBinding()] param([string]$LiteralPath)
    Add-Journal "LECTURE droits $LiteralPath"
    $s = [Security.AccessControl.DirectorySecurity]::new()
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'); $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $s.SetOwner($(if ($global:TRacine -eq 'proprietaire') { [Security.Principal.WindowsIdentity]::GetCurrent().User } else { $admins }))
    $h = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $s.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($admins, 'FullControl', $h, 'None', 'Allow'))
    $s.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, $(if ($global:TRacine -eq 'ouverte') { 'Modify' } else { 'ReadAndExecute' }), $h, 'None', 'Allow'))
    # (un droit qui ne vaut que pour ce qui sera créé dessous, comme « CREATOR OWNER » de Program Files : ne compte pas)
    $s.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-3-0'), 'FullControl', $h, 'InheritOnly', 'Allow'))
    $s
}
function global:Set-Acl { [CmdletBinding()] param([string]$LiteralPath, $AclObject) Add-Journal "ACTION droits posés sur $LiteralPath" }
function global:icacls { Add-Journal "ACTION droits (icacls) $(Get-TexteArgs $args)" }
function global:Get-CimInstance {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    if ($ClassName -eq 'Win32_Process' -and $Filter -match '^ProcessId=(\d+)$') { return [pscustomobject]@{ ProcessId = [int]$Matches[1] } }
    Add-Journal "LECTURE disque $Filter"
    if ($Filter -like "*'$($global:TLettre):'*") { return [pscustomobject]@{ DriveType = 3; FileSystem = 'NTFS' } }
    if ($Filter -like "*'$($global:TLettreAmovible):'*") { return [pscustomobject]@{ DriveType = 2; FileSystem = 'FAT32' } }
}
# Le propriétaire de chaque programme ouvert : celui de la tâche (l'utilisateur de Mindset), sauf ceux d'un autre compte
$global:TAutreCompte = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
$global:TProprietaires = @{ 109 = $global:TAutreCompte; 110 = $global:TAutreCompte }
function global:Invoke-CimMethod {
    [CmdletBinding()] param($InputObject, [string]$MethodName)
    $s = $global:TProprietaires[[int]$InputObject.ProcessId]
    [pscustomobject]@{ Sid = $(if ($s) { $s } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }) }
}
# Tâches planifiées
function global:New-ScheduledTaskPrincipal { [pscustomobject]@{ Texte = "Principal $(Get-TexteArgs $args)" } }
function global:New-ScheduledTaskSettingsSet { [pscustomobject]@{ Texte = 'Reglages' } }
function global:New-ScheduledTaskAction { [pscustomobject]@{ Texte = "Action $(Get-TexteArgs $args)" } }
function global:New-ScheduledTaskTrigger { [pscustomobject]@{ Texte = "Declencheur $(Get-TexteArgs $args)"; Delay = $null } }
function global:Register-ScheduledTask { Add-Journal "ACTION tâche créée : $(Get-TexteArgs $args)" }
function global:Unregister-ScheduledTask { Add-Journal "ACTION tâche retirée : $(Get-TexteArgs $args)" }
function global:Set-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath, $Action)
    Add-Journal "ACTION tâche modifiée : $TaskPath$TaskName -> $((@($Action) | ForEach-Object { $_.Execute }) -join ' | ')"
}
# Les tâches du PC : celles qui lancent l'ancienne copie d'une appli (<dossier de test>\ancienne\Appli.exe), de tous
# les genres ; et la tâche d'installation de Mindset, pour l'ancienne tâche (-SidTache : son utilisateur)
function global:Get-ScheduledTask {
    [CmdletBinding()] param([string]$TaskPath, [string]$TaskName)
    Add-Journal "LECTURE tâches $TaskPath$TaskName"
    if ($TaskPath -eq '\Mindset\' -and $TaskName -eq 'Mindset (installation)') {
        if (-not $global:TSidTache) { throw 'Tâche absente.' }
        return [pscustomobject]@{ TaskPath = '\Mindset\'; TaskName = $TaskName; Principal = [pscustomobject]@{ UserId = $global:TSidTache } }
    }
    if ($TaskPath -eq '\Mindset\') {
        if ($global:TTachesRestantes) { return [pscustomobject]@{ TaskPath = '\Mindset\'; TaskName = 'Mindset (démarrage)' } }
        if ($global:TAideAncienne) {
            # Des tâches d'aide d'avant (Mindset 2.10.0) : celle de l'utilisateur (à refaire en SYSTEM), celle d'un autre
            # compte, une vers un programme hors du dossier protégé, une déjà en SYSTEM (aucune des trois à toucher)
            $moi = [Security.Principal.WindowsIdentity]::GetCurrent()
            $pm = Join-Path $global:TDossier 'ProgramFiles\Mindset'
            function Get-Aide([string]$Nom, [string]$Compte, [string]$Exe) { [pscustomobject]@{ TaskPath = '\Mindset\'; TaskName = $Nom; Principal = [pscustomobject]@{ UserId = $Compte }; Actions = @([pscustomobject]@{ Execute = "`"$Exe`"" }) } }
            return @((Get-Aide 'Appli (aide)' $moi.Name "$pm\Appli\Aide.exe"), (Get-Aide 'Autre (aide)' $global:TAutreCompte "$pm\Appli\Aide.exe"),
                     (Get-Aide 'Piege (aide)' $moi.User.Value "$($global:TDossier)\victime\Aide.exe"), (Get-Aide 'Deja (aide)' 'SYSTEM' "$pm\Appli\Aide.exe"))
        }
        return
    }
    $anc = Join-Path $global:TDossier 'ancienne\Appli.exe'
    $moi = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    function Get-Act([string]$Exe) { [pscustomobject]@{ Execute = $Exe } }
    @(
        [pscustomobject]@{ TaskPath = '\'; TaskName = 'Appli (démarrage)'; Principal = [pscustomobject]@{ UserId = $moi }; Actions = @((Get-Act "`"$anc`""), (Get-Act 'C:\Autre\Autre.exe')) }
        [pscustomobject]@{ TaskPath = '\'; TaskName = 'Antivirus'; Principal = [pscustomobject]@{ UserId = 'S-1-5-18' }; Actions = @((Get-Act $anc)) }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Defrag\'; TaskName = 'Windows'; Principal = [pscustomobject]@{ UserId = $moi }; Actions = @((Get-Act $anc)) }
        [pscustomobject]@{ TaskPath = '\Mindset\'; TaskName = 'Mindset (aide)'; Principal = [pscustomobject]@{ UserId = $moi }; Actions = @((Get-Act $anc)) }
        [pscustomobject]@{ TaskPath = '\'; TaskName = 'Autre compte'; Principal = [pscustomobject]@{ UserId = $global:TAutreCompte }; Actions = @((Get-Act $anc)) }
        [pscustomobject]@{ TaskPath = '\'; TaskName = 'Groupe'; Principal = [pscustomobject]@{ UserId = $null; GroupId = 'Utilisateurs' }; Actions = @((Get-Act $anc)) }
    )
}
# Les programmes de Windows lancés par l'installateur (schtasks, icacls) : notés, jamais lancés
# (-DemarrageKo : la tâche de démarrage ne se lance pas)
function global:schtasks { Add-Journal "ACTION lancement schtasks $(Get-TexteArgs $args)"; $global:LASTEXITCODE = if ($global:TDemarrageKo -and "$args" -like '*(démarrage)*') { 1 } else { 0 } }
# Programmes
# (de faux programmes ouverts, avec leur chemin : Mindset lui-même, l'hôte Mindset.exe et l'ancien Appli.exe de l'appli,
# son aide, une autre appli au nom proche « AppliBis », des copies ailleurs, un processus au chemin illisible)
# -VraisProgrammes : les vrais Get-Process et Stop-Process, sur des programmes d'essai lancés par le test sous %TEMP%
if (-not $VraisProgrammes) {
    $pmt = Join-Path $Dossier 'ProgramFiles\Mindset'
    $global:TProcessus = @(
        [pscustomobject]@{ Id = 101; Path = "$pmt\Mindset\Mindset.exe" }
        [pscustomobject]@{ Id = 102; Path = "$pmt\Appli\Mindset.exe" }
        [pscustomobject]@{ Id = 103; Path = "$pmt\Appli\Appli.exe" }
        [pscustomobject]@{ Id = 104; Path = "$pmt\Appli\Aide.exe" }
        [pscustomobject]@{ Id = 105; Path = "$pmt\AppliBis\Appli.exe" }
        [pscustomobject]@{ Id = 106; Path = "$Dossier\ailleurs\Appli.exe" }
        [pscustomobject]@{ Id = 107; Path = "$Dossier\ailleurs\Mindset.exe" }
        [pscustomobject]@{ Id = 108; Path = $null }
        [pscustomobject]@{ Id = 109; Path = "$pmt\Appli\Mindset.exe"; SessionId = 98 }   # (un autre compte Windows, qui utilise la même copie)
        [pscustomobject]@{ Id = 110; Path = "$pmt\Appli\Appli.exe"; SessionId = 99 })   # (aussi, dans une autre session)
    foreach ($x in $global:TProcessus) { if (-not $x.PSObject.Properties['SessionId']) { $x | Add-Member SessionId ([Diagnostics.Process]::GetCurrentProcess().SessionId) } }
    function global:Get-Process { [CmdletBinding()] param([string[]]$Name) Add-Journal "LECTURE programmes ouverts $Name"; $global:TProcessus }
    function global:Stop-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force) process { Add-Journal "ACTION arrêt du programme $($InputObject.Path)" } }
}
function global:Wait-Process { Add-Journal "LECTURE attente $(Get-TexteArgs $args)" }
function global:Start-Process { [CmdletBinding()] param([string]$FilePath, [string[]]$ArgumentList) Add-Journal "ACTION lancement $FilePath $ArgumentList" }
function global:Start-Sleep { }
function global:New-Object {
    if ($args.Count -and "$($args[0])" -eq '-ComObject' -and "$($args[1])" -eq 'Schedule.Service') {
        # Le planificateur : seulement les droits posés sur une tâche et le retrait du dossier, notés
        $tache = [pscustomobject]@{}
        $tache | Add-Member -MemberType ScriptMethod -Name SetSecurityDescriptor -Value { param($Sddl, $Options) Add-Journal "ACTION droits de la tâche : $Sddl" }
        $dossier = [pscustomobject]@{ Tache = $tache }
        $dossier | Add-Member -MemberType ScriptMethod -Name GetTask -Value { param($Nom) Add-Journal "LECTURE tâche $Nom"; $this.Tache }
        $dossier | Add-Member -MemberType ScriptMethod -Name DeleteFolder -Value { param($Nom, $Options) Add-Journal "ACTION dossier de tâches retiré : $Nom" }
        $s = [pscustomobject]@{ Dossier = $dossier }
        $s | Add-Member -MemberType ScriptMethod -Name Connect -Value { }
        $s | Add-Member -MemberType ScriptMethod -Name GetFolder -Value { param($Chemin) $this.Dossier }
        return $s
    }
    if ($args.Count -and "$($args[0])" -eq '-ComObject') { Add-Journal "ACTION objet COM $($args[1])"; throw 'Objet COM interdit dans les tests.' }
    Microsoft.PowerShell.Utility\New-Object @args
}
function global:Add-Type {
    if ("$args" -match 'Windows\.Forms') { Add-Journal 'ACTION fenêtre'; throw 'Pas de fenêtre dans les tests.' }
    Microsoft.PowerShell.Utility\Add-Type @args
}

$p = @{}
$j = [IO.File]::ReadAllText($Parametres, [Text.Encoding]::UTF8) | ConvertFrom-Json
foreach ($q in $j.PSObject.Properties) { $p[$q.Name] = $q.Value }
try { & $Script @p; Add-Journal 'FIN' } catch { Add-Journal "ERREUR $($_.Exception.Message)" }
exit 0
'@

# ---------------------------------------------------------------------------------------------------------------
# Préparation : dossier temporaire, copie de l'installateur, clé de test, paquets signés
# ---------------------------------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "mindset-tests-installer-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
# (en nom long : sur GitHub, TEMP est en nom court « RUNNER~1 »)
$tmp = [IO.Path]::GetFullPath($tmp)
$tmp = (Get-Item -LiteralPath $tmp).FullName
$sha256 = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
$sidActuel = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$PF = Join-Path $tmp 'ProgramFiles'
$PM = Join-Path $PF 'Mindset'   # Program Files\Mindset (de test)

# Deux lettres de disque libres sur ce PC : le faux disque fixe, et un faux disque amovible
$prises = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() }) + @(Get-PSDrive | ForEach-Object { $_.Name.ToUpper() })
$libres = @([char[]]'QRSTUVWXYPONMLKJIH' | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $prises })
if ($libres.Count -lt 2) { throw 'Pas assez de lettres de disque libres pour le faux disque.' }
$L = $libres[0]; $LA = $libres[1]

function Save-Fichier([string]$Chemin, [string]$Contenu) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Chemin -Parent) | Out-Null
    [IO.File]::WriteAllText($Chemin, $Contenu, (New-Object Text.UTF8Encoding $false))
    $Chemin
}
function New-ZipTest($Entrees) {
    $ms = New-Object IO.MemoryStream
    $za = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($k in $Entrees.Keys) {
            $flux = $za.CreateEntry($k).Open()
            try { $o = [Text.Encoding]::UTF8.GetBytes([string]$Entrees[$k]); $flux.Write($o, 0, $o.Length) } finally { $flux.Dispose() }
        }
    } finally { $za.Dispose() }
    , $ms.ToArray()
}

# L'installateur testé, copié avec ses modules ; ses clés publiques : la clé de test seulement
$copie = Join-Path $tmp 'copie\fichiers'
New-Item -ItemType Directory -Force -Path (Join-Path $copie 'modules'), (Join-Path $copie 'cles-publiques'), (Join-Path $tmp 'journaux'), (Join-Path $tmp 'demandes'), (Join-Path $tmp 'resultats') | Out-Null
# Le bloc des dossiers de Windows (entre « <dossiers-windows> » et « </dossiers-windows> ») est remplacé par ceux du faux
# PC : Program Files de test, schtasks et icacls remplacés par de fausses fonctions. Le vrai bloc est vérifié à part
# (aucune variable d'environnement).
$texteInstalleur = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'installer-admin-powershell.ps1'), [Text.Encoding]::UTF8)
# Le relais livré (Mindset\fichiers\installer-admin.ps1)
$texteRelais = [IO.File]::ReadAllText((Join-Path $fichiers 'installer-admin.ps1'), [Text.Encoding]::UTF8)
$blocWindows = [regex]::Match($texteInstalleur, '(?s)# <dossiers-windows>.*?# </dossiers-windows>')
if (-not $blocWindows.Success) { throw 'Bloc <dossiers-windows> introuvable dans installer-admin.ps1.' }
$faux = @'
# <dossiers-windows> (faux PC des tests)
$DossierWindows = [Environment]::GetFolderPath('Windows')
$DossierSysteme = [Environment]::GetFolderPath('System')
$DossierProgrammes = Join-Path $global:TDossier 'ProgramFiles'
$PowerShellExe = Join-Path $DossierSysteme 'WindowsPowerShell\v1.0\powershell.exe'
$Schtasks = 'schtasks'
$Icacls = 'icacls'
$Explorer = Join-Path $DossierWindows 'explorer.exe'
$CleProfils = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
# </dossiers-windows>
'@
# Le module ScheduledTasks n'est pas importé dans la copie : ses commandes sont des fonctions, qui, importées par le
# script, passeraient devant les fausses du lanceur (et toucheraient aux vraies tâches planifiées de ce PC). Le vrai
# import est vérifié à part, dans le vrai installateur.
$importTaches = "'CimCmdlets', 'ScheduledTasks') {"
if (-not $texteInstalleur.Contains($importTaches)) { throw 'Import du module ScheduledTasks introuvable dans installer-admin.ps1.' }
$texteCopie = $texteInstalleur.Replace($blocWindows.Value, $faux.Trim()).Replace($importTaches, "'CimCmdlets') {")
if ($texteCopie -match "'ScheduledTasks'") { throw 'La copie de test importerait encore le module ScheduledTasks.' }
[IO.File]::WriteAllText((Join-Path $copie 'installer-admin.ps1'), $texteCopie, (New-Object Text.UTF8Encoding $true))
foreach ($m in 'signature.ps1', 'paquets.ps1', 'liste.ps1') { Copy-Item -LiteralPath (Join-Path $fichiers "modules\$m") -Destination (Join-Path $copie 'modules') }
# Son apps.json : l'appli de test (dossier Appli, programme Appli.exe, partie administrateur « Appli (aide) » Aide.exe)
# et une autre appli
$appsTest = @'
[
  { "id": "appli", "nom": "Appli", "zip": "Appli.zip", "dossier_zip": "Appli", "ancien_dossier_zip": "AncienAppli", "exe": "Appli.exe", "aide": "Appli (aide)", "aide_exe": "Aide.exe" },
  { "id": "autre", "nom": "Autre", "zip": "Autre.zip", "dossier_zip": "Autre", "exe": "Autre.exe" },
  { "id": "piege", "nom": "..\\Mindset", "zip": "Piege.zip", "dossier_zip": "Piege", "exe": "Piege.exe" }
]
'@
[IO.File]::WriteAllText((Join-Path $copie 'apps.json'), $appsTest, (New-Object Text.UTF8Encoding $true))
# La copie tourne depuis le dossier de Mindset de test (Program Files\Mindset\Mindset\fichiers), comme la vraie tâche :
# remise en place au début de chaque cas (voir Initialize-Etat)
$installeur = Join-Path $tmp 'ProgramFiles\Mindset\Mindset\fichiers\installer-admin.ps1'
$lanceur = Join-Path $tmp 'lanceur.ps1'
[IO.File]::WriteAllText($lanceur, $texteLanceur, (New-Object Text.UTF8Encoding $true))

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 3072
try {
    $rsa.PersistKeyInCsp = $false
    $null = Save-Fichier (Join-Path $copie 'cles-publiques\test.xml') $rsa.ToXmlString($false)
    function Save-Paquet([string]$Nom, $Entrees) {
        $z = New-ZipTest $Entrees
        [IO.File]::WriteAllBytes((Join-Path $paquets "$Nom.zip"), $z)
        [IO.File]::WriteAllBytes((Join-Path $paquets "$Nom.zip.sig"), $rsa.SignData($z, $sha256))
        Join-Path $paquets "$Nom.zip"
    }
    # (les zips téléchargés par Mindset : dans le dossier telechargements, à côté de sa demande)
    $paquets = Join-Path $tmp 'demandes\telechargements'
    New-Item -ItemType Directory -Force -Path $paquets | Out-Null
    $zipAppli = Save-Paquet 'Appli' ([ordered]@{ 'Appli/Appli.exe' = 'appli 2.0.0'; 'Appli/Aide.exe' = 'aide 2.0.0'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '2.0.0'`r`n" })
    $zipMindset = Save-Paquet 'Mindset' ([ordered]@{ 'Mindset/Mindset.exe' = 'mindset 2.0.0'; 'Mindset/fichiers/Mindset.ps1' = "`$AppVersion = '2.0.0'`r`n" })
    # Une signature fausse (celle d'un autre fichier)
    $sigFausse = Join-Path $paquets 'fausse.sig'
    [IO.File]::WriteAllBytes($sigFausse, $rsa.SignData([Text.Encoding]::UTF8.GetBytes('autre chose'), $sha256))
} finally { $rsa.Dispose() }

# Les dossiers de Mindset fournis par l'installation complète (Action mindset -Source)
$srcOk = Join-Path $tmp 'sources\Mindset'
$null = Save-Fichier (Join-Path $srcOk 'Mindset.exe') 'mindset nouveau'
$null = Save-Fichier (Join-Path $srcOk 'fichiers\Mindset.ps1') "`$AppVersion = '3.0.0'"
$null = Save-Fichier (Join-Path $srcOk 'LISEZMOI.txt') 'lisez-moi'
$srcSansExe = Join-Path $tmp 'sources\SansExe'
$null = Save-Fichier (Join-Path $srcSansExe 'fichiers\Mindset.ps1') "`$AppVersion = '3.0.0'"
$srcSansScript = Join-Path $tmp 'sources\SansScript'
$null = Save-Fichier (Join-Path $srcSansScript 'Mindset.exe') 'mindset nouveau'

# État de départ de chaque cas : Mindset 1.0.0 et une appli 1.0.0 dans Program Files\Mindset (de test), un dossier
# « victime » hors de Mindset, un faux disque vide
$racinesEtat = @($PF, (Join-Path $tmp 'disque'), (Join-Path $tmp 'Profils'), (Join-Path $tmp 'victime'), (Join-Path $tmp 'ancienne'))
function Initialize-Etat {
    foreach ($d in $racinesEtat) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } ; New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $null = Save-Fichier (Join-Path $PM 'Mindset\Mindset.exe') 'mindset 1.0.0'
    $null = Save-Fichier (Join-Path $PM 'Mindset\fichiers\Mindset.ps1') "`$AppVersion = '1.0.0'"
    $null = Save-Fichier (Join-Path $PM 'Appli\Appli.exe') 'appli 1.0.0'
    $null = Save-Fichier (Join-Path $PM 'Appli\Aide.exe') 'aide 1.0.0'
    $null = Save-Fichier (Join-Path $PM 'Appli\fichiers\Appli.ps1') "`$AppVersion = '1.0.0'"
    $null = Save-Fichier (Join-Path $tmp 'victime\important.txt') 'à garder'
    # La copie de l'installateur testée, dans le dossier de Mindset de test
    Copy-Item -Path (Join-Path $copie '*') -Destination (Join-Path $PM 'Mindset\fichiers') -Recurse -Force
    # Les versions gardées (faux HKLM:\SOFTWARE\Mindset\Versions) : celle de l'appli installée
    if (Test-Path -LiteralPath (Join-Path $tmp 'versions')) { Remove-Item -LiteralPath (Join-Path $tmp 'versions') -Recurse -Force }
    $null = Save-Fichier (Join-Path $tmp 'versions\appli.txt') '1.0.0'
    # (l'accusé de réception de la demande précédente, dans le faux registre)
    if (Test-Path -LiteralPath (Join-Path $tmp 'recu.txt')) { Remove-Item -LiteralPath (Join-Path $tmp 'recu.txt') -Force }
}
# Tous les fichiers et dossiers que l'installateur pourrait toucher : les fichiers avec leur taille et leur date (pas
# celle des dossiers, que Windows met à jour un peu après coup)
function Get-Etat {
    @(foreach ($d in $racinesEtat) { Get-ChildItem -LiteralPath $d -Recurse -Force | ForEach-Object { if ($_.PSIsContainer) { "$($_.FullName)\" } else { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } } }) | Sort-Object
}
function Get-Version([string]$Dossier) {
    $f = Join-Path $Dossier "fichiers\$(Split-Path $Dossier -Leaf).ps1"
    if (Test-Path -LiteralPath $f) { if ([IO.File]::ReadAllText($f) -match "'([\d.]+)'") { return $Matches[1] } }
    ''
}

# Lance la copie d'installer-admin.ps1 avec ces paramètres, depuis l'état de départ.
# Rend : Lignes (le journal), Actions (ce qui aurait été fait sur Windows), Reponse (la réponse : registre pour une
# demande, sinon le fichier -Resultat), Inchange (aucun fichier créé, modifié ou retiré), Erreur.
$script:NumeroCas = 0
# -SidTache : l'utilisateur de l'ancienne tâche (sans -Sid) ; -TachesRestantes : une tâche de Mindset ne part pas ;
# -GarderRecu : l'accusé de réception du cas précédent reste (la même demande relancée)
function Invoke-Installateur([hashtable]$Parametres, [scriptblock]$Preparer = $null, [switch]$SansResultat, [switch]$VraisProgrammes,
                             [string]$SidTache = '', [switch]$TachesRestantes, [switch]$GarderRecu, [switch]$DemarrageKo, [switch]$AideAncienne, [string]$Racine = '') {
    $n = ++$script:NumeroCas
    $recu = if ($GarderRecu -and (Test-Path -LiteralPath (Join-Path $tmp 'recu.txt'))) { [IO.File]::ReadAllText((Join-Path $tmp 'recu.txt')) } else { '' }
    Initialize-Etat
    if ($recu) { [IO.File]::WriteAllText((Join-Path $tmp 'recu.txt'), $recu) }
    if ($Preparer) { & $Preparer }
    $journal = Join-Path $tmp "journaux\$n.txt"; [IO.File]::WriteAllText($journal, '')
    $fichierReponse = Join-Path $tmp "resultats\$n.json"
    if (-not $SansResultat -and -not $Parametres.ContainsKey('Resultat')) { $Parametres['Resultat'] = $fichierReponse }
    $fp = Save-Fichier (Join-Path $tmp "journaux\$n.json") ($Parametres | ConvertTo-Json -Compress)
    $avant = @(Get-Etat)
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $sortie = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $lanceur `
            -Script $installeur -Parametres $fp -Journal $journal -Dossier $tmp -Lettre $L -LettreAmovible $LA @(if ($SidTache) { '-SidTache', $SidTache }) @(if ($VraisProgrammes) { '-VraisProgrammes' }) @(if ($TachesRestantes) { '-TachesRestantes' }) @(if ($DemarrageKo) { '-DemarrageKo' }) @(if ($AideAncienne) { '-AideAncienne' }) @(if ($Racine) { '-Racine', $Racine }) 2>&1
    } finally { $ErrorActionPreference = $eap }
    $lignes = @([IO.File]::ReadAllLines($journal, [Text.Encoding]::UTF8) | Where-Object { $_ })
    $reponse = $null
    $rr = @($lignes | Where-Object { $_ -like 'RESULTAT *' })
    if ($rr.Count) { $reponse = $rr[-1].Substring(9) | ConvertFrom-Json }
    elseif (Test-Path -LiteralPath $fichierReponse) { $reponse = [IO.File]::ReadAllText($fichierReponse, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    $changes = @(Compare-Object $avant @(Get-Etat) | ForEach-Object { "FICHIER $(if ($_.SideIndicator -eq '=>') { 'après' } else { 'avant' }) : $($_.InputObject)" })
    $r = [pscustomobject]@{
        Lignes   = $lignes + $changes
        Actions  = @($lignes | Where-Object { $_ -like 'ACTION *' -or $_ -like 'INTERDIT *' })
        Reponse  = $reponse
        Registre = [bool]$rr.Count
        Inchange = (-not $changes.Count)
        Erreur   = (@($lignes | Where-Object { $_ -like 'ERREUR *' }) -join ' ')
        Sortie   = $sortie
    }
    $script:Dernier = $r
    $r
}
# Une demande (comme celle écrite par Mindset) : $Contenu = table (écrite en JSON) ou texte brut ; -Taille : complétée
# par des espaces jusqu'à cette taille exacte en octets
function New-Demande($Contenu, [int]$Taille = 0) {
    $t = if ($Contenu -is [string]) { $Contenu } else { $Contenu | ConvertTo-Json -Compress }
    if ($Taille) { $t = $t + (' ' * ($Taille - [Text.Encoding]::UTF8.GetByteCount($t))) }
    Save-Fichier (Join-Path $tmp "demandes\$([guid]::NewGuid().ToString('N')).demande") $t
}
# Comme la tâche SYSTEM la lance : -Sid (l'utilisateur inscrit dans la tâche) et -Demande. -AncienneTache : comme
# l'ancienne tâche (sans -Sid), dont l'utilisateur est -SidTache.
function Invoke-Demande($Contenu, [int]$Taille = 0, [scriptblock]$Preparer = $null, [switch]$AncienneTache, [string]$SidTache = '', [switch]$TachesRestantes, [switch]$GarderRecu,
                        [switch]$AideAncienne, [string]$Racine = '') {
    $f = New-Demande $Contenu $Taille
    $p = @{ Action = 'demande'; Demande = $f }
    if (-not $AncienneTache) { $p.Sid = $sidActuel }
    Invoke-Installateur $p $Preparer -SidTache $SidTache -TachesRestantes:$TachesRestantes -GarderRecu:$GarderRecu -AideAncienne:$AideAncienne -Racine $Racine
}
function New-Id { [guid]::NewGuid().ToString('N') }
# Une copie de la table $Base, avec les valeurs de $Changes en plus ou à la place
function Merge-Table($Base, $Changes) { $d = @{} + $Base; foreach ($k in $Changes.Keys) { $d[$k] = $Changes[$k] }; $d }

# Refusé : réponse « ok = false » avec ce motif dans le message
function Test-Refuse($R, [string]$Motif) { [bool]($R.Reponse -and $R.Reponse.ok -eq $false -and ([string]$R.Reponse.message).Contains($Motif)) }
# Rien n'est fait : aucun fichier touché, aucune action sur Windows (sauf celles qui correspondent à $Permis)
function Test-RienFait($R, [string[]]$Permis = @()) {
    $autres = @($R.Actions | Where-Object { $a = $_; -not @($Permis | Where-Object { $a -like $_ }).Count })
    $R.Inchange -and -not $autres.Count
}
# Aucune réponse nulle part (ni registre, ni fichier) : la demande est ignorée sans un mot
function Test-SansReponse($R) { -not $R.Reponse -and -not $R.Registre }
function Test-Action($R, [string]$Texte) { [bool]@($R.Actions | Where-Object { $_.Contains($Texte) }).Count }
# (la tâche d'installation : en SYSTEM, l'utilisateur inscrit dans ses arguments, et lui seul peut la lancer)
function Test-TacheCreee($R, [string]$Nom, [string]$Sid = $sidActuel) {
    if ($Nom -eq 'Mindset (installation)') {
        return [bool]@($R.Actions | Where-Object { $_.Contains('ACTION tâche créée') -and $_.Contains("-TaskName $Nom -") -and $_.Contains('-UserId S-1-5-18 -LogonType ServiceAccount') -and $_.Contains("-Action demande -Sid $Sid -Demande") }).Count -and
            (Test-Action $R "ACTION droits de la tâche : D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;$Sid)")
    }
    # (la partie administrateur d'une appli : en SYSTEM aussi, l'utilisateur inscrit dans ses arguments, lui seul peut la lancer)
    if ($Nom -like '* (aide)') {
        return [bool]@($R.Actions | Where-Object { $_.Contains('ACTION tâche créée') -and $_.Contains("-TaskName $Nom -") -and $_.Contains('-UserId S-1-5-18 -LogonType ServiceAccount') -and $_.Contains(" -Argument -Sid $Sid ") }).Count -and
            (Test-Action $R "ACTION droits de la tâche : D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;$Sid)")
    }
    [bool]@($R.Actions | Where-Object { $_.Contains('ACTION tâche créée') -and $_.Contains("-TaskName $Nom -") -and $_.Contains("-UserId $Sid ") }).Count
}
function Test-SansTache($R) { -not @($R.Actions | Where-Object { $_ -like 'ACTION tâche*' }).Count }

# ---------------------------------------------------------------------------------------------------------------
# Le corpus de cas (cas\installateur\*.json, format décrit dans cas\LISEZMOI.md) : les mêmes cas serviront à
# l'installateur en Rust. Ici, chaque cas est passé à la copie d'installer-admin.ps1, sur le faux PC.
# ---------------------------------------------------------------------------------------------------------------
$dossierCas = Join-Path $racine 'cas\installateur'
# Le nombre de cas attendu au moins dans chaque fichier (un cas retiré ou un fichier vidé fait échouer le test)
$minimumCas = [ordered]@{ 'demande.json' = 31; 'appli.json' = 66; 'mindset.json' = 16; 'mindset-maj.json' = 9; 'taches.json' = 11
    'supprimer.json' = 11; 'systeme.json' = 12; 'ancienne-tache.json' = 5; 'prise-en-charge.json' = 9; 'programmes.json' = 6 }
$champsEntree = 'lancement', 'demande', 'demande_texte', 'demande_absente', 'taille', 'sid', 'sans_resultat', 'contexte'
$champsContexte = 'fichiers', 'retirer', 'copier', 'version_gardee', 'racine', 'aide_ancienne', 'taches_restantes', 'demarrage_ko', 'sid_tache', 'recu'
$champsAttendu = 'reponse', 'message', 'message_exact', 'message_absent', 'id_rendu', 'registre', 'rien_fait', 'actions_permises', 'actions', 'actions_absentes',
    'actions_absentes_motif', 'taches_creees', 'sans_tache', 'versions', 'existe', 'absent', 'version_gardee', 'erreur', 'arrets', 'nb_arrets', 'arrets_absents',
    'lignes', 'lignes_absentes', 'taches_modifiees', 'demande_gardee', 'avant'
# Les {valeurs} du faux PC ({id} : un numéro neuf pour chaque cas)
$valeursCas = @{
    '{tmp}' = $tmp; '{pf}' = $PF; '{pm}' = $PM; '{x}' = $L; '{xa}' = $LA
    '{zip-appli}' = $zipAppli; '{zip-mindset}' = $zipMindset; '{sig-fausse}' = $sigFausse
    '{src-ok}' = $srcOk; '{src-sans-exe}' = $srcSansExe; '{src-sans-script}' = $srcSansScript
    '{sid}' = $sidActuel; '{sid-autre}' = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    # (ce que lance la tâche d'installation de la version PowerShell : powershell.exe de System32)
    '{programme-installation}' = (Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe')
    '{arguments-installation}' = '-Argument -NoProfile -NonInteractive'
    '{ancienne}' = (Join-Path $tmp 'ancienne\Appli.exe')
}
function Expand-Texte([string]$T, [hashtable]$Valeurs) {
    foreach ($k in $Valeurs.Keys) { $T = $T.Replace($k, [string]$Valeurs[$k]) }
    if ($T -match '\{[a-z][a-z-]*\}') { throw "Valeur inconnue dans le corpus : $($Matches[0])" }
    $T
}
# Un objet lu dans le JSON, en table, avec les {valeurs} remplacées partout (textes, noms des champs, listes)
function ConvertTo-Valeur($V, [hashtable]$Valeurs) {
    if ($null -eq $V) { return $null }
    if ($V -is [string]) { return (Expand-Texte $V $Valeurs) }
    if ($V -is [Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $V.PSObject.Properties) { $h[(Expand-Texte $p.Name $Valeurs)] = ConvertTo-Valeur $p.Value $Valeurs }
        return $h
    }
    if ($V -is [Array]) { return , @(foreach ($x in $V) { ConvertTo-Valeur $x $Valeurs }) }
    $V
}
# La base du fichier complétée par le cas : un champ du cas remplace celui de la base ; un champ à null le retire
# (-GarderNull : il reste, à null, comme version_gardee)
function Join-Base($Base, $Cas, [switch]$GarderNull) {
    $d = @{}
    if ($Base) { foreach ($k in $Base.Keys) { $d[$k] = $Base[$k] } }
    if ($Cas) { foreach ($k in $Cas.Keys) { if ($null -eq $Cas[$k] -and -not $GarderNull) { $d.Remove($k) } else { $d[$k] = $Cas[$k] } } }
    $d
}
function Get-Arrets($R) { @($R.Actions | Where-Object { $_ -like 'ACTION arrêt du programme *' } | ForEach-Object { $_.Substring('ACTION arrêt du programme '.Length) } | Sort-Object) }

# Passe un cas du corpus à l'installateur. Rend le résultat (R), l'attendu (A), le fichier de la demande et son numéro.
function Invoke-CasInstallateur($Corpus, $Cas) {
    $v = @{} + $valeursCas; $v['{id}'] = New-Id
    $e = ConvertTo-Valeur $Cas.entree $v
    $a = ConvertTo-Valeur $Cas.attendu $v
    if (-not $e -or -not $a) { throw 'Cas sans entree ou sans attendu.' }
    $inconnus = @(@($e.Keys) | Where-Object { $_ -notin $champsEntree })
    if ($inconnus.Count) { throw "Champ d'entrée inconnu : $($inconnus -join ', ')" }
    $base = ConvertTo-Valeur $Corpus.base $v
    $donneId = ($e.demande -is [hashtable]) -and $e.demande.ContainsKey('Id')
    $demande = Join-Base $(if ($base) { $base.demande }) $e.demande
    $ctx = Join-Base $(if ($base) { $base.contexte }) $e.contexte -GarderNull
    $inconnus = @(@($ctx.Keys) | Where-Object { $_ -notin $champsContexte })
    if ($inconnus.Count) { throw "Champ de contexte inconnu : $($inconnus -join ', ')" }
    $lancement = [string]$e.lancement
    # (par la tâche, la demande porte un numéro neuf, sauf si le cas en donne un, ou le retire avec null)
    if ($lancement -ne 'direct' -and -not $donneId) { $demande['Id'] = $v['{id}'] }

    # L'état du faux PC propre au cas, posé après l'état de départ
    $script:CtxCas = $ctx
    $preparer = {
        $c = $script:CtxCas
        if ($c.fichiers) { foreach ($k in $c.fichiers.Keys) { $null = Save-Fichier $k ([string]$c.fichiers[$k]) } }
        if ($c.copier) { foreach ($k in $c.copier.Keys) { Copy-Item -LiteralPath $k -Destination $c.copier[$k] } }
        foreach ($k in @($c.retirer)) { if ($k) { Remove-Item -LiteralPath $k -Recurse -Force } }
        if ($c.ContainsKey('version_gardee')) {
            $dv = Join-Path $tmp 'versions'
            Remove-Item -LiteralPath $dv -Recurse -Force; New-Item -ItemType Directory -Path $dv | Out-Null
            if ($null -ne $c.version_gardee) { $null = Save-Fichier (Join-Path $dv 'appli.txt') ([string]$c.version_gardee) }
        }
        if ($c.recu) { [IO.File]::WriteAllText((Join-Path $tmp 'recu.txt'), [string]$c.recu) }
    }
    $options = @{ Preparer = $preparer; SidTache = [string]$ctx.sid_tache; TachesRestantes = [bool]$ctx.taches_restantes; DemarrageKo = [bool]$ctx.demarrage_ko
                  AideAncienne = [bool]$ctx.aide_ancienne; Racine = [string]$ctx.racine; SansResultat = [bool]$e.sans_resultat }
    $fichierDemande = ''
    if ($lancement -eq 'direct') {
        $p = $demande
    } elseif ($lancement -in 'tache', 'ancienne-tache') {
        $fichierDemande = if ($e.demande_absente) { Join-Path $tmp 'demandes\absente.demande' }
                          elseif ($e.ContainsKey('demande_texte')) { New-Demande ([string]$e.demande_texte) ([int]$e.taille) }
                          else { New-Demande $demande ([int]$e.taille) }
        $p = @{ Action = 'demande'; Demande = $fichierDemande }
        # (comme la tâche SYSTEM : -Sid, l'utilisateur inscrit dans la tâche ; l'ancienne tâche n'en a pas)
        if ($lancement -eq 'tache') { if (-not $e.ContainsKey('sid')) { $p.Sid = $sidActuel } elseif ($null -ne $e.sid) { $p.Sid = [string]$e.sid } }
    } else { throw "Lancement inconnu : $lancement" }
    $r = Invoke-Installateur $p @options
    [pscustomobject]@{ R = $r; A = $a; Demande = $fichierDemande; Id = $v['{id}'] }
}

# Compare le résultat à l'attendu du cas ; ce qui manque est ajouté au journal montré en cas d'échec
function Test-AttenduCas($X) {
    $R = $X.R; $A = $X.A
    $manques = New-Object Collections.Generic.List[string]
    foreach ($k in $A.Keys) { if ($k -notin $champsAttendu) { $manques.Add("champ attendu inconnu : $k") } }
    $msg = if ($R.Reponse) { [string]$R.Reponse.message } else { '' }
    if ($A.ContainsKey('reponse')) {
        $ok = switch ([string]$A.reponse) {
            'ok' { [bool]($R.Reponse -and $R.Reponse.ok -eq $true) }
            'refus' { [bool]($R.Reponse -and $R.Reponse.ok -eq $false) }
            'aucune' { [bool](Test-SansReponse $R) }
            default { $false } }
        if (-not $ok) { $manques.Add("réponse attendue : $($A.reponse)") }
    }
    foreach ($m in @($A.message)) { if ($null -ne $m -and -not $msg.Contains([string]$m)) { $manques.Add("message sans « $m »") } }
    if ($A.ContainsKey('message_exact') -and $msg -ne [string]$A.message_exact) { $manques.Add("message différent de « $($A.message_exact) »") }
    if ($A.ContainsKey('message_absent') -and $msg.Contains([string]$A.message_absent)) { $manques.Add("message avec « $($A.message_absent) »") }
    if ($A.id_rendu -and -not ($R.Reponse -and $R.Reponse.id -eq $X.Id)) { $manques.Add('numéro de la demande pas rendu') }
    if ($A.ContainsKey('registre') -and [bool]$R.Registre -ne [bool]$A.registre) { $manques.Add("réponse dans le registre : $($A.registre) attendu") }
    if ($A.rien_fait -and -not (Test-RienFait $R ([string[]]@($A.actions_permises | Where-Object { $_ })))) { $manques.Add('quelque chose a été fait') }
    foreach ($t in @($A.actions)) { if ($t -and -not (Test-Action $R $t)) { $manques.Add("action absente : $t") } }
    foreach ($t in @($A.actions_absentes)) { if ($t -and (Test-Action $R $t)) { $manques.Add("action en trop : $t") } }
    foreach ($t in @($A.actions_absentes_motif)) { if ($t -and @($R.Actions | Where-Object { $_ -match $t }).Count) { $manques.Add("action en trop (motif) : $t") } }
    foreach ($t in @($A.taches_creees)) { if ($t -and -not (Test-TacheCreee $R $t)) { $manques.Add("tâche pas créée comme attendu : $t") } }
    if ($A.sans_tache -and -not (Test-SansTache $R)) { $manques.Add('une tâche a été touchée') }
    if ($A.versions) { foreach ($k in $A.versions.Keys) { if ((Get-Version $k) -ne [string]$A.versions[$k]) { $manques.Add("version de $k : $($A.versions[$k]) attendue") } } }
    foreach ($t in @($A.existe)) { if ($t -and -not (Test-Path -LiteralPath $t)) { $manques.Add("absent : $t") } }
    foreach ($t in @($A.absent)) { if ($t -and (Test-Path -LiteralPath $t)) { $manques.Add("présent : $t") } }
    if ($A.ContainsKey('version_gardee')) {
        $f = Join-Path $tmp 'versions\appli.txt'
        $vu = if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { $null }
        if ($vu -ne $A.version_gardee) { $manques.Add("version gardée : $($A.version_gardee) attendue, $vu vue") }
    }
    if ($A.ContainsKey('erreur') -and [bool]$R.Erreur -ne [bool]$A.erreur) { $manques.Add("erreur : $($A.erreur) attendu") }
    if ($A.ContainsKey('arrets') -and ((Get-Arrets $R) -join '|') -ne ((@($A.arrets) | Sort-Object) -join '|')) { $manques.Add("programmes fermés : $(@($A.arrets) -join ', ') attendus") }
    if ($A.ContainsKey('nb_arrets') -and @($R.Lignes | Where-Object { $_ -like 'ACTION arrêt*' }).Count -ne [int]$A.nb_arrets) { $manques.Add("$($A.nb_arrets) programme(s) fermé(s) attendu(s)") }
    if ($A.ContainsKey('arrets_absents')) {
        foreach ($x in @(Get-Arrets $R)) { if (-not $x -or @($A.arrets_absents | Where-Object { $x.Contains($_) }).Count) { $manques.Add("programme fermé à tort : $x") } }
    }
    foreach ($t in @($A.lignes)) { if ($t -and -not @($R.Lignes | Where-Object { $_ -like $t }).Count) { $manques.Add("ligne absente : $t") } }
    foreach ($t in @($A.lignes_absentes)) { if ($t -and @($R.Lignes | Where-Object { $_ -like $t }).Count) { $manques.Add("ligne en trop : $t") } }
    if ($A.ContainsKey('taches_modifiees')) {
        $m = @($R.Actions | Where-Object { $_ -like 'ACTION tâche modifiée*' })
        if (($m -join "`n") -ne (@($A.taches_modifiees) -join "`n")) { $manques.Add('tâches modifiées différentes') }
    }
    if ($A.demande_gardee -and -not ($X.Demande -and (Test-Path -LiteralPath $X.Demande))) { $manques.Add('demande effacée') }
    if ($A.ContainsKey('avant')) {
        $l = @($R.Lignes); $i = [array]::IndexOf($l, [string]$A.avant[0])
        $j = @(0..($l.Count - 1) | Where-Object { $l[$_] -like [string]$A.avant[1] } | Select-Object -First 1)
        if (-not ($i -ge 0 -and $j.Count -and $j[0] -gt $i)) { $manques.Add("« $($A.avant[0]) » pas avant « $($A.avant[1]) »") }
    }
    if ($manques.Count) { $R.Lignes = @($R.Lignes) + @($manques | ForEach-Object { "ATTENDU manqué : $_" }) }
    -not $manques.Count
}

try {
    Write-Host 'Mindset : tests du mini-installateur (installer-admin.ps1)' -ForegroundColor Cyan
    Write-Host "Dossier de test : $tmp (faux disque $($L):, faux disque amovible $($LA):)"

    # =============================================================================================================
    # Les cas du corpus (cas\installateur), fichier par fichier
    # =============================================================================================================
    Write-Partie 'Le corpus de cas (cas\installateur)'
    # (les fichiers cote-mindset-*.json, le côté Mindset du protocole, sont lus par tester-mini-installateur.ps1, et
    # dossier-protege.json, une fonction seule, par tester-securite.ps1)
    $lus = @(Get-ChildItem -LiteralPath $dossierCas -Filter '*.json' -File | Where-Object { $_.Name -notlike 'cote-mindset-*' -and $_.Name -ne 'dossier-protege.json' } | ForEach-Object { $_.Name })
    Test-Cas "chaque fichier de cas\installateur est lu par ce test ($($lus.Count) fichiers)" { -not @($lus | Where-Object { -not $minimumCas.Contains($_) }).Count -and $lus.Count -eq $minimumCas.Count }
    foreach ($nomFichier in $minimumCas.Keys) {
        $corpus = [IO.File]::ReadAllText((Join-Path $dossierCas $nomFichier), [Text.Encoding]::UTF8) | ConvertFrom-Json
        Write-Partie "$($corpus.sujet) ($nomFichier)"
        $nCas = @($corpus.cas).Count
        Test-Cas "$nomFichier : format 1, au moins $($minimumCas[$nomFichier]) cas (trouvés : $nCas)" { $corpus.format -eq 1 -and $nCas -ge $minimumCas[$nomFichier] }
        foreach ($cas in @($corpus.cas)) {
            $c = $cas
            Test-Cas ([string]$c.nom) { Test-AttenduCas (Invoke-CasInstallateur $corpus $c) }
        }
    }

    # =============================================================================================================
    Write-Partie 'Ce qui ne s''écrit pas en données (lien sur le disque, fonction seule, texte du script, vrais programmes)'
    # =============================================================================================================
    # Une demande valable de référence : les tâches de Mindset, pour le Mindset de test
    $taches = @{ Action = 'taches'; Destination = (Join-Path $PM 'Mindset') }
    $appli = @{ Action = 'appli'; Appli = 'appli'; Zip = $zipAppli; Signature = "$zipAppli.sig"; Destination = (Join-Path $PM 'Appli'); DossierZip = 'Appli'; Exe = 'Appli.exe' }
    function Get-Appli([hashtable]$Changes) { Merge-Table $appli (Merge-Table @{ Id = (New-Id) } $Changes) }

    # Lien symbolique vers une demande valable. Sans le droit de créer un lien (PC sans mode développeur), un autre
    # point d'analyse NTFS (une étiquette de test posée sur le fichier) : le même attribut ReparsePoint.
    $f = New-Demande (@{ Id = (New-Id) } + $taches)
    $lien = Join-Path $tmp 'demandes\lien.demande'
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & cmd.exe /c mklink "$lien" "$f" 2>&1 } finally { $ErrorActionPreference = $eap }
    $sorte = 'lien symbolique vers une demande valable'
    if (-not (Test-Path -LiteralPath $lien)) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class MindsetTestPointAnalyse {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inb, int ins, IntPtr outb, int outs, out int ret, IntPtr ov);
    // Étiquette d'analyse « tierce » (0x4D53) sur un fichier : aucun droit particulier, aucun pilote ne la lit
    public static int Poser(string chemin) {
        using (var h = CreateFile(chemin, 0x40000000, 0, IntPtr.Zero, 3, 0x00200000 | 0x02000000, IntPtr.Zero)) {
            if (h.IsInvalid) return Marshal.GetLastWin32Error();
            byte[] b = new byte[28];
            BitConverter.GetBytes((uint)0x00004D53).CopyTo(b, 0);
            BitConverter.GetBytes((ushort)4).CopyTo(b, 4);
            Guid.NewGuid().ToByteArray().CopyTo(b, 8);
            int r;
            return DeviceIoControl(h, 0x000900A4, b, b.Length, IntPtr.Zero, 0, out r, IntPtr.Zero) ? 0 : Marshal.GetLastWin32Error();
        }
    }
}
'@
        Copy-Item -LiteralPath $f -Destination $lien
        $code = [MindsetTestPointAnalyse]::Poser($lien)
        if ($code) { throw "Impossible de poser un point d'analyse de test (erreur $code)." }
        $sorte = 'point d''analyse NTFS (pas de droit de lien symbolique sur ce PC)'
    }
    Test-Cas "demande en $sorte : ignorée sans réponse, rien fait" {
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $lien }
        ((Get-Item -LiteralPath $lien -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-SansReponse $r) -and (Test-RienFait $r)
    }

    # « Programme introuvable » (Register-TacheAide) : l'installateur vérifie déjà que le programme est là avant de
    # l'appeler ; la fonction est donc essayée seule (lue par l'analyseur), avec de fausses tâches planifiées
    Test-Cas 'tâche d''aide vers un programme absent : « Programme introuvable », aucune tâche créée' {
        $texte = [IO.File]::ReadAllText($installeur, [Text.Encoding]::UTF8)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($texte, [ref]$null, [ref]$null)
        $def = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Register-TacheAide' }, $true))[0]
        $script:TachesFaites = 0
        function New-ScheduledTaskPrincipal { }; function New-ScheduledTaskSettingsSet { }; function New-ScheduledTaskAction { }
        function Register-ScheduledTask { $script:TachesFaites++ }
        function Set-DroitsTache { }
        . ([scriptblock]::Create($def.Extent.Text))
        $refus = $false
        try { Register-TacheAide 'Appli (aide)' (Join-Path $PM 'Appli\Absent.exe') $sidActuel } catch { $refus = $_.Exception.Message -like '*Programme introuvable*' }
        $bon = $false
        Register-TacheAide 'Appli (aide)' (Join-Path $PM 'Appli\Aide.exe') $sidActuel; $bon = $script:TachesFaites -eq 1
        $refus -and $bon
    }

    # Les protections des premières lignes : dans le relais livré, et dans la version PowerShell de référence
    $blocRelais = [regex]::Match($texteRelais, '(?s)# <dossiers-windows>.*?# </dossiers-windows>')
    foreach ($x in @(@('le relais livré', $texteRelais, $blocRelais), @('la version PowerShell de référence', $texteInstalleur, $blocWindows))) {
        $quoi = $x[0]; $texteX = $x[1]; $blocX = $x[2]
        Test-Cas "$quoi : le bloc des dossiers de Windows les demande à Windows (GetFolderPath), sans aucune variable d'environnement" {
            $b = $blocX.Value
            $blocX.Success -and $b -notmatch '\$env:|\$\{env:' -and $b -match "GetFolderPath\('System'\)" -and $b -match "GetFolderPath\('ProgramFiles'\)" -and $b -match "GetFolderPath\('Windows'\)"
        }
        Test-Cas "$quoi : aucune autre variable d'environnement (seulement PSModulePath, fixé par le script lui-même)" {
            $autres = @([regex]::Matches($texteX, '\$env:\w+|\$\{env:[^}]+\}') | ForEach-Object { $_.Value } | Where-Object { $_ -ne '$env:PSModulePath' })
            -not $autres.Count
        }
        Test-Cas "$quoi : avant toute autre commande, PSModulePath réduit à System32, chargement automatique coupé, modules importés par leur chemin" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($texteX, [ref]$null, [ref]$null)
            $premieres = @($ast.EndBlock.Statements | Select-Object -First 4 | ForEach-Object { $_.Extent.Text })
            $premieres[0] -eq "`$ErrorActionPreference = 'Stop'" -and $premieres[1] -like "`$env:PSModulePath = [[]Environment[]]::GetFolderPath('System') + *" -and
                $premieres[2] -eq "`$PSModuleAutoLoadingPreference = 'None'" -and $premieres[3] -like 'foreach (*Import-Module -Name ($env:PSModulePath*'
        }
    }

    # De faux modules qui portent le nom de ceux de Windows, en tête de PSModulePath (comme Documents\WindowsPowerShell\Modules,
    # que l'utilisateur, ou un programme lancé sans droits, peut remplir) : chacun laisse un fichier témoin s'il est chargé.
    # Ici, les vraies copies du relais et de la version de référence (sans aucune fausse fonction) lisent une demande au
    # numéro invalide, puis s'arrêtent.
    $faux = Join-Path $tmp 'faux-modules'; $temoins = Join-Path $tmp 'temoins'
    New-Item -ItemType Directory -Force -Path $temoins | Out-Null
    $commandes = @{
        'Microsoft.PowerShell.Utility' = 'New-Object', 'ConvertFrom-Json', 'ConvertTo-Json', 'Add-Type', 'Get-Date'
        'Microsoft.PowerShell.Management' = 'Join-Path', 'Test-Path', 'Split-Path', 'New-Item', 'Get-Item', 'Get-ItemProperty', 'Set-ItemProperty', 'Remove-Item'
        'Microsoft.PowerShell.Security' = 'Get-Acl', 'Set-Acl'
        'ScheduledTasks' = 'Get-ScheduledTask', 'Register-ScheduledTask', 'Set-ScheduledTask'
        'CimCmdlets' = 'Get-CimInstance', 'Invoke-CimMethod'
    }
    foreach ($m in $commandes.Keys) {
        $temoin = (Join-Path $temoins "$m.txt").Replace("'", "''")
        $texte = "[IO.File]::WriteAllText('$temoin', 'chargé')`r`n" + (($commandes[$m] | ForEach-Object { "function $_ { [IO.File]::WriteAllText('$temoin', 'appelé') }" }) -join "`r`n") + "`r`nExport-ModuleMember -Function *"
        $null = Save-Fichier (Join-Path $faux "$m\$m.psm1") $texte
    }
    $vrai = Join-Path $tmp 'vrai\fichiers'
    New-Item -ItemType Directory -Force -Path (Join-Path $vrai 'modules') | Out-Null
    [IO.File]::WriteAllText((Join-Path $vrai 'installer-admin.ps1'), $texteRelais, (New-Object Text.UTF8Encoding $true))
    [IO.File]::WriteAllText((Join-Path $vrai 'reference.ps1'), $texteInstalleur, (New-Object Text.UTF8Encoding $true))
    # Contre-épreuve : la même copie sans ses premières lignes (PSModulePath, chargement automatique, import par chemin)
    $sansProtection = [regex]::Replace($texteRelais, "(?s)\`$env:PSModulePath = .*?(?=# <dossiers-windows>)", '')
    [IO.File]::WriteAllText((Join-Path $vrai 'sans-protection.ps1'), $sansProtection, (New-Object Text.UTF8Encoding $true))
    $demandeInvalide = New-Demande @{ Id = 'pas un numero'; Action = 'taches' }
    function Get-Temoins([string]$Script) {
        Get-ChildItem -LiteralPath $temoins -File | Remove-Item -Force
        $chemins = $env:PSModulePath
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $env:PSModulePath = "$faux;$chemins"
            $null = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script -Action demande -Sid $sidActuel -Demande $demandeInvalide 2>&1
        } finally { $env:PSModulePath = $chemins; $ErrorActionPreference = $eap }
        @(Get-ChildItem -LiteralPath $temoins -File | ForEach-Object { $_.BaseName })
    }
    foreach ($x in @(@('le relais', 'installer-admin.ps1'), @('la version de référence', 'reference.ps1'))) {
        $f = Join-Path $vrai $x[1]
        Test-Cas "faux modules de Windows en tête de PSModulePath : aucun n'est chargé par $($x[0]) (aucun fichier témoin)" {
            $t = @(Get-Temoins $f)
            if ($t.Count) { Write-Host "         chargés : $($t -join ', ')" -ForegroundColor DarkGray }
            -not $t.Count
        }
    }
    Test-Cas 'contre-épreuve : sans ses premières lignes, le relais charge le faux module (témoin)' {
        @(Get-Temoins (Join-Path $vrai 'sans-protection.ps1')).Count -gt 0
    }

    # =============================================================================================================
    Write-Partie 'Le relais (Mindset\fichiers\installer-admin.ps1) : il passe la main à MindsetInstallateur.exe'
    # =============================================================================================================
    # Un faux MindsetInstallateur.exe (compilé ici) note chaque lancement, avec ses arguments tels qu'il les reçoit,
    # dans appels.txt à côté de lui. Le relais tourne sur le faux PC (mêmes fausses fonctions), depuis le dossier de
    # Mindset de test, son bloc des dossiers de Windows remplacé par ceux du faux PC.
    $fauxExe = Join-Path $tmp 'faux-installateur\MindsetInstallateur.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path $fauxExe -Parent) | Out-Null
    Add-Type -OutputType ConsoleApplication -OutputAssembly $fauxExe -TypeDefinition @'
using System; using System.IO;
static class FauxInstallateur {
    static int Main(string[] a) {
        File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "appels.txt"), string.Join("\t", a) + "\r\n", new System.Text.UTF8Encoding(false));
        return 0;
    }
}
'@
    $fauxBlocRelais = @'
# <dossiers-windows> (faux PC des tests)
$DossierWindows = [Environment]::GetFolderPath('Windows')
$DossierSysteme = [Environment]::GetFolderPath('System')
$DossierProgrammes = Join-Path $global:TDossier 'ProgramFiles'
$Schtasks = 'schtasks'
# </dossiers-windows>
'@
    if (-not $blocRelais.Success) { throw 'Bloc <dossiers-windows> introuvable dans le relais.' }
    $copieRelais = Join-Path $tmp 'relais\installer-admin.ps1'
    $null = Save-Fichier $copieRelais ''
    [IO.File]::WriteAllText($copieRelais, $texteRelais.Replace($blocRelais.Value, $fauxBlocRelais.Trim()), (New-Object Text.UTF8Encoding $true))
    $exeTest = Join-Path $PM 'Mindset\MindsetInstallateur.exe'
    $appels = Join-Path $PM 'Mindset\appels.txt'
    # Lance le relais (à la place de l'installateur de test) ; rend le résultat, avec les lancements du faux exe (Appels)
    function Invoke-Relais([hashtable]$Parametres, [switch]$SansExe, [string]$Racine = '', [switch]$SansResultat) {
        $script:RelaisSansExe = [bool]$SansExe
        $r = Invoke-Installateur $Parametres -Racine $Racine -SansResultat:$SansResultat -Preparer {
            Copy-Item -LiteralPath $copieRelais -Destination $installeur -Force
            if (-not $script:RelaisSansExe) { Copy-Item -LiteralPath $fauxExe -Destination $exeTest -Force }
        }
        $l = @(if (Test-Path -LiteralPath $appels) { [IO.File]::ReadAllLines($appels, [Text.Encoding]::UTF8) | Where-Object { $_ } })
        $r | Add-Member -NotePropertyName Appels -NotePropertyValue $l
        if (-not $l.Count) { $r.Lignes = @($r.Lignes) + 'APPELS (aucun)' } else { $r.Lignes = @($r.Lignes) + @($l | ForEach-Object { "APPEL $_" }) }
        $script:Dernier = $r
        $r
    }
    # Les arguments attendus, dans l'ordre où le relais les passe (avec le fichier de réponse ajouté par le test)
    $ordre = 'Action', 'Resultat', 'Demande', 'Zip', 'Signature', 'Destination', 'DossierZip', 'Exe', 'AncienExe', 'Source', 'Version', 'AttendrePid', 'TacheAide', 'ExeAide', 'Appli', 'Disque', 'Sid', 'Liste'
    function Get-AppelAttendu([hashtable]$P) {
        $q = @{} + $P
        if (-not $q.ContainsKey('Resultat')) { $q.Resultat = Join-Path $tmp "resultats\$($script:NumeroCas).json" }
        $a = @(foreach ($n in $ordre) { if ($q.ContainsKey($n)) { "-$n"; [string]$q[$n] } })
        if ($q.Cache) { $a += '-Cache' }
        $a -join "`t"
    }

    # La demande de Windows : chaque valeur arrive telle quelle (espaces, accents, guillemet, barre finale, valeur vide)
    $p = @{ Action = 'appli'; Appli = 'appli'; Zip = "C:\Users\$([char]0xC9)lodie Test\t$([char]0xE9)l$([char]0xE9)chargements\Appli.zip"; Signature = 'C:\a"b\Appli.zip.sig'
            Destination = "$PM\Appli\"; DossierZip = 'Appli'; Exe = 'Appli.exe'; Version = ''; AttendrePid = 12; Sid = $sidActuel; Cache = $true
            Liste = "C:\Users\$([char]0xC9)lodie Test\AppData\Local\Mindset\Mindset\apps-en-ligne.json" }
    $r = Invoke-Relais $p
    Test-Cas 'demande de Windows : le relais lance MindsetInstallateur.exe une fois, avec les mêmes paramètres, valeur pour valeur' {
        $r.Appels.Count -eq 1 -and $r.Appels[0] -ceq (Get-AppelAttendu $p) -and -not $r.Erreur
    }
    $r = Invoke-Relais @{ Action = 'taches'; Destination = (Join-Path $PM 'Mindset'); Sid = $sidActuel } -SansExe
    Test-Cas 'demande de Windows sans MindsetInstallateur.exe : réponse « introuvable », rien lancé' {
        -not $r.Appels.Count -and $r.Reponse -and $r.Reponse.ok -eq $false -and ([string]$r.Reponse.message).Contains('MindsetInstallateur.exe') -and ([string]$r.Reponse.message).Contains('introuvable')
    }
    $r = Invoke-Relais @{ Action = 'mindset'; Source = $srcOk; Disque = 'QQ'; Sid = $sidActuel }
    Test-Cas 'disque « QQ » : refusé dès les paramètres par le relais, MindsetInstallateur.exe pas lancé' { $r.Erreur -and -not $r.Appels.Count }

    # Par la tâche SYSTEM (inscrite par un Mindset d'avant) : les tâches refaites par l'exe, puis la demande passée
    $f = New-Demande @{ Id = (New-Id); Action = 'taches'; Destination = (Join-Path $PM 'Mindset') }
    $p = @{ Action = 'demande'; Demande = $f; Sid = $sidActuel }
    $r = Invoke-Relais $p
    Test-Cas 'par la tâche SYSTEM : 1) tâches refaites par MindsetInstallateur.exe pour le même utilisateur (repointées vers lui), 2) la demande lui est passée telle quelle' {
        $r.Appels.Count -eq 2 -and $r.Appels[0] -ceq ("-Action`ttaches`t-Destination`t$(Join-Path $PM 'Mindset')`t-Sid`t$sidActuel") -and $r.Appels[1] -ceq (Get-AppelAttendu $p)
    }
    Test-Cas 'par la tâche SYSTEM : le relais lui-même ne répond pas et ne touche à rien sur Windows (c''est l''exe qui répond)' { -not $r.Registre -and -not @($r.Actions).Count }
    # L'ancienne tâche (sans -Sid) : la demande passée telle quelle (l'exe n'y accepte que « taches »)
    $f = New-Demande @{ Id = (New-Id); Action = 'taches'; Destination = (Join-Path $PM 'Mindset') }
    $p = @{ Action = 'demande'; Demande = $f }
    $r = Invoke-Relais $p
    Test-Cas 'ancienne tâche (sans -Sid) : la demande passée telle quelle à MindsetInstallateur.exe, une seule fois' { $r.Appels.Count -eq 1 -and $r.Appels[0] -ceq (Get-AppelAttendu $p) }
    # Dossier des programmes que les utilisateurs peuvent modifier : l'exe n'est jamais lancé, la demande est refusée
    # comme avant (accusé de réception, puis « dossier protégé »)
    $id = New-Id
    $f = New-Demande @{ Id = $id; Action = 'taches'; Destination = (Join-Path $PM 'Mindset') }
    $r = Invoke-Relais @{ Action = 'demande'; Demande = $f; Sid = $sidActuel } -Racine 'ouverte'
    Test-Cas 'par la tâche, dossier des programmes ouvert aux utilisateurs : MindsetInstallateur.exe pas lancé, refus « dossier protégé » avec le numéro de la demande' {
        -not $r.Appels.Count -and $r.Registre -and $r.Reponse.ok -eq $false -and $r.Reponse.id -eq $id -and ([string]$r.Reponse.message).Contains('dossier protégé') -and
            @($r.Lignes | Where-Object { $_ -eq "RECU $id" }).Count -eq 1
    }
    $f = New-Demande @{ Id = (New-Id); Action = 'taches'; Destination = (Join-Path $PM 'Mindset') }
    $r = Invoke-Relais @{ Action = 'demande'; Demande = $f; Sid = $sidActuel } -Racine 'proprietaire'
    Test-Cas 'par la tâche, dossier des programmes qui appartient à l''utilisateur : MindsetInstallateur.exe pas lancé, refus « dossier protégé »' {
        -not $r.Appels.Count -and $r.Reponse.ok -eq $false -and ([string]$r.Reponse.message).Contains('dossier protégé')
    }
    $f = New-Demande @{ Id = (New-Id); Action = 'mindset-maj'; Zip = $zipMindset; Signature = "$zipMindset.sig"; Destination = (Join-Path $PM 'Mindset'); Version = '2.0.0' }
    $r = Invoke-Relais @{ Action = 'demande'; Demande = $f; Sid = $sidActuel } -Racine 'ouverte'
    Test-Cas 'mise à jour de Mindset refusée ainsi : Mindset (déjà fermé) est relancé par sa tâche de démarrage, comme avant' {
        -not $r.Appels.Count -and $r.Reponse.ok -eq $false -and (Test-Action $r 'ACTION lancement schtasks /Run /TN \Mindset\Mindset (démarrage)')
    }
    $f = New-Demande @{ Id = (New-Id); Action = 'taches'; Destination = (Join-Path $PM 'Mindset') }
    $r = Invoke-Relais @{ Action = 'demande'; Demande = $f; Sid = $sidActuel } -SansExe
    Test-Cas 'par la tâche, MindsetInstallateur.exe absent : refus « introuvable », rien lancé' {
        -not $r.Appels.Count -and $r.Reponse.ok -eq $false -and ([string]$r.Reponse.message).Contains('introuvable')
    }
    $r = Invoke-Relais @{ Action = 'demande'; Demande = (New-Demande @{ Id = 'pas un numero'; Action = 'taches' }); Sid = $sidActuel } -Racine 'ouverte'
    Test-Cas 'refus par le relais : une demande au numéro invalide est ignorée sans un mot, comme avant' { -not $r.Appels.Count -and (Test-SansReponse $r) }

    # De vrais programmes d'essai (compilés ici, lancés depuis le dossier de test) avec les vrais Get-Process et Stop-Process
    $essaiExe = Join-Path $tmp 'essai.exe'
    Add-Type -OutputType WindowsApplication -OutputAssembly $essaiExe -TypeDefinition 'static class Essai { static void Main() { System.Threading.Thread.Sleep(600000); } }'
    $script:Essais = @{}
    $lancer = {
        param([string]$Chemin)
        New-Item -ItemType Directory -Force -Path (Split-Path $Chemin -Parent) | Out-Null
        Copy-Item -LiteralPath $essaiExe -Destination $Chemin -Force
        $script:Essais[$Chemin] = Start-Process -FilePath $Chemin -PassThru
    }
    $f = New-Demande (Get-Appli @{})
    $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = $sidActuel } -VraisProgrammes -Preparer {
        foreach ($c in "$PM\Appli\Mindset.exe", "$PM\Appli\Appli.exe", "$PM\Mindset\Mindset.exe", "$PM\AppliBis\Appli.exe", (Join-Path $tmp 'ailleurs\Mindset.exe')) { & $lancer $c }
        Start-Sleep -Milliseconds 500
    }
    $e = $script:Essais
    Test-Cas 'vrais programmes : l''hôte Mindset.exe et Appli.exe du dossier de l''appli sont fermés, l''appli installée' {
        $r.Reponse.ok -and $e["$PM\Appli\Mindset.exe"].WaitForExit(5000) -and $e["$PM\Appli\Appli.exe"].WaitForExit(5000) -and (Get-Version (Join-Path $PM 'Appli')) -eq '2.0.0'
    }
    Test-Cas 'vrais programmes : Mindset (Mindset.exe de son dossier), AppliBis et la copie ailleurs tournent toujours' {
        -not $e["$PM\Mindset\Mindset.exe"].HasExited -and -not $e["$PM\AppliBis\Appli.exe"].HasExited -and -not $e[(Join-Path $tmp 'ailleurs\Mindset.exe')].HasExited
    }
    foreach ($p in $script:Essais.Values) { try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(3000) } } catch {} }
} finally {
    foreach ($p in @($script:Essais.Values)) { try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(3000) } } catch {} }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch { Write-Host "Dossier de test non supprimé : $tmp ($($_.Exception.Message))" -ForegroundColor Yellow }
}

$total = $script:Reussis + $script:Echoues.Count + $script:Connus.Count
Write-Host ''
if ($script:Connus.Count) {
    Write-Host "Défauts connus, à corriger ($($script:Connus.Count)) :" -ForegroundColor Yellow
    $script:Connus | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($script:Echoues.Count) {
    Write-Host "Résultat : $($script:Echoues.Count) échec(s) sur $total cas." -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Résultat : $($script:Reussis) cas réussis sur $total, aucun échec$(if ($script:Connus.Count) { " ($($script:Connus.Count) défaut(s) connu(s))" })." -ForegroundColor Green
exit 0
