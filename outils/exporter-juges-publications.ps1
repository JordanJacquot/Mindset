# Mindset : juges du bloc « publications » pour la version Rust (rust\mindset-publications).
#
#   Depuis l'outil PowerShell, dans le dépôt : & '.\outils\exporter-juges-publications.ps1'
#
# Les VRAIES fonctions de la version PowerShell sont prises dans leurs fichiers (par l'analyseur : les modules exécutent du
# code au chargement), devant un FAUX GitHub (rien ne part sur Internet) et de faux réglages en mémoire. Leurs réponses
# sont écrites dans rust\mindset-publications\tests\juges\*.json, que les tests Rust rejouent :
#   - publications.json : Get-Publication (et tout ce qu'elle appelle : ConvertFrom-Release, Get-Preversion,
#     Get-PreversionSansApi, Get-PublicationSansApi, Test-FichierPublie, Get-NotesPage), avec la liste exacte des
#     questions posées au faux GitHub, dans l'ordre ;
#   - notes.json : Get-NotesPage seule (pages de versions inventées) ;
#   - html.json : [Net.WebUtility]::HtmlDecode (celle de Get-NotesPage) et sa table des noms (&eacute; ...) ;
#   - adresses.json : Test-AdresseTelechargement ;
#   - versions.json : Test-VersionPlusRecente et la lecture d'un numéro par [version] ;
#   - scenarios.json : Invoke-Actualiser, Update-InfoActualiser, Update-Publications, Get-VersionsEssaiAppli,
#     Set-VersionsEssaiAppli, la minuterie d'une heure (accueil.ps1) et Show-Fenetre (zone.ps1), pas à pas, avec une
#     horloge figée.
#
# Le faux GitHub : une réponse par adresse (code, contenu, en-tête Location) ou une erreur (pas de réponse du tout).
# Une adresse inconnue donne l'erreur « pas de réponse prévue pour <adresse> (essai) », comme le FauxReseau de Rust.
# Un code 400 ou plus est l'erreur de .NET « Le serveur distant a retourné une erreur : (404) Introuvable. » (texte de
# Get-MessageHttp ci-dessous, le même que dans le Rust : voir DIVERGENCES.md).
#
# Rien n'est lu ni écrit ailleurs que dans rust\mindset-publications\tests\juges. Aucune fenêtre, aucun réseau.

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$modules = Join-Path $racine 'Mindset\fichiers\modules'
$sortie = Join-Path $racine 'rust\mindset-publications\tests\juges'
New-Item -ItemType Directory -Force -Path $sortie | Out-Null

# ---------------------------------------------------------------------------------------------------------------
# Les vraies fonctions, prises dans leurs fichiers
# ---------------------------------------------------------------------------------------------------------------
$asts = @{}
foreach ($f in 'paquets.ps1', 'installations.ps1', 'accueil.ps1', 'mindset.ps1', 'zone.ps1', 'taches.ps1') {
    $err = $null
    $asts[$f] = [System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $modules $f), [Text.Encoding]::UTF8), [ref]$null, [ref]$err)
    if ($err) { throw "$f illisible : $($err[0].Message)" }
}
function Get-TexteFonction([string]$Fichier, [string]$Nom) {
    $d = $asts[$Fichier].Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Nom }, $true)
    if (-not $d) { throw "$Fichier : fonction $Nom introuvable" }
    $d.Extent.Text
}
$a_importer = @(
    @('paquets.ps1', 'Get-Publication'), @('paquets.ps1', 'ConvertFrom-Release'), @('paquets.ps1', 'Get-Preversion'),
    @('paquets.ps1', 'Get-PreversionSansApi'), @('paquets.ps1', 'Get-PublicationSansApi'), @('paquets.ps1', 'Test-FichierPublie'),
    @('paquets.ps1', 'Get-NotesPage'), @('paquets.ps1', 'Test-AdresseTelechargement'), @('paquets.ps1', 'Test-VersionPlusRecente'),
    @('installations.ps1', 'Update-Publications'), @('installations.ps1', 'Get-VersionsEssaiAppli'), @('installations.ps1', 'Set-VersionsEssaiAppli'),
    @('accueil.ps1', 'Invoke-Actualiser'), @('accueil.ps1', 'Update-InfoActualiser'), @('accueil.ps1', 'Get-Appli'),
    @('mindset.ps1', 'Test-VerifVersionsActive'), @('zone.ps1', 'Show-Fenetre'), @('taches.ps1', 'New-Action'), @('taches.ps1', 'Pop-Action')
)
$texte = foreach ($x in $a_importer) {
    # (les requêtes HEAD de .NET passent par le faux GitHub : [Net.HttpWebRequest]::Create devient New-FausseRequete)
    (Get-TexteFonction $x[0] $x[1]).Replace('[Net.HttpWebRequest]::Create', 'New-FausseRequete')
}
. ([scriptblock]::Create(($texte -join "`r`n")))

# La minuterie d'une heure (accueil.ps1, EtatTimer) : la ligne telle qu'elle est écrite
$texteAccueil = [IO.File]::ReadAllText((Join-Path $modules 'accueil.ps1'), [Text.Encoding]::UTF8)
$m = [regex]::Match($texteAccueil, 'if \(\(\(Get-Date\) - \$script:DernieresPublications\)\.TotalHours -ge 1\) \{ Invoke-Actualiser \}')
if (-not $m.Success) { throw 'accueil.ps1 : la minuterie d''une heure est introuvable' }
$minuterie = [scriptblock]::Create($m.Value)

# ---------------------------------------------------------------------------------------------------------------
# Le faux GitHub
# ---------------------------------------------------------------------------------------------------------------
$global:FauxGithub = [hashtable]::new([StringComparer]::Ordinal)
$global:Demandes = New-Object Collections.Generic.List[string]
function global:Get-MessageHttp([int]$Code) {
    $textes = @{ 400 = 'Demande incorrecte'; 401 = 'Non autorisé'; 403 = 'Interdit'; 404 = 'Introuvable'; 429 = 'Too Many Requests'; 500 = 'Erreur interne du serveur'
                 502 = 'Passerelle incorrecte'; 503 = 'Serveur indisponible' }
    $t = if ($textes.ContainsKey($Code)) { " $($textes[$Code])" } else { '' }
    "Le serveur distant a retourné une erreur : ($Code)$t."
}
function global:Invoke-FauxGithub([string]$Methode, [string]$Url) {
    $global:Demandes.Add("$Methode $Url")
    if (-not $global:FauxGithub.ContainsKey($Url)) { throw "pas de réponse prévue pour $Url (essai)" }
    $r = $global:FauxGithub[$Url]
    if ($r.erreur) { throw [string]$r.erreur }
    if ([int]$r.statut -ge 400) { throw (Get-MessageHttp ([int]$r.statut)) }
    $r
}
function global:New-FausseRequete([string]$Url) {
    $q = [pscustomobject]@{ Url = $Url; Method = 'GET'; AllowAutoRedirect = $true; UserAgent = ''; Timeout = 0; ReadWriteTimeout = 0 }
    $q | Add-Member ScriptMethod GetResponse {
        $r = Invoke-FauxGithub $this.Method $this.Url
        $rep = [pscustomobject]@{ StatusCode = [int]$r.statut; Headers = @{ Location = [string]$r.location } }
        $rep | Add-Member ScriptMethod Close {}
        $rep | Add-Member ScriptMethod Dispose {}
        $rep
    }
    $q
}
function global:Invoke-RestMethod([string]$Uri, $Headers, $TimeoutSec) {
    $r = Invoke-FauxGithub 'GET' $Uri
    $corps = [string]$r.corps
    try { $o = $corps | ConvertFrom-Json } catch { return $corps }
    $o
}
function global:New-Object {
    if ("$args" -match 'Net\.WebClient') {
        $w = [pscustomobject]@{ Headers = @{}; Encoding = $null }
        $w | Add-Member ScriptMethod DownloadString { param($u) [string](Invoke-FauxGithub 'GET' $u).corps }
        $w | Add-Member ScriptMethod Dispose {}
        return $w
    }
    Microsoft.PowerShell.Utility\New-Object @args
}

function ConvertTo-Sortie($p) {
    if ($null -eq $p) { return $null }
    $o = [ordered]@{}
    foreach ($k in @($p.Keys | Sort-Object)) { $o[$k] = $p[$k] }
    $o
}
function Set-Github([object[]]$Entrees) {
    $global:FauxGithub = [hashtable]::new([StringComparer]::Ordinal)
    foreach ($e in $Entrees) { $global:FauxGithub[$e.url] = $e }
    $global:Demandes.Clear()
}
# Une entrée du faux GitHub : une réponse (code, contenu, Location) ou une erreur
function Rep([string]$Url, [int]$Statut = 200, [string]$Corps = '', [string]$Location = '') { [ordered]@{ url = $Url; statut = $Statut; corps = $Corps; location = $Location; erreur = '' } }
function Panne([string]$Url, [string]$Erreur) { [ordered]@{ url = $Url; statut = 0; corps = ''; location = ''; erreur = $Erreur } }

# Une version publiée, telle que l'API de GitHub la décrit (en JSON)
function New-Release([string]$Depot, $Tag, $Pre = $false, $Brouillon = $false, [string[]]$Fichiers = @(), $Notes = $null) {
    [ordered]@{ tag_name = $Tag; prerelease = $Pre; draft = $Brouillon; body = $(if ($null -ne $Notes) { $Notes } else { "notes $Tag" })
        assets = @(foreach ($f in $Fichiers) { [ordered]@{ name = $f; browser_download_url = "https://github.com/$Depot/releases/download/$Tag/$f" } }) }
}
function Json($o) { ConvertTo-Json -InputObject $o -Depth 8 -Compress }

# ---------------------------------------------------------------------------------------------------------------
# publications.json : Get-Publication devant le faux GitHub
# ---------------------------------------------------------------------------------------------------------------
$cas = New-Object Collections.ArrayList
function Add-Cas([string]$Nom, [string]$Depot, [string[]]$Zips, [bool]$Essai, [object[]]$Github) {
    Set-Github $Github
    $res = $null; $exception = $null
    try { $res = Get-Publication $Depot $Zips -Essai:$Essai } catch { $exception = $_.Exception.Message }
    [void]$cas.Add([ordered]@{ nom = $Nom; depot = $Depot; zips = @($Zips); essai = $Essai; github = @($Github); resultat = (ConvertTo-Sortie $res)
        exception = $exception; demandes = @($global:Demandes) })
}
$mc = 'JordanJacquot/Mindcare'
$api = "https://api.github.com/repos/$mc"
$gh = "https://github.com/$mc"
$zips = @('Mindcare.zip')
$deux = @('Mindcare.zip', 'Ancien.zip')
$sig = @('Mindcare.zip', 'Mindcare.zip.sig')
function Latest($Rel) { Rep "$api/releases/latest" 200 (Json $Rel) }
function Liste([object[]]$Rels) { Rep "$api/releases?per_page=30" 200 (Json @($Rels)) }
$v153 = New-Release $mc 'v0.15.3' $false $false $sig
$page153 = "<html><div class=`"markdown-body my-3`"><p>Correction &amp; rapidité</p><ul><li>un</li><li>deux</li></ul></div></html>"

Add-Cas 'normale, case décochée : une seule question' $mc $zips $false @((Latest $v153))
Add-Cas 'normale, case cochée, aucune préversion' $mc $zips $true @((Latest $v153), (Liste @($v153)))
Add-Cas 'préversion plus récente prise (essai)' $mc $zips $true @((Latest $v153), (Liste @($v153, (New-Release $mc 'v0.90.0' $true $false $sig), (New-Release $mc 'liste-applis' $true $false $sig))))
Add-Cas 'préversion plus récente, case décochée : ignorée' $mc $zips $false @((Latest $v153), (Liste @($v153, (New-Release $mc 'v0.90.0' $true $false $sig))))
Add-Cas 'préversion plus ancienne que la normale : la normale' $mc $zips $true @((Latest (New-Release $mc 'v0.91.0' $false $false $sig)), (Liste @((New-Release $mc 'v0.90.2' $true $false $sig))))
Add-Cas 'brouillon, autre zip, nom qui n''est pas un numéro : ignorés' $mc $zips $true @((Latest $v153), (Liste @((New-Release $mc 'v0.95.0' $true $true $sig), (New-Release $mc 'v0.92.0' $true $false @('Autre.zip', 'Autre.zip.sig')), (New-Release $mc 'liste-applis' $true $false $sig), (New-Release $mc 'v0.90.1' $true $false $sig))))
Add-Cas 'préversion sans signature' $mc $zips $true @((Latest $v153), (Liste @((New-Release $mc 'v0.90.0' $true $false @('Mindcare.zip')))))
Add-Cas 'normale sans signature' $mc $zips $false @((Latest (New-Release $mc 'v1.0.0' $false $false @('Mindcare.zip'))))
Add-Cas 'normale sans le zip' $mc $zips $false @((Latest (New-Release $mc 'v1.0.0' $false $false @('Autre.zip'))))
Add-Cas 'ancien nom du zip seulement' $mc $deux $false @((Latest (New-Release $mc 'v0.10.0' $false $false @('Ancien.zip', 'Ancien.zip.sig'))))
Add-Cas 'les deux noms : le nom d''aujourd''hui' $mc $deux $false @((Latest (New-Release $mc 'v0.11.0' $false $false @('Ancien.zip', 'Ancien.zip.sig', 'Mindcare.zip', 'Mindcare.zip.sig'))))
Add-Cas 'nom du zip d''une autre casse' $mc $zips $false @((Latest (New-Release $mc 'V2.0.1' $false $false @('MINDCARE.ZIP', 'mindcare.zip.SIG'))))
Add-Cas 'nom de version sans v' $mc $zips $false @((Latest (New-Release $mc '3.1.4' $false $false $sig)))
Add-Cas 'nom de version vV' $mc $zips $false @((Latest (New-Release $mc 'vV3.1' $false $false $sig)))
Add-Cas 'nom de version vide' $mc $zips $false @((Latest (New-Release $mc '' $false $false $sig)))
Add-Cas 'nom de version nombre' $mc $zips $false @((Latest (New-Release $mc 7 $false $false $sig)))
Add-Cas 'notes absentes (null)' $mc $zips $false @((Rep "$api/releases/latest" 200 '{"tag_name":"v1.2.3","assets":[{"name":"Mindcare.zip","browser_download_url":"https://github.com/x/Mindcare.zip"}]}'))
Add-Cas 'notes avec accents et retours' $mc $zips $false @((Latest (New-Release $mc 'v1.2.4' $false $false $sig "Nouveautés :`r`n- Café crème`n- Forêt « verte »")))
Add-Cas 'asset sans adresse' $mc $zips $false @((Rep "$api/releases/latest" 200 '{"tag_name":"v1.2.5","assets":[{"name":"Mindcare.zip"},{"name":"Mindcare.zip.sig"}]}'))
Add-Cas 'assets en objet seul' $mc $zips $false @((Rep "$api/releases/latest" 200 '{"tag_name":"v1.2.6","assets":{"name":"Mindcare.zip","browser_download_url":"https://github.com/z/Mindcare.zip"}}'))
Add-Cas 'réponse pas en JSON : ne contient pas le zip' $mc $zips $false @((Rep "$api/releases/latest" 200 'pas du json'))
Add-Cas 'réponse vide' $mc $zips $false @((Rep "$api/releases/latest" 200 ''))
Add-Cas 'préversion "true" en texte, 1 en nombre, 0 et null' $mc $zips $true @((Latest $v153), (Rep "$api/releases?per_page=30" 200 ('[' + ((
    '{"tag_name":"v0.20.0","prerelease":"true","draft":false,"body":"a","assets":[{"name":"Mindcare.zip","browser_download_url":"u20"}]}',
    '{"tag_name":"v0.30.0","prerelease":1,"draft":"false","body":"b","assets":[{"name":"Mindcare.zip","browser_download_url":"u30"}]}',
    '{"tag_name":"v0.40.0","prerelease":0,"body":"c","assets":[{"name":"Mindcare.zip","browser_download_url":"u40"}]}',
    '{"tag_name":"v0.50.0","prerelease":null,"body":"d","assets":[{"name":"Mindcare.zip","browser_download_url":"u50"}]}') -join ',') + ']')))
Add-Cas 'brouillon "true" en texte, préversion TRUE' $mc $zips $true @((Latest $v153), (Rep "$api/releases?per_page=30" 200 ('[' + ((
    '{"tag_name":"v0.60.0","prerelease":true,"draft":"true","assets":[{"name":"Mindcare.zip","browser_download_url":"u60"}]}',
    '{"tag_name":"v0.55.0","prerelease":"TRUE","draft":"False","assets":[{"name":"Mindcare.zip","browser_download_url":"u55"}]}') -join ',') + ']')))
Add-Cas 'préversions de même numéro : la première' $mc $zips $true @((Latest $v153), (Liste @((New-Release $mc 'v0.90.0' $true $false $sig '1re'), (New-Release $mc '0.90.0' $true $false $sig '2e'), (New-Release $mc 'v0.89.9' $true $false $sig))))
Add-Cas 'préversions 1.2 et 1.2.0 (1.2.0 plus récente)' $mc $zips $true @((Latest (New-Release $mc 'v1.1.0' $false $false $sig)), (Liste @((New-Release $mc 'v1.2' $true $false $sig), (New-Release $mc 'v1.2.0' $true $false $sig), (New-Release $mc 'v1.2.0.0' $true $false $sig))))
Add-Cas 'préversion à 4 nombres et normale à 2' $mc $zips $true @((Latest (New-Release $mc 'v2.0' $false $false $sig)), (Liste @((New-Release $mc 'v2.0.0.1' $true $false $sig))))
Add-Cas 'préversion avec retour à la ligne final' $mc $zips $true @((Latest $v153), (Liste @((New-Release $mc "v0.99.0`n" $true $false $sig))))
Add-Cas 'préversion nom invalide (5 nombres, lettres)' $mc $zips $true @((Latest $v153), (Liste @((New-Release $mc 'v1.2.3.4.5' $true $false $sig), (New-Release $mc 'v1.2-beta' $true $false $sig), (New-Release $mc 'w1.2' $true $false $sig))))
Add-Cas 'normale illisible (1.2-beta), préversion lisible' $mc $zips $true @((Latest (New-Release $mc 'v1.2-beta' $false $false $sig)), (Liste @((New-Release $mc 'v0.1.0' $true $false $sig))))
Add-Cas 'normale avec espace, préversion plus haute' $mc $zips $true @((Latest (New-Release $mc 'v 1.5' $false $false $sig)), (Liste @((New-Release $mc 'v1.6' $true $false $sig))))
Add-Cas 'normale avec espace, préversion plus basse' $mc $zips $true @((Latest (New-Release $mc 'v 1.5' $false $false $sig)), (Liste @((New-Release $mc 'v1.4' $true $false $sig))))
Add-Cas 'liste des versions vide' $mc $zips $true @((Latest $v153), (Rep "$api/releases?per_page=30" 200 '[]'))
Add-Cas 'liste des versions : un objet seul' $mc $zips $true @((Latest $v153), (Rep "$api/releases?per_page=30" 200 (Json (New-Release $mc 'v0.97.0' $true $false $sig))))
Add-Cas 'liste des versions pas en JSON' $mc $zips $true @((Latest $v153), (Rep "$api/releases?per_page=30" 200 'oups'))

# Sans l'API (refusée : 60 questions par heure)
$atom = "<feed><entry><link rel=`"alternate`" type=`"text/html`" href=`"$gh/releases/tag/v0.90.0`"/></entry><entry><link href=`"$gh/releases/tag/liste-applis`"/></entry><entry><link href=`"$gh/releases/tag/v0.15.3`"/></entry></feed>"
$b153 = "$gh/releases/download/v0.15.3"; $b900 = "$gh/releases/download/v0.90.0"
$sansApi = @((Rep "$api/releases/latest" 403), (Rep "$api/releases?per_page=30" 403), (Rep "$gh/releases/latest" 302 '' "$gh/releases/tag/v0.15.3"),
    (Rep "$b153/Mindcare.zip" 302), (Rep "$b153/Mindcare.zip.sig" 302), (Rep "$gh/releases/tag/v0.15.3" 200 $page153), (Rep "$gh/releases.atom" 200 $atom),
    (Rep "$b900/Mindcare.zip" 302), (Rep "$b900/Mindcare.zip.sig" 200), (Rep "$gh/releases/tag/v0.90.0" 404))
Add-Cas 'sans l''API, case décochée : par la redirection' $mc $zips $false $sansApi
Add-Cas 'sans l''API, case cochée : la préversion du flux atom' $mc $zips $true $sansApi
Add-Cas 'sans l''API, préversion sans signature' $mc $zips $true @($sansApi | Where-Object { $_.url -ne "$b900/Mindcare.zip.sig" })
Add-Cas 'sans l''API, préversion sans zip : la normale' $mc $zips $true @($sansApi | Where-Object { $_.url -notlike "$b900/*" })
Add-Cas 'sans l''API, signature de la normale absente (404)' $mc $zips $false @(@($sansApi | Where-Object { $_.url -ne "$b153/Mindcare.zip.sig" }) + (Rep "$b153/Mindcare.zip.sig" 404))
Add-Cas 'sans l''API, signature en 303 (pas acceptée)' $mc $zips $false @(@($sansApi | Where-Object { $_.url -ne "$b153/Mindcare.zip.sig" }) + (Rep "$b153/Mindcare.zip.sig" 303))
Add-Cas 'sans l''API, signature en 301' $mc $zips $false @(@($sansApi | Where-Object { $_.url -ne "$b153/Mindcare.zip.sig" }) + (Rep "$b153/Mindcare.zip.sig" 301))
Add-Cas 'sans l''API, redirection sans v' $mc $zips $false @((Rep "$api/releases/latest" 429), (Rep "$gh/releases/latest" 302 '' "/$mc/releases/tag/0.16.0"), (Rep "$gh/releases/download/v0.16.0/Mindcare.zip.sig" 200), (Rep "$gh/releases/tag/v0.16.0" 200 '<p>rien</p>'))
Add-Cas 'sans l''API, redirection en majuscules' $mc $zips $false @((Rep "$api/releases/latest" 403), (Rep "$gh/releases/latest" 301 '' "HTTPS://GITHUB.COM/$mc/RELEASES/TAG/V0.17.0"))
Add-Cas 'sans l''API, redirection ailleurs que vers une version' $mc $zips $false @((Rep "$api/releases/latest" 403), (Rep "$gh/releases/latest" 302 '' "$gh/releases"))
Add-Cas 'sans l''API, pas de redirection (200)' $mc $zips $false @((Rep "$api/releases/latest" 403), (Rep "$gh/releases/latest" 200 'page'))
Add-Cas 'sans l''API, page des versions introuvable (404)' $mc $zips $false @((Rep "$api/releases/latest" 403), (Rep "$gh/releases/latest" 404))
Add-Cas 'pas de connexion du tout' $mc $zips $false @((Panne "$api/releases/latest" 'Impossible de se connecter au serveur distant'), (Panne "$gh/releases/latest" 'Impossible de se connecter au serveur distant'))
Add-Cas 'pas de connexion du tout, case cochée' $mc $zips $true @((Panne "$api/releases/latest" 'Le nom distant n''a pas pu être résolu: ''api.github.com'''), (Panne "$api/releases?per_page=30" 'Le nom distant n''a pas pu être résolu: ''api.github.com'''))
Add-Cas 'GitHub en panne (500), sans repli' $mc $zips $false @((Rep "$api/releases/latest" 500), (Rep "$gh/releases/latest" 503))
Add-Cas 'version introuvable, préversion par l''API' $mc $zips $true @((Rep "$api/releases/latest" 404), (Rep "$gh/releases/latest" 404), (Liste @((New-Release $mc 'v0.90.0' $true $false $sig))))
Add-Cas 'sans l''API, deux noms : le premier publié' $mc $deux $false @((Rep "$api/releases/latest" 403), (Rep "$gh/releases/latest" 302 '' "$gh/releases/tag/v0.18.0"), (Rep "$gh/releases/download/v0.18.0/Ancien.zip" 302), (Rep "$gh/releases/download/v0.18.0/Ancien.zip.sig" 302))
Add-Cas 'sans l''API, deux noms, aucun publié : le premier' $mc $deux $false @((Rep "$api/releases/latest" 403), (Rep "$gh/releases/latest" 302 '' "$gh/releases/tag/v0.19.0"))
$atomLong = '<feed>' + ((@('v1.0.0', 'v3.0.0', 'v2.0.0', 'v2.0.0', 'v1.5', 'v4.0.0.1', 'V9.0.0', 'v10.0.0x', 'v0.9') | ForEach-Object { "<link href=`"$gh/releases/tag/$_`"/>" }) -join '') + '</feed>'
$bases = @{ '4.0.0.1' = "$gh/releases/download/v4.0.0.1"; '3.0.0' = "$gh/releases/download/v3.0.0"; '2.0.0' = "$gh/releases/download/v2.0.0"; '1.5' = "$gh/releases/download/v1.5" }
Add-Cas 'flux atom : les 3 plus hautes, la plus haute qui a son zip' $mc $zips $true @((Rep "$api/releases/latest" 403), (Rep "$api/releases?per_page=30" 403), (Rep "$gh/releases/latest" 404), (Rep "$gh/releases.atom" 200 $atomLong),
    (Rep "$($bases['2.0.0'])/Mindcare.zip" 302), (Rep "$gh/releases/tag/v2.0.0" 200 '<div class="markdown-body">Deux</div>'))
Add-Cas 'flux atom : rien dans les 3 plus hautes' $mc $zips $true @((Rep "$api/releases/latest" 403), (Rep "$api/releases?per_page=30" 403), (Rep "$gh/releases/latest" 404), (Rep "$gh/releases.atom" 200 $atomLong), (Rep "$($bases['1.5'])/Mindcare.zip" 302))
Add-Cas 'flux atom introuvable' $mc $zips $true @((Rep "$api/releases/latest" 403), (Rep "$api/releases?per_page=30" 403), (Rep "$gh/releases/latest" 302 '' "$gh/releases/tag/v0.15.3"), (Rep "$b153/Mindcare.zip.sig" 302), (Rep "$gh/releases.atom" 404))
Add-Cas 'Mindset lui-même' 'JordanJacquot/Mindset' @('Mindset.zip') $false @((Rep 'https://api.github.com/repos/JordanJacquot/Mindset/releases/latest' 200 (Json (New-Release 'JordanJacquot/Mindset' 'v3.0.0' $false $false @('Mindset.zip', 'Mindset.zip.sig') 'Mindset en Rust'))))
Add-Cas 'dépôt avec accent' 'JordanJacquot/Forêt' @('Forêt.zip') $false @((Rep 'https://api.github.com/repos/JordanJacquot/Forêt/releases/latest' 200 (Json (New-Release 'JordanJacquot/Forêt' 'v1.0.0' $false $false @('Forêt.zip', 'Forêt.zip.sig')))))
Add-Cas 'noms vides retirés' $mc @('', 'Mindcare.zip', '') $false @((Latest $v153))

# Cas tirés au hasard (graine fixe) : des versions publiées mélangées, case cochée ou non
$hasard = New-Object Random 20261107
for ($n = 0; $n -lt 40; $n++) {
    $rels = @(for ($i = 0; $i -lt $hasard.Next(0, 7); $i++) {
        $tag = 'v{0}.{1}.{2}' -f $hasard.Next(0, 3), $hasard.Next(0, 4), $hasard.Next(0, 3)
        if ($hasard.Next(0, 8) -eq 0) { $tag = 'liste-applis' }
        $f = switch ($hasard.Next(0, 5)) { 0 { @('Mindcare.zip') } 1 { @('Autre.zip', 'Autre.zip.sig') } default { $sig } }
        New-Release $mc $tag ($hasard.Next(0, 3) -ne 0) ($hasard.Next(0, 6) -eq 0) $f
    })
    $normale = New-Release $mc ('v{0}.{1}.{2}' -f $hasard.Next(0, 3), $hasard.Next(0, 4), $hasard.Next(0, 3)) $false $false $sig
    $g = @()
    switch ($hasard.Next(0, 4)) { 0 { $g += Rep "$api/releases/latest" 404 } 1 { $g += Rep "$api/releases/latest" 403 } default { $g += Latest $normale } }
    if ($hasard.Next(0, 4) -eq 0) { $g += Rep "$api/releases?per_page=30" 403 } else { $g += Liste $rels }
    $g += Rep "$gh/releases/latest" 404
    $g += Rep "$gh/releases.atom" 404
    Add-Cas "hasard $n" $mc $zips ($hasard.Next(0, 3) -ne 0) $g
}
[IO.File]::WriteAllText((Join-Path $sortie 'publications.json'), (ConvertTo-Json -InputObject @($cas) -Depth 10), (New-Object Text.UTF8Encoding $false))

# ---------------------------------------------------------------------------------------------------------------
# notes.json : Get-NotesPage
# ---------------------------------------------------------------------------------------------------------------
$notes = New-Object Collections.ArrayList
function Add-Notes([string]$Nom, [object[]]$Github, [string]$Version = '1.2.3') {
    Set-Github $Github
    $r = Get-NotesPage $mc $Version
    [void]$notes.Add([ordered]@{ nom = $Nom; depot = $mc; version = $Version; github = @($Github); notes = $r; demandes = @($global:Demandes) })
}
$p = "$gh/releases/tag/v1.2.3"
Add-Notes 'page simple' @((Rep $p 200 $page153))
Add-Notes 'page introuvable : le lien' @((Rep $p 404))
Add-Notes 'pas de connexion : le lien' @((Panne $p 'Impossible de se connecter au serveur distant'))
Add-Notes 'pas de markdown-body : le lien' @((Rep $p 200 '<html><p>bonjour</p></html>'))
Add-Notes 'markdown-body vide : le lien' @((Rep $p 200 '<div class="markdown-body"></div>'))
Add-Notes 'markdown-body d''espaces : le lien' @((Rep $p 200 "<div class=`"markdown-body`">  `n  &nbsp; </div>"))
Add-Notes 'titres, br, li, entités' @((Rep $p 200 "<div data-x=`"1`" class=`"markdown-body markdown-x`" id=`"a`"><h2>Nouveautés</h2><p>Ligne 1<br>Ligne 2<BR/>Ligne 3<br />fin</p><ul>`n<li class=`"x`">Café &eacute;t&eacute; &#233; &#xE9; &lt;b&gt;</li>`n<LI>Forêt &quot;verte&quot; &#39;ok&#39; &apos;</LI></ul><H3>Fin</H3></div><div>autre</div>"))
Add-Notes 'majuscules dans la balise' @((Rep $p 200 '<DIV CLASS="MARKDOWN-BODY">Gros <B>texte</B></DIV>'))
Add-Notes 'lignes vides en trop et espaces' @((Rep $p 200 "<div class=`"markdown-body`"><p>a   </p><p></p><p></p><p>b</p>`r`n`r`n`r`n`r`n<p>c `t </p></div>"))
Add-Notes 'div imbriquée : coupée à la première fin' @((Rep $p 200 '<div class="markdown-body"><div>dedans</div>apres</div>'))
Add-Notes 'balise cassée' @((Rep $p 200 '<div class="markdown-body">a < b et c > d <i>e</div>'))
Add-Notes 'entités inconnues et incomplètes' @((Rep $p 200 '<div class="markdown-body">&inconnu; &amp &am&amp; &#; &#x; &#0; &#65536; &#x41;&#X42;&# 67; &#+68; &AMP; &Eacute;&eacute;&nbsp;fin</div>'))
Add-Notes 'emoji' @((Rep $p 200 '<div class="markdown-body">Fusée 🚀 et &#x2022; puce</div>'))
Add-Notes 'trop long : coupé à 4000' @((Rep $p 200 ('<div class="markdown-body"><p>' + ('é' * 3990) + ' ' + ('x' * 50) + '</p></div>')))
Add-Notes 'exactement 4000' @((Rep $p 200 ('<div class="markdown-body">' + ('a' * 4000) + '</div>')))
Add-Notes 'markdown-body sans guillemet fermant' @((Rep $p 200 '<div class=markdown-body>rien</div>'))
Add-Notes 'version à 2 nombres' @((Rep "$gh/releases/tag/v4.5" 200 '<div class="markdown-body">quatre</div>')) '4.5'
Add-Notes 'retours Windows dans les notes' @((Rep $p 200 "<div class=`"markdown-body`">un`r`ndeux  `r`n`r`n`r`n`r`ntrois</div>"))
[IO.File]::WriteAllText((Join-Path $sortie 'notes.json'), (ConvertTo-Json -InputObject @($notes) -Depth 10), (New-Object Text.UTF8Encoding $false))

# ---------------------------------------------------------------------------------------------------------------
# html.json : HtmlDecode et sa table des noms
# ---------------------------------------------------------------------------------------------------------------
$t = [System.Net.WebUtility].Assembly.GetType('System.Net.WebUtility+HtmlEntities')
$liste = $t.GetField('_entitiesList', [Reflection.BindingFlags]'NonPublic,Static').GetValue($null)
$entites = @(foreach ($e in $liste) { $i = $e.IndexOf('-'); [ordered]@{ nom = $e.Substring($i + 1); code = [int][char]$e[0] } })
$decode = @(foreach ($s in '', 'rien', '&', '&&', '&;', '&amp;', '&amp', '&amp;amp;', '&lt;&gt;&quot;&apos;', '&AMP;', '&Aacute;&aacute;', '&#65;', '&#x41;',
        '&#X41;', '&#x;', '&#;', '&#0;', '&#-0;', '&#+65;', '&# 65;', '&#65 ;', '&#	65;', '&#x 41;', '&#65536;', '&#xFFFF;', '&#x10000;',
        '&#4294967295;', '&#4294967296;', '&#00065;', '&#x0041;', '&#xg;', '&#1e2;', '&nbsp;&copy;&euro;&hearts;&zwj;', '&a&amp;', 'a&b;c', 'x &amp y &lt; z',
        '&#x2022;&#8230;', '&#xDFFF;x', '&#x1F600;', '&#128512;', '&thetasym;&upsih;&piv;', '&;&amp;;', '&é;', '&eacute', '&#١٢;', '&#x٤١;') {
    [ordered]@{ entree = $s; sortie = [Net.WebUtility]::HtmlDecode($s) }
})
# (les sorties qui ne sont pas de l'Unicode valide, comme une moitié de caractère, sont retirées : voir DIVERGENCES.md)
$decode = @($decode | Where-Object { -not ($_.sortie -match '[\uD800-\uDFFF]' -and $_.sortie -notmatch '[\uD800-\uDBFF][\uDC00-\uDFFF]') })
[IO.File]::WriteAllText((Join-Path $sortie 'html.json'), (ConvertTo-Json -InputObject ([ordered]@{ entites = $entites; decode = $decode }) -Depth 6), (New-Object Text.UTF8Encoding $false))

# ---------------------------------------------------------------------------------------------------------------
# adresses.json : Test-AdresseTelechargement
# ---------------------------------------------------------------------------------------------------------------
$adresses = @(foreach ($u in 'https://github.com/a/b.zip', 'https://objects.githubusercontent.com/x', 'https://release-assets.githubusercontent.com/y?z=1',
        'http://github.com/a/b.zip', 'https://exemple.com/b.zip', 'https://github.com.exemple.com/b.zip', 'https://github.com@exemple.com/b.zip',
        'https://exemple.com/https://github.com/b.zip', 'file:///C:/Windows/win.ini', '', 'https://github.com', 'https://github.com/',
        'HTTPS://GITHUB.COM/A', 'https://GitHub.Com/x', 'https://api.github.com/repos/a/b', 'https://gİthub.com/x', 'https://github.com:443/x',
        ' https://github.com/x', "https://github.com/`n", 'https://githubXcom/x', 'https://objects.githubusercontent.com.evil/x',
        'https://raw.githubusercontent.com/x', 'https://release-assets.githubusercontent.com/', 'https://github.com\x', 'https://objects-githubusercontent.com/x',
        'https://OBJECTS.GİTHUBUSERCONTENT.COM/x', 'https://github.ćom/x', 'https://ｇithub.com/x', "https://github.com/$('é' * 300)") {
    [ordered]@{ adresse = $u; acceptee = [bool](Test-AdresseTelechargement $u) }
})
[IO.File]::WriteAllText((Join-Path $sortie 'adresses.json'), (ConvertTo-Json -InputObject $adresses -Depth 4), (New-Object Text.UTF8Encoding $false))

# ---------------------------------------------------------------------------------------------------------------
# versions.json : Test-VersionPlusRecente et [version]
# ---------------------------------------------------------------------------------------------------------------
$textes = @('1.2', '1.2.0', '1.2.0.0', '1.10', '1.9.9', '0.90.1', '0.15.3', ' 1.2', '1.2 ', "1.2`n", '+1.2', '1.+2', '-0.1', '1.-2', '01.2', '1.2.3.4.5',
    '1,2', '', 'abc', '1', '1.', '.1', '1..2', '2147483647.0', '2147483648.0', '1.2.3.4', '١.٢', '1 .2', "1.2`t", '0.0', '3.0.0', '2.18.0')
$lectures = @(foreach ($s in $textes) { $v = $null; try { $v = ([version]$s).ToString() } catch {}; [ordered]@{ texte = $s; version = $v } })
$comparaisons = @(foreach ($a in $textes) { foreach ($b in '1.2', '1.2.0', ' 1.2', '0.90.1', '2.18.0', '', 'abc', '1.10', '3.0.0') {
    [ordered]@{ a = $a; b = $b; plus_recente = [bool](Test-VersionPlusRecente $a $b) } } })
[IO.File]::WriteAllText((Join-Path $sortie 'versions.json'), (ConvertTo-Json -InputObject ([ordered]@{ lectures = $lectures; comparaisons = $comparaisons }) -Depth 4), (New-Object Text.UTF8Encoding $false))

# ---------------------------------------------------------------------------------------------------------------
# scenarios.json : la recherche des nouvelles versions, pas à pas
# ---------------------------------------------------------------------------------------------------------------
$depart = [datetime]'2026-11-07T20:00:00'
function Get-Date { $script:Maintenant }
function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.ContainsKey($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur }
function Write-Log([string]$Texte) { $script:Journal.Add($Texte) }
function Start-VerifMajMindset { $script:Appels.Add('Start-VerifMajMindset') }
function Update-ListeEnLigne { $script:Appels.Add('Update-ListeEnLigne') }
function Update-Cartes { $script:Cartes++ }
function Update-ListeVersions { }
function Start-Tache([scriptblock]$Travail, [hashtable]$Parametres, [scriptblock]$Fin) {
    [void]$script:EnAttente.Add(@{ Parametres = $Parametres; Fin = $Fin })
    [void]$script:Lancees.Add([ordered]@{ depot = $Parametres.Depot; zip = @($Parametres.Zip); essai = [bool]$Parametres.Essai })
}
$EnTest = $false
$ui = @{ ActualiserInfo = [pscustomobject]@{ Text = '' } }
$Window = [pscustomobject]@{ IsVisible = $false; ShowInTaskbar = $false; WindowState = 'Normal' }
$Window | Add-Member ScriptMethod Show { $this.IsVisible = $true }
$Window | Add-Member ScriptMethod Activate { $true }

$applisEssai = @(
    [ordered]@{ id = 'nevermind'; nom = 'Nevermind'; depot = 'JordanJacquot/Nevermind'; zip = 'Nevermind.zip'; ancien_zip = 'OptiGame.zip' },
    [ordered]@{ id = 'evermind'; nom = 'Evermind'; depot = 'JordanJacquot/Evermind'; zip = 'Evermind.zip'; ancien_zip = '' },
    [ordered]@{ id = 'mindcare'; nom = 'Mindcare'; depot = 'JordanJacquot/Mindcare'; zip = 'Mindcare.zip'; ancien_zip = '' }
)
function ConvertTo-Table($o) {
    if ($null -eq $o) { return $null }
    $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }; $h
}
$scenarios = New-Object Collections.ArrayList
function Add-Scenario([string]$Nom, [hashtable]$Reglages, [bool]$Bienvenue, [object[]]$Pas) {
    $script:Reglages = @{}; foreach ($k in $Reglages.Keys) { $script:Reglages[$k] = $Reglages[$k] }
    $script:Maintenant = $depart
    $script:Journal = New-Object Collections.Generic.List[string]
    $script:Appels = New-Object Collections.Generic.List[string]
    $script:EnAttente = New-Object Collections.ArrayList
    $script:Publications = @{}; $script:Recherches = @{}
    $script:DernieresPublications = [datetime]::MinValue; $script:VerifieA = $null; $script:RechercheDepuis = [datetime]::MinValue
    $script:AttenteBienvenue = $Bienvenue; $script:OngletParametres = ''
    $script:Actions = New-Object System.Collections.Specialized.OrderedDictionary
    $script:Applis = @(foreach ($a in $applisEssai) { [pscustomobject]@{ Id = $a.id; Nom = $a.nom; Depot = $a.depot; Zip = $a.zip; AncienZip = $a.ancien_zip } })
    $ui.ActualiserInfo.Text = ''
    $Window.IsVisible = $false
    $sorties = New-Object Collections.ArrayList
    foreach ($p in $Pas) {
        $script:Lancees = New-Object Collections.ArrayList; $script:Cartes = 0
        $j0 = $script:Journal.Count; $script:Appels.Clear()
        switch ($p.pas) {
            'demarrage' { Update-InfoActualiser; Invoke-Actualiser }
            'clic' { Invoke-Actualiser -Clic }
            'auto' { Invoke-Actualiser }
            'minuterie' { & $minuterie }
            'fenetre' { $Window.IsVisible = [bool]$p.avant; Show-Fenetre }
            'avancer' { $script:Maintenant = $script:Maintenant.AddSeconds([double]$p.secondes) }
            'reglage' { Set-Setting $p.nom $p.valeur; if (Get-Command Update-InfoActualiser -ErrorAction SilentlyContinue) { Update-InfoActualiser } }
            'bienvenue' { $script:AttenteBienvenue = [bool]$p.oui }
            'essai' { Set-VersionsEssaiAppli $p.id ([bool]$p.oui) }
            'reponse' {
                $depot = ($script:Applis | Where-Object { $_.Id -eq $p.id }).Depot
                $t = @($script:EnAttente | Where-Object { $_.Parametres.Depot -eq $depot }) | Select-Object -First 1
                if (-not $t) { throw "$Nom : aucune question en attente pour $($p.id)" }
                $script:EnAttente.Remove($t)
                $res = $null; if ($p.Contains('resultat')) { $res = @{}; foreach ($k in $p.resultat.Keys) { $res[$k] = $p.resultat[$k] } }
                $err = if ($p.Contains('erreur')) { [string]$p.erreur } else { $null }
                & $t.Fin $res $err
            }
            default { throw "pas inconnu : $($p.pas)" }
        }
        $pubs = [ordered]@{}
        foreach ($k in @($script:Publications.Keys | Sort-Object)) { $pubs[$k] = ConvertTo-Sortie $script:Publications[$k] }
        [void]$sorties.Add([ordered]@{
            taches = @($script:Lancees); appels = @($script:Appels); journal = @($script:Journal | Select-Object -Skip $j0)
            info = $ui.ActualiserInfo.Text
            dernieres = $(if ($script:DernieresPublications -eq [datetime]::MinValue) { $null } else { $script:DernieresPublications.ToString('s') })
            verifie_a = $(if ($script:VerifieA) { $script:VerifieA.ToString('HH:mm') } else { $null })
            publications = $pubs; recherches = @($script:Recherches.Keys | Sort-Object); cartes = $script:Cartes
            versions_essai = $(if ($script:Reglages.ContainsKey('VersionsEssai')) { , $script:Reglages['VersionsEssai'] } else { 'absent' })
            visible = [bool]$Window.IsVisible
        })
    }
    [void]$scenarios.Add([ordered]@{ nom = $Nom; reglages = $Reglages; bienvenue = $Bienvenue; applis = $applisEssai; pas = @($Pas); sorties = @($sorties) })
}
function P([string]$Pas, [hashtable]$Valeurs = @{}) { $o = [ordered]@{ pas = $Pas }; foreach ($k in $Valeurs.Keys) { $o[$k] = $Valeurs[$k] }; $o }
$pubMc = [ordered]@{ Version = '0.15.3'; Fichier = 'Mindcare.zip'; UrlZip = 'https://github.com/JordanJacquot/Mindcare/releases/download/v0.15.3/Mindcare.zip'; UrlSig = 'https://github.com/JordanJacquot/Mindcare/releases/download/v0.15.3/Mindcare.zip.sig'; Notes = 'notes' }
$pubNv = [ordered]@{ Version = '1.4.0'; Fichier = 'Nevermind.zip'; UrlZip = 'https://github.com/JordanJacquot/Nevermind/releases/download/v1.4.0/Nevermind.zip'; UrlSig = $null; Notes = ''; Essai = $true }
$e429 = [ordered]@{ Erreur = 'Impossible de joindre GitHub (Le serveur distant a retourné une erreur : (429) Too Many Requests.).' }

Add-Scenario 'démarrage, réponses, limite de GitHub, minuterie' @{} $false @(
    (P 'demarrage'), (P 'reponse' @{ id = 'mindcare'; resultat = $pubMc }), (P 'reponse' @{ id = 'evermind'; erreur = 'Le serveur distant a retourné une erreur : (403) Interdit.' }),
    (P 'avancer' @{ secondes = 30 }), (P 'reponse' @{ id = 'nevermind'; resultat = $e429 }), (P 'avancer' @{ secondes = 600 }), (P 'minuterie'),
    (P 'avancer' @{ secondes = 1170 }), (P 'minuterie'), (P 'avancer' @{ secondes = 1 }), (P 'minuterie'), (P 'avancer' @{ secondes = 30 }), (P 'minuterie'), (P 'minuterie'))
Add-Scenario 'recherche coupée : seulement au clic' @{ VerifVersions = $false } $false @(
    (P 'demarrage'), (P 'minuterie'), (P 'avancer' @{ secondes = 7200 }), (P 'minuterie'), (P 'auto'), (P 'clic'), (P 'avancer' @{ secondes = 5 }), (P 'clic'),
    (P 'avancer' @{ secondes = 15 }), (P 'clic'), (P 'reglage' @{ nom = 'VerifVersions'; valeur = $true }), (P 'avancer' @{ secondes = 3600 }), (P 'minuterie'))
Add-Scenario 'recherche coupée en route' @{} $false @((P 'demarrage'), (P 'reglage' @{ nom = 'VerifVersions'; valeur = $false }), (P 'avancer' @{ secondes = 4000 }), (P 'minuterie'), (P 'clic'))
Add-Scenario 'réglage VerifVersions en texte ou nombre' @{ VerifVersions = 0 } $false @((P 'demarrage'), (P 'reglage' @{ nom = 'VerifVersions'; valeur = 'non' }), (P 'avancer' @{ secondes = 3600 }), (P 'minuterie'), (P 'reglage' @{ nom = 'VerifVersions'; valeur = '' }), (P 'minuterie'))
Add-Scenario 'bandeau d''installation : rien tout seul, le clic oui' @{} $true @(
    (P 'demarrage'), (P 'avancer' @{ secondes = 4000 }), (P 'minuterie'), (P 'fenetre' @{ avant = $false }), (P 'clic'), (P 'bienvenue' @{ oui = $false }),
    (P 'avancer' @{ secondes = 3599 }), (P 'minuterie'), (P 'avancer' @{ secondes = 1 }), (P 'minuterie'))
Add-Scenario 'rouvert depuis l''horloge après 15 minutes' @{} $false @(
    (P 'demarrage'), (P 'avancer' @{ secondes = 600 }), (P 'fenetre' @{ avant = $false }), (P 'avancer' @{ secondes = 299 }), (P 'fenetre' @{ avant = $true }),
    (P 'avancer' @{ secondes = 1 }), (P 'fenetre' @{ avant = $true }), (P 'fenetre' @{ avant = $false }), (P 'fenetre' @{ avant = $false }),
    (P 'avancer' @{ secondes = 900 }), (P 'reglage' @{ nom = 'VerifVersions'; valeur = $false }), (P 'fenetre' @{ avant = $false }))
Add-Scenario 'clics répétés : 20 secondes' @{} $false @(
    (P 'demarrage'), (P 'avancer' @{ secondes = 10 }), (P 'clic'), (P 'avancer' @{ secondes = 9 }), (P 'clic'), (P 'avancer' @{ secondes = 1 }), (P 'clic'),
    (P 'auto'), (P 'avancer' @{ secondes = 19 }), (P 'clic'))
Add-Scenario 'versions d''essai : cocher, décocher, casse, inconnue' @{} $false @(
    (P 'demarrage'), (P 'reponse' @{ id = 'mindcare'; resultat = $pubMc }), (P 'reponse' @{ id = 'nevermind'; resultat = $pubNv }),
    (P 'essai' @{ id = 'mindcare'; oui = $true }), (P 'essai' @{ id = 'mindcare'; oui = $true }), (P 'minuterie'), (P 'reponse' @{ id = 'mindcare'; resultat = $pubMc }),
    (P 'essai' @{ id = 'appli-inconnue'; oui = $true }), (P 'essai' @{ id = 'MINDCARE'; oui = $false }), (P 'essai' @{ id = 'NEVERMIND'; oui = $true }),
    (P 'essai' @{ id = 'evermind'; oui = $false }), (P 'essai' @{ id = 'mindcare'; oui = $false }), (P 'avancer' @{ secondes = 1 }), (P 'clic'))
Add-Scenario 'versions d''essai : réglage en texte seul' @{ VersionsEssai = 'mindcare' } $false @((P 'demarrage'), (P 'essai' @{ id = 'evermind'; oui = $true }), (P 'essai' @{ id = 'mindcare'; oui = $false }))
Add-Scenario 'versions d''essai : réglage avec null et nombre' @{ VersionsEssai = @($null, 5, 'evermind') } $false @((P 'demarrage'), (P 'essai' @{ id = 'mindcare'; oui = $true }), (P 'essai' @{ id = 'evermind'; oui = $false }))
Add-Scenario 'versions d''essai : réglage vide' @{ VersionsEssai = @() } $false @((P 'essai' @{ id = 'nevermind'; oui = $true }), (P 'demarrage'))
Add-Scenario 'réponse après la case changée' @{} $false @((P 'demarrage'), (P 'essai' @{ id = 'evermind'; oui = $true }), (P 'reponse' @{ id = 'evermind'; resultat = $pubMc }), (P 'minuterie'), (P 'reponse' @{ id = 'evermind'; erreur = 'boum (403)' }))
Add-Scenario 'deux recherches en route' @{} $false @((P 'demarrage'), (P 'avancer' @{ secondes = 30 }), (P 'clic'), (P 'reponse' @{ id = 'mindcare'; resultat = $pubMc }), (P 'reponse' @{ id = 'mindcare'; resultat = $e429 }))
Add-Scenario 'démarrage caché puis montré' @{} $false @((P 'demarrage'), (P 'avancer' @{ secondes = 901 }), (P 'fenetre' @{ avant = $false }), (P 'avancer' @{ secondes = 2 }), (P 'fenetre' @{ avant = $false }))
[IO.File]::WriteAllText((Join-Path $sortie 'scenarios.json'), (ConvertTo-Json -InputObject @($scenarios) -Depth 12), (New-Object Text.UTF8Encoding $false))

Remove-Item function:global:New-Object, function:global:Invoke-RestMethod, function:global:Invoke-FauxGithub, function:global:New-FausseRequete, function:global:Get-MessageHttp -ErrorAction SilentlyContinue
Write-Host "Juges écrits dans $sortie : $($cas.Count) publications, $($notes.Count) notes, $($decode.Count) décodages, $($adresses.Count) adresses, $($comparaisons.Count) comparaisons, $($scenarios.Count) scénarios"
