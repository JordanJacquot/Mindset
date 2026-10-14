# Mindset : versions publiées sur GitHub, téléchargement et installation d'un zip signé.
#
# Autonome (pas de fenêtre, pas d'autre module que signature.ps1) : chargé par les tâches de fond de Mindset
# et par installer-admin.ps1, lancé en administrateur pour les applis qui vont dans Program Files.

# Dernière version publiée d'une appli : numéro, adresse du zip et de sa signature
function Get-Publication([string]$Depot, [string]$Zip) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Depot/releases/latest" -Headers @{ 'User-Agent' = 'Mindset' } -TimeoutSec 15
    } catch {
        # L'API de GitHub limite les questions (60 par heure et par connexion) : on passe alors par la page des versions
        $repli = Get-PublicationSansApi $Depot $Zip
        if ($repli) { return $repli }
        return @{ Erreur = "Impossible de joindre GitHub ($($_.Exception.Message))." }
    }
    $z = @($r.assets | Where-Object { $_.name -eq $Zip }) | Select-Object -First 1
    $s = @($r.assets | Where-Object { $_.name -eq "$Zip.sig" }) | Select-Object -First 1
    if (-not $z) { return @{ Erreur = "La dernière version publiée ne contient pas $Zip." } }
    @{
        Version = ([string]$r.tag_name -replace '^[vV]', '')
        UrlZip  = [string]$z.browser_download_url
        UrlSig  = if ($s) { [string]$s.browser_download_url } else { $null }
        Notes   = [string]$r.body
    }
}

# Sans l'API : https://github.com/<dépôt>/releases/latest renvoie vers /releases/tag/v<version> (sans limite de questions),
# et les fichiers d'une version sont à /releases/download/v<version>/<fichier>
function Get-PublicationSansApi([string]$Depot, [string]$Zip) {
    try {
        $q = [Net.HttpWebRequest]::Create("https://github.com/$Depot/releases/latest")
        $q.Method = 'HEAD'; $q.AllowAutoRedirect = $false; $q.UserAgent = 'Mindset'; $q.Timeout = 15000
        $rep = $q.GetResponse(); $vers = [string]$rep.Headers['Location']; $rep.Close()
        if ($vers -notmatch '/releases/tag/v?(\d+(\.\d+){1,3})$') { return $null }
        $version = $Matches[1]
        $base = "https://github.com/$Depot/releases/download/v$version"
        # La signature est-elle publiée ? (une redirection vers le fichier veut dire oui)
        $sig = $null
        try {
            $q2 = [Net.HttpWebRequest]::Create("$base/$Zip.sig"); $q2.Method = 'HEAD'; $q2.AllowAutoRedirect = $false; $q2.UserAgent = 'Mindset'; $q2.Timeout = 15000
            $r2 = $q2.GetResponse(); if ([int]$r2.StatusCode -in 200, 301, 302) { $sig = "$base/$Zip.sig" }; $r2.Close()
        } catch {}
        @{ Version = $version; UrlZip = "$base/$Zip"; UrlSig = $sig; Notes = '' }
    } catch { $null }
}

function Get-Octets([string]$Url) {
    if ($Url -notmatch '^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/') { throw "Adresse de téléchargement refusée : $Url" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object Net.WebClient
    $wc.Headers['User-Agent'] = 'Mindset'
    try { $wc.DownloadData($Url) } finally { $wc.Dispose() }
}

function Test-VersionPlusRecente([string]$Distante, [string]$Locale) {
    try { [version]$Distante -gt [version]$Locale } catch { $false }
}

# Installe (ou remplace) une appli à partir de son zip signé.
#   Le zip est vérifié puis extrait depuis la mémoire : le fichier sur le disque peut changer après la vérification,
#   ce qu'on installe est exactement ce qu'on a vérifié.
#   Seul le contenu du dossier principal du zip (« OptiGame\... », « Evermind\... ») est extrait, et tout chemin qui
#   sortirait du dossier d'arrivée est refusé.
#   Le nouveau dossier est préparé à côté puis échangé avec l'ancien : une erreur en route laisse l'ancien intact.
function Install-Paquet([byte[]]$Zip, [byte[]]$Signature, [string]$ClePublique, [string]$Destination, [string]$DossierZip, [string]$Exe) {
    if (-not (Test-Signature $Zip $Signature $ClePublique)) { throw 'La signature du fichier téléchargé est invalide : rien n''a été installé.' }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    $Destination = [IO.Path]::GetFullPath($Destination.TrimEnd('\'))
    $parent = Split-Path $Destination -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    # Restes d'une installation interrompue
    foreach ($v in @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like "$Destination.nouveau-*" -or $_.FullName -like "$Destination.ancien-*" })) {
        try { Remove-Item -LiteralPath $v.FullName -Recurse -Force -ErrorAction Stop } catch {}
    }

    $suffixe = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = "$Destination.nouveau-$suffixe"
    $racine = $tmp + '\'
    $prefixe = $DossierZip.TrimEnd('\') + '\'
    $archive = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream (, $Zip)), [IO.Compression.ZipArchiveMode]::Read)
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        foreach ($e in $archive.Entries) {
            $nom = $e.FullName.Replace('/', '\')
            if (-not $nom.StartsWith($prefixe, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = $nom.Substring($prefixe.Length)
            if (-not $rel -or $rel.EndsWith('\')) { continue }
            $cible = [IO.Path]::GetFullPath((Join-Path $tmp $rel))
            if (-not $cible.StartsWith($racine, [StringComparison]::OrdinalIgnoreCase)) { throw "Chemin refusé dans le zip : $($e.FullName)" }
            New-Item -ItemType Directory -Force -Path (Split-Path $cible -Parent) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $cible, $true)
        }
    } catch {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch {}
        throw
    } finally { $archive.Dispose() }
    if (-not (Test-Path -LiteralPath (Join-Path $tmp $Exe))) {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        throw "Le zip ne contient pas $Exe dans le dossier $DossierZip."
    }

    if (Test-Path -LiteralPath $Destination) {
        $ancien = "$Destination.ancien-$suffixe"
        try { Move-Item -LiteralPath $Destination -Destination $ancien -ErrorAction Stop }
        catch {
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
            throw 'L''appli est encore ouverte (ses fichiers sont utilisés) : ferme-la puis réessaie.'
        }
        Move-Item -LiteralPath $tmp -Destination $Destination
        try { Remove-Item -LiteralPath $ancien -Recurse -Force -ErrorAction Stop } catch {}   # sinon, nettoyé la prochaine fois
    } else {
        Move-Item -LiteralPath $tmp -Destination $Destination
    }
    $Destination
}
