# Mindset : tests du retour après une mise à jour, des bulles près de l'horloge et des installations pendant une opération.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-maj-demarrage.ps1
#   (-Fichiers <dossier> : tester une autre copie de Mindset\fichiers, par exemple l'ancienne version, pour la contre-épreuve)
#
# On vérifie, dans un faux PC sous %TEMP% (faux réglages, faux zips, fausse icône près de l'horloge) :
#   1. après une mise à jour faite pendant que Mindset était caché, il revient (caché) même si « Mindset se lance avec
#      Windows » est coupé ; sans mise à jour, un démarrage de Windows le laisse toujours fermé (vrai Mindset de test,
#      lancé avec -Demarrage, sans fenêtre ni icône) ;
#   2. une bulle de Mindset lui-même (« Mindset reste ici », mise à jour faite, petit problème) n'ouvre jamais une appli
#      ni ne lui renvoie une vieille notification, même si Windows n'a pas signalé la fermeture de la bulle d'avant ;
#   3. une mise à jour de Mindset bloquée par des fichiers utilisés ne demande pas de « fermer l'appli » (impossible pour
#      l'utilisateur) ; le message des autres applis ne change pas ;
#   4. une appli dont le dossier manque pendant une opération en cours (échange des dossiers d'une mise à jour) n'est
#      pas effacée de installations.json ni de suite.json ; hors opération, elle l'est toujours.
# Rien sur le vrai PC : ni ses réglages, ni ses applis, ni leurs processus (seul le Mindset de test lancé ici est fermé,
# par son numéro), ni le registre. Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).
param([string]$Fichiers)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = if ($Fichiers) { (Resolve-Path -LiteralPath $Fichiers).Path } else { Join-Path $racine 'Mindset\fichiers' }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

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

$tmp = Join-Path $env:TEMP "mindset-majdem-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName   # (en nom long : sur GitHub, TEMP est en nom court)
$script:Lances = @()

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

# Lance le vrai Mindset de test avec -Demarrage (comme la tâche de démarrage), avec ces réglages ; rend le journal une
# fois qu'il a dit s'il s'ouvre ou non (puis il est fermé, par son numéro)
function Start-MindsetDemarrage([string]$Nom, $Reglages) {
    $d = Join-Path $tmp $Nom
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'Mindset') | Out-Null
    [IO.File]::WriteAllText((Join-Path $d 'Mindset\reglages.json'), (ConvertTo-Json -InputObject $Reglages), (New-Object Text.UTF8Encoding $false))
    $vars = @{ MINDSET_TEST = '1'; MINDSET_SANS_RESEAU = '1'; MINDSET_DONNEES = $d }
    $avant = @{}; foreach ($k in $vars.Keys) { $avant[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try {
        $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$(Join-Path $fichiers 'Mindset.ps1')`"", '-Demarrage' -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $d 'erreurs.txt')
        $script:Lances += $p
    } finally { foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $avant[$k]) } }
    $f = Join-Path $d 'Mindset\journal.txt'
    $limite = (Get-Date).AddSeconds(60); $j = ''
    while ((Get-Date) -lt $limite) {
        $j = try { [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) } catch { '' }
        if ($j -match 'Démarrage Mindset|rien n''est ouvert' -or $p.HasExited) { break }
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 500
    $j = try { [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) } catch { '' }
    try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(3000) } } catch {}
    $j
}

try {
    Write-Host 'Mindset : retour après une mise à jour, bulles, installations pendant une opération' -ForegroundColor Cyan
    Write-Host "Dossier de test : $tmp"

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '1. Retour de Mindset après une mise à jour faite pendant qu''il était caché (vrai Mindset de test)'
    # -------------------------------------------------------------------------------------------------------------
    $j = Start-MindsetDemarrage 'apres-maj' @{ LancerAvecWindows = $false; MajMindsetDemande = '0123456789abcdef0123456789abcdef'; VerifVersions = $false }
    Test-Cas 'Démarrage coupé, mais une mise à jour vient d''avoir lieu : Mindset revient, caché' { $j -match 'Démarrage Mindset .*, lancé avec Windows' -and $j -notmatch 'rien n''est ouvert' }
    $j = Start-MindsetDemarrage 'sans-maj' @{ LancerAvecWindows = $false; VerifVersions = $false }
    Test-Cas 'Démarrage coupé, sans mise à jour : Windows ne l''ouvre toujours pas' { $j -match 'rien n''est ouvert' -and $j -notmatch 'Démarrage Mindset' }
    $j = Start-MindsetDemarrage 'maj-vide' @{ LancerAvecWindows = $false; MajMindsetDemande = ''; VerifVersions = $false }
    Test-Cas 'Démarrage coupé, demande de mise à jour déjà traitée (vide) : toujours fermé' { $j -match 'rien n''est ouvert' -and $j -notmatch 'Démarrage Mindset' }
    $j = Start-MindsetDemarrage 'demarrage-oui' @{ LancerAvecWindows = $true; VerifVersions = $false }
    Test-Cas 'Démarrage activé : Mindset s''ouvre caché comme avant' { $j -match 'Démarrage Mindset .*, lancé avec Windows' }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '2. Les bulles de Mindset n''ouvrent jamais une appli avec une vieille notification'
    # -------------------------------------------------------------------------------------------------------------
    Import-Fonctions 'zone.ps1' @('Hide-Fenetre', 'Show-BulleMindset', 'Watch-NotificationsApplis', 'Open-BulleAppli')
    Import-Fonctions 'mindset.ps1' @('Show-BulleMajAuto')
    Import-Fonctions 'interface.ps1' @('Show-MessageErreurImprevue')
    $EnTest = $false   # (Show-MessageErreurImprevue ne montre rien en test ; ici la bulle est fausse)
    $script:Bulles = New-Object Collections.Generic.List[string]
    $script:IconeHorloge = New-Object PSObject
    $script:IconeHorloge | Add-Member ScriptMethod ShowBalloonTip { param($Duree, $Titre, $Texte, $Icone) $script:Bulles.Add([string]$Titre) }
    $Window = New-Object PSObject -Property @{ IsVisible = $false; WindowState = 'Normal' }
    $Window | Add-Member ScriptMethod Hide { }
    $script:Console = @{ Pret = $false }
    $script:Reglages = @{}
    function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.ContainsKey($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
    function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur }
    function Write-Log([string]$Texte) { }
    function Show-Fenetre { }
    $script:Ouvertes = New-Object Collections.Generic.List[string]
    function Open-AppliConsole([string]$Id) { $script:Ouvertes.Add($Id) }
    $donneesAppli = Join-Path $tmp 'donnees-appli'
    New-Item -ItemType Directory -Force -Path $donneesAppli | Out-Null
    $Applis = @([pscustomobject]@{ Id = 'appli'; Nom = 'Appli'; AfficherFichier = 'afficher.demande' })
    function Get-Appli([string]$Id) { $Applis | Where-Object { $_.Id -eq $Id } }
    function Get-DossierDonnees($Appli) { $donneesAppli }
    $fAfficher = Join-Path $donneesAppli 'afficher.demande'

    # Une notification de l'appli, dont Windows n'a jamais signalé la fermeture, puis une bulle de Mindset et un clic
    function Test-BulleMindset([scriptblock]$Bulle) {
        $script:Ouvertes.Clear(); $script:Bulles.Clear(); $script:BulleAppli = $null
        Remove-Item -LiteralPath $fAfficher -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText((Join-Path $donneesAppli 'notification.demande'), '{"titre":"Vieille notification","texte":"t","id":"0123456789ab"}', (New-Object Text.UTF8Encoding $false))
        Watch-NotificationsApplis
        if (-not $script:BulleAppli -or $script:Bulles.Count -ne 1) { throw 'la notification de l''appli n''a pas été montrée' }
        & $Bulle
        if ($script:Bulles.Count -ne 2) { throw 'la bulle de Mindset n''a pas été montrée' }
        Open-BulleAppli   # (le clic sur la bulle de Mindset)
        (-not $script:Ouvertes.Count) -and -not (Test-Path -LiteralPath $fAfficher)
    }
    Test-Cas 'Une vraie notification d''une appli ouvre bien l''appli et lui renvoie son numéro' {
        $script:Ouvertes.Clear(); $script:BulleAppli = $null; Remove-Item -LiteralPath $fAfficher -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText((Join-Path $donneesAppli 'notification.demande'), '{"titre":"Nouvelle","texte":"t","id":"abcdefabcdef"}', (New-Object Text.UTF8Encoding $false))
        Watch-NotificationsApplis; Open-BulleAppli
        ($script:Ouvertes -join ',') -eq 'appli' -and [IO.File]::ReadAllText($fAfficher) -eq 'notif:abcdefabcdef'
    }
    Test-Cas 'Clic sur « Mindset reste ici » : aucune appli ouverte, aucune vieille notification' { $script:Reglages.Remove('BulleHorlogeVue'); Test-BulleMindset { Hide-Fenetre } }
    Test-Cas 'Clic sur la bulle d''une mise à jour faite toute seule : rien d''ouvert' { Test-BulleMindset { Show-BulleMajAuto 'Nevermind est passé en 1.2.0' 'Corrections' } }
    Test-Cas 'Clic sur la bulle « Un petit problème est survenu » : rien d''ouvert' { Test-BulleMindset { Show-MessageErreurImprevue } }
    $EnTest = $true

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '3. Mise à jour de Mindset bloquée par des fichiers utilisés : un message juste'
    # -------------------------------------------------------------------------------------------------------------
    . (Join-Path $fichiers 'modules\paquets.ps1')
    function Test-Signature { $true }   # (la signature est testée par tester-securite.ps1 ; ici, seul le message compte)
    function New-ZipTest([string]$Dossier, [string]$Exe, [string]$Version) {
        $ms = New-Object IO.MemoryStream
        $za = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
        foreach ($k in @("$Dossier/$Exe", "$Dossier/fichiers/$Dossier.ps1")) {
            $w = New-Object IO.StreamWriter($za.CreateEntry($k).Open())
            $w.Write($(if ($k -like '*.ps1') { "`$AppVersion = '$Version'`r`n" } else { 'programme' })); $w.Dispose()
        }
        $za.Dispose()
        , $ms.ToArray()
    }
    # Installe par-dessus une version dont un fichier est tenu ouvert ; rend le message d'erreur et ce qui reste installé
    function Get-MessageBloque([string]$Dossier, [string]$Exe) {
        $dest = Join-Path $tmp "programmes\$Dossier"
        New-Item -ItemType Directory -Force -Path (Join-Path $dest 'fichiers') | Out-Null
        [IO.File]::WriteAllText((Join-Path $dest $Exe), 'ancien')
        [IO.File]::WriteAllText((Join-Path $dest "fichiers\$Dossier.ps1"), "`$AppVersion = '1.0.0'`r`n")
        $verrou = [IO.File]::Open((Join-Path $dest $Exe), 'Open', 'Read', 'None')
        $msg = ''
        try { $null = Install-Paquet -Zip (New-ZipTest $Dossier $Exe '1.1.0') -Signature ([byte[]]@(1)) -ClePublique 'x' -Destination $dest -DossierZip $Dossier -Exe $Exe }
        catch { $msg = $_.Exception.Message }
        finally { $verrou.Dispose() }
        @{ Message = $msg; Version = (Get-VersionDossier $dest) }
    }
    $r = Get-MessageBloque 'Mindset' 'Mindset.exe'
    Write-Host "         message : $($r.Message)"
    Test-Cas 'Mindset : le message ne demande pas de fermer l''appli ni de réessayer' { $r.Message -and $r.Message -notmatch 'ferme|réessaie|encore ouverte' -and $r.Message -match 'Mindset' -and $r.Message -match 'rien à faire' }
    Test-Cas 'Mindset : sa version actuelle reste installée' { $r.Version -eq '1.0.0' }
    Test-Cas 'Mindset : aucun tiret long dans le message' { $r.Message -notmatch "[$([char]0x2013)$([char]0x2014)]" }
    $r = Get-MessageBloque 'Evermind' 'Evermind.exe'
    Test-Cas 'Une autre appli : le message reste « ferme-la puis réessaie »' { $r.Message -match 'encore ouverte.*ferme-la puis réessaie' -and $r.Version -eq '1.0.0' }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie '4. Dossier qui manque quelques secondes pendant une opération : l''appli n''est pas effacée'
    # -------------------------------------------------------------------------------------------------------------
    Import-Fonctions 'installations.ps1' @('Get-Installation', 'Get-DossierGere', 'Test-DossierAppli', 'Get-VersionDans')
    $RacineProgrammes = Join-Path $tmp 'programmes-geres'
    $appliN = [pscustomobject]@{ Id = 'nevermind'; Nom = 'Nevermind'; Exe = 'Nevermind.exe'; Script = 'fichiers\Nevermind.ps1' }
    $dossierN = Join-Path $RacineProgrammes 'Nevermind'
    $script:Installs = @{}
    $script:Effaces = New-Object Collections.Generic.List[string]
    function Read-Installations([switch]$PourEcrire) { $c = @{}; foreach ($k in $script:Installs.Keys) { $c[$k] = $script:Installs[$k] }; $c }
    function Save-Installation([string]$Id, [string]$Dossier, [bool]$Gere) { if ($Dossier) { $script:Installs[$Id] = @{ Dossier = $Dossier; Gere = $Gere } } else { $script:Installs.Remove($Id); $script:Effaces.Add("installations:$Id") } }
    function Set-SuiteAppli([string]$Id, $Dossier) { if (-not $Dossier) { $script:Effaces.Add("suite:$Id") } }
    function Reset-Installs {
        $script:Installs = @{ nevermind = @{ Dossier = $dossierN; Gere = $true } }; $script:Effaces.Clear()
        Remove-Item -LiteralPath $dossierN -Recurse -Force -ErrorAction SilentlyContinue   # (dossier en plein échange : absent)
    }
    Reset-Installs; $script:Occupe = @{ nevermind = 'Installation...' }
    $i = Get-Installation $appliN
    Test-Cas 'Mise à jour en cours, dossier absent : rien n''est effacé de installations.json ni de suite.json' { -not $script:Effaces.Count -and $script:Installs.ContainsKey('nevermind') }
    Test-Cas '... et la carte la montre toujours installée (pas « Pas installé »)' { [bool]$i -and $i.Dossier -eq $dossierN -and $i.Gere }
    Reset-Installs; $script:Occupe = @{ nevermind = 'Désinstallation (accepte la demande de Windows)...' }
    $i = Get-Installation $appliN
    Test-Cas 'Désinstallation en cours : c''est sa fin qui retire l''appli, pas le relevé' { -not $script:Effaces.Count }
    Reset-Installs; $script:Occupe = @{ evermind = 'Installation...' }
    $i = Get-Installation $appliN
    Test-Cas 'Une autre appli occupée : le dossier vraiment disparu est bien oublié' { -not $i -and ($script:Effaces -join ',') -eq 'installations:nevermind,suite:nevermind' }
    Reset-Installs; $script:Occupe = @{}
    $i = Get-Installation $appliN
    Test-Cas 'Rien en cours : le dossier vraiment disparu est bien oublié' { -not $i -and ($script:Effaces -join ',') -eq 'installations:nevermind,suite:nevermind' }
    Reset-Installs; $script:Occupe = @{ nevermind = 'Installation...' }
    New-Item -ItemType Directory -Force -Path (Join-Path $dossierN 'fichiers') | Out-Null
    [IO.File]::WriteAllText((Join-Path $dossierN 'Nevermind.exe'), 'x'); [IO.File]::WriteAllText((Join-Path $dossierN 'fichiers\Nevermind.ps1'), "`$AppVersion = '1.4.0'`r`n")
    $i = Get-Installation $appliN
    Test-Cas 'Opération en cours, dossier présent : la version est lue comme d''habitude' { $i.Version -eq '1.4.0' -and -not $script:Effaces.Count }
}
catch {
    $script:Echoues += "Arrêt inattendu : $($_.Exception.Message)"
    Write-Host "  ÉCHEC  Arrêt inattendu : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
}
finally {
    # Seuls les Mindset de test lancés ici sont fermés (par leur numéro), puis le dossier de test est retiré
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
