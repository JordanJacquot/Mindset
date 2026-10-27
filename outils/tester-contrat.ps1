# Mindset : le contrat entre Mindset et une appli (docs\contrat-appli.md), vérifié avec l'appli témoin (temoin\) contre
# le VRAI code de Mindset (fonctions lues dans Mindset\fichiers\modules, natif.cs compilé tel quel).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-contrat.ps1
#
# Le témoin est construit (temoin\construire.ps1), zippé, signé avec une clé de test, installé par Install-Paquet dans un
# faux disque de la suite sous %TEMP% (<tmp>\Mindset\Programmes\Temoin), puis lancé et piloté comme Mindset le fait :
#   1  entrée apps.json (Get-Applis), dont « type »         6  lancement caché -Demarrage, cache_depuis
#   2  dossier reconnu, version installée                   7  fenêtre trouvée, accrochée, taille minimale, WM_CLOSE
#   3  verrou Local\Temoin-Instance, second lancement       8  dossier des données (règle des racines, copie ailleurs)
#   4  hôte Mindset.exe dans son dossier, relais             9  désinstalleur (seulement sur GitHub, voir plus bas)
#   5  quitter.demande, afficher.demande, notification.demande, etat.json, suite.json   10  version.json
# Contre-épreuve : à la fin, le test se relance sur des témoins cassés exprès (un point du contrat chacun) ; chacun doit
# échouer, sur le bon cas. (-Casser <point> : un seul témoin cassé, utilisé par cette contre-épreuve.)
#
# Rien sur le vrai PC : %LOCALAPPDATA% pointe vers le dossier de test pendant l'essai (le témoin et suite.json y vont),
# seuls les programmes lancés depuis ce dossier sont fermés, aucun droit administrateur, aucun réseau, rien dans le
# registre. Le témoin montre sa fenêtre deux fois (demande d'affichage) : sur le PC, lancer ce test sur un bureau
# Windows à part. Le désinstalleur du témoin n'est lancé que sur GitHub (règle : aucun désinstalleur lancé sur le PC).
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).
param([ValidateSet('', 'verrou', 'titre', 'quitter', 'taille', 'fermer', 'version')][string]$Casser = '')

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'
$modules = Join-Path $fichiers 'modules'
$temoinSource = Join-Path $racine 'temoin'
$surGitHub = $env:GITHUB_ACTIONS -eq 'true'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem, System.Windows.Forms
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)   # (aucun réseau)

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
# Attend qu'une condition soit vraie (en laissant passer les messages de Windows de ce fil : la fenêtre parente de test)
function Wait-Jusque([scriptblock]$Condition, [double]$Secondes = 10) {
    $fin = (Get-Date).AddSeconds($Secondes)
    do {
        [System.Windows.Forms.Application]::DoEvents()
        try { if (& $Condition) { return $true } } catch {}
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $fin)
    $false
}
# Lit les fonctions voulues d'un fichier de Mindset (sans exécuter le reste du fichier)
function Import-Fonctions([string]$Fichier, [string[]]$Noms) {
    $t = [IO.File]::ReadAllText((Join-Path $modules $Fichier), [Text.Encoding]::UTF8)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$null)
    foreach ($n in $Noms) {
        $d = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
        if (-not $d) { throw "$Fichier : fonction $n introuvable" }
        $d.Extent.Text
    }
}

$tmp = Join-Path $env:TEMP "mindset-contrat-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName   # (en nom long : sur GitHub, TEMP est en nom court)
$localVrai = $env:LOCALAPPDATA
$donneesTestVrai = $env:MINDSET_DONNEES

try {
    Write-Host "Mindset : contrat d'une appli, vérifié avec l'appli témoin$(if ($Casser) { " (témoin cassé exprès : $Casser)" })" -ForegroundColor Cyan
    Write-Host "Dossier de test : $tmp"
    # Le faux PC : %LOCALAPPDATA% (suite.json, données d'une copie non gérée) et le disque de la suite, sous $tmp
    $env:LOCALAPPDATA = Join-Path $tmp 'local'
    $env:MINDSET_DONNEES = $tmp   # (Mindset en test n'écrit que sous ce dossier : demandes, installations.json, suite.json)
    New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'Mindset') | Out-Null

    # =============================================================================================================
    Write-Partie 'Le vrai code de Mindset, et le témoin construit'
    # =============================================================================================================
    $EnTest = $true
    $MindsetAdmin = $false
    function Write-Log([string]$Texte) {}
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $modules 'natif.cs'), [Text.Encoding]::UTF8))
    . (Join-Path $modules 'signature.ps1')
    . (Join-Path $modules 'paquets.ps1')
    foreach ($f in (Import-Fonctions 'donnees.ps1' 'Get-RacinesDepuis', 'Save-JsonSur', 'ConvertFrom-JsonObjet', 'Read-JsonSur')) { . ([scriptblock]::Create($f)) }
    # Un Mindset installé sur le faux disque : les racines viennent de son emplacement (comme donnees.ps1)
    $MonDossier = Join-Path $tmp 'Mindset\Programmes\Mindset'
    New-Item -ItemType Directory -Force -Path $MonDossier | Out-Null
    $Racines = Get-RacinesDepuis $MonDossier
    $RacineProgrammes = $Racines.Programmes
    $SuiteDir = $Racines.Donnees
    $SuiteFileDir = Join-Path $env:LOCALAPPDATA 'Mindset'
    $DataDir = Join-Path $SuiteDir 'Mindset'
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    . (Join-Path $modules 'suite.ps1')
    foreach ($f in (Import-Fonctions 'installations.ps1' 'Get-DossierGere', 'Get-DossierDonnees', 'Read-Installations', 'Save-Installation', 'Get-ScriptAppli', 'Get-VersionDans', 'Test-DossierAppli', 'Get-Installation', 'Open-Appli')) { . ([scriptblock]::Create($f)) }
    $InstallFile = Join-Path $DataDir 'installations.json'
    $script:Occupe = @{}; $script:ARelancer = @{}
    foreach ($f in (Import-Fonctions 'integration.ps1' 'Find-FenetreAppli', 'Start-AppliCachee', 'Write-DemandeQuitter', 'Request-FermetureApplis')) { . ([scriptblock]::Create($f)) }
    foreach ($f in (Import-Fonctions 'zone.ps1' 'Watch-NotificationsApplis', 'Open-BulleAppli')) { . ([scriptblock]::Create($f)) }
    foreach ($f in (Import-Fonctions 'accueil.ps1' 'Get-EtatAppli')) { . ([scriptblock]::Create($f)) }
    $script:EtatsApplis = @{}
    # (ce que Mindset affiche autour : remplacé ici, rien ne s'ouvre)
    function Show-Fenetre {}
    function Open-AppliConsole([string]$Id) {}
    function Get-Appli([string]$Id) { $script:Applis | Where-Object Id -eq $Id }
    $bulles = New-Object System.Collections.ArrayList
    $script:IconeHorloge = New-Object psobject
    $script:IconeHorloge | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value ({ param($Duree, $Titre, $Texte, $Icone) [void]$bulles.Add(@{ Titre = $Titre; Texte = $Texte }) }.GetNewClosure())

    # Des fonctions de Windows pour regarder la fenêtre du témoin de l'extérieur
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ContratFenetre
{
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    public static string Classe(IntPtr h) { var s = new System.Text.StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    public static int[] Taille(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.Right - r.Left, r.Bottom - r.Top }; }
}
'@

    $construit = & (Join-Path $temoinSource 'construire.ps1') -Sortie (Join-Path $tmp 'construit')
    $scriptTemoin = Join-Path $construit 'fichiers\Temoin.ps1'
    $versionTemoin = ''
    if ([IO.File]::ReadAllText($scriptTemoin) -match "(?m)^\`$AppVersion\s*=\s*'([\d.]+)'") { $versionTemoin = $Matches[1] }
    Test-Cas 'le témoin se construit : Mindset.exe, Temoin.exe, Désinstaller Temoin.exe, version.json, fichiers\Temoin.ps1' {
        $versionTemoin -and -not @('Mindset.exe', 'Temoin.exe', 'Désinstaller Temoin.exe', 'version.json', 'fichiers\Temoin.ps1' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $construit $_)) }).Count
    }

    # Contre-épreuve : un point du contrat cassé exprès dans le témoin construit (le remplacement doit avoir eu lieu)
    if ($Casser) {
        $t = [IO.File]::ReadAllText($scriptTemoin, [Text.Encoding]::UTF8)
        $remplacements = @{
            verrou  = @('"Local\$AppNom-Instance"', '"Local\$AppNom-Autre"')
            titre   = @('$Fenetre.Title = $AppNom', '$Fenetre.Title = "$AppNom 2"')
            quitter = @("'quitter.demande'", "'quitter.demande.x'")
            taille  = @('$Fenetre.MinWidth = $script:TailleMin.L; $Fenetre.MinHeight = $script:TailleMin.H', '$null = 0')
            fermer  = @('$e.Cancel = $true; $Fenetre.Hide()', '$null = 0')
        }
        if ($Casser -eq 'version') {
            [IO.File]::WriteAllText((Join-Path $construit 'version.json'), "{ `"appli`": `"temoin`", `"version`": `"9.9.9`", `"mindset_min`": `"2.15.0`" }")
        } else {
            $r = $remplacements[$Casser]
            if (-not $t.Contains($r[0])) { throw "contre-épreuve $Casser : « $($r[0]) » introuvable dans Temoin.ps1" }
            [IO.File]::WriteAllText($scriptTemoin, $t.Replace($r[0], $r[1]), (New-Object Text.UTF8Encoding $true))
        }
    }

    # =============================================================================================================
    Write-Partie 'Partie 10 : version.json, et l''installation du zip par Mindset (Install-Paquet)'
    # =============================================================================================================
    $infoVersion = Read-VersionJson ([IO.File]::ReadAllBytes((Join-Path $construit 'version.json')))
    Test-Cas 'version.json lisible par Mindset (Read-VersionJson), appli « temoin »' { $infoVersion -and $infoVersion.Appli -ceq 'temoin' }
    Test-Cas 'version.json : la même version que la ligne $AppVersion du script (une seule source)' { $infoVersion.Version -eq $versionTemoin }
    Test-Cas 'version.json : mindset_min au moins 2.15.0' { $infoVersion.MindsetMin -and -not (Test-VersionPlusRecente '2.15.0' $infoVersion.MindsetMin) }
    Test-Cas 'version.json en UTF-8 sans BOM' { [IO.File]::ReadAllBytes((Join-Path $construit 'version.json'))[0] -eq [byte][char]'{' }

    # Le zip : le dossier Temoin\ (dossier_zip), signé avec une clé de test (jamais la vraie)
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 3072
    $rsa.PersistKeyInCsp = $false
    $clePublique = Join-Path $tmp 'cle-publique.xml'
    [IO.File]::WriteAllText($clePublique, $rsa.ToXmlString($false))
    $zipFichier = Join-Path $tmp 'Temoin.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $tmp 'construit'), $zipFichier)
    $zip = [IO.File]::ReadAllBytes($zipFichier)
    $signature = $rsa.SignData($zip, [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
    $prog = Join-Path $RacineProgrammes 'Temoin'
    Test-Cas 'Test-PaquetAppli (avant de fermer l''appli) : accepté par Mindset 2.15.0' { $null = Test-PaquetAppli $zip 'Temoin' 'temoin' '2.15.0'; $true }
    Test-Cas 'Test-PaquetAppli : refusé par un Mindset plus ancien (« Mets d''abord Mindset à jour »)' {
        try { Test-PaquetAppli $zip 'Temoin' 'temoin' '2.14.0'; $false } catch { $_.Exception.Message -like 'Mets d''abord Mindset à jour*' }
    }
    Test-Cas 'Get-VersionZip : la version du témoin' { (Get-VersionZip $zip 'Temoin') -eq $versionTemoin }
    Test-Cas 'Install-Paquet l''installe dans <disque>\Mindset\Programmes\Temoin, version lue dans le dossier' {
        ((Install-Paquet -Zip $zip -Signature $signature -ClePublique $clePublique -Destination $prog -DossierZip 'Temoin' -Exe 'Temoin.exe' -Appli 'temoin' -VersionMindset '2.15.0') -eq $prog) -and
        ((Get-VersionDossier $prog) -eq $versionTemoin)
    }

    # =============================================================================================================
    Write-Partie 'Partie 1 : son entrée dans apps.json (Get-Applis, applis.ps1)'
    # =============================================================================================================
    $entree = [IO.File]::ReadAllText((Join-Path $temoinSource 'entree-apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $AppDir = Join-Path $tmp 'apps'
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    function Get-ApplisAvec($Entree) {
        [IO.File]::WriteAllText((Join-Path $AppDir 'apps.json'), (ConvertTo-Json @($Entree) -Depth 4), (New-Object Text.UTF8Encoding $false))
        @(Get-Applis)
    }
    [IO.File]::WriteAllText((Join-Path $AppDir 'apps.json'), (ConvertTo-Json @($entree) -Depth 4), (New-Object Text.UTF8Encoding $false))
    . (Join-Path $modules 'applis.ps1')   # (définit Get-Applis et lit apps.json dans $Applis, comme Mindset au démarrage)
    $t = $Applis | Where-Object Id -eq 'temoin'
    Test-Cas 'entrée acceptée par Mindset, de type « powershell » écrit en toutes lettres' { @($Applis).Count -eq 1 -and $t.Type -eq 'powershell' }
    Test-Cas 'verrou : mutex = Local\<nom>-Instance' { $t.Mutex -ceq "Local\$($t.Nom)-Instance" }
    Test-Cas 'afficher_fichier présent (sinon Mindset ne lit pas ses bulles) : afficher.demande' { $t.AfficherFichier -ceq 'afficher.demande' }
    Test-Cas 'donnees présent (son ancien dossier), cache_depuis = sa première version' { $t.Donnees -and $t.CacheDepuis -eq '1.0.0' }
    Test-Cas 'identité dans la barre des tâches : JordanJacquot.Temoin' { $t.AppId -ceq 'JordanJacquot.Temoin' }
    Test-Cas 'son désinstalleur et son exe sont bien dans le dossier installé' { (Test-Path -LiteralPath (Join-Path $prog $t.Desinstalleur)) -and (Test-Path -LiteralPath (Join-Path $prog $t.Exe)) }
    $variante = $entree | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $variante.type = 'rust'; $variante.PSObject.Properties.Remove('script')
    $tRust = @(Get-ApplisAvec $variante)
    Test-Cas 'la même entrée en « type »: « rust » sans script : acceptée aussi' { $tRust.Count -eq 1 -and $tRust[0].Type -eq 'rust' -and $tRust[0].Script -eq '' }
    $variante.type = 'Rust'
    Test-Cas '« type » mal écrit (« Rust ») : entrée ignorée' { @(Get-ApplisAvec $variante).Count -eq 0 }
    $null = Get-ApplisAvec $entree

    # =============================================================================================================
    Write-Partie 'Partie 2 : le dossier installé reconnu (Test-DossierAppli, Get-Installation)'
    # =============================================================================================================
    Save-Installation 'temoin' $prog $true
    Test-Cas 'dossier reconnu par son script' { Test-DossierAppli $prog $t }
    Test-Cas 'dossier reconnu aussi par Mindset.exe et version.json (forme d''une appli Rust, entrée sans script)' { Test-DossierAppli $prog $tRust[0] }
    $inst = Get-Installation $t
    Test-Cas 'Get-Installation : gérée, dans le dossier protégé, version du témoin' { $inst -and $inst.Gere -and $inst.Dossier -eq $prog -and $inst.Version -eq $versionTemoin }

    # =============================================================================================================
    Write-Partie 'Partie 4 : l''hôte Mindset.exe et le relais Temoin.exe'
    # =============================================================================================================
    Test-Cas 'Mindset.exe : « Mindset » dans ses informations (le Gestionnaire des tâches range la suite sur une ligne)' { [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $prog 'Mindset.exe')).FileDescription -ceq 'Mindset' }
    Test-Cas 'Temoin.exe (le relais) et le désinstalleur : « Temoin »' {
        [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $prog 'Temoin.exe')).FileDescription -ceq 'Temoin' -and
        [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $prog 'Désinstaller Temoin.exe')).FileDescription -ceq 'Temoin'
    }
    Test-Cas 'numéro de version des programmes = version du témoin' { [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $prog 'Mindset.exe')).FileVersion -like "$versionTemoin*" }
    $avant = @(Get-ChildItem -LiteralPath $prog -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })

    # =============================================================================================================
    Write-Partie 'Parties 6, 3, 7 et 8 : lancée cachée par Mindset (Open-Appli -Demarrage)'
    # =============================================================================================================
    Open-Appli $t -Demarrage
    $h = [IntPtr]::Zero
    $trouvee = Wait-Jusque { $script:h = Find-FenetreAppli $t; $script:h -ne [IntPtr]::Zero } 30
    Test-Cas 'sa fenêtre est trouvée par Mindset (Find-FenetreAppli : titre exact, sans propriétaire, classe WPF)' { $trouvee }
    $hotes = @(Get-ProcessusAppli $t -Hote)
    Test-Cas 'un seul programme tourne : Mindset.exe de son dossier (trouvé par son chemin)' { $hotes.Count -eq 1 -and $hotes[0].Path -ieq (Join-Path $prog 'Mindset.exe') }
    $pidTemoin = if ($hotes.Count) { $hotes[0].Id } else { 0 }
    Test-Cas 'verrou Local\Temoin-Instance pris, et Test-AppliOuverte le voit' {
        $m = $null; $ok = [Threading.Mutex]::TryOpenExisting('Local\Temoin-Instance', [ref]$m); if ($m) { $m.Dispose() }
        $ok -and (Test-AppliOuverte $t)
    }
    Test-Cas '-Demarrage : fenêtre créée mais cachée, sans propriétaire, classe HwndWrapper' {
        $h -ne [IntPtr]::Zero -and -not [ContratFenetre]::IsWindowVisible($h) -and [ContratFenetre]::GetWindow($h, 4) -eq [IntPtr]::Zero -and ([ContratFenetre]::Classe($h)).StartsWith('HwndWrapper')
    }
    Test-Cas '-Demarrage : le premier plan ne lui est pas donné' { [ContratFenetre]::GetForegroundWindow() -ne $h }
    $donneesTemoin = Join-Path $SuiteDir 'Temoin'
    Test-Cas 'données : <disque>\Mindset\Donnees\Temoin, le dossier que Mindset lui donne (Get-DossierDonnees)' {
        (Wait-Jusque { Test-Path -LiteralPath (Join-Path $donneesTemoin 'etat.json') } 10) -and (Get-DossierDonnees $t) -eq $donneesTemoin
    }
    $script:Applis = $Applis
    Test-Cas 'Start-AppliCachee : cache_depuis atteint, Mindset la lance cachée (-Demarrage)' {
        $script:LanceeCachee = $null
        & { function Open-Appli($Appli, [switch]$Demarrage) { $script:LanceeCachee = [bool]$Demarrage }; Start-AppliCachee $t }
        $script:LanceeCachee -eq $true
    }

    # =============================================================================================================
    Write-Partie 'Partie 5 : les fichiers échangés (etat.json, notification.demande, suite.json)'
    # =============================================================================================================
    function Get-Etat { $script:EtatsApplis = @{}; Get-EtatAppli $t }
    function Test-Ligne([string]$Texte) { $e = Get-Etat; [bool]($e -and @($e.Lignes | Where-Object { $_.Texte -eq $Texte }).Count) }
    $etat = Get-Etat
    Test-Cas 'etat.json lu par Mindset (Get-EtatAppli, format commun) : titre, un score, des lignes' {
        $etat -and $etat.Titre -eq "Témoin $versionTemoin" -and @($etat.Scores).Count -eq 1 -and $etat.Scores[0].Valeur -eq 100 -and @($etat.Lignes).Count -ge 2
    }
    Test-Cas 'etat.json en UTF-8 sans BOM' { [IO.File]::ReadAllBytes((Join-Path $donneesTemoin 'etat.json'))[0] -eq [byte][char]'{' }
    Test-Cas 'notification.demande montrée par Mindset (Watch-NotificationsApplis), puis supprimée' {
        $bulles.Clear()
        (Wait-Jusque { Watch-NotificationsApplis; $bulles.Count -gt 0 } 10) -and $bulles[0].Titre -eq 'Témoin' -and $bulles[0].Texte -eq 'Le témoin est prêt.' -and
        -not (Test-Path -LiteralPath (Join-Path $donneesTemoin 'notification.demande')) -and $script:BulleAppli.Id -cmatch '^[0-9a-f]{12}$'
    }
    $bulle = $script:BulleAppli
    Test-Cas 'suite.json : le thème choisi dans Mindset (Set-SuiteTheme) est suivi' { Set-SuiteTheme 'crepuscule'; Wait-Jusque { Test-Ligne 'Thème : crepuscule' } 6 }
    Test-Cas 'suite.json : un thème inconnu écrit par un autre programme est ignoré' {
        [IO.File]::WriteAllText((Join-Path $SuiteFileDir 'suite.json'), '{ "theme": "..\\..\\piege", "applis": {} }')
        Start-Sleep -Seconds 2
        Test-Ligne 'Thème : crepuscule'
    }

    # =============================================================================================================
    Write-Partie 'Partie 7 : accrochée dans Mindset (MSIntegration de natif.cs)'
    # =============================================================================================================
    # La place de l'appli : une fenêtre Windows Forms jamais montrée (comme le panneau de Mindset, mais hors de l'écran)
    $panneau = New-Object System.Windows.Forms.Form
    $panneau.ShowInTaskbar = $false; $panneau.StartPosition = 'Manual'; $panneau.Location = New-Object Drawing.Point(-32000, -32000)
    $styles = [MSIntegration]::Accrocher($h, $panneau.Handle, 200, 200)
    Test-Cas 'Windows accepte de l''accrocher (Accrocher rend ses styles d''avant)' { $null -ne $styles -and [MSIntegration]::EstEnfantDe($h, $panneau.Handle) }
    Test-Cas 'accrochée : elle le voit, et se montre d''elle-même (WS_VISIBLE)' { (Wait-Jusque { Test-Ligne 'Affichée dans Mindset' } 6) -and [MSIntegration]::EstMontree($h) }
    # (taille minimale à 0 : WPF ne l'impose pas à une fenêtre enfant, le cas ci-dessous ne voit donc que la taille donnée par
    # Mindset ; c'est le retour de la taille minimale, une fois décrochée, qui montre que le témoin suit bien l'accrochage)
    Test-Cas 'accrochée : redimensionnée à 150 x 120 par Mindset, elle garde cette taille' {
        [MSIntegration]::Redimensionner($h, 150, 120)
        $null = Wait-Jusque { $false } 1.5
        $tl = [ContratFenetre]::Taille($h); $tl[0] -eq 150 -and $tl[1] -eq 120
    }
    Test-Cas 'pas de barre à elle (Mindset.BarrePropre absent) : la barre de Mindset reste' { -not [MSIntegration]::BarrePropre($h) }
    Test-Cas 'clic sur sa bulle (Open-BulleAppli) : « notif:<id> » reçu, sa fenêtre accrochée n''est pas touchée' {
        $script:BulleAppli = $bulle
        Open-BulleAppli
        (Wait-Jusque { Test-Ligne "Bulle ouverte : $($bulle.Id)" } 6) -and [MSIntegration]::EstEnfantDe($h, $panneau.Handle) -and
        -not (Test-Path -LiteralPath (Join-Path $donneesTemoin 'afficher.demande'))
    }
    Test-Cas 'une bulle qu''elle n''a pas donnée (« notif:000000000000 ») : ignorée' {
        [IO.File]::WriteAllText((Join-Path $donneesTemoin 'afficher.demande'), 'notif:000000000000')
        (Wait-Jusque { -not (Test-Path -LiteralPath (Join-Path $donneesTemoin 'afficher.demande')) } 4) -and (Test-Ligne "Bulle ouverte : $($bulle.Id)") -and
        [MSIntegration]::EstEnfantDe($h, $panneau.Handle)
    }
    Test-Cas '« Fermer » de Mindset (WM_CLOSE) : elle se range (cachée), sans se détruire ni quitter' {
        [MSIntegration]::Fermer($h)
        (Wait-Jusque { -not [MSIntegration]::EstMontree($h) } 5) -and [MSIntegration]::IsWindow($h) -and -not (Get-Process -Id $pidTemoin).HasExited
    }
    Test-Cas 'Mindset la rend (Liberer) : décrochée, cachée, sa taille minimale revient' {
        [MSIntegration]::Liberer($h, $styles[0], $styles[1])
        $ok = (Wait-Jusque { Test-Ligne 'Pas affichée dans Mindset' } 6) -and [ContratFenetre]::GetParent($h) -eq [IntPtr]::Zero -and -not [ContratFenetre]::IsWindowVisible($h)
        [MSIntegration]::Redimensionner($h, 100, 100)
        $null = Wait-Jusque { $false } 1
        $tl = [ContratFenetre]::Taille($h)
        $ok -and $tl[0] -ge 300 -and $tl[1] -ge 200
    }
    Test-Cas 'la même fenêtre tout du long (jamais recréée)' { (Find-FenetreAppli $t) -eq $h }
    $panneau.Dispose()

    # =============================================================================================================
    Write-Partie 'Parties 3 et 5 : ramenée par Mindset ou par un second lancement (afficher.demande)'
    # =============================================================================================================
    Test-Cas 'Open-Appli alors qu''elle tourne : afficher.demande (numéro de Mindset), sa fenêtre se montre' {
        Open-Appli $t
        (Wait-Jusque { [ContratFenetre]::IsWindowVisible($h) } 6) -and -not (Test-Path -LiteralPath (Join-Path $donneesTemoin 'afficher.demande'))
    }
    [MSIntegration]::Fermer($h)
    $null = Wait-Jusque { -not [ContratFenetre]::IsWindowVisible($h) } 5
    Test-Cas 'second lancement par Temoin.exe : il attend, dépose sa demande d''affichage et s''arrête ; la première se montre' {
        Start-Process -FilePath (Join-Path $prog 'Temoin.exe') -WorkingDirectory $prog
        $deux = Wait-Jusque { @(Get-ProcessusAppli $t -Hote).Count -ge 2 } 5
        $ok = (Wait-Jusque { [ContratFenetre]::IsWindowVisible($h) } 15)
        $seul = Wait-Jusque { $p = @(Get-ProcessusAppli $t -Hote); $p.Count -eq 1 -and $p[0].Id -eq $pidTemoin } 5
        $deux -and $ok -and $seul
    }
    [MSIntegration]::Fermer($h)
    $null = Wait-Jusque { -not [ContratFenetre]::IsWindowVisible($h) } 5

    # =============================================================================================================
    Write-Partie 'Partie 5 : Mindset quitte avec les applis (quitter.demande)'
    # =============================================================================================================
    Test-Cas 'Request-FermetureApplis : elle quitte en moins de 6 s, verrou rendu, demande supprimée' {
        Request-FermetureApplis
        (Wait-Jusque { (Get-Process -Id $pidTemoin -ErrorAction SilentlyContinue) -eq $null } 6) -and -not (Test-AppliOuverte $t) -and
        -not (Test-Path -LiteralPath (Join-Path $donneesTemoin 'quitter.demande'))
    }
    Test-Cas 'rien n''a été écrit dans son dossier des programmes' {
        $apres = @(Get-ChildItem -LiteralPath $prog -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
        -not (Compare-Object $avant $apres)
    }

    # =============================================================================================================
    Write-Partie 'Partie 8 : une copie hors de Mindset garde son ancien dossier (« donnees » de apps.json)'
    # =============================================================================================================
    if (-not $Casser) {
        $ailleurs = Join-Path $tmp 'Telechargements\Temoin'
        Copy-Item -LiteralPath $prog -Destination $ailleurs -Recurse
        $p = Start-Process -FilePath (Join-Path $ailleurs 'Mindset.exe') -ArgumentList '-Demarrage' -WorkingDirectory $ailleurs -PassThru
        Test-Cas "copie dans Téléchargements : ses données dans %LOCALAPPDATA%\Temoin, le dossier « donnees » que Mindset lit" {
            (Wait-Jusque { Test-Path -LiteralPath (Join-Path $t.Donnees 'etat.json') } 20) -and $t.Donnees -eq (Join-Path $env:LOCALAPPDATA 'Temoin')
        }
        [IO.File]::WriteAllText((Join-Path $t.Donnees 'quitter.demande'), [string]$PID)
        $null = $p.WaitForExit(6000)
    }

    # =============================================================================================================
    Write-Partie 'Partie 9 : son désinstalleur, lancé comme par « Désinstaller Mindset » (seulement sur GitHub)'
    # =============================================================================================================
    if ($Casser) { Write-Host '  (pas pour une contre-épreuve)' }
    elseif (-not $surGitHub) { Write-Host '  (pas sur ce PC : aucun désinstalleur n''est lancé en local ; ces cas tournent sur GitHub)' -ForegroundColor Yellow }
    else {
        # Comme desinstalleur.cs (LancerDesinstalleur) : dans le dossier de l'appli, -GarderDonnees ou -SupprimerDonnees
        function Invoke-Desinstalleur([string]$Option) {
            $psi = New-Object Diagnostics.ProcessStartInfo((Join-Path $prog $t.Desinstalleur), $Option)
            $psi.UseShellExecute = $false; $psi.WorkingDirectory = $prog
            $d = [Diagnostics.Process]::Start($psi)
            if (-not $d.WaitForExit(60000)) { try { $d.Kill() } catch {}; return $null }
            $d.ExitCode
        }
        function Install-Temoin { $null = Install-Paquet -Zip $zip -Signature $signature -ClePublique $clePublique -Destination $prog -DossierZip 'Temoin' -Exe 'Temoin.exe' -Appli 'temoin' -VersionMindset '2.15.0' }
        Open-Appli $t -Demarrage
        $null = Wait-Jusque { (Find-FenetreAppli $t) -ne [IntPtr]::Zero } 30
        Test-Cas '-GarderDonnees : rend 0, ferme l''appli, Temoin.exe disparaît, ses données restent' {
            ((Invoke-Desinstalleur '-GarderDonnees') -eq 0) -and -not (Test-Path -LiteralPath (Join-Path $prog 'Temoin.exe')) -and -not (Test-AppliOuverte $t) -and
            (Test-Path -LiteralPath (Join-Path $donneesTemoin 'etat.json'))
        }
        Test-Cas 'puis son dossier des programmes disparaît tout entier' { Wait-Jusque { -not (Test-Path -LiteralPath $prog) } 15 }
        Install-Temoin
        Test-Cas '-SupprimerDonnees : rend 0, Temoin.exe et ses données disparaissent' {
            ((Invoke-Desinstalleur '-SupprimerDonnees') -eq 0) -and -not (Test-Path -LiteralPath (Join-Path $prog 'Temoin.exe')) -and -not (Test-Path -LiteralPath $donneesTemoin)
        }
        $null = Wait-Jusque { -not (Test-Path -LiteralPath $prog) } 15
        Install-Temoin
        Test-Cas 'les deux options à la fois : il pose la question (il attend, rien n''est supprimé)' {
            $psi = New-Object Diagnostics.ProcessStartInfo((Join-Path $prog $t.Desinstalleur), '-GarderDonnees -SupprimerDonnees')
            $psi.UseShellExecute = $false; $psi.WorkingDirectory = $prog
            $d = [Diagnostics.Process]::Start($psi)
            $attend = -not $d.WaitForExit(4000)
            try { $d.Kill(); $null = $d.WaitForExit(3000) } catch {}
            $attend -and (Test-Path -LiteralPath (Join-Path $prog 'Temoin.exe'))
        }
    }

    # =============================================================================================================
    Write-Partie 'Contre-épreuve : un point du contrat cassé exprès dans le témoin fait échouer ce test'
    # =============================================================================================================
    if ($Casser) { Write-Host '  (déjà dans une contre-épreuve)' }
    else {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        foreach ($cas in @(
                @{ Point = 'verrou'; Cas = 'verrou Local\Temoin-Instance pris' },
                @{ Point = 'titre'; Cas = 'sa fenêtre est trouvée par Mindset' },
                @{ Point = 'quitter'; Cas = 'Request-FermetureApplis' },
                @{ Point = 'taille'; Cas = 'Mindset la rend (Liberer)' },
                @{ Point = 'fermer'; Cas = '« Fermer » de Mindset (WM_CLOSE)' },
                @{ Point = 'version'; Cas = 'version.json : la même version' })) {
            $c = $cas
            Test-Cas "témoin cassé ($($c.Point)) : le test échoue, sur « $($c.Cas) »" {
                $sortie = & $ps -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Casser $c.Point 2>&1 | Out-String
                $code = $LASTEXITCODE
                $code -eq 1 -and @($sortie -split "`n" | Where-Object { $_ -like '*ÉCHEC*' -and $_ -like "*$($c.Cas)*" }).Count -gt 0
            }
        }
    }
} catch {
    $script:Echoues += "Arrêt inattendu : $($_.Exception.Message)"
    Write-Host "  ÉCHEC  Arrêt inattendu : $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))" -ForegroundColor Red
} finally {
    # Seuls les programmes lancés depuis le dossier de test sont fermés
    foreach ($p in @(Get-Process | Where-Object { try { $_.Path -and $_.Path.StartsWith("$tmp\", [StringComparison]::OrdinalIgnoreCase) } catch { $false } })) {
        try { $p.Kill(); $null = $p.WaitForExit(3000) } catch {}
    }
    $env:LOCALAPPDATA = $localVrai
    $env:MINDSET_DONNEES = $donneesTestVrai
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "$($script:Reussis) réussi(s), $($script:Echoues.Count) échoué(s)." -ForegroundColor $(if ($script:Echoues.Count) { 'Red' } else { 'Green' })
if ($script:Echoues.Count) { exit 1 }
exit 0
