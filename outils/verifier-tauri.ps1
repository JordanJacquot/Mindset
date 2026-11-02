# Mindset : vérifie qu'un projet d'appli Tauri de la suite suit les 8 règles de docs\regles-tauri.md.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\verifier-tauri.ps1 -Projet <dossier de l'appli>
#
# Le dossier de l'appli est celui de tauri.conf.json (avec capabilities\, Cargo.toml, build.rs, src\ et les pages).
# Cargo.lock est cherché dans ce dossier puis au-dessus (espace de travail) ; -CargoLock le donne si besoin. Tous les
# Cargo.toml de l'espace de travail sont lus (une option de tauri activée par une autre crate vaut pour toutes).
#
# Rien n'est lancé ni construit : seulement des fichiers lus. Une phrase par problème, qui commence par
# « Règle <n> : » ou « Configuration : ». Code de sortie 0 si tout est bon, 1 sinon (tests GitHub).
# Les essais : outils\essais-tauri (un projet propre, et des projets cassés exprès), par outils\tester-verifier-tauri.ps1.

param(
    [Parameter(Mandatory = $true)][string]$Projet,
    [string]$CargoLock
)

$ErrorActionPreference = 'Stop'
$problemes = New-Object Collections.Generic.List[string]
function Add-Probleme([string]$Regle, [string]$Texte) {
    $debut = if ($Regle -eq 'config') { 'Configuration' } else { "Règle $Regle" }
    $problemes.Add("$debut : $Texte")
}

# La liste blanche des permissions de Tauri lui-même (core:...) : vide. Une permission n'y entre qu'après relecture
# de ce qu'elle ouvre (docs\regles-tauri.md, règle 2).
$PermissionsTauriAutorisees = @()
# Les plugins interdits (règles 4 et 8, et le plan de l'étape 4) : leur règle
$PluginsInterdits = [ordered]@{
    'tauri-plugin-shell' = '4'; 'tauri-plugin-fs' = '4'; 'tauri-plugin-single-instance' = '4'
    'tauri-plugin-global-shortcut' = '4'; 'tauri-plugin-updater' = '8'
}

function Read-Texte([string]$Chemin) { [IO.File]::ReadAllText($Chemin, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) }
function Get-Relatif([string]$Chemin) { $Chemin.Substring($racine.Length).TrimStart('\') }

# Un réglage de tauri.conf.json, sous son nom ou son autre nom à tirets (« withGlobalTauri » ou « with-global-tauri »).
# @{ Existe; Valeur }
function Get-Champ($Objet, [string[]]$Noms) {
    if ($null -eq $Objet -or $Objet -isnot [Management.Automation.PSCustomObject]) { return @{ Existe = $false; Valeur = $null } }
    $trouves = @($Noms | Where-Object { $Objet.PSObject.Properties[$_] })
    # (écrit sous ses deux noms : Tauri refuserait ou n'en lirait qu'un ; ici, refusé)
    if ($trouves.Count -gt 1) { Add-Probleme 'config' "le réglage $($trouves[0]) est écrit sous deux noms ($($trouves -join ' et ')) : un seul." }
    if ($trouves.Count) { return @{ Existe = $true; Valeur = $Objet.PSObject.Properties[$trouves[0]].Value } }
    @{ Existe = $false; Valeur = $null }
}
function Test-Vrai($Valeur) { $Valeur -is [bool] -and $Valeur }

# ---------------------------------------------------------------------------------------------------------------
# Le projet et sa configuration
# ---------------------------------------------------------------------------------------------------------------
try { $racine = [IO.Path]::GetFullPath($Projet).TrimEnd('\') } catch { Write-Output "Dossier du projet illisible : $Projet"; exit 1 }
if (-not [IO.Directory]::Exists($racine)) { Write-Output "Dossier du projet introuvable : $racine"; exit 1 }
Write-Output "Projet vérifié : $racine"

# Seul tauri.conf.json : Tauri lit aussi d'autres fichiers et les fusionne par dessus
foreach ($f in @(Get-ChildItem -LiteralPath $racine -File)) {
    if ($f.Name -match '^(?i)(tauri\.conf\.json5|tauri\.toml|tauri\.(windows|linux|macos|android|ios)\.conf\.json5?|tauri\.(windows|linux|macos|android|ios)\.toml)$') {
        Add-Probleme 'config' "$($f.Name) est interdit : Tauri le fusionne avec tauri.conf.json. Tout va dans tauri.conf.json."
    }
}
$conf = $null
$fichierConf = Join-Path $racine 'tauri.conf.json'
if (-not (Test-Path -LiteralPath $fichierConf -PathType Leaf)) { Add-Probleme 'config' 'tauri.conf.json introuvable.' }
else {
    try { $conf = Read-Texte $fichierConf | ConvertFrom-Json } catch { Add-Probleme 'config' "tauri.conf.json illisible ($($_.Exception.Message))." }
    if ($null -ne $conf -and $conf -isnot [Management.Automation.PSCustomObject]) { Add-Probleme 'config' "tauri.conf.json n'est pas un groupe de réglages."; $conf = $null }
}
$app = (Get-Champ $conf 'app').Valeur
$securite = (Get-Champ $app 'security').Valeur
$build = (Get-Champ $conf 'build').Valeur

# Le code Rust de l'appli (src\**\*.rs) et build.rs
$codes = @()
if ([IO.Directory]::Exists((Join-Path $racine 'src'))) {
    $codes = @(Get-ChildItem -LiteralPath (Join-Path $racine 'src') -Recurse -File -Filter '*.rs' | ForEach-Object { @{ Nom = Get-Relatif $_.FullName; Texte = (Read-Texte $_.FullName) } })
}
if (-not $codes.Count) { Add-Probleme 'config' 'aucun code Rust dans src\.' }
$fichierBuild = Join-Path $racine 'build.rs'
$texteBuild = if (Test-Path -LiteralPath $fichierBuild -PathType Leaf) { Read-Texte $fichierBuild } else { '' }

# Cargo.lock : dans le dossier, sinon au-dessus (l'espace de travail)
if (-not $CargoLock) {
    $d = $racine
    for ($i = 0; $i -lt 4 -and $d; $i++) {
        if (Test-Path -LiteralPath (Join-Path $d 'Cargo.lock') -PathType Leaf) { $CargoLock = Join-Path $d 'Cargo.lock'; break }
        $d = Split-Path $d -Parent
    }
}
$texteLock = ''
if (-not $CargoLock -or -not (Test-Path -LiteralPath $CargoLock -PathType Leaf)) { Add-Probleme 'config' 'Cargo.lock introuvable (dans le dossier du projet ou au-dessus) : les bibliothèques ne peuvent pas être vérifiées.' }
else { $texteLock = Read-Texte $CargoLock }
# Les Cargo.toml : celui de l'appli, et tous ceux de l'espace de travail (le dossier de Cargo.lock)
$tomlAppli = Join-Path $racine 'Cargo.toml'
if (-not (Test-Path -LiteralPath $tomlAppli -PathType Leaf)) { Add-Probleme 'config' 'Cargo.toml introuvable.' }
$tomls = New-Object Collections.Generic.List[string]
if (Test-Path -LiteralPath $tomlAppli -PathType Leaf) { $tomls.Add([IO.Path]::GetFullPath($tomlAppli)) }
if ($CargoLock -and (Test-Path -LiteralPath $CargoLock -PathType Leaf)) {
    $espace = Split-Path ([IO.Path]::GetFullPath($CargoLock)) -Parent
    foreach ($t in @(Get-ChildItem -LiteralPath $espace -Recurse -File -Filter 'Cargo.toml' | Where-Object { $_.FullName -notmatch '\\(target|\.git|node_modules)\\' })) {
        if (-not $tomls.Contains($t.FullName)) { $tomls.Add($t.FullName) }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Règle 1 : withGlobalTauri coupé, et seul ipc.js parle à Rust
# ---------------------------------------------------------------------------------------------------------------
if (Test-Vrai (Get-Champ $app 'withGlobalTauri', 'with-global-tauri').Valeur) {
    Add-Probleme '1' 'app.withGlobalTauri vaut true : toute l''API de Tauri serait offerte aux pages. Il doit valoir false.'
}
$dist = (Get-Champ $build 'frontendDist', 'frontend-dist').Valeur
$dossierPages = $null
if ($null -eq $dist) { Add-Probleme '1' 'build.frontendDist manque : les pages ne peuvent pas être vérifiées.' }
elseif ($dist -is [string] -and $dist -match '^[a-z][a-z0-9+.-]+:') {
    Add-Probleme '3' "build.frontendDist est une adresse ($dist) : l'exe ne charge que ses propres pages."
} elseif ($dist -isnot [string] -or [IO.Path]::IsPathRooted($dist)) {
    Add-Probleme '1' "build.frontendDist doit être un dossier de pages du projet, pas « $dist »."
} else {
    $dossierPages = [IO.Path]::GetFullPath((Join-Path $racine $dist)).TrimEnd('\')
    if (-not $dossierPages.StartsWith($racine + '\', [StringComparison]::OrdinalIgnoreCase) -or -not [IO.Directory]::Exists($dossierPages)) {
        Add-Probleme '1' "build.frontendDist ($dist) n'est pas un dossier du projet."; $dossierPages = $null
    }
}
if ($dossierPages) {
    $ipc = Join-Path $dossierPages 'ipc.js'
    $pages = @(Get-ChildItem -LiteralPath $dossierPages -Recurse -File | Where-Object { $_.Extension -match '^\.(html?|m?js|cjs|css|svg|json)$' })
    foreach ($p in $pages) {
        $t = Read-Texte $p.FullName
        $nom = Get-Relatif $p.FullName
        if ($p.FullName -ne $ipc) {
            foreach ($m in @(@('__TAURI', '__TAURI'), @('\binvoke\b', 'invoke'), @('ipc\.localhost', 'ipc.localhost'), @('chrome\.webview', 'chrome.webview'))) {
                if ($t -match $m[0]) { Add-Probleme '1' "$nom contient « $($m[1]) » : seul ipc.js parle à Rust." }
            }
        }
        foreach ($m in @('plugin-shell', 'plugin-fs', 'plugin:shell', 'plugin:fs')) {
            if ($t.Contains($m)) { Add-Probleme '4' "$nom parle du plugin « $m », interdit." }
        }
    }
    if (-not (Test-Path -LiteralPath $ipc -PathType Leaf)) { Add-Probleme '1' "ipc.js manque dans $dist : c'est le seul fichier qui appelle Rust." }
}
$paquetJs = Join-Path $racine 'package.json'
if (Test-Path -LiteralPath $paquetJs -PathType Leaf) {
    $t = Read-Texte $paquetJs
    foreach ($m in @('plugin-shell', 'plugin-fs', 'plugin-updater', 'plugin-single-instance', 'plugin-global-shortcut')) {
        if ($t.Contains("@tauri-apps/$m")) { Add-Probleme $(if ($m -eq 'plugin-updater') { '8' } else { '4' }) "package.json demande @tauri-apps/$m, interdit." }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Règle 2 : capabilities par fenêtre, commandes déclarées et autorisées une à une
# ---------------------------------------------------------------------------------------------------------------
$capConfig = Get-Champ $securite 'capabilities'
if ($capConfig.Existe -and @($capConfig.Valeur).Count) {
    Add-Probleme '2' 'app.security.capabilities est rempli : les capabilities vont seulement dans des fichiers capabilities\*.json.'
}
$fenetresCap = @{}   # label -> fichier
$permissionsApp = @{}   # allow-<commande> -> fichier
$dossierCap = Join-Path $racine 'capabilities'
if ([IO.Directory]::Exists($dossierCap)) {
    foreach ($e in @(Get-ChildItem -LiteralPath $dossierCap -Recurse -Force)) {
        $nom = Get-Relatif $e.FullName
        if ($e.PSIsContainer) { Add-Probleme '2' "$nom : pas de sous-dossier dans capabilities (Tauri les lit aussi)."; continue }
        if ($e.Extension -ne '.json') { Add-Probleme '2' "$nom : seulement des fichiers .json dans capabilities (Tauri lit aussi .toml et .json5)."; continue }
        $texte = Read-Texte $e.FullName
        $c = $null
        try { $c = $texte | ConvertFrom-Json } catch { Add-Probleme '2' "$nom illisible ($($_.Exception.Message))."; continue }
        if ($texte.TrimStart().StartsWith('[') -or $c -isnot [Management.Automation.PSCustomObject] -or (Get-Champ $c 'capabilities').Existe) {
            Add-Probleme '2' "$nom : une seule capability par fichier."; continue
        }
        $fen = Get-Champ $c 'windows'
        $labels = @($fen.Valeur | Where-Object { $null -ne $_ })
        if (-not $labels.Count) { Add-Probleme '2' "$nom : windows est vide, il doit nommer la fenêtre." }
        foreach ($l in $labels) {
            if ($l -isnot [string] -or $l -notmatch '^[A-Za-z0-9_-]{1,64}$') { Add-Probleme '2' "$nom : « $l » n'est pas un label exact de fenêtre (ni *, ni motif)."; continue }
            if ($fenetresCap.ContainsKey($l)) { Add-Probleme '2' "la fenêtre « $l » a plusieurs fichiers de capability ($($fenetresCap[$l]) et $nom)." }
            else { $fenetresCap[$l] = $nom }
        }
        if (@((Get-Champ $c 'webviews').Valeur | Where-Object { $null -ne $_ }).Count) { Add-Probleme '2' "$nom : webviews n'est pas utilisé dans la suite (une capability par fenêtre)." }
        if ((Get-Champ $c 'remote').Existe) { Add-Probleme '2' "$nom : remote est interdit, aucune adresse extérieure n'appelle l'appli." }
        $local = Get-Champ $c 'local'
        if ($local.Existe -and $local.Valeur -ne $true) { Add-Probleme '2' "$nom : local doit rester vrai." }
        foreach ($p in @((Get-Champ $c 'permissions').Valeur | Where-Object { $null -ne $_ })) {
            if ($p -isnot [string]) { Add-Probleme '2' "$nom : une permission avec un champ d'action (scope) est refusée, seulement des noms."; continue }
            if ($p -match '^(shell|fs):') { Add-Probleme '4' "$nom : la permission « $p » est interdite (ni shell ni fs)."; continue }
            if ($p -match '^updater:') { Add-Probleme '8' "$nom : la permission « $p » est interdite (pas de mise à jour par Tauri)."; continue }
            if ($p -cmatch '^allow-[a-z0-9]+(-[a-z0-9]+)*$') { $permissionsApp[$p] = $nom; continue }
            if ($PermissionsTauriAutorisees -ccontains $p) { continue }
            if ($p -match '(^|:)default$') { Add-Probleme '2' "$nom : « $p » ouvre plusieurs commandes d'un coup, refusé (liste écrite permission par permission)." }
            else { Add-Probleme '2' "$nom : la permission « $p » n'est pas dans la liste blanche de la suite." }
        }
    }
}
# Les commandes : celles du code, celles du manifeste de build.rs, celles autorisées
$commandesCode = @{}
foreach ($c in $codes) {
    foreach ($m in [regex]::Matches($c.Texte, '#\[\s*(tauri::)?command\b[^\]]*\]\s*(#\[[^\]]*\]\s*)*(pub(\([^)]*\))?\s+)?(async\s+)?fn\s+([A-Za-z0-9_]+)')) { $commandesCode[$m.Groups[6].Value] = $c.Nom }
}
$commandesManifeste = @{}
$manifeste = [regex]::Match($texteBuild, '(?s)AppManifest::new\(\)\s*\.commands\(\s*&\[(.*?)\]')
if (-not $texteBuild) { Add-Probleme '2' 'build.rs manque : il doit déclarer le manifeste des commandes de l''appli.' }
elseif (-not $manifeste.Success -or $texteBuild -notmatch 'app_manifest\(') {
    Add-Probleme '2' 'build.rs ne déclare pas le manifeste des commandes (AppManifest::new().commands(&[...]) dans app_manifest) : sans lui, toute page appelle toutes les commandes.'
} else {
    foreach ($m in [regex]::Matches($manifeste.Groups[1].Value, '"([^"]*)"')) { $commandesManifeste[$m.Groups[1].Value] = $true }
}
foreach ($k in $commandesCode.Keys) {
    if ($manifeste.Success -and -not $commandesManifeste.ContainsKey($k)) { Add-Probleme '2' "la commande $k ($($commandesCode[$k])) n'est pas dans le manifeste de build.rs." }
}
foreach ($k in $commandesManifeste.Keys) {
    if (-not $commandesCode.ContainsKey($k)) { Add-Probleme '2' "le manifeste de build.rs nomme $k, qui n'est pas une commande du code." }
    $perm = 'allow-' + $k.Replace('_', '-')
    if (-not $permissionsApp.ContainsKey($perm)) { Add-Probleme '2' "la commande $k n'est autorisée pour aucune fenêtre ($perm)." }
}
foreach ($p in $permissionsApp.Keys) {
    $ok = $false
    foreach ($k in $commandesManifeste.Keys) { if ('allow-' + $k.Replace('_', '-') -ceq $p) { $ok = $true } }
    if (-not $ok) { Add-Probleme '2' "$($permissionsApp[$p]) autorise $p, qui ne correspond à aucune commande du manifeste." }
}
# Les fenêtres créées dans le code, chacune avec sa capability (et réciproquement)
$fenetresCode = @{}
foreach ($c in $codes) {
    foreach ($m in [regex]::Matches($c.Texte, 'WebviewWindowBuilder::new\(\s*[^,]+,\s*"([^"]+)"')) { $fenetresCode[$m.Groups[1].Value] = $c.Nom }
}
foreach ($l in $fenetresCode.Keys) { if (-not $fenetresCap.ContainsKey($l)) { Add-Probleme '2' "la fenêtre « $l » ($($fenetresCode[$l])) n'a pas de fichier de capability." } }
foreach ($l in $fenetresCap.Keys) { if (-not $fenetresCode.ContainsKey($l)) { Add-Probleme '2' "$($fenetresCap[$l]) vise la fenêtre « $l », que le code ne crée pas." } }

# ---------------------------------------------------------------------------------------------------------------
# Règle 3 : CSP stricte, la même en développement, pas d'adresse de développement
# ---------------------------------------------------------------------------------------------------------------
# Une CSP en liste de directives @( @{ Nom; Sources } ), depuis un texte ou un groupe { directive: texte ou liste }
function ConvertTo-Directives($Csp) {
    $l = @()
    if ($Csp -is [string]) {
        foreach ($d in $Csp.Split(';')) {
            $mots = @($d.Trim() -split '\s+' | Where-Object { $_ })
            if ($mots.Count) { $l += , @{ Nom = $mots[0].ToLower(); Sources = @($mots | Select-Object -Skip 1) } }
        }
    } elseif ($Csp -is [Management.Automation.PSCustomObject]) {
        foreach ($p in $Csp.PSObject.Properties) {
            $s = @(foreach ($v in @($p.Value)) { @(([string]$v) -split '\s+' | Where-Object { $_ }) })
            $l += , @{ Nom = $p.Name.ToLower(); Sources = $s }
        }
    }
    , $l
}
function Get-TexteCsp($Directives) { (@($Directives | ForEach-Object { (@($_.Nom) + $_.Sources) -join ' ' }) -join '; ') }
$csp = Get-Champ $securite 'csp'
$directives = ConvertTo-Directives $csp.Valeur
if (-not $directives.Count) { Add-Probleme '3' 'app.security.csp est vide ou absente : une CSP stricte est obligatoire.' }
else {
    $defaut = @($directives | Where-Object { $_.Nom -eq 'default-src' })
    if (-not $defaut.Count -or ($defaut[0].Sources -join ' ') -ne "'none'") { Add-Probleme '3' "la CSP doit commencer par default-src 'none'." }
    foreach ($d in $directives) {
        foreach ($s in $d.Sources) {
            $sl = $s.ToLower()
            if ($sl -match 'unsafe-eval') { Add-Probleme '3' "la CSP permet $s dans $($d.Nom) : jamais de code fabriqué." }
            elseif ($sl -eq "'unsafe-inline'" -and $d.Nom -notmatch '^style-src(-elem|-attr)?$') { Add-Probleme '3' "la CSP permet 'unsafe-inline' dans $($d.Nom) : seulement toléré dans style-src." }
            elseif ($sl.Contains('*')) { Add-Probleme '3' "la CSP contient un joker ($s dans $($d.Nom))." }
            elseif ($sl -match '^(https?|wss?|ftp):$') { Add-Probleme '3' "la CSP ouvre tout $s dans $($d.Nom)." }
            elseif ($sl -match '^(data|blob|filesystem):$' -and $d.Nom -ne 'img-src') { Add-Probleme '3' "la CSP permet $s dans $($d.Nom) : seulement pour les images (img-src)." }
            elseif ($sl -match '^[a-z][a-z0-9+.-]*://' -and $sl -notmatch '^https?://[a-z0-9-]+\.localhost/?$') { Add-Probleme '3' "la CSP permet une adresse extérieure ($s dans $($d.Nom)) : seulement http://<nom>.localhost." }
            elseif ($sl -notmatch '^(''[a-z0-9+/=-]+''|[a-z][a-z0-9+.-]*:|https?://[a-z0-9-]+\.localhost/?)$') { Add-Probleme '3' "la CSP contient une source inconnue ($s dans $($d.Nom))." }
        }
    }
    $dev = Get-Champ $securite 'devCsp', 'dev-csp'
    if ($dev.Existe -and $null -ne $dev.Valeur -and (Get-TexteCsp (ConvertTo-Directives $dev.Valeur)) -cne (Get-TexteCsp $directives)) {
        Add-Probleme '3' 'app.security.devCsp n''est pas la même que csp.'
    }
}
$modif = Get-Champ $securite 'dangerousDisableAssetCspModification', 'dangerous-disable-asset-csp-modification'
if ($modif.Existe -and $modif.Valeur -ne $false) { Add-Probleme '3' 'dangerousDisableAssetCspModification est interdit : Tauri doit ajouter l''empreinte de ses scripts à la CSP.' }
if ((Get-Champ $build 'devUrl', 'dev-url').Existe) { Add-Probleme '3' 'build.devUrl est interdit : l''exe ne charge que ses propres pages.' }

# ---------------------------------------------------------------------------------------------------------------
# Règles 4 et 8 (bibliothèques), règle 5 : la dépendance tauri et ses options
# ---------------------------------------------------------------------------------------------------------------
foreach ($nomPlugin in $PluginsInterdits.Keys) {
    if ($texteLock -match "(?m)^name\s*=\s*""$([regex]::Escape($nomPlugin))""") { Add-Probleme $PluginsInterdits[$nomPlugin] "Cargo.lock contient $nomPlugin, interdit." }
}

# Retire un commentaire « # ... » d'une ligne TOML (hors des textes entre guillemets)
function Remove-CommentaireToml([string]$Ligne) {
    $dans = $false; $q = [char]0
    for ($i = 0; $i -lt $Ligne.Length; $i++) {
        $ch = $Ligne[$i]
        if ($dans) { if ($ch -eq $q) { $dans = $false } }
        elseif ($ch -eq '"' -or $ch -eq "'") { $dans = $true; $q = $ch }
        elseif ($ch -eq '#') { return $Ligne.Substring(0, $i) }
    }
    $Ligne
}
# Les déclarations de la dépendance tauri dans un Cargo.toml : le texte de chacune (table en ligne ou section)
function Get-DeclarationsTauri([string]$Texte) {
    $lignes = @($Texte -split "`r?`n" | ForEach-Object { Remove-CommentaireToml $_ })
    $decls = @()
    $section = ''
    for ($i = 0; $i -lt $lignes.Count; $i++) {
        $l = $lignes[$i]
        if ($l -match '^\s*\[\[?([^\]]+)\]\]?\s*$') {
            $section = $Matches[1].Trim()
            if ($section -match '(^|\.)(dev-|build-)?dependencies\.tauri$') {
                $t = ''
                for ($j = $i + 1; $j -lt $lignes.Count -and $lignes[$j] -notmatch '^\s*\[\[?[^\]]+\]\]?\s*$'; $j++) { $t += $lignes[$j] + "`n" }
                $decls += $t
            }
            continue
        }
        if ($section -match '(^|\.)(dev-|build-)?dependencies$' -and $l -match '^\s*tauri\s*=\s*(.*)$') {
            $v = $Matches[1]
            if ($v.TrimStart().StartsWith('{')) {
                $n = ([regex]::Matches($v, '\{').Count) - ([regex]::Matches($v, '\}').Count)
                while ($n -gt 0 -and $i + 1 -lt $lignes.Count) { $i++; $v += "`n" + $lignes[$i]; $n = ([regex]::Matches($v, '\{').Count) - ([regex]::Matches($v, '\}').Count) }
            }
            $decls += $v
        }
    }
    , $decls
}
$tauriDansAppli = $false
foreach ($t in $tomls) {
    $texte = Read-Texte $t
    $nom = if ($t -eq [IO.Path]::GetFullPath($tomlAppli)) { 'Cargo.toml' } else { $t }
    foreach ($nomPlugin in $PluginsInterdits.Keys) {
        if ($texte -match "(?m)^[^#\r\n]*\b$([regex]::Escape($nomPlugin))\b") { Add-Probleme $PluginsInterdits[$nomPlugin] "$nom demande $nomPlugin, interdit." }
    }
    if ($texte -match '(?m)^[^#\r\n]*package\s*=\s*"tauri"') { Add-Probleme '5' "$nom renomme la dépendance tauri : interdit (elle ne pourrait pas être vérifiée)." }
    foreach ($m in [regex]::Matches($texte, '"tauri\??/(devtools|dynamic-acl|default)"')) {
        Add-Probleme '5' "$nom active $($m.Value) par une option de la crate : interdit."
    }
    foreach ($d in (Get-DeclarationsTauri $texte)) {
        if ($nom -eq 'Cargo.toml') { $tauriDansAppli = $true }
        if ($d -match '\bworkspace\s*=\s*true') { Add-Probleme '5' "$nom : tauri doit être déclaré là où il sert, avec ses options, pas repris de l'espace de travail." ; continue }
        if ($d -notmatch 'default[-_]features\s*=\s*false') { Add-Probleme '5' "$nom : tauri garde ses options par défaut (dont dynamic-acl) : il faut default-features = false." }
        $options = @()
        $f = [regex]::Match($d, '(?s)\bfeatures\s*=\s*\[(.*?)\]')
        if ($f.Success) { $options = @([regex]::Matches($f.Groups[1].Value, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) }
        foreach ($o in $options) { if ($o -in @('devtools', 'dynamic-acl')) { Add-Probleme '5' "$nom : l'option $o de tauri est interdite." } }
        if ($nom -eq 'Cargo.toml' -and $options -notcontains 'custom-protocol') { Add-Probleme '5' 'Cargo.toml : l''option custom-protocol de tauri manque (sans elle, l''exe cherche un serveur de développement).' }
    }
}
if ((Test-Path -LiteralPath $tomlAppli -PathType Leaf) -and -not $tauriDansAppli) { Add-Probleme '5' 'Cargo.toml ne déclare pas tauri : ses options ne peuvent pas être vérifiées.' }
foreach ($c in $codes) {
    if ($c.Texte -match '\bopen_devtools\b|\.devtools\(\s*true\s*\)') { Add-Probleme '5' "$($c.Nom) ouvre les outils de développement : interdit." }
}

# ---------------------------------------------------------------------------------------------------------------
# Règle 6 : pas d'asset protocol
# ---------------------------------------------------------------------------------------------------------------
$asset = Get-Champ $securite 'assetProtocol', 'asset-protocol'
if ($asset.Existe -and $null -ne $asset.Valeur) {
    if (Test-Vrai (Get-Champ $asset.Valeur 'enable').Valeur) { Add-Probleme '6' 'assetProtocol est activé : les images des thèmes passent par le protocole pack de la suite.' }
    $scope = Get-Champ $asset.Valeur 'scope'
    if ($scope.Existe -and $null -ne $scope.Valeur -and ($scope.Valeur -isnot [array] -or @($scope.Valeur).Count)) { Add-Probleme '6' 'assetProtocol a un scope : interdit.' }
}

# ---------------------------------------------------------------------------------------------------------------
# Règle 7 : fenêtres créées dans le code, avec le dossier et les options de suite-commun
# ---------------------------------------------------------------------------------------------------------------
if (@((Get-Champ $app 'windows').Valeur | Where-Object { $null -ne $_ }).Count) { Add-Probleme '7' 'app.windows déclare une fenêtre : elles sont créées dans le code Rust (dossier WebView2 calculé au lancement).' }
$avecFenetre = @($codes | Where-Object { $_.Texte -match 'WebviewWindowBuilder::new' })
if ($codes.Count -and -not $avecFenetre.Count) { Add-Probleme '7' 'aucune fenêtre créée dans le code (WebviewWindowBuilder::new).' }
foreach ($c in $avecFenetre) {
    foreach ($m in @(@('\.data_directory\(', 'data_directory'), @('\.additional_browser_args\(', 'additional_browser_args'), @('\bOPTIONS_NAVIGATEUR\b', 'webview::OPTIONS_NAVIGATEUR'), @('\bchoisir_dossier\b', 'webview::choisir_dossier'))) {
        if ($c.Texte -notmatch $m[0]) { Add-Probleme '7' "$($c.Nom) crée une fenêtre sans $($m[1]) (dossier et options de suite-commun)." }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Règle 8 : ni installeur ni mise à jour par Tauri, productName Mindset
# ---------------------------------------------------------------------------------------------------------------
if (Test-Vrai (Get-Champ (Get-Champ $conf 'bundle').Valeur 'active').Valeur) { Add-Probleme '8' 'bundle.active vaut true : Mindset est le seul installeur de la suite.' }
if ((Get-Champ (Get-Champ $conf 'plugins').Valeur 'updater').Existe) { Add-Probleme '8' 'plugins.updater est interdit : les mises à jour passent par Mindset.' }
$produit = Get-Champ $conf 'productName', 'product-name'
if ($conf -and ($produit.Valeur -isnot [string] -or $produit.Valeur -cne 'Mindset')) { Add-Probleme '8' "productName doit valoir « Mindset » (description de l'exe, comme toute la suite), pas « $($produit.Valeur) »." }

# ---------------------------------------------------------------------------------------------------------------
if ($problemes.Count) {
    $problemes | Select-Object -Unique | ForEach-Object { Write-Output $_ }
    Write-Output "$(@($problemes | Select-Object -Unique).Count) problème(s) trouvé(s)."
    exit 1
}
Write-Output 'Aucun problème : les 8 règles sont suivies.'
exit 0
