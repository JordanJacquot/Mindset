# Mindset : la liste des applis de la suite et leur état.
# Chargé par Mindset.ps1, qui définit $AppDir, après donnees.ps1 ($DataDir), signature.ps1 et taches.ps1.
#
# La liste vient de liste.ps1 (chargé ici) : celle publiée en ligne et gardée dans le dossier des données de Mindset si
# elle est bonne (signée, plus récente que celle livrée, pour ce Mindset), sinon fichiers\apps.json livré avec Mindset.
# Chaque entrée y est vérifiée champ par champ (ConvertTo-Appli), et aucun texte qui en vient n'est exécuté comme une
# commande.
. (Join-Path $PSScriptRoot 'liste.ps1')

# La liste en ligne gardée ('' en test sans dossier de données à part : jamais celle du vrai PC)
$ListeGardee = if ($DataDir -and (-not $EnTest -or $env:MINDSET_DONNEES)) { Join-Path $DataDir $NomListeEnLigne } else { '' }

function Get-Applis {
    try { $l = Get-EntreesApplis $AppDir $ListeGardee ([string]$AppVersion) }
    catch { Write-Log "apps.json illisible : $_"; return @() }
    $origine = if ($l.Source -eq 'en-ligne') { "liste en ligne n° $($l.Numero)" } else { 'apps.json' }
    if ($l.Source -eq 'en-ligne') { Write-Log "Liste des applis : $origine (gardée, vérifiée)" }
    # (un id déjà vu plus haut : ignoré, la première entrée compte)
    $vus = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($e in $l.Entrees) {
        $a = ConvertTo-Appli $e $origine
        if (-not $a) { continue }
        if (-not $vus.Add($a.Id)) { Write-Log "${origine} : appli ignorée ($($a.Id), déjà dans la liste)"; continue }
        $a
    }
}

# La liste en ligne, cherchée au démarrage (en fond, sans retarder l'ouverture) puis toutes les 6 heures, avec les
# nouvelles versions (Invoke-Actualiser, accueil.ps1 : donc jamais si « Chercher les nouvelles versions » est coupé).
# Téléchargée sans l'API de GitHub (pas de limite de questions), 15 secondes au plus par fichier, vérifiée puis gardée
# par Add-ListeEnLigne (liste.ps1). Une nouvelle liste acceptée sert au prochain démarrage de Mindset : les cartes, les
# onglets et tout ce qui tient une appli ouverte sont faits au démarrage, les refaire en marche ne serait pas sûr.
# (test seulement : MINDSET_LISTE_URL, un fichier de ce PC à la place de l'adresse de GitHub)
$UrlListeEnLigne = "https://github.com/JordanJacquot/Mindset/releases/download/liste-applis/$NomListeEnLigne"
$script:DerniereListe = [datetime]::MinValue
function Update-ListeEnLigne {
    if (-not $ListeGardee -or ((Get-Date) - $script:DerniereListe).TotalHours -lt 6) { return }
    $script:DerniereListe = Get-Date
    $p = @{ Url = $UrlListeEnLigne; Fichier = '' }
    if ($EnTest -and $env:MINDSET_LISTE_URL) { $p.Fichier = $env:MINDSET_LISTE_URL }
    Start-Tache {
        $p = $args[0]
        if ($p.Fichier) { return @{ Json = [IO.File]::ReadAllBytes($p.Fichier); Sig = [IO.File]::ReadAllBytes("$($p.Fichier).sig") } }
        @{ Json = (Get-Octets $p.Url -MaxOctets 256KB -DelaiSecondes 15); Sig = (Get-Octets "$($p.Url).sig" -MaxOctets 64KB -DelaiSecondes 15) }
    } $p { param($Resultat, $Erreur) Receive-ListeEnLigne $Resultat $Erreur }
}
function Receive-ListeEnLigne($Resultat, $Erreur) {
    if ($Erreur -or -not $Resultat) {
        $script:DerniereListe = (Get-Date).AddHours(-5)   # (réessai dans une heure)
        Write-Log "Liste des applis en ligne : pas téléchargée ($Erreur)"
        return
    }
    try {
        $l = Add-ListeEnLigne ([byte[]]$Resultat.Json) ([byte[]]$Resultat.Sig) $AppDir $ListeGardee ([string]$AppVersion)
        if ($l) { Write-Log "Liste des applis en ligne n° $($l.Numero) gardée ($(@($l.Entrees).Count) applis) : elle sera prise au prochain démarrage de Mindset" }
    } catch { Write-Log "Liste des applis en ligne refusée : $($_.Exception.Message) (on garde celle qu'on avait)" }
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

# Les programmes de l'appli qui tournent, trouvés par leur CHEMIN, jamais par leur nom : l'hôte de chaque appli s'appelle
# Mindset.exe (comme Mindset lui-même, pour que le Gestionnaire des tâches regroupe la suite sur une ligne), et l'ancien
# <Appli>.exe n'est plus qu'un relais. Ce sont ceux lancés depuis le dossier où elle est installée ; -Hote : seulement son
# programme principal (l'hôte Mindset.exe ou l'ancien <Appli>.exe, directement dans ce dossier), pas ses programmes d'aide.
# Jamais Mindset lui-même (ce processus, ni un programme du dossier de Mindset). Rend des objets Process.
function Get-ProcessusAppli($Appli, [switch]$Hote) {
    $inst = Get-Installation $Appli
    if (-not $inst -or -not $inst.Dossier) { return @() }
    $noms = if ($Hote) { [string[]]@($Appli.Exe, 'Mindset.exe') } else { $null }
    @(foreach ($id in [MSProcessus]::DansDossier($inst.Dossier, $noms, $PID, $MonDossier)) { try { Get-Process -Id $id -ErrorAction Stop } catch {} })
}

# Les programmes d'aide qu'une appli lance depuis son dossier de DONNÉES (Evermind : voix\Mindset.exe, voix\ia\..., Mindcare :
# ia\...), eux aussi trouvés par leur chemin : ils s'appellent parfois Mindset.exe, et ne sont jamais Mindset lui-même
# (ni ce processus, ni un programme du dossier de Mindset). Rend des objets Process.
function Get-ProcessusDonneesAppli($Appli) {
    @(foreach ($d in @((Get-DossierDonnees $Appli), $Appli.Donnees) | Where-Object { $_ } | Select-Object -Unique) {
        if ($SuiteDir -and ($d.TrimEnd('\') -ieq $SuiteDir.TrimEnd('\'))) { continue }   # (jamais toutes les données de la suite)
        foreach ($id in [MSProcessus]::DansDossier($d, $null, $PID, $MonDossier)) { try { Get-Process -Id $id -ErrorAction Stop } catch {} }
    })
}

# Ouverte ou non : chaque appli garde un mutex tant qu'elle tourne (« une seule à la fois »).
# Si l'appli tourne en administrateur, Windows refuse de nous l'ouvrir : il existe, donc elle tourne.
# Sinon, on cherche son programme par son chemin (une instance de test, par exemple, ne prend pas le mutex).
# Une version d'avant le changement de nom garde son ancien mutex (AncienMutex) : elle compte aussi.
function Test-AppliOuverte($Appli) {
    foreach ($nom in @($Appli.Mutex, $Appli.AncienMutex) | Where-Object { $_ }) {
        try { $m = [System.Threading.Mutex]::OpenExisting($nom); $m.Dispose(); return $true }
        catch {
            $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
            if ($e -is [System.UnauthorizedAccessException]) { return $true }
        }
    }
    [bool]@(Get-ProcessusAppli $Appli -Hote).Count
}

$Applis = @(Get-Applis)
