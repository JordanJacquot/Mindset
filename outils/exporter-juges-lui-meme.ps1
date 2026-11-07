# Mindset : juges du bloc « Mindset lui-même » pour la version Rust (rust\mindset-lui-meme\tests\juges\*.json).
#
#   & '.\outils\exporter-juges-lui-meme.ps1'        (depuis l'outil PowerShell, jamais depuis Bash)
#
# Les VRAIES fonctions de la version PowerShell (modules\mindset.ps1, et les lignes de Mindset.ps1 qui décident au
# lancement) sont prises dans leurs fichiers par l'analyseur, puis appelées avec des entrées inventées : réglages en
# mémoire, faux journal, heure figée, fausses réponses de GitHub, faux registre du mini-installateur, faux Windows
# (Start-Process, Get-ItemProperty, Get-CimInstance remplacés). Leurs réponses (textes, décisions, fichiers écrits) sont
# écrites dans les juges, que les tests Rust rejouent (tests\juges.rs).
#
# Tout se passe dans un dossier temporaire sous %TEMP%, supprimé à la fin. Rien n'est lu ni écrit ailleurs : ni les
# réglages de Mindset, ni le registre, ni les raccourcis, aucun programme lancé, aucune fenêtre, aucun appel à
# Internet. Les nombres sont écrits comme sur un PC en français (culture fr-FR, celle des utilisateurs de Mindset).

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiersMindset = Join-Path $racine 'Mindset\fichiers'
$modules = Join-Path $fichiersMindset 'modules'
$dossierJuges = Join-Path $racine 'rust\mindset-lui-meme\tests\juges'
New-Item -ItemType Directory -Force -Path $dossierJuges | Out-Null
$cultureAvant = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
$tmp = Join-Path $env:TEMP "mindset-juges-lui-meme-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName
$systemDriveAvant = $env:SystemDrive
$rnd = New-Object Random 20261107

# ---------------------------------------------------------------------------------------------------------------
# Les vraies fonctions, prises dans leur fichier
# ---------------------------------------------------------------------------------------------------------------
function Get-Ast([string]$Fichier) {
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Fichier, [ref]$null, [ref]$err)
    if ($err) { throw "Fichier illisible pour PowerShell : $Fichier" }
    $ast
}
function Get-TexteFonction($Ast, [string]$Nom) {
    $f = $Ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Nom }, $true)
    if (-not $f) { throw "Fonction $Nom introuvable" }
    $f.Extent.Text
}
$astMindset = Get-Ast (Join-Path $modules 'mindset.ps1')
$astDonnees = Get-Ast (Join-Path $modules 'donnees.ps1')
$astPaquets = Get-Ast (Join-Path $modules 'paquets.ps1')
$astInstall = Get-Ast (Join-Path $modules 'installations.ps1')
$astApplis = Get-Ast (Join-Path $modules 'applis.ps1')
$astSignature = Get-Ast (Join-Path $modules 'signature.ps1')
$textes = @()
foreach ($n in 'Get-RaisonEchecMaj', 'Format-DeNom', 'Get-NomRaisonJeu', 'ConvertTo-EntreeMaj', 'Format-QuandMaj', 'Get-MajAutoReessai',
    'Add-MajAutoEssai', 'Test-MajAutoRecente', 'Complete-MajAuto', 'Set-EchecMajAuto', 'Read-HistoriqueMaj', 'Save-HistoriqueMaj',
    'Add-HistoriqueMaj', 'Set-MajMindsetAttendue', 'Resolve-MajMindsetAttendue', 'Get-DerniereMaj', 'Get-AppliMaj',
    'Get-DisquesInstallation', 'Invoke-MajAuto', 'Start-MajMindset', 'Start-MajMindsetDirecte', 'Show-ResultatMajMindset',
    'Show-RestesDesinstallation', 'Start-VerifMajMindset', 'Confirm-DesinstallMindset', 'Get-ApplisGerees', 'Copy-ReglageVerif',
    'Start-Demarrage', 'Get-JeuxNevermind', 'Test-MajAutoActive', 'Test-VerifVersionsActive') { $textes += Get-TexteFonction $astMindset $n }
foreach ($n in 'Read-JsonSur', 'Save-JsonSur', 'ConvertFrom-JsonObjet', 'Get-RacinesDepuis', 'Get-LancerAvecWindows') { $textes += Get-TexteFonction $astDonnees $n }
$textes += Get-TexteFonction $astPaquets 'Test-VersionPlusRecente'
foreach ($n in 'Format-ArgumentAdmin', 'Get-DemarrageAppli') { $textes += Get-TexteFonction $astInstall $n }
$textes += Get-TexteFonction $astApplis 'Test-AppliAdmin'
$textes += Get-TexteFonction $astSignature 'Test-Signature'
foreach ($t in $textes) { . ([scriptblock]::Create($t)) }

# ---------------------------------------------------------------------------------------------------------------
# Le faux Mindset : réglages en mémoire, journal, heure figée, écran
# ---------------------------------------------------------------------------------------------------------------
$EnTest = $false   # (comme Mindset installé : les fonctions font tout ; ce qui toucherait au PC est remplacé ci-dessous)
$script:Journal = New-Object Collections.Generic.List[string]
function Write-Log([string]$Texte) { $script:Journal.Add($Texte) }
$script:Reglages = @{}
function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.ContainsKey($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur }
$script:Maintenant = [datetime]'2026-11-07T20:00:00'
function Get-Date { param([string]$Format) if ($Format) { $script:Maintenant.ToString($Format) } else { $script:Maintenant } }
function New-Ui {
    $u = @{}
    foreach ($n in 'BienvenueTexte', 'MajTitre', 'MajTexte') { $u[$n] = [pscustomobject]@{ Text = '' } }
    $u.MajBandeau = [pscustomobject]@{ Visibility = 'Collapsed' }
    $u.BtnMajMindset = [pscustomobject]@{ Visibility = 'Visible' }
    $u.BtnMajFermer = [pscustomobject]@{ Content = 'OK' }
    $u
}
function Get-Bandeau { [ordered]@{ visible = $ui.MajBandeau.Visibility -eq 'Visible'; titre = [string]$ui.MajTitre.Text; texte = [string]$ui.MajTexte.Text
        bouton_maj = $ui.BtnMajMindset.Visibility -ne 'Collapsed'; bouton_fermer = [string]$ui.BtnMajFermer.Content } }
function Reset-Mindset {
    $script:Journal.Clear(); $script:Reglages = @{}; $script:Maintenant = [datetime]'2026-11-07T20:00:00'
    $script:ui = New-Ui
    $script:MajAuto = @{}; $script:MajAutoEssais = @{}; $script:MajAutoEchecs = @{}; $script:MajAutoDerniere = [datetime]::MinValue
    $script:MajAutoJeu = ''; $script:MajAutoAttentes = @{}; $script:MajAutoJeuNote = $null
    $script:MajMindset = $null; $script:MajMindsetEnCours = $false; $script:MajMindsetEnvoyee = $false; $script:MajMindsetAuto = ''
    $script:Occupe = @{}; $script:AttentesAdmin = New-Object Collections.ArrayList; $script:Publications = @{}
    $script:HistoriqueMaj = $null; $script:ProgresMindset = $null
    $script:Bulles = New-Object Collections.Generic.List[object]
    $script:Confirmations = New-Object Collections.Generic.List[object]
    $script:Sortie = $false; $script:SortieAvecApplis = $false
}
function Exit-Mindset([switch]$AvecApplis) { $script:Sortie = $true; if ($AvecApplis) { $script:SortieAvecApplis = $true } }
function Show-Confirmation([string]$Titre, [string]$Texte, [string]$Bouton, [scriptblock]$Oui) { $script:Confirmations.Add([ordered]@{ titre = $Titre; texte = $Texte; bouton = $Bouton }) }
function Write-Juge([string]$Nom, $Cas) {
    $f = Join-Path $dossierJuges "$Nom.json"
    $json = ConvertTo-Json -InputObject $(if ($Cas -is [Collections.Generic.List[object]]) { $Cas.ToArray() } else { @($Cas) }) -Depth 12
    [IO.File]::WriteAllText($f, $json, (New-Object Text.UTF8Encoding $false))
    Write-Host ("  {0,-22} {1,5} cas" -f "$Nom.json", $Cas.Count)
}
function Get-Journal { , $script:Journal.ToArray() }
Reset-Mindset
$AppVersion = '3.0.0'

try {
    Write-Host "Juges du bloc « Mindset lui-même » (dossier de travail : $tmp)" -ForegroundColor Cyan

    # -----------------------------------------------------------------------------------------------------------
    # 1. Les raisons d'un échec en mots simples, « de » / « d' », le nom d'un jeu
    # -----------------------------------------------------------------------------------------------------------
    $morceaux = @('Échec : ', 'échec:', '  ', 'ÉCHEC :', 'Mindcare est encore ouvert', 'fichiers sont utilisés', 'being used', 'utilisé par un autre processus',
        'signature invalide', 'SIGNATURE', 'ne répond pas', 'Ne Répond Pas', 'connexion perdue', 'réseau', 'internet', 'délai dépassé', 'timeout', 'timed out',
        'time out', 'timedout', 'impossible de résoudre', 'Remote', 'serveur distant', '(403)', 'erreur 404', 'code 4040', 'x429y', '_500', '502.', ' 503 ',
        'espace disque', 'disque plein', 'not enough space', 'place sur le disque', 'Accès refusé', 'quelque chose', '!', '?', '.', "`n", "`r`n", "`t",
        'la tâche d''installation ne répond pas (pas de réponse de la tâche en 30 secondes).', 'Le serveur distant a retourné une erreur : (404) Introuvable.',
        ('é' * 150), ('a' * 139), ('b' * 140), ('c' * 141), 'Hôte', 'Fin', 'ok', '123', '🙂', 'ﬁn')
    $cas = New-Object Collections.Generic.List[object]
    $fixes = @('Échec : Mindcare est encore ouvert', 'Les fichiers sont utilisés par un autre programme', 'The process cannot access the file because it is being used by another process',
        'la signature de la version 1.2.0 est invalide', 'la tâche d''installation ne répond pas', 'Impossible de se connecter au serveur distant', 'Le délai d''attente est dépassé',
        'Le serveur distant a retourné une erreur : (503) Serveur non disponible.', 'Il n''y a pas assez d''espace disque.', '', '   ', 'Échec :', 'Échec : erreur bizarre',
        'Fini !', 'Vraiment ?', "Point final.`n", ('x' * 200), ('é' * 141))
    foreach ($m in $fixes) { $cas.Add([ordered]@{ nom = 'Mindcare'; message = $m; attendu = (Get-RaisonEchecMaj 'Mindcare' $m) }) }
    for ($i = 0; $i -lt 400; $i++) {
        $n = $rnd.Next(0, 5); $m = ''
        for ($k = 0; $k -lt $n; $k++) { $m += $morceaux[$rnd.Next(0, $morceaux.Count)]; if ($rnd.Next(0, 3) -eq 0) { $m += ' ' } }
        $nom = @('Mindset', 'Evermind', 'Nevermind', 'Café crème')[$rnd.Next(0, 4)]
        $cas.Add([ordered]@{ nom = $nom; message = $m; attendu = (Get-RaisonEchecMaj $nom $m) })
    }
    Write-Juge 'raisons' $cas

    $cas = New-Object Collections.Generic.List[object]
    foreach ($n in 'Evermind', 'Mindcare', 'Nevermind', 'Hélène', 'Écran', 'Hôte', 'ombre', 'Zèbre', '', 'yoga', 'Ïle', 'Èlan', 'Êtes', 'Ulysse', 'Arc', 'hello', 'HELLO', '42', 'Œuvre', 'à', ' Evermind', 'Mindset') {
        $cas.Add([ordered]@{ quoi = 'de'; entree = $n; attendu = (Format-DeNom $n) })
    }
    foreach ($r in 'une fenêtre en plein écran (jeu ou vidéo)', 'une manette utilisée il y a moins de 5 minutes', 'un jeu ouvert (Battlefield 6)', 'Un Jeu Ouvert (X (deux))', 'un jeu ouvert ()',
        'un jeu ouvert (Forêt)x', "un jeu ouvert (Café crème)`n", 'PLEIN ÉCRAN', 'Manette', '', 'autre chose', 'un jeu ouvert (a) plein écran') {
        $cas.Add([ordered]@{ quoi = 'jeu'; entree = $r; attendu = (Get-NomRaisonJeu $r) })
    }
    Write-Juge 'noms' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 2. Les entrées de l'historique (ConvertTo-EntreeMaj), sur des valeurs relues de JSON
    # -----------------------------------------------------------------------------------------------------------
    $ids = @('"evermind"', '"Evermind"', '"mindset"', ('"' + ('a' * 30) + '"'), ('"' + ('a' * 31) + '"'), '"ab-cd"', '"ab_cd"', '""', '"ab\n"', '"123"', '123', 'true', 'null', '["evermind"]', '["a","b"]', '{"x":1}', '"é"')
    $versions = @('"1.2"', '"1.2.3"', '"1.2.3.4"', '"1.2.3.4.5"', '"1"', '"v1.2"', '"1.2.3\n"', '"\u0661.\u0662"', '12', '"1..2"', '""', 'null', '1.5', '["1.2"]')
    $quands = @('"2026-11-07T20:00:00"', '"2026-11-07 20:00:00"', '"2026-1-07T20:00:00"', '"2026-02-30T10:00:00"', '"2026-11-07T20:00:00.5"', '"2026-11-07T24:00:00"',
        '"0001-01-01T00:00:00"', '"9999-12-31T23:59:59"', '""', 'null', '20261107', '"2024-02-29T12:00:00"', '"2026-11-07T20:00:00Z"', '" 2026-11-07T20:00:00"')
    $noms = @('"Evermind"', ('"' + ('x' * 35) + '"'), ('"' + ('é' * 31) + '"'), '""', 'null', '5', 'true', '["A","B"]')
    $autos = @('true', 'false', '"false"', '""', '0', '1', 'null', '"0"', '[]', '[false]', '[1,2]', '{}')
    $notes = @('""', ('"' + ('x' * 2001) + '"'), '"abc"', 'null', ('"' + ('é' * 2000) + '"'), '"- Nouveautés\nLigne 2"', '42')
    $cas = New-Object Collections.Generic.List[object]
    $textesEntree = New-Object Collections.Generic.List[string]
    foreach ($t in '"texte"', '5', 'null', '[]', '{}', '[{"id":"evermind","version":"1.2","quand":"2026-11-07T20:00:00"}]',
        '[[{"id":"evermind","version":"1.2","quand":"2026-11-07T20:00:00"}]]', '[{"id":"a","version":"1.2","quand":"2026-11-07T20:00:00"},{"id":"b"}]',
        '{"ID":"Evermind","VERSION":"1.2.0","Quand":"2026-11-07T20:00:00","NOM":"Evermind","AUTO":true,"NOTES":"n"}') { $textesEntree.Add($t) }
    for ($i = 0; $i -lt 500; $i++) {
        $p = @()
        if ($rnd.Next(0, 12)) { $p += '"id":' + $ids[$rnd.Next(0, $ids.Count)] }
        if ($rnd.Next(0, 12)) { $p += '"version":' + $versions[$rnd.Next(0, $versions.Count)] }
        if ($rnd.Next(0, 12)) { $p += '"quand":' + $quands[$rnd.Next(0, $quands.Count)] }
        if ($rnd.Next(0, 3)) { $p += '"nom":' + $noms[$rnd.Next(0, $noms.Count)] }
        if ($rnd.Next(0, 3)) { $p += '"auto":' + $autos[$rnd.Next(0, $autos.Count)] }
        if ($rnd.Next(0, 3)) { $p += '"notes":' + $notes[$rnd.Next(0, $notes.Count)] }
        $textesEntree.Add('{' + ($p -join ',') + '}')
    }
    # (des entrées surtout valables, pour que les champs eux-mêmes soient comparés)
    for ($i = 0; $i -lt 200; $i++) {
        $textesEntree.Add('{"id":' + @('"evermind"', '"Evermind"', '"ab-cd"')[$rnd.Next(0, 3)] + ',"version":' + @('"1.2"', '"1.2.3"', '"1.2.3.4"')[$rnd.Next(0, 3)] +
            ',"quand":' + @('"2026-11-07T20:00:00"', '"2024-02-29T12:00:00"', '"0001-01-01T00:00:00"')[$rnd.Next(0, 3)] + ',"nom":' + $noms[$rnd.Next(0, $noms.Count)] +
            ',"auto":' + $autos[$rnd.Next(0, $autos.Count)] + ',"notes":' + $notes[$rnd.Next(0, $notes.Count)] + '}')
    }
    foreach ($t in $textesEntree) {
        $x = ConvertFrom-Json $t
        $cas.Add([ordered]@{ texte = $t; attendu = (ConvertTo-EntreeMaj $x) })
    }
    Write-Juge 'entrees' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 3. Les heures en mots (Format-QuandMaj), et le dernier essai automatique (Get-MajAutoReessai)
    # -----------------------------------------------------------------------------------------------------------
    $cas = New-Object Collections.Generic.List[object]
    foreach ($m in '2026-11-07T20:00:00', '2026-01-01T00:30:00', '2024-03-01T08:00:00', '2026-11-07T00:00:00', '2026-12-31T23:59:59') {
        $script:Maintenant = [datetime]$m
        $base = [datetime]$m
        $liste = @($base, $base.AddMinutes(-16), $base.AddHours(-23), $base.AddDays(-1), $base.AddDays(-1).Date, $base.AddDays(-2), $base.AddDays(-40), $base.AddYears(-1), $base.AddDays(1), $base.Date, $base.Date.AddSeconds(-1), [datetime]'2024-02-29T09:05:00', [datetime]'2026-08-15T09:30:00')
        foreach ($q in $liste) {
            foreach ($long in $false, $true) {
                $cas.Add([ordered]@{ maintenant = $m; quand = $q.ToString('s'); long = $long; attendu = (Format-QuandMaj $q.ToString('s') -Long:$long) })
            }
        }
    }
    Write-Juge 'quand' $cas

    $cas = New-Object Collections.Generic.List[object]
    $versionsEssai = @('1.0.0', '1.0.1', '1.0.0-Beta', '1.0.0-beta')
    for ($s = 0; $s -lt 60; $s++) {
        $script:MajAutoEssais = @{}
        $minutes = 0.0
        $etapes = New-Object Collections.Generic.List[object]
        for ($k = 0; $k -lt 10; $k++) {
            $minutes += @(0, 0.5, 1, 5, 14, 14.99, 15, 15.01, 16, 30, 0.01)[$rnd.Next(0, 11)]
            $script:Maintenant = ([datetime]'2026-11-07T20:00:00').AddMinutes($minutes)
            $id = @('evermind', 'mindset')[$rnd.Next(0, 2)]
            $v = $versionsEssai[$rnd.Next(0, $versionsEssai.Count)]
            if ($rnd.Next(0, 2)) { Add-MajAutoEssai $id $v; $etapes.Add([ordered]@{ op = 'ajouter'; minutes = $minutes; id = $id; version = $v; attendu = $null }) }
            else { $etapes.Add([ordered]@{ op = 'lire'; minutes = $minutes; id = $id; version = $v; attendu = (Get-MajAutoReessai $id $v) }) }
        }
        $cas.Add([ordered]@{ etapes = $etapes })
    }
    Write-Juge 'reessai' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 4. L'historique des mises à jour (Read/Save/Add/Set/Resolve, Get-DerniereMaj), dans un vrai fichier
    # -----------------------------------------------------------------------------------------------------------
    $DataDir = Join-Path $tmp 'historique'
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $FichierHistoriqueMaj = Join-Path $DataDir 'mises-a-jour.json'
    $HistoriqueMajMax = 20; $DureeDerniereMaj = 12
    $entreeValable = { param($i, $q) '{"id":"evermind","nom":"Evermind","version":"1.0.' + $i + '","quand":"' + $q + '","auto":' + $(if ($i % 2) { 'true' } else { 'false' }) + ',"notes":"n' + $i + '"}' }
    $departs = [ordered]@{
        absent = $null
        vide = '{}'
        abime = '{ ceci n''est pas du json'
        liste = '{"historique":[' + ((1..25 | ForEach-Object { & $entreeValable $_ '2026-11-07T10:00:00' }) -join ',') + '],"mindsetAttendu":null}'
        melange = '{"historique":[' + (& $entreeValable 1 '2026-11-07T19:00:00') + ',{"id":"X Y","version":"1.0","quand":"2026-11-07T10:00:00"},"texte",5,null,' + (& $entreeValable 2 'hier') + ',' + (& $entreeValable 3 '2026-11-06T22:00:00') + ']}'
        seul = '{"historique":' + (& $entreeValable 7 '2026-11-07T18:00:00') + '}'
        attendue = '{"historique":[],"mindsetAttendu":{"id":"mindset","nom":"Mindset","version":"3.0.0","quand":"2026-11-07T19:59:00","auto":true,"notes":"- Nouveautés de la 3.0"}}'
        attendue_autre = '{"historique":[' + (& $entreeValable 1 '2026-11-07T19:00:00') + '],"mindsetAttendu":{"id":"mindset","nom":"Mindset","version":"2.18.0","quand":"2026-11-07T19:59:00","auto":false,"notes":""}}'
        attendue_abimee = '{"historique":[],"mindsetAttendu":{"id":"mindset","version":"x"}}'
        attendue_casse = '{"historique":[],"mindsetAttendu":{"id":"mindset","nom":"Mindset","version":"3.0.0","quand":"2026-11-07T19:59:00","auto":"oui","notes":5}}'
        futur = '{"historique":[' + (& $entreeValable 1 '2026-11-08T10:00:00') + ']}'
        vieux = '{"historique":[' + (& $entreeValable 1 '2026-11-07T07:59:59') + ',' + (& $entreeValable 2 '2026-11-07T19:00:00') + ']}'
        limite = '{"historique":[' + (& $entreeValable 1 '2026-11-07T08:00:01') + ']}'
        tableau = '[1,2,3]'
    }
    $suites = [ordered]@{
        rien = @()
        lire = @(@{ op = 'derniere'; minutes = 0 })
        ajouter = @(@{ op = 'ajouter'; id = 'mindcare'; nom = 'Mindcare'; version = '0.12.0'; auto = $true; notes = '- Nouveautés'; minutes = 1 }, @{ op = 'derniere'; minutes = 2 })
        ajouter_faux = @(@{ op = 'ajouter'; id = 'Mind Care'; nom = 'Mindcare'; version = '0.12'; auto = $false; notes = ''; minutes = 0 }, @{ op = 'ajouter'; id = 'mindcare'; nom = 'Mindcare'; version = 'v2'; auto = $false; notes = ''; minutes = 0 })
        attendre = @(@{ op = 'attendre'; version = '3.0.1'; auto = $false; notes = 'Corrections'; minutes = 0 })
        resoudre = @(@{ op = 'resoudre'; minutes = 0 }, @{ op = 'derniere'; minutes = 1 })
        cycle = @(@{ op = 'attendre'; version = '3.0.0'; auto = $true; notes = 'A'; minutes = 0 }, @{ op = 'resoudre'; minutes = 2 }, @{ op = 'ajouter'; id = 'evermind'; nom = 'Evermind'; version = '1.3.0'; auto = $false; notes = 'B'; minutes = 3 }, @{ op = 'derniere'; minutes = 720 }, @{ op = 'derniere'; minutes = 723 })
        beaucoup = @(1..22 | ForEach-Object { @{ op = 'ajouter'; id = 'nevermind'; nom = 'Nevermind'; version = "2.0.$_"; auto = ($_ % 3 -eq 0); notes = "v$_"; minutes = $_ } })
        derniere_plus_tard = @(@{ op = 'derniere'; minutes = 300 }, @{ op = 'derniere'; minutes = 719 }, @{ op = 'derniere'; minutes = 721 })
    }
    $cas = New-Object Collections.Generic.List[object]
    foreach ($d in $departs.Keys) {
        foreach ($s in $suites.Keys) {
            foreach ($versionMindset in '3.0.0', '3.0.1') {
                Reset-Mindset
                $AppVersion = $versionMindset
                Get-ChildItem -LiteralPath $DataDir -Force | Remove-Item -Force -Recurse
                if ($null -ne $departs[$d]) { [IO.File]::WriteAllText($FichierHistoriqueMaj, $departs[$d], (New-Object Text.UTF8Encoding $false)) }
                $resultats = New-Object Collections.Generic.List[object]
                foreach ($e in $suites[$s]) {
                    $script:Maintenant = ([datetime]'2026-11-07T20:00:00').AddMinutes($e.minutes)
                    switch ($e.op) {
                        'ajouter' { Add-HistoriqueMaj $e.id $e.nom $e.version $e.auto $e.notes }
                        'attendre' { Set-MajMindsetAttendue $e.version $e.auto $e.notes }
                        'resoudre' { Resolve-MajMindsetAttendue }
                        'derniere' { $resultats.Add((Get-DerniereMaj)) }
                    }
                }
                $fin = if (Test-Path -LiteralPath $FichierHistoriqueMaj) { $t = [IO.File]::ReadAllText($FichierHistoriqueMaj, [Text.Encoding]::UTF8); try { ConvertFrom-Json $t } catch { [ordered]@{ texte_brut = $t } } } else { $null }
                $cas.Add([ordered]@{ depart = $d; texte = $departs[$d]; suite = $s; version = $versionMindset; etapes = @($suites[$s]); fichier = $fin
                    dernieres = $resultats.ToArray(); journal = @($script:Journal | Where-Object { $_ -like 'Historique*' }) })
            }
        }
    }
    $AppVersion = '3.0.0'
    Write-Juge 'historique' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 5. Les disques proposés (Get-DisquesInstallation), avec un faux Win32_LogicalDisk
    # -----------------------------------------------------------------------------------------------------------
    $script:Volumes = @()
    function Get-CimInstance { param($ClassName, [string]$Filter, $ErrorAction) $script:Volumes }
    $cas = New-Object Collections.Generic.List[object]
    $go = [double]1GB
    $libres = @(0, $null, (0.5 * $go), (1.5 * $go), (2.5 * $go), (999.5 * $go), (1234.5 * $go), (1999.4 * $go), (12345678 * $go), (476.9 * $go), (3.49 * $go), (1023.5 * $go), 7)
    $fs = @('NTFS', 'ntfs', 'FAT32', 'exFAT', 'ReFS', $null)
    for ($i = 0; $i -lt 120; $i++) {
        $n = $rnd.Next(0, 5); $v = @()
        $lettres = @('C', 'D', 'E', 'F', 'G', 'Z') | Sort-Object { $rnd.Next() }
        for ($k = 0; $k -lt $n; $k++) {
            $libre = if ($rnd.Next(0, 3)) { $libres[$rnd.Next(0, $libres.Count)] } else { [math]::Round($rnd.NextDouble() * 4000 * $go) }
            $v += [pscustomobject]@{ DeviceID = "$($lettres[$k]):"; FileSystem = $fs[$rnd.Next(0, $fs.Count)]; FreeSpace = $libre }
        }
        $script:Volumes = $v
        $sys = @('C:', 'D:')[$rnd.Next(0, 2)]
        $env:SystemDrive = $sys
        $r = @(Get-DisquesInstallation | ForEach-Object { [ordered]@{ lettre = $_.Lettre; texte = $_.Texte; libre = $_.Libre } })
        $cas.Add([ordered]@{ systeme = $sys.Substring(0, 1); volumes = @($v | ForEach-Object { [ordered]@{ lettre = $_.DeviceID; systeme_fichiers = $_.FileSystem; libre = $_.FreeSpace } }); attendu = $r })
    }
    $env:SystemDrive = $systemDriveAvant
    Write-Juge 'disques' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 6. Les bulles d'une mise à jour automatique finie (Complete-MajAuto, Set-EchecMajAuto)
    # -----------------------------------------------------------------------------------------------------------
    function Show-BulleMajAuto([string]$Titre, [string]$Texte) { Write-Log "Mise à jour automatique : $Titre"; $script:Bulles.Add([ordered]@{ titre = $Titre; texte = $Texte }) }
    $cas = New-Object Collections.Generic.List[object]
    $messagesFin = @('Mindcare 0.12.0 est installé.', 'Mindcare 0.12.0 EST INSTALLÉ. Ancien raccourci retiré.', 'Échec : Mindcare est encore ouvert', 'la signature de la version 0.12.0 est invalide',
        'la tâche d''installation ne répond pas', '', 'erreur 404', 'quelque chose de bizarre')
    $notesFin = @('', "- Corrige l'ouverture`r`n- Autre", "`n`n   `n## Nouveautés", "* " + ('z' * 200), "#-*  Titre  `nsuite", '   ', $null)
    for ($i = 0; $i -lt 120; $i++) {
        Reset-Mindset
        $nom = @('Mindcare', 'Evermind', 'Nevermind')[$rnd.Next(0, 3)]
        $id = $nom.ToLower()
        $v = @('0.12.0', '1.0.0')[$rnd.Next(0, 2)]
        $script:MajAuto[$id] = $v
        $n = $notesFin[$rnd.Next(0, $notesFin.Count)]
        $script:Publications[$id] = @{ Version = $v; Notes = $n }
        $essai = $null
        if ($rnd.Next(0, 3)) {
            $essai = [ordered]@{ version = @($v, '9.9.9')[$rnd.Next(0, 2)]; minutes = @(0, 3, 14.5, 15, 20)[$rnd.Next(0, 5)]; nombre = $rnd.Next(1, 5) }
            $script:MajAutoEssais[$id] = @{ Version = $essai.version; Quand = $script:Maintenant.AddMinutes(-$essai.minutes); Nombre = $essai.nombre }
        }
        if ($rnd.Next(0, 2)) { $script:MajAutoEchecs[$id] = @{ Version = $v; Raison = 'avant' } }
        $avantEchec = [bool]$script:MajAutoEchecs[$id]
        $m = $messagesFin[$rnd.Next(0, $messagesFin.Count)]
        $erreur = $null
        try { Complete-MajAuto ([pscustomobject]@{ Id = $id; Nom = $nom }) $m } catch { $erreur = $_.Exception.Message }
        $e = $script:MajAutoEchecs[$id]
        $cas.Add([ordered]@{ id = $id; nom = $nom; version = $v; notes = $n; essai = $essai; echec_avant = $avantEchec; message = $m; erreur = $erreur
            bulles = $script:Bulles.ToArray(); echec = $(if ($e) { [ordered]@{ version = $e.Version; raison = $e.Raison } } else { $null }); journal = (Get-Journal) })
    }
    Write-Juge 'bulles' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 7. Invoke-MajAuto : qui est mis à jour tout seul, et pourquoi les autres attendent
    # -----------------------------------------------------------------------------------------------------------
    $script:Scenario = $null
    function Test-TacheInstallation { [bool]$script:Scenario.tache }
    function Get-JeuEnCours { [string]$script:Scenario.jeu }
    function Get-SecondesInactif { if ($script:Scenario.inactif -eq 'erreur') { throw 'relevé impossible' }; [double]$script:Scenario.inactif }
    function Get-EtatCarte($Appli) {
        $a = @($script:Scenario.applis | Where-Object { $_.id -eq $Appli.Id })[0]
        @{ MajDispo = [bool]($a.gere -and $a.pub -and (Test-VersionPlusRecente $a.pub $a.installee)); Occupe = $null; Ouverte = [bool]$a.ouverte; Pub = @{ Version = $a.pub } }
    }
    $script:Actions = New-Object Collections.Generic.List[object]
    function Start-InstallAppli($Appli) { $script:Actions.Add([ordered]@{ quoi = 'installer'; id = $Appli.Id }) }
    function Start-MajMindset([switch]$Cache, [switch]$Auto) { $script:Actions.Add([ordered]@{ quoi = 'mindset'; auto = [bool]$Auto; cache = [bool]$Cache }) }
    $jeux = @('', '', '', 'une fenêtre en plein écran (jeu ou vidéo)', 'une manette utilisée il y a moins de 5 minutes', 'un jeu ouvert (Jeu Essai)')
    $cas = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt 400; $i++) {
        Reset-Mindset
        $listeApplis = @()
        foreach ($x in @(@{ id = 'evermind'; nom = 'Evermind' }, @{ id = 'mindcare'; nom = 'Mindcare' }, @{ id = 'nevermind'; nom = 'Nevermind' })) {
            if ($rnd.Next(0, 4) -eq 0) { continue }
            $inst = @('1.0.0', '1.2.0', $null)[$rnd.Next(0, 3)]
            $pub = @('1.1.0', '1.0.0', $null, '2.0.0')[$rnd.Next(0, 4)]
            $essai = $null
            if ($rnd.Next(0, 3) -eq 0) { $essai = [ordered]@{ version = @($pub, '1.1.0')[$rnd.Next(0, 2)]; minutes = @(1, 14, 16, 100)[$rnd.Next(0, 4)]; nombre = $rnd.Next(1, 4) } }
            $listeApplis += [ordered]@{ id = $x.id; nom = $x.nom; gere = [bool]$rnd.Next(0, 4); installee = $inst; pub = $pub; ouverte = [bool]$rnd.Next(0, 2); essai = $essai }
        }
        $mindset = $null
        if ($rnd.Next(0, 2)) { $mindset = [ordered]@{ version = '3.1.0'; en_cours = ($rnd.Next(0, 5) -eq 0); essai = $(if ($rnd.Next(0, 3) -eq 0) { [ordered]@{ version = '3.1.0'; minutes = @(1, 16)[$rnd.Next(0, 2)]; nombre = $rnd.Next(1, 4) } } else { $null }) } }
        $sc = [ordered]@{
            maj_auto = @($null, $true, $false)[$rnd.Next(0, 3)]; verif = @($null, $true, $true, $false)[$rnd.Next(0, 4)]
            admin = ($rnd.Next(0, 8) -eq 0); tache = ($rnd.Next(0, 8) -ne 0)
            derniere = @($null, $null, $null, 10, 31)[$rnd.Next(0, 5)]
            occupe = ($rnd.Next(0, 8) -eq 0); attentes_admin = ($rnd.Next(0, 10) -eq 0); deja = ($rnd.Next(0, 10) -eq 0)
            jeu = $jeux[$rnd.Next(0, $jeux.Count)]; jeu_note = @($null, 'une fenêtre en plein écran (jeu ou vidéo)')[$rnd.Next(0, 2)]
            inactif = @(0, 100, 299.9, 300, 1000, 'erreur')[$rnd.Next(0, 6)]
            visible = [bool]$rnd.Next(0, 2); reduite = ($rnd.Next(0, 4) -eq 0)
            applis = $listeApplis; mindset = $mindset
        }
        $script:Scenario = $sc
        if ($null -ne $sc.maj_auto) { $script:Reglages['MajAuto'] = $sc.maj_auto }
        if ($null -ne $sc.verif) { $script:Reglages['VerifVersions'] = $sc.verif }
        $MindsetAdmin = $sc.admin
        if ($null -ne $sc.derniere) { $script:MajAutoDerniere = $script:Maintenant.AddSeconds(-$sc.derniere) }
        if ($sc.occupe) { $script:Occupe['autre'] = 'Installation...' }
        if ($sc.attentes_admin) { [void]$script:AttentesAdmin.Add(@{ Id = 'x' }) }
        if ($sc.deja) { $script:MajAuto['autre'] = '1.0.0' }
        $script:MajAutoJeuNote = $sc.jeu_note
        $Window = [pscustomobject]@{ IsVisible = $sc.visible; WindowState = $(if ($sc.reduite) { 'Minimized' } else { 'Normal' }) }
        $Applis = @($listeApplis | ForEach-Object { [pscustomobject]@{ Id = $_.id; Nom = $_.nom } })
        foreach ($a in $listeApplis) { if ($a.essai) { $script:MajAutoEssais[$a.id] = @{ Version = $a.essai.version; Quand = $script:Maintenant.AddMinutes(-$a.essai.minutes); Nombre = $a.essai.nombre } } }
        if ($mindset) {
            $script:MajMindset = @{ Version = $mindset.version; Zip = 'Z'; Sig = 'S'; Notes = '' }
            $script:MajMindsetEnCours = $mindset.en_cours
            if ($mindset.essai) { $script:MajAutoEssais['mindset'] = @{ Version = $mindset.essai.version; Quand = $script:Maintenant.AddMinutes(-$mindset.essai.minutes); Nombre = $mindset.essai.nombre } }
        }
        $script:Actions.Clear()
        Invoke-MajAuto
        $essais = [ordered]@{}; foreach ($k in ($script:MajAutoEssais.Keys | Sort-Object)) { $essais[$k] = [ordered]@{ version = $script:MajAutoEssais[$k].Version; nombre = $script:MajAutoEssais[$k].Nombre } }
        $enCours = [ordered]@{}; foreach ($k in ($script:MajAuto.Keys | Sort-Object)) { $enCours[$k] = $script:MajAuto[$k] }
        $att = [ordered]@{}; foreach ($k in ($script:MajAutoAttentes.Keys | Sort-Object)) { $att[$k] = $script:MajAutoAttentes[$k] }
        $cas.Add([ordered]@{ scenario = $sc; actions = $script:Actions.ToArray(); attentes = $att; jeu = [string]$script:MajAutoJeu; essais = $essais; en_cours = $enCours; journal = (Get-Journal) })
    }
    $MindsetAdmin = $false
    Write-Juge 'maj-auto' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 8. Start-MajMindset et la fin de sa demande au mini-installateur (accusé de réception, réponse, repli)
    # -----------------------------------------------------------------------------------------------------------
    Remove-Item function:Start-MajMindset
    . ([scriptblock]::Create((Get-TexteFonction $astMindset 'Start-MajMindset')))
    $TelechargementsDir = Join-Path $tmp 'telechargements'
    New-Item -ItemType Directory -Force -Path $TelechargementsDir | Out-Null
    $FichierMajMindset = Join-Path $TelechargementsDir 'maj-mindset.json'
    $DossierMindset = 'DOSSIER'
    $script:Envoyees = New-Object Collections.Generic.List[object]
    $script:Directes = 0
    $script:Attendues = New-Object Collections.Generic.List[object]
    function Send-DemandeInstallation($D) { $script:Envoyees.Add($D); $true }
    function Start-MajMindsetDirecte { $script:Directes++ }
    function Set-MajMindsetAttendue([string]$Version, [bool]$Auto, [string]$Notes) { $script:Attendues.Add([ordered]@{ version = $Version; auto = $Auto; notes = $Notes }) }
    $cas = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt 300; $i++) {
        Reset-Mindset
        $script:Envoyees.Clear(); $script:Directes = 0; $script:Attendues.Clear()
        $sc = [ordered]@{
            prete = [bool]$rnd.Next(0, 6); occupe = ($rnd.Next(0, 6) -eq 0); envoyee = ($rnd.Next(0, 6) -eq 0); admin = ($rnd.Next(0, 6) -eq 0); tache = ($rnd.Next(0, 5) -ne 0)
            cache = [bool]$rnd.Next(0, 2); auto = [bool]$rnd.Next(0, 2); echec = [bool]$rnd.Next(0, 2)
            essai = $(if ($rnd.Next(0, 2)) { [ordered]@{ version = '3.1.0'; minutes = @(1, 16)[$rnd.Next(0, 2)]; nombre = $rnd.Next(1, 4) } } else { $null })
            fin = @('recu', 'ok', 'ko', 'repli')[$rnd.Next(0, 4)]; message = @('la signature est invalide', 'Mindset est encore ouvert', '')[$rnd.Next(0, 3)]
        }
        if ($sc.prete) { $script:MajMindset = @{ Version = '3.1.0'; Zip = 'C:\T\mindset.zip'; Sig = 'C:\T\mindset.zip.sig'; Notes = '- Nouveautés' } }
        if ($sc.occupe) { $script:Occupe['evermind'] = 'Installation...' }
        $script:MajMindsetEnvoyee = $sc.envoyee
        $MindsetAdmin = $sc.admin
        function Test-TacheInstallation { [bool]$script:ScenarioTache }
        $script:ScenarioTache = $sc.tache
        if ($sc.echec) { $script:MajAutoEchecs['mindset'] = @{ Version = '3.1.0'; Raison = 'avant' } }
        if ($sc.essai) { $script:MajAutoEssais['mindset'] = @{ Version = $sc.essai.version; Quand = $script:Maintenant.AddMinutes(-$sc.essai.minutes); Nombre = $sc.essai.nombre } }
        [IO.File]::WriteAllText($FichierMajMindset, '{}')
        Start-MajMindset -Cache:$sc.cache -Auto:$sc.auto
        $demande = $null
        if ($script:Envoyees.Count) {
            $d = $script:Envoyees[0]
            $c = [ordered]@{}; foreach ($k in ($d.Contenu.Keys | Sort-Object)) { if ($k -ne 'Id') { $c[$k] = $(if ($k -eq 'AttendrePid') { 'PID' } else { [string]$d.Contenu[$k] }) } }
            $demande = [ordered]@{ contenu = $c; auto = [bool]$d.Auto }
            $avantFin = $script:Journal.Count
            switch ($sc.fin) {
                'recu' { & $d.Recu $d }
                'ok' { & $d.Fin $true 'Mindset 3.1.0 est installé.' }
                'ko' { & $d.Fin $false $sc.message }
                'repli' { & $d.Repli $d }
            }
        }
        $e = $script:MajAutoEchecs['mindset']
        $cas.Add([ordered]@{ scenario = $sc; texte = [string]$ui.MajTexte.Text; visible_reglage = $(if ($script:Reglages.ContainsKey('MajMindsetVisible')) { $script:Reglages['MajMindsetVisible'] } else { $null })
            demande_reglage = $(if ($script:Reglages.ContainsKey('MajMindsetDemande')) { 'ID' } else { $null })
            attendues = $script:Attendues.ToArray(); demande = $demande; directes = $script:Directes; envoyee = [bool]$script:MajMindsetEnvoyee
            fichier_maj = (Test-Path -LiteralPath $FichierMajMindset); sortie = $script:Sortie
            echec = $(if ($e) { [ordered]@{ version = $e.Version; raison = $e.Raison } } else { $null }); bulles = $script:Bulles.ToArray(); journal = (Get-Journal) })
    }
    $MindsetAdmin = $false
    Write-Juge 'maj-mindset' $cas

    # Start-MajMindsetDirecte : la demande de Windows (MindsetInstallateur.exe en Rust)
    Remove-Item function:Start-MajMindsetDirecte
    . ([scriptblock]::Create((Get-TexteFonction $astMindset 'Start-MajMindsetDirecte')))
    $AppDir = 'FICHIERS'
    $PowerShellWindows = 'powershell.exe'
    function Get-RefusVariablesAdmin { '' }
    $script:Lances = New-Object Collections.Generic.List[object]
    $script:RefusLancement = $false
    function Start-Process { param([string]$FilePath, $ArgumentList, [string]$Verb, [string]$WindowStyle, [string]$WorkingDirectory, $ErrorAction, [switch]$PassThru)
        if ($script:RefusLancement) { throw 'L''opération a été annulée par l''utilisateur.' }
        $script:Lances.Add(@($ArgumentList)) }
    $cas = New-Object Collections.Generic.List[object]
    foreach ($prete in $true, $false) {
        foreach ($zip in 'C:\T\mindset.zip', 'C:\T\min"dset.zip', 'C:\Program Files\T\') {
            foreach ($refus in $false, $true) {
                Reset-Mindset; $script:Lances.Clear(); $script:RefusLancement = $refus
                if ($prete) { $script:MajMindset = @{ Version = '3.1.0'; Zip = $zip; Sig = 'C:\T\mindset.zip.sig'; Notes = '' } }
                Start-MajMindsetDirecte
                $params = $null
                if ($script:Lances.Count) {
                    $a = @($script:Lances[0]); $params = New-Object Collections.Generic.List[object]
                    $k = [array]::IndexOf($a, '-Action') + 2
                    while ($k -lt $a.Count - 1) {
                        $n = ([string]$a[$k]).TrimStart('-'); $v = ([string]$a[$k + 1])
                        if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) -replace '(\\+)\1$', '$1' }
                        if ($n -eq 'AttendrePid') { $v = 'PID' }; if ($n -eq 'Sid') { $v = 'SID' }
                        if ($n -ne 'Resultat') { $params.Add(@($n, $v)) }
                        $k += 2
                    }
                }
                $cas.Add([ordered]@{ prete = $prete; zip = $zip; refus = $refus; texte = [string]$ui.MajTexte.Text; parametres = $params; sortie = $script:Sortie; journal = (Get-Journal) })
            }
        }
    }
    Write-Juge 'maj-directe' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 9. Show-ResultatMajMindset : le bandeau au redémarrage
    # -----------------------------------------------------------------------------------------------------------
    function Resolve-MajMindsetAttendue { }
    $script:Valeurs = @{}
    function Get-ValeurInstallation([string]$Nom) { [string]$script:Valeurs[$Nom] }
    $script:Retraits = 0
    function Remove-DemandeInstallation { $script:Retraits++ }
    $resultats = @($null, '{"id":"ID","ok":true,"message":"Mindset 3.0.0 est installé."}', '{"id":"ID","ok":false,"message":"la signature est invalide."}', '{"id":"AUTRE","ok":true,"message":"x"}',
        'pas du json', '', '{"ok":true}', '{"id":"id","ok":"false","message":5}', '[1]', '{"id":"ID","ok":0}')
    $contenusFichier = @($null, '{"ok":true,"message":"fait"}', '{"ok":false,"message":"Mindset est encore ouvert."}', 'abîmé', '', "$([char]0xFEFF){""ok"":true}", '{"ok":1,"message":null}', 'null', '"texte"')
    $cas = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt 300; $i++) {
        Reset-Mindset; $script:Retraits = 0
        Get-ChildItem -LiteralPath $TelechargementsDir -Force | Remove-Item -Force
        $sc = [ordered]@{ demande = @($null, '', 'ID')[$rnd.Next(0, 3)]; resultat = $resultats[$rnd.Next(0, $resultats.Count)]; restes = @('', '', 'le dossier C:\Program Files\Mindset\Mindset')[$rnd.Next(0, 3)]
            fichier = $contenusFichier[$rnd.Next(0, $contenusFichier.Count)]; zips = [bool]$rnd.Next(0, 2); visible = @($null, $true)[$rnd.Next(0, 2)]; version = @('3.0.0', '3.0.1')[$rnd.Next(0, 2)] }
        $AppVersion = $sc.version
        if ($null -ne $sc.demande) { $script:Reglages['MajMindsetDemande'] = $(if ($sc.demande -eq 'ID') { '0123456789abcdef0123456789abcdef' } else { '' }) }
        if ($null -ne $sc.visible) { $script:Reglages['MajMindsetVisible'] = $sc.visible }
        $script:Valeurs = @{ Resultat = $(if ($sc.resultat) { $sc.resultat -replace '"ID"', '"0123456789abcdef0123456789abcdef"' -replace '"id"(?=,)', '"0123456789ABCDEF0123456789ABCDEF"' } else { $sc.resultat }); Restes = $sc.restes }
        if ($null -ne $sc.fichier) { [IO.File]::WriteAllText($FichierMajMindset, $sc.fichier, (New-Object Text.UTF8Encoding $false)) }
        if ($sc.zips) { foreach ($f in 'mindset.zip', 'mindset.zip.sig', 'mindset.zip.nouveau', 'mindset.zip.nouveau.sig') { [IO.File]::WriteAllText((Join-Path $TelechargementsDir $f), 'x') } }
        Show-ResultatMajMindset
        $restants = @(Get-ChildItem -LiteralPath $TelechargementsDir -Force | ForEach-Object Name | Sort-Object)
        $cas.Add([ordered]@{ scenario = $sc; resultat_valeur = $script:Valeurs.Resultat; bandeau = (Get-Bandeau); demande_apres = $script:Reglages['MajMindsetDemande']; visible_apres = $script:Reglages['MajMindsetVisible']
            retraits = $script:Retraits; restants = $restants; journal = (Get-Journal) })
    }
    $AppVersion = '3.0.0'
    Write-Juge 'resultat' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 10. Start-VerifMajMindset : la nouvelle version téléchargée, sa signature vraiment vérifiée (une clé d'essai)
    # -----------------------------------------------------------------------------------------------------------
    $cles = Join-Path $tmp 'cles-publiques'
    New-Item -ItemType Directory -Force -Path $cles | Out-Null
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
    $xmlCle = $rsa.ToXmlString($false)
    [IO.File]::WriteAllText((Join-Path $cles 'essai.xml'), $xmlCle, (New-Object Text.UTF8Encoding $false))
    $ClePublique = $cles
    function Test-MindsetInstalle { $true }
    function Update-ListeVersions { }
    $script:OngletParametres = ''
    $script:Pub = $null
    $script:Octets = @{}
    function Get-Publication([string]$Depot, [string[]]$Zip) { $script:Pub }
    function Get-Octets([string]$Url, $Progres = $null) {
        $o = $script:Octets[$Url]
        if ($null -eq $o) { throw "Adresse inconnue : $Url" }
        if ($o -is [string]) { throw $o }
        if ($Progres) { $Progres.Total = $o.Length; $Progres.Recu = $o.Length }
        , [byte[]]$o
    }
    function Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) {
        $r = $null; $err = $null
        try { $r = & $Travail $Parametres } catch { $err = $_.Exception.Message }
        & $Fin $r $err
    }
    $zipBon = [Text.Encoding]::UTF8.GetBytes('zip de Mindset 3.1.0')
    $sigBonne = $rsa.SignData($zipBon, 'SHA256')
    $sigFausse = [byte[]]($sigBonne.Clone()); $sigFausse[10] = $sigFausse[10] -bxor 1
    $cas = New-Object Collections.Generic.List[object]
    $publications = @(
        [ordered]@{ erreur = 'GitHub a refusé la demande (403)' },
        [ordered]@{ version = '3.1.0'; url_zip = 'https://github.com/z'; url_sig = 'https://github.com/s'; notes = '- Nouveautés' },
        [ordered]@{ version = '3.1.0'; url_zip = 'https://github.com/z'; url_sig = ''; notes = '' },
        [ordered]@{ version = '3.0.0'; url_zip = 'https://github.com/z'; url_sig = 'https://github.com/s'; notes = '' },
        [ordered]@{ version = '2.18.0'; url_zip = 'https://github.com/z'; url_sig = 'https://github.com/s'; notes = '' },
        [ordered]@{ version = 'abc'; url_zip = 'https://github.com/z'; url_sig = 'https://github.com/s'; notes = '' })
    foreach ($p in $publications) {
        foreach ($sig in 'bonne', 'fausse', 'absente') {
            foreach ($zip in 'bon', 'erreur') {
                foreach ($prete in $null, '3.0.5', '3.2.0') {
                    Reset-Mindset
                    Get-ChildItem -LiteralPath $TelechargementsDir -Force | Remove-Item -Force
                    if ($prete) {
                        $script:MajMindset = @{ Version = $prete; Zip = (Join-Path $TelechargementsDir 'mindset.zip'); Sig = (Join-Path $TelechargementsDir 'mindset.zip.sig'); Notes = 'ancienne' }
                        [IO.File]::WriteAllText($script:MajMindset.Zip, "zip $prete"); [IO.File]::WriteAllText($script:MajMindset.Sig, "sig $prete")
                    }
                    $script:Pub = if ($p.erreur) { @{ Erreur = $p.erreur } } else { @{ Version = $p.version; UrlZip = $p.url_zip; UrlSig = $p.url_sig; Notes = $p.notes } }
                    $script:Octets = @{ 'https://github.com/z' = $(if ($zip -eq 'bon') { $zipBon } else { 'Impossible de se connecter au serveur distant' }) }
                    if ($sig -eq 'bonne') { $script:Octets['https://github.com/s'] = $sigBonne } elseif ($sig -eq 'fausse') { $script:Octets['https://github.com/s'] = $sigFausse }
                    Start-VerifMajMindset
                    $fichiersApres = [ordered]@{}
                    foreach ($f in @(Get-ChildItem -LiteralPath $TelechargementsDir -File -Force | Sort-Object Name)) { $fichiersApres[$f.Name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName)) }
                    $cas.Add([ordered]@{ publication = $p; signature = $sig; zip = $zip; prete_avant = $prete
                        prete = $(if ($script:MajMindset) { [ordered]@{ version = [string]$script:MajMindset.Version; notes = [string]$script:MajMindset.Notes; zip = (Split-Path $script:MajMindset.Zip -Leaf); sig = (Split-Path $script:MajMindset.Sig -Leaf) } } else { $null })
                        en_cours = [bool]$script:MajMindsetEnCours; fichiers = $fichiersApres; bandeau = (Get-Bandeau); journal = (Get-Journal) })
                }
            }
        }
    }
    $verif = [ordered]@{ cle = $xmlCle; zip = [Convert]::ToBase64String($zipBon); sig_bonne = [Convert]::ToBase64String($sigBonne); sig_fausse = [Convert]::ToBase64String($sigFausse); cas = $cas }
    [IO.File]::WriteAllText((Join-Path $dossierJuges 'verif.json'), (ConvertTo-Json -InputObject $verif -Depth 12), (New-Object Text.UTF8Encoding $false))
    Write-Host ("  {0,-22} {1,5} cas" -f 'verif.json', $cas.Count)

    # -----------------------------------------------------------------------------------------------------------
    # 11. Confirm-DesinstallMindset : la question posée
    # -----------------------------------------------------------------------------------------------------------
    $DesinstalleurMindset = Join-Path $tmp 'Desinstaller Mindset.exe'
    $SuiteDir = 'SUITE'
    $script:Installs = @{}
    function Get-Installation($Appli) { $script:Installs[$Appli.Id] }
    $cas = New-Object Collections.Generic.List[object]
    $toutes = @([pscustomobject]@{ Id = 'nevermind'; Nom = 'Nevermind' }, [pscustomobject]@{ Id = 'evermind'; Nom = 'Evermind' }, [pscustomobject]@{ Id = 'mindcare'; Nom = 'Mindcare' })
    foreach ($installe in $true, $false) {
        foreach ($desinst in $true, $false) {
            for ($masque = 0; $masque -lt 8; $masque++) {
                foreach ($gereMasque in 0, 7, 5) {
                    Reset-Mindset
                    function Test-MindsetInstalle { [bool]$script:Installe }
                    $script:Installe = $installe
                    if ($desinst) { [IO.File]::WriteAllText($DesinstalleurMindset, 'x') } else { Remove-Item -LiteralPath $DesinstalleurMindset -Force -ErrorAction SilentlyContinue }
                    $Applis = @(); $script:Installs = @{}; $liste = @()
                    for ($k = 0; $k -lt 3; $k++) {
                        if ($masque -band (1 -shl $k)) {
                            $Applis += $toutes[$k]
                            $gere = [bool]($gereMasque -band (1 -shl $k))
                            $script:Installs[$toutes[$k].Id] = @{ Dossier = 'x'; Gere = $gere }
                            $liste += [ordered]@{ id = $toutes[$k].Id; nom = $toutes[$k].Nom; gere = $gere }
                        }
                    }
                    Confirm-DesinstallMindset
                    $cas.Add([ordered]@{ installe = $installe; desinstalleur = $desinst; applis = $liste; confirmations = $script:Confirmations.ToArray() })
                }
            }
        }
    }
    Write-Juge 'desinstallation' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 12. Le lancement (Mindset.ps1:117-120) et Start-Demarrage
    # -----------------------------------------------------------------------------------------------------------
    $lignes = [IO.File]::ReadAllLines((Join-Path $fichiersMindset 'Mindset.ps1'), [Text.Encoding]::UTF8)
    $l1 = @($lignes | Where-Object { $_ -like 'if ($Demarrage -and (Get-Setting ''MajMindsetVisible''*' })
    $l2 = @($lignes | Where-Object { $_ -like 'if ($Demarrage -and -not (Get-LancerAvecWindows)*' })
    if ($l1.Count -ne 1 -or $l2.Count -ne 1) { throw 'Lignes du lancement introuvables dans Mindset.ps1' }
    $texteLancement = ($l1[0] + "`n" + $l2[0]) -replace '\bexit\b', '$script:Sortie = $true; return'
    $cas = New-Object Collections.Generic.List[object]
    foreach ($dem in $true, $false) {
        foreach ($vis in '-', $true, $false, 'x', 0) {
            foreach ($law in '-', $true, $false, 0, '') {
                foreach ($dmd in '-', '', '0123456789abcdef0123456789abcdef', 0) {
                    Reset-Mindset
                    if (-not ($vis -is [string] -and $vis -eq '-')) { $script:Reglages['MajMindsetVisible'] = $vis }
                    if (-not ($law -is [string] -and $law -eq '-')) { $script:Reglages['LancerAvecWindows'] = $law }
                    if (-not ($dmd -is [string] -and $dmd -eq '-')) { $script:Reglages['MajMindsetDemande'] = $dmd }
                    $reglagesAvant = [ordered]@{}; foreach ($k in ($script:Reglages.Keys | Sort-Object)) { $reglagesAvant[$k] = $script:Reglages[$k] }
                    $Demarrage = $dem
                    . ([scriptblock]::Create($texteLancement))
                    $cas.Add([ordered]@{ demarrage = $dem; reglages = $reglagesAvant; sortie = $script:Sortie; demarrage_apres = $Demarrage
                        visible_apres = $(if ($script:Reglages.ContainsKey('MajMindsetVisible')) { $script:Reglages['MajMindsetVisible'] } else { '-' }); journal = (Get-Journal) })
                }
            }
        }
    }
    Write-Juge 'lancement' $cas

    foreach ($n in 'Update-RaccourcisApplis', 'Update-RaccourcisMindset', 'Repair-DemarrageApplis', 'Move-TachesDemarrage') { Set-Item -Path "function:script:$n" -Value { } }
    $script:Ouvertes = New-Object Collections.Generic.List[string]
    function Open-Appli($Appli, [switch]$Demarrage) { $script:Ouvertes.Add($Appli.Id) }
    $DataDir = Join-Path $tmp 'donnees-demarrage'
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $cas = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt 200; $i++) {
        Reset-Mindset; $script:Ouvertes.Clear()
        $marque = Join-Path $DataDir 'relance.marque'
        Remove-Item -LiteralPath $marque -Force -ErrorAction SilentlyContinue
        $age = @($null, $null, 30, 119, 121, 600)[$rnd.Next(0, 6)]
        if ($null -ne $age) { [IO.File]::WriteAllText($marque, '1'); (Get-Item -LiteralPath $marque).LastWriteTime = $script:Maintenant.AddSeconds(-$age) }
        $MindsetAdmin = [bool]$rnd.Next(0, 2)
        $Applis = @(); $script:Installs = @{}; $liste = @(); $dem = @()
        foreach ($x in @(@{ id = 'nevermind'; nom = 'Nevermind'; admin = $true; depuis = '1.15.0' }, @{ id = 'evermind'; nom = 'Evermind'; admin = $false; depuis = '' }, @{ id = 'mindcare'; nom = 'Mindcare'; admin = $true; depuis = '' })) {
            if ($rnd.Next(0, 4) -eq 0) { continue }
            $Applis += [pscustomobject]@{ Id = $x.id; Nom = $x.nom; Admin = $x.admin; SansDroitsDepuis = $x.depuis }
            $inst = $null
            if ($rnd.Next(0, 4)) { $inst = @{ Dossier = 'x'; Gere = [bool]$rnd.Next(0, 3); Version = @('1.14.0', '1.15.0', '2.0.0', $null)[$rnd.Next(0, 4)] }; $script:Installs[$x.id] = $inst }
            $d = [bool]$rnd.Next(0, 2); if ($d) { $dem += $x.id }
            $liste += [ordered]@{ id = $x.id; nom = $x.nom; admin = $x.admin; depuis = $x.depuis; installation = $(if ($inst) { [ordered]@{ gere = $inst.Gere; version = $inst.Version } } else { $null }); demarrage = $d }
        }
        $script:Reglages['Demarrage'] = $dem
        Start-Demarrage
        $cas.Add([ordered]@{ admin = $MindsetAdmin; marque_age = $age; applis = $liste; ouvertes = $script:Ouvertes.ToArray(); marque_apres = (Test-Path -LiteralPath $marque) })
    }
    $MindsetAdmin = $false
    Write-Juge 'demarrage' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 13. La bascule administrateur (Mindset.ps1:47-72), avec un faux Windows
    # -----------------------------------------------------------------------------------------------------------
    $texteMindset = [IO.File]::ReadAllText((Join-Path $fichiersMindset 'Mindset.ps1'), [Text.Encoding]::UTF8)
    $mb = [regex]::Match($texteMindset, '(?ms)^\$MarqueCache = .*?(?=^Add-Type -AssemblyName)')
    if (-not $mb.Success) { throw 'Bloc de la bascule introuvable dans Mindset.ps1' }
    $texteBascule = $mb.Value -replace '\$PSScriptRoot', '$FauxScriptRoot' -replace '(?m)\bexit\b', '$script:Sortie = $true; return'
    $script:Inscrit = ''
    function Get-ItemProperty { param($Path, [string]$ErrorAction) if (-not $script:Inscrit) { throw 'absent' }; [pscustomobject]@{ InstallLocation = $script:Inscrit } }
    $script:Lancements = New-Object Collections.Generic.List[string]
    function Start-Process {
        param([string]$FilePath, $ArgumentList, [string]$WorkingDirectory, [string]$WindowStyle, [switch]$PassThru)
        $a = @($ArgumentList | ForEach-Object { ([string]$_).Trim('"') })
        $nom = Split-Path $FilePath -Leaf
        if ($nom -eq 'powershell.exe') {
            $dest = $a[[array]::IndexOf($a, '-Destination') + 1]; $act = $a[[array]::IndexOf($a, '-Action') + 1]
            $script:Lancements.Add("$act|Destination=$(& $script:Marquer $dest)|Sid=SID")
        } else { $script:Lancements.Add("explorer|$(& $script:Marquer ($a -join ' '))") }
        if ($PassThru) { $o = [pscustomobject]@{}; $o | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }; $o }
    }
    $script:Maintenant = [datetime]::Now
    function Get-Date { param([string]$Format) if ($Format) { (& (Get-Command Get-Date -CommandType Cmdlet)).ToString($Format) } else { & (Get-Command Get-Date -CommandType Cmdlet) } }
    $tempAvant = $env:TEMP
    $cas = New-Object Collections.Generic.List[object]
    $dossierBascule = Join-Path $tmp 'bascule'
    foreach ($admin in $true, $false) {
        foreach ($desinst in $false, $true) {
            foreach ($dem in $false, $true) {
                foreach ($variante in 'aucun', 'copie', 'copie-majuscules', 'copie-barre', 'autre') {
                    foreach ($ageAdmin in $null, 30, 300) {
                        foreach ($ageCache in $null, 30, 300) {
                            if (-not $admin -and ($variante -ne 'copie' -or $ageAdmin)) { continue }
                            Reset-Mindset; $script:Lancements.Clear()
                            Remove-Item -LiteralPath $dossierBascule -Recurse -Force -ErrorAction SilentlyContinue
                            New-Item -ItemType Directory -Force -Path (Join-Path $dossierBascule 'Mindset\fichiers') | Out-Null
                            $temp = Join-Path $dossierBascule 'temp'; New-Item -ItemType Directory -Force -Path $temp | Out-Null
                            $FauxScriptRoot = Join-Path $dossierBascule 'Mindset\fichiers'
                            $copie = Join-Path $dossierBascule 'Mindset'
                            $AppExe = Join-Path $copie 'Mindset.exe'
                            $script:Marquer = { param($t) $t.Replace($AppExe, 'EXE').Replace($copie.ToUpper(), 'COPIE-MAJUSCULES').Replace("$copie\", 'COPIE-BARRE').Replace($copie, 'COPIE').Replace('C:\Autre\Mindset', 'AUTRE') }
                            $script:Inscrit = switch ($variante) { 'aucun' { '' } 'copie' { $copie } 'copie-majuscules' { $copie.ToUpper() } 'copie-barre' { "$copie\" } 'autre' { 'C:\Autre\Mindset' } }
                            $mA = Join-Path $temp 'mindset-bascule-admin.marque'; $mC = Join-Path $temp 'mindset-rouvrir-cache.marque'
                            if ($null -ne $ageAdmin) { [IO.File]::WriteAllText($mA, '1'); (Get-Item -LiteralPath $mA).LastWriteTime = ([datetime]::Now).AddSeconds(-$ageAdmin) }
                            if ($null -ne $ageCache) { [IO.File]::WriteAllText($mC, '1'); (Get-Item -LiteralPath $mC).LastWriteTime = ([datetime]::Now).AddSeconds(-$ageCache) }
                            $EnTest = $false; $EstAdmin = $admin; $Desinstaller = $desinst; $Demarrage = $dem
                            $env:TEMP = $temp
                            try { . ([scriptblock]::Create($texteBascule)) } finally { $env:TEMP = $tempAvant }
                            $cas.Add([ordered]@{ admin = $admin; desinstaller = $desinst; demarrage = $dem; inscrit = $variante; age_admin = $ageAdmin; age_cache = $ageCache
                                lancements = $script:Lancements.ToArray(); sortie = $script:Sortie; demarrage_apres = [bool]$Demarrage
                                marque_admin = (Test-Path -LiteralPath $mA); marque_cache = (Test-Path -LiteralPath $mC) })
                        }
                    }
                }
            }
        }
    }
    $EnTest = $false; $EstAdmin = $false; $Desinstaller = $false; $Demarrage = $false
    Remove-Item function:Start-Process; Remove-Item function:Get-ItemProperty
    function Get-Date { param([string]$Format) if ($Format) { $script:Maintenant.ToString($Format) } else { $script:Maintenant } }
    Write-Juge 'bascule' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 14. Les jeux ajoutés dans Nevermind (Get-JeuxNevermind), la manette et le plein écran (natif.cs)
    # -----------------------------------------------------------------------------------------------------------
    $dn = Join-Path $tmp 'nevermind-donnees'
    New-Item -ItemType Directory -Force -Path $dn | Out-Null
    function Get-Appli([string]$Id) { if ($Id -eq 'nevermind') { [pscustomobject]@{ Id = 'nevermind'; Nom = 'Nevermind'; Donnees = $dn } } }
    function Get-DossierDonnees($Appli) { $Appli.Donnees }
    $contenus = @('{"CustomGames":[{"Name":"A","Exe":"C:\\Jeux\\a.exe"},{"Exe":"a.exe"},{"Exe":"D:\\x\\Jeu.EXE"},{"Exe":5},null,{"Exe":"C:\\Jeux\\b.exe\n"},{"Exe":"C:\\.exe"},{"Exe":"C:\\a.exe.bak"}]}',
        '{"CustomGames":{"Exe":"C:\\Seul\\seul.exe"}}', '{"Autre":1}', '{"CustomGames":[]}', '{"CustomGames":null}', 'pas du json', '{"CustomGames":["C:\\Jeux\\a.exe",{"exe":"C:\\Jeux\\c.exe"}]}',
        '{"CustomGames":[{"Exe":"\\\\serveur\\j.exe"},{"Exe":"c:/Jeux/d.exe"},{"Exe":"Z:\\é\\jeu.exe"}]}', '[]')
    $cas = New-Object Collections.Generic.List[object]
    foreach ($c in $contenus) {
        [IO.File]::WriteAllText((Join-Path $dn 'parametres.json'), $c, (New-Object Text.UTF8Encoding $false))
        $script:JeuxNevermindCle = ''
        $cas.Add([ordered]@{ contenu = $c; attendu = @(Get-JeuxNevermind) })
    }
    Write-Juge 'jeux-nevermind' $cas

    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $modules 'natif.cs'), [Text.Encoding]::UTF8))
    $cas = New-Object Collections.Generic.List[object]
    $axes = @(0, 7999, 8000, -7999, -8000, 23999, 24000, -24000, 32767, -32768, 100, -100)
    for ($i = 0; $i -lt 400; $i++) {
        $b = $rnd.Next(0, 65536); $g = $rnd.Next(0, 256); $d = @(0, 40, 41, 255)[$rnd.Next(0, 4)]
        $ax = @(1..4 | ForEach-Object { if ($rnd.Next(0, 2)) { $axes[$rnd.Next(0, $axes.Count)] } else { $rnd.Next(-32768, 32768) } })
        $cas.Add([ordered]@{ quoi = 'signature'; e = @($b, $g, $d) + $ax; attendu = [MSActivite]::Signature([uint16]$b, [byte]$g, [byte]$d, [int16]$ax[0], [int16]$ax[1], [int16]$ax[2], [int16]$ax[3]) })
    }
    for ($i = 0; $i -lt 300; $i++) {
        $v = @(1..8 | ForEach-Object { @(0, 1, -1, 1920, 1919, 1921, 1080, 1079, 3840, -10, 2560)[$rnd.Next(0, 11)] })
        $cas.Add([ordered]@{ quoi = 'ecran'; e = $v; attendu = [MSActivite]::CouvreEcran($v[0], $v[1], $v[2], $v[3], $v[4], $v[5], $v[6], $v[7]) })
    }
    Write-Juge 'activite' $cas

    # -----------------------------------------------------------------------------------------------------------
    # 15. Copy-ReglageVerif : « Chercher les nouvelles versions » coupé suit Mindset installé sur un autre disque
    # -----------------------------------------------------------------------------------------------------------
    $SuiteFileDir = Join-Path $tmp 'copie\Local\Mindset'
    $SettingsFile = Join-Path $tmp 'copie\Donnees\Mindset\reglages.json'
    $cas = New-Object Collections.Generic.List[object]
    foreach ($verifOn in '-', $true, $false) {
        foreach ($dossier in 'Mindset\Programmes\Mindset', 'Ailleurs\Mindset', 'mindset\programmes\Mindset', 'Programmes\Mindset') {
            foreach ($avant in $null, '{"MajAuto":false,"Theme":"rubis"}', 'abîmé', '{"VerifVersions":true}') {
                Reset-Mindset
                Remove-Item -LiteralPath (Join-Path $tmp 'copie') -Recurse -Force -ErrorAction SilentlyContinue
                if (-not ($verifOn -is [string])) { $script:Reglages['VerifVersions'] = $verifOn }
                $d = Join-Path (Join-Path $tmp 'copie') $dossier
                $cible = Join-Path (Join-Path (Get-RacinesDepuis $d).Donnees 'Mindset') 'reglages.json'
                if ($null -ne $avant) { New-Item -ItemType Directory -Force -Path (Split-Path $cible) | Out-Null; [IO.File]::WriteAllText($cible, $avant, (New-Object Text.UTF8Encoding $false)) }
                Copy-ReglageVerif $d
                $rel = $cible.Substring((Join-Path $tmp 'copie').Length + 1)
                $apres = if (Test-Path -LiteralPath $cible) { $t = [IO.File]::ReadAllText($cible, [Text.Encoding]::UTF8); try { ConvertFrom-Json $t } catch { $t } } else { $null }
                $cas.Add([ordered]@{ verif = $verifOn; dossier = $dossier; avant = $avant; fichier = $rel; apres = $apres })
            }
        }
    }
    Write-Juge 'copie-verif' $cas

    Write-Host 'Juges écrits.' -ForegroundColor Green
}
catch {
    Write-Host "Arrêt : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber) : $($_.InvocationInfo.Line.Trim()))" -ForegroundColor Red
    throw
}
finally {
    $env:SystemDrive = $systemDriveAvant
    [Threading.Thread]::CurrentThread.CurrentCulture = $cultureAvant
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
