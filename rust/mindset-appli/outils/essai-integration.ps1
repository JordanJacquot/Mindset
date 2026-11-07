# Essai RÉEL de l'intégration : Mindset en Rust entier (construction d'essai, option cargo « essai »), avec des applis
# d'essai, puis Mindset 2.18 (PowerShell, mode test) avec les mêmes données, pour comparer. À lancer SEULEMENT sur un
# bureau Windows à part :
#
#   & 'D:\Projets\Nevermind\rust\nevermind-appli\outils\sur-bureau.ps1' -Script '<ce fichier>' -Arguments "-Exe '<Mindset.exe d'essai>' -Nevermind '<Mindset.exe d'essai de Nevermind>' -Sortie 'D:\Outils\Rust\essais\integration'" -Secondes 900
#
# Rien ne touche le vrai PC : tout est sous <Sortie>\racine (programmes, données, faux %LOCALAPPDATA%) ; la construction
# d'essai de Mindset ne lit pas HKLM, n'a aucun réseau, ne lance rien ; l'accrochage (MINDSET_INTEGRATION_TEST) ne
# vise que les programmes du dossier d'essai ; l'icône près de l'horloge (MINDSET_ESSAI_ICONE=1) n'est permise par le bloc
# horloge que sur un bureau à part, où il n'y a pas de barre des tâches (sans icône, la croix quitte, comme zone.ps1:82) ; Mindset 2.18 tourne en mode test (MINDSET_TEST,
# MINDSET_DONNEES, MINDSET_SANS_RESEAU, données de vitrine.ps1 du bloc écrans). À la fin, tout ce qui a été lancé ici
# est arrêté par son numéro de processus (et ses descendants), rien d'autre.
#
# Fait, dans l'ordre (chaque étape : OK ou ÉCHEC, et des captures <Sortie>\apres-<scène>.png) :
#  1. Mindset démarre, l'accueil s'affiche avec les applis d'essai (Nevermind installé et ouvert, Evermind installé,
#     Mindcare pas installé), taille de la fenêtre, ligne de démarrage ;
#  2. la croix rouge et sa question, puis « Annuler » ;
#  3. les Paramètres et leurs 6 panneaux ;
#  4. la page d'Evermind (pas ouverte) et celle de Mindcare (pas installé) ;
#  5. Nevermind (construction d'essai, Tauri) accroché dans la page ;
#  6. la console 3D (Animations : complètes) ;
#  7. mémoire et processeur : accueil classique, console, fenêtre cachée ; puis les mêmes avec Mindset 2.18.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Nevermind,
    [Parameter(Mandatory = $true)][string]$Sortie,
    [string]$Depot = 'D:\Projets\_arbres\mindset-rust',
    [int]$Mesure = 20
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
public static class EssaiIntegration
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int n);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    public static string Classe(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    public static string Titre(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
    public static long Trouver(int pid, string classe, string titre)
    {
        long r = 0;
        EnumWindows(delegate (IntPtr h, IntPtr x) {
            int p; GetWindowThreadProcessId(h, out p);
            if (p == pid && (classe == "" || Classe(h).StartsWith(classe)) && Titre(h) == titre) { r = (long)h; return false; }
            return true;
        }, IntPtr.Zero);
        return r;
    }
    public static string Taille(long h)
    {
        RECT w, c, d;
        GetWindowRect((IntPtr)h, out w); GetClientRect((IntPtr)h, out c);
        int ok = DwmGetWindowAttribute((IntPtr)h, 9, out d, Marshal.SizeOf(typeof(RECT)));   // DWMWA_EXTENDED_FRAME_BOUNDS
        string vu = ok == 0 ? string.Format("{0} x {1}", d.r - d.l, d.b - d.t) : "?";
        return string.Format("{0} x {1}|{2} x {3}|{4}|{5}", w.r - w.l, w.b - w.t, c.r, c.b, vu, GetDpiForWindow((IntPtr)h));
    }
}
'@

foreach ($x in @($Exe, $Nevermind)) { if (-not (Test-Path -LiteralPath $x)) { Write-Output "ÉCHEC : $x introuvable"; exit 1 } }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$Nevermind = (Resolve-Path -LiteralPath $Nevermind).Path
if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Exe)) -notmatch 'MINDSET_ESSAI_DONNEES') { Write-Output "ÉCHEC : $Exe n'est pas la construction d'essai"; exit 1 }
if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Nevermind)) -notmatch 'NEVERMIND_ESSAI_NOM') { Write-Output "ÉCHEC : $Nevermind n'est pas la construction d'essai de Nevermind"; exit 1 }
New-Item -ItemType Directory -Force -Path $Sortie | Out-Null
$racine = Join-Path $Sortie 'racine'
if (Test-Path -LiteralPath $racine) { Remove-Item -LiteralPath $racine -Recurse -Force }
$u8 = New-Object Text.UTF8Encoding $false
function Ecrire([string]$f, [string]$t) { New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null; [IO.File]::WriteAllText($f, $t, $u8) }

# ---------------------------------------------------------------------------------------------------------------------
# Les données d'essai (les mêmes que vitrine.ps1 du bloc écrans)
# ---------------------------------------------------------------------------------------------------------------------
$prog = Join-Path $racine 'Programmes'
$fichiers = Join-Path $prog 'Mindset\fichiers'
New-Item -ItemType Directory -Force -Path $fichiers, (Join-Path $racine 'Local\Mindset') | Out-Null
foreach ($f in 'apps.json', 'apps-liste.txt', 'Mindset.ico') { Copy-Item -LiteralPath (Join-Path $Depot "Mindset\fichiers\$f") -Destination $fichiers }
Copy-Item -LiteralPath (Join-Path $Depot 'Mindset\fichiers\cles-publiques') -Destination $fichiers -Recurse
# Nevermind 2.0.1 (Rust : son hôte Mindset.exe = la construction d'essai de Nevermind, et version.json « nevermind »)
$pn = Join-Path $prog 'Nevermind'
New-Item -ItemType Directory -Force -Path $pn | Out-Null
Copy-Item -LiteralPath $Nevermind -Destination (Join-Path $pn 'Mindset.exe')
Ecrire (Join-Path $pn 'Nevermind.exe') 'essai'
Ecrire (Join-Path $pn 'version.json') '{ "appli": "nevermind", "version": "2.0.1" }'
# Evermind 1.4.0 (PowerShell : son script)
$pe = Join-Path $prog 'Evermind'
Ecrire (Join-Path $pe 'Evermind.exe') 'essai'
Ecrire (Join-Path $pe 'fichiers\Evermind.ps1') '# essai'
Ecrire (Join-Path $pe 'version.json') '{ "appli": "evermind", "version": "1.4.0" }'
# Leurs résumés, comme elles les écrivent
$suite = Join-Path $racine 'Donnees'
Ecrire (Join-Path $suite 'Nevermind\etat.json') '{"Score":82,"Protection":64,"AFaire":"Mettre à jour le pilote graphique","Urgent":false,"NbAFaire":1}'
$maintenant = Get-Date
$s = { param($d) $d.ToString('s', [Globalization.CultureInfo]::InvariantCulture) }
$rdv = @(
    [ordered]@{ Id = ('a' * 31) + '1'; Titre = 'Appeler maman'; Quand = (& $s $maintenant.Date.AddHours($maintenant.Hour + 1).AddMinutes(15)); Journee = $false }
    [ordered]@{ Id = ('a' * 31) + '2'; Titre = 'Dentiste'; Quand = (& $s $maintenant.Date.AddDays(1).AddHours(9)); Journee = $false }
    [ordered]@{ Id = ('a' * 31) + '3'; Titre = 'Anniversaire de Léa'; Quand = (& $s $maintenant.Date.AddDays(3)); Journee = $true }
)
Ecrire (Join-Path $suite 'Evermind\etat.json') (ConvertTo-Json -InputObject @{ Prochains = $rdv } -Depth 4 -Compress)
$donnees = Join-Path $suite 'Mindset'
Ecrire (Join-Path $donnees 'reglages.json') '{ "Animations": "aucune", "Demarrage": ["nevermind"], "BulleHorlogeVue": true, "VerifVersions": true }'

# ---------------------------------------------------------------------------------------------------------------------
# Les outils
# ---------------------------------------------------------------------------------------------------------------------
$lances = New-Object System.Collections.Generic.List[int]
function Start-Essai([string]$Programme, [string]$Arguments, [string]$Dossier, [hashtable]$Env = @{}) {
    $psi = New-Object Diagnostics.ProcessStartInfo $Programme
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Dossier
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    $p = [Diagnostics.Process]::Start($psi)
    $lances.Add($p.Id)
    $p
}
function Attendre([scriptblock]$Condition, [int]$Secondes) {
    $fin = (Get-Date).AddSeconds($Secondes)
    while ((Get-Date) -lt $fin) { $r = & $Condition; if ($r) { return $r }; Start-Sleep -Milliseconds 200 }
    $null
}
function Journal { $f = Join-Path $donnees 'journal.txt'; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { '' } }
function Etat { $f = Join-Path $donnees 'etat.json'; try { [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null } }
function Action([string]$Id, $Valeur) {
    $ligne = ConvertTo-Json -Compress -Depth 5 -InputObject ([ordered]@{ type = 'action'; id = $Id; valeur = $Valeur; ecran = 'accueil' })
    $f = Join-Path $donnees 'actions.demande'
    [IO.File]::WriteAllText($f, $ligne, $u8)
    [void](Attendre { -not (Test-Path -LiteralPath $f) } 10)
}
function Capture([string]$Nom, [int]$Apres = 1500) {
    Start-Sleep -Milliseconds $Apres
    $png = Join-Path $donnees 'capture.png'
    if (Test-Path -LiteralPath $png) { Remove-Item -LiteralPath $png -Force }
    [IO.File]::WriteAllText((Join-Path $donnees 'capture.demande'), '1')
    if (Attendre { Test-Path -LiteralPath $png } 15) {
        Start-Sleep -Milliseconds 300
        $vers = Join-Path $Sortie "apres-$Nom.png"
        Copy-Item -LiteralPath $png -Destination $vers -Force
        Ok "capture $vers"
    } else { Echec "capture $Nom" }
}
# Un programme et tous ses descendants (Mindset.exe et ses WebView2 ; powershell.exe et les siennes)
function Get-Arbre([int]$Racine) {
    $tous = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)
    $ids = New-Object System.Collections.Generic.List[int]; $ids.Add($Racine)
    $i = 0
    while ($i -lt $ids.Count) { foreach ($p in $tous) { if ($p.ParentProcessId -eq $ids[$i] -and -not $ids.Contains([int]$p.ProcessId)) { $ids.Add([int]$p.ProcessId) } }; $i++ }
    $ids
}
# Mémoire (somme des « jeux de travail privés » et des jeux de travail) et processeur (en % d'un cœur), sur $Secondes
function Mesurer([int]$Racine, [string]$Quoi, [int]$Secondes) {
    $ids = Get-Arbre $Racine
    $avant = @{}
    foreach ($id in $ids) { try { $avant[$id] = (Get-Process -Id $id).TotalProcessorTime } catch {} }
    $t0 = Get-Date
    Start-Sleep -Seconds $Secondes
    $duree = ((Get-Date) - $t0).TotalSeconds
    $cpu = 0.0; $ws = 0; $prive = 0; $n = 0
    foreach ($id in $avant.Keys) {
        try {
            $p = Get-Process -Id $id
            $cpu += ($p.TotalProcessorTime - $avant[$id]).TotalSeconds
            $ws += $p.WorkingSet64; $prive += $p.PrivateMemorySize64; $n++
        } catch {}
    }
    $l = "MESURE : $Quoi : {0} programmes, mémoire {1:N0} Mo (privée {2:N0} Mo), processeur {3:N1} % d'un cœur sur {4:N0} s" -f $n, ($ws / 1MB), ($prive / 1MB), (100 * $cpu / $duree), $duree
    Write-Output $l
}

$code = 0
try {
    # -----------------------------------------------------------------------------------------------------------------
    # 0. Nevermind d'essai, lancé caché (-Demarrage), dans son dossier d'essai
    # -----------------------------------------------------------------------------------------------------------------
    $nmDonnees = Join-Path $racine 'nevermind\Donnees\Nevermind'
    $nmLocal = Join-Path $racine 'nevermind\Local'
    New-Item -ItemType Directory -Force -Path $nmDonnees, (Join-Path $nmLocal 'Mindset') | Out-Null
    Ecrire (Join-Path $nmLocal 'Mindset\suite.json') (([ordered]@{ theme = 'neon'; applis = [ordered]@{ nevermind = $pn }; modifie = (Get-Date -Format s) }) | ConvertTo-Json -Depth 4)
    $n = Start-Essai (Join-Path $pn 'Mindset.exe') '-Demarrage' $pn @{ NEVERMIND_ESSAI_DONNEES = $nmDonnees; NEVERMIND_ESSAI_LOCAL = $nmLocal; NEVERMIND_ESSAI_NOM = "integration-$PID" }
    $hn = Attendre { $x = [EssaiIntegration]::Trouver($n.Id, 'Tauri Window', 'Nevermind'); if ($x) { $x } } 40
    Verifier ([bool]$hn) "Nevermind d'essai lancé caché ($hn)"

    # -----------------------------------------------------------------------------------------------------------------
    # 1. Mindset en Rust
    # -----------------------------------------------------------------------------------------------------------------
    $debut = Get-Date
    $m = Start-Essai $Exe '' $env:SystemRoot @{ MINDSET_ESSAI_DONNEES = $racine; MINDSET_ESSAI_NOM = "integration-$PID"; MINDSET_INTEGRATION_TEST = '1'; MINDSET_ESSAI_ICONE = '1' }
    $hm = Attendre { $x = [EssaiIntegration]::Trouver($m.Id, 'Tauri Window', 'Mindset'); if ($x) { $x } } 40
    Verifier ([bool]$hm) "fenêtre de Mindset ($hm)"
    Verifier ([bool](Attendre { (Journal) -match 'Écran prêt' } 40)) "l'écran est prêt"
    Write-Output ("     prêt en {0:N1} s" -f ((Get-Date) - $debut).TotalSeconds)
    $t = ([EssaiIntegration]::Taille($hm)).Split('|')
    Write-Output "     fenêtre : $($t[0]) (cadre compris), intérieur $($t[1]), vue $($t[2]), DPI $($t[3])"
    $j = Journal
    Verifier ($j -match 'Démarrage Mindset 3\.0\.0 \(Rust\)') 'ligne « Démarrage Mindset 3.0.0 (Rust) »'
    Verifier ($j -match 'Écran : \d+ x \d+ à l''intérieur') "taille comptée cadre compris (journal : $([regex]::Match($j, 'Écran : \d+ x \d+ à l''intérieur[^\r\n]*').Value))"
    Start-Sleep -Seconds 3
    $e = Etat
    Verifier ($e -and $e._vue.page -eq 'accueil') 'accueil'
    Verifier ($e -and -not $e.ecrans.console) 'Animations : aucune, accueil classique (en-tête et onglets)'
    $ids = @($e.ecrans.onglets | ForEach-Object { $_.id })
    Verifier (($ids -join ',') -match 'nevermind' -and ($ids -join ',') -match 'evermind' -and ($ids -join ',') -match 'mindcare') "les onglets des 3 applis ($($ids -join ', '))"
    Capture 'accueil' 2500
    Mesurer $m.Id 'Mindset 3.0 Rust, accueil classique, montré' $Mesure

    # 2. La croix rouge : la question, puis Annuler
    [void][EssaiIntegration]::PostMessage([IntPtr]$hm, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    Verifier ([bool](Attendre { $x = Etat; $x -and $x.fermeture.visible } 10)) 'la croix pose la question'
    Verifier (-not $m.HasExited) 'la croix ne ferme pas Mindset'
    Capture 'fermeture'
    Action 'horloge:fermeture' @{ choix = 'annuler'; souvenir = $false }
    Verifier ([bool](Attendre { $x = Etat; $x -and -not $x.fermeture.visible } 10)) '« Annuler » referme la question'

    # 3. Les Paramètres et leurs 6 panneaux
    Action 'ecrans:onglet' 'parametres'
    Verifier ([bool](Attendre { $x = Etat; $x -and $x._vue.page -eq 'parametres' } 10)) 'page des Paramètres'
    foreach ($o in 'general', 'apparence', 'son', 'maj', 'conso', 'dossiers') {
        Action 'parametres:onglet' $o
        [void](Attendre { $x = Etat; $x -and $x.parametres.onglet -eq $o } 10)
        Capture "parametres-$o"
    }

    # 4. La page d'Evermind (installé, pas ouvert : l'écran « Ouvrir ») et celle de Mindcare (pas installé)
    Action 'ecrans:onglet' 'evermind'
    Capture 'evermind'
    Action 'ecrans:onglet' 'mindcare'
    Capture 'non-installe'

    # 5. Nevermind accroché
    Action 'ecrans:onglet' 'nevermind'
    $acc = Attendre { $x = Etat; if ($x -and $x.pages_applis.nevermind.barre_propre -ne $null -and $hn -and [EssaiIntegration]::GetParent([IntPtr]$hn) -ne [IntPtr]::Zero) { $true } } 30
    Verifier ([bool]$acc) 'Nevermind accroché dans la page (sa fenêtre a un parent)'
    Capture 'nevermind-accroche' 3000
    $jn = Journal
    Write-Output ('     journal : ' + (($jn -split "`r?`n") | Where-Object { $_ -match 'Nevermind' } | Select-Object -Last 4) -join ' / ')
    Action 'ecrans:menu' $null
    Action 'ecrans:onglet' 'accueil'
    Start-Sleep -Seconds 1
    Verifier ($hn -and -not [EssaiIntegration]::IsWindowVisible([IntPtr]$hn)) 'Nevermind effacé hors de sa page'

    # 6. La console 3D
    Action 'parametres:reglage' @{ quoi = 'animations'; valeur = 'completes' }
    Action 'ecrans:onglet' 'accueil'
    $cons = Attendre { $x = Etat; if ($x -and $x.ecrans.console -and $x.console.cadre) { $true } } 20
    Verifier ([bool]$cons) 'console 3D allumée (Animations : complètes)'
    Verifier ([bool](Attendre { (Journal) -match 'Console 3D' -or (Etat).console.attente -eq $false } 20)) 'scène prête'
    Capture 'console' 6000
    Mesurer $m.Id 'Mindset 3.0 Rust, console 3D, montré' $Mesure
    [void][EssaiIntegration]::ShowWindow([IntPtr]$hm, 0)   # SW_HIDE
    Start-Sleep -Seconds 5
    $x = Etat
    Verifier ($x -and -not $x._vue.visible) 'caché : la vue le sait'
    Mesurer $m.Id 'Mindset 3.0 Rust, fenêtre cachée' $Mesure
    [void][EssaiIntegration]::ShowWindow([IntPtr]$hm, 5)   # SW_SHOW
    Start-Sleep -Seconds 2
    Write-Output '--- journal de Mindset 3.0 (Rust) ---'
    Journal
    if (-not $m.HasExited) { Stop-Process -Id $m.Id -Force }

    # -----------------------------------------------------------------------------------------------------------------
    # 7. Mindset 2.18 (PowerShell) en mode test, les mêmes données (vitrine.ps1 du bloc écrans)
    # -----------------------------------------------------------------------------------------------------------------
    $vitrine = Join-Path $Depot 'rust\mindset-ecrans\outils\vitrine.ps1'
    $vdossier = Join-Path $Sortie 'vitrine'
    New-Item -ItemType Directory -Force -Path $vdossier | Out-Null
    [IO.File]::WriteAllText((Join-Path $vdossier 'maintenant.txt'), $maintenant.ToString('s', [Globalization.CultureInfo]::InvariantCulture))
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    foreach ($variante in @(@{ Nom = 'accueil classique'; Console = '' }, @{ Nom = 'console 3D'; Console = '1' })) {
        $d218 = Join-Path $racine "mindset-2.18-$($variante.Console)"
        New-Item -ItemType Directory -Force -Path $d218 | Out-Null
        $vars = @{ MINDSET_TEST = '1'; MINDSET_SANS_RESEAU = '1'; MINDSET_DONNEES = $d218; MINDSET_TEST_SCRIPT = $vitrine; MINDSET_VITRINE_DOSSIER = $vdossier; MINDSET_VITRINE = ''; MINDSET_VERSION = '2.18.0' }
        if ($variante.Console) { $vars['MINDSET_CONSOLE'] = '1' }
        $w = Start-Essai $powershell "-NoProfile -ExecutionPolicy Bypass -STA -File `"$(Join-Path $Depot 'Mindset\fichiers\Mindset.ps1')`"" $env:SystemRoot $vars
        $hw = Attendre { $x = [EssaiIntegration]::Trouver($w.Id, 'HwndWrapper', 'Mindset'); if ($x -and [EssaiIntegration]::IsWindowVisible([IntPtr]$x)) { $x } } 90
        Verifier ([bool]$hw) "Mindset 2.18 ($($variante.Nom)) : fenêtre ($hw)"
        if (-not $hw) { continue }
        if ($variante.Console -eq '') {
            $t = ([EssaiIntegration]::Taille($hw)).Split('|')
            Write-Output "     fenêtre 2.18 : $($t[0]) (cadre compris), intérieur $($t[1]), vue $($t[2]), DPI $($t[3])"
        }
        Start-Sleep -Seconds 12   # (l'accueil, ou la console qui s'allume)
        Mesurer $w.Id "Mindset 2.18 PowerShell, $($variante.Nom), montré" $Mesure
        if ($variante.Console) {
            [void][EssaiIntegration]::ShowWindow([IntPtr]$hw, 0)
            Start-Sleep -Seconds 5
            Mesurer $w.Id 'Mindset 2.18 PowerShell, fenêtre cachée' $Mesure
        }
        foreach ($id in (Get-Arbre $w.Id)) { try { Stop-Process -Id $id -Force } catch {} }
    }
} catch {
    Echec "erreur de l'essai : $_ ($($_.InvocationInfo.ScriptLineNumber))"
} finally {
    foreach ($id in $lances) { foreach ($x in (Get-Arbre $id)) { try { Stop-Process -Id $x -Force -ErrorAction SilentlyContinue } catch {} } }
}
if ($echecs.Count) { Write-Output "$($echecs.Count) échec(s) : $($echecs -join ' ; ')"; exit 1 }
Write-Output 'Tout est bon.'
exit 0
