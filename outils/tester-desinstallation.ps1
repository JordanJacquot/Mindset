# Mindset : tests du désinstalleur autonome (Desinstaller Mindset.exe, compilé depuis outils\desinstalleur.cs).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-desinstallation.ps1
#
# Même petit outil que tester-securite.ps1 (Test-Cas). Code de sortie 1 si un cas échoue (pour la CI de GitHub).
#
# Tout se passe dans un faux environnement : le désinstalleur est lancé avec -Test <fichier>, qui remplace
#   Program Files, %LOCALAPPDATA%, le Bureau, le menu Démarrer, le dossier temporaire et les disques par des dossiers
#   sous %TEMP%\mindset-desinst-..., le registre (HKLM et HKCU) par HKCU\Software\MindsetTest-<n°>, et le dossier de
#   tâches « \Mindset\ » par « \MindsetTest-<n°>\ » (tâches sans déclencheur, qui ne lancent jamais rien).
# Aucun droit administrateur, aucune demande de Windows, aucun réseau. La fenêtre du désinstalleur s'ouvre hors de l'écran
# sans prendre la main. Les seuls programmes fermés sont les faux programmes lancés ici. Tout est retiré à la fin.
#
# Ce qui est vérifié (critères de l'issue #1) :
#   - tout est retiré (tâches, clés, valeur Run, raccourcis, programmes, X:\Mindset vide), même sans Mindset.ps1 ;
#   - les données sont gardées quand la case est décochée (elle l'est au départ), supprimées quand elle est cochée ;
#   - le désinstalleur d'une appli est lancé ; s'il échoue, la désinstallation continue et le signale ;
#   - il reçoit le choix de la case (-GarderDonnees ou -SupprimerDonnees, issue #2) ; une ancienne version qui supprime
#     quand même ses données est repérée, et le message de fin le dit ;
#   - Mindset (bouton Désinstaller d'une carte) dit à la fin si les données de l'appli sont gardées ou supprimées ;
#   - un échec d'une étape est affiché avec ce qui reste à retirer, et la désinstallation peut être relancée ;
#   - -Nettoyer marche sur une installation à moitié cassée, deux fois de suite (idempotent) ;
#   - un lien (point de jonction) dans les données n'est jamais suivi.

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$NomExe = 'Desinstaller Mindset.exe'

# ---------------------------------------------------------------------------------------------------------------
# Le petit outil de test (le même que tester-securite.ps1)
# ---------------------------------------------------------------------------------------------------------------
$script:Reussis = 0
$script:Echoues = @()
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
    }
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

# ---------------------------------------------------------------------------------------------------------------
# Préparation : dossier temporaire, noms de test pour le registre et les tâches, programmes compilés
# ---------------------------------------------------------------------------------------------------------------
$id = [guid]::NewGuid().ToString('N')
$tmp = Join-Path $env:TEMP "mindset-desinst-$($id.Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = [IO.Path]::GetFullPath($tmp)   # (en nom long : sur GitHub, TEMP est en nom court « RUNNER~1 »)
$CleTest = "Software\MindsetTest-$id"
$TachesTest = "\MindsetTest-$id"
$marques = Join-Path $tmp 'marques'
New-Item -ItemType Directory -Force -Path $marques | Out-Null
$env:MINDSET_TEST_MARQUES = $marques   # (les faux désinstalleurs d'applis y notent leur passage)
$script:Processus = @()                # faux programmes lancés ici (fermés à la fin s'ils tournent encore)
$script:Verrous = @()                  # fichiers tenus ouverts pour faire échouer une étape

function Get-Texte([string]$Chemin) { [IO.File]::ReadAllText($Chemin, [Text.Encoding]::UTF8) }
function Save-Fichier([string]$Chemin, [string]$Contenu) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Chemin -Parent) | Out-Null
    [IO.File]::WriteAllText($Chemin, $Contenu, (New-Object Text.UTF8Encoding $false))
}

# Le service des tâches planifiées (pour créer les fausses tâches et vérifier qu'elles sont parties)
$script:Planificateur = New-Object -ComObject Schedule.Service
$script:Planificateur.Connect()
function Test-DossierTachesPresent {
    try { [void]$script:Planificateur.GetFolder($TachesTest); $true } catch { $false }
}
function Remove-DossierTachesTest {
    try { $f = $script:Planificateur.GetFolder($TachesTest) } catch { return }
    foreach ($t in @($f.GetTasks(1))) { try { $f.DeleteTask($t.Name, 0) } catch {} }
    try { $script:Planificateur.GetFolder('\').DeleteFolder($TachesTest.TrimStart('\'), 0) } catch {}
}

try {
    Write-Partie 'Préparation'
    $outils = Join-Path $tmp 'outils'
    New-Item -ItemType Directory -Force -Path $outils | Out-Null
    $desinstalleur = Join-Path $outils $NomExe
    # Compilé comme dans construire.ps1
    $sortie = & $csc /nologo /target:winexe /optimize+ /platform:anycpu "/win32manifest:$(Join-Path $PSScriptRoot 'desinstalleur.manifest')" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll /reference:System.Core.dll "/out:$desinstalleur" (Join-Path $PSScriptRoot 'desinstalleur.cs')
    Test-Cas 'Le désinstalleur se compile' { $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $desinstalleur) }
    if ($LASTEXITCODE) { $sortie | Write-Host; throw 'Compilation impossible.' }

    # Un faux programme : nommé « ...sinstaller ... », il joue un désinstalleur d'appli (efface les .exe de son dossier,
    # ou échoue si son nom contient « Autre ») ; sinon il attend 10 minutes sans rien faire (un Mindset qui tourne).
    # Il note ses options dans sa marque, et fait comme Nevermind pour ses données (<LocalAppData>\Mindset\<Appli>) :
    # supprimées avec -SupprimerDonnees, gardées sinon ; toujours supprimées si MINDSET_TEST_ANCIEN=1 (ancienne version)
    $sourceFaux = Join-Path $outils 'faux.cs'
    Save-Fichier $sourceFaux @'
using System; using System.IO; using System.Threading;
static class Faux {
    static int Main() {
        string moi = System.Reflection.Assembly.GetEntryAssembly().Location;
        string nom = Path.GetFileNameWithoutExtension(moi);
        if (nom.IndexOf("sinstaller", StringComparison.OrdinalIgnoreCase) < 0) { Thread.Sleep(600000); return 0; }
        string marques = Environment.GetEnvironmentVariable("MINDSET_TEST_MARQUES");
        string[] options = Environment.GetCommandLineArgs();
        string recu = string.Join(" ", options, 1, options.Length - 1);
        if (!string.IsNullOrEmpty(marques)) File.WriteAllText(Path.Combine(marques, nom + ".txt"), "lancé " + recu);
        if (nom.IndexOf("Autre", StringComparison.OrdinalIgnoreCase) >= 0) return 3;
        string dossier = Path.GetDirectoryName(moi);
        string env = Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(dossier)));
        string donnees = Path.Combine(Path.Combine(Path.Combine(env, "LocalAppData"), "Mindset"), Path.GetFileName(dossier));
        if ((recu.Contains("-SupprimerDonnees") || Environment.GetEnvironmentVariable("MINDSET_TEST_ANCIEN") == "1") && Directory.Exists(donnees))
            Directory.Delete(donnees, true);
        foreach (string f in Directory.GetFiles(Path.GetDirectoryName(moi), "*.exe"))
            if (!string.Equals(f, moi, StringComparison.OrdinalIgnoreCase)) File.Delete(f);
        return 0;
    }
}
'@
    $faux = Join-Path $outils 'faux.exe'
    & $csc /nologo /target:winexe "/out:$faux" $sourceFaux | Out-Null
    if ($LASTEXITCODE) { throw 'Compilation du faux programme impossible.' }

    # -------------------------------------------------------------------------------------------------------------
    # Un faux environnement complet : $Nom sous $tmp. Retourne ses chemins.
    #   -SansProgrammeC : rien dans Program Files (installation à moitié cassée)
    #   -Script 'absent' | 'abime' | 'normal' : fichiers\Mindset.ps1
    # -------------------------------------------------------------------------------------------------------------
    function New-Environnement([string]$Nom, [string]$Script = 'absent', [switch]$SansProgrammeC, [switch]$AppsAbime, [switch]$SansCleDesinstall) {
        $e = @{ Dossier = (Join-Path $tmp $Nom) }
        foreach ($k in 'ProgramFiles', 'LocalAppData', 'Bureau', 'Menu', 'Temp', 'DisqueX') { $e[$k] = Join-Path $e.Dossier $k; New-Item -ItemType Directory -Force -Path $e[$k] | Out-Null }
        $e.RacineC = Join-Path $e.ProgramFiles 'Mindset'
        $e.Mindset = Join-Path $e.RacineC 'Mindset'
        $e.Exe = Join-Path $e.Mindset $NomExe
        $e.RacineX = Join-Path $e.DisqueX 'Mindset'
        $apps = '[{"id":"appli","nom":"Appli","exe":"Appli.exe","desinstalleur":"Désinstaller Appli.exe"},' +
                '{"id":"autre","nom":"Autre","exe":"Autre.exe","desinstalleur":"Désinstaller Autre.exe"},' +
                '{"id":"evermind","nom":"Evermind","exe":"Evermind.exe"}]'
        if ($AppsAbime) { $apps = '[{"id": "appli", "nom": ' }
        if (-not $SansProgrammeC) {
            New-Item -ItemType Directory -Force -Path (Join-Path $e.Mindset 'fichiers\modules') | Out-Null
            Copy-Item -LiteralPath $faux -Destination (Join-Path $e.Mindset 'Mindset.exe') -Force
            Copy-Item -LiteralPath $desinstalleur -Destination $e.Exe -Force
            Save-Fichier (Join-Path $e.Mindset 'fichiers\apps.json') $apps
            Save-Fichier (Join-Path $e.Mindset 'fichiers\modules\donnees.ps1') '# module'
            if ($Script -eq 'normal') { Save-Fichier (Join-Path $e.Mindset 'fichiers\Mindset.ps1') "# Mindset`r`n" }
            if ($Script -eq 'abime') { Save-Fichier (Join-Path $e.Mindset 'fichiers\Mindset.ps1') "param([switch]`$Demarrage`r`n{{{ ceci n'est pas du PowerShell" }
            foreach ($a in 'Appli', 'Autre') {
                New-Item -ItemType Directory -Force -Path (Join-Path $e.RacineC $a) | Out-Null
                Copy-Item -LiteralPath $faux -Destination (Join-Path $e.RacineC "$a\$a.exe") -Force
                Copy-Item -LiteralPath $faux -Destination (Join-Path $e.RacineC "$a\Désinstaller $a.exe") -Force
                Save-Fichier (Join-Path $e.RacineC "$a\fichiers\$a.ps1") "`$AppVersion = '1.0.0'"
            }
            Save-Fichier (Join-Path $e.RacineC 'Evermind\Evermind.exe') 'programme'
            Save-Fichier (Join-Path $e.RacineC 'Evermind\fichiers\Evermind.ps1') "`$AppVersion = '1.0.0'"
            # Un fichier en lecture seule (Windows refuse de le supprimer tel quel)
            Save-Fichier (Join-Path $e.Mindset 'LISEZMOI.txt') 'Lis-moi'
            Set-ItemProperty -LiteralPath (Join-Path $e.Mindset 'LISEZMOI.txt') -Name IsReadOnly -Value $true
        }
        # Autre disque : X:\Mindset\Programmes et X:\Mindset\Donnees
        Save-Fichier (Join-Path $e.RacineX 'Programmes\Mindset\fichiers\apps.json') $apps
        Save-Fichier (Join-Path $e.RacineX 'Programmes\Mindset\Mindset.exe') 'programme'
        Save-Fichier (Join-Path $e.RacineX 'Donnees\Mindset\reglages.json') '{}'
        Save-Fichier (Join-Path $e.RacineX 'Donnees\Evermind\rendez-vous.json') '[]'
        # Données sur C: : suite.json, réglages, rendez-vous, téléchargements en cours
        $e.Donnees = Join-Path $e.LocalAppData 'Mindset'
        Save-Fichier (Join-Path $e.Donnees 'suite.json') '{"theme":"neon"}'
        Save-Fichier (Join-Path $e.Donnees 'Mindset\reglages.json') '{}'
        Save-Fichier (Join-Path $e.Donnees 'Mindset\installation.demande') '{}'
        Save-Fichier (Join-Path $e.Donnees 'Mindset\telechargements\appli.zip') 'zip'
        Save-Fichier (Join-Path $e.Donnees 'Evermind\rendez-vous.json') '[]'
        Save-Fichier (Join-Path $e.Donnees 'Appli\parametres.json') '{}'   # (gardées ou supprimées par le désinstalleur de l'appli)
        # Un point de jonction dans les données, vers un dossier précieux hors de Mindset : jamais suivi
        $e.Precieux = Join-Path $e.Dossier 'precieux'
        Save-Fichier (Join-Path $e.Precieux 'important.txt') 'à garder'
        $null = & "$env:SystemRoot\System32\cmd.exe" /c mklink /J "$(Join-Path $e.Donnees 'Mindset\lien')" "$($e.Precieux)" 2>&1
        # Raccourcis (celui d'un autre programme doit rester)
        foreach ($d in $e.Bureau, $e.Menu) { Save-Fichier (Join-Path $d 'Mindset.lnk') 'raccourci' }
        Save-Fichier (Join-Path $e.Bureau 'Autre programme.lnk') 'raccourci'
        # Registre de test
        $r = "HKCU:\$CleTest"
        Remove-Item -Path $r -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $SansCleDesinstall) {
            New-Item -Path "$r\Uninstall\Mindset" -Force | Out-Null
            Set-ItemProperty -Path "$r\Uninstall\Mindset" -Name InstallLocation -Value $e.Mindset
            Set-ItemProperty -Path "$r\Uninstall\Mindset" -Name UninstallString -Value "`"$(Join-Path $e.Mindset 'Mindset.exe')`" -Desinstaller"
        }
        New-Item -Path "$r\Mindset\Installation" -Force | Out-Null
        Set-ItemProperty -Path "$r\Mindset\Installation" -Name Resultat -Value '{"id":"1","ok":true}'
        New-Item -Path "$r\Run" -Force | Out-Null
        Set-ItemProperty -Path "$r\Run" -Name Mindset -Value "`"$(Join-Path $e.Mindset 'Mindset.exe')`" -Demarrage"
        Set-ItemProperty -Path "$r\Run" -Name 'Autre programme' -Value 'autre.exe'
        # Tâches de test : sans déclencheur, désactivées, pour l'utilisateur sans droits (elles ne lancent jamais rien)
        Remove-DossierTachesTest
        $act = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/c exit'
        $pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        $set = New-ScheduledTaskSettingsSet -Disable
        foreach ($t in 'Mindset (démarrage)', 'Mindset (installation)', 'Appli (aide)') {
            Register-ScheduledTask -TaskPath "$TachesTest\" -TaskName $t -Action $act -Principal $pr -Settings $set -Force | Out-Null
        }
        # Le fichier de test lu par le désinstalleur
        $e.Config = Join-Path $e.Dossier 'test.json'
        Save-Fichier $e.Config (ConvertTo-Json -Compress -InputObject ([ordered]@{
            ProgramFiles = $e.ProgramFiles; LocalAppData = $e.LocalAppData; Bureau = $e.Bureau; Menu = $e.Menu; Temp = $e.Temp
            Disques = @($e.DisqueX); Registre = $CleTest; Taches = $TachesTest }))
        $e
    }

    # Lance le désinstalleur sur un faux environnement et attend son bilan (écrit par la copie temporaire, à la fin)
    function Invoke-Desinstalleur($E, [string]$Exe, [string[]]$Options) {
        $rap = Join-Path $E.Dossier "rapport-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
        $a = @('-Test', "`"$($E.Config)`"", '-Rapport', "`"$rap`"") + $Options
        $p = Start-Process -FilePath $Exe -ArgumentList $a -PassThru -WorkingDirectory $env:SystemRoot
        $limite = (Get-Date).AddSeconds(180)
        while (-not (Test-Path -LiteralPath $rap) -and (Get-Date) -lt $limite) { Start-Sleep -Milliseconds 200 }
        if (-not (Test-Path -LiteralPath $rap)) { throw "Pas de bilan au bout de 3 minutes ($Exe)" }
        [void]$p.WaitForExit(10000)
        Get-Texte $rap | ConvertFrom-Json
    }
    function Test-Absent([string]$Chemin) { -not (Test-Path -LiteralPath $Chemin) }
    function Test-Valeur([string]$Cle, [string]$Nom) { $null -ne (Get-ItemProperty -Path $Cle -Name $Nom -ErrorAction SilentlyContinue) }
    function Test-ToutRetire($E) {
        (Test-Absent $E.RacineC) -and (Test-Absent (Join-Path $E.RacineX 'Programmes')) -and -not (Test-DossierTachesPresent) -and
        (Test-Absent "HKCU:\$CleTest\Uninstall\Mindset") -and (Test-Absent "HKCU:\$CleTest\Mindset") -and -not (Test-Valeur "HKCU:\$CleTest\Run" 'Mindset') -and
        (Test-Absent (Join-Path $E.Bureau 'Mindset.lnk')) -and (Test-Absent (Join-Path $E.Menu 'Mindset.lnk'))
    }
    Test-Cas 'Le faux environnement se prépare (tâches de test comprises)' { $e0 = New-Environnement 'essai'; (Test-DossierTachesPresent) -and (Test-Path -LiteralPath $e0.Exe) }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Désinstallation par la fenêtre, case laissée telle quelle (sans fichiers\Mindset.ps1)'
    # -------------------------------------------------------------------------------------------------------------
    $e = New-Environnement 'fenetre' -Script 'absent'
    $mindsetOuvert = Start-Process -FilePath (Join-Path $e.Mindset 'Mindset.exe') -PassThru
    $script:Processus += $mindsetOuvert
    Remove-Item -LiteralPath (Join-Path $marques '*') -Force -ErrorAction SilentlyContinue
    $b = Invoke-Desinstalleur $e $e.Exe @('-EssaiFenetre', '0')
    Test-Cas 'Le bilan est bon (rien ne reste)' { $b.ok -eq $true -and @($b.restes).Count -eq 0 }
    Test-Cas 'La case « Supprimer aussi mes données » est décochée au départ' { $b.caseDonneesAuDepart -eq $false -and $b.donneesSupprimees -eq $false }
    Test-Cas 'Mindset qui tournait est fermé' { $mindsetOuvert.WaitForExit(5000) }
    Test-Cas 'Tout est retiré : programmes (C: et X:), tâches, registre, lancement avec Windows, raccourcis' { Test-ToutRetire $e }
    Test-Cas 'Ce qui ne vient pas de Mindset reste (autre valeur Run, autre raccourci)' { (Test-Valeur "HKCU:\$CleTest\Run" 'Autre programme') -and (Test-Path -LiteralPath (Join-Path $e.Bureau 'Autre programme.lnk')) }
    Test-Cas 'Les données sont gardées (réglages, rendez-vous, suite.json, sur C: et sur X:)' {
        (Test-Path -LiteralPath (Join-Path $e.Donnees 'suite.json')) -and (Test-Path -LiteralPath (Join-Path $e.Donnees 'Mindset\reglages.json')) -and
        (Test-Path -LiteralPath (Join-Path $e.Donnees 'Evermind\rendez-vous.json')) -and (Test-Path -LiteralPath (Join-Path $e.RacineX 'Donnees\Evermind\rendez-vous.json'))
    }
    Test-Cas 'Les téléchargements en cours et la demande d''installation sont retirés' { (Test-Absent (Join-Path $e.Donnees 'Mindset\telechargements')) -and (Test-Absent (Join-Path $e.Donnees 'Mindset\installation.demande')) }
    Test-Cas 'Le désinstalleur de l''appli a été lancé' { Test-Path -LiteralPath (Join-Path $marques 'Désinstaller Appli.txt') }
    Test-Cas 'Case décochée : il reçoit -GarderDonnees (il ne pose pas la question)' { (Get-Texte (Join-Path $marques 'Désinstaller Appli.txt')) -eq 'lancé -GarderDonnees' }
    Test-Cas 'Case décochée : les données de l''appli sont gardées, et le bilan ne dit rien d''autre' {
        (Test-Path -LiteralPath (Join-Path $e.Donnees 'Appli\parametres.json')) -and @($b.donneesSupprimeesPar).Count -eq 0 -and $b.texteAffiche -match 'tu retrouveras tout' -and $b.texteAffiche -notmatch 'sauf'
    }
    Test-Cas 'Le désinstalleur d''appli qui échoue est signalé à l''écran, et la désinstallation a continué' {
        (Test-Path -LiteralPath (Join-Path $marques 'Désinstaller Autre.txt')) -and (@($b.alertes) -match 'Autre').Count -eq 1 -and $b.texteAffiche -match 'Autre' -and (Test-Absent (Join-Path $e.RacineC 'Autre'))
    }
    Test-Cas 'Le texte affiché dit que Mindset est désinstallé et que les données sont gardées' { $b.texteAffiche -match 'Mindset est désinstallé' -and $b.texteAffiche -match 'données sont gardées' }
    Test-Cas 'Le désinstalleur lui-même est parti' { Test-Absent $e.Exe }
    Test-Cas 'X:\Mindset reste, avec seulement les données' { @(Get-ChildItem -LiteralPath $e.RacineX -Force | ForEach-Object Name) -join ',' -eq 'Donnees' }
    Test-Cas 'Sa copie temporaire se supprime après coup' {
        $limite = (Get-Date).AddSeconds(15)
        while (@(Get-ChildItem -LiteralPath $e.Temp -Directory -Filter 'Mindset-desinstallation-*').Count -and (Get-Date) -lt $limite) { Start-Sleep -Milliseconds 300 }
        @(Get-ChildItem -LiteralPath $e.Temp -Directory -Filter 'Mindset-desinstallation-*').Count -eq 0
    }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Une étape échoue : affichée avec ce qui reste, puis la désinstallation se relance (Mindset.ps1 abîmé)'
    # -------------------------------------------------------------------------------------------------------------
    $e = New-Environnement 'echec' -Script 'abime'
    $bloque = Join-Path $e.RacineC 'Evermind\Evermind.exe'
    $script:Verrous += [IO.File]::Open($bloque, 'Open', 'Read', 'None')   # (comme un programme encore ouvert)
    $b = Invoke-Desinstalleur $e $e.Exe @('-EssaiFenetre', '1')
    Test-Cas 'Le bilan signale l''échec' { $b.ok -eq $false -and @($b.restes).Count -ge 1 }
    Test-Cas 'Le texte affiché dit ce qui reste à retirer et quoi faire' {
        $b.texteAffiche -match 'pas pu être retirés' -and $b.texteAffiche -match [regex]::Escape($e.RacineC) -and $b.texteAffiche -match 'Evermind\.exe' -and $b.texteAffiche -match 'relance'
    }
    Test-Cas 'Le reste a quand même été retiré (tâches, registre, raccourcis, autre disque)' {
        -not (Test-DossierTachesPresent) -and (Test-Absent "HKCU:\$CleTest\Mindset") -and -not (Test-Valeur "HKCU:\$CleTest\Run" 'Mindset') -and
        (Test-Absent (Join-Path $e.Bureau 'Mindset.lnk')) -and (Test-Absent (Join-Path $e.RacineX 'Programmes'))
    }
    Test-Cas 'Case cochée : le désinstalleur de l''appli reçoit -SupprimerDonnees' { (Get-Texte (Join-Path $marques 'Désinstaller Appli.txt')) -eq 'lancé -SupprimerDonnees' }
    Test-Cas 'Case cochée : les données sont supprimées' { $b.donneesSupprimees -eq $true -and (Test-Absent $e.Donnees) -and (Test-Absent (Join-Path $e.RacineX 'Donnees')) }
    Test-Cas 'Le lien dans les données n''a pas été suivi (le dossier visé est intact)' { Test-Path -LiteralPath (Join-Path $e.Precieux 'important.txt') }
    Test-Cas 'Le désinstalleur et l''entrée « Applications installées » restent, pour relancer' {
        (Test-Path -LiteralPath $e.Exe) -and (Get-ItemProperty -Path "HKCU:\$CleTest\Uninstall\Mindset" -Name UninstallString).UninstallString -eq "`"$($e.Exe)`""
    }
    foreach ($v in $script:Verrous) { $v.Dispose() }
    $script:Verrous = @()
    $b = Invoke-Desinstalleur $e $e.Exe @('-Nettoyer', '-SupprimerDonnees', '-Silencieux')
    Test-Cas 'Relancé une fois le fichier libéré : tout est retiré' { $b.ok -eq $true -and (Test-ToutRetire $e) -and (Test-Absent $e.Exe) }
    Test-Cas 'X:\Mindset, vide, est retiré aussi' { Test-Absent $e.RacineX }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Une ancienne version d''appli supprime ses données malgré la case décochée : le bilan le dit'
    # -------------------------------------------------------------------------------------------------------------
    $e = New-Environnement 'ancien' -Script 'normal'
    $env:MINDSET_TEST_ANCIEN = '1'
    try { $b = Invoke-Desinstalleur $e $e.Exe @('-EssaiFenetre', '0') } finally { Remove-Item env:MINDSET_TEST_ANCIEN -ErrorAction SilentlyContinue }
    Test-Cas 'Ses données sont bien parties (ancienne version)' { Test-Absent (Join-Path $e.Donnees 'Appli') }
    Test-Cas 'Le bilan note l''appli dont les données ont été supprimées' { (@($b.donneesSupprimeesPar) -join ',') -eq 'Appli' }
    Test-Cas 'Le texte affiché le dit, au lieu de « tu retrouveras tout »' {
        $b.texteAffiche -match 'sauf celles de Appli, que son désinstalleur a supprimées' -and $b.texteAffiche -notmatch 'tu retrouveras tout'
    }
    Test-Cas 'Les autres données restent' { (Test-Path -LiteralPath (Join-Path $e.Donnees 'Evermind\rendez-vous.json')) -and (Test-Path -LiteralPath (Join-Path $e.Donnees 'Mindset\reglages.json')) }
    $b = Invoke-Desinstalleur (New-Environnement 'ancien-coche' -Script 'normal') $desinstalleur @('-Nettoyer', '-Silencieux', '-SupprimerDonnees')
    Test-Cas 'Données supprimées à la demande : rien de spécial à dire' { @($b.donneesSupprimeesPar).Count -eq 0 }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Nettoyage de secours (-Nettoyer) sur une installation à moitié cassée'
    # -------------------------------------------------------------------------------------------------------------
    # Rien dans Program Files, apps.json abîmé, pas d'entrée « Applications installées » ; lancé depuis un autre dossier
    $e = New-Environnement 'secours' -SansProgrammeC -AppsAbime -SansCleDesinstall
    $b = Invoke-Desinstalleur $e $desinstalleur @('-Nettoyer', '-Silencieux')
    Test-Cas 'Il retire ce qui reste, sans planter' { $b.ok -eq $true -and (Test-ToutRetire $e) }
    Test-Cas 'Sans -SupprimerDonnees, les données restent' { (Test-Path -LiteralPath (Join-Path $e.Donnees 'Mindset\reglages.json')) -and (Test-Path -LiteralPath (Join-Path $e.RacineX 'Donnees\Mindset\reglages.json')) }
    $b = Invoke-Desinstalleur $e $desinstalleur @('-Nettoyer', '-Silencieux')
    Test-Cas 'Relancé : rien à faire, aucune erreur (idempotent)' { $b.ok -eq $true -and @($b.restes).Count -eq 0 -and @($b.faits).Count -eq 0 }
    $b = Invoke-Desinstalleur $e $desinstalleur @('-Nettoyer', '-Silencieux', '-SupprimerDonnees')
    Test-Cas 'Avec -SupprimerDonnees : plus aucun dossier Mindset, sur aucun disque' { $b.ok -eq $true -and (Test-Absent $e.Donnees) -and (Test-Absent $e.RacineX) -and (Test-Absent $e.RacineC) }
    Test-Cas 'Le lien dans les données n''a pas été suivi' { Test-Path -LiteralPath (Join-Path $e.Precieux 'important.txt') }
    Test-Cas 'Le désinstalleur lancé hors des programmes est gardé' { Test-Path -LiteralPath $desinstalleur }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Mindset passe par le désinstalleur'
    # -------------------------------------------------------------------------------------------------------------
    $admin = Get-Texte (Join-Path $fichiers 'installer-admin.ps1')
    Test-Cas 'L''installation le copie et l''inscrit dans « Applications installées »' { $admin -match [regex]::Escape("'$NomExe'") -and $admin -match 'UninstallString' }
    Test-Cas 'construire.ps1 le compile' { (Get-Texte (Join-Path $PSScriptRoot 'construire.ps1')) -match 'desinstalleur\.cs' }
    Test-Cas 'Mindset.exe -Desinstaller le lance (même sans Mindset.ps1)' { (Get-Texte (Join-Path $PSScriptRoot 'lanceur.cs')) -match [regex]::Escape($NomExe) }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Désinstaller une seule appli depuis Mindset : le message de fin dit ce qui a été fait'
    # -------------------------------------------------------------------------------------------------------------
    # Complete-Desinstallation lue dans installations.ps1 et lancée sur un faux dossier de données ; ce qu'elle appelle
    # d'autre est remplacé par une fausse version (rien n'est écrit ailleurs)
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $fichiers 'modules\installations.ps1'), [ref]$tok, [ref]$err)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Complete-Desinstallation' }, $false)
    Test-Cas 'Complete-Desinstallation est lisible' { -not $err -and $null -ne $fn }
    $script:MessageFin = $null
    function Save-Installation { }
    function Set-SuiteAppli { }
    function Set-DemarrageAppli { }
    function Write-Log { }
    function Stop-Operation($Appli, [string]$Message) { $script:MessageFin = $Message }
    Invoke-Expression $fn.Extent.Text
    $SuiteDir = Join-Path $tmp 'suite'
    $appli = [pscustomobject]@{ Id = 'appli'; Nom = 'Appli' }
    Save-Fichier (Join-Path $SuiteDir 'Appli\journal.txt') 'gardé'
    Complete-Desinstallation $appli
    Test-Cas 'Données gardées par le désinstalleur : « Ses données sont gardées dans ... »' { $script:MessageFin -match 'Ses données sont gardées dans' -and $script:MessageFin -match [regex]::Escape((Join-Path $SuiteDir 'Appli')) }
    Remove-Item -LiteralPath (Join-Path $SuiteDir 'Appli') -Recurse -Force
    Complete-Desinstallation $appli
    Test-Cas 'Données supprimées par le désinstalleur : « désinstallé, avec ses données »' { $script:MessageFin -match 'désinstallé, avec ses données' -and $script:MessageFin -notmatch 'gardées' }
    $accueil = Get-Texte (Join-Path $fichiers 'modules\accueil.ps1')
    Test-Cas 'La confirmation annonce que le désinstalleur de l''appli demande si les données sont gardées' { $accueil -match 'Il te demande aussi si tu gardes tes données' }
}
catch {
    $script:Echoues += "Arrêt inattendu : $($_.Exception.Message)"
    Write-Host "  ÉCHEC  Arrêt inattendu : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
}
finally {
    # Tout ce que le test a créé est retiré : fichiers ouverts, faux programmes, tâches, clé du registre, dossier
    foreach ($v in $script:Verrous) { try { $v.Dispose() } catch {} }
    foreach ($p in $script:Processus) { try { if (-not $p.HasExited) { $p.Kill() } } catch {} }
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($p.Path -and $p.Path.StartsWith("$tmp\", [StringComparison]::OrdinalIgnoreCase)) { $p.Kill(); [void]$p.WaitForExit(3000) } } catch {}
    }
    Remove-DossierTachesTest
    Remove-Item -Path "HKCU:\$CleTest" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:MINDSET_TEST_MARQUES -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    # (rd ne suit pas les points de jonction, contrairement à Remove-Item -Recurse de PowerShell 5.1)
    $null = & "$env:SystemRoot\System32\cmd.exe" /c rd /s /q "$tmp" 2>&1
}

Write-Host ''
$total = $script:Reussis + $script:Echoues.Count
if ($script:Echoues.Count) {
    Write-Host "$($script:Echoues.Count) échec(s) sur $total cas :" -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Les $total cas sont réussis." -ForegroundColor Green
exit 0
