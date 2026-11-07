# Mindset : juges du bloc Rust « console 3D » (rust\mindset-console).
#
#   & '.\outils\exporter-juges-console.ps1'          (depuis l'outil PowerShell, jamais lancé depuis Bash)
#
# Les VRAIES fonctions de la version PowerShell (prises dans le texte des modules, rien d'autre n'est exécuté) :
#   console.ps1 : Get-EtatConsole, Get-LogoConsole, Get-EtatMajConsole, Get-CouleursConsole, Get-ThemeConsole,
#                 Test-ImageAnimee, Get-AvanceeOuverture, Get-ReactionIncidentConsole, Receive-IncidentConsole,
#                 Stop-Console, Resume-ConsoleArretee, Remove-VueConsole, Update-PageConsole, Receive-MessageConsole,
#                 Set-MajAutoConsole, Stop-AppliConsole ;
#   et autour : Get-EtatCarte, Get-PhraseReseauAppli, Get-LienReseauAppli, Get-Appli (accueil.ps1),
#                 Get-MajAutoReessai, Test-MajAutoRecente, Get-NomRaisonJeu, Format-QuandMaj, Get-AppliMaj,
#                 Get-DerniereMaj, Test-VerifVersionsActive, Test-MajAutoActive (mindset.ps1), Test-VersionPlusRecente
#                 (paquets.ps1), ConvertTo-Hsl, ConvertFrom-Hsl, ConvertTo-ThemeHex et $AppThemes (themes.ps1),
#                 Get-ThemePack, Test-NomFichierPack, Test-CouleursPack, Get-FormatImagePack (packs.ps1),
#                 Start-AppliCachee (integration.ps1).
# Ce qui toucherait au PC (lancer, fermer, installer, la fenêtre, WebView2) est remplacé par des faux qui notent ce qui
# est demandé. Les entrées sont écrites dans le vocabulaire du tableau commun de la version Rust (mindset_noyau::partage)
# et traduites ici en variables $script: ; les tests Rust (rust\mindset-console\tests\juges.rs) rejouent chaque cas.
#
# Sortie : rust\mindset-console\tests\juges\*.json. Tout se passe sous %TEMP% (supprimé à la fin) : rien n'est lu ni
# écrit ailleurs, aucune fenêtre, aucun réseau.

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$modules = Join-Path $racine 'Mindset\fichiers\modules'
$ConsoleDir = Join-Path $racine 'Mindset\fichiers\console'
$sortie = Join-Path $racine 'rust\mindset-console\tests\juges'
New-Item -ItemType Directory -Force -Path $sortie | Out-Null
$tmp = Join-Path $env:TEMP "mindset-juges-console-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# ---------------------------------------------------------------------------------------------------------------
# Les vraies fonctions, prises dans leur fichier
# ---------------------------------------------------------------------------------------------------------------
$asts = @{}
function Get-AstModule([string]$Nom) {
    if (-not $asts[$Nom]) {
        $e = $null
        $asts[$Nom] = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $modules $Nom), [ref]$null, [ref]$e)
        if ($e) { throw "$Nom illisible : $($e[0].Message)" }
    }
    $asts[$Nom]
}
$textes = New-Object Collections.Generic.List[string]
function Add-Fonctions([string]$Fichier, [string[]]$Noms) {
    $ast = Get-AstModule $Fichier
    foreach ($n in $Noms) {
        $f = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true)
        if (-not $f) { throw "Fonction $n introuvable dans $Fichier" }
        $textes.Add($f.Extent.Text)
    }
}
Add-Fonctions 'console.ps1' @('Get-EtatConsole', 'Get-LogoConsole', 'Get-EtatMajConsole', 'Get-CouleursConsole', 'Get-ThemeConsole',
    'Test-ImageAnimee', 'Get-AvanceeOuverture', 'Get-ReactionIncidentConsole', 'Receive-IncidentConsole', 'Stop-Console',
    'Resume-ConsoleArretee', 'Remove-VueConsole', 'Update-PageConsole', 'Receive-MessageConsole', 'Set-MajAutoConsole', 'Stop-AppliConsole')
Add-Fonctions 'accueil.ps1' @('Get-EtatCarte', 'Get-PhraseReseauAppli', 'Get-LienReseauAppli', 'Get-Appli')
Add-Fonctions 'mindset.ps1' @('Get-MajAutoReessai', 'Test-MajAutoRecente', 'Get-NomRaisonJeu', 'Format-QuandMaj', 'Get-AppliMaj',
    'Get-DerniereMaj', 'Test-VerifVersionsActive', 'Test-MajAutoActive')
Add-Fonctions 'paquets.ps1' @('Test-VersionPlusRecente')
Add-Fonctions 'themes.ps1' @('ConvertTo-Hsl', 'ConvertFrom-Hsl', 'ConvertTo-ThemeHex')
Add-Fonctions 'packs.ps1' @('Get-ThemePack', 'Test-NomFichierPack', 'Test-CouleursPack', 'Get-FormatImagePack')
Add-Fonctions 'integration.ps1' @('Start-AppliCachee')
foreach ($t in $textes) { . ([scriptblock]::Create($t)) }

$affectation = (Get-AstModule 'themes.ps1').Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$AppThemes' }, $false)
if (-not $affectation) { throw '$AppThemes introuvable dans themes.ps1' }
$nouveauxThemes = [scriptblock]::Create($affectation.Right.Extent.Text)
$durees = (Get-AstModule 'chargement.ps1').Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$script:JaugeDureesDefaut' }, $false)
$script:JaugeDureesDefaut = & ([scriptblock]::Create($durees.Right.Extent.Text))
$OngletsParametres = [ordered]@{ general = 'Général'; apparence = 'Apparence'; son = 'Son'; maj = 'Mises à jour'; conso = 'Consommation'; dossiers = 'Dossiers' }
$DureeDerniereMaj = 12
$EnTest = $true

# ---------------------------------------------------------------------------------------------------------------
# Les faux (ce qui toucherait au PC), et le monde d'un cas
# ---------------------------------------------------------------------------------------------------------------
$script:Maintenant = [datetime]'2026-11-07T20:00:00'
function Get-Date { if ($args.Count) { Microsoft.PowerShell.Utility\Get-Date @args } else { $script:Maintenant } }
$script:Journal = New-Object Collections.Generic.List[string]
$script:Appels = New-Object Collections.Generic.List[string]
function Write-Log([string]$Texte) { $script:Journal.Add($Texte) }
function Get-Setting([string]$Nom, $Defaut = $null) { if ($script:Reglages.Contains($Nom)) { $script:Reglages[$Nom] } else { $Defaut } }
function Set-Setting([string]$Nom, $Valeur) { $script:Reglages[$Nom] = $Valeur; $script:Appels.Add("reglage:$Nom=$Valeur") }
function Get-Installation($Appli) { $script:Installations[$Appli.Id] }
function Test-AppliOuverte($Appli) { [bool]$script:Ouvertes[$Appli.Id] }
function Get-EtatAppli($Appli) { $null }
function Test-TacheInstallation { $script:Tache -eq 'systeme' }
function Read-HistoriqueMaj { @{ Liste = @($script:Historique) } }
function Invoke-ScriptConsole([string]$Code) { if (-not $script:Console.Vue -or -not $script:Console.Pret) { return }; $script:Appels.Add("script:$Code") }
function Send-EtatConsole([switch]$Force) { }
function Send-MajConsole([switch]$Force) { }
function Send-ParametresConsole([switch]$Force) { }
function Update-ReglagesMaj { $script:Appels.Add('reglages-maj') }
function Open-AppliIci([string]$Id) { $script:Appels.Add("ouvrir-ici:$Id") }
function Open-Appli($Appli, [switch]$Demarrage) { $script:Appels.Add("lancer:$($Appli.Id):$(if ($Demarrage) { 'cache' } else { 'normal' })") }
function Confirm-PriseEnCharge($Appli) { $script:Appels.Add("prendre:$($Appli.Id)") }
function Start-InstallAppli($Appli) { $script:Appels.Add("installer:$($Appli.Id)") }
function Confirm-MiseAJour($Appli) { $script:Appels.Add("maj:$($Appli.Id)") }
function Confirm-MajMindsetConsole { $script:Appels.Add('maj-mindset') }
function Open-PageConfidentialite([string]$Id) { $script:Appels.Add("confidentialite:$Id") }
function Write-DemandeQuitter($Appli) { $script:Appels.Add("demande-quitter:$($Appli.Id)") }
function Show-Page([string]$Id) { $script:Appels.Add("page:$Id$(if ($Id -eq 'parametres') { "@$script:OngletParametres" })") }
function Show-OngletParametres([string]$Id) { $script:OngletParametres = $Id }
function Invoke-Actualiser([switch]$Clic) { $script:Appels.Add('actualiser'); if ($script:ActualiserChange) { $script:DernieresPublications = $script:DernieresPublications.AddMinutes(1) } }
function Hide-Fenetre { $script:Appels.Add('veille') }
function Invoke-ReglageConsole($M) { $script:Appels.Add("reglage-console:$([string]$M.quoi)") }
function New-VueConsole([string]$VueDepart = 'menu') { if ($script:Console.Vue -or -not $script:Console.Possible) { return }; $script:Appels.Add("vue:$VueDepart"); $script:Console.Vue = 'vue'; $script:Console.Pret = $false }
function Set-NavigationConsole { }
function Get-EtatParametres { '{}' }
function Get-ImagesThemesConsole { '{}' }
function Start-CaptureConsole { }
# (la version Rust : seulement le réglage ; WebView2 et ses fichiers n'ont plus lieu, DIVERGENCES.md)
function Test-ConsolePossible { if ([string](Get-Setting 'Animations' 'completes') -eq 'aucune') { 'réglage Animations : aucune' } else { $null } }
class MSIntegration { static [System.Collections.Generic.List[string]]$Fermees = (New-Object 'System.Collections.Generic.List[string]'); static [void] Fermer([IntPtr]$H) { [MSIntegration]::Fermees.Add([string]$H.ToInt64()) } }
$script:ConsoleTimer = [pscustomobject]@{ Lancee = 0 } | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Lancee++ } -PassThru
$script:ConsoleAttenteTimer = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Start -Value { $script:Appels.Add('attente') } -PassThru
$Dispatcher = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name BeginInvoke -Value { param($Action) $Action.Invoke() } -PassThru
$Window = [pscustomobject]@{ Dispatcher = $Dispatcher; IsVisible = $true; WindowState = 'Normal' }
function New-Zone { [pscustomobject]@{ Visibility = 'Collapsed'; Children = (New-Object Collections.ArrayList) } }

# Le monde d'un cas, écrit comme le tableau commun de la version Rust
function ConvertTo-Table($Objet) { $h = [ordered]@{}; if ($Objet) { foreach ($p in $Objet.PSObject.Properties) { $h[$p.Name] = $p.Value } }; $h }
function Set-Monde($M, [string]$Dossier) {
    $script:Journal.Clear(); $script:Appels.Clear(); [MSIntegration]::Fermees.Clear()
    $script:Maintenant = [datetime]::ParseExact($(if ($M.maintenant) { $M.maintenant } else { '2026-11-07T20:00:00' }), 's', [Globalization.CultureInfo]::InvariantCulture)
    $script:AppVersion = $(if ($M.version) { [string]$M.version } else { '3.0.0' }); Set-Variable -Name AppVersion -Value $script:AppVersion -Scope Script
    $script:MindsetAdmin = [bool]$M.admin; Set-Variable -Name MindsetAdmin -Value ([bool]$M.admin) -Scope Script
    $script:Reglages = ConvertTo-Table $M.reglages
    $script:LogosAppliDir = Join-Path $Dossier 'Donnees\console-logos'; Set-Variable -Name LogosAppliDir -Value $script:LogosAppliDir -Scope Script
    $script:PacksDir = Join-Path $Dossier 'Donnees\packs'; Set-Variable -Name PacksDir -Value $script:PacksDir -Scope Script
    # Le thème (le haut de themes.ps1, recopié)
    Set-Variable -Name AppThemes -Value (& $nouveauxThemes) -Scope Script
    $script:ThemeCache = @{}
    $choix = $(if ($M.theme) { [string]$M.theme } else { 'neon' })
    $pack = $null; $id = $choix
    if ($choix -like 'pack:*') { $pack = Get-ThemePack $choix.Substring(5); $id = if ($pack) { $pack.Base } else { 'neon' } }
    if (-not $AppThemes.Contains($id)) { $id = 'neon' }
    Set-Variable -Name ThemeId -Value $id -Scope Script; Set-Variable -Name ThemePack -Value $pack -Scope Script
    $script:FichiersThemeConsole = @{}; $script:ImagesAnimees = @{}
    # Les applis (ConvertTo-Appli, les champs dont la console se sert)
    $liste = foreach ($a in @($M.applis)) {
        [pscustomobject]@{ Id = [string]$a.id; Nom = [string]$a.nom; Couleur = [string]$a.couleur; Description = [string]$a.description
            Presentation = [string]$a.presentation; Confidentialite = [string]$a.confidentialite; CacheDepuis = [string]$a.cache_depuis }
    }
    Set-Variable -Name Applis -Value @($liste) -Scope Script
    $p = $M.partage
    $script:Installations = @{}
    foreach ($e in (ConvertTo-Table $p.installations).GetEnumerator()) {
        $script:Installations[$e.Key] = @{ Dossier = ([string]$e.Value.dossier).Replace('<essai>', $Dossier); Gere = [bool]$e.Value.gere; Version = $(if ($null -ne $e.Value.version) { [string]$e.Value.version } else { $null }) }
    }
    $script:Publications = @{}
    foreach ($e in (ConvertTo-Table $p.publications).GetEnumerator()) {
        $script:Publications[$e.Key] = $(if ($e.Value.erreur) { @{ Erreur = [string]$e.Value.erreur } } else { @{ Version = [string]$e.Value.version; Notes = [string]$e.Value.notes } })
    }
    $script:Ouvertes = ConvertTo-Table $p.ouvertes
    $script:Trouvees = @{}; foreach ($e in (ConvertTo-Table $p.trouvees).GetEnumerator()) { $script:Trouvees[$e.Key] = [string]$e.Value }
    $script:Messages = @{}
    $script:Occupe = @{}; $script:Progres = @{}; $script:EnCours = @{}
    foreach ($e in (ConvertTo-Table $p.occupations).GetEnumerator()) {
        $o = $e.Value
        if ([string]$o.texte) { $script:Occupe[$e.Key] = [string]$o.texte }
        if ($null -ne $o.progres) { $script:Progres[$e.Key] = @{ Recu = [double]$o.progres * 1000; Total = 1000 } }
        elseif ([string]$o.quoi -eq 'installation') { $script:EnCours[$e.Key] = @{ Version = [string]$o.version } }
    }
    $script:Tache = $(if ($p.admin) { [string]$p.admin.tache } else { '' })
    $ma = $p.'maj-auto'
    $script:MajAuto = @{}; foreach ($e in (ConvertTo-Table $ma.en_cours).GetEnumerator()) { $script:MajAuto[$e.Key] = [string]$e.Value }
    $script:MajAutoEchecs = @{}; foreach ($e in (ConvertTo-Table $ma.echecs).GetEnumerator()) { $script:MajAutoEchecs[$e.Key] = @{ Version = [string]$e.Value.version; Raison = [string]$e.Value.raison } }
    $script:MajAutoEssais = @{}
    foreach ($e in (ConvertTo-Table $ma.essais).GetEnumerator()) { $script:MajAutoEssais[$e.Key] = @{ Version = [string]$e.Value.version; Nombre = [int]$e.Value.nombre; Quand = [datetime]::ParseExact([string]$e.Value.quand, 's', [Globalization.CultureInfo]::InvariantCulture) } }
    $script:MajAutoJeu = $(if ($ma) { [string]$ma.jeu } else { '' })
    $script:MajAutoAttentes = @{}; foreach ($e in (ConvertTo-Table $ma.attentes).GetEnumerator()) { $script:MajAutoAttentes[$e.Key] = [string]$e.Value }
    $mi = $p.mindset
    $mj = $(if ($mi) { $mi.maj } else { $null })
    $script:MajMindset = $(if ($mj -and $mj.prete) { @{ Version = [string]$mj.version; Notes = [string]$mj.notes } } else { $null })
    $script:MajMindsetEnCours = [bool]($mj -and $mj.en_cours)
    $script:ProgresMindset = $(if ($mj -and $mj.en_cours) { if ($null -ne $mj.progres) { @{ Version = [string]$mj.version; Recu = [double]$mj.progres * 1000; Total = 1000 } } else { @{ Version = ''; Recu = 0; Total = 0 } } } else { $null })
    $script:Historique = @(); if ($mi -and $mi.derniere_maj) { $script:Historique = @($mi.derniere_maj) }
    $r = $p.recherche
    $script:Recherches = @{}; if ($r) { foreach ($i in @($r.en_cours)) { if ($i) { $script:Recherches[[string]$i] = $script:Maintenant } } }
    $script:RechercheDepuis = $(if ($r -and $r.depuis) { [datetime]::ParseExact([string]$r.depuis, 's', [Globalization.CultureInfo]::InvariantCulture) } else { [datetime]::MinValue })
    $script:DernieresPublications = $(if ($r -and $r.derniere) { [datetime]::ParseExact([string]$r.derniere, 's', [Globalization.CultureInfo]::InvariantCulture) } else { [datetime]'2026-11-07T19:00:00' })
    $script:Integrees = @{}
    $k = 0
    foreach ($e in (ConvertTo-Table $p.accrochees).GetEnumerator()) { $k++; $script:Integrees[$e.Key] = @{ Fenetre = $(if ([string]$e.Value.etat -eq 'affiche') { [IntPtr]$k } else { [IntPtr]::Zero }); Id = $e.Key } }
    $script:OngletParametres = $(if ($p.'onglet-parametres') { [string]$p.'onglet-parametres' } else { 'general' })
    $script:PageCourante = $(if ($M.page) { [string]$M.page } else { 'accueil' })
    $Window.IsVisible = -not ($M.vue -and $M.vue.visible -eq $false)
    $Window.WindowState = $(if ($M.vue -and $M.vue.reduite) { 'Minimized' } else { 'Normal' })
    $script:ui = [pscustomobject]@{ PageConsole = (New-Zone); PageAccueil = (New-Zone); ConsoleAttente = (New-Zone) }
    Set-Variable -Name ui -Value $script:ui -Scope Script
    $c = $M.console
    $script:Console = @{ Possible = $true; Vue = $null; Pret = $false; DerniereAppli = $null; AJouer = $null; EtatEnvoye = ''; QuitteeA = $null
        EnFente = $null; Ejecter = $null; Attente = $null; AttenteDepuis = $null; Parametres = $false; ParametresEnvoyes = ''; MajEnvoye = '' }
    if ($c) {
        if ($null -ne $c.possible) { $script:Console.Possible = [bool]$c.possible }
        if ($c.cadre) { $script:Console.Vue = 'vue' }
        $script:Console.Pret = [bool]$c.pret
        $script:Console.DerniereAppli = $(if ($c.derniere) { [string]$c.derniere } else { $null })
        $script:Console.Ejecter = $(if ($c.ejecter) { [string]$c.ejecter } else { $null })
        $script:Console.EnFente = $(if ($c.en_fente) { [string]$c.en_fente } else { $null })
        $script:Console.Parametres = [bool]$c.parametres
        if ($c.quittee) { $script:Console.QuitteeA = $script:Maintenant.AddSeconds(-5) }
    }
    $script:ActualiserChange = [bool]$M.actualiser_change
    # Les fichiers du cas (icônes des applis installées, logos déjà tirés, pack du thème)
    if ($M.fichiers) { foreach ($e in (ConvertTo-Table $M.fichiers).GetEnumerator()) {
        $f = Join-Path $Dossier $e.Key; New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null
        [IO.File]::WriteAllBytes($f, [Convert]::FromBase64String([string]$e.Value))
    } }
}
# Le monde est relu après la création des fichiers (le pack du thème en a besoin)
function Initialize-Cas($M) {
    $d = Join-Path $tmp ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $O = ConvertTo-Objet $M   # (les tables du cas deviennent des objets, comme un JSON lu)
    if ($O.fichiers) { Set-Monde ([pscustomobject]@{ fichiers = $O.fichiers }) $d }
    Set-Monde $O $d
    $d
}
function ConvertTo-Objet($H) { ($H | ConvertTo-Json -Depth 12 -Compress) | ConvertFrom-Json }
# Les scripts notés (« window.mindset.x('a', 1) ») en appels { appel, args } : les textes entre ' deviennent du JSON
function ConvertFrom-Scripts([string[]]$Liste) {
    foreach ($s in $Liste) {
        foreach ($morceau in ($s -split ';\s*(?=window\.mindset\.)')) {
            if ($morceau -notmatch '^window\.mindset\.(\w+)\((.*)\)$') { [ordered]@{ appel = '?'; texte = $morceau }; continue }
            $appel = $Matches[1]; $a = $Matches[2]
            $a = [regex]::Replace($a, "'([^']*)'", { param($m) ConvertTo-Json -InputObject $m.Groups[1].Value -Compress })
            [ordered]@{ appel = $appel; args = "[$a]" }   # (le texte JSON des arguments : le test Rust le lit)
        }
    }
}
function Get-Notes {
    $scripts = @($script:Appels | Where-Object { $_ -like 'script:*' } | ForEach-Object { $_.Substring(7) })
    $autres = @($script:Appels | Where-Object { $_ -notlike 'script:*' })
    $f = @([MSIntegration]::Fermees | ForEach-Object { $h = [long]$_; ($script:Integrees.GetEnumerator() | Where-Object { $_.Value.Fenetre.ToInt64() -eq $h } | Select-Object -First 1).Key } | ForEach-Object { "fermer:$_" })
    [ordered]@{ appels = @($autres + $f); scripts = @(ConvertFrom-Scripts $scripts); journal = @($script:Journal) }
}
function Get-EtatFinal {
    $c = $script:Console
    [ordered]@{ possible = [bool]$c.Possible; cadre = [bool]$c.Vue; pret = [bool]$c.Pret; derniere = $c.DerniereAppli; ejecter = $c.Ejecter
        en_fente = $c.EnFente; attente = $c.Attente; lancee = [bool]$c.Lancee; parametres = [bool]$c.Parametres; quittee = [bool]$c.QuitteeA
        a_jouer = @(if ($c.AJouer) { ConvertFrom-Scripts @($c.AJouer) })
        page_console = [string]$script:ui.PageConsole.Visibility; reglages = $script:Reglages }
}

# ---------------------------------------------------------------------------------------------------------------
# Les données des cas
# ---------------------------------------------------------------------------------------------------------------
$EVERMIND = [ordered]@{ id = 'evermind'; nom = 'Evermind'; couleur = '#B04BFF'; description = 'Ton agenda.'; presentation = 'Ton agenda, qui te rappelle tes rendez-vous.'; confidentialite = 'https://github.com/JordanJacquot/Evermind/blob/main/CONFIDENTIALITE.md'; cache_depuis = '0.14.0' }
$NEVERMIND = [ordered]@{ id = 'nevermind'; nom = 'Nevermind'; couleur = '#00E5FF'; description = 'Ton PC au mieux.'; presentation = ''; confidentialite = ''; cache_depuis = '' }
$MINDCARE = [ordered]@{ id = 'mindcare'; nom = 'Mindcare'; couleur = '#3DDC84'; description = 'Prendre soin de toi.'; presentation = 'Un coin calme.'; confidentialite = ''; cache_depuis = '0.2.0' }
$CAFE = [ordered]@{ id = 'cafe-creme'; nom = 'Café crème'; couleur = '#FF8A3D'; description = 'Une appli d''essai, avec des accents : été, forêt.'; presentation = ''; confidentialite = 'https://exemple.invalid/cafe'; cache_depuis = '' }
$TOUTES = @($NEVERMIND, $EVERMIND, $MINDCARE, $CAFE)
function Inst([string]$Version, [bool]$Gere = $true, [string]$Nom = 'X') { [ordered]@{ dossier = "<essai>\Programmes\$Nom"; gere = $Gere; version = $Version } }
function Pub([string]$Version) { [ordered]@{ version = $Version; url_zip = ''; url_sig = ''; notes = "- Nouveauté de la $Version"; essai = $false } }

# Une icône (.ico) avec ces images : (largeur, octets) ; une image PNG commence par 0x89
function New-Icone($Images) {
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter $ms
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$Images.Count)
    $dp = 6 + 16 * $Images.Count
    foreach ($i in $Images) { $bw.Write([byte]$i[0]); $bw.Write([byte]$i[0]); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$i[1].Length); $bw.Write([uint32]$dp); $dp += $i[1].Length }
    foreach ($i in $Images) { $bw.Write([byte[]]$i[1]) }
    $bw.Flush(); [Convert]::ToBase64String($ms.ToArray())
}
$PNG1 = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5, 6)
$PNG2 = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)
$BMP = [byte[]](0x28, 0, 0, 0, 16, 0, 0, 0)
$alea = New-Object Random 20261107
function Get-Alea($Liste) { $Liste[$alea.Next($Liste.Count)] }

# ---------------------------------------------------------------------------------------------------------------
# 1. L'état des applis (Get-EtatConsole, Get-LogoConsole)
# ---------------------------------------------------------------------------------------------------------------
$casEtat = New-Object Collections.Generic.List[object]
function Add-CasEtat([string]$Nom, $M) {
    $d = Initialize-Cas $M
    $json = Get-EtatConsole
    $fichiers = [ordered]@{}
    if (Test-Path -LiteralPath $script:LogosAppliDir) { foreach ($f in Get-ChildItem -LiteralPath $script:LogosAppliDir -File) { $fichiers[$f.Name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName)) } }
    $casEtat.Add([ordered]@{ nom = $Nom; entree = $M; sortie = ($json | ConvertFrom-Json); logos_ecrits = $fichiers; journal = @($script:Journal) })
}
Add-CasEtat 'aucune appli' ([ordered]@{ applis = @(); partage = @{} })
Add-CasEtat 'rien d''installé, Néon' ([ordered]@{ applis = $TOUTES; partage = @{} })
Add-CasEtat 'installées, ouvertes, à jour' ([ordered]@{ applis = $TOUTES; partage = [ordered]@{
    installations = [ordered]@{ nevermind = (Inst '2.0.1' $true 'Nevermind'); evermind = (Inst '0.15.0' $true 'Evermind') }
    publications = [ordered]@{ nevermind = (Pub '2.0.1'); evermind = (Pub '0.15.0') }; ouvertes = [ordered]@{ nevermind = $true; evermind = $false } } })
Add-CasEtat 'mise à jour disponible, gérée ou non' ([ordered]@{ applis = $TOUTES; partage = [ordered]@{
    installations = [ordered]@{ nevermind = (Inst '2.0.1' $true); evermind = (Inst '0.14.2' $false); mindcare = (Inst '0.3.1' $true) }
    publications = [ordered]@{ nevermind = (Pub '2.1.0'); evermind = (Pub '0.15.0'); mindcare = [ordered]@{ erreur = 'GitHub injoignable' } } } })
Add-CasEtat 'version installée illisible' ([ordered]@{ applis = $TOUTES; partage = [ordered]@{
    installations = [ordered]@{ nevermind = [ordered]@{ dossier = '<essai>\N'; gere = $true; version = $null } }; publications = [ordered]@{ nevermind = (Pub '2.1.0') } } })
Add-CasEtat 'téléchargement et installation en cours' ([ordered]@{ applis = $TOUTES; partage = [ordered]@{
    installations = [ordered]@{ nevermind = (Inst '2.0.1') }; publications = [ordered]@{ nevermind = (Pub '2.1.0'); evermind = (Pub '0.15.0') }
    occupations = [ordered]@{ nevermind = [ordered]@{ texte = 'Téléchargement...'; progres = 0.66666; version = '2.1.0'; auto = $false; quoi = 'installation' }
        evermind = [ordered]@{ texte = 'Installation...'; progres = $null; version = '0.15.0'; auto = $true; quoi = 'installation' }
        mindcare = [ordered]@{ texte = 'Désinstallation...'; progres = $null; version = $null; auto = $false; quoi = 'desinstallation' } } } })
Add-CasEtat 'progrès arrondi au pair (0,0005)' ([ordered]@{ applis = @($NEVERMIND); partage = [ordered]@{ occupations = [ordered]@{ nevermind = [ordered]@{ texte = 'Téléchargement...'; progres = 0.0005; quoi = 'installation' } } } })
Add-CasEtat 'occupée sans texte : pas occupée' ([ordered]@{ applis = @($NEVERMIND); partage = [ordered]@{ installations = [ordered]@{ nevermind = (Inst '1.0') }; publications = [ordered]@{ nevermind = (Pub '1.1') }; occupations = [ordered]@{ nevermind = [ordered]@{ texte = ''; progres = 0.5 } } } })
foreach ($th in 'crepuscule', 'terminal', 'arcade', 'rubis') { Add-CasEtat "thème $th" ([ordered]@{ theme = $th; applis = $TOUTES; partage = [ordered]@{ installations = [ordered]@{ evermind = (Inst '0.15.0') } } }) }
Add-CasEtat 'couleur en minuscules (Néon : telle quelle)' ([ordered]@{ applis = @([ordered]@{ id = 'essai'; nom = 'Essai'; couleur = '#00e5ff'; description = 'd' }); partage = @{} })
Add-CasEtat 'couleur en minuscules (Crépuscule)' ([ordered]@{ theme = 'crepuscule'; applis = @([ordered]@{ id = 'essai'; nom = 'Essai'; couleur = '#00e5ff'; description = 'd' }); partage = @{} })
# Les logos : livré, déjà tiré, tiré de l'icône (la plus grande image PNG), icône sans PNG, icône abîmée, pas d'icône
$ico = New-Icone @(@(32, $PNG1), @(0, $PNG2), @(64, $BMP))
Add-CasEtat 'logo tiré de l''icône (la plus grande image PNG)' ([ordered]@{ applis = @($CAFE); partage = [ordered]@{ installations = [ordered]@{ 'cafe-creme' = (Inst '1.0' $true 'Cafe') } }; fichiers = [ordered]@{ 'Programmes\Cafe\fichiers\cafe.ico' = $ico } })
Add-CasEtat 'logo : la première icône par ordre des noms' ([ordered]@{ applis = @($CAFE); partage = [ordered]@{ installations = [ordered]@{ 'cafe-creme' = (Inst '1.0' $true 'Cafe') } }
    fichiers = [ordered]@{ 'Programmes\Cafe\fichiers\b.ico' = (New-Icone @(, @(48, $PNG1))); 'Programmes\Cafe\fichiers\A.ico' = (New-Icone @(, @(16, $PNG2))) } })
Add-CasEtat 'logo : icône sans image PNG (la lettre)' ([ordered]@{ applis = @($CAFE); partage = [ordered]@{ installations = [ordered]@{ 'cafe-creme' = (Inst '1.0' $true 'Cafe') } }; fichiers = [ordered]@{ 'Programmes\Cafe\fichiers\cafe.ico' = (New-Icone @(, @(32, $BMP))) } })
Add-CasEtat 'logo : icône abîmée' ([ordered]@{ applis = @($CAFE); partage = [ordered]@{ installations = [ordered]@{ 'cafe-creme' = (Inst '1.0' $true 'Cafe') } }; fichiers = [ordered]@{ 'Programmes\Cafe\fichiers\cafe.ico' = [Convert]::ToBase64String([byte[]](0, 0, 1, 0, 5, 0, 32)) } })
Add-CasEtat 'logo : image PNG qui dépasse la fin' ([ordered]@{ applis = @($CAFE); partage = [ordered]@{ installations = [ordered]@{ 'cafe-creme' = (Inst '1.0' $true 'Cafe') } }
    fichiers = [ordered]@{ 'Programmes\Cafe\fichiers\cafe.ico' = ([Convert]::ToBase64String(([Convert]::FromBase64String((New-Icone @(, @(32, $PNG1)))))[0..20])) } })
Add-CasEtat 'logo déjà tiré (pas installée)' ([ordered]@{ applis = @($CAFE); partage = @{}; fichiers = [ordered]@{ 'Donnees\console-logos\cafe-creme.png' = [Convert]::ToBase64String($PNG1) } })
Add-CasEtat 'logo : pas installée, pas d''icône' ([ordered]@{ applis = @($CAFE); partage = @{} })
Add-CasEtat 'logo : installée, dossier absent' ([ordered]@{ applis = @($CAFE); partage = [ordered]@{ installations = [ordered]@{ 'cafe-creme' = (Inst '1.0' $true 'Absent') } } })
# Des mondes au hasard (jamais écrits à la main)
for ($n = 1; $n -le 40; $n++) {
    $ins = [ordered]@{}; $pubs = [ordered]@{}; $ouv = [ordered]@{}; $occ = [ordered]@{}
    foreach ($a in $TOUTES) {
        if ($alea.Next(3)) { $ins[$a.id] = (Inst (Get-Alea @('1.0.0', '1.2', '2.0.1', '0.15.0', '3.0.0.1', '')) ([bool]$alea.Next(2)) $a.nom) }
        if ($alea.Next(3)) { $pubs[$a.id] = $(if ($alea.Next(6)) { (Pub (Get-Alea @('1.0.0', '1.3', '2.1.0', '0.15.0', 'abc'))) } else { [ordered]@{ erreur = 'injoignable' } }) }
        $ouv[$a.id] = [bool]$alea.Next(2)
        if (-not $alea.Next(4)) { $occ[$a.id] = [ordered]@{ texte = (Get-Alea @('Téléchargement...', 'Installation...', '')); progres = (Get-Alea @($null, 0.0, 0.25, 0.3333, 0.9995, 1.0)); version = '9.9'; auto = $false; quoi = (Get-Alea @('installation', 'desinstallation', 'deplacement')) } }
    }
    Add-CasEtat "au hasard $n" ([ordered]@{ theme = (Get-Alea @('neon', 'crepuscule', 'terminal', 'arcade', 'rubis')); applis = $TOUTES; partage = [ordered]@{ installations = $ins; publications = $pubs; ouvertes = $ouv; occupations = $occ } })
}

# ---------------------------------------------------------------------------------------------------------------
# 2. La carte des mises à jour (Get-EtatMajConsole)
# ---------------------------------------------------------------------------------------------------------------
$casMaj = New-Object Collections.Generic.List[object]
function Add-CasMaj([string]$Nom, $M) {
    $null = Initialize-Cas $M
    $casMaj.Add([ordered]@{ nom = $Nom; entree = $M; sortie = ((Get-EtatMajConsole) | ConvertFrom-Json) })
}
$systeme = [ordered]@{ tache = 'systeme'; en_cours = 0 }
$base = [ordered]@{ nevermind = (Inst '2.0.1'); evermind = (Inst '0.14.2') }
function MondeMaj($Partage, $Reglages = @{}, [bool]$Admin = $false, [string]$Theme = 'neon', [string]$Maintenant = '2026-11-07T20:00:00') {
    $p = [ordered]@{ installations = $base; admin = $systeme }
    foreach ($k in $Partage.Keys) { $p[$k] = $Partage[$k] }
    [ordered]@{ theme = $Theme; applis = $TOUTES; reglages = $Reglages; admin = $Admin; partage = $p; maintenant = $Maintenant }
}
Add-CasMaj 'tout à jour' (MondeMaj @{})
Add-CasMaj 'recherche coupée' (MondeMaj @{} @{ VerifVersions = $false })
Add-CasMaj 'recherche en cours (une question à GitHub)' (MondeMaj ([ordered]@{ recherche = [ordered]@{ en_cours = @('evermind'); depuis = '2026-11-07T19:59:00' } }))
Add-CasMaj 'recherche : depuis 1 s (au moins 2 s)' (MondeMaj ([ordered]@{ recherche = [ordered]@{ en_cours = @(); depuis = '2026-11-07T19:59:59' } }))
Add-CasMaj 'recherche : depuis 2 s (finie)' (MondeMaj ([ordered]@{ recherche = [ordered]@{ en_cours = @(); depuis = '2026-11-07T19:59:58' } }))
Add-CasMaj 'téléchargement d''une appli' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; occupations = [ordered]@{ evermind = [ordered]@{ texte = 'Téléchargement...'; progres = 0.4219; version = '0.15.0'; quoi = 'installation' } } }))
Add-CasMaj 'installation automatique' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; occupations = [ordered]@{ evermind = [ordered]@{ texte = 'Installation...'; progres = $null; version = '0.15.0'; quoi = 'installation' } }; 'maj-auto' = [ordered]@{ en_cours = [ordered]@{ evermind = '0.15.0' } } }))
Add-CasMaj 'installation sans version : celle publiée' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.1') }; occupations = [ordered]@{ evermind = [ordered]@{ texte = 'Installation...'; progres = $null; version = $null; quoi = 'installation' } } }))
Add-CasMaj 'deux occupées : celle qui télécharge d''abord' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0'); nevermind = (Pub '2.1.0') }; occupations = [ordered]@{ nevermind = [ordered]@{ texte = 'Installation...'; progres = $null; version = '2.1.0'; quoi = 'installation' }; evermind = [ordered]@{ texte = 'Téléchargement...'; progres = 1.2; quoi = 'installation' } } }))
Add-CasMaj 'une désinstallation ne compte pas' (MondeMaj ([ordered]@{ occupations = [ordered]@{ evermind = [ordered]@{ texte = 'Désinstallation...'; progres = $null; quoi = 'desinstallation' } } }))
Add-CasMaj 'Mindset se télécharge' (MondeMaj ([ordered]@{ mindset = [ordered]@{ installe = $true; maj = [ordered]@{ version = '3.1.0'; notes = ''; prete = $false; progres = 0.42; en_cours = $true } } }))
Add-CasMaj 'Mindset : recherche de sa version' (MondeMaj ([ordered]@{ mindset = [ordered]@{ installe = $true; maj = [ordered]@{ version = $null; prete = $false; progres = $null; en_cours = $true } } }))
Add-CasMaj 'Mindset prêt (auto possible : en attente, veille)' (MondeMaj ([ordered]@{ mindset = [ordered]@{ maj = [ordered]@{ version = '3.1.0'; notes = 'n'; prete = $true; progres = $null; en_cours = $false } } }))
Add-CasMaj 'Mindset prêt mais pas plus récent' (MondeMaj ([ordered]@{ mindset = [ordered]@{ maj = [ordered]@{ version = '3.0.0'; prete = $true; en_cours = $false } } }))
Add-CasMaj 'version prête (mises à jour auto coupées)' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') } }) @{ MajAuto = $false })
Add-CasMaj 'version prête (Mindset administrateur)' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') } }) @{} $true)
Add-CasMaj 'version prête (tâche ancienne)' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; admin = [ordered]@{ tache = 'ancienne'; en_cours = 0 } }))
Add-CasMaj 'en attente : jeu' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ jeu = 'un jeu ouvert (Forêt magique)' } }))
Add-CasMaj 'en attente : manette' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ jeu = 'une manette utilisée il y a moins de 5 minutes' } }))
Add-CasMaj 'en attente : plein écran' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ jeu = 'une fenêtre en plein écran (jeu ou vidéo)' } }))
Add-CasMaj 'en attente : PC utilisé' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ jeu = ''; attentes = [ordered]@{ evermind = 'utilise' } } }))
Add-CasMaj 'en attente : bientôt' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') } }))
Add-CasMaj 'échec, réessai dans 11 minutes' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ echecs = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; raison = 'Internet a coupé pendant le téléchargement.'; reessai = 11 } }; essais = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; quand = '2026-11-07T19:55:30'; nombre = 1 } } } }))
Add-CasMaj 'échec, 3 essais : plus tout seul' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ echecs = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; raison = 'x' } }; essais = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; quand = '2026-11-07T19:59:00'; nombre = 3 } } } }))
Add-CasMaj 'échec, essai vieux de 20 minutes (rien n''empêche)' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ echecs = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; raison = 'x' } }; essais = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; quand = '2026-11-07T19:40:00'; nombre = 1 } } } }))
Add-CasMaj 'échec d''une autre version : en attente' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ echecs = [ordered]@{ evermind = [ordered]@{ version = '0.14.9'; raison = 'x' } } } }))
Add-CasMaj 'échec, auto coupée : -1' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ echecs = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; raison = 'Le disque est plein.' } } } }) @{ MajAuto = $false })
Add-CasMaj 'essai récent sans échec : prête' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0') }; 'maj-auto' = [ordered]@{ essais = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; quand = '2026-11-07T19:58:00'; nombre = 1 } } } }))
Add-CasMaj 'la dernière mise à jour, aujourd''hui' (MondeMaj ([ordered]@{ mindset = [ordered]@{ derniere_maj = [ordered]@{ id = 'evermind'; nom = 'Evermind'; version = '0.14.2'; quand = '2026-11-07T19:13:00'; auto = $true; notes = "- Les rappels sonnent`n- Plus vite" } } }))
Add-CasMaj 'la dernière mise à jour, hier' (MondeMaj ([ordered]@{ mindset = [ordered]@{ derniere_maj = [ordered]@{ id = 'mindset'; nom = 'Mindset'; version = '2.18.0'; quand = '2026-11-07T08:05:00'; auto = $false; notes = '' } } }) @{} $false 'neon' '2026-11-08T01:00:00')
Add-CasMaj 'la dernière mise à jour, il y a 12 h : plus montrée' (MondeMaj ([ordered]@{ mindset = [ordered]@{ derniere_maj = [ordered]@{ id = 'evermind'; nom = 'Evermind'; version = '0.14.2'; quand = '2026-11-07T08:00:00'; auto = $true; notes = '' } } }))
Add-CasMaj 'la dernière mise à jour, d''une appli retirée' (MondeMaj ([ordered]@{ mindset = [ordered]@{ derniere_maj = [ordered]@{ id = 'ancienne'; nom = 'Ancienne appli'; version = '1.0'; quand = '2026-11-07T18:00:00'; auto = $false; notes = 'n' } } }) @{} $false 'crepuscule')
Add-CasMaj 'la dernière mise à jour, dans le futur : plus montrée' (MondeMaj ([ordered]@{ mindset = [ordered]@{ derniere_maj = [ordered]@{ id = 'evermind'; nom = 'Evermind'; version = '0.14.2'; quand = '2026-11-07T21:00:00'; auto = $true; notes = '' } } }))
Add-CasMaj 'le 18 octobre (plus de 12 h : rien)' (MondeMaj ([ordered]@{ mindset = [ordered]@{ derniere_maj = [ordered]@{ id = 'evermind'; nom = 'Evermind'; version = '0.14.2'; quand = '2026-10-18T09:30:00'; auto = $true; notes = '' } } }))
Add-CasMaj 'deux versions disponibles : la première de la liste' (MondeMaj ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.15.0'); nevermind = (Pub '2.1.0') }; mindset = [ordered]@{ maj = [ordered]@{ version = '3.1.0'; prete = $true } } }) @{ MajAuto = $false } $false 'arcade')
for ($n = 1; $n -le 50; $n++) {
    $p = [ordered]@{}
    $pubs = [ordered]@{}; foreach ($a in 'nevermind', 'evermind') { if ($alea.Next(2)) { $pubs[$a] = (Pub (Get-Alea @('2.0.1', '2.1.0', '0.14.2', '0.15.0'))) } }
    $p.publications = $pubs
    if (-not $alea.Next(3)) { $p.occupations = [ordered]@{ (Get-Alea @('nevermind', 'evermind')) = [ordered]@{ texte = 'Occupé...'; progres = (Get-Alea @($null, 0.1, 0.5555, 1.0)); version = (Get-Alea @($null, '9.0')); quoi = (Get-Alea @('installation', 'desinstallation')) } } }
    if (-not $alea.Next(3)) { $p.recherche = [ordered]@{ en_cours = @(Get-Alea @(@(), @('evermind'))); depuis = (Get-Alea @('2026-11-07T19:59:59', '2026-11-07T19:00:00')) } }
    $ma = [ordered]@{ jeu = (Get-Alea @('', '', 'un jeu ouvert (Café)')); attentes = [ordered]@{ evermind = (Get-Alea @('', 'page', 'utilise')) } }
    if (-not $alea.Next(3)) { $ma.echecs = [ordered]@{ evermind = [ordered]@{ version = (Get-Alea @('0.15.0', '0.14.9')); raison = 'raison' } } }
    if (-not $alea.Next(3)) { $ma.essais = [ordered]@{ evermind = [ordered]@{ version = '0.15.0'; quand = (Get-Alea @('2026-11-07T19:59:00', '2026-11-07T19:30:00')); nombre = (Get-Alea @(1, 2, 3)) } } }
    $p.'maj-auto' = $ma
    if (-not $alea.Next(3)) { $p.mindset = [ordered]@{ maj = [ordered]@{ version = (Get-Alea @('3.1.0', '2.0.0')); prete = [bool]$alea.Next(2); progres = (Get-Alea @($null, 0.3)); en_cours = [bool]$alea.Next(2) }; derniere_maj = $(if ($alea.Next(2)) { [ordered]@{ id = 'nevermind'; nom = 'Nevermind'; version = '2.0.1'; quand = (Get-Alea @('2026-11-07T10:00:00', '2026-11-06T23:00:00')); auto = [bool]$alea.Next(2); notes = 'n' } } else { $null }) } }
    if (-not $alea.Next(4)) { $p.admin = [ordered]@{ tache = (Get-Alea @('systeme', 'ancienne', 'absente')); en_cours = 0 } }
    Add-CasMaj "au hasard $n" (MondeMaj $p ([ordered]@{ MajAuto = [bool]$alea.Next(3); VerifVersions = [bool]$alea.Next(4) }) ([bool](-not $alea.Next(5))) (Get-Alea @('neon', 'crepuscule', 'rubis')))
}

# ---------------------------------------------------------------------------------------------------------------
# 3. Les couleurs de la scène et les images du thème (Get-CouleursConsole, Get-ThemeConsole, Test-ImageAnimee)
# ---------------------------------------------------------------------------------------------------------------
$casTheme = New-Object Collections.Generic.List[object]
function Add-CasTheme([string]$Nom, $M) {
    $null = Initialize-Cas $M
    $t = Get-ThemeConsole
    $casTheme.Add([ordered]@{ nom = $Nom; entree = $M; couleurs = (Get-CouleursConsole); theme = $(if ($t) { $t | ConvertFrom-Json } else { $null }) })
}
function B64([byte[]]$B) { [Convert]::ToBase64String($B) }
function Texte64([string]$T) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($T)) }
$gifAnime = [byte[]]([Text.Encoding]::ASCII.GetBytes('GIF89a') + @(1, 0, 1, 0, 0, 0, 0) + @(0x21, 0xF9, 0x04, 0, 0, 0, 0, 0) + @(0x2C) + @(0x21, 0xF9, 0x04, 0, 0, 0, 0, 0) + @(0x3B))
$gifFixe = [byte[]]([Text.Encoding]::ASCII.GetBytes('GIF89a') + @(1, 0, 1, 0, 0, 0, 0) + @(0x21, 0xF9, 0x04, 0, 0, 0, 0, 0) + @(0x2C, 0x3B))
$pngFixe = [byte[]](@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + [Text.Encoding]::ASCII.GetBytes('....IHDR....IDAT....'))
$pngAnime = [byte[]](@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + [Text.Encoding]::ASCII.GetBytes('....IHDR....acTL....IDAT....'))
$webpAnime = [byte[]]([Text.Encoding]::ASCII.GetBytes('RIFF') + @(0, 0, 0, 0) + [Text.Encoding]::ASCII.GetBytes('WEBPVP8X') + @(0, 0, 0, 0, 0x02, 0, 0, 0))
$webpFixe = [byte[]]([Text.Encoding]::ASCII.GetBytes('RIFF') + @(0, 0, 0, 0) + [Text.Encoding]::ASCII.GetBytes('WEBPVP8 ') + @(0, 0, 0, 0, 0, 0, 0, 0))
$jpeg = [byte[]](0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0)
$ttf = [byte[]](0, 1, 0, 0, 0, 0x0B, 0x00, 0x80, 0, 3, 0, 0x30)
foreach ($th in 'neon', 'crepuscule', 'terminal', 'arcade', 'rubis') { Add-CasTheme "couleurs $th" ([ordered]@{ theme = $th; applis = @(); partage = @{} }) }
function Pack([string]$Id, $Json, $Fichiers) {
    $f = [ordered]@{ "Donnees\packs\$Id\pack.json" = (Texte64 ($Json | ConvertTo-Json -Depth 8)) }
    foreach ($k in $Fichiers.Keys) { $f["Donnees\packs\$Id\$k"] = (B64 $Fichiers[$k]) }
    $f
}
Add-CasTheme 'pack complet (mascotte GIF animée, chargement qui tourne, logo de la console, police)' ([ordered]@{ theme = 'pack:foret'; applis = @(); partage = @{}
    fichiers = (Pack 'foret' ([ordered]@{ Name = 'Forêt'; Base = 'crepuscule'; Logo = 'logo.png'; Font = 'police.ttf'; Background = 'fond.jpg'; BackgroundOpacity = 0.5
        Console = [ordered]@{ Fond = 'console-fond.webp'; FondOpacite = 0.8; Mascotte = 'mascotte.gif'; Chargement = [ordered]@{ File = 'roue.png'; Effet = 'tourne' }; Logo = 'console logo (1).gif' } }) ([ordered]@{
        'logo.png' = $pngFixe; 'police.ttf' = $ttf; 'fond.jpg' = $jpeg; 'console-fond.webp' = $webpFixe; 'mascotte.gif' = $gifAnime; 'roue.png' = $pngFixe; 'console logo (1).gif' = $gifFixe })) })
Add-CasTheme 'pack : le fond du pack faute de fond de console, logo du pack, mascotte fixe' ([ordered]@{ theme = 'pack:cafe-creme'; applis = @(); partage = @{}
    fichiers = (Pack 'cafe-creme' ([ordered]@{ Name = 'Café crème'; Base = 'rubis'; Logo = 'logo.png'; Background = 'fond.jpg'; BackgroundOpacity = 0.6; Console = [ordered]@{ Mascotte = 'm.png'; Chargement = 'charge.webp' } }) ([ordered]@{
        'logo.png' = $pngFixe; 'fond.jpg' = $jpeg; 'm.png' = $pngFixe; 'charge.webp' = $webpAnime })) })
Add-CasTheme 'pack : planche animée, le logo de Mindset reste ; mascotte PNG animée' ([ordered]@{ theme = 'pack:ete'; applis = @(); partage = @{}
    fichiers = (Pack 'ete' ([ordered]@{ Name = 'Été'; Logo = 'planche.png'; LogoFrames = 4; Console = [ordered]@{ Mascotte = 'm.png'; FondOpacite = 0.01 } }) ([ordered]@{ 'planche.png' = $pngFixe; 'm.png' = $pngAnime })) })
Add-CasTheme 'pack sans bloc Console : rien' ([ordered]@{ theme = 'pack:sans'; applis = @(); partage = @{}; fichiers = (Pack 'sans' ([ordered]@{ Name = 'Sans'; Logo = 'logo.png' }) ([ordered]@{ 'logo.png' = $pngFixe })) })
Add-CasTheme 'pack aux couleurs propres' ([ordered]@{ theme = 'pack:couleurs'; applis = @(); partage = @{}
    fichiers = (Pack 'couleurs' ([ordered]@{ Name = 'Couleurs'; Colors = [ordered]@{ P = '#22AAFF'; S = '#FFAA22'; T = '#AA22FF'; NH = 210; NS = 0.5; Map = [ordered]@{ '07060D' = '#010203' } }; Console = [ordered]@{ Mascotte = 'm.webp' } }) ([ordered]@{ 'm.webp' = $webpAnime })) })
Add-CasTheme 'pack introuvable : Néon' ([ordered]@{ theme = 'pack:absent'; applis = @(); partage = @{} })
$casAnime = New-Object Collections.Generic.List[object]
foreach ($x in @(@('gif animé', $gifAnime), @('gif fixe', $gifFixe), @('png fixe', $pngFixe), @('png animé', $pngAnime), @('webp animé', $webpAnime), @('webp fixe', $webpFixe), @('jpeg', $jpeg),
    @('trop court', [byte[]](0x47, 0x49, 0x46)), @('vide', [byte[]]@()), @('webp coupé', [byte[]]$webpAnime[0..17]), @('png acTL après IDAT', [byte[]](@(0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0) + [Text.Encoding]::ASCII.GetBytes('IDATacTL'))),
    @('png acTL sans IDAT', [byte[]](@(0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0) + [Text.Encoding]::ASCII.GetBytes('acTL'))))) {
    $f = Join-Path $tmp ("anime-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [IO.File]::WriteAllBytes($f, [byte[]]$x[1]); $script:ImagesAnimees = @{}
    $casAnime.Add([ordered]@{ nom = $x[0]; octets = (B64 $x[1]); animee = [bool](Test-ImageAnimee $f) })
}
for ($n = 1; $n -le 30; $n++) {
    $b = New-Object byte[] ($alea.Next(40) + 1); $alea.NextBytes($b)
    $debut = Get-Alea @(@(0x47, 0x49, 0x46, 0x38), @(0x89, 0x50, 0x4E, 0x47), @(0x52, 0x49, 0x46, 0x46), @())
    for ($i = 0; $i -lt [math]::Min($debut.Count, $b.Length); $i++) { $b[$i] = $debut[$i] }
    if ($b.Length -gt 12 -and $debut.Count -and $debut[0] -eq 0x52) { $w = [Text.Encoding]::ASCII.GetBytes('WEBPVP8X'); for ($i = 0; $i -lt 8 -and 8 + $i -lt $b.Length; $i++) { $b[8 + $i] = $w[$i] } }
    $f = Join-Path $tmp ("anime-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [IO.File]::WriteAllBytes($f, $b); $script:ImagesAnimees = @{}
    $casAnime.Add([ordered]@{ nom = "au hasard $n"; octets = (B64 $b); animee = [bool](Test-ImageAnimee $f) })
}

# ---------------------------------------------------------------------------------------------------------------
# 4. Les petites règles : Format-QuandMaj, Get-NomRaisonJeu, Get-AvanceeOuverture, Get-ReactionIncidentConsole
# ---------------------------------------------------------------------------------------------------------------
$casRegles = [ordered]@{ quand = @(); jeu = @(); avancee = @(); incident = @() }
foreach ($x in @(@('2026-11-07T00:16:00', '2026-11-07T20:00:00'), @('2026-11-06T21:05:00', '2026-11-07T00:30:00'), @('2026-10-18T09:30:00', '2026-11-07T20:00:00'),
    @('2026-01-01T00:00:00', '2026-12-31T23:59:59'), @('2026-02-28T23:59:59', '2026-03-01T00:00:00'), @('2024-02-29T12:00:00', '2024-03-01T08:00:00'), @('2026-08-15T07:07:00', '2026-08-17T07:07:00'), @('2026-11-08T10:00:00', '2026-11-07T20:00:00'))) {
    $script:Maintenant = [datetime]$x[1]
    $casRegles.quand += [ordered]@{ quand = $x[0]; maintenant = $x[1]; texte = (Format-QuandMaj $x[0]) }
}
foreach ($r in 'un jeu ouvert (Forêt magique)', 'un jeu ouvert ()', 'Un jeu ouvert (MAJUSCULES)', 'une fenêtre en plein écran (jeu ou vidéo)', 'une manette utilisée il y a moins de 5 minutes', 'autre chose', '', 'un jeu ouvert (a (b))', 'PLEIN ÉCRAN') {
    $casRegles.jeu += [ordered]@{ raison = $r; nom = (Get-NomRaisonJeu $r) }
}
foreach ($id in 'nevermind', 'evermind', 'cafe-creme') {
    foreach ($reglage in @($null, 12.5, 0.4, 'abc', 3)) {
        foreach ($e in @(-1, 0, 0.3, 1, 2.5, 5, 9.99, 10, 12.5, 20, 30, 45, 61, 200)) {
            $script:Reglages = @{}; if ($null -ne $reglage) { $script:Reglages["Ouverture-$id"] = $reglage }
            $script:Console = @{ DureeAttendue = $null }
            $v = $null; try { $v = Get-AvanceeOuverture ([pscustomobject]@{ Id = $id }) $e } catch { $v = 'erreur' }
            $casRegles.avancee += [ordered]@{ id = $id; reglage = $reglage; ecoule = $e; avancee = $v }
        }
    }
}
foreach ($g in 'BrowserProcessExited', 'RenderProcessExited', 'RenderProcessUnresponsive', 'GpuProcessExited', 'UtilityProcessExited', 'FrameRenderProcessExited', 'UnknownProcessExited', 'SandboxHelperProcessExited', 'renderprocessexited', '') {
    $casRegles.incident += [ordered]@{ genre = $g; reaction = (Get-ReactionIncidentConsole $g) }
}

# ---------------------------------------------------------------------------------------------------------------
# 5. Les incidents dans le temps (Receive-IncidentConsole, Stop-Console, Resume-ConsoleArretee)
# ---------------------------------------------------------------------------------------------------------------
$casIncidents = New-Object Collections.Generic.List[object]
function Update-PageConsole { $script:Appels.Add('page-console') }   # (remplacée le temps de ces cas : comptée)
function Add-CasIncidents([string]$Nom, $Pas, $Reglages = @{}) {
    $null = Initialize-Cas ([ordered]@{ applis = @(); partage = @{}; reglages = $Reglages; console = [ordered]@{ possible = $true; cadre = $true; pret = $true } })
    $script:Console.Incidents = @(); $script:ConsoleTimer.Lancee = 0
    $etapes = @()
    foreach ($p in $Pas) {
        $script:Maintenant = $script:Maintenant.AddSeconds([double]$p.attendre)
        $script:Appels.Clear(); $script:Journal.Clear()
        if ($p.quoi -eq 'incident') { Receive-IncidentConsole $p.genre }
        elseif ($p.quoi -eq 'rouvrir') { Resume-ConsoleArretee }
        elseif ($p.quoi -eq 'reglage') { $script:Reglages['Animations'] = $p.valeur }
        if (-not $script:Console.Vue -and $script:Console.Possible) { $script:Console.Vue = 'vue'; $script:Console.Pret = $true }   # (la page la recrée)
        $etapes += [ordered]@{ pas = $p; possible = [bool]$script:Console.Possible; arretee = [bool]$script:Console.ArreteeA; incidents = @($script:Console.Incidents).Count
            pages = @($script:Appels | Where-Object { $_ -eq 'page-console' }).Count; journal = @($script:Journal) }
    }
    $casIncidents.Add([ordered]@{ nom = $Nom; etapes = $etapes })
}
function P([string]$Quoi, [double]$Attendre = 1, [string]$Genre = 'RenderProcessExited', $Valeur = $null) { [ordered]@{ quoi = $Quoi; attendre = $Attendre; genre = $Genre; valeur = $Valeur } }
Add-CasIncidents 'sans gravité' @((P 'incident' 1 'GpuProcessExited'), (P 'incident' 1 'UtilityProcessExited'))
Add-CasIncidents 'trois redémarrages, puis l''accueil classique' @((P 'incident'), (P 'incident' 60), (P 'incident' 60 'BrowserProcessExited'), (P 'incident' 60 'RenderProcessUnresponsive'))
Add-CasIncidents 'les incidents de plus de 10 minutes ne comptent plus' @((P 'incident'), (P 'incident' 30), (P 'incident' 30), (P 'incident' 601), (P 'incident' 1))
Add-CasIncidents 'rouvert avant 10 minutes : pas de nouvel essai ; après : réessayée' @((P 'incident'), (P 'incident' 1), (P 'incident' 1), (P 'incident' 1), (P 'rouvrir' 300), (P 'rouvrir' 299), (P 'rouvrir' 2), (P 'incident' 1))
Add-CasIncidents 'réessayée seulement si possible' @((P 'incident'), (P 'incident' 1), (P 'incident' 1), (P 'incident' 1), (P 'reglage' 1 '' 'aucune'), (P 'rouvrir' 700), (P 'reglage' 1 '' 'completes'), (P 'rouvrir' 700))
Remove-Item function:Update-PageConsole
. ([scriptblock]::Create(((Get-AstModule 'console.ps1').Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Update-PageConsole' }, $true)).Extent.Text))

# ---------------------------------------------------------------------------------------------------------------
# 6. Quelle page montrer (Update-PageConsole)
# ---------------------------------------------------------------------------------------------------------------
$casPage = New-Object Collections.Generic.List[object]
function Add-CasPage([string]$Nom, $M) {
    $null = Initialize-Cas $M
    Update-PageConsole
    $casPage.Add([ordered]@{ nom = $Nom; entree = $M; notes = (Get-Notes); final = (Get-EtatFinal) })
}
function MondePage([string]$Page, $Console, $Vue = $null, [string]$Onglet = '') {
    $p = [ordered]@{}; if ($Onglet) { $p.'onglet-parametres' = $Onglet }
    [ordered]@{ applis = $TOUTES; partage = $p; page = $Page; console = $Console; vue = $Vue }
}
function C([bool]$Cadre, [bool]$Pret, [string]$Derniere = '', [string]$Ejecter = '', [bool]$Parametres = $false, [bool]$Possible = $true, [bool]$Quittee = $false) {
    [ordered]@{ possible = $Possible; cadre = $Cadre; pret = $Pret; derniere = $(if ($Derniere) { $Derniere } else { $null }); ejecter = $(if ($Ejecter) { $Ejecter } else { $null }); parametres = $Parametres; quittee = $Quittee }
}
Add-CasPage 'accueil, pas de cadre : il est créé (menu)' (MondePage 'accueil' (C $false $false))
Add-CasPage 'accueil, pas de cadre, retour d''une appli : créé dedans, le menu en grand à jouer' (MondePage 'accueil' (C $false $false 'evermind'))
Add-CasPage 'accueil, pas de cadre, appli fermée : la cartouche ressortira' (MondePage 'accueil' (C $false $false 'evermind' 'evermind'))
Add-CasPage 'accueil, cadre qui se charge : à jouer quand il sera prêt' (MondePage 'accueil' (C $true $false 'nevermind'))
Add-CasPage 'accueil, cadre qui se charge, rien à jouer : ce qui attendait reste' (MondePage 'accueil' (C $true $false))
Add-CasPage 'accueil, cadre prêt : reprendre, puis le menu' (MondePage 'accueil' (C $true $true 'nevermind'))
Add-CasPage 'accueil, cadre prêt, appli fermée : reprendre, puis le retour avec éjection' (MondePage 'accueil' (C $true $true 'nevermind' 'nevermind'))
Add-CasPage 'accueil, Paramètres demandés, cadre prêt' (MondePage 'accueil' (C $true $true '' '' $true) $null 'son')
Add-CasPage 'accueil, Paramètres demandés, pas de cadre : tout de suite' (MondePage 'accueil' (C $false $false 'evermind' '' $true) $null 'maj')
Add-CasPage 'accueil, Paramètres demandés, onglet inconnu : général' (MondePage 'accueil' (C $true $true '' '' $true) $null 'inconnu')
Add-CasPage 'une appli : pause, quittée' (MondePage 'evermind' (C $true $true '' '' $true))
Add-CasPage 'une appli, déjà quittée : la minute continue' (MondePage 'evermind' (C $true $true '' '' $false $true $true))
Add-CasPage 'une appli, cadre qui se charge : pas d''ordre, quittée' (MondePage 'evermind' (C $true $false))
Add-CasPage 'une appli, pas de cadre' (MondePage 'nevermind' (C $false $false))
Add-CasPage 'les Paramètres (page) : ils restent demandés' (MondePage 'parametres' (C $true $true '' '' $true))
Add-CasPage 'accueil, Mindset caché : pause' (MondePage 'accueil' (C $true $true 'evermind') ([ordered]@{ visible = $false }))
Add-CasPage 'accueil, Mindset réduit : pause' (MondePage 'accueil' (C $true $true) ([ordered]@{ reduite = $true }))
Add-CasPage 'console impossible : rien' (MondePage 'accueil' (C $false $false 'evermind' '' $false $false))

# ---------------------------------------------------------------------------------------------------------------
# 7. Ce que la scène demande (Receive-MessageConsole)
# ---------------------------------------------------------------------------------------------------------------
$casMessages = New-Object Collections.Generic.List[object]
function Add-CasMessage([string]$Nom, $M, [string]$Json) {
    $null = Initialize-Cas $M
    $e = $null
    try { Receive-MessageConsole $Json } catch { $e = $_.Exception.Message }
    $casMessages.Add([ordered]@{ nom = $Nom; entree = $M; message = $Json; erreur = $e; notes = (Get-Notes); final = (Get-EtatFinal) })
}
function MondeMsg($Partage = @{}, $Console = (C $true $true), $Reglages = @{}, [string]$Page = 'accueil', [bool]$Change = $false) {
    $p = [ordered]@{ installations = [ordered]@{ nevermind = (Inst '2.0.1' $true 'Nevermind'); evermind = (Inst '0.15.0' $true 'Evermind') } }
    foreach ($k in $Partage.Keys) { $p[$k] = $Partage[$k] }
    [ordered]@{ applis = $TOUTES; partage = $p; console = $Console; reglages = $Reglages; page = $Page; actualiser_change = $Change }
}
Add-CasMessage 'prête : ce qui attendait est joué' ([ordered]@{ applis = $TOUTES; partage = @{}; console = (C $true $false) }) '{"type":"pret"}'
Add-CasMessage 'erreur du script (espaces)' (MondeMsg) '{"type":"erreur","texte":"  x is\n not\tdefined (ligne 12) "}'
Add-CasMessage 'trop long : ignoré' (MondeMsg) ('{"type":"erreur","texte":"' + ('a' * 2000) + '"}')
Add-CasMessage 'juste 2000 : pris' (MondeMsg) ('{"type":"erreur","texte":"' + ('a' * (2000 - 28)) + '"}')
Add-CasMessage 'réglage, Paramètres ouverts' (MondeMsg @{} (C $true $true '' '' $true)) '{"type":"reglage","quoi":"majauto","valeur":true,"id":""}'
Add-CasMessage 'réglage, Paramètres fermés : ignoré' (MondeMsg) '{"type":"reglage","quoi":"theme","valeur":"neon"}'
Add-CasMessage 'afficher : l''appli prend la place' (MondeMsg) '{"type":"afficher","id":"evermind"}'
Add-CasMessage 'afficher : id en majuscules' (MondeMsg) '{"type":"afficher","id":"EVERMIND"}'
Add-CasMessage 'afficher : appli inconnue' (MondeMsg) '{"type":"afficher","id":"inconnue"}'
Add-CasMessage 'afficher : id mal écrit' (MondeMsg) '{"type":"afficher","id":"../evermind"}'
Add-CasMessage 'ouvrir une appli fermée (cachée : version assez récente)' (MondeMsg) '{"type":"action","action":"ouvrir","id":"evermind"}'
Add-CasMessage 'ouvrir une appli fermée (version trop ancienne : normale)' (MondeMsg ([ordered]@{ installations = [ordered]@{ evermind = (Inst '0.13.0' $true 'Evermind') } })) '{"type":"action","action":"ouvrir","id":"evermind"}'
Add-CasMessage 'ouvrir une appli sans « CacheDepuis »' (MondeMsg) '{"type":"action","action":"ouvrir","id":"nevermind"}'
Add-CasMessage 'ouvrir une appli déjà ouverte : pas relancée' (MondeMsg ([ordered]@{ ouvertes = [ordered]@{ evermind = $true } })) '{"type":"action","action":"ouvrir","id":"evermind"}'
Add-CasMessage 'ouvrir une appli pas installée : rien' (MondeMsg) '{"type":"action","action":"ouvrir","id":"mindcare"}'
Add-CasMessage 'ouvrir, scène pas prête : rien n''est joué' (MondeMsg @{} (C $true $false)) '{"type":"action","action":"ouvrir","id":"evermind"}'
Add-CasMessage 'installer' (MondeMsg) '{"type":"action","action":"installer","id":"mindcare"}'
Add-CasMessage 'installer une copie trouvée : prise en charge' (MondeMsg ([ordered]@{ trouvees = [ordered]@{ mindcare = 'C:\Ancien\Mindcare' } })) '{"type":"action","action":"installer","id":"mindcare"}'
Add-CasMessage 'installer une appli déjà installée : rien' (MondeMsg) '{"type":"action","action":"installer","id":"evermind"}'
Add-CasMessage 'mettre à jour une appli' (MondeMsg) '{"type":"action","action":"maj","id":"evermind"}'
Add-CasMessage 'mettre à jour Mindset (prêt)' (MondeMsg ([ordered]@{ mindset = [ordered]@{ maj = [ordered]@{ version = '3.1.0'; prete = $true } } })) '{"type":"action","action":"maj","id":"mindset"}'
Add-CasMessage 'mettre à jour Mindset (rien de prêt)' (MondeMsg) '{"type":"action","action":"maj","id":"mindset"}'
Add-CasMessage 'confidentialité' (MondeMsg) '{"type":"action","action":"confidentialite","id":"cafe-creme"}'
Add-CasMessage 'confidentialité sans appli : rien' (MondeMsg) '{"type":"action","action":"confidentialite"}'
Add-CasMessage 'fermer une appli accrochée (dans la fente)' (MondeMsg ([ordered]@{ accrochees = [ordered]@{ evermind = [ordered]@{ etat = 'affiche'; pid = 12 } } }) ([ordered]@{ possible = $true; cadre = $true; pret = $true; en_fente = 'evermind' })) '{"type":"action","action":"fermer","id":"evermind"}'
Add-CasMessage 'fermer une appli ouverte à côté' (MondeMsg ([ordered]@{ ouvertes = [ordered]@{ nevermind = $true }; accrochees = [ordered]@{ nevermind = [ordered]@{ etat = 'cachee' } } })) '{"type":"action","action":"fermer","id":"nevermind"}'
Add-CasMessage 'fermer une appli fermée : l''éjection seulement' (MondeMsg) '{"type":"action","action":"fermer","id":"nevermind"}'
Add-CasMessage 'Paramètres' (MondeMsg ([ordered]@{ 'onglet-parametres' = 'son' })) '{"type":"action","action":"parametres"}'
Add-CasMessage 'Paramètres fermés' (MondeMsg @{} (C $true $true '' '' $true)) '{"type":"action","action":"parametresFermes"}'
Add-CasMessage 'Actualiser : une recherche part' (MondeMsg @{} (C $true $true) @{} 'accueil' $true) '{"type":"action","action":"actualiser"}'
Add-CasMessage 'Actualiser : tout vient d''être vérifié' (MondeMsg @{} (C $true $true) @{} 'accueil' $false) '{"type":"action","action":"actualiser"}'
Add-CasMessage 'pastille : oui' (MondeMsg @{} (C $true $true) ([ordered]@{ MajAuto = $false })) '{"type":"action","action":"majAuto","valeur":true}'
Add-CasMessage 'pastille : non' (MondeMsg) '{"type":"action","action":"majAuto","valeur":false}'
Add-CasMessage 'pastille, recherche coupée : rien ne change' (MondeMsg @{} (C $true $true) ([ordered]@{ VerifVersions = $false })) '{"type":"action","action":"majAuto","valeur":true}'
Add-CasMessage 'pastille : valeur absente (non)' (MondeMsg) '{"type":"action","action":"majAuto"}'
Add-CasMessage 'réglages des mises à jour' (MondeMsg) '{"type":"action","action":"majReglages"}'
Add-CasMessage 'tout mettre à jour : la première' (MondeMsg ([ordered]@{ publications = [ordered]@{ evermind = (Pub '0.16.0'); nevermind = (Pub '2.1.0') } })) '{"type":"action","action":"majTout"}'
Add-CasMessage 'tout mettre à jour : tout est à jour' (MondeMsg) '{"type":"action","action":"majTout"}'
Add-CasMessage 'veille' (MondeMsg) '{"type":"action","action":"veille"}'
Add-CasMessage 'action inconnue' (MondeMsg) '{"type":"action","action":"formater","id":"evermind"}'
Add-CasMessage 'type inconnu' (MondeMsg) '{"type":"autre","id":"evermind"}'
Add-CasMessage 'id trop long' (MondeMsg) ('{"type":"action","action":"ouvrir","id":"' + ('a' * 31) + '"}')

# ---------------------------------------------------------------------------------------------------------------
# Écriture
# ---------------------------------------------------------------------------------------------------------------
function Save-Juge([string]$Nom, $Contenu) {
    $f = Join-Path $sortie $Nom
    if ($Contenu -is [array]) { foreach ($x in $Contenu) { try { $null = ConvertTo-Json -InputObject $x -Depth 14 } catch { throw "$Nom, cas « $($x.nom) » : $($_.Exception.Message)" } } }
    $texte = [string](ConvertTo-Json -InputObject $Contenu -Depth 14)
    [IO.File]::WriteAllText($f, $texte, (New-Object Text.UTF8Encoding $false))
    Write-Host "  $Nom" -ForegroundColor Green
}
try {
    Write-Host 'Juges de la console :'
    Save-Juge 'etat-applis.json' ($casEtat.ToArray())
    Save-Juge 'etat-maj.json' ($casMaj.ToArray())
    Save-Juge 'theme.json' ($casTheme.ToArray())
    Save-Juge 'images-animees.json' ($casAnime.ToArray())
    Save-Juge 'regles.json' $casRegles
    Save-Juge 'incidents.json' ($casIncidents.ToArray())
    Save-Juge 'page.json' ($casPage.ToArray())
    Save-Juge 'messages.json' ($casMessages.ToArray())
    Write-Host "$($casEtat.Count + $casMaj.Count + $casTheme.Count + $casAnime.Count + $casRegles.quand.Count + $casRegles.jeu.Count + $casRegles.avancee.Count + $casRegles.incident.Count + $casIncidents.Count + $casPage.Count + $casMessages.Count) cas écrits dans $sortie"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
