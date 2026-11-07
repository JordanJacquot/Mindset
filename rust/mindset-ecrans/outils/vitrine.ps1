# Captures des écrans (bloc « écrans ») : les données d'essai de la VERSION POWERSHELL, chargées dans un Mindset de
# test (MINDSET_TEST_SCRIPT, après ses modules). Les mêmes données sont données au bloc Rust pour les captures
# « après » (tests\vitrine.rs) : trois applis (Nevermind installé et ouvert avec son résumé, Evermind installé avec une
# nouvelle version et ses rendez-vous, Mindcare pas installé), l'heure écrite dans $env:MINDSET_VITRINE_DOSSIER.
#
# Rien ne touche le PC : les fonctions qui lisent les installations, les applis ouvertes et les copies trouvées sont
# remplacées ici ; les résumés (etat.json) sont écrits dans le dossier de données d'essai (MINDSET_DONNEES).
# $env:MINDSET_VITRINE : la scène (accueil, confirmation, bienvenue, bandeaux...).

$vitrine = [string]$env:MINDSET_VITRINE
$maintenant = [datetime]::ParseExact([IO.File]::ReadAllText((Join-Path $env:MINDSET_VITRINE_DOSSIER 'maintenant.txt')).Trim(), 's', [Globalization.CultureInfo]::InvariantCulture)

$script:VitrineInst = @{
    nevermind = @{ Dossier = (Join-Path $RacineProgrammes 'Nevermind'); Gere = $true; Version = '2.0.1' }
    evermind  = @{ Dossier = (Join-Path $RacineProgrammes 'Evermind'); Gere = $true; Version = '1.4.0' }
}
function Get-Installation($Appli) { $script:VitrineInst[$Appli.Id] }
function Test-AppliOuverte($Appli) { $Appli.Id -eq 'nevermind' }
function Find-InstallationExistante($Appli) { $null }
function Get-DossierDonnees($Appli) { Join-Path $SuiteDir $Appli.Nom }
# (l'ancien dossier de données des applis : un dossier d'essai qui n'existe pas, jamais celui du vrai PC)
foreach ($a in $Applis) { $a.Donnees = Join-Path $SuiteDir "ancien-$($a.Id)" }
$script:Publications = @{ evermind = @{ Version = '1.5.0' } }

# Les résumés des applis, comme elles les écrivent
$u8 = New-Object Text.UTF8Encoding $false
$dn = Join-Path $SuiteDir 'Nevermind'; New-Item -ItemType Directory -Force -Path $dn | Out-Null
[IO.File]::WriteAllText((Join-Path $dn 'etat.json'), '{"Score":82,"Protection":64,"AFaire":"Mettre à jour le pilote graphique","Urgent":false,"NbAFaire":1}', $u8)
$de = Join-Path $SuiteDir 'Evermind'; New-Item -ItemType Directory -Force -Path $de | Out-Null
$s = { param($d) $d.ToString('s', [Globalization.CultureInfo]::InvariantCulture) }
$rdv = @(
    [ordered]@{ Id = ('a' * 31) + '1'; Titre = 'Appeler maman'; Quand = (& $s $maintenant.Date.AddHours($maintenant.Hour + 1).AddMinutes(15)); Journee = $false }
    [ordered]@{ Id = ('a' * 31) + '2'; Titre = 'Dentiste'; Quand = (& $s $maintenant.Date.AddDays(1).AddHours(9)); Journee = $false }
    [ordered]@{ Id = ('a' * 31) + '3'; Titre = 'Anniversaire de Léa'; Quand = (& $s $maintenant.Date.AddDays(3)); Journee = $true }
)
[IO.File]::WriteAllText((Join-Path $de 'etat.json'), (ConvertTo-Json -InputObject @{ Prochains = $rdv } -Depth 4 -Compress), $u8)
Set-Setting 'Demarrage' @('nevermind')

$script:CartesCle = @{}
$script:EtatsApplis = @{}
Update-Trouvees
Update-Cartes

switch ($vitrine) {
    'confirmation' { Confirm-Desinstallation (Get-Appli 'evermind') }
    'bandeaux' {
        $ui.MajTitre.Text = 'Mindset 3.0.1 est prêt'
        $ui.MajTexte.Text = 'La nouvelle version est téléchargée et sa signature vérifiée. Mindset va se fermer, se mettre à jour et se rouvrir tout seul.'
        $ui.BtnMajMindset.Visibility = 'Visible'; $ui.BtnMajFermer.Content = 'Plus tard'
        $ui.MajBandeau.Visibility = 'Visible'
    }
    'bienvenue' {
        # (les disques du vrai PC remplacés par deux disques d'essai)
        $ui.ChoixDisques.Children.Clear()
        foreach ($d in @(@{ Lettre = ''; Texte = 'C: (dans Program Files, comme les autres programmes)'; Libre = '120 Go libres' }, @{ Lettre = 'D'; Texte = 'D:\Mindset'; Libre = '900 Go libres' })) {
            $rb = New-Object System.Windows.Controls.RadioButton
            $rb.GroupName = 'Disque'; $rb.Tag = $d.Lettre; $rb.Margin = '0,2,0,2'; $rb.Foreground = Get-Brush '#ECEAF7'
            $rb.Content = "$($d.Texte)   ·   $($d.Libre)"
            if ($d.Lettre -eq '') { $rb.IsChecked = $true }
            [void]$ui.ChoixDisques.Children.Add($rb)
        }
    }
}
