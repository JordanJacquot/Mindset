# Mindset : le mini-installateur essayé en vrai, sur la machine jetable de GitHub Actions (workflow
# .github\workflows\installateur-reel.yml, lancé à la main). Vraies tâches planifiées, vrais comptes Windows, vrai
# registre, vraie installation de Mindset : JAMAIS sur un vrai PC. Le script refuse de tourner hors de GitHub Actions.
#
#   .\outils\essai-installateur-reel.ps1 -Cas 0     préparation (Mindset construit, clé de TEST, zips signés, Releases)
#   .\outils\essai-installateur-reel.ps1 -Cas N     un cas (1 à 10), voir la liste plus bas
#
# Côté Mindset, ce sont ses vraies fonctions (modules\installations.ps1, mindset.ps1), lues dans la copie installée et
# lancées sous le compte voulu (« client », -Client) : rien n'est simulé sauf la fenêtre où l'on clique « Oui » (pour un
# compte standard, l'administrateur y tape son mot de passe : seul son résultat est reproduit, la commande exacte que
# Mindset aurait passée à Windows lancée par l'administrateur).
# La clé de signature est une clé RSA de TEST créée ici, ajoutée aux clés publiques des copies d'essai seulement.
#
#   1. installation sur C:, puis sur D:\Mindset, puis une vraie demande passée par la tâche SYSTEM
#   2. mise à jour depuis la Release v2.9.0 : l'ancienne tâche « droits les plus élevés » remplacée par la tâche SYSTEM
#   3. la même depuis la Release v2.7.0
#   4. mise à jour avec Mindset caché (Cache=1) sur runneradmin : relancé par sa tâche de démarrage, sans boucle
#   5. un compte standard au nom accentué (« Élodie Test »), installé par un administrateur
#   6. ce compte lit et lance la tâche, et sa demande passe
#   7. deux comptes standard sur le même PC : seuls les programmes du bon compte sont fermés
#   8. tâche SYSTEM absente, désactivée ou cassée : la demande de Windows prend le relais, l'ancienne tâche ne tourne jamais
#   9. désinstallation (désinstalleur autonome, puis par la tâche) : plus aucune tâche \Mindset\
#  10. la tâche SYSTEM ne reprend ni les variables d'environnement ni le PSModulePath de l'utilisateur (contre-épreuve :
#      un programme lancé sous son compte les voit)
# Code de sortie 1 si un cas échoue.
param([int]$Cas = -1, [string]$Client)

if ($env:GITHUB_ACTIONS -ne 'true') {
    Write-Host 'Refusé : cet essai crée des comptes Windows et des tâches planifiées, et installe Mindset pour de vrai. Il ne tourne que sur la machine jetable de GitHub Actions.' -ForegroundColor Red
    exit 2
}
$ErrorActionPreference = 'Stop'
$Racine = 'C:\essai'
$PowerShellExe = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
$CleInstallation = 'HKLM:\SOFTWARE\Mindset\Installation'
$CleDesinstall = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset'
$NomTache = 'Mindset (installation)'

# Les fonctions de Mindset, lues dans ses fichiers (comme outils\tester-mini-installateur.ps1)
$script:Manquantes = @()
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($Fichier, [Text.Encoding]::UTF8), [ref]$null, [ref]$e)
    foreach ($n in $Noms) {
        $x = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true)) | Select-Object -First 1
        if (-not $x) { $script:Manquantes += "$(Split-Path $Fichier -Leaf) : $n"; continue }
        . ([scriptblock]::Create($x.Extent.Text))
        Set-Item -Path "function:script:$($x.Name)" -Value (Get-Item "function:$($x.Name)").ScriptBlock
    }
}

# =====================================================================================================================
# Le client : Mindset (ses vraies fonctions) sous le compte qui l'a lancé. Il lit sa consigne dans le fichier -Client
# (JSON) et écrit ce qui s'est passé dans le fichier Sortie.
# =====================================================================================================================
if ($Client) {
    $ErrorActionPreference = 'Continue'   # (comme Mindset : rien ne règle ce choix dans Mindset.ps1)
    $cfg = [IO.File]::ReadAllText($Client, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $script:Fins = New-Object Collections.ArrayList
    $script:RunAs = New-Object Collections.ArrayList
    $script:JournalClient = New-Object Collections.ArrayList
    $script:Reglages = @{}
    $script:Sorties = 0
    $script:Remplace = $null
    $sortie = [ordered]@{ Compte = [Security.Principal.WindowsIdentity]::GetCurrent().Name; Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Pid = $PID; Etat = ''; Erreur = '' }
    $debut = [DateTime]::Now
    try {
        $AppDir = Split-Path $cfg.Modules -Parent
        $DossierMindset = Split-Path $AppDir -Parent
        $DataDir = [string]$cfg.DataDir
        $TelechargementsDir = Join-Path $DataDir 'telechargements'
        $FichierDemande = Join-Path $DataDir 'installation.demande'
        $FichierMajMindset = Join-Path $TelechargementsDir 'maj-mindset.json'
        $MindsetAdmin = $false
        $TacheInstallation = '\Mindset\Mindset (installation)'
        $SchtasksExe = Join-Path ([Environment]::GetFolderPath('System')) 'schtasks.exe'
        $CleInstallationAdmin = $CleInstallation
        $DelaiAccuseTache = 30
        $script:MajAuto = @{}
        $script:Occupe = @{}
        $script:AttentesAdmin = New-Object System.Collections.ArrayList
        $script:DemandesEnAttente = New-Object System.Collections.ArrayList
        $script:Actions = New-Object System.Collections.Specialized.OrderedDictionary
        $script:AdminTimer = [pscustomobject]@{ Marche = $false }
        $script:AdminTimer | Add-Member ScriptMethod Start { $this.Marche = $true }
        $script:AdminTimer | Add-Member ScriptMethod Stop { $this.Marche = $false }
        $ui = @{}; foreach ($n in 'MajTitre', 'MajTexte', 'BtnMajMindset', 'BtnMajFermer', 'MajBandeau', 'AdminBandeau') { $ui[$n] = [pscustomobject]@{ Text = ''; Content = ''; Visibility = 'Collapsed' } }
        function Write-Log([string]$T) { [void]$script:JournalClient.Add($T) }
        function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur }
        function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.ContainsKey($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
        function Set-MajMindsetAttendue { }
        function Exit-Mindset { $script:Sorties++ }
        # La demande de Windows : notée ; faite pour de vrai seulement si la consigne le dit (runneradmin : Windows
        # l'accepte sans question). Sinon (compte standard : l'administrateur doit taper son mot de passe), elle est
        # refusée ici et sa ligne de commande est rendue, pour que l'essai la lance en administrateur.
        function Start-Process {
            param([string]$FilePath, $ArgumentList, [string]$Verb, [string]$WindowStyle, [string]$WorkingDirectory, [switch]$PassThru)
            if ($Verb -ne 'RunAs') { throw "lancement inattendu : $FilePath" }
            [void]$script:RunAs.Add((@($ArgumentList) -join ' '))
            if (-not $cfg.RunAsReel) { throw 'demande de Windows : pas de réponse ici' }
            Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Verb RunAs -WindowStyle Hidden -WorkingDirectory $WorkingDirectory -PassThru -ErrorAction Stop
        }
        $fin = { param($Ok, $Message) [void]$script:Fins.Add("$Ok|$Message") }

        foreach ($f in @($cfg.Copier)) {
            if (-not $f) { continue }
            New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
            Copy-Item -LiteralPath $f -Destination $TelechargementsDir -Force -ErrorAction Stop
        }
        $installations = Join-Path $cfg.Modules 'installations.ps1'
        $mindset = Join-Path $cfg.Modules 'mindset.ps1'
        if ($cfg.Mode -eq 'maj-ancienne') {
            # Mindset d'avant (2.9.0, 2.7.0) : ses fonctions à lui
            Import-Fonctions $installations @('Test-TacheInstallation')
            Import-Fonctions $mindset @('Start-MajMindset')
        } else {
            Import-Fonctions $installations @('Get-EtatTacheInstallation', 'Test-TacheInstallation', 'Remove-DemandeInstallation', 'Get-ValeurInstallation', 'Send-DemandeInstallation',
                'Skip-TacheInstallation', 'Invoke-Admin', 'Format-ArgumentAdmin', 'Invoke-AdminDirect', 'Send-DemandeSuivante', 'Update-AttentesAdmin', 'Start-RemplacementTache')
            Import-Fonctions $mindset @('Start-MajMindset', 'Start-MajMindsetDirecte')
            $sortie.Etat = Get-EtatTacheInstallation
        }
        if ($script:Manquantes.Count) { throw "Fonctions absentes : $($script:Manquantes -join ', ')" }

        $parametres = @{}
        if ($cfg.Parametres) { foreach ($p in $cfg.Parametres.PSObject.Properties) { $parametres[$p.Name] = [string]$p.Value } }
        if ($cfg.AttendreMoi) { $parametres['AttendrePid'] = [string]$PID }
        $max = if ($cfg.Max) { [int]$cfg.Max } else { 240 }
        $attendre = {
            param([scriptblock]$Fini)
            while (([DateTime]::Now - $debut).TotalSeconds -lt $max) {
                if (& $Fini) { return }
                if ($script:AttentesAdmin.Count) { Update-AttentesAdmin }
                Start-Sleep -Milliseconds 500
            }
            Write-Log "(client : délai de $max secondes dépassé)"
        }
        switch ([string]$cfg.Mode) {
            'droits' {
                # Lire, lancer (sans demande : la tâche n'a rien à faire), modifier (refusé attendu)
                $null = & $SchtasksExe /Query /TN $TacheInstallation /XML 2>&1; $sortie.CodeLire = $LASTEXITCODE
                if ($cfg.Lancer) { $null = & $SchtasksExe /Run /TN $TacheInstallation 2>&1; $sortie.CodeLancer = $LASTEXITCODE }
                $null = & $SchtasksExe /Change /TN $TacheInstallation /DISABLE 2>&1; $sortie.CodeModifier = $LASTEXITCODE
                $essai = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) "Mindset\essai-$PID.txt"
                $sortie.EcritProgrammes = $false
                try { [IO.File]::WriteAllText($essai, 'x'); $sortie.EcritProgrammes = $true; Remove-Item -LiteralPath $essai -Force } catch {}
            }
            'invoke' {
                Invoke-Admin ([string]$cfg.Action) $parametres $fin
                $sortie.Lancee = [bool]@($script:AttentesAdmin | Where-Object { $_.Id }).Count
                if ($cfg.SortirApresRecu) {
                    & $attendre { @($script:AttentesAdmin | Where-Object { $_.Recu }).Count -or $script:Fins.Count }
                } elseif (-not $cfg.SansAttente) {
                    & $attendre { $script:Fins.Count -and -not $script:AttentesAdmin.Count -and -not $script:DemandesEnAttente.Count }
                }
            }
            'maj' {
                $script:MajMindset = @{ Version = [string]$cfg.Version; Zip = (Join-Path $TelechargementsDir 'mindset.zip'); Sig = (Join-Path $TelechargementsDir 'mindset.zip.sig'); Notes = '' }
                if ($cfg.Cache) { Start-MajMindset -Cache } else { Start-MajMindset }
                & $attendre { $script:Sorties -or $script:Fins.Count -or $script:RunAs.Count }
            }
            'maj-ancienne' {
                $script:MajMindset = @{ Version = [string]$cfg.Version; Zip = (Join-Path $TelechargementsDir 'mindset.zip'); Sig = (Join-Path $TelechargementsDir 'mindset.zip.sig'); Notes = '' }
                Start-MajMindset
            }
            'remplacement' {
                $script:EtatTacheInstallation = $sortie.Etat
                Start-RemplacementTache { param($Ok) $script:Remplace = [bool]$Ok }
                & $attendre { $null -ne $script:Remplace }
                $script:TacheInstallationOk = $null
                $sortie.EtatApres = Get-EtatTacheInstallation
            }
            default { throw "Mode inconnu : $($cfg.Mode)" }
        }
    } catch { $sortie.Erreur = "$($_.Exception.Message) $($_.ScriptStackTrace)" }
    $sortie.Fins = @($script:Fins); $sortie.RunAs = @($script:RunAs); $sortie.Journal = @($script:JournalClient)
    $sortie.Sorties = $script:Sorties; $sortie.Remplace = $script:Remplace; $sortie.Demande = [string]$script:Reglages['MajMindsetDemande']
    $sortie.Duree = [math]::Round(([DateTime]::Now - $debut).TotalSeconds, 1)
    [IO.File]::WriteAllText([string]$cfg.Sortie, ($sortie | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    exit 0
}

# =====================================================================================================================
# L'essai (en runneradmin, administrateur)
# =====================================================================================================================
$Depot = Join-Path $Racine 'depot'                       # copie du dépôt, construite (Mindset.exe, désinstalleur)
$Source = Join-Path $Depot 'Mindset'                     # le Mindset à installer (avec la clé publique de TEST)
$Paquets = Join-Path $Racine 'paquets'                   # zips signés avec la clé de TEST
$Sorties = Join-Path $Racine 'sorties'
$VersionMaj = '9.9.1'                                    # la version du zip de mise à jour (plus récente que tout)
$Moi = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

$script:Reussis = 0
$script:Echoues = New-Object Collections.Generic.List[string]
$script:Notes = New-Object Collections.Generic.List[string]
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }
function Add-Note([string]$Texte) { $script:Notes.Add($Texte); Write-Host "  NOTE   $Texte" -ForegroundColor Yellow }
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = "$($_.Exception.Message) $($_.ScriptStackTrace)" }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
    } else {
        $script:Echoues.Add($Nom)
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
        Show-Diagnostic
    }
}
function Show-Diagnostic {
    try {
        Write-Host '         | tâches \Mindset\ :' -ForegroundColor DarkGray
        foreach ($t in @(Get-ScheduledTask -TaskPath '\Mindset\' -ErrorAction SilentlyContinue)) {
            $i = Get-ScheduledTaskInfo -TaskPath '\Mindset\' -TaskName $t.TaskName -ErrorAction SilentlyContinue
            Write-Host "         |   $($t.TaskName) [$($t.State)] compte $($t.Principal.UserId) $($t.Principal.LogonType) $($t.Principal.RunLevel) ; dernier lancement $($i.LastRunTime) code $($i.LastTaskResult)" -ForegroundColor DarkGray
            Write-Host "         |     $($t.Actions[0].Execute) $($t.Actions[0].Arguments)" -ForegroundColor DarkGray
        }
        $v = Get-ItemProperty -Path $CleInstallation -ErrorAction SilentlyContinue
        if ($v) { Write-Host "         | registre : Recu=$($v.Recu) Resultat=$($v.Resultat) Restes=$($v.Restes)" -ForegroundColor DarkGray }
        foreach ($e in @(Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 12 -ErrorAction SilentlyContinue)) {
            Write-Host "         | évènement $($e.Id) $($e.TimeCreated.ToString('HH:mm:ss')) $(($e.Message -split "`n")[0])" -ForegroundColor DarkGray
        }
    } catch {}
}

function Read-Json([string]$Fichier) {
    if (-not (Test-Path -LiteralPath $Fichier)) { return $null }
    try { [IO.File]::ReadAllText($Fichier, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $null }
}
function Write-Utf8([string]$Fichier, [string]$Texte) { [IO.File]::WriteAllText($Fichier, $Texte, (New-Object Text.UTF8Encoding $false)) }
function Wait-Jusque([scriptblock]$Condition, [int]$Secondes = 60) {
    $limite = (Get-Date).AddSeconds($Secondes)
    while ((Get-Date) -lt $limite) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 500 }
    [bool](& $Condition)
}

# Signature avec la clé de TEST (jamais la vraie : elle ne quitte pas le PC de Jordan)
function New-Signature([string]$Fichier) {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString([IO.File]::ReadAllText((Join-Path $Racine 'cle\privee-test.xml')))
        [IO.File]::WriteAllBytes("$Fichier.sig", $rsa.SignData([IO.File]::ReadAllBytes($Fichier), [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')))
    } finally { $rsa.Dispose() }
}

# Un compte Windows local de test (créé, ou mot de passe renouvelé), avec son profil
function Get-Compte([string]$Nom, [switch]$Admin) {
    $mdp = 'Aa1!' + [guid]::NewGuid().ToString('N').Substring(0, 14)
    $s = ConvertTo-SecureString $mdp -AsPlainText -Force
    $u = Get-LocalUser -Name $Nom -ErrorAction SilentlyContinue
    if ($u) { Set-LocalUser -Name $Nom -Password $s } else { $u = New-LocalUser -Name $Nom -Password $s -PasswordNeverExpires -AccountNeverExpires }
    if ($Admin -and -not @(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.SID.Value -eq $u.SID.Value }).Count) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $Nom }
    $cred = New-Object Management.Automation.PSCredential(".\$Nom", $s)
    $p = Microsoft.PowerShell.Management\Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', 'exit' -Credential $cred -LoadUserProfile -WorkingDirectory $Racine -PassThru -WindowStyle Hidden
    [void]$p.WaitForExit(60000)
    $sid = $u.SID.Value
    $profil = [string](Get-Item -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").GetValue('ProfileImagePath')
    @{ Nom = $Nom; Sid = $sid; Mdp = $mdp; Cred = $cred; Profil = $profil; Donnees = (Join-Path $profil 'AppData\Local\Mindset\Mindset') }
}
function Get-Runneradmin {
    $profil = [string](Get-Item -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Moi").GetValue('ProfileImagePath')
    @{ Nom = $env:USERNAME; Sid = $Moi; Cred = $null; Profil = $profil; Donnees = (Join-Path $profil 'AppData\Local\Mindset\Mindset') }
}

# Le client (Mindset) sous le compte $Compte (runneradmin si $Compte.Cred est vide). Rend sa sortie.
function Invoke-Client($Compte, [hashtable]$Consigne) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $Consigne.Sortie = Join-Path $Sorties "client-$id.json"
    $f = Join-Path $Racine "clients\client-$id.json"
    Write-Utf8 $f ($Consigne | ConvertTo-Json -Depth 4)
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Racine 'lancer.ps1')`"", '-Client', "`"$f`"")
    if ($Compte.Cred) { $p = Microsoft.PowerShell.Management\Start-Process -FilePath $PowerShellExe -ArgumentList $a -Credential $Compte.Cred -LoadUserProfile -WorkingDirectory $Racine -PassThru -WindowStyle Hidden }
    else { $p = Microsoft.PowerShell.Management\Start-Process -FilePath $PowerShellExe -ArgumentList $a -WorkingDirectory $Racine -PassThru -WindowStyle Hidden }
    $script:DernierClientPid = $p.Id
    if (-not $p.WaitForExit(420000)) { try { $p.Kill() } catch {}; Write-Host '         | client arrêté (trop long)' -ForegroundColor DarkGray }
    $s = Read-Json $Consigne.Sortie
    if (-not $s) { Write-Host "         | client $($Consigne.Mode) ($($Compte.Nom)) : pas de sortie" -ForegroundColor DarkGray; return [pscustomobject]@{ Erreur = 'pas de sortie'; Fins = @(); RunAs = @(); Journal = @(); Etat = '' } }
    Write-Host "         | client $($Consigne.Mode) ($($s.Compte), $($s.Duree) s) : état « $($s.Etat) », fins [$(@($s.Fins) -join ' / ')], demandes de Windows $(@($s.RunAs).Count)$(if ($s.Erreur) { ", ERREUR $($s.Erreur)" })" -ForegroundColor DarkGray
    foreach ($l in @($s.Journal)) { Write-Host "         |   journal : $l" -ForegroundColor DarkGray }
    $s
}

# Remet la machine à zéro : ni Mindset, ni tâche \Mindset\, ni registre de Mindset, ni données
function Reset-Machine {
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $c = [string]$p.ExecutablePath
        if ($c -like "$env:ProgramFiles\Mindset\*" -or $c -like 'D:\Mindset\*' -or $c -like "$env:ProgramFiles\MindsetEssaiEnv\*") { try { Stop-Process -Id $p.ProcessId -Force } catch {} }
    }
    Start-Sleep -Milliseconds 500
    foreach ($d in '\Mindset\', '\MindsetEssai\') {
        foreach ($t in @(Get-ScheduledTask -TaskPath $d -ErrorAction SilentlyContinue)) { Unregister-ScheduledTask -TaskPath $d -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
        try { $s = New-Object -ComObject Schedule.Service; $s.Connect(); $s.GetFolder('\').DeleteFolder($d.Trim('\'), 0) } catch {}
    }
    foreach ($d in "$env:ProgramFiles\Mindset", 'D:\Mindset', "$env:ProgramFiles\MindsetEssaiEnv") {
        if (Test-Path -LiteralPath $d) { & "$env:SystemRoot\System32\takeown.exe" /F $d /R /D Y 2>&1 | Out-Null; & "$env:SystemRoot\System32\icacls.exe" $d /reset /T /C /Q 2>&1 | Out-Null; Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($c in 'HKLM:\SOFTWARE\Mindset', $CleDesinstall) { Remove-Item -Path $c -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($u in @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath (Join-Path $u.FullName 'AppData\Local\Mindset') -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -Path "$env:TEMP\mindset-*.marque" -Force -ErrorAction SilentlyContinue
}

# Installe Mindset comme le fait la demande de Windows acceptée (installer-admin.ps1 -Action mindset, en administrateur)
function Install-MindsetDirect([string]$Sid, [string]$Disque = '', [string]$Dossier = $Source, [string]$Version = '2.9.0') {
    $f = Join-Path $Sorties "install-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Dossier 'fichiers\installer-admin.ps1'), '-Action', 'mindset', '-Source', $Dossier, '-Version', $Version, '-Sid', $Sid, '-Resultat', $f)
    if ($Disque) { $a += @('-Disque', $Disque) }
    & $PowerShellExe @a | Out-Host
    $r = Read-Json $f
    Write-Host "         | installation ($Version, pour $Sid$(if ($Disque) { ", disque $Disque" })) : $($r.ok) $($r.message)" -ForegroundColor DarkGray
    $r
}
# Les tâches de Mindset refaites (installer-admin.ps1 -Action taches, en administrateur)
function Register-TachesDirect([string]$Dossier, [string]$Sid) {
    $f = Join-Path $Sorties "taches-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dossier 'fichiers\installer-admin.ps1') -Action taches -Destination $Dossier -Sid $Sid -Resultat $f | Out-Host
    Read-Json $f
}

# Ce que Windows dit d'une tâche (XML exporté, droits, dernier lancement)
function Get-InfoTache([string]$Nom, [string]$Dossier = '\Mindset\') {
    $xml = $null
    try { $xml = [xml](Export-ScheduledTask -TaskPath $Dossier -TaskName $Nom -ErrorAction Stop) } catch { return $null }
    $pr = $xml.Task.Principals.Principal
    $i = Get-ScheduledTaskInfo -TaskPath $Dossier -TaskName $Nom -ErrorAction SilentlyContinue
    $sddl = ''
    try { $s = New-Object -ComObject Schedule.Service; $s.Connect(); $sddl = $s.GetFolder($Dossier.TrimEnd('\')).GetTask($Nom).GetSecurityDescriptor(4) } catch {}
    [pscustomobject]@{
        Compte = [string]$pr.UserId; LogonType = [string]$pr.LogonType; RunLevel = $(if ([string]$pr.RunLevel) { [string]$pr.RunLevel } else { 'LeastPrivilege' })
        Commande = [string]$xml.Task.Actions.Exec.Command; Arguments = [string]$xml.Task.Actions.Exec.Arguments
        Active = ([string]$xml.Task.Settings.Enabled -ne 'false'); Dernier = $(if ($i) { $i.LastRunTime } else { $null }); Code = $(if ($i) { $i.LastTaskResult } else { $null })
        Sddl = [string]$sddl; Xml = $xml.OuterXml
    }
}
function ConvertTo-Sid([string]$Compte) {
    if ($Compte -match '^S-1-') { return $Compte }
    try { (New-Object Security.Principal.NTAccount($Compte)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
}
# Les droits sur la tâche : le système et les administrateurs, et l'utilisateur $Sid en lecture et lancement (FRFX,
# que Windows rend en 0x1200a9) ; personne d'autre. (« LA » : le compte Administrateur intégré, runneradmin ici.)
function Test-DroitsTache([string]$Sddl, [string]$Sid) {
    $lui = $false
    foreach ($m in [regex]::Matches($Sddl, '\(([A-Z]+);[^;]*;([^;]*);[^;]*;[^;]*;([^)]+)\)')) {
        $type = $m.Groups[1].Value; $droits = $m.Groups[2].Value; $qui = $m.Groups[3].Value
        $qui = switch ($qui) { 'SY' { 'S-1-5-18' } 'BA' { 'S-1-5-32-544' } 'LA' { if ($Sid -match '-500$') { $Sid } else { 'LA' } } default { $qui } }
        if ($type -ne 'A') { continue }
        if ($qui -in 'S-1-5-18', 'S-1-5-32-544') { continue }
        if ($qui -eq $Sid -and $droits -in 'FRFX', '0x1200a9') { $lui = $true; continue }
        Write-Host "         | droit de trop sur la tâche : $($m.Value)" -ForegroundColor DarkGray
        return $false
    }
    $lui
}
# La tâche SYSTEM du mini-installateur, inscrite pour $Sid, avec ce fichier de demande
function Test-TacheSysteme([string]$Sid, [string]$Demande, [string]$Script) {
    $t = Get-InfoTache $NomTache
    if (-not $t) { Write-Host '         | tâche absente' -ForegroundColor DarkGray; return $false }
    Write-Host "         | tâche : $($t.Compte) $($t.LogonType) $($t.RunLevel) ; $($t.Arguments) ; $($t.Sddl)" -ForegroundColor DarkGray
    (ConvertTo-Sid $t.Compte) -eq 'S-1-5-18' -and $t.RunLevel -eq 'HighestAvailable' -and $t.Arguments.Contains("-Sid $Sid ") -and $t.Arguments.Contains("-Demande `"$Demande`"") -and
        $t.Arguments.Contains("-File `"$Script`"") -and (Test-DroitsTache $t.Sddl $Sid)
}
function Get-Valeur([string]$Nom) { try { [string](Get-ItemProperty -Path $CleInstallation -Name $Nom -ErrorAction Stop).$Nom } catch { '' } }
function Get-VersionInstallee([string]$Dossier) {
    $f = Join-Path $Dossier 'fichiers\Mindset.ps1'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    if ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) -match "(?m)^\`$AppVersion = '([\d.]+)'") { $Matches[1] } else { '' }
}
# Les programmes qui tournent depuis $Dossier : PID, compte (SID), session
function Get-ProgrammesDans([string]$Dossier) {
    $dans = $Dossier.TrimEnd('\') + '\'
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if (-not $p.ExecutablePath -or -not ([string]$p.ExecutablePath).StartsWith($dans, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $sid = ''; try { $sid = [string](Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid } catch {}
        [pscustomobject]@{ Id = [int]$p.ProcessId; Sid = $sid; Session = [int]$p.SessionId; Chemin = [string]$p.ExecutablePath }
    }
}
$ProgrammesC = Join-Path $env:ProgramFiles 'Mindset'
$MindsetC = Join-Path $ProgrammesC 'Mindset'
# Une demande « appli » : l'appli d'essai (Essai.exe, et sa partie administrateur EssaiAide.exe si -Aide)
function Get-DemandeEssai([string]$Donnees, [string]$Programmes = $ProgrammesC, [switch]$Aide) {
    $t = Join-Path $Donnees 'telechargements'
    $p = [ordered]@{ Zip = (Join-Path $t 'essai.zip'); Signature = (Join-Path $t 'essai.zip.sig'); Destination = (Join-Path $Programmes 'Essai'); DossierZip = 'Essai'; Exe = 'Essai.exe' }
    if ($Aide) { $p.TacheAide = 'Essai (aide)'; $p.ExeAide = 'EssaiAide.exe' }
    $p
}
$CopierEssai = @((Join-Path $Paquets 'essai.zip'), (Join-Path $Paquets 'essai.zip.sig'))

# =====================================================================================================================
# 0. Préparation
# =====================================================================================================================
function Initialize-Essai {
    Write-Partie '0. Préparation'
    $depotGit = Split-Path $PSScriptRoot -Parent
    foreach ($d in $Racine, "$Racine\cle", $Paquets, $Sorties, "$Racine\clients", "$Racine\outils", "$Racine\releases") { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    # Tout le monde lit C:\essai ; les clients (autres comptes) écrivent leurs consignes et leurs sorties
    & "$env:SystemRoot\System32\icacls.exe" $Racine /grant '*S-1-1-0:(OI)(CI)RX' /Q | Out-Null
    foreach ($d in $Sorties, "$Racine\clients") { & "$env:SystemRoot\System32\icacls.exe" $d /grant '*S-1-1-0:(OI)(CI)M' /Q | Out-Null }
    # Le journal du Planificateur (pour comprendre un échec)
    & "$env:SystemRoot\System32\wevtutil.exe" sl Microsoft-Windows-TaskScheduler/Operational /e:true | Out-Null

    # La clé RSA de TEST (3072 bits, comme l'exige Mindset)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    try {
        $rsa.PersistKeyInCsp = $false
        Write-Utf8 (Join-Path $Racine 'cle\privee-test.xml') $rsa.ToXmlString($true)
        Write-Utf8 (Join-Path $Racine 'cle\publique-test.xml') $rsa.ToXmlString($false)
    } finally { $rsa.Dispose() }

    # Copie du dépôt, clé de TEST ajoutée à ses clés publiques, puis construite (Mindset.exe, désinstalleur)
    if (Test-Path -LiteralPath $Depot) { Remove-Item -LiteralPath $Depot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Depot | Out-Null
    Copy-Item -LiteralPath (Join-Path $depotGit 'Mindset') -Destination $Depot -Recurse
    Copy-Item -LiteralPath (Join-Path $depotGit 'outils') -Destination $Depot -Recurse
    Copy-Item -LiteralPath (Join-Path $Racine 'cle\publique-test.xml') -Destination (Join-Path $Source 'fichiers\cles-publiques\essai-test.xml')
    & (Join-Path $Depot 'outils\construire.ps1') | Out-Host
    Test-Cas 'Mindset construit (Mindset.exe et son désinstalleur)' { (Test-Path -LiteralPath (Join-Path $Source 'Mindset.exe')) -and (Test-Path -LiteralPath (Join-Path $Source 'Desinstaller Mindset.exe')) }

    # Le zip de mise à jour : la même copie, en version $VersionMaj, signée avec la clé de TEST
    $maj = Join-Path $Racine 'maj'
    if (Test-Path -LiteralPath $maj) { Remove-Item -LiteralPath $maj -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $maj | Out-Null
    Copy-Item -LiteralPath $Source -Destination $maj -Recurse
    $ps1 = Join-Path $maj 'Mindset\fichiers\Mindset.ps1'
    $texte = [IO.File]::ReadAllText($ps1, [Text.Encoding]::UTF8) -replace "(?m)^\`$AppVersion = '[\d.]+'", "`$AppVersion = '$VersionMaj'"
    [IO.File]::WriteAllText($ps1, $texte, (New-Object Text.UTF8Encoding $true))
    $zip = Join-Path $Paquets 'mindset.zip'
    Compress-Archive -Path (Join-Path $maj 'Mindset') -DestinationPath $zip -Force
    New-Signature $zip

    # L'appli d'essai : Essai.exe (attend qu'on la ferme) et sa partie administrateur EssaiAide.exe
    $csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $app = Join-Path $Racine 'appli\Essai'
    New-Item -ItemType Directory -Force -Path $app | Out-Null
    $cs = Join-Path $Racine 'appli\essai.cs'
    Write-Utf8 $cs 'static class Essai { static void Main() { System.Threading.Thread.Sleep(System.Threading.Timeout.Infinite); } }'
    foreach ($n in 'Essai.exe', 'EssaiAide.exe') { & $csc /nologo /target:winexe "/out:$(Join-Path $app $n)" $cs | Out-Host }
    Compress-Archive -Path $app -DestinationPath (Join-Path $Paquets 'essai.zip') -Force
    New-Signature (Join-Path $Paquets 'essai.zip')
    . (Join-Path $Source 'fichiers\modules\signature.ps1')
    Test-Cas 'zips d''essai signés avec la clé de TEST, acceptés par la copie d''essai, refusés par les vraies clés' {
        $cles = Join-Path $Source 'fichiers\cles-publiques'
        $ok = $true
        foreach ($z in 'mindset.zip', 'essai.zip') {
            $o = [IO.File]::ReadAllBytes((Join-Path $Paquets $z)); $s = [IO.File]::ReadAllBytes((Join-Path $Paquets "$z.sig"))
            $ok = $ok -and (Test-Signature $o $s $cles) -and -not (Test-Signature $o $s (Join-Path $depotGit 'Mindset\fichiers\cles-publiques'))
        }
        $ok
    }

    # Les Releases v2.9.0 et v2.7.0 (zip publié, vérifié avec les vraies clés), puis la clé de TEST ajoutée à leur copie
    foreach ($v in '2.9.0', '2.7.0') {
        $d = Join-Path $Racine "releases\v$v"
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        & gh release download "v$v" -R $env:GITHUB_REPOSITORY -p 'Mindset.zip*' -D $d | Out-Host
        Test-Cas "Release v$v téléchargée, signée par la vraie clé" {
            $o = [IO.File]::ReadAllBytes((Join-Path $d 'Mindset.zip')); $s = [IO.File]::ReadAllBytes((Join-Path $d 'Mindset.zip.sig'))
            Test-Signature $o $s (Join-Path $depotGit 'Mindset\fichiers\cles-publiques')
        }
        Expand-Archive -LiteralPath (Join-Path $d 'Mindset.zip') -DestinationPath (Join-Path $d 'x') -Force
        Copy-Item -LiteralPath (Join-Path $Racine 'cle\publique-test.xml') -Destination (Join-Path $d 'x\Mindset\fichiers\cles-publiques\essai-test.xml')
        Test-Cas "Release v$v : Mindset $v dedans" { (Get-VersionInstallee (Join-Path $d 'x\Mindset')) -eq $v }
    }

    # Le script lui-même, et son lanceur pour les autres comptes (qui n'ont pas la variable GITHUB_ACTIONS)
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $Racine 'outils\essai-installateur-reel.ps1') -Force
    [IO.File]::WriteAllText((Join-Path $Racine 'lancer.ps1'), "param([string]`$Client)`r`n`$env:GITHUB_ACTIONS = 'true'`r`n& '$Racine\outils\essai-installateur-reel.ps1' -Client `$Client`r`n", (New-Object Text.UTF8Encoding $true))
}

# =====================================================================================================================
# 1. Installation sur C:, puis sur D:\Mindset, puis une vraie demande passée par la tâche SYSTEM
# =====================================================================================================================
function Test-Cas1 {
    Write-Partie '1. Installation sur C:, puis sur D:\Mindset, puis une demande par la tâche SYSTEM'
    Reset-Machine
    $ra = Get-Runneradmin
    $r = Install-MindsetDirect $ra.Sid
    Test-Cas 'C: : installé dans Program Files\Mindset\Mindset, inscrit dans « Applications installées »' {
        $r.ok -and $r.message -eq $MindsetC -and (Test-Path -LiteralPath (Join-Path $MindsetC 'Mindset.exe')) -and [string](Get-ItemProperty $CleDesinstall).InstallLocation -eq $MindsetC
    }
    Test-Cas 'C: : tâche SYSTEM pour runneradmin (demande dans son dossier, lue et lancée par lui seul)' { Test-TacheSysteme $ra.Sid (Join-Path $ra.Donnees 'installation.demande') (Join-Path $MindsetC 'fichiers\installer-admin.ps1') }
    Test-Cas 'C: : tâche de démarrage sous son compte, sans droits' { $t = Get-InfoTache 'Mindset (démarrage)'; $t -and (ConvertTo-Sid $t.Compte) -eq $ra.Sid -and $t.LogonType -eq 'InteractiveToken' -and $t.RunLevel -eq 'LeastPrivilege' }

    $r = Install-MindsetDirect $ra.Sid 'D'
    $dD = 'D:\Mindset\Programmes\Mindset'
    Test-Cas 'D: : installé dans D:\Mindset\Programmes\Mindset, « Applications installées » à jour' { $r.ok -and $r.message -eq $dD -and (Test-Path -LiteralPath (Join-Path $dD 'Mindset.exe')) -and [string](Get-ItemProperty $CleDesinstall).InstallLocation -eq $dD }
    Test-Cas 'D:\Mindset protégé : droits propres (pas ceux du disque), utilisateurs en lecture seule, Donnees modifiable par l''utilisateur' {
        $acl = Get-Acl -LiteralPath 'D:\Mindset'
        $users = @($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-545' })
        $autres = @($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-32-544', 'S-1-5-18', 'S-1-5-32-545' })
        $d = Get-Acl -LiteralPath 'D:\Mindset\Donnees'
        $modif = @($d.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $ra.Sid -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify })
        $acl.AreAccessRulesProtected -and $users.Count -and -not @($users | Where-Object { $_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData }).Count -and -not $autres.Count -and $modif.Count
    }
    Test-Cas 'D: : la tâche SYSTEM lance la copie de D:, demande dans D:\Mindset\Donnees\Mindset' { Test-TacheSysteme $ra.Sid 'D:\Mindset\Donnees\Mindset\installation.demande' (Join-Path $dD 'fichiers\installer-admin.ps1') }

    $avant = (Get-InfoTache $NomTache).Dernier
    $s = Invoke-Client $ra @{ Mode = 'invoke'; Modules = (Join-Path $dD 'fichiers\modules'); DataDir = 'D:\Mindset\Donnees\Mindset'; Action = 'appli'; Parametres = (Get-DemandeEssai 'D:\Mindset\Donnees\Mindset' 'D:\Mindset\Programmes'); Copier = $CopierEssai }
    Test-Cas 'demande par la tâche SYSTEM : reconnue, accusé de réception, appli installée dans D:\Mindset\Programmes\Essai, aucune demande de Windows' {
        $t = Get-InfoTache $NomTache
        $s.Etat -eq 'systeme' -and @($s.Fins).Count -eq 1 -and $s.Fins[0] -eq 'True|D:\Mindset\Programmes\Essai' -and -not @($s.RunAs).Count -and
            (Test-Path -LiteralPath 'D:\Mindset\Programmes\Essai\Essai.exe') -and $t.Dernier -ne $avant -and $t.Code -eq 0 -and -not (Test-Path -LiteralPath 'D:\Mindset\Donnees\Mindset\installation.demande')
    }
}

# =====================================================================================================================
# 2 et 3. Mise à jour depuis une Release d'avant la tâche SYSTEM
# =====================================================================================================================
function Test-MajDepuis([string]$Version) {
    Reset-Machine
    $adm = Get-Compte 'AdminEssai' -Admin
    $ancien = Join-Path $Racine "releases\v$Version\x\Mindset"
    $r = Install-MindsetDirect $adm.Sid '' $ancien $Version
    $t = Get-InfoTache $NomTache
    Test-Cas "Mindset $Version installé pour un administrateur de test (pas runneradmin), avec l'ancienne tâche « droits les plus élevés » sous son compte" {
        $r.ok -and $t -and (ConvertTo-Sid $t.Compte) -eq $adm.Sid -and $t.RunLevel -eq 'HighestAvailable' -and $t.Arguments -match '-Action demande' -and $t.Arguments -notmatch '-Sid '
    }
    # Adaptation : la machine de GitHub n'ouvre pas de session pour ce compte, et une tâche « à l'ouverture de session »
    # ne tourne pas sans elle. L'ancienne tâche est réinscrite à l'identique, mais avec son mot de passe (elle tourne
    # alors sans session). (Mindset $Version notait aussi la demande dans le dossier du compte qui avait accepté la demande
    # de Windows : ici, celui de l'administrateur de test, comme s'il avait accepté lui-même.)
    $demande = Join-Path $adm.Donnees 'installation.demande'
    $poserMdp = {
        $x = Get-ScheduledTask -TaskPath '\Mindset\' -TaskName $NomTache
        $a = $x.Actions[0]
        $arg = ([string]$a.Arguments) -replace '-Demande "[^"]*"', ('-Demande "' + $demande.Replace('$', '$$') + '"')
        $act = New-ScheduledTaskAction -Execute $a.Execute -Argument $arg -WorkingDirectory $a.WorkingDirectory
        Register-ScheduledTask -TaskPath '\Mindset\' -TaskName $NomTache -Action $act -Settings $x.Settings -User "$env:COMPUTERNAME\$($adm.Nom)" -Password $adm.Mdp -RunLevel Highest -Force | Out-Null
    }
    & $poserMdp
    Add-Note "cas $(if ($Version -eq '2.9.0') { 2 } else { 3 }) : ancienne tâche réinscrite avec le mot de passe de l'administrateur de test (LogonType Password au lieu d'Interactive : pas de session ouverte pour lui sur la machine de GitHub)"

    # Le Mindset d'avant demande sa mise à jour (ses propres fonctions), par l'ancienne tâche
    $s = Invoke-Client $adm @{ Mode = 'maj-ancienne'; Modules = (Join-Path $MindsetC 'fichiers\modules'); DataDir = $adm.Donnees; Version = $VersionMaj; Copier = @((Join-Path $Paquets 'mindset.zip'), (Join-Path $Paquets 'mindset.zip.sig')) }
    $fini = Wait-Jusque { $v = Get-Valeur 'Resultat'; $v -and $s.Demande -and $v -match $s.Demande } 180
    Test-Cas "Mindset $Version demande sa mise à jour par l'ancienne tâche : installée ($VersionMaj)" {
        $res = Get-Valeur 'Resultat' | ConvertFrom-Json
        $fini -and $s.Sorties -eq 1 -and $res.ok -and (Get-VersionInstallee $MindsetC) -eq $VersionMaj
    }
    # Le Mindset d'avant relance Mindset par l'Explorateur, ici sans session : ce qu'il aurait ouvert est fermé (le client
    # ci-dessous fait ce que fait le nouveau Mindset au démarrage)
    Start-Sleep -Seconds 5
    foreach ($p in @(Get-ProgrammesDans $MindsetC)) { Write-Host "         | Mindset relancé par l'ancien installateur, fermé : $($p.Id) session $($p.Session)" -ForegroundColor DarkGray; try { Stop-Process -Id $p.Id -Force } catch {} }
    # La mise à jour a réinscrit l'ancienne tâche (le code de Mindset $Version tournait encore) : à nouveau « à l'ouverture
    # de session », remise avec le mot de passe pour la suite
    $t = Get-InfoTache $NomTache
    Write-Host "         | après la mise à jour : $($t.Compte) $($t.LogonType) $($t.RunLevel) ; $($t.Arguments)" -ForegroundColor DarkGray
    if ($t -and $t.LogonType -ne 'Password' -and $t.Arguments -notmatch '-Sid ') { & $poserMdp }

    # Le nouveau Mindset démarre : il voit l'ancienne tâche et lui fait se remplacer par la tâche SYSTEM
    $s = Invoke-Client $adm @{ Mode = 'remplacement'; Modules = (Join-Path $MindsetC 'fichiers\modules'); DataDir = $adm.Donnees }
    Test-Cas 'le nouveau Mindset reconnaît l''ancienne tâche et la remplace par la tâche SYSTEM, sans demande de Windows' {
        $s.Etat -eq 'ancienne' -and $s.Remplace -eq $true -and $s.EtatApres -eq 'systeme' -and -not @($s.RunAs).Count
    }
    Test-Cas 'la tâche SYSTEM est en place pour l''administrateur de test (ni son compte, ni « droits les plus élevés » sous son nom)' { Test-TacheSysteme $adm.Sid $demande (Join-Path $MindsetC 'fichiers\installer-admin.ps1') }
    $s = Invoke-Client $adm @{ Mode = 'invoke'; Modules = (Join-Path $MindsetC 'fichiers\modules'); DataDir = $adm.Donnees; Action = 'appli'; Parametres = (Get-DemandeEssai $adm.Donnees); Copier = $CopierEssai }
    Test-Cas 'ensuite, une demande passe par la tâche SYSTEM' { $s.Etat -eq 'systeme' -and @($s.Fins).Count -eq 1 -and $s.Fins[0] -eq "True|$ProgrammesC\Essai" -and -not @($s.RunAs).Count }
}

# =====================================================================================================================
# 4. Mise à jour avec Mindset caché, sur runneradmin : relancé par sa tâche de démarrage dans sa session, sans boucle
# =====================================================================================================================
function Test-Cas4 {
    Write-Partie '4. Mise à jour avec Mindset caché (Cache=1) sur runneradmin'
    Reset-Machine
    $ra = Get-Runneradmin
    $null = Install-MindsetDirect $ra.Sid
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $avant = (Get-InfoTache 'Mindset (démarrage)').Dernier
    $s = Invoke-Client $ra @{ Mode = 'maj'; Cache = $true; Modules = (Join-Path $MindsetC 'fichiers\modules'); DataDir = $ra.Donnees; Version = $VersionMaj; Copier = @((Join-Path $Paquets 'mindset.zip'), (Join-Path $Paquets 'mindset.zip.sig')) }
    Test-Cas 'la demande part par la tâche SYSTEM (avec Cache=1), Mindset se ferme à l''accusé de réception' { $s.Etat -eq 'systeme' -and $s.Sorties -eq 1 -and $s.Demande -and -not @($s.RunAs).Count }
    $fini = Wait-Jusque { $v = Get-Valeur 'Resultat'; $v -and $v -match $s.Demande } 180
    Test-Cas "mise à jour installée ($VersionMaj)" { $fini -and (Get-Valeur 'Resultat' | ConvertFrom-Json).ok -and (Get-VersionInstallee $MindsetC) -eq $VersionMaj }
    $vus = @{}
    $lance = Wait-Jusque { foreach ($p in @(Get-ProgrammesDans $MindsetC | Where-Object { $_.Chemin -like '*\Mindset.exe' })) { $vus[$p.Id] = $p }; $vus.Count -gt 0 } 90
    # 60 secondes d'observation : une boucle relancerait Mindset sans fin
    $fin = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $fin) { foreach ($p in @(Get-ProgrammesDans $MindsetC | Where-Object { $_.Chemin -like '*\Mindset.exe' })) { $vus[$p.Id] = $p }; Start-Sleep -Milliseconds 500 }
    $vivants = @(Get-ProgrammesDans $MindsetC | Where-Object { $_.Chemin -like '*\Mindset.exe' })
    foreach ($p in $vus.Values) { Write-Host "         | Mindset.exe vu : $($p.Id), session $($p.Session), compte $($p.Sid)" -ForegroundColor DarkGray }
    $journal = Join-Path $ra.Donnees 'journal.txt'
    $lignes = @(if (Test-Path -LiteralPath $journal) { Get-Content -LiteralPath $journal -Encoding UTF8 })
    $lignes | ForEach-Object { Write-Host "         |   journal de Mindset : $_" -ForegroundColor DarkGray }
    Test-Cas 'la tâche « Mindset (démarrage) » s''est déclenchée' { $t = Get-InfoTache 'Mindset (démarrage)'; $t.Dernier -ne $avant }
    Test-Cas "Mindset $VersionMaj tourne, dans la session $session, sous runneradmin" { $lance -and $vivants.Count -eq 1 -and $vivants[0].Session -eq $session -and $vivants[0].Sid -eq $ra.Sid }
    Test-Cas 'sans boucle : au plus une relance (bascule de l''Explorateur administrateur), plus rien de nouveau ensuite' {
        $vus.Count -le 2 -and @($lignes | Where-Object { $_ -match "Démarrage Mindset $([regex]::Escape($VersionMaj))" }).Count -le 2
    }
    foreach ($p in @(Get-ProgrammesDans $MindsetC)) { try { Stop-Process -Id $p.Id -Force } catch {} }
}

# =====================================================================================================================
# 5 à 7. Comptes standard
# =====================================================================================================================
$NomElodie = "$([char]0xC9)lodie Test"
function Test-Cas5 {
    Write-Partie "5. Compte standard au nom accentué, installé par un administrateur"
    Reset-Machine
    $e = Get-Compte $NomElodie
    Test-Cas 'le compte et son dossier (C:\Users\Élodie Test) existent, nom intact' { $e.Profil -eq "C:\Users\$NomElodie" -and (Test-Path -LiteralPath $e.Profil) }
    # Mindset (pas encore installé) demande son installation : la demande de Windows, où l'administrateur tape son mot de
    # passe. Elle n'est pas automatisable : la commande exacte que Mindset passe à Windows est lancée en administrateur.
    $s = Invoke-Client $e @{ Mode = 'invoke'; SansAttente = $true; Modules = (Join-Path $Source 'fichiers\modules'); DataDir = $e.Donnees; Action = 'mindset'
        Parametres = @{ Source = $Source; Version = '2.9.0'; Disque = ''; Sid = $e.Sid } }
    Test-Cas 'Mindset passe par la demande de Windows, avec le compte d''Élodie (-Sid) et une réponse dans son dossier' { @($s.RunAs).Count -eq 1 -and $s.RunAs[0] -match "-Sid `"$([regex]::Escape($e.Sid))`"" -and $s.RunAs[0] -match '-Action mindset' }
    $rep = if ($s.RunAs[0] -match '-Resultat "([^"]+)"') { $Matches[1] } else { '' }
    Microsoft.PowerShell.Management\Start-Process -FilePath $PowerShellExe -ArgumentList $s.RunAs[0] -WorkingDirectory $env:SystemRoot -Wait -WindowStyle Hidden
    $r = Read-Json $rep
    Write-Host "         | réponse : $($r.ok) $($r.message)" -ForegroundColor DarkGray
    Test-Cas 'installé par l''administrateur pour Élodie' { $rep -like "$($e.Donnees)\telechargements\*" -and $r.ok -and $r.message -eq $MindsetC }
    Test-Cas 'tâche SYSTEM inscrite pour Élodie : sa demande dans C:\Users\Élodie Test\AppData\Local\Mindset\Mindset (accents intacts)' { Test-TacheSysteme $e.Sid "C:\Users\$NomElodie\AppData\Local\Mindset\Mindset\installation.demande" (Join-Path $MindsetC 'fichiers\installer-admin.ps1') }
    Test-Cas 'tâche de démarrage sous le compte d''Élodie (pas celui de l''administrateur)' { $t = Get-InfoTache 'Mindset (démarrage)'; (ConvertTo-Sid $t.Compte) -eq $e.Sid -and $t.RunLevel -eq 'LeastPrivilege' }
}

function Test-Cas6 {
    Write-Partie '6. Le compte standard lit et lance la tâche, et sa demande passe'
    Reset-Machine
    $e = Get-Compte $NomElodie
    $null = Install-MindsetDirect $e.Sid
    $s = Invoke-Client $e @{ Mode = 'droits'; Lancer = $true; Modules = (Join-Path $MindsetC 'fichiers\modules'); DataDir = $e.Donnees }
    Test-Cas 'Élodie lit la tâche (schtasks /Query) et la lance (schtasks /Run), Mindset la reconnaît' { -not $s.Erreur -and $s.Etat -eq 'systeme' -and $s.CodeLire -eq 0 -and $s.CodeLancer -eq 0 }
    Test-Cas 'Élodie ne peut ni modifier la tâche ni écrire dans Program Files\Mindset' { -not $s.Erreur -and $null -ne $s.CodeModifier -and $s.CodeModifier -ne 0 -and $s.EcritProgrammes -eq $false -and (Get-InfoTache $NomTache).Active }
    $s = Invoke-Client $e @{ Mode = 'invoke'; Modules = (Join-Path $MindsetC 'fichiers\modules'); DataDir = $e.Donnees; Action = 'appli'; Parametres = (Get-DemandeEssai $e.Donnees -Aide); Copier = $CopierEssai }
    Test-Cas 'sa demande passe par la tâche SYSTEM : appli installée, sans demande de Windows' { @($s.Fins).Count -eq 1 -and $s.Fins[0] -eq "True|$ProgrammesC\Essai" -and -not @($s.RunAs).Count -and (Test-Path -LiteralPath "$ProgrammesC\Essai\Essai.exe") }
    Test-Cas 'la partie administrateur de l''appli : tâche « Essai (aide) » pour Élodie seulement' { $t = Get-InfoTache 'Essai (aide)'; $t -and (ConvertTo-Sid $t.Compte) -eq $e.Sid -and $t.Commande -eq "`"$ProgrammesC\Essai\EssaiAide.exe`"" }
}

function Test-Cas7 {
    Write-Partie '7. Deux comptes standard sur le même PC'
    Reset-Machine
    $e = Get-Compte $NomElodie
    $b = Get-Compte 'Bruno Essai'
    $null = Install-MindsetDirect $e.Sid
    $modules = Join-Path $MindsetC 'fichiers\modules'
    $s = Invoke-Client $e @{ Mode = 'invoke'; Modules = $modules; DataDir = $e.Donnees; Action = 'appli'; Parametres = (Get-DemandeEssai $e.Donnees); Copier = $CopierEssai }
    Test-Cas 'appli d''essai installée par Élodie (tâche SYSTEM)' { @($s.Fins).Count -eq 1 -and $s.Fins[0] -like 'True|*' }
    $exe = "$ProgrammesC\Essai\Essai.exe"
    $pe = Microsoft.PowerShell.Management\Start-Process -FilePath $exe -Credential $e.Cred -LoadUserProfile -WorkingDirectory $env:SystemRoot -PassThru
    $pb = Microsoft.PowerShell.Management\Start-Process -FilePath $exe -Credential $b.Cred -LoadUserProfile -WorkingDirectory $env:SystemRoot -PassThru
    Start-Sleep -Seconds 2
    $avant = @(Get-ProgrammesDans "$ProgrammesC\Essai")
    Test-Cas 'l''appli tourne sous les deux comptes' { @($avant | Where-Object { $_.Sid -eq $e.Sid }).Count -eq 1 -and @($avant | Where-Object { $_.Sid -eq $b.Sid }).Count -eq 1 }
    # Élodie réinstalle l'appli : seul son programme est fermé, jamais celui de Bruno
    $s = Invoke-Client $e @{ Mode = 'invoke'; Modules = $modules; DataDir = $e.Donnees; Action = 'appli'; Parametres = (Get-DemandeEssai $e.Donnees); Copier = $CopierEssai }
    $apres = @(Get-ProgrammesDans "$ProgrammesC\Essai")
    Test-Cas 'réinstallation par Élodie : son programme est fermé, celui de Bruno continue (l''installation attend qu''il le ferme)' {
        -not @($apres | Where-Object { $_.Sid -eq $e.Sid }).Count -and @($apres | Where-Object { $_.Sid -eq $b.Sid -and $_.Id -eq $pb.Id }).Count -eq 1 -and @($s.Fins).Count -eq 1
    }
    $s2 = Invoke-Client $b @{ Mode = 'droits'; Lancer = $true; Modules = $modules; DataDir = $b.Donnees }
    Test-Cas 'Bruno ne peut ni lire ni lancer la tâche d''Élodie (Mindset ne l''utilise pas pour lui)' { -not $s2.Erreur -and $s2.Etat -eq '' -and $null -ne $s2.CodeLire -and $s2.CodeLire -ne 0 -and $null -ne $s2.CodeLancer -and $s2.CodeLancer -ne 0 }
    try { Stop-Process -Id $pb.Id -Force } catch {}
    Start-Sleep -Seconds 1
    $s = Invoke-Client $e @{ Mode = 'invoke'; Modules = $modules; DataDir = $e.Donnees; Action = 'appli'; Parametres = (Get-DemandeEssai $e.Donnees); Copier = $CopierEssai }
    Test-Cas 'Bruno l''a fermée : la réinstallation d''Élodie passe' { @($s.Fins).Count -eq 1 -and $s.Fins[0] -like 'True|*' }
    foreach ($p in @(Get-ProgrammesDans "$ProgrammesC\Essai")) { try { Stop-Process -Id $p.Id -Force } catch {} }
    try { Stop-Process -Id $pe.Id -Force -ErrorAction SilentlyContinue } catch {}
}

# =====================================================================================================================
# 8. Tâche SYSTEM absente, désactivée ou cassée : la demande de Windows ; l'ancienne tâche ne tourne jamais
# =====================================================================================================================
function Test-Cas8 {
    Write-Partie '8. Tâche SYSTEM absente, désactivée ou cassée'
    Reset-Machine
    $ra = Get-Runneradmin
    $null = Install-MindsetDirect $ra.Sid
    $modules = Join-Path $MindsetC 'fichiers\modules'
    $script = Join-Path $MindsetC 'fichiers\installer-admin.ps1'
    $demande = Join-Path $ra.Donnees 'installation.demande'
    # L'ancienne tâche (comme Mindset 2.9.0 la créait : sous le compte, avec les droits les plus élevés, sans -Sid)
    $ancienne = {
        param([string]$Nom)
        $act = New-ScheduledTaskAction -Execute $PowerShellExe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Action demande -Demande `"$demande`"" -WorkingDirectory $env:SystemRoot
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(30)) -MultipleInstances Queue
        Register-ScheduledTask -TaskPath '\Mindset\' -TaskName $Nom -Action $act -Principal (New-ScheduledTaskPrincipal -UserId $ra.Sid -LogonType Interactive -RunLevel Highest) -Settings $set -Force | Out-Null
    }
    $client = @{ Mode = 'invoke'; RunAsReel = $true; Modules = $modules; DataDir = $ra.Donnees; Action = 'appli'; Parametres = (Get-DemandeEssai $ra.Donnees); Copier = $CopierEssai }

    # a. Absente : l'ancienne tâche à sa place
    Unregister-ScheduledTask -TaskPath '\Mindset\' -TaskName $NomTache -Confirm:$false
    & $ancienne $NomTache
    $avant = (Get-InfoTache $NomTache).Dernier
    $s = Invoke-Client $ra $client
    Test-Cas 'tâche SYSTEM absente, l''ancienne à sa place : demande de Windows, appli installée' { $s.Etat -eq 'ancienne' -and @($s.RunAs).Count -eq 1 -and @($s.Fins).Count -eq 1 -and $s.Fins[0] -eq "True|$ProgrammesC\Essai" }
    Test-Cas 'l''ancienne tâche n''a pas tourné (dernier lancement inchangé)' { (Get-InfoTache $NomTache).Dernier -eq $avant }

    # b. Désactivée (l'ancienne tâche « \Mindset\Mindset » d'avant la 0.3 présente à côté)
    $null = Register-TachesDirect $MindsetC $ra.Sid
    & $ancienne 'Mindset'
    Disable-ScheduledTask -TaskPath '\Mindset\' -TaskName $NomTache | Out-Null
    $avant = (Get-InfoTache $NomTache).Dernier; $avantAncienne = (Get-InfoTache 'Mindset').Dernier
    $s = Invoke-Client $ra $client
    Test-Cas 'tâche SYSTEM désactivée : demande de Windows, appli installée' { $s.Etat -eq 'systeme' -and @($s.RunAs).Count -eq 1 -and @($s.Fins).Count -eq 1 -and $s.Fins[0] -like 'True|*' }
    Test-Cas 'ni la tâche désactivée ni l''ancienne n''ont tourné' { (Get-InfoTache $NomTache).Dernier -eq $avant -and (Get-InfoTache 'Mindset').Dernier -eq $avantAncienne }

    # c. Cassée : elle démarre, mais son script n'existe pas (aucun accusé de réception)
    Enable-ScheduledTask -TaskPath '\Mindset\' -TaskName $NomTache | Out-Null
    $t = Get-InfoTache $NomTache
    $xml = $t.Xml.Replace('installer-admin.ps1', 'installer-absent.ps1')
    Register-ScheduledTask -TaskPath '\Mindset\' -TaskName $NomTache -Xml $xml -Force | Out-Null
    $avantAncienne = (Get-InfoTache 'Mindset').Dernier
    $s = Invoke-Client $ra $client
    Test-Cas 'tâche SYSTEM cassée (pas d''accusé de réception en 30 s) : demande retirée, puis demande de Windows, appli installée' {
        $s.Etat -eq 'systeme' -and $s.Duree -ge 30 -and @($s.RunAs).Count -eq 1 -and @($s.Fins).Count -eq 1 -and $s.Fins[0] -like 'True|*' -and -not (Test-Path -LiteralPath $demande)
    }
    Test-Cas 'l''ancienne tâche n''a toujours pas tourné' { (Get-InfoTache 'Mindset').Dernier -eq $avantAncienne }
}

# =====================================================================================================================
# 9. Désinstallation : plus aucune tâche \Mindset\
# =====================================================================================================================
function Test-RienDeMindset {
    $taches = @(Get-ScheduledTask -TaskPath '\Mindset\' -ErrorAction SilentlyContinue)
    $dossier = $true; try { $s = New-Object -ComObject Schedule.Service; $s.Connect(); $null = $s.GetFolder('\Mindset') } catch { $dossier = $false }
    Write-Host "         | tâches restantes : $($taches.Count) ; dossier \Mindset\ : $dossier ; Program Files\Mindset : $(Test-Path -LiteralPath $ProgrammesC) ; HKLM\SOFTWARE\Mindset : $(Test-Path 'HKLM:\SOFTWARE\Mindset') ; Applications installées : $(Test-Path $CleDesinstall)" -ForegroundColor DarkGray
    -not $taches.Count -and -not $dossier -and -not (Test-Path -LiteralPath $MindsetC) -and -not (Test-Path $CleDesinstall) -and -not (Test-Path 'HKLM:\SOFTWARE\Mindset')
}
function Test-Cas9 {
    Write-Partie '9. Désinstallation'
    $ra = Get-Runneradmin
    $modules = Join-Path $MindsetC 'fichiers\modules'
    foreach ($par in 'desinstalleur', 'tache') {
        Reset-Machine
        $null = Install-MindsetDirect $ra.Sid
        $s = Invoke-Client $ra @{ Mode = 'invoke'; Modules = $modules; DataDir = $ra.Donnees; Action = 'appli'; Parametres = (Get-DemandeEssai $ra.Donnees -Aide); Copier = $CopierEssai }
        Test-Cas "avant ($par) : trois tâches (démarrage, installation, « Essai (aide) »)" { @(Get-ScheduledTask -TaskPath '\Mindset\').Count -eq 3 }
        if ($par -eq 'desinstalleur') {
            $rap = Join-Path $Sorties 'desinstallation.json'
            Microsoft.PowerShell.Management\Start-Process -FilePath (Join-Path $MindsetC 'Desinstaller Mindset.exe') -ArgumentList '-Silencieux', '-Sid', $ra.Sid, '-Rapport', "`"$rap`"" -WorkingDirectory $env:SystemRoot
            $fini = Wait-Jusque { Test-Path -LiteralPath $rap } 180
            $r = Read-Json $rap
            Write-Host "         | bilan du désinstalleur : ok $($r.ok), restes [$(@($r.restes) -join ' ; ')]" -ForegroundColor DarkGray
            Test-Cas 'désinstalleur autonome (« Applications installées ») : plus rien de Mindset, plus aucune tâche \Mindset\' { $fini -and (Test-RienDeMindset) }
        } else {
            # Par la tâche (désinstallation sans le désinstalleur autonome, Mindset.ps1 Confirm-DesinstallMindset) :
            # Mindset se ferme après l'accusé de réception
            $s = Invoke-Client $ra @{ Mode = 'invoke'; SortirApresRecu = $true; AttendreMoi = $true; Modules = $modules; DataDir = $ra.Donnees; Action = 'supprimer'; Parametres = @{ Destination = $MindsetC } }
            $fini = Wait-Jusque { Test-RienDeMindset } 120
            Test-Cas 'par la tâche SYSTEM (Mindset fermé) : plus rien de Mindset, plus aucune tâche \Mindset\' { $s.Etat -eq 'systeme' -and -not @($s.RunAs).Count -and $fini }
        }
    }
}

# =====================================================================================================================
# 10. La tâche SYSTEM ne reprend rien de l'environnement de l'utilisateur
# =====================================================================================================================
function Test-Cas10 {
    Write-Partie '10. Environnement : la tâche SYSTEM ne voit ni les variables ni le PSModulePath de l''utilisateur'
    Reset-Machine
    $e = Get-Compte $NomElodie
    $null = Install-MindsetDirect $e.Sid
    $marque = Join-Path $Racine 'modules-temoin-MINDSET'
    New-Item -ItemType Directory -Force -Path $marque | Out-Null   # (vide : rien ne s'y charge)
    # Les réglages d'Élodie, posés sous son compte (HKCU\Environment) : une variable témoin inoffensive et son PSModulePath
    $code = "[Environment]::SetEnvironmentVariable('MINDSET_TEMOIN_ENV', '1', 'User'); [Environment]::SetEnvironmentVariable('PSModulePath', '$marque', 'User')"
    $p = Microsoft.PowerShell.Management\Start-Process -FilePath $PowerShellExe -ArgumentList '-NoProfile', '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) -Credential $e.Cred -LoadUserProfile -WorkingDirectory $Racine -PassThru -WindowStyle Hidden
    [void]$p.WaitForExit(60000)
    # Deux copies de test de installer-admin.ps1 (dans Program Files : modifiables par les seuls administrateurs) : elles
    # écrivent leur environnement au tout début (ce qu'elles reçoivent) et après le chargement des modules de Windows
    $copies = @{}
    foreach ($qui in 'systeme', 'utilisateur') {
        $d = Join-Path $env:ProgramFiles "MindsetEssaiEnv\$qui"
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $texte = [IO.File]::ReadAllText((Join-Path $MindsetC 'fichiers\installer-admin.ps1'), [Text.Encoding]::UTF8)
        $ecrire = "& { param(`$Etape) `$l = [Collections.Generic.List[string]]::new(); `$l.Add('COMPTE=' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value); `$l.Add('PSMODULEPATH=' + `$env:PSModulePath); `$v = [Environment]::GetEnvironmentVariables(); foreach (`$k in `$v.Keys) { `$l.Add('VAR ' + `$k + '=' + `$v[`$k]) }; foreach (`$m in @(Get-Module)) { `$l.Add('MODULE ' + `$m.Path) }; [IO.File]::WriteAllLines('$Sorties\env-$qui-' + `$Etape + '.txt', `$l) }"
        $i = $texte.IndexOf("`$ErrorActionPreference = 'Stop'")
        $texte = $texte.Substring(0, $i) + "$ecrire 'debut'`r`n" + $texte.Substring($i)
        $texte = $texte.Replace('# <dossiers-windows>', "$ecrire 'apres'`r`n# <dossiers-windows>")
        [IO.File]::WriteAllText((Join-Path $d 'installer-admin.ps1'), $texte, (New-Object Text.UTF8Encoding $true))
        $copies[$qui] = Join-Path $d 'installer-admin.ps1'
    }
    # La copie « systeme » lancée par la tâche SYSTEM d'Élodie, à l'identique (même compte, mêmes arguments)
    $t = Get-InfoTache $NomTache
    $script = Join-Path $MindsetC 'fichiers\installer-admin.ps1'
    Register-ScheduledTask -TaskPath '\MindsetEssai\' -TaskName 'Environnement' -Xml $t.Xml.Replace($script, $copies['systeme']) -Force | Out-Null
    Start-ScheduledTask -TaskPath '\MindsetEssai\' -TaskName 'Environnement'
    # La contre-épreuve : la copie « utilisateur » lancée sous le compte d'Élodie, avec les mêmes arguments
    $p = Microsoft.PowerShell.Management\Start-Process -FilePath $PowerShellExe -ArgumentList $t.Arguments.Replace($script, $copies['utilisateur']) -Credential $e.Cred -LoadUserProfile -WorkingDirectory $env:SystemRoot -PassThru -WindowStyle Hidden
    [void]$p.WaitForExit(60000)
    $null = Wait-Jusque { Test-Path -LiteralPath "$Sorties\env-systeme-apres.txt" } 60
    $lire = { param($f) $x = @{ Vars = @{}; Modules = @() }; foreach ($l in @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue)) { if ($l -match '^COMPTE=(.*)') { $x.Compte = $Matches[1] } elseif ($l -match '^PSMODULEPATH=(.*)') { $x.PSModulePath = $Matches[1] } elseif ($l -match '^VAR ([^=]+)=(.*)') { $x.Vars[$Matches[1]] = $Matches[2] } elseif ($l -match '^MODULE (.*)') { $x.Modules += $Matches[1] } }; $x }
    $sd = & $lire "$Sorties\env-systeme-debut.txt"; $sa = & $lire "$Sorties\env-systeme-apres.txt"
    $ud = & $lire "$Sorties\env-utilisateur-debut.txt"; $ua = & $lire "$Sorties\env-utilisateur-apres.txt"
    foreach ($x in @(@('SYSTEM, au début', $sd), @('SYSTEM, après', $sa), @('Élodie, au début', $ud), @('Élodie, après', $ua))) {
        Write-Host "         | $($x[0]) : compte $($x[1].Compte), MINDSET_TEMOIN_ENV=$($x[1].Vars['MINDSET_TEMOIN_ENV']), PSModulePath=$($x[1].PSModulePath)" -ForegroundColor DarkGray
    }
    $systeme32 = [Environment]::GetFolderPath('System') + '\WindowsPowerShell\v1.0\Modules'
    foreach ($x in @(@('SYSTEM', $sa), @('Élodie', $ua))) { foreach ($m in $x[1].Modules) { Write-Host "         | module chargé ($($x[0])) : $m" -ForegroundColor DarkGray } }
    $pshome32 = [Environment]::GetFolderPath('System') + '\WindowsPowerShell\v1.0\'
    Test-Cas 'contre-épreuve : un programme lancé sous le compte d''Élodie voit sa variable témoin et son dossier de modules' {
        $ud.Compte -eq $e.Sid -and $ud.Vars['MINDSET_TEMOIN_ENV'] -eq '1' -and $ud.PSModulePath -like "*$marque*"
    }
    Test-Cas 'la tâche SYSTEM (copie de test) ne voit ni la variable témoin ni le dossier de modules d''Élodie' {
        $sd.Compte -eq 'S-1-5-18' -and -not $sd.Vars.ContainsKey('MINDSET_TEMOIN_ENV') -and $sd.PSModulePath -and $sd.PSModulePath -notlike "*$marque*" -and -not @($sd.Vars.Values | Where-Object { $_ -like "*$NomElodie*" }).Count
    }
    Test-Cas 'après son début, l''installateur ne charge que les modules de Windows (System32), en SYSTEM comme sous le compte d''Élodie' {
        $sa.PSModulePath -eq $systeme32 -and $ua.PSModulePath -eq $systeme32 -and $sa.Modules.Count -and -not @(@($sa.Modules) + @($ua.Modules) | Where-Object { $_ -and -not $_.StartsWith($pshome32, [StringComparison]::OrdinalIgnoreCase) }).Count
    }
}

# =====================================================================================================================
$titres = @{ 0 = 'Préparation'; 1 = 'Installation C:, D:, demande par la tâche SYSTEM'; 2 = 'Mise à jour depuis v2.9.0'; 3 = 'Mise à jour depuis v2.7.0'; 4 = 'Mise à jour cachée sur runneradmin'
    5 = 'Compte standard accentué installé par un administrateur'; 6 = 'Le compte standard lance la tâche'; 7 = 'Deux comptes standard'; 8 = 'Tâche absente, désactivée ou cassée'; 9 = 'Désinstallation'; 10 = 'Environnement de l''utilisateur' }
if (-not $titres.ContainsKey($Cas)) { Write-Host 'Indique -Cas 0 (préparation) ou -Cas 1 à 10.' -ForegroundColor Yellow; exit 2 }
try {
    if ($Cas -ne 0) { Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $Racine 'outils\essai-installateur-reel.ps1') -Force }
    switch ($Cas) {
        0 { if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "| Cas | Quoi | Résultat |`n|---|---|---|`n", (New-Object Text.UTF8Encoding $false)) }; Initialize-Essai }
        1 { Test-Cas1 }
        2 { Write-Partie '2. Mise à jour depuis la Release v2.9.0'; Test-MajDepuis '2.9.0' }
        3 { Write-Partie '3. Mise à jour depuis la Release v2.7.0'; Test-MajDepuis '2.7.0' }
        4 { Test-Cas4 }
        5 { Test-Cas5 }
        6 { Test-Cas6 }
        7 { Test-Cas7 }
        8 { Test-Cas8 }
        9 { Test-Cas9 }
        10 { Test-Cas10 }
    }
} catch {
    $script:Echoues.Add("erreur : $($_.Exception.Message)")
    Write-Host "ERREUR : $($_.Exception.Message) $($_.ScriptStackTrace)" -ForegroundColor Red
    Show-Diagnostic
}

$total = $script:Reussis + $script:Echoues.Count
$etat = if ($script:Echoues.Count) { "échoué ($($script:Echoues.Count) sur $total) : $($script:Echoues -join ' ; ')" } elseif ($script:Notes.Count) { "adapté ($($script:Reussis) sur $total) : $($script:Notes -join ' ; ')" } else { "réussi ($($script:Reussis) sur $total)" }
if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "| $Cas | $($titres[$Cas]) | $etat |`n", (New-Object Text.UTF8Encoding $false)) }
Write-Host ''
if ($script:Echoues.Count) { Write-Host "Cas $Cas : $etat" -ForegroundColor Red; exit 1 }
Write-Host "Cas $Cas : $etat" -ForegroundColor Green
exit 0
