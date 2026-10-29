<#
    Mindset : le relais vers le mini-installateur, MindsetInstallateur.exe (à côté de Mindset.exe).

    Tout ce qui se fait dans Program Files\Mindset (installer, mettre à jour, supprimer une appli ou Mindset, refaire
    les tâches) est fait par MindsetInstallateur.exe, avec les mêmes contrôles et les mêmes réponses qu'avant. Ce
    script ne fait plus que lui passer la main, avec les mêmes paramètres, pour tous ceux qui le lancent encore :
      - les anciens Mindset (2.9 et avant, 2.11, 2.14...) qui se mettent à jour : leur tâche, ou la demande de Windows,
        lance toujours ce script ;
      - la tâche SYSTEM « \Mindset\Mindset (installation) » inscrite par un Mindset d'avant (-Action demande -Sid
        <utilisateur>) : elle est repointée vers MindsetInstallateur.exe (ses tâches refaites), puis la demande lui est
        passée ;
      - l'ancienne tâche « avec les droits les plus élevés » (sans -Sid, jusqu'à Mindset 2.9.0) : la demande est passée
        telle quelle à MindsetInstallateur.exe, qui n'y accepte que « taches », pour se remplacer par la tâche SYSTEM ;
      - la demande de Windows (les autres actions, -Resultat <fichier>) : les paramètres sont passés tels quels, et la
        réponse est celle de MindsetInstallateur.exe.
    -Liste <chemin> (Mindset 2.16 et après) : la liste des applis en ligne gardée par Mindset (apps-en-ligne.json, sa
    signature à côté), passée elle aussi telle quelle : MindsetInstallateur.exe la revérifie et y cherche l'appli.
    Gardé jusqu'à l'étape 7 du passage en Rust, pour les amis qui sautent des versions.

    Protections, comme avant : en administrateur, rien ne vient de l'utilisateur, ni ses modules PowerShell
    (Documents\WindowsPowerShell\Modules, en tête de PSModulePath), ni ses variables d'environnement (les dossiers de
    Windows sont demandés à Windows). Par une tâche, MindsetInstallateur.exe n'est lancé que depuis un dossier protégé
    (Program Files\Mindset\Mindset, ou X:\Mindset\Programmes\Mindset sur un disque fixe NTFS), sans lien sur son chemin :
    sinon, la demande est refusée ici (« dossier protégé »), sans rien lancer.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('appli', 'mindset', 'mindset-maj', 'taches', 'supprimer', 'demande')][string]$Action,
    [string]$Resultat, [string]$Demande,
    [string]$Zip, [string]$Signature, [string]$Destination, [string]$DossierZip, [string]$Exe, [string]$AncienExe,
    [string]$Source, [string]$Version, [int]$AttendrePid, [string]$TacheAide, [string]$ExeAide, [string]$Appli,
    [ValidatePattern('^[A-Za-z]?$')][string]$Disque, [string]$Sid, [switch]$Cache, [string]$Liste
)
$ErrorActionPreference = 'Stop'
# Avant toute autre commande : les modules de Windows seulement, chargés par leur chemin (le chargement automatique
# prendrait le premier module du même nom trouvé dans PSModulePath, qui commence par le dossier Documents de l'utilisateur)
$env:PSModulePath = [Environment]::GetFolderPath('System') + '\WindowsPowerShell\v1.0\Modules'
$PSModuleAutoLoadingPreference = 'None'
foreach ($m in 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'CimCmdlets') {
    Import-Module -Name ($env:PSModulePath + '\' + $m) -ErrorAction Stop
}
# <dossiers-windows> Les dossiers et programmes de Windows, demandés à Windows (jamais aux variables d'environnement, que
# l'utilisateur peut changer). (outils\tester-installer.ps1 remplace ce bloc par ceux de son faux PC.)
$DossierWindows = [Environment]::GetFolderPath('Windows')
$DossierSysteme = [Environment]::GetFolderPath('System')
$DossierProgrammes = [Environment]::GetFolderPath('ProgramFiles')
$Schtasks = Join-Path $DossierSysteme 'schtasks.exe'
# </dossiers-windows>

# Le mini-installateur : à côté de Mindset.exe, dans le dossier de Mindset d'où ce script est lancé
$DossierMindset = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$Installateur = Join-Path $DossierMindset 'MindsetInstallateur.exe'

# Un chemin sans lien (point de jonction, lien symbolique) sur lui ni sur un de ses dossiers parents
function Test-SansLien([string]$Chemin) {
    $x = [IO.Path]::GetFullPath($Chemin)
    while ($x -and $x.Length -gt 3) {
        try { if ([IO.File]::GetAttributes($x) -band [IO.FileAttributes]::ReparsePoint) { return $false } } catch { return $false }
        $x = [IO.Path]::GetDirectoryName($x)
    }
    $true
}

function Test-DisqueFixe([string]$Lettre) {
    $v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Lettre.ToUpper()):'" -ErrorAction SilentlyContinue
    [bool]($v -and $v.DriveType -eq 3 -and $v.FileSystem -eq 'NTFS')
}

# Un dossier que seuls les administrateurs peuvent changer : il appartient aux Administrateurs, à SYSTEM ou à
# TrustedInstaller, et personne d'autre n'y a un droit d'écriture (ni l'utilisateur, ni « Utilisateurs », ni « Tout le
# monde »)
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

# Par une tâche : le dossier de Mindset (celui de ce script) est dans un dossier des programmes protégé, sans lien, et
# MindsetInstallateur.exe y est, sans lien lui non plus. Sinon, le message du refus.
function Get-RefusRacine {
    $racine = Split-Path $DossierMindset -Parent
    $pf = [IO.Path]::GetFullPath((Join-Path $DossierProgrammes 'Mindset')).TrimEnd('\')
    $ok = (Split-Path $DossierMindset -Leaf) -eq 'Mindset' -and ($racine -ieq $pf -or $racine -match '^[A-Za-z]:\\Mindset\\Programmes\z')
    if ($ok -and $racine -ine $pf -and -not (Test-DisqueFixe $racine.Substring(0, 1))) {
        return "Le disque $($racine.Substring(0, 1)): n'est pas un disque fixe NTFS : Mindset ne peut pas y protéger ses programmes."
    }
    if (-not $ok -or -not (Test-SansLien $DossierMindset) -or -not (Test-DossierProtege $racine)) {
        return "Mindset n'est pas installé dans un dossier protégé ($racine) : rien n'a été fait."
    }
    if (-not [IO.File]::Exists($Installateur) -or -not (Test-SansLien $Installateur)) {
        return "Le mini-installateur de Mindset (MindsetInstallateur.exe) est introuvable dans $DossierMindset : rien n'a été fait."
    }
    ''
}

# Par une tâche, quand MindsetInstallateur.exe ne peut pas être lancé : la demande est refusée ici, avec la même
# réponse qu'avant (accusé de réception puis réponse dans HKLM:\SOFTWARE\Mindset\Installation, jamais dans un dossier
# modifiable sans droits). La demande est lue avec les mêmes contrôles : sans lien, 16 Ko au plus, numéro valable, pas
# déjà reçue. Une mise à jour de Mindset le relance (il s'est déjà fermé).
function Write-RefusTache([string]$Message) {
    $cle = 'HKLM:\SOFTWARE\Mindset\Installation'
    $j = $null
    try {
        if (-not $Demande -or -not (Test-SansLien $Demande)) { return }
        $fi = New-Object IO.FileInfo $Demande
        if (-not $fi.Exists -or $fi.Length -gt 16KB) { return }
        $j = [IO.File]::ReadAllText($Demande, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { $j = $null }
    if (-not $j -or [string]$j.Id -notmatch '^[0-9a-f]{8,32}\z') { return }
    $recu = ''
    try { $recu = [string](Get-ItemProperty -Path $cle -Name 'Recu' -ErrorAction Stop).Recu } catch {}
    if ($recu -eq [string]$j.Id) { return }
    try {
        New-Item -Path $cle -Force | Out-Null
        Set-ItemProperty -Path $cle -Name 'Recu' -Value ([string]$j.Id)
        New-Item -Path $cle -Force | Out-Null
        Set-ItemProperty -Path $cle -Name 'Resultat' -Value (@{ id = [string]$j.Id; ok = $false; message = $Message } | ConvertTo-Json -Compress)
    } catch {}
    if ([string]$j.Action -eq 'mindset-maj') { $null = & $Schtasks /Run /TN '\Mindset\Mindset (démarrage)' 2>&1 }
}

# Un argument de la ligne de commande, entre guillemets si besoin, comme Windows les relit (les « \ » qui précèdent un
# guillemet ou la fin sont doublés) : chaque valeur arrive telle quelle à MindsetInstallateur.exe
function Format-Argument([string]$Valeur) {
    if ($Valeur -and $Valeur -notmatch '[\s"]') { return $Valeur }
    $r = New-Object Text.StringBuilder
    [void]$r.Append('"')
    $barres = 0
    foreach ($c in $Valeur.ToCharArray()) {
        if ($c -eq '\') { $barres++; continue }
        if ($c -eq '"') { [void]$r.Append([char]'\', $barres * 2 + 1).Append([char]'"') }
        else { [void]$r.Append([char]'\', $barres).Append($c) }
        $barres = 0
    }
    [void]$r.Append([char]'\', $barres * 2).Append([char]'"')
    $r.ToString()
}

# Lance MindsetInstallateur.exe avec ces paramètres, sans fenêtre, et attend sa fin ; rend son code de sortie
function Invoke-Installateur([string[]]$Parametres) {
    $i = New-Object Diagnostics.ProcessStartInfo
    $i.FileName = $Installateur
    $i.Arguments = (@($Parametres | ForEach-Object { Format-Argument $_ }) -join ' ')
    $i.UseShellExecute = $false
    $i.CreateNoWindow = $true
    $i.WorkingDirectory = $DossierSysteme
    $p = [Diagnostics.Process]::Start($i)
    $p.WaitForExit()
    $p.ExitCode
}

# Les paramètres reçus, tels quels (dans l'ordre de la liste ci-dessus)
$transmis = New-Object Collections.Generic.List[string]
foreach ($n in 'Action', 'Resultat', 'Demande', 'Zip', 'Signature', 'Destination', 'DossierZip', 'Exe', 'AncienExe', 'Source', 'Version', 'AttendrePid', 'TacheAide', 'ExeAide', 'Appli', 'Disque', 'Sid', 'Liste') {
    if ($PSBoundParameters.ContainsKey($n)) { $transmis.Add("-$n"); $transmis.Add([string]$PSBoundParameters[$n]) }
}
if ($Cache) { $transmis.Add('-Cache') }

if ($Action -eq 'demande') {
    # Par une tâche (la tâche SYSTEM, ou l'ancienne « droits les plus élevés ») : jamais un programme hors du dossier
    # protégé
    $refus = Get-RefusRacine
    if ($refus) { Write-RefusTache $refus; exit }
    # La tâche SYSTEM inscrite par un Mindset d'avant lance encore ce script : ses tâches sont refaites par
    # MindsetInstallateur.exe (elles le lancent désormais lui-même), pour le même utilisateur, puis la demande lui est
    # passée. (L'ancienne tâche, sans -Sid, ne fait que passer la demande : il n'y accepte que « taches ».)
    if ($Sid) { $null = Invoke-Installateur @('-Action', 'taches', '-Destination', $DossierMindset, '-Sid', $Sid) }
    $null = Invoke-Installateur $transmis
    exit
}

# La demande de Windows : les paramètres passés tels quels, la réponse est celle de MindsetInstallateur.exe
if (-not [IO.File]::Exists($Installateur)) {
    $m = "Le mini-installateur de Mindset (MindsetInstallateur.exe) est introuvable dans $DossierMindset : rien n'a été fait."
    if ($Resultat) { try { [IO.File]::WriteAllText($Resultat, (@{ ok = $false; message = $m } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {} }
    exit 1
}
exit (Invoke-Installateur $transmis)
