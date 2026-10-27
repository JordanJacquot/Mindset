// L'appli témoin (docs\contrat-appli.md) : ses trois programmes, compilés par temoin\construire.ps1 depuis ce fichier.
//   Mindset.exe (sans symbole) : l'hôte. Il fait tourner fichiers\Temoin.ps1 DANS son propre processus (moteur PowerShell
//     hébergé), avec « Mindset » comme titre : le Gestionnaire des tâches range toute la suite sur une ligne « Mindset »
//     (contrat, partie 4). Il calcule le dossier des données (partie 8) et le donne au script, avec -Demarrage (partie 6).
//   Temoin.exe (symbole RELAIS) : le programme <exe> de apps.json. Il lance Mindset.exe de CE dossier avec les mêmes
//     arguments, puis se ferme aussitôt (comme Nevermind.exe).
//   Désinstaller Temoin.exe (symbole DESINSTALLER) : le désinstalleur par appli (partie 9). Il ne dépend pas du script :
//     il marche même si fichiers\Temoin.ps1 est abîmé ou supprimé.
// Aucun réglage de test ici : ni variable d'environnement à part, ni option cachée.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
#if !RELAIS && !DESINSTALLER
using System.Management.Automation;
using System.Management.Automation.Runspaces;
#endif

#if RELAIS || DESINSTALLER
[assembly: AssemblyTitle("Temoin")]
#else
[assembly: AssemblyTitle("Mindset")]
#endif
[assembly: AssemblyProduct("Temoin")]
[assembly: AssemblyDescription("L'appli témoin de la suite Mindset")]

static class Lanceur
{
    const string Nom = "Temoin";   // le « nom » de son entrée dans apps.json (dossier, titre de la fenêtre)

    // Le dossier des données, déduit de l'emplacement des programmes (même règle que Get-RacinesDepuis de Mindset,
    // modules\donnees.ps1, et que suite-commun) :
    //   X:\Mindset\Programmes\Temoin        ->  X:\Mindset\Donnees\Temoin
    //   C:\Program Files\Mindset\Temoin     ->  %LOCALAPPDATA%\Mindset\Temoin
    //   ailleurs (une copie que Mindset ne gère pas)  ->  %LOCALAPPDATA%\Temoin (le champ « donnees » de apps.json)
    // %LOCALAPPDATA% est lu comme Mindset le lit (sa variable d'environnement), pour que les deux tombent d'accord.
    static string DossierDonnees(string dossierProgrammes)
    {
        string moi = Path.GetFullPath(dossierProgrammes).TrimEnd('\\', '/');
        DirectoryInfo p = new DirectoryInfo(moi).Parent;
        DirectoryInfo m = p == null ? null : p.Parent;
        if (m != null && string.Equals(p.Name, "Programmes", StringComparison.OrdinalIgnoreCase) && string.Equals(m.Name, "Mindset", StringComparison.OrdinalIgnoreCase))
            return Path.Combine(Path.Combine(m.FullName, "Donnees"), Nom);
        string local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (string.IsNullOrEmpty(local)) local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string gere = Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Mindset"), Nom);
        if (string.Equals(moi, gere, StringComparison.OrdinalIgnoreCase)) return Path.Combine(Path.Combine(local, "Mindset"), Nom);
        return Path.Combine(local, Nom);
    }

    // Une option de la ligne de commande, écrite -Option ou /Option, sans tenir compte des majuscules
    static bool Option(string a, string nom) { return a.TrimStart('-', '/').Equals(nom, StringComparison.OrdinalIgnoreCase); }

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        string dossier = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
#if RELAIS
        string hote = Path.Combine(dossier, "Mindset.exe");
        try
        {
            var psi = new ProcessStartInfo(hote, Arguments(args));
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Environment.CurrentDirectory;
            using (Process.Start(psi)) { }
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show("Temoin n'a pas pu démarrer :\n\n" + e.Message, Nom, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
#elif DESINSTALLER
        return Desinstaller(dossier, args);
#else
        string script = Path.Combine(Path.Combine(dossier, "fichiers"), "Temoin.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Le dossier « fichiers » est introuvable à côté de ce programme. Réinstalle Temoin depuis Mindset.", Nom, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
        bool demarrage = false;
        foreach (string a in args) if (Option(a, "Demarrage")) demarrage = true;
        try
        {
            Directory.SetCurrentDirectory(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;   // (la fenêtre WPF tourne sur ce fil)
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    ps.AddParameter("DossierDonnees", DossierDonnees(dossier));
                    if (demarrage) ps.AddParameter("Demarrage");
                    ps.Invoke();
                }
            }
        }
        catch (Exception e)
        {
            MessageBox.Show("Temoin n'a pas pu démarrer :\n\n" + e.Message, Nom, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            Environment.Exit(1);
        }
        // Aucun fil de fond ne garde le processus en vie sans fenêtre après « Quitter » (contrat, partie 3)
        Environment.Exit(0);
        return 0;
#endif
    }

#if DESINSTALLER
    // Désinstaller Temoin.exe [-GarderDonnees | -SupprimerDonnees] (contrat, partie 9) :
    //   sans option, ou avec les deux, il pose la question ; avec une seule, il ne la pose pas ;
    //   il ferme l'appli, remet Windows comme avant (le témoin n'y change rien), supprime ses programmes (Temoin.exe
    //   disparaît : c'est ce que Mindset attend), ses données si demandé, et rend 0.
    static int Desinstaller(string dossier, string[] args)
    {
        bool garder = false, supprimer = false;
        foreach (string a in args)
        {
            if (Option(a, "GarderDonnees")) garder = true;
            else if (Option(a, "SupprimerDonnees")) supprimer = true;
        }
        if (garder == supprimer)
        {
            DialogResult r = MessageBox.Show("Désinstaller Temoin.\n\nGarder ses données (réglages, journal) pour une prochaine installation ?",
                "Désinstaller Temoin", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (r == DialogResult.Cancel) return 1;
            supprimer = r == DialogResult.No;
        }
        string donnees = DossierDonnees(dossier);

        // 1. L'appli se ferme d'elle-même (quitter.demande), puis ce qui tourne encore depuis son dossier est arrêté
        try { if (Directory.Exists(donnees)) File.WriteAllText(Path.Combine(donnees, "quitter.demande"), Process.GetCurrentProcess().Id.ToString()); } catch { }
        DateTime limite = DateTime.Now.AddSeconds(8);
        while (DateTime.Now < limite && ProcessusDuDossier(dossier).Length > 0) Thread.Sleep(250);
        foreach (Process p in ProcessusDuDossier(dossier)) { try { p.Kill(); p.WaitForExit(3000); } catch { } }

        // 2. Windows remis comme avant : rien à faire pour le témoin (une vraie appli défait ici ce qu'elle a changé)

        // 3. Ses programmes, sauf ce désinstalleur qui tourne : Temoin.exe d'abord
        int restes = 0;
        foreach (string f in new[] { Path.Combine(dossier, "Temoin.exe") })
            try { if (File.Exists(f)) File.Delete(f); } catch { restes++; }
        string moi = Process.GetCurrentProcess().MainModule.FileName;
        foreach (string f in Directory.GetFiles(dossier))
            if (!string.Equals(f, moi, StringComparison.OrdinalIgnoreCase)) try { File.Delete(f); } catch { restes++; }
        foreach (string d in Directory.GetDirectories(dossier)) try { Directory.Delete(d, true); } catch { restes++; }

        // 4. Ses données, si c'est le choix
        if (supprimer) try { if (Directory.Exists(donnees)) Directory.Delete(donnees, true); } catch { restes++; }

        // 5. Ce désinstalleur et le dossier vide : retirés juste après sa fin, par l'invite de commandes de Windows (sans fenêtre)
        try
        {
            string cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
            var psi = new ProcessStartInfo(cmd, "/d /c \"ping -n 3 127.0.0.1 >nul & del /f /q \"" + moi + "\" & rd /s /q \"" + dossier + "\"\"");
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Environment.SystemDirectory;
            using (Process.Start(psi)) { }
        }
        catch { }
        return restes == 0 ? 0 : 1;
    }

    // Les programmes lancés depuis ce dossier (par leur chemin, jamais par leur nom), sauf ce désinstalleur
    static Process[] ProcessusDuDossier(string dossier)
    {
        var r = new System.Collections.Generic.List<Process>();
        string prefixe = dossier.TrimEnd('\\') + "\\";
        int moi = Process.GetCurrentProcess().Id;
        foreach (Process p in Process.GetProcesses())
        {
            if (p.Id == moi) continue;
            try { if (p.MainModule.FileName.StartsWith(prefixe, StringComparison.OrdinalIgnoreCase)) r.Add(p); } catch { }
        }
        return r.ToArray();
    }
#endif

#if RELAIS
    // Les arguments reçus, remis en une ligne de commande (guillemets et barres obliques inverses selon la règle de Windows)
    static string Arguments(string[] args)
    {
        var sb = new StringBuilder();
        foreach (string a in args)
        {
            if (sb.Length > 0) sb.Append(' ');
            if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) { sb.Append(a); continue; }
            sb.Append('"');
            int barres = 0;
            foreach (char c in a)
            {
                if (c == '\\') { barres++; continue; }
                if (c == '"') { sb.Append('\\', barres * 2 + 1); sb.Append('"'); barres = 0; continue; }
                sb.Append('\\', barres); barres = 0;
                sb.Append(c);
            }
            sb.Append('\\', barres * 2);
            sb.Append('"');
        }
        return sb.ToString();
    }
#endif
}
