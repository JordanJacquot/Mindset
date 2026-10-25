// Mindset.exe : le programme Mindset. Il exécute lui même le code de Mindset (fichiers\Mindset.ps1)
// au lieu de le confier à powershell.exe : pour Windows, c'est une vraie application, avec son nom
// et son icône (barre des tâches, Gestionnaire des tâches).
// Compilé par construire.ps1.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Mindset")]
[assembly: AssemblyProduct("Mindset")]
[assembly: AssemblyDescription("Le portail de la suite : Nevermind et Evermind au même endroit")]
[assembly: AssemblyVersion("2.10.0.0")]
[assembly: AssemblyFileVersion("2.10.0.0")]

static class Lanceur
{
    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        string dossier = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(Path.Combine(dossier, "fichiers"), "Mindset.ps1");

        // « Mindset.exe -Desinstaller » (ancienne entrée de « Applications installées ») : le désinstalleur autonome,
        // sans passer par le code de Mindset (il marche même si fichiers\Mindset.ps1 est supprimé ou abîmé)
        string desinstalleur = Path.Combine(dossier, "Desinstaller Mindset.exe");
        foreach (string a in args)
        {
            if (!string.Equals(a, "-Desinstaller", StringComparison.OrdinalIgnoreCase) || !File.Exists(desinstalleur)) continue;
            try
            {
                System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo(desinstalleur);
                psi.WorkingDirectory = Environment.SystemDirectory;   // (pas le dossier de Mindset : il doit pouvoir être supprimé)
                System.Diagnostics.Process.Start(psi);
                return 0;
            }
            catch (Exception e) { Journal("Désinstalleur : " + e.Message); }
        }

        if (!File.Exists(script))
        {
            MessageBox.Show(
                "Le dossier « fichiers » est introuvable à côté de ce programme.\n\n" +
                "Extrais d'abord tout le zip (clic droit sur le zip, puis « Extraire tout »), " +
                "puis lance Mindset depuis le dossier extrait.",
                "Mindset", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }

        try
        {
            // Le code tourne sur ce fil (STA, nécessaire aux fenêtres), sans les restrictions de scripts de Windows
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    // « Mindset.exe -Demarrage » (lancé avec Windows), « -Desinstaller » (Applications installées, sans
                    // le désinstalleur autonome à côté)
                    foreach (string a in args)
                    {
                        if (string.Equals(a, "-Demarrage", StringComparison.OrdinalIgnoreCase)) ps.AddParameter("Demarrage");
                        else if (string.Equals(a, "-Desinstaller", StringComparison.OrdinalIgnoreCase)) ps.AddParameter("Desinstaller");
                    }
                    ps.Invoke();
                    if (ps.Streams.Error.Count > 0)
                    {
                        StringBuilder sb = new StringBuilder();
                        foreach (ErrorRecord e in ps.Streams.Error) sb.AppendLine(e.ToString() + " (" + e.InvocationInfo.PositionMessage + ")");
                        Journal("Erreurs : " + sb);
                    }
                }
            }
        }
        catch (Exception e)
        {
            Journal("Arrêt inattendu : " + e);
            MessageBox.Show("Mindset s'est arrêté à cause d'une erreur :\n\n" + e.Message, "Mindset", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }

    // Même journal que le code de Mindset : <données>\Mindset\journal.txt (voir modules\donnees.ps1)
    static void Journal(string texte)
    {
        try
        {
            string dir = DossierDonnees(AppDomain.CurrentDomain.BaseDirectory);
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "journal.txt"), DateTime.Now.ToString("s") + " " + texte + "\r\n", new UTF8Encoding(false));
        }
        catch { }
    }

    // Le dossier des données de Mindset, déduit de l'emplacement de ce programme (même règle que Get-RacinesDepuis dans
    // modules\donnees.ps1) : installé sur un autre disque (X:\Mindset\Programmes\Mindset), X:\Mindset\Donnees\Mindset ;
    // sinon %LOCALAPPDATA%\Mindset\Mindset. Lancé hors de son installation (dossier téléchargé) : celle inscrite dans
    // « Applications installées », comme le code de Mindset.
    static string DossierDonnees(string dossierExe)
    {
        string d = DonneesSurAutreDisque(dossierExe);
        if (d != null) return d;
        try
        {
            string moi = Path.GetFullPath(dossierExe).TrimEnd('\\', '/');
            string defaut = Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Mindset"), "Mindset");
            if (!string.Equals(moi, defaut, StringComparison.OrdinalIgnoreCase))
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset"))
                {
                    string inscrit = k == null ? null : k.GetValue("InstallLocation") as string;
                    if (!string.IsNullOrEmpty(inscrit) && File.Exists(Path.Combine(inscrit, "Mindset.exe")))
                    {
                        d = DonneesSurAutreDisque(inscrit);
                        if (d != null) return d;
                    }
                }
            }
        }
        catch { }
        return Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mindset"), "Mindset");
    }

    // X:\Mindset\Programmes\Mindset donne X:\Mindset\Donnees\Mindset ; tout autre dossier, null
    static string DonneesSurAutreDisque(string dossierMindset)
    {
        try
        {
            DirectoryInfo p = new DirectoryInfo(dossierMindset.TrimEnd('\\', '/')).Parent;
            DirectoryInfo m = p == null ? null : p.Parent;
            if (p != null && m != null && string.Equals(p.Name, "Programmes", StringComparison.OrdinalIgnoreCase) && string.Equals(m.Name, "Mindset", StringComparison.OrdinalIgnoreCase))
                return Path.Combine(Path.Combine(m.FullName, "Donnees"), "Mindset");
        }
        catch { }
        return null;
    }
}
