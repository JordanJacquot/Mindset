# Mindset : versions publiées sur GitHub, téléchargement et installation d'un zip signé.
#
# Autonome (pas de fenêtre, pas d'autre module que signature.ps1) : chargé par les tâches de fond de Mindset
# et par installer-admin.ps1, lancé en administrateur pour les applis qui vont dans Program Files.

# Dernière version publiée d'une appli : numéro, adresse du zip et de sa signature.
# -Zip : son nom, ou plusieurs noms par ordre de préférence (le nom d'aujourd'hui, puis l'ancien : une version publiée
# avant le changement de nom de l'appli n'a que l'ancien) ; le premier présent dans la version est pris.
function Get-Publication([string]$Depot, [string[]]$Zip) {
    $Zip = @($Zip | Where-Object { $_ })
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Depot/releases/latest" -Headers @{ 'User-Agent' = 'Mindset' } -TimeoutSec 15
    } catch {
        # L'API de GitHub limite les questions (60 par heure et par connexion) : on passe alors par la page des versions
        $repli = Get-PublicationSansApi $Depot $Zip
        if ($repli) { return $repli }
        return @{ Erreur = "Impossible de joindre GitHub ($($_.Exception.Message))." }
    }
    $nom = @($Zip | Where-Object { $n = $_; @($r.assets | Where-Object { $_.name -eq $n }).Count }) | Select-Object -First 1
    if (-not $nom) { return @{ Erreur = "La dernière version publiée ne contient pas $($Zip[0])." } }
    $z = @($r.assets | Where-Object { $_.name -eq $nom }) | Select-Object -First 1
    $s = @($r.assets | Where-Object { $_.name -eq "$nom.sig" }) | Select-Object -First 1
    @{
        Version = ([string]$r.tag_name -replace '^[vV]', '')
        Fichier = [string]$nom
        UrlZip  = [string]$z.browser_download_url
        UrlSig  = if ($s) { [string]$s.browser_download_url } else { $null }
        Notes   = [string]$r.body
    }
}

# Sans l'API : https://github.com/<dépôt>/releases/latest renvoie vers /releases/tag/v<version> (sans limite de questions),
# et les fichiers d'une version sont à /releases/download/v<version>/<fichier>
function Get-PublicationSansApi([string]$Depot, [string[]]$Zip) {
    $Zip = @($Zip | Where-Object { $_ })
    try {
        $q = [Net.HttpWebRequest]::Create("https://github.com/$Depot/releases/latest")
        $q.Method = 'HEAD'; $q.AllowAutoRedirect = $false; $q.UserAgent = 'Mindset'; $q.Timeout = 15000
        $rep = $q.GetResponse(); $vers = [string]$rep.Headers['Location']; $rep.Close()
        if ($vers -notmatch '/releases/tag/v?(\d+(\.\d+){1,3})$') { return $null }
        $version = $Matches[1]
        $base = "https://github.com/$Depot/releases/download/v$version"
        # Plusieurs noms possibles : le premier publié dans cette version (sinon le premier, comme avec un seul nom)
        $nom = $Zip[0]
        if ($Zip.Count -gt 1) { $nom = @($Zip | Where-Object { Test-FichierPublie "$base/$_" }) + $Zip[0] | Select-Object -First 1 }
        # La signature est-elle publiée ?
        $sig = if (Test-FichierPublie "$base/$nom.sig") { "$base/$nom.sig" } else { $null }
        @{ Version = $version; Fichier = $nom; UrlZip = "$base/$nom"; UrlSig = $sig; Notes = (Get-NotesPage $Depot $version) }
    } catch { $null }
}

# Un fichier d'une version publiée existe-t-il ? (une redirection vers le fichier veut dire oui)
function Test-FichierPublie([string]$Url) {
    try {
        $q = [Net.HttpWebRequest]::Create($Url); $q.Method = 'HEAD'; $q.AllowAutoRedirect = $false; $q.UserAgent = 'Mindset'; $q.Timeout = 15000
        $r = $q.GetResponse(); $ok = [int]$r.StatusCode -in 200, 301, 302; $r.Close(); $ok
    } catch { $false }
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

# Les seules adresses d'où Mindset télécharge : GitHub et ses serveurs de fichiers (vérifié aussi après chaque redirection)
function Test-AdresseTelechargement([string]$Url) {
    $Url -match '^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/'
}

# $Progres (facultatif, une table partagée avec Mindset) : Recu et Total en octets, mis à jour pendant le téléchargement
# (la barre de progression de la console)
# Au plus $MaxOctets (200 Mo : le zip d'une appli en fait quelques-uns) et $DelaiSecondes en tout (10 minutes) : un
# fichier énorme ou un réseau qui traîne s'arrêtent avec un message, au lieu de laisser la carte sur « Téléchargement... ».
# Les redirections (GitHub renvoie vers son serveur de fichiers) sont suivies ici, 5 au plus, et chaque adresse est revérifiée.
function Get-Octets([string]$Url, $Progres = $null, [long]$MaxOctets = 200MB, [int]$DelaiSecondes = 600) {
    if (-not (Test-AdresseTelechargement $Url)) { throw "Adresse de téléchargement refusée : $Url" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $limite = (Get-Date).AddSeconds($DelaiSecondes)
    $trop = "Le fichier téléchargé est trop gros (plus de $([math]::Round($MaxOctets / 1MB)) Mo) : rien n'a été installé."
    $lent = "Le téléchargement a pris plus de $([math]::Round($DelaiSecondes / 60, 1)) minutes : la connexion est peut-être trop lente, réessaie plus tard."
    for ($saut = 0; ; $saut++) {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'Mindset'; $req.AllowAutoRedirect = $false
        $req.Timeout = 30000; $req.ReadWriteTimeout = 30000
        $rep = $req.GetResponse()
        $code = [int]$rep.StatusCode
        if ($code -in 301, 302, 303, 307, 308) {
            $vers = [string]$rep.Headers['Location']; $rep.Dispose()
            if ($saut -ge 5 -or -not $vers) { throw 'Le téléchargement renvoie d''adresse en adresse : rien n''a été installé.' }
            $Url = (New-Object Uri ([Uri]$Url), $vers).AbsoluteUri
            if (-not (Test-AdresseTelechargement $Url)) { throw "Adresse de téléchargement refusée : $Url" }
            if ((Get-Date) -gt $limite) { throw $lent }
            continue
        }
        break
    }
    try {
        if ($rep.ContentLength -gt $MaxOctets) { throw $trop }
        if ($Progres -and $rep.ContentLength -gt 0) { $Progres.Total = $rep.ContentLength }
        $flux = $rep.GetResponseStream(); $ms = New-Object IO.MemoryStream; $morceau = New-Object byte[] 65536
        while (($n = $flux.Read($morceau, 0, $morceau.Length)) -gt 0) {
            $ms.Write($morceau, 0, $n)
            if ($Progres) { $Progres.Recu += $n }
            if ($ms.Length -gt $MaxOctets) { throw $trop }
            if ((Get-Date) -gt $limite) { throw $lent }
        }
        , $ms.ToArray()
    } finally { $rep.Dispose() }
}

# Le dossier principal d'un zip téléchargé (son contenu en octets) : le premier des noms donnés (le nom d'aujourd'hui,
# puis l'ancien nom de l'appli) qui contient son programme -Exe. Zip illisible ou aucun : le premier nom (l'installation
# dira alors ce qui manque).
function Get-DossierZip([byte[]]$Zip, [string[]]$Noms, [string]$Exe) {
    $Noms = @($Noms | Where-Object { $_ })
    try {
        Add-Type -AssemblyName System.IO.Compression
        $archive = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream (, $Zip)), [IO.Compression.ZipArchiveMode]::Read)
        try { $entrees = @($archive.Entries | ForEach-Object { $_.FullName.Replace('/', '\') }) } finally { $archive.Dispose() }
        foreach ($n in $Noms) { if ($entrees -icontains "$($n.TrimEnd('\'))\$Exe") { return $n } }
    } catch {}
    $Noms[0]
}

# Ce que dit un fichier version.json (ses octets) : @{ Version; Appli; MindsetMin }, ou $null s'il est illisible ou mal
# formé. La construction d'une appli le range dans le dossier principal de son zip (<DossierZip>\version.json, voir
# docs\contrat-appli.md, partie 10). Lu exactement comme suite-commun (lire_version_json, rust\suite-commun\src\paquet.rs) :
# 64 Ko au plus ; marque d'encodage suivie (UTF-8, UTF-16, UTF-32), sinon UTF-8 ; un objet JSON ; « version » obligatoire
# (2 à 4 nombres) ; « appli » et « mindset_min » facultatifs, mais des textes s'ils sont là, et « mindset_min » au format
# d'une version. Les noms des champs comptent avec leur casse. Rien de ce qui est lu n'est exécuté.
function Read-VersionJson([byte[]]$Octets) {
    if ($null -eq $Octets -or $Octets.Length -gt 64KB) { return $null }
    $n = $Octets.Length
    try {
        $texte = if ($n -ge 3 -and $Octets[0] -eq 0xEF -and $Octets[1] -eq 0xBB -and $Octets[2] -eq 0xBF) { (New-Object Text.UTF8Encoding $false).GetString($Octets, 3, $n - 3) }
                 elseif ($n -ge 4 -and $Octets[0] -eq 0xFF -and $Octets[1] -eq 0xFE -and $Octets[2] -eq 0 -and $Octets[3] -eq 0) { (New-Object Text.UTF32Encoding $false, $false).GetString($Octets, 4, $n - 4) }
                 elseif ($n -ge 4 -and $Octets[0] -eq 0 -and $Octets[1] -eq 0 -and $Octets[2] -eq 0xFE -and $Octets[3] -eq 0xFF) { (New-Object Text.UTF32Encoding $true, $false).GetString($Octets, 4, $n - 4) }
                 elseif ($n -ge 2 -and $Octets[0] -eq 0xFF -and $Octets[1] -eq 0xFE) { (New-Object Text.UnicodeEncoding $false, $false).GetString($Octets, 2, $n - 2) }
                 elseif ($n -ge 2 -and $Octets[0] -eq 0xFE -and $Octets[1] -eq 0xFF) { (New-Object Text.UnicodeEncoding $true, $false).GetString($Octets, 2, $n - 2) }
                 else { (New-Object Text.UTF8Encoding $false).GetString($Octets) }
        Add-Type -AssemblyName System.Web.Extensions
        $o = (New-Object Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($texte)
    } catch { return $null }
    # (un objet JSON : un dictionnaire dont les clés comptent avec leur casse)
    if ($o -isnot [Collections.Generic.Dictionary[string, object]]) { return $null }
    $forme = '^[0-9]+(\.[0-9]+){1,3}\z'
    if (-not $o.ContainsKey('version') -or $o['version'] -isnot [string] -or $o['version'] -cnotmatch $forme) { return $null }
    $r = @{ Version = [string]$o['version']; Appli = $null; MindsetMin = $null }
    if ($o.ContainsKey('appli')) {
        if ($o['appli'] -isnot [string]) { return $null }
        $r.Appli = [string]$o['appli']
    }
    if ($o.ContainsKey('mindset_min')) {
        if ($o['mindset_min'] -isnot [string] -or $o['mindset_min'] -cnotmatch $forme) { return $null }
        $r.MindsetMin = [string]$o['mindset_min']
    }
    $r
}

# Le version.json d'un zip (ses octets) : celui du dossier principal (<DossierZip>\version.json) et celui de la racine du
# zip (nom exact « version.json », comme suite-commun). @{ Present; Info } : Present faux s'il n'y en a aucun (ou zip
# illisible) ; Info $null s'il est illisible, ou si les deux existent sans être identiques.
function Get-VersionJsonZip([byte[]]$Zip, [string]$DossierZip) {
    $dansDossier = $null; $racine = $null
    try {
        Add-Type -AssemblyName System.IO.Compression
        $archive = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream (, $Zip)), [IO.Compression.ZipArchiveMode]::Read)
        try {
            $json = $DossierZip.TrimEnd('\') + '\version.json'
            foreach ($e in $archive.Entries) {
                $aLaRacine = $e.FullName -ceq 'version.json'
                if (-not $aLaRacine -and $e.FullName.Replace('/', '\') -ine $json) { continue }
                $ms = New-Object IO.MemoryStream
                $flux = $e.Open()
                try { $flux.CopyTo($ms) } finally { $flux.Dispose() }
                if ($aLaRacine) { $racine = $ms.ToArray() } else { $dansDossier = $ms.ToArray() }
            }
        } finally { $archive.Dispose() }
    } catch { return @{ Present = $false; Info = $null } }
    if ($null -eq $dansDossier -and $null -eq $racine) { return @{ Present = $false; Info = $null } }
    if ($null -ne $dansDossier -and $null -ne $racine -and [Convert]::ToBase64String($dansDossier) -cne [Convert]::ToBase64String($racine)) { return @{ Present = $true; Info = $null } }
    @{ Present = $true; Info = (Read-VersionJson $(if ($null -ne $dansDossier) { $dansDossier } else { $racine })) }
}

# L'appli attendue dans un zip quand l'appelant ne la donne pas (installer-admin.ps1) : l'id de l'entrée de apps.json
# (celui de ce Mindset, à côté du dossier modules) dont le dossier du zip est $DossierZip, ou « mindset » pour Mindset
# lui-même. '' si on ne sait pas : pas de contrôle de l'appli alors (le programme attendu dans <DossierZip>\ reste vérifié).
function Get-AppliDuDossierZip([string]$DossierZip) {
    $d = $DossierZip.TrimEnd('\')
    if ($d -ieq 'Mindset') { return 'mindset' }
    if (-not $PSScriptRoot) { return '' }
    try {
        $liste = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($a in $liste) {
            if ([string]$a.id -cmatch '^[a-z0-9-]+$' -and ([string]$a.dossier_zip -ieq $d -or ($a.ancien_dossier_zip -and [string]$a.ancien_dossier_zip -ieq $d))) { return [string]$a.id }
        }
    } catch {}
    ''
}

# Le version.json d'un zip vérifié AVANT de fermer quoi que ce soit (tâche de téléchargement de Mindset) : illisible, d'une
# autre appli, ou demandant un Mindset plus récent : une erreur, avec le même message que l'installation. Sans version.json
# (toutes les applis d'aujourd'hui) ou zip illisible : rien (l'installation fait ensuite ses contrôles habituels).
function Test-PaquetAppli([byte[]]$Zip, [string]$DossierZip, [string]$Appli, [string]$VersionMindset) {
    $j = Get-VersionJsonZip $Zip $DossierZip
    if (-not $j.Present) { return }
    $i = $j.Info
    if (-not $i) { throw 'Le fichier téléchargé ne dit pas quelle version il contient : rien n''a été installé.' }
    if ($i.Appli -and $Appli -and -not [string]::Equals($i.Appli, $Appli, [StringComparison]::OrdinalIgnoreCase)) { throw "Ce fichier contient l'appli $($i.Appli) et pas $Appli : rien n'a été installé." }
    if ($i.MindsetMin -and $VersionMindset -and (Test-VersionPlusRecente $i.MindsetMin $VersionMindset)) { throw "Mets d'abord Mindset à jour : cette version demande Mindset $($i.MindsetMin) ou plus récent." }
}

# Version contenue dans un zip (ses octets) : celle de son version.json s'il en a un (illisible, ou deux différents : ''),
# sinon la ligne « $AppVersion = 'x.y.z' » d'un script de <DossierZip>\fichiers\ (comme Get-VersionDossier, avant toute
# extraction). '' si introuvable ou zip illisible.
function Get-VersionZip([byte[]]$Zip, [string]$DossierZip) {
    $j = Get-VersionJsonZip $Zip $DossierZip
    if ($j.Present) { if ($j.Info) { return $j.Info.Version }; return '' }
    try {
        Add-Type -AssemblyName System.IO.Compression
        $archive = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream (, $Zip)), [IO.Compression.ZipArchiveMode]::Read)
        try {
            $prefixe = $DossierZip.TrimEnd('\') + '\fichiers\'
            foreach ($e in $archive.Entries) {
                $nom = $e.FullName.Replace('/', '\')
                if (-not $nom.StartsWith($prefixe, [StringComparison]::OrdinalIgnoreCase) -or $nom.Substring($prefixe.Length) -notmatch '^[^\\]+\.ps1$') { continue }
                $lecteur = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
                try {
                    for ($n = 0; $n -lt 40; $n++) {
                        $l = $lecteur.ReadLine(); if ($null -eq $l) { break }
                        if ($l -match "^\`$AppVersion\s*=\s*'(\d+(\.\d+){1,3})'") { return $Matches[1] }
                    }
                } finally { $lecteur.Dispose() }
            }
        } finally { $archive.Dispose() }
    } catch {}
    ''
}

function Test-VersionPlusRecente([string]$Distante, [string]$Locale) {
    try { [version]$Distante -gt [version]$Locale } catch { $false }
}

# Version d'une appli installée dans un dossier : celle de son version.json s'il en a un, sinon la ligne
# « $AppVersion = 'x.y.z' » de son script principal (fichiers\*.ps1 : Nevermind.ps1, Evermind.ps1, Mindset.ps1). '' si
# introuvable. Un version.json abîmé laisse la place à l'ancienne lecture (la version installée reste connue).
# -Detail (pour Install-Paquet) : @{ Version ; Info (ce que dit version.json, ou $null) ; Illisible (version.json présent
# mais illisible : Version vaut alors '') ; Scripts (la version lue dans les scripts, ou '') }.
function Get-VersionDossier([string]$Dossier, [switch]$Detail) {
    $info = $null; $illisible = $false
    $fj = Join-Path $Dossier 'version.json'
    if (Test-Path -LiteralPath $fj -PathType Leaf) {
        try { $info = Read-VersionJson ([IO.File]::ReadAllBytes($fj)) } catch {}
        $illisible = -not $info
        if ($info -and -not $Detail) { return $info.Version }
    }
    $scripts = ''
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Dossier 'fichiers') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        foreach ($l in @(Get-Content -LiteralPath $f.FullName -TotalCount 40 -ErrorAction SilentlyContinue)) {
            if ($l -match "^\`$AppVersion\s*=\s*'(\d+(\.\d+){1,3})'") { $scripts = $Matches[1]; break }
        }
        if ($scripts) { break }
    }
    if (-not $Detail) { return $scripts }
    @{ Version = $(if ($info) { $info.Version } elseif ($illisible) { '' } else { $scripts }); Info = $info; Illisible = $illisible; Scripts = $scripts }
}

# Installe (ou remplace) une appli à partir de son zip signé.
#   Le zip est vérifié puis extrait depuis la mémoire : le fichier sur le disque peut changer après la vérification,
#   ce qu'on installe est exactement ce qu'on a vérifié.
#   Seul le contenu du dossier principal du zip (« Nevermind\... », « Evermind\... ») est extrait, et tout chemin qui
#   sortirait du dossier d'arrivée est refusé.
#   Le nouveau dossier est préparé à côté puis échangé avec l'ancien : une erreur en route laisse l'ancien intact.
#   -ClePublique : le dossier des clés publiques de la suite (fichiers\cles-publiques), voir signature.ps1.
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

#   -VersionMinimale : la plus haute version de l'appli déjà installée sur ce PC (gardée par installer-admin.ps1) ; une
#   version plus ancienne est refusée, même si l'appli a été supprimée entre-temps.
#   version.json (docs\contrat-appli.md, partie 10) est lu avant la ligne $AppVersion des scripts, comme suite-commun :
#   -Appli : l'id de l'appli attendue (sans lui : déduit de apps.json par le dossier du zip, voir Get-AppliDuDossierZip) ;
#   un version.json d'une autre appli est refusé. -VersionMindset : la version du Mindset qui installe ; un version.json
#   qui demande un Mindset plus récent (« mindset_min ») est refusé (sans elle : pas ce contrôle ici ; Mindset le fait
#   avant de fermer l'appli, Test-PaquetAppli). Un zip sans version.json s'installe exactement comme avant.
function Install-Paquet([byte[]]$Zip, [byte[]]$Signature, [string]$ClePublique, [string]$Destination, [string]$DossierZip, [string]$Exe, [string]$VersionMinimale, [string]$Appli, [string]$VersionMindset) {
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
    $versionRacine = $null   # (le version.json de la racine du zip, s'il y en a un : rangé ensuite avec l'appli)
    # Le contenu d'une entrée, copié dans $Vers, avec les contrôles de suite-commun (Rust) que .NET ne fait pas :
    # - une entrée marquée « chiffrée » est refusée (.NET en installerait les octets tels quels) ;
    # - le contenu doit avoir exactement la taille et le CRC annoncés par le zip, et un deflate illisible est refusé
    #   (.NET écrirait sans contrôle ce qu'il tire d'un deflate abîmé : parfois rien du tout, sans erreur).
    # Même message que suite-commun dans les deux cas. Un zip abîmé n'est jamais installé, même signé.
    # Le drapeau, le CRC annoncé et le calcul du CRC sont des parties internes de .NET : absentes, l'entrée est refusée.
    # (pas une fonction à part : des tests chargent Install-Paquet seule)
    $interne = [Reflection.BindingFlags]'NonPublic,Instance'
    $champDrapeaux = [IO.Compression.ZipArchiveEntry].GetField('_generalPurposeBitFlag', $interne)
    $champCrc = [IO.Compression.ZipArchiveEntry].GetField('_crc32', $interne)
    $calculCrc = [IO.Compression.ZipArchive].Assembly.GetType('System.IO.Compression.Crc32Helper')
    if ($calculCrc) { $calculCrc = $calculCrc.GetMethod('UpdateCrc32', [Reflection.BindingFlags]'NonPublic,Public,Static', $null, [type[]]@([uint32], [byte[]], [int], [int]), $null) }
    $abime = 'Le zip est abîmé : rien n''a été installé.'
    $copier = {
        param($Entree, [IO.Stream]$Vers)
        if (-not $champDrapeaux -or ([int]$champDrapeaux.GetValue($Entree) -band 1)) { throw 'Le zip contient un fichier chiffré : rien n''a été installé.' }
        if (-not $calculCrc -or -not $champCrc) { throw $abime }
        $flux = $Entree.Open()
        try {
            $tampon = [byte[]]::new(81920)   # (New-Object l'envelopperait : Invoke ne le prendrait pas)
            $total = [long]0
            [uint32]$crc = 0
            while ($true) {
                try { $n = $flux.Read($tampon, 0, $tampon.Length) } catch { throw $abime }   # (deflate illisible)
                if ($n -le 0) { break }
                $total += $n
                if ($total -gt $Entree.Length) { throw $abime }
                $crc = $calculCrc.Invoke($null, [object[]]@($crc, $tampon, 0, $n))
                $Vers.Write($tampon, 0, $n)
            }
        } finally { $flux.Dispose() }
        if ($total -ne $Entree.Length -or $crc -ne [uint32]$champCrc.GetValue($Entree)) { throw $abime }
    }
    $archive = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream (, $Zip)), [IO.Compression.ZipArchiveMode]::Read)
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        foreach ($e in $archive.Entries) {
            if ($e.FullName -ceq 'version.json') {
                $ms = New-Object IO.MemoryStream
                & $copier $e $ms
                $versionRacine = $ms.ToArray(); continue
            }
            $nom = $e.FullName.Replace('/', '\')
            if (-not $nom.StartsWith($prefixe, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = $nom.Substring($prefixe.Length)
            if (-not $rel -or $rel.EndsWith('\')) { continue }
            $cible = [IO.Path]::GetFullPath((Join-Path $tmp $rel))
            if (-not $cible.StartsWith($racine, [StringComparison]::OrdinalIgnoreCase)) { throw "Chemin refusé dans le zip : $($e.FullName)" }
            New-Item -ItemType Directory -Force -Path (Split-Path $cible -Parent) | Out-Null
            # (comme ExtractToFile : fichier remplacé s'il existe, date de modification reprise du zip)
            $fichier = [IO.File]::Open($cible, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { & $copier $e $fichier } finally { $fichier.Dispose() }
            [IO.File]::SetLastWriteTime($cible, $e.LastWriteTime.DateTime)
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
    # Un zip dont on ne peut pas lire la version est refusé aussi : on ne saurait pas dire s'il est plus ancien.
    $illisible = 'Le fichier téléchargé ne dit pas quelle version il contient : rien n''a été installé.'
    # version.json à la racine du zip : rangé avec l'appli (pour les comparaisons suivantes) ; s'il y en a aussi un dans
    # le dossier principal, les deux doivent être identiques
    if ($null -ne $versionRacine) {
        $dansDossier = Join-Path $tmp 'version.json'
        $different = $false
        try {
            if (Test-Path -LiteralPath $dansDossier -PathType Leaf) { $different = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dansDossier)) -cne [Convert]::ToBase64String($versionRacine) }
            else { [IO.File]::WriteAllBytes($dansDossier, $versionRacine) }
        } catch {
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
            throw
        }
        if ($different) {
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
            throw $illisible
        }
    }
    $lu = Get-VersionDossier $tmp -Detail
    $nouvelle = $lu.Version
    if (-not $nouvelle) {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        throw $illisible
    }
    if ($lu.Info) {
        $refus = $null
        # L'ancienne ligne $AppVersion, si elle est encore là, doit dire la même chose
        if ($lu.Scripts -and $lu.Scripts -cne $lu.Info.Version) { $refus = $illisible }
        # Le zip d'une autre appli n'est jamais installé à la place de celle-ci
        elseif ($lu.Info.Appli) {
            $attendue = if ($Appli) { $Appli } else { Get-AppliDuDossierZip $DossierZip }
            if ($attendue -and -not [string]::Equals($lu.Info.Appli, $attendue, [StringComparison]::OrdinalIgnoreCase)) { $refus = "Ce fichier contient l'appli $($lu.Info.Appli) et pas $attendue : rien n'a été installé." }
        }
        if (-not $refus -and $lu.Info.MindsetMin -and $VersionMindset -and (Test-VersionPlusRecente $lu.Info.MindsetMin $VersionMindset)) {
            $refus = "Mets d'abord Mindset à jour : cette version demande Mindset $($lu.Info.MindsetMin) ou plus récent."
        }
        if ($refus) {
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
            throw $refus
        }
    }
    # (la version installée : un version.json abîmé chez l'utilisateur ne bloque pas, l'ancienne lecture prend le relais)
    $installee = Get-VersionDossier $Destination
    if ($installee -and (Test-VersionPlusRecente $installee $nouvelle)) {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        throw "Version $nouvelle refusée : la version $installee, plus récente, est déjà installée."
    }
    if ($VersionMinimale -and (Test-VersionPlusRecente $VersionMinimale $nouvelle)) {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        throw "Version $nouvelle refusée : la version $VersionMinimale, plus récente, a déjà été installée sur ce PC."
    }

    # Mise à jour de Mindset lui-même (faite une fois qu'il est fermé) : l'utilisateur n'a rien à fermer ni à réessayer,
    # Mindset garde sa version et réessaiera tout seul (ce que dit la suite du message, mindset.ps1)
    $bloque = if ($Exe -ieq 'Mindset.exe') { 'Des fichiers de Mindset étaient encore utilisés par Windows ou par l''antivirus, il n''y a rien à faire de ton côté.' }
    if (Test-Path -LiteralPath $Destination) {
        $ancien = "$Destination.ancien-$suffixe"
        # (quelques essais : un programme qui vient de se fermer, comme la 3D de Mindset, lâche ses fichiers un peu après)
        if (-not (Move-DossierEssais $Destination $ancien)) {
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
            throw $(if ($bloque) { $bloque } else { 'L''appli est encore ouverte (ses fichiers sont utilisés) : ferme-la puis réessaie.' })
        }
        if (-not (Move-DossierEssais $tmp $Destination)) {
            [IO.Directory]::Move($ancien, $Destination)   # on remet l'ancienne version telle quelle
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
            throw $(if ($bloque) { $bloque } else { 'La nouvelle version n''a pas pu être mise en place (fichiers bloqués) : réessaie dans un moment.' })
        }
        try { Remove-Item -LiteralPath $ancien -Recurse -Force -ErrorAction Stop } catch {}   # sinon, nettoyé la prochaine fois
    } elseif (-not (Move-DossierEssais $tmp $Destination)) {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        throw 'L''appli n''a pas pu être mise en place (fichiers bloqués) : réessaie dans un moment.'
    }
    $Destination
}
