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
        $exe = Join-Path $dossier 'Mindset.exe'
        $sh = New-Object -ComObject WScript.Shell
        foreach ($l in $RaccourcisMindset) {
            try { $s = $sh.CreateShortcut($l); $s.TargetPath = $exe; $s.WorkingDirectory = $dossier; $s.IconLocation = "$exe,0"; $s.Description = 'Mindset : Nevermind et Evermind au même endroit'; $s.Save() }
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

# Désinstaller Mindset : seulement quand plus aucune appli n'est gérée par lui (elles n'ont plus d'autre accès)
function Get-ApplisGerees { @($Applis | Where-Object { $i = Get-Installation $_; $i -and $i.Gere }) }

function Confirm-DesinstallMindset {
    $g = @(Get-ApplisGerees)
    if ($g.Count) {
        Show-Confirmation 'Désinstalle d''abord les applis' "Mindset gère encore $(($g | ForEach-Object Nom) -join ' et ') : désinstalle-les depuis l'accueil, puis reviens ici. Leurs données sont gardées." 'Aller à l''accueil' { Show-Page 'accueil' }
        return
    }
    Show-Confirmation 'Désinstaller Mindset ?' "Mindset, son raccourci et son lancement au démarrage vont être retirés. Ses données (et celles des applis) restent dans $SuiteDir : une réinstallation les retrouve." 'Désinstaller' {
        foreach ($l in $RaccourcisMindset) { Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue }
        Remove-ItemProperty -Path $CleRun -Name 'Mindset' -ErrorAction SilentlyContinue
        if (Test-MindsetInstalle) {
            # Le dossier est supprimé en administrateur une fois ce Mindset fermé
            Invoke-Admin 'supprimer' @{ Destination = $DossierMindset; AttendrePid = $PID } { param($Ok, $Message) if (-not $Ok) { Write-Log "Désinstallation de Mindset : $Message" } }
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromSeconds(2)
            $t.Add_Tick({ $this.Stop(); Exit-Mindset })
            $t.Start()
        } else { Exit-Mindset }
        Write-Log 'Mindset désinstallé'
    }
}

# Mindset s'ouvre (ou démarre avec Windows, caché) : les applis « S'ouvre avec Mindset » démarrent en arrière-plan,
# prêtes à s'afficher dans leur onglet. Pas après une relance pour un nouveau thème (une appli fermée resterait fermée).
# Une appli administrateur (Nevermind) seulement si Mindset l'est aussi : sinon Windows demanderait l'autorisation.
function Start-Demarrage {
    if ($EnTest) { return }
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
# Mise à jour de Mindset lui-même (au démarrage, puis toutes les 6 heures avec les applis) :
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
        $ui.MajTexte.Text = "La nouvelle version est téléchargée et sa signature vérifiée. Mindset va se fermer, se mettre à jour (Windows demande l'autorisation) et se rouvrir tout seul."
        $ui.BtnMajMindset.Visibility = 'Visible'; $ui.BtnMajFermer.Content = 'Plus tard'
        $ui.MajBandeau.Visibility = 'Visible'
    }
}

function Start-MajMindset {
    $m = $script:MajMindset
    if (-not $m -or $script:Occupe.Count) { if ($script:Occupe.Count) { $ui.MajTexte.Text = 'Une installation est en cours : réessaie quand elle sera finie.' }; return }
    Remove-Item -LiteralPath $FichierMajMindset -Force -ErrorAction SilentlyContinue
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
    if (-not (Test-Path -LiteralPath $FichierMajMindset)) { return }
    try { $r = [IO.File]::ReadAllText($FichierMajMindset, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return }
    Remove-Item -LiteralPath $FichierMajMindset -Force -ErrorAction SilentlyContinue
    foreach ($f in 'mindset.zip', 'mindset.zip.sig') { Remove-Item -LiteralPath (Join-Path $TelechargementsDir $f) -Force -ErrorAction SilentlyContinue }
    $ui.BtnMajMindset.Visibility = 'Collapsed'; $ui.BtnMajFermer.Content = 'OK'
    if ($r.ok) { $ui.MajTitre.Text = "Mindset est à jour (version $AppVersion)"; $ui.MajTexte.Text = 'La mise à jour s''est bien passée.' }
    else { $ui.MajTitre.Text = 'La mise à jour de Mindset n''a pas pu se faire'; $ui.MajTexte.Text = "$($r.message) Mindset garde sa version actuelle et réessaiera plus tard." }
    Write-Log "Résultat de la mise à jour de Mindset : $(if ($r.ok) { 'réussie' } else { $r.message })"
    $ui.MajBandeau.Visibility = 'Visible'
}
