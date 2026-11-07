# Mindset en Rust : un exe livré ne connaît pas la construction d'essai (option cargo « essai » de mindset-appli et du
# désinstalleur) ni le mode test de la version PowerShell : ni MINDSET_ESSAI_DONNEES / MINDSET_ESSAI_NOM (tout dans un
# dossier d'essai), ni MINDSET_TEST, MINDSET_CAPTURE, MINDSET_SANS_RESEAU, MINDSET_DONNEES (version PowerShell), ni la
# capture de la fenêtre ou les actions pilotées de l'essai (capture.demande, actions.demande), ni -EssaiFenetre du
# désinstalleur. Sans ça, une variable d'environnement posée par n'importe quel programme changerait ce que fait Mindset
# chez l'utilisateur (docs\regles-tauri.md : aucune variable ni option cachée dans l'exe livré). Le test cherche ces
# noms dans l'exe, en texte simple et en UTF-16, sans rien lancer (comme celui de Nevermind).
#
#   & '.\outils\verifier-sans-essai.ps1' -Exe <Mindset.exe>
#
# Code 0 : aucun nom trouvé ; 1 : un nom trouvé (ou exe introuvable). Contre-épreuve (tests.yml) : sur l'exe de la
# construction d'essai, il doit rendre 1.
param([Parameter(Mandatory = $true)][string]$Exe)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { Write-Host "Introuvable : $Exe"; exit 1 }
$octets = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Exe).Path)
# (chaque octet tel quel : les noms cherchés sont en ASCII)
$simple = [Text.Encoding]::GetEncoding(28591).GetString($octets)
$noms = 'MINDSET_ESSAI', 'MINDSET_TEST', 'MINDSET_CAPTURE', 'MINDSET_SANS_RESEAU', 'MINDSET_DONNEES', 'capture.demande', 'actions.demande', 'EssaiFenetre'
$trouves = @()
foreach ($n in $noms) {
    $large = ($n.ToCharArray() | ForEach-Object { "$_`0" }) -join ''
    if ($simple.Contains($n) -or $simple.Contains($large)) { $trouves += $n }
}
if ($trouves.Count) { Write-Host "$Exe contient la construction d'essai : $($trouves -join ', ')"; exit 1 }
Write-Host "$Exe : aucune trace de la construction d'essai ($($noms -join ', '))."
exit 0
