# Mindset : juges du bloc Rust « installations » (rust\mindset-installations), exportés depuis la version PowerShell.
#
#   & '.\outils\exporter-juges-installations.ps1'   (depuis l'outil PowerShell, jamais par powershell.exe lancé ailleurs)
#
# Les VRAIES fonctions de Mindset\fichiers\modules\installations.ps1 (et Get-RaisonEchecMaj de mindset.ps1, les
# lectures de zip de paquets.ps1) sont prises telles quelles dans leur fichier (lecture de leur texte), puis passées à
# des cas inventés dans un faux PC sous %TEMP%. Leurs réponses vont dans rust\mindset-installations\tests\juges\*.json,
# que « cargo test -p mindset-installations » rejoue (tests\juges.rs) :
#   - dossiers.json      Test-DossierAppli, Get-VersionDans, Get-ScriptAppli
#   - installations.json Read-Installations, Save-Installation, Get-Installation (installations.json, dossiers)
#   - arguments.json     Format-ArgumentAdmin
#   - variables.json     Get-RefusVariablesAdmin
#   - raisons.json       Get-RaisonEchecMaj
#   - run.json           Get-DemarragesAppli
#   - demarrage.json     Get-DemarrageWindowsAppli
#   - copie.json         Remove-AncienneCopie (vrai zip, vrais fichiers)
#   - desinstallation.json  Complete-Desinstallation (données gardées ou non, WebView2, WebView2-Tauri)
#   - paquets.json       Get-DossierZip, Test-PaquetAppli
#   - admin.json         la file du mini-installateur : Invoke-Admin, Send-DemandeInstallation, Update-AttentesAdmin,
#                        Skip-TacheInstallation, Invoke-AdminDirect, Send-DemandeSuivante (faux schtasks, faux registre,
#                        fausse demande de Windows, horloge simulée, comme outils\tester-mini-installateur.ps1)
#
# Rien sur le vrai PC : aucun schtasks, aucun registre, aucune demande de Windows, aucun réseau, aucune fenêtre. Les
# seules variables d'environnement touchées sont celles de ce PowerShell-ci, remises comme avant à la fin. Le dossier
# temporaire est supprimé à la fin. Les noms d'essai sont inventés (« Café crème », « Forêt »).

param([string]$Fichiers)

$ErrorActionPreference = 'Stop'
$racineDepot = Split-Path $PSScriptRoot -Parent
$fichiers = if ($Fichiers) { (Resolve-Path -LiteralPath $Fichiers).Path } else { Join-Path $racineDepot 'Mindset\fichiers' }
$sortie = Join-Path $racineDepot 'rust\mindset-installations\tests\juges'
New-Item -ItemType Directory -Force -Path $sortie | Out-Null
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------------------------------------------------------------------------------------------------------
# Les vraies fonctions, prises dans leur fichier
# ---------------------------------------------------------------------------------------------------------------
$asts = @{}
foreach ($m in 'installations.ps1', 'mindset.ps1', 'paquets.ps1') {
    $e = $null
    $asts[$m] = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $fichiers "modules\$m"), [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
}
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    foreach ($n in $Noms) {
        $x = @($asts[$Fichier].FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true)) | Select-Object -First 1
        if (-not $x) { throw "$Fichier : $n introuvable" }
        . ([scriptblock]::Create($x.Extent.Text))
        Set-Item -Path "function:script:$($x.Name)" -Value (Get-Item "function:$($x.Name)").ScriptBlock
    }
}
Import-Fonctions 'paquets.ps1' 'Read-VersionJson', 'Get-VersionJsonZip', 'Test-PaquetAppli', 'Get-DossierZip', 'Test-VersionPlusRecente'
Import-Fonctions 'mindset.ps1' 'Get-RaisonEchecMaj'
Import-Fonctions 'installations.ps1' 'Get-DossierGere', 'Get-DossierDonnees', 'Read-Installations', 'Save-Installation', 'Get-ScriptAppli',
    'Get-VersionDans', 'Test-DossierAppli', 'Get-Installation', 'Get-DemarragesAppli', 'Get-DemarrageWindowsAppli', 'Test-DossierSur',
    'Test-DossierTravail', 'Remove-AncienneCopie', 'Complete-Desinstallation', 'Format-ArgumentAdmin', 'Get-RefusVariablesAdmin',
    'Test-TacheInstallation', 'Get-EtatTacheInstallation', 'Send-DemandeInstallation', 'Skip-TacheInstallation', 'Invoke-Admin',
    'Invoke-AdminDirect', 'Send-DemandeSuivante', 'Update-AttentesAdmin', 'Get-ValeurInstallation', 'Set-DemarrageAppli', 'Get-DemarrageAppli'

# ---------------------------------------------------------------------------------------------------------------
# Le faux PC
# ---------------------------------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "mindset-juges-installations-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$EnTest = $false
$script:Journal = New-Object Collections.Generic.List[string]
function Write-Log([string]$T) { $script:Journal.Add($T) }
$script:Reglages = @{}
function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.ContainsKey($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur }
$script:Suite = [ordered]@{}
function Set-SuiteAppli([string]$Id, [string]$Dossier) { if ($Dossier) { $script:Suite[$Id] = $Dossier } else { $script:Suite.Remove($Id) } }
function Read-JsonSur([string]$Fichier) {
    if (-not [IO.File]::Exists($Fichier)) { return $null }
    $t = [IO.File]::ReadAllText($Fichier, [Text.Encoding]::UTF8)
    try { $j = $t | ConvertFrom-Json } catch { return $null }
    if ($j -is [System.Management.Automation.PSCustomObject]) { $j } else { $null }
}
function Save-JsonSur([string]$Fichier, [string]$Texte) { [IO.File]::WriteAllText($Fichier, $Texte, (New-Object Text.UTF8Encoding $false)) }
$script:Occupe = @{}
$MindsetAdmin = $false
$MenuApplis = ''

function Set-Racine([string]$R) {
    $script:R = $R
    $script:RacineProgrammes = Join-Path $R 'Programmes'
    $script:SuiteDir = Join-Path $R 'Donnees'
    $script:DataDir = Join-Path $R 'Donnees\Mindset'
    $script:InstallFile = Join-Path $script:DataDir 'installations.json'
    $script:TelechargementsDir = Join-Path $script:DataDir 'telechargements'
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
}
function Expand-R([string]$T) { if ($null -eq $T) { return $null }; $T.Replace('<R>', $script:R) }
function Hide-R($V) {
    if ($null -eq $V) { return $null }
    if ($V -is [string]) { return $V.Replace($script:R, '<R>') }
    $V
}
# Une appli d'essai (les champs d'apps.json dont les fonctions se servent)
function New-Appli($A) {
    [pscustomobject]@{
        Id = [string]$A.id; Nom = [string]$A.nom; Exe = [string]$A.exe; Script = [string]$A.script; AncienScript = [string]$A.ancien_script
        DossierZip = [string]$A.dossier_zip; AncienDossierZip = [string]$A.ancien_dossier_zip; Donnees = (Expand-R ([string]$A.donnees))
        Rappels = [bool]$A.rappels; Aide = [string]$A.aide; AppId = ''; Description = ''
    }
}
# Des fichiers : chemin relatif -> texte (UTF-8 sans BOM), ou { b64 }
function New-Fichiers([string]$Dossier, $Liste) {
    foreach ($f in @($Liste)) {
        if (-not $f) { continue }
        $p = Join-Path $Dossier ([string]$f.chemin)
        New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
        if ($f.dossier) { New-Item -ItemType Directory -Force -Path $p | Out-Null; continue }
        if ($null -ne $f.b64) { [IO.File]::WriteAllBytes($p, [Convert]::FromBase64String([string]$f.b64)) }
        else { [IO.File]::WriteAllText($p, (Expand-R ([string]$f.texte)), (New-Object Text.UTF8Encoding $false)) }
    }
}
function Get-Arbre([string]$Dossier) {
    if (-not (Test-Path -LiteralPath $Dossier)) { return @() }
    $d = (Resolve-Path -LiteralPath $Dossier).Path.TrimEnd('\')
    @(Get-ChildItem -LiteralPath $d -Recurse -Force | ForEach-Object { $r = $_.FullName.Substring($d.Length + 1); if ($_.PSIsContainer) { "$r\" } else { $r } } | Sort-Object { $_.ToLowerInvariant() })
}
function Save-Juge([string]$Nom, $Cas) {
    $j = [ordered]@{ famille = $Nom; origine = 'outils\exporter-juges-installations.ps1'; cas = @($Cas) }
    $t = ConvertTo-Json -InputObject $j -Depth 12
    [IO.File]::WriteAllText((Join-Path $sortie "$Nom.json"), $t, (New-Object Text.UTF8Encoding $false))
    Write-Host "  $Nom.json : $(@($Cas).Count) cas"
}
$numero = 0
function New-Racine { $script:numero++; $r = Join-Path $tmp "c$script:numero"; Set-Racine $r; $script:Journal.Clear(); $script:Suite.Clear(); $script:Reglages = @{}; $script:Occupe = @{}; $r }

$evermind = @{ id = 'evermind'; nom = 'Evermind'; exe = 'Evermind.exe'; script = 'fichiers\Evermind.ps1'; dossier_zip = 'Evermind'; donnees = '<R>\Anciennes\Evermind'; rappels = $true }
$nevermind = @{ id = 'nevermind'; nom = 'Nevermind'; exe = 'Nevermind.exe'; script = 'fichiers\Nevermind.ps1'; ancien_script = 'fichiers\OptiGame.ps1'; dossier_zip = 'Nevermind'; ancien_dossier_zip = 'OptiGame'; donnees = '<R>\Anciennes\Nevermind'; aide = 'NevermindAide' }
$mindcare = @{ id = 'mindcare'; nom = 'Mindcare'; exe = 'Mindcare.exe'; script = ''; dossier_zip = 'Mindcare'; donnees = '<R>\Anciennes\Mindcare' }
$cafe = @{ id = 'cafe-creme'; nom = 'CafeCreme'; exe = 'CafeCreme.exe'; script = 'fichiers\CafeCreme.ps1'; dossier_zip = 'CafeCreme'; donnees = '' }

Write-Host 'Juges du bloc installations :'

# ---------------------------------------------------------------------------------------------------------------
# dossiers.json : Test-DossierAppli, Get-VersionDans, Get-ScriptAppli
# ---------------------------------------------------------------------------------------------------------------
$vj = { param($o) $o | ConvertTo-Json -Compress }
$casDossiers = @(
    @{ nom = 'vide'; appli = $evermind; fichiers = @() }
    @{ nom = 'exe seul'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }) }
    @{ nom = 'script seul'; appli = $evermind; fichiers = @(@{ chemin = 'fichiers\Evermind.ps1'; texte = "`$AppVersion = '1.2.3'" }) }
    @{ nom = 'exe et script'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "# Evermind`r`n`$AppVersion = '2.4.0'`r`n" }) }
    @{ nom = 'script sans version'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "# rien`n" }) }
    @{ nom = 'version en minuscules'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "`$appversion='3.1'" }) }
    @{ nom = 'version decalee'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "  `$AppVersion = '3.1.0'" }) }
    @{ nom = 'version entre guillemets doubles'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "`$AppVersion = `"3.1.0`"" }) }
    @{ nom = 'deux versions'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "`$AppVersion = '1.0.0'`n`$AppVersion = '2.0.0'" }) }
    @{ nom = 'version avec BOM'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; b64 = [Convert]::ToBase64String([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("`$AppVersion = '1.9.9'")) }) }
    @{ nom = 'ancien script'; appli = $nevermind; fichiers = @(@{ chemin = 'Nevermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\OptiGame.ps1'; texte = "`$AppVersion = '1.14.0'" }) }
    @{ nom = 'les deux scripts'; appli = $nevermind; fichiers = @(@{ chemin = 'Nevermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\OptiGame.ps1'; texte = "`$AppVersion = '1.14.0'" }, @{ chemin = 'fichiers\Nevermind.ps1'; texte = "`$AppVersion = '1.20.0'" }) }
    @{ nom = 'exe est un dossier'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; dossier = $true }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "`$AppVersion = '1.0'" }) }
    @{ nom = 'script est un dossier'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; dossier = $true }) }
    @{ nom = 'rust complet'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"0.91.0","appli":"mindcare"}' }) }
    @{ nom = 'rust appli en majuscules'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"0.91.0","appli":"MindCare"}' }) }
    @{ nom = 'rust sans hote'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"0.91.0","appli":"mindcare"}' }) }
    @{ nom = 'rust autre appli'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"0.91.0","appli":"evermind"}' }) }
    @{ nom = 'rust sans appli'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"0.91.0"}' }) }
    @{ nom = 'rust appli vide'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"0.91.0","appli":""}' }) }
    @{ nom = 'rust version abimee'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"0.91","appli":"mindcare"' }) }
    @{ nom = 'rust version mal formee'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"v1","appli":"mindcare"}' }) }
    @{ nom = 'rust version.json vide'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '' }) }
    @{ nom = 'rust version.json utf16'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; b64 = [Convert]::ToBase64String([byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes('{"version":"1.0.4","appli":"mindcare"}')) }) }
    @{ nom = 'powershell avec version.json'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "`$AppVersion = '1.0.0'" }, @{ chemin = 'version.json'; texte = '{"version":"2.0.0","appli":"evermind"}' }) }
    @{ nom = 'version.json autre appli, script'; appli = $evermind; fichiers = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "`$AppVersion = '1.0.0'" }, @{ chemin = 'version.json'; texte = '{"version":"2.0.0","appli":"nevermind"}' }) }
    @{ nom = 'version.json mindset_min'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"1.0.0","appli":"mindcare","mindset_min":"3.0.0"}' }) }
    @{ nom = 'version.json mindset_min mal forme'; appli = $mindcare; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"1.0.0","appli":"mindcare","mindset_min":"trois"}' }) }
    @{ nom = 'accents dans le dossier'; appli = $cafe; sous = 'Café crème'; fichiers = @(@{ chemin = 'CafeCreme.exe'; texte = 'x' }, @{ chemin = 'fichiers\CafeCreme.ps1'; texte = "`$AppVersion = '0.1.0'" }) }
    @{ nom = 'version 4 nombres'; appli = $cafe; fichiers = @(@{ chemin = 'CafeCreme.exe'; texte = 'x' }, @{ chemin = 'fichiers\CafeCreme.ps1'; texte = "`$AppVersion = '1.2.3.4'" }) }
    @{ nom = 'version vide entre apostrophes'; appli = $cafe; fichiers = @(@{ chemin = 'CafeCreme.exe'; texte = 'x' }, @{ chemin = 'fichiers\CafeCreme.ps1'; texte = "`$AppVersion = ''`n`$AppVersion = '5.0'" }) }
    @{ nom = 'egal sur la ligne suivante'; appli = $cafe; fichiers = @(@{ chemin = 'CafeCreme.exe'; texte = 'x' }, @{ chemin = 'fichiers\CafeCreme.ps1'; texte = "`$AppVersion`n= '6.0'" }) }
)
$sorties = foreach ($c in $casDossiers) {
    $r = New-Racine
    $d = Join-Path $r $(if ($c.sous) { $c.sous } else { 'Appli' })
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    New-Fichiers $d $c.fichiers
    $a = New-Appli $c.appli
    $s = Get-ScriptAppli $d $a
    [ordered]@{ nom = $c.nom; appli = $c.appli; sous = $(if ($c.sous) { $c.sous } else { 'Appli' }); fichiers = @($c.fichiers)
        dossier_appli = [bool](Test-DossierAppli $d $a); version = (Get-VersionDans $d $a); script = $(if ($s) { $s.Substring($d.Length + 1) } else { $null }) }
}
Save-Juge 'dossiers' $sorties

# ---------------------------------------------------------------------------------------------------------------
# installations.json : Read-Installations, Save-Installation, Get-Installation
# ---------------------------------------------------------------------------------------------------------------
$appliEver = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = "`$AppVersion = '2.4.1'" })
$casInst = @(
    @{ nom = 'rien'; appli = $evermind; fichier = $null; dossiers = @() }
    @{ nom = 'fichier vide'; appli = $evermind; fichier = ''; dossiers = @() }
    @{ nom = 'fichier abime'; appli = $evermind; fichier = '{"evermind": {'; dossiers = @() }
    @{ nom = 'geree presente'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Programmes\\Evermind","gere":true}}'; dossiers = @(@{ chemin = 'Programmes\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'geree en majuscules'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\PROGRAMMES\\evermind","gere":true}}'; dossiers = @(@{ chemin = 'Programmes\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'geree hors du dossier protege'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Ailleurs\\Evermind","gere":true}}'; dossiers = @(@{ chemin = 'Ailleurs\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'geree hors, copie geree presente'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Ailleurs\\Evermind","gere":true}}'; dossiers = @(@{ chemin = 'Ailleurs\Evermind'; fichiers = $appliEver }, @{ chemin = 'Programmes\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'non geree presente'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Travail\\Evermind","gere":false}}'; dossiers = @(@{ chemin = 'Travail\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'non geree disparue'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Travail\\Evermind","gere":false},"nevermind":{"dossier":"<R>\\X","gere":false}}'; dossiers = @() }
    @{ nom = 'geree disparue'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Programmes\\Evermind","gere":true}}'; dossiers = @(); suite = @{ evermind = '<R>\Programmes\Evermind' } }
    @{ nom = 'geree disparue pendant une operation'; appli = $evermind; occupee = $true; fichier = '{"evermind":{"dossier":"<R>\\Programmes\\Evermind","gere":true}}'; dossiers = @() }
    @{ nom = 'oubliee mais presente'; appli = $evermind; fichier = '{}'; dossiers = @(@{ chemin = 'Programmes\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'fichier absent, copie geree'; appli = $evermind; fichier = $null; dossiers = @(@{ chemin = 'Programmes\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'gere en texte'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Travail\\Evermind","gere":"false"}}'; dossiers = @(@{ chemin = 'Travail\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'gere en nombre'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Programmes\\Evermind","gere":0}}'; dossiers = @(@{ chemin = 'Programmes\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'dossier absent du fichier'; appli = $evermind; fichier = '{"evermind":{"gere":false}}'; dossiers = @() }
    @{ nom = 'entree en texte'; appli = $evermind; fichier = '{"evermind":"<R>\\Travail"}'; dossiers = @() }
    @{ nom = 'id en majuscules'; appli = $evermind; fichier = '{"Evermind":{"dossier":"<R>\\Travail\\Evermind","gere":false}}'; dossiers = @(@{ chemin = 'Travail\Evermind'; fichiers = $appliEver }) }
    @{ nom = 'autres applis gardees'; appli = $evermind; fichier = '{"nevermind":{"dossier":"<R>\\N","gere":false},"evermind":{"dossier":"<R>\\Rien","gere":false},"mindcare":{"dossier":"<R>\\M","gere":true}}'; dossiers = @() }
    @{ nom = 'dossier avec accents'; appli = $evermind; fichier = '{"evermind":{"dossier":"<R>\\Forêt\\Café crème","gere":false}}'; dossiers = @(@{ chemin = 'Forêt\Café crème'; fichiers = $appliEver }) }
    @{ nom = 'rust gere'; appli = $mindcare; fichier = '{"mindcare":{"dossier":"<R>\\Programmes\\Mindcare","gere":true}}'; dossiers = @(@{ chemin = 'Programmes\Mindcare'; fichiers = @(@{ chemin = 'Mindcare.exe'; texte = 'x' }, @{ chemin = 'Mindset.exe'; texte = 'x' }, @{ chemin = 'version.json'; texte = '{"version":"0.92.1","appli":"mindcare"}' }) }) }
    @{ nom = 'tableau au lieu d objet'; appli = $evermind; fichier = '[1,2]'; dossiers = @(@{ chemin = 'Programmes\Evermind'; fichiers = $appliEver }) }
)
$sorties = foreach ($c in $casInst) {
    $r = New-Racine
    foreach ($d in @($c.dossiers)) { if ($d) { $p = Join-Path $r $d.chemin; New-Item -ItemType Directory -Force -Path $p | Out-Null; New-Fichiers $p $d.fichiers } }
    if ($null -ne $c.fichier) { [IO.File]::WriteAllText($InstallFile, (Expand-R ($c.fichier -replace '\\\\', '\')).Replace('\', '\\'), (New-Object Text.UTF8Encoding $false)) }
    if ($c.suite) { foreach ($k in $c.suite.Keys) { $script:Suite[$k] = Expand-R $c.suite[$k] } }
    $a = New-Appli $c.appli
    if ($c.occupee) { $script:Occupe[$a.Id] = 'Installation...' }
    $i = Get-Installation $a
    $apres = $null
    if ([IO.File]::Exists($InstallFile)) { try { $apres = [IO.File]::ReadAllText($InstallFile, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $apres = 'abime' } }
    $apresNorm = $null
    if ($apres -is [System.Management.Automation.PSCustomObject]) { $apresNorm = [ordered]@{}; foreach ($p in $apres.PSObject.Properties) { $apresNorm[$p.Name] = [ordered]@{ dossier = (Hide-R ([string]$p.Value.dossier)); gere = [bool]$p.Value.gere } } }
    elseif ($apres) { $apresNorm = $apres }
    $suiteSortie = [ordered]@{}; foreach ($k in $script:Suite.Keys) { $suiteSortie[$k] = Hide-R $script:Suite[$k] }
    [ordered]@{ nom = $c.nom; appli = $c.appli; fichier = $c.fichier; dossiers = @($c.dossiers); occupee = [bool]$c.occupee; suite_avant = $c.suite
        installation = $(if ($i) { [ordered]@{ dossier = (Hide-R $i.Dossier); gere = [bool]$i.Gere; version = $i.Version } } else { $null })
        fichier_apres = $apresNorm; suite = $suiteSortie; journal = @($script:Journal | ForEach-Object { Hide-R $_ }) }
}
Save-Juge 'installations' $sorties

# ---------------------------------------------------------------------------------------------------------------
# arguments.json : Format-ArgumentAdmin
# ---------------------------------------------------------------------------------------------------------------
$valeurs = @('C:\Program Files\Mindset\Evermind', 'E:\', 'E:\\', 'C:\a\b\\\', '', 'simple', 'avec espace', 'Forêt\Café crème', 'a"b', '"', 'fin\"', "d$([char]0x2019)Arthur", 'x$y', 'C:\x\ y\', '\\serveur\partage\')
$sorties = foreach ($v in $valeurs) {
    try { [ordered]@{ valeur = $v; resultat = (Format-ArgumentAdmin $v); erreur = $null } } catch { [ordered]@{ valeur = $v; resultat = $null; erreur = $_.Exception.Message } }
}
Save-Juge 'arguments' $sorties

# ---------------------------------------------------------------------------------------------------------------
# variables.json : Get-RefusVariablesAdmin (les variables de ce PowerShell-ci, remises comme avant)
# ---------------------------------------------------------------------------------------------------------------
$deja = @([Environment]::GetEnvironmentVariables('Process').Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^(COR_|COMPlus_|CORECLR_|DOTNET_STARTUP_HOOKS\z|DOTNET_ADDITIONAL_DEPS\z|DOTNET_SHARED_STORE\z)' })
if ($deja.Count) { throw "Ce PowerShell a déjà des variables $($deja -join ', ') : les juges des variables seraient faux" }
$casVar = @(
    @{ nom = 'rien'; processus = @(); compte = @() }
    @{ nom = 'reglage dotnet sans danger'; processus = @('DOTNET_TieredCompilation'); compte = @('DOTNET_gcServer') }
    @{ nom = 'cor profiler'; processus = @('COR_ENABLE_PROFILING', 'COR_PROFILER'); compte = @() }
    @{ nom = 'complus du compte'; processus = @(); compte = @('COMPlus_ETWEnabled') }
    @{ nom = 'complus en majuscules'; processus = @('COMPLUS_X'); compte = @() }
    @{ nom = 'coreclr et hooks'; processus = @('CORECLR_PROFILER'); compte = @('DOTNET_STARTUP_HOOKS', 'DOTNET_ADDITIONAL_DEPS') }
    @{ nom = 'shared store'; processus = @(); compte = @('DOTNET_SHARED_STORE') }
    @{ nom = 'presque'; processus = @('DOTNET_STARTUP_HOOKSX', 'XCOR_', 'COR'); compte = @('DOTNET_SHARED_STORE_2') }
    @{ nom = 'doublon processus et compte'; processus = @('COR_PROFILER'); compte = @('cor_profiler', 'COR_PROFILER') }
    @{ nom = 'ordre'; processus = @('COR_Z', 'COMPlus_A'); compte = @('CORECLR_M', 'cor_b') }
)
$sorties = foreach ($c in $casVar) {
    $script:Journal.Clear()
    $script:Compte = @($c.compte)
    function Get-NomsVariablesCompte { @($script:Compte) }
    foreach ($n in $c.processus) { [Environment]::SetEnvironmentVariable($n, '1', 'Process') }
    try { $m = Get-RefusVariablesAdmin } finally { foreach ($n in $c.processus) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') } }
    [ordered]@{ nom = $c.nom; processus = @($c.processus); compte = @($c.compte); message = [string]$m; journal = @($script:Journal) }
}
Save-Juge 'variables' $sorties

# ---------------------------------------------------------------------------------------------------------------
# raisons.json : Get-RaisonEchecMaj
# ---------------------------------------------------------------------------------------------------------------
$messages = @(
    'Échec : CafeCreme est encore ouvert', 'Échec : les fichiers sont utilisés par un autre programme', 'The process cannot access the file because it is being used by another process.',
    'Échec : La signature du fichier téléchargé est invalide : rien n''a été installé.', 'la tâche d''installation ne répond pas (pas de réponse de la tâche en 30 secondes).',
    'Échec : Impossible de se connecter au serveur distant', 'Échec : Le délai d''attente de l''opération a expiré.', 'The operation has timed out.', 'Timeout',
    'Échec : Le serveur distant a retourné une erreur : (404) Introuvable.', 'Échec : erreur 4040', 'Échec : HTTP 503', 'Échec : code_403',
    'Échec : Il n''y a pas assez d''espace disque.', 'There is not enough space on the disk.', '', 'Échec : ', '   ÉCHEC   :   bizarre', 'échec: minuscule',
    'Échec : Version 1.0.0 refusée : la version 2.0.0, plus récente, est déjà installée.', 'Une erreur sans point', 'Une erreur avec point d''exclamation !', 'Question ?',
    ('Échec : ' + ('x' * 150)), ('y' * 139 + '.'), ('z' * 141), 'Échec : INTERNET coupé', 'Réseau indisponible', 'Échec : impossible de résoudre le nom', 'Échec : remote host closed',
    'Échec : la tâche d''installation ne répond pas.', "Échec : ligne`nsuite", "fin par saut`n", 'Échec : Le zip ne contient pas CafeCreme.exe dans le dossier CafeCreme.',
    'Échec : pas de réponse du mini-installateur (opération interrompue ?).', 'Signature : rien', 'Échec : place sur le disque insuffisante', 'Échec: disque plein'
)
$sorties = foreach ($m in $messages) { [ordered]@{ nom = 'CafeCreme'; message = $m; raison = (Get-RaisonEchecMaj 'CafeCreme' $m) } }
$sorties = @($sorties) + @([ordered]@{ nom = 'Evermind'; message = 'encore ouvert'; raison = (Get-RaisonEchecMaj 'Evermind' 'encore ouvert') })
Save-Juge 'raisons' $sorties

# ---------------------------------------------------------------------------------------------------------------
# run.json : Get-DemarragesAppli (fausse clé Run de l'utilisateur)
# ---------------------------------------------------------------------------------------------------------------
$casRun = @(
    @{ nom = 'aucune'; exe = 'Evermind.exe'; entrees = @() }
    @{ nom = 'entre guillemets avec argument'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'Evermind'; valeur = '"C:\Users\x\Evermind\Evermind.exe" -Demarrage' }) }
    @{ nom = 'sans guillemets'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'Evermind'; valeur = 'C:\Evermind\Evermind.exe' }) }
    @{ nom = 'majuscules'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'E'; valeur = 'c:\evermind\EVERMIND.EXE' }) }
    @{ nom = 'sans dossier'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'E'; valeur = 'Evermind.exe' }) }
    @{ nom = 'autre appli'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'N'; valeur = 'C:\N\Nevermind.exe' }) }
    @{ nom = 'nom qui commence par PS'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'PSEvermind'; valeur = 'C:\E\Evermind.exe' }, @{ nom = 'Evermind'; valeur = 'C:\F\Evermind.exe' }) }
    @{ nom = 'valeur pas texte'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'E'; nombre = 5 }) }
    @{ nom = 'nom proche'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'E'; valeur = 'C:\E\MonEvermind.exe' }) }
    @{ nom = 'exe deux fois'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'E'; valeur = 'C:\Evermind.exe\Evermind.exe -x' }) }
    @{ nom = 'guillemet au milieu'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'E'; valeur = 'C:\a"b\Evermind.exe' }) }
    @{ nom = 'cmd devant'; exe = 'Evermind.exe'; entrees = @(@{ nom = 'E'; valeur = 'cmd /c "C:\E\Evermind.exe"' }) }
    @{ nom = 'plusieurs'; exe = 'Nevermind.exe'; entrees = @(@{ nom = 'Nevermind'; valeur = '"D:\Jeux\Nevermind\Nevermind.exe"' }, @{ nom = 'OptiGame'; valeur = 'D:\OptiGame\Nevermind.exe /min' }, @{ nom = 'Autre'; valeur = 'C:\x.exe' }) }
    @{ nom = 'accents'; exe = 'CafeCreme.exe'; entrees = @(@{ nom = 'Café'; valeur = '"C:\Forêt\Café crème\CafeCreme.exe"' }) }
)
$sorties = foreach ($c in $casRun) {
    $script:Run = [pscustomobject]@{ PSPath = 'x'; PSParentPath = 'y'; PSChildName = 'Run'; PSDrive = 'HKCU'; PSProvider = 'Registry' }
    foreach ($e in @($c.entrees)) { if ($e) { $script:Run | Add-Member NoteProperty $e.nom $(if ($null -ne $e.nombre) { [int]$e.nombre } else { [string]$e.valeur }) } }
    function Get-ItemProperty { [CmdletBinding()] param([string]$Path) $script:Run }
    $a = [pscustomobject]@{ Exe = $c.exe }
    [ordered]@{ nom = $c.nom; exe = $c.exe; entrees = @($c.entrees); trouvees = @(Get-DemarragesAppli $a | ForEach-Object { [ordered]@{ nom = $_.Nom; cible = $_.Cible } }) }
}
Remove-Item function:Get-ItemProperty -ErrorAction SilentlyContinue
Save-Juge 'run' $sorties

# ---------------------------------------------------------------------------------------------------------------
# demarrage.json : Get-DemarrageWindowsAppli
# ---------------------------------------------------------------------------------------------------------------
$TachesDemarrageAppli = @{ nevermind = @('Nevermind (démarrage)', 'OptiGame (démarrage)', 'Nexo (démarrage)') }
function Get-TachesDemarrageAppli([string]$Id) { @(foreach ($n in @($TachesDemarrageAppli[$Id] | Where-Object { $_ })) { if ($script:TachesExistantes -contains "\$n") { $n } }) }
$casDem = @(
    @{ nom = 'rien'; appli = $evermind }
    @{ nom = 'entree run'; appli = $evermind; run = @(@{ nom = 'Evermind'; valeur = 'C:\E\Evermind.exe' }) }
    @{ nom = 'reglage vrai'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"DemarrageWindows":true}' }) }
    @{ nom = 'reglage faux'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"DemarrageWindows":false}' }) }
    @{ nom = 'reglage texte'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"DemarrageWindows":"true"}' }) }
    @{ nom = 'reglage nombre'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"DemarrageWindows":1}' }) }
    @{ nom = 'parametres.json'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\parametres.json'; texte = '{"DemarrageWindows":true}' }) }
    @{ nom = 'reglages avant parametres'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"DemarrageWindows":false}' }, @{ chemin = 'Anciennes\Evermind\parametres.json'; texte = '{"DemarrageWindows":true}' }) }
    @{ nom = 'reglages abime'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"DemarrageWindows":' }, @{ chemin = 'Anciennes\Evermind\parametres.json'; texte = '{"DemarrageWindows":true}' }) }
    @{ nom = 'suite d abord'; appli = $evermind; installations = '{"evermind":{"dossier":"<R>\\Programmes\\Evermind","gere":true}}'; fichiers = @(@{ chemin = 'Donnees\Evermind\reglages.json'; texte = '{"DemarrageWindows":false}' }, @{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"DemarrageWindows":true}' }) }
    @{ nom = 'suite pas geree'; appli = $evermind; installations = '{"evermind":{"dossier":"<R>\\Programmes\\Evermind","gere":false}}'; fichiers = @(@{ chemin = 'Donnees\Evermind\reglages.json'; texte = '{"DemarrageWindows":false}' }, @{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"DemarrageWindows":true}' }) }
    @{ nom = 'tache sans admin'; appli = $nevermind; taches = @('\Nevermind (démarrage)') }
    @{ nom = 'tache avec admin'; appli = $nevermind; admin = $true; taches = @('\OptiGame (démarrage)') }
    @{ nom = 'admin sans tache'; appli = $nevermind; admin = $true; taches = @() }
    @{ nom = 'reglage absent'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '{"Theme":"neon"}' }) }
    @{ nom = 'reglages tableau'; appli = $evermind; fichiers = @(@{ chemin = 'Anciennes\Evermind\reglages.json'; texte = '[true]' }) }
    @{ nom = 'sans dossier de donnees'; appli = $cafe; run = @() }
)
$sorties = foreach ($c in $casDem) {
    $r = New-Racine
    New-Fichiers $r $c.fichiers
    if ($c.installations) { [IO.File]::WriteAllText($InstallFile, (Expand-R ($c.installations -replace '\\\\', '\')).Replace('\', '\\'), (New-Object Text.UTF8Encoding $false)) }
    $script:TachesExistantes = @($c.taches)
    $MindsetAdmin = [bool]$c.admin
    $script:Run = [pscustomobject]@{ PSPath = 'x' }
    foreach ($e in @($c.run)) { if ($e) { $script:Run | Add-Member NoteProperty $e.nom ([string]$e.valeur) } }
    function Get-ItemProperty { [CmdletBinding()] param([string]$Path) $script:Run }
    $a = New-Appli $c.appli
    $v = Get-DemarrageWindowsAppli $a
    $MindsetAdmin = $false
    [ordered]@{ nom = $c.nom; appli = $c.appli; run = @($c.run); fichiers = @($c.fichiers); installations = $c.installations; admin = [bool]$c.admin; taches = @($c.taches); resultat = $v }
}
Remove-Item function:Get-ItemProperty -ErrorAction SilentlyContinue
Save-Juge 'demarrage' $sorties

# ---------------------------------------------------------------------------------------------------------------
# paquets.json : Get-DossierZip, Test-PaquetAppli (zips faits ici)
# ---------------------------------------------------------------------------------------------------------------
function New-Zip($Entrees) {
    $ms = New-Object IO.MemoryStream
    $z = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($e in @($Entrees)) {
        if (-not $e) { continue }
        $x = $z.CreateEntry([string]$e.nom)
        if ($null -ne $e.texte) { $f = $x.Open(); $o = [Text.Encoding]::UTF8.GetBytes([string]$e.texte); $f.Write($o, 0, $o.Length); $f.Dispose() }
    }
    $z.Dispose()
    , $ms.ToArray()
}
$casPaq = @(
    @{ nom = 'dossier d aujourd hui'; noms = @('Nevermind', 'OptiGame'); exe = 'Nevermind.exe'; entrees = @(@{ nom = 'Nevermind/Nevermind.exe'; texte = 'x' }) }
    @{ nom = 'ancien dossier'; noms = @('Nevermind', 'OptiGame'); exe = 'Nevermind.exe'; entrees = @(@{ nom = 'OptiGame/Nevermind.exe'; texte = 'x' }) }
    @{ nom = 'aucun'; noms = @('Nevermind', 'OptiGame'); exe = 'Nevermind.exe'; entrees = @(@{ nom = 'Autre/Nevermind.exe'; texte = 'x' }) }
    @{ nom = 'majuscules'; noms = @('Nevermind', ''); exe = 'Nevermind.exe'; entrees = @(@{ nom = 'nevermind/NEVERMIND.exe'; texte = 'x' }) }
    @{ nom = 'barres de windows'; noms = @('', 'Evermind'); exe = 'Evermind.exe'; entrees = @(@{ nom = 'Evermind\Evermind.exe'; texte = 'x' }) }
    @{ nom = 'zip illisible'; noms = @('Evermind'); exe = 'Evermind.exe'; brut = 'pas un zip' }
    @{ nom = 'version.json bon'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Mindcare/Mindcare.exe'; texte = 'x' }, @{ nom = 'Mindcare/version.json'; texte = '{"version":"1.0.0","appli":"mindcare","mindset_min":"2.18.0"}' }) }
    @{ nom = 'version.json autre appli'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Mindcare/Mindcare.exe'; texte = 'x' }, @{ nom = 'Mindcare/version.json'; texte = '{"version":"1.0.0","appli":"evermind"}' }) }
    @{ nom = 'version.json mindset trop ancien'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Mindcare/Mindcare.exe'; texte = 'x' }, @{ nom = 'Mindcare/version.json'; texte = '{"version":"1.0.0","appli":"mindcare","mindset_min":"3.1.0"}' }) }
    @{ nom = 'version.json illisible'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Mindcare/Mindcare.exe'; texte = 'x' }, @{ nom = 'Mindcare/version.json'; texte = '{"version":' }) }
    @{ nom = 'version.json a la racine'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Mindcare/Mindcare.exe'; texte = 'x' }, @{ nom = 'version.json'; texte = '{"version":"1.0.0","appli":"autre"}' }) }
    @{ nom = 'deux version.json differents'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Mindcare/version.json'; texte = '{"version":"1.0.0"}' }, @{ nom = 'version.json'; texte = '{"version":"1.0.1"}' }) }
    @{ nom = 'deux version.json pareils'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Mindcare/version.json'; texte = '{"version":"1.0.0","appli":"autre"}' }, @{ nom = 'version.json'; texte = '{"version":"1.0.0","appli":"autre"}' }) }
    @{ nom = 'Version.json en majuscule a la racine'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Version.json'; texte = '{"version":"1.0.0","appli":"autre"}' }) }
    @{ nom = 'sans appli attendue'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = ''; mindset = ''; entrees = @(@{ nom = 'Mindcare/version.json'; texte = '{"version":"1.0.0","appli":"autre","mindset_min":"9.0.0"}' }) }
    @{ nom = 'appli en majuscules'; noms = @('Mindcare'); exe = 'Mindcare.exe'; appli = 'mindcare'; mindset = '3.0.0'; entrees = @(@{ nom = 'Mindcare/version.json'; texte = '{"version":"1.0.0","appli":"MINDCARE","mindset_min":"3.0.0"}' }) }
)
$sorties = foreach ($c in $casPaq) {
    $zip = if ($c.brut) { [Text.Encoding]::UTF8.GetBytes($c.brut) } else { New-Zip $c.entrees }
    $dz = Get-DossierZip $zip $c.noms $c.exe
    $err = $null; try { Test-PaquetAppli $zip $dz ([string]$c.appli) ([string]$c.mindset) } catch { $err = $_.Exception.Message }
    [ordered]@{ nom = $c.nom; noms = @($c.noms); exe = $c.exe; appli = [string]$c.appli; mindset = [string]$c.mindset; zip = [Convert]::ToBase64String($zip); dossier_zip = $dz; erreur = $err }
}
Save-Juge 'paquets' $sorties

# ---------------------------------------------------------------------------------------------------------------
# copie.json : Remove-AncienneCopie
# ---------------------------------------------------------------------------------------------------------------
$pfAvant = $env:ProgramFiles
$livreEver = @(@{ nom = 'Evermind/Evermind.exe'; texte = 'x' }, @{ nom = 'Evermind/fichiers/Evermind.ps1'; texte = 'y' }, @{ nom = 'Evermind/fichiers/modules/a.ps1'; texte = 'z' }, @{ nom = 'Evermind/fichiers/'; texte = $null }, @{ nom = 'LISEZMOI.txt'; texte = 'r' })
$arbreEver = @(@{ chemin = 'Evermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\Evermind.ps1'; texte = 'y' }, @{ chemin = 'fichiers\modules\a.ps1'; texte = 'z' })
$casCopie = @(
    @{ nom = 'tout livre'; appli = $evermind; arbre = $arbreEver; entrees = $livreEver }
    @{ nom = 'un fichier en plus'; appli = $evermind; arbre = $arbreEver + @(@{ chemin = 'notes.txt'; texte = 'n' }); entrees = $livreEver }
    @{ nom = 'deux fichiers en plus'; appli = $evermind; arbre = $arbreEver + @(@{ chemin = 'notes.txt'; texte = 'n' }, @{ chemin = 'fichiers\perso\b.txt'; texte = 'b' }); entrees = $livreEver }
    @{ nom = 'dossier vide en plus'; appli = $evermind; arbre = $arbreEver + @(@{ chemin = 'vide\sous'; dossier = $true }); entrees = $livreEver }
    @{ nom = 'dossier de travail'; appli = $evermind; arbre = $arbreEver + @(@{ chemin = '.git\HEAD'; texte = 'ref' }); entrees = $livreEver }
    @{ nom = 'dossier de travail parent'; appli = $evermind; sous = 'Depot\Evermind'; arbre = $arbreEver; parent = @(@{ chemin = '.git'; dossier = $true }); entrees = $livreEver }
    @{ nom = 'dans les programmes'; appli = $evermind; sous = 'Programmes\Vieux'; arbre = $arbreEver; entrees = $livreEver }
    @{ nom = 'dans program files mindset'; appli = $evermind; sous = 'pc\ProgramFiles\Mindset\Evermind'; arbre = $arbreEver; entrees = $livreEver }
    @{ nom = 'dans program files'; appli = $evermind; sous = 'pc\ProgramFiles\Evermind'; arbre = $arbreEver; entrees = $livreEver }
    @{ nom = 'zip illisible'; appli = $evermind; arbre = $arbreEver; brut = 'pas un zip' }
    @{ nom = 'autre dossier du zip'; appli = $evermind; arbre = $arbreEver; entrees = $livreEver; dossier_zip = 'Autre' }
    @{ nom = 'dossier du zip par defaut'; appli = $evermind; arbre = $arbreEver; entrees = $livreEver; dossier_zip = '' }
    @{ nom = 'ancien script'; appli = $nevermind; arbre = @(@{ chemin = 'Nevermind.exe'; texte = 'x' }, @{ chemin = 'fichiers\OptiGame.ps1'; texte = 'o' }); entrees = @(@{ nom = 'Nevermind/Nevermind.exe'; texte = 'x' }) }
    @{ nom = 'zip qui sort du dossier'; appli = $evermind; arbre = $arbreEver; dehors = @(@{ chemin = 'Garde.txt'; texte = 'g' }); entrees = $livreEver + @(@{ nom = 'Evermind/../Garde.txt'; texte = 'g' }) }
    @{ nom = 'dossier avec accents'; appli = $evermind; sous = 'Forêt\Café crème'; arbre = $arbreEver; entrees = $livreEver }
    @{ nom = 'fichier livre absent'; appli = $evermind; arbre = @(@{ chemin = 'Evermind.exe'; texte = 'x' }); entrees = $livreEver }
    @{ nom = 'fichier cache en plus'; appli = $evermind; arbre = $arbreEver + @(@{ chemin = 'desktop.ini'; texte = 'c'; cache = $true }); entrees = $livreEver }
    @{ nom = 'barre finale'; appli = $evermind; arbre = $arbreEver; entrees = $livreEver; barre = $true }
)
$sorties = foreach ($c in $casCopie) {
    $r = New-Racine
    $env:ProgramFiles = Join-Path $r 'pc\ProgramFiles'
    $sous = if ($c.sous) { $c.sous } else { 'Ancienne\Evermind' }
    $d = Join-Path $r $sous
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    New-Fichiers $d $c.arbre
    if ($c.parent) { New-Fichiers (Split-Path $d) $c.parent }
    if ($c.dehors) { New-Fichiers (Split-Path $d) $c.dehors }
    foreach ($f in @($c.arbre)) { if ($f.cache) { $x = Get-Item -LiteralPath (Join-Path $d $f.chemin) -Force; $x.Attributes = $x.Attributes -bor [IO.FileAttributes]::Hidden } }
    $zipOctets = if ($c.brut) { [Text.Encoding]::UTF8.GetBytes($c.brut) } else { New-Zip $c.entrees }
    $zip = Join-Path $r 'appli.zip'; [IO.File]::WriteAllBytes($zip, $zipOctets)
    $dz = if ($c.ContainsKey('dossier_zip')) { $c.dossier_zip } else { 'Evermind' }
    $a = New-Appli $c.appli
    $arg = if ($c.barre) { "$d\" } else { $d }
    $m = Remove-AncienneCopie $a $arg $zip $dz
    $env:ProgramFiles = $pfAvant
    [ordered]@{ nom = $c.nom; appli = $c.appli; sous = $sous; arbre = @($c.arbre); parent = @($c.parent); dehors = @($c.dehors); zip = [Convert]::ToBase64String($zipOctets); dossier_zip = $dz; barre = [bool]$c.barre
        message = (Hide-R ([string]$m)); existe = (Test-Path -LiteralPath $d); restants = @(Get-Arbre $d); dehors_restants = @(Get-Arbre (Split-Path $d) | Where-Object { $_ -notlike "$(Split-Path $d -Leaf)\*" -and $_ -ne "$(Split-Path $d -Leaf)\" }) }
}
$env:ProgramFiles = $pfAvant
Save-Juge 'copie' $sorties

# ---------------------------------------------------------------------------------------------------------------
# desinstallation.json : Complete-Desinstallation (la part des données)
# ---------------------------------------------------------------------------------------------------------------
function Stop-Operation($Appli, [string]$Message) { $script:Fin = $Message }
function Remove-RaccourciAppli($Appli) { }
$casDes = @(
    @{ nom = 'donnees gardees'; appli = $evermind; suite = @(@{ chemin = 'Evermind\reglages.json'; texte = '{}' }) }
    @{ nom = 'donnees supprimees'; appli = $evermind; suite = @() }
    @{ nom = 'dossier vide'; appli = $evermind; suite = @(@{ chemin = 'Evermind'; dossier = $true }) }
    @{ nom = 'sous-dossier vide seul'; appli = $evermind; suite = @(@{ chemin = 'Evermind\vide'; dossier = $true }) }
    @{ nom = 'profil webview2'; appli = $nevermind; suite = @(@{ chemin = 'WebView2\EBWebView\WV2Profile_nevermind\Cookies'; texte = 'c' }, @{ chemin = 'WebView2\EBWebView\WV2Profile_mindset\Cookies'; texte = 'c' }) }
    @{ nom = 'profil webview2 donnees gardees'; appli = $nevermind; suite = @(@{ chemin = 'Nevermind\a.txt'; texte = 'a' }, @{ chemin = 'WebView2\EBWebView\WV2Profile_nevermind\Cookies'; texte = 'c' }) }
    @{ nom = 'webview2-tauri seul'; appli = $mindcare; suite = @(@{ chemin = 'WebView2-Tauri\Mindcare\EBWebView\x'; texte = 'x' }) }
    @{ nom = 'webview2-tauri avec un autre'; appli = $mindcare; suite = @(@{ chemin = 'WebView2-Tauri\Mindcare\EBWebView\x'; texte = 'x' }, @{ chemin = 'WebView2-Tauri\Mindset\y'; texte = 'y' }) }
    @{ nom = 'webview2-tauri en lecture seule'; appli = $mindcare; suite = @(@{ chemin = 'WebView2-Tauri\Mindcare\lecture.txt'; texte = 'x'; lecture = $true }) }
    @{ nom = 'webview2-tauri gardees'; appli = $mindcare; suite = @(@{ chemin = 'Mindcare\journal.txt'; texte = 'j' }, @{ chemin = 'WebView2-Tauri\Mindcare\x'; texte = 'x' }) }
    @{ nom = 'webview2-tauri vide'; appli = $mindcare; suite = @(@{ chemin = 'WebView2-Tauri'; dossier = $true }) }
    @{ nom = 'nom refuse pour tauri'; appli = $cafe; nom_force = 'Café'; suite = @(@{ chemin = 'WebView2-Tauri\Café\x'; texte = 'x' }) }
)
$sorties = foreach ($c in $casDes) {
    $r = New-Racine
    New-Item -ItemType Directory -Force -Path $SuiteDir | Out-Null
    New-Fichiers $SuiteDir $c.suite
    foreach ($f in @($c.suite)) { if ($f.lecture) { $x = Get-Item -LiteralPath (Join-Path $SuiteDir $f.chemin); $x.IsReadOnly = $true } }
    $script:Fin = $null
    $a = New-Appli $c.appli
    if ($c.nom_force) { $a.Nom = $c.nom_force }
    Complete-Desinstallation $a
    [ordered]@{ nom = $c.nom; appli = $c.appli; nom_force = $c.nom_force; suite = @($c.suite); message = (Hide-R $script:Fin); journal = @($script:Journal | ForEach-Object { Hide-R $_ } | Where-Object { $_ -notlike 'installations.json*' }); restants = @(Get-Arbre $SuiteDir | Where-Object { $_ -notlike 'Mindset\*' -and $_ -ne 'Mindset\' }) }
}
Remove-Item function:Stop-Operation, function:Remove-RaccourciAppli -ErrorAction SilentlyContinue
Save-Juge 'desinstallation' $sorties

# ---------------------------------------------------------------------------------------------------------------
# admin.json : la file du mini-installateur
# ---------------------------------------------------------------------------------------------------------------
$r = New-Racine
$moi = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$AppDir = Join-Path $r 'Programmes\Mindset\fichiers'
$DossierMindset = Join-Path $r 'Programmes\Mindset'
$TacheInstallation = '\Mindset\Mindset (installation)'
$FichierDemande = Join-Path $DataDir 'installation.demande'
$CleInstallationAdmin = 'HKLM:\SOFTWARE\Mindset\Installation'
$DelaiAccuseTache = 30
$PowerShellWindows = 'powershell-de-test.exe'
$script:Maintenant = [datetime]'2026-11-07 20:00:00'
function Get-Date { $script:Maintenant }
function Get-XmlTache([string]$Compte, [string]$Arguments) {
    "<?xml version=""1.0"" encoding=""UTF-16""?>`n<Task xmlns=""http://schemas.microsoft.com/windows/2004/02/mit/task""><Principals><Principal id=""Author""><UserId>$Compte</UserId></Principal></Principals><Actions Context=""Author""><Exec><Command>x.exe</Command><Arguments>$([Security.SecurityElement]::Escape($Arguments))</Arguments></Exec></Actions></Task>"
}
function Invoke-FauxSchtasks {
    $a = "$args"
    if ($a -like '/Query*') {
        $xml = switch ($script:EtatTache) {
            'systeme' { Get-XmlTache 'S-1-5-18' "-Action demande -Sid $moi -Demande `"x`"" }
            'ancienne' { Get-XmlTache $moi '-Action demande -Demande "x"' }
            default { $null }
        }
        if ($xml) { $global:LASTEXITCODE = 0; return ($xml -split "`n") }
        $global:LASTEXITCODE = 1; return
    }
    if ($a -like '/Run*') {
        $c = [IO.File]::ReadAllText($FichierDemande) | ConvertFrom-Json
        $script:Taches.Add([string]$c.Action); $script:Ids.Add([string]$c.Id)
        $global:LASTEXITCODE = if ($script:RunOk) { 0 } else { 1 }
        return
    }
    $global:LASTEXITCODE = 1
}
$SchtasksExe = 'Invoke-FauxSchtasks'
function Get-ItemProperty {
    [CmdletBinding()] param([string]$Path, [string]$Name)
    if ($Path -ne $CleInstallationAdmin -or -not $script:Registre.ContainsKey($Name)) { throw 'absent' }
    [pscustomobject]@{ $Name = $script:Registre[$Name] }
}
function Remove-DemandeInstallation { $script:Retraits++; try { [IO.File]::Delete($FichierDemande) } catch {} }
function Start-Process {
    [CmdletBinding()] param([string]$FilePath, $ArgumentList, [string]$Verb, [string]$WindowStyle, [string]$WorkingDirectory, [switch]$PassThru)
    if ($Verb -ne 'RunAs') { throw "lancement inattendu : $FilePath" }
    $l = @($ArgumentList)
    $action = ''; $rep = ''; $params = @()
    for ($i = 0; $i -lt $l.Count; $i++) {
        if ($l[$i] -ceq '-Action') { $action = [string]$l[$i + 1]; $i++; continue }
        if ($l[$i] -ceq '-Resultat') { $rep = ([string]$l[$i + 1]).Trim('"'); $i++; continue }
        if ($l[$i] -ceq '-File') { $i++; continue }
        if ([string]$l[$i] -match '^-[A-Z][A-Za-z]+$' -and $l[$i] -notin '-NoProfile', '-ExecutionPolicy', '-WindowStyle') { $params += , @(([string]$l[$i]).Substring(1), [string]$l[$i + 1]); $i++ }
    }
    $script:Runas.Add([ordered]@{ action = $action; parametres = @($params | Sort-Object { $_[0] } | ForEach-Object { , @($_[0], $_[1]) }) })
    $script:Reponses.Add($rep)
    if (-not $script:RunasOk) { throw 'refusée' }
    [pscustomobject]@{ HasExited = $true }
}
$script:AdminTimer = [pscustomobject]@{ Marche = $false }
$script:AdminTimer | Add-Member ScriptMethod Start { $this.Marche = $true }
$script:AdminTimer | Add-Member ScriptMethod Stop { $this.Marche = $false }
function Get-NomsVariablesCompte { @($script:Compte) }

function P([string]$Cle, [string]$Valeur) { , @($Cle, $Valeur) }
$pAppli = @((P 'Appli' 'evermind'), (P 'Zip' "$r\Donnees\Mindset\telechargements\evermind.zip"), (P 'Destination' "$r\Programmes\Evermind"), (P 'Exe' 'Evermind.exe'))
$pVide = @((P 'Destination' "$r\Programmes\Evermind"), (P 'Exe' ''), (P 'Version' $null))
$casAdmin = @(
    @{ nom = 'par la tache, tout va bien'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ tic = $true }, @{ recu = 0 }, @{ tic = $true }, @{ resultat = @{ de = 0; ok = $true; message = "$r\Programmes\Evermind" } }, @{ tic = $true }, @{ tic = $true }) }
    @{ nom = 'tache absente : demande de Windows'; debut = @{ tache = 'absente' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'supprimer'; parametres = $pVide } }, @{ reponse_directe = @{ de = 0; ok = $true; message = 'fait' } }, @{ tic = $true }) }
    @{ nom = 'ancienne tache : jamais pour installer'; debut = @{ tache = 'ancienne' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ tic = $true }) }
    @{ nom = 'mindset administrateur : demande directe'; debut = @{ tache = 'systeme'; admin = $true }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ reponse_directe = @{ de = 0; ok = $false; message = 'refusé par le test' } }, @{ tic = $true }) }
    @{ nom = 'action mindset : toujours directe'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'mindset'; parametres = @((P 'Source' "$r\Telechargements\Mindset"), (P 'Version' '3.0.0'), (P 'Disque' 'D')) } }, @{ tic = $true }) }
    @{ nom = 'pas d accuse en 30 s : repli'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ avancer = 29 }, @{ tic = $true }, @{ avancer = 1 }, @{ tic = $true }, @{ reponse_directe = @{ de = 0; ok = $true; message = 'fait par Windows' } }, @{ tic = $true }) }
    @{ nom = 'pas d accuse, mise a jour automatique : abandon'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli; auto = $true } }, @{ avancer = 31 }, @{ tic = $true }) }
    @{ nom = 'accuse juste avant le retrait'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ avancer = 31 }, @{ recu_tardif = 0 }, @{ tic = $true }, @{ resultat = @{ de = 0; ok = $true; message = 'ok' } }, @{ tic = $true }) }
    @{ nom = 'lente mais accusee : pas doublee'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ recu = 0 }, @{ tic = $true }, @{ avancer = 300 }, @{ tic = $true }, @{ avancer = 299 }, @{ tic = $true }, @{ avancer = 2 }, @{ tic = $true }) }
    @{ nom = 'reponse d une autre demande ignoree'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ recu = 0 }, @{ resultat_autre = $true }, @{ tic = $true }, @{ resultat = @{ de = 0; ok = $false; message = 'Version refusée' } }, @{ tic = $true }) }
    @{ nom = 'deux demandes : une a la fois'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ admin = @{ nom = 'B'; action = 'supprimer'; parametres = $pVide } }, @{ recu = 0 }, @{ resultat = @{ de = 0; ok = $true; message = 'un' } }, @{ tic = $true }, @{ recu = 1 }, @{ resultat = @{ de = 1; ok = $true; message = 'deux' } }, @{ tic = $true }) }
    @{ nom = 'la tache ne demarre pas'; debut = @{ tache = 'systeme'; run_ok = $false }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ reponse_directe = @{ de = 0; ok = $true; message = 'direct' } }, @{ tic = $true }, @{ admin = @{ nom = 'B'; action = 'appli'; parametres = $pAppli } }, @{ tic = $true }) }
    @{ nom = 'la tache ne demarre pas, auto'; debut = @{ tache = 'systeme'; run_ok = $false }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli; auto = $true } }, @{ tic = $true }) }
    @{ nom = 'deuxieme en attente quand la premiere echoue'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ admin = @{ nom = 'B'; action = 'supprimer'; parametres = $pVide; auto = $true } }, @{ admin = @{ nom = 'C'; action = 'supprimer'; parametres = $pVide } }, @{ avancer = 30 }, @{ tic = $true }, @{ tic = $true }) }
    @{ nom = 'demande de Windows refusee'; debut = @{ tache = 'absente'; runas = $false }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ tic = $true }) }
    @{ nom = 'demande de Windows sans reponse'; debut = @{ tache = 'absente' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ tic = $true }) }
    @{ nom = 'variables dangereuses'; debut = @{ tache = 'absente'; compte = @('COR_PROFILER') }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ tic = $true }) }
    @{ nom = 'guillemet dans une valeur'; debut = @{ tache = 'absente' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'supprimer'; parametres = @((P 'Destination' 'C:\a"b'), (P 'Exe' 'Evermind.exe')) } }, @{ tic = $true }) }
    @{ nom = 'valeurs avec apostrophe et dollar'; debut = @{ tache = 'absente' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'supprimer'; parametres = @((P 'Destination' "C:\d$([char]0x2019)Arthur\`$x"), (P 'Exe' 'E:\')) } }, @{ reponse_directe = @{ de = 0; ok = $true; message = 'ok' } }, @{ tic = $true }) }
    @{ nom = 'reponse ok en texte'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ recu = 0 }, @{ resultat_brut = @{ de = 0; json = '{"id":"<ID>","ok":"false","message":5}' } }, @{ tic = $true }) }
    @{ nom = 'reponse abimee'; debut = @{ tache = 'systeme' }; etapes = @(
        @{ admin = @{ nom = 'A'; action = 'appli'; parametres = $pAppli } }, @{ recu = 0 }, @{ resultat_brut = @{ de = 0; json = '{"id":"<ID>",' } }, @{ tic = $true }, @{ avancer = 601 }, @{ tic = $true }) }
)
$sorties = foreach ($c in $casAdmin) {
    $script:Maintenant = [datetime]'2026-11-07 20:00:00'
    $script:EtatTache = [string]$c.debut.tache; $script:RunOk = $(if ($c.debut.ContainsKey('run_ok')) { [bool]$c.debut.run_ok } else { $true })
    $script:RunasOk = $(if ($c.debut.ContainsKey('runas')) { [bool]$c.debut.runas } else { $true })
    $script:Compte = @($c.debut.compte); $MindsetAdmin = [bool]$c.debut.admin
    $script:TacheInstallationOk = $null; $script:EtatTacheInstallation = $null
    $script:AttentesAdmin = New-Object System.Collections.ArrayList; $script:DemandesEnAttente = New-Object System.Collections.ArrayList
    $script:Registre = @{}; $script:Ids = New-Object Collections.Generic.List[string]; $script:Reponses = New-Object Collections.Generic.List[string]
    $etapes = foreach ($e in $c.etapes) {
        $script:Journal.Clear(); $script:Taches = New-Object Collections.Generic.List[string]; $script:Runas = New-Object Collections.Generic.List[object]; $script:Retraits = 0
        $global:FinsJuge = New-Object Collections.Generic.List[object]
        if ($e.admin) {
            $nom = $e.admin.nom
            $params = @{}; foreach ($p in $e.admin.parametres) { $params[$p[0]] = $p[1] }
            $fin = { param($Ok, $Message) $global:FinsJuge.Add(@($nom, [bool]$Ok, [string]$Message)) }.GetNewClosure()
            Invoke-Admin $e.admin.action $params $fin -Auto:([bool]$e.admin.auto)
        }
        if ($e.ContainsKey('avancer')) { $script:Maintenant = $script:Maintenant.AddSeconds($e.avancer) }
        if ($e.ContainsKey('recu')) { $script:Registre['Recu'] = $script:Ids[$e.recu] }
        if ($e.ContainsKey('recu_tardif')) {
            # (posé pendant le retrait de la demande : la tâche l'a prise juste avant)
            $script:RecuTardif = $script:Ids[$e.recu_tardif]
            function Remove-DemandeInstallation { $script:Retraits++; if ($script:RecuTardif) { $script:Registre['Recu'] = $script:RecuTardif; $script:RecuTardif = $null } }
        }
        if ($e.resultat) { $script:Registre['Resultat'] = (ConvertTo-Json -Compress -InputObject ([ordered]@{ id = $script:Ids[$e.resultat.de]; ok = $e.resultat.ok; message = $e.resultat.message })) }
        if ($e.resultat_brut) { $script:Registre['Resultat'] = $e.resultat_brut.json.Replace('<ID>', $script:Ids[$e.resultat_brut.de]) }
        if ($e.resultat_autre) { $script:Registre['Resultat'] = '{"id":"00000000000000000000000000000000","ok":true,"message":"autre"}' }
        if ($e.reponse_directe) { [IO.File]::WriteAllText($script:Reponses[$e.reponse_directe.de], (ConvertTo-Json -Compress -InputObject ([ordered]@{ ok = $e.reponse_directe.ok; message = $e.reponse_directe.message })), [Text.Encoding]::UTF8) }
        if ($e.tic) { Update-AttentesAdmin }
        [ordered]@{ taches = @($script:Taches); retraits = $script:Retraits; runas = @($script:Runas | ForEach-Object { [ordered]@{ action = $_.action; parametres = @($_.parametres | ForEach-Object { , @($_[0], (Hide-R $_[1])) }) } })
            fins = @($global:FinsJuge | ForEach-Object { , @($_[0], $_[1], (Hide-R $_[2])) }); journal = @($script:Journal | ForEach-Object { Hide-R $_ }) }
    }
    function Remove-DemandeInstallation { $script:Retraits++; try { [IO.File]::Delete($FichierDemande) } catch {} }
    $c2 = @{ nom = $c.nom; debut = $c.debut; etapes = @() }
    $c2.etapes = @(foreach ($e in $c.etapes) {
        $x = [ordered]@{}
        foreach ($k in $e.Keys) {
            if ($k -eq 'admin') { $x.admin = [ordered]@{ nom = $e.admin.nom; action = $e.admin.action; auto = [bool]$e.admin.auto; parametres = @($e.admin.parametres | ForEach-Object { , @($_[0], (Hide-R $_[1])) }) } }
            elseif ($k -eq 'resultat') { $x.resultat = [ordered]@{ de = $e.resultat.de; ok = $e.resultat.ok; message = (Hide-R $e.resultat.message) } }
            else { $x[$k] = $e[$k] }
        }
        $x
    })
    [ordered]@{ nom = $c.nom; debut = $c.debut; etapes = $c2.etapes; sorties = @($etapes); tache_ok = $script:TacheInstallationOk }
}
Remove-Item function:Get-Date, function:Get-ItemProperty, function:Start-Process -ErrorAction SilentlyContinue
Save-Juge 'admin' $sorties

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Fini.'
