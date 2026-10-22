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
        @{ Version = $version; UrlZip = "$base/$Zip"; UrlSig = $sig; Notes = (Get-NotesPage $Depot $version) }
    } catch { $null }
}

# Les notes d'une version lues sur sa page GitHub (quand l'API refuse) ; introuvables : le lien vers la page
function Get-NotesPage([string]$Depot, [string]$Version) {
    $page = "https://github.com/$Depot/releases/tag/v$Version"
    $notes = ''
    try {
        $wc = New-Object Net.WebClient; $wc.Headers['User-Agent'] = 'Mindset'; $wc.Encoding = [Text.Encoding]::UTF8
        try { $html = $wc.DownloadString($page) } finally { $wc.Dispose() }
        if ($html -match '(?s)<div[^>]*class="markdown-body[^"]*"[^>]*>(.*?)</div>') {
            $t = $Matches[1] -replace '(?i)<br\s*/?>|</p>|</li>|</h\d>', "`n" -replace '(?i)<li[^>]*>', '- ' -replace '<[^>]+>', ''
            $notes = ([Net.WebUtility]::HtmlDecode($t) -replace "[ \t]+\r?\n", "`n" -replace "(\r?\n){3,}", "`n`n").Trim()
        }
    } catch {}
    if ($notes.Length -gt 4000) { $notes = $notes.Substring(0, 4000) + '...' }
    if (-not $notes) { $notes = "Les nouveautés de cette version : $page" }
    $notes
}

# $Progres (facultatif, une table partagée avec Mindset) : Recu et Total en octets, mis à jour pendant le téléchargement
# (la barre de progression de la console)
function Get-Octets([string]$Url, $Progres = $null) {
    if ($Url -notmatch '^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/') { throw "Adresse de téléchargement refusée : $Url" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not $Progres) {
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = 'Mindset'
        try { return , $wc.DownloadData($Url) } finally { $wc.Dispose() }
    }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'Mindset'; $req.AllowAutoRedirect = $true
    $rep = $req.GetResponse()
    try {
        if ($rep.ContentLength -gt 0) { $Progres.Total = $rep.ContentLength }
        $flux = $rep.GetResponseStream(); $ms = New-Object IO.MemoryStream; $morceau = New-Object byte[] 65536
        while (($n = $flux.Read($morceau, 0, $morceau.Length)) -gt 0) { $ms.Write($morceau, 0, $n); $Progres.Recu += $n }
        , $ms.ToArray()
    } finally { $rep.Dispose() }
}

function Test-VersionPlusRecente([string]$Distante, [string]$Locale) {
    try { [version]$Distante -gt [version]$Locale } catch { $false }
}

# Version d'une appli installée dans un dossier : la ligne « $AppVersion = 'x.y.z' » de son script principal
# (fichiers\*.ps1 : OptiGame.ps1, Evermind.ps1, Mindset.ps1). '' si introuvable.
function Get-VersionDossier([string]$Dossier) {
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Dossier 'fichiers') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        foreach ($l in @(Get-Content -LiteralPath $f.FullName -TotalCount 40 -ErrorAction SilentlyContinue)) {
            if ($l -match "^\`$AppVersion\s*=\s*'(\d+(\.\d+){1,3})'") { return $Matches[1] }
        }
    }
    ''
}

# Installe (ou remplace) une appli à partir de son zip signé.
#   Le zip est vérifié puis extrait depuis la mémoire : le fichier sur le disque peut changer après la vérification,
#   ce qu'on installe est exactement ce qu'on a vérifié.
#   Seul le contenu du dossier principal du zip (« OptiGame\... », « Evermind\... ») est extrait, et tout chemin qui
#   sortirait du dossier d'arrivée est refusé.
#   Le nouveau dossier est préparé à côté puis échangé avec l'ancien : une erreur en route laisse l'ancien intact.
# Renomme un dossier d'un seul bloc, en réessayant pendant 3 secondes : un programme qui vient de se fermer (la 3D de
# Mindset) ou l'antivirus qui analyse un exe tout juste extrait garde ses fichiers ouverts un court moment. (Un seul bloc :
# un fichier ouvert fait échouer le renommage sans rien déplacer ; Move-Item, lui, déplaçait déjà une partie des fichiers
# avant d'échouer, et l'appli installée restait incomplète.)
function Move-DossierEssais([string]$De, [string]$Vers) {
    for ($n = 0; $n -lt 6; $n++) {
        try { [IO.Directory]::Move($De, $Vers); return $true } catch { Start-Sleep -Milliseconds 500 }
    }
    $false
}

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
    # Jamais de retour en arrière : une version plus ancienne que celle installée est refusée, même signée (un
    # programme pourrait sinon faire réinstaller une vieille version et ses défauts). La même version reste permise.
    $nouvelle = Get-VersionDossier $tmp; $installee = Get-VersionDossier $Destination
    if ($nouvelle -and $installee -and (Test-VersionPlusRecente $installee $nouvelle)) {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        throw "Version $nouvelle refusée : la version $installee, plus récente, est déjà installée."
    }

    if (Test-Path -LiteralPath $Destination) {
        $ancien = "$Destination.ancien-$suffixe"
        # (quelques essais : un programme qui vient de se fermer, comme la 3D de Mindset, lâche ses fichiers un peu après)
        if (-not (Move-DossierEssais $Destination $ancien)) {
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
            throw 'L''appli est encore ouverte (ses fichiers sont utilisés) : ferme-la puis réessaie.'
        }
        if (-not (Move-DossierEssais $tmp $Destination)) {
            [IO.Directory]::Move($ancien, $Destination)   # on remet l'ancienne version telle quelle
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
            throw 'La nouvelle version n''a pas pu être mise en place (fichiers bloqués) : réessaie dans un moment.'
        }
        try { Remove-Item -LiteralPath $ancien -Recurse -Force -ErrorAction Stop } catch {}   # sinon, nettoyé la prochaine fois
    } elseif (-not (Move-DossierEssais $tmp $Destination)) {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        throw 'L''appli n''a pas pu être mise en place (fichiers bloqués) : réessaie dans un moment.'
    }
    $Destination
}
