# Essai des écrans noirs du 11 et 12/11/2026 (Mindset 3.0.4). À lancer SEULEMENT sur un bureau Windows à part
# (sur-bureau.ps1). Tout est sous -Base\<Nom> ; seuls les programmes lancés ici sont arrêtés.
# -Exe : un Mindset.exe construit en mode essai (feature « essai »).
#
# Cause trouvée le 12/11 : la page de WebView2 n'était remise visible que si Windows changeait la fenêtre ; quand
# Mindset se montrait lui-même (icône de l'horloge, nouveau lancement), elle restait « cachée » : écran noir, alors que
# le journal disait « Console 3D prête ». Échec si une capture d'après le retour est sombre à plus de 90 %.
#
#  -Retour 'signal'  : Mindset est rendu comme par un clic sur l'icône de l'horloge ou un nouveau lancement
#                      (le signal d'essai Local\MindsetEssai-<nom>-Afficher, donc Effet::Fenetre(Montrer)) ;
#  -Retour 'windows' : Mindset est rendu par Windows lui-même (ShowWindow SW_RESTORE, comme un clic dans la barre des
#                      tâches sur une fenêtre réduite).
#  -Icone 1 : l'icône de l'horloge existe (comme chez Jordan) : réduit, Mindset est caché près de l'horloge.
param([string]$Exe, [string]$Nom = 'essai', [string]$Retour = 'signal', [int]$Icone = 1, [string]$Base = (Join-Path $env:TEMP 'mindset-essai-ecran-noir'))
$ErrorActionPreference = 'Stop'
$Sortie = Join-Path $Base $Nom
$Depot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:Noirs = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $Sortie) { Remove-Item -LiteralPath $Sortie -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Sortie | Out-Null

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
public static class SondeNoir
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    public static long Trouver(int pid, string titre)
    {
        long r = 0;
        EnumWindows(delegate (IntPtr h, IntPtr x) {
            int p; GetWindowThreadProcessId(h, out p);
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            if (p == pid && c.ToString().StartsWith("Tauri Window") && t.ToString() == titre) { r = (long)h; return false; }
            return true;
        }, IntPtr.Zero);
        return r;
    }
    // La part de pixels sombres (max(R,V,B) < 30) et la luminosité moyenne, au centre de l'image (sans le cadre)
    public static string Mesure(string fichier)
    {
        using (var b = new Bitmap(fichier))
        {
            int x0 = b.Width / 5, x1 = b.Width * 4 / 5, y0 = b.Height / 5, y1 = b.Height * 4 / 5;
            long n = 0, sombres = 0; double lum = 0;
            for (int y = y0; y < y1; y += 3) for (int x = x0; x < x1; x += 3)
            {
                var c = b.GetPixel(x, y); int m = Math.Max(c.R, Math.Max(c.G, c.B));
                if (m < 30) sombres++; lum += (c.R + c.G + c.B) / 3.0; n++;
            }
            return string.Format("{0:N1} % sombres, luminosité {1:N1}", 100.0 * sombres / n, lum / n);
        }
    }
}
'@

$t0 = Get-Date
function Note([string]$t) { Write-Output ("{0:HH:mm:ss.f} (+{1,6:N1} s) {2}" -f (Get-Date), ((Get-Date) - $t0).TotalSeconds, $t) }
$u8 = New-Object Text.UTF8Encoding $false
function Ecrire([string]$f, [string]$t) { New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null; [IO.File]::WriteAllText($f, $t, $u8) }

# Les données d'essai : Mindset, et un Nevermind installé mais pas ouvert (sa page : l'écran « Ouvrir »)
$racine = Join-Path $Sortie 'racine'
$prog = Join-Path $racine 'Programmes'
$fichiers = Join-Path $prog 'Mindset\fichiers'
New-Item -ItemType Directory -Force -Path $fichiers, (Join-Path $racine 'Local\Mindset') | Out-Null
foreach ($f in 'apps.json', 'apps-liste.txt', 'Mindset.ico') { Copy-Item -LiteralPath (Join-Path $Depot "Mindset\fichiers\$f") -Destination $fichiers }
Copy-Item -LiteralPath (Join-Path $Depot 'Mindset\fichiers\cles-publiques') -Destination $fichiers -Recurse
$pn = Join-Path $prog 'Nevermind'
Ecrire (Join-Path $pn 'Nevermind.exe') 'essai'
Ecrire (Join-Path $pn 'Mindset.exe') 'essai'
Ecrire (Join-Path $pn 'version.json') '{ "appli": "nevermind", "version": "2.3.1" }'
$donnees = Join-Path $racine 'Donnees\Mindset'
Ecrire (Join-Path $donnees 'reglages.json') '{ "Animations": "completes", "BulleHorlogeVue": true, "VerifVersions": false, "ReduireHorloge": true }'

$lances = New-Object System.Collections.Generic.List[int]
function Get-Arbre([int]$Racine) {
    $tous = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)
    $ids = New-Object System.Collections.Generic.List[int]; $ids.Add($Racine)
    $i = 0
    while ($i -lt $ids.Count) { foreach ($p in $tous) { if ($p.ParentProcessId -eq $ids[$i] -and -not $ids.Contains([int]$p.ProcessId)) { $ids.Add([int]$p.ProcessId) } }; $i++ }
    $ids
}
function Attendre([scriptblock]$Condition, [int]$Secondes) {
    $fin = (Get-Date).AddSeconds($Secondes)
    while ((Get-Date) -lt $fin) { $r = & $Condition; if ($r) { return $r }; Start-Sleep -Milliseconds 200 }
    $null
}
function Journal { $f = Join-Path $donnees 'journal.txt'; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) } else { '' } }
function Etat { $f = Join-Path $donnees 'etat.json'; try { [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null } }
function Action([string]$Id, $Valeur) {
    $ligne = ConvertTo-Json -Compress -Depth 5 -InputObject ([ordered]@{ type = 'action'; id = $Id; valeur = $Valeur; ecran = 'accueil' })
    $f = Join-Path $donnees 'actions.demande'
    [IO.File]::WriteAllText($f, $ligne, $u8)
    [void](Attendre { -not (Test-Path -LiteralPath $f) } 10)
    Note "ACTION $Id $(ConvertTo-Json -Compress $Valeur)"
}
function Capture([string]$Quoi, [int]$Apres = 3000) {
    Start-Sleep -Milliseconds $Apres
    $png = Join-Path $donnees 'capture.png'
    if (Test-Path -LiteralPath $png) { Remove-Item -LiteralPath $png -Force }
    [IO.File]::WriteAllText((Join-Path $donnees 'capture.demande'), '1')
    if (Attendre { Test-Path -LiteralPath $png } 15) {
        Start-Sleep -Milliseconds 400
        $vers = Join-Path $Sortie "$Quoi.png"
        Copy-Item -LiteralPath $png -Destination $vers -Force
        $e = Etat
        $mesure = [SondeNoir]::Mesure($vers)
        Note ("CAPTURE {0} : {1} (page {2}, visible {3}, réduite {4}, console attente {5})" -f $Quoi, $mesure, $e._vue.page, $e._vue.visible, $e._vue.reduite, $e.console.attente)
        $part = [double]::Parse(($mesure -split ' %')[0].Replace(',', '.').Replace([char]0xA0, ' ').Replace(' ', ''), [Globalization.CultureInfo]::InvariantCulture)
        if ($part -gt 90) { $script:Noirs.Add("$Quoi ($mesure)") }
    } else { Note "CAPTURE $Quoi impossible"; $script:Noirs.Add("$Quoi (capture impossible)") }
}
function Fenetre([long]$h) { "visible=$([SondeNoir]::IsWindowVisible([IntPtr]$h)) réduite=$([SondeNoir]::IsIconic([IntPtr]$h))" }

$code = 0
try {
    $nomEssai = "noir-$PID"
    $psi = New-Object Diagnostics.ProcessStartInfo $Exe
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $env:SystemRoot
    $psi.EnvironmentVariables['MINDSET_ESSAI_DONNEES'] = $racine
    $psi.EnvironmentVariables['MINDSET_ESSAI_NOM'] = $nomEssai
    $psi.EnvironmentVariables['MINDSET_TEST_DECOR'] = 'jour'
    if ($Icone) { $psi.EnvironmentVariables['MINDSET_ESSAI_ICONE'] = '1' }
    $m = [Diagnostics.Process]::Start($psi); $lances.Add($m.Id)
    Note "Mindset d'essai lancé, pid $($m.Id), retour par « $Retour », icône $Icone"
    $h = Attendre { $x = [SondeNoir]::Trouver($m.Id, 'Mindset'); if ($x) { $x } } 40
    Note "fenêtre $h ($(Fenetre $h))"
    [void](Attendre { (Journal) -match 'Console 3D prête' } 40)
    Capture '1-accueil' 4000

    # Cas B : la page de Nevermind, Mindset réduit puis rendu, puis Échap (action « menu »)
    Action 'ecrans:onglet' 'nevermind'
    Capture '2-page-nevermind' 2000
    [void][SondeNoir]::ShowWindow([IntPtr]$h, 6)   # SW_MINIMIZE (comme le clic sur le bouton « Réduire »)
    Note "réduit par ShowWindow(SW_MINIMIZE)"
    Start-Sleep -Seconds 3
    Note "après la réduction : $(Fenetre $h)"
    if ($Retour -eq 'signal') {
        $ev = [Threading.EventWaitHandle]::OpenExisting("Local\MindsetEssai-$nomEssai-Afficher")
        [void]$ev.Set(); $ev.Dispose()
        Note "signal d'essai Afficher levé (comme un clic sur l'icône ou un nouveau lancement)"
    } else {
        [void][SondeNoir]::ShowWindow([IntPtr]$h, 9)   # SW_RESTORE
        Note "rendu par ShowWindow(SW_RESTORE)"
    }
    Start-Sleep -Seconds 2
    Note "après le retour : $(Fenetre $h)"
    Capture '3-page-nevermind-rendue' 2000
    Action 'menu' $null
    [void](Attendre { (Journal) -split "`n" | Select-Object -Last 3 | Where-Object { $_ -match 'Console 3D prête' } } 20)
    Capture '4-echap-menu' 5000

    # Cas A : Mindset réduit, la page revient à l'accueil pendant qu'il est caché, puis il est rendu
    [void][SondeNoir]::ShowWindow([IntPtr]$h, 6)
    Note "réduit de nouveau"
    Start-Sleep -Seconds 3
    Note "après la réduction : $(Fenetre $h)"
    if ($Retour -eq 'signal') {
        $ev = [Threading.EventWaitHandle]::OpenExisting("Local\MindsetEssai-$nomEssai-Afficher")
        [void]$ev.Set(); $ev.Dispose()
        Note "signal d'essai Afficher levé"
    } else {
        [void][SondeNoir]::ShowWindow([IntPtr]$h, 9)
        Note "rendu par ShowWindow(SW_RESTORE)"
    }
    Start-Sleep -Seconds 2
    Note "après le retour : $(Fenetre $h)"
    Capture '5-accueil-rendu' 6000

    Write-Output '--- journal ---'
    Journal
    if ($script:Noirs.Count) { Write-Output "ÉCHEC : écran noir sur $($script:Noirs -join ' ; ')"; $code = 1 } else { Write-Output 'OK : aucun écran noir' }
} catch {
    Note "ERREUR : $_ (ligne $($_.InvocationInfo.ScriptLineNumber))"; $code = 1
} finally {
    foreach ($id in $lances) { foreach ($x in (Get-Arbre $id)) { try { Stop-Process -Id $x -Force -ErrorAction SilentlyContinue } catch {} } }
}
exit $code
