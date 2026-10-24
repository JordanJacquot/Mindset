# Mindset : l'icône près de l'horloge (zone de notification), réduire et fermer.
# Comme Nevermind et Evermind :
#   réduire       Mindset se cache près de l'horloge (réglage « ReduireHorloge », oui par défaut)
#   croix rouge   « Réduire près de l'horloge » ou « Quitter », avec « Ne plus me demander » (réglage « Fermeture » :
#                 demander, reduire ou quitter ; modifiable dans Paramètres)
#   l'icône       un clic rouvre Mindset ; clic droit : ouvrir Mindset, ouvrir une appli installée, quitter
# Chargé par Mindset.ps1 après parametres.ps1.

Add-Type -AssemblyName System.Windows.Forms

function Show-Fenetre {
    # Rouvert depuis l'horloge après un moment : les nouvelles versions sont cherchées tout de suite (accueil.ps1), si
    # « Chercher les nouvelles versions » est activé (sinon Invoke-Actualiser ne fait rien)
    if (-not $Window.IsVisible -and ((Get-Date) - $script:DernieresPublications).TotalMinutes -ge 15 -and (Get-Command Invoke-Actualiser -ErrorAction SilentlyContinue)) { Invoke-Actualiser }
    $Window.ShowInTaskbar = $true
    $Window.Show()
    if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
    [void]$Window.Activate()
}

function Hide-Fenetre {
    $Window.Hide()
    # La première fois, une bulle explique où est passé Mindset
    if (-not (Get-Setting 'BulleHorlogeVue' $false) -and $script:IconeHorloge) {
        Show-BulleMindset 4000 'Mindset reste ici' 'Clique sur l''icône pour le rouvrir. Clic droit pour tes applis ou pour quitter.' 'None'
        Set-Setting 'BulleHorlogeVue' $true
    }
}

# ---------------------------------------------------------------------------
# L'icône et son menu
# ---------------------------------------------------------------------------
function Initialize-IconeHorloge {
    if ($EnTest) { return }
    $n = New-Object System.Windows.Forms.NotifyIcon
    try { $n.Icon = New-Object System.Drawing.Icon (New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($IconPath))) } catch { $n.Icon = [System.Drawing.SystemIcons]::Application }
    $n.Text = 'Mindset'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Add_Opening({ Update-MenuHorloge })
    $n.ContextMenuStrip = $menu
    $n.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Fenetre } })
    $n.Add_BalloonTipClicked({ Open-BulleAppli })
    $n.Add_BalloonTipClosed({ $script:BulleAppli = $null })
    $n.Visible = $true
    $script:IconeHorloge = $n
}

# Le menu est refait à chaque ouverture : une appli installée entre-temps y apparaît
function Update-MenuHorloge {
    $m = $script:IconeHorloge.ContextMenuStrip
    $m.Items.Clear()
    $o = $m.Items.Add('Ouvrir Mindset'); $o.Font = New-Object System.Drawing.Font($o.Font, [System.Drawing.FontStyle]::Bold)
    $o.Add_Click({ Show-Fenetre })
    $installees = @($Applis | Where-Object { Get-Installation $_ })
    if ($installees.Count) {
        [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        foreach ($a in $installees) {
            $i = $m.Items.Add("Ouvrir $($a.Nom)"); $i.Tag = $a.Id
            $i.Add_Click({ param($s) Show-Fenetre; Open-AppliConsole $s.Tag })   # (lancée et affichée dans Mindset ; console.ps1)
        }
    }
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $q = $m.Items.Add('Tout quitter (Mindset et ses applis)')
    $q.Add_Click({ Exit-Mindset -AvecApplis })
}

# ---------------------------------------------------------------------------
# Réduire : caché près de l'horloge
# ---------------------------------------------------------------------------
$Window.Add_StateChanged({
    if ($Window.WindowState -eq 'Minimized' -and $script:IconeHorloge -and (Get-Setting 'ReduireHorloge' $true)) {
        $Window.WindowState = 'Normal'   # (rouverte telle qu'elle était, pas réduite)
        Hide-Fenetre
    }
})

# ---------------------------------------------------------------------------
# La croix rouge : réduire ou quitter
# ---------------------------------------------------------------------------
$Window.Add_Closing({
    param($s, $e)
    if ($script:QuitterVraiment -or $EnTest -or -not $script:IconeHorloge) { return }
    $e.Cancel = $true
    # Juste après (pas pendant la fermeture annulée : Windows refuse alors d'afficher, cacher ou refermer la fenêtre)
    [void]$Window.Dispatcher.BeginInvoke([action]{
        switch ([string](Get-Setting 'Fermeture' 'demander')) {
            'reduire' { Hide-Fenetre }
            'quitter' { Exit-Mindset -AvecApplis }
            default {
                if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
                $ui.FermetureSouvenir.IsChecked = $false
                $ui.Fermeture.Visibility = 'Visible'
                [void]$ui.BtnFermetureReduire.Focus()
            }
        }
    })
})

function Close-ChoixFermeture([string]$Choix) {
    $ui.Fermeture.Visibility = 'Collapsed'
    if ($ui.FermetureSouvenir.IsChecked) { Set-Setting 'Fermeture' $Choix; Update-ReglageFermeture }
    if ($Choix -eq 'quitter') { Exit-Mindset -AvecApplis } else { Hide-Fenetre }
}
$ui.BtnFermetureReduire.Add_Click({ Close-ChoixFermeture 'reduire' })
$ui.BtnFermetureQuitter.Add_Click({ Close-ChoixFermeture 'quitter' })
$ui.BtnFermetureAnnuler.Add_Click({ $ui.Fermeture.Visibility = 'Collapsed' })

# Paramètres : que fait la croix rouge, et réduire
function Update-ReglageFermeture {
    $c = [string](Get-Setting 'Fermeture' 'demander')
    foreach ($rb in $ui.ChoixFermeture.Children) { $rb.IsChecked = ($rb.Tag -eq $c) }
}
foreach ($o in @(@('demander', 'Me demander à chaque fois'), @('reduire', 'Réduire près de l''horloge'), @('quitter', 'Tout quitter (Mindset et ses applis)'))) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.GroupName = 'Fermeture'; $rb.Tag = $o[0]; $rb.Content = $o[1]; $rb.Margin = '0,2,0,2'; $rb.Foreground = Get-Brush '#ECEAF7'
    $rb.Add_Checked({ param($s) Set-Setting 'Fermeture' $s.Tag })
    [void]$ui.ChoixFermeture.Children.Add($rb)
}
Update-ReglageFermeture
$ui.ReduireHorloge.IsChecked = [bool](Get-Setting 'ReduireHorloge' $true)
$ui.ReduireHorloge.Add_Click({ Set-Setting 'ReduireHorloge' ([bool]$ui.ReduireHorloge.IsChecked) })

Initialize-IconeHorloge

# ---------------------------------------------------------------------------
# Notifications des applis : elles n'ont plus d'icône près de l'horloge, tout passe par celle de Mindset.
# Nevermind écrit notification.demande dans son dossier de données ({ titre, texte, id }) ; Mindset la montre en bulle.
# Un clic sur la bulle ouvre l'appli ici et lui renvoie son numéro (« notif:<id> » dans son fichier d'affichage) pour
# qu'elle fasse ce qu'elle annonçait. Le titre et le texte sont seulement affichés.
# ---------------------------------------------------------------------------
$script:BulleAppli = $null
function Watch-NotificationsApplis {
    foreach ($a in @($Applis | Where-Object { $_.AfficherFichier })) {
        $f = Join-Path (Get-DossierDonnees $a) 'notification.demande'
        if (-not [IO.File]::Exists($f)) { continue }
        $j = $null
        try { if ((New-Object IO.FileInfo $f).Length -lt 8KB) { $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json } } catch {}
        try { [IO.File]::Delete($f) } catch {}
        if (-not $j -or -not $script:IconeHorloge) { continue }
        $titre = [string]$j.titre; $texte = [string]$j.texte; $id = [string]$j.id
        if (-not $titre) { $titre = $a.Nom }
        if ($titre.Length -gt 63) { $titre = $titre.Substring(0, 62) + '…' }
        if ($texte.Length -gt 250) { $texte = $texte.Substring(0, 249) + '…' }
        if ($id -notmatch '^[0-9a-f]{12}$') { $id = '' }
        $script:BulleAppli = @{ Appli = $a.Id; Id = $id }
        $script:IconeHorloge.ShowBalloonTip(8000, $titre, $(if ($texte) { $texte } else { ' ' }), [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

# Une bulle de Mindset lui-même : elle n'est plus celle d'une appli. Sans cela, si Windows n'a pas signalé la fermeture
# de la bulle précédente, un clic sur celle-ci ouvrirait l'appli et lui renverrait une vieille notification.
function Show-BulleMindset([int]$Duree, [string]$Titre, [string]$Texte, $Icone) {
    $script:BulleAppli = $null
    if ($script:IconeHorloge) { $script:IconeHorloge.ShowBalloonTip($Duree, $Titre, $Texte, $Icone) }
}

function Open-BulleAppli {
    $b = $script:BulleAppli; $script:BulleAppli = $null
    Show-Fenetre
    if (-not $b) { return }
    $a = Get-Appli $b.Appli
    if (-not $a) { return }
    Open-AppliConsole $a.Id
    if ($b.Id) {
        try { [IO.File]::WriteAllText((Join-Path (Get-DossierDonnees $a) $a.AfficherFichier), "notif:$($b.Id)", (New-Object Text.UTF8Encoding $false)) } catch { Write-Log "Notification de $($a.Nom) : $_" }
    }
}

if (-not $EnTest) {
    $script:NotifTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:NotifTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:NotifTimer.Add_Tick({ try { Watch-NotificationsApplis } catch { Write-Log "Notifications des applis : $_" } })
    $script:NotifTimer.Start()
}

if ($EnTest -and $env:MINDSET_FERMETURE) { $ui.Fermeture.Visibility = 'Visible' }   # (capture de test de la question)
