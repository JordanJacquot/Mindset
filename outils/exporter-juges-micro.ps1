# Mindset : les juges du micro et du casque de la suite, pour le module Rust « micro » (rust\suite-commun).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\exporter-juges-micro.ps1 [-Projets D:\Projets]
#
# Chaque cas est un suite.json préparé (abîmé, vide, valeurs étranges...) et une fausse liste de micros et de sorties.
# Il est passé aux VRAIES fonctions PowerShell d'aujourd'hui, reprises telles quelles de leurs fichiers :
#   - Mindset   : Read-Suite (modules\suite.ps1, avec Read-JsonSur de donnees.ps1) ;
#   - Mindcare  : Read-Suite (modules\mindset.ps1) et Get-DicteeMicro (modules\dictee.ps1), le micro de la dictée ;
#   - Evermind  : Read-Suite (modules\mindset.ps1), puis Set-MicroActif et Set-CasqueActif (modules\voix.ps1).
# Leurs réponses sont écrites dans rust\suite-commun\src\micro\juges.json, que les tests Rust relisent.
#
# Rien du PC n'est lu ni touché : les fichiers sont dans un dossier temporaire sous %TEMP%, supprimé à la fin ; les
# micros sont une fausse liste (le code natif des applis n'est jamais chargé, aucun micro n'est ouvert). Les dépôts de
# Mindcare et d'Evermind sont seulement lus. Aucun droit administrateur, aucun réseau, rien dans le registre.

param([string]$Projets = 'D:\Projets')

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$sources = @{
    Mindset  = Join-Path $racine 'Mindset\fichiers\modules'
    Mindcare = Join-Path $Projets 'Mindcare\Mindcare\fichiers\modules'
    Evermind = Join-Path $Projets 'Evermind\Evermind\fichiers\modules'
}
$sortie = Join-Path $racine 'rust\suite-commun\src\micro\juges.json'

# Les fonctions d'un fichier, reprises telles quelles (leur texte exact)
function Get-Fonctions([string]$Fichier, [string[]]$Noms) {
    $erreurs = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Fichier, [ref]$null, [ref]$erreurs)
    if ($erreurs) { throw "$Fichier ne se lit pas : $($erreurs[0])" }
    $trouvees = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -in $Noms })
    foreach ($n in $Noms) { if (@($trouvees | Where-Object Name -eq $n).Count -ne 1) { throw "$n introuvable (ou en double) dans $Fichier" } }
    ($trouvees | ForEach-Object { $_.Extent.Text }) -join "`n"
}

$defMindset = (Get-Fonctions (Join-Path $sources.Mindset 'suite.ps1') 'Test-ThemeSuite', 'Test-NomAppareil', 'Read-Suite') + "`n" +
              (Get-Fonctions (Join-Path $sources.Mindset 'donnees.ps1') 'ConvertFrom-JsonObjet', 'Read-JsonSur')
$defMindcare = (Get-Fonctions (Join-Path $sources.Mindcare 'mindset.ps1') 'Get-CheminNormal', 'Test-SuitePrise', 'Read-Suite') + "`n" +
               (Get-Fonctions (Join-Path $sources.Mindcare 'dictee.ps1') 'Get-DicteeMicro')
$defEvermind = (Get-Fonctions (Join-Path $sources.Evermind 'mindset.ps1') 'Get-CheminNormal', 'Test-SuitePrise', 'Read-Suite') + "`n" +
               (Get-Fonctions (Join-Path $sources.Evermind 'voix.ps1') 'Set-MicroActif', 'Set-CasqueActif')

# Les faux appareils : les mêmes noms de classes que le code natif des applis (jamais chargé ici)
Add-Type -TypeDefinition @'
public static class FauxAudio { public static string[] Micros = new string[0]; public static string[] Sorties = new string[0]; }
public class MindcareMicro { public static string[] Noms() { return FauxAudio.Micros; } }
public static class EMMicros { public static uint Choisi = 0xFFFFFFFF; public static string[] Noms() { return FauxAudio.Micros; } }
public static class EMSortie { public static uint Choisi = 0xFFFFFFFF; public static string[] Noms() { return FauxAudio.Sorties; } }
'@

function Write-Log([string]$Message) { }
$ThemesSuite = @('neon', 'crepuscule', 'terminal', 'arcade', 'rubis')
$AppId = 'mindcare'

# ---------------------------------------------------------------------------------------------------------------
# Les cas : le contenu de suite.json (octets ; $null = pas de fichier), sa copie .bak, les micros et les sorties
# ---------------------------------------------------------------------------------------------------------------
$utf8 = New-Object Text.UTF8Encoding $false
function T([string]$Texte) { , $utf8.GetBytes($Texte) }
$usb = 'Micro USB (Realtek(R) Audio)'
$coupe = 'Microphone (2- USB Audio Device'   # 31 lettres : le nom que Windows donne, coupé
$micros = @('Microphone (Realtek(R) Audio)', $usb, 'Casque (Logitech G435)')
$sorties = @('Haut-parleurs (Realtek(R) Audio)', 'Casque (Logitech G435)')

$cas = [Collections.ArrayList]@()
function Add-Cas([string]$Nom, $Fichier, [string[]]$Micros = $micros, [string[]]$Sorties = $sorties, $Bak = $null) {
    # (des octets gardés tels quels : un $(...) en ferait une liste de nombres)
    $f = $null; if ($null -ne $Fichier) { $f = [byte[]]$Fichier }
    $b = $null; if ($null -ne $Bak) { $b = [byte[]]$Bak }
    [void]$cas.Add([ordered]@{ nom = $Nom; fichier = $f; bak = $b; micros = @($Micros); sorties = @($Sorties) })
}

Add-Cas 'pas de suite.json' $null
Add-Cas 'suite.json vide' (T '')
Add-Cas 'seulement des espaces' (T "  `r`n ")
Add-Cas 'abîmé (coupé en plein milieu)' (T '{"theme":"neon","micro":"Micro USB')
Add-Cas 'abîmé, copie .bak bonne' (T '{"micro":"Casque (Log') -Bak (T '{"theme":"neon","micro":"Casque (Logitech G435)","casque":""}')
Add-Cas 'du JSON, mais un tableau' (T '[1,2]')
Add-Cas 'un tableau d''un objet' (T "[{`"micro`":`"$usb`"}]")
Add-Cas 'une chaîne seule' (T '"Micro USB"')
Add-Cas 'null' (T 'null')
Add-Cas 'aucun choix (que le thème)' (T '{"theme":"neon","applis":{}}')
Add-Cas 'celui de Windows (vide)' (T '{"theme":"neon","micro":"","casque":""}')
Add-Cas 'choix présent' (T "{`"theme`":`"neon`",`"micro`":`"$usb`",`"casque`":`"Casque (Logitech G435)`"}")
Add-Cas 'choix présent, premier de la liste' (T '{"micro":"Microphone (Realtek(R) Audio)","casque":"Haut-parleurs (Realtek(R) Audio)"}')
Add-Cas 'choix débranché' (T '{"micro":"Micro Blue Yeti","casque":"Casque Bluetooth"}')
Add-Cas 'aucun micro sur le PC' (T "{`"micro`":`"$usb`"}") -Micros @() -Sorties @()
Add-Cas 'deux micros au même nom' (T "{`"micro`":`"$usb`"}") -Micros @('Microphone (Realtek(R) Audio)', $usb, $usb)
Add-Cas 'nom coupé à 31 lettres' (T "{`"micro`":`"$coupe`"}") -Micros @('Microphone (Realtek(R) Audio)', $coupe)
Add-Cas 'nom entier alors que Windows le coupe' (T "{`"micro`":`"$coupe)`"}") -Micros @('Microphone (Realtek(R) Audio)', $coupe)
Add-Cas 'majuscules différentes' (T '{"micro":"micro usb (realtek(r) audio)","casque":"CASQUE (LOGITECH G435)"}')
Add-Cas 'espace en plus à la fin' (T "{`"micro`":`"$usb `"}")
Add-Cas 'liste avec un nom vide' (T '{"micro":""}') -Micros @('', $usb)
Add-Cas 'choix présent après un nom vide' (T "{`"micro`":`"$usb`"}") -Micros @('', $usb)
Add-Cas 'clé en majuscules' (T "{`"MICRO`":`"$usb`",`"Casque`":`"Casque (Logitech G435)`"}")
Add-Cas 'clé en deux casses' (T "{`"micro`":`"$usb`",`"Micro`":`"Casque (Logitech G435)`"}")
Add-Cas 'clé en deux casses ailleurs (thème)' (T "{`"micro`":`"$usb`",`"theme`":`"neon`",`"Theme`":`"rubis`"}")
Add-Cas 'clé en deux casses plus loin (applis)' (T "{`"micro`":`"$usb`",`"applis`":{`"mindcare`":`"C:\\A`",`"MindCare`":`"C:\\B`"}}")
Add-Cas 'clé en deux casses dans un tableau' (T "{`"micro`":`"$usb`",`"x`":[{`"a`":1,`"A`":2}]}")
Add-Cas 'très grand nombre ailleurs' (T "{`"micro`":`"$usb`",`"n`":1e400}")
# (ConvertFrom-Json de Windows PowerShell 5.1 refuse un fichier qui va à plus de 102 niveaux, le premier compté)
Add-Cas 'imbriqué sur 102 niveaux (tableaux)' (T ("{`"micro`":`"$usb`",`"x`":" + ('[' * 101) + (']' * 101) + '}'))
Add-Cas 'imbriqué sur 103 niveaux (tableaux)' (T ("{`"micro`":`"$usb`",`"x`":" + ('[' * 102) + (']' * 102) + '}'))
Add-Cas 'imbriqué sur 102 niveaux (objets)' (T ("{`"micro`":`"$usb`",`"x`":" + ('{"a":' * 100) + '1' + ('}' * 100) + '}'))
Add-Cas 'imbriqué sur 103 niveaux (objets)' (T ("{`"micro`":`"$usb`",`"x`":" + ('{"a":' * 101) + '1' + ('}' * 101) + '}'))
Add-Cas 'clé en double'(T "{`"micro`":`"Micro Blue Yeti`",`"micro`":`"$usb`"}")
Add-Cas 'micro : un nombre' (T '{"micro":5,"casque":1.5}')
Add-Cas 'micro : vrai' (T '{"micro":true,"casque":false}')
Add-Cas 'micro : null' (T '{"micro":null,"casque":null}')
Add-Cas 'micro : un objet' (T "{`"micro`":{`"nom`":`"$usb`"},`"casque`":{}}")
Add-Cas 'micro : un tableau d''un nom' (T "{`"micro`":[`"$usb`"],`"casque`":[]}")
Add-Cas '64 lettres' (T ('{"micro":"' + ('A' * 64) + '"}')) -Micros @('A' * 64)
Add-Cas '65 lettres' (T ('{"micro":"' + ('A' * 65) + '"}')) -Micros @('A' * 65)
Add-Cas '62 lettres et un emoji (64 unités)' (T ('{"micro":"' + ('A' * 62) + '\ud83c\udfa4"}')) -Micros @(('A' * 62) + [char]0xD83C + [char]0xDFA4)
Add-Cas '63 lettres et un emoji (65 unités)' (T ('{"micro":"' + ('A' * 63) + '\ud83c\udfa4"}')) -Micros @(('A' * 63) + [char]0xD83C + [char]0xDFA4)
Add-Cas '64 lettres accentuées' (T ('{"micro":"' + ('é' * 64) + '"}')) -Micros @('é' * 64)
Add-Cas 'tabulation dans le nom' (T '{"micro":"Micro\tUSB","casque":"Casque\u0000"}') -Micros @("Micro`tUSB")
Add-Cas 'caractère 0x1F' (T '{"micro":"Micro\u001fUSB"}') -Micros @("Micro$([char]0x1F)USB")
Add-Cas 'caractère DEL (0x7F)' (T '{"micro":"Micro\u007fUSB"}') -Micros @("Micro$([char]0x7F)USB")
Add-Cas 'caractère de contrôle C1 (0x85)' (T '{"micro":"Micro\u0085USB"}') -Micros @("Micro$([char]0x85)USB")
Add-Cas 'accents écrits en \u' (T '{"micro":"Micro \u00e9t\u00e9","casque":"Casque d''\u00e9t\u00e9"}') -Micros @('Micro été')
Add-Cas 'marque UTF-8 (BOM)' ([byte[]]([byte[]](0xEF, 0xBB, 0xBF) + (T "{`"micro`":`"$usb`"}")))
Add-Cas 'UTF-16 avec sa marque' ([byte[]]([byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("{`"micro`":`"Micro été`"}"))) -Micros @('Micro été')
Add-Cas 'octet invalide dans le nom' ([byte[]]((T '{"micro":"Micro ') + [byte[]](0xE9) + (T 't"}'))) -Micros @("Micro $([char]0xFFFD)t", 'Micro ét')
Add-Cas 'virgule en trop' (T "{`"micro`":`"$usb`",}")
Add-Cas 'guillemets simples' (T "{'micro':'$usb'}")
Add-Cas 'texte après l''objet' (T "{`"micro`":`"$usb`"} x")
Add-Cas 'casque choisi, micro absent' (T '{"casque":"Casque (Logitech G435)"}')
Add-Cas 'casque débranché, micro présent' (T "{`"micro`":`"$usb`",`"casque`":`"Casque Bluetooth`"}")

# ---------------------------------------------------------------------------------------------------------------
# Les réponses des vraies fonctions
# ---------------------------------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "juges-micro-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$EnTest = $true
$env:MINDSET_DONNEES = $tmp   # (Read-JsonSur de Mindset ne touche qu'aux fichiers de ce dossier temporaire)

function Set-Fichiers($C, [string]$Dossier) {
    New-Item -ItemType Directory -Force -Path $Dossier | Out-Null
    $f = Join-Path $Dossier 'suite.json'
    if ($null -ne $C.fichier) { [IO.File]::WriteAllBytes($f, [byte[]]$C.fichier) }
    if ($null -ne $C.bak) { [IO.File]::WriteAllBytes("$f.bak", [byte[]]$C.bak) }
    [FauxAudio]::Micros = [string[]]@($C.micros)
    [FauxAudio]::Sorties = [string[]]@($C.sorties)
    $f
}

try {
    $n = 0
    foreach ($c in $cas) {
        $n++
        # Mindset (chaque appli a son propre dossier : Read-JsonSur de Mindset met de côté un fichier abîmé)
        $c.mindset = & {
            . ([scriptblock]::Create($defMindset))
            $SuiteFile = Set-Fichiers $c (Join-Path $tmp "$n\mindset")
            $s = Read-Suite
            [ordered]@{ illisible = [bool]$s.Illisible; micro = $s.micro; casque = $s.casque }
        }
        # Mindcare : ce que lit Read-Suite, et le numéro du micro donné à la dictée
        $c.mindcare = & {
            . ([scriptblock]::Create($defMindcare))
            $SuiteFile = Set-Fichiers $c (Join-Path $tmp "$n\mindcare")
            $s = Read-Suite 1
            [ordered]@{ micro = $s.Micro; numero = [uint32](Get-DicteeMicro) }
        }
        # Evermind (une copie gérée par Mindset) : le micro et le casque de la suite remplacent les siens quand ils sont
        # donnés ($null : il garde son réglage, ici celui de Windows), puis voix.ps1 cherche leur numéro
        $c.evermind = & {
            . ([scriptblock]::Create($defEvermind))
            $SuiteFile = Set-Fichiers $c (Join-Path $tmp "$n\evermind")
            $s = Read-Suite 1
            $reglages = @{ Micro = ''; Casque = '' }
            function Get-Setting($Cle, $Defaut) { if ($reglages.ContainsKey($Cle)) { $reglages[$Cle] } else { $Defaut } }
            foreach ($k in 'Micro', 'Casque') { if ($null -ne $s[$k]) { $reglages[$k] = $s[$k] } }
            [EMMicros]::Choisi = [uint32]::MaxValue; [EMSortie]::Choisi = [uint32]::MaxValue
            [void](Set-MicroActif); [void](Set-CasqueActif)
            [ordered]@{ micro = $s.Micro; casque = $s.Casque; numero_micro = [EMMicros]::Choisi; numero_casque = [EMSortie]::Choisi }
        }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\MINDSET_DONNEES -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------------------------------------
# L'écriture : du JSON en ASCII seul (tout autre caractère en \uXXXX), les octets des fichiers en base64
# ---------------------------------------------------------------------------------------------------------------
function ConvertTo-JsonAscii($V, [string]$Retrait = '') {
    if ($null -eq $V) { return 'null' }
    if ($V -is [bool]) { return $(if ($V) { 'true' } else { 'false' }) }
    if ($V -is [byte[]]) { return '"' + [Convert]::ToBase64String($V) + '"' }
    if ($V -is [string]) {
        $b = New-Object Text.StringBuilder '"'
        foreach ($ch in $V.ToCharArray()) {
            $u = [int]$ch
            if ($ch -eq '"') { [void]$b.Append('\"') } elseif ($ch -eq '\') { [void]$b.Append('\\') }
            elseif ($u -ge 0x20 -and $u -le 0x7E) { [void]$b.Append($ch) } else { [void]$b.Append(('\u{0:x4}' -f $u)) }
        }
        return $b.Append('"').ToString()
    }
    if ($V -is [ValueType]) { return [string]$V }
    $dedans = "$Retrait  "
    if ($V -is [Collections.IDictionary]) {
        $l = foreach ($k in $V.Keys) { "$dedans" + (ConvertTo-JsonAscii ([string]$k)) + ': ' + (ConvertTo-JsonAscii $V[$k] $dedans) }
        return "{`n" + ($l -join ",`n") + "`n$Retrait}"
    }
    $l = @(foreach ($e in $V) { ConvertTo-JsonAscii $e $dedans })
    if (-not $l.Count) { return '[]' }
    if (-not @($V | Where-Object { $_ -isnot [string] }).Count) { return '[' + ($l -join ', ') + ']' }
    "[`n" + (@($l | ForEach-Object { "$dedans$_" }) -join ",`n") + "`n$Retrait]"
}

$texte = "{`n  `"note`": " + (ConvertTo-JsonAscii 'Fait par outils\exporter-juges-micro.ps1 : ne pas modifier à la main.') + ",`n  `"cas`": " + (ConvertTo-JsonAscii $cas '  ') + "`n}`n"
[IO.File]::WriteAllText($sortie, $texte, $utf8)
Write-Output "$($cas.Count) cas écrits dans $sortie"
