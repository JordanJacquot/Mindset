# Mindset : tests de Mindset face à son mini-installateur (la tâche SYSTEM « \Mindset\Mindset (installation) »).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-mini-installateur.ps1
#   (-Fichiers <dossier> : tester une autre copie de Mindset\fichiers, par exemple l'ancienne version, pour la contre-épreuve)
#
# On vérifie, avec les vraies fonctions de Mindset (modules\installations.ps1, mindset.ps1, taches.ps1) et de faux
# Windows (faux schtasks, fausse demande de Windows, faux registre, horloge simulée) :
#   1. la tâche n'est utilisée que si c'est la tâche SYSTEM inscrite pour cet utilisateur ; l'ancienne (« avec les
#      droits les plus élevés ») ne sert qu'à se remplacer, jamais à installer ;
#   2. si la tâche ne marche pas (refusée, absente, pas d'accusé de réception dans le délai), la demande normale de
#      Windows prend le relais (jamais l'ancienne tâche), sauf pour la mise à jour automatique elle-même (personne pour
#      répondre ; une opération lancée à la main pendant qu'elle tourne garde la demande de Windows) ; une tâche lente
#      mais qui a accusé réception n'est pas doublée ;
#   3. Mindset ne se ferme pour se mettre à jour qu'à l'accusé de réception de la tâche (sinon : la demande de Windows) ;
#   4. la demande est effacée par Mindset (le mini-installateur, en SYSTEM, n'efface rien dans ses dossiers) ;
#   5. la ligne de commande de la demande de Windows avec un dossier qui finit par \ (Mindset lancé depuis E:\) ;
#   6. plus de code fabriqué avec des données (revue du 25/10, constat 10) : un dossier « d’Arthur » ou avec un $ arrive
#      tel quel, rien n'est exécuté, et la table des valeurs ne grossit pas ;
#   7. la demande de Windows n'est pas lancée si une variable COR_* ou COMPlus_* (lue par .NET avant le script) est
#      dans Mindset ou dans les variables du compte, et powershell.exe est celui de System32, demandé à Windows ;
#   8. après une mise à jour directe depuis Mindset 2.11.0 ou avant, les tâches d'avant (partie administrateur sous le
#      compte, très vieille « \Mindset\Mindset ») sont vues au démarrage et refaites par la tâche SYSTEM (audit du 25/10,
#      constats 11 et 25e).
# Rien sur le vrai PC : ni tâche planifiée, ni registre, ni demande de Windows (tout est faux, en mémoire), aucun réseau.
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).
param([string]$Fichiers)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = if ($Fichiers) { (Resolve-Path -LiteralPath $Fichiers).Path } else { Join-Path $racine 'Mindset\fichiers' }
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)

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
        $script:Journal | Select-Object -Last 12 | ForEach-Object { Write-Host "           | $_" -ForegroundColor DarkGray }
    }
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

# Les fonctions de Mindset, lues dans ses fichiers
$asts = @{}
foreach ($m in 'installations.ps1', 'mindset.ps1', 'taches.ps1', 'accueil.ps1') {
    $e = $null
    $asts[$m] = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $fichiers "modules\$m"), [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
}
$script:Manquantes = @()
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    foreach ($n in $Noms) {
        $x = @($asts[$Fichier].FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true)) | Select-Object -First 1
        if (-not $x) { $script:Manquantes += "$Fichier : $n"; continue }
        . ([scriptblock]::Create($x.Extent.Text))
        Set-Item -Path "function:script:$($x.Name)" -Value (Get-Item "function:$($x.Name)").ScriptBlock
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Le faux PC
# ---------------------------------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "mindset-tests-mini-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$moi = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$apo = [string][char]0x2019   # l'apostrophe typographique, que PowerShell prend aussi pour une fin de texte
$DataDir = Join-Path $tmp 'donnees'; $TelechargementsDir = Join-Path $DataDir 'telechargements'
New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
$AppDir = Join-Path $tmp 'Mindset\fichiers'; $DossierMindset = Join-Path $tmp 'Mindset'
$FichierMajMindset = Join-Path $TelechargementsDir 'maj-mindset.json'
$MindsetAdmin = $false
$TacheInstallation = '\Mindset\Mindset (installation)'
$FichierDemande = Join-Path $DataDir 'installation.demande'
$CleInstallationAdmin = 'HKLM:\SOFTWARE\Mindset\Installation'
$DelaiAccuseTache = 30
$script:Journal = New-Object Collections.Generic.List[string]
function Write-Log([string]$T) { $script:Journal.Add("JOURNAL $T") }

# Horloge simulée
$script:Maintenant = [datetime]'2026-10-25 10:00:00'
function Get-Date { $script:Maintenant }
function Move-Horloge([double]$Secondes) { $script:Maintenant = $script:Maintenant.AddSeconds($Secondes) }

# Faux schtasks : /Query /XML rend $script:XmlTache (rien : absente), /Run réussit si $script:RunOk
$script:XmlTache = $null; $script:RunOk = $true; $script:Lancements = New-Object Collections.Generic.List[string]
function Invoke-FauxSchtasks {
    $a = "$args"
    if ($a -like '/Query*') {
        # (la tâche d'installation : $script:XmlTache ; les autres : $script:AutresTaches, nom -> XML)
        $nom = [string]$args[2]
        $xml = if ($nom -eq $TacheInstallation) { $script:XmlTache } else { $script:AutresTaches[$nom] }
        if ($xml) { $global:LASTEXITCODE = 0; return ($xml -split "`n") }
        $global:LASTEXITCODE = 1; return
    }
    if ($a -like '/Run*') {
        $c = if (Test-Path -LiteralPath $FichierDemande) { [IO.File]::ReadAllText($FichierDemande) | ConvertFrom-Json } else { $null }
        $script:Lancements.Add("TACHE $($c.Action)")
        $global:LASTEXITCODE = if ($script:RunOk) { 0 } else { 1 }
        return
    }
    $global:LASTEXITCODE = 1
}
$SchtasksExe = 'Invoke-FauxSchtasks'
function Get-XmlTache([string]$Compte, [string]$Arguments) {
    "<?xml version=""1.0"" encoding=""UTF-16""?>`n<Task xmlns=""http://schemas.microsoft.com/windows/2004/02/mit/task""><Principals><Principal id=""Author""><UserId>$Compte</UserId></Principal></Principals><Actions Context=""Author""><Exec><Command>powershell.exe</Command><Arguments>$([Security.SecurityElement]::Escape($Arguments))</Arguments></Exec></Actions></Task>"
}
$xmlSysteme = Get-XmlTache 'S-1-5-18' "-NoProfile -File `"C:\Program Files\Mindset\Mindset\fichiers\installer-admin.ps1`" -Action demande -Sid $moi -Demande `"$FichierDemande`""
$xmlAncienne = Get-XmlTache $moi "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"x`" -Action demande -Demande `"$FichierDemande`""

# Faux registre (HKLM:\SOFTWARE\Mindset\Installation) : Recu et Resultat
$script:Registre = @{}
function Get-ItemProperty {
    param([string]$Path, [string]$Name)
    if ($Path -ne $CleInstallationAdmin -or -not $script:Registre.ContainsKey($Name)) { throw 'absent' }
    [pscustomobject]@{ $Name = $script:Registre[$Name] }
}
# Fausse demande de Windows : notée ; $script:RunAsAccepte : l'utilisateur clique « Oui »
$script:RunAs = New-Object Collections.Generic.List[string]; $script:RunAsAccepte = $true; $script:RunAsExe = New-Object Collections.Generic.List[string]
function Start-Process {
    param([string]$FilePath, $ArgumentList, [string]$Verb, [string]$WindowStyle, [string]$WorkingDirectory, [switch]$PassThru)
    if ($Verb -ne 'RunAs') { throw "lancement inattendu : $FilePath" }
    $script:RunAs.Add((@($ArgumentList) -join ' ')); $script:RunAsExe.Add($FilePath)
    if (-not $script:RunAsAccepte) { throw 'refusée' }
    [pscustomobject]@{ HasExited = $true }
}
$script:AdminTimer = [pscustomobject]@{ Marche = $false }
$script:AdminTimer | Add-Member ScriptMethod Start { $this.Marche = $true }
$script:AdminTimer | Add-Member ScriptMethod Stop { $this.Marche = $false }
$ui = @{}; foreach ($n in 'MajTitre', 'MajTexte', 'BtnMajMindset', 'BtnMajFermer', 'MajBandeau') { $ui[$n] = [pscustomobject]@{ Text = ''; Content = ''; Visibility = 'Collapsed' } }
$script:Reglages = @{}
function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur }
function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.ContainsKey($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
function Set-MajMindsetAttendue { }
$script:Sorties = 0
function Exit-Mindset { $script:Sorties++ }

Import-Fonctions 'installations.ps1' @('Get-EtatTacheInstallation', 'Test-TacheInstallation', 'Remove-DemandeInstallation', 'Get-ValeurInstallation', 'Send-DemandeInstallation',
    'Skip-TacheInstallation', 'Invoke-Admin', 'Format-ArgumentAdmin', 'Invoke-AdminDirect', 'Send-DemandeSuivante', 'Update-AttentesAdmin', 'Start-RemplacementTache',
    'Get-RefusVariablesAdmin', 'Test-TachesAnciennes', 'Start-RemiseEnOrdreTaches')
# (les variables du compte, HKCU\Environment : fausses ici, jamais celles de ce PC)
$script:VariablesCompte = @()
function Get-NomsVariablesCompte { $script:VariablesCompte }
$PowerShellWindows = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
# (les applis de apps.json qui ont une partie administrateur)
$Applis = @([pscustomobject]@{ Id = 'nevermind'; Aide = 'Nevermind (aide)' }, [pscustomobject]@{ Id = 'evermind'; Aide = '' })
$script:AutresTaches = @{}
Import-Fonctions 'mindset.ps1' @('Start-MajMindset', 'Start-MajMindsetDirecte', 'Set-EchecMajAuto', 'Get-RaisonEchecMaj', 'Format-DeNom', 'Get-MajAutoReessai', 'Show-BulleMajAuto')
$script:MajAutoEchecs = @{}; $script:MajAutoEssais = @{}
Import-Fonctions 'taches.ps1' @('New-Action', 'Pop-Action')
$script:Actions = New-Object System.Collections.Specialized.OrderedDictionary

# Remet le faux PC à zéro. $Xml : la tâche vue par schtasks ; -RunKo : schtasks /Run échoue
function Reset-Pc([string]$Xml, [switch]$RunKo) {
    $script:XmlTache = $Xml; $script:RunOk = -not $RunKo
    $script:Lancements.Clear(); $script:RunAs.Clear(); $script:RunAsExe.Clear(); $script:RunAsAccepte = $true; $script:Registre = @{}; $script:Journal.Clear()
    $script:VariablesCompte = @(); $script:AutresTaches = @{}
    $script:TacheInstallationOk = $null; $script:EtatTacheInstallation = $null
    $script:AttentesAdmin = New-Object System.Collections.ArrayList; $script:DemandesEnAttente = New-Object System.Collections.ArrayList
    $script:MajAuto = @{}; $script:Fins = New-Object Collections.Generic.List[string]; $script:Sorties = 0; $script:MajMindsetEnvoyee = $false
    $script:Reglages = @{}
    Remove-Item -LiteralPath $FichierDemande -Force -ErrorAction SilentlyContinue
}
$fin = { param($Ok, $Message) $script:Fins.Add("$Ok|$Message") }
# La tâche reçoit la demande (accusé de réception), puis répond
function Set-Recu { $c = [IO.File]::ReadAllText($FichierDemande) | ConvertFrom-Json; $script:Registre['Recu'] = $c.Id; $c.Id }
function Set-Reponse([string]$Id, [bool]$Ok, [string]$Message) { $script:Registre['Resultat'] = (@{ id = $Id; ok = $Ok; message = $Message } | ConvertTo-Json -Compress) }
$appli = @{ Zip = (Join-Path $TelechargementsDir 'a.zip'); Signature = (Join-Path $TelechargementsDir 'a.zip.sig'); Destination = 'C:\Program Files\Mindset\Appli'; DossierZip = 'Appli'; Exe = 'Appli.exe' }

# Le corpus de cas, côté Mindset (cas\installateur\cote-mindset-*.json, format décrit dans cas\LISEZMOI.md) : les mêmes cas
# serviront à Mindset en Rust. Le nombre de cas attendu au moins dans chaque fichier : un cas retiré fait échouer le test.
$dossierCas = Join-Path $racine 'cas\installateur'
$minimumCas = [ordered]@{ 'cote-mindset-tache.json' = 5; 'cote-mindset-variables.json' = 9; 'cote-mindset-taches-anciennes.json' = 4; 'cote-mindset-arguments.json' = 3 }
$valeursCas = @{ '{sid}' = $moi; '{sid-autre}' = 'S-1-5-21-1111111111-2222222222-3333333333-1001'; '{demande}' = $FichierDemande }
function Expand-Texte([string]$T) {
    foreach ($k in $valeursCas.Keys) { $T = $T.Replace($k, $valeursCas[$k]) }
    if ($T -match '\{[a-z][a-z-]*\}') { throw "Valeur inconnue dans le corpus : $($Matches[0])" }
    $T
}
# Les cas d'un fichier (et un cas de plus : le fichier est au format 1, avec assez de cas, et ses attendus sont connus)
function Read-Corpus([string]$Nom, [string[]]$Attendus) {
    $corpus = [IO.File]::ReadAllText((Join-Path $dossierCas $Nom), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $n = @($corpus.cas).Count
    $inconnus = @(@($corpus.cas) | ForEach-Object { $_.attendu.PSObject.Properties.Name } | Where-Object { $_ -notin $Attendus })
    Test-Cas "$Nom : format 1, au moins $($minimumCas[$Nom]) cas (trouvés : $n), attendus connus" { $corpus.format -eq 1 -and $n -ge $minimumCas[$Nom] -and -not $inconnus.Count }
    @($corpus.cas)
}

try {
    Write-Host 'Mindset : tests face au mini-installateur (tâche SYSTEM)' -ForegroundColor Cyan
    if ($script:Manquantes.Count) { Write-Host "Fonctions absentes : $($script:Manquantes -join ', ')" -ForegroundColor Yellow }

    # =============================================================================================================
    Write-Partie 'Quelle tâche est utilisée'
    # =============================================================================================================
    $lus = @(Get-ChildItem -LiteralPath $dossierCas -Filter 'cote-mindset-*.json' -File | ForEach-Object { $_.Name })
    Test-Cas "chaque fichier cas\installateur\cote-mindset-*.json est lu par ce test ($($lus.Count) fichiers)" { -not @($lus | Where-Object { -not $minimumCas.Contains($_) }).Count -and $lus.Count -eq $minimumCas.Count }
    foreach ($cas in (Read-Corpus 'cote-mindset-tache.json' 'etat', 'utilisee')) {
        $c = $cas
        Test-Cas ([string]$c.nom) {
            Reset-Pc $(if ($c.entree.absente) { $null } else { Get-XmlTache (Expand-Texte $c.entree.compte) (Expand-Texte $c.entree.arguments) })
            (Get-EtatTacheInstallation) -eq [string]$c.attendu.etat -and [bool](Test-TacheInstallation) -eq [bool]$c.attendu.utilisee
        }
    }

    # =============================================================================================================
    Write-Partie 'Par la tâche SYSTEM, et la demande de Windows si elle ne marche pas (condition de l''auditeur)'
    # =============================================================================================================
    Test-Cas 'tâche qui marche : demande écrite, tâche lancée, accusé puis réponse, Fin appelée, demande effacée par Mindset, aucune demande de Windows' {
        Reset-Pc $xmlSysteme
        Invoke-Admin 'appli' $appli $fin
        $lancee = (Test-Path -LiteralPath $FichierDemande) -and $script:Lancements.Count -eq 1
        Move-Horloge 2; $id = Set-Recu; Update-AttentesAdmin
        Move-Horloge 40; Update-AttentesAdmin   # (accusé reçu : pas de repli même après le délai)
        $avant = $script:Fins.Count
        Set-Reponse $id $true 'C:\Program Files\Mindset\Appli'; Move-Horloge 1; Update-AttentesAdmin
        $lancee -and $avant -eq 0 -and $script:Fins.Count -eq 1 -and $script:Fins[0] -like 'True|*' -and -not (Test-Path -LiteralPath $FichierDemande) -and -not $script:RunAs.Count
    }
    Test-Cas 'tâche refusée (schtasks /Run échoue) : la demande de Windows tout de suite, avec les mêmes paramètres' {
        Reset-Pc $xmlSysteme -RunKo
        Invoke-Admin 'appli' $appli $fin
        $script:RunAs.Count -eq 1 -and $script:RunAs[0] -like '*-Action appli*' -and $script:RunAs[0] -like "*-Zip `"$($appli.Zip)`"*" -and -not (Test-Path -LiteralPath $FichierDemande) -and $script:TacheInstallationOk -eq $false
    }
    Test-Cas 'tâche muette (pas d''accusé de réception en 30 s) : demande retirée, puis la demande de Windows' {
        Reset-Pc $xmlSysteme
        Invoke-Admin 'appli' $appli $fin
        Move-Horloge 29; Update-AttentesAdmin; $pasEncore = -not $script:RunAs.Count
        Move-Horloge 2; Update-AttentesAdmin
        $pasEncore -and $script:RunAs.Count -eq 1 -and -not (Test-Path -LiteralPath $FichierDemande) -and -not @($script:AttentesAdmin | Where-Object { $_.Id }).Count
    }
    Test-Cas 'après une tâche muette : l''opération suivante passe directement par la demande de Windows' {
        Invoke-Admin 'supprimer' @{ Destination = 'C:\Program Files\Mindset\Appli'; Exe = 'Appli.exe' } $fin
        $script:RunAs.Count -eq 2 -and $script:Lancements.Count -eq 1
    }
    Test-Cas 'accusé arrivé juste au délai (la tâche a pris la demande au dernier moment) : pas de demande de Windows en double' {
        Reset-Pc $xmlSysteme
        Invoke-Admin 'appli' $appli $fin
        $null = Set-Recu; Move-Horloge 31; Update-AttentesAdmin
        -not $script:RunAs.Count -and @($script:AttentesAdmin | Where-Object { $_.Id }).Count -eq 1
    }
    Test-Cas 'tâche lente (accusé reçu, réponse après 5 minutes) : on l''attend, aucune demande de Windows' {
        Reset-Pc $xmlSysteme
        Invoke-Admin 'appli' $appli $fin
        $id = Set-Recu; Update-AttentesAdmin
        Move-Horloge 300; Update-AttentesAdmin
        Set-Reponse $id $false 'Dossier refusé'; Update-AttentesAdmin
        -not $script:RunAs.Count -and $script:Fins.Count -eq 1 -and $script:Fins[0] -eq 'False|Dossier refusé'
    }
    Test-Cas 'tâche absente : la demande de Windows, sans essayer de lancer une tâche' {
        Reset-Pc $null
        Invoke-Admin 'appli' $appli $fin
        $script:RunAs.Count -eq 1 -and -not $script:Lancements.Count
    }
    Test-Cas 'ancienne tâche seulement : jamais utilisée pour installer, la demande de Windows à la place' {
        Reset-Pc $xmlAncienne
        Invoke-Admin 'appli' $appli $fin
        $script:RunAs.Count -eq 1 -and -not $script:Lancements.Count
    }
    Test-Cas 'la mise à jour automatique elle-même (-Auto), tâche muette : pas de demande de Windows (personne pour répondre), échec noté' {
        Reset-Pc $xmlSysteme
        $script:MajAuto = @{ appli = '2.0.0' }
        Invoke-Admin 'appli' $appli $fin -Auto
        Move-Horloge 31; Update-AttentesAdmin
        -not $script:RunAs.Count -and $script:Fins.Count -eq 1 -and $script:Fins[0] -like 'False|*'
    }
    Test-Cas 'une installation lancée à la main PENDANT une mise à jour automatique, tâche muette : elle garde la demande de Windows' {
        Reset-Pc $xmlSysteme
        $script:MajAuto = @{ autre = '2.0.0' }
        Invoke-Admin 'appli' $appli $fin
        Move-Horloge 31; Update-AttentesAdmin
        $script:RunAs.Count -eq 1 -and $script:RunAs[0] -like '*-Action appli*'
    }
    Test-Cas '... et tâche refusée : la demande de Windows tout de suite pour elle aussi' {
        Reset-Pc $xmlSysteme -RunKo
        $script:MajAuto = @{ autre = '2.0.0' }
        Invoke-Admin 'appli' $appli $fin
        $script:RunAs.Count -eq 1
    }
    Test-Cas 'deux demandes : la seconde attend la première ; tâche muette sur la première, les deux passent par la demande de Windows' {
        Reset-Pc $xmlSysteme
        Invoke-Admin 'appli' $appli $fin
        Invoke-Admin 'supprimer' @{ Destination = 'C:\Program Files\Mindset\Autre'; Exe = 'Autre.exe' } $fin
        $une = $script:Lancements.Count -eq 1
        Move-Horloge 31; Update-AttentesAdmin
        $une -and $script:RunAs.Count -eq 2 -and $script:RunAs[1] -like '*-Action supprimer*' -and $script:Lancements.Count -eq 1
    }
    Test-Cas 'demande de Windows refusée par l''utilisateur : « autorisation refusée », rien d''autre' {
        Reset-Pc $xmlSysteme -RunKo
        $script:RunAsAccepte = $false
        Invoke-Admin 'appli' $appli $fin
        $script:Fins.Count -eq 1 -and $script:Fins[0] -like 'False|*autorisation*'
    }

    # =============================================================================================================
    Write-Partie 'Demande de Windows et variables lues par .NET avant le script (audit du 25/10, constat 15)'
    # =============================================================================================================
    # (sans variable dangereuse : la demande de Windows, avec powershell.exe de System32 demandé à Windows ; sinon aucune,
    # et l'opération échoue avec un message simple qui nomme la variable)
    foreach ($cas in (Read-Corpus 'cote-mindset-variables.json' 'demande_windows', 'message')) {
        $c = $cas
        Test-Cas ([string]$c.nom) {
            Reset-Pc $null
            $script:VariablesCompte = @($c.entree.variables_compte | ForEach-Object { Expand-Texte $_ })
            $poses = @($c.entree.variables_processus | Where-Object { $_ })
            foreach ($n in $poses) { Set-Item -LiteralPath "env:$n" -Value '1' }
            try { Invoke-Admin 'appli' $appli $fin } finally { foreach ($n in $poses) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue } }
            if ($c.attendu.demande_windows) { $script:RunAs.Count -eq 1 -and $script:RunAsExe[0] -eq $PowerShellWindows }
            else { -not $script:RunAs.Count -and $script:Fins.Count -eq 1 -and $script:Fins[0] -like 'False|*' -and -not @($c.attendu.message | Where-Object { $script:Fins[0] -notlike "*$_*" }).Count }
        }
    }
    Test-Cas 'mise à jour de Mindset par la demande de Windows, variable COR_ENABLE_PROFILING : rien lancé, Mindset reste ouvert, message' {
        Reset-Pc $null
        $script:VariablesCompte = @('COR_ENABLE_PROFILING')
        $script:MajMindset = @{ Version = '9.9.9'; Zip = (Join-Path $TelechargementsDir 'm.zip'); Sig = (Join-Path $TelechargementsDir 'm.zip.sig'); Notes = '' }
        Start-MajMindsetDirecte
        -not $script:RunAs.Count -and $script:Sorties -eq 0 -and $ui.MajTexte.Text -like '*réglage inhabituel*'
    }
    Test-Cas 'contre-épreuve : la même mise à jour sans la variable passe par la demande de Windows (powershell.exe de System32)' {
        Reset-Pc $null
        $script:MajMindset = @{ Version = '9.9.9'; Zip = (Join-Path $TelechargementsDir 'm.zip'); Sig = (Join-Path $TelechargementsDir 'm.zip.sig'); Notes = '' }
        Start-MajMindsetDirecte
        $script:RunAs.Count -eq 1 -and $script:Sorties -eq 1 -and $script:RunAsExe[0] -eq $PowerShellWindows
    }

    # =============================================================================================================
    Write-Partie 'Tâches d''avant laissées par une mise à jour directe depuis Mindset 2.11.0 (audit du 25/10, constats 11 et 25e)'
    # =============================================================================================================
    foreach ($cas in (Read-Corpus 'cote-mindset-taches-anciennes.json' 'anciennes')) {
        $c = $cas
        Test-Cas ([string]$c.nom) {
            Reset-Pc $xmlSysteme
            foreach ($p in @($c.entree.taches.PSObject.Properties)) { $script:AutresTaches[$p.Name] = Get-XmlTache (Expand-Texte $p.Value.compte) (Expand-Texte $p.Value.arguments) }
            [bool](Test-TachesAnciennes) -eq [bool]$c.attendu.anciennes
        }
    }
    Test-Cas 'refaites par la tâche SYSTEM : une demande « taches » pour ce Mindset, sans demande de Windows (même si la tâche ne répond pas)' {
        Reset-Pc $xmlSysteme
        Start-RemiseEnOrdreTaches
        $c = [IO.File]::ReadAllText($FichierDemande) | ConvertFrom-Json
        $ok = $script:Lancements.Count -eq 1 -and $c.Action -eq 'taches' -and $c.Destination -eq $DossierMindset
        Move-Horloge 31; Update-AttentesAdmin
        $ok -and -not $script:RunAs.Count
    }
    Test-Cas 'tâches refaites (réponse de la tâche) : noté pour cette version de Mindset (pas redemandé au prochain démarrage)' {
        Reset-Pc $xmlSysteme
        $AppVersion = '9.9.9'
        Start-RemiseEnOrdreTaches
        $id = Set-Recu; Update-AttentesAdmin
        Set-Reponse $id $true $DossierMindset; Update-AttentesAdmin
        (Get-Setting 'TachesRefaitesPour' '') -eq '9.9.9' -and -not $script:RunAs.Count
    }
    Test-Cas 'parametres.ps1 : au démarrage, demande « taches » si une tâche d''avant est là ou si cette version ne l''a pas encore faite' {
        $t = [IO.File]::ReadAllText((Join-Path $fichiers 'modules\parametres.ps1'), [Text.Encoding]::UTF8)
        $t -match "TachesRefaitesPour' ''\) -ne \`$AppVersion -or \(Test-TachesAnciennes\)\)\) \{\s+Start-RemiseEnOrdreTaches"
    }
    Test-Cas 'Mindset.ps1 ne lance plus la très vieille tâche « \Mindset\Mindset » (elle ouvrait Mindset en administrateur)' {
        $t = [IO.File]::ReadAllText((Join-Path $fichiers 'Mindset.ps1'), [Text.Encoding]::UTF8)
        $t -notmatch '/Run /TN ''\\Mindset\\Mindset'''
    }

    # =============================================================================================================
    Write-Partie 'Remplacement de l''ancienne tâche (mise à jour depuis Mindset 2.9.0)'
    # =============================================================================================================
    Test-Cas 'l''ancienne tâche reçoit une seule demande : « taches » (se remplacer), sans demande de Windows' {
        Reset-Pc $xmlAncienne
        $script:Remplace = $null
        Start-RemplacementTache { param($Ok) $script:Remplace = $Ok }
        $c = [IO.File]::ReadAllText($FichierDemande) | ConvertFrom-Json
        $script:Lancements.Count -eq 1 -and $c.Action -eq 'taches' -and $c.Destination -eq $DossierMindset -and -not $script:RunAs.Count
    }
    Test-Cas 'remplacée : la tâche SYSTEM est ensuite utilisée' {
        $id = Set-Recu; Update-AttentesAdmin
        $script:XmlTache = $xmlSysteme
        Set-Reponse $id $true $DossierMindset; Update-AttentesAdmin
        $script:Remplace -eq $true -and (Test-TacheInstallation)
    }
    Test-Cas 'pas remplacée (l''ancienne tâche ne répond pas) : aucune demande de Windows au démarrage, et rien d''autre ne passe par elle' {
        Reset-Pc $xmlAncienne
        $script:Remplace = $null
        Start-RemplacementTache { param($Ok) $script:Remplace = $Ok }
        Move-Horloge 31; Update-AttentesAdmin
        Invoke-Admin 'appli' $appli $fin
        $script:Remplace -eq $false -and $script:Lancements.Count -eq 1 -and $script:RunAs.Count -eq 1
    }

    # =============================================================================================================
    Write-Partie 'Mise à jour de Mindset lui-même'
    # =============================================================================================================
    $script:MajMindset = @{ Version = '9.0.0'; Zip = (Join-Path $TelechargementsDir 'mindset.zip'); Sig = (Join-Path $TelechargementsDir 'mindset.zip.sig'); Notes = '' }
    $script:Occupe = @{}
    Test-Cas 'par la tâche : Mindset ne se ferme qu''à l''accusé de réception' {
        Reset-Pc $xmlSysteme
        Start-MajMindset
        $avant = $script:Sorties
        $id = Set-Recu; Update-AttentesAdmin
        $avant -eq 0 -and $script:Sorties -eq 1 -and (Get-Setting 'MajMindsetDemande' '') -eq $id -and -not $script:RunAs.Count
    }
    Test-Cas 'demandée à l''écran : Mindset reviendra avec sa fenêtre ; automatique : caché' {
        Reset-Pc $xmlSysteme; Start-MajMindset; $vu = (Get-Setting 'MajMindsetVisible' $null) -eq $true
        Reset-Pc $xmlSysteme; Start-MajMindset -Cache; $vu -and (Get-Setting 'MajMindsetVisible' $null) -eq $false
    }
    Test-Cas 'tâche muette : Mindset ne se ferme pas, la demande est retirée, puis la demande de Windows (avec l''utilisateur)' {
        Reset-Pc $xmlSysteme
        Start-MajMindset
        Move-Horloge 29; Update-AttentesAdmin
        $ouvert = $script:Sorties -eq 0
        Move-Horloge 2; Update-AttentesAdmin
        $ouvert -and $script:RunAs.Count -eq 1 -and $script:RunAs[0] -like '*-Action mindset-maj*' -and $script:RunAs[0] -like "*-Sid $moi*" -and $script:Sorties -eq 1 -and -not (Test-Path -LiteralPath $FichierDemande)
    }
    Test-Cas 'tâche refusée : la demande de Windows tout de suite' {
        Reset-Pc $xmlSysteme -RunKo
        Start-MajMindset
        $script:RunAs.Count -eq 1 -and $script:RunAs[0] -like '*-Action mindset-maj*'
    }
    Test-Cas 'mise à jour automatique (caché), tâche muette : pas de demande de Windows, Mindset reste ouvert' {
        Reset-Pc $xmlSysteme
        Start-MajMindset -Cache
        Move-Horloge 31; Update-AttentesAdmin
        -not $script:RunAs.Count -and $script:Sorties -eq 0
    }
    Test-Cas 'mise à jour automatique à l''écran (-Auto, personne au PC), tâche muette : pas de demande de Windows, il reviendra à l''écran, l''échec est gardé pour la console' {
        Reset-Pc $xmlSysteme; $script:MajAutoEchecs = @{}
        Start-MajMindset -Auto
        $visible = (Get-Setting 'MajMindsetVisible' $null) -eq $true
        Move-Horloge 31; Update-AttentesAdmin
        $visible -and -not $script:RunAs.Count -and $script:Sorties -eq 0 -and $script:MajAutoEchecs['mindset'].Version -eq '9.0.0' -and $script:MajAutoEchecs['mindset'].Raison -match 'outil d''installation'
    }
    Test-Cas '« Réessayer » (à la main, sans -Auto) : l''échec n''est plus montré' {
        Reset-Pc $xmlSysteme
        Start-MajMindset
        -not $script:MajAutoEchecs['mindset']
    }
    Test-Cas 'deux clics sur « Mettre à jour » : une seule demande envoyée' {
        Reset-Pc $xmlSysteme
        Start-MajMindset; Start-MajMindset
        $script:Lancements.Count -eq 1
    }

    # =============================================================================================================
    Write-Partie 'Ligne de commande de la demande de Windows (revue du 25/10, constat 19)'
    # =============================================================================================================
    $exeArgs = Join-Path $tmp 'args.exe'
    foreach ($cas in (Read-Corpus 'cote-mindset-arguments.json' 'texte', 'refuse', 'relu')) {
        $c = $cas
        Test-Cas ([string]$c.nom) {
            $val = Expand-Texte $c.entree.valeur
            if ($c.attendu.refuse) { $refus = $false; try { $null = Format-ArgumentAdmin $val } catch { $refus = $true }; return $refus }
            $f = Format-ArgumentAdmin $val
            $ok = $true
            if ($null -ne $c.attendu.texte) { $ok = $ok -and $f -eq (Expand-Texte $c.attendu.texte) }
            if ($c.attendu.relu) {
                if (-not (Test-Path -LiteralPath $exeArgs)) {
                    Add-Type -OutputType ConsoleApplication -OutputAssembly $exeArgs -TypeDefinition 'public static class A { public static void Main(string[] a) { System.Console.OutputEncoding = new System.Text.UTF8Encoding(false); System.Console.WriteLine(string.Join("|", a)); } }'
                }
                # (Start-Process joint la liste par des espaces, et Windows la redécoupe : la même chose ici)
                $psi = New-Object Diagnostics.ProcessStartInfo $exeArgs, ((@('-Source', $f, '-Version', '2.9.0', '-Sid', $moi)) -join ' ')
                $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true; $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
                $p = [Diagnostics.Process]::Start($psi); $vu = $p.StandardOutput.ReadToEnd().Trim(); $p.WaitForExit()
                $ok = $ok -and $vu -eq "-Source|$val|-Version|2.9.0|-Sid|$moi"
            }
            $ok
        }
    }

    # =============================================================================================================
    Write-Partie 'Plus de code fabriqué avec des données (revue du 25/10, constat 10)'
    # =============================================================================================================
    Test-Cas 'accueil.ps1 et installations.ps1 : plus aucun [scriptblock]::Create avec des valeurs' {
        $n = 0
        foreach ($f in 'accueil.ps1', 'installations.ps1') { $n += ([regex]::Matches([IO.File]::ReadAllText((Join-Path $fichiers "modules\$f")), '\[scriptblock\]::Create\(')).Count }
        $n -eq 0
    }
    Test-Cas 'un dossier « D:\Jeux d''Arthur\$(...) » (apostrophe typographique) arrive tel quel, sans rien exécuter' {
        $script:Execute = $false; $script:Recu = $null
        $dossier = "D:\Jeux d$($apo)Arthur\`$(`$script:Execute = `$true)$apo ; `$script:Execute = `$true ; $apo"
        $sb = New-Action @{ Id = 'nevermind'; Dossier = $dossier } { $script:Recu = "$($v.Id)|$($v.Dossier)" }
        & $sb
        $script:Recu -eq "nevermind|$dossier" -and -not $script:Execute
    }
    Test-Cas 'avec des paramètres (fin d''une tâche de fond) : les valeurs et les paramètres arrivent' {
        $script:Recu = $null
        $m = "l$($apo)essai `$(x) `"ok`""
        $sb = New-Action @{ Message = $m } { $script:Recu = "$Ok|$Message|$($v.Message)" } 'Ok', 'Message'
        & $sb $true 'fini'
        $script:Recu -eq "True|fini|$m"
    }
    Test-Cas 'chaque entrée est retirée quand elle sert (un second appel ne fait rien)' {
        $script:Actions.Clear(); $script:Compte = 0
        $sb = New-Action @{ A = 1 } { $script:Compte++ }
        $un = $script:Actions.Count -eq 1
        & $sb; & $sb
        $un -and $script:Actions.Count -eq 0 -and $script:Compte -eq 1
    }
    Test-Cas 'confirmations jamais utilisées : la table ne garde pas plus de 200 entrées' {
        $script:Actions.Clear()
        foreach ($i in 1..250) { $null = New-Action @{ I = $i } { } }
        $script:Actions.Count -eq 200
    }
    Test-Cas 'aucune fonction définie deux fois dans les modules (la dernière chargée cacherait l''autre)' {
        $vues = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $fichiers 'modules') -Filter '*.ps1' -File)) {
            $e = $null
            $a = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
            foreach ($x in @($a.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))) { $vues[$x.Name] = @($vues[$x.Name]) + $f.Name | Where-Object { $_ } }
        }
        $doubles = @($vues.Keys | Where-Object { @($vues[$_]).Count -gt 1 } | ForEach-Object { "$_ ($(@($vues[$_]) -join ', '))" })
        if ($doubles.Count) { $script:Journal.Add("JOURNAL en double : $($doubles -join ' ; ')") }
        -not $doubles.Count
    }
    Test-Cas 'dans l''ordre de chargement de Mindset.ps1, New-Action est la table des valeurs de taches.ps1 (pas le bouton de l''accueil)' {
        $ordre = if ([IO.File]::ReadAllText((Join-Path $fichiers 'Mindset.ps1'), [Text.Encoding]::UTF8) -match '(?m)^\$msModules = (.+)$') { @([regex]::Matches($Matches[1], "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value }) } else { @() }
        $derniere = ''
        foreach ($m in $ordre) {
            $e = $null
            $a = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $fichiers "modules\$m.ps1"), [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
            if (@($a.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-Action' }, $false)).Count) { $derniere = $m }
        }
        $ordre.Count -gt 10 -and $derniere -eq 'taches'
    }
    Test-Cas 'un nom de paramètre qui n''est pas un simple mot : refusé' {
        $refus = $false; try { $null = New-Action @{} { } 'Ok)', 'x' } catch { $refus = $true }; $refus
    }
} finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch { Write-Host "Dossier de test non supprimé : $tmp" -ForegroundColor Yellow }
}

$total = $script:Reussis + $script:Echoues.Count
Write-Host ''
if ($script:Echoues.Count) {
    Write-Host "Résultat : $($script:Echoues.Count) échec(s) sur $total cas." -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Résultat : $($script:Reussis) cas réussis sur $total, aucun échec." -ForegroundColor Green
exit 0
