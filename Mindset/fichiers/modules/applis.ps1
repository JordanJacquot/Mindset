# Mindset : la liste des applis de la suite (fichiers\apps.json) et leur état.
# Chargé par Mindset.ps1, qui définit $AppDir.
#
# Sécurité : apps.json est livré avec Mindset ; on n'y lit que des champs connus, vérifiés un par un,
# et aucun texte qui en vient n'est exécuté comme une commande.

function Get-Applis {
    $f = Join-Path $AppDir 'apps.json'
    # (sans @() : PowerShell 5.1 rend un tableau JSON en un seul bloc, que @() emballerait dans un autre tableau)
    try { $liste = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { Write-Log "apps.json illisible : $_"; return @() }
    $nomFichier = '^[^\\/:*?"<>|]+$'
    foreach ($a in $liste) {
        if ($a.id -isnot [string] -or $a.couleur -isnot [string]) { Write-Log 'apps.json : entrée mal formée ignorée'; continue }
        $ok = $a.id -match '^[a-z0-9-]+$' -and $a.nom -and $a.couleur -match '^#[0-9A-Fa-f]{6}$' -and
              $a.depot -match '^[\w.-]+/[\w.-]+$' -and $a.zip -match $nomFichier -and $a.dossier_zip -match $nomFichier -and
              $a.exe -match '^[^\\/:*?"<>|]+\.exe$' -and $a.script -match '^[\w\\.-]+\.ps1$' -and $a.script -notmatch '\.\.'
        if ($a.desinstalleur) { $ok = $ok -and $a.desinstalleur -match '^[^\\/:*?"<>|]+\.exe$' }
        if ($a.afficher_fichier) { $ok = $ok -and $a.afficher_fichier -match $nomFichier }
        if ($a.aide) { $ok = $ok -and $a.aide -cmatch '^[A-Za-z0-9 ]{1,40} \(aide\)$' -and $a.aide_exe -match '^[^\\/:*?"<>|]+\.exe$' }
        if ($a.sans_droits_depuis) { $ok = $ok -and $a.sans_droits_depuis -match '^\d+(\.\d+){1,3}$' }
        if (-not $ok) { Write-Log "apps.json : appli ignorée ($($a.id))"; continue }
        [pscustomobject]@{
            Id              = [string]$a.id
            Nom             = [string]$a.nom
            Couleur         = [string]$a.couleur
            Description     = [string]$a.description
            Depot           = [string]$a.depot
            Zip             = [string]$a.zip
            DossierZip      = [string]$a.dossier_zip
            Exe             = [string]$a.exe
            Script          = [string]$a.script
            Mutex           = [string]$a.mutex
            AfficherFichier = [string]$a.afficher_fichier   # nom du fichier, dans le dossier de données de l'appli
            AfficherSignal  = [string]$a.afficher_signal
            Desinstalleur   = [string]$a.desinstalleur
            Donnees         = [Environment]::ExpandEnvironmentVariables([string]$a.donnees)
            Admin           = [bool]$a.admin
            SansDroitsDepuis = [string]$a.sans_droits_depuis   # version à partir de laquelle elle n'a plus besoin des droits (son Aide les a)
            Aide            = [string]$a.aide       # tâche planifiée de sa partie administrateur (« \Mindset\<aide> »)
            AideExe         = [string]$a.aide_exe   # le programme qu'elle lance, à côté de l'exe de l'appli
            CacheDepuis     = [string]$a.cache_depuis   # version à partir de laquelle l'appli lancée cachée se dessine une fois affichée dans Mindset
        }
    }
}

# L'appli a-t-elle besoin des droits administrateur ? Selon la version installée : Nevermind n'en a plus besoin depuis
# « sans_droits_depuis » (ce qui en demande passe par son Aide) ; une version plus ancienne les demande encore.
function Test-AppliAdmin($Appli, $Inst = $null) {
    if (-not $Appli.Admin) { return $false }
    if (-not $Appli.SansDroitsDepuis) { return $true }
    if (-not $Inst) { $Inst = Get-Installation $Appli }
    if (-not $Inst -or -not $Inst.Version) { return $true }
    Test-VersionPlusRecente $Appli.SansDroitsDepuis $Inst.Version
}

# Ouverte ou non : chaque appli garde un mutex tant qu'elle tourne (« une seule à la fois »).
# Si l'appli tourne en administrateur, Windows refuse de nous l'ouvrir : il existe, donc elle tourne.
# Sinon, on cherche son programme par son nom (une instance de test, par exemple, ne prend pas le mutex).
function Test-AppliOuverte($Appli) {
    if ($Appli.Mutex) {
        try { $m = [System.Threading.Mutex]::OpenExisting($Appli.Mutex); $m.Dispose(); return $true }
        catch {
            $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
            if ($e -is [System.UnauthorizedAccessException]) { return $true }
        }
    }
    $nom = [IO.Path]::GetFileNameWithoutExtension($Appli.Exe)
    [bool]($nom -and (Get-Process -Name $nom -ErrorAction SilentlyContinue))
}

$Applis = @(Get-Applis)
