# Mindset : les captures « après » des Paramètres, avec la CONSTRUCTION D'ESSAI de Mindset en Rust (option cargo
# « essai »), un onglet après l'autre. À lancer SEULEMENT sur un bureau Windows à part :
#
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '<ce fichier>' -Arguments "-Exe '<Mindset.exe d'essai>'" -Secondes 240
#
# La construction d'essai ne lit pas HKLM, ne lance rien, n'utilise que le dossier d'essai et des verrous d'essai. La
# page des Paramètres (page\parametres.css et parametres.js de ce bloc) y est mise par actions.demande (« script »),
# en attendant son branchement dans ui\ à l'intégration ; avec elle, seulement le fond de la fenêtre d'interface.xaml
# (le dégradé et ses trois lueurs, travail du bloc écrans), pour comparer à la capture WPF dans les mêmes conditions.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Sortie = 'D:\Outils\Rust\essais\parametres\captures'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scenario-captures.ps1')
$Exe = (Resolve-Path -LiteralPath $Exe).Path
if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Exe)) -notmatch 'MINDSET_ESSAI_DONNEES') { Write-Output "ÉCHEC : $Exe n'est pas la construction d'essai"; exit 1 }
$racine = 'D:\Outils\Rust\essais\parametres\apres'
if (Test-Path -LiteralPath $racine) { Remove-Item -LiteralPath $racine -Recurse -Force }
$donnees = Join-Path $racine 'Donnees\Mindset'
Initialize-ScenarioEssai $donnees (Join-Path $racine 'Local\Mindset')
# Les appareils et les mesures du faux Windows (les mêmes noms que ceux du PC, lus par la capture « avant »)
Write-TexteEssai (Join-Path $donnees 'essai-parametres.json') '{ "micros": ["Microphone (PRO X 2 LIGHTSPEED)", "Microphone (Sonic Studio Virtua", "Microphone sur casque (2- DualS"], "sorties": ["Haut-parleurs (PRO X 2 LIGHTSPE", "Realtek Digital Output (Realtek", "DELL AW2518HF (NVIDIA High Defi", "Haut-parleurs (2- DualSense Wir", "Haut-parleurs (Sonic Studio Vir", "OMEN by HP 25 (NVIDIA High Defi"], "parties": [ { "nom": "Mindset", "nombre": 1, "memoire": 125829120, "processeur": 0.4 }, { "nom": "WebView2 de la suite", "nombre": 5, "memoire": 241172480, "processeur": 1.1 } ] }'
New-Item -ItemType Directory -Force -Path $Sortie | Out-Null
$env:MINDSET_ESSAI_DONNEES = $racine
$env:MINDSET_ESSAI_NOM = "parametres-$PID"

function Attendre([scriptblock]$Condition, [int]$Secondes) {
    $fin = (Get-Date).AddSeconds($Secondes)
    while ((Get-Date) -lt $fin) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 200 }
    $false
}
function Journal { $f = Join-Path $donnees 'journal.txt'; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { '' } }
$demande = Join-Path $donnees 'actions.demande'
function Envoyer([object[]]$Lignes) {
    [void](Attendre { -not (Test-Path -LiteralPath $demande) } 10)
    [IO.File]::WriteAllText($demande, (($Lignes | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress -Depth 6 }) -join "`n"), (New-Object Text.UTF8Encoding $false))
    [void](Attendre { -not (Test-Path -LiteralPath $demande) } 10)
}

$page = Join-Path (Split-Path $PSScriptRoot -Parent) 'page'
$css = [IO.File]::ReadAllText((Join-Path $page 'parametres.css'))
$js = [IO.File]::ReadAllText((Join-Path $page 'parametres.js'))
$decor = 'background:linear-gradient(135deg,#0C0920,#06050F)'
$glows = "radial-gradient(55% 55% at 12% 5%, rgba(0,229,255,.27), rgba(0,229,255,0)), radial-gradient(45% 45% at 60% 35%, rgba(122,60,255,.15), rgba(122,60,255,0)), radial-gradient(50% 55% at 92% 90%, rgba(255,46,181,.27), rgba(255,46,181,0)), linear-gradient(135deg,#0C0920,#06050F)"
$injection = "(function(){var s=document.createElement('style');s.textContent=" + (ConvertTo-Json $css) + ";document.head.appendChild(s);var f=document.getElementById('fond');if(f){f.style.background=" + (ConvertTo-Json $glows) + ";}})();`n" + $js

$p = Start-Process -FilePath $Exe -WorkingDirectory $env:SystemRoot -PassThru
try {
    if (-not (Attendre { (Journal) -match 'Écran prêt' } 40)) { Write-Output 'ÉCHEC : écran pas prêt'; Journal; exit 1 }
    Start-Sleep -Milliseconds 800
    Envoyer @(@{ script = $injection }, @{ type = 'action'; id = 'parametres:reglage'; valeur = @{ quoi = 'animations'; valeur = 'aucune' }; ecran = 'accueil' })
    Start-Sleep -Milliseconds 1200
    $png = Join-Path $donnees 'capture.png'
    foreach ($onglet in $OngletsEssai) {
        Envoyer @(@{ type = 'action'; id = 'parametres:onglet'; valeur = $onglet; ecran = 'parametres' })
        Start-Sleep -Milliseconds $(if ($onglet -eq 'conso') { 4500 } else { 1500 })
        if (Test-Path -LiteralPath $png) { Remove-Item -LiteralPath $png -Force }
        [IO.File]::WriteAllText((Join-Path $donnees 'capture.demande'), '1')
        if (Attendre { Test-Path -LiteralPath $png } 10) {
            Start-Sleep -Milliseconds 300
            Copy-Item -LiteralPath $png -Destination (Join-Path $Sortie "apres-$onglet.png") -Force
            Write-Output "OK : apres-$onglet.png"
        } else { Write-Output "ÉCHEC : pas de capture pour $onglet" }
    }
    $etat = Join-Path $donnees 'etat.json'
    if (Test-Path -LiteralPath $etat) { Copy-Item -LiteralPath $etat -Destination (Join-Path $Sortie 'apres-etat.json') -Force }
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}
Write-Output '--- journal ---'
Journal
