# Mindset : la liste des applis de la suite, celle livrée avec Mindset (fichiers\apps.json) ou celle publiée en ligne.
#
# Autonome (pas de fenêtre, pas d'autre module que signature.ps1) : chargé par applis.ps1, par les tâches de fond de
# Mindset et par la version PowerShell du mini-installateur (outils\installer-admin-powershell.ps1).
#
# apps.json est livré avec Mindset, avec son numéro (apps-liste.txt). Une liste plus récente peut être publiée sans
# nouvelle version de Mindset (outils\publier-liste.ps1) : apps-en-ligne.json et sa signature apps-en-ligne.json.sig, sur
# la version « liste-applis » du dépôt de Mindset (une préversion : /releases/latest ne la voit jamais). Elle n'est prise
# que si TOUT est bon, sinon on garde ce qu'on avait (jamais à moitié) :
#   1. 256 Ko au plus, signée par une des clés livrées (fichiers\cles-publiques, comme les zips : voir signature.ps1) ;
#   2. un objet JSON : « liste » (un entier, 1 ou plus), « mindset_min » (une version x.y.z), « applis » (un tableau non
#      vide) ; les noms des champs comptent avec leur casse ;
#   3. « mindset_min » pas plus récent que ce Mindset (sinon : une liste pour un Mindset plus récent, ignorée) ;
#   4. « liste » plus grand que le numéro livré, et que celui de la liste déjà gardée : une ancienne liste signée ne
#      revient jamais (pas de retour en arrière) ;
#   5. chaque entrée passe les contrôles de ConvertTo-Appli, les mêmes que pour apps.json : une entrée refusée est
#      ignorée (le reste est pris), comme un id déjà vu plus haut ; il doit en rester au moins une.
# Une liste acceptée remplace la liste livrée (c'est la liste complète : elle peut retirer une appli).
# Elle est gardée dans le dossier des données de Mindset (apps-en-ligne.json et .sig), modifiable sans droits : à chaque
# lecture, tout est revérifié sur les octets lus une seule fois (rien n'est relu entre la vérification et l'usage).

$TailleMaxListe = 256KB
$NomListeEnLigne = 'apps-en-ligne.json'

# Le journal de Mindset, s'il est là (pas dans l'installateur ni dans les tâches de fond)
function Write-JournalListe([string]$Texte) {
    if (Get-Command Write-Log -CommandType Function -ErrorAction SilentlyContinue) { Write-Log $Texte }
}

# Une entrée de la liste (apps.json ou liste en ligne), vérifiée champ par champ : l'appli telle que Mindset s'en sert, ou
# $null si elle est refusée (noté au journal). On n'y lit que des champs connus, et aucun texte qui en vient n'est
# exécuté comme une commande. $Origine : le nom de la liste, pour le journal.
function ConvertTo-Appli($a, [string]$Origine = 'apps.json') {
    $nomFichier = '^[^\\/:*?"<>|]+$'
    if ($a -isnot [Management.Automation.PSCustomObject] -or $a.id -isnot [string] -or $a.couleur -isnot [string]) { Write-JournalListe "$Origine : entrée mal formée ignorée"; return $null }
    # Son type (docs\contrat-appli.md, partie 1) : « powershell » (champ absent : les applis d'aujourd'hui) a un script
    # principal ; « rust » n'en a pas forcément (sa version est dans son version.json). Tout autre type : ignorée.
    $type = if ($null -eq $a.type) { 'powershell' } else { $a.type }
    if ($type -isnot [string] -or $type -cnotmatch '^(powershell|rust)$') { Write-JournalListe "$Origine : appli ignorée ($($a.id), type inconnu)"; return $null }
    $ok = $a.id -match '^[a-z0-9-]+$' -and $a.nom -and $a.couleur -match '^#[0-9A-Fa-f]{6}$' -and
          $a.depot -match '^[\w.-]+/[\w.-]+$' -and $a.zip -match $nomFichier -and $a.dossier_zip -match $nomFichier -and
          $a.exe -match '^[^\\/:*?"<>|]+\.exe$'
    if ($type -eq 'powershell' -or $a.script) { $ok = $ok -and $a.script -match '^[\w\\.-]+\.ps1$' -and $a.script -notmatch '\.\.' }
    # Les noms de son verrou et de son signal d'affichage, et la version de « cache_depuis » : contrôlés comme les autres
    if ($a.mutex) { $ok = $ok -and $a.mutex -match '^Local\\[\w.-]+$' }
    if ($a.afficher_signal) { $ok = $ok -and $a.afficher_signal -match '^Local\\[\w.-]+$' }
    if ($a.cache_depuis) { $ok = $ok -and $a.cache_depuis -match '^\d+(\.\d+){1,3}$' }
    if ($a.desinstalleur) { $ok = $ok -and $a.desinstalleur -match '^[^\\/:*?"<>|]+\.exe$' }
    if ($a.afficher_fichier) { $ok = $ok -and $a.afficher_fichier -match $nomFichier }
    if ($a.aide) { $ok = $ok -and $a.aide -cmatch '^[A-Za-z0-9 ]{1,40} \(aide\)$' -and $a.aide_exe -match '^[^\\/:*?"<>|]+\.exe$' }
    if ($a.sans_droits_depuis) { $ok = $ok -and $a.sans_droits_depuis -match '^\d+(\.\d+){1,3}$' }
    # Ses anciens noms (Nevermind s'appelait OptiGame) : seulement pour reconnaître une installation ou une version publiée
    # d'avant le changement de nom, vérifiés comme les nouveaux
    if ($a.ancien_zip) { $ok = $ok -and $a.ancien_zip -match $nomFichier }
    if ($a.ancien_dossier_zip) { $ok = $ok -and $a.ancien_dossier_zip -match $nomFichier }
    if ($a.ancien_script) { $ok = $ok -and $a.ancien_script -match '^[\w\\.-]+\.ps1$' -and $a.ancien_script -notmatch '\.\.' }
    if ($a.ancien_mutex) { $ok = $ok -and $a.ancien_mutex -match '^Local\\[\w.-]+$' }
    if (-not $ok) { Write-JournalListe "$Origine : appli ignorée ($($a.id))"; return $null }
    # Son logo dans Mindset (à la place de sa première lettre) : un tracé de traits droits (M, L) sur une grille de 100,
    # dessiné au trait épais comme les lettres de Nevermind et d'Evermind. Mal formé : ignoré, la lettre reste.
    $logo = if ([string]$a.logo -match '^[ML0-9., ]{3,240}$' -and [string]$a.logo -match '^M') { [string]$a.logo } else { '' }
    if ($a.logo -and -not $logo) { Write-JournalListe "$Origine : logo de $($a.id) ignoré (tracé non compris)" }
    # Sa page de confidentialité (ce que l'appli envoie sur Internet), montrée avant de l'installer : seulement une page
    # du compte GitHub de la suite, sinon ignorée (la phrase renvoie alors à celle de Mindset)
    $confidentialite = if ([string]$a.confidentialite -cmatch '^https://github\.com/JordanJacquot/[\w.-]+/blob/main/[\w.-]+\.md$') { [string]$a.confidentialite } else { '' }
    if ($a.confidentialite -and -not $confidentialite) { Write-JournalListe "$Origine : page de confidentialité de $($a.id) ignorée (adresse non acceptée)" }
    $epaisseur = 0.0
    if (-not [double]::TryParse([string]$a.logo_epaisseur, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$epaisseur) -or $epaisseur -lt 4 -or $epaisseur -gt 25) { $epaisseur = 12.0 }
    [pscustomobject]@{
        Id              = [string]$a.id
        Type            = $type   # « powershell » ou « rust »
        Nom             = [string]$a.nom
        Couleur         = [string]$a.couleur
        AppId           = 'JordanJacquot.' + ([string]$a.nom -replace '[^A-Za-z0-9]', '')   # son identité dans la barre des tâches (celle que l'appli se donne)
        Description     = [string]$a.description
        Presentation    = [string]$a.presentation   # ce que fait l'appli, en une phrase (console : menu en grand, écran « pas encore installée »)
        Depot           = [string]$a.depot
        Zip             = [string]$a.zip
        DossierZip      = [string]$a.dossier_zip
        Exe             = [string]$a.exe
        Script          = [string]$a.script
        Mutex           = [string]$a.mutex
        # (anciens noms, ou '' : la version publiée sous l'ancien nom, le dossier de son zip, son script principal dans une
        # installation d'avant, son mutex quand une version d'avant est ouverte)
        AncienZip       = [string]$a.ancien_zip
        AncienDossierZip = [string]$a.ancien_dossier_zip
        AncienScript    = [string]$a.ancien_script
        AncienMutex     = [string]$a.ancien_mutex
        AfficherFichier = [string]$a.afficher_fichier   # nom du fichier, dans le dossier de données de l'appli
        AfficherSignal  = [string]$a.afficher_signal
        Desinstalleur   = [string]$a.desinstalleur
        Donnees         = [Environment]::ExpandEnvironmentVariables([string]$a.donnees)
        Admin           = [bool]$a.admin
        Rappels         = ($a.rappels -eq $true)   # appli de rappels (Evermind) : elle doit tourner pour qu'ils sonnent, donc s'ouvre avec Mindset d'office
        SansDroitsDepuis = [string]$a.sans_droits_depuis   # version à partir de laquelle elle n'a plus besoin des droits (son Aide les a)
        Aide            = [string]$a.aide       # tâche planifiée de sa partie administrateur (« \Mindset\<aide> »)
        AideExe         = [string]$a.aide_exe   # le programme qu'elle lance, à côté de l'exe de l'appli
        CacheDepuis     = [string]$a.cache_depuis   # version à partir de laquelle l'appli lancée cachée se dessine une fois affichée dans Mindset
        Confidentialite = $confidentialite   # page qui dit ce que l'appli envoie sur Internet (ou rien)
        Logo            = $logo        # tracé du logo (grille de 100), sinon sa première lettre
        LogoEpaisseur   = $epaisseur / 100
    }
}

# Le numéro de la liste livrée (fichiers\apps-liste.txt) : un entier, ou -1 s'il est absent ou illisible (aucune liste en
# ligne n'est alors prise : sans numéro, on ne saurait pas dire si elle est plus récente)
function Get-NumeroListeLivree([string]$DossierFichiers) {
    try {
        $t = [IO.File]::ReadAllText((Join-Path $DossierFichiers 'apps-liste.txt'), [Text.Encoding]::UTF8).Trim()
        if ($t -match '^[0-9]{1,9}\z') { return [long]$t }
    } catch {}
    -1
}

# Une liste en ligne (ses octets et ceux de sa signature) vérifiée selon les règles 1 à 5 (voir plus haut), avec les clés
# et le numéro de $DossierFichiers (le dossier fichiers de Mindset). -NumeroMin : le numéro qu'elle doit dépasser (celui de
# la liste livrée, ou de la liste déjà gardée). Rend @{ Numero ; MindsetMin ; Entrees } (les entrées acceptées, telles
# qu'écrites dans la liste), ou une erreur qui dit pourquoi elle est refusée.
function Read-ListeEnLigne([byte[]]$Json, [byte[]]$Signature, [string]$DossierFichiers, [string]$VersionMindset, [long]$NumeroMin) {
    # 1. Taille et signature
    if (-not $Json -or $Json.Length -gt $TailleMaxListe) { throw "liste vide ou trop grosse (plus de $($TailleMaxListe / 1KB) Ko)" }
    if (-not (Test-Signature $Json $Signature (Join-Path $DossierFichiers 'cles-publiques'))) { throw 'signature invalide' }
    # 2. Sa forme (UTF-8 strict, marque d'encodage permise)
    try {
        $debut = if ($Json.Length -ge 3 -and $Json[0] -eq 0xEF -and $Json[1] -eq 0xBB -and $Json[2] -eq 0xBF) { 3 } else { 0 }
        $j = (New-Object Text.UTF8Encoding $false, $true).GetString($Json, $debut, $Json.Length - $debut) | ConvertFrom-Json -ErrorAction Stop
    } catch { throw 'liste illisible (JSON abîmé)' }
    if ($j -isnot [Management.Automation.PSCustomObject]) { throw 'liste illisible (pas un objet JSON)' }
    $noms = @($j.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($n in 'liste', 'mindset_min', 'applis') { if ($noms -cnotcontains $n) { throw "liste illisible (champ « $n » absent)" } }
    $numero = $j.liste
    if (($numero -isnot [int] -and $numero -isnot [long]) -or $numero -lt 1) { throw 'liste illisible (« liste » doit être un entier, 1 ou plus)' }
    $min = $j.mindset_min
    if ($min -isnot [string] -or $min -cnotmatch '^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}\z') { throw 'liste illisible (« mindset_min » doit être une version x.y.z)' }
    $applis = $j.applis
    if ($applis -isnot [array] -or -not $applis.Count) { throw 'liste illisible (« applis » doit être un tableau non vide)' }
    # 3. Pour ce Mindset
    $ce = $null
    if (-not [version]::TryParse([string]$VersionMindset, [ref]$ce)) { throw 'version de ce Mindset inconnue' }
    if ([version]$min -gt $ce) { throw "liste pour un Mindset plus récent ($min ou plus, celui-ci est en $VersionMindset)" }
    # 4. Plus récente que ce qu'on a
    if ($numero -le $NumeroMin) { throw "liste n° $numero trop ancienne (il faut un numéro plus grand que $NumeroMin)" }
    # 5. Chaque entrée, avec les mêmes contrôles que apps.json ; un id déjà vu plus haut est ignoré
    $vus = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $entrees = @(foreach ($e in $applis) {
        $a = ConvertTo-Appli $e 'liste en ligne'
        if (-not $a) { continue }
        if (-not $vus.Add($a.Id)) { Write-JournalListe "liste en ligne : appli ignorée ($($a.Id), déjà dans la liste)"; continue }
        $e
    })
    if (-not $entrees.Count) { throw 'aucune appli valable dans la liste' }
    @{ Numero = [long]$numero; MindsetMin = $min; Entrees = $entrees }
}

# La liste gardée ($Fichier : apps-en-ligne.json, sa signature à côté), lue une seule fois puis vérifiée (règles 1 à 5,
# numéro plus grand que celui de la liste livrée). Rend comme Read-ListeEnLigne, $null s'il n'y en a pas, ou une erreur.
function Read-ListeGardee([string]$Fichier, [string]$DossierFichiers, [string]$VersionMindset) {
    if (-not $Fichier -or -not [IO.File]::Exists($Fichier)) { return $null }
    $livree = Get-NumeroListeLivree $DossierFichiers
    if ($livree -lt 0) { throw 'numéro de la liste livrée (apps-liste.txt) illisible' }
    # (sa taille regardée avant de la lire : un fichier énorme n'est jamais chargé en mémoire)
    if ((New-Object IO.FileInfo $Fichier).Length -gt $TailleMaxListe -or (New-Object IO.FileInfo "$Fichier.sig").Length -gt 64KB) { throw "liste vide ou trop grosse (plus de $($TailleMaxListe / 1KB) Ko)" }
    try { $json = [IO.File]::ReadAllBytes($Fichier); $sig = [IO.File]::ReadAllBytes("$Fichier.sig") }
    catch { throw 'liste ou signature illisible sur le disque' }
    Read-ListeEnLigne $json $sig $DossierFichiers $VersionMindset $livree
}

# Les entrées de la liste des applis à utiliser : la liste gardée $ListeGardee si elle est bonne, sinon apps.json livré
# (dans $DossierFichiers). Rend @{ Source ('en-ligne' ou 'livree') ; Numero ; Entrees }. apps.json illisible : une erreur.
# C'est par ici que passe tout ce qui lit la liste des applis (applis.ps1, paquets.ps1, l'installateur).
function Get-EntreesApplis([string]$DossierFichiers, [string]$ListeGardee, [string]$VersionMindset) {
    if ($ListeGardee) {
        try {
            $l = Read-ListeGardee $ListeGardee $DossierFichiers $VersionMindset
            if ($l) { return @{ Source = 'en-ligne'; Numero = $l.Numero; Entrees = $l.Entrees } }
        } catch { Write-JournalListe "Liste des applis gardée refusée ($($_.Exception.Message)) : celle livrée avec Mindset est prise" }
    }
    # (sans @() : PowerShell 5.1 rend un tableau JSON en un seul bloc, que @() emballerait dans un autre tableau)
    $liste = [IO.File]::ReadAllText((Join-Path $DossierFichiers 'apps.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    @{ Source = 'livree'; Numero = (Get-NumeroListeLivree $DossierFichiers); Entrees = @(foreach ($a in $liste) { $a }) }
}

# Une liste téléchargée (ses octets et ceux de sa signature) : gardée à la place de $ListeGardee si elle passe les règles
# 1 à 5, avec un numéro plus grand que celui de la liste livrée ET que celui de la liste déjà gardée (si elle est bonne).
# Écrite à côté puis renommée, seulement une fois acceptée. Rend ce qu'a rendu Read-ListeEnLigne, $null si c'est la même
# que celle qu'on a déjà (même numéro : le cas de tous les jours, rien à dire), ou une erreur qui dit pourquoi elle est
# refusée (rien n'est alors changé sur le disque).
function Add-ListeEnLigne([byte[]]$Json, [byte[]]$Signature, [string]$DossierFichiers, [string]$ListeGardee, [string]$VersionMindset) {
    $min = Get-NumeroListeLivree $DossierFichiers
    if ($min -lt 0) { throw 'numéro de la liste livrée (apps-liste.txt) illisible' }
    $gardee = $null
    try { $gardee = Read-ListeGardee $ListeGardee $DossierFichiers $VersionMindset } catch {}
    if ($gardee -and $gardee.Numero -gt $min) { $min = $gardee.Numero }
    # (vérifiée en entier même quand elle porte le numéro qu'on a déjà, puis laissée de côté)
    $l = Read-ListeEnLigne $Json $Signature $DossierFichiers $VersionMindset ($min - 1)
    if ($l.Numero -eq $min) { return $null }
    New-Item -ItemType Directory -Force -Path (Split-Path $ListeGardee -Parent) | Out-Null
    # (la signature d'abord, puis la liste : interrompu entre les deux, la signature ne va plus avec la liste, qui est
    # alors refusée à la lecture : la liste livrée est prise, et le prochain téléchargement remet tout en ordre)
    foreach ($x in @(@("$ListeGardee.sig", $Signature), @($ListeGardee, $Json))) {
        $tmp = "$($x[0]).tmp"
        [IO.File]::WriteAllBytes($tmp, [byte[]]$x[1])
        if ([IO.File]::Exists($x[0])) { [IO.File]::Replace($tmp, $x[0], $null) } else { [IO.File]::Move($tmp, $x[0]) }
    }
    $l
}
