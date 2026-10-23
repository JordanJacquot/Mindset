# Mindset : tests du démarrage des applis, des mises à jour (Mindset et ses applis) et du filet contre les plantages.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-mises-a-jour.ps1
#   (-Fichiers <dossier> : tester une autre copie de Mindset\fichiers, par exemple l'ancienne version, pour la contre-épreuve)
#
# On vérifie, dans un faux PC sous %TEMP% (faux réglages en mémoire, faux zips, faux programmes compilés à la volée) :
#   1. une appli prise en charge qui se lançait avec Windows (entrée « Run », réglage DemarrageWindows d'Evermind, tâche
#      de Nevermind) s'ouvre avec Mindset ; une appli de rappels l'est d'office à l'installation ; une réparation, une
#      seule fois, pour celles déjà prises en charge ; une mise à jour ne touche pas au choix de l'utilisateur ;
#   2. une version de Mindset déjà prête n'empêche pas d'en trouver une plus récente : son zip est remplacé ;
#   3. une appli ouverte est priée de quitter (quitter.demande) et attendue avant l'installation ; si elle ne répond
#      pas, l'installation part quand même après le délai (l'installateur la ferme alors) ;
#   4. un jeu est vu même en fenêtre (dossiers de jeux, jeux ajoutés dans Nevermind), sur un autre écran, ou à la
#      manette ; une mise à jour automatique ne rouvre pas une appli que l'utilisateur avait fermée ;
#   5. une erreur imprévue dans une minuterie ne ferme plus Mindset (vrai Mindset de test, fenêtre hors de l'écran) :
#      notée au journal 3 fois au plus, un seul message.
# Rien sur le vrai PC : ni ses réglages, ni ses applis, ni leurs processus (seuls les programmes d'essai lancés ici
# sont fermés), ni le registre. Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).
param([string]$Fichiers)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = if ($Fichiers) { (Resolve-Path -LiteralPath $Fichiers).Path } else { Join-Path $racine 'Mindset\fichiers' }

$script:Reussis = 0
$script:Echoues = @()
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
    }
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

$tmp = Join-Path $env:TEMP "mindset-maj-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName   # (en nom long : sur GitHub, TEMP est en nom court)
$script:Lances = @()
$ancienDonnees = $env:MINDSET_DONNEES

# Les fonctions de Mindset sont prises dans ses fichiers (par l'analyseur : les modules exécutent du code au chargement).
# Une fonction absente (ancienne version) n'est pas définie : les cas qui en ont besoin échouent.
$asts = @{}
foreach ($m in @(Get-ChildItem -LiteralPath (Join-Path $fichiers 'modules') -Filter '*.ps1' -File)) {
    $e = $null
    $asts[$m.Name] = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($m.FullName, [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
    if ($e) { throw "$($m.Name) illisible : $($e[0].Message)" }
}
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    foreach ($x in @($asts[$Fichier].FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Noms }, $true))) {
        . ([scriptblock]::Create($x.Extent.Text))
        Set-Item -Path "function:script:$($x.Name)" -Value (Get-Item "function:$($x.Name)").ScriptBlock
    }
}
# Les lignes de premier niveau d'un module qui parlent de ces noms (variables, minuteries), à exécuter ici (par « . »)
function Get-Lignes([string]$Fichier, [string]$Motif) {
    $l = foreach ($s in @($asts[$Fichier].EndBlock.Statements)) {
        if ($s -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $s.Extent.Text -match $Motif) { $s.Extent.Text }
    }
    [scriptblock]::Create((@($l) -join "`r`n"))
}
function Test-Fonction([string]$Nom) { [bool](Get-Command $Nom -CommandType Function -ErrorAction SilentlyContinue) }

# Fait tourner la fenêtre (minuteries) jusqu'à ce que la condition soit vraie, ou $Secondes au plus
function Wait-Condition([scriptblock]$Condition, [double]$Secondes) {
    $limite = (Get-Date).AddSeconds($Secondes)
    while (-not (& $Condition) -and (Get-Date) -lt $limite) {
        $script:Cadre = New-Object System.Windows.Threading.DispatcherFrame
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(100)
        $t.Add_Tick({ $this.Stop(); $script:Cadre.Continue = $false })
        $t.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($script:Cadre)
    }
    [bool](& $Condition)
}

try {
    Write-Partie 'Préparation'
    Add-Type -AssemblyName PresentationFramework, WindowsBase
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $fichiers 'modules\natif.cs'), [Text.Encoding]::UTF8))
    # Le programme d'essai. « appli <mutex> <dossier> [sourde] » : une appli qui garde son mutex et quitte quand
    # quitter.demande apparaît dans son dossier de données (sauf « sourde ») ; sans argument : un jeu qui attend.
    $essai = Join-Path $tmp 'essai.exe'
    Add-Type -OutputType WindowsApplication -OutputAssembly $essai -TypeDefinition @'
using System; using System.IO; using System.Threading;
static class Essai {
    static void Main(string[] a) {
        if (a.Length >= 3 && a[0] == "appli") {
            bool cree; var m = new Mutex(true, a[1], out cree);
            string f = Path.Combine(a[2], "quitter.demande");
            for (int i = 0; i < 1200; i++) {
                if (a.Length < 4 && File.Exists(f)) { try { File.Delete(f); } catch { } Thread.Sleep(300); m.ReleaseMutex(); return; }
                Thread.Sleep(100);
            }
            return;
        }
        Thread.Sleep(600000);
    }
}
'@
    Test-Cas 'Le programme d''essai se compile' { Test-Path -LiteralPath $essai }
    function Start-Essai([string]$Chemin, [string[]]$Arguments) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Chemin -Parent) | Out-Null
        if (-not (Test-Path -LiteralPath $Chemin)) { Copy-Item -LiteralPath $essai -Destination $Chemin }
        $p = if ($Arguments) { Start-Process -FilePath $Chemin -ArgumentList $Arguments -PassThru } else { Start-Process -FilePath $Chemin -PassThru }
        $script:Lances += $p
        $p
    }

    # Le faux PC : programmes, données de la suite, anciennes données, téléchargements
    $prog = Join-Path $tmp 'Programmes'
    $donnees = Join-Path $tmp 'Donnees'
    $TelechargementsDir = Join-Path $donnees 'Mindset\telechargements'
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    $MonDossier = Join-Path $prog 'Mindset'
    $SuiteDir = $donnees
    $ClePublique = Join-Path $tmp 'cles'
    $EnTest = $true
    $env:MINDSET_DONNEES = $tmp   # (Write-DemandeQuitter n'écrit qu'ici en test)
    $MindsetAdmin = $false
    $AppVersion = '2.2.0'

    # Les applis comme Mindset les lit dans apps.json, avec un mutex et des anciennes données de test (jamais ceux des vraies)
    function Write-Log([string]$Texte) { $script:Journal.Add($Texte) }
    $script:Journal = New-Object Collections.Generic.List[string]
    $AppDir = $fichiers
    . (Join-Path $fichiers 'modules\applis.ps1')
    foreach ($a in $Applis) { $a.Mutex = "Local\MindsetTest-$([guid]::NewGuid().ToString('N'))"; $a.Donnees = Join-Path $tmp "ancien\$($a.Nom)" }
    $evermind = $Applis | Where-Object Id -eq 'evermind'
    $nevermind = $Applis | Where-Object Id -eq 'nevermind'
    $mindcare = $Applis | Where-Object Id -eq 'mindcare'
    function Get-Appli([string]$Id) { $Applis | Where-Object Id -eq $Id | Select-Object -First 1 }

    # Faux : réglages en mémoire, installations, entrées « Run », tâches, fenêtre
    $script:Reglages = @{}
    function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.ContainsKey($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
    function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur }
    $script:Installs = @{}
    function Get-Installation($Appli) { $script:Installs[$Appli.Id] }
    function Save-Installation([string]$Id, [string]$Dossier, [bool]$Gere) { if ($Dossier) { $script:Installs[$Id] = @{ Dossier = $Dossier; Gere = $Gere; Version = '9.0.0' } } else { $script:Installs.Remove($Id) } }
    function Get-DossierDonnees($Appli) { Join-Path $donnees $Appli.Nom }
    $script:Run = @{}
    function Get-DemarragesAppli($Appli) { @($script:Run[$Appli.Id] | Where-Object { $_ }) }
    $script:TachesFaux = @{}
    $script:TachesRetirees = New-Object Collections.Generic.List[string]
    function Remove-TachesDemarrageAppli([string]$Id) { $script:TachesRetirees.Add($Id); $script:TachesFaux.Remove($Id) }
    function Set-SuiteAppli { }
    function Update-RaccourciAppli { }
    function Remove-Doublons { '' }
    function Remove-AncienneCopie { '' }
    function Update-Cartes { }
    function Update-Trouvees { }
    function Update-ListeVersions { }
    function Test-TacheInstallation { $true }
    $script:Fins = @{}
    function Move-DonneesAppli($Appli, [string]$Message) { Stop-Operation $Appli $Message }
    function Stop-Operation($Appli, [string]$Message) { $script:Occupe.Remove($Appli.Id); $script:Fins[$Appli.Id] = @{ Message = $Message; Relancer = [bool]$script:ARelancer[$Appli.Id] }; $script:ARelancer.Remove($Appli.Id) }
    $script:AppelsAdmin = New-Object Collections.ArrayList
    $script:AdminRepond = $true
    function Invoke-Admin([string]$Action, [hashtable]$Parametres, [scriptblock]$Fin) {
        $a = $Applis | Where-Object { $Parametres.Destination -and $Parametres.Destination -like "*\$($_.Nom)" } | Select-Object -First 1
        [void]$script:AppelsAdmin.Add(@{ Action = $Action; Quand = Get-Date; Ouverte = [bool]($a -and (Test-AppliOuverte $a)) })
        if ($script:AdminRepond) { & $Fin $true ([string]$Parametres.Destination) }
    }
    # Travaux de fond : faits tout de suite, ici (le réseau est faux : Get-Publication, Get-Octets, Test-Signature)
    function Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) {
        $r = $null; $err = $null
        try { $r = & $Travail $Parametres } catch { $err = $_.Exception.Message }
        & $Fin $r $err
    }
    $script:Pubs = @{}
    $script:Telecharges = New-Object Collections.Generic.List[string]
    function Get-Publication([string]$Depot, [string]$Zip) { $v = $script:Pubs[$Depot]; @{ Version = $v; UrlZip = "zip $Depot $v"; UrlSig = "sig $Depot $v"; Notes = '' } }
    function Get-Octets([string]$Url, $Progres = $null) { $script:Telecharges.Add($Url); [Text.Encoding]::UTF8.GetBytes($Url) }
    function Test-Signature { $true }
    . ([scriptblock]::Create(($asts['paquets.ps1'].FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-VersionPlusRecente' }, $true) | Select-Object -First 1).Extent.Text))
    $script:Interrupteurs = New-Object Collections.ArrayList
    $Window = [pscustomobject]@{ IsVisible = $false; WindowState = 'Normal' }
    $ui = @{}
    foreach ($n in 'MajTitre', 'MajTexte', 'BtnMajMindset', 'BtnMajFermer', 'MajBandeau') { $ui[$n] = [pscustomobject]@{ Text = ''; Content = ''; Visibility = 'Collapsed' } }

    Import-Fonctions 'installations.ps1' @('Start-InstallAppli', 'Complete-Telechargement', 'Send-InstallationAppli', 'Complete-Installation', 'Get-DemarrageAppli', 'Set-DemarrageAppli',
        'Get-DemarrageWindowsAppli', 'Repair-DemarrageApplis', 'Move-TachesDemarrage', 'Get-DossierGere')
    Import-Fonctions 'integration.ps1' @('Write-DemandeQuitter')
    Import-Fonctions 'mindset.ps1' @('Start-VerifMajMindset', 'Get-JeuxNevermind', 'Get-JeuEnCours')
    function Get-TachesDemarrageAppli([string]$Id) { @($script:TachesFaux[$Id] | Where-Object { $_ }) }   # (après l'import : jamais les vraies tâches)
    function Test-MindsetInstalle { $true }
    $RacineProgrammes = $prog
    . (Get-Lignes 'installations.ps1' 'DelaiFermetureAppli|AttentesFermeture|FermetureTimer|^\$TachesDemarrageAppli')
    . (Get-Lignes 'mindset.ps1' '^\$DossiersJeux|^\$DossiersPasJeux')
    $script:Occupe = @{}; $script:Messages = @{}; $script:EnCours = @{}; $script:Progres = @{}; $script:ARelancer = @{}; $script:MajAuto = @{}
    Test-Cas 'Les réglages de test ne sont jamais ceux du PC (Set-Setting est un faux, en mémoire)' { (Get-Command Set-Setting).ScriptBlock.ToString() -notmatch 'WriteAllText' }

    function Reset-Pc {
        $script:Reglages = @{}; $script:Installs = @{}; $script:Run = @{}; $script:TachesFaux = @{}; $script:TachesRetirees.Clear()
        $script:Fins = @{}; $script:AppelsAdmin.Clear(); $script:AdminRepond = $true; $script:Journal.Clear()
        $script:Occupe = @{}; $script:EnCours = @{}; $script:ARelancer = @{}; $script:MajAuto = @{}
        foreach ($d in $donnees, (Join-Path $tmp 'ancien')) { if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Exclude 'Mindset' | Remove-Item -Recurse -Force } }
        $script:Pubs = @{ 'JordanJacquot/Evermind' = '0.14.0'; 'JordanJacquot/Nevermind' = '1.5.0'; 'JordanJacquot/Mindcare' = '0.11.0' }
    }
    function Save-Json([string]$Fichier, $Objet) { New-Item -ItemType Directory -Force -Path (Split-Path $Fichier) | Out-Null; [IO.File]::WriteAllText($Fichier, ($Objet | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false)) }
    function Get-Demarrage { @(Get-Setting 'Demarrage' @()) -join ',' }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '1. Une appli qui se lançait avec Windows continue, par Mindset (« S''ouvre avec Mindset »)'
    # -------------------------------------------------------------------------------------------------------------
    Test-Cas 'apps.json : Evermind est une appli de rappels, pas Nevermind ni Mindcare' { $evermind.Rappels -eq $true -and -not $nevermind.Rappels -and -not $mindcare.Rappels }
    Reset-Pc
    $script:Run['evermind'] = @([pscustomobject]@{ Nom = 'Evermind'; Cible = "$tmp\ancien-programme\Evermind.exe" })
    Save-Json (Join-Path $evermind.Donnees 'reglages.json') @{ DemarrageWindows = $true; Theme = 'neon' }
    Start-InstallAppli $evermind "$tmp\ancien-programme"
    Test-Cas 'Prise en charge d''Evermind qui se lançait avec Windows : il s''ouvre avec Mindset' { (Get-Demarrage) -eq 'evermind' }
    Test-Cas '... et il est lancé tout de suite en arrière-plan (sans attendre le prochain démarrage du PC)' { $script:Fins['evermind'].Relancer -and $script:Fins['evermind'].Message -match 'est installé' }
    Reset-Pc
    Save-Json (Join-Path $evermind.Donnees 'reglages.json') @{ DemarrageWindows = $false }
    Start-InstallAppli $evermind "$tmp\ancien-programme"
    Test-Cas 'Prise en charge d''Evermind dont le démarrage avec Windows avait été coupé : il reste coupé' { (Get-Demarrage) -eq '' -and $script:Fins['evermind'] }
    Reset-Pc
    Start-InstallAppli $evermind
    Test-Cas 'Première installation d''Evermind (rien avant) : il s''ouvre avec Mindset d''office (sinon ses rappels ne sonnent pas)' { (Get-Demarrage) -eq 'evermind' }
    Reset-Pc
    Start-InstallAppli $mindcare
    Test-Cas 'Première installation de Mindcare (pas d''appli de rappels, aucun démarrage avant) : rien n''est allumé' { (Get-Demarrage) -eq '' -and $script:Fins['mindcare'] }
    Reset-Pc
    $script:Run['mindcare'] = @([pscustomobject]@{ Nom = 'Mindcare'; Cible = "$tmp\ailleurs\Mindcare.exe" })
    Start-InstallAppli $mindcare "$tmp\ailleurs"
    Test-Cas 'Prise en charge d''une autre appli qui avait une entrée « Run » : elle s''ouvre avec Mindset aussi' { (Get-Demarrage) -eq 'mindcare' }
    Reset-Pc
    $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.13.0' }
    Save-Json (Join-Path $donnees 'Evermind\reglages.json') @{ DemarrageWindows = $true }
    $script:Reglages['Demarrage'] = @()
    Start-InstallAppli $evermind
    Test-Cas 'Mise à jour d''Evermind déjà géré, interrupteur coupé par l''utilisateur : il reste coupé' { (Get-Demarrage) -eq '' -and $script:Fins['evermind'] }

    Reset-Pc
    $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.14.0' }
    $script:Installs['mindcare'] = @{ Dossier = "$prog\Mindcare"; Gere = $true; Version = '0.11.0' }
    Save-Json (Join-Path $donnees 'Evermind\reglages.json') @{ DemarrageWindows = $true }
    if (Test-Fonction 'Repair-DemarrageApplis') { Repair-DemarrageApplis }
    Test-Cas 'Réparation (installations d''avant, comme chez Jordan) : Evermind géré, qui voulait démarrer avec Windows, s''ouvre avec Mindset' { (Get-Demarrage) -eq 'evermind' -and (Get-Setting 'DemarrageRepris' $false) }
    $script:Reglages['Demarrage'] = @()
    if (Test-Fonction 'Repair-DemarrageApplis') { Repair-DemarrageApplis }
    Test-Cas 'Une seule fois : coupé ensuite par l''utilisateur, la réparation ne le rallume pas' { (Get-Demarrage) -eq '' -and (Get-Setting 'DemarrageRepris' $false) }
    Reset-Pc
    $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.14.0' }
    Save-Json (Join-Path $donnees 'Evermind\reglages.json') @{ DemarrageWindows = $false }
    if (Test-Fonction 'Repair-DemarrageApplis') { Repair-DemarrageApplis }
    Test-Cas 'Réparation : Evermind dont le démarrage avait été coupé reste coupé' { (Get-Demarrage) -eq '' -and (Get-Setting 'DemarrageRepris' $false) }
    Reset-Pc
    $script:Installs['nevermind'] = @{ Dossier = "$prog\Nevermind"; Gere = $true; Version = '1.5.0' }
    $script:TachesFaux['nevermind'] = @('Nevermind (démarrage)')
    $MindsetAdmin = $true
    Move-TachesDemarrage
    $MindsetAdmin = $false
    Test-Cas 'Mindset administrateur : la tâche de démarrage de Nevermind est retirée ET reprise par « S''ouvre avec Mindset »' { (Get-Demarrage) -eq 'nevermind' -and $script:TachesRetirees -contains 'nevermind' }
    $acc = [IO.File]::ReadAllText((Join-Path $fichiers 'modules\accueil.ps1'), [Text.Encoding]::UTF8)
    Test-Cas 'La carte d''une appli de rappels dit « S''ouvre avec Mindset (sinon tes rappels ne sonnent pas) »' { $acc.Contains("S'ouvre avec Mindset (sinon tes rappels ne sonnent pas)") -and $acc -match '\$Appli\.Rappels' }

    # Une mise à jour automatique ne rouvre pas une appli fermée par l'utilisateur
    Reset-Pc
    $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.13.0' }
    $script:Reglages['Demarrage'] = @('evermind')
    $script:MajAuto['evermind'] = '0.14.0'
    Start-InstallAppli $evermind
    Test-Cas 'Mise à jour automatique d''Evermind fermé (même « S''ouvre avec Mindset ») : il n''est pas rouvert' { $script:Fins['evermind'] -and -not $script:Fins['evermind'].Relancer }
    Reset-Pc
    $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.13.0' }
    $script:Reglages['Demarrage'] = @('evermind')
    Start-InstallAppli $evermind
    Test-Cas 'Mise à jour demandée par l''utilisateur (bouton) : relancé comme avant' { $script:Fins['evermind'].Relancer }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '2. Une version de Mindset déjà prête n''empêche pas d''en trouver une plus récente'
    # -------------------------------------------------------------------------------------------------------------
    Reset-Pc
    $script:MajMindset = $null; $script:MajMindsetEnCours = $false; $script:Telecharges.Clear()
    $fz = Join-Path $TelechargementsDir 'mindset.zip'
    $script:Pubs['JordanJacquot/Mindset'] = '2.3.3'
    Start-VerifMajMindset
    Test-Cas 'Mindset 2.2.0 : la 2.3.3 est téléchargée et prête' { $script:MajMindset.Version -eq '2.3.3' -and [IO.File]::ReadAllText($fz) -eq 'zip JordanJacquot/Mindset 2.3.3' }
    $script:Pubs['JordanJacquot/Mindset'] = '2.5.0'
    Start-VerifMajMindset
    Test-Cas 'La 2.5.0 sort ensuite : elle remplace la 2.3.3 prête (zip et signature)' {
        $script:MajMindset.Version -eq '2.5.0' -and [IO.File]::ReadAllText($fz) -eq 'zip JordanJacquot/Mindset 2.5.0' -and [IO.File]::ReadAllText("$fz.sig") -eq 'sig JordanJacquot/Mindset 2.5.0'
    }
    Test-Cas 'La version prête pointe vers mindset.zip, et rien ne traîne à côté' {
        $script:MajMindset.Zip -ieq $fz -and (@(Get-ChildItem -LiteralPath $TelechargementsDir -Filter 'mindset*' | ForEach-Object Name | Sort-Object) -join ',') -eq 'mindset.zip,mindset.zip.sig'
    }
    $script:Telecharges.Clear()
    Start-VerifMajMindset
    Test-Cas 'Toujours 2.5.0 publiée : rien n''est retéléchargé, la 2.5.0 reste prête' { $script:Telecharges.Count -eq 0 -and $script:MajMindset.Version -eq '2.5.0' }
    $script:Pubs['JordanJacquot/Mindset'] = '2.4.0'
    Start-VerifMajMindset
    Test-Cas 'Une version plus ancienne que celle qui est prête n''est jamais prise' { $script:MajMindset.Version -eq '2.5.0' -and [IO.File]::ReadAllText($fz) -eq 'zip JordanJacquot/Mindset 2.5.0' }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '3. Une appli ouverte est priée de quitter avant son installation (sans être fermée de force)'
    # -------------------------------------------------------------------------------------------------------------
    $DelaiFermetureAppli = 3
    Reset-Pc
    $script:AdminRepond = $false
    $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.13.0' }
    New-Item -ItemType Directory -Force -Path (Join-Path $donnees 'Evermind') | Out-Null
    $appli = Start-Essai "$prog\Evermind\Mindset.exe" @('appli', $evermind.Mutex, "`"$(Join-Path $donnees 'Evermind')`"")
    Test-Cas '(l''appli d''essai tourne : Mindset la voit ouverte par son mutex)' { Wait-Condition { Test-AppliOuverte $evermind } 5 }
    $debut = Get-Date
    Start-InstallAppli $evermind
    $ok = Wait-Condition { $script:AppelsAdmin.Count -gt 0 } 8
    Test-Cas 'Elle reçoit quitter.demande et se ferme d''elle-même ; l''installation ne part qu''ensuite' { $ok -and -not $script:AppelsAdmin[0].Ouverte -and $appli.HasExited }
    Test-Cas '... sans attendre tout le délai (elle s''est fermée vite)' { $ok -and ($script:AppelsAdmin[0].Quand - $debut).TotalSeconds -lt $DelaiFermetureAppli }
    Reset-Pc
    $script:AdminRepond = $false
    $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.13.0' }
    New-Item -ItemType Directory -Force -Path (Join-Path $donnees 'Evermind') | Out-Null
    $sourde = Start-Essai "$prog\Evermind\Mindset.exe" @('appli', $evermind.Mutex, "`"$(Join-Path $donnees 'Evermind')`"", 'sourde')
    [void](Wait-Condition { Test-AppliOuverte $evermind } 5)
    $debut = Get-Date
    Start-InstallAppli $evermind
    $ok = Wait-Condition { $script:AppelsAdmin.Count -gt 0 } ($DelaiFermetureAppli + 5)
    Test-Cas 'Une appli qui ne répond pas : l''installation part quand même après le délai (l''installateur la fermera)' {
        $ok -and $script:AppelsAdmin[0].Ouverte -and ($script:AppelsAdmin[0].Quand - $debut).TotalSeconds -ge ($DelaiFermetureAppli - 0.5) -and ($script:Journal -match 'ne s''est pas fermé').Count
    }
    try { $sourde.Kill(); [void]$sourde.WaitForExit(3000) } catch {}
    Reset-Pc
    $script:AdminRepond = $false
    $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.13.0' }
    Start-InstallAppli $evermind
    Test-Cas 'Une appli fermée : l''installation part tout de suite' { $script:AppelsAdmin.Count -eq 1 -and -not $script:AppelsAdmin[0].Ouverte }
    $admin = [IO.File]::ReadAllText((Join-Path $fichiers 'installer-admin.ps1'), [Text.Encoding]::UTF8)
    Test-Cas 'L''installateur garde son arrêt forcé en dernier recours (Stop-Programme, par dossier)' { $admin -match 'Stop-Programme \$Exe \$dest' }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '4. Un jeu en cours : vu même en fenêtre, sur un autre écran ou à la manette'
    # -------------------------------------------------------------------------------------------------------------
    $jeu = Start-Essai "$tmp\SteamLibrary\steamapps\common\Jeu de test\JeuTest.exe"
    $lanceur = Start-Essai "$tmp\Epic Games\Launcher\Portal\Binaries\LanceurTest.exe"
    $ajoute = Start-Essai "$tmp\Mes jeux\MonJeu.exe"
    Start-Sleep -Milliseconds 600
    $vus = @()
    try { $vus = @([MSProcessus]::JeuxOuverts([string[]]$DossiersJeux, [string[]]$DossiersPasJeux, [string[]]@("$tmp\Mes jeux\MonJeu.exe"))) } catch {}
    Test-Cas 'Un jeu d''un dossier de jeux (\steamapps\common\) qui tourne en fenêtre : vu' { $vus -contains "$tmp\SteamLibrary\steamapps\common\Jeu de test\JeuTest.exe" }
    Test-Cas 'Un lanceur qui reste ouvert en fond (\Epic Games\Launcher\) : pas pris pour un jeu' { $vus.Count -and $vus -notcontains "$tmp\Epic Games\Launcher\Portal\Binaries\LanceurTest.exe" }
    Test-Cas 'Un jeu ajouté à la main dans Nevermind : vu par son chemin' { $vus -contains "$tmp\Mes jeux\MonJeu.exe" }
    Save-Json (Join-Path $donnees 'Nevermind\parametres.json') @{ CustomGames = @(@{ Name = 'Mon jeu'; Exe = "$tmp\Mes jeux\MonJeu.exe" }, @{ Name = 'Pas un chemin'; Exe = 'MonJeu.exe' }) }
    Test-Cas 'Les jeux ajoutés dans Nevermind sont lus dans ses réglages (un nom sans chemin est ignoré)' { (@(Get-JeuxNevermind) -join '|') -eq "$tmp\Mes jeux\MonJeu.exe" }
    Test-Cas 'Get-JeuEnCours voit le jeu (quelle que soit la raison trouvée en premier)' { [string](Get-JeuEnCours) -ne '' }
    $jeu.Kill(); $ajoute.Kill(); [void]$jeu.WaitForExit(3000); [void]$ajoute.WaitForExit(3000)
    $vus = @([MSProcessus]::JeuxOuverts([string[]]$DossiersJeux, [string[]]$DossiersPasJeux, [string[]]@("$tmp\Mes jeux\MonJeu.exe")))
    Test-Cas 'Jeux fermés : plus vus' { -not @($vus | Where-Object { $_.StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase) }).Count }

    Test-Cas 'Plein écran sur un AUTRE écran (à droite du premier) : vu' { [MSActivite]::CouvreEcran(1920, 0, 3840, 1080, 1920, 0, 3840, 1080) -and [MSActivite]::CouvreEcran(1910, -10, 3850, 1090, 1920, 0, 3840, 1080) }
    Test-Cas 'Une fenêtre qui ne couvre pas tout son écran : pas un plein écran' { -not [MSActivite]::CouvreEcran(1920, 0, 3840, 1040, 1920, 0, 3840, 1080) }
    $w = New-Object System.Windows.Window
    $w.WindowStartupLocation = 'Manual'; $w.Left = -10000; $w.Top = 0; $w.Width = 3000; $w.Height = 2000; $w.WindowStyle = 'None'
    $w.ShowActivated = $false; $w.ShowInTaskbar = $false; $w.Title = 'Test plein écran'
    $w.Show()
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
    $pe = [MSActivite]::EstPleinEcran($h)
    $w.Close()
    Test-Cas 'Une fenêtre hors de tout écran n''est pas un plein écran (et le relevé de toutes les fenêtres marche)' { -not $pe -and ([MSActivite]::PleinEcranQuelquePart() -is [bool]) }

    $s0 = [MSActivite]::Signature(0, 0, 0, 0, 0, 0, 0)
    Test-Cas 'Manette : un stick qui dérive un peu au repos ne compte pas' { [MSActivite]::Signature(0, 10, 0, 3000, -2500, 0, 7000) -eq $s0 }
    [void][MSActivite]::Noter(3, $false, 0)
    $allumee = [MSActivite]::Noter(3, $true, $s0)
    $repos = [MSActivite]::Noter(3, $true, $s0)
    $bouton = [MSActivite]::Noter(3, $true, [MSActivite]::Signature(0x1000, 0, 0, 0, 0, 0, 0))
    $stick = [MSActivite]::Noter(3, $true, [MSActivite]::Signature(0x1000, 0, 0, 30000, 0, 0, 0))
    [void][MSActivite]::Noter(3, $false, 0)
    Test-Cas 'Manette : allumée, bouton, stick poussé comptent ; au repos non' { $allumee -and -not $repos -and $bouton -and $stick }
    Test-Cas 'Manette utilisée à l''instant : moins de 5 minutes (les mises à jour attendent)' { [MSActivite]::SecondesManette() -lt 300 }
    Test-Cas 'Le relevé des vraies manettes marche (lecture seule)' { [MSActivite]::ReleverManette(); $true }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '5. Filet : une erreur imprévue ne ferme plus Mindset (vrai Mindset de test, hors de l''écran)'
    # -------------------------------------------------------------------------------------------------------------
    $essaiM = Join-Path $tmp 'mindset-test'
    New-Item -ItemType Directory -Force -Path $essaiM | Out-Null
    $capture = Join-Path $essaiM 'capture.png'
    $vars = @{ MINDSET_TEST = '1'; MINDSET_SANS_RESEAU = '1'; MINDSET_DONNEES = $essaiM; MINDSET_CAPTURE = $capture; MINDSET_CAPTURE_DELAI = '3'; MINDSET_TEST_PLANTAGE = '1' }
    $avant = @{}; foreach ($k in $vars.Keys) { $avant[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try {
        $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$(Join-Path $fichiers 'Mindset.ps1')`"" -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $essaiM 'erreurs.txt')
        $null = $p.Handle   # (sans lui, Windows PowerShell ne donne pas le code de sortie)
        $script:Lances += $p
        if (-not $p.WaitForExit(90000)) { $p.Kill() }
    } finally { foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $avant[$k]) } }
    $journal = try { [IO.File]::ReadAllText((Join-Path $essaiM 'Mindset\journal.txt'), [Text.Encoding]::UTF8) } catch { '' }
    Test-Cas 'Mindset continue après 5 erreurs dans une minuterie : il va au bout (capture faite, sortie normale)' { (Test-Path -LiteralPath $capture) -and $p.ExitCode -eq 0 }
    Test-Cas 'L''erreur est notée au journal avec son script et sa ligne, 3 fois au plus' {
        $n = ([regex]::Matches($journal, 'Erreur imprévue, Mindset continue : .*Plantage de test \(interface\.ps1 ligne \d+\)')).Count
        $n -eq 3 -and $journal -match 'elle se répète : plus notée'
    }
    Test-Cas 'Un seul message pour l''utilisateur, en mots simples' { ([regex]::Matches($journal, 'Message montré : Un petit problème est survenu')).Count -eq 1 }
}
catch {
    $script:Echoues += "Arrêt inattendu : $($_.Exception.Message)"
    Write-Host "  ÉCHEC  Arrêt inattendu : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
}
finally {
    $env:MINDSET_DONNEES = $ancienDonnees
    # Seuls les programmes d'essai lancés ici sont fermés, puis le dossier de test est retiré
    foreach ($p in $script:Lances) { try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(3000) } } catch {} }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$total = $script:Reussis + $script:Echoues.Count
if ($script:Echoues.Count) {
    Write-Host "$($script:Echoues.Count) échec(s) sur $total cas :" -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Les $total cas sont réussis." -ForegroundColor Green
exit 0
