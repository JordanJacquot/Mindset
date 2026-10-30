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
        $j = Read-JsonSur $f   # (illisible : une erreur, rien n'est écrit par-dessus ses réglages)
        if ($null -ne $j) { foreach ($p in $j.PSObject.Properties) { $r[$p.Name] = $p.Value } }
        $r['VerifVersions'] = $false
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        Save-JsonSur $f ($r | ConvertTo-Json -Depth 5)
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
    # (une fois : les applis prises en charge avant que Mindset ne reprenne leur démarrage, et qui se lançaient avec Windows s'ouvrent avec Mindset)
    Repair-DemarrageApplis
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

# Une version déjà prête (téléchargée, pas encore installée) n'arrête pas la recherche : si une plus récente sort entre-
# temps, elle la remplace (sinon Mindset installerait une version déjà dépassée). Le nouveau zip est écrit à côté
# (.nouveau), puis mis à la place de l'ancien d'un coup, dans la fenêtre : une installation lancée pendant le
# téléchargement prend toujours un zip complet.
# Pendant le téléchargement, $script:ProgresMindset (table partagée avec la tâche de fond : Version, Recu, Total) donne
# la barre et le % de la carte des mises à jour de la console (console.ps1, Get-EtatMajConsole).
$script:ProgresMindset = $null
function Start-VerifMajMindset {
    if (-not ((Test-MindsetInstalle) -or ($EnTest -and $env:MINDSET_MAJ_TEST)) -or $script:MajMindsetEnCours) { return }
    $script:MajMindsetEnCours = $true
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    $deja = if ($script:MajMindset -and (Test-VersionPlusRecente ([string]$script:MajMindset.Version) $AppVersion)) { [string]$script:MajMindset.Version } else { $AppVersion }
    $script:ProgresMindset = [hashtable]::Synchronized(@{ Version = ''; Recu = 0; Total = 0 })
    Start-Tache {
        $p = $args[0]
        $pub = Get-Publication 'JordanJacquot/Mindset' 'Mindset.zip'
        if ($pub.Erreur) { throw $pub.Erreur }
        if (-not (Test-VersionPlusRecente $pub.Version $p.Version)) { return @{ AJour = $true } }
        if (-not $pub.UrlSig) { throw "la version $($pub.Version) n'est pas signée" }
        $p.Progres.Version = [string]$pub.Version   # (la recherche est finie : c'est maintenant un téléchargement)
        $zip = Get-Octets $pub.UrlZip $p.Progres; $sig = Get-Octets $pub.UrlSig
        if (-not (Test-Signature $zip $sig $p.Cle)) { throw "la signature de la version $($pub.Version) est invalide" }
        $fz = Join-Path $p.Dossier 'mindset.zip.nouveau'
        [IO.File]::WriteAllBytes($fz, $zip); [IO.File]::WriteAllBytes("$fz.sig", $sig)
        @{ Version = $pub.Version; Zip = $fz; Sig = "$fz.sig"; Notes = $pub.Notes }
    } @{ Version = $deja; Cle = $ClePublique; Dossier = $TelechargementsDir; Progres = $script:ProgresMindset } {
        param($Resultat, $Erreur)
        $script:MajMindsetEnCours = $false; $script:ProgresMindset = $null
        if ($script:OngletParametres -eq 'maj') { Update-ListeVersions }
        if ($Erreur) {
            Write-Log "Mise à jour de Mindset : $Erreur"
            if ($Erreur -match '403|429') { $script:DernieresPublications = (Get-Date).AddHours(-5.5) }   # (limite de GitHub : réessai dans 30 minutes)
            return
        }
        if (-not $Resultat.Version) { return }
        # Le zip vérifié prend la place de celui d'avant (une version plus ancienne, prête mais pas installée)
        $fz = Join-Path $TelechargementsDir 'mindset.zip'
        try {
            Move-Item -LiteralPath $Resultat.Zip -Destination $fz -Force -ErrorAction Stop
            Move-Item -LiteralPath $Resultat.Sig -Destination "$fz.sig" -Force -ErrorAction Stop
        } catch {
            Write-Log "Mise à jour de Mindset : le zip de la version $($Resultat.Version) n'a pas pu remplacer l'ancien ($($_.Exception.Message))"
            foreach ($f in $Resultat.Zip, $Resultat.Sig) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            return
        }
        $avant = $script:MajMindset
        $Resultat.Zip = $fz; $Resultat.Sig = "$fz.sig"
        if ($avant) { Write-Log "Mindset $($avant.Version) était prêt, remplacé par la $($Resultat.Version), plus récente" }
        $script:MajMindset = $Resultat
        Write-Log "Mindset $($Resultat.Version) téléchargé et vérifié, prêt à installer"
        $ui.MajTitre.Text = "Mindset $($Resultat.Version) est prêt"
        $ui.MajTexte.Text = "La nouvelle version est téléchargée et sa signature vérifiée. Mindset va se fermer, se mettre à jour et se rouvrir tout seul."
        $ui.BtnMajMindset.Visibility = 'Visible'; $ui.BtnMajFermer.Content = 'Plus tard'
        $ui.MajBandeau.Visibility = 'Visible'
    }
}

# -Auto : mise à jour automatique (Invoke-MajAuto) : jamais de demande de Windows (personne pour y répondre), un échec
# est montré par la console (Set-EchecMajAuto). -Cache : automatique, faite pendant que Mindset est caché : il revient
# caché près de l'horloge (sans -Cache, il revient avec sa fenêtre)
function Start-MajMindset([switch]$Cache, [switch]$Auto) {
    $enAuto = [bool]($Auto -or $Cache)
    $m = $script:MajMindset
    if (-not $m -or $script:Occupe.Count) { if ($script:Occupe.Count) { $ui.MajTexte.Text = 'Une installation est en cours : réessaie quand elle sera finie.' }; return }
    if ($script:MajMindsetEnvoyee) { return }   # (déjà envoyée au mini-installateur : on attend son accusé de réception)
    if (-not $enAuto -and $script:MajAutoEchecs) { $script:MajAutoEchecs.Remove('mindset') }   # (« Réessayer » : la carte ne dit plus l'échec)
    Remove-Item -LiteralPath $FichierMajMindset -Force -ErrorAction SilentlyContinue
    Set-MajMindsetAttendue ([string]$m.Version) $enAuto ([string]$m.Notes)   # (l'historique, au redémarrage)
    # Demandée à l'écran : Mindset revient avec sa fenêtre (le mini-installateur le relance par sa tâche de démarrage, qui
    # le lancerait sinon caché près de l'horloge, voir Mindset.ps1)
    Set-Setting 'MajMindsetVisible' (-not $Cache)
    # Par le mini-installateur (sans demande de Windows) : il attend la fermeture de Mindset, installe, puis le relance.
    # Mindset ne se ferme qu'à son accusé de réception ; sans lui (tâche absente, refusée, muette), la demande de Windows.
    if (-not $MindsetAdmin -and (Test-TacheInstallation)) {
        $id = [guid]::NewGuid().ToString('N')
        $c = @{ Id = $id; Action = 'mindset-maj'; Zip = [string]$m.Zip; Signature = [string]$m.Sig; Destination = [string]$DossierMindset; Version = [string]$m.Version; AttendrePid = [string]$PID }
        if ($Cache) { $c.Cache = '1' }
        $script:MajMindsetEnvoyee = $true
        $script:MajMindsetAuto = if ($enAuto) { [string]$m.Version } else { '' }   # (pour sa fin : un échec automatique se montre)
        $d = @{ Contenu = $c; Auto = $enAuto
            Recu  = { param($D) Set-Setting 'MajMindsetDemande' $D.Contenu.Id; Write-Log "Mise à jour vers Mindset $($D.Contenu.Version) lancée"; Exit-Mindset }
            Fin   = { param($Ok, $Message) $script:MajMindsetEnvoyee = $false
                if (-not $Ok) { $ui.MajTexte.Text = "Mise à jour impossible : $Message"; if ($script:MajMindsetAuto) { Set-EchecMajAuto 'mindset' 'Mindset' ([string]$script:MajMindsetAuto) $Message } } }
            Repli = { param($D) $script:MajMindsetEnvoyee = $false
                if ($D.Auto) { Set-EchecMajAuto 'mindset' 'Mindset' ([string]$D.Contenu.Version) 'la tâche d''installation ne répond pas' } else { Start-MajMindsetDirecte } } }
        [void](Send-DemandeInstallation $d)
        return
    }
    Start-MajMindsetDirecte
}

# Par la demande normale de Windows : installer-admin.ps1 en administrateur, il attend la fermeture, installe, puis relance
function Start-MajMindsetDirecte {
    $m = $script:MajMindset
    if (-not $m) { return }
    try {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Format-ArgumentAdmin (Join-Path $AppDir 'installer-admin.ps1')), '-Action', 'mindset-maj',
               '-Zip', (Format-ArgumentAdmin $m.Zip), '-Signature', (Format-ArgumentAdmin $m.Sig), '-Destination', (Format-ArgumentAdmin $DossierMindset), '-Version', $m.Version, '-AttendrePid', $PID,
               '-Sid', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value, '-Resultat', (Format-ArgumentAdmin $FichierMajMindset))
    } catch { $ui.MajTexte.Text = "Mise à jour impossible : $($_.Exception.Message)"; return }
    # (variables d'environnement qui détourneraient le PowerShell administrateur : rien n'est lancé, voir installations.ps1)
    $refus = Get-RefusVariablesAdmin
    if ($refus) { $ui.MajTexte.Text = "Mise à jour impossible : $refus"; return }
    # (lancé depuis le dossier de Windows : s'il gardait le dossier de Mindset comme dossier courant, il ne pourrait pas le remplacer)
    try { Start-Process -FilePath $PowerShellWindows -ArgumentList $a -Verb RunAs -WindowStyle Hidden -WorkingDirectory ([Environment]::GetFolderPath('Windows')) -ErrorAction Stop | Out-Null }
    catch { $ui.MajTexte.Text = 'Mise à jour annulée : l''autorisation de Windows a été refusée. Tu peux réessayer.'; return }
    Write-Log "Mise à jour vers Mindset $($m.Version) lancée"
    Exit-Mindset   # installer-admin.ps1 attend la fermeture, installe, puis le relance
}

# Après une mise à jour : le résultat laissé par installer-admin.ps1
function Show-ResultatMajMindset {
    Resolve-MajMindsetAttendue
    Set-Setting 'MajMindsetVisible' $false
    Show-RestesDesinstallation
    $r = $null
    # Mise à jour faite par le mini-installateur : sa réponse dans le registre, reconnue à son numéro
    $id = [string](Get-Setting 'MajMindsetDemande' '')
    if ($id) {
        Set-Setting 'MajMindsetDemande' ''
        try { $r = Get-ValeurInstallation 'Resultat' | ConvertFrom-Json } catch {}
        if ($r -and $r.id -ne $id) { $r = $null }
        Remove-DemandeInstallation   # (le mini-installateur ne l'efface pas : c'est à Mindset de le faire)
    }
    if (-not $r) {
        if (-not (Test-Path -LiteralPath $FichierMajMindset)) { return }
        try { $r = [IO.File]::ReadAllText($FichierMajMindset, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return }
        Remove-Item -LiteralPath $FichierMajMindset -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in 'mindset.zip', 'mindset.zip.sig', 'mindset.zip.nouveau', 'mindset.zip.nouveau.sig') { Remove-Item -LiteralPath (Join-Path $TelechargementsDir $f) -Force -ErrorAction SilentlyContinue }
    $ui.BtnMajMindset.Visibility = 'Collapsed'; $ui.BtnMajFermer.Content = 'OK'
    if ($r.ok) { $ui.MajTitre.Text = "Mindset est à jour (version $AppVersion)"; $ui.MajTexte.Text = 'La mise à jour s''est bien passée.' }
    else { $ui.MajTitre.Text = 'La mise à jour de Mindset n''a pas pu se faire'; $ui.MajTexte.Text = "$($r.message) Mindset garde sa version actuelle et réessaiera plus tard." }
    Write-Log "Résultat de la mise à jour de Mindset : $(if ($r.ok) { 'réussie' } else { $r.message })"
    $ui.MajBandeau.Visibility = 'Visible'
}

# Désinstallation de Mindset faite par le mini-installateur (sans désinstalleur autonome) et pas allée au bout : ce qui
# reste, écrit dans HKLM par le mini-installateur (en SYSTEM, il n'affiche aucune fenêtre), est dit ici
function Show-RestesDesinstallation {
    $t = Get-ValeurInstallation 'Restes'
    if (-not $t) { return }
    Write-Log "Désinstallation de Mindset pas finie : $t"
    $ui.MajTitre.Text = 'Mindset n''a pas pu être désinstallé entièrement'
    $ui.MajTexte.Text = $t
    $ui.BtnMajMindset.Visibility = 'Collapsed'; $ui.BtnMajFermer.Content = 'OK'
    $ui.MajBandeau.Visibility = 'Visible'
}

# ---------------------------------------------------------------------------
# Mises à jour automatiques (réglage « MajAuto », activé par défaut ; Paramètres, Mises à jour) : vérifié toutes les
# 30 secondes. Une appli fermée est mise à jour dès que sa nouvelle version est connue ; une appli qui tourne (souvent
# cachée près de l'horloge) quand personne ne touche au PC depuis 5 minutes, puis elle est relancée cachée ; Mindset
# lui-même quand il est caché, ou à l'écran quand personne ne touche au PC depuis 5 minutes (il revient comme il était).
# Jamais pendant un jeu (Get-JeuEnCours : plein écran sur n'importe quel écran, manette, jeu ouvert en fenêtre), jamais
# pendant une autre installation, et seulement par le mini-installateur (aucune demande de Windows). Une appli fermée par
# l'utilisateur n'est pas rouverte. Une à la fois. Une version ratée est réessayée 15 minutes plus tard, 3 fois au plus
# par session ; la console montre l'échec, sa raison et « Réessayer ». Une notification (ou la bulle de la console) dit
# ce qui a changé, ou ce qui n'a pas pu se faire.
# ---------------------------------------------------------------------------
$script:MajAuto = @{}          # id -> version en cours de mise à jour automatique
$script:MajAutoEssais = @{}    # id -> @{ Version; Quand; Nombre } (dernier essai, et combien pour cette version)
$script:MajAutoEchecs = @{}    # id -> @{ Version; Raison } (dernier essai raté, montré par la console avec « Réessayer »)
$script:MajAutoDerniere = [datetime]::MinValue
# Pourquoi une mise à jour attend (vu au dernier passage, montré par la console : Get-EtatMajConsole) : le jeu en cours
# (sa raison, ou ''), et pour chaque appli (ou « mindset ») « utilise » (on se sert du PC), « page » (sa page est à
# l'écran dans Mindset) ou « veille » (Mindset à l'écran et le PC utilisé)
$script:MajAutoJeu = ''
$script:MajAutoAttentes = @{}
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

# Un essai automatique de cette version vient d'être fait (moins de 15 minutes), ou il y en a déjà eu 3 dans cette
# session : pas de nouvel essai tout seul (le bouton « Mettre à jour » ou « Réessayer » reste là)
function Test-MajAutoRecente([string]$Id, [string]$Version) { $null -ne (Get-MajAutoReessai $Id $Version) }
# Dans combien de minutes le prochain essai tout seul : 0 et plus (il attend), -1 (plus d'essai tout seul : 3 déjà
# faits), $null (rien ne l'empêche)
function Get-MajAutoReessai([string]$Id, [string]$Version) {
    $d = $script:MajAutoEssais[$Id]
    if (-not $d -or $d.Version -ne $Version) { return $null }
    if ([int]$d.Nombre -ge 3) { return -1 }
    $reste = 15 - ((Get-Date) - $d.Quand).TotalMinutes
    if ($reste -gt 0) { [int][math]::Ceiling($reste) } else { $null }
}
function Add-MajAutoEssai([string]$Id, [string]$Version) {
    $d = $script:MajAutoEssais[$Id]
    $n = if ($d -and $d.Version -eq $Version) { [int]$d.Nombre + 1 } else { 1 }
    $script:MajAutoEssais[$Id] = @{ Version = $Version; Quand = Get-Date; Nombre = $n }
}

# ---------------------------------------------------------------------------
# Un jeu en cours ? (rien ne se met à jour tout seul pendant une partie) Rend la raison, ou '' :
#   - une fenêtre en plein écran sur n'importe quel écran (même pas devant : un jeu sur l'autre écran) ;
#   - une manette utilisée il y a moins de 5 minutes (le clavier et la souris ne bougent pas quand on joue à la manette) ;
#   - un jeu ouvert, même dans une fenêtre : un programme lancé depuis un dossier de jeux des lanceurs connus, ou un
#     des jeux ajoutés à la main dans la bibliothèque de Nevermind (ses réglages, s'il est installé).
# ---------------------------------------------------------------------------
$DossiersJeux = @('\steamapps\common\', '\Epic Games\', '\EA Games\', '\Riot Games\', '\Ubisoft Game Launcher\games\', '\GOG Galaxy\Games\', '\XboxGames\', '\Rockstar Games\')
# (dans ces dossiers, les lanceurs et services qui restent ouverts en fond ne sont pas des jeux)
$DossiersPasJeux = @('\Epic Games\Launcher\', '\Epic Games\Epic Online Services\', '\Riot Games\Riot Client\', '\Rockstar Games\Launcher\', '\Rockstar Games\Social Club\', '\steamapps\common\Steamworks Shared\', '\steamapps\common\wallpaper_engine\')

# Les jeux ajoutés à la main dans Nevermind (réglage « CustomGames » de son parametres.json : nom et programme)
function Get-JeuxNevermind {
    $a = Get-Appli 'nevermind'
    if (-not $a) { return @() }
    foreach ($d in @((Get-DossierDonnees $a), $a.Donnees) | Where-Object { $_ } | Select-Object -Unique) {
        $f = Join-Path $d 'parametres.json'
        try {
            $i = New-Object IO.FileInfo $f
            if (-not $i.Exists -or $i.Length -gt 4MB) { continue }
            if ($script:JeuxNevermindCle -ne "$f|$($i.LastWriteTimeUtc.Ticks)") {
                $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
                $script:JeuxNevermind = @(@($j.CustomGames) | Where-Object { $_ -and $_.Exe -is [string] -and $_.Exe -match '^[A-Za-z]:\\.+\.exe$' } | ForEach-Object { [string]$_.Exe })
                $script:JeuxNevermindCle = "$f|$($i.LastWriteTimeUtc.Ticks)"
            }
            return $script:JeuxNevermind
        } catch { $script:JeuxNevermindCle = ''; return @() }
    }
    @()
}

# Le nom d'un programme en mots lisibles : sa description (« Battlefield 6 »), sinon son nom de produit, sinon le nom de
# son fichier sans « .exe »
function Get-NomProgramme([string]$Chemin) {
    try {
        $i = [Diagnostics.FileVersionInfo]::GetVersionInfo($Chemin)
        foreach ($n in $i.FileDescription, $i.ProductName) { $n = ([string]$n).Trim(); if ($n -and $n.Length -le 40) { return $n } }
    } catch {}
    [IO.Path]::GetFileNameWithoutExtension($Chemin)
}

function Get-JeuEnCours {
    try { if ([MSActivite]::PleinEcranQuelquePart()) { return 'une fenêtre en plein écran (jeu ou vidéo)' } } catch {}
    try { if ([MSActivite]::SecondesManette() -lt 300) { return 'une manette utilisée il y a moins de 5 minutes' } } catch {}
    try {
        $j = @([MSProcessus]::JeuxOuverts([string[]]$DossiersJeux, [string[]]$DossiersPasJeux, [string[]]@(Get-JeuxNevermind)))
        if ($j.Count) { return "un jeu ouvert ($(Get-NomProgramme $j[0]))" }
    } catch {}
    ''
}
# Ce que la console met entre parenthèses après « après ta partie » : le jeu, ou ce qui fait croire à une partie
function Get-NomRaisonJeu([string]$Raison) {
    if ($Raison -match '^un jeu ouvert \((.+)\)$') { return $Matches[1] }
    if ($Raison -match 'plein écran') { return 'une fenêtre en plein écran' }
    if ($Raison -match 'manette') { return 'manette utilisée' }
    $Raison
}

# Depuis combien de secondes personne ne touche au clavier ni à la souris (à part : les tests le remplacent)
function Get-SecondesInactif { [MSActivite]::SecondesInactif() }

function Invoke-MajAuto {
    if ($EnTest -and -not $env:MINDSET_MAJAUTO_TEST) { return }
    if (-not (Test-MajAutoActive) -or -not (Test-VerifVersionsActive) -or $MindsetAdmin -or -not (Test-TacheInstallation)) { return }
    try { [MSActivite]::ReleverManette() } catch {}   # (toutes les 2 secondes : une manette qui sert se voit)
    if (((Get-Date) - $script:MajAutoDerniere).TotalSeconds -lt 30) { return }
    $script:MajAutoDerniere = Get-Date
    if ($script:Occupe.Count -or $script:AttentesAdmin.Count -or $script:MajAuto.Count) { return }
    # Pendant une partie : rien (ni les applis, ouvertes ou non, ni Mindset) ; on réessaie 30 secondes plus tard
    $jeu = Get-JeuEnCours
    $script:MajAutoJeu = [string]$jeu
    if ($jeu) {
        if ($script:MajAutoJeuNote -ne $jeu) { Write-Log "Mises à jour automatiques en attente : $jeu"; $script:MajAutoJeuNote = $jeu }
        return
    }
    $script:MajAutoJeuNote = $null
    try { $inactif = Get-SecondesInactif } catch { return }
    $alEcran = $Window.IsVisible -and $Window.WindowState -ne 'Minimized'
    $attentes = @{}
    foreach ($a in $Applis) {
        $e = Get-EtatCarte $a
        if (-not $e.MajDispo -or $e.Occupe) { continue }
        $v = [string]$e.Pub.Version
        if (Test-MajAutoRecente $a.Id $v) { continue }
        if ($e.Ouverte) {
            if ($inactif -lt 300) { $attentes[$a.Id] = 'utilise'; continue }                           # on s'en sert peut-être
            if ($script:PageCourante -eq $a.Id -and $alEcran) { $attentes[$a.Id] = 'page'; continue }   # à l'écran dans Mindset
        }
        $script:MajAutoAttentes = $attentes
        Add-MajAutoEssai $a.Id $v
        $script:MajAuto[$a.Id] = $v
        Write-Log "Mise à jour automatique : $($a.Nom) $v$(if ($e.Ouverte) { ' (elle tournait, relancée cachée)' })"
        Start-InstallAppli $a
        return
    }
    # Mindset lui-même : caché (près de l'horloge, ou réduit), ou à l'écran quand personne ne touche au PC depuis
    # 5 minutes (comme une appli ouverte : on ne coupe jamais quelqu'un qui s'en sert). Il revient comme il était.
    # (pas pendant qu'une version plus récente se télécharge : elle remplacera celle qui est prête)
    $m = $script:MajMindset
    $attendre = $m -and $alEcran -and $inactif -lt 300
    if ($attendre) { $attentes['mindset'] = 'veille' }
    $script:MajAutoAttentes = $attentes
    if ($m -and -not $attendre -and -not $script:MajMindsetEnCours -and -not (Test-MajAutoRecente 'mindset' ([string]$m.Version))) {
        Add-MajAutoEssai 'mindset' ([string]$m.Version)
        Write-Log "Mise à jour automatique : Mindset $($m.Version)$(if ($alEcran) { ' (à l''écran, personne au clavier depuis 5 minutes)' })"
        Start-MajMindset -Auto -Cache:(-not $alEcran)
    }
}

# Fin d'une mise à jour automatique (appelé par Stop-Operation) : la notification, ou la bulle de la console
function Complete-MajAuto($Appli, [string]$Message) {
    $v = $script:MajAuto[$Appli.Id]; $script:MajAuto.Remove($Appli.Id)
    if ($Message -notmatch 'est installé') { Set-EchecMajAuto $Appli.Id $Appli.Nom ([string]$v) $Message; return }
    $script:MajAutoEchecs.Remove($Appli.Id)
    $titre = "$($Appli.Nom) est passé en $v"
    $notes = [string]$script:Publications[$Appli.Id].Notes
    $resume = (($notes -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -replace '^[-*#\s]+', '').Trim()
    if ($resume.Length -gt 180) { $resume = $resume.Substring(0, 177) + '...' }
    Show-BulleMajAuto $titre $resume
}

# Une mise à jour automatique ratée (d'une appli, ou de Mindset lui-même) : notée au journal, gardée pour la console
# (Get-EtatMajConsole : la raison et « Réessayer »), et dite tout de suite (bulle de la console, ou notification)
function Set-EchecMajAuto([string]$Id, [string]$Nom, [string]$Version, [string]$Message) {
    Write-Log "Mise à jour automatique de $Nom $Version ratée : $Message"
    $raison = Get-RaisonEchecMaj $Nom $Message
    $script:MajAutoEchecs[$Id] = @{ Version = $Version; Raison = $raison }
    $reessai = Get-MajAutoReessai $Id $Version
    $suite = if ($reessai -ge 0) { "Mindset réessaiera tout seul dans $reessai minutes, ou clique sur Réessayer." } else { 'Clique sur Réessayer dans Mindset.' }
    Show-BulleMajAuto "La mise à jour $(Format-DeNom $Nom) n'a pas pu se faire" "$raison $suite"
}
# « de Mindcare », « d'Evermind »
function Format-DeNom([string]$Nom) { if ($Nom -match '^[aeiouyéèêh]') { "d'$Nom" } else { "de $Nom" } }
# Pourquoi une mise à jour a raté, en mots simples (le message technique reste dans le journal)
function Get-RaisonEchecMaj([string]$Nom, [string]$Message) {
    $m = ([string]$Message -replace '^\s*Échec\s*:\s*', '').Trim()
    if ($m -match 'encore ouvert|fichiers sont utilisés|being used|utilisé par un autre') { return "$Nom était encore ouvert et n'a pas pu être fermé." }
    if ($m -match 'signature') { return "Le fichier téléchargé n'a pas passé la vérification de sécurité : rien n'a été changé." }
    if ($m -match 'ne répond pas') { return "L'outil d'installation de Mindset n'a pas répondu." }
    if ($m -match 'connexion|réseau|Internet|délai|timed? ?out|résoudre|remote|distant|\b(403|404|429|500|502|503)\b') { return 'Internet a coupé pendant le téléchargement.' }
    if ($m -match 'espace disque|disque plein|not enough space|place sur le disque') { return "Il n'y a plus assez de place sur le disque." }
    if (-not $m) { return 'Une erreur inconnue l''a arrêtée.' }
    if ($m.Length -gt 140) { $m = $m.Substring(0, 137) + '...' }
    if ($m -notmatch '[.!?]$') { $m += '.' }
    $m
}

function Show-BulleMajAuto([string]$Titre, [string]$Texte) {
    Write-Log "Mise à jour automatique : $Titre"
    if ($Window.IsVisible -and $Window.WindowState -ne 'Minimized' -and $script:Console.Pret) {
        Invoke-ScriptConsole "window.mindset.message($(ConvertTo-Json -InputObject $Titre -Compress))"
    } elseif ($script:IconeHorloge) {
        try { Show-BulleMindset 6000 $Titre $(if ($Texte) { $Texte } else { 'Mise à jour faite toute seule.' }) ([System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }
}

# ---------------------------------------------------------------------------
# L'historique des mises à jour (mises-a-jour.json, dans les données de Mindset) : les 20 dernières, de Mindset et de ses
# applis, la plus récente d'abord, avec leur heure, automatique ou faite par l'utilisateur, et leurs nouveautés (le texte
# de la version, pour le bouton « Nouveautés » de la console). La dernière reste sur la carte de la console pendant
# $DureeDerniereMaj heures (Get-DerniereMaj) ; toutes dans Paramètres > Mises à jour.
# Écrit à côté puis remplacé d'un coup : jamais un fichier à moitié écrit. Un fichier abîmé est mis de côté (.abime) et
# l'historique repart de zéro ; une entrée qui n'a pas la forme attendue est ignorée.
# Mindset lui-même se ferme pour se mettre à jour : sa mise à jour est notée « attendue » avant (Set-MajMindsetAttendue),
# puis ajoutée au redémarrage si c'est bien cette version qui tourne (Resolve-MajMindsetAttendue).
# ---------------------------------------------------------------------------
$FichierHistoriqueMaj = Join-Path $DataDir 'mises-a-jour.json'
$HistoriqueMajMax = 20
$DureeDerniereMaj = 12
$script:HistoriqueMaj = $null

# Une entrée relue ou ajoutée : seulement des valeurs attendues ($null sinon)
function ConvertTo-EntreeMaj($X) {
    if (-not $X -or [string]$X.id -notmatch '^[a-z0-9-]{1,30}$' -or [string]$X.version -notmatch '^\d+(\.\d+){1,3}$') { return $null }
    $quand = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$X.quand, 's', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$quand)) { return $null }
    $nom = [string]$X.nom; if ($nom.Length -gt 30) { $nom = $nom.Substring(0, 30) }
    $notes = [string]$X.notes; if ($notes.Length -gt 2000) { $notes = $notes.Substring(0, 1997) + '...' }
    [ordered]@{ id = [string]$X.id; nom = $nom; version = [string]$X.version; quand = $quand.ToString('s'); auto = [bool]$X.auto; notes = $notes }
}

function Read-HistoriqueMaj {
    if ($null -ne $script:HistoriqueMaj) { return $script:HistoriqueMaj }
    $h = @{ Liste = @(); Attendue = $null }
    # (abîmé : mis de côté et repris de sa copie, voir Read-JsonSur ; pris par un autre programme : relu la prochaine fois,
    # et rien n'est écrit d'ici là, pour ne pas remplacer l'historique par une liste vide)
    try { $j = Read-JsonSur $FichierHistoriqueMaj }
    catch { Write-Log "Historique des mises à jour : $($_.Exception.Message)"; $h.Illisible = $true; return $h }
    if ($null -ne $j) {
        $h.Liste = @(@($j.historique) | ForEach-Object { ConvertTo-EntreeMaj $_ } | Where-Object { $_ } | Select-Object -First $HistoriqueMajMax)
        if ($j.mindsetAttendu) { $h.Attendue = ConvertTo-EntreeMaj $j.mindsetAttendu }
    }
    $script:HistoriqueMaj = $h
    $h
}

function Save-HistoriqueMaj {
    $h = Read-HistoriqueMaj
    if ($EnTest -and -not $env:MINDSET_DONNEES) { return }   # (test sans dossier à part : rien n'est écrit)
    if ($h.Illisible) { Write-Log 'Historique des mises à jour non enregistré : il n''a pas pu être lu'; return }
    $texte = ConvertTo-Json -InputObject ([ordered]@{ historique = @($h.Liste); mindsetAttendu = $h.Attendue }) -Depth 4
    try { Save-JsonSur $FichierHistoriqueMaj $texte }
    catch { Write-Log "Historique des mises à jour non enregistré : $($_.Exception.Message)" }
}

function Add-HistoriqueMaj([string]$Id, [string]$Nom, [string]$Version, [bool]$Auto, [string]$Notes) {
    $e = ConvertTo-EntreeMaj ([pscustomobject]@{ id = $Id; nom = $Nom; version = $Version; quand = (Get-Date).ToString('s'); auto = $Auto; notes = $Notes })
    if (-not $e) { Write-Log "Historique des mises à jour : $Nom $Version pas noté (valeurs inattendues)"; return }
    $h = Read-HistoriqueMaj
    $h.Liste = @(@($e) + @($h.Liste) | Select-Object -First $HistoriqueMajMax)
    Save-HistoriqueMaj
    Write-Log "Historique des mises à jour : $Nom $Version ($(if ($Auto) { 'automatique' } else { 'faite par l''utilisateur' }))"
}

function Set-MajMindsetAttendue([string]$Version, [bool]$Auto, [string]$Notes) {
    $h = Read-HistoriqueMaj
    $h.Attendue = ConvertTo-EntreeMaj ([pscustomobject]@{ id = 'mindset'; nom = 'Mindset'; version = $Version; quand = (Get-Date).ToString('s'); auto = $Auto; notes = $Notes })
    Save-HistoriqueMaj
}

# Au démarrage : la mise à jour de Mindset attendue est faite si c'est cette version qui tourne ; sinon elle est oubliée
function Resolve-MajMindsetAttendue {
    $h = Read-HistoriqueMaj
    $a = $h.Attendue
    if (-not $a) { return }
    $h.Attendue = $null
    if ($a.version -eq $AppVersion) { Add-HistoriqueMaj 'mindset' 'Mindset' $a.version $a.auto $a.notes } else { Save-HistoriqueMaj }
}

# La dernière mise à jour, si elle date de moins de $DureeDerniereMaj heures ($null sinon)
function Get-DerniereMaj {
    $e = @((Read-HistoriqueMaj).Liste) | Select-Object -First 1
    if (-not $e) { return $null }
    $age = ((Get-Date) - [datetime]::ParseExact($e.quand, 's', [Globalization.CultureInfo]::InvariantCulture)).TotalHours
    if ($age -lt 0 -or $age -ge $DureeDerniereMaj) { return $null }
    $e
}

# « à 00 h 16 », « hier à 21 h 05 », « le 18 octobre à 09 h 30 » (-Long : « aujourd'hui à 00 h 16 »)
function Format-QuandMaj([string]$Quand, [switch]$Long) {
    $q = [datetime]::ParseExact($Quand, 's', [Globalization.CultureInfo]::InvariantCulture)
    $h = $q.ToString("HH' h 'mm", [Globalization.CultureInfo]::InvariantCulture)
    $jours = ((Get-Date).Date - $q.Date).TotalDays
    if ($jours -eq 0) { return "$(if ($Long) { 'aujourd''hui ' })à $h" }
    if ($jours -eq 1) { return "hier à $h" }
    "le $($q.ToString('d MMMM', [Globalization.CultureInfo]::GetCultureInfo('fr-FR'))) à $h"
}

# Le nom et la couleur d'une entrée : ceux de l'appli de apps.json (ou de Mindset), sinon le nom noté
function Get-AppliMaj([string]$Id, [string]$Nom) {
    if ($Id -eq 'mindset') { return @{ Id = 'mindset'; Nom = 'Mindset'; Couleur = '#ECEAF7' } }
    $a = Get-Appli $Id
    if ($a) { @{ Id = $a.Id; Nom = $a.Nom; Couleur = $a.Couleur } } else { @{ Id = $Id; Nom = $Nom; Couleur = '#A9A3C9' } }
}
