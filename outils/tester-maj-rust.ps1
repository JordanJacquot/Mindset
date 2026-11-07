# Mindset en Rust : la mise à jour depuis la version PowerShell ne perd rien. LE test obligatoire avant de publier 3.0
# (décision de Jordan : pas de version d'essai, 3.0 part chez tout le monde). SUR GITHUB SEULEMENT (job « Mise à jour
# depuis la version PowerShell » de .github\workflows\tests.yml) : il installe Mindset pour de vrai dans Program Files,
# inscrit de vraies tâches planifiées, écrit dans HKLM et dans %LOCALAPPDATA%\Mindset du compte, lance de vrais Mindset ;
# la machine de GitHub est jetée après. Sur un PC, il refuse de tourner.
#
#   & '.\outils\tester-maj-rust.ps1' -Ancienne <Mindset.zip publié de 2.18.0> -Nouveau <dossier Mindset en Rust construit>
#                                    -Suivant <le même, construit avec le numéro suivant (3.0.1)>
#
# Comme chez un utilisateur (ici runneradmin, installé sur C:) :
#   1. Mindset 2.18.0 (le zip publié, vérifié avec les vraies clés ; la clé de TEST ajoutée à ses clés publiques) est
#      installé par son propre installateur (installer-admin.ps1 -Action mindset, le relais vers son
#      MindsetInstallateur.exe) : Program Files\Mindset\Mindset, tâches \Mindset\, « Applications installées ».
#   2. Des données inventées, comme chez quelqu'un qui s'en sert : réglages (des vrais, dont LancerAvecWindows, et des
#      inventés aux accents), installations.json avec Nevermind (Rust), Mindcare (Rust) et Evermind (PowerShell) dans
#      Program Files\Mindset et leurs données, suite.json, l'historique des mises à jour, le dossier WebView2 commun de
#      la suite (Evermind s'en sert encore), les raccourcis du Bureau et du menu Démarrer. Mindset 2.18 est lancé pour de
#      vrai (-Demarrage, caché) puis arrêté : il écrit ses fichiers. Puis tout est relevé (chaque fichier, son empreinte,
#      chaque champ des JSON).
#   3. 2.18 -> 3.0 : la demande « mindset-maj » de 2.18 (les mêmes champs que Start-MajMindset de mindset.ps1, contrôlé
#      ici) passe par la tâche SYSTEM : c'est l'installateur de 2.18 qui installe le zip 3.0 (construit par la CI, signé
#      par la clé de TEST), refait les tâches et relance Mindset par sa tâche de démarrage : le NOUVEAU Mindset.exe.
#   4. 3.0 -> 3.0.1 : la même demande (celle que doit écrire Mindset 3.0, même protocole), cette fois faite par
#      l'installateur de 3.0 (Rust, du zip 3.0), vers un zip 3.0.1.
#   Après chaque mise à jour : la bonne version installée (version.json), plus de Mindset.ps1 ni de modules, le relais
#   installer-admin.ps1 et fichiers\version.ps1 là, rien de l'ancien dossier à côté, les tâches pointent vers le nouvel
#   installateur et Mindset.exe -Demarrage, « Applications installées » à jour (version, désinstalleur), le nouveau
#   Mindset relancé ; puis, Mindset arrêté : rien de perdu (chaque fichier encore là et lisible, un fichier qui n'est
#   pas du JSON identique, un JSON garde chaque champ et chaque élément d'avant, les réglages choisis gardent leur valeur),
#   les applis toujours là (dossiers de programmes identiques, installations.json), les raccourcis intacts, le démarrage
#   avec Windows toujours en place (tâche de démarrage active, LancerAvecWindows gardé).
#   Ce que fait Mindset 3.0 lui-même à son démarrage (dépend des blocs : marqué « appli ») : son journal dit
#   « Démarrage Mindset 3.0.0 (Rust), lancé avec Windows », il a lu le résultat de la mise à jour (MajMindsetDemande
#   vidé) et noté la mise à jour dans l'historique.
#   Contre-épreuve : la comparaison doit voir un fichier retiré, un champ retiré et un réglage changé.
# Ce qui change à chaque lancement n'est pas comparé : journal.txt, etat.json, les demandes (*.demande), les marques
# (*.marque), telechargements\, console-logos\, les dossiers WebView2 (sauf le fichier témoin du dossier commun), les
# réglages que Mindset écrit lui-même (MajMindsetDemande, MajMindsetVisible, TachesRefaitesPour...) ; d'une copie de
# secours (*.bak), seulement qu'elle est encore là.
# Code de sortie 1 si un cas échoue.
param(
    [Parameter(Mandatory = $true)][string]$Ancienne,
    [Parameter(Mandatory = $true)][string]$Nouveau,
    [Parameter(Mandatory = $true)][string]$Suivant
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:RUNNER_TEMP) {
    Write-Host 'Refusé : ce test installe Mindset pour de vrai (Program Files, tâches planifiées, registre, données du compte). Il ne tourne que sur la machine jetable de GitHub Actions.' -ForegroundColor Red
    exit 2
}
. (Join-Path $PSScriptRoot 'contenu-rust.ps1')
$depot = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$base = Join-Path $env:RUNNER_TEMP 'maj-mindset'
$PowerShellExe = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
$Schtasks = Join-Path ([Environment]::GetFolderPath('System')) 'schtasks.exe'
$ProgrammesC = Join-Path $env:ProgramFiles 'Mindset'
$MindsetC = Join-Path $ProgrammesC 'Mindset'
$CleInstallation = 'HKLM:\SOFTWARE\Mindset\Installation'
$CleDesinstall = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset'
$Moi = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$SuiteDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Mindset'
$DataDir = Join-Path $SuiteDir 'Mindset'
$Telechargements = Join-Path $DataDir 'telechargements'
$Raccourcis = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mindset.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Mindset.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Nevermind.lnk'))
$sansBom = New-Object Text.UTF8Encoding($false)

$script:Echecs = New-Object Collections.Generic.List[string]
$script:Reussis = 0
$script:Notes = New-Object Collections.Generic.List[string]
function Write-Partie([string]$T) { Write-Host ''; Write-Host $T -ForegroundColor Cyan }
function Add-Note([string]$T) { $script:Notes.Add($T); Write-Host "  NOTE   $T" -ForegroundColor Yellow }
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) { $script:Reussis++; Write-Host "  OK     $Nom" -ForegroundColor Green }
    else { $script:Echecs.Add($Nom); Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red }
}
function Wait-Jusque([scriptblock]$Condition, [double]$Secondes) {
    $fin = (Get-Date).AddSeconds($Secondes)
    do { try { if (& $Condition) { return $true } } catch {}; Start-Sleep -Milliseconds 500 } while ((Get-Date) -lt $fin)
    $false
}
function Read-Json([string]$F) { if (-not (Test-Path -LiteralPath $F)) { return $null }; try { [IO.File]::ReadAllText($F, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $null } }
function Get-Valeur([string]$Nom) { try { [string](Get-ItemProperty -Path $CleInstallation -Name $Nom -ErrorAction Stop).$Nom } catch { '' } }
function New-Signature([string]$Fichier) {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString([IO.File]::ReadAllText((Join-Path $base 'cle\privee-test.xml')))
        [IO.File]::WriteAllBytes("$Fichier.sig", $rsa.SignData([IO.File]::ReadAllBytes($Fichier), [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')))
    } finally { $rsa.Dispose() }
}
# Les programmes qui tournent depuis un dossier (par leur chemin, jamais par leur nom)
function Get-ProgrammesDans([string]$Dossier) {
    $dans = $Dossier.TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and ([string]$_.ExecutablePath).StartsWith($dans, [StringComparison]::OrdinalIgnoreCase) })
}
function Stop-ProgrammesDans([string]$Dossier) {
    foreach ($p in Get-ProgrammesDans $Dossier) { Write-Host "         | arrêté : $($p.ExecutablePath) ($($p.ProcessId))" -ForegroundColor DarkGray; try { Stop-Process -Id $p.ProcessId -Force } catch {} }
    $null = Wait-Jusque { -not @(Get-ProgrammesDans $Dossier).Count } 15
}
function Get-InfoTache([string]$Nom) {
    try { $x = [xml](Export-ScheduledTask -TaskPath '\Mindset\' -TaskName $Nom -ErrorAction Stop) } catch { return $null }
    [pscustomobject]@{ Commande = [string]$x.Task.Actions.Exec.Command; Arguments = [string]$x.Task.Actions.Exec.Arguments; Active = ([string]$x.Task.Settings.Enabled -ne 'false'); Compte = [string]$x.Task.Principals.Principal.UserId }
}
function Get-Lnk([string]$F) { $s = (New-Object -ComObject WScript.Shell).CreateShortcut($F); "$($s.TargetPath)|$($s.Arguments)|$($s.WorkingDirectory)" }
function Get-EmpreinteDossier([string]$D) {
    @(Get-ChildItem -LiteralPath $D -Recurse -File -Force | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($D.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join ';'
}

# Le relevé du dossier des données de la suite : chemin relatif -> @{ Hash; Json (le texte de chaque champ ou élément) }
$volatils = '^(Mindset\\(journal\.txt|etat\.json|[^\\]+\.demande|[^\\]+\.marque|maj-mindset\.json|telechargements\\.*|console-logos\\.*)|[^\\]+\\journal\.txt|[^\\]+\\etat\.json|WebView2-Tauri\\.*|WebView2\\(?!temoin-evermind\.txt$).*)$'
function Get-Releve {
    $r = [ordered]@{}
    foreach ($f in @(Get-ChildItem -LiteralPath $SuiteDir -Recurse -File -Force | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($SuiteDir.Length + 1)
        if ($rel -match $volatils) { continue }
        $e = @{ Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash; Json = $null }
        if ($f.Extension -ieq '.json') {
            try {
                $o = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
                $champs = @{}
                if ($o -is [Management.Automation.PSCustomObject]) { foreach ($p in $o.PSObject.Properties) { $champs["champ:$($p.Name)"] = ConvertTo-Json $p.Value -Depth 20 -Compress } }
                elseif ($o -is [array]) { foreach ($x in $o) { $champs["élément:$(ConvertTo-Json $x -Depth 20 -Compress)"] = '' } }
                $e.Json = $champs
            } catch { $e.Json = 'illisible' }
        }
        $r[$rel] = $e
    }
    $r
}
# Les réglages que Mindset écrit lui-même (leur valeur peut changer ; le champ, lui, reste)
$ReglagesVivants = @('MajMindsetDemande', 'MajMindsetVisible', 'TachesRefaitesPour', 'DemarrageRepris', 'BulleHorlogeVue', 'DerniereRelanceTheme', 'MajAutoEssais', 'DerniereVerif')
# Les différences entre deux relevés : ce qui a été perdu (une liste vide : rien)
function Compare-Releves($Avant, $Apres, [hashtable]$Choisis) {
    $perdu = @()
    foreach ($rel in $Avant.Keys) {
        $a = $Avant[$rel]; $b = $Apres[$rel]
        if (-not $b) { $perdu += "$rel disparu"; continue }
        if ($a.Json -is [hashtable]) {
            if ($b.Json -isnot [hashtable]) { $perdu += "$rel illisible"; continue }
            foreach ($k in $a.Json.Keys) {
                if (-not $b.Json.ContainsKey($k)) { $perdu += "$rel : $k perdu"; continue }
                $nom = $k -replace '^champ:', ''
                $vivant = $rel -eq 'Mindset\reglages.json' -and $ReglagesVivants -contains $nom
                if ($k.StartsWith('champ:') -and -not $vivant -and $rel -notmatch '\\mises-a-jour\.json$' -and $b.Json[$k] -cne $a.Json[$k]) { $perdu += "$rel : $nom changé ($($a.Json[$k]) -> $($b.Json[$k]))" }
            }
        } elseif ($rel -match '\.bak$') { }
        elseif ($b.Hash -ne $a.Hash) { $perdu += "$rel changé" }
    }
    foreach ($n in $Choisis.Keys) {
        $b = $Apres['Mindset\reglages.json']
        if (-not $b -or $b.Json -isnot [hashtable] -or $b.Json["champ:$n"] -cne $Choisis[$n]) { $perdu += "réglage $n : $($Choisis[$n]) attendu" }
    }
    $perdu
}

# La demande « mindset-maj » écrite comme Mindset la fait, passée par la tâche SYSTEM ; rend son numéro
function Send-MajMindset([string]$Version, [string]$Zip, [int]$AttendrePid) {
    New-Item -ItemType Directory -Force -Path $Telechargements | Out-Null
    Copy-Item -LiteralPath $Zip -Destination (Join-Path $Telechargements 'mindset.zip') -Force
    Copy-Item -LiteralPath "$Zip.sig" -Destination (Join-Path $Telechargements 'mindset.zip.sig') -Force
    $id = [guid]::NewGuid().ToString('N')
    # (ce que Start-MajMindset écrit avant la demande : le numéro dans les réglages, la mise à jour attendue dans l'historique)
    $fr = Join-Path $DataDir 'reglages.json'
    $r = Read-Json $fr; if (-not $r) { $r = [pscustomobject]@{} }
    foreach ($p in @(@('MajMindsetDemande', $id), @('MajMindsetVisible', $false))) { $r | Add-Member -NotePropertyName $p[0] -NotePropertyValue $p[1] -Force }
    [IO.File]::WriteAllText($fr, ($r | ConvertTo-Json -Depth 10), $sansBom)
    $fh = Join-Path $DataDir 'mises-a-jour.json'
    $h = Read-Json $fh; $liste = if ($h) { @($h.historique) } else { @() }
    [IO.File]::WriteAllText($fh, (ConvertTo-Json -InputObject ([ordered]@{ historique = $liste; mindsetAttendu = [ordered]@{ id = 'mindset'; nom = 'Mindset'; version = $Version; quand = (Get-Date).ToString('s'); auto = $true; notes = "Mindset $Version" } }) -Depth 6), $sansBom)
    $c = [ordered]@{ Id = $id; Action = 'mindset-maj'; Zip = (Join-Path $Telechargements 'mindset.zip'); Signature = (Join-Path $Telechargements 'mindset.zip.sig'); Destination = $MindsetC; Version = $Version; AttendrePid = [string]$AttendrePid; Cache = '1' }
    [IO.File]::WriteAllText((Join-Path $DataDir 'installation.demande'), (ConvertTo-Json -InputObject $c -Compress), $sansBom)
    $null = & $Schtasks /Run /TN '\Mindset\Mindset (installation)' 2>&1
    if ($LASTEXITCODE) { throw "la tâche d'installation n'a pas démarré (code $LASTEXITCODE)" }
    $id
}

# Après une mise à jour : installée, tâches, registre, relance ; puis Mindset arrêté et rien de perdu
function Test-ApresMaj([string]$Version, [string]$Id, $Avant, [hashtable]$Choisis, [string]$Installateur) {
    $fini = Wait-Jusque { $v = Get-Valeur 'Resultat'; $v -and $v -match $Id } 240
    $res = Get-Valeur 'Resultat' | ConvertFrom-Json -ErrorAction SilentlyContinue
    Write-Host "         | réponse de l'installateur : $(Get-Valeur 'Resultat')" -ForegroundColor DarkGray
    Test-Cas "$Version : l'installateur $Installateur répond « ok » à la demande, par la tâche SYSTEM" { $fini -and $res.ok -eq $true -and $res.id -eq $Id }
    Test-Cas "$Version : installé (version.json « mindset » $Version), sans Mindset.ps1 ni modules, avec le relais et version.ps1" {
        $vj = Read-Json (Join-Path $MindsetC 'version.json')
        $vj.appli -eq 'mindset' -and $vj.version -eq $Version -and -not (Test-Path -LiteralPath (Join-Path $MindsetC 'fichiers\Mindset.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $MindsetC 'fichiers\modules')) -and
            (Test-Path -LiteralPath (Join-Path $MindsetC 'fichiers\installer-admin.ps1')) -and ([IO.File]::ReadAllText((Join-Path $MindsetC 'fichiers\version.ps1')) -match "\`$AppVersion = '$([regex]::Escape($Version))'")
    }
    Test-Cas "$Version : exactement les fichiers du zip dans Program Files\Mindset\Mindset" {
        $vus = @(Get-ChildItem -LiteralPath $MindsetC -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($MindsetC.Length + 1) } | Sort-Object)
        $attendus = @(Get-ChildItem -LiteralPath (Join-Path $base "zip-$Version\Mindset") -Recurse -File | ForEach-Object { $_.FullName.Substring((Join-Path $base "zip-$Version\Mindset").Length + 1) } | Sort-Object)
        if (($vus -join '|') -ne ($attendus -join '|')) { throw "vus : $($vus -join ', ')" }
        $true
    }
    Test-Cas "$Version : rien de l'ancien dossier à côté (Mindset.ancien-*, Mindset.nouveau-*)" { -not @(Get-ChildItem -LiteralPath $ProgrammesC -Directory -Force | Where-Object { $_.Name -like 'Mindset.*' }).Count }
    Test-Cas "$Version : la tâche SYSTEM lance le nouveau MindsetInstallateur.exe pour ce compte, la tâche de démarrage le nouveau Mindset.exe -Demarrage, active" {
        $i = Get-InfoTache 'Mindset (installation)'; $d = Get-InfoTache 'Mindset (démarrage)'
        Write-Host "         | tâches : $($i.Commande) $($i.Arguments) ; $($d.Commande) $($d.Arguments) (active : $($d.Active))" -ForegroundColor DarkGray
        $i -and $i.Commande -eq "`"$MindsetC\MindsetInstallateur.exe`"" -and $i.Arguments.StartsWith("-Action demande -Sid $Moi ") -and
            $d -and $d.Commande -eq "`"$MindsetC\Mindset.exe`"" -and $d.Arguments -eq '-Demarrage' -and $d.Active
    }
    Test-Cas "$Version : « Applications installées » à jour (version $Version, le désinstalleur en Rust)" {
        $k = Get-ItemProperty -Path $CleDesinstall
        $k.DisplayVersion -eq $Version -and $k.UninstallString -eq "`"$MindsetC\Desinstaller Mindset.exe`"" -and $k.InstallLocation -eq $MindsetC
    }
    # La relance par la tâche de démarrage (le nouveau Mindset, caché près de l'horloge)
    $relance = Wait-Jusque { @(Get-ProgrammesDans $MindsetC | Where-Object { $_.Name -ieq 'Mindset.exe' }).Count } 90
    if (-not $relance) {
        Add-Note "$Version : Mindset pas relancé par sa tâche de démarrage en 90 s (pas de session ouverte pour runneradmin ?) : lancé par le test, -Demarrage"
        Start-Process -FilePath (Join-Path $MindsetC 'Mindset.exe') -ArgumentList '-Demarrage' -WorkingDirectory $MindsetC -WindowStyle Hidden | Out-Null
    }
    Test-Cas "$Version : le nouveau Mindset.exe tourne (relancé après la mise à jour)" { Wait-Jusque { @(Get-ProgrammesDans $MindsetC | Where-Object { $_.Name -ieq 'Mindset.exe' }).Count } 30 }
    $journal = Join-Path $DataDir 'journal.txt'
    $vu = Wait-Jusque { (Test-Path -LiteralPath $journal) -and ([IO.File]::ReadAllText($journal, [Text.Encoding]::UTF8) -match "D$([char]0xE9)marrage Mindset $([regex]::Escape($Version)) \(Rust\)") } 60
    Start-Sleep -Seconds 20   # (le temps de lire le résultat et d'écrire ses fichiers)
    Stop-ProgrammesDans $MindsetC
    Test-Cas "$Version (appli) : son journal dit « Démarrage Mindset $Version (Rust) »" { $vu }
    Test-Cas "$Version (appli) : il a lu le résultat de la mise à jour (MajMindsetDemande vidé) et l'a noté dans l'historique" {
        $r = Read-Json (Join-Path $DataDir 'reglages.json'); $h = Read-Json (Join-Path $DataDir 'mises-a-jour.json')
        -not [string]$r.MajMindsetDemande -and -not $h.mindsetAttendu -and @($h.historique | Where-Object { $_.id -eq 'mindset' -and $_.version -eq $Version }).Count
    }
    $apres = Get-Releve
    Test-Cas "$Version : rien de perdu dans les données de la suite ($($Avant.Count) fichiers relevés avant)" {
        $p = @(Compare-Releves $Avant $apres $Choisis)
        if ($p.Count) { throw ($p -join ' ; ') }
        $true
    }
    Test-Cas "$Version : les applis toujours là (Nevermind, Mindcare, Evermind : dossiers de programmes identiques, installations.json)" {
        $ok = $true
        foreach ($a in $script:Applis.Keys) { if ((Get-EmpreinteDossier (Join-Path $ProgrammesC $a)) -ne $script:Applis[$a]) { Write-Host "         | $a changé" -ForegroundColor DarkGray; $ok = $false } }
        $inst = Read-Json (Join-Path $DataDir 'installations.json')
        $ok -and $inst.nevermind.dossier -eq "$ProgrammesC\Nevermind" -and $inst.mindcare.dossier -eq "$ProgrammesC\Mindcare" -and $inst.evermind.dossier -eq "$ProgrammesC\Evermind"
    }
    Test-Cas "$Version : les raccourcis intacts (Bureau, menu Démarrer : Mindset et Nevermind)" {
        -not @($Raccourcis | Where-Object { -not (Test-Path -LiteralPath $_) -or (Get-Lnk $_) -ne $script:Lnk[$_] }).Count
    }
    Test-Cas "$Version : démarrage avec Windows toujours en place (LancerAvecWindows gardé, tâche de démarrage active, pas de ligne Run ajoutée)" {
        $r = Read-Json (Join-Path $DataDir 'reglages.json')
        $run = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Mindset' -ErrorAction SilentlyContinue)
        $r.LancerAvecWindows -eq $true -and (Get-InfoTache 'Mindset (démarrage)').Active -and -not $run
    }
    $apres
}

try {
    Write-Partie '0. Préparation : machine vide, clé de TEST, zips 3.0 et 3.0.1 signés, Mindset 2.18 publié'
    Stop-ProgrammesDans $ProgrammesC
    foreach ($t in @(Get-ScheduledTask -TaskPath '\Mindset\' -ErrorAction SilentlyContinue)) { Unregister-ScheduledTask -TaskPath '\Mindset\' -TaskName $t.TaskName -Confirm:$false }
    foreach ($d in $ProgrammesC, $SuiteDir, $base) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
    foreach ($c in 'HKLM:\SOFTWARE\Mindset', $CleDesinstall) { Remove-Item -Path $c -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path "$base\cle" | Out-Null
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    try { $rsa.PersistKeyInCsp = $false; [IO.File]::WriteAllText("$base\cle\privee-test.xml", $rsa.ToXmlString($true)); [IO.File]::WriteAllText("$base\cle\publique-test.xml", $rsa.ToXmlString($false)) } finally { $rsa.Dispose() }

    # Mindset 2.18 : le zip publié, signé par la vraie clé (vérifié avec les clés du dépôt), puis la clé de TEST ajoutée
    . (Join-Path $depot 'Mindset\fichiers\modules\signature.ps1')
    $ancien = (Resolve-Path -LiteralPath $Ancienne).Path
    Test-Cas 'le zip de Mindset 2.18 est bien le zip publié (signature de la vraie clé)' {
        Test-Signature ([IO.File]::ReadAllBytes($ancien)) ([IO.File]::ReadAllBytes("$ancien.sig")) (Join-Path $depot 'Mindset\fichiers\cles-publiques')
    }
    Expand-Archive -LiteralPath $ancien -DestinationPath "$base\v2.18"
    $src218 = "$base\v2.18\Mindset"
    $versionAncienne = if ([IO.File]::ReadAllText("$src218\fichiers\Mindset.ps1", [Text.Encoding]::UTF8) -match "(?m)^\`$AppVersion = '([\d.]+)'") { $Matches[1] } else { '' }
    Copy-Item -LiteralPath "$base\cle\publique-test.xml" -Destination "$src218\fichiers\cles-publiques\essai-test.xml"
    # La demande de mise à jour de 2.18 : ses champs (Start-MajMindset), pour écrire ici exactement la même
    $champs218 = if ([IO.File]::ReadAllText("$src218\fichiers\modules\mindset.ps1", [Text.Encoding]::UTF8) -match "\`$c = @\{ (Id = [^\r\n]*AttendrePid = \[string\]\`$PID) \}") { @([regex]::Matches($Matches[1], '(\w+) = ') | ForEach-Object { $_.Groups[1].Value }) } else { @() }
    Test-Cas "Mindset $versionAncienne : la demande « mindset-maj » de Start-MajMindset a les champs que ce test écrit (Id, Action, Zip, Signature, Destination, Version, AttendrePid, et Cache)" { ($champs218 -join ',') -eq 'Id,Action,Zip,Signature,Destination,Version,AttendrePid' }

    # Les zips 3.0 et 3.0.1 : les deux dossiers construits par la CI (le second avec le numéro suivant, construit pour de
    # vrai : son Mindset.exe dit 3.0.1), clé de TEST ajoutée, signés par elle
    $versions = @()
    foreach ($dossier in $Nouveau, $Suivant) {
        $source = [IO.Path]::GetFullPath($dossier)
        $v = (Read-Json (Join-Path $source 'version.json')).version
        $d = "$base\zip-$v\Mindset"
        Copy-Item -LiteralPath $source -Destination $d -Recurse
        Copy-Item -LiteralPath "$base\cle\publique-test.xml" -Destination "$d\fichiers\cles-publiques\essai-test.xml"
        Compress-Archive -LiteralPath $d -DestinationPath "$base\Mindset-$v.zip" -Force
        New-Signature "$base\Mindset-$v.zip"
        $versions += $v
    }
    $version30, $version301 = $versions
    Test-Cas "les deux versions en Rust se suivent ($version30 puis $version301)" { $version30 -and $version301 -and [version]$version301 -gt [version]$version30 }
    Write-Host "  zips : Mindset $version30 et $version301 (Rust), Mindset $versionAncienne (PowerShell, publié)"

    Write-Partie "1. Mindset $versionAncienne installé par son installateur, données inventées, puis lancé pour de vrai"
    $fr = "$base\installation.json"
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File "$src218\fichiers\installer-admin.ps1" -Action mindset -Source $src218 -Version $versionAncienne -Sid $Moi -Resultat $fr | Out-Host
    $r = Read-Json $fr
    Test-Cas "Mindset $versionAncienne installé dans Program Files\Mindset\Mindset (tâches, « Applications installées »)" {
        $r.ok -and (Test-Path -LiteralPath "$MindsetC\fichiers\Mindset.ps1") -and (Get-InfoTache 'Mindset (installation)').Commande -eq "`"$MindsetC\MindsetInstallateur.exe`"" -and (Get-ItemProperty -Path $CleDesinstall).DisplayVersion -eq $versionAncienne
    }
    # Les applis : Nevermind et Mindcare en Rust (version.json), Evermind en PowerShell (son script), gérées par Mindset
    $script:Applis = [ordered]@{}
    $apps = @(
        @{ Id = 'nevermind'; Nom = 'Nevermind'; Fichiers = @{ 'Mindset.exe' = 'nevermind'; 'Nevermind.exe' = 'relais'; 'NevermindAide.exe' = 'aide'; 'version.json' = '{"appli":"nevermind","version":"2.0.2","mindset_min":"2.18.0"}' } }
        @{ Id = 'mindcare'; Nom = 'Mindcare'; Fichiers = @{ 'Mindset.exe' = 'mindcare'; 'Mindcare.exe' = 'relais'; 'version.json' = '{"appli":"mindcare","version":"1.0.0","mindset_min":"2.18.0"}' } }
        @{ Id = 'evermind'; Nom = 'Evermind'; Fichiers = @{ 'Evermind.exe' = 'lanceur'; 'fichiers\Evermind.ps1' = "`$AppVersion = '0.20.0'`r`n" } }
    )
    $installations = [ordered]@{}
    foreach ($a in $apps) {
        $d = Join-Path $ProgrammesC $a.Nom
        foreach ($f in $a.Fichiers.Keys) { New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $d $f) -Parent) | Out-Null; [IO.File]::WriteAllText((Join-Path $d $f), $a.Fichiers[$f], $sansBom) }
        New-Item -ItemType Directory -Force -Path (Join-Path $SuiteDir $a.Nom) | Out-Null
        [IO.File]::WriteAllText((Join-Path $SuiteDir "$($a.Nom)\parametres.json"), "{`"EssaiMaj`":`"garder-moi $($a.Nom)`",`"Nombre`":7}", $sansBom)
        $installations[$a.Id] = [ordered]@{ dossier = $d; gere = $true }
        $script:Applis[$a.Nom] = Get-EmpreinteDossier $d
    }
    New-Item -ItemType Directory -Force -Path $DataDir, "$SuiteDir\WebView2" | Out-Null
    [IO.File]::WriteAllText("$DataDir\installations.json", ($installations | ConvertTo-Json -Depth 4), $sansBom)
    [IO.File]::WriteAllText("$SuiteDir\suite.json", '{"theme":"neon","applis":{"nevermind":"C:\\Program Files\\Mindset\\Nevermind"},"son":{"micro":"","casque":""}}', $sansBom)
    [IO.File]::WriteAllText("$SuiteDir\WebView2\temoin-evermind.txt", "Le dossier WebView2 commun (Evermind s'en sert encore) : à garder, é à ü", $sansBom)
    [IO.File]::WriteAllText("$DataDir\mises-a-jour.json", (ConvertTo-Json -InputObject ([ordered]@{ historique = @([ordered]@{ id = 'nevermind'; nom = 'Nevermind'; version = '2.0.2'; quand = '2026-11-06T21:00:00'; auto = $true; notes = 'Nevermind 2.0.2' }); mindsetAttendu = $null }) -Depth 5), $sansBom)
    $script:Choisis = [ordered]@{ LancerAvecWindows = 'true'; VerifVersions = 'false'; MajAuto = 'false'; 'Ouverture-nevermind' = '3.4'; EssaiMaj = '"garder-moi"'; EssaiAccents = "`"é à ü œ ç`""; EssaiListe = '["un","deux"]' }
    $reglages = [ordered]@{ LancerAvecWindows = $true; VerifVersions = $false; MajAuto = $false; 'Ouverture-nevermind' = 3.4; EssaiMaj = 'garder-moi'; EssaiAccents = 'é à ü œ ç'; EssaiListe = @('un', 'deux') }
    [IO.File]::WriteAllText("$DataDir\reglages.json", ($reglages | ConvertTo-Json -Depth 5), $sansBom)
    # Les raccourcis (comme Install-Mindset et Update-RaccourciAppli)
    $sh = New-Object -ComObject WScript.Shell
    $script:Lnk = @{}
    foreach ($l in $Raccourcis) {
        $cible = if ($l -like '*Nevermind.lnk') { "$ProgrammesC\Nevermind\Nevermind.exe" } else { "$MindsetC\Mindset.exe" }
        New-Item -ItemType Directory -Force -Path (Split-Path $l -Parent) | Out-Null
        $s = $sh.CreateShortcut($l); $s.TargetPath = $cible; $s.WorkingDirectory = (Split-Path $cible -Parent); $s.Save()
        $script:Lnk[$l] = Get-Lnk $l
    }
    # Mindset 2.18 lancé pour de vrai, caché (comme au démarrage de Windows), le temps d'écrire ses fichiers
    $p = Start-Process -FilePath "$MindsetC\Mindset.exe" -ArgumentList '-Demarrage' -WorkingDirectory $MindsetC -PassThru
    $parti = Wait-Jusque { (Test-Path -LiteralPath "$DataDir\journal.txt") -and ([IO.File]::ReadAllText("$DataDir\journal.txt", [Text.Encoding]::UTF8) -match "D$([char]0xE9)marrage Mindset $([regex]::Escape($versionAncienne))") } 180
    Start-Sleep -Seconds 25
    Stop-ProgrammesDans $MindsetC
    Test-Cas "Mindset $versionAncienne a démarré pour de vrai (son journal), puis a été arrêté" { $parti }
    $avant = Get-Releve
    Write-Host "  relevé : $($avant.Count) fichiers ($(@($avant.Keys) -join ', '))"
    Test-Cas "Mindset $versionAncienne a gardé les données inventées (sinon ce test ne prouverait rien)" {
        $i = $avant['Mindset\installations.json']
        -not @(Compare-Releves $avant $avant $script:Choisis).Count -and $i -and $i.Json -is [hashtable] -and
            -not @('nevermind', 'mindcare', 'evermind' | Where-Object { -not $i.Json.ContainsKey("champ:$_") }).Count -and
            $avant.Contains('Nevermind\parametres.json') -and $avant.Contains('Mindcare\parametres.json') -and $avant.Contains('Evermind\parametres.json') -and $avant.Contains('WebView2\temoin-evermind.txt')
    }
    Test-Cas 'contre-épreuve : la comparaison voit un fichier retiré, un champ retiré et un réglage changé' {
        $faux = [ordered]@{}; foreach ($k in $avant.Keys) { $faux[$k] = @{ Hash = $avant[$k].Hash; Json = $(if ($avant[$k].Json -is [hashtable]) { $avant[$k].Json.Clone() } else { $avant[$k].Json }) } }
        $faux.Remove('suite.json')
        $faux['Mindset\installations.json'].Json.Remove('champ:evermind')
        $faux['Mindset\reglages.json'].Json['champ:EssaiMaj'] = '"autre"'
        $p = @(Compare-Releves $avant $faux $script:Choisis)
        @($p | Where-Object { $_ -match '^suite\.json disparu' }).Count -and @($p | Where-Object { $_ -match 'evermind perdu' }).Count -and @($p | Where-Object { $_ -match 'EssaiMaj' }).Count
    }

    Write-Partie "2. Mise à jour $versionAncienne -> $version30 (Rust), faite par l'installateur de $versionAncienne"
    $id = Send-MajMindset $version30 "$base\Mindset-$version30.zip" 0
    $null = Test-ApresMaj $version30 $id $avant $script:Choisis "de $versionAncienne"

    Write-Partie "3. Mise à jour $version30 -> $version301, faite par l'installateur de $version30 (Rust)"
    $id = Send-MajMindset $version301 "$base\Mindset-$version301.zip" 0
    $null = Test-ApresMaj $version301 $id $avant $script:Choisis "de $version30 (Rust)"
} catch {
    $script:Echecs.Add("erreur : $($_.Exception.Message)")
    Write-Host "ERREUR : $($_.Exception.Message) $($_.ScriptStackTrace)" -ForegroundColor Red
} finally {
    try { Stop-ProgrammesDans $ProgrammesC } catch {}
    if (Test-Path -LiteralPath "$DataDir\journal.txt") { Write-Host ''; Write-Host '  (fin du journal de Mindset :)'; Get-Content -LiteralPath "$DataDir\journal.txt" -Tail 40 -Encoding UTF8 | ForEach-Object { "    $_" } }
}

Write-Host ''
$total = $script:Reussis + $script:Echecs.Count
if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "Mise à jour 2.18 -> 3.0 -> 3.0.1 : $($script:Reussis) sur $total$(if ($script:Echecs.Count) { ", ratés : $($script:Echecs -join ' ; ')" })$(if ($script:Notes.Count) { ", notes : $($script:Notes -join ' ; ')" })`n", $sansBom) }
if ($script:Echecs.Count) { Write-Host "Mise à jour depuis la version PowerShell : $($script:Echecs.Count) cas raté(s) sur $total." -ForegroundColor Red; exit 1 }
Write-Host "Mise à jour depuis la version PowerShell : $($script:Reussis) cas sur $total, rien de perdu." -ForegroundColor Green
exit 0
