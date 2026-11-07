# Mindset en Rust (3.0 et après) : ce que contient son zip et d'où vient sa version, écrit à UN seul endroit pour
# outils\construire-rust.ps1, outils\verifier-zip-rust.ps1, outils\version-rust.ps1, outils\tester-maj-rust.ps1 et
# outils\publier.ps1 -Rust (chargé par « . (Join-Path $PSScriptRoot 'contenu-rust.ps1') »).
#
#   Mindset\                                  (le dossier « Mindset » du zip : celui que l'installateur 2.18 attend,
#                                              dossier_zip « Mindset », exe « Mindset.exe »)
#     Mindset.exe                             <- Mindset (rust\mindset-appli, programme cargo « Mindset ») : fenêtre Tauri,
#                                                les pages sont rangées dans l'exe (docs\regles-tauri.md)
#     MindsetInstallateur.exe                 <- le mini-installateur (rust\mindset-installateur) : la tâche SYSTEM
#                                                « \Mindset\Mindset (installation) » le lance, et la demande de Windows aussi
#     Desinstaller Mindset.exe                <- le désinstalleur autonome (rust\desinstalleur, programme cargo
#                                                « desinstaller-mindset », renommé ici) : « Applications installées » le lance
#     version.json                            <- { "appli": "mindset", "version": <Cargo.toml de mindset-appli> }
#                                                (l'installateur de 2.18 refuse un zip dont version.json dit une autre appli)
#     LISEZMOI.txt                            <- Mindset\LISEZMOI.txt
#     fichiers\apps.json, apps-liste.txt      <- la liste des applis livrée et son numéro
#     fichiers\cles-publiques\*.xml           <- les clés publiques de la suite (toutes celles du dépôt)
#     fichiers\Mindset.ico                    <- l'icône (près de l'horloge, raccourcis)
#     fichiers\installer-admin.ps1            <- le relais vers MindsetInstallateur.exe, GARDÉ : la tâche SYSTEM inscrite
#                                                par un Mindset 2.14 ou avant lance « powershell -File
#                                                <Mindset>\fichiers\installer-admin.ps1 » ; sans lui, cette tâche ne
#                                                répondrait plus après la mise à jour (et l'ancienne tâche ne pourrait plus
#                                                se remplacer elle-même sans demande de Windows)
#     fichiers\version.ps1                    <- écrit ici : une seule ligne utile, « $AppVersion = '<version>' ». Personne
#                                                ne le lance. Les Mindset 2.14 et avant lisent la version d'un zip sur cette
#                                                ligne (Get-VersionDossier) : sans elle, ceux de 2.11 à 2.14 refusent la
#                                                mise à jour (« Le fichier téléchargé ne dit pas quelle version il
#                                                contient » ; preuve : outils\tester-zip-anciens.ps1, sur les 62 versions
#                                                publiées). L'installateur de 2.15 à 2.18 exige qu'elle dise la même chose
#                                                que version.json.
#
# Plus de Mindset.ps1, de modules, de lib\webview2 (WPF) ni de console\ : tout est dans Mindset.exe.
#
# Une seule version pour tout : la ligne « version = » de [package] de rust\mindset-appli\Cargo.toml. Mindset.exe la prend
# là (tauri-build) ; MindsetInstallateur.exe et le désinstalleur la prennent dans $AppVersion de Mindset\fichiers\Mindset.ps1
# (leur build.rs) : outils\version-rust.ps1 écrit donc les deux.

$MindsetRust = @{
    # Les programmes : nom dans le zip -> programme cargo, sa crate, et ce que disent leurs informations de version
    Programmes = [ordered]@{
        'Mindset.exe'              = @{ Bin = 'Mindset'; Paquet = 'mindset-appli'; Description = 'Mindset'; Produit = 'Mindset' }
        'MindsetInstallateur.exe'  = @{ Bin = 'MindsetInstallateur'; Paquet = 'mindset-installateur'; Description = 'Mindset'; Produit = 'Mindset' }
        'Desinstaller Mindset.exe' = @{ Bin = 'desinstaller-mindset'; Paquet = 'desinstalleur'; Description = "D$([char]0xE9)sinstaller Mindset"; Produit = 'Mindset' }
    }
    # Les fichiers copiés tels quels : chemin dans le dossier Mindset -> chemin dans le dépôt
    Copies = [ordered]@{
        'LISEZMOI.txt'                   = 'Mindset\LISEZMOI.txt'
        'fichiers\apps.json'             = 'Mindset\fichiers\apps.json'
        'fichiers\apps-liste.txt'        = 'Mindset\fichiers\apps-liste.txt'
        'fichiers\Mindset.ico'           = 'Mindset\fichiers\Mindset.ico'
        'fichiers\installer-admin.ps1'   = 'Mindset\fichiers\installer-admin.ps1'
    }
    # Le dossier des clés publiques, copié en entier (chaque fichier .xml)
    Cles = 'Mindset\fichiers\cles-publiques'
    # Écrits à la construction
    VersionJson = 'version.json'
    VersionPs1 = 'fichiers\version.ps1'
}

# Le texte de fichiers\version.ps1 pour une version (UTF-8 avec BOM, fins de ligne CRLF)
function Get-TexteVersionPs1([string]$Version) {
    "# Mindset en Rust : ce fichier n'est lanc$([char]0xE9) par personne. Il donne la version de ce dossier aux Mindset 2.14 et`r`n" +
    "# avant, qui la lisent sur la ligne ci-dessous avant d'installer une mise $([char]0xE0) jour (outils\contenu-rust.ps1).`r`n" +
    "`$AppVersion = '$Version'`r`n"
}

# Le texte de version.json pour une version (UTF-8 sans marque)
function Get-TexteVersionJson([string]$Version) {
    [ordered]@{ appli = 'mindset'; version = $Version } | ConvertTo-Json -Compress
}

# Tous les fichiers attendus dans le dossier Mindset (chemins relatifs), pour un dépôt donné
function Get-FichiersMindsetRust([string]$Racine) {
    $cles = @(Get-ChildItem -LiteralPath (Join-Path $Racine $MindsetRust.Cles) -Filter '*.xml' -File | Sort-Object Name | ForEach-Object { "fichiers\cles-publiques\$($_.Name)" })
    @(@($MindsetRust.Programmes.Keys) + @($MindsetRust.VersionJson, $MindsetRust.VersionPs1) + @($MindsetRust.Copies.Keys) + $cles)
}

# La version de Mindset en Rust : la ligne « version = "x.y.z" » de la section [package] de rust\mindset-appli\Cargo.toml
function Get-VersionMindsetRust([string]$Racine) {
    $cargo = Join-Path $Racine 'rust\mindset-appli\Cargo.toml'
    if (-not (Test-Path -LiteralPath $cargo -PathType Leaf)) { return $null }
    $section = ''
    foreach ($ligne in [IO.File]::ReadAllLines($cargo, [Text.Encoding]::UTF8)) {
        $l = $ligne.Trim()
        if ($l.StartsWith('[')) { $section = $l; continue }
        if ($section -eq '[package]' -and $l -match '^version\s*=\s*"([^"]*)"') { return $Matches[1] }
    }
    $null
}

# $AppVersion de Mindset\fichiers\Mindset.ps1 : la version de la version PowerShell, et celle que prennent
# MindsetInstallateur.exe et le désinstalleur à leur construction
function Get-VersionMindsetPs([string]$Racine) {
    $ps1 = Join-Path $Racine 'Mindset\fichiers\Mindset.ps1'
    if ((Test-Path -LiteralPath $ps1) -and [IO.File]::ReadAllText($ps1, [Text.Encoding]::UTF8) -match "(?m)^\`$AppVersion = '([\d\.]+)'") { return $Matches[1] }
    $null
}

# Une version sur quatre nombres (« 3.0.0 » -> « 3.0.0.0 »), comme les informations de version des exe
function ConvertTo-Version4([string]$Version) {
    $p = @(([string]$Version).Split('.') | Where-Object { $_ -ne '' }); while ($p.Count -lt 4) { $p += '0' }
    $p -join '.'
}
