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
            CacheDepuis     = [string]$a.cache_depuis   # version à partir de laquelle l'appli lancée cachée se dessine une fois affichée dans Mindset
        }
    }
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
