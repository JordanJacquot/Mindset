# Mindset : où sont les applis, et ce qu'on peut en faire (installer, mettre à jour, prendre en charge, ouvrir, désinstaller).
# Chargé par Mindset.ps1 après applis.ps1 et taches.ps1.
#
# Une appli gérée par Mindset :
#   programme   C:\Program Files\Mindset\<Appli>     (seul un administrateur peut y écrire : installer-admin.ps1)
#   données     %LOCALAPPDATA%\Mindset\<Appli>      (l'appli y déplace elle-même ses anciennes données)
#   aucun raccourci direct ni lancement au démarrage à elle : tout passe par Mindset.
# Une copie trouvée sur le PC (téléchargée avant Mindset, ou un dossier de travail) peut être ouverte telle quelle,
# ou prise en charge : Mindset installe une copie gérée, retire les raccourcis et démarrages de l'ancienne, puis
# supprime l'ancienne copie (seulement les fichiers livrés avec l'appli, jamais un dossier de travail).

$InstallFile = Join-Path $DataDir 'installations.json'
$TelechargementsDir = Join-Path $DataDir 'telechargements'
$ClePublique = Join-Path $AppDir 'cles-publiques'   # la liste des clés publiques (voir signature.ps1)
$script:Publications = @{}   # id -> dernière version publiée (ou erreur)
$script:Occupe = @{}         # id -> texte de l'opération en cours
$script:Messages = @{}       # id -> dernier message affiché sur la carte
$script:EnCours = @{}        # id -> installation en cours (version, zip, ancienne copie)
$script:Progres = @{}        # id -> progression du téléchargement en cours (Recu, Total ; table partagée avec la tâche de fond)

function Get-DossierGere($Appli) { Join-Path $RacineProgrammes $Appli.Nom }

# Dossier de données d'une appli : celui de la suite si elle est gérée et l'a déjà adopté, sinon l'ancien
function Get-DossierDonnees($Appli) {
    $inst = (Read-Installations)[$Appli.Id]
    $suite = Join-Path $SuiteDir $Appli.Nom
    if ($inst -and $inst.Gere -and (Test-Path -LiteralPath $suite)) { $suite } else { $Appli.Donnees }
}

# (abîmé : mis de côté et repris de sa copie, voir Read-JsonSur ; -PourEcrire : une erreur s'il ne peut pas être lu)
function Read-Installations([switch]$PourEcrire) {
    $r = @{}
    try {
        $j = Read-JsonSur $InstallFile
        if ($null -ne $j) { foreach ($p in $j.PSObject.Properties) { $r[$p.Name] = @{ Dossier = [string]$p.Value.dossier; Gere = [bool]$p.Value.gere } } }
    } catch {
        if ($PourEcrire) { throw }
        Write-Log "installations.json illisible : $($_.Exception.Message)"
    }
    $r
}

function Save-Installation([string]$Id, [string]$Dossier, [bool]$Gere) {
    # (illisible pour l'instant : rien n'est écrit, plutôt que de remplacer la liste par une liste presque vide)
    try { $r = Read-Installations -PourEcrire } catch { Write-Log "installations.json pas modifié ($Id) : $($_.Exception.Message)"; return }
    if ($Dossier) { $r[$Id] = @{ Dossier = $Dossier; Gere = $Gere } } else { $r.Remove($Id) }
    $o = [ordered]@{}; foreach ($k in $r.Keys) { $o[$k] = @{ dossier = $r[$k].Dossier; gere = $r[$k].Gere } }
    if (-not $EnTest -or $env:MINDSET_DONNEES) { Save-JsonSur $InstallFile ($o | ConvertTo-Json -Depth 4) }
}

function Get-VersionDans([string]$Dossier, $Appli) {
    $f = Join-Path $Dossier $Appli.Script
    try { if ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) -match "(?m)^\`$AppVersion\s*=\s*'([\d.]+)'") { return $Matches[1] } } catch {}
    $null
}

function Test-DossierAppli([string]$Dossier, $Appli) {
    $Dossier -and (Test-Path -LiteralPath (Join-Path $Dossier $Appli.Exe)) -and (Test-Path -LiteralPath (Join-Path $Dossier $Appli.Script))
}

# L'installation connue d'une appli : @{ Dossier; Gere; Version } ou $null
function Get-Installation($Appli) {
    $r = (Read-Installations)[$Appli.Id]
    # installations.json est modifiable par n'importe quel programme : une installation « gérée » n'est crue que dans le
    # dossier protégé des programmes (un Mindset administrateur ne lance jamais un programme qu'on aurait glissé ailleurs)
    if ($r -and $r.Gere -and $r.Dossier -ine (Get-DossierGere $Appli)) { Write-Log "installations.json : $($Appli.Nom) « géré » hors de $(Get-DossierGere $Appli), ignoré"; $r = $null }
    if ($r -and (Test-DossierAppli $r.Dossier $Appli)) {
        return @{ Dossier = $r.Dossier; Gere = $r.Gere; Version = (Get-VersionDans $r.Dossier $Appli) }
    }
    # Pendant une opération sur l'appli (installation, mise à jour, désinstallation), son dossier peut manquer quelques
    # secondes (échange de l'ancien et du nouveau) : elle reste notée, c'est la fin de l'opération qui décide
    if ($r -and $script:Occupe -and $script:Occupe[$Appli.Id]) { return @{ Dossier = $r.Dossier; Gere = $r.Gere; Version = $null } }
    if ($r) { Save-Installation $Appli.Id $null $false; if ($r.Gere) { Set-SuiteAppli $Appli.Id $null } }
    # Copie gérée présente mais oubliée (installations.json effacé)
    $g = Get-DossierGere $Appli
    if (Test-DossierAppli $g $Appli) { Save-Installation $Appli.Id $g $true; Set-SuiteAppli $Appli.Id $g; return @{ Dossier = $g; Gere = $true; Version = (Get-VersionDans $g $Appli) } }
    $null
}

# ---------------------------------------------------------------------------
# Copies déjà présentes sur le PC
# ---------------------------------------------------------------------------
function Get-LieuxRaccourcis {
    @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'),
      [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('Startup')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}

# Raccourcis (.lnk) qui lancent cette appli, quelle que soit la copie
function Get-RaccourcisAppli($Appli) {
    $sh = New-Object -ComObject WScript.Shell
    foreach ($l in Get-LieuxRaccourcis) {
        foreach ($lnk in @(Get-ChildItem -LiteralPath $l -Filter *.lnk -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
            try { $t = $sh.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
            if ($t -and [IO.Path]::GetFileName($t) -ieq $Appli.Exe) { [pscustomobject]@{ Lien = $lnk.FullName; Cible = $t } }
        }
    }
}

# Entrées « lancer au démarrage » de l'utilisateur qui lancent cette appli
function Get-DemarragesAppli($Appli) {
    try { $run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop } catch { return }
    foreach ($p in $run.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        if ($p.Value -is [string] -and $p.Value -match ('^"?([^"]*\\' + [regex]::Escape($Appli.Exe) + ')"?')) { [pscustomobject]@{ Nom = $p.Name; Cible = $Matches[1] } }
    }
}

# Une copie déjà présente : raccourcis, démarrage, programme ouvert, puis Téléchargements, Bureau et Documents
function Find-InstallationExistante($Appli) {
    $candidats = New-Object System.Collections.Generic.List[string]
    foreach ($r in @(Get-RaccourcisAppli $Appli)) { $candidats.Add((Split-Path $r.Cible -Parent)) }
    foreach ($r in @(Get-DemarragesAppli $Appli)) { $candidats.Add((Split-Path $r.Cible -Parent)) }
    # Un programme ouvert : son dossier (l'ancien <Appli>.exe, ou l'hôte Mindset.exe d'une appli récente), vérifié ensuite
    # comme les autres candidats (Test-DossierAppli) ; jamais le dossier de Mindset lui-même
    foreach ($c in @([MSProcessus]::Chemins([string[]]@($Appli.Exe, 'Mindset.exe')))) {
        $d = Split-Path $c -Parent
        if ($d -ine $MonDossier) { $candidats.Add($d) }
    }
    $telech = Join-Path $env:USERPROFILE 'Downloads'
    foreach ($l in @($telech, [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'))) {
        if (-not $l -or -not (Test-Path -LiteralPath $l)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $l -Filter $Appli.Exe -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 5)) { $candidats.Add($f.DirectoryName) }
    }
    $gere = Get-DossierGere $Appli
    foreach ($c in $candidats | Select-Object -Unique) {
        if ($c -ine $gere -and (Test-DossierAppli $c $Appli)) { return $c }
    }
    $null
}

# ---------------------------------------------------------------------------
# Ouvrir : lancer l'appli, ou ramener sa fenêtre si elle tourne déjà
# ---------------------------------------------------------------------------
function Open-Appli($Appli, [switch]$Demarrage) {
    $inst = Get-Installation $Appli
    if (-not $inst) { return }
    # En cours d'installation : pas maintenant (elle démarrerait avec les anciens fichiers) ; elle est relancée à la fin
    if ($script:Occupe[$Appli.Id]) { $script:ARelancer[$Appli.Id] = $true; return }
    if (Test-AppliOuverte $Appli) {
        if ($Demarrage) { return }
        # Chaque appli a sa façon d'être réveillée : un fichier qu'elle surveille (Nevermind) ou un signal (Evermind).
        # Relancer son .exe marcherait aussi, mais pour Nevermind cela redemanderait l'autorisation de Windows.
        try { [void][MSNative]::AllowSetForegroundWindow(-1) } catch {}
        if ($Appli.AfficherSignal) {
            try { $ev = [System.Threading.EventWaitHandle]::OpenExisting($Appli.AfficherSignal); [void]$ev.Set(); $ev.Dispose(); return } catch {}
        }
        if ($Appli.AfficherFichier) {
            try { $f = Join-Path (Get-DossierDonnees $Appli) $Appli.AfficherFichier; New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null; [IO.File]::WriteAllText($f, [string]$PID); return } catch {}
        }
    }
    # Une appli récente a son hôte Mindset.exe dans son dossier (<Appli>.exe n'y est plus qu'un relais vers lui) : lancé
    # directement ; une ancienne version, par son <Appli>.exe
    $exe = Join-Path $inst.Dossier 'Mindset.exe'
    if (-not (Test-Path -LiteralPath $exe) -or $inst.Dossier -ieq $MonDossier) { $exe = Join-Path $inst.Dossier $Appli.Exe }
    # Mindset administrateur : seule une appli administrateur installée par lui (dossier protégé) hérite de ses droits.
    # Les autres (Evermind, une copie de travail) sont lancées avec les droits de l'utilisateur.
    $avecDroits = (Test-AppliAdmin $Appli $inst) -and $inst.Gere -and $inst.Dossier -ieq (Get-DossierGere $Appli)
    try {
        if ($MindsetAdmin -and -not $avecDroits) { [void][MSLanceur]::SansAdmin($exe, $(if ($Demarrage) { '-Demarrage' } else { '' }), $inst.Dossier) }
        else {
            $p = @{ FilePath = $exe; WorkingDirectory = $inst.Dossier; ErrorAction = 'Stop' }
            if ($Demarrage) { $p.ArgumentList = '-Demarrage' }
            Start-Process @p
        }
    } catch { Write-Log "Lancement de $($Appli.Nom) : $($_.Exception.Message)" }   # (par exemple : autorisation de Windows refusée)
}

# ---------------------------------------------------------------------------
# Versions publiées (au démarrage, puis toutes les 6 heures)
# ---------------------------------------------------------------------------
# (pendant la question, $script:Recherches[id] : la console montre « Recherche des mises à jour... »)
$script:Recherches = @{}
function Update-Publications {
    foreach ($a in $Applis) {
        $script:Recherches[$a.Id] = Get-Date
        Start-Tache { $p = $args[0]; Get-Publication $p.Depot $p.Zip } @{ Depot = $a.Depot; Zip = $a.Zip } (New-Action @{ Id = $a.Id } {
            $script:Recherches.Remove($v.Id)
            $script:Publications[$v.Id] = if ($Erreur) { @{ Erreur = $Erreur } } else { $Resultat }
            # GitHub limite les questions (60 par heure et par connexion) : refusé, on réessaie dans 30 minutes
            if ("$Erreur $($Resultat.Erreur)" -match '403|429') { $script:DernieresPublications = (Get-Date).AddHours(-0.5) }
            Update-Cartes
            if ($script:OngletParametres -eq 'maj') { Update-ListeVersions }
        } 'Resultat', 'Erreur')
    }
}

# ---------------------------------------------------------------------------
# installer-admin.ps1 : le travail en administrateur ; $Fin reçoit (ok, message)
# ---------------------------------------------------------------------------
$script:AttentesAdmin = New-Object System.Collections.ArrayList

# Le mini-installateur : la tâche « \Mindset\Mindset (installation) » (installer-admin.ps1 -Action demande), en SYSTEM,
# sans demande de Windows. Mindset écrit sa demande dans installation.demande (une à la fois : les suivantes attendent),
# lit l'accusé de réception (valeur Recu) puis la réponse (valeur Resultat) dans HKLM:\SOFTWARE\Mindset\Installation
# (écrites seulement par l'installateur), puis efface sa demande.
# Si la tâche ne marche pas (absente, refusée, pas d'accusé de réception en $DelaiAccuseTache secondes) : la demande
# normale de Windows (la fenêtre où l'on clique « Oui »), jamais l'ancienne tâche « avec les droits les plus élevés ».
$TacheInstallation = '\Mindset\Mindset (installation)'
$SchtasksExe = Join-Path ([Environment]::GetFolderPath('System')) 'schtasks.exe'
$FichierDemande = Join-Path $DataDir 'installation.demande'
$CleInstallationAdmin = 'HKLM:\SOFTWARE\Mindset\Installation'
$DelaiAccuseTache = 30
$script:DemandesEnAttente = New-Object System.Collections.ArrayList

# La tâche du mini-installateur, pour cet utilisateur : 'systeme' (la tâche SYSTEM inscrite pour lui), 'ancienne' (celle
# d'avant, sous son compte avec les droits les plus élevés : elle ne sert plus qu'à se remplacer, voir
# Start-RemplacementTache), ou '' (absente, illisible, ou celle d'un autre compte du PC)
function Get-EtatTacheInstallation {
    $x = $null
    try {
        $t = @(& $SchtasksExe /Query /TN $TacheInstallation /XML 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $t.Count) { return '' }
        $x = [xml]($t -join "`n")
    } catch { return '' }
    $moi = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $compte = [string]$x.Task.Principals.Principal.UserId
    if ($compte -and $compte -notmatch '^S-1-') { try { $compte = (New-Object Security.Principal.NTAccount($compte)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $compte = '' } }
    $arguments = [string]$x.Task.Actions.Exec.Arguments
    if ($compte -eq 'S-1-5-18' -and $arguments -match "-Sid $([regex]::Escape($moi))(\s|\z)") { return 'systeme' }
    if ($compte -eq $moi -and $arguments -match '-Action demande' -and $arguments -notmatch '-Sid ') { return 'ancienne' }
    ''
}

function Test-TacheInstallation {
    if ($null -eq $script:TacheInstallationOk) {
        $script:EtatTacheInstallation = Get-EtatTacheInstallation
        $script:TacheInstallationOk = ($script:EtatTacheInstallation -eq 'systeme')
    }
    $script:TacheInstallationOk
}

function Remove-DemandeInstallation { try { [IO.File]::Delete($FichierDemande) } catch {} }

function Get-ValeurInstallation([string]$Nom) {
    try { [string](Get-ItemProperty -Path $CleInstallationAdmin -Name $Nom -ErrorAction Stop).$Nom } catch { '' }
}

# $D : @{ Contenu (la demande : Id, Action, paramètres) ; Fin (ok, message) ; Repli (appelé avec $D si la tâche ne
# marche pas, $null : pas de repli) ; Recu (facultatif, appelé avec $D à l'accusé de réception) }
function Send-DemandeInstallation($D) {
    try {
        [IO.File]::WriteAllText($FichierDemande, (ConvertTo-Json -InputObject $D.Contenu -Compress), (New-Object Text.UTF8Encoding $false))
        $null = & $SchtasksExe /Run /TN $TacheInstallation 2>&1
        if ($LASTEXITCODE -ne 0) { throw "la tâche d'installation n'a pas démarré (code $LASTEXITCODE)" }
    } catch {
        Remove-DemandeInstallation
        Skip-TacheInstallation $D $_.Exception.Message
        return $false
    }
    $D.Debut = Get-Date
    [void]$script:AttentesAdmin.Add(@{ Process = $null; Id = $D.Contenu.Id; Fin = $D.Fin; Debut = $D.Debut; Demande = $D; Recu = $false })
    $script:AdminTimer.Start()
    $true
}

# La tâche ne marche pas : elle n'est plus utilisée jusqu'au prochain lancement de Mindset, et l'opération passe par la
# demande normale de Windows ($D.Repli)
function Skip-TacheInstallation($D, [string]$Raison) {
    Write-Log "Mini-installateur : $Raison ; $(if ($D.Repli) { 'demande de Windows à la place' } else { 'opération abandonnée' })"
    $script:TacheInstallationOk = $false
    if ($D.Repli) { & $D.Repli $D } else { & $D.Fin $false "la tâche d'installation ne répond pas ($Raison)." }
}

function Invoke-Admin([string]$Action, [hashtable]$Parametres, [scriptblock]$Fin) {
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    if (-not $MindsetAdmin -and $Action -ne 'mindset' -and (Test-TacheInstallation)) {
        $c = @{ Id = [guid]::NewGuid().ToString('N'); Action = $Action }
        foreach ($k in $Parametres.Keys) { if ($null -ne $Parametres[$k] -and "$($Parametres[$k])" -ne '') { $c[$k] = [string]$Parametres[$k] } }
        # Repli : la demande de Windows, sauf pendant une mise à jour automatique (personne n'est là pour y répondre :
        # elle sera faite à la main, la carte le dit)
        $repli = if ($script:MajAuto -and $script:MajAuto.Count) { $null } else { { param($D) Invoke-AdminDirect $D.Action $D.Parametres $D.Fin } }
        $d = @{ Contenu = $c; Fin = $Fin; Action = $Action; Parametres = $Parametres; Repli = $repli }
        if (@($script:AttentesAdmin | Where-Object { $_.Id }).Count) { [void]$script:DemandesEnAttente.Add($d); return }
        [void](Send-DemandeInstallation $d)
        return
    }
    Invoke-AdminDirect $Action $Parametres $Fin
}

# Un argument de la ligne de commande de l'installateur, entre guillemets : les \ qui le finissent sont doublés (sinon
# « "E:\" » ferait du guillemet de fin un caractère du texte, et décalerait les arguments suivants)
function Format-ArgumentAdmin([string]$Valeur) {
    if ($Valeur.Contains('"')) { throw "Valeur refusée (guillemet) : $Valeur" }
    '"' + ($Valeur -replace '(\\+)$', '$1$1') + '"'
}

# La demande normale de Windows : installer-admin.ps1 lancé en administrateur, sa réponse dans un fichier
function Invoke-AdminDirect([string]$Action, [hashtable]$Parametres, [scriptblock]$Fin) {
    $rep = Join-Path $TelechargementsDir "admin-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    try {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Format-ArgumentAdmin (Join-Path $AppDir 'installer-admin.ps1')), '-Action', $Action, '-Resultat', (Format-ArgumentAdmin $rep))
        foreach ($k in $Parametres.Keys) { if ($null -ne $Parametres[$k] -and "$($Parametres[$k])" -ne '') { $a += @("-$k", (Format-ArgumentAdmin ([string]$Parametres[$k]))) } }
    } catch { & $Fin $false $_.Exception.Message; return }
    try { $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -Verb RunAs -WindowStyle Hidden -WorkingDirectory $env:SystemRoot -PassThru -ErrorAction Stop }
    catch { & $Fin $false 'l''autorisation de Windows a été refusée.'; return }
    [void]$script:AttentesAdmin.Add(@{ Process = $proc; Reponse = $rep; Fin = $Fin; Debut = Get-Date })
    $script:AdminTimer.Start()
}

# La demande suivante, une fois la précédente finie (par la tâche si elle marche toujours, sinon par son repli)
function Send-DemandeSuivante {
    if (-not $script:DemandesEnAttente.Count) { return }
    $s = $script:DemandesEnAttente[0]; $script:DemandesEnAttente.RemoveAt(0)
    if (Test-TacheInstallation) { [void](Send-DemandeInstallation $s) }
    elseif ($s.Repli) { & $s.Repli $s }
    else { & $s.Fin $false 'la tâche d''installation ne répond pas.' }
}

# Toutes les 500 ms, tant qu'une opération en administrateur est en cours
function Update-AttentesAdmin {
    foreach ($w in @($script:AttentesAdmin)) {
        $r = $null
        if ($w.Id) {
            # Demande passée par la tâche : sa réponse, reconnue à son numéro
            try { $r = Get-ValeurInstallation 'Resultat' | ConvertFrom-Json } catch {}
            if ($r -and $r.id -ne $w.Id) { $r = $null }
            if (-not $r) {
                $ecoule = ((Get-Date) - $w.Debut).TotalSeconds
                if (-not $w.Recu -and (Get-ValeurInstallation 'Recu') -eq $w.Id) {
                    $w.Recu = $true
                    if ($w.Demande -and $w.Demande.Recu) { try { & $w.Demande.Recu $w.Demande } catch { Write-Log "Accusé de réception : $_" } }
                }
                if (-not $w.Recu -and $ecoule -ge $DelaiAccuseTache) {
                    # Pas d'accusé de réception : la demande est retirée (la tâche ne la fera plus), puis on regarde une
                    # dernière fois (elle a pu la prendre juste avant) ; sinon, la demande de Windows
                    Remove-DemandeInstallation
                    if ((Get-ValeurInstallation 'Recu') -eq $w.Id) { $w.Recu = $true; continue }
                    [void]$script:AttentesAdmin.Remove($w)
                    Skip-TacheInstallation $w.Demande "pas de réponse de la tâche en $DelaiAccuseTache secondes"
                    Send-DemandeSuivante
                    continue
                }
                if ($ecoule -lt 600) { continue }
            }
            [void]$script:AttentesAdmin.Remove($w)
            Remove-DemandeInstallation
            try { if ($r) { & $w.Fin ([bool]$r.ok) ([string]$r.message) } else { & $w.Fin $false 'pas de réponse du mini-installateur (opération interrompue ?).' } } catch { Write-Log "Fin d'opération admin : $_" }
            Send-DemandeSuivante
            continue
        }
        $fini = $false; try { $fini = $w.Process.HasExited } catch {}
        if (-not $fini -and ((Get-Date) - $w.Debut).TotalMinutes -lt 5) { continue }
        [void]$script:AttentesAdmin.Remove($w)
        try { $r = [IO.File]::ReadAllText($w.Reponse, [Text.Encoding]::UTF8) | ConvertFrom-Json; Remove-Item -LiteralPath $w.Reponse -Force } catch {}
        try {
            if ($r) { & $w.Fin ([bool]$r.ok) ([string]$r.message) } else { & $w.Fin $false 'pas de réponse (opération interrompue ?).' }
        } catch { Write-Log "Fin d'opération admin : $_" }
    }
    if (-not $script:AttentesAdmin.Count) { $script:AdminTimer.Stop() }
}

$script:AdminTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:AdminTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:AdminTimer.Add_Tick({ Update-AttentesAdmin })

# Mise à jour depuis Mindset 2.9.0 ou avant : la tâche est encore l'ancienne (sous le compte de l'utilisateur, avec les
# droits les plus élevés). Elle sert une dernière fois, sans demande de Windows, à se remplacer par la tâche SYSTEM
# (installer-admin.ps1 n'accepte plus qu'Action taches par elle). Rien d'autre ne passe par elle : en cas d'échec, les
# opérations utilisent la demande de Windows, et le bandeau des Paramètres propose de réactiver le mini-installateur.
# $Fin reçoit $true si la tâche SYSTEM est en place.
function Start-RemplacementTache([scriptblock]$Fin) {
    $script:RemplacementFin = $Fin
    $c = @{ Id = [guid]::NewGuid().ToString('N'); Action = 'taches'; Destination = [string]$DossierMindset }
    $d = @{ Contenu = $c; Repli = $null; Fin = {
            param($Ok, $Message)
            if ($Ok) { Write-Log 'Mini-installateur : l''ancienne tâche est remplacée par la tâche SYSTEM' }
            else { Write-Log "Mini-installateur : l'ancienne tâche n'a pas pu être remplacée ($Message)" }
            $script:TacheInstallationOk = $null
            & $script:RemplacementFin ([bool]((Test-TacheInstallation) -and $Ok))
        } }
    [void](Send-DemandeInstallation $d)
}

# ---------------------------------------------------------------------------
# Installer, mettre à jour, prendre en charge
# ---------------------------------------------------------------------------
# $AncienDossier : copie existante qu'on prend en charge
function Start-InstallAppli($Appli, [string]$AncienDossier) {
    if ($script:Occupe[$Appli.Id]) { return }
    # Ouverte, ou qui s'ouvre avec Mindset : relancée une fois installée (l'installation la ferme). Mise à jour
    # automatique : seulement si elle était ouverte (une appli que l'utilisateur a fermée reste fermée).
    $ouverte = Test-AppliOuverte $Appli
    $script:ARelancer[$Appli.Id] = if ($script:MajAuto -and $script:MajAuto[$Appli.Id]) { [bool]$ouverte } else { [bool]($ouverte -or (Get-DemarrageAppli $Appli.Id)) }
    $script:Occupe[$Appli.Id] = 'Téléchargement...'
    $script:Messages.Remove($Appli.Id)
    Update-Cartes
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    $script:Progres[$Appli.Id] = [hashtable]::Synchronized(@{ Recu = 0; Total = 0 })
    $params = @{ Depot = $Appli.Depot; Zip = $Appli.Zip; Cle = $ClePublique; Dossier = $TelechargementsDir; Id = $Appli.Id; Progres = $script:Progres[$Appli.Id] }
    Start-Tache {
        $p = $args[0]
        $pub = Get-Publication $p.Depot $p.Zip
        if ($pub.Erreur) { throw $pub.Erreur }
        if (-not $pub.UrlSig) { throw "La version $($pub.Version) n'est pas signée : Mindset ne l'installera pas." }
        $zip = Get-Octets $pub.UrlZip $p.Progres
        $sig = Get-Octets $pub.UrlSig
        if (-not (Test-Signature $zip $sig $p.Cle)) { throw 'La signature du fichier téléchargé est invalide : rien n''a été installé.' }
        $fz = Join-Path $p.Dossier "$($p.Id).zip"; $fs = "$fz.sig"
        [IO.File]::WriteAllBytes($fz, $zip); [IO.File]::WriteAllBytes($fs, $sig)
        @{ Version = $pub.Version; Zip = $fz; Sig = $fs }
    } $params (New-Action @{ Id = $Appli.Id; Ancien = $AncienDossier } { Complete-Telechargement (Get-Appli $v.Id) $Resultat $Erreur $v.Ancien } 'Resultat', 'Erreur')
}

function Complete-Telechargement($Appli, $Resultat, $Erreur, [string]$AncienDossier) {
    $script:Progres.Remove($Appli.Id)
    if ($Erreur -or -not $Resultat) { Stop-Operation $Appli "Échec : $Erreur"; return }
    $p = [ordered]@{ Zip = $Resultat.Zip; Signature = $Resultat.Sig; Destination = (Get-DossierGere $Appli); DossierZip = $Appli.DossierZip; Exe = $Appli.Exe }
    # (prise en charge : l'utilisateur est donné aussi, l'installateur ne réécrit que ses tâches planifiées à lui)
    if ($AncienDossier) { $p.AncienExe = Join-Path $AncienDossier $Appli.Exe; $p.Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    # Appli avec une partie administrateur (Nevermind) : sa tâche planifiée est créée ou remise à jour à chaque installation
    if ($Appli.Aide) { $p.TacheAide = $Appli.Aide; $p.ExeAide = $Appli.AideExe; $p.Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    # Première installation ou prise en charge : l'appli qui se lançait avec Windows s'ouvrira avec Mindset (sinon, prise
    # en charge, elle ne démarrerait plus du tout : plus de rappels pour Evermind). Regardé maintenant, avant que ses
    # anciens démarrages ne soient retirés. Une appli de rappels l'est d'office, sauf si elle avait été coupée.
    $inst = Get-Installation $Appli
    $demarrage = $false
    if (-not ($inst -and $inst.Gere) -and -not (Get-DemarrageAppli $Appli.Id)) {
        $avant = Get-DemarrageWindowsAppli $Appli
        $demarrage = if ($null -ne $avant) { [bool]$avant } else { [bool]$Appli.Rappels }
    }
    # (Avant : la version d'avant, pour l'historique des mises à jour ; rien pour une première installation)
    $script:EnCours[$Appli.Id] = @{ Appli = $Appli; Ancien = $AncienDossier; Version = $Resultat.Version; Zip = $Resultat.Zip; Parametres = $p; Demarrage = $demarrage; Avant = $(if ($inst) { [string]$inst.Version } else { '' }) }
    # Ouverte (ou son ancienne copie) : d'abord priée de quitter proprement (quitter.demande, comme quand on quitte
    # Mindset), le temps d'enregistrer ce qu'elle fait. L'installateur ne ferme de force que ce qui reste ouvert après.
    if (Test-AppliOuverte $Appli) {
        Write-DemandeQuitter $Appli
        Write-Log "$($Appli.Nom) : fermeture demandée avant l'installation"
        $script:Occupe[$Appli.Id] = "Fermeture de $($Appli.Nom)..."
        Update-Cartes
        $script:AttentesFermeture[$Appli.Id] = Get-Date
        $script:FermetureTimer.Start()
        return
    }
    Send-InstallationAppli $Appli
}

# Attente de la fermeture des applis avant leur installation : par leur mutex et leur chemin (Test-AppliOuverte),
# $DelaiFermetureAppli secondes au plus ; ensuite l'installation part quand même (l'installateur ferme ce qui reste)
$DelaiFermetureAppli = 10
$script:AttentesFermeture = @{}
$script:FermetureTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FermetureTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:FermetureTimer.Add_Tick({
    foreach ($id in @($script:AttentesFermeture.Keys)) {
        $a = Get-Appli $id
        $ouverte = $a -and (Test-AppliOuverte $a)
        $ecoule = ((Get-Date) - $script:AttentesFermeture[$id]).TotalSeconds
        if ($ouverte -and $ecoule -lt $DelaiFermetureAppli) { continue }
        $script:AttentesFermeture.Remove($id)
        if (-not $a) { continue }
        if ($ouverte) { Write-Log "$($a.Nom) ne s'est pas fermé en $DelaiFermetureAppli s : l'installateur le fermera" }
        else { Write-Log "$($a.Nom) s'est fermé proprement ($([math]::Round($ecoule, 1)) s)" }
        try { Send-InstallationAppli $a } catch { Write-Log "Installation de $($a.Nom) : $_"; Stop-Operation $a "Échec : $($_.Exception.Message)" }
    }
    if (-not $script:AttentesFermeture.Count) { $script:FermetureTimer.Stop() }
})

function Send-InstallationAppli($Appli) {
    $c = $script:EnCours[$Appli.Id]
    if (-not $c) { return }
    $script:Occupe[$Appli.Id] = $(if (-not $MindsetAdmin -and (Test-TacheInstallation)) { 'Installation...' } else { 'Installation (accepte la demande de Windows)...' })
    Update-Cartes
    Invoke-Admin 'appli' $c.Parametres (New-Action @{ Id = $Appli.Id } {
        $a = Get-Appli $v.Id
        if ($Ok) { Complete-Installation $a $Message } else { Stop-Operation $a "Échec : $Message" }
    } 'Ok', 'Message')
}

function Complete-Installation($Appli, [string]$Dossier) {
    $c = $script:EnCours[$Appli.Id]; $script:EnCours.Remove($Appli.Id)
    $ancien = if ($c -and $c.Appli.Id -eq $Appli.Id) { $c.Ancien } else { '' }
    Save-Installation $Appli.Id $Dossier $true
    Set-SuiteAppli $Appli.Id $Dossier
    Update-RaccourciAppli $Appli
    $notes = @(Remove-Doublons $Appli)
    if ($ancien) { $notes += Remove-AncienneCopie $Appli $ancien $c.Zip }
    foreach ($f in @(Get-ChildItem -LiteralPath $TelechargementsDir -Filter "$($Appli.Id).*" -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    Write-Log "$($Appli.Nom) $($c.Version) installé dans $Dossier$(if ($ancien) { " (pris en charge depuis $ancien)" })"
    # Une mise à jour (une version plus récente que celle d'avant) : notée dans l'historique, automatique ou non, avec ses nouveautés
    if ($c -and $c.Avant -and (Test-VersionPlusRecente ([string]$c.Version) $c.Avant)) {
        $pub = if ($script:Publications) { $script:Publications[$Appli.Id] }
        $notes = if ($pub -and [string]$pub.Version -eq [string]$c.Version) { [string]$pub.Notes } else { '' }
        Add-HistoriqueMaj $Appli.Id $Appli.Nom ([string]$c.Version) ([bool]($script:MajAuto -and $script:MajAuto[$Appli.Id])) $notes
    }
    # Elle se lançait avec Windows (ou c'est une appli de rappels) : elle s'ouvre maintenant avec Mindset, et tout de
    # suite, en arrière-plan (sans attendre le prochain démarrage du PC)
    if ($c -and $c.Demarrage -and -not (Get-DemarrageAppli $Appli.Id)) {
        Set-DemarrageAppli $Appli.Id $true
        $script:ARelancer[$Appli.Id] = $true
        Write-Log "$($Appli.Nom) s'ouvre avec Mindset (il se lançait avec Windows, ou ses rappels en ont besoin)"
        foreach ($x in $script:Interrupteurs) { if ($x.Tag -eq $Appli.Id) { $x.IsChecked = $true } }
    }
    $fin = (@("$($Appli.Nom) $($c.Version) est installé.") + $notes | Where-Object { $_ }) -join ' '
    Move-DonneesAppli $Appli $fin
}

# Les données d'avant (dossier de l'appli autonome, ou %LOCALAPPDATA%\Mindset si la suite était sur C:) rejoignent
# celles de la suite. Sur le même disque, l'appli renomme elle-même le dossier d'un bloc au lancement ; d'un disque à
# l'autre, Mindset copie, vérifie (nombre de fichiers et taille), puis supprime l'ancien, avant le premier lancement.
function Move-DonneesAppli($Appli, [string]$Message) {
    $dest = Join-Path $SuiteDir $Appli.Nom
    $src = @((Join-Path $env:LOCALAPPDATA "Mindset\$($Appli.Nom)"), $Appli.Donnees) | Where-Object { $_ -ine $dest -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ((Test-Path -LiteralPath $dest) -or -not $src -or ([IO.Path]::GetPathRoot($src) -ieq [IO.Path]::GetPathRoot($dest))) { Stop-Operation $Appli $Message; return }
    if (-not (Test-DossierSur $src)) { Write-Log "Données de $($Appli.Nom) : $src est un lien vers un autre dossier, pas déplacé"; Stop-Operation $Appli $Message; return }
    $taille = (Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $script:Occupe[$Appli.Id] = "Déplacement des données vers $dest ({0:N1} Go)..." -f ($taille / 1GB)
    Update-Cartes
    Start-Tache {
        $p = $args[0]
        $mesure = { param($d) $f = @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue); "$($f.Count)|$(($f | Measure-Object Length -Sum).Sum)" }
        New-Item -ItemType Directory -Force -Path (Split-Path $p.Dest) | Out-Null
        $tmp = "$($p.Dest).copie"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        robocopy $p.Src $tmp /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8 -or (& $mesure $p.Src) -ne (& $mesure $tmp)) {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            throw "la copie de $($p.Src) n'est pas complète : les données restent à leur place."
        }
        [IO.Directory]::Move($tmp, $p.Dest)   # (même disque : renommage d'un bloc, le dossier n'apparaît qu'une fois complet)
        try { Remove-Item -LiteralPath $p.Src -Recurse -Force -ErrorAction Stop; '' }
        catch { "L'ancien dossier $($p.Src) n'a pas pu être supprimé (un fichier est ouvert) : supprime-le plus tard." }
    } @{ Src = $src; Dest = $dest } (New-Action @{ Id = $Appli.Id; Message = $Message; Src = $src; Dest = $dest } {
        $a = Get-Appli $v.Id
        if ($Erreur) { Write-Log "Données de $($a.Nom) : $Erreur"; Stop-Operation $a "$($v.Message) Attention : $Erreur" }
        else { Write-Log "Données de $($a.Nom) déplacées : $($v.Src) -> $($v.Dest)"; Stop-Operation $a ("$($v.Message) Ses données sont maintenant dans $($v.Dest). $Resultat".Trim()) }
    } 'Resultat', 'Erreur')
}

# Plus aucun accès direct : raccourcis et lancement au démarrage de l'appli (toutes copies) sont retirés.
# Le lancement au démarrage d'une appli qui en a besoin (les rappels d'Evermind) est repris par Mindset.
function Remove-Doublons($Appli) {
    $n = 0
    foreach ($r in @(Get-RaccourcisAppli $Appli)) { try { Remove-Item -LiteralPath $r.Lien -Force -ErrorAction Stop; $n++ } catch { Write-Log "Raccourci non retiré : $($r.Lien)" } }
    $demarrage = @(Get-DemarragesAppli $Appli)
    foreach ($d in $demarrage) { try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $d.Nom -ErrorAction Stop } catch {} }
    # (son ancien lancement avec Windows est repris par « S'ouvre avec Mindset » : vu avant, dans Complete-Telechargement)
    if ($n) { "$n raccourci$(if ($n -gt 1) { 's' }) direct$(if ($n -gt 1) { 's' }) retiré$(if ($n -gt 1) { 's' }) : $($Appli.Nom) s'ouvre maintenant depuis Mindset." }
}

# ---------------------------------------------------------------------------
# Le nom de l'appli dans la barre des tâches : son raccourci du menu Démarrer (Mindset\<Appli>.lnk)
# ---------------------------------------------------------------------------
# L'hôte de chaque appli s'appelle Mindset.exe (pour que le Gestionnaire des tâches range la suite sur une ligne). Pour
# nommer le bouton d'une appli, Windows cherche dans le menu Démarrer un raccourci qui porte la même identité qu'elle
# (AppUserModelID, ex. JordanJacquot.Nevermind) et prend son nom et son icône ; sans lui, il prend la description de
# son programme : « Mindset » pour toutes. Mindset écrit donc ce raccourci pour chaque appli gérée qui a son hôte
# Mindset.exe (installation, mise à jour, prise en charge, et à chaque démarrage pour réparer), et le retire quand
# elle est désinstallée ou n'est plus gérée. (En test, seulement dans le dossier donné par MINDSET_TEST_MENU.)
$MenuApplis = if ($EnTest) { [string]$env:MINDSET_TEST_MENU } else { Join-Path ([Environment]::GetFolderPath('Programs')) 'Mindset' }

function Get-RaccourciMenu($Appli) { if ($MenuApplis) { Join-Path $MenuApplis "$($Appli.Nom).lnk" } }

function Update-RaccourciAppli($Appli) {
    $lien = Get-RaccourciMenu $Appli
    if (-not $lien) { return }
    $inst = Get-Installation $Appli
    $hote = if ($inst -and $inst.Gere) { Join-Path $inst.Dossier 'Mindset.exe' } else { '' }
    if (-not $hote -or -not (Test-Path -LiteralPath $hote -PathType Leaf)) { Remove-RaccourciAppli $Appli; return }
    # Déjà juste (même programme, même icône, même identité) : il n'est pas réécrit
    $l = $null
    if (Test-Path -LiteralPath $lien) { try { $l = [MSRaccourci]::Lire($lien) } catch {} }
    if ($l -and $l[0] -ieq $hote -and $l[1] -ieq "$hote,0" -and $l[2] -ceq $Appli.AppId) { return }
    # Sinon il est remplacé (un ancien raccourci du même nom, sans identité ou vers un autre dossier, ne reste pas)
    try {
        New-Item -ItemType Directory -Force -Path $MenuApplis | Out-Null
        if (Test-Path -LiteralPath $lien) { Remove-Item -LiteralPath $lien -Force -ErrorAction Stop }
        [MSRaccourci]::Ecrire($lien, $hote, $inst.Dossier, $hote, $Appli.Description, $Appli.AppId)
        Write-Log "Raccourci de $($Appli.Nom) dans le menu Démarrer : $lien"
    } catch { Write-Log "Raccourci de $($Appli.Nom) dans le menu Démarrer : $($_.Exception.Message)" }
}

function Remove-RaccourciAppli($Appli) {
    $lien = Get-RaccourciMenu $Appli
    if (-not $lien) { return }
    if (Test-Path -LiteralPath $lien) {
        try { Remove-Item -LiteralPath $lien -Force -ErrorAction Stop; Write-Log "Raccourci de $($Appli.Nom) retiré du menu Démarrer" }
        catch { Write-Log "Raccourci $lien pas retiré : $($_.Exception.Message)" }
    }
    # Le dossier Mindset du menu Démarrer, une fois vide
    try { if ((Test-Path -LiteralPath $MenuApplis) -and -not @(Get-ChildItem -LiteralPath $MenuApplis -Force).Count) { Remove-Item -LiteralPath $MenuApplis -Force -ErrorAction Stop } } catch {}
}

# Au démarrage de Mindset : les installations d'avant (ou un raccourci supprimé, cassé, d'une autre version) sont réparées
function Update-RaccourcisApplis { foreach ($a in $Applis) { Update-RaccourciAppli $a } }

# Un dossier que Mindset (peut-être administrateur) accepte de vider : ni dossier de Windows ou de programmes, ni point de
# jonction ou lien symbolique (sur lui ou sur un de ses parents), qui pourrait renvoyer ailleurs que là où il semble être
function Test-DossierSur([string]$Dossier) {
    $d = [IO.Path]::GetFullPath($Dossier.TrimEnd('\'))
    foreach ($interdit in $env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) { if ($interdit -and ($d -ieq $interdit -or $d -like "$interdit\*")) { return $false } }
    $x = $d
    while ($x -and $x.Length -gt 3) {
        try { if ((Get-Item -LiteralPath $x -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false } } catch { return $false }
        $x = Split-Path $x -Parent
    }
    $true
}

# Dossier de travail (dépôt Git dans la copie ou son parent, comme D:\Projets\Evermind\Evermind) : Mindset ne le
# supprime jamais, et c'est la seule copie non gérée que les applis acceptent encore d'ouvrir sans Mindset
function Test-DossierTravail([string]$Dossier) {
    $Dossier -and ((Test-Path -LiteralPath (Join-Path $Dossier '.git')) -or (Test-Path -LiteralPath (Join-Path (Split-Path $Dossier -Parent) '.git')))
}

# L'ancienne copie, une fois prise en charge : seuls les fichiers livrés avec l'appli (ceux du zip) sont supprimés,
# puis les dossiers devenus vides. Jamais un dossier de travail (Git), jamais dans les programmes de Mindset.
function Remove-AncienneCopie($Appli, [string]$Dossier, [string]$Zip) {
    $d = [IO.Path]::GetFullPath($Dossier.TrimEnd('\'))
    if ($d -like "$([IO.Path]::GetFullPath($RacineProgrammes))\*" -or $d -like "$([IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Mindset')))\*") { return '' }
    if (-not (Test-DossierSur $d)) { return "L'ancienne copie ($d) n'a pas été supprimée (dossier protégé ou lien vers un autre dossier)." }
    if (Test-DossierTravail $d) {
        return "L'ancienne copie ($d) est un dossier de travail : elle est gardée telle quelle."
    }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::OpenRead($Zip)
        $prefixe = $Appli.DossierZip + '\'
        $livres = @($za.Entries | ForEach-Object { $_.FullName.Replace('/', '\') } | Where-Object { $_.StartsWith($prefixe, [StringComparison]::OrdinalIgnoreCase) -and -not $_.EndsWith('\') } | ForEach-Object { $_.Substring($prefixe.Length) })
        $za.Dispose()
    } catch { return "L'ancienne copie ($d) n'a pas été supprimée (contenu du zip illisible)." }
    foreach ($rel in $livres) {
        $f = [IO.Path]::GetFullPath((Join-Path $d $rel))
        if ($f.StartsWith("$d\", [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $f -PathType Leaf)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch {} }
    }
    foreach ($sd in @(Get-ChildItem -LiteralPath $d -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
        if (-not @(Get-ChildItem -LiteralPath $sd.FullName -Force -ErrorAction SilentlyContinue).Count) { Remove-Item -LiteralPath $sd.FullName -Force -ErrorAction SilentlyContinue }
    }
    $reste = @(Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue)
    if (-not $reste.Count) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; return "L'ancienne copie ($d) a été supprimée." }
    "L'ancienne copie ($d) a été vidée de $($Appli.Nom) ; $($reste.Count) fichier$(if ($reste.Count -gt 1) { 's' }) qui n'en fai$(if ($reste.Count -gt 1) { 'saient' } else { 'sait' }) pas partie y reste$(if ($reste.Count -gt 1) { 'nt' })."
}

function Stop-Operation($Appli, [string]$Message) {
    $script:Occupe.Remove($Appli.Id); $script:Progres.Remove($Appli.Id)
    if ($script:MajAuto -and $script:MajAuto[$Appli.Id]) { Complete-MajAuto $Appli $Message }
    $script:Messages[$Appli.Id] = $Message
    Update-Trouvees
    Update-Cartes
    # Fermée par l'installation (ou demandée pendant) : relancée, cachée, puis accrochée si son onglet est affiché
    if ($script:ARelancer[$Appli.Id]) {
        $script:ARelancer.Remove($Appli.Id)
        $i = Get-Installation $Appli
        if ($i -and $i.Gere -and -not $EnTest) {
            if ($script:PageCourante -eq $Appli.Id) { Open-AppliIci $Appli.Id } else { Open-Appli $Appli -Demarrage }
        }
    }
}
$script:ARelancer = @{}

# ---------------------------------------------------------------------------
# « S'ouvre avec Mindset » (interrupteur des cartes de l'accueil) : l'appli démarre en arrière-plan quand Mindset s'ouvre,
# donc aussi au démarrage de Windows (Mindset.exe -Demarrage), voir Start-Demarrage dans mindset.ps1
# ---------------------------------------------------------------------------
# Nevermind avait sa propre tâche de démarrage : un Mindset administrateur la retire (une seule règle, la sienne), et
# l'appli qui démarrait par elle s'ouvre avec Mindset (sinon elle ne démarrerait plus du tout)
$TachesDemarrageAppli = @{ nevermind = @('Nevermind (démarrage)', 'OptiGame (démarrage)', 'Nexo (démarrage)') }

# Ses tâches de démarrage qui existent encore
function Get-TachesDemarrageAppli([string]$Id) {
    @(foreach ($n in @($TachesDemarrageAppli[$Id] | Where-Object { $_ })) {
        & "$env:SystemRoot\System32\schtasks.exe" /Query /TN "\$n" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $n }
    })
}

# L'appli se lançait-elle avec Windows par elle-même ? $true, $false, ou $null (on ne sait pas : jamais lancée)
#   - une entrée « Run » de l'utilisateur qui lance son programme (ancienne copie, avant sa prise en charge) ;
#   - Mindset administrateur : sa propre tâche de démarrage (Nevermind) ;
#   - son réglage « DemarrageWindows » (Evermind le garde dans reglages.json, même quand Mindset l'a pris en charge et
#     qu'elle a retiré son entrée « Run » elle-même).
# Rien n'est modifié ici : seulement lu.
function Get-DemarrageWindowsAppli($Appli) {
    if (@(Get-DemarragesAppli $Appli).Count) { return $true }
    if ($MindsetAdmin -and @(Get-TachesDemarrageAppli $Appli.Id).Count) { return $true }
    foreach ($d in @((Get-DossierDonnees $Appli), $Appli.Donnees) | Where-Object { $_ } | Select-Object -Unique) {
        foreach ($n in 'reglages.json', 'parametres.json') {
            $f = Join-Path $d $n
            if (-not [IO.File]::Exists($f)) { continue }
            try { $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
            $v = $j.PSObject.Properties['DemarrageWindows']
            if ($v -and $v.Value -is [bool]) { return [bool]$v.Value }
        }
    }
    $null
}

# Une fois (réglage « DemarrageRepris ») : les applis prises en charge avant que Mindset ne reprenne leur démarrage
# (Evermind : il retirait son démarrage avec Windows, et Mindset ne le lançait pas, donc plus de rappels).
# Celles qui se lançaient avec Windows (ou une appli de rappels qui ne l'avait pas coupé) s'ouvrent avec Mindset.
function Repair-DemarrageApplis {
    if (Get-Setting 'DemarrageRepris' $false) { return }
    foreach ($a in $Applis) {
        $i = Get-Installation $a
        if (-not ($i -and $i.Gere) -or (Get-DemarrageAppli $a.Id)) { continue }
        $avant = Get-DemarrageWindowsAppli $a
        $oui = if ($null -ne $avant) { [bool]$avant } else { [bool]$a.Rappels }
        if (-not $oui) { continue }
        Set-DemarrageAppli $a.Id $true
        Write-Log "$($a.Nom) s'ouvre avec Mindset (il se lançait avec Windows avant d'être pris en charge)"
    }
    Set-Setting 'DemarrageRepris' $true
}

function Get-DemarrageAppli([string]$Id) { $Id -in @(Get-Setting 'Demarrage' @()) }
function Set-DemarrageAppli([string]$Id, [bool]$Oui) {
    $l = @(@(Get-Setting 'Demarrage' @()) | Where-Object { $_ -ne $Id })
    if ($Oui) { $l += $Id }
    Set-Setting 'Demarrage' $l
    if ($MindsetAdmin) { Remove-TachesDemarrageAppli $Id }
}

function Remove-TachesDemarrageAppli([string]$Id) {
    foreach ($n in @($TachesDemarrageAppli[$Id] | Where-Object { $_ })) {
        & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN "\$n" /F 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "Tâche « $n » retirée : le démarrage de $Id se règle dans Mindset (S'ouvre avec Mindset)" }
    }
}

# Mindset administrateur : une appli gérée qui avait sa propre tâche de démarrage la perd, et son interrupteur
# « S'ouvre avec Mindset » s'allume à la place (elle démarrait avec Windows : elle continue, par Mindset)
function Move-TachesDemarrage {
    if (-not $MindsetAdmin) { return }
    foreach ($id in @($TachesDemarrageAppli.Keys)) {
        $a = Get-Appli $id; $i = if ($a) { Get-Installation $a } else { $null }
        if (-not ($i -and $i.Gere)) { continue }
        if (@(Get-TachesDemarrageAppli $id).Count -and -not (Get-DemarrageAppli $id)) {
            Set-DemarrageAppli $id $true
            Write-Log "$($a.Nom) s'ouvre avec Mindset (sa tâche de démarrage est reprise)"
        }
        Remove-TachesDemarrageAppli $id
    }
}

# ---------------------------------------------------------------------------
# Désinstaller (seulement une installation gérée : jamais une copie trouvée sur le PC)
# ---------------------------------------------------------------------------
function Start-DesinstallAppli($Appli) {
    $inst = Get-Installation $Appli
    if (-not $inst -or -not $inst.Gere -or $inst.Dossier -ine (Get-DossierGere $Appli)) { return }
    # Ses programmes d'aide lancés depuis son dossier de données (ils tiendraient ses données ouvertes si elles sont
    # supprimées) : fermés d'abord, par leur chemin. Le reste (son hôte, son dossier des programmes) est fermé par son
    # désinstalleur ou par le mini-installateur.
    if (-not $EnTest) {
        foreach ($p in @(Get-ProcessusDonneesAppli $Appli)) {
            try { $p.Kill(); [void]$p.WaitForExit(3000); Write-Log "Désinstallation de $($Appli.Nom) : programme d'aide fermé ($($p.Id))" } catch { Write-Log "Désinstallation de $($Appli.Nom) : programme d'aide $($p.Id) pas fermé ($_)" }
        }
    }
    if ($Appli.Desinstalleur) {
        # Nevermind a son propre désinstalleur : il remet les réglages de Windows comme avant, puis supprime ses fichiers.
        # Lancé sans option : c'est lui qui demande si les données sont gardées (sans droits, il se relance en
        # administrateur et une option ne suivrait pas). Complete-Desinstallation regarde ensuite ce qu'il a fait.
        try { Start-Process -FilePath (Join-Path $inst.Dossier $Appli.Desinstalleur) -WorkingDirectory $inst.Dossier -ErrorAction Stop } catch { Stop-Operation $Appli 'Désinstallation annulée.'; return }
        $script:Occupe[$Appli.Id] = 'Désinstallation (suis les étapes de son désinstalleur)...'
        $script:AttenteDesinstall = @{ Appli = $Appli; Dossier = $inst.Dossier; Debut = Get-Date }
        $script:DesinstallTimer.Start()
        Update-Cartes
        return
    }
    $script:Occupe[$Appli.Id] = 'Désinstallation (accepte la demande de Windows)...'
    Update-Cartes
    Invoke-Admin 'supprimer' @{ Destination = $inst.Dossier; Exe = $Appli.Exe } (New-Action @{ Id = $Appli.Id } {
        $a = Get-Appli $v.Id
        if ($Ok) { Complete-Desinstallation $a } else { Stop-Operation $a "Désinstallation impossible : $Message" }
    } 'Ok', 'Message')
}

function Complete-Desinstallation($Appli) {
    Save-Installation $Appli.Id $null $false
    Set-SuiteAppli $Appli.Id $null
    Set-DemarrageAppli $Appli.Id $false
    Remove-RaccourciAppli $Appli
    # Le message dit ce qui s'est vraiment passé : le désinstalleur de l'appli a gardé ses données ou les a supprimées,
    # selon le choix fait dans sa fenêtre (une ancienne version de Nevermind les supprime toujours). Sans désinstalleur
    # propre (Evermind...), seuls les programmes sont supprimés : les données restent.
    $donnees = Join-Path $SuiteDir $Appli.Nom
    $gardees = [IO.Directory]::Exists($donnees) -and @([IO.Directory]::EnumerateFileSystemEntries($donnees)).Count
    Write-Log "$($Appli.Nom) désinstallé (données $(if ($gardees) { 'gardées' } else { 'supprimées' }))"
    # Ses données supprimées : son profil dans le WebView2 commun de la suite aussi (Nevermind : profil « Nevermind » ;
    # le dossier commun, lui, reste pour Mindset). Si WebView2 le tient encore ouvert, il reste : sans danger.
    if (-not $gardees) {
        $profil = Join-Path $SuiteDir "WebView2\EBWebView\WV2Profile_$($Appli.Nom.ToLower())"   # (nom que WebView2 donne au dossier du profil)
        if ([IO.Directory]::Exists($profil)) {
            try { Remove-Item -LiteralPath $profil -Recurse -Force -ErrorAction Stop; Write-Log "Profil WebView2 de $($Appli.Nom) retiré" } catch { Write-Log "Profil WebView2 de $($Appli.Nom) pas retiré ($($_.Exception.Message))" }
        }
    }
    Stop-Operation $Appli $(if ($gardees) { "$($Appli.Nom) est désinstallé. Ses données sont gardées dans $donnees : une réinstallation les retrouve." } else { "$($Appli.Nom) est désinstallé, avec ses données (réglages, journal, sauvegarde)." })
}

$script:DesinstallTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DesinstallTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:DesinstallTimer.Add_Tick({
    $w = $script:AttenteDesinstall
    if (-not $w) { $script:DesinstallTimer.Stop(); return }
    if (-not (Test-Path -LiteralPath (Join-Path $w.Dossier $w.Appli.Exe))) {
        $script:DesinstallTimer.Stop(); $script:AttenteDesinstall = $null
        try { Complete-Desinstallation $w.Appli } catch { Write-Log "Fin de la désinstallation de $($w.Appli.Nom) : $_"; Stop-Operation $w.Appli "Échec : $($_.Exception.Message)" }
    } elseif (((Get-Date) - $w.Debut).TotalMinutes -gt 10) {
        $script:DesinstallTimer.Stop(); $script:AttenteDesinstall = $null
        Stop-Operation $w.Appli 'Désinstallation annulée ou pas terminée.'
    }
})

# Utiliser une copie trouvée telle quelle (Mindset l'ouvre, sans la gérer)
function Use-InstallationTrouvee($Appli, [string]$Dossier) {
    if (-not (Test-DossierAppli $Dossier $Appli)) { Stop-Operation $Appli "Ce dossier ne contient pas $($Appli.Nom)."; return }
    Save-Installation $Appli.Id $Dossier $false
    Update-RaccourciAppli $Appli   # (plus gérée : son raccourci du menu Démarrer part)
    Stop-Operation $Appli "Mindset ouvrira la copie de $Dossier. Elle se met à jour toute seule et garde son propre thème."
}
