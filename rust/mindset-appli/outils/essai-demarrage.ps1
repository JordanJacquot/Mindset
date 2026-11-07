# Essai de démarrage de Mindset en Rust, avec la CONSTRUCTION D'ESSAI de Mindset.exe (option cargo « essai ») et un
# dossier d'essai. À lancer SEULEMENT sur un bureau Windows à part :
#
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '<ce fichier>' -Arguments "-Exe '<Mindset.exe d'essai>' -Racine '<dossier d'essai>'" -Secondes 120
#
# La construction d'essai ne lit pas HKLM, ne lance rien, n'ouvre rien, n'utilise que le dossier d'essai et des verrous
# d'essai (Local\MindsetEssai-<nom>-...). Vérifié, dans l'ordre :
#  1. une fenêtre « Tauri Window » titrée exactement « Mindset », sans propriétaire, montrée ;
#  2. la page chargée, l'écran prêt, l'état envoyé (etat.json, avec _vue) ;
#  3. EBWebView seulement sous <essai>\Donnees\WebView2-Tauri\Mindset ;
#  4. un second lancement s'en va tout de suite (un seul Mindset à la fois) et ramène le premier ;
#  5. la capture de la fenêtre (capture.png) ;
#  6. la croix ne ferme pas Mindset (le bloc « près de l'horloge » décide) ; arrêt par numéro de processus.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Racine
)
$ErrorActionPreference = 'Stop'
$echecs = New-Object System.Collections.Generic.List[string]
function Ok([string]$t) { Write-Output "OK : $t" }
function Echec([string]$t) { Write-Output "ÉCHEC : $t"; $echecs.Add($t) }
function Verifier([bool]$c, [string]$t) { if ($c) { Ok $t } else { Echec $t } }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class EssaiFenetreMs
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public static string Classe(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    public static string Titre(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
    public static IntPtr[] Fenetres(int pid)
    {
        var l = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr x) { int p; GetWindowThreadProcessId(h, out p); if (p == pid) l.Add(h); return true; }, IntPtr.Zero);
        return l.ToArray();
    }
}
'@

$Exe = (Resolve-Path -LiteralPath $Exe).Path
$texte = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Exe))
if ($texte -notmatch 'MINDSET_ESSAI_DONNEES') { Write-Output "ÉCHEC : $Exe n'est pas la construction d'essai"; exit 1 }
if (Test-Path -LiteralPath $Racine) { Remove-Item -LiteralPath $Racine -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Racine | Out-Null
$donnees = Join-Path $Racine 'Donnees\Mindset'
$env:MINDSET_ESSAI_DONNEES = $Racine
$env:MINDSET_ESSAI_NOM = "fondations-$PID"

function Attendre([scriptblock]$Condition, [int]$Secondes) {
    $fin = (Get-Date).AddSeconds($Secondes)
    while ((Get-Date) -lt $fin) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 200 }
    $false
}
function Journal { $f = Join-Path $donnees 'journal.txt'; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { '' } }

$debut = Get-Date
$p = Start-Process -FilePath $Exe -WorkingDirectory $env:SystemRoot -PassThru
try {
    $fenetre = [IntPtr]::Zero
    $vue = Attendre { foreach ($h in [EssaiFenetreMs]::Fenetres($p.Id)) { if ([EssaiFenetreMs]::Classe($h) -eq 'Tauri Window' -and [EssaiFenetreMs]::Titre($h) -ceq 'Mindset') { $script:fenetre = $h; return $true } }; $false } 30
    Verifier $vue 'fenêtre « Tauri Window » titrée « Mindset »'
    if ($vue) {
        Verifier ([EssaiFenetreMs]::GetWindow($fenetre, 4) -eq [IntPtr]::Zero) 'sans propriétaire'
        Verifier ([EssaiFenetreMs]::IsWindowVisible($fenetre)) 'montrée (lancée sans -Demarrage)'
    }
    Verifier (Attendre { (Journal) -match 'Écran prêt' } 30) "l'écran est prêt"
    Write-Output ("     prêt en {0:N1} s" -f ((Get-Date) - $debut).TotalSeconds)
    Verifier ((Journal) -match 'Écran : page chargée http://tauri.localhost/index.html') 'page chargée'
    Verifier ((Journal) -match 'menu du clic droit, raccourcis du navigateur, saisie automatique') 'réglages de WebView2 coupés'
    $etat = Join-Path $donnees 'etat.json'
    Verifier (Attendre { Test-Path -LiteralPath $etat } 10) 'état envoyé (etat.json)'
    if (Test-Path -LiteralPath $etat) {
        $e = [IO.File]::ReadAllText($etat) | ConvertFrom-Json
        Verifier ($e._vue.page -eq 'accueil' -and $e._vue.version -eq '3.0.0') "_vue : page accueil, version 3.0.0"
    }
    $eb = Join-Path $Racine 'Donnees\WebView2-Tauri\Mindset\EBWebView'
    Verifier (Test-Path -LiteralPath $eb) "EBWebView sous <essai>\Donnees\WebView2-Tauri\Mindset"
    $ailleurs = @(Get-ChildItem -LiteralPath $Racine -Recurse -Directory -Filter 'EBWebView' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $eb })
    Verifier (-not $ailleurs.Count) 'aucun autre EBWebView dans le dossier d''essai'
    # 4. un second lancement
    $p2 = Start-Process -FilePath $Exe -WorkingDirectory $env:SystemRoot -PassThru
    Verifier ($p2.WaitForExit(8000)) 'un second lancement s''en va tout de suite'
    Verifier (-not $p.HasExited) 'le premier tourne toujours'
    # 5. la capture
    [IO.File]::WriteAllText((Join-Path $donnees 'capture.demande'), '1')
    $png = Join-Path $donnees 'capture.png'
    Verifier (Attendre { Test-Path -LiteralPath $png } 10) 'capture de la fenêtre'
    if (Test-Path -LiteralPath $png) { Copy-Item -LiteralPath $png -Destination (Join-Path $Racine '..\capture-fondations.png') -Force }
    # 6. la croix
    if ($fenetre -ne [IntPtr]::Zero) {
        [void][EssaiFenetreMs]::PostMessage($fenetre, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        Start-Sleep -Milliseconds 1500
        Verifier (-not $p.HasExited) 'la croix ne ferme pas Mindset (le bloc près de l''horloge décide)'
    }
    $ws = (Get-Process -Id $p.Id).WorkingSet64
    Write-Output ("     mémoire de Mindset.exe (sans WebView2) : {0:N0} Mo" -f ($ws / 1MB))
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}
Write-Output '--- journal ---'
Journal
if ($echecs.Count) { Write-Output "$($echecs.Count) échec(s)"; exit 1 }
Write-Output 'Tout est bon.'
exit 0
