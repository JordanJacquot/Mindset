# Mindset : la liste des applis de la suite (fichiers\apps.json) et leur état.
# Chargé par Mindset.ps1, qui définit $AppDir.
#
# Sécurité : apps.json est installé avec Mindset (dans Program Files plus tard) ; on n'y lit que des champs connus,
# et aucun texte qui en vient n'est exécuté comme une commande.

function Get-Applis {
    $f = Join-Path $AppDir 'apps.json'
    # (sans @() : PowerShell 5.1 rend un tableau JSON en un seul bloc, que @() emballerait dans un autre tableau)
    try { $liste = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { Write-Log "apps.json illisible : $_"; return @() }
    foreach ($a in $liste) {
        if ($a.id -isnot [string] -or $a.couleur -isnot [string]) { Write-Log 'apps.json : entrée mal formée ignorée'; continue }
        if (-not ($a.id -match '^[a-z0-9-]+$' -and $a.nom -and $a.couleur -match '^#[0-9A-Fa-f]{6}$')) { Write-Log "apps.json : appli ignorée ($($a.id))"; continue }
        [pscustomobject]@{
            Id          = [string]$a.id
            Nom         = [string]$a.nom
            Couleur     = [string]$a.couleur
            Description = [string]$a.description
            Depot       = [string]$a.depot
            Zip         = [string]$a.zip
            Exe         = [string]$a.exe
            Mutex       = [string]$a.mutex
            Donnees     = [Environment]::ExpandEnvironmentVariables([string]$a.donnees)
            Admin       = [bool]$a.admin
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
