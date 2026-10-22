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
[assembly: AssemblyVersion("2.3.4.0")]
[assembly: AssemblyFileVersion("2.3.4.0")]

static class Lanceur
{
    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        string dossier = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(Path.Combine(dossier, "fichiers"), "Mindset.ps1");

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
                    // « Mindset.exe -Demarrage » (lancé avec Windows), « -Desinstaller » (Applications installées)
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

    // Même journal que le code de Mindset (%LOCALAPPDATA%\Mindset\Mindset\journal.txt)
    static void Journal(string texte)
    {
        try
        {
            string dir = Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mindset"), "Mindset");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "journal.txt"), DateTime.Now.ToString("s") + " " + texte + "\r\n", new UTF8Encoding(false));
        }
        catch { }
    }
}
