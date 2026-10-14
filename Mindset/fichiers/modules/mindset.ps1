# Mindset : s'installer sur le PC, se lancer avec Windows, se désinstaller.
# Chargé par Mindset.ps1 après installations.ps1 (Invoke-Admin).
#
# Installé, Mindset est dans C:\Program Files\Mindset\Mindset, avec un raccourci « Mindset » sur le Bureau et
# dans le menu Démarrer, et se lance avec Windows (Mindset.exe -Demarrage : il démarre en arrière-plan les applis
# qui en ont besoin, comme les rappels d'Evermind, puis se ferme). Il est aussi dans « Applications installées ».

$DossierMindset = Join-Path $env:ProgramFiles 'Mindset\Mindset'
$RaccourcisMindset = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mindset.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Mindset.lnk'))
$CleRun = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Test-MindsetInstalle { (Split-Path $AppDir -Parent) -ieq $DossierMindset }

# Un dossier de travail (dépôt Git) : pas de proposition d'installation
function Test-MindsetDeveloppement { Test-Path -LiteralPath (Join-Path (Split-Path (Split-Path $AppDir -Parent) -Parent) '.git') }

function Install-Mindset {
    if ($script:InstallMindsetEnCours) { return }
    $script:InstallMindsetEnCours = $true
    $ui.BienvenueTexte.Text = 'Installation (accepte la demande de Windows)...'
    Invoke-Admin 'mindset' @{ Source = (Split-Path $AppDir -Parent); Version = $AppVersion } {
        param($Ok, $Message)
        $script:InstallMindsetEnCours = $false
        if (-not $Ok) { $ui.BienvenueTexte.Text = "Installation impossible : $Message"; return }
        $exe = Join-Path $DossierMindset 'Mindset.exe'
        $sh = New-Object -ComObject WScript.Shell
        foreach ($l in $RaccourcisMindset) {
            try { $s = $sh.CreateShortcut($l); $s.TargetPath = $exe; $s.WorkingDirectory = $DossierMindset; $s.IconLocation = "$exe,0"; $s.Description = 'Mindset : Nevermind et Evermind au même endroit'; $s.Save() }
            catch { Write-Log "Raccourci $l : $_" }
        }
        Set-ItemProperty -Path $CleRun -Name 'Mindset' -Value "`"$exe`" -Demarrage"
        Write-Log "Mindset $AppVersion installé dans $DossierMindset"
        # Le Mindset installé prend le relais ; celui-ci (dans le dossier téléchargé) se ferme
        $script:LancerApres = $exe
        $Window.Close()
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
            $t.Add_Tick({ $this.Stop(); $Window.Close() })
            $t.Start()
        } else { $Window.Close() }
        Write-Log 'Mindset désinstallé'
    }
}

# Mindset.exe -Demarrage : démarre en arrière-plan les applis choisies (Paramètres), puis se ferme.
# Nevermind n'en fait pas partie : il garde sa tâche planifiée, qui le lance en administrateur sans demande.
function Start-Demarrage {
    foreach ($a in $Applis) {
        if (-not $a.Admin -and (Get-DemarrageAppli $a.Id)) { $i = Get-Installation $a; if ($i -and $i.Gere) { Open-Appli $a -Demarrage } }
    }
}
