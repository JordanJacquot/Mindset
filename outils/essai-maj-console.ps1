# Mindset : essai des mises à jour visibles dans la console, dans un VRAI Mindset de test (outils\tester-mises-a-jour.ps1,
# partie 7). Chargé par Mindset.ps1 après ses modules, seulement en test (MINDSET_TEST et MINDSET_TEST_SCRIPT).
#
# Le code des mises à jour reste le vrai (Get-EtatMajConsole, Send-MajConsole, Invoke-MajAuto, Invoke-Actualiser,
# Update-Publications, l'historique, la page de la console) : seul ce qui toucherait au PC ou à Internet est remplacé par
# du faux. De fausses applis installées (aucune vraie appli n'est lue ni ouverte), de fausses versions publiées, un faux
# téléchargement (sa progression avance toute seule), un faux jeu, et aucune installation ni demande de Windows.
#
#   MINDSET_TEST_ETAPE   recherche, telechargement, installation, termine, notes, prete, attente, clic, majclic, coupee,
#                        mindset, mindsetprete, suite, parametres
#   MINDSET_TEST_TAILLE  la taille de la fenêtre (1000x640), MINDSET_TEST_DECOR (console.ps1) : jour, soir ou nuit
# Ce que la carte affiche est noté au journal (« Essai : carte = ... ») juste avant la capture : la preuve que la console
# a bien reçu l'état.

$script:Essai = @{ Etape = [string]$env:MINDSET_TEST_ETAPE; Debut = $null; Fait = @{} }
Write-Log "Essai des mises à jour dans la console : étape $($script:Essai.Etape)"
if ($env:MINDSET_TEST_TAILLE -match '^(\d{3,4})x(\d{3,4})$') { $Window.Width = [int]$Matches[1]; $Window.Height = [int]$Matches[2] }

# --- Les fausses applis : installées (gérées) dans le dossier de test, jamais lues sur le PC ---
$script:EssaiVersions = @{ nevermind = '1.0.121'; evermind = '0.14.2'; mindcare = '0.3.1' }
$EssaiNotes = "- Les rappels sonnent aussi quand le PC sort de veille`n- La dictée comprend mieux les heures (« à 7 h 30 »)`n- Un nouveau thème de couleurs pour l'agenda`n- Corrections : l'agenda s'ouvre plus vite"
function Get-Installation($Appli) {
    $v = $script:EssaiVersions[$Appli.Id]
    if ($v) { @{ Dossier = (Join-Path $DataDir "essai-programmes\$($Appli.Nom)"); Gere = $true; Version = $v } }
}
function Test-AppliOuverte($Appli) { $false }
function Get-EtatAppli($Appli) { $null }
function Find-InstallationExistante($Appli) { $null }
function Test-TacheInstallation { $true }
# Rien n'est jamais installé ni lancé en administrateur
function Invoke-Admin([string]$Action, [hashtable]$Parametres, [scriptblock]$Fin) { Write-Log "Essai : $Action refusé (rien n'est installé)"; & $Fin $false 'essai' }
function Start-MajMindset([switch]$Cache) { Write-Log 'Essai : Start-MajMindset (rien n''est installé)' }
function Get-JeuEnCours { if ($script:Essai.Etape -eq 'attente') { 'un jeu ouvert (essai)' } else { '' } }
$script:Publications = @{}
foreach ($a in $Applis) { $script:Publications[$a.Id] = @{ Version = $script:EssaiVersions[$a.Id]; Notes = '' } }
function Set-PublicationEssai([string]$Id, [string]$Version) { $script:Publications[$Id] = @{ Version = $Version; UrlZip = ''; UrlSig = ''; Notes = $EssaiNotes } }

# Le faux téléchargement : sa progression avance (5 % toutes les 150 ms) jusqu'à $Cible ; à 1, l'installation (sans %),
# puis, si $Finir, l'appli passe à sa nouvelle version (le vrai Complete-Installation n'est pas appelé : il installerait)
$script:EssaiCibles = @{ telechargement = 0.65; installation = 1.0; majclic = 0.4; suite = 0.3 }
function Start-InstallAppli($Appli, [string]$AncienDossier) {
    if ($script:Occupe[$Appli.Id]) { return }
    $cible = if ($script:Essai.Etape -eq 'suite' -and $Appli.Id -eq 'evermind') { 1.0 } else { [double]$script:EssaiCibles[$script:Essai.Etape] }
    if (-not $cible) { $cible = 1.0 }
    $finir = $script:Essai.Etape -eq 'suite' -and $Appli.Id -eq 'evermind'
    Write-Log "Essai : faux téléchargement de $($Appli.Nom) (jusqu'à $([int]($cible * 100)) %)"
    $script:Occupe[$Appli.Id] = 'Téléchargement...'
    $script:Progres[$Appli.Id] = [hashtable]::Synchronized(@{ Recu = 0; Total = 1000 })
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(150)
    $t.Tag = @{ Id = $Appli.Id; Cible = $cible; Finir = $finir; Install = 0 }
    $t.Add_Tick({
        param($s)
        $x = $s.Tag; $a = Get-Appli $x.Id; $pr = $script:Progres[$x.Id]
        if ($pr) {
            $pr.Recu = [math]::Min([int]($x.Cible * 1000), $pr.Recu + 50)
            if ($pr.Recu -lt 1000) { if ($pr.Recu -ge [int]($x.Cible * 1000)) { $s.Stop() }; return }
            $script:Progres.Remove($x.Id)   # (tout reçu : l'installation)
            $script:EnCours[$x.Id] = @{ Appli = $a; Version = [string]$script:Publications[$x.Id].Version }
            $script:Occupe[$x.Id] = 'Installation...'
            if (-not $x.Finir) { $s.Stop() }
            return
        }
        if (++$x.Install -lt 4) { return }
        $s.Stop()
        $v = [string]$script:EnCours[$x.Id].Version
        $script:EnCours.Remove($x.Id); $script:Occupe.Remove($x.Id)
        $script:EssaiVersions[$x.Id] = $v
        Add-HistoriqueMaj $x.Id $a.Nom $v ([bool]$script:MajAuto[$x.Id]) $EssaiNotes
        $script:MajAuto.Remove($x.Id)
        $script:MajAutoDerniere = [datetime]::MinValue   # (la suivante tout de suite, sans attendre 30 secondes)
        Write-Log "Essai : $($a.Nom) $v installé (faux)"
    })
    $t.Start()
}

# L'historique d'avant (écrit comme Mindset l'écrit : le vrai Read-HistoriqueMaj le relit)
function Write-HistoriqueEssai([object[]]$Entrees) {
    $o = [ordered]@{ historique = @($Entrees | ForEach-Object { [ordered]@{ id = $_[0]; nom = $_[1]; version = $_[2]; quand = (Get-Date).AddMinutes(-$_[3]).ToString('s'); auto = $_[4]; notes = $EssaiNotes } }); mindsetAttendu = $null }
    [IO.File]::WriteAllText($FichierHistoriqueMaj, (ConvertTo-Json -InputObject $o -Depth 4), (New-Object Text.UTF8Encoding $false))
    $script:HistoriqueMaj = $null
}
$histoAncien = @(@('nevermind', 'Nevermind', '1.0.121', 1500, $true), @('mindset', 'Mindset', '2.6.0', 1620, $false), @('mindcare', 'Mindcare', '0.3.1', 4400, $true))

# --- Les étapes ---
# Un Mindset comme chez l'utilisateur, sans les droits administrateur : sur GitHub, les tests tournent en administrateur,
# et un Mindset administrateur ne fait aucune mise à jour automatique (la carte restait « prête »)
$MindsetAdmin = $false
Set-Setting 'MajAuto' $true; Set-Setting 'VerifVersions' $true
switch ($script:Essai.Etape) {
    { $_ -in 'telechargement', 'installation', 'attente' } { Set-PublicationEssai 'evermind' '0.15.0' }
    { $_ -in 'termine', 'notes', 'parametres' } {
        $script:EssaiVersions.evermind = '0.15.0'; $script:Publications.evermind = @{ Version = '0.15.0'; Notes = $EssaiNotes }
        Write-HistoriqueEssai (@(, @('evermind', 'Evermind', '0.15.0', 47, $true)) + $histoAncien)
    }
    { $_ -in 'prete', 'clic', 'majclic' } { Set-Setting 'MajAuto' $false; Set-PublicationEssai 'evermind' '0.15.0' }
    'coupee' { Set-Setting 'VerifVersions' $false }
    'mindset' { $script:MajMindsetEnCours = $true; $script:ProgresMindset = [hashtable]::Synchronized(@{ Version = '2.7.0'; Recu = 420; Total = 1000 }) }
    'mindsetprete' { $script:MajMindset = @{ Version = '2.7.0'; Notes = $EssaiNotes } }
    'suite' { Set-PublicationEssai 'evermind' '0.15.0'; Set-PublicationEssai 'mindcare' '0.4.0'; Write-HistoriqueEssai $histoAncien }
}
Update-ReglagesMaj

# Une fois la console prête : le geste de l'étape (comme un clic de l'utilisateur), puis ce que la carte affiche, noté
# au journal juste avant la capture (MINDSET_CONSOLE_DELAI après « prête »)
$script:EssaiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EssaiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:EssaiTimer.Add_Tick({
    if (-not $script:Console.Pret) { return }
    if (-not $script:Essai.Debut) { $script:Essai.Debut = Get-Date }
    $t = ((Get-Date) - $script:Essai.Debut).TotalMilliseconds
    $e = $script:Essai.Etape; $f = $script:Essai.Fait
    if ($t -ge 1200 -and -not $f.Geste) {
        $f.Geste = $true
        switch ($e) {
            'recherche' {
                # La vraie recherche (Invoke-Actualiser -Clic, Update-Publications), mais GitHub ne répond jamais : la
                # question reste en cours
                $env:MINDSET_SANS_RESEAU = $null
                function script:Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) { }
                Invoke-ScriptConsole "document.querySelector('#ronds button[data-r=`"actualiser`"]').click()"
            }
            'notes' { Invoke-ScriptConsole "document.querySelector('#majLoin [data-maj=`"notes`"]').click()" }
            'clic' { Invoke-ScriptConsole "document.querySelector('#majLoin [data-maj=`"auto`"]').click()" }
            'majclic' { Invoke-ScriptConsole "document.querySelector('#majLoin [data-maj=`"maj`"]').click()" }
            'parametres' { Invoke-ScriptConsole "setTimeout(() => window.mindsetEssai.defiler(5000), 600)" }
        }
    }
    $delai = [int]$(if ($env:MINDSET_CONSOLE_DELAI) { $env:MINDSET_CONSOLE_DELAI } else { 3000 })
    if ($t -ge ($delai - 700) -and -not $f.Lecture) {
        $f.Lecture = $script:Console.Vue.CoreWebView2.ExecuteScriptAsync("JSON.stringify({ carte: document.getElementById('majLoin').hidden ? '' : document.getElementById('majLoin').innerText.replace(/\s+/g, ' ').trim(), notes: document.getElementById('majNotes').hidden ? '' : document.getElementById('majNotes').innerText.replace(/\s+/g, ' ').trim().slice(0, 80), cherche: document.querySelector('#ronds button[data-r=`"actualiser`"]').className, pastille: document.querySelector('#majLoin .pastilleMaj')?.getAttribute('aria-checked') || '', reglages: document.getElementById('reglagesGrand').hidden ? '' : document.getElementById('reglagesGrand').innerText.replace(/\s+/g, ' ').trim().slice(-400) })")
    }
    if ($f.Lecture -and $f.Lecture.IsCompleted -and -not $f.Noté) {
        $f.Noté = $true; $script:EssaiTimer.Stop()
        $r = try { $f.Lecture.Result | ConvertFrom-Json | ConvertFrom-Json } catch { $null }
        if ($r) {
            Write-Log "Essai : carte = $($r.carte)"
            Write-Log "Essai : pastille = $($r.pastille)"
            Write-Log "Essai : bouton Chercher = $($r.cherche)"
            if ($r.notes) { Write-Log "Essai : nouveautés = $($r.notes)" }
            if ($r.reglages) { Write-Log "Essai : réglages = $($r.reglages)" }
        } else { Write-Log 'Essai : lecture de la carte ratée' }
        Write-Log "Essai : réglage MajAuto = $(Get-Setting 'MajAuto' $true)"
    }
})
$script:EssaiTimer.Start()
