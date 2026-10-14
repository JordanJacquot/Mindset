# Mindset : l'icône près de l'horloge (zone de notification), réduire et fermer.
# Comme Nevermind et Evermind :
#   réduire       Mindset se cache près de l'horloge (réglage « ReduireHorloge », oui par défaut)
#   croix rouge   « Réduire près de l'horloge » ou « Quitter », avec « Ne plus me demander » (réglage « Fermeture » :
#                 demander, reduire ou quitter ; modifiable dans Paramètres)
#   l'icône       un clic rouvre Mindset ; clic droit : ouvrir Mindset, ouvrir une appli installée, quitter
# Chargé par Mindset.ps1 après parametres.ps1.

Add-Type -AssemblyName System.Windows.Forms

function Show-Fenetre {
    $Window.ShowInTaskbar = $true
    $Window.Show()
    if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
    [void]$Window.Activate()
}

function Hide-Fenetre {
    $Window.Hide()
    # La première fois, une bulle explique où est passé Mindset
    if (-not (Get-Setting 'BulleHorlogeVue' $false) -and $script:IconeHorloge) {
        $script:IconeHorloge.ShowBalloonTip(4000, 'Mindset reste ici', 'Clique sur l''icône pour le rouvrir. Clic droit pour Nevermind, Evermind ou quitter.', 'None')
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
            $i.Add_Click({ param($s) Open-Appli (Get-Appli $s.Tag) })
        }
    }
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $q = $m.Items.Add('Tout quitter (Mindset et ses applis)')
    $q.Add_Click({ Exit-Mindset -Applis })
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
            'quitter' { Exit-Mindset -Applis }
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
    if ($Choix -eq 'quitter') { Exit-Mindset -Applis } else { Hide-Fenetre }
}
$ui.BtnFermetureReduire.Add_Click({ Close-ChoixFermeture 'reduire' })
$ui.BtnFermetureQuitter.Add_Click({ Close-ChoixFermeture 'quitter' })
$ui.BtnFermetureAnnuler.Add_Click({ $ui.Fermeture.Visibility = 'Collapsed' })

# Paramètres : que fait la croix rouge, et réduire
function Update-ReglageFermeture {
    $c = [string](Get-Setting 'Fermeture' 'demander')
    foreach ($rb in $ui.ChoixFermeture.Children) { $rb.IsChecked = ($rb.Tag -eq $c) }
}
foreach ($o in @(@('demander', 'Me demander à chaque fois'), @('reduire', 'Réduire près de l''horloge'), @('quitter', 'Tout quitter (Mindset, Nevermind et Evermind)'))) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.GroupName = 'Fermeture'; $rb.Tag = $o[0]; $rb.Content = $o[1]; $rb.Margin = '0,2,0,2'; $rb.Foreground = Get-Brush '#ECEAF7'
    $rb.Add_Checked({ param($s) Set-Setting 'Fermeture' $s.Tag })
    [void]$ui.ChoixFermeture.Children.Add($rb)
}
Update-ReglageFermeture
$ui.ReduireHorloge.IsChecked = [bool](Get-Setting 'ReduireHorloge' $true)
$ui.ReduireHorloge.Add_Click({ Set-Setting 'ReduireHorloge' ([bool]$ui.ReduireHorloge.IsChecked) })

Initialize-IconeHorloge

if ($EnTest -and $env:MINDSET_FERMETURE) { $ui.Fermeture.Visibility = 'Visible' }   # (capture de test de la question)
