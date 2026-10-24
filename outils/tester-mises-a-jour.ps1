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
#   6. les mises à jour visibles dans la console : l'état envoyé à la carte (fausses applis, faux zips, fausse
#      progression, faux jeu), le clic sur la pastille, plusieurs applis à la suite, Mindset lui-même, l'historique
#      (écriture sûre, relecture, fichier abîmé, 12 heures sur la carte) ;
#   7. la vraie console reçoit l'état : un Mindset de test par étape (hors écran, outils\essai-maj-console.ps1), ce que
#      la carte affiche est relu dans la page avant la capture (ignoré si la console 3D n'est pas possible sur ce PC).
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
    # (avec une table de progression : une fausse progression, 650 octets sur 1000, et $script:PendantTelechargement est appelé)
    function Get-Octets([string]$Url, $Progres = $null) {
        $script:Telecharges.Add($Url)
        if ($Progres) { $Progres.Total = 1000; $Progres.Recu = 650; if ($script:PendantTelechargement) { & $script:PendantTelechargement } }
        [Text.Encoding]::UTF8.GetBytes($Url)
    }
    $script:PendantTelechargement = $null
    function Test-Signature { $true }
    . ([scriptblock]::Create(($asts['paquets.ps1'].FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-VersionPlusRecente' }, $true) | Select-Object -First 1).Extent.Text))
    $script:Interrupteurs = New-Object Collections.ArrayList
    $Window = [pscustomobject]@{ IsVisible = $false; WindowState = 'Normal' }
    $ui = @{}
    foreach ($n in 'MajTitre', 'MajTexte', 'BtnMajMindset', 'BtnMajFermer', 'MajBandeau') { $ui[$n] = [pscustomobject]@{ Text = ''; Content = ''; Visibility = 'Collapsed' } }

    Import-Fonctions 'installations.ps1' @('Start-InstallAppli', 'Complete-Telechargement', 'Send-InstallationAppli', 'Complete-Installation', 'Get-DemarrageAppli', 'Set-DemarrageAppli',
        'Get-DemarrageWindowsAppli', 'Repair-DemarrageApplis', 'Move-TachesDemarrage', 'Get-DossierGere')
    Import-Fonctions 'integration.ps1' @('Write-DemandeQuitter')
    Import-Fonctions 'mindset.ps1' @('Start-VerifMajMindset', 'Get-JeuxNevermind', 'Get-JeuEnCours', 'ConvertTo-EntreeMaj', 'Read-HistoriqueMaj', 'Save-HistoriqueMaj', 'Add-HistoriqueMaj',
        'Set-MajMindsetAttendue', 'Resolve-MajMindsetAttendue', 'Get-DerniereMaj', 'Format-QuandMaj', 'Get-AppliMaj')
    function Get-TachesDemarrageAppli([string]$Id) { @($script:TachesFaux[$Id] | Where-Object { $_ }) }   # (après l'import : jamais les vraies tâches)
    function Test-MindsetInstalle { $true }
    $RacineProgrammes = $prog
    . (Get-Lignes 'installations.ps1' 'DelaiFermetureAppli|AttentesFermeture|FermetureTimer|^\$TachesDemarrageAppli')
    . (Get-Lignes 'mindset.ps1' '^\$DossiersJeux|^\$DossiersPasJeux')
    $script:Occupe = @{}; $script:Messages = @{}; $script:EnCours = @{}; $script:Progres = @{}; $script:ARelancer = @{}; $script:MajAuto = @{}
    # L'historique des mises à jour : dans le dossier de test (le vrai Complete-Installation y écrit)
    $DataDir = $tmp
    . (Get-Lignes 'mindset.ps1' '^\$FichierHistoriqueMaj|^\$HistoriqueMajMax|^\$DureeDerniereMaj')
    $script:HistoriqueMaj = $null
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

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '6. Les mises à jour visibles dans la console : états envoyés, pastille, historique'
    # -------------------------------------------------------------------------------------------------------------
    $script:Journal = New-Object Collections.Generic.List[string]   # (« $journal » de la partie 5 est la même variable)
    Import-Fonctions 'console.ps1' @('Get-EtatMajConsole', 'Send-MajConsole', 'Set-MajAutoConsole', 'Receive-MessageConsole')
    Import-Fonctions 'accueil.ps1' @('Get-EtatCarte', 'Confirm-MiseAJour')
    Import-Fonctions 'mindset.ps1' @('Invoke-MajAuto', 'Test-MajAutoActive', 'Test-VerifVersionsActive', 'Set-VerifVersions', 'Test-MajAutoRecente')
    Import-Fonctions 'installations.ps1' @('Update-Publications')
    Import-Fonctions 'parametres.ps1' @('Get-HistoriqueMajAffiche')
    function ConvertTo-ThemeHex([string]$Hex) { $Hex }
    function Get-EtatAppli { $null }
    $script:SyncReglages = 0
    function Update-ReglagesMaj { $script:SyncReglages++ }
    function Send-ParametresConsole { }
    function Get-JeuEnCours { $script:JeuFaux }   # (après les imports : jamais le vrai PC, où un jeu tourne peut-être)
    $script:Envoye = New-Object Collections.Generic.List[string]
    function Invoke-ScriptConsole([string]$Code) { $script:Envoye.Add($Code) }
    function Get-Maj { Get-EtatMajConsole | ConvertFrom-Json }
    function Reset-Maj {
        Reset-Pc
        $script:Pubs['JordanJacquot/Evermind'] = '0.15.0'; $script:Pubs['JordanJacquot/Mindcare'] = '0.12.0'
        $script:Installs['evermind'] = @{ Dossier = "$prog\Evermind"; Gere = $true; Version = '0.14.0' }
        $script:Installs['mindcare'] = @{ Dossier = "$prog\Mindcare"; Gere = $true; Version = '0.11.0' }
        $script:Publications = @{}; foreach ($k in $script:Installs.Keys) { $script:Publications[$k] = @{ Version = $script:Installs[$k].Version; Notes = '' } }
        $script:Trouvees = @{}; $script:Recherches = @{}; $script:RechercheDepuis = [datetime]::MinValue; $script:Progres = @{}
        $script:MajAutoJeu = ''; $script:MajAutoAttentes = @{}; $script:MajAutoEssais = @{}; $script:MajAutoDerniere = [datetime]::MinValue; $script:JeuFaux = ''
        $script:MajMindset = $null; $script:MajMindsetEnCours = $false; $script:ProgresMindset = $null; $script:AttentesAdmin = New-Object Collections.ArrayList
        $script:Console = @{ Vue = $true; Pret = $true; MajEnvoye = '' }; $script:Envoye.Clear(); $script:Telecharges.Clear(); $script:SyncReglages = 0; $script:PendantTelechargement = $null
        $script:HistoriqueMaj = $null; Remove-Item -Path "$FichierHistoriqueMaj*" -Force -ErrorAction SilentlyContinue
    }
    function Set-Pub([string]$Id, [string]$Version) { $script:Publications[$Id] = @{ Version = $Version; UrlZip = 'zip'; UrlSig = 'sig'; Notes = "- Nouveautés de $Version" } }
    $ancienMajAuto = $env:MINDSET_MAJAUTO_TEST; $env:MINDSET_MAJAUTO_TEST = '1'   # (Invoke-MajAuto, ici seulement avec ses faux)
    try {
        Reset-Maj
        $m = Get-Maj
        Test-Cas 'Tout est à jour : phase « ajour », pastille cochée (réglage par défaut), recherche activée, rien de fait' { $m.phase -eq 'ajour' -and $m.auto -and $m.verif -and -not $m.fait }
        Set-Pub 'evermind' '0.15.0'; $script:Reglages['MajAuto'] = $false
        $m = Get-Maj
        Test-Cas 'Pastille décochée, Evermind 0.15.0 publié : « prête », pour Evermind 0.15.0 (le bouton Mettre à jour)' { $m.phase -eq 'prete' -and $m.appli.id -eq 'evermind' -and $m.appli.version -eq '0.15.0' -and -not $m.auto }
        $script:Reglages['MajAuto'] = $true
        $m = Get-Maj
        Test-Cas 'Pastille cochée : « en attente », dans un instant (elle se fera toute seule)' { $m.phase -eq 'attente' -and $m.raison -eq 'bientot' }
        $script:JeuFaux = 'un jeu ouvert (test)'
        Invoke-MajAuto
        $m = Get-Maj
        Test-Cas 'Un faux jeu : Invoke-MajAuto repousse, la carte dit « après ta partie », rien n''est téléchargé' { $m.phase -eq 'attente' -and $m.raison -eq 'jeu' -and $script:Telecharges.Count -eq 0 -and -not $script:Occupe.Count }
        $script:JeuFaux = ''; $script:MajAutoJeu = ''
        $script:MajAutoEssais['evermind'] = @{ Version = '0.15.0'; Quand = Get-Date }
        $m = Get-Maj
        Test-Cas 'Une mise à jour automatique ratée il y a moins de 6 heures : « prête », avec son bouton' { $m.phase -eq 'prete' }

        # Le vrai téléchargement (Start-InstallAppli) : sa progression arrive sur la carte
        Reset-Maj; Set-Pub 'evermind' '0.15.0'; $script:AdminRepond = $false
        $script:PendantTelechargement = { $script:Pendant = Get-Maj }
        $script:Pendant = $null
        Start-InstallAppli $evermind
        Test-Cas 'Pendant le téléchargement (fausse progression) : « telechargement », Evermind 0.15.0, 65 %' { $script:Pendant.phase -eq 'telechargement' -and $script:Pendant.appli.id -eq 'evermind' -and $script:Pendant.appli.version -eq '0.15.0' -and [double]$script:Pendant.progres -eq 0.65 }
        $m = Get-Maj
        Test-Cas 'Puis l''installation par l''Aide administrateur : « installation » (sans %), Evermind 0.15.0' { $m.phase -eq 'installation' -and $m.appli.version -eq '0.15.0' }
        Reset-Maj; Set-Pub 'evermind' '0.15.0'
        Start-InstallAppli $evermind
        $h = @((Read-HistoriqueMaj).Liste)
        $m = Get-Maj
        Test-Cas 'Une mise à jour faite par l''utilisateur : notée (Evermind 0.15.0, pas automatique, ses nouveautés)' { $h.Count -eq 1 -and $h[0].id -eq 'evermind' -and $h[0].version -eq '0.15.0' -and -not $h[0].auto -and $h[0].notes -match '0\.15\.0' }
        Test-Cas '... et la carte la garde : « Evermind 0.15.0 mis à jour à HH h MM »' { $m.phase -eq 'ajour' -and $m.fait.id -eq 'evermind' -and -not $m.fait.auto -and $m.fait.quand -match '^à \d\d h \d\d$' -and $m.fait.notes }
        Reset-Maj; Set-Pub 'evermind' '0.15.0'; $script:Installs.Remove('mindcare')
        Start-InstallAppli $mindcare
        Test-Cas 'Une première installation (rien avant) n''est pas une mise à jour : rien dans l''historique' { -not @((Read-HistoriqueMaj).Liste | Where-Object { $_.id -eq 'mindcare' }).Count }
        Reset-Maj; Set-Pub 'evermind' '0.15.0'
        Invoke-MajAuto
        $h = @((Read-HistoriqueMaj).Liste)
        Test-Cas 'Une mise à jour automatique (Invoke-MajAuto, pas de jeu) : notée « automatique »' { $h.Count -eq 1 -and $h[0].auto -and (Get-Maj).fait.auto }

        # Plusieurs applis l'une après l'autre : la carte suit celle en cours
        Reset-Maj; Set-Pub 'evermind' '0.15.0'; Set-Pub 'mindcare' '0.12.0'; $script:AdminRepond = $false
        Invoke-MajAuto
        $m1 = Get-Maj
        $script:Occupe.Remove('evermind'); $script:EnCours.Remove('evermind'); $script:MajAuto.Remove('evermind'); $script:Installs['evermind'].Version = '0.15.0'
        $m2 = Get-Maj
        $script:MajAutoDerniere = [datetime]::MinValue
        Invoke-MajAuto
        $m3 = Get-Maj
        Test-Cas 'Deux applis à mettre à jour : la carte montre Evermind, puis Mindcare qui attend, puis Mindcare en cours' { $m1.appli.id -eq 'evermind' -and $m1.phase -eq 'installation' -and $m2.appli.id -eq 'mindcare' -and $m2.phase -eq 'attente' -and $m3.appli.id -eq 'mindcare' -and $m3.phase -eq 'installation' }

        # Mindset lui-même
        Reset-Maj; $script:Pubs['JordanJacquot/Mindset'] = '2.7.0'
        $script:PendantTelechargement = { $script:Pendant = Get-Maj }; $script:Pendant = $null
        Start-VerifMajMindset
        Test-Cas 'Mindset télécharge sa nouvelle version (le vrai Start-VerifMajMindset) : « telechargement », Mindset 2.7.0, 65 %' { $script:Pendant.phase -eq 'telechargement' -and $script:Pendant.appli.id -eq 'mindset' -and $script:Pendant.appli.version -eq '2.7.0' -and [double]$script:Pendant.progres -eq 0.65 }
        $m = Get-Maj
        Test-Cas 'Puis Mindset 2.7.0 est prête ; Mindset à l''écran : « à la prochaine mise en veille »' { $m.phase -eq 'attente' -and $m.appli.id -eq 'mindset' -and $m.raison -eq 'veille' }
        Reset-Maj; $script:MajMindsetEnCours = $true; $script:ProgresMindset = @{ Version = ''; Recu = 0; Total = 0 }
        Test-Cas 'Mindset demande à GitHub (version pas encore connue) : « recherche »' { (Get-Maj).phase -eq 'recherche' }

        # La recherche : les vraies questions (Update-Publications), dont la réponse tarde
        Reset-Maj
        $script:Differees = New-Object Collections.ArrayList
        function Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) { [void]$script:Differees.Add($Fin) }
        Update-Publications
        $m1 = Get-Maj
        foreach ($f in @($script:Differees)) { & $f @{ Version = '0.1.0' } $null }
        $m2 = Get-Maj
        Test-Cas 'Pendant les questions à GitHub : « recherche » ; les réponses arrivées : plus de recherche' { $m1.phase -eq 'recherche' -and $m2.phase -ne 'recherche' -and -not $script:Recherches.Count }
        function Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) { $r = $null; $err = $null; try { $r = & $Travail $Parametres } catch { $err = $_.Exception.Message }; & $Fin $r $err }
        $script:RechercheDepuis = Get-Date
        Test-Cas 'Une recherche qui vient de partir se voit au moins 2 secondes (GitHub répond vite)' { (Get-Maj).phase -eq 'recherche' }

        # La recherche coupée, et la pastille
        Reset-Maj; $script:Reglages['VerifVersions'] = $false
        $m = Get-Maj
        Set-MajAutoConsole $false
        Test-Cas 'Recherche coupée : « coupee » (la carte le dit), et la pastille ne peut pas changer le réglage' { $m.phase -eq 'coupee' -and -not $m.verif -and -not $script:Reglages.ContainsKey('MajAuto') }
        Reset-Maj; Set-Pub 'evermind' '0.15.0'
        Receive-MessageConsole '{"type":"action","action":"majAuto","valeur":false}'
        $apres = $script:Envoye | Select-Object -Last 1
        Test-Cas 'Clic sur la pastille (message de la page) : MajAuto coupé, Paramètres > Mises à jour suit, la console reçoit « prête »' {
            $script:Reglages['MajAuto'] -eq $false -and $script:SyncReglages -eq 1 -and $apres -match '^window\.mindset\.majAuto\(' -and $apres -match '"auto":false' -and $apres -match '"phase":"prete"'
        }
        Receive-MessageConsole '{"type":"action","action":"majAuto","valeur":true}'
        Test-Cas 'Clic à nouveau : MajAuto remis, la console reçoit « en attente »' { $script:Reglages['MajAuto'] -eq $true -and ($script:Envoye | Select-Object -Last 1) -match '"phase":"attente"' }
        $n = $script:Envoye.Count; Send-MajConsole; Send-MajConsole
        Test-Cas 'L''état n''est renvoyé que s''il a changé' { $script:Envoye.Count -eq $n }

        # L'historique : écriture sûre, relecture, fichier abîmé
        Reset-Maj
        for ($i = 1; $i -le 25; $i++) { Add-HistoriqueMaj 'nevermind' 'Nevermind' "1.0.$i" ($i % 2 -eq 0) "notes $i" }
        $script:HistoriqueMaj = $null
        $h = @((Read-HistoriqueMaj).Liste)
        Test-Cas 'Historique : les 20 dernières, la plus récente d''abord, relues du fichier (aucun .tmp ne traîne)' { $h.Count -eq 20 -and $h[0].version -eq '1.0.25' -and $h[19].version -eq '1.0.6' -and $h[1].auto -and -not (Test-Path -LiteralPath "$FichierHistoriqueMaj.tmp") }
        [IO.File]::WriteAllText($FichierHistoriqueMaj, '{ "historique": [ { "id": "evermind", "vers')
        $script:HistoriqueMaj = $null
        $vide = @((Read-HistoriqueMaj).Liste).Count
        Add-HistoriqueMaj 'evermind' 'Evermind' '0.15.0' $true ''
        $relu = [IO.File]::ReadAllText($FichierHistoriqueMaj) | ConvertFrom-Json
        Test-Cas 'Fichier abîmé : mis de côté (.abime), l''historique repart de zéro et le suivant s''écrit bien' { $vide -eq 0 -and (Test-Path -LiteralPath "$FichierHistoriqueMaj.abime") -and @($relu.historique).Count -eq 1 }
        $q = (Get-Date).ToString('s')
        [IO.File]::WriteAllText($FichierHistoriqueMaj, (ConvertTo-Json -Depth 4 -InputObject @{ historique = @(
            @{ id = 'evermind'; nom = 'Evermind'; version = '0.15.0'; quand = $q; auto = $true }, @{ id = '..\x'; nom = 'X'; version = '1.0'; quand = $q },
            @{ id = 'mindcare'; nom = 'Mindcare'; version = 'abc'; quand = $q }, @{ id = 'mindcare'; nom = 'Mindcare'; version = '1.0'; quand = 'hier' }, 'texte') }))
        $script:HistoriqueMaj = $null
        Test-Cas 'Une entrée qui n''a pas la forme attendue (nom, version, date) est ignorée' { @((Read-HistoriqueMaj).Liste).Count -eq 1 }
        Reset-Maj
        Set-MajMindsetAttendue '2.7.0' $true '- Nouveautés de Mindset'
        $script:HistoriqueMaj = $null
        $avantVersion = $AppVersion; $AppVersion = '2.7.0'
        Resolve-MajMindsetAttendue
        $AppVersion = $avantVersion
        $h = @((Read-HistoriqueMaj).Liste)
        Test-Cas 'Mindset s''est mis à jour (attendue avant de se fermer, 2.7.0 au redémarrage) : noté automatique' { $h.Count -eq 1 -and $h[0].id -eq 'mindset' -and $h[0].version -eq '2.7.0' -and $h[0].auto -and -not (Read-HistoriqueMaj).Attendue }
        Reset-Maj
        Set-MajMindsetAttendue '2.8.0' $false ''
        Resolve-MajMindsetAttendue
        Test-Cas 'Mise à jour de Mindset ratée (il redémarre dans son ancienne version) : rien de noté' { -not @((Read-HistoriqueMaj).Liste).Count -and -not (Read-HistoriqueMaj).Attendue }
        Reset-Maj
        $o = @{ historique = @(@{ id = 'evermind'; nom = 'Evermind'; version = '0.15.0'; quand = (Get-Date).AddHours(-13).ToString('s'); auto = $true }) }
        [IO.File]::WriteAllText($FichierHistoriqueMaj, (ConvertTo-Json -Depth 4 -InputObject $o)); $script:HistoriqueMaj = $null
        $vieux = Get-Maj
        $o.historique[0].quand = (Get-Date).AddHours(-11).ToString('s')
        [IO.File]::WriteAllText($FichierHistoriqueMaj, (ConvertTo-Json -Depth 4 -InputObject $o)); $script:HistoriqueMaj = $null
        $recent = Get-Maj
        Test-Cas 'La dernière mise à jour reste sur la carte 12 heures, pas plus' { -not $vieux.fait -and $recent.fait.version -eq '0.15.0' }
        $aff = @(Get-HistoriqueMajAffiche)
        Test-Cas 'Paramètres > Mises à jour : la liste dit l''appli, la version, quand, et « automatique »' { $aff.Count -eq 1 -and $aff[0].nom -eq 'Evermind' -and $aff[0].version -eq '0.15.0' -and $aff[0].auto -and $aff[0].quand -match '^(Aujourd''hui|Hier) à \d\d h \d\d$' }
        Test-Cas 'Les heures en mots simples : « à 00 h 16 », « hier à 21 h 05 », « le 18 octobre à 09 h 30 »' {
            (Format-QuandMaj ((Get-Date).Date.AddMinutes(16).ToString('s'))) -eq 'à 00 h 16' -and (Format-QuandMaj ((Get-Date).Date.AddDays(-1).AddHours(21).AddMinutes(5).ToString('s'))) -eq 'hier à 21 h 05' -and
            (Format-QuandMaj '2026-10-18T09:30:00') -match '^le 18 octobre à 09 h 30$|^hier|^à'
        }
    } finally { $env:MINDSET_MAJAUTO_TEST = $ancienMajAuto }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '7. La vraie console reçoit l''état (Mindset de test hors de l''écran, outils\essai-maj-console.ps1)'
    # -------------------------------------------------------------------------------------------------------------
    # Chaque étape : un Mindset de test avec la console 3D, de fausses applis et de fausses mises à jour ; ce que la carte
    # affiche est relu dans la page juste avant la capture (« Essai : carte = ... » au journal)
    $etapes = [ordered]@{
        telechargement = @('Evermind 0\.15\.0 65 %', 'majCharge')
        attente        = @('Evermind 0\.15\.0 : après ta partie', '')
        prete          = @('Nouvelle version d''Evermind prête Mettre à jour', '')
        clic           = @('dans un instant', '')
        termine        = @('Evermind 0\.15\.0 mis à jour tout seul à \d\d h \d\d Nouveautés', '')
        recherche      = @('Recherche des mises à jour', 'majCherche')
    }
    $sansConsole = $false
    foreach ($e in $etapes.Keys) {
        if ($sansConsole) { break }
        $dossier = Join-Path $tmp "console-$e"
        New-Item -ItemType Directory -Force -Path $dossier | Out-Null
        $png = Join-Path $dossier 'console.png'
        $vars = @{ MINDSET_TEST = '1'; MINDSET_SANS_RESEAU = '1'; MINDSET_DONNEES = $dossier; MINDSET_CONSOLE = '1'; MINDSET_CAPTURE = (Join-Path $dossier 'inutile.png')
            MINDSET_CONSOLE_CAPTURE = $png; MINDSET_CONSOLE_DELAI = '5000'; MINDSET_TEST_SCRIPT = (Join-Path $PSScriptRoot 'essai-maj-console.ps1'); MINDSET_TEST_ETAPE = $e
            MINDSET_MAJAUTO_TEST = $(if ($e -in 'telechargement', 'attente') { '1' } else { '' }) }
        $avant = @{}; foreach ($k in $vars.Keys) { $avant[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        try {
            $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$(Join-Path $fichiers 'Mindset.ps1')`"" -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $dossier 'erreurs.txt')
            $null = $p.Handle
            $script:Lances += $p
            if (-not $p.WaitForExit(90000)) { $p.Kill() }
        } finally { foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $avant[$k]) } }
        $journal = try { [IO.File]::ReadAllText((Join-Path $dossier 'Mindset\journal.txt'), [Text.Encoding]::UTF8) } catch { '' }
        if ($journal -match 'Console 3D désactivée : (.*)') { Write-Host "  IGNORÉ la console 3D n'est pas possible ici ($($Matches[1].Trim()))" -ForegroundColor Yellow; $sansConsole = $true; break }
        $carte = if ($journal -match 'Essai : carte = (.*)') { $Matches[1].Trim() } else { '' }
        $bouton = if ($journal -match 'Essai : bouton Chercher = (.*)') { $Matches[1].Trim() } else { '' }
        $attendu = $etapes[$e]
        Test-Cas "Étape $e : la carte affiche « $($attendu[0] -replace '\\', '') » (capture faite)" { (Test-Path -LiteralPath $png) -and $carte -match $attendu[0] -and $carte -match '^Mise à jour automatique' -and (-not $attendu[1] -or $bouton -match $attendu[1]) }
        if ($e -eq 'clic') { Test-Cas '... le clic sur la pastille dans la page a coché le réglage' { $journal -match 'Mises à jour automatiques : oui \(pastille de la console\)' -and $journal -match 'Essai : pastille = true' } }
        if ($e -eq 'telechargement') { Test-Cas '... la mise à jour vient du vrai Invoke-MajAuto, et rien n''est installé pour de vrai' { $journal -match 'Mise à jour automatique : Evermind 0\.15\.0' -and $journal -notmatch 'Essai : .* refusé' } }
    }
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
