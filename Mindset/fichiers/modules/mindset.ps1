# Mindset : s'installer sur le PC, se lancer avec Windows, se désinstaller.
# Chargé par Mindset.ps1 après installations.ps1 (Invoke-Admin).
#
# Installé, Mindset est dans C:\Program Files\Mindset\Mindset (ou X:\Mindset\Programmes\Mindset sur le disque choisi),
# avec un raccourci « Mindset » sur le Bureau et dans le menu Démarrer, et se lance avec Windows (Mindset.exe -Demarrage :
# il démarre en arrière-plan les applis qui en ont besoin, comme les rappels d'Evermind, et reste caché près de l'horloge).
# Il est aussi dans « Applications installées ».

$DossierMindset = Join-Path $RacineProgrammes 'Mindset'
$RaccourcisMindset = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mindset.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Mindset.lnk'))
$CleRun = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$DescriptionRaccourciMindset = 'Mindset : toutes tes applis au même endroit'

# Ses raccourcis portent son identité dans la barre des tâches (JordanJacquot.Mindset), comme sa fenêtre : épinglé
# depuis le menu Démarrer, il garde un seul bouton. Ceux d'avant (sans identité) sont réécrits au démarrage, seulement
# s'ils lancent ce Mindset installé (un raccourci supprimé n'est pas recréé).
function Update-RaccourcisMindset {
    if (-not (Test-MindsetInstalle)) { return }
    foreach ($l in $RaccourcisMindset) {
        if (-not (Test-Path -LiteralPath $l)) { continue }
        try {
            $r = [MSRaccourci]::Lire($l)
            if ($r[0] -ine $AppExe -or $r[2] -ceq $AppId) { continue }
            [MSRaccourci]::Ecrire($l, $AppExe, (Split-Path $AppExe -Parent), $AppExe, $DescriptionRaccourciMindset, $AppId)
            Write-Log "Raccourci $l : identité ajoutée"
        } catch { Write-Log "Raccourci $l : $($_.Exception.Message)" }
    }
}

function Test-MindsetInstalle { (Split-Path $AppDir -Parent) -ieq $DossierMindset }

# Un dossier de travail (dépôt Git) : pas de proposition d'installation
function Test-MindsetDeveloppement { Test-Path -LiteralPath (Join-Path (Split-Path (Split-Path $AppDir -Parent) -Parent) '.git') }

# Disques proposés à l'installation : C: (Program Files) et les autres disques fixes NTFS, avec leur place libre
function Get-DisquesInstallation {
    foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Sort-Object DeviceID)) {
        if ($v.FileSystem -ne 'NTFS') { continue }
        $l = $v.DeviceID.Substring(0, 1)
        $systeme = ($l -eq $env:SystemDrive.Substring(0, 1))
        [pscustomobject]@{
            Lettre = if ($systeme) { '' } else { $l }
            Texte  = if ($systeme) { "$($l): (dans Program Files, comme les autres programmes)" } else { "$($l):\Mindset" }
            Libre  = "{0:N0} Go libres" -f ($v.FreeSpace / 1GB)
        }
    }
}

# $Disque : '' pour C: (Program Files), sinon la lettre du disque choisi (X:\Mindset)
function Install-Mindset([string]$Disque) {
    if ($script:InstallMindsetEnCours) { return }
    $script:InstallMindsetEnCours = $true
    $ui.BienvenueTexte.Text = 'Installation (accepte la demande de Windows)...'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Invoke-Admin 'mindset' @{ Source = (Split-Path $AppDir -Parent); Version = $AppVersion; Disque = $Disque; Sid = $sid } {
        param($Ok, $Message)
        $script:InstallMindsetEnCours = $false
        if (-not $Ok) { $ui.BienvenueTexte.Text = "Installation impossible : $Message"; return }
        # Le dossier où Mindset a été installé, et « |sans-taches » si ses tâches planifiées n'ont pas pu être créées
        $dossier, $sansTaches = $Message -split '\|', 2
        Copy-ReglageVerif $dossier
        $exe = Join-Path $dossier 'Mindset.exe'
        foreach ($l in $RaccourcisMindset) {
            try { [MSRaccourci]::Ecrire($l, $exe, $dossier, $exe, $DescriptionRaccourciMindset, $AppId) }
            catch { Write-Log "Raccourci $l : $_" }
        }
        # Lancement avec Windows : par sa tâche planifiée (en administrateur), sinon par le registre (sans les droits)
        if ($sansTaches) { Write-Log "Tâches planifiées : $sansTaches"; Set-ItemProperty -Path $CleRun -Name 'Mindset' -Value "`"$exe`" -Demarrage" }
        else { Remove-ItemProperty -Path $CleRun -Name 'Mindset' -ErrorAction SilentlyContinue }
        Write-Log "Mindset $AppVersion installé dans $dossier"
        # Le Mindset installé prend le relais ; celui-ci (dans le dossier téléchargé) se ferme
        $script:LancerApres = $exe
        Exit-Mindset
    }
}

# « Chercher les nouvelles versions » coupé dans le bandeau d'installation : le choix suit Mindset installé sur un autre
# disque, où sont alors ses réglages (X:\Mindset\Donnees\Mindset). Activé, rien à faire : c'est la valeur par défaut.
function Copy-ReglageVerif([string]$Dossier) {
    if (Test-VerifVersionsActive) { return }
    $f = Join-Path (Join-Path (Get-RacinesDepuis $Dossier).Donnees 'Mindset') 'reglages.json'
    if ($f -ieq $SettingsFile) { return }
    try {
        $r = [ordered]@{}
        if (Test-Path -LiteralPath $f) { $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $r[$p.Name] = $p.Value } }
        $r['VerifVersions'] = $false
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllText($f, ($r | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    } catch { Write-Log "Réglage « Chercher les nouvelles versions » non repris dans $f : $_" }
}

# Désinstaller Mindset : par son désinstalleur autonome (Desinstaller Mindset.exe, à côté de Mindset.exe), qui retire
# aussi les applis (en lançant leur propre désinstalleur), propose de garder les données et affiche ce qui n'a pas pu
# être retiré. Mindset se ferme pour lui laisser la place.
function Get-ApplisGerees { @($Applis | Where-Object { $i = Get-Installation $_; $i -and $i.Gere }) }
$DesinstalleurMindset = Join-Path (Split-Path $AppDir -Parent) 'Desinstaller Mindset.exe'

function Confirm-DesinstallMindset {
    if ((Test-MindsetInstalle) -and (Test-Path -LiteralPath $DesinstalleurMindset)) {
        $g = @(Get-ApplisGerees)
        $applis = if ($g.Count) { " Les applis qu'il a installées ($(($g | ForEach-Object Nom) -join ', ')) seront retirées aussi." } else { '' }
        Show-Confirmation 'Désinstaller Mindset ?' "Mindset va se fermer et ouvrir son désinstalleur (accepte la demande de Windows).$applis Tu pourras choisir de garder tes données." 'Continuer' {
            if ($EnTest) { return }
            try { Start-Process -FilePath $DesinstalleurMindset -WorkingDirectory $env:SystemRoot -ErrorAction Stop }
            catch { Show-Confirmation 'Le désinstalleur ne s''ouvre pas' "Windows n'a pas pu lancer $DesinstalleurMindset ($($_.Exception.Message))." 'Réessayer' { Confirm-DesinstallMindset }; return }
            Write-Log 'Désinstallation de Mindset : désinstalleur lancé'
            Exit-Mindset -AvecApplis
        }
        return
    }
    # Sans désinstalleur autonome (copie de travail, copie pas installée, ou d'avant lui) : comme avant, mais ce qui ne
    # part pas est dit à l'utilisateur au lieu d'être seulement noté dans le journal
    $g = @(Get-ApplisGerees)
    if ($g.Count) {
        Show-Confirmation 'Désinstalle d''abord les applis' "Mindset gère encore $(($g | ForEach-Object Nom) -join ' et ') : désinstalle-les depuis l'accueil, puis reviens ici. Leurs données sont gardées." 'Aller à l''accueil' { Show-Page 'accueil' }
        return
    }
    Show-Confirmation 'Désinstaller Mindset ?' "Mindset, son raccourci et son lancement au démarrage vont être retirés. Ses données (et celles des applis) restent dans $SuiteDir : une réinstallation les retrouve." 'Désinstaller' {
        $restes = @()
        foreach ($l in $RaccourcisMindset) {
            try { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force -ErrorAction Stop } } catch { $restes += "le raccourci $l" }
        }
        try { if ($null -ne (Get-ItemProperty -Path $CleRun -Name 'Mindset' -ErrorAction SilentlyContinue)) { Remove-ItemProperty -Path $CleRun -Name 'Mindset' -ErrorAction Stop } }
        catch { $restes += 'le lancement avec Windows (registre)' }
        if ($restes) {
            Write-Log "Désinstallation de Mindset : il reste $($restes -join ', ')"
            Show-Confirmation 'Désinstallation pas finie' "Ces éléments n'ont pas pu être retirés : $($restes -join ', '). Ferme les programmes qui pourraient les utiliser, puis réessaie." 'Réessayer' { Confirm-DesinstallMindset }
            return
        }
        if (Test-MindsetInstalle) {
            # Le dossier est supprimé en administrateur une fois ce Mindset fermé ; si la demande ne part même pas
            # (autorisation refusée, mini-installateur absent), Mindset reste ouvert et le dit.
            # (Une fois Mindset fermé, installer-admin.ps1 affiche lui-même ce qui n'a pas pu être retiré.)
            $script:DesinstallEchec = $null
            Invoke-Admin 'supprimer' @{ Destination = $DossierMindset; AttendrePid = $PID } {
                param($Ok, $Message)
                if (-not $Ok) { Write-Log "Désinstallation de Mindset : $Message"; $script:DesinstallEchec = $Message }
            }
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromSeconds(2)
            $t.Add_Tick({
                $this.Stop()
                if ($script:DesinstallEchec) {
                    Show-Confirmation 'Désinstallation impossible' "Le dossier $DossierMindset et les tâches planifiées de Mindset n'ont pas pu être retirés : $($script:DesinstallEchec)" 'Réessayer' { Confirm-DesinstallMindset }
                    return
                }
                Write-Log 'Mindset désinstallé'
                Exit-Mindset
            })
            $t.Start()
        } else { Write-Log 'Mindset désinstallé'; Exit-Mindset }
    }
}

# Mindset s'ouvre (ou démarre avec Windows, caché) : les applis « S'ouvre avec Mindset » démarrent en arrière-plan,
# prêtes à s'afficher dans leur onglet. Pas après une relance pour un nouveau thème (une appli fermée resterait fermée).
# Une appli administrateur (Nevermind) seulement si Mindset l'est aussi : sinon Windows demanderait l'autorisation.
function Start-Demarrage {
    if ($EnTest) { return }
    # Les raccourcis du menu Démarrer (le nom de chaque appli dans la barre des tâches), réparés s'il le faut
    Update-RaccourcisApplis
    Update-RaccourcisMindset
    $marque = Join-Path $DataDir 'relance.marque'
    if (Test-Path -LiteralPath $marque) {
        $recente = ((Get-Date) - (Get-Item -LiteralPath $marque).LastWriteTime).TotalSeconds -lt 120
        Remove-Item -LiteralPath $marque -Force -ErrorAction SilentlyContinue
        if ($recente) { return }
    }
    Move-TachesDemarrage
    foreach ($a in $Applis) {
        if ((Test-AppliAdmin $a) -and -not $MindsetAdmin) { continue }
        if (-not (Get-DemarrageAppli $a.Id)) { continue }
        $i = Get-Installation $a
        if ($i -and $i.Gere) { Open-Appli $a -Demarrage }
    }
}

# ---------------------------------------------------------------------------
# Mise à jour de Mindset lui-même (au démarrage, puis toutes les heures avec les applis, si « Chercher les nouvelles
# versions » est activé ; sinon seulement avec « Actualiser » ou « Vérifier maintenant ») :
# la nouvelle version est téléchargée et sa signature vérifiée en arrière-plan, puis un bandeau la propose.
# Un clic : Mindset se ferme, installer-admin.ps1 (une demande de Windows) vérifie à nouveau et installe, puis le relance.
# ---------------------------------------------------------------------------
$FichierMajMindset = Join-Path $TelechargementsDir 'maj-mindset.json'

function Start-VerifMajMindset {
    if (-not ((Test-MindsetInstalle) -or ($EnTest -and $env:MINDSET_MAJ_TEST)) -or $script:MajMindset -or $script:MajMindsetEnCours) { return }
    $script:MajMindsetEnCours = $true
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    Start-Tache {
        $p = $args[0]
        $pub = Get-Publication 'JordanJacquot/Mindset' 'Mindset.zip'
        if ($pub.Erreur) { throw $pub.Erreur }
        if (-not (Test-VersionPlusRecente $pub.Version $p.Version)) { return @{ AJour = $true } }
        if (-not $pub.UrlSig) { throw "la version $($pub.Version) n'est pas signée" }
        $zip = Get-Octets $pub.UrlZip; $sig = Get-Octets $pub.UrlSig
        if (-not (Test-Signature $zip $sig $p.Cle)) { throw "la signature de la version $($pub.Version) est invalide" }
        $fz = Join-Path $p.Dossier 'mindset.zip'
        [IO.File]::WriteAllBytes($fz, $zip); [IO.File]::WriteAllBytes("$fz.sig", $sig)
        @{ Version = $pub.Version; Zip = $fz; Sig = "$fz.sig"; Notes = $pub.Notes }
    } @{ Version = $AppVersion; Cle = $ClePublique; Dossier = $TelechargementsDir } {
        param($Resultat, $Erreur)
        $script:MajMindsetEnCours = $false
        if ($script:OngletParametres -eq 'maj') { Update-ListeVersions }
        if ($Erreur) {
            Write-Log "Mise à jour de Mindset : $Erreur"
            if ($Erreur -match '403|429') { $script:DernieresPublications = (Get-Date).AddHours(-5.5) }   # (limite de GitHub : réessai dans 30 minutes)
            return
        }
        if (-not $Resultat.Version) { return }
        $script:MajMindset = $Resultat
        Write-Log "Mindset $($Resultat.Version) téléchargé et vérifié, prêt à installer"
        $ui.MajTitre.Text = "Mindset $($Resultat.Version) est prêt"
        $ui.MajTexte.Text = "La nouvelle version est téléchargée et sa signature vérifiée. Mindset va se fermer, se mettre à jour et se rouvrir tout seul."
        $ui.BtnMajMindset.Visibility = 'Visible'; $ui.BtnMajFermer.Content = 'Plus tard'
        $ui.MajBandeau.Visibility = 'Visible'
    }
}

# -Cache : mise à jour automatique faite pendant que Mindset est caché : il revient caché près de l'horloge
function Start-MajMindset([switch]$Cache) {
    $m = $script:MajMindset
    if (-not $m -or $script:Occupe.Count) { if ($script:Occupe.Count) { $ui.MajTexte.Text = 'Une installation est en cours : réessaie quand elle sera finie.' }; return }
    Remove-Item -LiteralPath $FichierMajMindset -Force -ErrorAction SilentlyContinue
    # Par le mini-installateur (sans demande de Windows) : il attend la fermeture de Mindset, installe, puis le relance
    if (-not $MindsetAdmin -and (Test-TacheInstallation)) {
        $id = [guid]::NewGuid().ToString('N')
        $c = @{ Id = $id; Action = 'mindset-maj'; Zip = [string]$m.Zip; Signature = [string]$m.Sig; Destination = [string]$DossierMindset; Version = [string]$m.Version; AttendrePid = [string]$PID }
        if ($Cache) { $c.Cache = '1' }
        try {
            [IO.File]::WriteAllText($FichierDemande, (ConvertTo-Json -InputObject $c -Compress), (New-Object Text.UTF8Encoding $false))
            $null = & "$env:SystemRoot\System32\schtasks.exe" /Run /TN $TacheInstallation 2>&1
            if ($LASTEXITCODE -ne 0) { throw "code $LASTEXITCODE" }
        } catch { $ui.MajTexte.Text = "Mise à jour impossible : la tâche d'installation n'a pas démarré ($($_.Exception.Message))."; return }
        Set-Setting 'MajMindsetDemande' $id
        Write-Log "Mise à jour vers Mindset $($m.Version) lancée"
        Exit-Mindset
        return
    }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $AppDir 'installer-admin.ps1')`"", '-Action', 'mindset-maj',
           '-Zip', "`"$($m.Zip)`"", '-Signature', "`"$($m.Sig)`"", '-Destination', "`"$DossierMindset`"", '-Version', $m.Version, '-AttendrePid', $PID, '-Resultat', "`"$FichierMajMindset`"")
    # (lancé depuis le dossier de Windows : s'il gardait le dossier de Mindset comme dossier courant, il ne pourrait pas le remplacer)
    try { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -Verb RunAs -WindowStyle Hidden -WorkingDirectory $env:SystemRoot -ErrorAction Stop | Out-Null }
    catch { $ui.MajTexte.Text = 'Mise à jour annulée : l''autorisation de Windows a été refusée. Tu peux réessayer.'; return }
    Write-Log "Mise à jour vers Mindset $($m.Version) lancée"
    Exit-Mindset   # installer-admin.ps1 attend la fermeture, installe, puis relance Mindset
}

# Après une mise à jour : le résultat laissé par installer-admin.ps1
function Show-ResultatMajMindset {
    $r = $null
    # Mise à jour faite par le mini-installateur : sa réponse dans le registre, reconnue à son numéro
    $id = [string](Get-Setting 'MajMindsetDemande' '')
    if ($id) {
        Set-Setting 'MajMindsetDemande' ''
        try { $r = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Mindset\Installation' -Name Resultat -ErrorAction Stop).Resultat | ConvertFrom-Json } catch {}
        if ($r -and $r.id -ne $id) { $r = $null }
    }
    if (-not $r) {
        if (-not (Test-Path -LiteralPath $FichierMajMindset)) { return }
        try { $r = [IO.File]::ReadAllText($FichierMajMindset, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return }
        Remove-Item -LiteralPath $FichierMajMindset -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in 'mindset.zip', 'mindset.zip.sig') { Remove-Item -LiteralPath (Join-Path $TelechargementsDir $f) -Force -ErrorAction SilentlyContinue }
    $ui.BtnMajMindset.Visibility = 'Collapsed'; $ui.BtnMajFermer.Content = 'OK'
    if ($r.ok) { $ui.MajTitre.Text = "Mindset est à jour (version $AppVersion)"; $ui.MajTexte.Text = 'La mise à jour s''est bien passée.' }
    else { $ui.MajTitre.Text = 'La mise à jour de Mindset n''a pas pu se faire'; $ui.MajTexte.Text = "$($r.message) Mindset garde sa version actuelle et réessaiera plus tard." }
    Write-Log "Résultat de la mise à jour de Mindset : $(if ($r.ok) { 'réussie' } else { $r.message })"
    $ui.MajBandeau.Visibility = 'Visible'
}

# ---------------------------------------------------------------------------
# Mises à jour automatiques (réglage « MajAuto », activé par défaut ; Paramètres, Mises à jour) : vérifié toutes les
# 30 secondes. Une appli fermée est mise à jour dès que sa nouvelle version est connue ; une appli qui tourne (souvent
# cachée près de l'horloge) quand personne ne touche au PC depuis 5 minutes, puis elle est relancée cachée ; Mindset
# lui-même quand il est caché, et il revient caché. Jamais pendant un jeu ou une vidéo en plein écran, jamais pendant
# une autre installation, et seulement par le mini-installateur (aucune demande de Windows). Une à la fois ; une
# version ratée n'est pas réessayée avant 6 heures. Une notification (ou la bulle de la console) dit ce qui a changé.
# ---------------------------------------------------------------------------
$script:MajAuto = @{}          # id -> version en cours de mise à jour automatique
$script:MajAutoEssais = @{}    # id -> @{ Version; Quand } (dernier essai)
$script:MajAutoDerniere = [datetime]::MinValue
function Test-MajAutoActive { [bool](Get-Setting 'MajAuto' $true) }

# « Chercher les nouvelles versions » (réglage « VerifVersions », activé par défaut ; Paramètres, Mises à jour, et le
# bandeau d'installation) : coupé, Mindset ne demande plus rien à GitHub de lui-même (ni au démarrage, ni toutes les
# heures, ni en revenant de l'horloge), et les mises à jour automatiques ne tournent plus (elles en dépendent). Les
# gestes de l'utilisateur restent possibles : « Actualiser », « Vérifier maintenant », installer, mettre à jour.
function Test-VerifVersionsActive { [bool](Get-Setting 'VerifVersions' $true) }
function Set-VerifVersions([bool]$Oui) {
    Set-Setting 'VerifVersions' $Oui
    Write-Log "Chercher les nouvelles versions tout seul : $(if ($Oui) { 'oui' } else { 'non' })"
    if (Get-Command Update-InfoActualiser -ErrorAction SilentlyContinue) { Update-InfoActualiser }
}

# La page qui dit ce que Mindset (et chaque appli) envoie sur Internet, ouverte dans le navigateur. Seulement une adresse
# connue : celle de Mindset, ou celle d'une appli de apps.json (vérifiée par applis.ps1).
$PageConfidentialite = 'https://github.com/JordanJacquot/Mindset/blob/main/CODE_SIGNING.md'
function Open-PageConfidentialite([string]$Id) {
    $url = $PageConfidentialite
    if ($Id) { $a = Get-Appli $Id; if ($a -and $a.Confidentialite) { $url = $a.Confidentialite } }
    Write-Log "Page de confidentialité ouverte : $url"
    if ($EnTest) { return }
    try { Start-Process -FilePath $url } catch { Write-Log "Navigateur : $($_.Exception.Message)" }
}

function Test-MajAutoRecente([string]$Id, [string]$Version) {
    $d = $script:MajAutoEssais[$Id]
    $d -and $d.Version -eq $Version -and ((Get-Date) - $d.Quand).TotalHours -lt 6
}

function Invoke-MajAuto {
    if ($EnTest -and -not $env:MINDSET_MAJAUTO_TEST) { return }
    if (-not (Test-MajAutoActive) -or -not (Test-VerifVersionsActive) -or $MindsetAdmin -or -not (Test-TacheInstallation)) { return }
    if (((Get-Date) - $script:MajAutoDerniere).TotalSeconds -lt 30) { return }
    $script:MajAutoDerniere = Get-Date
    if ($script:Occupe.Count -or $script:AttentesAdmin.Count -or $script:MajAuto.Count) { return }
    try { if ([MSActivite]::PleinEcranDevant()) { return }; $inactif = [MSActivite]::SecondesInactif() } catch { return }
    foreach ($a in $Applis) {
        $e = Get-EtatCarte $a
        if (-not $e.MajDispo -or $e.Occupe) { continue }
        $v = [string]$e.Pub.Version
        if (Test-MajAutoRecente $a.Id $v) { continue }
        if ($e.Ouverte) {
            if ($inactif -lt 300) { continue }                                                     # on s'en sert peut-être
            if ($script:PageCourante -eq $a.Id -and $Window.IsVisible -and $Window.WindowState -ne 'Minimized') { continue }   # à l'écran dans Mindset
        }
        $script:MajAutoEssais[$a.Id] = @{ Version = $v; Quand = Get-Date }
        $script:MajAuto[$a.Id] = $v
        Write-Log "Mise à jour automatique : $($a.Nom) $v$(if ($e.Ouverte) { ' (elle tournait, relancée cachée)' })"
        Start-InstallAppli $a
        return
    }
    # Mindset lui-même, seulement caché (près de l'horloge, ou réduit)
    $m = $script:MajMindset
    if ($m -and -not ($Window.IsVisible -and $Window.WindowState -ne 'Minimized') -and -not (Test-MajAutoRecente 'mindset' ([string]$m.Version))) {
        $script:MajAutoEssais['mindset'] = @{ Version = [string]$m.Version; Quand = Get-Date }
        Write-Log "Mise à jour automatique : Mindset $($m.Version)"
        Start-MajMindset -Cache
    }
}

# Fin d'une mise à jour automatique (appelé par Stop-Operation) : la notification, ou la bulle de la console
function Complete-MajAuto($Appli, [string]$Message) {
    $v = $script:MajAuto[$Appli.Id]; $script:MajAuto.Remove($Appli.Id)
    if ($Message -notmatch 'est installé') { Write-Log "Mise à jour automatique de $($Appli.Nom) $v ratée : $Message"; return }
    $titre = "$($Appli.Nom) est passé en $v"
    $notes = [string]$script:Publications[$Appli.Id].Notes
    $resume = (($notes -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -replace '^[-*#\s]+', '').Trim()
    if ($resume.Length -gt 180) { $resume = $resume.Substring(0, 177) + '...' }
    Show-BulleMajAuto $titre $resume
}

function Show-BulleMajAuto([string]$Titre, [string]$Texte) {
    Write-Log "Mise à jour automatique : $Titre"
    if ($Window.IsVisible -and $Window.WindowState -ne 'Minimized' -and $script:Console.Pret) {
        Invoke-ScriptConsole "window.mindset.message($(ConvertTo-Json -InputObject $Titre -Compress))"
    } elseif ($script:IconeHorloge) {
        try { $script:IconeHorloge.ShowBalloonTip(6000, $Titre, $(if ($Texte) { $Texte } else { 'Mise à jour faite toute seule.' }), [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }
}
