# Mindset : tests du nom de chaque appli dans la barre des tâches (raccourcis du menu Démarrer, installations.ps1).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\outils\tester-raccourcis.ps1
#
# L'hôte de chaque appli s'appelle Mindset.exe. Pour nommer le bouton d'une appli, Windows cherche dans le menu Démarrer
# un raccourci qui porte la même identité (System.AppUserModel.ID) ; sans lui, il affiche « Mindset » (la description
# du programme). On vérifie, dans un faux menu Démarrer sous %TEMP% (jamais le vrai), que :
#   - chaque appli gérée qui a son hôte Mindset.exe a UN raccourci <Appli>.lnk, vers son hôte, avec son icône et son
#     identité (lus dans le .lnk, par un lecteur indépendant de celui de Mindset) ;
#   - un ancien raccourci du même nom (sans identité, ou vers un autre dossier) est remplacé ; un raccourci juste n'est
#     pas réécrit ; une appli sans hôte, pas gérée, ou désinstallée n'en a pas (il est retiré, le dossier vide aussi) ;
#   - ces raccourcis ne sont jamais pris pour des « raccourcis directs » à retirer (Remove-Doublons) ;
#   - Mindset en test n'écrit nulle part sans dossier de test ; les identités sont celles que les applis se donnent ;
#   - les raccourcis de Mindset reçoivent son identité ; sa fenêtre porte son identité, sa commande de relance, son
#     nom et son icône (lus avec SHGetPropertyStoreForWindow sur une fenêtre de test hors de l'écran).
# Code de sortie 1 si un cas échoue (utilisé par la CI de GitHub).

$ErrorActionPreference = 'Stop'
$racine = Split-Path $PSScriptRoot -Parent
$fichiers = Join-Path $racine 'Mindset\fichiers'

$script:Reussis = 0
$script:Echoues = @()
function Test-Cas([string]$Nom, [scriptblock]$Condition) {
    $detail = ''
    try { $r = @(& $Condition) } catch { $r = @(); $detail = $_.Exception.Message }
    if ($r.Count -and $r[-1] -is [bool] -and $r[-1]) {
        $script:Reussis++
        Write-Host "  OK     $Nom" -ForegroundColor Green
    } else {
        $script:Echoues += $Nom
        Write-Host "  ÉCHEC  $Nom$(if ($detail) { " ($detail)" })" -ForegroundColor Red
    }
}
function Write-Partie([string]$Titre) { Write-Host ''; Write-Host $Titre -ForegroundColor Cyan }

$tmp = Join-Path $env:TEMP "mindset-raccourcis-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Get-Item -LiteralPath ([IO.Path]::GetFullPath($tmp))).FullName   # (en nom long : sur GitHub, TEMP est en nom court)

# Lecteur indépendant de celui de Mindset : un .lnk (programme, icône, identité) et les propriétés d'une fenêtre
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LecteurTest
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink { }
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder f, int c, IntPtr d, uint fl);
        void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int c); void SetDescription(string s);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int c); void SetWorkingDirectory(string s);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int c); void SetArguments(string s);
        void GetHotkey(out short h); void SetHotkey(short h); void GetShowCmd(out int s); void SetShowCmd(int s);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int c, out int i);
    }
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct PK { public Guid f; public uint p; }
    [StructLayout(LayoutKind.Explicit)] struct PV { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public long x; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore { void GetCount(out uint c); void GetAt(uint i, out PK k); void GetValue(ref PK k, out PV v); }
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PV v);
    [DllImport("shell32.dll", PreserveSig = false)] static extern void SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore s);
    static string Valeur(IPropertyStore s, uint pid)
    {
        PK k = new PK { f = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), p = pid };
        PV v; s.GetValue(ref k, out v);
        try { return v.vt == 31 && v.p != IntPtr.Zero ? Marshal.PtrToStringUni(v.p) : ""; } finally { PropVariantClear(ref v); }
    }
    // { programme, dossier, icône, index, commentaire, identité }
    public static string[] Raccourci(string lien)
    {
        object o = new ShellLink();
        try
        {
            ((System.Runtime.InteropServices.ComTypes.IPersistFile)o).Load(lien, 0);
            IShellLinkW l = (IShellLinkW)o;
            StringBuilder p = new StringBuilder(1024), d = new StringBuilder(1024), i = new StringBuilder(1024), c = new StringBuilder(1024);
            int n; l.GetPath(p, 1024, IntPtr.Zero, 4); l.GetWorkingDirectory(d, 1024); l.GetIconLocation(i, 1024, out n); l.GetDescription(c, 1024);
            return new string[] { p.ToString(), d.ToString(), i.ToString(), n.ToString(), c.ToString(), Valeur((IPropertyStore)o, 5) };
        }
        finally { Marshal.ReleaseComObject(o); }
    }
    // { identité, commande de relance, icône de relance, nom de relance }
    public static string[] Fenetre(IntPtr h)
    {
        Guid iid = typeof(IPropertyStore).GUID; IPropertyStore s;
        SHGetPropertyStoreForWindow(h, ref iid, out s);
        try { return new string[] { Valeur(s, 5), Valeur(s, 2), Valeur(s, 3), Valeur(s, 4) }; }
        finally { Marshal.ReleaseComObject(s); }
    }
}
'@

# Les fonctions de Mindset sont lues dans ses fichiers (rien d'autre n'est chargé)
function Get-Fonctions([string]$Fichier, [string[]]$Noms) {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $fichiers "modules\$Fichier"), [ref]$tok, [ref]$err)
    if ($err) { throw "$Fichier illisible" }
    foreach ($n in $Noms) {
        $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }.GetNewClosure(), $true)
        if (-not $f) { throw "$n introuvable dans $Fichier" }
        $f.Extent.Text
    }
}
function Get-Corps([string]$Fichier, [string]$Nom) { Get-Fonctions $Fichier $Nom }

try {
    Write-Partie 'Préparation'
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $fichiers 'modules\natif.cs'), [Text.Encoding]::UTF8))
    Test-Cas 'natif.cs se compile (MSRaccourci compris)' { $null -ne ('MSRaccourci' -as [type]) }
    foreach ($t in Get-Fonctions 'installations.ps1' 'Get-RaccourciMenu', 'Update-RaccourciAppli', 'Remove-RaccourciAppli', 'Update-RaccourcisApplis', 'Get-RaccourcisAppli') { Invoke-Expression $t }
    function Write-Log { }
    $Menu = Join-Path $tmp 'Menu Démarrer\Programmes'
    $MenuApplis = Join-Path $Menu 'Mindset'
    $prog = Join-Path $tmp 'Programmes'
    # Les applis comme Mindset les lit dans apps.json (applis.ps1)
    $AppDir = $fichiers
    . (Join-Path $fichiers 'modules\applis.ps1')
    $nevermind = $Applis | Where-Object Id -eq 'nevermind'
    $evermind = $Applis | Where-Object Id -eq 'evermind'
    $mindcare = $Applis | Where-Object Id -eq 'mindcare'
    Test-Cas 'Identités tirées de apps.json : JordanJacquot.Nevermind, .Evermind, .Mindcare' {
        $nevermind.AppId -ceq 'JordanJacquot.Nevermind' -and $evermind.AppId -ceq 'JordanJacquot.Evermind' -and $mindcare.AppId -ceq 'JordanJacquot.Mindcare'
    }
    # Les installations du faux PC : Nevermind et Evermind gérées avec leur hôte, Mindcare ancienne (sans hôte)
    $script:Installs = @{}
    function Get-Installation($Appli) { $script:Installs[$Appli.Id] }
    function Set-Installation([string]$Id, [string]$Dossier, [bool]$Gere, [string[]]$Exes) {
        foreach ($e in $Exes) { New-Item -ItemType Directory -Force -Path $Dossier | Out-Null; [IO.File]::WriteAllText((Join-Path $Dossier $e), 'programme') }
        $script:Installs[$Id] = @{ Dossier = $Dossier; Gere = $Gere; Version = '1.0.0' }
    }
    Set-Installation 'nevermind' "$prog\Nevermind" $true 'Mindset.exe', 'Nevermind.exe'
    Set-Installation 'evermind' "$prog\Evermind" $true 'Mindset.exe', 'Evermind.exe'
    Set-Installation 'mindcare' "$prog\Mindcare" $true 'Mindcare.exe'
    $lienN = Join-Path $MenuApplis 'Nevermind.lnk'
    $lienE = Join-Path $MenuApplis 'Evermind.lnk'
    $lienC = Join-Path $MenuApplis 'Mindcare.lnk'

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Une appli gérée avec son hôte Mindset.exe : son raccourci, avec son identité'
    # -------------------------------------------------------------------------------------------------------------
    Update-RaccourciAppli $nevermind
    $r = if (Test-Path -LiteralPath $lienN) { [LecteurTest]::Raccourci($lienN) } else { @() }
    Test-Cas 'Nevermind.lnk est créé dans le dossier « Mindset » du menu Démarrer' { Test-Path -LiteralPath $lienN }
    Test-Cas 'Il lance l''hôte Mindset.exe du dossier de Nevermind, depuis ce dossier' { $r[0] -ieq "$prog\Nevermind\Mindset.exe" -and $r[1] -ieq "$prog\Nevermind" }
    Test-Cas 'Son icône est celle de l''hôte (l''icône de l''appli), index 0' { $r[2] -ieq "$prog\Nevermind\Mindset.exe" -and $r[3] -eq '0' }
    Test-Cas 'Il porte l''identité de Nevermind (System.AppUserModel.ID = JordanJacquot.Nevermind)' { $r[5] -ceq 'JordanJacquot.Nevermind' }
    Test-Cas 'Son commentaire est la description de l''appli' { $r[4] -eq $nevermind.Description }
    Test-Cas 'Le lecteur de Mindset lit la même chose' { $m = [MSRaccourci]::Lire($lienN); $m[0] -ieq $r[0] -and $m[2] -ceq $r[5] -and $m[1] -ieq "$($r[2]),0" }
    $avant = (Get-Item -LiteralPath $lienN).LastWriteTimeUtc
    Start-Sleep -Milliseconds 50
    Update-RaccourciAppli $nevermind
    Test-Cas 'Déjà juste : il n''est pas réécrit' { (Get-Item -LiteralPath $lienN).LastWriteTimeUtc -eq $avant }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Un ancien raccourci du même nom est remplacé proprement'
    # -------------------------------------------------------------------------------------------------------------
    Remove-Item -LiteralPath $lienN -Force
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lienN); $s.TargetPath = "$prog\Nevermind\Nevermind.exe"; $s.Save()
    Test-Cas '(un raccourci sans identité, vers l''ancien Nevermind.exe, est en place)' { ([LecteurTest]::Raccourci($lienN))[5] -eq '' }
    Update-RaccourciAppli $nevermind
    $r = [LecteurTest]::Raccourci($lienN)
    Test-Cas 'Sans identité : remplacé (vers l''hôte, avec l''identité)' { $r[0] -ieq "$prog\Nevermind\Mindset.exe" -and $r[5] -ceq 'JordanJacquot.Nevermind' }
    [MSRaccourci]::Ecrire($lienN, "$tmp\ailleurs\Mindset.exe", "$tmp\ailleurs", "$tmp\ailleurs\Mindset.exe", 'x', 'JordanJacquot.Nevermind')
    Update-RaccourciAppli $nevermind
    Test-Cas 'Vers un autre dossier (même identité) : remplacé' { ([LecteurTest]::Raccourci($lienN))[0] -ieq "$prog\Nevermind\Mindset.exe" }
    [MSRaccourci]::Ecrire($lienN, "$prog\Nevermind\Mindset.exe", "$prog\Nevermind", "$prog\Nevermind\Mindset.exe", 'x', 'JordanJacquot.Autre')
    Update-RaccourciAppli $nevermind
    Test-Cas 'Avec une autre identité : remplacé' { ([LecteurTest]::Raccourci($lienN))[5] -ceq 'JordanJacquot.Nevermind' }
    [IO.File]::WriteAllText($lienN, 'abîmé')
    Update-RaccourciAppli $nevermind
    Test-Cas 'Abîmé (illisible) : remplacé' { ([LecteurTest]::Raccourci($lienN))[5] -ceq 'JordanJacquot.Nevermind' }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Toutes les applis au démarrage de Mindset (réparation) : un raccourci par appli, pas de doublon'
    # -------------------------------------------------------------------------------------------------------------
    [MSRaccourci]::Ecrire($lienC, "$prog\Mindcare\Mindcare.exe", "$prog\Mindcare", "$prog\Mindcare\Mindcare.exe", 'x', 'JordanJacquot.Mindcare')
    Update-RaccourcisApplis
    Test-Cas 'Nevermind et Evermind en ont un, chacun avec son identité' {
        ([LecteurTest]::Raccourci($lienN))[5] -ceq 'JordanJacquot.Nevermind' -and ([LecteurTest]::Raccourci($lienE))[5] -ceq 'JordanJacquot.Evermind' -and
        ([LecteurTest]::Raccourci($lienE))[0] -ieq "$prog\Evermind\Mindset.exe"
    }
    Test-Cas 'Mindcare d''avant (sans hôte Mindset.exe : son nom s''affiche déjà) : pas de raccourci, l''ancien est retiré' { -not (Test-Path -LiteralPath $lienC) }
    Test-Cas 'Exactement un raccourci par appli dans le dossier, rien d''autre' { (@(Get-ChildItem -LiteralPath $MenuApplis | ForEach-Object Name | Sort-Object) -join ',') -eq 'Evermind.lnk,Nevermind.lnk' }
    Set-Installation 'mindcare' "$prog\Mindcare" $true 'Mindset.exe'
    Update-RaccourcisApplis
    Test-Cas 'Mindcare mis à jour (son hôte arrive) : son raccourci est créé' { ([LecteurTest]::Raccourci($lienC))[5] -ceq 'JordanJacquot.Mindcare' }
    Test-Cas 'Une identité différente par raccourci' { @(@($lienN, $lienE, $lienC) | ForEach-Object { ([LecteurTest]::Raccourci($_))[5] } | Select-Object -Unique).Count -eq 3 }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Une appli qui n''est plus gérée, ou désinstallée : son raccourci part'
    # -------------------------------------------------------------------------------------------------------------
    $script:Installs['evermind'] = @{ Dossier = "$tmp\ailleurs\Evermind"; Gere = $false; Version = '1.0.0' }
    Update-RaccourciAppli $evermind
    Test-Cas 'Copie trouvée ouverte telle quelle (pas gérée) : pas de raccourci' { -not (Test-Path -LiteralPath $lienE) }
    $script:Installs.Remove('mindcare')
    Update-RaccourciAppli $mindcare
    Test-Cas 'Plus installée : son raccourci est retiré' { -not (Test-Path -LiteralPath $lienC) }
    [IO.File]::WriteAllText((Join-Path $MenuApplis 'Note de l''utilisateur.txt'), 'à garder')
    Remove-RaccourciAppli $nevermind
    Test-Cas 'Désinstallée (Remove-RaccourciAppli) : retiré ; un fichier qui n''est pas de Mindset reste, avec le dossier' {
        -not (Test-Path -LiteralPath $lienN) -and (Test-Path -LiteralPath (Join-Path $MenuApplis 'Note de l''utilisateur.txt'))
    }
    Remove-Item -LiteralPath (Join-Path $MenuApplis 'Note de l''utilisateur.txt')
    Update-RaccourciAppli $nevermind
    Remove-RaccourciAppli $nevermind
    Test-Cas 'Le dernier parti, le dossier « Mindset » du menu Démarrer part aussi' { -not (Test-Path -LiteralPath $MenuApplis) -and (Test-Path -LiteralPath $Menu) }
    Remove-RaccourciAppli $nevermind
    Test-Cas 'Rien à retirer : sans erreur' { -not (Test-Path -LiteralPath $MenuApplis) }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Jamais pris pour un « raccourci direct » à retirer'
    # -------------------------------------------------------------------------------------------------------------
    Update-RaccourciAppli $nevermind
    function Get-LieuxRaccourcis { $Menu }
    Test-Cas 'Get-RaccourcisAppli (Remove-Doublons, recherche des copies) ne le voit pas' { @(Get-RaccourcisAppli $nevermind).Count -eq 0 -and (Test-Path -LiteralPath $lienN) }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Mindset s''en occupe au bon moment, et jamais dans le vrai menu Démarrer en test'
    # -------------------------------------------------------------------------------------------------------------
    $inst = [IO.File]::ReadAllText((Join-Path $fichiers 'modules\installations.ps1'), [Text.Encoding]::UTF8)
    Test-Cas 'Installation, mise à jour, prise en charge (Complete-Installation) : Update-RaccourciAppli' { (Get-Corps 'installations.ps1' 'Complete-Installation') -match 'Update-RaccourciAppli \$Appli' }
    Test-Cas 'Désinstallation (Complete-Desinstallation) : Remove-RaccourciAppli' { (Get-Corps 'installations.ps1' 'Complete-Desinstallation') -match 'Remove-RaccourciAppli \$Appli' }
    Test-Cas 'Copie trouvée choisie (Use-InstallationTrouvee) : Update-RaccourciAppli' { (Get-Corps 'installations.ps1' 'Use-InstallationTrouvee') -match 'Update-RaccourciAppli \$Appli' }
    Test-Cas 'Démarrage de Mindset (Start-Demarrage) : réparation, avant tout retour anticipé' {
        $c = Get-Corps 'mindset.ps1' 'Start-Demarrage'
        $c -match 'Update-RaccourcisApplis' -and $c.IndexOf('Update-RaccourcisApplis') -lt $c.IndexOf('relance.marque')
    }
    $ligne = [regex]::Match($inst, '(?m)^\$MenuApplis = .*$').Value
    Test-Cas 'En test sans MINDSET_TEST_MENU : aucun dossier (rien n''est écrit)' {
        $EnTest = $true; $env:MINDSET_TEST_MENU = $null
        Invoke-Expression $ligne
        -not $MenuApplis
    }
    Test-Cas 'Hors test : le dossier « Mindset » du menu Démarrer de l''utilisateur' {
        $EnTest = $false
        Invoke-Expression $ligne
        $MenuApplis -ieq (Join-Path ([Environment]::GetFolderPath('Programs')) 'Mindset')
    }
    # (les applis voisines, si leur dépôt est à côté : l'identité qu'elles se donnent est bien celle de leur raccourci)
    $voisins = @{ nevermind = 'Nevermind\OptiGame\fichiers\OptiGame.ps1'; evermind = 'Evermind\Evermind\fichiers\Evermind.ps1'; mindcare = 'Mindcare\Mindcare\fichiers\Mindcare.ps1' }
    foreach ($a in $nevermind, $evermind, $mindcare) {
        $f = Join-Path (Split-Path $racine -Parent) $voisins[$a.Id]
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $t = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
        Test-Cas "$($a.Nom) (dépôt voisin) se donne l'identité $($a.AppId)" { $t -cmatch [regex]::Escape("'$($a.AppId)'") -or ($t -cmatch 'JordanJacquot\.\$AppNom' -and $t -cmatch "AppNom\s*=\s*'$($a.Nom)'") }
    }

    # -------------------------------------------------------------------------------------------------------------
    Write-Partie 'Mindset lui-même : ses raccourcis et sa fenêtre gardent son nom'
    # -------------------------------------------------------------------------------------------------------------
    foreach ($t in Get-Fonctions 'mindset.ps1' 'Update-RaccourcisMindset') { Invoke-Expression $t }
    $AppId = 'JordanJacquot.Mindset'
    $AppExe = Join-Path $prog 'Mindset\Mindset.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path $AppExe) | Out-Null; [IO.File]::WriteAllText($AppExe, 'programme')
    $DescriptionRaccourciMindset = 'Mindset : toutes tes applis au même endroit'
    function Test-MindsetInstalle { $true }
    $bureau = Join-Path $tmp 'Bureau'; New-Item -ItemType Directory -Force -Path $bureau | Out-Null
    $RaccourcisMindset = @((Join-Path $bureau 'Mindset.lnk'), (Join-Path $Menu 'Mindset.lnk'))
    $s = $sh.CreateShortcut($RaccourcisMindset[0]); $s.TargetPath = $AppExe; $s.Save()
    $s = $sh.CreateShortcut($RaccourcisMindset[1]); $s.TargetPath = "$tmp\autre\Mindset.exe"; $s.Save()
    Update-RaccourcisMindset
    $r = [LecteurTest]::Raccourci($RaccourcisMindset[0])
    Test-Cas 'Mindset.lnk d''avant (sans identité) reçoit JordanJacquot.Mindset, toujours vers Mindset.exe' { $r[5] -ceq 'JordanJacquot.Mindset' -and $r[0] -ieq $AppExe -and $r[4] -eq $DescriptionRaccourciMindset }
    Test-Cas 'Un Mindset.lnk vers un autre Mindset n''est pas touché' { ([LecteurTest]::Raccourci($RaccourcisMindset[1]))[5] -eq '' }
    Remove-Item -LiteralPath $RaccourcisMindset[0]
    Update-RaccourcisMindset
    Test-Cas 'Un raccourci supprimé par l''utilisateur n''est pas recréé' { -not (Test-Path -LiteralPath $RaccourcisMindset[0]) }
    Test-Cas 'L''installation de Mindset écrit ses raccourcis avec son identité' { (Get-Corps 'mindset.ps1' 'Install-Mindset') -match '\[MSRaccourci\]::Ecrire\(\$l, \$exe, \$dossier, \$exe, \$DescriptionRaccourciMindset, \$AppId\)' }

    # La fenêtre : identité, relance, nom et icône (fenêtre de test hors de l'écran, sans prendre la main ni la barre des tâches)
    Add-Type -AssemblyName PresentationFramework
    $w = New-Object System.Windows.Window
    $w.WindowStartupLocation = 'Manual'; $w.Left = -10000; $w.Top = 0; $w.Width = 200; $w.Height = 100
    $w.ShowActivated = $false; $w.ShowInTaskbar = $false; $w.Title = 'Test Mindset'
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $w).EnsureHandle()
    $icone = Join-Path $fichiers 'Mindset.ico'
    [MSNative]::SetWindowIdentity($h, 'JordanJacquot.MindsetTest', "`"$AppExe`"", $icone, 'Mindset')
    $f = [LecteurTest]::Fenetre($h)
    $w.Close()
    Test-Cas 'Fenêtre : identité, commande de relance (Mindset.exe), icône et nom « Mindset »' {
        $f[0] -ceq 'JordanJacquot.MindsetTest' -and $f[1] -eq "`"$AppExe`"" -and $f[2] -eq $icone -and $f[3] -ceq 'Mindset'
    }
    Test-Cas 'interface.ps1 donne à la fenêtre l''identité de Mindset et le nom « Mindset »' {
        [IO.File]::ReadAllText((Join-Path $fichiers 'modules\interface.ps1'), [Text.Encoding]::UTF8) -match "SetWindowIdentity\(\`$h, \`$AppId, \(Get-LaunchCommand\), \`$IconPath, 'Mindset'\)"
    }
}
catch {
    $script:Echoues += "Arrêt inattendu : $($_.Exception.Message)"
    Write-Host "  ÉCHEC  Arrêt inattendu : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
}
finally {
    Remove-Item env:MINDSET_TEST_MENU -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$total = $script:Reussis + $script:Echoues.Count
if ($script:Echoues.Count) {
    Write-Host "$($script:Echoues.Count) échec(s) sur $total cas :" -ForegroundColor Red
    $script:Echoues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Les $total cas sont réussis." -ForegroundColor Green
exit 0
