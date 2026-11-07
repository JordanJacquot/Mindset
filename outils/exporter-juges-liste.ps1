# Mindset : les juges du bloc « liste des applis » (rust\mindset-liste), exportés depuis la version PowerShell.
#
#   & '.\outils\exporter-juges-liste.ps1'      (depuis l'outil PowerShell de l'agent, ou une console : aucune fenêtre)
#
# Chaque cas est passé aux VRAIES fonctions d'aujourd'hui, reprises telles quelles de leurs fichiers :
#   - modules\liste.ps1 en entier (ConvertTo-Appli, Get-NumeroListeLivree, Read-ListeEnLigne, Read-ListeGardee,
#     Get-EntreesApplis, Add-ListeEnLigne) ;
#   - modules\signature.ps1 en entier (Test-Signature) ;
#   - de modules\applis.ps1 : Get-Applis et Receive-ListeEnLigne.
# Leurs réponses (applis, erreurs, journal, fichiers écrits) vont dans rust\mindset-liste\tests\juges\*.json, que les
# tests Rust rejouent :
#   - convertir.json : des entrées de la liste (une par cas), passées à ConvertTo-Appli ;
#   - listes.json    : des dossiers préparés (apps.json, apps-liste.txt, liste gardée et sa signature) et une liste
#                      téléchargée, passés aux autres fonctions ;
#   - hasard.json    : des cas tirés au hasard (graine fixe), jamais écrits à la main.
#
# Rien du PC n'est lu ni touché : tout est dans un dossier temporaire sous %TEMP%, supprimé à la fin, avec une clé de
# TEST créée ici (la vraie clé n'est jamais lue). LOCALAPPDATA est détourné pendant l'export (dans ce processus
# seulement) vers un faux chemin, pour que les juges ne contiennent aucun chemin du PC. Aucun réseau (toute connexion
# passe par un relais qui n'existe pas), rien dans le registre, aucun droit administrateur.

param([int]$Graine = 20261107, [int]$NombreHasard = 300)

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$modulesVrais = Join-Path $racine 'Mindset\fichiers\modules'
$sortie = Join-Path $racine 'rust\mindset-liste\tests\juges'
$utf8 = New-Object Text.UTF8Encoding $false
$sha256 = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://127.0.0.1:9', $false)

# Les fonctions d'un fichier, reprises telles quelles (leur texte exact)
function Get-Fonctions([string]$Fichier, [string[]]$Noms) {
    $erreurs = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Fichier, [ref]$null, [ref]$erreurs)
    if ($erreurs) { throw "$Fichier ne se lit pas : $($erreurs[0])" }
    $trouvees = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -in $Noms })
    foreach ($n in $Noms) { if (@($trouvees | Where-Object Name -eq $n).Count -ne 1) { throw "$n introuvable (ou en double) dans $Fichier" } }
    ($trouvees | ForEach-Object { $_.Extent.Text }) -join "`n"
}

$tmp = [IO.Path]::GetFullPath((Join-Path $env:TEMP "mindset-juges-liste-$([guid]::NewGuid().ToString('N').Substring(0, 8))"))
$mindset = Join-Path $tmp 'Mindset'
$fichiers = Join-Path $mindset 'fichiers'
$donnees = Join-Path $tmp 'Donnees\Mindset'
$cheminGardee = Join-Path $donnees 'apps-en-ligne.json'
$envAvant = @{ LOCALAPPDATA = $env:LOCALAPPDATA; FORET = $env:MINDSET_ESSAI_FORET }
$envJuge = [ordered]@{ LOCALAPPDATA = 'C:\Essai\AppData\Local'; MINDSET_ESSAI_FORET = 'D:\Forêt verte' }

# Le journal de Mindset (Write-Log) : chaque ligne notée, le dossier de test remplacé par « <racine> »
$script:Journal = New-Object Collections.Generic.List[string]
function Write-Log([string]$Texte) { $script:Journal.Add($Texte.Replace($tmp, '<racine>')) }
function Format-Message([string]$Texte) { $Texte.Replace($tmp, '<racine>') }

# Les vraies fonctions
. (Join-Path $modulesVrais 'signature.ps1')
. (Join-Path $modulesVrais 'liste.ps1')
. ([scriptblock]::Create((Get-Fonctions (Join-Path $modulesVrais 'applis.ps1') 'Get-Applis', 'Receive-ListeEnLigne')))

function New-CleTest {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 3072
    try { $rsa.PersistKeyInCsp = $false; @{ Privee = $rsa.ToXmlString($true); Publique = $rsa.ToXmlString($false) } }
    finally { $rsa.Dispose() }
}
function Get-Sig([byte[]]$Donnees, [string]$Privee) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($Privee); , $rsa.SignData($Donnees, $sha256) }
    finally { $rsa.Dispose() }
}
function T([string]$Texte) { , $utf8.GetBytes($Texte) }

# Un bloc d'octets dans un juge : { b64, bourrage } (bourrage : autant d'espaces ajoutés à la fin, pour les gros fichiers)
function Get-Bloc($B) {
    if ($null -eq $B) { return $null }
    if ($B -is [hashtable]) { return [ordered]@{ b64 = [Convert]::ToBase64String([byte[]]$B.Octets); bourrage = [int]$B.Bourrage } }
    [ordered]@{ b64 = [Convert]::ToBase64String([byte[]]$B); bourrage = 0 }
}
function Get-OctetsBloc($B) {
    if ($null -eq $B) { return $null }
    if ($B -is [hashtable]) { return , ([byte[]]$B.Octets + [byte[]](, 0x20 * [int]$B.Bourrage)) }
    , [byte[]]$B
}
# Un gros fichier : $Octets suivis d'espaces jusqu'à $Taille octets
function New-Gros([byte[]]$Octets, [int]$Taille) { @{ Octets = $Octets; Bourrage = $Taille - $Octets.Length } }

# Une appli telle que rendue par ConvertTo-Appli, avec les noms des champs de Rust (mindset_noyau::appli::Appli)
function ConvertTo-JugeAppli($r) {
    [ordered]@{
        id = $r.Id; genre = $r.Type; nom = $r.Nom; couleur = $r.Couleur; app_id = $r.AppId; description = $r.Description
        presentation = $r.Presentation; depot = $r.Depot; zip = $r.Zip; dossier_zip = $r.DossierZip; exe = $r.Exe
        script = $r.Script; mutex = $r.Mutex; ancien_zip = $r.AncienZip; ancien_dossier_zip = $r.AncienDossierZip
        ancien_script = $r.AncienScript; ancien_mutex = $r.AncienMutex; afficher_fichier = $r.AfficherFichier
        afficher_signal = $r.AfficherSignal; desinstalleur = $r.Desinstalleur; donnees = $r.Donnees; admin = [bool]$r.Admin
        rappels = [bool]$r.Rappels; sans_droits_depuis = $r.SansDroitsDepuis; aide = $r.Aide; aide_exe = $r.AideExe
        cache_depuis = $r.CacheDepuis; confidentialite = $r.Confidentialite; logo = $r.Logo
        logo_epaisseur = ([double]$r.LogoEpaisseur).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }
}
function Get-IdsEntrees($Entrees) { , @(foreach ($e in @($Entrees)) { [string]$e.id }) }
function Get-NomsEntrees($Entrees) { , @(foreach ($e in @($Entrees)) { [string]$e.nom }) }

# ---------------------------------------------------------------------------------------------------------------
# Les entrées (convertir.json) : le texte JSON d'une entrée, lu comme dans une liste
# ---------------------------------------------------------------------------------------------------------------
$base = [ordered]@{ id = '"cafe-creme"'; type = '"rust"'; nom = '"Café crème"'; couleur = '"#12AB34"'; depot = '"JordanJacquot/CafeCreme"'
    zip = '"CafeCreme.zip"'; dossier_zip = '"CafeCreme"'; exe = '"CafeCreme.exe"' }
# Une entrée : la base, avec ces champs changés (texte JSON brut) ou retirés ($null)
function E([hashtable]$Champs = @{}, [switch]$Vide) {
    $o = [ordered]@{}
    if (-not $Vide) { foreach ($k in $base.Keys) { $o[$k] = $base[$k] } }
    foreach ($k in $Champs.Keys) { if ($null -eq $Champs[$k]) { $o.Remove($k) } else { $o[$k] = $Champs[$k] } }
    '{' + (@(foreach ($k in $o.Keys) { '"' + $k + '":' + $o[$k] }) -join ',') + '}'
}
function J([string]$Texte) { ConvertTo-Json -InputObject $Texte -Compress }

$casEntrees = New-Object Collections.Generic.List[object]
function C([string]$Nom, [string]$Entree, [string]$Origine = 'apps.json') { $casEntrees.Add(@{ Nom = $Nom; Entree = $Entree; Origine = $Origine }) }

$vraiesTexte = [IO.File]::ReadAllText((Join-Path $racine 'Mindset\fichiers\apps.json'), [Text.Encoding]::UTF8)
$vraies = @($vraiesTexte | ConvertFrom-Json | ForEach-Object { $_ })
foreach ($v in $vraies) { C "apps.json livré : $($v.id)" (ConvertTo-Json -InputObject $v -Compress -Depth 5) }
C 'la base (rust, sans script)' (E)
C 'la base, origine liste en ligne' (E) 'liste en ligne'
C 'la base, origine liste en ligne n° 4' (E @{ logo = '"C 1 2 3"' }) 'liste en ligne n° 4'
# le type
C 'type absent, script donné' (E @{ type = $null; script = '"fichiers\\Cafe.ps1"' })
C 'type absent, sans script' (E @{ type = $null })
C 'type null, script donné' (E @{ type = 'null'; script = '"fichiers\\Cafe.ps1"' })
C 'type powershell avec script' (E @{ type = '"powershell"'; script = '"fichiers\\Cafe.ps1"' })
C 'type powershell sans script' (E @{ type = '"powershell"' })
foreach ($t in '"Rust"', '"RUST"', '"rust\n"', '"rust\n\n"', '"go"', '""', '5', 'true', '["rust"]', '{"a":1}', '" rust"') { C "type $t" (E @{ type = $t }) }
# l'id
foreach ($t in '"Cafe"', '"CAFE-CREME"', '"café"', '"a b"', '""', '"-"', '"cafe\n"', '"cafe\n\n"', '"\ncafe"', '"cafe_creme"', '"cafe.creme"', '5', 'null', 'true', '["cafe"]', '{"x":"cafe"}', '"cafe\t"') { C "id $t" (E @{ id = $t }) }
C 'id absent' (E @{ id = $null })
# le nom
foreach ($t in '""', '"  "', '0', '5', '1.5', 'true', 'false', '["A","B"]', '["A"]', '[]', '[""]', '{"a":1}', '{}', 'null', '"Forêt"', '"Café-crème 2 !"', '"Nom\nsur deux lignes"') { C "nom $t" (E @{ nom = $t }) }
C 'nom absent' (E @{ nom = $null })
# la couleur
foreach ($t in '"#12ab34"', '"#12AB3"', '"#12AB345"', '"12AB34"', '12', '"#12AB34\n"', '"#GGGGGG"', '"#12AB34 "', '["#12AB34"]', 'null') { C "couleur $t" (E @{ couleur = $t }) }
C 'couleur absente' (E @{ couleur = $null })
# le dépôt
foreach ($t in '"a/b"', '"a/b/c"', '"a"', '"é/ü"', '"a b/c"', '"a/b\n"', '["a/b"]', '["x","a/b"]', '["a/b","c/d"]', '5', '"./.."', '"a_b/c-d.e"', '"/b"', '"a/"', '""', '"a\\b"') { C "dépôt $t" (E @{ depot = $t }) }
C 'dépôt absent' (E @{ depot = $null })
# le zip et son dossier
foreach ($t in '"a:b.zip"', '""', '"a\\b"', '"\n"', '"x\ny"', '["a.zip","b.zip"]', '"a*.zip"', '"a?.zip"', '"a<b"', '"a|b"', '"a\"b"', '5', '"Forêt.zip"', '" "') { C "zip $t" (E @{ zip = $t }) }
foreach ($t in '"a/b"', '""', '"Dossier avec espaces"', '7', '["x"]') { C "dossier_zip $t" (E @{ dossier_zip = $t }) }
C 'zip absent' (E @{ zip = $null })
# le programme
foreach ($t in '"Cafe.EXE"', '".exe"', '"..exe"', '"a.exe.bak"', '"a/b.exe"', '"a\\b.exe"', '"a.exe\n"', '"a.ex"', '"a .exe"', '"a.exe "', '"a:b.exe"', '5', '["a.exe"]', '"é.exe"') { C "exe $t" (E @{ exe = $t }) }
C 'exe absent' (E @{ exe = $null })
# le script
foreach ($t in '"fichiers\\Cafe.ps1"', '"..\\x.ps1"', '"a..b.ps1"', '"x.PS1"', '"x.ps1\n"', '"x y.ps1"', '"/x.ps1"', '"x.ps1.txt"', '"é.ps1"', '"x_1-2.ps1"', '""', '5', '["x.ps1"]', '["x.ps1","..\\y.ps1"]') {
    C "script $t (powershell)" (E @{ type = '"powershell"'; script = $t })
    C "script $t (rust)" (E @{ script = $t })
}
# le verrou, le signal d'affichage
foreach ($t in '"Local\\Cafe-Instance"', '"local\\x"', '"LOCAL\\x.y_z"', '"Global\\x"', '"Local\\"', '"Local\\a b"', '"Local\\x\n"', '"Local/x"', '0', '""', 'false', '5', '["Local\\x"]') {
    C "mutex $t" (E @{ mutex = $t })
    C "afficher_signal $t" (E @{ afficher_signal = $t })
    C "ancien_mutex $t" (E @{ ancien_mutex = $t })
}
# les versions
foreach ($t in '"1.0"', '"1"', '"1.0.0.0.0"', '"1.0.0.0"', '"a.b"', '1.5', '2', '"1.0\n"', '"1.0 "', '" 1.0"', '"1..0"', '"01.002"', '""', '0', '["1.0"]') {
    C "cache_depuis $t" (E @{ cache_depuis = $t })
    C "sans_droits_depuis $t" (E @{ sans_droits_depuis = $t })
}
# le désinstalleur, le fichier d'affichage
foreach ($t in '"Désinstaller Café.exe"', '"x\\y.exe"', '"x.bat"', '"x.exe\n"', '""', '3') { C "desinstalleur $t" (E @{ desinstalleur = $t }) }
foreach ($t in '"afficher.demande"', '"a/b"', '"a:b"', '"Forêt.txt"', '""', '"x\ny"') { C "afficher_fichier $t" (E @{ afficher_fichier = $t }) }
# l'aide
C 'aide et son programme' (E @{ aide = '"Cafe (aide)"'; aide_exe = '"CafeAide.exe"' })
C 'aide sans programme' (E @{ aide = '"Cafe (aide)"' })
C 'programme d''aide sans aide' (E @{ aide_exe = '"..\\CafeAide.exe"' })
foreach ($t in '"cafe (Aide)"', '"Café (aide)"', '"(aide)"', '" (aide)"', '"Cafe(aide)"', '"Cafe (aide)\n"', ('"' + ('A' * 40) + ' (aide)"'), ('"' + ('A' * 41) + ' (aide)"'), '"Cafe Creme 2 (aide)"', '"Cafe-Creme (aide)"', '5') {
    C "aide $t" (E @{ aide = $t; aide_exe = '"CafeAide.exe"' })
}
C 'aide, programme mal écrit' (E @{ aide = '"Cafe (aide)"'; aide_exe = '"Cafe\\Aide.exe"' })
# les anciens noms
foreach ($t in '"OptiGame.zip"', '"a/b.zip"', '""') { C "ancien_zip $t" (E @{ ancien_zip = $t }); C "ancien_dossier_zip $t" (E @{ ancien_dossier_zip = $t }) }
foreach ($t in '"fichiers\\OptiGame.ps1"', '"..\\x.ps1"', '"x.txt"', '"x.ps1\n"') { C "ancien_script $t" (E @{ ancien_script = $t }) }
# le logo
foreach ($t in '"M14,52 L31,52 L38,31"', '"m1 l2 3"', '"C 1 2 3"', ('"M' + ('1' * 239) + '"'), ('"M' + ('1' * 240) + '"'), '"M"', '"M1"', '"M12"', '"L1 M2"', '5', '""', '"M1 2\n"', '"M1,2;3"', '["M1","2"]', '{"a":1}', 'true', '"M1.5 2.5"') { C "logo $t" (E @{ logo = $t }) }
# la page de confidentialité
foreach ($t in '"https://github.com/JordanJacquot/Cafe/blob/main/CODE_SIGNING.md"', '"http://github.com/JordanJacquot/Cafe/blob/main/A.md"', '"https://github.com/Autre/Cafe/blob/main/A.md"', '"https://github.com/JordanJacquot/Cafe/blob/main/A.md\n"', '"https://GITHUB.com/JordanJacquot/Cafe/blob/main/A.md"', '"https://github.com/JordanJacquot/Cafe/blob/dev/A.md"', '"https://github.com/JordanJacquot/Cafe/blob/main/A.txt"', '"https://github.com/JordanJacquot/Cafe/blob/main/dossier/A.md"', '""', '5') { C "confidentialite $t" (E @{ confidentialite = $t }) }
# l'épaisseur du logo
foreach ($t in '12', '4', '25', '3.9', '25.1', '"8"', '"8,5"', '"8.5"', '"abc"', 'null', 'true', '" 8 "', '"1e1"', '"Infinity"', '"-Infinity"', '8.50', '"+9"', '"9."', '".5"', '"0x10"', '[8]', '[8,9]', '1E1', '"10e0"', '-5', '"   "') { C "logo_epaisseur $t" (E @{ logo_epaisseur = $t }) }
# droits, rappels
foreach ($t in 'true', 'false', '"false"', '0', '1', '[]', '[false]', '[true]', '""', 'null', '"0"', '{}', '0.0') { C "admin $t" (E @{ admin = $t }) }
foreach ($t in 'true', 'false', '"true"', '"TRUE"', '"True"', '1', '2', '1.0', '"1"', '[true]', '[false,true]', '[false]', 'null', '"yes"', '{}', '0', '[1]', '["true"]') { C "rappels $t" (E @{ rappels = $t }) }
# le dossier de données (variables d'environnement)
foreach ($t in '"%LOCALAPPDATA%\\Cafe"', '"%localappdata%\\Cafe"', '"%MINDSET_ESSAI_FORET%\\x"', '"%INCONNUE_XYZ_123%\\x"', '"%%"', '"100%"', '"%LOCALAPPDATA%%MINDSET_ESSAI_FORET%"', '"%INCONNUE_XYZ_123%LOCALAPPDATA%"', '"a%b%c"', '5', '["%LOCALAPPDATA%","x"]', '""', '"%"', '"%%LOCALAPPDATA%%"') { C "donnees $t" (E @{ donnees = $t }) }
# les textes libres
foreach ($t in '5', '1.25', '["un","deux"]', '{"a":1}', 'true', 'null', '"Une phrase, avec une virgule"') { C "description $t" (E @{ description = $t; presentation = $t }) }
# pas un objet
foreach ($t in '"texte"', '5', 'null', '[1,2]', 'true', '[]', '[{"id":"cafe"}]') { C "entrée $t" $t }
# les noms des champs ne tiennent pas compte des majuscules
C 'champs en majuscules (ID, Nom, EXE...)' '{"ID":"cafe","Type":"rust","NOM":"Café","Couleur":"#12AB34","Depot":"a/b","Zip":"a.zip","Dossier_Zip":"a","EXE":"a.exe","Logo":"M1 2 3","Admin":true}'
C 'deux champs id à la casse près (illisible)' '{"id":"cafe","Id":"autre","nom":"x","couleur":"#12AB34","depot":"a/b","zip":"a.zip","dossier_zip":"a","exe":"a.exe","type":"rust"}'
C 'champs inconnus en plus' (E @{ inconnu = '"x"'; autre = '[1,{"b":2}]' })
C 'entrée vide {}' '{}'
C 'nom pour AppId' (E @{ nom = '"Mon Appli 2 (béta)!"' })

# Au hasard (graine fixe) : des entrées faites de morceaux pris dans des réserves de bonnes et de mauvaises valeurs
$alea = New-Object Random $Graine
$reserves = [ordered]@{
    id = @('"cafe"', '"foret-2"', '"Cafe"', '"a b"', '""', '5', '"x\n"', '"é"')
    type = @('"rust"', '"powershell"', '"Rust"', 'null', '5')
    nom = @('"Café"', '"Forêt verte"', '""', '0', '7', '["a"]')
    couleur = @('"#12AB34"', '"#abcdef"', '"#12AB3"', '5', '"#12AB34\n"')
    depot = @('"a/b"', '"JordanJacquot/Foret"', '"a"', '"a/b/c"', '["a/b"]')
    zip = @('"a.zip"', '"a:b"', '""', '"Forêt.zip"')
    dossier_zip = @('"a"', '"a/b"', '""')
    exe = @('"a.exe"', '"a.EXE"', '"a.bat"', '"a\\b.exe"', '".exe"')
    script = @('"a.ps1"', '"..\\a.ps1"', '"fichiers\\a.ps1"', '""', '"a.txt"')
    mutex = @('"Local\\a"', '"Global\\a"', '""', '"Local\\a b"')
    afficher_signal = @('"Local\\a-Afficher"', '"x"')
    cache_depuis = @('"1.0.5"', '"x"', '"1"')
    desinstalleur = @('"D.exe"', '"D\\x.exe"')
    afficher_fichier = @('"afficher.demande"', '"a/b"')
    aide = @('"A (aide)"', '"a (Aide)"')
    aide_exe = @('"AAide.exe"', '"A\\B.exe"')
    sans_droits_depuis = @('"1.2.3"', '"a"')
    ancien_zip = @('"O.zip"', '"O:zip"')
    ancien_script = @('"o.ps1"', '"..\\o.ps1"')
    ancien_mutex = @('"Local\\O"', '"O"')
    logo = @('"M1 2 L3 4"', '"C 1"', '"m1 1 1"', '5')
    logo_epaisseur = @('12', '3', '"20"', '"x"', '24.5')
    confidentialite = @('"https://github.com/JordanJacquot/A/blob/main/A.md"', '"https://exemple.fr/a.md"')
    admin = @('true', 'false', '"false"', '0')
    rappels = @('true', '"true"', '1', 'false')
    donnees = @('"%LOCALAPPDATA%\\A"', '"%INCONNUE_XYZ_123%"', '"C:\\x"')
    description = @('"Une appli"', '5', '["a","b"]')
}
for ($i = 0; $i -lt $NombreHasard; $i++) {
    $champs = [ordered]@{}
    foreach ($k in $reserves.Keys) {
        # (les champs obligatoires sont souvent là, les autres moins)
        $proba = if ($k -in 'id', 'nom', 'couleur', 'depot', 'zip', 'dossier_zip', 'exe') { 0.92 } else { 0.3 }
        if ($alea.NextDouble() -lt $proba) { $r = $reserves[$k]; $champs[$k] = $r[$alea.Next($r.Count)] }
    }
    $texte = '{' + (@(foreach ($k in $champs.Keys) { '"' + $k + '":' + $champs[$k] }) -join ',') + '}'
    $casEntrees.Add(@{ Nom = "hasard $i"; Entree = $texte; Origine = 'liste en ligne'; Hasard = $true })
}

# ---------------------------------------------------------------------------------------------------------------
# Les dossiers (listes.json, hasard.json)
# ---------------------------------------------------------------------------------------------------------------
$cle = New-CleTest
$autreCle = New-CleTest
$appsLivre = T $vraiesTexte
$nouvelle = [pscustomobject][ordered]@{ id = 'nouvelle'; type = 'rust'; nom = 'Nouvelle'; couleur = '#12AB34'; description = 'Une appli de test'
    depot = 'JordanJacquot/Nouvelle'; zip = 'Nouvelle.zip'; dossier_zip = 'Nouvelle'; exe = 'Nouvelle.exe'; mutex = 'Local\Nouvelle-Instance' }
$foret = [pscustomobject][ordered]@{ id = 'foret'; type = 'rust'; nom = 'Forêt'; couleur = '#2E8B57'; depot = 'JordanJacquot/Foret'; zip = 'Foret.zip'
    dossier_zip = 'Foret'; exe = 'Foret.exe'; logo = 'C 1 2'; confidentialite = 'https://exemple.fr/a.md' }
$mauvaise = [pscustomobject]@{ id = 'Pas Bon!'; nom = 'Piege'; couleur = '#000000'; depot = 'a/b'; zip = 'P.zip'; dossier_zip = 'P'; exe = 'P.exe'; type = 'rust' }
$piegee = [pscustomobject]@{ id = 'piege'; nom = 'Piege'; couleur = '#000000'; depot = 'a/b'; zip = 'P.zip'; dossier_zip = 'P'; exe = 'P.exe'; script = '..\..\piege.ps1' }
# (bien formée pour la règle simple de suite-commun, refusée par ConvertTo-Appli : couleur absente ; puis la bonne, même id)
$sansCouleur = [pscustomobject]@{ id = 'nouvelle'; type = 'rust'; nom = 'Sans couleur'; depot = 'a/b'; zip = 'S.zip'; dossier_zip = 'S'; exe = 'S.exe' }
$double = [pscustomobject]@{ id = 'nouvelle'; type = 'rust'; nom = 'Doublon'; couleur = '#000000'; depot = 'a/b'; zip = 'D.zip'; dossier_zip = 'D'; exe = 'D.exe' }
$applisListe = @($vraies) + $nouvelle

function New-Liste([long]$Numero = 4, [string]$Min = '2.16.0', $Applis = $applisListe) {
    T (ConvertTo-Json -InputObject ([ordered]@{ liste = $Numero; mindset_min = $Min; applis = @($Applis) }) -Depth 6)
}
function S([byte[]]$Json, [string]$Privee = $cle.Privee) { Get-Sig $Json $Privee }

$casListes = New-Object Collections.Generic.List[object]
# Un cas : Op (numero | en_ligne | gardee | entrees | ajouter | applis | recevoir), et ses fichiers ; voir Invoke-Cas
function L([string]$Nom, [hashtable]$P) {
    $c = @{ Nom = $Nom; Op = 'entrees'; Version = '3.0.0'; Apps = $appsLivre; Numero = (T "3`r`n"); AvecGardee = $true; Gardee = $null; GardeeSig = $null
        Json = $null; Sig = $null; NumeroMin = 3; Erreur = $null }
    foreach ($k in $P.Keys) { $c[$k] = $P[$k] }
    $casListes.Add($c)
}
# Une liste gardée bonne, et sa signature
function G([byte[]]$Json) { @{ Gardee = $Json; GardeeSig = (S $Json) } }
function Add-Champs([hashtable]$A, [hashtable]$B) { $r = @{}; foreach ($k in $A.Keys) { $r[$k] = $A[$k] }; foreach ($k in $B.Keys) { $r[$k] = $B[$k] }; $r }

# -- le numéro livré
foreach ($t in @("3`r`n", '12', ' 7 ', '0', '-1', '3.0', 'trois', '1234567890', '999999999', '', "3`n`n", '1 2', "$([char]0x663)", '+3', "`t5`t")) {
    L "numéro livré « $($t.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')) »" @{ Op = 'numero'; Numero = (T $t) }
}
L 'numéro livré avec une marque UTF-8' @{ Op = 'numero'; Numero = [byte[]](@(0xEF, 0xBB, 0xBF) + (T '12')) }
L 'numéro livré en UTF-16' @{ Op = 'numero'; Numero = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes('8')) }
L 'numéro livré absent' @{ Op = 'numero'; Numero = $null }

# -- une liste en ligne jugée (Read-ListeEnLigne)
$j4 = New-Liste
L 'bonne liste' @{ Op = 'en_ligne'; Json = $j4; Sig = (S $j4) }
$jb = [byte[]](@(0xEF, 0xBB, 0xBF) + $j4)
L 'bonne liste avec marque UTF-8' @{ Op = 'en_ligne'; Json = $jb; Sig = (S $jb) }
$jbb = [byte[]](@(0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF) + $j4)
L 'deux marques UTF-8' @{ Op = 'en_ligne'; Json = $jbb; Sig = (S $jbb) }
L 'signée par une autre clé' @{ Op = 'en_ligne'; Json = $j4; Sig = (S $j4 $autreCle.Privee) }
L 'signature vide' @{ Op = 'en_ligne'; Json = $j4; Sig = [byte[]]@() }
L 'signature tronquée' @{ Op = 'en_ligne'; Json = $j4; Sig = [byte[]]((S $j4)[0..100]) }
L 'modifiée après signature' @{ Op = 'en_ligne'; Json = (New-Liste 4 '2.16.0' $vraies); Sig = (S $j4) }
L 'liste vide (0 octet)' @{ Op = 'en_ligne'; Json = [byte[]]@(); Sig = (S (T 'x')) }
$gros = New-Gros $j4 (256KB + 1); $grosO = Get-OctetsBloc $gros
L 'trop grosse (256 Ko + 1)' @{ Op = 'en_ligne'; Json = $gros; Sig = (S $grosO) }
$juste = New-Gros $j4 (256KB); $justeO = Get-OctetsBloc $juste
L 'juste 256 Ko' @{ Op = 'en_ligne'; Json = $juste; Sig = (S $justeO) }
L 'trop grosse et mal signée' @{ Op = 'en_ligne'; Json = $gros; Sig = [byte[]]@(1, 2, 3) }
foreach ($b in @(
        @('UTF-8 invalide', [byte[]](@(0xC3, 0x28) + (T '{}'))),
        @('JSON abîmé', (T '{ "liste": 5, "mindset_min": "2.16.0", "applis": [ { "id": ')),
        @('texte null', (T 'null')), @('nombre seul', (T '5')), @('tableau', (T '[1,2]')), @('texte seul', (T '"x"')),
        @('espaces seuls', (T '   ')), @('vrai', (T 'true')),
        @('champ Liste en majuscules', (T '{"Liste":4,"mindset_min":"2.16.0","applis":[{"id":"a"}]}')),
        @('champs liste et Liste', (T '{"liste":4,"Liste":5,"mindset_min":"2.16.0","applis":[{"id":"a"}]}')),
        @('champ Mindset_min', (T '{"liste":4,"Mindset_min":"2.16.0","applis":[{"id":"a"}]}')),
        @('champ Applis', (T '{"liste":4,"mindset_min":"2.16.0","Applis":[{"id":"a"}]}')),
        @('liste texte', (T '{"liste":"4","mindset_min":"2.16.0","applis":[1]}')),
        @('liste 0', (T '{"liste":0,"mindset_min":"2.16.0","applis":[1]}')),
        @('liste -2', (T '{"liste":-2,"mindset_min":"2.16.0","applis":[1]}')),
        @('liste 4.0', (T '{"liste":4.0,"mindset_min":"2.16.0","applis":[1]}')),
        @('liste 4.5', (T '{"liste":4.5,"mindset_min":"2.16.0","applis":[1]}')),
        @('liste 1e1', (T '{"liste":1e1,"mindset_min":"2.16.0","applis":[1]}')),
        @('liste vrai', (T '{"liste":true,"mindset_min":"2.16.0","applis":[1]}')),
        @('liste null', (T '{"liste":null,"mindset_min":"2.16.0","applis":[1]}')),
        @('liste énorme', (T '{"liste":9223372036854775808,"mindset_min":"2.16.0","applis":[1]}')),
        @('mindset_min 2.16', (T '{"liste":4,"mindset_min":"2.16","applis":[1]}')),
        @('mindset_min 2.16.0.1', (T '{"liste":4,"mindset_min":"2.16.0.1","applis":[1]}')),
        @('mindset_min nombre', (T '{"liste":4,"mindset_min":2.16,"applis":[1]}')),
        @('mindset_min v2.16.0', (T '{"liste":4,"mindset_min":"v2.16.0","applis":[1]}')),
        @('mindset_min avec retour à la ligne', (T '{"liste":4,"mindset_min":"2.16.0\n","applis":[1]}')),
        @('mindset_min 10 chiffres', (T '{"liste":4,"mindset_min":"1234567890.0.0","applis":[1]}')),
        @('mindset_min null', (T '{"liste":4,"mindset_min":null,"applis":[1]}')),
        @('applis vide', (T '{"liste":4,"mindset_min":"2.16.0","applis":[]}')),
        @('applis objet', (T '{"liste":4,"mindset_min":"2.16.0","applis":{"id":"a"}}')),
        @('applis texte', (T '{"liste":4,"mindset_min":"2.16.0","applis":"a"}')),
        @('applis null', (T '{"liste":4,"mindset_min":"2.16.0","applis":null}')),
        @('applis sans aucune bonne', (T '{"liste":4,"mindset_min":"2.16.0","applis":[1,"a",null]}')),
        @('mindset_min 02.016.000 et une bonne appli', (T '{"liste":4,"mindset_min":"02.016.000","applis":[{"id":"a","type":"rust","nom":"A","couleur":"#123456","depot":"a/b","zip":"a.zip","dossier_zip":"a","exe":"a.exe"}]}'))
    )) {
    L "forme : $($b[0])" @{ Op = 'en_ligne'; Json = $b[1]; Sig = (S $b[1]) }
}
foreach ($m in '3.0.0', '3.0.1', '2.99.99', '10.0.0', '0.0.0', '3.1.0') { $j = New-Liste 4 $m; L "mindset_min $m pour Mindset 3.0.0" @{ Op = 'en_ligne'; Json = $j; Sig = (S $j) } }
$j = New-Liste 4 '3.0.0'
L 'mindset_min 3.0.0 pour un Mindset 3.0 (deux nombres)' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j); Version = '3.0' }
L 'version de ce Mindset illisible' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j); Version = 'abc' }
L 'version de ce Mindset vide' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j); Version = '' }
L 'mindset_min 3.0.0 pour un Mindset 3.0.0.1' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j); Version = '3.0.0.1' }
foreach ($n in @(@(4, 4), @(4, 5), @(4, 3), @(1, 0), @(99999999999, 3), @(4, -1))) { $j = New-Liste $n[0]; L "liste n° $($n[0]), minimum $($n[1])" @{ Op = 'en_ligne'; Json = $j; Sig = (S $j); NumeroMin = $n[1] } }
$j = New-Liste 4 '2.16.0' (@($vraies) + $mauvaise + $nouvelle + $piegee + 'texte' + $null + $foret)
L 'entrées mal formées ignorées' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j) }
$j = New-Liste 4 '2.16.0' ($applisListe + $double)
L 'id en double, la première compte' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j) }
$j = New-Liste 4 '2.16.0' (@($sansCouleur) + $applisListe)
L 'id en double, la première refusée : la seconde compte' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j) }
$j = New-Liste 4 '2.16.0' @($mauvaise, $piegee)
L 'aucune entrée valable' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j) }
$j = New-Liste 4 '2.16.0' @($sansCouleur)
L 'seulement une entrée sans couleur' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j) }
$j = T '{"liste":4,"mindset_min":"2.16.0","applis":[{"id":"a","type":"rust","nom":"A","couleur":"#123456","depot":"a/b","zip":"a.zip","dossier_zip":"a","exe":"a.exe"},{"id":"A","type":"rust","nom":"B","couleur":"#123456","depot":"a/b","zip":"a.zip","dossier_zip":"a","exe":"a.exe"}]}'
L 'ids a et A (comparés exactement)' @{ Op = 'en_ligne'; Json = $j; Sig = (S $j) }

# -- la liste gardée (Read-ListeGardee)
$g4 = G $j4
L 'gardée : pas de chemin' @{ Op = 'gardee'; AvecGardee = $false }
L 'gardée : pas de fichier' @{ Op = 'gardee' }
L 'gardée : bonne' (Add-Champs @{ Op = 'gardee' } $g4)
L 'gardée : signature absente' @{ Op = 'gardee'; Gardee = $j4 }
L 'gardée : signature seule' @{ Op = 'gardee'; GardeeSig = (S $j4) }
L 'gardée : numéro livré illisible' (Add-Champs @{ Op = 'gardee'; Numero = (T 'x') } $g4)
L 'gardée : numéro livré absent' (Add-Champs @{ Op = 'gardee'; Numero = $null } $g4)
L 'gardée : trop grosse sur le disque' @{ Op = 'gardee'; Gardee = $gros; GardeeSig = (S $grosO) }
L 'gardée : signature trop grosse sur le disque' @{ Op = 'gardee'; Gardee = $j4; GardeeSig = (New-Gros (S $j4) (64KB + 1)) }
L 'gardée : modifiée' @{ Op = 'gardee'; Gardee = (T ([Text.Encoding]::UTF8.GetString($j4).Replace('#12AB34', '#FF0000'))); GardeeSig = (S $j4) }
L 'gardée : devenue trop ancienne (livrée n° 10)' (Add-Champs @{ Op = 'gardee'; Numero = (T '10') } $g4)
L 'gardée : pour un Mindset plus récent' (Add-Champs @{ Op = 'gardee'; Version = '2.15.0' } $g4)
L 'gardée : fichier vide' @{ Op = 'gardee'; Gardee = [byte[]]@(); GardeeSig = (S $j4) }

# -- les entrées à utiliser (Get-EntreesApplis)
L 'entrées : sans liste gardée' @{ Op = 'entrees' }
L 'entrées : sans chemin de liste gardée' @{ Op = 'entrees'; AvecGardee = $false }
L 'entrées : liste gardée bonne' (Add-Champs @{ Op = 'entrees' } $g4)
L 'entrées : liste gardée sans signature' @{ Op = 'entrees'; Gardee = $j4 }
L 'entrées : liste gardée modifiée' @{ Op = 'entrees'; Gardee = (New-Liste 5); GardeeSig = (S $j4) }
L 'entrées : liste gardée, numéro livré illisible' (Add-Champs @{ Op = 'entrees'; Numero = (T 'x') } $g4)
L 'entrées : apps.json absent' @{ Op = 'entrees'; Apps = $null }
L 'entrées : apps.json abîmé' @{ Op = 'entrees'; Apps = (T '[ { "id": ') }
L 'entrées : apps.json abîmé, liste gardée bonne' (Add-Champs @{ Op = 'entrees'; Apps = (T '[ { "id": ') } $g4)
L 'entrées : apps.json un seul objet' @{ Op = 'entrees'; Apps = (T '{"id":"seule","nom":"Seule"}') }
L 'entrées : apps.json null' @{ Op = 'entrees'; Apps = (T 'null') }
L 'entrées : apps.json vide' @{ Op = 'entrees'; Apps = (T '') }
L 'entrées : apps.json espaces' @{ Op = 'entrees'; Apps = (T "  `r`n ") }
L 'entrées : apps.json tableau vide' @{ Op = 'entrees'; Apps = (T '[]') }
L 'entrées : apps.json nombre' @{ Op = 'entrees'; Apps = (T '5') }
L 'entrées : apps.json avec marque UTF-8' @{ Op = 'entrees'; Apps = [byte[]](@(0xEF, 0xBB, 0xBF) + (T '[{"id":"a"}]')) }
L 'entrées : apps.json en UTF-16' @{ Op = 'entrees'; Apps = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes('[{"id":"forêt"}]')) }
L 'entrées : apps.json, deux champs à la casse près' @{ Op = 'entrees'; Apps = (T '[{"id":"a","ID":"b"}]') }
L 'entrées : apps.json, numéro livré absent' @{ Op = 'entrees'; Numero = $null }

# -- une liste téléchargée proposée (Add-ListeEnLigne)
$j5 = New-Liste 5; $g5 = G $j5
L 'ajouter : première liste' @{ Op = 'ajouter'; Json = $j4; Sig = (S $j4) }
L 'ajouter : première liste, avec marque' @{ Op = 'ajouter'; Json = $jb; Sig = (S $jb) }
L 'ajouter : même numéro que la gardée, contenu différent' (Add-Champs @{ Op = 'ajouter'; Json = (New-Liste 4 '2.16.0' $vraies); Sig = (S (New-Liste 4 '2.16.0' $vraies)) } $g4)
L 'ajouter : plus récente que la gardée' (Add-Champs @{ Op = 'ajouter'; Json = $j5; Sig = (S $j5) } $g4)
L 'ajouter : plus ancienne que la gardée' (Add-Champs @{ Op = 'ajouter'; Json = $j4; Sig = (S $j4) } $g5)
$j3 = New-Liste 3; $j2 = New-Liste 2
L 'ajouter : même numéro que la livrée' @{ Op = 'ajouter'; Json = $j3; Sig = (S $j3) }
L 'ajouter : plus ancienne que la livrée' @{ Op = 'ajouter'; Json = $j2; Sig = (S $j2) }
L 'ajouter : numéro livré illisible' @{ Op = 'ajouter'; Json = $j4; Sig = (S $j4); Numero = (T 'trois') }
L 'ajouter : numéro livré absent' @{ Op = 'ajouter'; Json = $j4; Sig = (S $j4); Numero = $null }
L 'ajouter : gardée modifiée (ignorée), la nouvelle prend sa place' @{ Op = 'ajouter'; Json = $j4; Sig = (S $j4); Gardee = $j5; GardeeSig = (S $j4) }
L 'ajouter : gardée pour un Mindset plus récent (ignorée)' @{ Op = 'ajouter'; Json = $j4; Sig = (S $j4); Gardee = (New-Liste 7 '9.0.0'); GardeeSig = (S (New-Liste 7 '9.0.0')) }
L 'ajouter : mal signée, la gardée reste' (Add-Champs @{ Op = 'ajouter'; Json = $j5; Sig = (S $j5 $autreCle.Privee) } $g4)
L 'ajouter : signature vide' @{ Op = 'ajouter'; Json = $j4; Sig = [byte[]]@() }
L 'ajouter : trop grosse' @{ Op = 'ajouter'; Json = $gros; Sig = (S $grosO) }
L 'ajouter : pour un Mindset plus récent' @{ Op = 'ajouter'; Json = (New-Liste 4 '3.0.1'); Sig = (S (New-Liste 4 '3.0.1')) }
L 'ajouter : signature gardée seule (sans liste)' @{ Op = 'ajouter'; Json = $j4; Sig = (S $j4); GardeeSig = (S $j2) }
L 'ajouter : liste gardée sans signature' @{ Op = 'ajouter'; Json = $j4; Sig = (S $j4); Gardee = $j5 }
$jm = New-Liste 4 '2.16.0' (@($vraies) + $mauvaise + $foret)
L 'ajouter : entrées refusées et logo ignoré, notés au journal' @{ Op = 'ajouter'; Json = $jm; Sig = (S $jm) }
L 'ajouter : la même que la gardée, avec un logo ignoré' (Add-Champs @{ Op = 'ajouter'; Json = $jm; Sig = (S $jm) } (G $jm))

# -- Get-Applis
L 'applis : apps.json livré' @{ Op = 'applis' }
L 'applis : liste gardée bonne' (Add-Champs @{ Op = 'applis' } $g4)
L 'applis : liste gardée avec un logo ignoré' (Add-Champs @{ Op = 'applis' } (G $jm))
L 'applis : liste gardée pour un Mindset plus récent' (Add-Champs @{ Op = 'applis'; Version = '2.15.0' } $g4)
L 'applis : apps.json abîmé' @{ Op = 'applis'; Apps = (T '[ { "id": ') }
L 'applis : apps.json absent' @{ Op = 'applis'; Apps = $null }
L 'applis : apps.json, entrées refusées et doublons' @{ Op = 'applis'; Apps = (T (ConvertTo-Json -InputObject (@($vraies) + $mauvaise + $nouvelle + $double + $piegee + 'texte' + $foret + $sansCouleur) -Depth 6)) }
L 'applis : apps.json, champs en majuscules' @{ Op = 'applis'; Apps = (T '[{"ID":"cafe","Type":"rust","NOM":"Café","Couleur":"#12AB34","Depot":"a/b","Zip":"a.zip","Dossier_Zip":"a","EXE":"a.exe"}]') }
L 'applis : apps.json un seul objet' @{ Op = 'applis'; Apps = (T (ConvertTo-Json -InputObject $nouvelle)) }
L 'applis : apps.json null' @{ Op = 'applis'; Apps = (T 'null') }
L 'applis : sans chemin de liste gardée' (Add-Champs @{ Op = 'applis'; AvecGardee = $false } $g4)

# -- Receive-ListeEnLigne (la fin du téléchargement)
$j6 = New-Liste 6
L 'recevoir : erreur de téléchargement' @{ Op = 'recevoir'; Erreur = 'pas de connexion à Internet' }
L 'recevoir : rien reçu, sans erreur' @{ Op = 'recevoir' }
L 'recevoir : bonne liste' @{ Op = 'recevoir'; Json = $j6; Sig = (S $j6) }
L 'recevoir : bonne liste, gardée plus ancienne' (Add-Champs @{ Op = 'recevoir'; Json = $j6; Sig = (S $j6) } $g4)
L 'recevoir : la même que la gardée' (Add-Champs @{ Op = 'recevoir'; Json = $j4; Sig = (S $j4) } $g4)
L 'recevoir : mal signée' @{ Op = 'recevoir'; Json = $j6; Sig = (S $j6 $autreCle.Privee) }
L 'recevoir : trop ancienne' (Add-Champs @{ Op = 'recevoir'; Json = $j4; Sig = (S $j4) } $g5)
L 'recevoir : numéro livré illisible' @{ Op = 'recevoir'; Json = $j6; Sig = (S $j6); Numero = (T '') }
L 'recevoir : erreur et octets' @{ Op = 'recevoir'; Json = $j6; Sig = (S $j6); Erreur = 'délai dépassé' }

# -- au hasard (graine fixe) : des dossiers et des listes tirés au sort
$casHasard = New-Object Collections.Generic.List[object]
$poolEntrees = @($vraies) + $nouvelle + $foret + $mauvaise + $piegee + $double + $sansCouleur + 'texte'
function Get-Hasard($Liste) { $Liste[$alea.Next($Liste.Count)] }
for ($i = 0; $i -lt [math]::Max(40, [int]($NombreHasard / 2)); $i++) {
    $n = $alea.Next(0, 8)
    $min = Get-Hasard @('2.0.0', '3.0.0', '3.0.1', '9.9.9', '2.16.0')
    $entrees = @(for ($k = 0; $k -lt $alea.Next(1, 6); $k++) { Get-Hasard $poolEntrees })
    $j = New-Liste $n $min $entrees
    $sig = switch ($alea.Next(0, 5)) { 0 { S $j $autreCle.Privee } 1 { , [byte[]]@() } 2 { S (New-Liste ($n + 1) $min $entrees) } default { S $j } }
    $c = @{ Op = (Get-Hasard @('en_ligne', 'ajouter', 'ajouter', 'entrees', 'applis', 'recevoir', 'gardee')); Json = $j; Sig = $sig; NumeroMin = $alea.Next(0, 6)
        Numero = (T (Get-Hasard @('3', '1', '5', 'x', '0'))); Version = '3.0.0'; Apps = $appsLivre; AvecGardee = $true; Erreur = $null }
    switch ($alea.Next(0, 5)) {
        0 { }
        1 { $c = Add-Champs $c (G (New-Liste $alea.Next(1, 8) '2.0.0' $applisListe)) }
        2 { $c = Add-Champs $c @{ Gardee = (New-Liste 6); GardeeSig = (S $j4) } }
        3 { $c = Add-Champs $c @{ Gardee = $j }; if ($alea.Next(2)) { $c.GardeeSig = $sig } }
        4 { $c = Add-Champs $c (G (New-Liste $alea.Next(1, 8) $min $entrees)) }
    }
    if ($c.Op -eq 'gardee' -or $c.Op -eq 'entrees' -or $c.Op -eq 'applis') { if (-not $c.Gardee -and $alea.Next(2)) { $c = Add-Champs $c @{ Gardee = $j; GardeeSig = $sig } } }
    $c.Nom = "hasard $i"
    $p = @{}; foreach ($k in $c.Keys) { $p[$k] = $c[$k] }
    $casHasard.Add($p)
}

# ---------------------------------------------------------------------------------------------------------------
# Rejouer un cas sur les vraies fonctions
# ---------------------------------------------------------------------------------------------------------------
function Reset-Dossiers($c) {
    foreach ($d in $mindset, (Join-Path $tmp 'Donnees')) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
    New-Item -ItemType Directory -Force -Path (Join-Path $fichiers 'cles-publiques') | Out-Null
    [IO.File]::WriteAllText((Join-Path $fichiers 'cles-publiques\test.xml'), $cle.Publique, $utf8)
    if ($null -ne $c.Apps) { [IO.File]::WriteAllBytes((Join-Path $fichiers 'apps.json'), (Get-OctetsBloc $c.Apps)) }
    if ($null -ne $c.Numero) { [IO.File]::WriteAllBytes((Join-Path $fichiers 'apps-liste.txt'), (Get-OctetsBloc $c.Numero)) }
    if ($null -ne $c.Gardee -or $null -ne $c.GardeeSig) { New-Item -ItemType Directory -Force -Path $donnees | Out-Null }
    if ($null -ne $c.Gardee) { [IO.File]::WriteAllBytes($cheminGardee, (Get-OctetsBloc $c.Gardee)) }
    if ($null -ne $c.GardeeSig) { [IO.File]::WriteAllBytes("$cheminGardee.sig", (Get-OctetsBloc $c.GardeeSig)) }
}
function Get-Disque {
    $r = [ordered]@{ gardee = $null; sig = $null; autres = @() }
    if ([IO.File]::Exists($cheminGardee)) { $r.gardee = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cheminGardee)) }
    if ([IO.File]::Exists("$cheminGardee.sig")) { $r.sig = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$cheminGardee.sig")) }
    if (Test-Path -LiteralPath $donnees) { $r.autres = @(Get-ChildItem -LiteralPath $donnees -Force | Where-Object { $_.Name -notin 'apps-en-ligne.json', 'apps-en-ligne.json.sig' } | ForEach-Object { $_.Name }) }
    $r
}
function Get-ResultatListe($l) {
    if ($null -eq $l) { return $null }
    [ordered]@{ numero = [long]$l.Numero; mindset_min = $l.MindsetMin; ids = (Get-IdsEntrees $l.Entrees); noms = (Get-NomsEntrees $l.Entrees) }
}
function Invoke-Cas($c) {
    Reset-Dossiers $c
    $script:Journal.Clear()
    $gardee = if ($c.AvecGardee) { $cheminGardee } else { '' }
    $json = Get-OctetsBloc $c.Json; $sig = Get-OctetsBloc $c.Sig
    $r = [ordered]@{ ok = $true; erreur = $null; resultat = $null }
    try {
        switch ($c.Op) {
            'numero' { $r.resultat = [long](Get-NumeroListeLivree $fichiers) }
            'en_ligne' { $r.resultat = Get-ResultatListe (Read-ListeEnLigne $json $sig $fichiers $c.Version ([long]$c.NumeroMin)) }
            'gardee' { $r.resultat = Get-ResultatListe (Read-ListeGardee $gardee $fichiers $c.Version) }
            'entrees' {
                $l = Get-EntreesApplis $fichiers $gardee $c.Version
                $r.resultat = [ordered]@{ source = $l.Source; numero = [long]$l.Numero; ids = (Get-IdsEntrees $l.Entrees) }
            }
            'ajouter' { $r.resultat = Get-ResultatListe (Add-ListeEnLigne $json $sig $fichiers $gardee $c.Version) }
            'applis' {
                $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = $c.Version
                $r.resultat = @(foreach ($a in @(Get-Applis)) { ConvertTo-JugeAppli $a })
            }
            'recevoir' {
                $AppDir = $fichiers; $ListeGardee = $gardee; $AppVersion = $c.Version
                $script:DerniereListe = [datetime]::MinValue
                $res = if ($null -ne $json -or $null -ne $sig) { @{ Json = $json; Sig = $sig } } else { $null }
                Receive-ListeEnLigne $res $c.Erreur
                $r.resultat = [ordered]@{ reessai_dans_une_heure = ($script:DerniereListe -ne [datetime]::MinValue) }
            }
        }
    } catch { $r.ok = $false; $r.erreur = Format-Message $_.Exception.Message }
    $sortieCas = [ordered]@{
        nom = $c.Nom; op = $c.Op; version = $c.Version; avec_gardee = [bool]$c.AvecGardee; numero_min = [long]$c.NumeroMin; erreur_telechargement = $c.Erreur
        apps = (Get-Bloc $c.Apps); numero = (Get-Bloc $c.Numero); gardee = (Get-Bloc $c.Gardee); gardee_sig = (Get-Bloc $c.GardeeSig)
        json = (Get-Bloc $c.Json); sig = (Get-Bloc $c.Sig)
        attendu = [ordered]@{ ok = $r.ok; erreur = $r.erreur; resultat = $r.resultat; journal = @($script:Journal); disque = (Get-Disque) }
    }
    $sortieCas
}

# Un défaut de la version PowerShell, corrigé en Rust (voir rust\mindset-liste\DIVERGENCES.md) : dans Add-ListeEnLigne,
# [IO.File]::Replace($tmp, $x[0], $null) reçoit une chaîne VIDE (PowerShell change $null en '' pour un paramètre texte de
# .NET), et échoue (« Le chemin d'accès n'a pas une forme conforme ») : une fois une liste gardée, aucune liste plus
# récente ne la remplace jamais. Chaque cas est donc joué deux fois : tel quel, puis avec ce seul appel corrigé
# ([NullString]::Value : un vrai null). Le juge est la version corrigée ; la réponse d'aujourd'hui est notée à côté
# (« divergence_ps ») quand elle diffère.
$texteListe = [IO.File]::ReadAllText((Join-Path $modulesVrais 'liste.ps1'), [Text.Encoding]::UTF8)
$texteCorrige = $texteListe.Replace('[IO.File]::Replace($tmp, $x[0], $null)', '[IO.File]::Replace($tmp, $x[0], [NullString]::Value)')
if ($texteCorrige -eq $texteListe) { throw 'liste.ps1 : l''appel à [IO.File]::Replace a changé, revoir la correction des juges.' }
$sbCorrige = [scriptblock]::Create($texteCorrige)
function Invoke-CasDeuxFois($c) {
    $tel = Invoke-Cas $c
    . $sbCorrige
    $corrige = Invoke-Cas $c
    $corrige.divergence_ps = $null
    if ((ConvertTo-Json -InputObject $tel.attendu -Depth 12 -Compress) -cne (ConvertTo-Json -InputObject $corrige.attendu -Depth 12 -Compress)) {
        $corrige.divergence_ps = [ordered]@{ erreur = $tel.attendu.erreur; journal = $tel.attendu.journal; disque = $tel.attendu.disque }
    }
    $corrige
}

function Write-Juge([string]$Nom, $Objet) {
    New-Item -ItemType Directory -Force -Path $sortie | Out-Null
    [IO.File]::WriteAllText((Join-Path $sortie $Nom), (ConvertTo-Json -InputObject $Objet -Depth 12), $utf8)
}

try {
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $env:LOCALAPPDATA = $envJuge.LOCALAPPDATA; $env:MINDSET_ESSAI_FORET = $envJuge.MINDSET_ESSAI_FORET

    # convertir.json
    $sortieEntrees = New-Object Collections.Generic.List[object]
    foreach ($c in $casEntrees) {
        $script:Journal.Clear()
        $lisible = $true; $appli = $null
        try { $v = ConvertFrom-Json ('[' + $c.Entree + ']') -ErrorAction Stop } catch { $lisible = $false }
        if ($lisible) { $r = ConvertTo-Appli $v[0] $c.Origine; if ($r) { $appli = ConvertTo-JugeAppli $r } }
        $sortieEntrees.Add([ordered]@{ nom = $c.Nom; origine = $c.Origine; entree = $c.Entree; hasard = [bool]$c.Hasard; lisible = $lisible; appli = $appli; journal = @($script:Journal) })
    }
    $publique = $cle.Publique
    Write-Juge 'convertir.json' ([ordered]@{ source = 'outils\exporter-juges-liste.ps1 (ConvertTo-Appli de modules\liste.ps1)'; env = $envJuge; cas = $sortieEntrees })

    # listes.json, hasard.json
    $sortieListes = New-Object Collections.Generic.List[object]
    foreach ($c in $casListes) { $sortieListes.Add((Invoke-CasDeuxFois $c)) }
    Write-Juge 'listes.json' ([ordered]@{ source = 'outils\exporter-juges-liste.ps1 (modules\liste.ps1, Get-Applis et Receive-ListeEnLigne de modules\applis.ps1)'; env = $envJuge; cle_publique = $publique; cas = $sortieListes })
    $sortieHasard = New-Object Collections.Generic.List[object]
    foreach ($c in $casHasard) { $sortieHasard.Add((Invoke-CasDeuxFois $c)) }
    Write-Juge 'hasard.json' ([ordered]@{ source = "outils\exporter-juges-liste.ps1 (cas tirés au hasard, graine $Graine)"; env = $envJuge; cle_publique = $publique; cas = $sortieHasard })

    Write-Host "Juges écrits dans $sortie : $($sortieEntrees.Count) entrées, $($sortieListes.Count) dossiers, $($sortieHasard.Count) au hasard."
} finally {
    $env:LOCALAPPDATA = $envAvant.LOCALAPPDATA; $env:MINDSET_ESSAI_FORET = $envAvant.FORET
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch { Write-Host "Dossier de test non supprimé : $tmp" }
}
