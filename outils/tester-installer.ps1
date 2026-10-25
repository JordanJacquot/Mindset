# Mindset : tests automatiques des refus du mini-installateur (fichiers\installer-admin.ps1).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-installer.ps1
#
# installer-admin.ps1 tourne en administrateur, lancé par la tâche « \Mindset\Mindset (installation) » : il lit une
# demande écrite par Mindset sans droits, et revérifie tout. Ici, chaque refus est essayé pour de vrai : la demande est
# refusée, avec le bon message, et rien n'est fait. Chaque chemin a aussi au moins une demande valable, acceptée (un
# installateur qui refuserait tout ne passerait pas ces tests).
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
      [string]$SidTache, [switch]$TachesRestantes, [switch]$DemarrageKo)
$global:TJournal = $Journal
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
function global:Get-Acl { [CmdletBinding()] param([string]$LiteralPath) Add-Journal "LECTURE droits $LiteralPath"; [Security.AccessControl.DirectorySecurity]::new() }
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
$texteInstalleur = [IO.File]::ReadAllText((Join-Path $fichiers 'installer-admin.ps1'), [Text.Encoding]::UTF8)
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
foreach ($m in 'signature.ps1', 'paquets.ps1') { Copy-Item -LiteralPath (Join-Path $fichiers "modules\$m") -Destination (Join-Path $copie 'modules') }
$installeur = Join-Path $copie 'installer-admin.ps1'
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
                             [string]$SidTache = '', [switch]$TachesRestantes, [switch]$GarderRecu, [switch]$DemarrageKo) {
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
            -Script $installeur -Parametres $fp -Journal $journal -Dossier $tmp -Lettre $L -LettreAmovible $LA @(if ($SidTache) { '-SidTache', $SidTache }) @(if ($VraisProgrammes) { '-VraisProgrammes' }) @(if ($TachesRestantes) { '-TachesRestantes' }) @(if ($DemarrageKo) { '-DemarrageKo' }) 2>&1
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
function Invoke-Demande($Contenu, [int]$Taille = 0, [scriptblock]$Preparer = $null, [switch]$AncienneTache, [string]$SidTache = '', [switch]$TachesRestantes, [switch]$GarderRecu) {
    $f = New-Demande $Contenu $Taille
    $p = @{ Action = 'demande'; Demande = $f }
    if (-not $AncienneTache) { $p.Sid = $sidActuel }
    Invoke-Installateur $p $Preparer -SidTache $SidTache -TachesRestantes:$TachesRestantes -GarderRecu:$GarderRecu
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
    [bool]@($R.Actions | Where-Object { $_.Contains('ACTION tâche créée') -and $_.Contains("-TaskName $Nom -") -and $_.Contains("-UserId $Sid ") }).Count
}
function Test-SansTache($R) { -not @($R.Actions | Where-Object { $_ -like 'ACTION tâche*' }).Count }
# Par la tâche SYSTEM, Mindset est toujours relancé par sa tâche de démarrage (sans droits, dans la session de l'utilisateur)
$relanceTache = 'ACTION lancement schtasks /Run /TN \Mindset\Mindset (démarrage)'

try {
    Write-Host 'Mindset : tests du mini-installateur (installer-admin.ps1)' -ForegroundColor Cyan
    Write-Host "Dossier de test : $tmp (faux disque $($L):, faux disque amovible $($LA):)"

    # =============================================================================================================
    Write-Partie 'La demande lue par la tâche (Action demande)'
    # =============================================================================================================
    # Une demande valable de référence : les tâches de Mindset, pour le Mindset de test
    $taches = @{ Action = 'taches'; Destination = (Join-Path $PM 'Mindset') }

    Test-Cas 'demande valable acceptée : tâches créées pour l''utilisateur de la tâche, réponse dans le registre' {
        $id = New-Id
        $r = Invoke-Demande (@{ Id = $id } + $taches)
        $r.Registre -and $r.Reponse.ok -and $r.Reponse.id -eq $id -and (Test-TacheCreee $r 'Mindset (installation)') -and (Test-TacheCreee $r 'Mindset (démarrage)')
    }
    Test-Cas 'demande absente : ignorée sans réponse, rien fait' {
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = (Join-Path $tmp 'demandes\absente.demande') }
        (Test-SansReponse $r) -and (Test-RienFait $r)
    }
    Test-Cas 'demande de 16 Ko tout juste : acceptée' {
        $r = Invoke-Demande (@{ Id = (New-Id) } + $taches) -Taille 16384
        $r.Reponse.ok -and (Test-TacheCreee $r 'Mindset (installation)')
    }
    Test-Cas 'demande de plus de 16 Ko (16 Ko + 1 octet) : ignorée sans réponse, rien fait, laissée en place' {
        $f = New-Demande (@{ Id = (New-Id) } + $taches) -Taille 16385
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = $sidActuel }
        (Test-SansReponse $r) -and (Test-RienFait $r) -and (Test-Path -LiteralPath $f)
    }
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
    Test-Cas 'demande illisible (pas du JSON) : « Demande illisible », rien fait' {
        $f = New-Demande "{ Id: 'abcdef12', Action: taches"
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = $sidActuel }
        (Test-Refuse $r 'Demande illisible') -and -not $r.Registre -and (Test-RienFait $r)
    }
    Test-Cas 'demande illisible, lancée comme par la tâche (sans -Resultat) : aucune réponse écrite nulle part' {
        $f = New-Demande 'pas du json'
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = $sidActuel } -SansResultat
        (Test-SansReponse $r) -and (Test-RienFait $r)
    }
    Test-Cas 'demande avec un Id valable mais un AttendrePid illisible : « Demande illisible » dans le registre, rien fait' {
        $id = New-Id
        $r = Invoke-Demande (@{ Id = $id; AttendrePid = 'abc' } + $taches)
        (Test-Refuse $r 'Demande illisible') -and $r.Registre -and $r.Reponse.id -eq $id -and (Test-RienFait $r)
    }
    foreach ($cas in @(
            @{ Nom = 'sans Id'; Id = $null },
            @{ Nom = 'Id trop court (7)'; Id = 'abcdef1' },
            @{ Nom = 'Id trop long (33)'; Id = ('a' * 33) },
            @{ Nom = 'Id avec un chemin'; Id = '..\..\abcdef12' },
            @{ Nom = 'Id avec autre chose après'; Id = 'abcdef12 ; x' },
            @{ Nom = 'Id vide'; Id = '' })) {
        $c = $cas
        Test-Cas "Id invalide ($($c.Nom)) : ignorée sans réponse, rien fait" {
            $d = @{} + $taches
            if ($null -ne $c.Id) { $d['Id'] = $c.Id }
            $r = Invoke-Demande $d
            (Test-SansReponse $r) -and (Test-RienFait $r)
        }
    }
    foreach ($cas in @(
            @{ Nom = 'mindset, réservée au lancement direct'; Action = 'mindset' },
            @{ Nom = 'demande'; Action = 'demande' },
            @{ Nom = 'inconnue'; Action = 'formater' },
            @{ Nom = 'avec une espace'; Action = 'supprimer ' },
            @{ Nom = 'vide'; Action = '' },
            @{ Nom = 'absente'; Action = $null })) {
        $c = $cas
        Test-Cas "action $($c.Nom) : « Demande refusée. », rien fait" {
            $id = New-Id
            $d = @{ Id = $id; Destination = (Join-Path $PM 'Appli'); Source = $srcOk }
            if ($null -ne $c.Action) { $d['Action'] = $c.Action }
            $r = Invoke-Demande $d
            (Test-Refuse $r 'Demande refusée.') -and $r.Reponse.id -eq $id -and (Test-RienFait $r)
        }
    }
    Test-Cas 'utilisateur donné dans la demande (Sid) ignoré : la tâche est pour l''utilisateur de la tâche' {
        $autre = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $r = Invoke-Demande @{ Id = (New-Id); Action = 'appli'; Zip = $zipAppli; Signature = "$zipAppli.sig"; Destination = (Join-Path $PM 'Appli'); DossierZip = 'Appli'; Exe = 'Appli.exe'; TacheAide = 'Appli (aide)'; ExeAide = 'Aide.exe'; Sid = $autre }
        $r.Reponse.ok -and (Test-TacheCreee $r 'Appli (aide)') -and -not (Test-Action $r $autre)
    }
    Test-Cas 'fichier de réponse donné dans la demande (Resultat) ignoré : rien écrit hors du registre' {
        $piege = Join-Path $tmp 'victime\piege.json'
        $r = Invoke-Demande (@{ Id = (New-Id); Resultat = $piege } + $taches)
        $r.Registre -and $r.Reponse.ok -and -not (Test-Path -LiteralPath $piege)
    }
    Test-Cas 'paramètre qui n''est pas du texte (Destination en liste) ignoré : rien supprimé' {
        $r = Invoke-Demande @{ Id = (New-Id); Action = 'supprimer'; Destination = @((Join-Path $PM 'Appli')) }
        $r.Reponse.ok -eq $false -and (Test-RienFait $r) -and (Test-Path -LiteralPath (Join-Path $PM 'Appli\Appli.exe'))
    }

    # =============================================================================================================
    Write-Partie 'Installer une appli (Action appli)'
    # =============================================================================================================
    $appli = @{ Action = 'appli'; Zip = $zipAppli; Signature = "$zipAppli.sig"; Destination = (Join-Path $PM 'Appli'); DossierZip = 'Appli'; Exe = 'Appli.exe' }
    function Get-Appli([hashtable]$Changes) { Merge-Table $appli (Merge-Table @{ Id = (New-Id) } $Changes) }

    Test-Cas 'appli valable acceptée : installée (2.0.0), sa tâche d''aide créée pour l''utilisateur de la tâche' {
        $r = Invoke-Demande (Get-Appli @{ TacheAide = 'Appli (aide)'; ExeAide = 'Aide.exe' })
        $aide = Join-Path $PM 'Appli\Aide.exe'
        $r.Reponse.ok -and $r.Reponse.message -eq (Join-Path $PM 'Appli') -and (Get-Version (Join-Path $PM 'Appli')) -eq '2.0.0' -and
            (Test-TacheCreee $r 'Appli (aide)') -and (Test-Action $r "-Execute `"$aide`"")
    }
    Test-Cas 'appli valable acceptée en lancement direct (-Resultat)' {
        $r = Invoke-Installateur (@{} + $appli)
        $r.Reponse.ok -and -not $r.Registre -and (Get-Version (Join-Path $PM 'Appli')) -eq '2.0.0' -and (Test-SansTache $r)
    }
    foreach ($cas in @(
            @{ Nom = 'Program Files\Mindset lui-même'; Dossier = $PM },
            @{ Nom = 'Program Files\Mindset\'; Dossier = "$PM\" },
            @{ Nom = 'trop profond (Mindset\Appli\fichiers)'; Dossier = (Join-Path $PM 'Appli\fichiers') },
            @{ Nom = 'à côté de Mindset (Program Files\Autre)'; Dossier = (Join-Path $PF 'Autre') },
            @{ Nom = 'nom proche (Program Files\MindsetX\Appli)'; Dossier = (Join-Path $PF 'MindsetX\Appli') },
            @{ Nom = 'qui remonte (Mindset\..\Autre)'; Dossier = "$PM\..\Autre" },
            @{ Nom = 'hors de Program Files'; Dossier = (Join-Path $tmp 'victime\Appli') },
            @{ Nom = 'X:\Autre\Programmes'; Dossier = "$($L):\Autre\Programmes\Appli" },
            @{ Nom = 'X:\Mindset\Programmes trop profond'; Dossier = "$($L):\Mindset\Programmes\Appli\x" },
            @{ Nom = 'réseau (\\serveur\Mindset\Programmes)'; Dossier = '\\serveur\Mindset\Programmes\Appli' })) {
        $c = $cas
        Test-Cas "destination refusée ($($c.Nom)) : « Dossier refusé », rien fait" {
            $r = Invoke-Demande (Get-Appli @{ Destination = $c.Dossier })
            (Test-Refuse $r 'Dossier refusé') -and (Test-RienFait $r)
        }
    }
    Test-Cas 'X:\Mindset\Programmes sur un disque amovible : refusé (disque fixe NTFS), rien fait' {
        $r = Invoke-Demande (Get-Appli @{ Destination = "$($LA):\Mindset\Programmes\Appli" })
        (Test-Refuse $r 'disque fixe NTFS') -and (Test-RienFait $r)
    }
    foreach ($nom in 'App\li', 'App/li', '..\Appli', 'C:', 'Ap*li', 'Ap?li', 'Ap"li', 'Ap<li', 'Ap>li', 'Ap|li') {
        $n = $nom
        Test-Cas "nom de dossier du zip « $n » : « Nom de dossier refusé. », rien fait" {
            $r = Invoke-Demande (Get-Appli @{ DossierZip = $n })
            (Test-Refuse $r 'Nom de dossier refusé.') -and (Test-RienFait $r)
        }
    }
    foreach ($nom in '..\Appli.exe', 'C:\Windows\explorer.exe', 'sous/Appli.exe', 'Appli', 'Appli.txt', 'Appli.exe.lnk', 'A*.exe', 'Appli.exe:flux', '') {
        $n = $nom
        Test-Cas "programme « $n » : « Nom de programme refusé. », rien fait (aucun programme arrêté)" {
            $r = Invoke-Demande (Get-Appli @{ Exe = $n })
            (Test-Refuse $r 'Nom de programme refusé.') -and (Test-RienFait $r)
        }
    }
    Test-Cas 'programme d''aide « ..\Aide.exe » : « Nom de programme refusé. », rien installé, aucune tâche' {
        $r = Invoke-Demande (Get-Appli @{ TacheAide = 'Appli (aide)'; ExeAide = '..\Aide.exe' })
        (Test-Refuse $r 'Nom de programme refusé.') -and (Test-RienFait $r)   # (noms vérifiés avant tout arrêt)
    }
    Test-Cas 'zip à la signature fausse : refusé, rien installé, aucune tâche' {
        $r = Invoke-Demande (Get-Appli @{ Signature = $sigFausse; TacheAide = 'Appli (aide)'; ExeAide = 'Aide.exe' })
        (Test-Refuse $r 'signature') -and (Test-RienFait $r)   # (signature vérifiée avant d'arrêter quoi que ce soit)
    }
    foreach ($nom in 'Mindset (installation)', 'Mindset (démarrage)', 'Appli', 'Appli (AIDE)', 'App\li (aide)', '..\Appli (aide)', "$('A' * 41) (aide)", ' (aide)') {
        $n = $nom
        Test-Cas "nom de tâche « $($n.Trim()) » : « Nom de tâche refusé. », aucune tâche créée" {
            $r = Invoke-Demande (Get-Appli @{ TacheAide = $n; ExeAide = 'Aide.exe' })
            (Test-Refuse $r 'Nom de tâche refusé.') -and (Test-RienFait $r)   # (refusé avant l'installation)
        }
    }
    Test-Cas 'nom de tâche suivi d''un retour à la ligne : « Nom de tâche refusé. », aucune tâche créée' {
        $r = Invoke-Demande (Get-Appli @{ TacheAide = "Appli (aide)`n"; ExeAide = 'Aide.exe' })
        (Test-Refuse $r 'Nom de tâche refusé.') -and (Test-RienFait $r)
    }
    Test-Cas 'nom de programme suivi d''un retour à la ligne : « Nom de programme refusé. », rien fait' {
        $r = Invoke-Demande (Get-Appli @{ Exe = "Appli.exe`n" })
        (Test-Refuse $r 'Nom de programme refusé.') -and (Test-RienFait $r)
    }
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18', 'S-1-5-21-1-2-3', 'utilisateur', '') {
        $s = $sid
        Test-Cas "lancement direct, utilisateur « $s » : « Utilisateur inconnu. », aucune tâche créée" {
            $r = Invoke-Installateur (@{ TacheAide = 'Appli (aide)'; ExeAide = 'Aide.exe'; Sid = $s } + $appli)
            (Test-Refuse $r 'Utilisateur inconnu.') -and (Test-SansTache $r)
        }
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
        . ([scriptblock]::Create($def.Extent.Text))
        $refus = $false
        try { Register-TacheAide 'Appli (aide)' (Join-Path $PM 'Appli\Absent.exe') $sidActuel } catch { $refus = $_.Exception.Message -like '*Programme introuvable*' }
        $bon = $false
        Register-TacheAide 'Appli (aide)' (Join-Path $PM 'Appli\Aide.exe') $sidActuel; $bon = $script:TachesFaites -eq 1
        $refus -and $bon
    }

    # =============================================================================================================
    Write-Partie 'Installer Mindset (Action mindset, lancement direct seulement)'
    # =============================================================================================================
    Test-Cas 'Mindset valable accepté dans Program Files : copié, inscrit dans « Applications installées », tâches créées' {
        $r = Invoke-Installateur @{ Action = 'mindset'; Source = $srcOk; Version = '3.0.0'; Sid = $sidActuel }
        $dest = Join-Path $PM 'Mindset'
        $r.Reponse.ok -and $r.Reponse.message -eq $dest -and (Get-Version $dest) -eq '3.0.0' -and (Test-Path -LiteralPath (Join-Path $dest 'LISEZMOI.txt')) -and
            (Test-Action $r 'Uninstall\Mindset\DisplayVersion = 3.0.0') -and (Test-TacheCreee $r 'Mindset (installation)') -and (Test-TacheCreee $r 'Mindset (démarrage)')
    }
    Test-Cas 'Mindset valable accepté sur un autre disque (X:\Mindset protégé, puis Programmes\Mindset)' {
        $r = Invoke-Installateur @{ Action = 'mindset'; Source = $srcOk; Version = '3.0.0'; Disque = $L; Sid = $sidActuel }
        $dest = Join-Path $tmp 'disque\Mindset\Programmes\Mindset'
        $r.Reponse.ok -and $r.Reponse.message -eq "$($L):\Mindset\Programmes\Mindset" -and (Get-Version $dest) -eq '3.0.0' -and
            (Test-Action $r "droits posés sur $($L):\Mindset") -and (Test-TacheCreee $r 'Mindset (installation)')
    }
    foreach ($d in 'QQ', '1', "$($L):", '\') {
        $x = $d
        Test-Cas "disque « $x » : refusé dès les paramètres, rien fait, aucune réponse" {
            $r = Invoke-Installateur @{ Action = 'mindset'; Source = $srcOk; Disque = $x; Sid = $sidActuel }
            (Test-SansReponse $r) -and $r.Erreur -and (Test-RienFait $r)
        }
    }
    Test-Cas 'action inconnue en lancement direct : refusée dès les paramètres, rien fait' {
        $r = Invoke-Installateur @{ Action = 'formater'; Destination = (Join-Path $PM 'Appli') }
        (Test-SansReponse $r) -and $r.Erreur -and (Test-RienFait $r)
    }
    Test-Cas 'disque amovible : refusé (disque fixe NTFS), X:\Mindset pas créé' {
        $r = Invoke-Installateur @{ Action = 'mindset'; Source = $srcOk; Disque = $LA; Sid = $sidActuel }
        (Test-Refuse $r 'disque fixe NTFS') -and (Test-RienFait $r)
    }
    foreach ($sid in 'S-1-5-32-545', 'S-1-5-18', 'S-1-5-21-1-2-3', '') {
        $s = $sid
        Test-Cas "autre disque, utilisateur « $s » : « Utilisateur inconnu. », X:\Mindset pas créé, aucun droit posé" {
            $r = Invoke-Installateur @{ Action = 'mindset'; Source = $srcOk; Disque = $L; Sid = $s }
            (Test-Refuse $r 'Utilisateur inconnu.') -and (Test-RienFait $r)
        }
    }
    Test-Cas 'Program Files, utilisateur invalide : Mindset installé « sans-taches », aucune tâche créée' {
        $r = Invoke-Installateur @{ Action = 'mindset'; Source = $srcOk; Version = '3.0.0'; Sid = 'S-1-5-32-544' }
        $r.Reponse.ok -and ([string]$r.Reponse.message).Contains('sans-taches') -and ([string]$r.Reponse.message).Contains('Utilisateur inconnu.') -and (Test-SansTache $r)
    }
    foreach ($cas in @(@{ Nom = 'sans Mindset.exe'; Source = $srcSansExe }, @{ Nom = 'sans fichiers\Mindset.ps1'; Source = $srcSansScript }, @{ Nom = 'absent'; Source = (Join-Path $tmp 'sources\Absent') })) {
        $c = $cas
        Test-Cas "dossier source $($c.Nom) : « ne contient pas Mindset », rien fait" {
            $r = Invoke-Installateur @{ Action = 'mindset'; Source = $c.Source; Sid = $sidActuel }
            (Test-Refuse $r 'ne contient pas Mindset') -and (Test-RienFait $r)
        }
    }

    # =============================================================================================================
    Write-Partie 'Mettre Mindset à jour (Action mindset-maj)'
    # =============================================================================================================
    $maj = @{ Action = 'mindset-maj'; Zip = $zipMindset; Signature = "$zipMindset.sig"; Destination = (Join-Path $PM 'Mindset'); Version = '2.0.0' }
    Test-Cas 'mise à jour valable acceptée : 2.0.0 installée, version inscrite, tâches à jour, Mindset relancé' {
        $r = Invoke-Demande (@{ Id = (New-Id) } + $maj)
        $dest = Join-Path $PM 'Mindset'
        $r.Reponse.ok -and $r.Reponse.message -eq '2.0.0' -and (Get-Version $dest) -eq '2.0.0' -and (Test-Action $r 'Uninstall\Mindset\DisplayVersion = 2.0.0') -and
            (Test-TacheCreee $r 'Mindset (installation)') -and (Test-Action $r $relanceTache) -and -not (Test-Action $r 'explorer.exe')
    }
    Test-Cas 'mise à jour automatique (Mindset caché) : relancé par sa tâche de démarrage, jamais par l''Explorateur' {
        $r = Invoke-Demande (@{ Id = (New-Id); Cache = '1' } + $maj)
        $r.Reponse.ok -and (Test-Action $r $relanceTache) -and -not (Test-Action $r 'explorer.exe')
    }
    Test-Cas 'par la tâche, la tâche de démarrage ne se lance pas : jamais l''Explorateur (il tournerait en SYSTEM)' {
        $f = New-Demande (@{ Id = (New-Id) } + $maj)
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = $sidActuel } -DemarrageKo
        $r.Reponse.ok -and (Test-Action $r $relanceTache) -and -not (Test-Action $r 'explorer.exe')
    }
    Test-Cas 'mise à jour en lancement direct (demande de Windows) : relancé par l''Explorateur, comme avant' {
        $r = Invoke-Installateur (@{} + $maj)
        $r.Reponse.ok -and (Test-Action $r "explorer.exe `"$(Join-Path $PM 'Mindset\Mindset.exe')`"") -and -not (Test-Action $r 'schtasks')
    }
    Test-Cas 'mise à jour par la tâche avec un zip hors du dossier telechargements : refusée, rien installé' {
        $ailleurs = Join-Path $tmp 'victime\Mindset.zip'
        $r = Invoke-Demande (Merge-Table $maj @{ Id = (New-Id); Zip = $ailleurs; Signature = "$ailleurs.sig" }) -Preparer {
            Copy-Item -LiteralPath $zipMindset -Destination $ailleurs; Copy-Item -LiteralPath "$zipMindset.sig" -Destination "$ailleurs.sig" }
        (Test-Refuse $r 'Fichier refusé') -and (Get-Version (Join-Path $PM 'Mindset')) -eq '1.0.0' -and (Test-RienFait $r @($relanceTache))
    }
    foreach ($cas in @(
            @{ Nom = 'hors de Program Files\Mindset'; Dossier = (Join-Path $tmp 'victime\Mindset') },
            @{ Nom = 'Program Files\Mindset lui-même'; Dossier = $PM },
            @{ Nom = 'qui ne s''appelle pas Mindset (une appli)'; Dossier = (Join-Path $PM 'Appli') })) {
        $c = $cas
        Test-Cas "mise à jour vers un dossier $($c.Nom) : « Dossier refusé », rien installé, seul l'ancien Mindset relancé" {
            $r = Invoke-Demande (Merge-Table $maj @{ Id = (New-Id); Destination = $c.Dossier })
            (Test-Refuse $r 'Dossier refusé') -and (Test-RienFait $r @($relanceTache))
        }
    }
    Test-Cas 'mise à jour à la signature fausse : refusée, rien installé, aucune tâche, aucune clé' {
        $r = Invoke-Demande (Merge-Table $maj @{ Id = (New-Id); Signature = $sigFausse })
        (Test-Refuse $r 'signature') -and (Test-RienFait $r @($relanceTache))
    }

    # =============================================================================================================
    Write-Partie 'Tâches de Mindset (Action taches)'
    # =============================================================================================================
    Test-Cas 'tâches en lancement direct, utilisateur valable : acceptées' {
        $r = Invoke-Installateur @{ Action = 'taches'; Destination = (Join-Path $PM 'Mindset'); Sid = $sidActuel }
        $r.Reponse.ok -and (Test-TacheCreee $r 'Mindset (installation)') -and (Test-TacheCreee $r 'Mindset (démarrage)')
    }
    foreach ($cas in @(
            @{ Nom = 'hors de Program Files\Mindset'; Dossier = (Join-Path $tmp 'victime\Mindset') },
            @{ Nom = 'trop profond'; Dossier = (Join-Path $PM 'Appli\Mindset') },
            @{ Nom = 'qui ne s''appelle pas Mindset (une appli)'; Dossier = (Join-Path $PM 'Appli') })) {
        $c = $cas
        Test-Cas "tâches pour un dossier $($c.Nom) : « Dossier refusé », aucune tâche" {
            $r = Invoke-Demande @{ Id = (New-Id); Action = 'taches'; Destination = $c.Dossier }
            (Test-Refuse $r 'Dossier refusé') -and (Test-RienFait $r)
        }
    }
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18', '') {
        $s = $sid
        Test-Cas "tâches en lancement direct, utilisateur « $s » : « Utilisateur inconnu. », aucune tâche" {
            $r = Invoke-Installateur @{ Action = 'taches'; Destination = (Join-Path $PM 'Mindset'); Sid = $s }
            (Test-Refuse $r 'Utilisateur inconnu.') -and (Test-RienFait $r)
        }
    }
    Test-Cas 'tâches pour un Mindset sans Mindset.exe : refusé (introuvable), aucune tâche' {
        $r = Invoke-Demande @{ Id = (New-Id); Action = 'taches'; Destination = (Join-Path $PM 'Mindset') } -Preparer { Remove-Item -LiteralPath (Join-Path $PM 'Mindset\Mindset.exe') }
        (Test-Refuse $r 'Mindset.exe introuvable') -and (Test-RienFait $r)
    }

    # =============================================================================================================
    Write-Partie 'Supprimer (Action supprimer)'
    # =============================================================================================================
    Test-Cas 'suppression d''une appli acceptée : son dossier retiré, Mindset gardé' {
        $r = Invoke-Demande @{ Id = (New-Id); Action = 'supprimer'; Destination = (Join-Path $PM 'Appli'); Exe = 'Appli.exe' }
        $r.Reponse.ok -and -not (Test-Path -LiteralPath (Join-Path $PM 'Appli')) -and (Test-Path -LiteralPath (Join-Path $PM 'Mindset\Mindset.exe')) -and (Test-Action $r "arrêt du programme $PM\Appli\")
    }
    Test-Cas 'suppression de Mindset lui-même acceptée : dossier, tâches et clés retirés (sans fenêtre ni réponse)' {
        $r = Invoke-Demande @{ Id = (New-Id); Action = 'supprimer'; Destination = (Join-Path $PM 'Mindset') }
        -not (Test-Path -LiteralPath (Join-Path $PM 'Mindset')) -and (Test-Path -LiteralPath (Join-Path $PM 'Appli\Appli.exe')) -and
            (Test-Action $r 'registre : suppression de HKLM:\SOFTWARE\Mindset') -and (Test-Action $r 'tâche retirée') -and -not (Test-Action $r 'fenêtre') -and -not $r.Registre
    }
    foreach ($cas in @(
            @{ Nom = 'Program Files\Mindset (tout)'; Dossier = $PM },
            @{ Nom = 'Program Files'; Dossier = $PF },
            @{ Nom = 'Mindset\Appli\.. (tout)'; Dossier = "$PM\Appli\.." },
            @{ Nom = 'trop profond (Appli\fichiers)'; Dossier = (Join-Path $PM 'Appli\fichiers') },
            @{ Nom = 'hors de Mindset'; Dossier = (Join-Path $tmp 'victime') },
            @{ Nom = 'X:\Mindset sur le faux disque'; Dossier = "$($L):\Mindset" })) {
        $c = $cas
        Test-Cas "suppression de $($c.Nom) : « Dossier refusé », rien supprimé" {
            $r = Invoke-Demande @{ Id = (New-Id); Action = 'supprimer'; Destination = $c.Dossier } -Preparer { $null = Save-Fichier (Join-Path $tmp 'disque\Mindset\Programmes\Appli\Appli.exe') 'x' }
            (Test-Refuse $r 'Dossier refusé') -and (Test-RienFait $r)
        }
    }
    Test-Cas 'suppression avec le programme « ..\Appli.exe » : « Nom de programme refusé. », rien supprimé' {
        $r = Invoke-Demande @{ Id = (New-Id); Action = 'supprimer'; Destination = (Join-Path $PM 'Appli'); Exe = '..\Appli.exe' }
        (Test-Refuse $r 'Nom de programme refusé.') -and (Test-RienFait $r)
    }

    # =============================================================================================================
    Write-Partie 'La tâche SYSTEM : rien ne vient de l''utilisateur (revue du 25/10, constat 1)'
    # =============================================================================================================
    Test-Cas 'le vrai bloc des dossiers de Windows les demande à Windows (GetFolderPath), sans aucune variable d''environnement' {
        $b = $blocWindows.Value
        $b -notmatch '\$env:|\$\{env:' -and $b -match "GetFolderPath\('System'\)" -and $b -match "GetFolderPath\('ProgramFiles'\)" -and $b -match "GetFolderPath\('Windows'\)"
    }
    Test-Cas 'aucune autre variable d''environnement dans l''installateur (seulement PSModulePath, qu''il fixe lui-même)' {
        $autres = @([regex]::Matches($texteInstalleur, '\$env:\w+|\$\{env:[^}]+\}') | ForEach-Object { $_.Value } | Where-Object { $_ -ne '$env:PSModulePath' })
        -not $autres.Count
    }
    Test-Cas 'avant toute autre commande : PSModulePath réduit à System32, chargement automatique coupé, modules importés par leur chemin' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($texteInstalleur, [ref]$null, [ref]$null)
        $premieres = @($ast.EndBlock.Statements | Select-Object -First 4 | ForEach-Object { $_.Extent.Text })
        $premieres[0] -eq "`$ErrorActionPreference = 'Stop'" -and $premieres[1] -like "`$env:PSModulePath = [[]Environment[]]::GetFolderPath('System') + *" -and
            $premieres[2] -eq "`$PSModuleAutoLoadingPreference = 'None'" -and $premieres[3] -like 'foreach (*ScheduledTasks*Import-Module -Name ($env:PSModulePath*'
    }

    # De faux modules qui portent le nom de ceux de Windows, en tête de PSModulePath (comme Documents\WindowsPowerShell\Modules,
    # que l'utilisateur, ou un programme lancé sans droits, peut remplir) : chacun laisse un fichier témoin s'il est chargé.
    # Ici, la vraie copie d'installer-admin.ps1 (sans aucune fausse fonction) lit une demande au numéro invalide, puis s'arrête.
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
    [IO.File]::WriteAllText((Join-Path $vrai 'installer-admin.ps1'), $texteInstalleur, (New-Object Text.UTF8Encoding $true))
    # Contre-épreuve : la même copie sans ses premières lignes (PSModulePath, chargement automatique, import par chemin)
    $sansProtection = [regex]::Replace($texteInstalleur, "(?s)\`$env:PSModulePath = .*?(?=# <dossiers-windows>)", '')
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
    Test-Cas 'faux modules de Windows en tête de PSModulePath : aucun n''est chargé (aucun fichier témoin)' {
        $t = @(Get-Temoins (Join-Path $vrai 'installer-admin.ps1'))
        if ($t.Count) { Write-Host "         chargés : $($t -join ', ')" -ForegroundColor DarkGray }
        -not $t.Count
    }
    Test-Cas 'contre-épreuve : sans ses premières lignes, l''installateur charge le faux module (témoin)' {
        @(Get-Temoins (Join-Path $vrai 'sans-protection.ps1')).Count -gt 0
    }
    Test-Cas 'variables de l''utilisateur piégées (ProgramFiles, LOCALAPPDATA, windir...) : rien écrit ni lu par elles, installation faite' {
        $r = Invoke-Demande (@{ Id = (New-Id) } + $taches)
        $r.Reponse.ok -and -not @($r.Lignes | Where-Object { $_ -like '*piege-variable*' }).Count
    }

    Test-Cas 'tâche d''installation : en SYSTEM, utilisateur inscrit dans ses arguments, lui seul peut la lancer, powershell.exe de System32' {
        $r = Invoke-Demande (@{ Id = (New-Id) } + $taches)
        $ps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
        $r.Reponse.ok -and (Test-TacheCreee $r 'Mindset (installation)') -and (Test-Action $r "-Execute $ps ") -and (Test-Action $r '-NoProfile -NonInteractive') -and
            -not (Test-Action $r '-UserId S-1-5-21-1111111111')
    }
    Test-Cas 'sa demande : dans le dossier de l''utilisateur lu dans ProfileList (HKLM), jamais dans LOCALAPPDATA' {
        $r = Invoke-Demande (@{ Id = (New-Id) } + $taches)
        $attendu = Join-Path $tmp "Profils\$sidActuel\AppData\Local\Mindset\Mindset\installation.demande"
        $r.Reponse.ok -and (Test-Action $r "-Demande `"$attendu`"") -and (Test-Action $r 'LOCALAPPDATA') -eq $false
    }
    Test-Cas 'Mindset sur un autre disque : sa demande dans X:\Mindset\Donnees\Mindset' {
        $r = Invoke-Installateur @{ Action = 'mindset'; Source = $srcOk; Version = '3.0.0'; Disque = $L; Sid = $sidActuel }
        $r.Reponse.ok -and (Test-Action $r "-Demande `"$($L):\Mindset\Donnees\Mindset\installation.demande`"")
    }
    Test-Cas 'accusé de réception : l''Id de la demande, écrit dans HKLM avant le travail' {
        $id = New-Id
        $r = Invoke-Demande (@{ Id = $id } + $taches)
        $l = @($r.Lignes)
        $i = [array]::IndexOf($l, "RECU $id"); $j = @(0..($l.Count - 1) | Where-Object { $l[$_] -like 'ACTION tâche créée*' } | Select-Object -First 1)
        $r.Reponse.ok -and $i -ge 0 -and $j.Count -and $j[0] -gt $i
    }
    Test-Cas 'la même demande relancée (même Id, déjà reçue) : rien refait, aucune réponse' {
        $id = New-Id
        $null = Invoke-Demande (@{ Id = $id } + $taches)
        $f = New-Demande (@{ Id = $id } + $taches)
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = $sidActuel } -GarderRecu
        (Test-SansReponse $r) -and (Test-SansTache $r)
    }
    Test-Cas 'la demande n''est jamais effacée par l''installateur (Mindset l''efface ; en SYSTEM, un lien ferait effacer autre chose)' {
        $f = New-Demande (@{ Id = (New-Id) } + $taches)
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = $sidActuel }
        $r.Reponse.ok -and (Test-Path -LiteralPath $f)
    }
    Test-Cas 'demande illisible : « Demande illisible. » sans recopier le texte de l''erreur (il citerait le contenu du fichier)' {
        $f = New-Demande '{ secret: 12345'
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = $sidActuel }
        (Test-Refuse $r 'Demande illisible') -and -not ([string]$r.Reponse.message).Contains('secret')
    }
    foreach ($cas in @(@{ Nom = 'le zip'; Zip = (Join-Path $tmp 'victime\Appli.zip'); Sig = "$zipAppli.sig" }, @{ Nom = 'la signature'; Zip = $zipAppli; Sig = (Join-Path $tmp 'victime\Appli.zip.sig') })) {
        $c = $cas
        Test-Cas "par la tâche, $($c.Nom) hors du dossier telechargements de l'utilisateur : « Fichier refusé », rien fait" {
            $r = Invoke-Demande (Get-Appli @{ Zip = $c.Zip; Signature = $c.Sig }) -Preparer {
                Copy-Item -LiteralPath $zipAppli -Destination (Join-Path $tmp 'victime\Appli.zip'); Copy-Item -LiteralPath "$zipAppli.sig" -Destination (Join-Path $tmp 'victime\Appli.zip.sig') }
            (Test-Refuse $r 'Fichier refusé') -and (Test-RienFait $r)
        }
    }
    Test-Cas 'par la tâche, un zip donné par un chemin relatif : « Fichier refusé », rien fait' {
        $r = Invoke-Demande (Get-Appli @{ Zip = 'telechargements\Appli.zip' })
        (Test-Refuse $r 'Fichier refusé') -and (Test-RienFait $r)
    }
    Test-Cas 'par la tâche, -Sid invalide (le système) : « Utilisateur inconnu. », rien fait' {
        $f = New-Demande (@{ Id = (New-Id) } + $taches)
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f; Sid = 'S-1-5-18' }
        (Test-Refuse $r 'Utilisateur inconnu.') -and (Test-RienFait $r)
    }

    # L'ancienne tâche (jusqu'à Mindset 2.9.0 : sous le compte de l'utilisateur, droits les plus élevés, sans -Sid)
    Test-Cas 'ancienne tâche, Action taches : elle se remplace par la tâche SYSTEM, pour son utilisateur' {
        $r = Invoke-Demande (@{ Id = (New-Id) } + $taches) -AncienneTache -SidTache $sidActuel
        $r.Reponse.ok -and (Test-TacheCreee $r 'Mindset (installation)') -and (Test-TacheCreee $r 'Mindset (démarrage)')
    }
    foreach ($a in 'appli', 'mindset-maj', 'supprimer') {
        $x = $a
        Test-Cas "ancienne tâche, Action $x : refusée (elle doit d'abord être remplacée), rien fait" {
            $d = switch ($x) { 'appli' { Get-Appli @{} } 'mindset-maj' { @{ Id = (New-Id) } + $maj } 'supprimer' { @{ Id = (New-Id); Action = 'supprimer'; Destination = (Join-Path $PM 'Appli'); Exe = 'Appli.exe' } } }
            $r = Invoke-Demande $d -AncienneTache -SidTache $sidActuel
            (Test-Refuse $r 'Ancienne tâche') -and (Test-RienFait $r)
        }
    }
    Test-Cas 'ancienne tâche d''un autre compte que celui qui la lance : « Utilisateur inconnu. », aucune tâche' {
        $r = Invoke-Demande (@{ Id = (New-Id) } + $taches) -AncienneTache -SidTache 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        (Test-Refuse $r 'Utilisateur inconnu.') -and (Test-RienFait $r)
    }

    # =============================================================================================================
    Write-Partie 'Prise en charge : seules les tâches de l''utilisateur qui lançaient l''ancienne copie (revue du 25/10, constat 3)'
    # =============================================================================================================
    $ancienne = Join-Path $tmp 'ancienne\Appli.exe'
    $creerAncienne = { $null = Save-Fichier $ancienne 'appli 0.9' }
    function Get-Modifiees($R) { @($R.Actions | Where-Object { $_ -like 'ACTION tâche modifiée*' }) }
    Test-Cas 'ancienne copie valable : seule la tâche de l''utilisateur est réécrite, ses deux actions gardées' {
        $r = Invoke-Demande (Get-Appli @{ AncienExe = $ancienne }) -Preparer $creerAncienne
        $m = @(Get-Modifiees $r)
        $r.Reponse.ok -and $m.Count -eq 1 -and $m[0] -eq "ACTION tâche modifiée : \Appli (démarrage) -> `"$(Join-Path $PM 'Appli\Appli.exe')`" | C:\Autre\Autre.exe"
    }
    Test-Cas 'ni la tâche SYSTEM, ni celle de Windows (\Microsoft\), ni celle de Mindset, ni celle d''un autre compte ou d''un groupe' {
        $r = Invoke-Demande (Get-Appli @{ AncienExe = $ancienne }) -Preparer $creerAncienne
        $r.Reponse.ok -and -not @(Get-Modifiees $r | ForEach-Object { ($_ -split ' -> ')[0] } | Where-Object { $_ -match 'Antivirus|\\Microsoft\\|\\Mindset\\|Autre compte|Groupe' }).Count
    }
    foreach ($cas in @(
            @{ Nom = 'un autre programme (explorer.exe)'; Exe = 'C:\Windows\explorer.exe' },
            @{ Nom = 'le programme d''un antivirus'; Exe = 'C:\Program Files\Antivirus\Appli.exe.bak' },
            @{ Nom = 'un chemin relatif'; Exe = 'Appli.exe' },
            @{ Nom = 'un chemin qui remonte'; Exe = (Join-Path $tmp 'ancienne\..\ancienne\Appli.exe') },
            @{ Nom = 'un programme absent'; Exe = (Join-Path $tmp 'absente\Appli.exe') },
            @{ Nom = 'un chemin réseau'; Exe = '\\serveur\partage\Appli.exe' })) {
        $c = $cas
        Test-Cas "ancienne copie refusée ($($c.Nom)) : « Ancienne copie refusée. », rien installé, aucune tâche modifiée" {
            $r = Invoke-Demande (Get-Appli @{ AncienExe = $c.Exe }) -Preparer $creerAncienne
            (Test-Refuse $r 'Ancienne copie refusée.') -and (Test-RienFait $r)
        }
    }
    Test-Cas 'lancement direct sans utilisateur : l''appli est installée, aucune tâche modifiée' {
        $r = Invoke-Installateur (@{ AncienExe = $ancienne } + $appli) -Preparer $creerAncienne
        $r.Reponse.ok -and -not @(Get-Modifiees $r).Count
    }

    # =============================================================================================================
    Write-Partie 'En SYSTEM, aucune fenêtre ; programmes fermés seulement ceux de l''utilisateur'
    # =============================================================================================================
    Test-Cas 'désinstallation de Mindset par la tâche, pas allée au bout : aucune fenêtre, ce qui reste est écrit dans HKLM pour Mindset' {
        $r = Invoke-Demande @{ Id = (New-Id); Action = 'supprimer'; Destination = (Join-Path $PM 'Mindset') } -TachesRestantes
        -not (Test-Action $r 'fenêtre') -and @($r.Lignes | Where-Object { $_ -like 'RESTES *' }).Count -and @($r.Lignes | Where-Object { $_ -like '- la tâche planifiée*' }).Count -and -not (Test-Action $r 'suppression de HKLM:\SOFTWARE\Mindset')
    }
    Test-Cas 'même cas en lancement direct (demande de Windows) : la fenêtre est montrée, comme avant' {
        $r = Invoke-Installateur @{ Action = 'supprimer'; Destination = (Join-Path $PM 'Mindset') } -TachesRestantes
        (Test-Action $r 'fenêtre') -and -not @($r.Lignes | Where-Object { $_ -like 'RESTES *' }).Count
    }
    Test-Cas 'par la tâche : le programme d''un autre compte qui utilise la même copie n''est pas fermé' {
        $r = Invoke-Demande (Get-Appli @{})
        $r.Reponse.ok -and @($r.Lignes | Where-Object { $_ -like 'ACTION arrêt*' }).Count -eq 3
    }
    Test-Cas 'en lancement direct sans utilisateur : seulement ceux de la session (pas celui de la session 99)' {
        $r = Invoke-Installateur @{ Action = 'supprimer'; Destination = (Join-Path $PM 'Appli'); Exe = 'Appli.exe' }
        $r.Reponse.ok -and @($r.Lignes | Where-Object { $_ -like 'ACTION arrêt*' }).Count -eq 3
    }

    # =============================================================================================================
    Write-Partie 'Programmes fermés : par leur chemin (le dossier de l''appli), jamais par leur nom'
    # =============================================================================================================
    # L'hôte de chaque appli s'appelle Mindset.exe, comme Mindset : fermer « Mindset » ou « Appli » par nom fermerait
    # Mindset lui-même, ou en administrateur n'importe quel programme du même nom. Seuls ceux du dossier de l'appli partent.
    $attendus = @("$PM\Appli\Mindset.exe", "$PM\Appli\Appli.exe", "$PM\Appli\Aide.exe")
    function Get-Arrets($R) { @($R.Actions | Where-Object { $_ -like 'ACTION arrêt du programme *' } | ForEach-Object { $_.Substring('ACTION arrêt du programme '.Length) } | Sort-Object) }
    Test-Cas 'installation : seuls l''hôte Mindset.exe, Appli.exe et l''aide du dossier de l''appli sont fermés' {
        $r = Invoke-Demande (Get-Appli @{ TacheAide = 'Appli (aide)'; ExeAide = 'Aide.exe' })
        $r.Reponse.ok -and ((Get-Arrets $r) -join '|') -eq ((@($attendus) | Sort-Object) -join '|')
    }
    Test-Cas 'installation : ni Mindset, ni l''appli au nom proche (AppliBis), ni les copies ailleurs, ni un programme au chemin illisible' {
        $r = Invoke-Demande (Get-Appli @{})
        $a = Get-Arrets $r
        $r.Reponse.ok -and $a.Count -eq 3 -and -not ($a | Where-Object { $_ -like "*\Mindset\Mindset\*" -or $_ -like '*AppliBis*' -or $_ -like '*ailleurs*' -or -not $_ })
    }
    Test-Cas 'suppression d''une appli : seuls les programmes de son dossier sont fermés' {
        $r = Invoke-Demande @{ Id = (New-Id); Action = 'supprimer'; Destination = (Join-Path $PM 'Appli'); Exe = 'Appli.exe' }
        $r.Reponse.ok -and ((Get-Arrets $r) -join '|') -eq ((@($attendus) | Sort-Object) -join '|')
    }
    Test-Cas 'demande refusée (signature fausse) : aucun programme fermé' {
        $r = Invoke-Demande (Get-Appli @{ Signature = $sigFausse })
        (Test-Refuse $r 'signature') -and -not (Get-Arrets $r).Count
    }

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
