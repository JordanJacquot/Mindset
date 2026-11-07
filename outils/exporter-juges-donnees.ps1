# Mindset : juges du bloc « données » pour Mindset en Rust (rust\mindset-donnees).
#
#   & '.\outils\exporter-juges-donnees.ps1'      (depuis PowerShell, dans le dépôt)
#
# Prépare des installations d'essai de Mindset 2.18 (programmes, données, ancien dossier, fichiers abîmés...) dans un
# dossier temporaire, charge les VRAIS modules donnees.ps1 et suite.ps1 sur chacune, rejoue une suite d'étapes
# (réglages, fichiers JSON sûrs, suite.json, son, thème) et écrit tout ce qui en sort dans
# rust\mindset-donnees\tests\juges\donnees.json : les dossiers calculés, la réponse de chaque étape, et TOUS les
# fichiers du dossier d'essai à la fin (journal compris). Les tests Rust (tests\juges.rs) rejouent les mêmes cas.
#
# Rien ne touche le vrai PC :
#   - %LOCALAPPDATA% et %ProgramFiles% sont remplacés par des dossiers d'essai le temps du script (rendus à la fin) ;
#   - la lecture du registre (InstallLocation de Mindset, donnees.ps1:30) est remplacée par une fonction d'essai
#     Get-ItemProperty, vérifiée AVANT le premier chargement (une fonction passe avant la vraie commande) ;
#   - chaque cas vérifie que les dossiers calculés sont bien sous son dossier d'essai, sinon tout s'arrête.
# Les cas « au hasard » (graine fixe) sont tirés par ce script, pas écrits à la main.

param([int]$Graine = 20261107)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$modules = Join-Path $racine 'Mindset\fichiers\modules'
$sortie = Join-Path $racine 'rust\mindset-donnees\tests\juges\donnees.json'
$utf8 = New-Object Text.UTF8Encoding $false

$base = Join-Path $env:TEMP "mindset-juges-donnees-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $base | Out-Null
$base = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($base))).FullName

$avant = @{ LOCALAPPDATA = $env:LOCALAPPDATA; ProgramFiles = $env:ProgramFiles; MINDSET_DONNEES = $env:MINDSET_DONNEES }

# ---------------------------------------------------------------------------------------------------------------
# Le registre simulé : InstallLocation de Mindset (donnees.ps1:30). $script:Inscrit = $null : la clé n'existe pas.
# ---------------------------------------------------------------------------------------------------------------
$script:Inscrit = $null
$script:RegistreLu = 0
function Get-ItemProperty {
    param($Path)   # (-ErrorAction Stop arrive dans $args : fonction simple)
    $script:RegistreLu++
    if ($Path -notlike 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset') { throw "Lecture inattendue : $Path" }
    if ($null -eq $script:Inscrit) { throw 'Clé absente (essai)' }
    [pscustomobject]@{ InstallLocation = $script:Inscrit }
}
# (preuve que la fonction d'essai passe avant la vraie commande, avant tout chargement)
$script:Inscrit = 'Z:\essai'
if ((Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset' -ErrorAction Stop).InstallLocation -ne 'Z:\essai' -or $script:RegistreLu -ne 1) {
    throw 'La lecture du registre ne serait pas simulée : arrêt'
}

# ---------------------------------------------------------------------------------------------------------------
# Outils
# ---------------------------------------------------------------------------------------------------------------
function Get-Chemin([string]$T, [string]$Rel) { if ($Rel -eq '') { $T } else { Join-Path $T $Rel } }

# Le texte d'un fichier tel quel (marque d'encodage gardée en U+FEFF)
function Get-TexteBrut([string]$f) { [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($f)) }

# Tous les fichiers sous $T : chemin relatif => texte
function Get-Fichiers([string]$T) {
    $r = [ordered]@{}
    foreach ($f in @(Get-ChildItem -LiteralPath $T -Recurse -Force -File | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($T.Length + 1)
        $r[$rel] = Get-TexteBrut $f.FullName
    }
    $r
}
function Get-DossiersVides([string]$T) {
    @(Get-ChildItem -LiteralPath $T -Recurse -Force -Directory | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($T.Length + 1) })
}

# Une valeur PowerShell en JSON (une seule ligne ; $null => null)
function ConvertTo-JsonJuge($v) {
    if ($null -eq $v) { return 'null' }
    ConvertTo-Json -InputObject $v -Depth 20 -Compress
}

# ---------------------------------------------------------------------------------------------------------------
# Un cas : prépare, charge les modules, rejoue les étapes
# ---------------------------------------------------------------------------------------------------------------
$script:Numero = 0
function Invoke-Cas($Cas) {
    $script:Numero++
    $ErrorActionPreference = 'Continue'   # (comme Mindset.ps1)
    $CasDossier = Join-Path $base ('c{0:000}' -f $script:Numero)
    New-Item -ItemType Directory -Force -Path $CasDossier | Out-Null
    $local = if ($Cas.localappdata) { $Cas.localappdata } else { 'Local' }
    $pf = 'PF'
    $env:LOCALAPPDATA = Get-Chemin $CasDossier $local
    $env:ProgramFiles = Get-Chemin $CasDossier $pf
    Remove-Item Env:\MINDSET_DONNEES -ErrorAction SilentlyContinue
    $exe = if ($Cas.exe) { $Cas.exe } else { 'PF\Mindset\Mindset\Mindset.exe' }
    $dossierMindset = Split-Path (Get-Chemin $CasDossier $exe) -Parent
    New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:ProgramFiles, $dossierMindset | Out-Null
    $script:Inscrit = $null
    if ($Cas.inscrit_rel) { $script:Inscrit = Get-Chemin $CasDossier $Cas.inscrit_rel }
    elseif ($null -ne $Cas.inscrit_brut) { $script:Inscrit = $Cas.inscrit_brut }

    # Les fichiers d'avant
    $ages = @()
    foreach ($avantUn in @($Cas.avant)) {
        if (-not $avantUn) { continue }
        $p = Get-Chemin $CasDossier $avantUn.chemin
        if ($avantUn.dossier) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        else {
            New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
            if ($null -ne $avantUn.b64) { [IO.File]::WriteAllBytes($p, [Convert]::FromBase64String($avantUn.b64)) }
            else { [IO.File]::WriteAllText($p, [string]$avantUn.texte, $utf8) }
        }
        if ($avantUn.jours) { $ages += , @($p, [int]$avantUn.jours, [bool]$avantUn.dossier) }
    }
    # (les dates en dernier : créer un fichier change la date de son dossier)
    foreach ($x in $ages | Sort-Object { $_[0].Length } -Descending) {
        $d = (Get-Date).AddDays(-$x[1])
        if ($x[2]) { [IO.Directory]::SetLastWriteTime($x[0], $d) } else { [IO.File]::SetLastWriteTime($x[0], $d) }
    }

    $flux = @{}
    $resultats = @()
    $ouvert = $false
    try {
        foreach ($e in @($Cas.etapes)) {
            $r = [ordered]@{ op = $e.op }
            switch ($e.op) {
                'ouvrir' {
                    $script:RegistreLu = 0
                    $script:AppDir = Join-Path $dossierMindset 'fichiers'
                    $AppDir = $script:AppDir
                    $EnTest = $false
                    . (Join-Path $modules 'donnees.ps1')
                    . (Join-Path $modules 'suite.ps1')
                    foreach ($v in $DataDir, $LogFile, $SettingsFile, $SuiteFile, $SuiteDir, $SuiteFileDir) {
                        if (-not "$v".StartsWith("$CasDossier\", [StringComparison]::OrdinalIgnoreCase)) { throw "Dossier hors de l'essai : $v (arrêt)" }
                    }
                    $ouvert = $true
                    $r.dossiers = [ordered]@{
                        fichiers = $AppDir; mindset = $MonDossier; programmes = $RacineProgrammes; donnees_suite = $SuiteDir
                        local_mindset = $SuiteFileDir; donnees = $DataDir; disque = [string]$Racines.Disque
                    }
                    $r.registre_lu = $script:RegistreLu -gt 0
                    $r.illisibles = [bool]$script:ReglagesIllisibles
                    $r.repris = [bool]$script:ReglagesRepris
                }
                'reglages' {
                    $o = [ordered]@{}; foreach ($k in @($script:Settings.Keys | Sort-Object)) { $o[$k] = ConvertTo-JsonJuge $script:Settings[$k] }
                    $r.valeurs = $o
                }
                'reglage' {
                    $r.existe = $script:Settings.ContainsKey($e.nom)
                    $r.valeur = ConvertTo-JsonJuge (Get-Setting $e.nom)
                }
                'ecrire_reglage' {
                    # (dans un objet : un tableau seul serait enveloppé par ConvertFrom-Json de PowerShell 5.1, {value, Count})
                    $v = ('{"v":' + $e.valeur + '}' | ConvertFrom-Json).v
                    $EnTest = $false
                    Set-Setting $e.nom $v
                }
                'lancer_avec_windows' { $r.oui = Get-LancerAvecWindows }
                'ecrire_lancer_avec_windows' { $EnTest = $false; Set-LancerAvecWindows ([bool]$e.oui) }
                'lire_json' {
                    try { $j = Read-JsonSur (Get-Chemin $CasDossier $e.fichier); $r.valeur = ConvertTo-JsonJuge $j }
                    catch { $r.erreur = $_.Exception.Message.Replace($CasDossier, '<T>') }
                }
                'ecrire_json' {
                    try { Save-JsonSur (Get-Chemin $CasDossier $e.fichier) ($e.valeur | ConvertFrom-Json | ConvertTo-Json -Depth 5); $r.ok = $true }
                    catch { $r.ok = $false }
                }
                'json_texte' { $r.texte = ($e.valeur | ConvertFrom-Json | ConvertTo-Json -Depth 5) }
                'suite' {
                    $s = Read-Suite
                    $applis = @(); foreach ($k in $s.applis.Keys) { $applis += , @($k, $s.applis[$k]) }
                    $r.theme = $s.theme; $r.micro = $s.micro; $r.casque = $s.casque
                    $r.applis = @($applis | Sort-Object { $_[0] } | ForEach-Object { , @($_[0], $_[1]) })
                    $r.illisible = [bool]$s.Illisible
                }
                'theme_suite' { $r.theme = Get-SuiteTheme }
                'ecrire_theme_suite' { Set-SuiteTheme $e.theme }
                'ecrire_suite_appli' { Set-SuiteAppli $e.id $e.dossier }
                'son_suite' { $s = Get-SuiteSon; $r.micro = $s.Micro; $r.casque = $s.Casque }
                'ecrire_son_suite' { Set-SuiteSon $e.quoi $e.nom }
                'theme_valable' { $r.oui = [bool](Test-ThemeSuite $e.theme) }
                'nom_appareil' { $r.oui = [bool](Test-NomAppareil $e.nom) }
                'racines_depuis' { try { $x = Get-RacinesDepuis $e.dossier 2>$null; $r.programmes = $x.Programmes; $r.donnees = $x.Donnees; $r.disque = $x.Disque } catch { $r.erreur = $true } }
                'verrouiller' { $flux[$e.fichier] = [IO.File]::Open((Get-Chemin $CasDossier $e.fichier), 'Open', 'ReadWrite', 'None') }
                'liberer' { $flux[$e.fichier].Dispose(); $flux.Remove($e.fichier) }
                'ecrire_fichier' {
                    $p = Get-Chemin $CasDossier $e.fichier
                    New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
                    [IO.File]::WriteAllText($p, [string]$e.texte, $utf8)
                }
                'effacer_fichier' { [IO.File]::Delete((Get-Chemin $CasDossier $e.fichier)) }
                default { throw "Étape inconnue : $($e.op)" }
            }
            $resultats += , $r
        }
    } finally {
        foreach ($f in @($flux.Values)) { $f.Dispose() }
    }

    # Les chemins absolus deviennent « <T> » (le dossier du cas)
    $fichiers = Get-Fichiers $CasDossier
    $o = [ordered]@{
        nom = $Cas.nom
        localappdata = $local
        program_files = $pf
        exe = $exe
        inscrit_rel = $Cas.inscrit_rel
        inscrit_brut = $Cas.inscrit_brut
        avant = @($Cas.avant | Where-Object { $_ })
        etapes = @($Cas.etapes | Where-Object { $_ })
        resultats = $resultats
        fichiers = $fichiers
        dossiers_apres = Get-DossiersVides $CasDossier
    }
    $texte = ConvertTo-Json -InputObject $o -Depth 20 -Compress
    # (le dossier d'essai, écrit en JSON avec ses barres doublées)
    $texte = $texte.Replace(($CasDossier -replace '\\', '\\'), '<T>')
    $texte
}

# ---------------------------------------------------------------------------------------------------------------
# Les cas
# ---------------------------------------------------------------------------------------------------------------
function F([string]$Chemin, [string]$Texte, [int]$Jours = 0) { $h = [ordered]@{ chemin = $Chemin; texte = $Texte }; if ($Jours) { $h.jours = $Jours }; $h }
function D([string]$Chemin, [int]$Jours = 0) { $h = [ordered]@{ chemin = $Chemin; dossier = $true }; if ($Jours) { $h.jours = $Jours }; $h }
function E([string]$Op, $Autres = @{}) { $h = [ordered]@{ op = $Op }; foreach ($k in $Autres.Keys) { $h[$k] = $Autres[$k] }; $h }

$autreDisque = 'X\Mindset\Programmes\Mindset\Mindset.exe'
$donneesAutre = 'X\Mindset\Donnees\Mindset'
$donneesDefaut = 'Local\Mindset\Mindset'
$tout = @((E 'reglages'), (E 'suite'), (E 'theme_suite'), (E 'son_suite'), (E 'lancer_avec_windows'))

# Des réglages de Mindset 2.18, comme Set-Setting les écrit (ConvertTo-Json d'une table)
$reglages218 = @'
{
    "Ouverture-nevermind":  3.2,
    "VerifVersions":  false,
    "MajAuto":  true,
    "Demarrage":  [
                      "evermind",
                      "mindcare"
                  ],
    "LancerAvecWindows":  false,
    "Fermeture":  "reduire",
    "Animations":  "reduites",
    "ReduireHorloge":  true,
    "BulleHorlogeVue":  true,
    "DemarrageRepris":  true,
    "VersionsEssai":  [
                          "nevermind"
                      ],
    "MajMindsetVisible":  true,
    "MajMindsetDemande":  "2026-11-06T22:10:05",
    "TachesRefaitesPour":  "2.18.0",
    "DerniereRelanceTheme":  "2026-11-01T10:00:00",
    "Theme":  "pack:cafe-creme",
    "Dossier":  "D:\\Jeux\\Élodie <test> & \u0027copie\u0027",
    "Vide":  [

             ],
    "Objet":  {
                  "a":  1,
                  "b":  {

                        }
              },
    "Rien":  null
}
'@
$suite218 = '{"theme":"rubis","micro":"Micro (Realtek Audio)","casque":"","applis":{"nevermind":"C:\\Program Files\\Mindset\\Nevermind","evermind":"D:\\Mindset\\Programmes\\Evermind"},"modifie":"2026-11-01T09:00:00"}'
$installations218 = '{"nevermind":{"dossier":"C:\\Program Files\\Mindset\\Nevermind","gere":true}}'

$cas = [Collections.Generic.List[object]]::new()
function Add-Cas($Nom, $Proprietes) { $h = [ordered]@{ nom = $Nom }; foreach ($k in $Proprietes.Keys) { $h[$k] = $Proprietes[$k] }; $cas.Add($h) }

# --- Les racines (où sont les programmes et les données) ---
Add-Cas 'installé dans Program Files, rien encore' @{ etapes = @((E 'ouvrir')) + $tout }
Add-Cas 'installé sur un autre disque' @{ exe = $autreDisque; etapes = @((E 'ouvrir')) + $tout }
Add-Cas 'autre disque, noms en majuscules' @{ exe = 'X\MINDSET\programmes\Mindset\Mindset.exe'; etapes = @((E 'ouvrir')) }
Add-Cas 'lancé depuis le dossier téléchargé, Mindset inscrit sur un autre disque' @{ exe = 'Telechargements\Mindset 2.18\Mindset\Mindset.exe'; inscrit_rel = 'X\Mindset\Programmes\Mindset'; avant = @((F 'X\Mindset\Programmes\Mindset\Mindset.exe' 'exe')); etapes = @((E 'ouvrir')) }
Add-Cas 'lancé depuis le dossier téléchargé, inscrit sans Mindset.exe' @{ exe = 'Telechargements\Mindset\Mindset.exe'; inscrit_rel = 'X\Mindset\Programmes\Mindset'; etapes = @((E 'ouvrir')) }
Add-Cas 'lancé depuis le dossier téléchargé, rien d''inscrit' @{ exe = 'Telechargements\Mindset\Mindset.exe'; etapes = @((E 'ouvrir')) }
Add-Cas 'lancé depuis un dossier qui ne s''appelle pas Mindset, inscrit vide' @{ exe = 'Bureau\Copie\Mindset.exe'; inscrit_brut = ''; etapes = @((E 'ouvrir')) }
Add-Cas 'inscrit avec une barre à la fin' @{ exe = 'Bureau\Copie\Mindset.exe'; inscrit_rel = 'Y\Mindset\Programmes\Mindset\'; avant = @((F 'Y\Mindset\Programmes\Mindset\Mindset.exe' 'exe')); etapes = @((E 'ouvrir')) }
Add-Cas 'inscrit dans Program Files' @{ exe = 'Bureau\Mindset\Mindset.exe'; inscrit_rel = 'PF\Mindset\Mindset'; avant = @((F 'PF\Mindset\Mindset\Mindset.exe' 'exe')); etapes = @((E 'ouvrir')) }
Add-Cas 'profil avec accents et espaces' @{ localappdata = 'Users\Élodie Café\AppData\Local'; avant = @((F 'Users\Élodie Café\AppData\Local\Mindset\Mindset\reglages.json' '{"Fermeture":"quitter"}')); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'ecrire_reglage' @{ nom = 'Animations'; valeur = '"aucune"' })) }
$long = 'Dossier tres long ' + ('abcdefghij' * 7) + '\' + ('klmnopqrst' * 5)
Add-Cas 'chemin long (plus de 200 lettres)' @{ exe = "$long\Mindset\Programmes\Mindset\Mindset.exe"; etapes = @((E 'ouvrir'), (E 'ecrire_reglage' @{ nom = 'MajAuto'; valeur = 'false' }), (E 'reglages')) }
foreach ($d in 'C:\Program Files\Mindset\Mindset', 'D:\Mindset\Programmes\Mindset', 'd:\mindset\programmes\mindset\', 'E:\Mindset\Programmes\Mindset\', 'E:/Mindset/Programmes/Mindset',
    'Mindset\Programmes\Mindset', 'C:\Programmes\Mindset', 'C:\Mindset', 'C:\', 'F:\Autre\Mindset\Programmes\Mindset', 'F:\Mindset\Programmes\Mindset\Mindset\Mindset', '\\serveur\partage\Mindset\Programmes\Mindset',
    'é:\Mindset\Programmes\Mindset', 'Z:\Mindset\Programmes\Nevermind') {
    Add-Cas "racines depuis $d" @{ etapes = @((E 'ouvrir'), (E 'racines_depuis' @{ dossier = $d })) }
}

# --- La reprise des anciens fichiers ---
Add-Cas 'premières versions : fichiers à la racine de LOCALAPPDATA\Mindset' @{ avant = @((F 'Local\Mindset\journal.txt' "2025-01-01T10:00:00 ancien`r`n"), (F 'Local\Mindset\reglages.json' '{"MajAuto":false,"Fermeture":"quitter"}'), (F 'Local\Mindset\installations.json' $installations218)); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'premières versions, mais les nouveaux existent déjà' @{ avant = @((F 'Local\Mindset\reglages.json' '{"MajAuto":false}'), (F "$donneesDefaut\reglages.json" '{"MajAuto":true}')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'autre disque : anciens fichiers de LOCALAPPDATA\Mindset\Mindset repris' @{ exe = $autreDisque; avant = @((F "$donneesDefaut\reglages.json" $reglages218), (F "$donneesDefaut\installations.json" $installations218), (F "$donneesDefaut\journal.txt" "2026-10-01T08:00:00 vieux journal`r`n")); etapes = @((E 'ouvrir')) + $tout }
Add-Cas 'autre disque : ancien journal de Mindset.exe ajouté au vrai journal' @{ exe = $autreDisque; avant = @((F "$donneesDefaut\journal.txt" "plantage 1`r`nplantage 2`r`n`r`n"), (F "$donneesAutre\journal.txt" "2026-11-01T10:00:00 Démarrage`r`n")); etapes = @((E 'ouvrir')) }
Add-Cas 'autre disque : ancien journal vide supprimé sans rien ajouter' @{ exe = $autreDisque; avant = @((F "$donneesDefaut\journal.txt" "  `r`n "), (F "$donneesAutre\journal.txt" "x`r`n")); etapes = @((E 'ouvrir')) }
Add-Cas 'autre disque : racine et sous-dossier ont chacun un reglages.json' @{ exe = $autreDisque; avant = @((F 'Local\Mindset\reglages.json' '{"Fermeture":"quitter"}'), (F "$donneesDefaut\reglages.json" '{"Fermeture":"reduire"}')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'autre disque : données déjà en place, ancien dossier laissé' @{ exe = $autreDisque; avant = @((F "$donneesDefaut\reglages.json" '{"Fermeture":"quitter"}'), (F "$donneesAutre\reglages.json" '{"Fermeture":"reduire"}'), (F "$donneesAutre\installations.json" $installations218)); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reprise complète d''une 2.18 sur un autre disque' @{ exe = $autreDisque; avant = @((F "$donneesAutre\reglages.json" $reglages218), (F "$donneesAutre\reglages.json.bak" '{"MajAuto":false}'), (F "$donneesAutre\installations.json" $installations218), (F 'Local\Mindset\suite.json' $suite218), (F 'Local\Mindset\suite.json.bak' '{"theme":"neon"}'), (F 'X\Mindset\Donnees\Evermind\reglages.json' '{"Theme":"arcade","Micro":"Casque","Casque":"Casque"}'), (F "$donneesAutre\historique-maj.json" '{"historique":[]}'), (F 'Local\Mindset\afficher-page.txt' 'parametres')); etapes = @((E 'ouvrir')) + $tout + @((E 'reglage' @{ nom = 'Demarrage' }), (E 'reglage' @{ nom = 'Inconnu' }), (E 'reglage' @{ nom = 'majauto' }), (E 'reglage' @{ nom = 'Rien' }), (E 'ecrire_reglage' @{ nom = 'Animations'; valeur = '"completes"' }), (E 'reglages')) }

# --- Le reste du disque : console-webview ---
Add-Cas 'console-webview pas servi depuis 20 jours : supprimé' @{ avant = @((F "$donneesDefaut\console-webview\EBWebView\Local State" 'x' 20), (D "$donneesDefaut\console-webview\EBWebView" 20), (D "$donneesDefaut\console-webview" 20)); etapes = @((E 'ouvrir')) }
Add-Cas 'console-webview servi il y a 3 jours : gardé' @{ avant = @((F "$donneesDefaut\console-webview\EBWebView\Local State" 'x' 3), (D "$donneesDefaut\console-webview" 20)); etapes = @((E 'ouvrir')) }
Add-Cas 'console-webview vieux, un reste .a-supprimer déjà là' @{ avant = @((F "$donneesDefaut\console-webview\a.txt" 'x' 30), (D "$donneesDefaut\console-webview" 30), (F "$donneesDefaut\console-webview.a-supprimer\b.txt" 'y')); etapes = @((E 'ouvrir')) }
Add-Cas 'console-webview vide et vieux' @{ avant = @((D "$donneesDefaut\console-webview" 15)); etapes = @((E 'ouvrir')) }

# --- Les réglages ---
Add-Cas 'reglages.json normal' @{ avant = @((F "$donneesDefaut\reglages.json" $reglages218)); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'lancer_avec_windows'), (E 'ecrire_lancer_avec_windows' @{ oui = $true }), (E 'lancer_avec_windows'), (E 'reglages')) }
Add-Cas 'reglages.json avec marque UTF-8' @{ avant = @((F "$donneesDefaut\reglages.json" ([char]0xFEFF + '{"VerifVersions":false,"Fermeture":"quitter"}'))); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json abîmé, copie bonne' @{ avant = @((F "$donneesDefaut\reglages.json" '{ "VerifVersions": false, "MajAuto": fa'), (F "$donneesDefaut\reglages.json.bak" '{"VerifVersions":false,"MajAuto":false,"Fermeture":"quitter"}')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json abîmé sans copie : reprise de ce qui se lit' @{ avant = @((F "$donneesDefaut\reglages.json" "{`r`n  `"LancerAvecWindows`": false,`r`n  `"VerifVersions`": false,`r`n  `"Demarrage`": [ `"evermind`", `"mindcare`" ],`r`n  `"Fermeture`": `"reduire`",`r`n  `"Animations`": `"compl")); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'lancer_avec_windows')) }
Add-Cas 'reglages.json abîmé sans copie, Demarrage en texte' @{ avant = @((F "$donneesDefaut\reglages.json" '{"MajAuto": true, "ReduireHorloge":false,"BulleHorlogeVue" : true,"DemarrageRepris":false, "Demarrage": "nevermind", "Fermeture":"QUITTER","Animations":"aucune", "Theme":"rubis"')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json abîmé sans copie, Demarrage vide' @{ avant = @((F "$donneesDefaut\reglages.json" '{"Demarrage": [],"VerifVersions":true,"x":')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json abîmé sans copie, rien de lisible' @{ avant = @((F "$donneesDefaut\reglages.json" 'n''importe quoi')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json et copie abîmés' @{ avant = @((F "$donneesDefaut\reglages.json" '{"MajAuto":true,"Fermeture":"demander"'), (F "$donneesDefaut\reglages.json.bak" 'pas du json')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json vide sans copie' @{ avant = @((F "$donneesDefaut\reglages.json" '')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json vide, copie bonne' @{ avant = @((F "$donneesDefaut\reglages.json" ''), (F "$donneesDefaut\reglages.json.bak" '{"MajAuto":false}')); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'ecrire_reglage' @{ nom = 'Fermeture'; valeur = '"reduire"' })) }
Add-Cas 'reglages.json est un tableau' @{ avant = @((F "$donneesDefaut\reglages.json" '[{"MajAuto":false}]')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json null' @{ avant = @((F "$donneesDefaut\reglages.json" 'null')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json objet vide' @{ avant = @((F "$donneesDefaut\reglages.json" '{}')); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'lancer_avec_windows')) }
Add-Cas 'seule la copie existe' @{ avant = @((F "$donneesDefaut\reglages.json.bak" '{"LancerAvecWindows":false}')); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'lancer_avec_windows')) }
Add-Cas 'reglages.json pris par un autre programme au démarrage' @{ avant = @((F "$donneesDefaut\reglages.json" '{"VerifVersions":false,"Fermeture":"quitter"}')); etapes = @((E 'verrouiller' @{ fichier = "$donneesDefaut\reglages.json" }), (E 'ouvrir'), (E 'reglages'), (E 'ecrire_reglage' @{ nom = 'Animations'; valeur = '"reduites"' }), (E 'liberer' @{ fichier = "$donneesDefaut\reglages.json" }), (E 'reglages'), (E 'ecrire_reglage' @{ nom = 'MajAuto'; valeur = 'false' }), (E 'reglages')) }
Add-Cas 'reglages.json pris, puis abîmé quand il se libère' @{ avant = @((F "$donneesDefaut\reglages.json" '{"Fermeture":"quitter"}')); etapes = @((E 'verrouiller' @{ fichier = "$donneesDefaut\reglages.json" }), (E 'ouvrir'), (E 'liberer' @{ fichier = "$donneesDefaut\reglages.json" }), (E 'ecrire_fichier' @{ fichier = "$donneesDefaut\reglages.json"; texte = '{"LancerAvecWindows":false,"Fer' }), (E 'ecrire_reglage' @{ nom = 'Animations'; valeur = '"aucune"' }), (E 'reglages')) }
Add-Cas 'écritures de réglages variées' @{ etapes = @((E 'ouvrir'), (E 'ecrire_reglage' @{ nom = 'Demarrage'; valeur = '["nevermind"]' }), (E 'ecrire_reglage' @{ nom = 'Ouverture-evermind'; valeur = '12.5' }), (E 'ecrire_reglage' @{ nom = 'Texte'; valeur = '"Café <crème> & ''thé'' \"ok\" \\ fin\n\tsuite"' }), (E 'ecrire_reglage' @{ nom = 'Vide'; valeur = '[]' }), (E 'ecrire_reglage' @{ nom = 'Objet'; valeur = '{"a":[1,2,{"b":null}],"c":{}}' }), (E 'ecrire_reglage' @{ nom = 'Rien'; valeur = 'null' }), (E 'ecrire_reglage' @{ nom = 'MajAuto'; valeur = 'false' }), (E 'ecrire_reglage' @{ nom = 'MajAuto'; valeur = 'true' }), (E 'reglages'), (E 'reglage' @{ nom = 'MAJAUTO' })) }
Add-Cas 'lancer avec Windows : valeurs à la PowerShell' @{ avant = @((F "$donneesDefaut\reglages.json" '{"LancerAvecWindows":"false"}')); etapes = @((E 'ouvrir'), (E 'lancer_avec_windows'), (E 'ecrire_reglage' @{ nom = 'LancerAvecWindows'; valeur = '0' }), (E 'lancer_avec_windows'), (E 'ecrire_reglage' @{ nom = 'LancerAvecWindows'; valeur = '[]' }), (E 'lancer_avec_windows'), (E 'ecrire_reglage' @{ nom = 'LancerAvecWindows'; valeur = 'null' }), (E 'lancer_avec_windows'), (E 'ecrire_lancer_avec_windows' @{ oui = $false }), (E 'lancer_avec_windows')) }
Add-Cas 'au lancement suivant, la reprise est gardée' @{ avant = @((F "$donneesDefaut\reglages.json" '{ "VerifVersions": false, "ReduireHorl')); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json : la même clé en majuscules' @{ avant = @((F "$donneesDefaut\reglages.json" '{"MajAuto":false,"majauto":true,"Fermeture":"quitter"}'), (F "$donneesDefaut\reglages.json.bak" '{"MajAuto":false}')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json : la même clé en majuscules, sans copie' @{ avant = @((F "$donneesDefaut\reglages.json" '{"MajAuto":false,"majauto":true,"Fermeture":"quitter","LancerAvecWindows":false}')); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'ecrire_reglage' @{ nom = 'Animations'; valeur = '"aucune"' })) }
Add-Cas 'suite.json : la même clé en majuscules' @{ avant = @((F 'Local\Mindset\suite.json' '{"theme":"rubis","Theme":"arcade","applis":{}}'), (F 'Local\Mindset\suite.json.bak' '{"theme":"terminal","applis":{"nevermind":"C:\\N"}}')); etapes = @((E 'ouvrir'), (E 'suite'), (E 'theme_suite')) }
Add-Cas 'reglages.json : la même clé deux fois' @{ avant = @((F "$donneesDefaut\reglages.json" '{"Fermeture":"quitter","Fermeture":"reduire"}')); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json : guillemets simples et virgule de trop' @{ avant = @((F "$donneesDefaut\reglages.json" "{'Fermeture':'quitter', `"MajAuto`": false,}")); etapes = @((E 'ouvrir'), (E 'reglages')) }
Add-Cas 'reglages.json : très grand nombre et nombre décimal' @{ avant = @((F "$donneesDefaut\reglages.json" '{"Grand":123456789012345678901234567890,"Dec":1.50,"Exp":1e3}')); etapes = @((E 'ouvrir'), (E 'reglages'), (E 'ecrire_reglage' @{ nom = 'MajAuto'; valeur = 'false' })) }

# --- Fichiers JSON sûrs (Read-JsonSur, Save-JsonSur) ---
$f = "$donneesDefaut\essai.json"
Add-Cas 'JSON sûr : écrire, relire, copie' @{ etapes = @((E 'ouvrir'), (E 'ecrire_json' @{ fichier = $f; valeur = '{"n":1}' }), (E 'ecrire_json' @{ fichier = $f; valeur = '{"n":2,"liste":["a"],"vide":{}}' }), (E 'lire_json' @{ fichier = $f })) }
Add-Cas 'JSON sûr : fichier abîmé repris de sa copie' @{ avant = @((F $f '{ "n": 7, "coup'), (F "$f.bak" '{"n":4}')); etapes = @((E 'ouvrir'), (E 'lire_json' @{ fichier = $f }), (E 'lire_json' @{ fichier = $f })) }
foreach ($t in '', '   ', '[1, 2]', '"texte"', '{ "a": ', 'null', '42', ([char]0xFEFF + '{"n":5}'), '{"n":"é à ç"}', "{`"n`":1}`r`n", '{"a":1} x') {
    Add-Cas "JSON sûr : contenu « $($t.Replace([string][char]0xFEFF, '<BOM>')) » avec copie" @{ avant = @((F $f $t), (F "$f.bak" '{"n":8}')); etapes = @((E 'ouvrir'), (E 'lire_json' @{ fichier = $f })) }
}
Add-Cas 'JSON sûr : fichier et copie abîmés' @{ avant = @((F $f '{ "n": 9'), (F "$f.bak" 'pas du json')); etapes = @((E 'ouvrir'), (E 'lire_json' @{ fichier = $f })) }
Add-Cas 'JSON sûr : fichier absent' @{ etapes = @((E 'ouvrir'), (E 'lire_json' @{ fichier = $f })) }
Add-Cas 'JSON sûr : seulement la copie' @{ avant = @((F "$f.bak" '{"n":3}')); etapes = @((E 'ouvrir'), (E 'lire_json' @{ fichier = $f })) }
Add-Cas 'JSON sûr : fichier pris par un autre programme' @{ avant = @((F $f '{"n":10}')); etapes = @((E 'ouvrir'), (E 'verrouiller' @{ fichier = $f }), (E 'lire_json' @{ fichier = $f }), (E 'ecrire_json' @{ fichier = $f; valeur = '{"n":11}' }), (E 'liberer' @{ fichier = $f }), (E 'lire_json' @{ fichier = $f })) }
Add-Cas 'JSON sûr : copie temporaire restée après une coupure' @{ avant = @((F $f '{"n":2}'), (F "$f.tmp" '{ "n": 3, "coup')); etapes = @((E 'ouvrir'), (E 'lire_json' @{ fichier = $f }), (E 'ecrire_json' @{ fichier = $f; valeur = '{"n":4}' }), (E 'lire_json' @{ fichier = $f })) }
Add-Cas 'JSON sûr : dossier absent' @{ etapes = @((E 'ouvrir'), (E 'ecrire_json' @{ fichier = "$donneesDefaut\pas-la\x.json"; valeur = '{"n":1}' })) }

# --- La forme du JSON écrit (ConvertTo-Json de PowerShell 5.1) ---
foreach ($v in '{"a":1,"b":"deux","c":true,"d":null}', '{"liste":[1,"a",[],{}],"o":{"p":{"q":[{"r":1}]}}}', '{"texte":"<a href=''x''>&amp;</a> \"guillemets\" \\ \/ \b\f\n\r\t \u0001 \u001f \u007f \u0085 \u2028 \u2029 é ç 😀"}',
    '{"n":[0,-1,2147483647,2147483648,-9007199254740993,1.5,0.1,3.0,-0.25,12.345678]}', '{"clé accentuée":"v","\"x\"":"y","a<b":"c"}', '{"seul":["un"]}', '{}', '{"v":[[[]]]}') {
    Add-Cas "forme JSON de $v" @{ etapes = @((E 'ouvrir'), (E 'json_texte' @{ valeur = $v })) }
}

# --- suite.json ---
$sf = 'Local\Mindset\suite.json'
Add-Cas 'suite.json absent : thème neon, son de Windows' @{ etapes = @((E 'ouvrir')) + $tout }
Add-Cas 'suite.json de 2.18' @{ avant = @((F $sf $suite218)); etapes = @((E 'ouvrir')) + $tout }
foreach ($t in '"neon"', '"NEON"', '"Crepuscule"', '"pack:cafe-creme"', '"pack:Cafe-Creme"', '"pack:"', ('"pack:' + ('a' * 40) + '"'), ('"pack:' + ('a' * 41) + '"'), '"pack:café"', '"pack:a\n"', '"neon\n"', '42', 'true', '["neon"]', 'null', '""', '"sombre"') {
    Add-Cas "suite.json, thème $t" @{ avant = @((F $sf "{`"theme`":$t,`"applis`":{}}")); etapes = @((E 'ouvrir'), (E 'suite'), (E 'theme_suite'), (E 'theme_valable' @{ theme = 'neon' })) }
}
foreach ($m in '"Micro (USB)"', '""', '"a\u0001b"', ('"' + ('m' * 64) + '"'), ('"' + ('m' * 65) + '"'), '42', 'null', '["x"]', '"tab\there"', '"é😀"') {
    Add-Cas "suite.json, micro $m" @{ avant = @((F $sf "{`"theme`":`"neon`",`"micro`":$m,`"casque`":$m}")); etapes = @((E 'ouvrir'), (E 'suite'), (E 'son_suite')) }
}
foreach ($a in '{"nevermind":"C:\\N","Evermind":"D:\\E","mind care":"x","mindcare":5,"a-1":"","b\n":"y"}', '[{"nevermind":"x"}]', '"nevermind"', '{}', '42', 'null', '{"a":{"b":"c"}}') {
    Add-Cas "suite.json, applis $a" @{ avant = @((F $sf "{`"theme`":`"neon`",`"applis`":$a}")); etapes = @((E 'ouvrir'), (E 'suite'), (E 'ecrire_suite_appli' @{ id = 'mindcare'; dossier = 'C:\Program Files\Mindset\Mindcare' }), (E 'suite')) }
}
Add-Cas 'suite.json, clés en majuscules' @{ avant = @((F $sf '{"Theme":"arcade","MICRO":"M","Casque":"C","Applis":{"nevermind":"N"}}')); etapes = @((E 'ouvrir'), (E 'suite')) }
Add-Cas 'suite.json abîmé, copie bonne' @{ avant = @((F $sf '{ "theme": "arc'), (F "$sf.bak" $suite218)); etapes = @((E 'ouvrir'), (E 'suite'), (E 'ecrire_theme_suite' @{ theme = 'terminal' }), (E 'suite')) }
Add-Cas 'suite.json abîmé sans copie' @{ avant = @((F $sf '{ "theme": "arc')); etapes = @((E 'ouvrir'), (E 'suite'), (E 'theme_suite'), (E 'ecrire_suite_appli' @{ id = 'nevermind'; dossier = 'C:\N' }), (E 'suite')) }
Add-Cas 'suite.json pris par un autre programme' @{ avant = @((F $sf $suite218)); etapes = @((E 'ouvrir'), (E 'verrouiller' @{ fichier = $sf }), (E 'suite'), (E 'ecrire_theme_suite' @{ theme = 'arcade' }), (E 'ecrire_suite_appli' @{ id = 'mindcare'; dossier = 'C:\M' }), (E 'ecrire_son_suite' @{ quoi = 'micro'; nom = 'X' }), (E 'theme_suite'), (E 'son_suite'), (E 'liberer' @{ fichier = $sf }), (E 'suite')) }
Add-Cas 'thème de la suite : écrire' @{ avant = @((F $sf $suite218)); etapes = @((E 'ouvrir'), (E 'ecrire_theme_suite' @{ theme = 'terminal' }), (E 'ecrire_theme_suite' @{ theme = 'sombre' }), (E 'ecrire_theme_suite' @{ theme = 'pack:foret' }), (E 'ecrire_theme_suite' @{ theme = 'ARCADE' }), (E 'ecrire_theme_suite' @{ theme = '' }), (E 'suite')) }
Add-Cas 'thème écrit sans suite.json' @{ etapes = @((E 'ouvrir'), (E 'ecrire_theme_suite' @{ theme = 'rubis' }), (E 'suite')) }
Add-Cas 'applis : ajout, remplacement, retrait' @{ avant = @((F $sf $suite218)); etapes = @((E 'ouvrir'), (E 'ecrire_suite_appli' @{ id = 'mindcare'; dossier = 'C:\M' }), (E 'ecrire_suite_appli' @{ id = 'NEVERMIND'; dossier = 'E:\N' }), (E 'ecrire_suite_appli' @{ id = 'evermind'; dossier = $null }), (E 'ecrire_suite_appli' @{ id = 'absente'; dossier = '' }), (E 'suite')) }
Add-Cas 'appli ajoutée sans suite.json : thème d''Evermind repris' @{ avant = @((F 'Local\Mindset\Evermind\reglages.json' '{"Theme":"crepuscule"}')); etapes = @((E 'ouvrir'), (E 'ecrire_suite_appli' @{ id = 'evermind'; dossier = 'C:\E' }), (E 'suite')) }

# --- Le thème et le son repris des applis au premier lancement (Evermind, Nevermind, ancien OptiGame) ---
$ev = 'Local\Mindset\Evermind\reglages.json'
$evl = 'Local\Evermind\reglages.json'
$nv = 'Local\Mindset\Nevermind\parametres.json'
$og = 'Local\OptiGame\parametres.json'
Add-Cas 'premier lancement : thème d''Evermind' @{ avant = @((F $ev '{"Theme":"arcade","Micro":"Micro Evermind","Casque":"Casque Evermind"}')); etapes = @((E 'ouvrir'), (E 'theme_suite'), (E 'son_suite')) }
Add-Cas 'premier lancement : Evermind dans LOCALAPPDATA' @{ avant = @((F $evl '{"Theme":"terminal","Micro":"M2"}')); etapes = @((E 'ouvrir'), (E 'theme_suite'), (E 'son_suite')) }
Add-Cas 'premier lancement : thème de Nevermind' @{ avant = @((F $nv '{"Theme":"rubis"}')); etapes = @((E 'ouvrir'), (E 'theme_suite')) }
Add-Cas 'premier lancement : ancien dossier OptiGame' @{ avant = @((F $og '{"Theme":"crepuscule","Autre":1}')); etapes = @((E 'ouvrir'), (E 'theme_suite'), (E 'ecrire_suite_appli' @{ id = 'nevermind'; dossier = 'C:\N' }), (E 'suite')) }
Add-Cas 'premier lancement : OptiGame abîmé, thème neon' @{ avant = @((F $og '{"Theme":"cre')); etapes = @((E 'ouvrir'), (E 'theme_suite')) }
Add-Cas 'premier lancement : Evermind au thème inconnu, OptiGame bon' @{ avant = @((F $ev '{"Theme":"pack:foret"}'), (F $og '{"Theme":"ARCADE"}')); etapes = @((E 'ouvrir'), (E 'theme_suite')) }
Add-Cas 'premier lancement : réglages d''Evermind en tableau' @{ avant = @((F $ev '[{"Theme":"rubis","Micro":"M"}]')); etapes = @((E 'ouvrir'), (E 'theme_suite'), (E 'son_suite')) }
Add-Cas 'premier lancement : réglages d''Evermind vides' @{ avant = @((F $ev ''), (F $evl '{"Micro":"M3","Casque":"C3"}')); etapes = @((E 'ouvrir'), (E 'son_suite')) }
Add-Cas 'premier lancement : Evermind abîmé, celui de LOCALAPPDATA bon' @{ avant = @((F $ev '{"Micro":'), (F $evl '{"Micro":"M4","Casque":"C4"}')); etapes = @((E 'ouvrir'), (E 'son_suite')) }
Add-Cas 'premier lancement : micro d''Evermind trop long' @{ avant = @((F $ev ('{"Micro":"' + ('x' * 70) + '","Casque":5}'))); etapes = @((E 'ouvrir'), (E 'son_suite')) }
Add-Cas 'premier lancement, autre disque : Evermind dans les données de la suite' @{ exe = $autreDisque; avant = @((F 'X\Mindset\Donnees\Evermind\reglages.json' '{"Theme":"rubis","Micro":"MX"}'), (F $ev '{"Theme":"arcade","Micro":"ML"}')); etapes = @((E 'ouvrir'), (E 'theme_suite'), (E 'son_suite')) }
Add-Cas 'son : micro choisi, casque repris d''Evermind' @{ avant = @((F $ev '{"Micro":"ME","Casque":"CE"}'), (F $sf '{"theme":"neon","applis":{}}')); etapes = @((E 'ouvrir'), (E 'ecrire_son_suite' @{ quoi = 'micro'; nom = 'Micro (USB)' }), (E 'suite'), (E 'son_suite')) }
Add-Cas 'son : écritures refusées ou étranges' @{ avant = @((F $sf $suite218)); etapes = @((E 'ouvrir'), (E 'ecrire_son_suite' @{ quoi = 'enceinte'; nom = 'x' }), (E 'ecrire_son_suite' @{ quoi = 'micro'; nom = ('y' * 65) }), (E 'ecrire_son_suite' @{ quoi = 'casque'; nom = "a`tb" }), (E 'ecrire_son_suite' @{ quoi = 'CASQUE'; nom = 'Casque (Bluetooth)' }), (E 'ecrire_son_suite' @{ quoi = 'micro'; nom = '' }), (E 'suite'), (E 'son_suite')) }
Add-Cas 'son : premier choix sans suite.json' @{ etapes = @((E 'ouvrir'), (E 'ecrire_son_suite' @{ quoi = 'casque'; nom = 'Casque' }), (E 'suite')) }

# --- Petites règles ---
$regles = @()
foreach ($t in 'neon', 'Neon', 'rubis', 'pack:a', 'pack:A-1', 'pack:', 'pack:a b', "pack:a`n", "neon`n", 'pack:é', ('pack:' + 'z' * 40), ('pack:' + 'z' * 41), '', 'sombre') { $regles += E 'theme_valable' @{ theme = $t } }
foreach ($n in '', 'Micro', ('m' * 64), ('m' * 65), ("a" + [char]1 + "b"), "a`nb", ("a" + [char]0x1f), ("a" + [char]0x7f), 'é😀', ('😀' * 32), ('😀' * 33)) { $regles += E 'nom_appareil' @{ nom = $n } }
Add-Cas 'petites règles : thèmes et noms d''appareils' @{ etapes = @((E 'ouvrir')) + $regles }

# --- Au hasard (graine fixe) : des réglages abîmés n'importe où, des suite.json mélangés ---
$hasard = New-Object Random $Graine
$cles = 'LancerAvecWindows', 'VerifVersions', 'MajAuto', 'ReduireHorloge', 'BulleHorlogeVue', 'DemarrageRepris', 'Fermeture', 'Animations', 'Demarrage', 'VersionsEssai', 'MajMindsetVisible', 'Theme', 'Ouverture-nevermind', 'Autre'
function Get-ValeurHasard([string]$Cle) {
    switch ($hasard.Next(9)) {
        0 { 'true' } 1 { 'false' } 2 { '"' + @('demander', 'reduire', 'quitter', 'aucune', 'completes', 'REDUITES', 'a-b', 'trop long pour la regle x')[$hasard.Next(8)] + '"' }
        3 { '[' + (@(1..$hasard.Next(4) | ForEach-Object { '"' + @('evermind', 'nevermind', 'mindcare', 'Mind-2', 'x_y')[$hasard.Next(5)] + '"' }) -join ', ') + ']' }
        4 { '"' + @('nevermind', 'evermind', 'NEVER')[$hasard.Next(3)] + '"' } 5 { [string]$hasard.Next(-5, 100) } 6 { 'null' } 7 { '{"a":' + $hasard.Next(9) + '}' } default { '3.5' }
    }
}
for ($i = 1; $i -le 40; $i++) {
    $choisies = @($cles | Sort-Object { $hasard.Next() } | Select-Object -First ($hasard.Next(1, $cles.Count)))
    $espace = @('', ' ', "`r`n    ", "`t")[$hasard.Next(4)]
    $texte = '{' + $espace + (@($choisies | ForEach-Object { '"' + $_ + '"' + @(':', ' : ', ':  ')[$hasard.Next(3)] + (Get-ValeurHasard $_) }) -join (',' + $espace)) + $espace + '}'
    $coupe = $hasard.Next(0, $texte.Length + 1)
    if ($hasard.Next(5) -eq 0) { $coupe = $texte.Length }
    $abime = $texte.Substring(0, $coupe)
    $avantH = @((F "$donneesDefaut\reglages.json" $abime))
    if ($hasard.Next(3) -eq 0) { $avantH += F "$donneesDefaut\reglages.json.bak" ($texte.Substring(0, $hasard.Next(0, $texte.Length + 1))) }
    $etapesH = @((E 'ouvrir'), (E 'reglages'), (E 'lancer_avec_windows'))
    if ($hasard.Next(2) -eq 0) { $etapesH += E 'ecrire_reglage' @{ nom = 'Animations'; valeur = '"reduites"' } }
    Add-Cas "hasard réglages $i" @{ avant = $avantH; etapes = $etapesH }
}
for ($i = 1; $i -le 25; $i++) {
    $morceaux = @()
    if ($hasard.Next(4)) { $morceaux += '"theme":' + @('"neon"', '"Rubis"', '"pack:foret"', '"pack:Foret-2"', '"x"', '1', 'null', '"pack:"')[$hasard.Next(8)] }
    if ($hasard.Next(2)) { $morceaux += '"micro":' + @('"M"', '""', '3', 'null', ('"' + 'q' * 70 + '"'))[$hasard.Next(5)] }
    if ($hasard.Next(2)) { $morceaux += '"casque":' + @('"C"', '""', 'false', 'null')[$hasard.Next(4)] }
    if ($hasard.Next(4)) { $morceaux += '"applis":{' + (@(1..$hasard.Next(4) | ForEach-Object { '"' + @('nevermind', 'evermind', 'Mindcare', 'a b', 'x-1')[$hasard.Next(5)] + $_ + '":' + @('"C:\\A"', '1', 'null', '"D:\\Éé"')[$hasard.Next(4)] }) -join ',') + '}' }
    $texte = '{' + ($morceaux -join ',') + '}'
    if ($hasard.Next(4) -eq 0) { $texte = $texte.Substring(0, $hasard.Next(0, $texte.Length)) }
    $avantH = @((F $sf $texte))
    if ($hasard.Next(3) -eq 0) { $avantH += F $ev ('{"Theme":"' + @('arcade', 'x', 'TERMINAL')[$hasard.Next(3)] + '","Micro":"EM","Casque":"EC"}') }
    $etapesH = @((E 'ouvrir'), (E 'suite'), (E 'theme_suite'), (E 'son_suite'))
    switch ($hasard.Next(4)) {
        0 { $etapesH += E 'ecrire_suite_appli' @{ id = 'nevermind'; dossier = 'C:\N' } }
        1 { $etapesH += E 'ecrire_son_suite' @{ quoi = 'micro'; nom = 'Nouveau' } }
        2 { $etapesH += E 'ecrire_theme_suite' @{ theme = 'arcade' } }
        default {}
    }
    $etapesH += E 'suite'
    Add-Cas "hasard suite $i" @{ avant = $avantH; etapes = $etapesH }
}

# ---------------------------------------------------------------------------------------------------------------
# On rejoue tout
# ---------------------------------------------------------------------------------------------------------------
$textes = [Collections.Generic.List[string]]::new()
try {
    foreach ($c in $cas) { $textes.Add((Invoke-Cas $c)) }
} finally {
    $env:LOCALAPPDATA = $avant.LOCALAPPDATA
    $env:ProgramFiles = $avant.ProgramFiles
    if ($null -ne $avant.MINDSET_DONNEES) { $env:MINDSET_DONNEES = $avant.MINDSET_DONNEES }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path (Split-Path $sortie -Parent) | Out-Null
$json = "{`"source`":`"Mindset 2.18 PowerShell (donnees.ps1, suite.ps1)`",`"graine`":$Graine,`"cas`":[`n" + ($textes -join ",`n") + "`n]}`n"
[IO.File]::WriteAllText($sortie, $json, $utf8)
Write-Host "$($textes.Count) cas écrits dans $sortie"
