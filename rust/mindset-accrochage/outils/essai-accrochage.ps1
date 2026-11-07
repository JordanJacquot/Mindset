# Essai RÉEL de l'accrochage (bloc mindset-accrochage), à lancer SEULEMENT sur un bureau Windows à part :
#
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '<ce fichier>' -Arguments "-Mindset '<Mindset.exe d'essai>' -Nevermind '<Mindset.exe d'essai de Nevermind>' -Essai '<essai_reel.exe>' -Racine '<dossier d'essai>'" -Secondes 240
#
# Tout est lancé ici, sur ce bureau, et seulement des constructions d'essai (refusées sinon) :
#  - la construction d'essai de Mindset (option cargo « essai », dossier d'essai, verrous d'essai) : une vraie fenêtre
#    Tauri avec sa page WebView2 ; son propre bloc d'accrochage ne fait rien (essai sans MINDSET_INTEGRATION_TEST) ;
#  - une fenêtre WPF d'essai, « Forêt » (fenetre-wpf-essai.ps1), cachée au départ ;
#  - une fenêtre Win32 de classe HwndWrapper[...] peinte par GDI, « Café crème » (fenetre-gdi-essai.ps1), cachée : son dessin
#    se lit sur l'image, contrairement à celui de WPF ;
#  - la construction d'essai de Nevermind (Tauri), lancée cachée (-Demarrage), avec ses dossiers d'essai ;
#  - essai_reel.exe (examples\essai_reel.rs) : le vrai bloc et le vrai Windows, qui accroche les deux applis dans la
#    fenêtre de Mindset et vérifie sur l'image de la fenêtre qu'elles sont VISIBLES par-dessus la page.
# Les images vont dans <Racine>\images. À la fin, tout ce qui a été lancé est arrêté par son numéro de processus.
param(
    [Parameter(Mandatory = $true)][string]$Mindset,
    [Parameter(Mandatory = $true)][string]$Nevermind,
    [Parameter(Mandatory = $true)][string]$Essai,
    [Parameter(Mandatory = $true)][string]$Racine
)
$ErrorActionPreference = 'Stop'
$echecs = 0
function Ok([string]$t) { Write-Output "OK : $t" }
function Echec([string]$t) { Write-Output "ÉCHEC : $t"; $script:echecs++ }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class EssaiAccrochage
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static long Trouver(int pid, string classe, string titre)
    {
        long r = 0;
        EnumWindows(delegate (IntPtr h, IntPtr x) {
            int p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            if ((classe == "" ? c.ToString().StartsWith("HwndWrapper") : c.ToString() == classe) && t.ToString() == titre) { r = h.ToInt64(); return false; }
            return true;
        }, IntPtr.Zero);
        return r;
    }
}
'@

function Test-Essai([string]$Exe, [string]$Marque) {
    $t = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Exe))
    if (-not $t.Contains($Marque)) { Write-Output "ÉCHEC : $Exe n'est pas une construction d'essai : rien n'est lancé."; exit 1 }
}
$Mindset = (Resolve-Path -LiteralPath $Mindset).Path
$Nevermind = (Resolve-Path -LiteralPath $Nevermind).Path
$Essai = (Resolve-Path -LiteralPath $Essai).Path
Test-Essai $Mindset 'MINDSET_ESSAI_DONNEES'
Test-Essai $Nevermind 'NEVERMIND_ESSAI_NOM'
if (Test-Path -LiteralPath $Racine) { Remove-Item -LiteralPath $Racine -Recurse -Force }
$images = Join-Path $Racine 'images'
New-Item -ItemType Directory -Force -Path $images | Out-Null

# Un programme sans console, sur ce bureau ; les variables d'environnement données ne valent que pour lui
function Start-Essai([string]$Exe, [string]$Arguments, [string]$Dossier, [hashtable]$Env = @{}, [switch]$Sortie) {
    $psi = New-Object Diagnostics.ProcessStartInfo $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Dossier
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    if ($Sortie) { $psi.RedirectStandardOutput = $true; $psi.StandardOutputEncoding = [Text.Encoding]::UTF8 }
    [Diagnostics.Process]::Start($psi)
}
function Attendre([scriptblock]$Condition, [int]$Secondes) {
    $fin = (Get-Date).AddSeconds($Secondes)
    while ((Get-Date) -lt $fin) { $r = & $Condition; if ($r) { return $r }; Start-Sleep -Milliseconds 200 }
    $null
}

$lances = New-Object System.Collections.Generic.List[int]
try {
    # 1. Mindset (construction d'essai)
    $m = Start-Essai $Mindset '' $env:SystemRoot @{ MINDSET_ESSAI_DONNEES = (Join-Path $Racine 'mindset'); MINDSET_ESSAI_NOM = "accrochage-$PID" }
    $lances.Add($m.Id)
    $hm = Attendre { $x = [EssaiAccrochage]::Trouver($m.Id, 'Tauri Window', 'Mindset'); if ($x) { $x } } 40
    if (-not $hm) { Echec 'la fenêtre de Mindset d''essai'; exit 1 }
    Ok "fenêtre de Mindset d'essai ($hm)"
    Start-Sleep -Seconds 4   # (sa page se charge)

    # 2. Forêt (WPF), cachée
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $wpf = Join-Path $PSScriptRoot 'fenetre-wpf-essai.ps1'
    $w = Start-Essai $ps "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wpf`" -Secondes 200 -Journal `"$Racine\foret.txt`"" $env:SystemRoot
    $lances.Add($w.Id)
    $hw = Attendre { $x = [EssaiAccrochage]::Trouver($w.Id, '', 'Forêt'); if ($x) { $x } } 40
    if ($hw) { Ok "fenêtre WPF « Forêt » ($hw), cachée (comme lancée avec -Demarrage)" } else { Echec 'la fenêtre WPF « Forêt »' }

    # 2 bis. Café crème (Win32, classe HwndWrapper[...], peinte par GDI : la preuve sur l'image), cachée
    $gdi = Join-Path $PSScriptRoot 'fenetre-gdi-essai.ps1'
    $c = Start-Essai $ps "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$gdi`" -Secondes 200" $env:SystemRoot
    $lances.Add($c.Id)
    $hc = Attendre { $x = [EssaiAccrochage]::Trouver($c.Id, '', 'Café crème'); if ($x) { $x } } 40
    if ($hc) { Ok "fenêtre « Café crème » ($hc), cachée" } else { Echec 'la fenêtre « Café crème »' }

    # 3. Nevermind (Tauri, construction d'essai), lancé caché
    $prog = Join-Path $Racine 'nevermind\Programmes\Nevermind'
    $donnees = Join-Path $Racine 'nevermind\Donnees\Nevermind'
    $local = Join-Path $Racine 'nevermind\Local'
    New-Item -ItemType Directory -Force -Path $prog, $donnees, (Join-Path $local 'Mindset') | Out-Null
    $exeNm = Join-Path $prog 'Mindset.exe'
    Copy-Item -LiteralPath $Nevermind -Destination $exeNm
    $suite = [ordered]@{ theme = 'neon'; applis = [ordered]@{ nevermind = $prog }; modifie = (Get-Date -Format s) }
    [IO.File]::WriteAllText((Join-Path $local 'Mindset\suite.json'), ($suite | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $n = Start-Essai $exeNm '-Demarrage' $prog @{ NEVERMIND_ESSAI_DONNEES = $donnees; NEVERMIND_ESSAI_LOCAL = $local; NEVERMIND_ESSAI_NOM = "accrochage-$PID" }
    $lances.Add($n.Id)
    $hn = Attendre { $x = [EssaiAccrochage]::Trouver($n.Id, 'Tauri Window', 'Nevermind'); if ($x) { $x } } 40
    if ($hn) { Ok "fenêtre Tauri « Nevermind » ($hn), lancée cachée" } else { Echec 'la fenêtre « Nevermind »' }
    Start-Sleep -Seconds 6   # (sa page se charge, cachée)

    # 4. L'accrochage, par le vrai bloc
    $arguments = @($hm, "`"$images`"")
    if ($hw) { $arguments += "`"$($w.Id):Forêt:foret`"" }
    if ($hc) { $arguments += "`"$($c.Id):Café crème:cafe-creme`"" }
    if ($hn) { $arguments += "`"$($n.Id):Nevermind:nevermind`"" }
    $e = Start-Essai $Essai ($arguments -join ' ') $env:SystemRoot @{} -Sortie
    $lances.Add($e.Id)
    $texte = $e.StandardOutput.ReadToEnd()
    $null = $e.WaitForExit(120000)
    Write-Output $texte.TrimEnd()
    if ($e.ExitCode -ne 0) { $script:echecs++ }
    if (Test-Path -LiteralPath "$Racine\foret.txt") { Write-Output "Journal de Forêt :"; Get-Content -LiteralPath "$Racine\foret.txt" -Encoding UTF8 }
    Write-Output "Images : $images"
    foreach ($f in Get-ChildItem -LiteralPath $images -Filter *.png) { Write-Output "     $($f.FullName)" }
} finally {
    foreach ($id in $lances) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {} }
}
Write-Output "$echecs échec(s) au total"
exit $(if ($echecs) { 1 } else { 0 })
