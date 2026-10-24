# Mindset : où sont les programmes et les données, journal et réglages.
# Chargé par Mindset.ps1, qui définit $AppDir et $ModulesDir.
#
# Mindset s'installe sur le disque choisi à l'installation :
#   par défaut   programmes  C:\Program Files\Mindset\<Appli>      données  %LOCALAPPDATA%\Mindset\<Appli>
#   autre disque programmes  X:\Mindset\Programmes\<Appli>        données  X:\Mindset\Donnees\<Appli>
# L'emplacement se déduit toujours de celui du programme (protégé : seul un administrateur peut y écrire), jamais
# d'un fichier modifiable. suite.json (thème, applis gérées) reste toujours dans %LOCALAPPDATA%\Mindset.

$SuiteFileDir = Join-Path $env:LOCALAPPDATA 'Mindset'
# Mindset tourne-t-il en administrateur (lancé par sa tâche planifiée) ? Il peut alors accueillir Nevermind
$MindsetAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Racines d'une installation dont on connaît le dossier du programme Mindset (…\Mindset)
function Get-RacinesDepuis([string]$DossierMindset) {
    $p = Split-Path $DossierMindset -Parent; $m = Split-Path $p -Parent
    if ((Split-Path $p -Leaf) -eq 'Programmes' -and $m -and (Split-Path $m -Leaf) -eq 'Mindset') {
        return @{ Programmes = $p; Donnees = (Join-Path $m 'Donnees'); Disque = $m.Substring(0, 1).ToUpper() }
    }
    @{ Programmes = (Join-Path $env:ProgramFiles 'Mindset'); Donnees = $SuiteFileDir; Disque = '' }
}

# Ce Mindset est-il installé ? Sinon (lancé depuis le dossier téléchargé), celui inscrit dans « Applications
# installées » (écrit en administrateur) donne les racines ; sans installation, les racines par défaut.
$MonDossier = Split-Path $AppDir -Parent
$Racines = Get-RacinesDepuis $MonDossier
if ((Split-Path $MonDossier -Leaf) -ne 'Mindset' -or (Join-Path $Racines.Programmes 'Mindset') -ine $MonDossier) {
    $Racines = Get-RacinesDepuis 'C:\_\Mindset'   # (défaut)
    try {
        $inscrit = [string](Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset' -ErrorAction Stop).InstallLocation
        if ($inscrit -and (Test-Path -LiteralPath (Join-Path $inscrit 'Mindset.exe'))) { $Racines = Get-RacinesDepuis $inscrit }
    } catch {}
}
$RacineProgrammes = $Racines.Programmes
$SuiteDir = $Racines.Donnees
if ($EnTest -and $env:MINDSET_DONNEES) { $SuiteDir = $env:MINDSET_DONNEES; $SuiteFileDir = $env:MINDSET_DONNEES }
$DataDir = Join-Path $SuiteDir 'Mindset'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Premières versions : les fichiers de Mindset étaient à la racine de %LOCALAPPDATA%\Mindset
foreach ($n in 'journal.txt', 'reglages.json', 'installations.json') {
    foreach ($a in (Join-Path $SuiteFileDir $n), (Join-Path $SuiteFileDir "Mindset\$n")) {
        $b = Join-Path $DataDir $n
        if ($a -ine $b -and (Test-Path -LiteralPath $a) -and -not (Test-Path -LiteralPath $b)) { try { Move-Item -LiteralPath $a -Destination $DataDir } catch {} }
    }
}

$LogFile = Join-Path $DataDir 'journal.txt'
$SettingsFile = Join-Path $DataDir 'reglages.json'

function Write-Log([string]$Texte) {
    try { [IO.File]::AppendAllText($LogFile, "$((Get-Date).ToString('s')) $Texte`r`n", (New-Object Text.UTF8Encoding $false)) } catch {}
}

# Fichiers de données (réglages, installations, suite.json, historique des mises à jour) : jamais écrits directement.
# Le texte va dans un fichier à côté (.tmp), qui remplace l'ancien d'un coup ; l'ancien reste dans « .bak ». Un plantage
# ou une coupure de courant en pleine écriture laisse donc toujours un fichier entier : l'ancien ou le nouveau.
function Save-JsonSur([string]$Fichier, [string]$Texte) {
    $tmp = "$Fichier.tmp"
    try {
        [IO.File]::WriteAllText($tmp, $Texte, (New-Object Text.UTF8Encoding $false))
        for ($n = 1; ; $n++) {
            # (une appli qui lit le fichier au même moment peut bloquer le remplacement un court instant)
            try { if ([IO.File]::Exists($Fichier)) { [IO.File]::Replace($tmp, $Fichier, "$Fichier.bak") } else { [IO.File]::Move($tmp, $Fichier) }; break }
            catch { if ($n -ge 3) { throw }; Start-Sleep -Milliseconds 50 }
        }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# Le texte d'un fichier JSON, s'il contient bien un objet ; $null sinon (abîmé, vide, coupé en plein milieu)
function ConvertFrom-JsonObjet([string]$Texte) {
    try { $j = $Texte | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($j -is [System.Management.Automation.PSCustomObject]) { $j } else { $null }
}

# Lit un fichier écrit par Save-JsonSur. Abîmé : mis de côté (.abime-<date>, jamais effacé), noté au journal, et remplacé
# par sa copie .bak si elle est bonne. Rend $null s'il n'y a rien de bon à lire ; $script:JsonAbime donne alors le texte
# du fichier abîmé (sinon $null : il n'existait pas). Un fichier qu'un autre programme empêche de lire n'est pas abîmé :
# une erreur, pour que l'appelant ne reparte pas de zéro (il écraserait tout à la sauvegarde suivante).
function Read-JsonSur([string]$Fichier) {
    $script:JsonAbime = $null
    $nom = Split-Path $Fichier -Leaf
    $ecrire = -not $EnTest -or $env:MINDSET_DONNEES   # (un test sans dossier à part ne touche à aucun fichier)
    $texte = $null
    for ($n = 1; $n -le 3; $n++) {
        if (-not [IO.File]::Exists($Fichier)) { $texte = $null; break }
        try { $texte = [IO.File]::ReadAllText($Fichier, [Text.Encoding]::UTF8) }
        catch { if ($n -eq 3) { throw "$nom ne peut pas être lu ($($_.Exception.Message))" }; Start-Sleep -Milliseconds 50; continue }
        $j = ConvertFrom-JsonObjet $texte
        if ($null -ne $j) { return $j }
        if ($n -lt 3) { Start-Sleep -Milliseconds 50 }   # (peut-être en train d'être écrit par une autre appli : on relit)
    }
    if ($null -ne $texte) {
        $script:JsonAbime = $texte
        $de = "$Fichier.abime-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        if (-not $ecrire) { Write-Log "$nom abîmé (illisible)" }
        else {
            try { [IO.File]::Move($Fichier, $de); Write-Log "$nom abîmé (illisible) : mis de côté dans $(Split-Path $de -Leaf)" }
            catch { Write-Log "$nom abîmé (illisible), pas pu être mis de côté : $($_.Exception.Message)" }
        }
    }
    $bak = "$Fichier.bak"
    if ([IO.File]::Exists($bak)) {
        $j = $null
        try { $j = ConvertFrom-JsonObjet ([IO.File]::ReadAllText($bak, [Text.Encoding]::UTF8)) } catch {}
        if ($null -ne $j) {
            Write-Log "$nom $(if ($null -ne $texte) { 'abîmé' } else { 'absent' }) : repris de sa copie ($nom.bak)"
            if ($ecrire -and -not [IO.File]::Exists($Fichier)) {
                try { [IO.File]::Copy($bak, "$Fichier.tmp", $true); [IO.File]::Move("$Fichier.tmp", $Fichier) }
                catch { Write-Log "$nom non remis en place depuis sa copie : $($_.Exception.Message)" }
            }
            $script:JsonAbime = $null
            return $j
        }
        Write-Log "$nom : sa copie ($nom.bak) est illisible aussi"
    }
    if ($null -ne $texte) { Write-Log "$nom : aucune copie lisible, il repart de zéro" }
    $null
}

# Réglages : un simple fichier JSON, relu au démarrage
# Abîmé et sans copie lisible : ce qui s'y lit encore est repris, et dans le doute « Chercher les nouvelles versions » et
# « Mises à jour automatiques » restent coupés : jamais rallumés en silence si l'utilisateur les avait coupés.
$ReglagesPrudents = @('VerifVersions', 'MajAuto')
function Read-Reglages {
    $r = @{}
    $script:ReglagesIllisibles = $false; $script:ReglagesRepris = $false
    $j = $null
    try { $j = Read-JsonSur $SettingsFile }
    catch { Write-Log "Réglages : $($_.Exception.Message)"; $script:ReglagesIllisibles = $true }
    if ($null -ne $j) { foreach ($p in $j.PSObject.Properties) { $r[$p.Name] = $p.Value }; return $r }
    $abime = $script:JsonAbime
    if ($null -eq $abime -and -not $script:ReglagesIllisibles) { return $r }   # (pas encore de réglages : valeurs par défaut)
    if ($abime) {
        foreach ($m in [regex]::Matches($abime, '"(LancerAvecWindows|VerifVersions|MajAuto|ReduireHorloge|BulleHorlogeVue|DemarrageRepris)"\s*:\s*(true|false)\b')) { $r[$m.Groups[1].Value] = $m.Groups[2].Value -eq 'true' }
        foreach ($m in [regex]::Matches($abime, '"(Fermeture|Animations)"\s*:\s*"([a-z]{1,20})"')) { $r[$m.Groups[1].Value] = $m.Groups[2].Value }
        $m = [regex]::Match($abime, '"Demarrage"\s*:\s*(\[[^\]]*\]|"[a-z0-9-]+")')
        if ($m.Success) { $r['Demarrage'] = @([regex]::Matches($m.Groups[1].Value, '"([a-z0-9-]{1,30})"') | ForEach-Object { $_.Groups[1].Value }) }
        if ($r.Count) { Write-Log "Réglages repris du fichier abîmé : $(@($r.Keys | Sort-Object) -join ', ')" }
    }
    foreach ($n in $ReglagesPrudents) {
        if (-not $r.ContainsKey($n)) { $r[$n] = $false; Write-Log "Réglage $n perdu : coupé par prudence (il se rallume dans les Paramètres)" }
    }
    $script:ReglagesRepris = $true
    $r
}
$script:Settings = Read-Reglages
$script:ReglagesChanges = @{}
# (repris d'un fichier abîmé : écrit tout de suite, sinon au prochain lancement les valeurs par défaut reviendraient)
if ($script:ReglagesRepris -and -not $script:ReglagesIllisibles -and (-not $EnTest -or $env:MINDSET_DONNEES)) {
    try { Save-JsonSur $SettingsFile ($script:Settings | ConvertTo-Json -Depth 5) } catch { Write-Log "Réglages non enregistrés : $($_.Exception.Message)" }
}

function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Settings.ContainsKey($Nom)) { $script:Settings[$Nom] } else { $Defaut } }

function Set-Setting([string]$Nom, $Valeur) {
    $script:Settings[$Nom] = $Valeur
    $script:ReglagesChanges[$Nom] = $true
    if ($EnTest) { return }
    # reglages.json n'a pas pu être lu au démarrage (pris par un autre programme) : relu avant d'écrire, pour ne pas
    # remplacer les réglages de l'utilisateur par les valeurs par défaut
    if ($script:ReglagesIllisibles) {
        $relus = Read-Reglages
        if ($script:ReglagesIllisibles) { Write-Log "Réglages non enregistrés : reglages.json ne peut toujours pas être lu"; return }
        foreach ($k in $script:ReglagesChanges.Keys) { $relus[$k] = $script:Settings[$k] }
        $script:Settings = $relus
    }
    try { Save-JsonSur $SettingsFile ($script:Settings | ConvertTo-Json -Depth 5) }
    catch { Write-Log "Réglages non enregistrés : $($_.Exception.Message)" }
}

# Mindset lui-même se lance-t-il avec Windows ? (oui tant que l'utilisateur ne l'a pas coupé dans les Paramètres ;
# lu par Mindset.ps1 juste après ce module, avant que la fenêtre et l'icône près de l'horloge n'existent)
function Get-LancerAvecWindows { [bool](Get-Setting 'LancerAvecWindows' $true) }
function Set-LancerAvecWindows([bool]$Oui) { Set-Setting 'LancerAvecWindows' $Oui }
