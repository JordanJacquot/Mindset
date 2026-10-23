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
param([string]$Script, [string]$Parametres, [string]$Journal, [string]$Dossier, [string]$Lettre, [string]$LettreAmovible, [switch]$VraisProgrammes)
$global:TJournal = $Journal
$global:TPermis = @(($Dossier.TrimEnd('\') + '\'), "$($Lettre):\")
$global:TLettre = $Lettre; $global:TLettreAmovible = $LettreAmovible
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)
$env:ProgramFiles = Join-Path $Dossier 'ProgramFiles'
$env:LOCALAPPDATA = Join-Path $Dossier 'LocalAppData'
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
    Add-Journal "ACTION registre : $Path\$Name = $Value"
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
    Add-Journal "LECTURE disque $Filter"
    if ($Filter -like "*'$($global:TLettre):'*") { return [pscustomobject]@{ DriveType = 3; FileSystem = 'NTFS' } }
    if ($Filter -like "*'$($global:TLettreAmovible):'*") { return [pscustomobject]@{ DriveType = 2; FileSystem = 'FAT32' } }
}
# Tâches planifiées
function global:New-ScheduledTaskPrincipal { [pscustomobject]@{ Texte = "Principal $(Get-TexteArgs $args)" } }
function global:New-ScheduledTaskSettingsSet { [pscustomobject]@{ Texte = 'Reglages' } }
function global:New-ScheduledTaskAction { [pscustomobject]@{ Texte = "Action $(Get-TexteArgs $args)" } }
function global:New-ScheduledTaskTrigger { [pscustomobject]@{ Texte = "Declencheur $(Get-TexteArgs $args)"; Delay = $null } }
function global:Register-ScheduledTask { Add-Journal "ACTION tâche créée : $(Get-TexteArgs $args)" }
function global:Unregister-ScheduledTask { Add-Journal "ACTION tâche retirée : $(Get-TexteArgs $args)" }
function global:Set-ScheduledTask { Add-Journal "ACTION tâche modifiée : $(Get-TexteArgs $args)" }
function global:Get-ScheduledTask { Add-Journal "LECTURE tâches $(Get-TexteArgs $args)" }
# Programmes
# (de faux programmes ouverts, avec leur chemin : Mindset lui-même, l'hôte Mindset.exe et l'ancien Appli.exe de l'appli,
# son aide, une autre appli au nom proche « AppliBis », des copies ailleurs, un processus au chemin illisible)
# -VraisProgrammes : les vrais Get-Process et Stop-Process, sur des programmes d'essai lancés par le test sous %TEMP%
if (-not $VraisProgrammes) {
    $pmt = Join-Path $env:ProgramFiles 'Mindset'
    $global:TProcessus = @(
        [pscustomobject]@{ Id = 101; Path = "$pmt\Mindset\Mindset.exe" }
        [pscustomobject]@{ Id = 102; Path = "$pmt\Appli\Mindset.exe" }
        [pscustomobject]@{ Id = 103; Path = "$pmt\Appli\Appli.exe" }
        [pscustomobject]@{ Id = 104; Path = "$pmt\Appli\Aide.exe" }
        [pscustomobject]@{ Id = 105; Path = "$pmt\AppliBis\Appli.exe" }
        [pscustomobject]@{ Id = 106; Path = "$Dossier\ailleurs\Appli.exe" }
        [pscustomobject]@{ Id = 107; Path = "$Dossier\ailleurs\Mindset.exe" }
        [pscustomobject]@{ Id = 108; Path = $null })
    function global:Get-Process { [CmdletBinding()] param([string[]]$Name) Add-Journal "LECTURE programmes ouverts $Name"; $global:TProcessus }
    function global:Stop-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force) process { Add-Journal "ACTION arrêt du programme $($InputObject.Path)" } }
}
function global:Wait-Process { Add-Journal "LECTURE attente $(Get-TexteArgs $args)" }
function global:Start-Process { [CmdletBinding()] param([string]$FilePath, [string[]]$ArgumentList) Add-Journal "ACTION lancement $FilePath $ArgumentList" }
function global:Start-Sleep { }
function global:New-Object {
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
Copy-Item -LiteralPath (Join-Path $fichiers 'installer-admin.ps1') -Destination $copie
foreach ($m in 'signature.ps1', 'paquets.ps1') { Copy-Item -LiteralPath (Join-Path $fichiers "modules\$m") -Destination (Join-Path $copie 'modules') }
$installeur = Join-Path $copie 'installer-admin.ps1'
$propreMindset = [IO.Path]::GetFullPath((Join-Path $copie '..\Mindset.exe'))   # le Mindset qui a fait la demande
$lanceur = Join-Path $tmp 'lanceur.ps1'
[IO.File]::WriteAllText($lanceur, $texteLanceur, (New-Object Text.UTF8Encoding $true))

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 3072
try {
    $rsa.PersistKeyInCsp = $false
    $null = Save-Fichier (Join-Path $copie 'cles-publiques\test.xml') $rsa.ToXmlString($false)
    function Save-Paquet([string]$Nom, $Entrees) {
        $z = New-ZipTest $Entrees
        [IO.File]::WriteAllBytes((Join-Path $tmp "paquets\$Nom.zip"), $z)
        [IO.File]::WriteAllBytes((Join-Path $tmp "paquets\$Nom.zip.sig"), $rsa.SignData($z, $sha256))
        Join-Path $tmp "paquets\$Nom.zip"
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'paquets') | Out-Null
    $zipAppli = Save-Paquet 'Appli' ([ordered]@{ 'Appli/Appli.exe' = 'appli 2.0.0'; 'Appli/Aide.exe' = 'aide 2.0.0'; 'Appli/fichiers/Appli.ps1' = "`$AppVersion = '2.0.0'`r`n" })
    $zipMindset = Save-Paquet 'Mindset' ([ordered]@{ 'Mindset/Mindset.exe' = 'mindset 2.0.0'; 'Mindset/fichiers/Mindset.ps1' = "`$AppVersion = '2.0.0'`r`n" })
    # Une signature fausse (celle d'un autre fichier)
    $sigFausse = Join-Path $tmp 'paquets\fausse.sig'
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
$racinesEtat = @($PF, (Join-Path $tmp 'disque'), (Join-Path $tmp 'LocalAppData'), (Join-Path $tmp 'victime'))
function Initialize-Etat {
    foreach ($d in $racinesEtat) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } ; New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $null = Save-Fichier (Join-Path $PM 'Mindset\Mindset.exe') 'mindset 1.0.0'
    $null = Save-Fichier (Join-Path $PM 'Mindset\fichiers\Mindset.ps1') "`$AppVersion = '1.0.0'"
    $null = Save-Fichier (Join-Path $PM 'Appli\Appli.exe') 'appli 1.0.0'
    $null = Save-Fichier (Join-Path $PM 'Appli\Aide.exe') 'aide 1.0.0'
    $null = Save-Fichier (Join-Path $PM 'Appli\fichiers\Appli.ps1') "`$AppVersion = '1.0.0'"
    $null = Save-Fichier (Join-Path $tmp 'victime\important.txt') 'à garder'
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
function Invoke-Installateur([hashtable]$Parametres, [scriptblock]$Preparer = $null, [switch]$SansResultat, [switch]$VraisProgrammes) {
    $n = ++$script:NumeroCas
    Initialize-Etat
    if ($Preparer) { & $Preparer }
    $journal = Join-Path $tmp "journaux\$n.txt"; [IO.File]::WriteAllText($journal, '')
    $fichierReponse = Join-Path $tmp "resultats\$n.json"
    if (-not $SansResultat -and -not $Parametres.ContainsKey('Resultat')) { $Parametres['Resultat'] = $fichierReponse }
    $fp = Save-Fichier (Join-Path $tmp "journaux\$n.json") ($Parametres | ConvertTo-Json -Compress)
    $avant = @(Get-Etat)
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $sortie = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $lanceur `
            -Script $installeur -Parametres $fp -Journal $journal -Dossier $tmp -Lettre $L -LettreAmovible $LA @(if ($VraisProgrammes) { '-VraisProgrammes' }) 2>&1
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
function Invoke-Demande($Contenu, [int]$Taille = 0, [scriptblock]$Preparer = $null) {
    $f = New-Demande $Contenu $Taille
    Invoke-Installateur @{ Action = 'demande'; Demande = $f } $Preparer
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
function Test-TacheCreee($R, [string]$Nom, [string]$Sid = $sidActuel) {
    [bool]@($R.Actions | Where-Object { $_.Contains('ACTION tâche créée') -and $_.Contains("-TaskName $Nom -") -and $_.Contains("-UserId $Sid ") }).Count
}
function Test-SansTache($R) { -not @($R.Actions | Where-Object { $_ -like 'ACTION tâche*' }).Count }
$relancePropre = "ACTION lancement *explorer.exe `"$propreMindset`""

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
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f }
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
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f }
        (Test-Refuse $r 'Demande illisible') -and -not $r.Registre -and (Test-RienFait $r)
    }
    Test-Cas 'demande illisible, lancée comme par la tâche (sans -Resultat) : aucune réponse écrite nulle part' {
        $f = New-Demande 'pas du json'
        $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f } -SansResultat
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
            (Test-TacheCreee $r 'Mindset (installation)') -and (Test-Action $r "explorer.exe `"$(Join-Path $dest 'Mindset.exe')`"")
    }
    foreach ($cas in @(
            @{ Nom = 'hors de Program Files\Mindset'; Dossier = (Join-Path $tmp 'victime\Mindset') },
            @{ Nom = 'Program Files\Mindset lui-même'; Dossier = $PM },
            @{ Nom = 'qui ne s''appelle pas Mindset (une appli)'; Dossier = (Join-Path $PM 'Appli') })) {
        $c = $cas
        Test-Cas "mise à jour vers un dossier $($c.Nom) : « Dossier refusé », rien installé, seul l'ancien Mindset relancé" {
            $r = Invoke-Demande (Merge-Table $maj @{ Id = (New-Id); Destination = $c.Dossier })
            (Test-Refuse $r 'Dossier refusé') -and (Test-RienFait $r @($relancePropre))
        }
    }
    Test-Cas 'mise à jour à la signature fausse : refusée, rien installé, aucune tâche, aucune clé' {
        $r = Invoke-Demande (Merge-Table $maj @{ Id = (New-Id); Signature = $sigFausse })
        (Test-Refuse $r 'signature') -and (Test-RienFait $r @("ACTION lancement *explorer.exe `"$(Join-Path $PM 'Mindset\Mindset.exe')`""))
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
    $r = Invoke-Installateur @{ Action = 'demande'; Demande = $f } -VraisProgrammes -Preparer {
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
